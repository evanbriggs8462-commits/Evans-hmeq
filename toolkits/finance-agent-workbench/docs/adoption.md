# Adoption and knowledge maintenance

## Choose the boundary first

Use two repositories if the approved Git boundary differs between personal and work systems:

- A generic toolkit may contain public documentation links, synthetic fixtures, portable scripts, and non-company-specific failure patterns.
- A company-owned private repository may add internal schema names, hierarchy rules, approved endpoints, report mappings, and sanitized incident evidence under company retention policy.

Do not copy proprietary material to a personal private repository merely because the repository is not public. Private hosting is not the same as company approval.

## Install into an OpenCode project

OpenCode discovers a root `AGENTS.md` and `.opencode/skills/*/SKILL.md` automatically when the working directory is inside the Git worktree.

For a separate report repository:

1. Copy or submodule `.opencode/skills/finance-data-reliability/`.
2. Merge relevant operating rules into that repository's `AGENTS.md`.
3. Merge model/agent settings into its `opencode.json` without replacing provider or MCP configuration.
4. Keep the actual provider credential in the approved credential store or environment, never in Git.
5. Run the tests with synthetic data before pointing any script at a share.

## Convert experience into durable knowledge

For each incident, record only:

- sanitized symptom and exact exit/error class;
- affected stage and invariant;
- evidence that separated root cause from similar failures;
- retry classification;
- deterministic remediation;
- regression fixture and test name;
- tool/version conditions.

Avoid long narrative incident dumps. The agent needs discriminating signals and required actions, not every conversational detail.

## Review cadence

Review the pack after:

- an OpenCode, Power BI Desktop, TE2, DAX Studio, Python, PowerShell, or Databricks runtime upgrade;
- a new SAP spool layout or encoding;
- a change to VPN/share topology;
- any false success, destructive near miss, or unexplained reconciliation difference.

Changes should be made through a branch and reviewed as code. A runbook claim is incomplete until a test or receipt contract supports it where practical.

