---
name: handoff-finance-run
description: Package a finance-agent task so another local or lower-cost model can resume without reconstructing the conversation. Use at a pause, model switch, context limit, blocker, end of a migration phase, failed tool run, or before handing work to a reviewer; emit evidence-linked state, candidate hashes, missing context, next permitted action, and exact resume instructions.
---

# Handoff a Finance Run

1. Load the task brief and
   `../finance-report-migration/references/local-model-operations.md`.
2. Validate against `schemas/run-handoff.schema.json` and use
   `templates/run-handoff.example.json` as shape guidance.
3. Record context/artifact/tool hashes, stages completed, last verified
   boundary, observed/inferred/verified claims, checks, candidate state,
   unresolved discrepancies, blockers, and highest permitted gate.
4. State the exact next safe action and exact skill/command required to resume.
5. Use aliases in portable output; keep private values and sensitive evidence
   only in ignored approved local storage.
6. Never report `passed` when the available evidence supports only accepted,
   persisted, partial, failed, or inconclusive.
