# OpenCode setup

Configure OpenCode before opening this repository. The toolkit must run in a native Windows session that can reach Power BI Desktop and the installed Windows executables; a remote or cloud shell cannot inspect a PBIX open on your computer.

## Provider setup

1. Obtain an API key through your team's approved OpenCode service.
2. Add the provider, endpoint, and key through OpenCode's provider settings or approved credential store.
3. Select a model that is available in the current internal registry.
4. Use OpenCode 1.1.1 or later—or your newer company-supported build—and enable its command-execution mode for this repository. Add your team's onboarding link and support owner to your internal copy of this guide.

Do not paste the key into a prompt, `.env`, `opencode.json`, PowerShell script, or Markdown file. This toolkit's `.env` contains only local executable and output paths.

## Open the correct folder

Open the repository root—the folder containing `AGENTS.md`, `QUICKSTART.md`, `powershell`, and `te2`. Do not open only the `powershell` subfolder.

The tracked `opencode.json` uses [OpenCode project permissions](https://opencode.ai/docs/permissions/) to deny repository edits and all shell commands except the three toolkit wrappers and the Windows check. Each permitted command still requires approval. Leave auto-approve off. If your approved `EVIDENCE_ROOT` is not `%USERPROFILE%\PowerBI-Evidence`, update the matching `external_directory` rule in `opencode.json` through a reviewed commit before starting the session.

At the beginning of the session, ask OpenCode to run this check:

```text
Run powershell.exe -NoProfile -Command "Write-Output OPENCODE_WINDOWS_OK" and return only the output. Do not run another command.
```

The command must return `OPENCODE_WINDOWS_OK` from the Windows machine where Power BI Desktop, Tabular Editor, and DAX Studio are installed. The setup preflight checks the PowerShell version. Then ask:

```text
Read AGENTS.md and QUICKSTART.md. Confirm the repository root and list the supported operations and hard limits. Do not run anything yet.
```

The response should match the supported operations and hard limits in `AGENTS.md`.

The scripts write evidence outside the repository. When OpenCode requests external-directory access, approve read/write access only to the exact `EVIDENCE_ROOT` folder configured in `.env`. Do not approve the whole user profile or drive.

## Setup preflight

After copying `templates/.env.example` to `.env`, ask OpenCode:

```text
For an inventory only, run powershell.exe -NoProfile -File ./powershell/test_toolkit_setup.ps1 -InventoryOnly from the repository root. For a DAX task, omit -InventoryOnly. Report only PASS/FAIL checks and corrective actions. Do not display .env or any environment-variable values.
```

Continue only after the required checks pass. Then use [the standard handoff prompt](../prompts/OPENCODE_HANDOFF.md).

## Session permissions

Allow only the commands needed for the stated task. A normal inventory needs the preflight script and `run_model_inventory.ps1`. A DAX export also needs `run_dax_query_any_model.ps1`.

Stop the session if it proposes:

- an unlisted Tabular Editor script;
- a Tabular Editor deploy, save, process, or build argument;
- a PBIX or PBIT file commit;
- a request to print or paste a credential;
- a command outside the supported operations in `AGENTS.md`.

Do not allow OpenCode to edit or commit repository files during an extraction session. Project permissions deny edits and unlisted shell commands; the preflight and wrappers also reject changed execution files.
