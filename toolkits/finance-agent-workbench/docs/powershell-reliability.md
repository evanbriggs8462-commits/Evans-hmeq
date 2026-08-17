# PowerShell and SMB reliability for large SAP spool XML

`scripts/Stage-Spool.ps1` is the only supported network-to-local copy path in
this repository. It targets Windows PowerShell 5.1 and .NET Framework 4.x. The
agent should orchestrate this script; it should not invent a new `Copy-Item`,
byte-loop, or XML-reading command for each export.

Before any large-file content read or copy, follow the mandatory
[large XML over SMB runbook](../.opencode/skills/finance-data-reliability/references/large-xml-smb-runbook.md).
This document explains the staging implementation; the mandatory runbook
controls command selection, handoff, validation, and incident interpretation.
For a sanitized elapsed timer on a bounded command, also follow
[long-running task observability](long-running-task-observability.md). Its
heartbeat is liveness evidence only and does not override an agent host's hard
wall-clock limit.

## Operating contract

The staging boundary is deliberately narrow:

1. Accept exactly one literal `.xml` UNC path.
2. Require it to be below a root inherited through
   `SPOOL_ALLOWED_UNC_ROOTS`.
3. Probe length and UTC last-write time more than once.
4. Prove the volume is ready and fixed, reject known sync roots and every
   existing reparse-point ancestor, and only then create the destination.
5. Require sufficient local capacity.
6. Copy with restartable, unbuffered `robocopy` into a deterministic directory
   whose name ends in `.part`.
7. Restat the source immediately before and immediately after copying.
8. Check local length and calculate SHA-256 **on the local file**.
9. Atomically rename into content-addressed storage and mark it read-only.
10. Write a no-BOM UTF-8 JSON receipt atomically and emit the same result as
   machine-readable JSON.

The script never modifies source data. In particular, its `robocopy` argument
set contains no `/MOV`, `/MOVE`, `/MIR`, `/PURGE`, or `/DELETE` switch.

`robocopy` copies a file under its original leaf name, so it cannot directly
rename the incoming file to `name.xml.part`. The script instead uses an
isolated directory named `<source-fingerprint>.part`. A failed transfer stays
there and `/Z` can restart it. No partial file is ever placed in the final
`objects` tree.

## Authentication and policy

A domain-qualified identity such as `DOMAIN\user` means SMB normally uses the
Windows logon token through Kerberos or NTLM. That is the right pattern here:
the stage command has no username, password, token, or `PSCredential`
parameter. Never add credentials to command lines, JSON receipts, source code,
Git configuration, or agent prompts.

Configure approved roots outside the repository. For an interactive test in a
trusted shell:

```powershell
$env:SPOOL_ALLOWED_UNC_ROOTS = '\\server\approved-share\sap-spool'
```

Multiple roots are separated by semicolons. In production, have a trusted
launcher, scheduled-task definition, or endpoint policy set the environment
variable before the agent starts. An environment variable is a guardrail, not
an authorization boundary: a caller that can alter the launcher or script can
also alter the policy. Share and NTFS ACLs remain the real security boundary.

Do not commit actual server names, share names, usernames, client names, spool
files, Databricks tokens, or copied receipts to Git. Use placeholders in tests
and documentation.

## Invocation

Use a short local destination outside OneDrive. A path such as
`C:\SpoolStage` is preferable to a profile directory.

Before `Stage-Spool.ps1` creates that directory, it verifies the drive reports
`IsReady = true` and `DriveType = Fixed`. It then walks the drive root and every
existing path component with literal-path metadata checks. Any junction,
symbolic link, volume mount point, or other reparse point is rejected, because
an apparently local `C:\...` path can otherwise redirect to another location.
Known OneDrive roots are rejected lexically as well. The same ancestor walk is
repeated immediately after directory creation before a staging file is opened,
and again around creation of the `.staging`, `objects`, and `receipts`
subdirectories so an existing child junction cannot redirect those writes.

`Get-EnvironmentProfile.ps1` applies the same evidence standard without
creating the proposed directory. It emits
`local_destination_confirmed: true` only after the ready/fixed-volume,
sync-root, and existing-ancestor checks pass. Rejections produce a nonzero exit
and sanitized JSON with `local_destination_confirmed: false`; the supplied path
is not echoed.

```powershell
$scriptPath = 'C:\approved-tools\Stage-Spool.ps1'
$sourcePath = '\\server\approved-share\sap-spool\2026\ledger.xml'

& powershell.exe -NoLogo -NoProfile -NonInteractive -File $scriptPath `
    -SourcePath $sourcePath `
    -DestinationRoot 'C:\SpoolStage' `
    -StabilityProbeCount 3 `
    -StabilityProbeSeconds 5 `
    -ReserveBytes 1073741824 `
    -RobocopyRetryCount 2 `
    -RobocopyWaitSeconds 5
$stageExitCode = $LASTEXITCODE
```

Capture `$LASTEXITCODE` immediately after the native/script invocation. Do not
run another command first. A successful stdout object contains the artifact and
receipt paths **relative to `DestinationRoot`**, local SHA-256, source restat
metadata, and `robocopy` bit flags. It records stable SHA-256 fingerprints of
the source leaf name, canonical source path, and approved root; none of those
raw values or the local root are written to agent-facing JSON. Persisted
receipts use explicit UTF-8 without a byte-order mark, avoiding Windows
PowerShell 5.1's inconsistent default file encodings.

Failure JSON likewise omits the supplied source and destination paths. Any
captured `robocopy` output tail replaces the source directory, staging
directory, and leaf name with placeholders before it reaches the envelope.

Do not use `Invoke-Expression` to build this command. When invoking from another
PowerShell wrapper, pass arguments as an array so spaces in UNC and local paths
remain one argument.

## Exit and failure classes

The process exit code gives the broad action, while `failureClass` in failed
JSON gives the precise condition.

| Stage exit | Meaning | Representative failure class |
|---:|---|---|
| 0 | Complete; receipt written | n/a |
| 1 | Unexpected implementation/runtime error | `Unexpected.UnhandledError` |
| 2 | Invalid path or policy | `Policy.SourceOutsideAllowlist` |
| 3 | Source unavailable or invalid | `Source.Unavailable` |
| 4 | Source unstable before copying | `Source.UnstableDuringProbe` |
| 5 | Insufficient local space | `Destination.InsufficientSpace` |
| 6 | `robocopy` unavailable or failed | `Copy.RobocopyFailed` |
| 7 | Source changed or vanished during copying | `Source.ChangedDuringCopy` |
| 8 | Local length/hash integrity failure | `Integrity.LengthMismatch` |
| 9 | Atomic promotion/content-address conflict failed | `Promotion.AtomicRenameFailed` |
| 10 | Artifact exists, but receipt creation failed | `Receipt.WriteFailed` |
| 11 | Another process holds the same staging lock | `Concurrency.StageLocked` |

`robocopy` has its own bitmask exit convention. Values **0 through 7 are
success-class results**. Values **8 and above indicate at least one failure**.
Treating any nonzero `robocopy` code as failure is a common automation bug.

| Robocopy bit | Meaning |
|---:|---|
| 1 | One or more files copied |
| 2 | Extra destination entries detected |
| 4 | Mismatched entries detected |
| 8 | At least one copy failure |
| 16 | Serious/fatal error |

The script uses `/Z /J /IS /R:2 /W:5` by default. `/Z` makes an interrupted copy
restartable, `/J` avoids the file-cache pressure caused by buffering a huge
file, `/IS` forces a same-size/same-time staging file to be refreshed rather
than silently trusted, and bounded retry/wait values prevent an agent from
hanging for hours.
Do not casually add `/MT` for one huge file across a high-latency VPN; it does
not split a single file and can add contention for multi-file calls.

## Failures that look similar but are not

| Symptom | Usually means | Deterministic response |
|---|---|---|
| `ChildProcess.kill`, `Shell Unknown`, or no native exit code | The agent host killed PowerShell because of a wall-clock/idle timeout, cancellation, or process policy. It does **not** prove PowerShell or SMB failed. | If expected transfer time exceeds the tool's hard limit, do not run the copy in that interactive shell. Hand the approved command to a durable company-approved terminal/job runner and retrieve its JSON receipt. Extend a configurable timeout only when the operation is bounded, progress is observable, and the new limit remains within policy. |
| `PathNotFound`, `The network path was not found` | VPN route, DNS, DFS referral, SMB port, or a mistyped literal path | Test DNS, TCP 445, then `Get-Item -LiteralPath`. Do not keep retrying an invalid path. |
| `Access is denied`, logon failure | The noninteractive process has a different Windows token, Kerberos ticket, share ACL, or NTFS ACL | Compare `whoami` in the working shell and agent shell. Use a UNC path, not an interactive mapped drive. Ask IT to correct access; never put a password in the command. |
| `The specified network name is no longer available`, connection reset | VPN/SMB session dropped during transfer | Preserve the `.part` directory and rerun the same command so `/Z` can restart. Investigate VPN stability if it repeats. |
| Sharing violation | The SAP export or another process still owns the file in an incompatible sharing mode | Wait for the producer's completion marker or for stable metadata; do not force-unlock or copy a live export. |
| Code 1, 2, 3, 5, 6, or 7 reported as failure | A wrapper incorrectly assumed all nonzero native codes fail | Apply the documented `robocopy` boundary: `0..7` success, `>=8` failure. |
| Local disk fills despite a precheck | Other processes consumed space after the check, sparse/allocation behavior differed, or reserve was too small | Keep staging on a dedicated volume, increase `ReserveBytes`, and monitor free space. A precheck cannot reserve capacity. |
| Final rename fails | Antivirus/indexer interference, permissions, a corrupt existing hash path, or an unexpected destination | Keep `.staging` and `objects` under the validated fixed root. If a concurrent process created the exact same content-addressed object, the script verifies its length and SHA-256 and treats the race as idempotent reuse. It never force-overwrites a different object. |
| Repeated recopy or stale data | Source length/time changed, clock precision is unusual, or an earlier wrapper copied into a shared temp filename | Reuse the same script and source path. Its source fingerprint isolates partial files and its before/after restat rejects ordinary changes. |

### Why mapped drives fail in agents

Drive mappings such as `S:` belong to a logon session and integrity context.
An interactive user can see `S:` while a noninteractive child process cannot.
Use the approved UNC path. Windows-integrated authentication still applies; a
UNC path does not imply embedding credentials.

### Why OneDrive is rejected as a staging destination

OneDrive Files On-Demand, sync filters, file locking, renames, path growth, and
cloud hydration can interfere with huge temporary files. Keeping the repository
or `opencode.json` in OneDrive does not make OneDrive an appropriate data
landing zone. The script rejects configured OneDrive roots for staging.

### Quoting rules

- Use `-LiteralPath`, never `-Path`, for file operations on a caller-supplied
  path.
- Pass native arguments as an array; do not manually wrap each path in embedded
  quote characters.
- Never concatenate a UNC path into `powershell.exe -Command "..."`.
- Never use `Invoke-Expression`.
- Reject `*`, `?`, `[`, `]`, `..`, device paths, and alternate data streams at
  the boundary.

The script invokes `robocopy.exe` with an argument array and captures
`$LASTEXITCODE` on the immediately following statement.

## Safe diagnostics

Run these read-only commands in the same noninteractive/domain context that
will perform staging. Replace placeholders locally; redact server/share names
before posting logs outside the company.

```powershell
# Runtime and identity. Do not publish the actual identity.
$PSVersionTable | Select-Object PSVersion, CLRVersion
whoami

# DNS and SMB reachability.
Resolve-DnsName -Name 'server' -ErrorAction Stop
Test-NetConnection -ComputerName 'server' -Port 445 -InformationLevel Detailed

# Existing SMB sessions without printing usernames.
Get-SmbConnection |
    Select-Object ServerName, ShareName, Dialect, NumOpens

# Literal metadata only; this does not load the XML.
Get-Item -LiteralPath '\\server\approved-share\path\ledger.xml' |
    Select-Object FullName, Length, LastWriteTimeUtc, Attributes

# Local capacity and filesystem.
Get-PSDrive -PSProvider FileSystem |
    Select-Object Name, Root, Used, Free
Get-Volume -DriveLetter C |
    Select-Object DriveLetter, FileSystem, SizeRemaining, Size

# Share mappings visible to this logon context.
Get-SmbMapping |
    Select-Object LocalPath, RemotePath, Status
```

`Test-NetConnection` succeeding on port 445 does not prove share/NTFS
authorization. Conversely, an authorization failure should not trigger DNS or
VPN retry loops. Diagnose the layers in order: process lifetime, VPN/DNS,
TCP 445, Windows identity, share ACL, NTFS ACL, literal file, stable metadata,
then copy.

Avoid dumping `klist`, `whoami /all`, full environment variables, OpenCode HTTP
payloads, request headers, or verbose SMB traces into an agent chat. Those can
contain internal identities, group memberships, endpoints, prompts, and tokens.

## Large-file anti-patterns

Do not run any of these directly against a high-latency remote share:

- `[xml](Get-Content $path)`, `Get-Content -Raw`, `ReadAllText`, or
  `StreamReader.ReadToEnd()`;
- `[System.IO.File]::ReadAllBytes()`;
- byte-by-byte or byte-to-hex loops across SMB;
- `Copy-Item` as an improvised substitute for restartable transfer;
- Python `ElementTree.parse()` or another whole-tree parser on a multi-gigabyte
  export;
- a source-side SHA-256 on every retry;
- unbounded `while ($true)` retry loops or the `robocopy` historical default of
  extremely large retry counts;
- `/MIR`, `/MOVE`, cleanup, or source deletion in an agent-controlled copy
  step.

Even a small header read can appear frozen when the first SMB read blocks on a
VPN or DFS problem. A supervisor may then report only `ChildProcess.kill`.
That is why reachability/metadata checks and staging are separate from parsing.

After a successful receipt, Python should parse only the local immutable
artifact. Use the repository's callback-only streaming parser, emit bounded
records, validate expected date fields, and record parse counts/errors against
the receipt SHA-256. DAX Studio, TE2, Power BI, or Databricks reconciliation
should consume that parsed result; they should never each reopen the live UNC
XML independently.

## Tests

The Pester suite mocks UNC metadata and the native copy boundary while using a
temporary local filesystem for promotion and receipt checks:

```powershell
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path '.\tests\powershell' -Output Detailed
```

Run the suite in Windows PowerShell 5.1, not only in modern `pwsh`. It checks
allowlist boundary handling, wildcard rejection, stability changes, capacity,
all `robocopy` success codes `0..7`, the `>=8` failure boundary, destructive
switch absence, ready/fixed destination evidence, ancestor reparse rejection,
sync-root rejection, `.part` staging, local hashing, idempotent promotion races,
sanitized environment-profile failures, and no-BOM UTF-8 receipt creation.

`scripts/Invoke-Checks.ps1` accepts a Pester run only when `Result` is
`Passed`, at least one test was discovered and executed, `FailedCount` is zero,
and no failed container, container error record, or failed block is reported.
Its machine-readable receipt records the run result; discovered/executed counts
and their source properties; pass/fail/skip/not-run counts; failed-container and
failed-block counts; and container failure/error signals. This prevents an
empty or discovery-broken suite from appearing green merely because
`FailedCount` is zero.

## Deliberate limitations

- Length and last-write time detect ordinary active exports, not a malicious or
  unusual producer that changes bytes while preserving both fields. A producer
  completion marker or manifest is stronger when available.
- SHA-256 is intentionally local. Hashing the source would reread the entire
  file over the VPN and doubles network exposure. The receipt proves the local
  artifact's identity, not an independently supplied source checksum.
- The Windows read-only attribute prevents accidental ordinary writes; it is
  not WORM storage. Enforce NTFS ACLs, retention, backups, or platform-level
  immutability if required by control policy.
- Free-space checks are point-in-time observations, not reservations.
- A process environment allowlist is a guardrail. File-share and NTFS ACLs are
  the security boundary.
- Ancestor checks are repeated after destination creation, but PowerShell 5.1
  does not provide a simple handle-relative, race-free directory creation API.
  Protect the local staging root with NTFS ACLs; these checks are defense in
  depth, not protection against an administrator racing path replacement.
- Failed `.part` directories are retained for restart or investigation. Use a
  separate, reviewed retention job to clean old staging data; do not give the
  agent a recursive delete command.
- The staging script validates transport and file integrity, not XML schema,
  encoding declarations, well-formedness, business dates, row counts, or
  Databricks reconciliation. Those belong in the local streaming parser and
  downstream validation stages.

## Primary sources

- [Microsoft: robocopy options and exit codes](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/robocopy)
- [Microsoft: character encoding in Windows PowerShell](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_character_encoding?view=powershell-5.1)
- [Microsoft: Get-FileHash](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/get-filehash?view=powershell-5.1)
