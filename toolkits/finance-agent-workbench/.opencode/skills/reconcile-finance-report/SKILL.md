---
name: reconcile-finance-report
description: Prove or diagnose parity between legacy and candidate finance data, semantic models, or reports. Use for source-to-Databricks, M-to-SQL, PBIX/PBIP, DAX, hierarchy, visual, refresh, or migration validation; row/key/amount differences; control totals; duplicate or unmatched records; and deciding whether a report is verified, failed, or inconclusive.
---

# Reconcile a Finance Report

1. Load `finance-report-migration`, the migration playbook, finance semantics,
   and `../finance-data-reliability/references/databricks-reconciliation.md` when
   Databricks is involved.
2. Require aligned artifacts, snapshots, grain, periods, ledger, currency,
   hierarchy version, signs, and tolerances. Otherwise return `INCONCLUSIVE`.
3. Compare in layers: structure; rows/keys/duplicates/nulls; global totals;
   grouped totals; currency/sign/components; key-level exceptions; DAX/filter
   context; visual behavior; and operations.
4. Produce exception buckets for baseline-only, candidate-only, duplicate,
   changed value, unmapped hierarchy, FX, sign, null/blank/zero, and cutoff
   differences.
5. Classify each discrepancy before modifying logic. Aggregate agreement cannot
   hide offsetting errors.
6. Link every verified claim to a deterministic check and record unresolved
   differences in the run handoff.

Genie or model narrative may help classify a discrepancy but cannot promote a
failed deterministic check.
