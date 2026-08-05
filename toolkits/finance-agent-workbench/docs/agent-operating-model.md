# Agent Operating Model

## Outcome

Use the model to plan, classify, and orchestrate; use deterministic code and independent checks to establish truth. The goal is not to eliminate every failure. It is to make failures bounded, diagnosable, recoverable, and unable to silently corrupt a reconciliation or semantic model.

## Division of responsibility

| Layer | Primary responsibility | Trust boundary |
|---|---|---|
| Agent | Interpret intent, choose the workflow, propose diffs, call wrappers, classify evidence, explain results | Never treat its own narrative as validation |
| PowerShell | Preflight remote access, select an exact file, stage it locally, manage processes, and emit transport evidence | Do not parse large remote exports through object pipelines |
| Python | Stream-parse local semi-structured data, normalize types under an explicit contract, and produce bounded summaries | Do not load unbounded exports into memory or logs |
| Databricks SQL | Read the governed target and calculate reproducible comparison evidence | Read-only unless a separate write is expressly authorized |
| DAX Studio | Query, inspect, test, and analyze DAX/model behavior | Not a PBIX or Power Query editor |
| Tabular Editor 2/TOM | Inspect and edit supported semantic-model metadata | Metadata writes do not prove validity, M execution, refresh, save, or publish |
| Power BI Desktop/service | Evaluate Power Query, perform supported refresh/processing, save, and publish through supported workflows | Live artifact operations require explicit gates and postcondition checks |

## Decision gates

### Gate 0 — Scope and classification

Proceed only after identifying:

- the requested outcome and whether the user asked to diagnose, plan, or change;
- source, target, environment, and exact artifact identity;
- the comparison grain, date scope, measures, and tolerance where reconciliation is involved;
- the matching skill references;
- the highest-impact operation that might be required.

Stay read-only when the request is diagnostic or the target is ambiguous.

### Gate 1 — Evidence plan

Before material execution, state:

- known facts, assumptions, and unknowns;
- the smallest operation that can test each important assumption;
- expected postconditions and failure signals;
- time, memory, network, and output bounds;
- the receipt fields that will prove the result.

Prefer a metadata-only preflight and synthetic/local fixture before touching a large remote input.

### Gate 2 — Read-only execution

The agent may perform scoped inspection and testing, stage a source into a unique local run directory, parse the verified local copy, run approved read-only queries, and create local evidence artifacts. These actions must not mutate the source, shared model, remote configuration, governed table, job, schedule, or published report.

Stop at this gate when the user asked only for diagnosis, review, explanation, or a plan.

### Gate 3 — Candidate change

Produce a minimal patch or metadata diff and its validation/rollback plan. Validate it offline or against a disposable fixture where possible. Show:

- exact objects affected;
- before/after fingerprints or canonical diff;
- tests and expected results;
- unsupported or unvalidated portions;
- backup and rollback mechanism.

A candidate is not permission to apply it to a live target.

### Gate 4 — Controlled write

Require explicit authorization for the exact target immediately before any live metadata write, remote file write, shared configuration edit, or Databricks mutation. Reconfirm target identity, backup, rollback, and validation capability. Apply one bounded change and then perform an independent round-trip check.

If any precondition changes between approval and execution, stop and request a new decision.

### Gate 5 — High-impact action

Use a separate confirmation for publish, overwrite, delete, refresh with broad operational impact, table/schema/job/schedule/security changes, or a change that affects multiple consumers. State blast radius and recovery steps plainly. Never bundle this approval into an earlier diagnostic or metadata-write approval.

## Validation pipeline

Use the pipeline in order. Preserve the receipt at each boundary so a later failure does not erase earlier evidence.

1. **Intent contract** — Define desired outcome, invariants, scope, grain, time window, tolerances, and prohibited operations.
2. **Environment proof** — Record effective non-secret configuration, executable/tool versions, permissions, target identity, architecture, and runtime limits.
3. **Source stability** — Confirm the producer completed, select one exact input, and observe stable metadata or an authoritative completion marker.
4. **Transport proof** — Copy to a unique `.part` path with bounded retry behavior; finalize atomically only after size/integrity checks pass.
5. **Structural proof** — Verify file type, encoding, XML well-formedness, namespace/schema fingerprint, required fields, and parser counters.
6. **Semantic proof** — Parse dates and financial values with explicit formats, decimal rules, null behavior, currency/sign policy, and rejected-record counts.
7. **Target proof** — Record the governed object and available snapshot/version/time; hash the deterministic read-only query.
8. **Reconciliation proof** — Compare shape, global totals, grouped totals, duplicates/nulls, and finally bounded key-level exceptions.
9. **Candidate proof** — Produce a minimal diff and show that offline/static tests pass. Keep limitations explicit.
10. **Mutation proof** — After authorization, apply the bounded change, reconnect/reread, and compare persisted state with the candidate.
11. **Behavioral proof** — Execute independent assertions in the supported host. For M, evaluate and refresh through Power BI Desktop or another supported Power Query host; a TOM write is insufficient.
12. **Artifact proof** — Reopen the saved artifact and repeat critical assertions before publish or replacement.
13. **Receipt and disposition** — Mark the run passed, failed, or inconclusive; record warnings, remaining hypotheses, outputs, and rollback status.

## Evidence receipts

Store one structured receipt per run. JSON is preferred for machine use, with an optional concise Markdown summary. Use relative or sanitized identifiers rather than internal paths.

Minimum shape:

```json
{
  "run_id": "generated-identifier",
  "started_utc": "ISO-8601 timestamp",
  "finished_utc": "ISO-8601 timestamp",
  "operation": "stage|inspect|reconcile|model-change",
  "mode": "read-only|candidate|controlled-write",
  "tools": [{"name": "tool", "version": "version"}],
  "inputs": [{"id": "sanitized-id", "bytes": 0, "sha256": "hash-or-null"}],
  "contract_hash": "hash",
  "checks": [{"name": "check", "status": "passed|failed|inconclusive", "observed": "bounded-summary"}],
  "outputs": [{"id": "sanitized-id", "sha256": "hash-or-null"}],
  "termination": {"exit_code": 0, "signal": null},
  "warnings": [],
  "status": "passed|failed|inconclusive"
}
```

Never include secrets, authorization headers, raw records, full internal paths, hostnames, account identifiers, sensitive SQL, or unbounded stdout/stderr. If a sensitive value is needed to correlate runs, store a salted or environment-scoped fingerprint outside Git.

## Deterministic-wrapper contract

Every maintained wrapper should:

- accept typed, explicit parameters and reject ambiguous wildcards;
- support a read-only or dry-run mode where mutation is possible;
- set bounded timeout, retries, memory/output behavior, and cancellation handling;
- emit structured progress separately from result data;
- return meaningful exit codes and preserve a sanitized stderr tail;
- be idempotent or use unique run IDs plus atomic finalization;
- assert postconditions rather than infer success from command completion;
- produce a receipt compatible with the run model;
- have synthetic tests for success, partial input, lock/timeout, malformed XML, schema drift, and duplicate replay where relevant.

The agent may generate an exploratory command to learn a bounded fact. Once the operation becomes part of the workflow, move it into a reviewed wrapper and test it.

## Power BI-specific control

Keep four claims distinct:

1. **Metadata was accepted:** the TOM write returned successfully.
2. **Metadata persisted:** reconnecting shows the intended canonical diff.
3. **Model behavior is valid:** DAX assertions and dependency checks pass.
4. **Data acquisition is valid:** Power Query evaluates and the expected schema/data checks pass in a supported host.

Power BI Desktop from June 2025 supports all TOM metadata write operations, while external processing commands remain forbidden. Tabular Editor 2 can store M partition expressions but cannot execute or validate M or schema-check the evaluated partition. Therefore, never collapse these four claims into “the report is fixed.”

## Reconciliation-specific control

Use exact row/key comparisons where the contract permits. For financial values, use explicit decimal precision plus documented absolute/relative tolerances. Apply tolerances at the declared comparison stage, not opportunistically after observing differences. Treat changing snapshots, unknown hierarchy versions, or unresolved currency/date rules as inconclusive rather than passed or failed transformation logic.

## Reasoning and orchestration controls

- Use **medium reasoning** for known scripts, routine inspection, standard XML failure classes, ordinary DAX assertions, and established reconciliation contracts.
- Use **high reasoning** for ambiguous schema drift, multiple plausible failure layers, complex filter context, hierarchy/grain ambiguity, date/currency interactions, or a risky candidate change.
- Use a second independent validation path for high-impact changes when practical.
- Treat **Plan/Build** as an orchestration and tool-permission choice. It does not set reasoning effort.
- Do not use higher reasoning as compensation for missing evidence, unsupported tooling, broad permissions, or an absent rollback plan.

## Stop and escalate

Stop before mutation when the exact target, authorization, backup, or validation path is missing. Stop during execution when integrity changes, retries are exhausted, a security control intervenes, snapshots cannot be aligned, or a postcondition fails. Preserve the receipt, explain the last verified boundary, and propose the smallest next diagnostic or recovery action.

Never work around permissions, disable security controls, suppress a failing check, modify data to force agreement, or report “done” when only metadata or command completion has been observed.
