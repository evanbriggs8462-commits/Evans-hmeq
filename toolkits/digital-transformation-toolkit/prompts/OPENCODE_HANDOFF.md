# OpenCode handoff prompt

Copy one prompt below and replace the bracketed values.

## Open PBIX in Power BI Desktop

```text
Read AGENTS.md and QUICKSTART.md before acting. Work from the repository root.

Power BI Desktop is already open with this exact file name:
- PBIX: [REPORT_NAME.pbix]

Perform a read-only core semantic-model inventory.

1. Run powershell.exe -NoProfile -File ./powershell/test_toolkit_setup.ps1 -InventoryOnly.
2. If preflight fails, stop and return the failed checks without displaying .env or environment variables.
3. Run powershell.exe -NoProfile -File ./powershell/run_model_inventory.ps1 with -PbixName set to the exact filename above.
4. Read inventory_manifest.json from the returned output folder.
5. Confirm status is succeeded; toolkit commit, tool version, and exporter hash are present; and all six CSV artifacts have a row count, byte size, and SHA-256 hash.
6. Return the output folder and counts for tables, measures, columns, relationships, partitions, and shared expressions.

Do not edit or save the PBIX. Do not publish, refresh, or deploy. Stay within the hard limits in AGENTS.md. Do not rank objects or infer business logic unless I ask after reviewing the inventory.
```

## Published semantic model

```text
Read AGENTS.md and QUICKSTART.md before acting. Work from the repository root.

Target:
- XMLA endpoint: [POWERBI_XMLA_ENDPOINT]
- Semantic model: [MODEL_NAME]

Perform a read-only core semantic-model inventory.

1. Run powershell.exe -NoProfile -File ./powershell/test_toolkit_setup.ps1 -InventoryOnly.
2. If preflight fails, stop and return the failed checks without displaying .env or environment variables.
3. Run powershell.exe -NoProfile -File ./powershell/run_model_inventory.ps1 with -ModelServer and -ModelName set to the values above.
4. Read inventory_manifest.json from the returned output folder.
5. Confirm status is succeeded; toolkit commit, tool version, and exporter hash are present; and all six CSV artifacts have a row count, byte size, and SHA-256 hash.
6. Return the output folder and counts for tables, measures, columns, relationships, partitions, and shared expressions.

Do not edit, save, process, refresh, publish, or deploy the model. Stay within the hard limits in AGENTS.md.
```

## Reviewed DAX query to CSV

```text
Read AGENTS.md and QUICKSTART.md before acting. Work from the repository root.

Target:
- Server or open PBIX filename: [SERVER_OR_REPORT.pbix]
- Database for non-Desktop connections: [MODEL_NAME_OR_NOT_APPLICABLE]
- Reviewed DAX file outside the repository: [ABSOLUTE_DAX_FILE]

1. Run powershell.exe -NoProfile -File ./powershell/test_toolkit_setup.ps1.
2. Run powershell.exe -NoProfile -File ./powershell/run_dax_query_any_model.ps1 with the target connection and -QueryFile ./dax/queries/connection_test.dax. Include -Database for every connection except Power BI Desktop.
3. Confirm the connection-test CSV contains ToolkitConnection equal to OK, its manifest status is succeeded, and manifest validation.connectionTest is passed. Stop if any check fails.
4. Confirm the reviewed DAX file contains no unresolved `@@TOKEN@@` values. Do not change it.
5. Run powershell.exe -NoProfile -File ./powershell/run_dax_query_any_model.ps1 with the same connection and the reviewed -QueryFile.
6. Read the returned `.manifest.json` and confirm status is succeeded, the recorded query hash matches the reviewed file, and the toolkit commit and DAX Studio version are present.
7. Return the reviewed-query CSV and manifest paths, row count, delimiter, byte size, and SHA-256 hash.

If OpenCode requests access outside the repository, ask me to approve only the configured EVIDENCE_ROOT or the exact query-file folder. Do not display .env, credentials, or environment-variable values. Do not claim that the returned number is correct business logic merely because the query executed.

If the reviewed query is designed to return detail rows, stop and ask me to approve that output scope before executing it. Prefer a small aggregate result. On DirectQuery or Direct Lake models, explain that the query can reach backing data and create load or cost.
```
