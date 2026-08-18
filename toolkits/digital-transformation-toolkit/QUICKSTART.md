# Digital Transformation Toolkit — quick start

This is the supported first-run path for Windows and OpenCode.

## 1. Install the local tools

Required for the core model inventory:

- a company-supported Windows version
- PowerShell 5.1 or later
- Git and access to this repository
- OpenCode 1.1.1 or later, or a newer company-supported build
- Power BI Desktop for a local PBIX
- Tabular Editor 2 version 2.28.0 or later

Also install DAX Studio 3.3.0 or later if you want OpenCode to connect to an open PBIX by filename and execute DAX queries with `dscmd`.

Install tools through your normal company software channel. The common executable locations are:

```text
C:\Program Files (x86)\Tabular Editor\TabularEditor.exe
C:\Program Files\DAX Studio\dscmd.exe
```

Your OpenCode provider and API key must already be configured in OpenCode. See [docs/OPENCODE_SETUP.md](docs/OPENCODE_SETUP.md). Those credentials do not belong in this repository or its `.env` file.

## 2. Clone and configure the toolkit

```powershell
git clone https://github.com/briggse4/digital_transformation_toolkit.git
Set-Location .\digital_transformation_toolkit
Copy-Item .\templates\.env.example .\.env
```

Edit `.env` and set the two executable paths plus an approved evidence folder outside the repository:

```ini
TE2_EXE_PATH=C:\Program Files (x86)\Tabular Editor\TabularEditor.exe
DSCMD_EXE_PATH=C:\Program Files\DAX Studio\dscmd.exe
EVIDENCE_ROOT=%USERPROFILE%\PowerBI-Evidence
```

The PowerShell scripts load `.env` automatically. Do not put API keys or Power BI tokens in it.

## 3. Run preflight

From the repository root:

```powershell
.\powershell\test_toolkit_setup.ps1
```

The full preflight reports `PASS` for the PowerShell version and syntax, reviewed execution files, `.env`, Tabular Editor 2, DAX Studio, and the evidence folder. It verifies versions and local paths, but not Power BI authentication or model connectivity.

To validate an inventory-only setup without DAX Studio:

```powershell
.\powershell\test_toolkit_setup.ps1 -InventoryOnly
```

Fix every failed check before handing the repository to OpenCode.

Preflight also stops if a tracked execution script has been edited since checkout. Submit script changes for review instead of changing them during an extraction session.

## 4. Export an open PBIX

1. Open the PBIX in Power BI Desktop and wait for it to finish loading.
2. Keep Power BI Desktop open.
3. Run the inventory using the PBIX filename shown in Desktop:

```powershell
.\powershell\run_model_inventory.ps1 -PbixName "Margin Report.pbix"
```

The command creates a timestamped folder under `EVIDENCE_ROOT`. It succeeds only after all six CSV files can be read and the manifest is written.

If two open PBIX files have the same filename, close one or give them unique filenames before running the command.

## 5. Optional: run a DAX connection test

For the same open PBIX:

```powershell
.\powershell\run_dax_query_any_model.ps1 `
  -Server "Margin Report.pbix" `
  -QueryFile ".\dax\queries\connection_test.dax"
```

For a published semantic model, include the XMLA endpoint and database name:

```powershell
.\powershell\run_dax_query_any_model.ps1 `
  -Server "powerbi://api.powerbi.com/v1.0/myorg/Finance Workspace" `
  -Database "Margin Model" `
  -QueryFile ".\dax\queries\connection_test.dax"
```

The result is saved under `EVIDENCE_ROOT` unless `-OutputCsv` is supplied.

For another DAX query, use the reviewed-query handoff prompt. The wrapper requires a reviewed copy outside the repository and records its SHA-256 hash in the manifest.

## Published-model core inventory

Use the XMLA endpoint and exact semantic-model name:

```powershell
.\powershell\run_model_inventory.ps1 `
  -ModelServer "powerbi://api.powerbi.com/v1.0/myorg/Finance Workspace" `
  -ModelName "Margin Model"
```

The signed-in user still needs XMLA access. The scripts do not acquire or store Power BI tokens.

## Hand off to OpenCode

Open the repository root in OpenCode, then paste the prompt from [prompts/OPENCODE_HANDOFF.md](prompts/OPENCODE_HANDOFF.md). Replace only the PBIX filename or XMLA values. OpenCode should run preflight, execute the inventory, verify `inventory_manifest.json`, and summarize the exported object counts.

If a command fails, use [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md). Do not let the session claim success from a launched process or an old output file.

Before broad team rollout, run the inventory and DAX connection test once on a non-sensitive PBIX from the same Windows/OpenCode setup your team will use.
