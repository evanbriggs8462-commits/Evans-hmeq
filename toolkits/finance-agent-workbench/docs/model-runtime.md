# Model and runtime controls

## What the visible selector proves

Seeing `azure/gpt-5.3-codex` in OpenCode proves the session selected that provider/model identifier. Seeing Build or Plan identifies an agent permission profile. It does not identify the model's reasoning effort.

OpenCode merges remote organization, global, custom, project, inline, and managed configuration. A local file inspection alone therefore does not prove the resolved runtime configuration. Prefer:

```powershell
opencode debug config
opencode models
```

If the executable is not in `PATH`, locate the approved installed executable and invoke it by exact path. Do not download or substitute another binary on a managed workstation without approval.

## Explicit profiles

This repository pins:

| Profile | Reasoning | Use |
|---|---:|---|
| `finance-build` | medium | Routine scripting, tests, documentation, bounded diagnosis |
| `finance-deep` | high | Schema drift, unexplained variances, cross-system or semantic-model failures |

Do not default to xhigh. Escalating reasoning increases cost and latency but does not repair a broken tool contract, missing evidence, stale schema, truncated file, or unsafe shell command.

## Version gate

Use an organization-approved OpenCode release at least as new as `1.18.4` for this Azure configuration. That release corrected Azure endpoint support and provider-defined reasoning option handling. Record the actual OpenCode version in incident evidence.

## Verification without leaking work data

First inspect the resolved configuration. If transport verification is still required, capture only a redacted envelope:

```json
{
  "provider": "azure",
  "model": "gpt-5.3-codex",
  "endpoint_kind": "responses",
  "reasoning_effort": "medium"
}
```

Never log authorization headers, API keys, request bodies, prompts, tool definitions, raw file paths, XML content, SQL results, or model output. A model's self-report is not proof of the outbound request.

For Responses-based integrations, preserve response item metadata across turns instead of flattening everything into plain text. In particular, do not discard assistant phase information used to distinguish commentary from the final answer.

## Sources

- [OpenCode configuration](https://opencode.ai/docs/config/)
- [OpenCode agents](https://opencode.ai/docs/agents/)
- [OpenCode changelog](https://opencode.ai/changelog)
- [GPT-5.3-Codex](https://developers.openai.com/api/docs/models/gpt-5.3-codex)
- [Codex prompting guide](https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide)

