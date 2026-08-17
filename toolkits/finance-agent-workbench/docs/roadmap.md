# Agentic Capability Roadmap

This roadmap turns the next useful agent-workbench ideas into bounded,
testable increments. It is a planning artifact, not permission to access a
tenant, run compute, publish a report, or modify a governed object.

The public repository must contain only generic contracts, synthetic fixtures,
and sanitized examples. Real aliases, identifiers, report definitions, query
text, row data, hierarchy rules, credentials, and runtime evidence belong only
in an approved private environment.

## Current baseline

The current branch has a strong reliability and safety foundation, but some
agent commands are contracts rather than executable integrations.

| Capability | Current state | Remaining gap |
|---|---|---|
| Local-model context and finance migration guidance | Guidance/contract layer implemented as a routed context catalog, public work context, ignored private overlay template, migration playbook, thin workflow skills/commands, policies, and schemas | Add deterministic brief/handoff builders, redaction, cache, and task-family eval execution |
| Large-file reliability and `runwatch` | Implemented with deterministic code and tests | Validate on the intended Windows, VPN, and SMB environment |
| Power BI capability discovery | Read-only `/pbi-capabilities` contract and runbook | Approved private adapter and live read-only validation |
| Databricks capability discovery | Bounded `/dbx-capabilities` contract and runbook | Approved private adapter, cache, and cross-platform task brief |
| Genie investigation | Bounded `/dbx-genie-probe` contract and safety rules | Executable client, private evidence package, and reconciliation integration |
| PBIR report authoring | Detailed candidate/deployment runbook | Deterministic inventory, placement, clone, binding, and validation utilities |
| Failure learning | Taxonomy plus proposed-case skill/command, schema, and synthetic example | Deterministic sanitizer/capture runner, implemented fixtures/tests, corpus, graders, and routing evidence |
| Receipts and liveness state | Tool-specific receipts, atomic `runwatch` state, and a validated handoff contract/example | Executable append-only cross-tool ledger and resume validator |
| Semantic contracts | Contract schema/example plus resolution skill/command and finance reference | Deterministic validator/linter, approved private contracts, metric-view generation, and regression fixtures |
| Workload profiling | Read-only guidance and prompt command contract | Approved Power BI/Databricks telemetry adapters and correlation runtime |
| Migration impact analysis | Not started | PBIR/TMDL/M dependencies joined to bounded Unity Catalog lineage |
| Databricks ADBC readiness | Documented externally, not checked here | Mixed ADBC/ODBC lint and staging validation before the transition |

The context pack exists because a roadmap is not runtime memory. OpenCode loads
`AGENTS.md` and selected skills; it does not automatically turn this document
or prior chat into task context. The new boot protocol uses
`context/catalog.json`, a schema-valid task brief, narrow workflow skills,
approved private context slices, and a resumable handoff so a lower-cost model
receives the relevant judgment scaffolding at execution time.

## Build order

The branch now contains thin routing skills and command contracts. Do not treat
them as executable adapters. For each phase, build the deterministic script,
sanitizer, or validator, prove it with synthetic fixtures, and only then promote
the command from fail-closed guidance to an operational workflow.

### 0. Close the baseline adoption gate

Before adding new live integrations:

- run the complete Python and PowerShell suites in the intended workstation
  environment;
- exercise anonymized SMB staging and real Windows `runwatch` cancellation,
  status, and exit-code behavior;
- prove that `/pbi-capabilities` and `/dbx-capabilities` fail closed when their
  approved adapters are missing; and
- run synthetic read-only probes before any live finance source is considered.

Acceptance requires passing receipts with no credentials or internal
identifiers, an explicit record of unavailable checks, and no live mutation.

### 1. Execute the task brief and capability snapshot

The public task-brief schema, example, context catalog, workflow routing, model
policy, tool-budget policy, and `/prepare-finance-task` command contract now
exist. The remaining work is the deterministic builder, sanitizer, cache, and
live capability-receipt integration described below.

Candidate artifacts:

```text
schemas/task-brief.schema.json
schemas/capability-snapshot.schema.json
policies/tool-budgets.json
src/finance_workbench/tasking/prepare.py
```

The current `/prepare-finance-task` is a prompt contract. Implement its wrapper
before treating its output as runtime-enforced. The wrapper should accept
approved aliases, outcome, grain, time window, tolerances, prohibited actions,
and a tool budget, then reuse fresh sanitized Power BI and Databricks capability
receipts instead of repeating probes.

Acceptance criteria:

- schema-valid input and output with stable canonical hashes;
- cache keys include adapter version, target-alias fingerprint, and expiry;
- identity, workspace, VPN, permission, or tool-version changes invalidate the
  snapshot;
- stale, truncated, or conflicting evidence returns `INCONCLUSIVE`;
- no raw platform object, token, host, path, or row reaches model context; and
- preparing a task performs no SQL, compute start, refresh, or write.

### 2. Add a shared evidence bundle and resumable run ledger

Candidate artifacts:

```text
schemas/run-report.schema.json
schemas/evidence-bundle.schema.json
schemas/run-ledger.schema.json
src/finance_workbench/evidence/
tests/python/test_evidence_ledger.py
```

The ledger should link each claim to evidence and record the task-brief hash,
adapter/tool versions, source fingerprints, bounded invocation hashes, exit
codes, validations, unresolved discrepancies, confidence class, and next
permitted step. Sensitive evidence stays in ignored private storage; the
portable receipt contains aliases, hashes, counts, and error classes only.

Acceptance criteria:

- state changes are atomic and append-only or versioned;
- interrupted work resumes from the last verified boundary;
- retryable operations carry an idempotency or replay decision;
- a lost response to a state-creating request is never blindly repeated;
- partial evidence cannot be promoted to `VERIFIED`; and
- another agent can continue without reconstructing the task from chat.

### 3. Capture failures and evaluate model routing

The `capture-agent-failure` skill/command, proposed-case schema, and synthetic
example exist. They may produce a proposal under diagnosis scope and may create
fixtures/tests only when the user explicitly asks to codify or remediate. They
do not provide an automatic sanitizer, capture runner, corpus, or eval harness.

Candidate artifacts:

```text
evals/golden/
evals/failures/
evals/routing/
policies/model-routing.json
src/finance_workbench/evals/capture.py
src/finance_workbench/evals/runner.py
```

Implement the sanitizer and runner before automatic capture. Then convert each
approved real incident into a minimal synthetic fixture, violated invariant,
expected classification, deterministic result, and implemented regression
test. Compare models by task rather than choosing one model for the entire
workbench.

Score at least:

- business and technical correctness;
- reconciliation and required-postcondition results;
- tool choice and repeated probes;
- policy or disclosure violations;
- unsupported certainty and false success;
- elapsed time, token use, and estimated cost; and
- resume quality after an interrupted run.

Models never grade themselves. Deterministic assertions decide pass/fail where
possible; model graders may add diagnostic labels but cannot override a failed
invariant.

### 4. Turn the Genie probe into an evidence investigator

Candidate artifacts:

```text
src/finance_workbench/databricks/capabilities.py
src/finance_workbench/databricks/genie_evidence.py
tests/python/test_databricks_adapters.py
```

Extend the existing contract rather than creating an unrestricted SQL tool.
Use the stateful Conversation API when follow-up history matters. A per-Agent
managed MCP call is useful for one bounded question, but it does not carry the
same conversation history into Genie.

The private adapter may retain generated SQL, result fragments, conversation
identifiers, and exact source objects only in approved local storage. The
agent-facing receipt exposes hashes, aliases, terminal state, bounds,
truncation, compute disclosure, trusted-asset indicators, and the named
deterministic check.

Acceptance criteria:

- capability discovery runs no SQL and starts no compute;
- one investigation uses one task-scoped conversation with bounded polling;
- ambiguous POST outcomes are inspected before any replay;
- row, byte, page, poll, and elapsed-time limits fail closed;
- every answer remains `UNVERIFIED_HYPOTHESIS` until an independent named
  reconciliation passes; and
- the broad Databricks SQL MCP remains disabled in the default production
  finance path.

### 5. Integrate and harden PBIR candidate patching

Candidate artifacts:

```text
src/finance_workbench/pbir/inventory.py
src/finance_workbench/pbir/layout.py
src/finance_workbench/pbir/patch.py
src/finance_workbench/pbir/validate.py
tests/fixtures/pbir/
tests/python/test_pbir_tools.py
```

Use Microsoft's first-party preview Report Authoring skill for supported PBIR
page, visual, filter, formatting, and theme changes before inventing a parallel
general editor. Use the Windows-local preview Desktop Bridge for controlled
reload, status, and screenshot checks, and the Modeling MCP only for semantic
model work. Keep custom code focused on finance-specific preflight, canonical
diffs, deterministic placement constraints, bindings, and postconditions.

The workflow stops at a private local PBIR/PBIP candidate; the existing
separate publication and whole-definition replacement gates still apply.

Acceptance criteria:

- immutable baseline manifest and canonical before/after diff;
- path-safe reads and writes confined to one candidate tree;
- deterministic placement with explicit collision and page-bound checks;
- unique identifiers and resolvable semantic bindings;
- untouched files remain byte-identical and unexplained churn fails;
- unsupported PBIR schema/version returns `MISSING_PREREQUISITE`; and
- Desktop reload/render plus independent DAX checks pass before development
  deployment is considered.

The current ignore rule for `*.Report/` also covers realistic PBIR fixture
folders. Use a neutral synthetic fixture layout or add one narrow allow
exception; do not weaken the production-report ignore boundary.

### 6. Define machine-checkable finance semantic contracts

The JSON Schema, synthetic JSON example, finance-semantics reference, and
resolution command contract exist. The validator, approved private contracts,
metric-view generator, and regression fixtures do not.

Candidate artifacts:

```text
schemas/finance-semantic-contract.schema.json
src/finance_workbench/semantics/validate.py
tests/fixtures/finance-contracts/
```

Define each metric's grain, inputs, formula, keys, join cardinality, currency
and FX date, sign convention, null/blank/zero behavior, hierarchy and effective
date rules, tolerances, synonyms, display names, formatting, and approved
source aliases. The public example must be synthetic; proprietary values live
only in a company-approved private repository.

Generate and lint candidate metric-view metadata where useful, but do not write
to Unity Catalog from this workflow. Treat Databricks agent metadata as a
version-gated candidate and do not assume its display names, formats, or
synonyms automatically propagate into Power BI.

Acceptance criteria:

- every derived metric traces to explicit source fields and rules;
- breaking changes are distinguished from additive metadata changes;
- ambiguous hierarchy, date, currency, or grain behavior fails closed; and
- fixtures cover duplicate-join amplification, trailing-minus values,
  blank-versus-zero, late-arriving records, and effective-date boundaries.

### 7. Profile Power BI and Databricks workload timing

Candidate artifacts:

```text
src/finance_workbench/workload/powerbi.py
src/finance_workbench/workload/databricks.py
src/finance_workbench/workload/profile.py
tests/fixtures/workload-profile/
```

Combine a bounded Power BI refresh-history export with approved aggregate
fields from Databricks query history and warehouse events, plus approved
aggregate evidence from the Fabric Capacity Metrics app when diagnosing Power
BI capacity pressure. Databricks `system.query.history` can separate warehouse
compute/capacity wait from SQL execution, but it cannot prove P3/Fabric
capacity queueing by itself. Normalize time zones, retain correlation
confidence, and distinguish Power BI capacity pressure, warehouse
availability, query runtime, result fetch, and semantic-model processing
before recommending schedule changes.

Acceptance criteria:

- no raw query text, result rows, user identities, hosts, or object names enter
  Git or the model context;
- extraction is time-windowed, row-bounded, and read-only;
- system-table and Power BI refresh-history access passes its own capability
  and permission gate;
- uncertain cross-system correlation is labeled `INCONCLUSIVE`;
- recommendations include expected benefit and evidence, not automatic
  schedule writes; and
- synthetic cases separate a queued refresh from a slow source query.

### 8. Build the migration impact map

Candidate artifacts:

```text
src/finance_workbench/impact/powerbi.py
src/finance_workbench/impact/unity_lineage.py
src/finance_workbench/impact/graph.py
tests/fixtures/impact-map/
```

Join static PBIR, TMDL, DAX, and bounded M dependencies with approved Unity
Catalog table/column lineage to answer what could break when a table, column,
measure, hierarchy, or relationship changes. Use aliases in portable output.
Dynamic SQL, opaque custom connectors, and incomplete lineage must remain
explicit unknowns.

Acceptance criteria:

- known table, column, measure, hierarchy, relationship, page, and visual edges
  are covered by fixtures;
- cycles and ambiguous references are represented rather than flattened away;
- discovery is bounded to approved seeds and never crawls the full catalog;
- absence of a lineage edge is not treated as proof of no dependency; and
- the default output is a read-only change-impact report, not a lineage write.

## Immediate compatibility check: ADBC

Ahead of the planned phased 2026 Power BI transition, add a read-only M-source
lint that identifies mixed Databricks ODBC and ADBC connections inside one
semantic model. Treat `Implementation="2.0"` as ADBC and `"1.0"` as ODBC;
flag a missing implementation value as environment-dependent rather than
guessing. The lint should report locations and migration readiness; it must
not rewrite M or change credentials. Test development and staging models first,
and preserve the current source of truth and rollback path.

## Skill distribution

This repository currently uses `.opencode/skills` as its canonical copy;
OpenCode also recognizes other supported skill locations. Genie Code does not
consume the repository copy automatically: workspace or user skills must be
placed under its `.assistant/skills` paths. If an approved runtime needs the
same skill, generate a mirror with a reviewed `scripts/sync_skills.py` rather
than editing two copies by hand. Generated copies must be checksum-equivalent,
contain no private aliases or credentials, and must never be uploaded to a
workspace automatically.

## Promotion gates

Reuse the gates in [Agent Operating Model](agent-operating-model.md):

1. exact scope, bounds, receipts, and failure plan;
2. synthetic or approved read-only execution;
3. private candidate with canonical diff and rollback;
4. explicit authorization for one exact controlled write; and
5. separate confirmation for publication, whole-definition replacement,
   compute/job/schedule changes, or shared production impact.

Every increment requires synthetic negative tests, sanitizer and identifier
scans, machine-readable receipts, an explicit `INCONCLUSIVE` path, and a list
of checks not performed.

## Primary sources

Documentation was rechecked on 2026-08-05. Preview behavior and endpoints must
be revalidated before implementation.

- [OpenCode Agent Skills](https://opencode.ai/docs/skills/)
- [Testing Agent Skills Systematically with Evals](https://developers.openai.com/blog/eval-skills)
- [Databricks Current User API](https://docs.databricks.com/api/workspace/currentuser/me)
- [Databricks SQL Warehouses list API](https://docs.databricks.com/api/workspace/warehouses/list)
- [Databricks Workspace list API](https://docs.databricks.com/api/workspace/workspace/list)
- [Databricks Genie Agent managed MCP](https://docs.databricks.com/aws/en/agents/mcp-tools/genie-agent)
- [Databricks Genie Agents API](https://docs.databricks.com/aws/en/genie-agents/conversation-api)
- [Databricks managed MCP servers](https://docs.databricks.com/aws/en/agents/mcp-tools/managed-mcp)
- [Databricks SQL MCP](https://docs.databricks.com/aws/en/agents/mcp-tools/databricks-sql)
- [Databricks metric views](https://docs.databricks.com/aws/en/uc-semantics/metric-views/)
- [Databricks metric-view agent metadata](https://docs.databricks.com/aws/en/uc-semantics/agent-metadata)
- [Databricks query-history system table](https://docs.databricks.com/aws/en/admin/system-tables/query-history)
- [Unity Catalog lineage](https://docs.databricks.com/aws/en/data-governance/unity-catalog/data-lineage)
- [Genie Code skills](https://docs.databricks.com/aws/en/genie-code/skills)
- [Power BI enhanced report format](https://learn.microsoft.com/en-us/power-bi/developer/embedded/projects-enhanced-report-format)
- [Power BI Report Authoring skill](https://learn.microsoft.com/en-us/power-bi/developer/agentic/power-bi-report-authoring-skill-overview)
- [Power BI Desktop Bridge](https://learn.microsoft.com/en-us/power-bi/developer/agentic/power-bi-desktop-bridge-overview)
- [Power BI MCP servers](https://learn.microsoft.com/en-us/power-bi/developer/mcp/mcp-servers-overview)
- [Power BI Modeling MCP repository](https://github.com/microsoft/powerbi-modeling-mcp)
- [Fabric Capacity Metrics app](https://learn.microsoft.com/en-us/fabric/enterprise/metrics-app)
- [Power BI Databricks ADBC guidance](https://learn.microsoft.com/en-us/azure/databricks/partners/bi/power-bi/adbc)
- [Microsoft ADBC transition timeline](https://learn.microsoft.com/en-us/power-query/transition-to-adbc)
