# Long-running task observability

Use `runwatch` when a bounded, noninteractive command may be quiet long enough
that a person or agent cannot tell whether it is still running.

`runwatch` provides:

- an immediate start message;
- a heartbeat on stderr every 15 seconds by default;
- monotonic elapsed time;
- direct-child liveness observations;
- inherited child stdout and stderr, without wrapper-owned pipe buffering;
- exact child exit-code propagation for ordinary process exit codes;
- an optional atomically replaced, sanitized local status JSON file;
- a final `exited`, `interrupted`, or launch/wrapper-failure event.

It has no third-party runtime dependency.

## Four claims that must stay separate

| Claim | Evidence | What it does not prove |
|---|---|---|
| The supervisor is alive | A current `runwatch` heartbeat | The child is advancing through business work |
| The direct child had not exited | `child.observedRunning: true` in a current status file | The child is not blocked inside a network, file, or lock operation |
| The observation is current | `updatedUtc` is still within `staleAfterSeconds` | The next heartbeat will arrive or the process will survive its host |
| The work is progressing | Phase-specific bytes, records, or completed assertions emitted by the child | The final result will pass |

A timer solves uncertainty about elapsed time. It is not automatically a
progress meter. A Python process may be computing correctly, blocked on SMB,
waiting on a lock, or stuck while heartbeats continue normally. Report only
the liveness evidence actually observed; never convert it into a progress
claim.

## Hard host timeout boundary

`runwatch` is an attached supervisor, not a durable scheduler. If OpenCode or
another host kills the process tree after a hard wall-clock limit, the wrapper
cannot preserve the child.

For example, a host limit of `120000 ms` is two minutes:

- If the command is proven to finish inside two minutes, run it under
  `runwatch` in the agent shell.
- If it may exceed two minutes, prepare the exact command in the agent, then
  run `runwatch` from a normal company-approved PowerShell terminal or durable
  job runner under the correct Windows identity.
- Do not assume `Start-Job` or `Start-Process` launched from inside the
  short-lived agent shell will survive termination of that shell.
- A durable runner must preserve logs, status, cancellation, exit code, and
  receipt retrieval independently of the agent session.

Heartbeat output may prevent an **idle-output** timeout in some hosts. It
cannot override a fixed maximum wall-clock timeout.

## Status-file boundary

The optional status file must be:

- an absolute path;
- under an already-existing, approved local directory;
- on a ready fixed local volume on Windows;
- outside UNC paths, mapped network drives, OneDrive, and configured sync
  roots;
- outside symbolic-link, junction, mount-point, and reparse-point ancestors;
- inside an owner-controlled, non-shared directory. On Windows, provision and
  review the directory ACL so untrusted users cannot create or replace files.

The target file must not already exist, so each run preserves earlier evidence
and avoids accidental status-path reuse. The wrapper refuses to create the
parent directory. Validate and provision the local run root separately. Do not
use the report repository or a convenient `local_staging` folder as an
implicit status destination.

`runwatch` takes an exclusive sibling lock before launching the child and uses
a fresh, random, exclusively created temporary file for every update. Each
temporary is verified as the same regular file before same-directory atomic
replacement. Replacement is retried only a small bounded number of times for
transient Windows reader or antivirus sharing conflicts. Never relax the
directory ACL or reuse a status target to work around a refusal.

The status file contains no raw command, argument, command fingerprint, path,
child output, environment value, or raw exception text. The user-supplied
label is included, so keep it generic and nonsensitive.

The child inherits the wrapper's stdout and stderr handles. `runwatch` itself
writes nothing to stdout, so machine-readable child stdout remains unchanged
and there are no wrapper-owned output pipes to deadlock. Heartbeats share
stderr with any child diagnostics and can interleave with them. Machine
consumers must poll the atomic status JSON instead of parsing stderr. The child
remains responsible for sanitizing its own output.

A blocked higher-level stderr consumer can also block a human heartbeat. A
closed or broken heartbeat sink is treated as degraded observability and does
not cancel the child; continue polling the status file. Neither behavior turns
the heartbeat into evidence of data progress.

Because this is a general process launcher, it does not grant permission to
run a command. OpenCode must still ask under the repository's command policy,
and the operator must still approve the exact executable and tokenized
arguments. Do not put secrets in arguments; operating-system process listings
may expose them.

## Installation and discovery

From the toolkit root, either install the local package:

```powershell
python -m pip install -e .
runwatch --help
```

or use it without installation:

```powershell
$env:PYTHONPATH = "$PWD\src"
python -m runwatch --help
```

Use the same Python executable for the supervisor and the child unless the task
has a documented reason to select another interpreter.

The executable itself must be a regular file on a ready fixed local volume,
outside mapped drives, configured sync roots, and reparse ancestry. If the
currently discovered Python environment lives inside OneDrive, select or
provision an organization-approved local interpreter; do not weaken the check.

## PowerShell 5.1 invocation

Build arguments as an array. Do not concatenate a `-Command` string and do not
use `Invoke-Expression`. Pass a native executable such as `python.exe` or
`powershell.exe` to `runwatch`; do not pass a `.ps1`, `.cmd`, or `.bat` file as
the executable. Invoke a PowerShell script with explicit
`powershell.exe -NoLogo -NoProfile -NonInteractive -File` arguments.

Replace the placeholders only inside the approved company environment:

```powershell
$python = (Get-Command python -ErrorAction Stop).Source
$statusRoot = 'C:\SpoolStage\run-status'
$statusName = 'xml-validation.{0}.runwatch.json' -f `
    ([guid]::NewGuid().ToString('D'))
$statusPath = Join-Path $statusRoot $statusName
$childScript = 'C:\approved-project\xml_validation.py'

if (-not (Test-Path -LiteralPath $statusRoot -PathType Container `
        -ErrorAction Stop)) {
    throw 'The approved local status directory does not exist.'
}

$runwatchArguments = @(
    '-m'
    'runwatch'
    '--heartbeat-seconds'
    '15'
    '--status-out'
    $statusPath
    '--label'
    'xml-validation'
    '--'
    $python
    $childScript
    '--source-xml'
    '\\server\approved-share\path\source.xml'
    '--staging-root'
    'C:\SpoolStage'
    '--year'
    '2026'
    '--period'
    '7'
)

& $python @runwatchArguments
$runExitCode = $LASTEXITCODE
```

The example demonstrates argument handling only. The child must still follow
the large-XML/SMB runbook: remote metadata preflight, `Stage-Spool.ps1`,
receipt-derived local artifact, local streaming parse, and business assertions.
A heartbeat wrapper does not authorize a custom Python script to parse or copy
the live UNC source.

## Heartbeat format

Human-readable heartbeats go to stderr so they do not corrupt a child's
machine-readable stdout:

```text
[runwatch] run=00000000-0000-0000-0000-000000000000 label=xml-validation state=running elapsed=00:03:15 heartbeat=14 pid=1234
[runwatch] run=00000000-0000-0000-0000-000000000000 label=xml-validation state=exited elapsed=00:08:41 heartbeat=35 pid=1234 exit=0
```

Fields:

- `label` — generic operator-selected label;
- `run` — generated nonsensitive run UUID for heartbeat/status correlation;
- `state` — supervisor/child lifecycle state;
- `elapsed` — monotonic elapsed time, not wall-clock subtraction;
- `heartbeat` — increasing sequence number;
- `pid` — direct child process ID;
- `exit` — observed child or reserved wrapper exit code when complete.

The first heartbeat is emitted immediately after the child starts. Therefore,
a blank terminal after invoking `runwatch` means the wrapper did not reach that
point, the child launch has not completed, or output is being buffered by a
higher-level host.

## Status JSON

The wrapper atomically replaces a small JSON file at each heartbeat. A typical
shape is:

```json
{
  "schemaVersion": 1,
  "runId": "00000000-0000-0000-0000-000000000000",
  "label": "xml-validation",
  "state": "running",
  "terminal": false,
  "startedUtc": "2026-01-01T12:00:00.000Z",
  "updatedUtc": "2026-01-01T12:03:15.000Z",
  "finishedUtc": null,
  "elapsedSeconds": 195.0,
  "heartbeatSequence": 14,
  "heartbeatSeconds": 15.0,
  "staleAfterSeconds": 60.0,
  "child": {
    "pid": 1234,
    "started": true,
    "observedRunning": true,
    "exitCode": null
  },
  "cancellation": {
    "requested": false,
    "method": null
  },
  "guarantees": {
    "livenessOnly": true,
    "progressVerified": false,
    "survivesSupervisor": false,
    "processTreeContained": false
  }
}
```

The example UUID, timestamps, and PID are synthetic.

Because this is a small local JSON status file, it is safe to inspect with
`Get-Content -Raw`. That does not weaken the prohibition on using
`Get-Content -Raw` against large XML:

```powershell
$status = Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop |
    ConvertFrom-Json

$status |
    Select-Object state, elapsedSeconds, heartbeatSequence,
        terminal,
        @{Name = 'childObservedRunning'; Expression = {
            $_.child.observedRunning
        }},
        @{Name = 'childExitCode'; Expression = { $_.child.exitCode }}
```

## Stale-heartbeat interpretation

The status records the configured `staleAfterSeconds`, whose default is
`max(3H, 60 seconds)` for heartbeat interval `H`. A nonterminal record becomes
stale only after an observer rereads it and finds that `updatedUtc` plus that
threshold is no later than the observer's current UTC time.

Use this decision order:

1. Confirm the status file is the one for the intended run ID.
2. Check whether the direct child PID still exists in the same process context.
3. Check whether the supervising terminal/job runner is still alive.
4. Check local CPU, disk, and network activity without dumping sensitive data.
5. Inspect only sanitized, bounded log tails.
6. Classify a fresh nonterminal record as a current liveness observation, a
   terminal record by its state and child exit code, and a stale nonterminal
   record as **unknown/inconclusive**.

Do not automatically kill a process because it has been quiet. Some valid
parsers and hashes produce no output for long periods. Do not automatically
restart a stale run; first determine whether the prior child still owns the
staging artifact or lock.

## States and exit behavior

| State | Meaning |
|---|---|
| `starting` | Initial status written before the child launch |
| `running` | Direct child has not exited |
| `exited` | Direct child exit was observed; inspect the exact `child.exitCode` and the child's own postcondition |
| `launch-failed` | The child could not be started; no child exit code was invented |
| `interrupted` | Wrapper received keyboard interruption and attempted to stop the direct child |
| `wrapper-failed` | The wrapper could not establish or complete its own observation contract |

`125` is reserved for wrapper failure and `130` for keyboard interruption.
The status JSON preserves an observed direct-child exit code separately. A
zero child exit still does not prove business success; require the child's
receipt or other documented postcondition. Uncommon Windows exit values
outside the ordinary `0..255` range must be validated on the target workstation
before relying on exact shell propagation.

When a requested status update cannot be published, stderr reports
`state=status-update-failed`. The wrapper still returns the observed ordinary
child code so it does not invent a child result. Treat a missing or nonterminal
final status as **inconclusive even when the child code is zero** and inspect
the child's independent receipt/postcondition.

On Windows, the wrapper starts a cooperative console process group. On
keyboard interruption it first attempts a targeted `CTRL_BREAK_EVENT`, then a
bounded direct-child terminate/kill fallback. These actions still do not prove
every descendant process—such as a separately spawned `robocopy`—was stopped.
An interrupted status records the attempted method, not process-tree
containment. Do not use `runwatch` as a production job-control system.

Before production use, run a bounded integration on the actual Windows
PowerShell 5.1/Python workstation. Verify inherited redirected output,
Ctrl+C/`CTRL_BREAK_EVENT` and forced fallback, locked-status replacement,
mapped/sync/reparse path rejection, ordinary and high Windows exit codes, and
immediate PowerShell capture of `$LASTEXITCODE`. Linux tests do not prove the
workstation console, endpoint-protection, or file-sharing behavior.

## Retrofitting a command that is already running

A wrapper cannot be inserted around a process that has already started. Do not
cancel useful multi-gigabyte work solely to add a timer.

For the current run, use a separate approved terminal to check:

- whether the expected Python process still exists;
- whether the approved local staging file's length or last-write time changes;
- local disk/network activity;
- whether a final receipt or output appears.

Avoid repeated recursive scans. Monitor the exact known local artifact or run
directory. Treat process existence as liveness evidence and file growth as
transport progress; neither proves final XML or reconciliation success.

Use `runwatch` from the next invocation onward.

## Child progress protocol

The generic wrapper observes only attached-supervisor/direct-child liveness.
For meaningful percent, rate, ETA, records, or phases, the child must emit
bounded progress based on measured work.

Recommended child events are:

- `phase=preflight`;
- `phase=staging bytes_done=<n> bytes_total=<n>`;
- `phase=parsing bytes_done=<n> bytes_total=<n> rows=<n>`;
- `phase=validating assertion=<name>`;
- `phase=reconciling group=<sanitized-name>`;
- `phase=complete receipt=<relative-or-fingerprinted-id>`.

Never print raw records, paths, keys, SQL, hostnames, or exception dumps as
progress. Percent and ETA must be based on measured completed units, not an
invented model estimate.
