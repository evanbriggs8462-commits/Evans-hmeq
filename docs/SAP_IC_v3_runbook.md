# SAP intercompany reconciliation v3 runbook

## Bottom line

The v3 sandbox is a controlled replacement for the submitted monolith, not a cosmetic rewrite. It fixes the defects that can materially misstate intercompany exposure:

- AR/AP is filtered to a source/client/company/account scope. The shipped `*`
  company pilot is diagnostic and intentionally fails release until replaced.
- Every FI item is keyed by source system, SAP client, company code, fiscal year, accounting document, and line item.
- Blank trading partners remain in the population and enter an evidence workflow.
- Conflicting source copies, partner candidates, mappings, and FX rates fail closed.
- Legal-entity matching happens before profit-center/BU/OU allocation.
- Split allocations conserve every source-item amount; no dominant BU is selected.
- Matching occurs in transaction currency and requires reference evidence.
- Currency keys are normalized before grouping, matching, and FX lookup.
- Exact BSEG enrichment must agree on account, account type, sign, and both
  document/local amounts; offset splitting cannot bypass that test.
- BSID/BSIK open-index rows and BSAD/BSAK cleared-index rows must agree with
  their clearing fields; contradictions remain visible and cannot match.
- A zero pair balance is not called reconciled when its transactions are unassigned.
- GR/IR is a separate PO-item lifecycle sidecar and never alters official AR/AP OOB.
- GR/IR includes a diagnostic work queue, while invalid event values,
  incomplete assignment history, and non-additive FI slices remain explicit.
- GR/IR clearing exclusion now requires consistent `AUGDT/AUGBL/AUGGJ`, a
  uniquely resolved clearing `BKPF`, and clearing chronology on/after posting.
- GR/IR business routing is blocked while EKBEH and reversal lineage are absent;
  the queue exposes raw-presence hypotheses rather than accounting conclusions.
- Null or unknown control, membership, manifest, scope, and release statuses
  fail closed; blank match-group lineage and duplicate AR-to-GR/IR join paths
  cannot emit diagnostic dollars.

The SQL parses successfully as 125 Databricks statements (124 created objects), and the offline exact-decimal harness currently passes all 38 fixture and mutation checks. In a separate typed empty-schema run, all 124 views materialized in dependency order, the final query returned nine deliberately blocked products, and all 54 assertion statements bound and executed. The 54-statement live assertion pack still remains to be executed against the real Unity Catalog data. Product-level release gates intentionally block the current wildcard account pilot, unproven scope coverage, and all enterprise publication while source snapshots, global entity mappings, special-G/L classification, manual-G/L position semantics, governed reference-data versions, and materialized production stages are absent. Text labels in `ic_v3_params` cannot turn those production gates green; they require registry-backed evidence in a future implementation. This is meaningful implementation evidence, but it is not a substitute for a live catalog compile, source control-total tie-outs, or a Finance-reviewed shadow close.

## Files

- `SAP_IC_reconciliation_v3_sandbox.sql` — 125-statement, temporary-view-only ECC pilot.
- `SAP_IC_v3_live_assertions.sql` — live release assertions and SAP control-total extracts.
- `SAP_IC_v3_offline_harness.py` — local parser, exact-decimal fixtures, and mutation tests; no DBUs.
- `SAP_IC_v3_test_requirements.txt` — pinned local test dependencies.
- `SAP_IC_SQL_validation_pack.sql` — pre-existing discovery and source-profiling queries.
- `SAP_IC_SQL_review.md` and `SAP_IC_reconciliation_deep_design_v2.md` — detailed defect analysis and target design.

The original file in Downloads was not modified.

## Frozen offline bundle

The independently tested executable trio is pinned by SHA-256:

```text
SAP_IC_reconciliation_v3_sandbox.sql
DA6DFF35786160928AE7D41C7B27D811C2863883B423826A02B88E7139BE1B9C

SAP_IC_v3_live_assertions.sql
C5B1E6BF603A0768A4F6BF460C5CE463246F38D1DA5E3FD75D791AB2577C8051

SAP_IC_v3_offline_harness.py
A371B1F998E4301E84E224944F7063FC393291C4D0017B2FB0E76F963BD59725
```

For these exact bytes, the independent final audit parsed 125 SQL statements,
found 124 uniquely named views with no forward internal references or explicit
`UNION` arity mismatch, bound and stage-materialized every view against typed
empty source tables, executed the final nine-row product release query with all
products correctly `BLOCKED`, and bound/executed all 54 live assertions. The
offline harness passed 38/38 checks and a focused publication-boundary suite
passed 8/8 adversarial cases. This proves structural and tested semantic
behavior in the offline compatibility environment; it does not prove live
Databricks schemas, source contracts, data quality, performance, or accounting
tie-outs.

## What is authoritative

The controlled resolved-pair intercompany out-of-balance is:

```text
ic_v3_pair_currency_summary.arap_net_dc
```

Its grain is:

```text
run + as-of date + unordered legal-entity pair + transaction currency
```

It is publishable only when `ARAP_TRANSACTION_CURRENCY_SANDBOX` or the stricter requested enterprise product is eligible in `ic_v3_product_release_status`. Unresolved, ambiguous, conflicting, self-partner, invalid, and unmapped-owner items stay in `ic_v3_population_bridge` and block AR/AP certification; they are never silently removed from the denominator.

The following are separate products and must not be summed together:

| Product | Purpose | Can change AR/AP OOB? |
|---|---|---:|
| `ic_v3_pair_currency_summary` | Resolved-pair legal AR/AP result, conditional on release gates | Yes; this is the controlled result |
| `ic_v3_management_allocation_detail` | Conserved BU/OU reporting | No; it allocates the same item value |
| `ic_v3_partner_exception_summary` | Missing/ambiguous/conflicting partner exposure | No; it is an exception denominator |
| `ic_v3_diagnostic_partner_candidate_pair_summary` | Sole fallback-candidate OOB for missing posted partners | No; hypothesis surface only |
| `ic_v3_pair_reporting_summary` | Translated reporting view | No; blocked when FX is incomplete |
| `ic_v3_grir_po_item_lifecycle` | GR/IR operational exceptions | No |
| `ic_v3_grir_workqueue` | Aged GR/IR routing and recommended next checks | No; diagnostic workflow only |
| `ic_v3_arap_grir_link` | Diagnostic PO-reference overlap; supported amount is forced to null | No |

This separation follows SAP's own ICR framing: reconcile companies and their trading partners, assign records under configured rules, and reconcile in transaction currency to avoid creating conversion differences. SAP also supports collection across different SAP systems and clients. [SAP Intercompany Reconciliation](https://help.sap.com/docs/SAP_ERP/44ff4797667d4fd88d845044c010bb00/6b5a7c525ae17154e10000000a44176d.html), [SAP cross-system ICR](https://help.sap.com/docs/SAP_ERP/d99f293899c64e8aa5c5f57aa1bbf8f7/8376d7531a4d424de10000000a174cb4.html)

## Safe execution sequence

### 1. Run locally without DBUs

From the `outputs` directory, use a project-local Python environment:

```powershell
py -3.12 -m venv ..\work\ic_v3_venv
..\work\ic_v3_venv\Scripts\python.exe -m pip install -r SAP_IC_v3_test_requirements.txt
..\work\ic_v3_venv\Scripts\python.exe SAP_IC_v3_offline_harness.py
```

Expected result:

```text
38/38 checks passed
```

The local harness checks the logic without reading company data or consuming Databricks compute. It covers:

- cross-system and cross-client document-number collisions;
- cutoff boundaries and clearing-date sentinels;
- posted, derived, diagnostic-only, ambiguous, conflicting, self, and unresolved partners;
- 40/60 splits and deterministic decimal rounding;
- mapping fanout;
- exact 1:1, many-to-many, one-sided, cross-currency, and zero-net-unassigned matching;
- date-specific FX priority, overlap, and missing rates;
- GR-only, IR-only, both-with-residual, and missing-history GR/IR cases;
- bounded GR/IR support that cannot change official OOB;
- input-order invariance;
- mutations representing the submitted query's known failure modes.
- missing AP-feed detection and missing-release-gate detection;
- lifecycle-copy conflict detection before open-item filtering;
- GR/IR no-PO lineage blocking;
- rejection of offset splits when another subledger line shares the document.
- transaction-currency canonicalization (`USD` versus `usd `);
- exact BSEG account/type/amount/sign validation for both allocation paths;
- negative or malformed AR/AP, GR/IR FI, EKBE, and offset values;
- separation of valid suggested gross from invalid one-sided/nonreciprocal groups;
- non-additive EKBE measures across multiple FI account/currency slices;
- incomplete `EKBE-ZEKKN` assignment evidence without `EKBE_MA`;
- invalid GR/IR posting dates and empty GR/IR source populations;
- manual-G/L scope that cannot pass merely because recent movement is zero;
- expected-gate and product-scope manifest duplication;
- required parameter and account-scope semantic domains.
- BSID/BSIK versus BSAD/BSAK lifecycle contradictions;
- company-specific account scope and deliberate wildcard blocking;
- null debit/credit indicators on offset lines;
- zero-amount BSEG rows whose debit/credit indicator disagrees;
- nullable FX approval and self-attested production-readiness attempts;
- `AUGDT/AUGBL/AUGGJ` clearing-reference and BKPF chronology controls;
- EKBE-only archive gaps and reversal-blind business routing;
- one-to-many or non-GR-only AR-to-GR/IR overlap suppression;
- ANSI-safe `TRY_CAST` usage inside payload hashes.
- null debit/credit classification in both GR/IR FI and PO-history events.
- null or unknown lifecycle, FX, membership, routing, manifest, scope, and
  product statuses at publication boundaries;
- blank membership group IDs, physical AR-to-GR/IR pair duplication, and
  allocation fallback under SQL three-valued logic.

### 2. Profile the live source

Run the relevant statements in `SAP_IC_SQL_validation_pack.sql`. Do not proceed until these are answered:

1. For which explicit company codes and charts is `0010250000` a governed AR
   account? Replace the shipped `*`; the same account number is not assumed to
   have the same semantics across companies/charts.
2. Are the AP and GR/IR scopes correct by client/company/chart and effective date?
3. Are current-state CDC rows unique for the assumed native keys, and does the
   replication contract explicitly define null/blank `hdr__oper` as active?
4. Does every company code have one `T001-RCOMP` value?
5. Are profit-center-to-OU and OU-to-BU maps unique at the close date?
6. What percentage and gross value have blank `VBUND`?
7. Which `VGABE/BEWTP/BWART/SHKZG` tuples occur in EKBE?
8. Does the FX table represent a direct multiplier, and how are SAP factors and inverse quotation handled?
9. Are `BSEG-AUGDT/AUGBL/AUGGJ` present and do clearing references resolve to
   one nondeleted `BKPF` with a consistent date?
10. Does the UC source include both EKBE and EKBEH, or the released PO History
    API that combines current and historic values?

### 3. Edit controlled parameters

At the top of `SAP_IC_reconciliation_v3_sandbox.sql`, change:

- `as_of_date` and `cutoff_exclusive`;
- unique `reconciliation_run_id`;
- SAP client and source-system ID;
- account scope;
- reporting currency;
- rule and mapping versions.

The only executable switch is the FX multiplier contract, and it remains false until Finance validates quotation and factor semantics:

```text
fx_multiplier_contract_approved = false
```

Current-master and same-document partner fallbacks are hard-coded diagnostic-only; there is no Boolean that can promote them. GR/IR automation is also hard-disabled. It requires implemented, versioned contracts rather than an approval flag. Leave these control values unchanged in the sandbox:

```text
source_contract_certification_id = NOT_CERTIFIED
execution_mode = TEMP_VIEW_SANDBOX
grir_event_rule_version = NOT_IMPLEMENTED
grir_value_basis_version = NOT_IMPLEMENTED
grir_reversal_rule_version = NOT_IMPLEMENTED
buyer_ap_completeness_contract = NOT_IMPLEMENTED
cross_system_lineage_version = NOT_IMPLEMENTED
```

Changing a label is not evidence. The production implementation must derive each gate from versioned rule tables, source watermarks, schema certification, and row-level controls.

The supplied account-scope rows use `company_code='*'` only to make discovery
possible. `ACCOUNT_SCOPE_COMPANY_EXPLICIT` therefore fails by design. Replace
each wildcard with approved company-code rows before interpreting even the AR/AP
sandbox output as publishable.

### 4. Compile before scanning the full population

Use a development SQL warehouse and a narrow company/account/as-of pilot. Run `EXPLAIN FORMATTED` on the key terminal views before the first full action:

```sql
EXPLAIN FORMATTED
SELECT * FROM ic_v3_pair_currency_summary;

EXPLAIN FORMATTED
SELECT * FROM ic_v3_grir_po_item_lifecycle;
```

Check for full scans caused by an unapplied account/client predicate, large Cartesian products, and repeated exchange stages. The sandbox uses temporary logical views for safety. At enterprise scale, do not repeatedly execute the entire logical graph from several BI queries.

### 5. Run live assertions

In the same session, run `SAP_IC_v3_live_assertions.sql`.

- Every violation query must return zero rows.
- Expected-exception queries quantify exposure and do not silently remove it.
- Extract 18 is the AR/AP control total to reconcile to SAP by client, company, account, side, and document currency.
- Extract 19 is the independent FI GR/IR control total.
- Read both `ic_v3_release_status` and `ic_v3_product_release_status`. A valid component does not imply a valid enterprise product.

The product status view distinguishes these release surfaces:

| Product status | Intended use |
|---|---|
| `ARAP_TRANSACTION_CURRENCY_SANDBOX` | One controlled source-local subledger pilot, transaction currency only |
| `ARAP_ENTERPRISE_PRODUCTION` | Global publishable IC result; also requires manual-G/L position semantics |
| `MANAGEMENT_OWNER_SPLIT_DC_SANDBOX` | Owner-side management split in document currency |
| `MANAGEMENT_COUNTERPART_SPLIT_DC_SANDBOX` | Counterpart OU/BU, intentionally blocked until a transaction rule is certified |
| `MANAGEMENT_SPLIT_LC_ENTERPRISE` | Management split with labeled local currency and production controls |
| `REPORTING_CURRENCY_ENTERPRISE` | Translated enterprise result with certified FX |
| `GRIR_FI_DIAGNOSTIC_SANDBOX` | Exact open FI GR/IR population and exceptions |
| `GRIR_PO_LIFECYCLE_DIAGNOSTIC_SANDBOX` | Raw PO-history presence diagnostic; currently blocked by EKBEH/reversal gates |
| `GRIR_AUTOMATION` | Intentionally blocked until the full contract is implemented |

`MANUAL_GL` is a separate required scope for enterprise products. It is hard-blocked while the configured manual IC accounts have no governed open-item or balance-from-inception fact. An empty recent-movement query is not evidence of a zero position.

### 6. Shadow close

For at least two closes, compare:

1. SAP key-date open-item totals to `ic_v3_item_fact`.
2. Current published report totals to v3, explaining every delta by defect category.
3. A stratified item sample covering each system, client, entity pair, account, currency, partner status, allocation method, and match status.
4. Every high-value unresolved, ambiguous, conflict, duplicate, and missing-FX bucket.
5. GR/IR FI totals to SAP independently of PO-history event totals.

Finance should approve the rule version, account scope, entity crosswalk, FX contract, and sample evidence before production publication.

## Why this matches how large SAP organizations reconcile

Complex groups do not rely on one giant pair-net query. SAP's own ICR process separates data selection, rule-based assignment, reconciliation, communication, and correction. It supports different systems and clients and operates at company/trading-partner level. That is the same staged shape used here: immutable candidates, evidence, resolution, assignment groups, exceptions, and reporting. [SAP ICR process](https://help.sap.com/docs/SAP_ERP/44ff4797667d4fd88d845044c010bb00/6b5a7c525ae17154e10000000a44176d.html)

Public programs with comparable complexity use the same pattern:

- UPL/Deloitte describes 240+ entities, 650+ profit centers, six S/4HANA systems, and more than 50 tailored ICMR rules, with over 85% automated matching. That is strong evidence that a rule portfolio plus exceptions—not one universal join—is normal at this scale. [Deloitte UPL case study](https://www.deloitte.com/in/en/services/consulting/case-studies/win-story-in-focus-upl-limited.html)
- Lexmark replaced an 18-step spreadsheet process with ICMR workflows and document/allocation visibility. [SAP Lexmark case study](https://www.sap.com/asset/dynamic/2024/01/f85ed165-a27e-0010-bca6-c68f7e60039b.html)
- A KPMG global-IT case describes 65+ source-to-system reconciliations across AR, AP, P&L, and balance sheet, with explicit missing-document, timing, system-failure, financial-impact, severity, and root-cause categories. [KPMG reconciliation case study](https://kpmg.com/in/en/services/advisory/consulting/business-consulting/finance-transformation/streamlined-system-to-system-reconciliation-to-ensure-accurate-and-consistent-financial-data-for-a-global-leader-in-the-it-sector.html)
- Microsoft's intercompany transformation emphasized a common data source and a Finance/Tax/IT operating model, reinforcing that governance and ownership are part of the solution. [PwC Microsoft case study](https://www.pwc.com/us/en/library/case-studies/microsoft-transfer-pricing-approach.html)

For S/4HANA, SAP provides ICMR data sources based on CDS views and allows custom CDS extensions for required fields or performance logic. SAP specifically lists BSEG/BKPF-based entry-view sources for AR/AP use cases and advises choosing the organizational dimension and corresponding leading/partner fields deliberately. [SAP ICMR data-source considerations](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/651d8af3ea974ad1a4d74449122c620e/c9027ed077454271a7dd6d1b7b4b542b.html), [SAP: extend an ICMR data source](https://help.sap.com/docs/PRODUCT_ID/0fa84c9d9c634132b7c4abb9ffdd8f06/f82322d2f16f4ba89d4d78fedd98caff.html)

The implication is important: ECC, S/4HANA, and legacy data should not be joined raw to each other. Each instance needs an adapter into one canonical contract, followed by a global entity crosswalk.

SAP Central Finance likewise uses source-aware key/value mapping because local identifiers vary; source logical systems must be unique, and mapping changes can affect follow-on consistency. This supports the production gate that rejects raw `VBUND`/`RCOMP` as globally canonical IDs. [SAP Central Finance mapping](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/26c2d5e366bc44c1a98f2a9212a0c49d/11a8355871504442e10000000a4450e5.html)

## Cross-instance adapter contract

| Concern | ECC adapter | S/4HANA adapter | Non-SAP/legacy adapter |
|---|---|---|---|
| Native identity | source system + `MANDT/BUKRS/GJAHR/BELNR/BUZEI` | source/logical system + client + ledger + company + fiscal year + document + universal-journal line (`DOCLN`); confirm released fields | immutable source + ledger + legal entity + fiscal period/year + document + line; collision quarantine if no true line ID |
| AR/AP position | `BSID/BSAD` and `BSIK/BSAK` key-date snapshot, tied to `BSEG/BKPF`; validate open/cleared index semantics | released ICMR CDS view or governed ACDOCA/BKPF adapter; do not assume ECC index-table behavior | governed open-item flag plus clearing history or balance-from-inception rule |
| Owner legal entity | `BUKRS -> T001-RCOMP` | company/company-code mapping exposed by the source | effective-dated local-entity-to-global-entity crosswalk |
| Posted partner | `VBUND` | `RASSC`/released partner-unit field | explicit affiliate/trading-partner field |
| Organization | `BSEG-PRCTR`; partner org requires exact evidence | `PRCTR` and, where populated and governed, `PPRCTR` | source cost/profit center through effective-dated org crosswalk |
| Currency | `WAERS/WRBTR` plus governed local/reporting bases | explicit currency type + currency + amount from released source | explicit basis, currency, amount, scale, and sign convention |
| References | namespaced `BVORG`, `ZUONR`, clearing and governed document-flow keys | released reference/source-document fields, namespaced by system | typed reference namespace; never compare naked text across systems |
| Watermark | extractor sequence and immutable source snapshot | source extraction timestamp/sequence and ledger scope | batch/file ID and immutable ingestion timestamp |

### Optional Unity Catalog sources to look for

The top of `SAP_IC_reconciliation_v3_sandbox.sql` contains a commented discovery catalog and zero-row `information_schema` probes. None of these optional objects is a runnable dependency.

| Priority | Object(s) and useful columns | Best use | Guardrail |
|---|---|---|---|
| P0 | S/4 `ACDOCA` or `I_GLAccountLineItemRawData`: ledger, `RBUKRS/GJAHR/BELNR/DOCLN`, `RACCT`, `RASSC`, `PRCTR/PPRCTR`, currency types/amounts | Native S/4 legal and split dimensions | Build an S/4 adapter; never union ACDOCA and BSEG as if they shared one grain. [SAP raw journal extraction](https://help.sap.com/docs/SAP_S4HANA_CLOUD/c0c54048d35849128be8e872df5bea6d/7fe239a3f2214e2cb36e90d453eee6d3.html) |
| P0 | ECC New GL `FAGL_SPLINFO/FAGL_SPLINFO_VAL`; `FAGLFLEXA`; classic `GLPCA` | Native document-split or profit-center allocation | Reconcile by ledger/currency back to FI before replacing the offset fallback. [SAP subsequent document splitting](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/3cb1182b4a184bdd93f8d62e3f1f0741/8965bf6eb7b142e1b089f3e7394c0258.html) |
| P0 | `BSIS/BSAS`, plus `SKA1/SKB1` fields such as `MITKZ`, `XOPVW`, and ledger-group clearing settings | Manual-IC and GR/IR as-of G/L positions; governed account registry | Confirm open-item-management semantics and extraction history first. In some S/4 extended-OIM scenarios, clearing information is retained in ACDOCA rather than BSEG. [SAP extended open item management](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/651d8af3ea974ad1a4d74449122c620e/e03dc67ea7354354bf5d2b23cf575a8c.html) |
| P0 | `T000/T001/T880`; `KNA1/LFA1`; S/4 `CVI_CUST_LINK/CVI_VEND_LINK/BUT000` | Source/client namespace and local-to-canonical entity candidates | Current master values remain diagnostic until effective-dated and globally cross-walked. |
| P0 | `EKBE/EKBEH`, `EKBE_MA`, `EKKN`; keys `EBELN/EBELP/ZEKKN/VGABE/BEWTP/GJAHR/BELNR/BUZEI`, reference tuple, quantities, `AREWR/AREWB/AREWW` | PO event ledger and assignment-level GR/IR values | Maintain many-to-many events; do not infer one GR to one IR. [SAP purchase-order history](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/af9ef57f504840d2b81be8667206d485/1d6f6bea1c3b4f049742e15a81ff86a0.html), [SAP assignment-level history](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/af9ef57f504840d2b81be8667206d485/a1cfb17cbdfa48418b665ae94c15dc79.html) |
| P0 | ECC `MKPF/MSEG` or S/4 `MATDOC/I_MaterialDocumentItem_2` | Exact goods-receipt and reversal lineage | Select the native model for the instance; never union MATDOC with MSEG compatibility output. [SAP material document item](https://help.sap.com/docs/SAP_S4HANA_CLOUD/c0c54048d35849128be8e872df5bea6d/14305f6e8cb842bbb1647ffd5a30ca31.html) |
| P0 | `RBKP/RSEG/RBCO`: invoice/year/item, PO/item/assignment, `LFBNR/LFGJA/LFPOS`, status and reversal | Posted invoice-receipt and exact material-document provenance | PO/item alone is not a unique GR-to-IR link; respect parked/blocked/reversed status. [SAP invoice-to-material reference](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/af9ef57f504840d2b81be8667206d485/306fb6531de6b64ce10000000a174cb4.html) |
| P1 | `ICADOCM` | Existing S/4 ICMR assignments, reasons, workflow, and rule results | Potential confirmed evidence only with pinned method/rule/cutoff and complete roll-in. [SAP ICMR matching documents](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/651d8af3ea974ad1a4d74449122c620e/d6e1f222780744268eb4cbcb836f6b92.html) |
| P1 | `VBRK/VBRP/VBFA`; `BKPF-AWTYP/AWKEY/AWSYS` | Billing, cancellation, and typed origin/document-flow lineage | Parse by reference type and retain source namespace; bare document numbers and free text are not keys. |
| P1 | `TCURR/TCURF/TCURN/TCURX` | Complete rate, factors, quotation direction, and decimal shifts | `TCURR` by itself is not a certified multiplier. |

These objects stay comments/adapters until metadata proves they exist. The one
new executable ECC field dependency is standard `BSEG-AUGGJ`, used with the
already-used `AUGDT/AUGBL` and `BKPF` to prevent a plausible-looking clearing
date from silently dropping a GR/IR line. If your replicated BSEG omits AUGGJ,
the compile should fail; ask Genie only for that column-contract fact, then add a
governed source adapter rather than weakening the clearing control.

Start by checking existence and column metadata. Only profile values for the few objects that can close a named control gap; this is where a small Genie query is worth the DBUs.

SAP identifies `RASSC` as the trading-partner company and distinguishes it from `PRCTR` and partner profit center `PPRCTR`; these are separate dimensions, not interchangeable BU codes. [SAP field definitions](https://help.sap.com/docs/SAP_BUSINESSOBJECTS_FINANCIAL_INFORMATION_MANAGEMENT/42177c639aea4f559027e8a25064bf3b/f9ce23a86faf1014878bae8cb0e91070.html), [SAP consolidation dimensions](https://help.sap.com/doc/302807b412ad4219802dae8338811e3d/1709%20002/en-US/e0f3ad5789cfca02e10000000a4450e5.pdf)

### Canonical item contract

Every adapter should emit at least:

```text
source_system_id
source_client
source_family
native_item_id fields
owner_local_entity_id
global_owner_entity_id + mapping version/status
posted_partner_raw
document currency + signed DECIMAL amount
local currency + signed DECIMAL amount
posting date
clearing date/status
account + match side
reference namespace/value rows
allocation signal rows
source extraction watermark
```

Do not create a synthetic key from too few columns. If a legacy source lacks a stable line key, generate a candidate hash from immutable fields, calculate collisions, and quarantine collisions rather than appending an arbitrary row number.

## Trading-partner fallback policy

Missing `VBUND` is a control population, not a filter condition. The v3 evidence table preserves every candidate and source.

SAP documents both normal trading-partner derivation from affiliated customer/vendor masters and configuration paths where inheritance is not available on every line. SAP's delivered group-reconciliation content also includes a missing-trading-partner rule category. Blank partner values are therefore an expected exception class, not evidence that a posting is non-intercompany. [SAP trading-partner derivation](https://help.sap.com/docs/SAP_ERP/daf0f4e552e248d0bf0db2bb5f322192/8cbed153e8b34208e10000000a174cb4.html), [SAP delivered matching content](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/4ebf1502064b406c964b0911adfb3f01/4bd4e6f16fde424cac273a8ffd4ce3e6.html)

Recommended promotion order:

1. Exact posted trading partner.
2. Approved cross-company reference with exactly one reciprocal counterparty.
3. Approved historical party master at the posting date.
4. Approved same-document rule after backtesting.
5. SD/MM/EDI/document-flow adapter with exact source-scoped lineage.
6. Current KNA1/LFA1 only as diagnostic evidence until history is reconstructed.

Status meanings:

| Status | Meaning | Automatic matching? |
|---|---|---:|
| `POSTED` | One posted candidate and no contradictory evidence | Yes |
| `DERIVED_UNIQUE` | One approved automatic candidate and no contradiction | Yes |
| `DERIVED_UNIQUE_DIAGNOSTIC` | One candidate from an unapproved/current source | No |
| `AMBIGUOUS` | More than one viable candidate | No |
| `CONFLICT` | Posted/authoritative evidence disagrees | No |
| `CONFLICT_SELF` | Candidate resolves to the owner | No |
| `UNRESOLVED` | No evidence | No |

Do not turn a candidate into a resolution with `MAX`, `MIN`, `FIRST`, `ANY_VALUE`, or `ROW_NUMBER()=1`. Aggregate functions are acceptable only after a distinct-candidate count proves uniqueness.

`BKPF-BVORG` is kept source-scoped and diagnostic-only. SAP defines it as the cross-company transaction number linking the separate company-code documents created by one cross-company posting; one transaction may involve more than two company documents. It is not a universal cross-system invoice ID. [SAP cross-company transaction behavior](https://help.sap.com/docs/SAP_ERP/34e83d3c59844048bb8289f00ce23ddd/b7a4bb53707db44ce10000000a174cb4.html)

## Split billing and BU/OU rules

The v3 pilot accepts only two allocation methods:

1. Profit center on the exact FI item.
2. Opposite-sign G/L offsets in a document containing exactly one scoped IC item, when the offsets exactly balance the item and every nonzero offset has a profit center.

Otherwise it emits one full-value `UNALLOCATED_*` row. This is preferable to selecting the most common BU: a report can show an unallocated bucket, while it cannot recover dollars silently assigned to the wrong organization.

This reflects SAP document-splitting behavior: one AR/AP item can be represented by several G/L lines carrying different account assignments. The code therefore requires the target to be the sole subledger line, validates exact document- and local-currency balance, and retains every accepted profit-center component. [SAP document splitting](https://help.sap.com/docs/SAP_S4HANA_CLOUD/0fa84c9d9c634132b7c4abb9ffdd8f06/4911c9cc2a934a18e10000000a42189b.html)

The submitted FI-to-billing join (`FI BELNR = VBRP-VBELN`) is not used. A future billing adapter must traverse the accounting-origin/document-flow fields proven in that instance, preserve billing item grain, and supply a real monetary or quantity basis. Billing-line count is not an allocation basis.

Partner BU/OU is filled only from a confirmed 1:1 counterparty whose allocation resolves to one organization. A split counterpart remains `COUNTERPART_SPLIT_OR_MAPPING_AMBIGUOUS`; the code never cross-multiplies the two sides' allocation rows.

## GR/IR: what is useful now and what is not yet certified

SAP treats GR/IR reconciliation as a purchase-order-item exception process that combines FI open items, purchasing history, quantities, amounts, status, and root cause. [SAP Reconcile GR/IR Accounts](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/651d8af3ea974ad1a4d74449122c620e/17f3a45189524e78b4a80bf51ff2b741.html), [SAP GR/IR automated processing](https://help.sap.com/docs/SAP_S4HANA_CLOUD/651d8af3ea974ad1a4d74449122c620e/972d2c0f719f4067b2d53b4dc1fa6576.html)

The v3 sidecar therefore keeps three grains separate:

| Object | Grain |
|---|---|
| `ic_v3_grir_fi_open_line` | exact FI line at cutoff |
| `ic_v3_grir_po_history_event` | exact PO-history event and account assignment |
| `ic_v3_grir_po_event_summary` | canonical additive PO-item event summary |
| `ic_v3_grir_po_item_lifecycle` | PO item + GR/IR account + document currency; account-assignment history remains diagnostic |
| `ic_v3_grir_workqueue` | lifecycle slice with age, review queue, and next-check hypothesis |

It produces useful diagnostic categories now:

- PO history missing;
- GR event seen, IR not seen;
- IR event seen, GR not seen;
- both event families with an open FI residual;
- other/unmapped event;
- missing PO/item lineage;
- multiple account assignments;
- partner unresolved/ambiguous/conflicting.

The current event reader uses EKBE only. SAP's released PO History API combines
EKBE with historic EKBEH values, so `history_basis_status` remains
`EKBE_ONLY_EKBEH_NOT_INGESTED`, and the lifecycle release is blocked. A GR that
moved to EKBEH while an IR remains in EKBE would otherwise look like IR-only.
Similarly, reversal lineage is incomplete, so the workqueue routes first to SAP
history/reversal stewardship. Supplier-invoice and receipt teams are not sent a
business action from raw presence alone.

EKBE measures are PO-item facts. If one PO item has several FI
`GR/IR account + document currency` slices, those event measures repeat on the
lifecycle rows and must not be summed there. The
`event_measure_additivity_status` column and release warning expose this;
aggregate `ic_v3_grir_po_event_summary` for event totals.

Likewise, `EKBE-ZEKKN` alone cannot prove complete assignment lineage. Even a
single observed assignment remains warning-only until `EKBE_MA`/`EKKN` (or a
released equivalent) is ingested and reconciled. Invalid/negative EKBE values,
quantities, or debit/credit codes are quarantined before any diagnostic sum.

It does **not** claim exact GR/IR value reconciliation yet. `EKBE-WRBTR/DMBTR` are history amounts and may not be the exact clearing value. SAP's own material identifies `EKBE-AREWR` as the GR/IR clearing value in relevant invoice-verification logic. [SAP valuation in invoice verification](https://help.sap.com/docs/SUPPORT_CONTENT/spmm/3362167904.html)

Multiple-account-assignment and delivery-cost cases need their own adapters. SAP exposes assignment-level GR/IR values through `EKBE_MA` (including `AREWR`, `AREWB`, and `AREWW`), and delivery-cost history uses separate structures. Until those populations are explicitly covered, the PO-history layer is a presence/root-cause diagnostic, not a monetary clearing engine. [SAP multiple-account-assignment field model](https://help.sap.com/docs/SAP_S4HANA_ON-PREMISE/af9ef57f504840d2b81be8667206d485/a1cfb17cbdfa48418b665ae94c15dc79.html)

Before any row may become automation-eligible, ingest and govern:

- `BKPF-STJAH` with `STBLG` for FI reversal lineage;
- `EKBE-LFGJA/LFBNR/LFPOS` or equivalent PO-history reference/reversal lineage;
- `EKBE-AREWR/AREWB/AREWW` for exact GR/IR value bases;
- `EKBE_MA` or equivalent assignment-level values for multiple account assignment;
- quantity unit and price-unit fields;
- an approved instance-specific `VGABE/BEWTP/BWART/SHKZG` rule table;
- company local currency;
- source-scoped buyer PO/item lineage on the unmatched seller AR side.

Until then, `ic_v3_arap_grir_link` remains diagnostic, `automation_eligibility_status` is hard-blocked, and `supported_amount_dc` is always null. `diagnostic_bounded_overlap_dc` is populated only for a one-to-one candidate with a debit seller AR, a credit buyer GR/IR residual, and a GR-seen/IR-not-seen raw-presence status. Ambiguous, IR-only, both-event, wrong-sign, and clearing-control cases remain null. Even the populated amount is labeled pairwise and noncausal; it is not evidence that buyer AP is absent. The sidecar never posts, nets, or changes OOB.

## Scaling from sandbox to billions of rows

Temporary views are appropriate for a narrow, read-only proof because they leave no data behind. They are not the final physical design. At production scale:

1. Materialize immutable Delta checkpoints by `reconciliation_run_id` and cutoff.
2. Filter client/account/date at the source scan before wide joins.
3. Build one source adapter per SAP instance; do not repeatedly scan raw BSEG/ACDOCA from BI.
4. Partition large snapshot facts by close date and source system; consider clustering on client/company/account and high-use item keys after measuring query profiles.
5. Persist narrow document, partner-evidence, allocation, and match-member tables instead of one denormalized fanout-prone table.
6. Collect table statistics and inspect actual query profiles before choosing broadcast hints.
7. Make Power BI read only certified marts, never raw joins or pair totals repeated on detail rows.
8. Store input watermarks, account/rule/map/FX versions, row counts, signed totals, gross totals, and lineage hashes with each run.

The first production materialization should be created in a development catalog under your normal change process. This deliverable intentionally does not guess that catalog name or write company data.

## How to divide work between Codex and Genie

Use the local harness and Codex for high-token, data-free work:

- SQL architecture and review;
- source contracts and invariants;
- synthetic edge cases and mutation tests;
- documentation and release gates;
- analysis of exported schemas, query plans, and aggregated validation results.

Use Genie for the narrow work that requires Unity Catalog metadata or live distributions:

- `DESCRIBE TABLE` and column confirmation;
- small aggregate profiles by source/client/account;
- query-plan and runtime evidence;
- instance-specific code/value discovery;
- controlled tie-outs against certified SAP reports.

Do not ask Genie to rewrite the whole query from prose. Give it one bounded question, require row counts and control totals before/after, and bring the result back through the offline tests and release gates. Its catalog access can discover granular facts that local reasoning cannot, while the versioned SQL and tests prevent those discoveries from silently becoming financial rules.

### Low-token / low-DBU escalation ladder

Use the cheapest layer that can answer the question:

1. **Codex only:** architecture, line-by-line review, SAP documentation checks, source contracts, SQL generation, AST/binder checks, exact-decimal fixtures, mutation tests, and interpretation of exported results. This consumes no company Databricks compute and does not require company data.
2. **Genie metadata probe:** confirm table/column types, partition columns, row-estimate metadata, and instance-specific field availability. Return only the requested rows and the exact SQL Genie ran.
3. **Narrow aggregate probe:** one client, one company, one account, a short posting range, and only counts/signed/gross totals. Use this to measure duplicates, blank partners, event-code domains, and join cardinality.
4. **Exception sample:** retrieve a small deterministic sample of keys from a quantified exception bucket. Never begin with a wide `SELECT *` or the whole reconciliation graph.
5. **Plan-only check:** run `EXPLAIN FORMATTED` after predicates and staged materialization are designed. Look for repeated BSEG/ACDOCA scans and many-to-many exchanges.
6. **Full pilot action:** only after the schema, cardinality, conservation, and plan probes pass. Materialize the narrow run-scoped source stage once, then reuse it.

For every paid/live probe, require this evidence packet:

```text
question being answered
exact SQL and source object versions
source snapshot/watermark
row count and distinct native-key count
signed and gross amount controls at a valid currency grain
before/after counts for every join
exception counts and gross exposure
query-plan/runtime metrics
small deterministic examples only when needed
```

The practical division is: let Genie discover facts that depend on the live catalog; let Codex decide whether those facts satisfy a predeclared invariant. If Genie proposes a field or join, treat it as a hypothesis until a cardinality query and amount-conservation query pass. That preserves Genie's useful granularity without paying it to repeatedly reason over the full program or trusting fluent SQL as proof.

## Production stop conditions

Do not publish if any of these is true:

- a native key has more than one financial payload;
- an account rule overlaps another rule;
- an AR/AP account rule still uses wildcard company scope;
- an open/cleared index row contradicts its clearing fields;
- a required header or owner entity is missing;
- allocation does not conserve both document and local amount exactly;
- a match-eligible item has zero or multiple selected memberships;
- a membership status, rule, or group ID is null, blank, unknown, or inconsistent;
- a suggested transaction group is presented as confirmed before its rule is governed and backtested;
- a reporting-currency total contains missing, ambiguous, invalid, or unapproved FX;
- unresolved/conflicting partner exposure is omitted from the control report;
- GR/IR is present in the AR/AP OOB formula;
- a GR/IR event is unmapped or duplicated but still receives an automatic explanation;
- a GR/IR line is excluded as cleared without resolved `AUGDT/AUGBL/AUGGJ`
  and clearing-header chronology;
- EKBEH or reversal lineage is absent but raw presence is routed as a business conclusion;
- SAP source totals do not tie exactly at the governed grain;
- a required product is blocked in `ic_v3_product_release_status`, even if one component scope is green.
- a failed row has an unknown monetary amount: the row-count gate is valid, but
  `violating_gross_dc` cannot quantify dollars that the source did not provide.

Passing those controls is the standard for trusting the result—not whether a long SQL statement happens to execute or produce a plausible total.
