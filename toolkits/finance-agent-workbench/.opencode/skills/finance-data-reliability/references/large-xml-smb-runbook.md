# Large XML over SMB: mandatory operating runbook

Use this runbook for multi-gigabyte SAP spool XML, UNC or mapped-drive input,
VPN/SMB latency, high-latency remote file shares, killed child processes,
timeouts, encoding discovery, or any proposal to create a local staging area.

The purpose is to prevent a plausible exploratory command from becoming an
unbounded network read, an unsafe copy, or false evidence. The required flow is:

1. establish a sanitized comparison contract;
2. perform metadata-only remote preflight;
3. stage exactly once to an approved fixed local volume;
4. parse only the finalized local artifact;
5. validate through XML EOF and business assertions;
6. reconcile against a frozen target snapshot;
7. report a sanitized receipt and every unverified claim.

Do not skip directly from "the path exists" to "the data is valid."

## Non-negotiable boundaries

- Treat the source share as read-only. Never rename, move, delete, rewrite,
  truncate, lock, repair, or change permissions on the source.
- Do not repeatedly parse, hash, grep, or seek through a large file over SMB.
- Do not send raw XML, business records, internal paths, server/share names,
  usernames, screenshots, or verbose command output to the model or Git.
- Do not create a staging directory merely because it is writable. The staging
  root must pass the destination checks in `scripts/Stage-Spool.ps1`.
- Do not claim XML validity, row counts, required-field coverage, or date
  correctness from a prefix, regex, `Test-Path`, `Get-Item`, or a successful
  copy alone.
- Do not increase a timeout until the operation is known to be bounded and
  progress is independently observable.

## Classify every statement

Use these labels in plans and receipts:

- **Observed:** directly returned by a bounded command, such as source length
  and UTC last-write time from a metadata call.
- **Inferred:** a hypothesis supported by observations, such as an orchestrator
  timeout probably terminating an otherwise running copy.
- **Verified:** proven by the required deterministic gate, such as valid XML
  EOF plus zero missing required fields on the staged artifact.

Examples:

| Statement | Correct label |
|---|---|
| `Test-Path` returned true | Observed path visibility in that process context |
| A child process was killed after two minutes | Observed supervisor termination; root cause remains inferred |
| The first bytes look like UTF-16 XML | Inferred encoding hypothesis until the parser confirms it |
| The document contains the expected number of rows | Verified only after the streaming parser reaches valid EOF |
| The source and Databricks agree | Verified only against declared snapshots, grain, keys, measures, and tolerances |

## Phase 0: define the contract before touching content

Record, without exposing sensitive values:

- exact source selected by the user or approved workflow;
- whether the producer has a completion marker;
- expected approximate size and expected transfer duration;
- expected XML record qualified name, if known;
- required key and date fields, if known;
- expected date range and whether dates are calendar or fiscal;
- expected business grain and duplicate-key policy;
- target Databricks snapshot or extraction time;
- expected row count, if it is an independent business assertion;
- allowed reconciliation tolerances;
- approved local staging volume and retention owner.

An expected row count is an assertion to test. It is not permission to stop
reading after that many apparent tags, and it is not evidence until valid XML
EOF is also reached.

## Phase 1: capture the effective runtime safely

The supported workstation baseline is Windows PowerShell 5.1 on .NET Framework
4.x with Python 3.11 or later. Record versions, but sanitize identity output.

```powershell
$PSVersionTable | Select-Object PSVersion, CLRVersion
python --version
whoami
```

Do not commit or publicly paste the actual `whoami` result, workstation name,
environment dump, Kerberos tickets, HTTP request payloads, or internal paths.

Python 3.12 and later deprecate naive `datetime.utcnow()`. Maintained scripts
must create timezone-aware UTC values:

```python
from datetime import datetime, timezone

instant = datetime.now(timezone.utc)
stamp = instant.strftime("%Y%m%dT%H%M%SZ")
iso_utc = instant.isoformat(timespec="seconds").replace("+00:00", "Z")
```

A deprecation warning does not by itself invalidate a completed run, but the
warning must be fixed so future runtime upgrades do not turn it into a failure.

## Phase 2: metadata-only remote preflight

Use the same Windows identity and noninteractive context that will stage the
file. Prefer the exact UNC path; mapped drives belong to a logon session and
may disappear under an agent or scheduled process.

Allowed metadata observations include:

```powershell
$exists = Test-Path -LiteralPath '\\server\approved-share\path\source.xml' `
    -PathType Leaf -ErrorAction Stop

if (-not $exists) {
    throw 'The approved source is not visible as a file in this process context.'
}

$metadata = Get-Item -LiteralPath `
    '\\server\approved-share\path\source.xml' -ErrorAction Stop

$metadata | Select-Object Length, LastWriteTimeUtc, Attributes
```

Redact the literal source before sharing the output. These commands establish
only visibility and metadata at one instant. They do not establish:

- the ability to sustain a long content read;
- producer completion or source stability;
- XML encoding or well-formedness;
- valid EOF;
- record count, required fields, dates, or amounts;
- agreement with Databricks.

### PowerShell Boolean trap

Never write this:

```powershell
Test-Path -LiteralPath $path
if ($?) { 'exists' }
```

`$?` says whether `Test-Path` itself completed without a terminating error. A
valid `Test-Path` call that emits `False` can still leave `$?` equal to `True`.
Branch on the returned Boolean:

```powershell
if (Test-Path -LiteralPath $path -PathType Leaf) {
    'exists'
}
else {
    'missing'
}
```

Use `$LASTEXITCODE` immediately after a native executable or script process
when its documented process exit code is the evidence being captured.

## Phase 3: understand bounded reads before using one

A bounded prefix read is optional diagnostic evidence. It is not the staging
or parsing workflow. By default, perform it only on the finalized local
artifact. Limit it explicitly, avoid printing content, and label the result
provisional.

Do not run a synchronous UNC `Open`/`Read` inside an interactive agent shell:
even a four-byte read can block before returning. Staging is encoding-agnostic,
so a remote BOM probe is normally unnecessary. If policy requires one before
staging, use a separately managed diagnostic worker with an enforced
wall-clock limit; a timeout result is **inconclusive**, not evidence of file
corruption.

### Python evaluation-order trap

This is forbidden for a large file:

```python
prefix = path.read_bytes()[:8000]
```

Python evaluates `path.read_bytes()` first. It reads and allocates the complete
file and only then returns an 8,000-byte slice. The slice does not bound the
read.

A truly bounded binary read is:

```python
from pathlib import Path

path = Path(r"C:\approved-local-artifact\source.xml")
with path.open("rb") as stream:
    prefix = stream.read(8000)

prefix_length = len(prefix)
```

Prefer doing even this against the staged local artifact. Do not print the raw
prefix because it may contain business data.

### `Get-Content -TotalCount` trap

This is forbidden as a bounded-byte XML probe:

```powershell
Get-Content -LiteralPath $path -TotalCount 80
```

In the text-mode command above, `-TotalCount 80` requests 80 text lines/content
objects. It does not request 80 bytes, XML elements, or business records. A
minified export may be one enormous line, so PowerShell can consume gigabytes
while searching for line 80. Windows PowerShell has special byte-mode behavior,
but repository policy still requires an explicit bounded `FileStream` rather
than relying on provider/encoding semantics.

### Minimal PowerShell BOM probe

On the finalized local artifact, read at most four bytes and do not decode or
print record content:

```powershell
$path = 'C:\approved-local-artifact\source.xml'
$stream = $null
try {
    $stream = [System.IO.File]::Open(
        $path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $bytes = New-Object byte[] 4
    $read = $stream.Read($bytes, 0, $bytes.Length)

    $encodingHint = if ($read -ge 4 -and
        $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and
        $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        'utf-32-le-bom'
    }
    elseif ($read -ge 4 -and
        $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and
        $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        'utf-32-be-bom'
    }
    elseif ($read -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        'utf-8-bom'
    }
    elseif ($read -ge 2 -and
        $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        'utf-16-le-bom'
    }
    elseif ($read -ge 2 -and
        $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        'utf-16-be-bom'
    }
    else {
        'no-bom-or-unknown'
    }

    [pscustomobject]@{
        bytes_read = $read
        encoding_hint = $encodingHint
        validated = $false
    } | ConvertTo-Json -Compress
}
finally {
    if ($null -ne $stream) {
        $stream.Dispose()
    }
}
```

If this pattern is ever placed back on a remote path, `Open` or `Read` can
block during a VPN, DNS, DFS, SMB, or authorization problem. A killed child
still proves only that the host ended the process. Do not convert a host
timeout into a claim of file corruption.

If there is no BOM, do not guess UTF-8 or UTF-16 from arbitrary decoded text.
Let the streaming XML parser inspect the declaration on the local artifact.

## Phase 4: never validate XML with regex

A command such as the following can be useful only as a disposable hypothesis
on a bounded, non-sensitive local fixture; it is not XML validation:

```text
regex: <item>(.*?)</item>
```

It can fail or mislead because:

- the opening or closing tag can cross the chosen chunk boundary;
- default namespaces and prefixes change the tag representation;
- attributes, whitespace, comments, CDATA, and entity escaping are XML syntax;
- `.` may not match line breaks under the chosen regex mode;
- nested elements cannot be parsed correctly with a flat expression;
- a prefix cannot prove closing tags or valid EOF;
- a sample of values cannot prove total row count or required-field coverage.

Use the repository's XML parser for validation. If the row qualified name is
unknown, derive a provisional candidate from an approved synthetic/sample
schema or a bounded local structural tool, then confirm it by parsing the
entire finalized local artifact through EOF. Never promote a regex result from
**inferred** to **verified**.

## Phase 5: choose a real local staging destination

"Local" has a strict operational meaning:

- the volume reports ready and fixed;
- the root is outside OneDrive and every configured sync root;
- no existing ancestor is a reparse point, junction, mount point, or symbolic
  link that redirects storage;
- sufficient free space exists for the source plus reserve;
- the process can create and atomically rename within the same volume;
- retention, access, and cleanup ownership are approved.

The repository may live in OneDrive. The data landing zone must not. Never
create `local_staging` underneath the workspace as an improvised solution.

Check the proposed destination without exposing it in shared output:

```powershell
./scripts/Get-EnvironmentProfile.ps1 `
    -LocalStagingRoot 'C:\SpoolStage'
```

Proceed only when the sanitized result reports
`local_destination_confirmed: true`. The profile and staging wrapper reject
configured OneDrive roots and unsafe ancestors.

## Phase 6: stage exactly once through the supported wrapper

Set the source allowlist in a trusted launcher or approved PowerShell terminal,
not in committed configuration:

```powershell
$env:SPOOL_ALLOWED_UNC_ROOTS = '\\server\approved-share\sap-spool'
$sourcePath = '\\server\approved-share\sap-spool\path\source.xml'
$destinationRoot = 'C:\SpoolStage'
$scriptPath = (Resolve-Path -LiteralPath '.\scripts\Stage-Spool.ps1').Path
$windowsPowerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'

$stageJson = & $windowsPowerShell `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -File $scriptPath `
    -SourcePath $sourcePath `
    -DestinationRoot $destinationRoot `
    -StabilityProbeCount 3 `
    -StabilityProbeSeconds 5 `
    -ReserveBytes 1073741824 `
    -RobocopyRetryCount 2 `
    -RobocopyWaitSeconds 5
$stageExitCode = $LASTEXITCODE

if ($stageExitCode -ne 0) {
    $failureClass = 'unclassified'
    try {
        $failureEnvelope = $stageJson | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $failureEnvelope.failureClass) {
            $failureClass = [string] $failureEnvelope.failureClass
        }
    }
    catch {
        # Keep the fallback generic; never echo unparsed process output.
    }
    throw "Staging failed with sanitized failure class '$failureClass' " +
        "and process exit code $stageExitCode."
}

$stageReceipt = $stageJson | ConvertFrom-Json
$artifactPath = Join-Path $destinationRoot `
    $stageReceipt.artifact.relativePath
```

The wrapper performs policy checks, repeated source metadata observations,
capacity validation, restartable unbuffered copy, source restat, local length
and SHA-256 verification, content-addressed promotion, read-only marking, and
atomic receipt creation. It deliberately does not parse XML or validate
business fields.

Do not replace it with `Copy-Item`, `Get-Content`, a Python copy loop, or a
manually created destination. Do not add `/MIR`, `/MOVE`, `/PURGE`, `/DELETE`,
unbounded retries, or cleanup of the source.

### Transfers longer than the agent shell limit

An interactive agent shell may terminate a command at a configured wall-clock
limit even while Windows and SMB are still working. For a multi-gigabyte VPN
copy whose expected duration exceeds that limit:

A host limit of `120000 ms` is two minutes. Treat such a shell as suitable for
metadata preflight and command preparation only when the transfer cannot be
proven to complete inside that boundary. Do not solve this by launching
`Start-Job` or `Start-Process` inside the same agent host unless the runner
explicitly guarantees that the child survives parent termination and provides
durable logs, exit status, cancellation, and receipt retrieval.

1. run the approved `Stage-Spool.ps1` invocation in a normal company-approved
   PowerShell terminal or approved job runner under the correct Windows token;
2. keep the terminal/job alive and capture its final exit code;
3. preserve the deterministic `.part` directory after interruption;
4. rerun the exact same invocation so `robocopy /Z` can resume;
5. return only the sanitized JSON receipt or failure envelope to the agent.

Do not use a different mapped drive or credential workaround merely because a
background context cannot see the interactive mapping. Use the approved UNC
path and resolve identity/ACL problems through the proper administrator.

### Elapsed-time heartbeat without false progress claims

For a bounded validation command that is proven to fit inside the agent host's
wall-clock limit, follow the repository's
[long-running task observability](../../../../docs/long-running-task-observability.md)
contract and use `runwatch`. It emits a monotonic elapsed timer to stderr and
can atomically publish a sanitized status file on approved local storage.

A fresh `running` heartbeat proves only that the attached supervisor observed
the direct child had not exited. It does not prove that an SMB read returned,
a copy advanced, XML bytes were parsed, records were accepted, or a
reconciliation is correct. Actual progress requires measured worker-specific
events such as local bytes staged, parser bytes consumed, records validated,
and completed assertions.

Do not place `runwatch` around the multi-gigabyte transfer inside a host capped
at `120000 ms`; the wrapper cannot extend that limit or survive it. Launch both
the approved operation and `runwatch` from the approved durable terminal/job
runner described above. A stale nonterminal status is **unknown/inconclusive**,
not a failure verdict or permission to start a competing copy.

## Phase 7: parse only the finalized local artifact

Use `$artifactPath`, derived by joining the approved destination root with
`artifact.relativePath` from the successful stage receipt. The concrete layout
is `objects\<first-two-hash-characters>\<sha256>.xml`; never guess a filename.
Do not point `spoolctl` at a UNC path, mapped network drive, `.part` file,
OneDrive path, or mutable working copy.

```powershell
$env:PYTHONPATH = "$PWD\src"

$inspectJson = python -m spoolctl inspect `
    $artifactPath `
    --row-qname '{urn:example}row' `
    --required-field '{urn:example}document-number' `
    --required-field '{urn:example}entry-date'

$inspectExitCode = $LASTEXITCODE
if ($inspectExitCode -ne 0) {
    throw "XML inspection failed with process exit code $inspectExitCode."
}
$inspectReceipt = $inspectJson | ConvertFrom-Json
```

Replace qualified names with the approved schema values. Do not invent a field
from a partial text match. The parser is callback-based, rejects remote input,
rejects DTD/entity declarations, enforces finite resource limits, detects
source mutation between passes, requires valid EOF, and publishes output
atomically only after validation.

The parser validates XML structure and required-field presence. A separate
deterministic transformation must explicitly parse business dates and amounts,
count invalid values, enforce key rules, and produce its own receipt.

## Phase 8: acceptance gates

Do not mark the XML stage passed unless the receipt proves every applicable
gate:

| Gate | Required evidence |
|---|---|
| Source selection | Exact source chosen under an approved root; sanitized source/root fingerprints |
| Producer completion | Completion marker or stable length and UTC last-write observations |
| Transport | Successful stage exit, source unchanged across copy, local length verified |
| Artifact identity | Local SHA-256 and content-addressed relative artifact path |
| XML safety | DTD/entity policy passed and all parser resource limits remained within contract |
| XML completeness | `completed_eof: true` |
| Schema | Expected root/row expanded qualified names and schema fingerprint |
| Required fields | Missing-required counts equal zero unless an explicit exception exists |
| Record population | Row count compared with an independently declared expectation |
| Business keys | Null/blank/duplicate counts compared with the written grain contract |
| Dates | Explicit format, timezone/fiscal rule, invalid count, and min/max bounds |
| Amounts | Decimal parsing, scale, sign, currency, null, and rounding rules |
| Outputs | Atomic publication, output fingerprint, bounded/sanitized logs |

A row-count match does not override malformed XML, missing fields, or duplicate
keys. Valid XML does not prove correct finance semantics.

## Phase 9: reconcile with Databricks

Only after local parsing passes should reconciliation proceed. Freeze the
source artifact hash and the Databricks snapshot/extraction time, then compare:

1. shape, schema, row counts, date bounds, nulls, and duplicates;
2. global decimal totals under explicit sign/currency/rounding rules;
3. grouped totals by period and stable low-cardinality dimensions;
4. missing, extra, duplicate, and changed business keys;
5. bounded exception samples with sensitive values redacted.

Use read-only SQL unless the user separately authorizes an exact controlled
write. Do not hide a mismatch with an unexplained filter, sign flip, tolerance,
deduplication, or hard-coded adjustment.

## Known failure signatures and exact interpretation

| Observed command or symptom | What it actually means | Required response |
|---|---|---|
| `Path.read_bytes()[:N]` | Complete file read occurs before slicing | Stop; replace with `open('rb').read(N)` only for a justified bounded diagnostic, preferably local |
| `Get-Content -TotalCount N` | Reads N text lines, potentially scanning one enormous XML line | Stop; do not increase timeout or treat N as bytes/rows |
| Bounded `FileStream.Read` succeeds | A prefix was readable under that identity at that instant | Record only bounded-read/encoding evidence; do not claim XML validity |
| Prefix decoded with a hard-coded encoding | Text may be misdecoded when BOM/declaration differs | Detect BOM; let the local XML parser honor the declaration |
| Regex finds `<item>` values | A partial lexical pattern matched | Label as a schema hypothesis; never use as row-count or validity evidence |
| `Test-Path` is true | The path was visible | Continue with stability, staging, and validation gates |
| `if ($?)` follows `Test-Path` | Branch tests command execution, not emitted Boolean | Store/branch on the actual `Test-Path` result |
| `ChildProcess.kill`, `Shell Unknown`, or timeout | Supervisor ended the command; root cause is unproven | Determine whether work was bounded and progressing; use approved long-running execution for staging |
| `local_staging` created under OneDrive | Writable path was mistaken for a valid landing zone | Stop before copying; use the validated fixed-volume root |
| `datetime.utcnow()` warning | Naive UTC API is deprecated | Use timezone-aware UTC; do not confuse warning with data validation failure |
| Expected count matches a prefix/sample | Sampling happened to match an expectation | Parse the immutable artifact through EOF and check all invariants |

## Public Git and prompt hygiene

Never commit or paste:

- screenshots containing internal paths or report names;
- real UNC paths, mapped-drive targets, usernames, organization names, or
  workstation paths;
- source XML, normalized finance rows, CSV exceptions, PBIX files, or receipts
  containing raw paths;
- access tokens, request headers, environment dumps, SQL containing sensitive
  identifiers, or Databricks connection details;
- raw `robocopy` tails or traceback text before sanitization.

Commit only stable rules, placeholders, synthetic fixtures, typed failure
classes, sanitized receipt schemas, and regression tests. A public toolkit can
contain the method; company-specific knowledge belongs in an approved private
repository or governed catalog.

Before publication, scan both the candidate tree and Git history with the
organization-approved secret scanner. Also review path-shaped literals, image
attachments, generated manifests, shell transcripts, and deleted files that
remain reachable in history. A clean current checkout does not prove clean
history.

If a credential or token was ever committed, removing the line in a later
commit is insufficient. Stop publication, revoke or rotate the credential,
notify the appropriate security owner, and use the organization's approved
history-rewrite procedure. Do not improvise a force-push to a shared branch.

A repository being technically private does not establish company approval
for its host, collaborators, data classification, retention, or geographic
storage. Confirm those controls before adding company-specific knowledge.

## What permanent agent learning means

An agent correcting its next command in the same conversation is adaptation,
not durable learning. A failure becomes durable knowledge only when all three
artifacts exist:

1. a sanitized rule or failure-taxonomy entry;
2. a minimal synthetic fixture or reproducible example;
3. a regression test that fails if the protection disappears.

After a new incident, update those artifacts instead of storing the raw chat or
screenshot. Future agents must load this runbook through `SKILL.md`; reasoning
effort alone does not preserve it.

## Copy/paste instruction for the agent

Use this when an agent starts improvising against a large remote XML file:

```text
Stop the current content read and load the finance-data-reliability skill,
including the large-xml-smb-runbook and failure taxonomy.

Treat the remote source as read-only. Do not use Path.read_bytes(),
Get-Content -Raw or -TotalCount, ReadAllBytes, regex XML validation,
ElementTree.parse(), Copy-Item, a manually created local_staging directory,
or repeated remote hashing/parsing.

Report separately what is observed, inferred, and verified. Perform only
metadata/stability and approved-destination preflight on the remote side.
Stage exactly once with scripts/Stage-Spool.ps1 to a validated non-OneDrive
fixed local root. If the copy exceeds the interactive shell limit, provide the
approved PowerShell invocation for a normal terminal/job runner and wait for
its sanitized receipt. Then run spoolctl only against the finalized local
artifact and require valid EOF, expected qualified names, required fields,
row-count assertion, key/date validation, and a sanitized manifest before
Databricks reconciliation.
```
