# Genie Verification Update — Canonical IC Reconciliation Architecture

Date: 2026-08-17

Purpose: capture the latest Databricks Genie review of the intercompany reconciliation POC and reconcile it with the current architecture guidance so the local agent has a clear implementation sequence.

## Executive conclusion

Genie's latest review is directionally strong, and its central conclusion is correct: **Cell 6 should become the canonical foundation, not the older V7/V8 matching cells.**

The most important finding is that the newer implementation already fixes the atomic-evidence problem identified in the earlier screenshot review. That materially changes the implementation plan.

The newer Cell 6 pattern:

```text
assignment_evidence
  -> assignment_evidence_ranked
  -> assignment_selected
```

is the correct architecture because it stores one row per item/evidence/candidate and selects a single evidence row atomically. VBUND and BUKRS are therefore not independently `COALESCE`d from different evidence sources.

## What Genie correctly identifies as already implemented

The following patterns are aligned with the architecture guidance and should be preserved:

1. **Atomic evidence selection**
   - `assignment_evidence -> assignment_evidence_ranked -> assignment_selected`
   - One evidence row is selected atomically.
   - VBUND and BUKRS remain bound to the same evidence source.

2. **NULLIF handling**
   - KNA1/LFA1 and SD logic already normalize blank SAP character values with `NULLIF(TRIM(...), '')` in important places.

3. **Temporal basis labeling**
   - Evidence rows distinguish sources such as `POSTED_LINE`, `PROCESS_LINEAGE`, and `CURRENT_MASTER_ASSUMPTION`.
   - Current-master fallback is explicitly lower priority than posted/document evidence.

4. **IC candidate universe**
   - Cell 6 uses multiple IC indicators and preserves unresolved rows such as `MANUAL_RECON_REQUIRED` rather than restricting the denominator to already resolved exact-partner items.

5. **AUGBL treatment**
   - Clearing document evidence is being used as an IC indicator rather than as an automatic cross-company matching rule.

6. **BVORG two-company lineage**
   - `RULE_1B_BVORG_TWO_COMPANY` is a strong addition because it can resolve the exact counterpart BUKRS when a cross-company transaction contains exactly two company codes.

7. **Run parameters**
   - `as_of_date`, `cutoff_exclusive`, `source_state_as_of_ts`, `reconstruction_mode`, and `code_version` are already represented.

## Important qualification: Cell 6 is not yet fully control-grade

Cell 6 should be described as **architecturally superior and suitable as the canonical base after several correctness fixes**, not simply "done" or "fully sound."

The following issues still require correction.

## 1. Replace arbitrary MAX(VBUND) with unique-only evidence

If `kna1_base` or `lfa1_base` uses:

```sql
MAX(NULLIF(TRIM(vbund), ''))
```

then multiple competing VBUND values can be collapsed into whichever value sorts highest. That can silently create false assignments.

Use a unique-only pattern:

```sql
CASE
  WHEN COUNT(DISTINCT NULLIF(TRIM(vbund), '')) = 1
  THEN MIN(NULLIF(TRIM(vbund), ''))
  ELSE NULL
END
```

Ambiguous master evidence should remain ambiguous rather than being resolved arbitrarily.

## 2. Separate activity-window logic from month-end open-item logic

A one-month filter such as:

```sql
budat >= window_start
AND budat < cutoff_exclusive
```

may be acceptable for an activity-analysis bridge, but it is not sufficient for a month-end open-item population.

There are two distinct populations:

```text
assignment_activity_population
    postings occurring inside a limited analysis period

month_end_open_population
    every item posted before cutoff_exclusive that remained open at cutoff
```

The month-end financial population must not exclude prior-month or prior-year items that are still open.

The financial spine should retain the true key-date rule:

```text
BUDAT < cutoff_exclusive
AND item was uncleared at cutoff
```

A recent activity window may still be used downstream to constrain expensive lineage searches, but it must not define the accounting balance.

## 3. Add complete run-level audit fields

The current parameters are directionally correct but should be completed with:

```text
run_id
git_commit_sha
executed_at
```

alongside:

```text
as_of_date
cutoff_exclusive
source_state_as_of_ts
reconstruction_mode
code_version
```

These fields should flow into validation and output tables so a result can be traced to a specific code state and source-state snapshot.

## 4. Preserve SD roles as separate evidence rows

Do not collapse payer and sold-to evidence with:

```sql
COALESCE(payer_vbund, sold_to_vbund)
```

Even if both source columns remain visible in the output, a coalesced partner derivation loses role context and can hide disagreement.

Model them separately:

```text
SD_SOLD_TO_VBUND
SD_PAYER_VBUND
SD_ORDERING_COMPANY
SD_DELIVERING_COMPANY
SD_INTERCOMPANY_BILLING_COMPANY
```

A disagreement between payer and sold-to is useful evidence and should remain visible to the assignment engine.

## 5. Add invoice-family and direct source-document references

Add from BSEG where available:

```text
REBZG
REBZJ
REBZZ
VBELN
EBELN
EBELP
XREF3
SGTXT
UMSKZ
AUGGJ
```

`REBZG/REBZJ/REBZZ` are particularly valuable for credit memo, payment, and invoice-family linkage and should rank ahead of fuzzy amount/date similarity.

The source document keys `VBELN`, `EBELN`, and `EBELP` can also materially reduce dependence on heuristic matching.

## 6. Add New GL RASSC corroboration carefully

If New GL is active, add `FAGLFLEXA-RASSC` as trading-partner corroboration.

Do not assume a one-to-one relationship between ledger line number and BSEG item number because document splitting can create multiple ledger lines for a single entry-view item.

Auto-promote RASSC only when the relevant ledger lines resolve to one distinct partner. Otherwise preserve the candidate set and conflict state.

## 7. Complete the SD ownership chain

Do not stop at payer/sold-to VBUND.

Trace the intercompany sales geometry:

```text
FI source document
  -> VBRK/VBRP
  -> VBFA document flow
  -> ordering sales organization
  -> TVKO-BUKRS
  -> delivering plant
  -> T001W/T001K company code
  -> intercompany billing document
```

This can identify the actual ordering and delivering legal entities even when customer roles are not sufficient.

## 8. Add cross-company clearing configuration evidence

Add configured cross-company clearing evidence from the relevant SAP configuration tables, including T001U / OBYA relationships where landed and applicable.

This can provide a stronger counterpart signal than generic amount/date matching.

## 9. Assert one source-state row per SAP native key

This remains a high-priority control.

If Qlik/Attunity landing tables contain multiple versions of the same SAP business row, a normal join can silently multiply BSEG or master records.

Before relying on any source adapter, assert one row per complete SAP native key for the selected `source_state_as_of_ts`.

If the table is append-only/history, reconstruct the selected state using:

```text
complete native key
source timestamp
deterministic change sequence
operation code
```

Filtering deletion records alone is not enough to guarantee one current row.

## 10. Add T880 enterprise-structure corroboration where useful

T880 or an equivalent governed company registry can help validate group-company membership and map trading-partner/company identifiers to legal entities.

Use it as corroboration and legal-entity registry support rather than as an uncontrolled replacement for document evidence.

## 11. Validate TCURX before changing landed amounts

Genie is correct that hardcoded two-decimal assumptions are unsafe, but do not blindly rescale landed `WRBTR`, `DMBTR`, or similar amounts.

SAP currency decimal behavior and replication-layer transformations can differ. The landed Qlik/Attunity representation may already expose externally scaled values.

Before changing amount logic:

1. Select known examples for a zero-decimal currency such as JPY.
2. Select a three-decimal currency if present.
3. Compare the landed values to known SAP report values.
4. Determine whether the replication layer already applies currency scaling.
5. Only then make TCURX-aware tolerance or display logic.

Use TCURX primarily to define currency precision and tolerance once the landed amount semantics are verified.

## Recommended implementation order

The next sprint should be ordered as follows:

1. **Open-item spine correctness** — ensure the accounting population includes all items open at cutoff, not only one-month activity.
2. **Unique-only master evidence** — replace arbitrary `MAX(VBUND)` behavior.
3. **Source-state/native-key assertions** — prove joins cannot silently duplicate SAP rows.
4. **Invoice-family and source-document keys** — add `REBZG/REBZJ/REBZZ`, `VBELN`, `EBELN/EBELP`, and related fields.
5. **SD role preservation** — keep payer, sold-to, ordering-company, delivering-company, and billing-company evidence distinct.
6. **BVORG/BVOR and clearing configuration** — strengthen exact legal-entity resolution.
7. **RASSC plus SD/MM process lineage** — enrich transaction identity with native SAP document flow.
8. **Currency precision validation** — validate landed amount semantics before making TCURX-driven changes.

This order matters. Sophisticated lineage should not be built on top of an accounting population that can omit aged open items or a replicated source state that can duplicate native SAP keys.

## Do not delete V7/V8 yet

Freeze V7/V8 as comparison baselines while Cell 6 becomes the canonical architecture.

Run old and new logic side-by-side and report, at minimum:

```text
population item count
gross open value
resolved VBUND %
exact partner BUKRS %
linked item %
linked gross %
balanced linked %
ambiguous partner count
duplicate native-key count
rule-level precision
high-value changed assignments
```

For every fallback rule, backtest against items where `BSEG-VBUND` is already populated by masking the known answer and measuring whether the rule recovers it correctly.

A rule should be promoted from review-only to automatic only after its precision is demonstrated.

## Canonical path going forward

The intended architecture should now be:

```text
Cell 6 canonical evidence architecture
    -> corrected month-end FI item spine
    -> source-state/native-key validation
    -> partner evidence rows
    -> atomic partner assignment
    -> IC candidate universe
    -> deterministic SAP lineage adapters
    -> match_group
    -> match_member
    -> side_coverage
    -> canonical_pair_summary
    -> exception outputs
```

The older V7/V8 pattern:

```sql
COALESCE(line_vbund, vendor_vbund, customer_vbund)
```

should be refactored around Cell 6 rather than used as the foundation for Cell 6.

## Final decision

**Cell 6 is the canonical foundation going forward.**

Before adding more fuzzy matching sophistication, implement these four changes first:

1. Fix `MAX(VBUND)` to unique-only logic.
2. Add invoice-family fields and direct SAP lineage keys to `bseg_base`.
3. Expand the FI spine to the true month-end open-item population.
4. Add source-state/native-key validation.

Then extend the evidence graph with BVORG/BVOR, clearing configuration, RASSC, SD ownership, MM/STO lineage, and currency-aware validation.
