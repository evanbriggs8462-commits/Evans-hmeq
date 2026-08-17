# Operating Lower-Cost Local Models Reliably

## Objective

Strengthen a less-expensive model with better context, narrower decisions, and
deterministic evidence. Do not try to compensate by loading every runbook into
every prompt or by escalating every task to the most expensive model.

## Progressive context layers

Load context in this order:

1. **Always-loaded kernel:** `AGENTS.md` defines scope, evidence, autonomy, and
   write gates.
2. **Task brief:** one bounded statement of outcome, targets, semantics,
   prohibitions, tool budget, and proof.
3. **Workflow skill:** exact steps and outputs for inventory, migration,
   reconciliation, authoring, investigation, or failure diagnosis.
4. **Triggered references:** only the domain and tool details relevant to the
   current branch.
5. **Private context slice:** only approved aliases/rules required by this
   task, retrieved from ignored local context.
6. **Evidence and handoff:** receipts and resume state, not the whole chat.

Avoid a giant permanent prompt. It raises token cost, hides important rules,
and makes weaker models less consistent.

## Startup loop for every material task

1. Read `AGENTS.md`.
2. Classify the workflow.
3. Load the matching skill and references.
4. Reuse a matching fresh task brief/handoff when available.
5. Resolve facts from artifacts, local context, and receipts.
6. List only unresolved facts that can change the plan or result.
7. Set a tool budget and smallest next proof.
8. Execute until the next real gate, then write the handoff.

## Positive fallback rule

`MISSING_PREREQUISITE`, permission denial, unavailable live adapter, or absent
private context blocks only the action that requires it.

If the request explicitly authorizes build, fix, change, refactor, migrate, or
implement work, continue with in-scope repo-local candidates such as:

- repository inspection and public documentation;
- schemas, interfaces, adapters, tests, and synthetic fixtures;
- local candidate SQL, M, DAX, TMDL, PBIR, or scripts;
- a dry-run or mocked evidence package;
- a precise setup/validation checklist; and
- capture of the blocker in the run handoff.

For diagnose, inspect, review, explain, or plan requests, keep the fallback
non-mutating: inspect existing artifacts, identify the exact candidate/test
that would be needed, and write the findings or handoff only when the request
authorizes that artifact. Do not convert a blocked live probe into a blanket
refusal, but do not infer edit authority from the missing prerequisite either.
Do not fake the missing evidence.

## Model roles

Use roles by task, even when the same approved model serves several roles:

| Role | Default work | Expected reasoning |
|---|---|---|
| Scout | File/repo inventory, metadata extraction, reference selection, formatting | Low or medium |
| Builder | Deterministic wrappers, candidate SQL/M/DAX, tests, docs | Medium |
| Compute | One approved bounded adapter interaction with disclosed external effects | Low or medium |
| Investigator | Schema drift, hierarchy/grain/currency ambiguity, failure isolation | High |
| Verifier | Independent assertions, diff review, receipt and policy checks | Medium or high |
| Summarizer | Compact task brief, evidence bundle, resume handoff | Low or medium |

Do not let the builder's narrative serve as verification. Reuse deterministic
checks and, for risky changes, use a fresh verifier context when practical.

## Escalation triggers

Escalate reasoning or model capability only for a bounded uncertainty such as:

- several plausible grains or source mappings;
- unexplained grouped variances after snapshots align;
- complex DAX filter context or circular dependencies;
- effective-dated hierarchy conflicts;
- ledger/currency/sign interactions;
- cross-system failure with evidence in several layers;
- ambiguous PBIR or semantic-model churn; or
- a high-impact candidate whose blast radius is difficult to establish.

Before escalating, improve the task brief, load the correct reference, reduce
the artifact, and run deterministic diagnostics. An expensive model cannot
repair a truncated source, stale schema, unavailable permission, or missing
business rule.

## Tool budget

Set bounds appropriate to the task:

- maximum files/objects/pages to inventory;
- maximum rows, bytes, stdout/stderr, and result samples;
- maximum recursive depth and approved roots;
- maximum polls, retries, elapsed time, and compute-triggering actions;
- maximum repeated capability probes;
- model/context token target; and
- stop condition for inconclusive evidence.

Reuse hashes, indexes, inventories, and fresh capability receipts. Do not make
the model rediscover the same workspace, schema, report, or tool boundary on
every turn.

## Evidence hierarchy

Prefer evidence in this order:

1. deterministic postcondition or round-trip read;
2. schema-valid receipt from an approved wrapper;
3. exact tool/API result within bounds;
4. inspected artifact and canonical diff;
5. documented inference tied to observations;
6. model hypothesis.

Never promote a lower level over a contradictory higher level.

## Failure-learning loop

When the model makes a meaningful error or a workflow exposes a new source
quirk:

1. capture the smallest sanitized symptom and exact failure class;
2. identify the violated invariant and the evidence that distinguishes it;
3. create a synthetic fixture that reproduces the decision;
4. add a deterministic assertion or expected classification;
5. update the narrowest relevant skill/reference;
6. run the regression plus nearby negative cases; and
7. record model/runtime versions, cost, and whether the task now resumes.

Do not paste a long incident narrative into `AGENTS.md`. Durable learning is a
rule, fixture, test, and routing change.

## Resume handoff

Use `schemas/run-handoff.schema.json`. At minimum record:

- task and contract hash;
- workflow and exact mode;
- selected context paths/hashes;
- artifact and tool versions;
- completed stages and last verified boundary;
- claims linked to evidence;
- failed/inconclusive checks;
- candidate paths and hashes;
- uncommitted or live state;
- blockers and missing private context;
- next permitted step; and
- the exact command/skill to resume.

The next model should not need the original conversation to know what was
attempted, what is true, and what remains unsafe.

## Anti-patterns

- Loading every Power BI and Databricks runbook “just in case.”
- Asking the operator to restate information that a local artifact can prove.
- Repeating raw CLI/API probes instead of using a cached sanitized capability
  receipt.
- Generating final SQL before grain and join cardinality are known.
- Treating Genie, an LLM reviewer, or the same builder model as financial
  signoff.
- Increasing reasoning effort instead of adding a missing fixture/assertion.
- Stopping all work because a live adapter is unavailable.
- Continuing live work after a real authorization or target gate is missing.
- Writing “success” when the evidence proves only request acceptance or
  metadata persistence.
