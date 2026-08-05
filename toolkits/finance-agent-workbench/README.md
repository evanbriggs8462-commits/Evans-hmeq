# Finance Agent Workbench

A portable knowledge and validation pack for agent-assisted finance data work with OpenCode, PowerShell, Python, SAP spool XML, Databricks, DAX Studio, Tabular Editor 2, and Power BI.

The central design decision is simple: the model may plan, invoke approved wrappers, and interpret machine-readable receipts. Deterministic code copies files, parses XML, validates outputs, and performs reconciliations. The model never gets to infer success from a plausible-looking console message.

## What is included

- `AGENTS.md` — always-loaded project operating rules.
- `.opencode/skills/finance-data-reliability/` — on-demand workflow knowledge and tool boundaries.
- `opencode.json` — explicit GPT-5.3-Codex agents with medium and high reasoning profiles.
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

## Safe adoption

1. Put this repository on a company-approved private Git host before adding any internal knowledge.
2. Keep credentials, real UNC paths, SAP exports, screenshots, PBIX files, proprietary schemas, hierarchy maps, and client identifiers out of Git.
3. Open the repository root in OpenCode. It discovers `AGENTS.md` and the project skill automatically. Large XML, UNC, SMB, VPN, OneDrive, killed-process, and timeout triggers route to the mandatory large-file runbook. Premium/Fabric workspace, REST, XMLA, MCP, service TMDL, enhanced-refresh, and token triggers route to the Power BI runbook before tool selection.
4. Merge `opencode.json` into any existing project configuration; do not overwrite provider, MCP, or organization-managed settings blindly.
5. Start with anonymized fixtures and a read-only shadow run. Promote a workflow only after its receipts and reconciliation results match the established process.

Capture a sanitized workstation profile before troubleshooting:

```powershell
./scripts/Get-EnvironmentProfile.ps1 -LocalStagingRoot 'C:\SpoolStage'
```

The profile intentionally omits usernames, computer names, physical paths, environment variables, and endpoints.

For an existing report repository, copy or submodule the `.opencode/skills/finance-data-reliability` folder, merge the relevant `AGENTS.md` rules, and bring over only the deterministic scripts actually used by that report.

## Agent profiles

- `finance-build`: medium reasoning for ordinary implementation and diagnosis.
- `finance-deep`: high reasoning for schema drift, unexplained reconciliation differences, or cross-system failures.

Build/Plan controls tool permissions. It is separate from reasoning effort. Do not use high or xhigh reasoning as a substitute for tests, receipts, allowlists, or review gates.

For an existing authenticated Power BI setup, begin with capability discovery:

```text
/pbi-capabilities <workspace alias and semantic-model alias>
```

This command is read-only. It inventories the accessible target and selects
between REST, XMLA, MCP, and Desktop without taking ownership, refreshing
permissions, triggering refresh, or testing write access by mutation. It never
asks for or prints a bearer token.

For an approved Databricks environment, begin with bounded metadata discovery:

```text
/dbx-capabilities profile_alias=<approved-alias> \
  workspace_path_alias=<approved-path-alias> \
  catalog_alias=<approved-catalog-alias> \
  schema_alias=<approved-schema-alias>
```

This command does not run SQL, return rows, export notebooks, start compute,
or change workspace/Unity Catalog state. It uses only the existing approved
authenticated adapter and returns aliases, counts, and capability evidence.

When an exact curated Genie Agent is approved for an investigation, use:

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
- [GPT-5.3-Codex model capabilities](https://developers.openai.com/api/docs/models/gpt-5.3-codex)
- [Python XML security guidance](https://docs.python.org/3/library/xml.html#xml-vulnerabilities)
- [Azure Databricks managed MCP servers](https://learn.microsoft.com/en-us/azure/databricks/generative-ai/mcp/managed-mcp)
- [Azure Databricks Genie Conversation API](https://learn.microsoft.com/en-us/azure/databricks/genie-agents/conversation-api)
- [Databricks unified authentication](https://docs.databricks.com/aws/en/dev-tools/auth/unified-auth)
- [Microsoft Power BI Report Authoring skill](https://learn.microsoft.com/en-us/power-bi/developer/agentic/power-bi-report-authoring-skill-overview)
