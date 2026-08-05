# Finance Agent Workbench

Use this repository to build repeatable, evidence-backed automation for large finance data exports, file-share staging, Python inspection, Databricks reconciliation, and Power BI semantic-model work.

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

## Large remote file hard stops

For any large XML, SAP spool export, UNC path, mapped network drive, VPN/SMB
transfer, or killed/timed-out file command, read
`.opencode/skills/finance-data-reliability/references/large-xml-smb-runbook.md`
before issuing another content-reading or copy command.

- Metadata access is not content validation. `Test-Path` and `Get-Item` can
  establish visibility, size, and timestamps only.
- Never use an expression that loads the complete file before slicing it,
  including `Path.read_bytes()[:N]`, `ReadAllBytes()`, `Get-Content -Raw`,
  `[xml](Get-Content ...)`, or `ElementTree.parse()` on a multi-gigabyte input.
- `Get-Content -TotalCount N` counts text lines, not bytes, XML elements, or
  business records. It is not a bounded-byte probe and must not be used to
  inspect a large XML export.
- Never validate XML with regular expressions. A bounded prefix can support an
  explicitly labeled encoding or schema hypothesis only; it cannot prove EOF,
  namespaces, row count, required fields, or business semantics.
- "Local" means an approved, ready fixed volume outside OneDrive and every
  other sync root, with no reparse-point ancestor and enough free capacity.
  A directory underneath the current workspace is not automatically an
  acceptable staging destination.
- Use `scripts/Stage-Spool.ps1` for the network-to-local boundary. Do not
  manually substitute `Copy-Item`, a byte loop, an ad hoc Python copy, or a
  newly created `local_staging` directory.
- Do not keep a multi-gigabyte VPN copy inside an interactive agent shell whose
  wall-clock limit is shorter than the expected transfer. Use an approved
  terminal or job runner, preserve restartable `.part` state, and return the
  sanitized receipt to the agent.
- In PowerShell, `$?` is the last pipeline-success indicator, is independent
  of a cmdlet's Boolean output, and is overwritten by the next pipeline. It is
  not the value emitted by `Test-Path` and never replaces the numeric
  `$LASTEXITCODE` captured immediately after a native process. Branch directly
  on `if (Test-Path -LiteralPath $path -ErrorAction Stop) { ... }`.

## Long-running command observability

For a bounded noninteractive command that may be quiet for 30 seconds or more,
read `docs/long-running-task-observability.md`. When the command is proven to
fit inside the host's hard wall-clock limit, invoke it through `runwatch` so a
person receives a sanitized monotonic timer and can poll an atomic local status
file.

- A heartbeat proves only that the attached supervisor observed the direct
  child had not exited at that instant. It does not prove bytes, rows, or
  business work are progressing. Treat it as liveness evidence only.
- A local heartbeat also does not prove a Power BI service refresh is making
  progress. Only polling the exact service request ID establishes its state.
- `runwatch` cannot extend a hard host timeout or make a child durable. If the
  expected duration may exceed the host limit, use the approved external
  terminal or job runner and return its receipt.
- Keep status on an approved local fixed volume outside network and sync roots.
  Never commit runtime status, child output, commands, arguments, or paths.
- The child inherits stdout and stderr. Keep stdout machine-readable, expect
  heartbeat and child diagnostics to interleave on stderr, and poll the JSON
  status for machine decisions.
- `runwatch` is a general command launcher, not a permission bypass. Apply the
  existing command approval and write gates to the exact child invocation.

## Skill routing

For file staging, XML inspection, Databricks reconciliation, or Power BI work, read `.opencode/skills/finance-data-reliability/SKILL.md` and every reference it routes for the task. When more than one trigger matches, load all matching references. The large-XML/SMB runbook is mandatory before retrying a failed or timed-out remote content operation. The Premium-workspace runbook is mandatory for Power BI REST, Fabric REST, XMLA, service-side Tabular Editor or TMDL View, Power BI MCP, published-model, enhanced-refresh, refresh-history, or expiring-token work.

## Change gates

- **Read-only:** Inspect files, metadata, schemas, query results, logs, and generated receipts. Proceed when within the user's stated scope.
- **Candidate change:** Produce a patch, script, dry run, or local generated artifact. Do not apply it to a live model or remote system.
- **Controlled write:** Require explicit authorization, an exact target, a backup or rollback path, and validation before writing to a semantic model, remote share, Databricks object, schedule, or shared configuration.
- **High-impact write:** Require a separate explicit confirmation before publish, overwrite, delete, whole-definition replacement, ownership takeover, permission/gateway/security changes, broad refresh or cancellation, table/schema/job changes, or any production-wide operation. Stop if the target is ambiguous.

## Power BI boundaries

- Treat DAX Studio as a query, inspection, test, and performance-analysis tool; do not present it as a PBIX or Power Query editor.
- Use Power BI REST or the remote query MCP for supported discovery, refresh orchestration, history, and bounded query operations. Use XMLA/TOM through Tabular Editor 2 or the local Modeling MCP for published semantic-model metadata. Use Desktop/PBIP for report pages, visuals, layout, and local Power Query authoring.
- Treat Tabular Editor 2 as a TOM semantic-model metadata editor. A save to a service model opened through XMLA is an immediate live shared-model write, not a local candidate waiting for publish.
- External processing commands remain unsupported against a model loaded in Power BI Desktop. Do not generalize that Desktop restriction to a capacity-backed service model: authorized service XMLA/TOM/TMSL and enhanced REST refresh can process published semantic models.
- Build supports external query/read scenarios; model Write is required for XMLA metadata mutation and is normally inherited by workspace Contributor, Member, and Admin roles. Neither proves OAuth scope, tenant settings, capacity XMLA Read Write, ownership, gateway access, or model compatibility.
- Tabular Editor 2 can write an M partition expression as metadata, but it cannot execute or validate Power Query M or schema-check the evaluated partition. Validate M in Desktop/test before promotion or through a separately authorized service refresh using the service credentials and gateway.
- Preserve the original PBIX and a private canonical metadata baseline before the first XMLA write to a Desktop-authored published model. An XMLA write can make that semantic model unavailable for PBIX download.

## Evidence and reporting

Each material run must create or return a sanitized receipt containing, as applicable: run ID, UTC timestamps, tool versions, operation, read/write mode, sanitized input identifiers, byte counts, hashes, row counts, date bounds, schema fingerprints, query IDs or hashes, validation checks, warnings, exit code or termination signal, and output identifiers. Exclude credentials, raw records, full internal paths, and sensitive query text.

Label conclusions as **observed**, **inferred**, or **verified**. If validation cannot be completed, say what remains unverified and stop before any dependent write.

## Model controls

- Use medium reasoning for routine implementation, inspection, and known failure patterns.
- Use high reasoning for ambiguous schema drift, unexplained reconciliation differences, cross-system date/currency/grain issues, or risky model changes.
- Plan/Build controls orchestration and tool permissions; it is separate from reasoning effort.
- Higher reasoning never replaces deterministic checks, tests, receipts, or approval gates.
