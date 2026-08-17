---
name: capture-agent-failure
description: Convert a real finance-agent mistake, false success, repeated tool failure, source quirk, reconciliation miss, or unsafe/overly restrictive behavior into durable learning when the user asks to capture, codify, remediate, or add regression coverage. For diagnosis-only requests, produce a proposed sanitized case and do not edit skills, fixtures, wrappers, routes, or tests.
---

# Capture an Agent Failure

1. Load `../finance-report-migration/references/local-model-operations.md` and the
   matching workflow/failure references.
2. Record the smallest sanitized symptom, stage, exact error/classification,
   model/runtime versions, and violated invariant in a case conforming to
   `schemas/failure-case.schema.json`.
3. Identify evidence that distinguishes the root cause from similar failures.
4. For diagnosis/review scope, stop with a proposed case, fixture, regression,
   and remediation plan. Do not edit the repository.
5. When the user explicitly asks to capture/codify/remediate, create a minimal
   synthetic fixture and deterministic expected result, then update the
   narrowest relevant skill, reference, wrapper, or route. Do not append an
   incident transcript to `AGENTS.md`.
6. Under that same change authority, test success, nearby negative cases,
   false-success behavior, and resume quality. A model grader may label the
   case but cannot override assertions.
7. If a deterministic eval runner and a verified private binding for the
   cheaper/local model both exist, record time/token/cost and whether it now
   passes. Otherwise return an eval plan plus `MISSING_PREREQUISITE`; do not
   invent a model ID or claim evaluation occurred.
8. Keep raw work data, identifiers, prompts, logs, and credentials out of Git.
