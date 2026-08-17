# Finance Agent Workbench

A portable knowledge and validation pack for agent-assisted finance data work with OpenCode, PowerShell, Python, SAP spool XML, Databricks, DAX Studio, Tabular Editor 2, and Power BI.

The central design decision is simple: the model may plan, invoke approved
wrappers, and interpret machine-readable receipts. Deterministic code—not model
narrative—must establish file, parsing, validation, and reconciliation truth.
The current executable code covers staging, streaming XML inspection, and
bounded liveness; several Power BI, Databricks, reconciliation, and context
workflows remain fail-closed command contracts until their approved adapters
or validators are installed.

## What is included

- `AGENTS.md` — always-loaded project operating rules.
- `.opencode/skills/finance-data-reliability/` — on-demand workflow knowledge and tool boundaries.
- `.opencode/skills/finance-report-migration/` — the sanitized work context and end-to-end report migration playbook.
- Narrow skills for task preparation, inventory, semantic resolution, query migration, reconciliation, refresh profiling, failure capture, and handoff.
- `context/catalog.json` plus an ignored `context/local-context.json` overlay — progressive context loading for lower-cost models without committing private identifiers or rules.
- `schemas/`, `templates/`, and `policies/` — task/handoff contracts, synthetic examples, tool budgets, and model-routing guidance.
- `opencode.json` — model-agnostic scout, builder, verifier, and bounded-investigator roles; the selected session or private configuration supplies the approved model.
- `scripts/Stage-Spool.ps1` — bounded, receipt-producing UNC-to-local staging.
- `src/spoolctl/` — strict streaming XML inspection and contracts.
- `src/runwatch/` — elapsed-time heartbeats and atomic, sanitized liveness status for bounded child commands.
- `tests/` — regression tests for truncation, namespaces, source mutation, unsafe paths, and other known failure modes.
- `docs/` — deeper runbooks that are loaded only when relevant.
- [Roadmap](docs/roadmap.md) — implemented capabilities, contracted workflows, remaining adapters, and promotion gates.

The mandatory incident-driven guide for large remote exports is
[Large XML over SMB: mandatory operating runbook](.opencode/skills/finance-data-reliability/references/large-xml-smb-runbook.md).
It covers Python evaluation-order traps, PowerShell line-versus-byte semantics,
bounded prefix evidence, XML/regex boundaries, OneDrive staging, long-running
VPN transfers, local parsing, acceptance gates, and public-repository hygiene.
For long commands that fit inside the host limit, see
[Long-running task observability](docs/long-running-task-observability.md).
It explains the difference between elapsed time, liveness, real progress, and
durable execution.

For service-side semantic-model work, use
[Power BI Premium workspace operations](.opencode/skills/finance-data-reliability/references/power-bi-premium-workspace-runbook.md).
It separates ordinary Power BI REST, Fabric REST, XMLA/TOM, Tabular Editor,
TMDL, Desktop, and the two Microsoft Power BI MCP servers. It also documents
permission gates, token renewal, targeted asynchronous refresh, M validation,
PBIX consequences, rollback, and sanitized receipts.

For Databricks identity, bounded inventory, Unity Catalog discovery, Genie,
and MCP selection, use
[Databricks agent access](.opencode/skills/finance-data-reliability/references/databricks-agent-access.md).
It establishes one named OAuth profile, a narrow SDK adapter, explicit
metadata/query/compute boundaries, and a stateful Genie workflow whose output
remains unverified until deterministic finance checks pass.

For report pages, visuals, blank canvas space, filters, slicers, layout, and
themes, use
[Power BI report authoring](.opencode/skills/finance-data-reliability/references/power-bi-report-authoring.md).
It covers Microsoft's preview Report Authoring skill and PBIR workflow. It is
a local candidate-and-review path, not a direct production visual-edit API;
publishing remains a separately approved whole-definition replacement.

For end-to-end legacy report recreation or migration, use
[Finance report migration](.opencode/skills/finance-report-migration/SKILL.md).
It gives the local model the stable work context, finance semantic rules,
inventory and migration workflow, positive fallbacks when a live adapter is
missing, model-routing guidance, and a resumable handoff contract. It should be
loaded with the reliability skill whenever the task touches files, Databricks,
Power BI, or a live system.

For ECC intercompany customer/vendor open-item reconstruction and reciprocal
matching, use the notebook-ready
[V7 implementation brief](.opencode/skills/finance-report-migration/references/ecc-intercompany-reconciliation-v7-implementation-brief.md).
The finance-migration skill loads it conditionally for ECC/VBUND/RCOMP work so
unrelated migration and reconciliation tasks do not pay its context cost. Its
raw file begins with `%md` and can be pasted into one Databricks Markdown cell
without editing.

## Safe adoption

1. Put this repository on a company-approved private Git host before adding any internal knowledge.
2. Keep credentials, real UNC paths, SAP exports, screenshots, PBIX files, proprietary schemas, hierarchy maps, and client identifiers out of Git.
3. Open the repository root in OpenCode. It discovers `AGENTS.md` and the project skills automatically. The context boot protocol routes finance work through `context/catalog.json`; large XML, Databricks, and Power BI triggers also load their mandatory reliability references before tool selection.
4. Merge `opencode.json` into any existing project configuration; do not overwrite provider, MCP, or organization-managed settings blindly.
5. Start with anonymized fixtures and a read-only shadow run. Promote a workflow only after its receipts and reconciliation results match the established process.

Capture a sanitized workstation profile before troubleshooting:

```powershell
./scripts/Get-EnvironmentProfile.ps1 -LocalStagingRoot 'C:\SpoolStage'
```

The profile intentionally omits usernames, computer names, physical paths, environment variables, and endpoints.

For an existing report repository, copy or submodule the complete workbench
package, not an isolated skill. The minimum coherent set is `AGENTS.md`,
`.gitignore`, `opencode.json`, `pyproject.toml`, `.opencode/skills/`, `context/`
(excluding the ignored private overlay), `policies/`, `schemas/`, `templates/`,
`docs/`, the deterministic scripts/source actually used, and their tests.
Partial copying leaves skill routes and contracts broken.

## Agent roles and model choice

- `finance-scout`: classify, prepare, and perform approved no-state metadata reads with repository edits and shell execution denied.
- `finance-build`: create an explicitly requested repo-local candidate and focused tests.
- `finance-verifier`: independently review diffs, receipts, and evidence with repository edits and shell execution denied.
- `finance-compute`: perform one explicitly invoked bounded external read/compute action through an approved adapter, with effects disclosed and shell/edit access denied.
- `finance-deep`: investigate one bounded semantic or cross-system ambiguity with no broader authority than the builder.

The checked-in roles deliberately omit `model` and provider-specific reasoning
options. Select an approved inexpensive/local model for the session or bind
role-to-model aliases in private user/organization configuration after checking
`opencode models` and `opencode debug config`. Do not commit an unverified
machine-specific provider/model ID to this portable pack. The investigator is
an escalation role, not automatic permission to use a more expensive model or
perform a live write. Model choice never replaces tests, receipts, allowlists,
or review gates.

`/validate` uses the builder role because running project tests executes code
and may create local cache files. The verifier independently reviews the diff,
schema-valid receipts, and test evidence without rerunning arbitrary code.

## Local-model workflow

When adopting the workbench—or only when the private context overlay is absent
or stale—bootstrap it first under the approved model/data boundary:

```text
/bootstrap-finance-context <approved local artifacts and scope>
```

Normal material tasks begin by preparing a bounded context capsule:

```text
/prepare-finance-task <outcome, source/target aliases, and scope>
```

Then run one exact phase:

```text
/inventory-finance-report <task brief or artifact alias>
/resolve-finance-semantics <task brief or unresolved rule>
/migrate-finance-query <task brief and query alias>
/reconcile-finance-report <task brief and baseline/candidate aliases>
/profile-finance-refresh <task brief and time window>
```

At a pause, model switch, blocker, or phase boundary:

```text
/handoff-finance-run <task brief and current evidence aliases>
```

If company policy permits an exact internal context overlay, copy
`context/local-context.example.json` to the ignored
`context/local-context.json` and populate approved aliases and rules. Never
commit that file or paste it wholesale into model context. If the resolved
configuration uses Azure or any other remote provider, loading a selected
`WORK_INTERNAL` field sends it to that provider. Load such fields only when the
exact provider/model boundary is company-approved for the data class;
otherwise require a pre-generated approved projection, an installed
deterministic redaction adapter, or a genuinely local approved model. If none
exists, omit private values and return `MISSING_CONTEXT` or
`MISSING_PREREQUISITE`; never ask the model to redact raw private values.
Missing private context blocks only conclusions or live actions that require
it; repo-local candidates continue only when the request authorizes changes.

The following Power BI and Databricks commands are **fail-closed prompt
contracts**, not executable adapters shipped by this repository. Cloning the
workbench does not make them technically read-only. Until an approved narrow
adapter is installed and validated, they must return `MISSING_PREREQUISITE`
without falling back to generic bash, raw REST, token input, or mutation-based
permission tests.

With an installed approved Power BI adapter, begin with capability discovery:

```text
/pbi-capabilities <workspace alias and semantic-model alias>
```

The intended adapter contract is read-only. It inventories the accessible target and selects
between REST, XMLA, MCP, and Desktop without taking ownership, refreshing
permissions, triggering refresh, or testing write access by mutation. It never
asks for or prints a bearer token.

With an installed approved Databricks adapter, begin with bounded metadata discovery:

```text
/dbx-capabilities profile_alias=<approved-alias> \
  workspace_path_alias=<approved-path-alias> \
  catalog_alias=<approved-catalog-alias> \
  schema_alias=<approved-schema-alias>
```

The intended adapter contract does not run SQL, return rows, export notebooks, start compute,
or change workspace/Unity Catalog state. It uses only the existing approved
authenticated adapter and returns aliases, counts, and capability evidence.

When the approved adapter and an exact curated Genie Agent are both available,
use:

```text
/dbx-genie-probe profile_alias=<approved-alias> \
  space_alias=<approved-genie-alias> \
  question_template=<approved-template> \
  check_id=<deterministic-check-id>
```

This creates task-scoped conversation state and may execute a query or consume
warehouse compute. Its result is always an `UNVERIFIED_HYPOTHESIS`; only the
separate deterministic reconciliation can promote the conclusion.

## Validation

Python:

```powershell
python -m pip install -e ".[test]"
python -m pytest
```

PowerShell, when Pester 5 is installed:

```powershell
Invoke-Pester tests/powershell
```

Or run both through:

```powershell
./scripts/Invoke-Checks.ps1
```

After a source has been staged locally, the dependency-free CLI can inspect it without installing the package:

```powershell
$env:PYTHONPATH = "$PWD\src"
python -m spoolctl inspect 'C:\SpoolStage\objects\ab\artifact.xml' `
    --row-qname '{urn:example}row' `
    --required-field '{urn:example}posting-date'
```

The parser rejects UNC paths, URI inputs, and Windows mapped network drives so an agent cannot accidentally parse the live share.

For the next bounded command that may be quiet, run it under the dependency-free
timer. Keep the status file on an approved local, non-synced fixed volume:

```powershell
$env:PYTHONPATH = "$PWD\src"
$python = (Get-Command python -ErrorAction Stop).Source
$statusName = 'xml-validation.{0}.runwatch.json' -f `
    ([guid]::NewGuid().ToString('D'))
& $python -m runwatch --heartbeat-seconds 15 `
    --status-out (Join-Path 'C:\SpoolStage\run-status' $statusName) `
    --label xml-validation -- $python 'C:\approved-project\validation.py'
$runExitCode = $LASTEXITCODE
```

The timer reports that the supervisor and direct child were observed alive; it
does not prove data progress. If the command may exceed the agent's hard limit,
run it from the approved durable terminal/job runner instead.

Default XML safety limits are 8 MiB of retained text per row, 10,000 values per row, 2,048 distinct fields per row, 256 levels of nesting, 4,096 distinct qualified names per document, 1 MiB per markup token, and 8 MiB per contiguous character-data segment. Each can be lowered or deliberately raised with a CLI option; limit failures are typed and never publish a partial output. The callback parser never constructs an XML element tree and discards non-row text immediately.

## Current validation status

The Python suite and repository-contract tests must pass in the adoption environment, including the outside-row memory regression and both runbook-routing contracts. The OpenCode JSON and skill structure also receive static validation. Windows PowerShell 5.1, Pester, `robocopy`, VPN, and SMB are not available in every build environment, so the PowerShell platform check must be performed on the intended workstation before production adoption. Run `Invoke-Pester` there and perform a bounded integration test with an anonymized XML file on an approved share. Also exercise `runwatch` with redirected output, Ctrl+C/CTRL+Break, a briefly locked status file, rejected mapped/sync paths, and `$LASTEXITCODE`. A mocked test does not prove real Windows console, SMB resume, timestamp, antivirus, or rename behavior.

No public build validates a live tenant, capacity assignment, REST scope, XMLA
setting, MCP schema, Tabular Editor edition, gateway, or service refresh. Run
the read-only capability inventory in the approved work environment before
using any live-write instruction.

## Maintenance rule

Every real failure should become three things after sanitization:

1. A short entry in the relevant runbook or failure taxonomy.
2. A minimal fixture that reproduces the behavior without business data.
3. A regression test proving the chosen response.

Do not turn raw chat transcripts into permanent context. Preserve only stable decisions, failure signatures, exact validation gates, and deterministic tools.

## Primary documentation sources

- [OpenCode project rules](https://opencode.ai/docs/rules/)
- [OpenCode agent skills](https://opencode.ai/docs/skills/)
- [OpenCode agent configuration](https://opencode.ai/docs/agents/)
- [OpenCode configuration precedence](https://opencode.ai/docs/config/)
- [Python XML security guidance](https://docs.python.org/3/library/xml.html#xml-vulnerabilities)
- [Azure Databricks managed MCP servers](https://learn.microsoft.com/en-us/azure/databricks/generative-ai/mcp/managed-mcp)
- [Azure Databricks Genie Conversation API](https://learn.microsoft.com/en-us/azure/databricks/genie-agents/conversation-api)
- [Databricks unified authentication](https://docs.databricks.com/aws/en/dev-tools/auth/unified-auth)
- [Microsoft Power BI Report Authoring skill](https://learn.microsoft.com/en-us/power-bi/developer/agentic/power-bi-report-authoring-skill-overview)
