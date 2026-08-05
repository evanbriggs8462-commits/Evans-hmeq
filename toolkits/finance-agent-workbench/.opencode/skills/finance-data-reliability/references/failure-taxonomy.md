# Failure Taxonomy

Diagnose the failing layer before changing code. Capture the stage, UTC time, elapsed time, executable and version, exit code or termination signal, sanitized stderr tail, input fingerprint, and last completed assertion. A killed child process is an observation, not a root cause.

## Triage order

1. Prove effective configuration, executable path, version, architecture, and non-secret environment settings.
2. Prove remote path visibility and permissions with a metadata-only preflight.
3. Prove that the producer has finished and the remote file is stable.
4. Stage one local copy and prove its size/integrity.
5. Prove XML well-formedness and encoding with a streaming parser.
6. Prove record/schema/date/amount semantics.
7. Reconcile the parsed result against a frozen target snapshot.

For a Power BI service incident, use this separate order instead of forcing the
file pipeline onto the problem:

1. Prove the authenticated identity source without exposing the token.
2. Prove the exact sanitized workspace/model target and model category.
3. Classify REST, Fabric REST, XMLA, remote MCP, local Modeling MCP, or Desktop.
4. Inspect OAuth scope, workspace/item role, ownership, tenant setting, and
   effective capacity XMLA setting independently.
5. For an accepted asynchronous request, recover its request ID and poll the
   same operation before considering a retry.
6. Separate transport acceptance, metadata persistence, processing, M/data
   acquisition, DAX behavior, and rollback evidence.

Retry only after classifying a failure as transient. Use bounded attempts with backoff and jitter. Repeating the same deterministic failure produces noise, not evidence.

## Common failure classes

| Symptom | Likely layer and evidence | Safe response |
|---|---|---|
| Works interactively but fails under the agent | Different executable, PATH, profile, bitness, working directory, service identity, credential context, or environment | Record effective values; invoke the explicit executable with argument arrays; avoid profile dependence; never copy credentials into the script |
| Child process is killed or returns no useful error | Orchestrator timeout/cancellation, output-buffer deadlock, memory limit, endpoint protection, user cancellation, or host termination | Record wall time, signal/exit code, stdout/stderr byte counts, and heartbeat; bound output; write sanitized logs; increase a timeout only after proving progress |
| Command is quiet and the session appears frozen | Lack of output alone does not distinguish useful computation, blocking, or a hang | If the bounded command fits the host limit, use `runwatch` and its atomic status; treat heartbeat as direct-child liveness only and require child-specific progress/postconditions |
| A nonterminal `runwatch` status becomes stale | The supervisor stopped publishing; parent, child, host, or status storage may have failed | Classify the run as unknown/inconclusive; inspect the approved runner and exact local artifact before retrying; never infer success or permission to kill/restart |
| Remote read hangs, resets, or becomes very slow | VPN/SMB latency, reconnect, DNS/authentication transition, server load, offline caching, or repeated remote seeks | Stop parsing remotely; preflight once, stage locally with resumable/bounded copy behavior, then parse the verified local file |
| Access denied or path not found | Wrong identity, disconnected VPN, name resolution, stale mapping, path quoting, permissions, or a nonexistent source | Test the literal path and current identity without mutation; stop rather than working around access controls |
| File size or timestamp changes during copy | Producer is still writing, replacement is in progress, or snapshot is unstable | Require two stable observations separated by an appropriate interval or a producer completion marker; stage to `.part`; retry later |
| Local and remote sizes differ, or hash changes | Partial transfer, remote mutation, stale/replayed input, or wrong wildcard selection | Reject the local copy; retain the failed receipt; select an exact input; restage into a new run directory |
| PowerShell consumes excessive memory | Whole-file `Get-Content`, implicit pipeline materialization, string concatenation, byte-to-hex conversion, or collecting all objects | Stream bytes/records; bound header/trailer inspection; emit summaries instead of large objects; use 64-bit PowerShell for large workloads |
| Python prefix inspection is killed after `Path.read_bytes()[:N]` | `read_bytes()` loads the complete file before Python applies the slice | Stop the command; use `open('rb').read(N)` only for a justified bounded diagnostic, preferably on the finalized local artifact |
| `Get-Content -TotalCount N` times out on XML | `TotalCount` counts text lines, not bytes, tags, or records; a minified export may be one enormous line | Do not increase the timeout; stop using line-oriented inspection and follow the large-XML/SMB runbook |
| A bounded prefix or regex returns plausible fields | Only the sampled bytes and lexical matches were observed; chunk boundaries, namespaces, entities, and EOF remain untested | Label the result a schema hypothesis; validate the finalized local artifact with the streaming XML parser |
| A `local_staging` folder was created under OneDrive or the workspace | A writable path was mistaken for a validated local landing zone | Stop before copying; use `Stage-Spool.ps1` with a ready fixed volume outside every sync root and reparse-point ancestor |
| `if ($?)` reports success after `Test-Path` emitted `False` | `$?` describes command execution, not the Boolean object emitted by `Test-Path` | Store or branch directly on `Test-Path -LiteralPath ...`; capture `$LASTEXITCODE` separately for native commands |
| Process hangs while producing lots of output | Parent is not draining stdout/stderr or the agent is trying to ingest unbounded output | Drain both streams concurrently or redirect to bounded files; emit periodic structured progress and a short sanitized tail |
| Command works with simple paths but not real paths | Quoting, wildcard expansion, provider semantics, special characters, long paths, or string-built command injection | Use literal-path APIs and argument arrays; avoid command-string construction; log a sanitized normalized target |
| XML fails near end of file | Truncated export/copy, missing closing element, encoding damage, or producer still writing | Verify copy integrity and inspect only a bounded trailer; run a streaming well-formedness check before semantic parsing |
| XML fails at the first bytes | BOM/encoding mismatch, non-XML preamble, compressed/binary input, or incorrect file selection | Inspect a bounded byte prefix; honor the XML declaration; reject unsupported input rather than decoding with replacement |
| XML parses but expected fields are missing | Default namespaces, schema drift, optional nodes, mixed record types, or incorrect element path | Enumerate namespace-qualified element names and a bounded structural profile; version the schema fingerprint; fail required-field assertions |
| Parser is killed on a large export | DOM/object expansion, retained elements, one enormous record, entity expansion, or log/prompt amplification | Use secure streaming parsing with external entities disabled; clear processed elements; cap record/log size; quarantine oversized records by fingerprint, not content |
| Dates or amounts silently disagree | Locale-dependent parsing, timezone conversion, fiscal cutoffs, decimal scale, currency, signs, rounding, or blank/zero coercion | Parse with explicit formats and decimal types; retain parse-failure counts; reconcile using a written contract |
| A retry duplicates output | Non-idempotent staging or append behavior, reused run directory, or missing manifest | Use unique run IDs, immutable finalized inputs, atomic output replacement, and content fingerprints; never append implicitly |
| Databricks totals vary between runs | Different snapshots, late data, nondeterministic filters, cache assumptions, or mutable reference tables | Pin or record the available snapshot/version/time and rerun the same query contract; then use the Databricks reference |
| Power BI metadata write “succeeds” but model fails later | No round-trip check, unresolved dependency, M was stored but not evaluated, or metadata acceptance was mistaken for processing | Reconnect and diff TOM metadata; run DAX assertions; validate M in Desktop/test or with an authorized targeted service refresh; use both Power BI references |
| REST returns `401` while polling | The current access token is absent, expired, or revoked; the server-side operation might still be running | Reauthenticate through the approved broker and resume polling the same request ID; never repeat an accepted POST merely because the polling token expired |
| REST returns `403` | Scope, workspace/item role, ownership, tenant/capacity setting, gateway authority, or model category does not permit the operation | Inspect the exact gate and stop; token refresh and retries do not create permission |
| A refresh POST returns `202 Accepted` and the agent reports success | Acceptance was mistaken for terminal completion | Persist the request ID/Location, poll to a terminal state, inspect per-object results, and run independent postconditions |
| A refresh POST returns `400` while another refresh is active | Power BI permits only one refresh operation per semantic model | Inspect and monitor the existing refresh; do not create a retry loop or submit competing requests |
| The access token expires during enhanced refresh | Client authentication expired after the service accepted the work | Reacquire authentication only for polling; the service operation continues unless it independently fails or is cancelled |
| XMLA discovery works but Tabular Editor save fails | Build/read connectivity was mistaken for model Write, or the capacity endpoint is not Read Write | Inspect model permission, tenant integration, effective capacity setting, ownership restrictions, and supported model category; do not test with another mutation |
| M metadata persists but service refresh fails | Stored M text did not prove syntax, schema, privacy, credentials, gateway, source availability, or policy behavior | Keep metadata and data claims separate; classify the sanitized service error; validate/repair in test or roll back the object-scoped change |
| PBIX download becomes unavailable after an XMLA write | Documented consequence for a Desktop-authored service model, not a transient download error | Use the retained original PBIX/PBIP and private TMDL source; do not seek a permission workaround |
| Newly granted access is missing from ordinary API results | Permission propagation might be delayed | With explicit authorization, call `RefreshUserPermissions` at most once, wait about two minutes, and retry the read; it is not a general workspace reset |
| Power BI/Fabric REST returns `429` | Request-rate or capacity throttling | Honor `Retry-After`, classify rate versus capacity pressure, and use only a bounded retry; immediate repetition cannot fix overloaded capacity |
| Fabric definition call returns `202` with no body | Long-running operation was accepted, not completed | Capture exact `Location`/operation ID privately, wait for `Retry-After`, poll terminal state, and retrieve a result only after success |
| JSON DAX returns HTTP 200 with nested error or truncation | Transport succeeded but the result is invalid/limited | Fail the assertion, discard partial data, and correct/bound the query |
| Arrow DAX returns HTTP 200 with `IsError=true` | Query or permission failure is encoded in Arrow schema metadata | Inspect every concatenated stream, fail the assertion, and retain only sanitized fault classification |

## PowerShell reliability rules

- Use `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`, and explicit `try`/`catch`/`finally` in maintained wrappers. Do not add `-ErrorAction SilentlyContinue` to make a run green.
- Pass paths as literal values and process arguments as arrays. Avoid constructing executable command lines by interpolation.
- Open streams with explicit access/share modes and dispose them in `finally` or `using` scopes.
- Do not use `Get-Content -TotalCount` as a byte or XML-record limit. It counts text lines and can scan an enormous single-line document.
- Do not use `$?` as the value returned by `Test-Path`; branch on the returned Boolean. Use `$LASTEXITCODE` immediately after native processes.
- Separate progress records from data output. Keep stdout machine-readable and stderr actionable but sanitized.
- For elapsed visibility, use `runwatch` only inside a proven host-time bound. It cannot create durability or override a hard timeout; its stderr heartbeat is not a progress event.
- Make timeouts, retry count, and backoff explicit. Record each attempt and its reason.
- Do not recursively enumerate a large remote tree when the exact source should be known.
- Do not calculate a remote hash repeatedly. When end-to-end hashing is required, calculate it once per stable snapshot and compare it with the finalized local copy.
- Never disable certificate checks, endpoint protection, execution policy, or access controls as a troubleshooting shortcut.

## XML reliability rules

- Parse incrementally with a secure parser; disable external entity resolution and network access.
- Treat a bounded prefix as encoding or schema-discovery evidence only. Never validate XML or count records with regex.
- Keep memory proportional to the current record, not the file size. Clear processed elements and do not retain all parsed rows unless bounded by design.
- Capture the XML declaration, encoding, root/record qualified names, namespace map, required-field presence, record count, parse-failure count, date bounds, and schema fingerprint.
- Treat replacement decoding, skipped malformed rows, coerced dates/amounts, and ignored unknown elements as explicit policy decisions with counters—not silent fixes.
- Never include raw financial records in logs, prompts, tests, or Git. Build minimal synthetic fixtures for each structural edge case.

## Escalate instead of patching when

- permissions or credentials are missing;
- endpoint protection or policy blocks execution;
- the producer cannot provide a stable snapshot;
- integrity checks disagree after a bounded restage;
- a required field or schema contract is ambiguous;
- the only proposed fix is an unlimited retry, suppressed error, disabled security control, unexplained data adjustment, or unvalidated live write.
