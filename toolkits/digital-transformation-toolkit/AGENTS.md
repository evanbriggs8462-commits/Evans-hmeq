# OpenCode instructions

This repository performs read-only Power BI semantic-model extraction. Follow these rules whenever you operate in this repository.

## Supported work

- Validate local Tabular Editor 2 and DAX Studio paths.
- Export core metadata—tables, measures, columns, relationships, partitions, and shared expressions—from an open PBIX.
- Export the same metadata from a semantic model exposed through XMLA.
- Execute a user-reviewed DAX query and save its result as CSV.

Do not claim that this toolkit extracts report pages, visuals, bookmarks, or Power BI service refresh history. Those workflows are not implemented here. The toolkit does not connect directly to source systems, but DAX against DirectQuery or Direct Lake models can make Power BI query backing data.

## Before running anything

1. Confirm the working directory is the repository root containing this file.
2. Read `QUICKSTART.md`.
3. Confirm whether the target is:
   - an open Power BI Desktop file, identified by its exact `.pbix` filename; or
   - a published model, identified by its XMLA endpoint and exact database/model name.
4. Run `powershell/test_toolkit_setup.ps1`. Use `-InventoryOnly` only when no DAX query is requested.
5. Stop if `.env` is missing, an executable path fails, or `EVIDENCE_ROOT` is not writable.

Run scripts through native Windows PowerShell, for example `powershell.exe -NoProfile -File ./powershell/test_toolkit_setup.ps1`. Forward-slash paths remain valid if OpenCode launches the command from Git Bash. If OpenCode asks for external-directory access, request user approval only for the exact `EVIDENCE_ROOT` folder.

Never ask the user to paste an OpenCode API key, Power BI token, or other credential into chat. Never print the contents of `.env` or dump environment variables.

## Inventory command

For Power BI Desktop:

```powershell
powershell.exe -NoProfile -File ./powershell/run_model_inventory.ps1 -PbixName "<EXACT_FILE_NAME>.pbix"
```

For an XMLA endpoint:

```powershell
powershell.exe -NoProfile -File ./powershell/run_model_inventory.ps1 -ModelServer "<XMLA_ENDPOINT>" -ModelName "<SEMANTIC_MODEL_NAME>"
```

Use `-OutDir` only when the user supplies an approved output folder outside the repository.

The inventory is complete only when:

- the command exits without error;
- `inventory_manifest.json` has `status` set to `succeeded`;
- the toolkit commit, Tabular Editor version, and exporter hash are present;
- all six listed CSV artifacts exist;
- each artifact's size, row count, and SHA-256 value are present in the manifest.

Report the output directory and counts from the manifest. Do not infer business meaning or rank “important” objects unless the user gives a ranking rule.

## DAX command

Run the shipped `dax/queries/connection_test.dax` first unless a working connection was already proven in the current session. Confirm its CSV contains `ToolkitConnection` equal to `OK` and its manifest succeeded. A local PBIX uses its filename as `-Server`. An XMLA connection also requires `-Database`.

The shipped connection test is pre-approved. Execute every other DAX file only after the user supplies or reviews it. Do not edit `dax/queries/control_total_template.dax` in place; copy it to the evidence folder, replace every `@@TOKEN@@`, and scan for unresolved tokens before execution. The wrapper rejects non-test query files inside the repository.

Treat detail-level DAX exports as sensitive. Obtain explicit user approval for the query and output scope. Prefer a small aggregate or control-total result, especially for DirectQuery or Direct Lake models, because execution can reach backing data and create load or cost.

A DAX export is complete only when the wrapper exits without error, its `.manifest.json` has `status` set to `succeeded`, the toolkit commit and DAX Studio version are present, the query hash matches the reviewed file, and the output entry includes a row count, byte size, delimiter, and SHA-256 hash.

## Hard limits

- Do not modify model metadata, save a PBIX, publish, deploy, refresh, or process a model.
- Do not invoke Tabular Editor with deployment, build, BPA, or arbitrary script arguments.
- Use only `te2/readonly/export_model_inventory.csx` through the included wrapper.
- Do not add or run Databricks, Fabric, Power BI REST, or MCP commands as part of this toolkit.
- Keep PBIX/PBIT files, credentials, tokens, `.env`, and generated evidence out of Git.
- Do not weaken a failed check or reuse an old output file to make a run pass.
- Do not edit or commit repository files during an extraction session. Stop and request a separate human-reviewed change if a tracked script needs modification.
- Read only `inventory_manifest.json` after an inventory. Partition and shared-expression files can contain restricted endpoints or embedded credentials; obtain the user's approval before reading their contents.

## Failure response

When blocked, return:

1. the command that failed, with secrets and internal identifiers redacted where needed;
2. the actual error message;
3. the most likely cause supported by the error;
4. one next diagnostic or corrective action;
5. the artifact that will confirm recovery.

Label incomplete results `UNVERIFIED`. Never report success only because Tabular Editor or DAX Studio opened.
