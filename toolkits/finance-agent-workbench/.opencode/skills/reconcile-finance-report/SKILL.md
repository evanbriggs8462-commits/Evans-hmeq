---
name: reconcile-finance-report
description: Prove or diagnose parity between legacy and candidate finance data, semantic models, or reports. Use for source-to-Databricks, M-to-SQL, PBIX/PBIP, DAX, hierarchy, visual, refresh, or migration validation; row/key/amount differences; control totals; duplicate or unmatched records; ECC customer/vendor open-item reconstruction; intercompany partner assignment and reciprocal matching; and deciding whether a report is verified, failed, or inconclusive.
---

# Reconcile a Finance Report

1. Load `finance-report-migration`, the migration playbook, finance semantics,
   and `../finance-data-reliability/references/databricks-reconciliation.md` when
   Databricks is involved.
2. For ECC customer/vendor items open at a historical key date, VBUND/RCOMP
   partner assignment, reciprocal D/K matching, split billing, matching
   coverage, or residual exposure, load
   [the V7 ECC intercompany implementation brief](../finance-report-migration/references/ecc-intercompany-reconciliation-v7-implementation-brief.md).
   Treat its population, record-grain, assignment, candidate-generation,
   matching, tolerance, summary, and validation requirements as mandatory.
3. Require aligned artifacts, snapshots, grain, periods, ledger, currency,
   hierarchy version, signs, and tolerances. Otherwise return `INCONCLUSIVE`.
4. Compare in layers: structure; rows/keys/duplicates/nulls; global totals;
   grouped totals; currency/sign/components; key-level exceptions; DAX/filter
   context; visual behavior; and operations.
5. Produce exception buckets for baseline-only, candidate-only, duplicate,
   changed value, unmapped hierarchy, FX, sign, null/blank/zero, and cutoff
   differences.
6. Classify each discrepancy before modifying logic. Aggregate agreement cannot
   hide offsetting errors.
7. Link every verified claim to a deterministic check and record unresolved
   differences in the run handoff.

Genie or model narrative may help classify a discrepancy but cannot promote a
failed deterministic check.
