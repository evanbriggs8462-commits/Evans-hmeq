---
name: finance-report-migration
description: Inventory, reverse-engineer, migrate, reconcile, and operationalize manufacturing-finance reports across ERP or SAP-style exports, Excel/XML/Power Query M, governed Databricks data, and Power BI. Use for report recreation, spool modernization, M-to-SQL migration, PBIX/PBIP/PBIR work, DAX or relationship parity, hierarchy or ledger mapping, gross-margin and backlog analysis, refresh scheduling, migration handoffs, or when a cheaper local model needs the project context and exact workflow instead of generic coding advice.
---

# Finance Report Migration

Use this skill for the business and migration workflow. Also load the sibling
`finance-data-reliability` skill whenever the task touches files, PowerShell,
Databricks, Power BI, credentials, long-running work, reconciliation, or a live
system. This skill explains **what must be preserved**; the reliability skill
explains **how to operate safely**.

## Load the relevant context

- Always read [work context](references/work-context.md) before planning a
  finance migration task. If the ignored `context/local-context.json` exists,
  load only the fields that company policy permits sending to the configured
  model/provider. If that boundary is not approved, require a pre-generated
  approved alias/hash projection, an installed deterministic redaction adapter,
  or a genuinely local approved model. Otherwise omit the overlay and return
  `MISSING_CONTEXT`; never ask the model to redact raw private values.
- Read [migration playbook](references/migration-playbook.md) for report
  inventory, reverse engineering, M/SQL/DAX migration, PBIX/PBIP/PBIR work,
  reconciliation, deployment, or refresh-readiness tasks.
- Read [finance semantics](references/finance-semantics.md) whenever grain,
  ledger, hierarchy, account, sign, currency, FX, intercompany, blank/zero,
  effective date, or mapping logic can affect the answer.
- Read the [V7 ECC intercompany implementation brief](references/ecc-intercompany-reconciliation-v7-implementation-brief.md)
  when the task involves V7 unified SQL, ECC customer/vendor items open at a
  historical key date, BKPF/BSEG/BSID/BSAD/BSIK/BSAK, VBUND/RCOMP partner
  assignment, reciprocal D/K matching, split billing, matching coverage, or
  residual exposure. Treat it as the task-specific implementation and
  acceptance contract; do not load it for unrelated migrations.
- Read [local-model operations](references/local-model-operations.md) when
  preparing a task, choosing a model, limiting tool use, resuming prior work,
  capturing a failure, or deciding whether to escalate reasoning.
- Load every matching reference. Do not replace a missing private rule with a
  plausible guess.

## Start with a task contract

Before material execution, create or update a task brief using
`schemas/task-brief.schema.json` and `templates/task-brief.example.json`.
Resolve the following from repository evidence and available context before
asking the operator:

1. outcome and workflow type;
2. exact mode: `read-only`, `local-candidate`, `repository-publish`,
   `controlled-write`, or `high-impact`;
3. source and target aliases;
4. business grain, keys, date/as-of scope, measures, and dimensions;
5. hierarchy, ledger, currency, sign, null, and tolerance rules;
6. prohibited actions and tool budget; and
7. evidence required to call the result verified.

Ask only when a missing fact changes the transformation, target, permission,
or validation result. Do not ask for facts already established by artifacts or
approved local context.

## Execute the migration in gates

1. **Inventory** — Extract sources, Power Query M, sample-file/helper queries,
   parameters, DAX, calculated columns, relationships, roles, visuals,
   filters, bookmarks, refresh settings, and known totals. Do not begin by
   rewriting code.
2. **Reconstruct semantics** — State the grain and rules behind every material
   metric, join, hierarchy, date, sign, currency, blank, and exclusion.
3. **Map lineage** — Link each output field and measure to a source field or a
   documented derivation. Mark opaque steps and dynamic dependencies unknown.
4. **Build a candidate** — Produce the smallest reviewable SQL, M, TMDL, DAX,
   PBIR, or script change in a private/local candidate. Preserve the original.
5. **Validate independently** — Prove structural, data, semantic-model, visual,
   and operational parity with deterministic checks. A plausible model answer,
   successful save, or matching grand total is not proof.
6. **Explain differences** — Classify source snapshot, grain, join,
   transformation, hierarchy, currency, sign, filter-context, or refresh causes
   before changing logic.
7. **Promote deliberately** — Stop at the candidate unless the exact live
   target and write authority are explicit. Use the higher gates in `AGENTS.md`
   for deployment, refresh, schedule, or whole-definition changes.
8. **Handoff** — Emit a schema-valid run handoff using
   `schemas/run-handoff.schema.json`. Another model must be able to continue
   from the last verified boundary without rereading the chat.

## Required deliverables

Return the smallest set needed for the task, but never omit a required proof:

- task brief and assumptions;
- artifact inventory and dependency map;
- source-to-target field and metric mapping;
- candidate diff or generated artifact;
- reconciliation matrix with pass, fail, or inconclusive status;
- unresolved discrepancies and their evidence;
- exact next permitted action; and
- resumable handoff with paths, hashes, versions, and checks performed.

## Autonomy and interaction

- Proceed through read-only inspection and local candidate work when the task
  authorizes building or migration. Do not turn every reversible repo edit into
  a strategy discussion.
- Pause before a live external write, destructive action, permission change,
  broad refresh, schedule change, publication, or target ambiguity.
- Prefer concrete artifacts, diffs, tests, and concise findings over generic
  recommendations or long narration.
- Preserve one-for-one business parity before proposing optimization. Record
  improvements separately so modernization does not silently redefine the
  report.
- Treat expensive-model escalation as a targeted exception. First improve the
  task brief, retrieve the correct reference, and run deterministic checks.
