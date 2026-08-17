---
name: inventory-finance-report
description: Create a read-only, evidence-backed inventory of a legacy or current finance report and its dependencies. Use for PBIX, PBIP, PBIR, Excel, Power Query M, SAP/XML/spool, DAX, relationships, visuals, helper/sample-file queries, parameters, refresh settings, Databricks source mappings, or before recreating, repairing, or optimizing a report.
---

# Inventory a Finance Report

1. Load `finance-report-migration`, its work context, and the inventory phase in
   `../finance-report-migration/references/migration-playbook.md`.
2. Load `finance-data-reliability` references matching every source/tool.
3. Create or reuse a task brief. Stay read-only.
4. Fingerprint exact artifacts and record versions; do not infer a complete
   model from screenshots or pasted expressions.
5. Inventory data acquisition, helper/sample-file functions, semantic-model
   objects, relationships, DAX, report pages/visuals/filters/bookmarks, refresh
   behavior, and known control totals.
6. Label each artifact and each material inventory claim `observed`, `inferred`,
   `unknown`, or `blocked` in the schema's evidence map and cite bounded
   evidence. Bare descriptive lists are not independently verified claims.
7. Return an inventory conforming to `schemas/report-inventory.schema.json`, a
   dependency map, missing-artifact list, risk hotspots, and the next phase.
   Do not rewrite queries during inventory.

If a required artifact is unavailable, continue with the available inventory
and synthetic/local tooling. Block only conclusions that require the missing
artifact.
