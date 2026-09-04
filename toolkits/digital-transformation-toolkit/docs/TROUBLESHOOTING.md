# Troubleshooting

Run every command from the repository root unless noted otherwise.

## `.env` was not found

Create it from the tracked template:

```powershell
Copy-Item .\templates\.env.example .\.env
```

Set real local paths. Do not add credentials.

## `TE2_EXE_PATH` or `DSCMD_EXE_PATH` failed

Find the installed executable, update `.env`, then rerun:

```powershell
.\powershell\test_toolkit_setup.ps1
```

An application shortcut or installation directory is not sufficient; the value must point to the executable file.

## No local Power BI Desktop instance was found

- Open the PBIX in Power BI Desktop and wait for the model to load.
- Pass the exact filename including `.pbix` to `-PbixName` or DAX `-Server`.
- Close duplicate open files with the same filename.
- If Tabular Editor still cannot locate it, open Tabular Editor interactively once and confirm the model appears under local instances. Do not save changes.

## XMLA connection failed

- Confirm the workspace supports XMLA and your account has access.
- Copy the endpoint from workspace settings rather than typing it from memory.
- Use the exact semantic-model name as `-ModelName` or DAX `-Database`.
- Sign in through the approved Tabular Editor or DAX Studio authentication flow if prompted.

Do not add tokens to the command line or `.env`.

## DAX Studio treated the query path as query text

Use the included wrapper. It passes a file with `-f`; `-q` is for inline DAX and is not used here.

## An output already existed

The wrappers remove only the exact expected output files before running. If a run fails, it should not report an old file as new evidence. Review the process error, fix the cause, and rerun; do not copy an older artifact into the new folder.

## A CSV has quoted fields or multiline expressions

That is expected. DAX and Power Query expressions can contain commas, quotes, and line breaks. The Tabular Editor exporter preserves them using standard CSV quoting. Use `Import-Csv`, Excel, or another CSV-aware reader instead of splitting lines on commas.

## Inventory stopped after Tabular Editor opened

The wrapper waits for Tabular Editor and checks its exit code. If the process remains open, close any unexpected dialog and capture its message. A run is not successful until `inventory_manifest.json` lists all six artifacts.

## OpenCode says the run succeeded but no manifest exists

Treat the run as failed. Ask OpenCode to return the exact command and error, then rerun the inventory. `AGENTS.md` requires manifest verification before a success claim.

## Script execution is blocked by company policy

Do not bypass an organizational PowerShell policy. Ask your support team to approve or sign the repository scripts through the normal process.

## Escalation bundle

Route OpenCode provider or command-execution problems to the team that issued OpenCode access. Route PBIX, XMLA, or workspace-permission problems to the Power BI model/workspace owner. Include:

- the preflight check name and PASS/FAIL result;
- installed Tabular Editor and DAX Studio versions;
- the exact failed command with internal identifiers redacted;
- the error text;
- whether a new manifest was created.

Do not attach `.env`, tokens, PBIX files, or exported metadata to a public issue or external support request.
