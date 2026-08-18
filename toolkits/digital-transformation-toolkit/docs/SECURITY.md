# Security

## Credentials

- Configure the OpenCode provider key outside this repository.
- Do not intentionally add Power BI tokens or passwords to `.env`, scripts, prompts, or outputs. An inventory can reproduce credentials already embedded in legacy model expressions; keep evidence restricted and inspect it locally before sharing it with OpenCode.
- The included scripts do not acquire tokens. Tabular Editor and DAX Studio use the identity available to those tools.
- Use a read-only Power BI identity for XMLA endpoints. Script-side checks do not replace access control.

## Repository contents

Never commit:

- `.env` or credential files;
- PBIX or PBIT files;
- generated CSV, JSON, or log evidence;
- internal server names, model identifiers, or personal filesystem paths in reusable examples.

Before committing, run:

```powershell
git status --short
git diff --cached
```

Review every staged file. `.gitignore` is a safeguard, not permission to keep secrets in the repository.

## Evidence

Set `EVIDENCE_ROOT` to an approved folder outside the clone. Model expressions and source definitions can contain internal names, restricted endpoints, business logic, or credentials embedded in legacy M code. Treat all exports as internal data. Follow your team's access, retention, and deletion requirements.

The inventory handoff reads only the manifest. Before allowing OpenCode to read `partitions.csv` or `expressions.csv`, review or scan those files locally, redact any credential or restricted endpoint, and obtain the user's approval for that exact task.

The wrappers reject output paths inside the repository. They remove only the expected stale artifact at the exact requested path before execution.

## Read-only boundary

The Tabular Editor wrapper:

- accepts only the shipped `te2/readonly/export_model_inventory.csx` script;
- uses either a local `-L` connection or positional XMLA server/database arguments;
- passes only the advanced-script `-S` option;
- waits for the process, checks its exit code, and requires new output files.

Preflight and both execution wrappers use Git to reject changes to the shipped PowerShell, Tabular Editor, and connection-test files. Make script changes in a separate reviewed commit, not during an extraction session.

The DAX wrapper uses `dscmd csv` with a query file. Non-test queries must be reviewed copies outside the repository, and their hashes are recorded in the manifest. DAX query execution is not permission isolation; the connected identity still determines accessible data. A DirectQuery or Direct Lake query can reach backing data and create source load or cost. Require explicit approval for every non-test query and for any detail-level export; prefer small aggregate results.

No script in this repository edits a model, publishes content, performs a refresh, or connects directly to a source system.
