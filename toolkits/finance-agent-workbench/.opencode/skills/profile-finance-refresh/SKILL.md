---
name: profile-finance-refresh
description: Diagnose and propose improvements for a portfolio of scheduled Power BI/Fabric finance refreshes backed by Databricks or other enterprise sources. Use for long refreshes, queueing, overlapping schedules, premium-capacity contention, warehouse wait, gateway/network delay, Power Query or SQL runtime, model processing, refresh failures, or a low-risk schedule-staggering plan before query redesign.
---

# Profile Finance Refreshes

1. Load the work context, local-model operations, migration playbook operational
   phase, and the relevant Power BI/Databricks reliability references.
2. Build a read-only task brief with time window, close-period coverage,
   consumer deadlines, report aliases, and telemetry bounds.
3. Separate Power BI/Fabric capacity queueing, gateway/network/authentication,
   Power Query/data acquisition, Databricks warehouse queue/SQL runtime/result
   fetch, and semantic-model processing.
4. Normalize time zones and correlate only within defensible windows. Databricks
   query history alone does not prove Fabric capacity contention.
5. Return a baseline, bottleneck classification with confidence, proposed
   stagger or architecture change, expected benefit, rollback, and observation
   window.
6. Do not change schedules, refresh, warehouse settings, jobs, queries, or
   partitions without the separate exact write gate.

