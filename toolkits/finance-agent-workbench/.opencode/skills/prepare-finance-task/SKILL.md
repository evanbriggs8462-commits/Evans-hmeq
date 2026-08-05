---
name: prepare-finance-task
description: Build or refresh a bounded task brief for manufacturing-finance report work before material tool use. Use when starting, resuming, or handing off inventory, migration, reconciliation, Power BI, Databricks, Genie, hierarchy, refresh, or failure-diagnosis tasks, especially when a cheaper model needs the correct context slice, tool budget, and proof requirements without rereading chat history.
---

# Prepare a Finance Task

1. Read `context/catalog.json` and
   `../finance-report-migration/references/local-model-operations.md`. Load the
   work context only when the classified workflow routes it.
2. If `context/local-context.json` exists, load only the entries needed by the
   task and approved for the resolved provider/model. Otherwise use only a
   pre-generated approved projection or installed deterministic redaction
   adapter. If neither exists, omit private values and mark dependent decisions
   `MISSING_CONTEXT`; never ask the model to redact the raw overlay.
3. Search for a compatible fresh handoff/task brief before probing tools again.
4. Classify the workflow: inventory, semantic resolution, query migration,
   model/report parity, reconciliation, refresh profiling, platform discovery,
   failure diagnosis, or handoff.
5. Fill `schemas/task-brief.schema.json` using repository facts, artifact
   evidence, and approved context. Use `MISSING_CONTEXT`, not an invented rule.
6. Select every required skill/reference, set row/byte/file/poll/time/context
   bounds, and name the deterministic proof for each material claim.
7. Hash the canonical brief and list context paths plus hashes. Keep private
   values in ignored run state; use aliases in portable output.
8. Perform no SQL, refresh, compute start, publication, schedule change, or live
   write while preparing the task.

Ask the operator only for a missing value that changes the transformation,
target, authorization, or acceptance test. Return the brief, unresolved
questions, selected workflow, next safe command, and highest permitted gate.
