# SAP intercompany reconciliation v3

This directory contains the frozen SQL reference implementation and the live
validation queries for the SAP ECC intercompany reconciliation sandbox.

## Start here

Read the [execution runbook](../docs/SAP_IC_v3_runbook.md) before executing the
main SQL. Do not begin with an enterprise-wide run.

Use this sequence:

1. Run [the source-validation pack](SAP_IC_SQL_validation_pack.sql) to confirm
   the live Unity Catalog schemas, CDC behavior, SAP native-key uniqueness, and
   required columns.
2. Select a narrow development pilot: one SAP source/client, one company code,
   governed AR/AP accounts, one currency, and a short close period.
3. Replace the wildcard and pilot configuration in `ic_v3_params`,
   `ic_v3_account_scope`, and the related mapping/rule views.
4. Execute [the main sandbox](SAP_IC_reconciliation_v3_sandbox.sql) in a
   development catalog.
5. Execute [the live assertions](SAP_IC_v3_live_assertions.sql), then reconcile
   row counts, signed balances, gross exposure, and exceptions to SAP controls.
6. Inspect the Databricks query profile and complete a Finance-reviewed shadow
   close before expanding scope or publishing a reporting product.

The main file is intentionally comprehensive and fail-closed. It is a tested
reference pipeline, not a claim that the current source contracts or accounting
results have been production-certified.

## Supporting material

- [Genie bounded-query playbook](../docs/SAP_IC_Genie_playbook.md)
- [Detailed SQL review](../docs/SAP_IC_SQL_review.md)
- [Deep reconciliation design](../docs/SAP_IC_reconciliation_deep_design_v2.md)
- [Offline test harness](SAP_IC_v3_offline_harness.py)
- [Pinned test dependencies](SAP_IC_v3_test_requirements.txt)
