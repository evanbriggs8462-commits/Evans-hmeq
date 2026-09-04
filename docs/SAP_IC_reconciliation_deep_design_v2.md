# SAP intercompany reconciliation deep design v2

Date: 2026-09-03  
Scope: global AR/AP out-of-balance reporting, missing trading-partner recovery, split profit-center reporting, GR/IR diagnostics, ECC/S/4HANA/legacy adapters, and Databricks/Genie serving.

This document extends the static review in `SAP_IC_SQL_review.md`. It does not replace source-system reconciliation, accounting policy, or a controlled SAP/Databricks test using actual company, account, document-type, currency, and reversal configurations.

## Executive decision

The current query starts with `VBUND <> blank`. That makes a missing trading partner invisible precisely when it is most likely to create an intercompany exception. The production design should make these two operations independent:

1. **IC population:** decide whether a source item is potentially intercompany.
2. **Partner resolution:** preserve the posted partner and collect evidence for a canonical counterparty; resolve only when the evidence is unique and defensible.

A blank `VBUND` must therefore become `UNRESOLVED`, `AMBIGUOUS`, or a provenance-bearing derived partner. It must never mean `EXTERNAL`, and it must not remove the amount from the denominator.

Four other boundaries are equally important:

- A company-pair balance can net to zero while the underlying documents remain unassigned. SAP explicitly calls out this condition in its cross-system intercompany reconciliation documentation. [SAP: Interactive Reconciliation](https://help.sap.com/docs/SAP_ERP/1cd6e1d47833422fb4dc6e28de61c5b5/4dd0086bcdbe0be7e10000000a42189e.html)
- Legal-entity AR/AP matching and profit-center allocation are different controls. A financial match can be valid while its management allocation is incomplete.
- GR/IR is a procurement-lifecycle exception fact. It can support a timing explanation only through direct buyer/seller lineage; it is not a third amount to add to a pair-level AR/AP residual.
- Genie should query certified reconciliation facts and trusted functions, never reconstruct SAP joins or matching logic from raw tables.

## What changes in the submitted SQL

| Current lines | Current behavior | Why it can hurt | Required replacement |
|---|---|---|---|
| 27–31 | Builds `active_ar_entities` only from rows with a populated `VBUND`. | An entity with only blank-partner defects appears absent and can be mislabeled one-sided. | Build source-coverage status from the system inventory and load controls, independent of partner completeness. |
| 100, 106 | Excludes blank-partner AR before analysis. | Missing-partner IC receivables are omitted from both exposure and data-quality totals. | Select by governed IC scope plus other IC evidence; resolve partner afterward. |
| 161–164 | Tests a raw trading-partner company ID against an OU hierarchy and may return a BU. | SAP company/trading-partner identity is not an OU or BU identifier. Coincidentally equal codes can be silently mistranslated. | Map `source partner ID -> canonical legal entity`; map legal entity to management structures in a separate effective-dated bridge. |
| 225 | Uses `MAX` for document and vendor partner evidence. | Conflicting partners become a plausible-looking arbitrary value. | Emit one evidence row per candidate, count distinct canonical candidates, and mark conflict/ambiguity. |
| 239, 245 | Excludes blank-partner AP. | Missing-partner IC payables disappear. | Use account/master/application evidence for IC candidacy before partner resolution. |
| 278 | Excludes blank-partner manual IC accruals. | The population most likely to need manual coding is removed. | Include governed IC manual-JE accounts/document types and report partner completeness. |
| 325–327 and equivalents | Uses local T001 mapping and the AR population to infer source visibility. | `T001-RCOMP` can map several company codes to one company ID, and a partner can live in another ingested instance. | Use a global, effective-dated entity/source-coverage dimension. |
| 383–405 | Repeated scalar subqueries convert GR/IR partner values into BU values. | This is costly at scale and repeats the company-ID-versus-OU error. | Resolve partner once in a persisted table, then join a unique legal-entity/management bridge. |
| 420 | Removes GR/IR with no recovered partner. | The most important diagnostic population is discarded. | Keep it as `PARTNER_MISSING` and quantify the exposure. |
| 459–467 | Nets all history by an unordered BU pair without currency, cutoff, legal entity, rule version, or match assignment. | Unrelated lines and currencies can offset; results cannot be reproduced as of a close. | Persist legal-entity match groups and members by currency and cutoff, then allocate to management dimensions. |
| 475–478 | Labels a pair balanced or timing-explained from aggregate thresholds and signs. | It can call unrelated GR/IR a timing explanation and can hide zero-net unassigned items. | Separate `balance_status`, `match_status`, `difference_type`, `cause_code`, `resolution_status`, and `close_status`. |

The first production refactor should remove blank-partner predicates at the **candidate population** stage, not simply delete the predicates from the current monolith. Doing only that would make the query much larger and amplify its existing joins.

## 1. Canonical grains and identities

### Source financial item

For ECC operational FI items, the normal minimum key is:

```text
source_system + SAP client + BUKRS + BELNR + GJAHR + BUZEI
```

Add ledger or other source-specific qualifiers wherever the adapter requires them. Never assume a document number, company code, customer, supplier, profit center, or trading-partner ID is globally unique.

For S/4HANA, keep the operational BSEG item number (`BUZEI`) and Universal Journal line (`ACDOCA-DOCLN`) as different identifiers. Build an explicit bridge where ledger allocations are related to operational open items; do not equate the two numbers.

### Legal pair versus management pair

Persist both directional and unordered keys:

```text
owner_global_entity_id
resolved_partner_global_entity_id
directional_entity_pair_id
unordered_entity_pair_id

owner_profit_center_id
partner_profit_center_id
owner_ou_id / partner_ou_id
owner_bu_id / partner_bu_id
```

`VBUND`/`RASSC` represents a trading-partner company ID. `PPRCTR` is a partner profit center where populated. SAP exposes company, trading partner, profit center, and partner profit center as separate reporting characteristics. [SAP: Financial Statements characteristics](https://help.sap.com/docs/SAP_ERP/44d76b07aa8e45899a2e83923c3d11ba/747908c6d0724652b97e35bae8396675.html)

### Amount grain

Keep, at minimum:

- exact signed document-currency amount and currency;
- exact signed local/company-code amount and currency;
- exact signed group/reporting-currency amount, currency, rate type, rate date, and rate version;
- quantity and UOM for procurement events;
- original item amount and allocated amount.

Never expose one ambiguous `amount` column. Matching should begin in transaction/document currency. Translation differences should be reported separately rather than used to force a transactional match.

## 2. IC candidate universe before partner resolution

Create `ic_candidate_item` from the union of independently governed signals. A row is a candidate if **any** approved signal is true:

```text
posted_partner_present
OR account_is_in_effective_dated_ic_scope
OR customer_or_supplier_master_is_affiliated
OR counterparty_account_is_in_internal_party_crosswalk
OR direct_sd_intercompany_lineage_exists
OR direct_mm_or_sto_intercompany_lineage_exists
OR cross_company_fi_transaction_evidence_exists
OR universal_journal_partner_evidence_exists
OR approved_manual_scope_rule_applies
```

The table must retain `ic_scope_reason[]`, not just a Boolean. It also needs a negative control population so the team can estimate false positives when account-level rules are broad.

Recommended scope fields:

| Field | Purpose |
|---|---|
| `source_item_id` | Stable, collision-free source-line identity. |
| `scope_rule_id`, `scope_rule_version` | Reproduce why the item entered the IC population. |
| `scope_evidence_type` | Posted partner, account scope, master affiliation, SD, MM/STO, cross-company FI, manual rule, and so on. |
| `scope_effective_from/to` | Prevent today’s map from silently rewriting history. |
| `scope_is_deterministic` | Distinguish a structural IC indicator from a broad review signal. |
| `scope_run_id`, `source_watermark` | Reconcile the result to one controlled extraction state. |

SAP documents that trading-partner population depends on document-type settings and master data. A document can contain one or several partners, and for document types that allow cross-company posting, the partner is not necessarily inherited to other items. [SAP: Trading partner (BSEG-VBUND) in FI posting](https://help.sap.com/docs/SUPPORT_CONTENT/fiaccounting/3361880810.html) This is why neither blankness nor same-document copying is a safe population rule by itself.

## 3. Missing-partner evidence model

### Preserve evidence atomically

Use a narrow `ic_partner_evidence` table with **one row per source item, evidence rule, and candidate partner**:

```text
source_item_id
candidate_global_entity_id
raw_candidate_value
evidence_rule_id / version / priority
evidence_source_system / table / key
evidence_observed_at
evidence_effective_from / to
determinism_class
candidate_strength
reciprocal_evidence_flag
evidence_payload_hash
```

Do not join this multirow table directly to financial measures. Resolve it into a one-row-per-item table first.

### Recommended evidence ladder

The exact priority is enterprise policy, but the following is a defensible starting point. A lower tier is not allowed to override a conflicting higher tier silently.

| Tier | Evidence | Automation posture | Important condition |
|---|---|---|---|
| A | Posted line partner: ECC `VBUND`, S/4 `RASSC`, or equivalent legacy field. | Accept after mapping validation. | Raw value maps to exactly one effective canonical legal entity. Preserve the raw value even if invalid. |
| B | Customer/supplier or BP master partner as of the posting date. | Accept when unique and historically valid. | Use source/client/account identity and an SCD2 snapshot. SAP identifies `KNA1-VBUND` and `LFA1-VBUND` as trading-partner fields. [SAP semantic IDs](https://help.sap.com/docs/signavio-process-insights/administration-guide/be4b0a35f6d048eb979899f569509c78.html) |
| C | Direct application lineage that structurally identifies both companies: intercompany billing, internal customer/supplier, PO/STO supplying/receiving company, or controlled interface message. | Accept only from a tested, unique path. | Persist the originating billing/PO/item/delivery/interface key. In SAP intercompany sales, the selling company and delivering plant belong to different company codes and the delivering company bills the selling company. [SAP intercompany sales](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/7b24a64d9d0941bda1afa753263d9e39/e770b6535fe6b74ce10000000a174cb4.html) |
| D | Cross-company FI transaction group, including a unique counterpart found through the cross-company transaction reference and configured clearing lines. | Accept only after instance-level proof. | `BSEG-KTOSL='BUV'` is documented as cross-company posting evidence, but it does not itself name a globally mapped partner. [SAP Central Finance guide](https://help.sap.com/doc/a9616f4a29354fc297c58499b754e3f8/1909.002/en-US/loio4857c0540cf5ef05e10000000a4450e5.pdf) |
| E | Approved, effective-dated legacy counterparty or internal-account crosswalk. | Accept if owner, approval, and validity are present. | Never treat an unmanaged spreadsheet’s latest value as historical truth. |
| F | Same-document consensus. | Derived/suggested unless proven for the document type. | Exactly one distinct mapped partner across eligible sibling lines; no conflicting customer, supplier, SD, MM, or cross-company evidence. SAP permits different partners in one FI document, so `MAX(VBUND)` is unsafe. |
| G | Reciprocal reference/amount/date/text similarity. | Suggestion only. | Amount and date alone never auto-resolve a legal counterparty. Retain candidate count and ambiguity. |

SAP’s own flexible derivation behavior leaves a partner empty when zero or multiple partner-unit assignments are possible. That is the right control precedent: ambiguity is an output, not a reason to select the first row. [SAP: Flexible Derivation of Consolidation Units](https://help.sap.com/docs/SAP_S4HANA_CLOUD/90c07e91c7a64f328be3fd6b48955b13/1f915048593941e88672f6887478c0ae.html)

Specific technical paths within those tiers need separate rules and tests:

- **Reversal lineage:** use the exact original-document link (`BKPF-STBLG/STJAH`) when present and the original resolves to one partner. SAP’s older SD cancellation procedure does not always populate that FI reversal link, so SD cancellations must also follow the billing/document flow. [SAP: Billing cancellation and FI reversal behavior](https://help.sap.com/docs/SUPPORT_CONTENT/sd/3362915532.html)
- **Residual/partial-payment lineage:** original document/year/item references such as `REBZG/REBZJ/REBZZ` can be strong evidence when complete. Absence is not disproof because partial-payment references can be optional. Never take `MAX` across one clearing document that settles several invoices or partners. [SAP: Residual and partial payment](https://help.sap.com/docs/SUPPORT_CONTENT/fiaccounting/3361878585.html)
- **Cross-company FI group:** use `BKPF-BVORG`/`BVOR` only when the same source system/client transaction maps to exactly two distinct canonical companies. With three or more companies, it is a group identifier, not a unique counterparty. [SAP: Cross-company-code transactions](https://help.sap.com/docs/SAP_ERP/34e83d3c59844048bb8289f00ce23ddd/b7a4bb53707db44ce10000000a174cb4.html)
- **SD to FI:** follow `BKPF-AWTYP/AWKEY/AWSYS` to the originating application document, then billing/document flow and the internal payer/customer. Never use `FI BELNR = VBRP-VBELN`. Multi-level intercompany billing requires the adjacent invoicing counterparty, not the ultimate shipper or seller. [SAP: Reference transaction linkage](https://help.sap.com/docs/SAP_ERP/250f73843ea3416684389f4de2525704/217dd0531d8b4208e10000000a174cb4.html)
- **EDI/IDoc:** an exact outbound intercompany billing to inbound supplier-invoice/AP chain can be strong evidence when message, invoice/PO reference, status, and legal-entity mapping are present. `EDIDC-SNDPRN/RCVPRN` alone identifies a logical/technical partner and must not be assumed to be one legal entity.
- **MM/STO:** prove that receiving and supplying plants belong to different companies, then resolve the adjacent supplying/receiving company through the exact PO/item flow. Ordinary external POs, intracompany STOs, returns, and multi-hop advanced intercompany flows require distinct rules. [SAP: Cross-company stock transport setup](https://help.sap.com/docs/SAP_ERP/b704a8db767040a08100adc846218964/ba60bd534f22b44ce10000000a174cb4.html)
- **One-time accounts:** exclude collective one-time customer/vendor masters from automatic master-based resolution unless item-level address/counterparty evidence supplies the legal entity. [SAP: One-time accounts](https://help.sap.com/docs/SAP_ERP/72b431fb78a649da9c8b46951e64fb88/e7d8cb53f0f67314e10000000a174cb4.html)
- **Partner profit center:** `PPRCTR` can support BU/OU allocation after legal-partner resolution, but it is not itself proof of a legal entity. Profit centers can span company codes within a controlling area.
- **Free references:** `XBLNR`, `ZUONR`, `XREF1-3`, PO/SO/invoice numbers, text, amount, and date remain suggestions unless a locally governed namespace is collision-free and has passed point-in-time validation.

SAP publishes a dedicated control for intercompany bookings with no trading partner. This supports reporting missing partner as its own control population instead of laundering it into an inferred pair. [SAP: Intercompany bookings with no trading partner](https://help.sap.com/docs/risk-and-assurance-management/business-content-risk-and-assurance-management/intercompany-bookings-with-no-trading-partner)

### Resolution result

`ic_partner_resolution` should contain exactly one row per source item and resolution run:

```text
raw_partner_id
resolved_global_entity_id
resolution_status       -- POSTED, DERIVED_UNIQUE, AMBIGUOUS, CONFLICT, UNRESOLVED
resolution_method
strongest_evidence_tier
candidate_count
strongest_candidate_count
conflicting_candidate_count
mapping_version
resolution_rule_version
resolution_run_id
```

Decision logic:

1. Map every evidence candidate to a canonical entity before comparing candidates.
2. If the strongest eligible tier has one canonical candidate and no disqualifying higher-tier conflict, resolve it.
3. If the strongest tier has more than one candidate, return `AMBIGUOUS`.
4. If authoritative tiers disagree, return `CONFLICT` even if a priority could technically choose one.
5. If no eligible candidate exists, return `UNRESOLVED`.

`MAX`, `MIN`, `FIRST`, `ANY_VALUE`, or `ROW_NUMBER() = 1` without an explicit uniqueness assertion must never constitute partner resolution.

### Backtest every fallback

Use populated, trusted partner rows as a labeled holdout:

1. Hide the posted partner.
2. Run every fallback independently.
3. Compare the derived canonical entity with the hidden truth.
4. Segment results by source system/client, company, account, document type, posting key, process, year, and amount band.
5. Test future periods separately; do not randomly split rows across time and leak later master mappings into earlier observations.

Publish these metrics for each rule/version:

- eligible items and amount;
- coverage rate;
- exact precision and amount-weighted precision;
- ambiguous/conflicting rate;
- reciprocal-consistency rate;
- false-resolution amount;
- stability across time and systems.

For a billion-dollar control, a high average precision is not sufficient if one rule fails on the largest items. Automatic use should be limited to deterministic, unique, versioned paths that pass the finance-approved amount-weighted tests. Everything else remains suggested or unresolved.

A conservative promotion proposal—not an SAP requirement—is to require the 95% lower confidence bound on precision to exceed 99.9% in both row-count and material-value strata, zero known high-materiality false assignments, and two successful shadow closes. Even this does not eliminate judgment: with zero observed errors, roughly 3,000 independent test cases are needed merely to support that one-sided binomial bound, and amount concentration needs its own stress test.

## 4. ECC, S/4HANA, Central Finance, and legacy adapters

All systems should emit the same canonical contract but use different physical adapters.

| Adapter | Operational/open-item source | Ledger/allocation source | Key caution | Partner evidence |
|---|---|---|---|---|
| ECC classic/new GL | `BKPF/BSEG`, `BSID/BSAD`, `BSIK/BSAK`, and scoped G/L open-item indexes | New-GL/document-splitting sources such as `FAGLFLEXA` and applicable split-information tables | Include `MANDT` and `BUZEI`; resolve extractor CDC state before unioning indexes. | `VBUND`, KNA1/LFA1, SD/MM document flow, cross-company group, controlled mappings. |
| S/4HANA | BSEG/open-item compatibility views for operational clearing behavior | `ACDOCA` for ledger allocations; keep `DOCLN` separate from `BUZEI` | Compatibility views do not make BSEG and ACDOCA grains interchangeable. | `RASSC`, `PPRCTR`, BP/customer/supplier, application lineage. |
| Central Finance | Central document plus original-system reference fields | Central universal-journal allocation | A central document ID is not the original source key; initial-load and replication limitations must be visible. | Central mapped partner plus source-system partner/evidence, retained separately. |
| Non-SAP/legacy | Native subledger/GL adapter | Native segment/allocation source | Do not manufacture SAP keys or assume local IDs are global. | Effective-dated entity/account/counterparty crosswalk and original external references. |

SAP Cross-System ICR was designed to select data from SAP systems, clients, and non-SAP sources into a reconciliation database. That supports the adapter pattern, while still requiring the original source identity. [SAP: Cross-System Intercompany Reconciliation](https://help.sap.com/docs/SAP_ERP/44ff4797667d4fd88d845044c010bb00/6b5a7c525ae17154e10000000a44176d.html)

Use these separate statuses:

```text
PARTNER_SOURCE_INGESTED
PARTNER_SOURCE_NOT_INGESTED
PARTNER_SOURCE_LATE
PARTNER_SOURCE_FAILED_CONTROL
PARTNER_ENTITY_UNMAPPED
PARTNER_ITEM_NOT_FOUND
```

Calling all of them `ONE_SIDED` conceals fundamentally different remedies.

## 5. Matching and allocation

### Match legal items first

Persist two objects:

- `ic_match_group`: scope, rule/version/order, cutoff, currency, cardinality, side totals, residual, tolerance, match status, reason, and run lineage.
- `ic_match_member`: group ID, source item/allocation ID, side/role, original and assigned amount, membership type, and evidence.

Support 1:1, 1:M, M:1, and M:M explicitly. Oracle ARCS and OneStream both document these cardinalities, tolerances, and suggested/automatic outcomes. [Oracle: Match Rules](https://docs.oracle.com/en/cloud/saas/account-reconcile-cloud/raarc/admin_trans_match_about_match_rules.html) [OneStream: Transaction Matching Rules](https://documentation.onestream.com/docs/Content/TXM/Rules.html)

Candidate generation at scale should be bounded:

1. Use changed source keys from CDC or the current run’s delta.
2. Create selective buckets using canonical entity pair, currency, normalized exact references, direct PO/billing lineage, bounded posting/due-date windows, and governed amount bands.
3. Probe only affected reciprocal buckets.
4. Store candidate edges in an engineering-only table.
5. Apply exact rules first, then bounded grouped/tolerance rules, then suggested rules.
6. Publish only selected assignments and unresolved items.

Do not repeatedly run a full AR × AP join, and do not expose candidate edges to Genie.

This order should be persisted as configuration. SAP ICMR likewise applies matching rules sequentially, with records assigned by an earlier rule excluded from later rules. [SAP: Define Matching Methods](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/651d8af3ea974ad1a4d74449122c620e/885a3eb67393430291c54d62c6eb9390.html) Normalize invoice, PO, assignment, and other reference tokens into persisted columns before bucket aggregation; SAP’s matching example warns that transformations applied after aggregation may not create the intended groups. [SAP: Example of Matching Run](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/4ebf1502064b406c964b0911adfb3f01/2e011ae22663463c98acae54d2defe43.html)

### Allocate matched items to profit centers afterward

An allocation row should contain:

```text
source_item_id
match_group_id
allocation_id
owner_profit_center / partner_profit_center
allocation_basis
allocation_weight
allocated_amount_dc / lc / gc
allocation_status
allocation_residual
```

Required control:

```text
SUM(allocated amount by source item and currency) = original source-item amount
```

SAP ICMR supports company/profit-center matrix dimensions paired with partner company/partner profit center. This is evidence for retaining both sides of the split rather than choosing a dominant value. [SAP: Matrix Reconciliation](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/4ebf1502064b406c964b0911adfb3f01/da33c8dae32840d9a731e832c33f0f31.html)

Use independent fields:

```text
financial_match_status
owner_allocation_status
partner_allocation_status
allocation_reciprocity_status
```

## 6. GR/IR that explains rather than merely nets

### Correct fact grain

Build the buyer-side GR/IR fact at:

```text
source system + client + company + PO + PO item + account assignment
+ valuation/currency basis + cutoff
```

Retain the original FI line keys and the PO-history event keys. Important fields include `EBELN`, `EBELP`, account assignment, vendor/internal counterparty, plant and company ownership, quantity, UOM, amount/currency, event type, reversal link, posting date, clearing status, and source watermark.

Before classifying any event, profile and govern each instance’s `EKBE-VGABE`, `BEWTP`, movement type, invoice/GR indicators, debit/credit sign, reversal and return behavior. Do not infer lifecycle meaning from `SHKZG` alone.

### Useful lifecycle exception types

| Exception | Meaning | AR/AP relevance |
|---|---|---|
| `GR_POSTED_IR_NOT_POSTED` | Receipt is recorded; invoice receipt/vendor AP is missing or short. | Can explain a seller AR versus missing buyer AP only when buyer/seller/PO-item lineage is confirmed and the open GR/IR direction agrees. |
| `IR_POSTED_GR_NOT_POSTED` | Invoice/AP exists; goods receipt is missing or short. | Does not explain missing buyer AP; it is a logistics/receipt timing exception. |
| `GR_IR_QUANTITY_MISMATCH` | Received and invoiced quantities differ after normalized UOM and reversals. | Show quantity root cause; do not hide it in value netting. |
| `GR_IR_PRICE_OR_VALUE_MISMATCH` | Quantities align but values do not. | Candidate causes include price, tax, freight, FX, or valuation; requires separate cause. |
| `REVERSAL_OR_RETURN_OPEN` | Event and reversal/return chain is incomplete or cut off. | Prevents false aging and false timing matches. |
| `INVOICE_BLOCKED_OR_HELD` | Invoice exists but is blocked/held according to the available source process. | Operational explanation, not a missing invoice. |
| `PO_LINEAGE_MISSING_OR_AMBIGUOUS` | The GR/IR amount cannot be uniquely tied to PO/item/account assignment. | Diagnostic only; never combine with AR/AP. |
| `STANDALONE_DOCUMENT` | Billing, AP, GR, IR, return, or credit has no expected predecessor/successor. | Route to a lifecycle-specific queue. |

NetSuite’s published intercompany reconciliation report separates unlinked orders, amount mismatches, fulfillment/receipt/billing quantity mismatches, billing amount mismatches, and standalone documents. That is a useful reporting precedent for GR/IR lifecycle states. [Oracle NetSuite: Intercompany Reconciliation](https://docs.oracle.com/en/cloud/saas/netsuite/ns-online-help/section_N1502183.html)

### Link standard

An AR/AP exception may be labeled `TIMING_SUPPORTED_BY_GRIR` only when all of these are true:

- direct and unique billing/PO/item or equivalent application/interface lineage;
- reciprocal canonical entities;
- same governed cutoff and compatible currency/valuation basis;
- buyer GR/IR event classification is `GR_POSTED_IR_NOT_POSTED` after reversals;
- the linked amount allocation is bounded and does not exceed either source exposure;
- no competing linkage at the same evidence tier;
- rule and lineage versions are recorded.

Otherwise, expose `POSSIBLE_RELATED_GRIR` as a suggestion or a separate diagnostic. Never compute `AR + AP + all pair GRIR` and call a smaller absolute value a match.

OneStream’s documented three-dataset matching is a useful implementation analogy: seller billing/AR, buyer vendor invoice/AP, and buyer PO history can form a three-dataset group when exact lineage exists. [OneStream: Transaction Matching Rules](https://documentation.onestream.com/docs/Content/TXM/Rules.html)

## 7. Enterprise reporting model

The cross-vendor pattern is five connected but distinct views:

1. **Balance:** entity/partner/account/currency/cutoff totals.
2. **Transaction assignment:** match groups, members, cardinality, and residual.
3. **Exception explanation:** difference type, cause, support, comments, and evidence.
4. **Resolution workflow:** owner, due date, action, approval, and adjustment/reversal.
5. **Close/certification:** immutable close snapshot, source watermark, rule version, closer, and late-change/outdated status.

SAP reconciliation cases define two-sided display groups and tolerances, while reason codes can require comments, workflow, temporary resolution, rematching, or adjustment posting. [SAP: Reconciliation Case](https://help.sap.com/docs/SAP_S4HANA_CLOUD/90c07e91c7a64f328be3fd6b48955b13/896c9e2bb0124e2dbe03eed2b7e73fa4.html) [SAP: Reason Code](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/4ebf1502064b406c964b0911adfb3f01/ee560774552a41eb977f28b508257494.html)

Other enterprise products reinforce the same control pattern. These are design comparisons, not substitutes for SAP-specific validation:

| Product | Publicly documented pattern | Design implication here |
|---|---|---|
| Oracle Account Reconciliation | 1:1, 1:M, M:1 and M:M rules; amount/date tolerances; automatic, suggested and ambiguous outcomes; supported unmatched transactions with retained justification. [Oracle: Matching engine](https://docs.oracle.com/en/cloud/saas/account-reconcile-cloud/suarc/admin_trans_match_overview_matching_engine_100x0f827b25.html) [Oracle: Supported transactions](https://docs.oracle.com/en/cloud/saas/account-reconcile-cloud/raarc/reconcile_trans_match_supported_transactions_about.html) | Preserve match cardinality/candidate count and distinguish `SUPPORTED_UNMATCHED` from matched or unexplained. |
| OneStream | Two- or three-dataset matching with grouped/tolerance rules, plus reconciliation reporting for balance, explained/unexplained amount, state, risk, owner and aging. [OneStream: Rules](https://documentation.onestream.com/docs/Content/TXM/Rules.html) [OneStream: Reconciliation analysis](https://documentation.onestream.com/docs/Content/RCM/Analysis.html) | Three-way GR/IR is appropriate only with direct lineage; retain original age, risk and responsibility. |
| BlackLine | ERP-agnostic intercompany detail, status, support, journals, FX/tax/exception data, workflow and audit trail; matching includes grouped outcomes and reason codes. [BlackLine: Balance & Resolve](https://www.blackline.com/products/intercompany/balance-and-resolve/) [BlackLine: Transaction Matching](https://pages.blackline.com/rs/blacklinesystems/images/Transaction%20Matching.pdf) | Normalize centrally while retaining ERP lineage, evidence, explanation and action history. Public material is product-level, so it is not a field specification. |
| Microsoft Dynamics 365 | Reconciliation distinguishes subledger-not-ledger, ledger-not-subledger and amount mismatch, then records match, adjustment, reversal, accept-without-change and undo actions. [Microsoft: Account reconciliation](https://learn.microsoft.com/en-us/dynamics365/finance/general-ledger/account-reconciliation) | Keep detected exception type separate from the corrective action. |
| Oracle NetSuite | Intercompany reconciliation separates unlinked orders/returns, amount and quantity mismatches, and standalone invoices/bills/credits/payments. [Oracle NetSuite: IC reconciliation](https://docs.oracle.com/en/cloud/saas/netsuite/ns-online-help/section_N1502183.html) | Report procurement/billing lifecycle failures separately instead of hiding them in a three-way net. |

Recommended orthogonal status fields:

```text
difference_type:
  PARTNER_MISSING, PARTNER_AMBIGUOUS, PARTNER_CONFLICT,
  MISSING_BUYER_SIDE, MISSING_SELLER_SIDE, REFERENCE_AMBIGUOUS,
  AMOUNT_MISMATCH, CURRENCY_MISMATCH, PERIOD_LAG,
  QUANTITY_MISMATCH, PROFIT_CENTER_SPLIT_MISMATCH,
  REVERSAL_OR_RETURN, STANDALONE_DOCUMENT, SUBLEDGER_GL_GAP

cause_code:
  TIMING, FX, ROUNDING, TAX, FREIGHT, PRICING, MASTER_DATA,
  MAPPING, INTERFACE_FAILURE, POSTING_ERROR, UNKNOWN

match_status:
  UNMATCHED, SUGGESTED_AMBIGUOUS, SUGGESTED,
  AUTO_EXACT, AUTO_TOLERATED, MANUAL, SUPPORTED_UNMATCHED

resolution_status:
  OPEN, INVESTIGATING, WAIT_NEXT_PERIOD, ADJUSTMENT_REQUIRED,
  PENDING_APPROVAL, ADJUSTMENT_POSTED, REVERSED, RESOLVED

close_status:
  OPEN, PENDING_APPROVAL, CLOSED, REOPENED, OUTDATED
```

Oracle Fusion reports from provider/receiver legal entity and transaction currency and explicitly exposes unassigned legal entities. Oracle FCCS includes entity/partner, account/matching or plug account, scenario, period, reporting currency, data source, movement, and custom dimensions. [Oracle Fusion: IC reconciliation](https://docs.oracle.com/en/cloud/saas/financials/26b/faiac/overview-of-intercompany-reconciliation.html) [Oracle FCCS: matching reports](https://docs.oracle.com/en/cloud/saas/financial-consolidation-cloud/usfcc/setting_up_intercompany_matching_reports.html)

### Required KPIs

Always compute exact measures by currency and cutoff:

- gross IC candidate exposure;
- posted-partner coverage by item count, gross amount, and absolute amount;
- uniquely derived-partner coverage;
- unresolved, ambiguous, and conflicting-partner exposure;
- matched gross amount, assigned residual, and unmatched gross amount;
- pair net OOB, with unmatched item/document counts shown beside it;
- zero-net-but-unassigned group count and gross amount;
- supported-unmatched versus unexplained exposure;
- profit-center allocated, unallocated, and allocation-residual amounts;
- GR/IR exceptions by lifecycle type, PO-item age, and materiality;
- source-load/control status and late-posting amount;
- open-case age, owner, due date, and close status.

Keep transaction-match tolerance, report-display materiality, and close/escalation threshold as three different configurations. Rows below presentation materiality remain in the base population.

The dashboard should keep inferred data visibly separated:

1. Posted-trading-partner OOB.
2. Approved auto-enriched OOB.
3. Missing-partner candidate exposure.
4. Ambiguous/conflicting-partner exposure.
5. Unmapped/unknown exposure.

Show each by source system, owner entity, account/display group, currency, evidence rule/version, and age. The total candidate population must reconcile across all five sections.

## 8. Databricks architecture for billions of rows

```text
SAP/legacy CDC or ordered snapshots
  -> immutable Bronze events and source control totals
  -> source-specific Silver current state plus SCD2 history
  -> canonical FI/open-item/billing/PO-history facts
  -> IC candidate scope and atomic partner evidence
  -> one-row partner resolution and bounded candidate graph
  -> match groups/members and profit-center allocations
  -> certified close snapshots and exact aggregate materializations
  -> metric views, secure drill-through views, trusted TVFs
  -> Genie
```

### Ingestion and state

- Use one adapter and native composite key per source table/instance.
- Retain the extraction watermark, source change sequence, operation, ingestion timestamp, and row hash.
- Use `AUTO CDC` for ordered change feeds and `AUTO CDC FROM SNAPSHOT` for legacy ordered snapshots; use a deterministic compound sequence when timestamps tie. Databricks documents that `AUTO CDC` handles out-of-order events and supports SCD1/SCD2. [Databricks: AUTO CDC](https://docs.databricks.com/aws/en/ldp/cdc)
- Use SCD2 for entity, master-partner, account-scope, profit-center, and legacy crosswalks when historical reporting depends on their former values.
- Treat Delta Change Data Feed as a processing feed, not the permanent audit ledger; retain a durable history when replayability is required.

### Incremental matching

For each run, derive impacted keys from changed items, mappings, FX rates, and allocation inputs. Recompute only affected:

- source items;
- entity/currency/reference candidate buckets;
- match groups and their reciprocal groups;
- profit-center allocations;
- pair summaries and close-delta comparisons.

If a materialized-view definition cannot incrementally refresh, use impacted-key recomputation into a persisted Delta result instead of accepting routine full scans. Databricks provides `EXPLAIN CREATE MATERIALIZED VIEW` to inspect incremental eligibility and `INCREMENTAL STRICT` to fail rather than unexpectedly perform a full recomputation. [Databricks: Incremental materialized views](https://docs.databricks.com/aws/en/ldp/incremental-refresh) [Databricks: EXPLAIN CREATE MATERIALIZED VIEW](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-qry-explain-materialized-view)

### Physical design

- Prefer Unity Catalog managed Delta tables.
- Start with automatic liquid clustering where supported and predictive optimization is enabled; validate the chosen keys against actual filters and joins. Databricks says liquid clustering adapts to changing access patterns and is incremental. [Databricks: Liquid clustering](https://docs.databricks.com/aws/en/delta/clustering)
- Avoid over-partitioning and do not combine partitioning/Z-order with liquid clustering.
- Use fixed-scale `DECIMAL` for finance amounts. Approximate aggregates and samples are profiling tools, never financial controls.
- Precompute common exact pair/cutoff/currency summaries and GR/IR exception summaries.
- Use a separate engineering surface for large trace investigations; do not let ad hoc semantic queries hit the candidate graph.

### Publication controls

Persist exact controls by source/company/currency at every boundary:

```text
source rows/amount
landed rows/amount
current-state rows/amount
candidate rows/amount
resolved/ambiguous/unresolved amount
allocated/unallocated amount
matched/unmatched amount
deleted/reversed count
duplicate-key count
mapping-orphan count
```

Use row-level expectations for valid records and separate validation/publication tasks for dataset-wide uniqueness and control-total equality. Databricks expectations can warn, drop, or fail records and expose quality metrics in the pipeline event log. [Databricks: Lakeflow expectations](https://docs.databricks.com/aws/en/ldp/expectations)

Minimum stop-publish gates:

- duplicate canonical source key > 0;
- source-to-current-state control difference outside approved source behavior;
- source-item allocation residual outside exact currency tolerance;
- duplicate certified pair/cutoff/currency grain > 0;
- conflicting high-tier partner resolution published as resolved;
- missing or overlapping FX mapping used in group amounts;
- stale/failed source watermark presented as complete;
- rule or mapping version missing from a result.

## 9. Certified Genie surface

Keep the Agent focused. A practical surface is:

1. `ic_reconciliation_metrics` — certified measures and dimensions.
2. `ic_exception_detail_secure` — bounded item-level drill-through.
3. `ic_match_trace_secure` — match groups/members and evidence trace.
4. `grir_exception_metrics` — PO-item lifecycle exceptions.
5. Trusted parameterized table functions for official balance, exception, and trace answers.

Do not expose raw BSEG/ACDOCA/VBRP/EKBE tables, mapping tables, multirow evidence, or candidate edges. Databricks recommends simplified, well-documented or prejoined datasets for Genie and prefers SQL expressions/example SQL over large text-instruction sets. [Databricks: Curate an effective Genie Agent](https://docs.databricks.com/aws/en/genie-agents/best-practices)

Metric views should define exact measures and separate document, local, and group currency. Their metadata can supply business names, formats, and synonyms to Genie. [Databricks: Metric-view modeling](https://docs.databricks.com/aws/en/uc-semantics/metric-views/basic-modeling) [Databricks: Agent metadata](https://docs.databricks.com/aws/en/uc-semantics/agent-metadata)

Never rely on declared join cardinality alone. Continuously test dimension uniqueness and referential coverage before allowing a join into a certified measure.

The companion `SAP_IC_Genie_playbook.md` contains a paste-ready instruction block, trusted-asset design, metrics, benchmarks, and unsafe-prompt tests.

## 10. Phased implementation

### Phase A — prove population and state

- Run the existing validation pack.
- Resolve CDC current state and native-key uniqueness for every source.
- Replace code-embedded account lists with an effective-dated account-scope table.
- Produce exact key-date AR/AP controls before enrichment.
- Quantify blank-partner exposure by source/company/account/currency.

### Phase B — partner evidence pilot

- Implement `ic_candidate_item`, `ic_partner_evidence`, and `ic_partner_resolution` for one high-volume entity pair.
- Backtest every fallback using hidden posted partners.
- Publish unresolved and ambiguous queues; do not optimize them away.
- Obtain Finance/Data Governance approval for automatic tiers.

### Phase C — legal-entity matching

- Persist exact and grouped match assignments.
- Reconcile every match member to source items and exact currency totals.
- Report zero-net-unassigned items.
- Add source-coverage and close-snapshot controls.

### Phase D — split profit-center allocation

- Build ECC/S/4 allocation adapters.
- Replace all dominant `MAX`/`ROW_NUMBER` shortcuts with conserved allocation rows.
- Validate owner and partner allocation independently.

### Phase E — useful GR/IR

- Build the PO-item/account-assignment event fact.
- Govern event and reversal mappings by source instance.
- Implement lifecycle exceptions first.
- Link GR/IR to AR/AP only through confirmed lineage and bounded allocation.

### Phase F — Genie

- Certify a small semantic surface and trusted functions.
- Add finance-critical SQL regression tests before Agent benchmarks.
- Promote only after generated SQL cannot reach forbidden raw/candidate objects and all exact controls pass.

## Final acceptance criteria

The design is ready for financial use only when the team can answer all of these with stored evidence:

- Which exact source lines and source watermark produced this reported amount?
- Which blank-partner items were included, how much exposure do they represent, and why was each partner resolved or not resolved?
- Can every selected partner and profit-center allocation be reproduced under the recorded mapping and rule versions?
- Do allocated amounts conserve each source amount in every currency basis?
- Which transaction members make up a zero pair balance, and which remain unassigned?
- Which GR/IR item directly links to which buyer/seller document chain, including reversals and quantities?
- Was the period closed against an immutable cutoff, and did later data make that close outdated?
- Did all exact source, allocation, currency, and publication controls pass?

Until then, the output is a diagnostic reconciliation model—not a certified financial balance.
