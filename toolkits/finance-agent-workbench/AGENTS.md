# Finance Agent Workbench

Use this repository to build repeatable, evidence-backed automation for large finance data exports, file-share staging, Python inspection, Databricks reconciliation, and Power BI semantic-model work.

## Context boot protocol

For every material finance task:

1. Classify the request as context bootstrap, task preparation, inventory,
   semantic resolution, query migration, model/report parity, reconciliation,
   refresh profiling, platform discovery, failure diagnosis, or handoff.
2. Read the narrow workflow skill and references named by
   `context/catalog.json`. Load `finance-report-migration` and its work context
   only for report inventory, migration, semantic, parity, reconciliation, or
   refresh work—not for unrelated platform discovery or failure diagnosis.
3. Build or reuse a task brief conforming to
   `schemas/task-brief.schema.json` before broad tool use. Reuse fresh
   capability receipts and prior handoffs instead of rediscovering the same
   environment.
4. If the ignored `context/local-context.json` exists, load only fields required
   by the task and approved for the configured model/provider. Loading a field
   into OpenCode context transmits it to that provider unless the model is
   genuinely local. If that boundary is not approved, use only a pre-generated
   approved projection or an installed deterministic redaction adapter. If
   neither exists, omit the private values and mark dependent conclusions
   `MISSING_CONTEXT` or `MISSING_PREREQUISITE`; never ask the model to redact
   raw private values. Never invent a metric, ledger equivalence, hierarchy
   edge, source mapping, join key, effective date, sign, FX rule, or tolerance.
5. Load every reference required by the selected workflow, but do not flood the
   model with unrelated runbooks.
6. Finish each material phase with a handoff conforming to
   `schemas/run-handoff.schema.json` so another model can resume without the
   chat transcript.

The durable context is the combination of routing, references, private overlay,
schemas, artifacts, receipts, and tests. A README, roadmap, or long prompt alone
is not runtime memory.

## Required behavior

1. Act as an orchestrator. Prefer versioned scripts, tests, and narrow wrappers over improvised shell commands. If an operation will recur, make it deterministic and parameterized.
2. Default external systems and source data to read-only. A request to diagnose, inspect, explain, plan, or reconcile does not authorize a write.
3. Separate the layers:
   - Use PowerShell to discover, preflight, and stage remote files locally.
   - Use streaming Python to inspect or parse large XML and other semi-structured data.
   - Use read-only SQL for Databricks reconciliation.
   - Use the appropriate Power BI host or external tool within its documented boundary.
4. Never parse a large file repeatedly across a VPN or network share. Stage it once into a unique local run directory, verify it, and operate on the local copy.
5. Never place secrets, tokens, credentials, raw source data, internal hostnames, real network paths, account identifiers, or client-specific values in Git. Use placeholders, environment variables, ignored local configuration, and synthetic fixtures.
6. Do not suppress errors or retry indefinitely. Classify the failure, use bounded retries only for a demonstrated transient condition, and preserve a sanitized receipt.
7. Do not claim success from a zero exit code alone. Validate the intended postcondition and record the evidence.

## Authorization by effect

Interpret authorization by the effect of the action:

- **Local read:** inspect repository files and approved local artifacts.
- **Repo-local candidate:** when the user asks to build, fix, change, refactor,
  migrate, or implement, create the scoped local patch, synthetic fixtures, and
  relevant tests without treating each reversible edit as a live-system write.
- **External read or compute:** use only the approved bounded adapter and
  disclose query, refresh, Genie, or warehouse-compute effects.
- **Repository publish:** an explicit request to push authorizes only the exact
  repository and branch; it does not authorize merge, force-push, deletion, or
  any business-system mutation.
- **Live controlled/high-impact write:** apply the exact gates below.

MISSING_PREREQUISITE blocks only the exact unavailable action. When the request
authorizes build/change work, continue safe repo-local candidates, synthetic
fixtures, tests, documentation, dry runs, and a resumable handoff. For
diagnosis/review scope, keep the fallback non-mutating. Never fake missing
evidence or broaden authority to work around the block.

## Large remote file hard stops

For any large XML, SAP spool export, UNC path, mapped network drive, VPN/SMB
transfer, or killed/timed-out file command, read
`.opencode/skills/finance-data-reliability/references/large-xml-smb-runbook.md`
before issuing another content-reading or copy command.

- Metadata and bounded prefixes do not prove content validity; never load an
  unbounded export into memory or validate XML with regex.
- Stage once through `scripts/Stage-Spool.ps1` to an approved local fixed volume
  outside sync/network roots, then stream-parse only the finalized artifact.
- Use an approved durable runner when the transfer may exceed the host timeout,
  and capture the native numeric exit code plus the sanitized receipt.

## Long-running command observability

For a bounded quiet command, read
`docs/long-running-task-observability.md`. Use `runwatch` only when the child
fits inside the host limit: heartbeat is liveness, not progress, and cannot
make work durable or extend a timeout. Poll the exact service request ID for a
remote operation, keep local status ignored, and apply normal approval gates.

## Skill routing

For report recreation, reverse engineering, M/SQL/DAX migration, finance
semantics, hierarchy work, reconciliation, report parity, or refresh profiling,
read `.opencode/skills/finance-report-migration/SKILL.md` and the narrow skill
selected in `context/catalog.json`.

For file staging, XML inspection, Databricks access/reconciliation, or Power BI
work, also read `.opencode/skills/finance-data-reliability/SKILL.md` and every
reference it routes for the task. When more than one trigger matches, load all
matching references. The large-XML/SMB runbook is mandatory before retrying a
failed or timed-out remote content operation. The Databricks access runbook is
mandatory before authentication, CLI/SDK inventory, Genie, or Databricks MCP
work. The Premium-workspace runbook is mandatory for Power BI REST, Fabric
REST, XMLA, service-side Tabular Editor or TMDL View, Power BI MCP,
published-model, enhanced-refresh, refresh-history, or expiring-token work.
The report-authoring runbook is mandatory for PBIP/PBIR pages, visuals, layout,
Desktop Bridge, or report-definition retrieval/replacement.

## Change gates

- **Read-only:** Inspect files, metadata, schemas, query results, logs, and generated receipts. Proceed when within the user's stated scope.
- **Candidate change:** Produce a patch, script, dry run, or local generated artifact. Do not apply it to a live model or remote system.
- **Controlled write:** Require explicit authorization, an exact target, a backup or rollback path, and validation before writing to a semantic model, remote share, Databricks object, schedule, or shared configuration.
- **High-impact write:** Require a separate explicit confirmation before publish, overwrite, delete, whole-definition replacement, ownership takeover, permission/gateway/security changes, broad refresh or cancellation, table/schema/job changes, or any production-wide operation. Stop if the target is ambiguous.

## Power BI boundaries

- Treat DAX Studio as a query, inspection, test, and performance-analysis tool; do not present it as a PBIX or Power Query editor.
- Treat Tabular Editor 2/XMLA/TOM as semantic-model metadata tooling; a connected service save is an immediate live write, and stored M is not evaluated M.
- External processing is unsupported against a model loaded in Desktop; separately authorized service XMLA/TOM/TMSL or enhanced REST processing is a different boundary.
- Use Desktop/PBIP/PBIR/report-authoring tools for report pages and Power Query. Whole-definition publication remains a high-impact replacement with baseline, render, validation, and rollback gates.

## Databricks access boundaries

- `/dbx-capabilities` and `/dbx-genie-probe` are fail-closed contracts until an approved narrow adapter exists; never substitute token input, raw REST, or generic shell access.
- Visibility is not approval or query/write authority. Listing state must not start compute; queries, Genie, jobs, and warehouse starts are distinct disclosed effects.
- Genie output is an unverified hypothesis until independent finance checks pass. Keep the broad read/write Databricks SQL MCP disabled for the default production path.

## Evidence and reporting

Each material run must create or return a sanitized receipt containing, as applicable: run ID, UTC timestamps, tool versions, operation, read/write mode, sanitized input identifiers, byte counts, hashes, row counts, date bounds, schema fingerprints, query IDs or hashes, validation checks, warnings, exit code or termination signal, and output identifiers. Exclude credentials, raw records, full internal paths, and sensitive query text.

Label conclusions as **observed**, **inferred**, or **verified**. If validation cannot be completed, say what remains unverified and stop before any dependent write.

## Model controls

- The checked-in roles are model-agnostic: scout, builder, verifier, bounded external compute, and bounded investigator. The approved session or private configuration selects the model.
- Use the least expensive approved model that passes the task-family evals. Escalate only one bounded ambiguity or failed invariant at a time.
- The scout and verifier cannot edit or execute shell commands. External compute is a separate explicitly invoked role with disclosed effects. The investigator receives no broader authority than the builder, and no role gains live-system authority from model choice.
- Reasoning settings never replace deterministic checks, tests, receipts, or approval gates.
