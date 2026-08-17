# Agent Reinforcement: ECC Intercompany Reconciliation V7

Date: 2026-08-17

Purpose: make the latest SAP/ECC intercompany reconciliation findings easy for the local agent to discover from the repository root on `main`.

## Core design principle

Do not grow the current solution into a larger all-to-all matching query. Build an auditable SAP document-evidence graph that answers three separate questions:

1. Is this item intercompany, and which legal entity is the partner?
2. Which reciprocal posting or transaction group does it belong to?
3. Does that group financially reconcile?

Keep partner identity, transaction identity, and financial reconciliation separate.

---

## Immediate correctness fixes from the visible SQL

### 1. Remove the historical cutoff defect

The current logic uses a `min_gjahr` restriction. Remove it from the accounting population.

A prior-year item can still be open at the reporting key date. `GJAHR` is fiscal year and may not align to calendar year.

Correct key-date logic:

```sql
BUDAT < cutoff_exclusive
AND (
  AUGDT is initial/null/blank/00000000
  OR AUGDT >= cutoff_exclusive
)
```

If a historical restriction is needed for performance, derive it from a governed retained-history policy and surface it as a limitation.

### 2. Rename and strengthen run parameters

Use:

```text
as_of_date
cutoff_exclusive
source_state_as_of_ts
reconstruction_mode
run_id
code_version
git_commit_sha
executed_at
```

`cutoff_exclusive` is the first day after the reporting period.

`source_state_as_of_ts` is separate from the accounting key date and determines which physical source state is used for reconstruction.

Recommended modes:

```text
CURRENT_RESTATED
ORIGINAL_CLOSE
```

### 3. Current source state is not always historical truth

SAP clearing reset behavior can remove `AUGBL` / `AUGDT`. A current BSEG row can therefore misrepresent whether an item was cleared at an earlier close.

For reproducible historical closes, use retained CDC/history or certified monthly snapshots.

Likewise, current KNA1/LFA1 VBUND values are not automatically valid for old postings. A master assignment can change over time. Use posting-time history, CDHDR/CDPOS, certified snapshots, or label the fallback:

```text
CURRENT_MASTER_ASSUMPTION
```

and keep it below posted/document/process evidence.

### 4. Do not independently COALESCE partner VBUND and partner BUKRS

The visible logic can create an internally inconsistent hybrid assignment when the strongest VBUND evidence has no unique BUKRS but a lower-priority evidence source does.

Bad pattern:

```sql
assigned_ic_partner = COALESCE(line_vbund, vendor_master_vbund, customer_master_vbund)
partner_bukrs       = COALESCE(line_vbund_bukrs, vendor_master_bukrs, customer_master_bukrs)
```

Instead, create one row per item/evidence/candidate and select a single evidence row atomically.

Required atomic fields:

```text
candidate_vbund
candidate_bukrs
assignment_rule
evidence_priority
temporal_basis
confidence
source_document_keys
```

If posted VBUND is known but maps to multiple BUKRS values, preserve:

```text
assigned_vbund = known
partner_bukrs = NULL
partner_status = ENTITY_AMBIGUOUS
```

Do not fall through to a different VBUND's unique BUKRS.

### 5. The current coverage denominator is biased

The visible `matchable` population requires resolved partner assignment before reporting. This removes the hardest rows from the denominator.

Build an `ic_candidate_universe` first and keep unresolved suspected IC rows in scope.

Suggested classes:

```text
CONFIRMED_IC
PROBABLE_IC
POSSIBLE_IC
NON_IC
```

Preserve `ic_scope_reason`.

Report separately:

```text
partner_company_coverage
exact_entity_coverage
transaction_linkage_coverage
balanced_linkage_coverage
```

### 6. The visible match-rate formula can exceed 100%

The current design creates one canonical pair statistic but joins it back to directional entity rows and computes:

```sql
s.pairs * 2.0 / p.items * 100
```

For one matched item on each side, each side can report 200%.

Replace pair-count coverage with member-based coverage:

```text
unique accepted match_member.item_key count / total in-scope item count
```

For directional views, compute matched counts and gross values from the actual members on that entity side.

### 7. Matched gross is also directionally wrong

The visible query calculates matched amount from side A only, where A is forced by lexical BUKRS ordering. That amount is then joined to both directional rows.

This can produce negative `unmatched_dc` on one side.

Create explicit `match_member` rows for both sides and aggregate each side from its own items.

### 8. Dual ROW_NUMBER is a mutual-best heuristic, not true greedy matching

The current logic keeps only rows where both sides rank each other first:

```sql
ra = 1 AND rb = 1
```

This is not globally optimal and can leave valid alternative matches unused.

It is also nondeterministic when priority, amount residual, and date distance tie.

At minimum add a stable final tie-break key and rename the result:

```text
MUTUAL_BEST_1_TO_1_SUGGESTION
```

Better approach:

1. Accept deterministic lineage groups first.
2. Consume their members.
3. Accept exact-reference groups where unambiguous.
4. Run weaker candidate logic only on unconsumed items.
5. Route ambiguous components to review instead of forcing a match.

### 9. Blank SAP character fields require NULLIF before COALESCE

Bad pattern:

```sql
COALESCE(TRIM(kunrg), TRIM(kunag))
```

If `KUNRG` is blank spaces, `TRIM` becomes `''`, which is not NULL.

Use:

```sql
COALESCE(NULLIF(TRIM(kunrg), ''), NULLIF(TRIM(kunag), ''))
```

Better: preserve customer roles separately instead of collapsing payer and sold-to.

### 10. P2 reference predicates are asymmetric

The visible P2 logic tests nonblank status on only one side before checking both directions. Matching success can therefore depend on which BUKRS sorts lower.

Use symmetric predicates for XBLNR, ZUONR, XREF1, XREF2, etc.

Also preserve actual rule codes instead of one generic priority:

```text
P2_XBLNR_TO_BELNR
P2_ZUONR_TO_BELNR
P2_XREF1_TO_BELNR
P2_XREF2_TO_BELNR
P2_REBZG_TO_BELNR
```

### 11. XREF2 is selected but not evaluated

The visible code selects XREF2 but the candidate rules do not use it. Either implement it as a governed reference rule or remove it from the POC until supported.

### 12. Equal AUGBL across company codes is not strong enough for automatic matching

Accounting document numbers are not globally unique across BUKRS/fiscal year.

Do not use:

```sql
a.augbl = b.augbl
```

across different company codes as a standalone automatic match rule.

Later clearing behavior can be evidence, but use full clearing/document context and cross-company transaction lineage.

### 13. Exact amount alone is not a control-grade transaction identity

Do not auto-accept:

```sql
ABS(a.amount_dc_signed + b.amount_dc_signed) < tolerance
```

without additional lineage/reference/date/process evidence and an ambiguity check.

Equal amount/date with no lineage should remain:

```text
AMOUNT_SUGGESTION
```

### 14. The current 1% fuzzy rule is too loose for high-value items

A 1% tolerance on a very large item can permit a material residual.

Use separate tolerances:

```text
technical_rounding_tolerance
absolute_policy_tolerance
relative_tolerance_with_absolute_cap
```

Use TCURX-aware currency precision instead of assuming two decimals globally.

---

## Strongest missing-partner recovery paths

Recommended evidence order:

| Priority | Evidence | Resolves |
|---|---|---|
| 1 | Valid BSEG-VBUND | Trading-partner company ID, not necessarily exact BUKRS |
| 2 | BKPF-BVORG + BVOR members | Exact counterpart BUKRS when exactly two company codes participate |
| 3 | Cross-company clearing line/configuration evidence | Configured counterpart |
| 4 | SD sales-org and plant ownership | Ordering and delivering company codes |
| 5 | STO supplying and receiving plants | Supplying and receiving company codes |
| 6 | Retained SD -> IDoc -> MM/FI lineage | Reciprocal application document |
| 7 | One distinct sibling partner or New GL RASSC | Company ID if unique |
| 8 | Posting-time KNA1/LFA1 VBUND | Company ID |
| 9 | KNA1-LIFNR -> LFA1-VBUND or LFA1-KUNNR -> KNA1-VBUND | Cross-role fallback |
| 10 | References/text/profit center/amount/date | Corroboration or review only |

For same-document partner recovery, only propagate a sibling partner if:

```sql
COUNT(DISTINCT normalized_vbund) = 1
```

Do not propagate through documents containing multiple distinct partners.

---

## Direct cross-company FI lineage

Use:

```text
BSEG item
-> BKPF.BVORG
-> BVOR transaction members
-> exact other BUKRS when exactly two company codes participate
-> company/trading-partner registry
```

For transactions containing more than two company codes, retain all candidates and resolve item-level relationships using the generated company-code clearing lines rather than arbitrarily selecting one counterpart.

Add these fields/tables where landed:

```text
BKPF-BVORG
BVOR
BSEG-KTOSL
T001U / cross-company clearing configuration
T880
```

---

## Source-document lineage

The current POC selects `AWTYP` but does not meaningfully use the corresponding source key.

Add:

```text
BKPF-AWTYP
BKPF-AWKEY
BKPF-AWSYS
```

and where available:

```text
BSEG-REBZG
BSEG-REBZJ
BSEG-REBZZ
BSEG-EBELN
BSEG-EBELP
BSEG-VBELN
BSEG-XREF3
BSEG-SGTXT
BSEG-UMSKZ
BSEG-AUGGJ
```

Invoice-family references such as REBZG/REBZJ/REBZZ can be stronger than generic amount/date similarity.

---

## New GL corroboration

If New GL is active, use:

```text
FAGLFLEXA-RASSC
```

as a trading-partner corroboration/recovery path.

Because document splitting can create several ledger lines from one entry-view item, do not assume:

```text
FAGLFLEXA-DOCLN = BSEG-BUZEI
```

Auto-use RASSC only when the relevant ledger lines resolve to one distinct partner.

Useful tables:

```text
FAGLFLEXA
FAGL_SPLINFO
```

---

## SD intercompany sale lineage

Do not rely on payer/sold-to identity alone.

Use process geometry:

```text
Seller FI where AWTYP='VBRK'
-> BKPF.AWKEY
-> VBRK/VBRP
-> VBFA document flow
-> originating sales organization
-> TVKO company code
-> delivering plant
-> T001W/T001K company code
-> intercompany billing document
-> inbound AP invoice / IDoc where retained
```

Ownership paths:

```text
ordering company: sales org -> TVKO-BUKRS
delivering company: plant -> valuation area -> T001K-BUKRS
billing company: VBRK-BUKRS
```

Preserve payer and sold-to as separate role records. Do not blindly coalesce them.

Useful SD tables:

```text
VBRK
VBRP
VBFA
VBAK
VBAP
VBKD
VBPA
KNVP
TVKO
LIKP
LIPS
```

---

## MM / STO lineage

Use:

```text
EKKO.RESWK supplying plant
-> T001W/T001K supplying BUKRS

EKPO.WERKS receiving plant
-> T001W/T001K receiving BUKRS

EBELN/EBELP
-> EKBE
-> RSEG
-> RBKP
-> buyer FI where AWTYP='RMRP'
```

A PO item can legitimately map to multiple deliveries, goods receipts, invoices, subsequent debits/credits, and reversals.

Use PO/document lineage as transaction identity, then reconcile group totals.

Useful MM/STO tables:

```text
EKKO
EKPO
EKBE
RBKP
RSEG
MKPF
MSEG
T001W
T001K
```

---

## IDoc / INVOIC lineage

If retained, use semantic business references rather than comparing outbound and inbound IDoc DOCNUM directly.

Useful tables:

```text
EDIDC
EDID4
EDIDS
```

Potentially useful mappings include purchase-order and delivery references from INVOIC segments. Treat DOCNUM as local to a system, not as a universal cross-system transaction key.

---

## Qlik / Attunity landing semantics

The visible SQL already excludes both uppercase and lowercase delete operation codes, so that is not the immediate issue.

The important question is whether each landed object is:

```text
current-state
history
append-only changes
other replicated form
```

Filtering deletion rows is not sufficient if the source contains multiple versions of the same SAP key.

For append-only history, rank by:

```text
complete native SAP key
source timestamp
change sequence
```

then retain the latest effective row and exclude terminal deletes.

If DDIC metadata is landed, use it to create a native-key registry rather than manually guessing table keys:

```text
DD02L
DD03L
DD04T
DD08L
```

---

## Recommended V7 architecture

Break the monolithic query into auditable layers.

### 1. `run_context`

Parameters and reproducibility metadata.

### 2. `source_state_*`

Resolve current/history/CDC semantics independently per table and assert one row per native key.

### 3. `fi_item_spine`

Normalize:

```text
source system/client
BUKRS/BELNR/GJAHR/BUZEI
posting date
clearing state
SHKZG signs
document currency
local currency
special G/L
reversal/source references
full item key
```

### 4. `ic_candidate_universe`

Classify CONFIRMED/PROBABLE/POSSIBLE/NON_IC and preserve why each item entered scope.

### 5. `partner_evidence`

One row per item/evidence/candidate, including:

```text
posted VBUND
BVORG/BVOR
cross-company clearing evidence
sibling-document consensus
New GL RASSC
historical master
cross-role master
SD ownership
MM/STO ownership
governed crosswalk
```

### 6. `partner_assignment`

Select VBUND, BUKRS, rule, confidence, and temporal basis atomically from a single compatible evidence row.

Preserve conflicts and candidate arrays.

### 7. `transaction_lineage`

Separate adapters for:

```text
direct FI
SD billing
MM invoice/STO
IDoc
invoice families
credits/reversals
```

### 8. `match_group`

One row per accepted transaction group.

Recommended fields:

```text
match_group_id
canonical_entity_a
canonical_entity_b
currency
match_rule
lineage_type
link_strength
balance_status
group_residual
member_count_a
member_count_b
contains_post_cutoff_evidence
```

### 9. `match_member`

One row per contributing FI item.

Recommended fields:

```text
match_group_id
item_key
entity
partner_vbund
partner_bukrs
amount_dc_signed
amount_lc_signed
member_side
assignment_rule
```

### 10. `side_coverage`

Directional controller view:

```text
entity
partner
currency
in_scope_items
assigned_partner_items
exact_entity_items
linked_items
balanced_linked_items
total_gross
linked_gross
unlinked_gross
net_exposure
```

### 11. `canonical_pair_summary`

Canonical pair view:

```text
entity_a
entity_b
currency
a_open_gross
b_open_gross
a_net_exposure
b_net_exposure
combined_net_residual
linked_groups
linked_unbalanced_groups
unlinked_gross_a
unlinked_gross_b
```

### 12. Exception outputs

Keep these explicit:

```text
unresolved_partner
partner_conflict
entity_ambiguous
linked_unbalanced
ambiguous_candidates
no_counterpart_found
source_state_quality_failure
```

---

## Validation gates

Before trusting V7, enforce or report these checks:

```text
duplicate_fi_item_keys = 0
joined_item_count = distinct_item_key_count
hybrid_partner_assignments = 0
items_in_multiple_accepted_groups = 0
match_rate_pct between 0 and 100
unlinked_gross >= 0
side_coverage totals tie to item spine
same inputs + source state => same result hash
```

For fallback-rule backtests, temporarily mask known BSEG-VBUND and measure:

```text
coverage
precision
conflict rate
false exact-BUKRS rate
gross value affected
precision by entity pair
precision by posting process
precision by age bucket
```

Do not promote a fallback rule to automatic merely because it increases coverage.

---

## Highest-value tables to add

### FI / master

```text
BVOR
T001U
T880
KNB1
LFB1
SKA1
SKB1
FAGLFLEXA
FAGL_SPLINFO
CDHDR
CDPOS
TCURX
T001A
```

### SD

```text
VBRP
VBFA
VBAK
VBAP
VBKD
VBPA
KNVP
TVKO
LIKP
LIPS
```

### MM / STO

```text
EKKO
EKPO
EKBE
RBKP
RSEG
MKPF
MSEG
T001W
T001K
```

### IDoc / exception

```text
EDIDC
EDID4
EDIDS
BSEC
LFBK
KNBK
MARM
T006
```

### Metadata

```text
DD02L
DD03L
DD04T
DD08L
```

---

## Immediate implementation order

1. Fix `match_rate_pct`, matched gross, and unmatched gross.
2. Remove `min_gjahr` from the financial population.
3. Fix blank-string handling and asymmetric reference predicates.
4. Replace independent partner COALESCE logic with atomic evidence selection.
5. Add source system/client and validate one current row per SAP key.
6. Remove equal AUGBL as an automatic cross-company match rule.
7. Build the denominator from the full IC candidate universe.
8. Add BVORG/BVOR, AWKEY/AWSYS, invoice-family fields, and RASSC.
9. Introduce `match_group` and `match_member`.
10. Add SD/MM lineage.
11. Keep amount/date logic only as a residual suggestion layer.

---

## Final principle for the agent

Do not optimize for the largest possible match percentage.

Optimize for an auditable hierarchy:

```text
partner identity
-> transaction lineage
-> financial reconciliation
```

Interpret outcomes as follows:

```text
strong lineage + residual = LINKED_UNBALANCED
equal amount/date without lineage = AMOUNT_SUGGESTION
known VBUND + multiple BUKRS = ENTITY_AMBIGUOUS
conflicting strong evidence = PARTNER_CONFLICT
credible IC evidence but unresolved = keep in population and denominator
```

Do not turn ambiguity into false certainty to improve coverage.
