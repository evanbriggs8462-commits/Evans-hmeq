# V7 Intercompany Reconciliation — Reinforcement Findings

Date: 2026-08-17

Purpose: reinforce the local agent with the latest SAP/ECC intercompany reconciliation findings, visible-code defects, architectural recommendations, and implementation priorities derived from the current Databricks POC screenshots and SAP posting architecture research.

## Core design principle

Do not expand the current solution into a larger all-to-all matching query. The stronger control-grade design is an auditable SAP document-evidence graph that answers three separate questions:

1. Is this item intercompany, and which legal entity is the partner?
2. Which reciprocal posting or transaction group does it belong to?
3. Does that group financially reconcile?

Keep partner identity, transaction identity, and financial balance as distinct concepts.

---

# A. Important findings beyond the original implementation brief

## 1. Add a second temporal parameter: `source_state_as_of_ts`

`cutoff_exclusive` answers the accounting key date. `source_state_as_of_ts` answers which physical source state is being used to reconstruct that close.

SAP clearing reset behavior can remove `AUGBL` / `AUGDT`. Therefore, a current-state BSEG record may no longer reveal whether the item was cleared at a prior close. A reproducible control needs either retained CDC/history or certified month-end snapshots.

Recommended run modes:

- `CURRENT_RESTATED`: reconstruct the historical key date using current source state.
- `ORIGINAL_CLOSE`: reconstruct the key date using source state retained as of the historical close.

Add:

```text
as_of_date
cutoff_exclusive
source_state_as_of_ts
reconstruction_mode
```

## 2. Confirm Qlik / Attunity landing semantics before filtering `hdr__oper`

The visible SQL already filters both `'D'` and `'d'`, so lowercase deletion leakage is not the immediate defect.

The more important question is whether each landed object is:

- a current-state table,
- a history table,
- an append-only changes table,
- or some other replicated representation.

Filtering deletion records does not necessarily collapse a CDC/history dataset to one current row per native SAP key.

For append-only history, rank by the complete SAP key plus source timestamp and deterministic sequence, then exclude the final `UPPER(hdr__oper)='D'` state.

## 3. Current KNA1/LFA1 is not historical truth

Do not backfill an older blank BSEG-VBUND using today's KNA1/LFA1 without labeling the temporal assumption.

A master assignment can change during the year. Using the current master on an older posting can retroactively classify an item as intercompany even though the relationship was different when the item posted.

Preferred evidence order:

- posting-time master snapshot,
- CDHDR/CDPOS reconstruction,
- certified historical master snapshot,
- current master only as `CURRENT_MASTER_ASSUMPTION`.

## 4. The IC population must include unresolved suspected IC items

The current visible query creates the reporting population from already-resolved exact partner items. This excludes precisely the items that the bridge is supposed to remediate.

Build an `ic_candidate_universe` containing items with reasons such as:

- posted VBUND,
- dedicated IC reconciliation account,
- known internal customer/vendor registry,
- BVORG/BVOR membership,
- cross-company clearing evidence,
- New GL RASSC evidence,
- sibling-document partner evidence,
- SD or MM organizational ownership,
- governed historical crosswalk evidence.

Classify scope, for example:

```text
CONFIRMED_IC
PROBABLE_IC
POSSIBLE_IC
NON_IC
```

Preserve `ic_scope_reason` and do not hide unresolved rows from the denominator.

## 5. Once 1:N and N:1 exist, pair-count coverage is invalid

The formula `2 * matched_pairs / total_items` is only meaningful for a pure 1:1 subset.

Overall coverage should use unique match members:

```text
unique accepted match_member.item_key count / total in-scope item count
```

## 6. Normalize amounts once and preserve currency semantics

Use `SHKZG` to normalize sign. Do not assume `WRBTR` or `DMBTR` is already signed.

Carry separately:

- document currency,
- local/company-code currency,
- any additional local currencies if relevant.

Do not hardcode two-decimal tolerance globally. Currency precision can differ; use TCURX-aware logic.

## 7. Transaction identity and financial reconciliation are separate

A strong SD/MM/FI lineage link with a residual should be:

```text
LINKED_UNBALANCED
```

not “unmatched.”

Conversely, an equal amount/date pair without transaction lineage should remain an:

```text
AMOUNT_SUGGESTION
```

not an accepted control-grade match.

---

# B. Strongest missing-partner recovery paths

Recommended evidence priority:

| Priority | Evidence | What it resolves |
|---|---|---|
| 1 | Valid BSEG-VBUND | Company / trading-partner ID; not necessarily exact BUKRS |
| 2 | BKPF-BVORG plus BVOR members | Exact counterpart BUKRS when exactly two company codes participate |
| 3 | Cross-company clearing line/configuration evidence | Exact configured counterpart |
| 4 | SD sales-org and plant ownership | Exact ordering and delivering company codes |
| 5 | STO supplying and receiving plants | Exact supplying and receiving company codes |
| 6 | Retained SD → IDoc → MM/FI lineage | Exact reciprocal application document |
| 7 | One distinct partner elsewhere in FI document or New GL RASSC | Company/trading-partner ID when unique |
| 8 | Posting-time KNA1/LFA1 VBUND | Company/trading-partner ID |
| 9 | KNA1-LIFNR → LFA1-VBUND or LFA1-KUNNR → KNA1-VBUND | Cross-role master fallback |
| 10 | References, one-time-account identity, profit center, text, amount/date | Corroboration or review only |

For same-document partner recovery, copy a sibling partner only when:

```sql
COUNT(DISTINCT normalized_vbund) = 1
```

Do not propagate a partner through documents containing multiple partner values.

If New GL is active, `FAGLFLEXA-RASSC` can corroborate or recover BSEG-VBUND, but document splitting can create several ledger rows per entry-view item. Do not assume ledger line number maps 1:1 to BSEG-BUZEI. Use RASSC automatically only where the relevant ledger lines resolve to one distinct partner.

---

# C. SAP posting chains worth implementing

## Direct cross-company FI

```text
BSEG item
  → BKPF.BVORG
  → BVOR transaction members
  → exact other BUKRS where transaction has exactly two company codes
  → T001.RCOMP / company registry
```

For multi-company transactions, preserve all counterpart candidates and resolve line-level relationships using the generated intercompany clearing lines rather than selecting an arbitrary company.

## SD intercompany sale

```text
Seller FI where AWTYP='VBRK'
  → BKPF.AWKEY / VBRK
  → VBRP
  → VBFA document flow
  → originating sales organization
  → TVKO company code
  → delivering plant
  → T001W/T001K company code
  → intercompany billing document
  → IDoc / inbound AP invoice where retained
```

Useful ownership paths:

- Ordering company: sales organization → TVKO-BUKRS.
- Delivering company: plant → valuation area → company code.
- Billing company: VBRK-BUKRS.

Do not simply coalesce payer and sold-to customer roles. Preserve role-level records and conflicts.

## MM / STO

```text
EKKO.RESWK supplying plant
  → T001W/T001K supplying BUKRS
EKPO.WERKS receiving plant
  → T001W/T001K receiving BUKRS
EBELN / EBELP
  → EKBE history
  → RSEG
  → RBKP
  → buyer FI where AWTYP='RMRP'
```

A PO item can legitimately map to multiple deliveries, goods receipts, invoices, subsequent debits/credits, and reversals. Use PO item and document-flow lineage for transaction identity, then evaluate group totals.

## IDoc / INVOIC

When retained, use semantic qualifiers and business references. Do not match outbound and inbound IDoc DOCNUM directly because IDoc numbers are local to the system.

---

# D. Visible SQL review — lines 1–263

The screenshots are sufficient to identify several concrete defects in the current POC.

## Stop-ship defect 1: partner assignment can create a hybrid counterparty

The visible logic independently computes:

```sql
assigned_ic_partner = COALESCE(line_vbund, vendor_master_vbund, customer_master_vbund)
partner_bukrs       = COALESCE(line_vbund_bukrs, vendor_master_bukrs, customer_master_bukrs)
```

Those expressions can choose different evidence sources.

Example:

```text
BSEG-VBUND = C001
C001 maps to multiple BUKRS → line-derived exact BUKRS is NULL

LFA1-VBUND = C002
C002 maps uniquely to BUKRS 2000
```

The current row can become:

```text
assigned_ic_partner = C001
partner_bukrs       = 2000
assignment_rule     = RULE_1_DIRECT_VALID_VBUND
partner_status      = RESOLVED
```

That is internally inconsistent and can lead to false exact entity matching.

### Required correction

Build one row per item/evidence/candidate and select an evidence row atomically.

Example conceptual structure:

```sql
partner_evidence AS (
    SELECT
        item_key,
        10 AS evidence_priority,
        'POSTED_BSEG_VBUND' AS evidence_type,
        vbund_line AS candidate_vbund,
        vp_line.unique_partner_bukrs AS candidate_bukrs,
        'POSTED' AS temporal_basis
    FROM ...

    UNION ALL

    SELECT
        item_key,
        80,
        'CURRENT_VENDOR_MASTER',
        lp.unique_vbund,
        vp_vendor.unique_partner_bukrs,
        'CURRENT_MASTER_ASSUMPTION'
    FROM ...
)
```

The selected evidence row must provide these fields together:

```text
assigned_vbund
partner_bukrs
assignment_rule
temporal_basis
confidence
source_document_keys
```

If the strongest evidence identifies a VBUND but cannot identify an exact BUKRS, preserve:

```text
assigned_vbund = C001
partner_bukrs  = NULL
partner_status = PARTNER_COMPANY_KNOWN_ENTITY_AMBIGUOUS
```

Do not fall through to a lower-priority BUKRS associated with a different VBUND.

---

## Stop-ship defect 2: final match-rate calculation can exceed 100%

The visible query creates directional population rows by:

```sql
GROUP BY bukrs, partner_bukrs, waers
```

but creates one canonical pair statistic by:

```sql
GROUP BY a_ent, b_ent, ccy
```

Then it joins the canonical pair statistic back to both directional rows and calculates:

```sql
s.pairs * 2.0 / p.items * 100
```

For one matched item on each side:

```text
p.items = 1
s.pairs = 1
```

The result is 200%.

### The amount metrics have the same canonical/directional mismatch

`match_stats.matched_dc` is calculated from `ABS(a_amt)`, where side A is forced to be the lexicographically lower company code.

Example:

```text
A item = 100
B item = -99
Residual = 1
```

Canonical statistics record:

```text
matched_dc = 100
```

On B's directional row:

```text
p.gross = 99
unmatched_dc = 99 - 100 = -1
```

Negative unmatched gross is a reporting artifact and logically invalid.

### Required correction

Introduce match members:

```sql
matched_members AS (
    SELECT a_key AS item_key, match_group_id FROM matched
    UNION ALL
    SELECT b_key AS item_key, match_group_id FROM matched
)
```

Then compute directional coverage directly from the item spine:

```sql
100.0 * matched_items / NULLIF(total_items, 0)
```

and directional matched gross from the actual items on that side.

This remains valid for 1:1, 1:N, N:1, and N:M groups.

---

## Stop-ship defect 3: the coverage denominator excludes difficult items

The visible `matchable` CTE filters to:

```sql
partner_bukrs IS NOT NULL
AND assigned_ic_partner IS NOT NULL
AND partner_status = 'RESOLVED'
```

Then `pop` is built from `matchable`.

Therefore the final report excludes:

- blank VBUND items,
- ambiguous VBUND-to-BUKRS mappings,
- conflicting master assignments,
- missing customer/vendor master partner values,
- probable IC items inferred from process/document evidence,
- unresolved high-value exposure.

These rows disappear instead of showing as unresolved.

### Required coverage measures

At minimum report separately:

```text
Partner-company coverage
  items with assigned VBUND / all in-scope IC items

Exact-entity coverage
  items with assigned partner BUKRS / all in-scope IC items

Transaction-linkage coverage
  items in accepted match groups / all in-scope IC items

Balanced-linkage coverage
  items in accepted groups whose residual is within tolerance / all in-scope IC items
```

The denominator must come from `ic_candidate_universe`, not `matchable`.

---

## Stop-ship defect 4: dual ROW_NUMBER is not truly greedy or globally optimal

The visible logic ranks candidates independently for each side and keeps only:

```sql
ra = 1 AND rb = 1
```

This is a mutual-best heuristic, not a true greedy algorithm and not a maximum-cardinality or minimum-cost bipartite assignment.

Example:

```text
A1 → B1 strong
A1 → B2 acceptable
A2 → B1 strong
```

Mutual-best may accept only A1-B1, while the assignment A1-B2 plus A2-B1 would consume all four items.

The current window ordering also has no final unique tie-breaker. If priority, residual, and date distance tie, `ROW_NUMBER()` can be nondeterministic.

### Tactical correction

Add a stable item key at the end of each ordering:

```sql
ROW_NUMBER() OVER (
    PARTITION BY a_key
    ORDER BY
        priority,
        ABS(a_amt + b_amt),
        ABS(DATEDIFF(a_dt, b_dt)),
        b_key
) AS ra
```

Do the reciprocal equivalent with `a_key`.

Rename this outcome to something like:

```text
MUTUAL_BEST_1_TO_1_SUGGESTION
```

Do not represent it as a general 1:1 matching engine.

### Better control design

1. Accept deterministic lineage groups first.
2. Consume their members.
3. Accept exact-reference groups only when cardinality is unambiguous.
4. Generate weaker amount/date candidates only over unconsumed items.
5. Auto-accept residual candidates only where both sides are unique and the winner has a sufficient margin over second-best.
6. Route ambiguous connected components to review.

Prefer `AMBIGUOUS_CANDIDATES` over forcing an arbitrary match.

---

## Stop-ship defect 5: historical open-item reconstruction is not reproducible

### Remove `b.gjahr >= p.min_gjahr`

The visible query derives a calendar-year floor and applies it to fiscal year.

This can drop valid prior-year open items and behaves inconsistently across calendar months. It is also not safe for non-calendar fiscal variants.

A true month-end population should use the accounting key-date condition without silently dropping older open items.

If performance requires a retained-history bound, make that a governed policy with an explicit limitation.

### Keep the key-date logic but normalize initial values

Conceptually correct condition:

```sql
BUDAT < cutoff_exclusive
AND (
    clearing date is initial
    OR AUGDT >= cutoff_exclusive
)
```

Normalize blank/null/initial SAP values such as `00000000` before comparing.

### Current source state is not enough for `ORIGINAL_CLOSE`

Clearing resets and backdated activity mean current BSEG state can differ from what was known when the close originally occurred.

Use retained history/snapshot semantics for a reproducible original close.

---

# E. Additional visible defects

## 1. `COALESCE(TRIM(kunrg), TRIM(kunag))` mishandles blank SAP character fields

A blank string is not NULL. If `KUNRG` trims to `''`, `COALESCE` returns `''` and never reaches `KUNAG`.

Use:

```sql
COALESCE(
    NULLIF(TRIM(kunrg), ''),
    NULLIF(TRIM(kunag), '')
)
```

Better: preserve payer and sold-to as separate roles and retain conflicts.

## 2. P2 reference rules are asymmetric because only one side is checked for nonblank

Visible pattern:

```sql
WHEN COALESCE(a.xblnr, '') <> ''
 AND (a.xblnr = b.belnr OR b.xblnr = a.belnr)
THEN 2
```

If `a.xblnr` is blank but `b.xblnr = a.belnr`, the reverse-direction evidence is blocked.

Use symmetrical logic:

```sql
WHEN (
       NULLIF(a.xblnr, '') IS NOT NULL
       AND a.xblnr = b.belnr
     )
  OR (
       NULLIF(b.xblnr, '') IS NOT NULL
       AND b.xblnr = a.belnr
     )
THEN 2
```

Apply the same concept to ZUONR, XREF1, XREF2, and invoice-family references.

## 3. XREF2 is selected but not evaluated

Preserve explicit rule codes rather than one generic priority bucket:

```text
P2_XBLNR_TO_BELNR
P2_ZUONR_TO_BELNR
P2_XREF1_TO_BELNR
P2_XREF2_TO_BELNR
P2_REBZG_TO_BELNR
```

This is necessary for rule-level precision backtesting.

## 4. Equal AUGBL across different company codes is not sufficient automatic identity

Accounting document numbers are not globally unique across company code/fiscal year.

Treat equal AUGBL across entities as weak or corroborating evidence unless reinforced by proper clearing/cross-company transaction lineage.

## 5. Exact amount without date/lineage bounds is too weak

Visible rule:

```sql
ABS(a.amount_dc_signed + b.amount_dc_signed) < 0.01
```

This can cross-match recurring identical amounts over a large date horizon.

Do not auto-accept exact amount alone. Require entity reciprocity, currency compatibility, time bounds, and stronger source/reference/process corroboration.

## 6. A 1% fuzzy tolerance is financially unsafe without an absolute cap

For a USD 10 million item, 1% is USD 100,000.

Use separate concepts:

```text
technical rounding tolerance
policy residual tolerance
relative tolerance as corroboration only
```

Always cap relative tolerance with an absolute policy limit.

---

# F. Strong SAP evidence currently not used by the visible query

## 1. Direct cross-company FI

Add:

```text
BKPF-BVORG
BVOR transaction membership
BSEG-KTOSL or equivalent cross-company clearing line characteristics
cross-company clearing configuration where landed
```

For a two-company transaction, BVORG/BVOR can identify the exact counterpart much more reliably than reference or amount comparison.

## 2. Source-document lineage

The query selects `AWTYP` but does not exploit source lineage.

Add:

```text
BKPF-AWTYP
BKPF-AWKEY
BKPF-AWSYS
```

Also add where available:

```text
REBZG / REBZJ / REBZZ
EBELN / EBELP
VBELN
XREF3
SGTXT
UMSKZ
AUGGJ
```

Invoice-family and source-document references are generally stronger than generic amount/date similarity.

## 3. New GL corroboration

If New GL is active, use:

```text
FAGLFLEXA-RASSC
```

as recovery/corroboration evidence, subject to document-splitting ambiguity controls.

## 4. SD lineage

Current VBRK use is only a supplemental customer filter. Replace that with a proper SD ownership/document-flow adapter.

## 5. MM/STO lineage

Use plant ownership, PO item, PO history, invoice receipt, and FI source-document references to reconstruct reciprocal groups.

---

# G. Recommended V7 architecture

Break the monolith into auditable layers.

## 1. `source_state_*`

Resolve current/history/CDC semantics separately for each table.

Assert one row per native SAP key after applying source-state logic.

Where useful and landed, use DD03L/DDIC metadata to drive a native-key registry.

## 2. `fi_item_spine`

Normalize:

- source system/client,
- BUKRS/BELNR/GJAHR/BUZEI,
- posting/clearing dates,
- signed amounts,
- document/local currencies,
- special G/L indicators,
- reversals,
- source document references,
- clearing information,
- FI reference fields.

## 3. `ic_candidate_universe`

Classify every FI item as:

```text
CONFIRMED_IC
PROBABLE_IC
POSSIBLE_IC
NON_IC
```

Preserve every reason that caused it to enter scope.

## 4. `partner_evidence`

One row per item/evidence/candidate.

Include evidence adapters for:

- posted BSEG-VBUND,
- BVORG/BVOR,
- cross-company clearing evidence,
- document consensus,
- New GL RASSC,
- historical master,
- current master fallback,
- cross-role customer/vendor master,
- SD ownership,
- MM/STO ownership,
- governed crosswalks.

## 5. `partner_assignment`

Select an evidence row atomically.

Preserve:

```text
assigned_vbund
partner_bukrs
assignment_rule
evidence_priority
confidence
temporal_basis
candidate_count
candidate_array
conflict_flag
```

## 6. `transaction_lineage`

Build separate adapters for:

- direct FI,
- SD billing,
- MM invoice / STO,
- IDoc,
- invoice families,
- credit/debit relationships,
- reversals,
- payments/clearings.

## 7. `match_group` and `match_member`

Accept governed 1:1, 1:N, N:1, and lineage-resolved N:M groups.

Preserve every contributing item key.

Only run weaker pair candidates on unconsumed items.

## 8. Separate outputs

Produce distinct outputs:

```text
match_detail
match_members
side_coverage
canonical_pair_summary
unresolved_partner
partner_conflict
entity_ambiguous
linked_unbalanced
ambiguous_candidates
no_counterpart_found
source_state_quality_failure
candidate_review
```

---

# H. Recommended output models

## `match_group`

One row per transaction group:

```text
match_group_id
canonical_entity_a
canonical_entity_b
transaction_currency
match_rule
lineage_type
link_strength
balance_status
group_residual
member_count_a
member_count_b
evidence_available_ts
contains_post_cutoff_evidence
```

## `match_member`

One row per contributing FI item:

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

## `side_coverage`

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

## `canonical_pair_summary`

One row per entity pair:

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

---

# I. Suggested mapping from current CTEs to the stronger architecture

| Current CTE | Recommended replacement |
|---|---|
| `params` | `run_context` with as-of date, cutoff, source-state timestamp, code version |
| `t001_canonical` | `legal_entity_registry` |
| `supplemental_vbund` | governed internal business-partner registry + role-level SD evidence |
| `kna1_profile`, `lfa1_profile` | historical/current master evidence adapters |
| `open_dk_items` | `fi_item_spine` |
| `assigned_balance` | `partner_evidence`, `partner_candidate_summary`, `partner_assignment` |
| `matchable` | `ic_candidate_universe`; exact-partner subset becomes downstream only |
| `candidates` | deterministic-lineage edges, reference edges, amount-suggestion edges |
| `ranked`, `matched` | `match_group`, `match_member`, `candidate_review` |
| `match_stats`, `pop` | `side_coverage`, `canonical_pair_summary` |

---

# J. Versioning and run metadata

The visible notebook/file names are inconsistent (`v4`, `V6`, `V7`). Add explicit run metadata to every output:

```text
run_id
code_version
git_commit_sha
as_of_date
cutoff_exclusive
source_state_as_of_ts
reconstruction_mode
executed_at
```

This removes ambiguity from before/after validation and audit review.

---

# K. Minimum validation gates before trusting V7

The implementation should fail or warn prominently when any of these are violated:

```sql
-- One source-state row per FI item key
duplicate_fi_item_keys = 0

-- BKPF join did not multiply BSEG
joined_item_count = distinct_item_key_count

-- Partner company and exact BUKRS are evidence-compatible
hybrid_partner_assignments = 0

-- Accepted items are consumed once
items_in_multiple_groups = 0

-- Coverage is bounded
match_rate_pct BETWEEN 0 AND 100

-- Gross exposure cannot be negative
unlinked_gross_dc >= 0

-- Directional totals reconcile to the item spine
SUM(side_coverage.total_gross) = SUM(ic_population.gross)

-- Same parameters and source state reproduce same result
result_hash_run_1 = result_hash_run_2
```

For each fallback rule, backtest by temporarily masking populated BSEG-VBUND and measuring:

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

Do not promote a rule from review to automatic solely because it increases coverage.

---

# L. Immediate implementation order

1. Fix `match_rate_pct`, `matched_dc`, and `unmatched_dc` using member-based directional coverage.
2. Remove `b.gjahr >= p.min_gjahr` from the accounting population.
3. Fix blank-string handling and asymmetric P2 predicates.
4. Replace independent partner `COALESCE` expressions with atomic evidence selection.
5. Add source system/client to SAP keys and validate source-state uniqueness.
6. Remove equal `AUGBL` as an automatic cross-company match rule.
7. Build the denominator from the complete IC candidate universe.
8. Add BVORG/BVOR, AWKEY/AWSYS, invoice-family fields, and RASSC.
9. Introduce `match_group` and `match_member`.
10. Add SD/MM lineage.
11. Keep amount/date logic as a residual suggestion layer, not primary transaction identity.
12. Add before/after validation metrics and rule-level backtesting.

---

# M. Highest-value additional SAP tables / fields

## FI / master

```text
BVOR
T001U or relevant cross-company clearing configuration landed in ECC extract
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

## SD

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

## MM / STO

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

## IDoc / exception

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

## Metadata

```text
DD02L
DD03L
DD04T
DD08L
```

---

# N. Final principle for the local agent

Do not optimize for the largest possible match percentage.

Optimize for an auditable hierarchy of evidence:

```text
partner identity
→ transaction lineage
→ financial reconciliation
```

A row with strong transaction lineage but a financial residual is `LINKED_UNBALANCED`.

A row with equal amount/date but no lineage is `AMOUNT_SUGGESTION`.

An item with one known trading partner but multiple possible BUKRS values is `ENTITY_AMBIGUOUS`.

An item with conflicting strong evidence should be `PARTNER_CONFLICT`.

An item with unresolved but credible IC evidence must remain in the population and denominator.

Do not turn ambiguity into false certainty merely to improve coverage.
