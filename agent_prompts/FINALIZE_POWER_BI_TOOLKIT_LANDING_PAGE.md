# Simplify the HMEQ Power BI toolkit into a practical landing page

Work only in:

- Repository: `evanbriggs8462-commits/Evans-hmeq`
- Branch: `agent/power-bi-opencode-toolkit`
- Path: `toolkits/digital-transformation-toolkit/`

Do not modify unrelated HMEQ content or merge the PR.

## Purpose

This repository is a starter landing page for teammates using OpenCode with Power BI Desktop, Tabular Editor 2, and DAX Studio.

It should help a user:

1. Understand which tools are needed.
2. Configure their own OpenCode provider/API key.
3. Configure their own local executable paths.
4. Open a PBIX and extract basic semantic-model information quickly.
5. Run a reviewed DAX query.
6. Understand when TE2 expression writes are reasonable and when they should not be used.

The repository is not responsible for configuring every workstation, managing production deployments, enforcing organization-wide governance, or guaranteeing that a user's custom query or expression is correct.

Keep the implementation small and understandable.

## Preserve the working starter scripts

Keep the audited HMEQ implementations for:

- `powershell/run_model_inventory.ps1`
- `powershell/invoke_te2_readonly.ps1`
- `powershell/run_dax_query_any_model.ps1`
- `powershell/test_toolkit_setup.ps1`
- `powershell/common.ps1`
- `te2/readonly/export_model_inventory.csx`
- the DAX connection test and query template

Do not copy the broken scripts from `briggse4/digital_transformation_toolkit` commit `9312bee`.

Confirm the starter commands remain technically correct:

- Local PBIX TE2 connection:

  ```text
  TabularEditor.exe -L "<file.pbix>" -S "<script>"
  ```

- XMLA TE2 connection:

  ```text
  TabularEditor.exe "<server>" "<database>" -S "<script>"
  ```

- DAX Studio query files must use `-f`, not `-q`.
- XMLA DAX connections require a database/model name.
- `.env` must load before its values are used.
- Scripts must remain compatible with Windows PowerShell 5.1.
- Do not introduce `System.Text.Json`, `Path.GetRelativePath`, PowerShell 7-only syntax, or additional package dependencies.
- Do not include TE2 deployment, processing, refresh, BPA, or build flags in the read-only extraction commands.

Retain basic output validation so a command does not claim success when no files were created. Do not expand this into a complex compliance, approval-token, or deployment framework.

## Keep the repository Power BI/OpenCode-only

Do not add:

- Databricks examples
- MCP functionality
- Power BI token acquisition
- Fabric or Power BI REST automation
- Python dependencies
- source-system reconciliation examples
- production deployment automation

A brief statement that these items are outside scope is sufficient. Do not repeatedly discuss them throughout the documentation.

## Simplify the documentation

Keep a small documentation structure:

```text
README.md
QUICKSTART.md
AGENTS.md
docs/OPENCODE_SETUP.md
docs/TE2_GUIDANCE.md
docs/TROUBLESHOOTING.md
prompts/OPENCODE_HANDOFF.md
```

Retain `docs/SECURITY.md` only if it contains short, useful guidance not already covered elsewhere.

### README

The README should explain:

- what the toolkit is;
- what it extracts;
- which tools are required;
- where to start;
- what is not included;
- that users are responsible for their own environment and validation.

Do not describe the toolkit as foolproof, autonomous, production-ready, fully governed, or guaranteed to work in every environment.

### Quick start

The quick start should contain only the normal first-run sequence:

1. Install or confirm OpenCode, Power BI Desktop, TE2 2.28+, and optionally DAX Studio 3.3+.
2. Configure the approved OpenCode provider/API key outside the repository.
3. Copy `.env.example` to `.env`.
4. Set local TE2, DAX Studio, and evidence-folder paths.
5. Run the basic preflight.
6. Open a PBIX in Power BI Desktop.
7. Run the inventory using the exact PBIX filename.
8. Optionally run the DAX connection test.
9. Review the output.

State clearly that executable locations, API/provider configuration, Power BI access, PBIX filenames, XMLA endpoints, and model names differ by user.

### OpenCode setup

Keep this provider-neutral.

Do not prescribe:

- localhost providers;
- invented models;
- model costs;
- token limits;
- temperature settings;
- internal endpoints;
- unsupported company-specific configuration.

Say only that the user must configure the provider, endpoint, model, and API key through the approved internal process before opening the repository.

### AGENTS.md

Keep root `AGENTS.md` because OpenCode loads it automatically.

It should tell the session:

- read the README and Quickstart;
- ask whether the target is a local PBIX or XMLA model;
- ask for the exact required identifiers;
- never request or display credentials;
- run preflight before extraction;
- use the included starter scripts;
- verify that expected output exists;
- do not claim business correctness merely because a command executed;
- obtain explicit permission before any model write.

Do not turn `AGENTS.md` into a long policy manual.

### OpenCode permissions

Because every teammate's paths and environment can differ, do not impose a root `opencode.json` with hardcoded external-directory paths.

Move it to an optional example such as:

```text
templates/opencode.example.json
```

Explain that users may copy and adapt it if they want project-level command restrictions.

The repository should not claim that the optional configuration fits every user automatically.

### Handoff prompt

Provide short, usable prompts for:

- extracting an open PBIX;
- extracting an XMLA model;
- running a reviewed DAX query;
- asking for help with a TE2 expression change.

Each prompt should include the actual placeholder the user must replace. Do not use generic language such as "I will send files later."

## TE2 expression-write guidance

Do not build an automated plan/apply/rollback system.

Add a concise `docs/TE2_GUIDANCE.md` explaining that TE2 can modify semantic-model expressions when the user explicitly requests it and accepts responsibility for the change.

Cover these expression types:

- measures;
- calculated columns;
- partition M;
- shared M expressions.

Explain that expression writes should normally be used only when:

- working with a local PBIX rather than a production XMLA model;
- a backup or duplicate PBIX exists;
- the exact target object is known;
- the current and proposed expressions have been reviewed;
- only one deliberate change is being made;
- the user is prepared to validate the report afterward.

Explain that expression writes should not be used for:

- bulk or wildcard changes;
- production XMLA models without an established deployment process;
- object deletion or renaming;
- relationships, RLS, roles, credentials, or data sources;
- refreshes or processing;
- unreviewed M changes that could alter table schemas;
- any PBIX without a backup.

State that changing an expression does not prove the business logic is correct.

For M changes, tell users to validate the query, schema, credentials, and refresh behavior in Power BI Desktop afterward.

The OpenCode instructions should require explicit user approval immediately before a TE2 write. Read-only extraction does not require this additional approval beyond the normal command confirmation.

A small commented expression-write example is acceptable, but:

- it must not contain a deployment flag;
- it must target one explicitly named object;
- it must contain obvious placeholders;
- it must not execute automatically as part of setup;
- it must be clearly labeled as an advanced example that users must review and adapt.

## Tone and noise reduction

Use concise, direct language.

Remove:

- repeated safety sections;
- marketing language;
- unrealistic setup-time promises;
- generic AI personas;
- duplicate workflows;
- unsupported claims about models, costs, or performance;
- explanations unrelated to getting started with Power BI, TE2, DAX Studio, and OpenCode.

A teammate should be able to understand the repository in a few minutes.

## Validation

Before committing:

1. Confirm only the toolkit directory changed.
2. Validate PowerShell syntax.
3. Validate `opencode.example.json` if retained.
4. Check every relative Markdown link.
5. Confirm Databricks and MCP implementation files are absent.
6. Confirm no API key, token, internal hostname, personal path, PBIX, CSV output, or evidence file is staged.
7. Confirm TE2 examples use the documented connection syntax.
8. Confirm DAX query files use `-f`.
9. Run `git diff --check`.

If a Windows machine with Power BI Desktop, TE2, and DAX Studio is available, run the basic inventory and connection test on a disposable PBIX. Otherwise, state clearly that the scripts were statically checked but still require a local Windows smoke test.

Commit the focused changes to `agent/power-bi-opencode-toolkit`. Do not merge the PR.

Return:

- files changed;
- what was simplified;
- checks completed;
- anything still requiring user-specific setup;
- commit hash;
- PR link.

Implement these changes. Do not add additional automation or expand the scope beyond this landing-page purpose.
