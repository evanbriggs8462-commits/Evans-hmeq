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

The mandatory incident-driven guide for large remote exports is
[Large XML over SMB: mandatory operating runbook](.opencode/skills/finance-data-reliability/references/large-xml-smb-runbook.md).
It covers Python evaluation-order traps, PowerShell line-versus-byte semantics,
bounded prefix evidence, XML/regex boundaries, OneDrive staging, long-running
VPN transfers, local parsing, acceptance gates, and public-repository hygiene.
For long commands that fit inside the host limit, see
[Long-running task observability](docs/long-running-task-observability.md).
It explains the difference between elapsed time, liveness, real progress, and
durable execution.

## Safe adoption

1. Put this repository on a company-approved private Git host before adding any internal knowledge.
2. Keep credentials, real UNC paths, SAP exports, screenshots, PBIX files, proprietary schemas, hierarchy maps, and client identifiers out of Git.
3. Open the repository root in OpenCode. It discovers `AGENTS.md` and the project skill automatically. Large XML, UNC, SMB, VPN, OneDrive, killed-process, and timeout triggers route the agent to the mandatory large-file runbook before it issues another content-read or copy command.
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

The Python suite and repository-contract tests must pass in the adoption environment, including the outside-row memory regression and the large-XML runbook routing contract. The OpenCode JSON and skill structure also receive static validation. Windows PowerShell 5.1, Pester, `robocopy`, VPN, and SMB are not available in every build environment, so the PowerShell platform check must be performed on the intended workstation before production adoption. Run `Invoke-Pester` there and perform a bounded integration test with an anonymized XML file on an approved share. Also exercise `runwatch` with redirected output, Ctrl+C/CTRL+Break, a briefly locked status file, rejected mapped/sync paths, and `$LASTEXITCODE`. A mocked test does not prove real Windows console, SMB resume, timestamp, antivirus, or rename behavior.

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
