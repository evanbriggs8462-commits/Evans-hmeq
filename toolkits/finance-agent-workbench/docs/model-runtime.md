# Model and runtime controls

## What the resolved configuration proves

The visible model selector identifies the provider/model selected for that
session. The scout, builder, verifier, or investigator label identifies a role
and permission boundary. Neither one proves the final merged runtime alone.

OpenCode merges organization, global, custom, project, inline, and managed
configuration. Inspect the effective result before relying on a model or
permission claim:

```powershell
opencode debug config
opencode models
```

If the approved executable is not in `PATH`, invoke its exact installed path.
Do not download or substitute a binary on a managed workstation without
authorization.

## Portable roles, private model bindings

This repository intentionally omits checked-in provider/model IDs and
provider-specific reasoning options:

| Role | Repository authority | Use |
|---|---|---|
| `finance-scout` | Built-in/no-state adapter reads; edits and shell denied | Classification, task capsule, bounded metadata |
| `finance-build` | Approval-gated repo-local edits | Explicitly requested candidate and focused tests |
| `finance-verifier` | Built-in reads only; edits and shell denied | Independent diff, invariant, and receipt review |
| `finance-compute` | Approved adapter only; edits and shell denied | One disclosed bounded external read/compute action |
| `finance-deep` | No broader than builder | One bounded semantic or cross-system ambiguity |

Choose an approved inexpensive or genuinely local model in the session, or
bind roles to verified aliases in private user/organization configuration. Do
not put an unverified machine-specific provider/model ID in the portable
project file. Commands attached to these roles then inherit the resolved model
instead of silently overriding the cheaper session choice.

The role boundary is independent of model cost and reasoning effort. A more
capable model does not gain permission to write, broaden a target, query a live
system, or skip evidence.

## Private-context boundary

When the resolved model is remote, any field loaded into its context is sent to
that provider. Load a `WORK_INTERNAL` field only when the exact provider/model
boundary is approved for that data class. Otherwise use only a pre-generated
approved projection, an installed deterministic redaction adapter, or a
genuinely local approved model. If none exists, omit private fields and return
`MISSING_CONTEXT`/`MISSING_PREREQUISITE`; never ask the model to redact the raw
values. Never include
credentials, authorization headers, raw finance rows, PII, unrestricted object
dumps, or sensitive query text.

For a safe diagnostic record, capture only a redacted envelope:

```json
{
  "provider_alias": "APPROVED_PROVIDER_A",
  "model_alias": "APPROVED_MODEL_A",
  "local_or_remote": "local",
  "role": "finance-build"
}
```

A model's self-report is not evidence of the outbound request or resolved
configuration.

## Promotion and escalation

Qualify models by task family with sanitized synthetic cases. Require every
critical invariant, zero critical policy violations, bounded tool use, and an
independent deterministic verifier. Escalate only when evidence conflicts, a
material semantic rule remains unresolved, or two bounded materially different
attempts fail the same invariant. Missing adapters, packages, or private
context block only the exact dependent action; they do not justify a blanket
refusal or broader access.

## Sources

- [OpenCode configuration](https://opencode.ai/docs/config/)
- [OpenCode agents](https://opencode.ai/docs/agents/)
- [OpenCode models](https://opencode.ai/docs/models/)
