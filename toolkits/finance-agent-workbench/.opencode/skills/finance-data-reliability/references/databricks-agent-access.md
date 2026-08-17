# Databricks Agent Access

Use this runbook when an agent needs to discover Databricks identity,
warehouses, workspace objects, Unity Catalog metadata, or a specific Genie
Agent (formerly a Genie Space). This is a public-safe operating pattern, not a
tenant configuration. Replace placeholders only inside the approved company
environment and keep the resolved values out of Git, prompts, screenshots, and
receipts intended for external sharing.

Read [Databricks reconciliation](databricks-reconciliation.md) before judging
financial results. Read
[long-running task observability](../../../../docs/long-running-task-observability.md)
before launching a quiet command or asynchronous probe.

## Default architecture

Prefer one authenticated Databricks client and a small, versioned adapter over
giving the agent several overlapping ways to improvise API calls:

1. Use one named Databricks unified-authentication profile for the intended
   workspace and user.
2. Use the Databricks SDK for Python as the maintained control-plane adapter.
3. Expose fixed, read-only inventory operations and approved reconciliation
   templates to OpenCode.
4. Address an exact allowlisted Genie Agent through the Conversation API when
   multi-turn business context is useful.
5. Treat every generated query or natural-language answer as a hypothesis
   until deterministic finance assertions pass.

Do not simultaneously expose an unrestricted CLI shell, arbitrary REST
request tool, arbitrary SQL tool, broad SQL MCP server, and raw credential to
the model. More access paths create more authentication ambiguity, larger
prompt exposure, inconsistent retry behavior, and a wider write surface.

## Non-negotiable safety boundaries

- Default the workspace, warehouses, notebooks, jobs, Unity Catalog, Genie,
  and source data to read-only.
- Never print or return an access token, refresh token, client secret,
  authorization header, signed download URL, raw profile file, or credential
  cache.
- Never put a token in a command argument, OpenCode configuration, repository,
  `.env` file, transcript, receipt, or screenshot.
- Never disable TLS verification or redirect an approved hostname to work
  around a certificate, proxy, VPN, or Private Link failure.
- Never infer authorization from visibility. An object may be discoverable
  without being queryable, writable, or organization-approved for the task.
- Never recursively enumerate the whole workspace, export all notebooks, list
  all users, or crawl every catalog because an endpoint permits it.
- Do not start, stop, resize, or change auto-stop on a SQL warehouse as an
  incidental response to a query delay.
- Do not create, update, delete, move, or export Genie Agents or conversations
  through the read-only adapter. Starting a conversation and adding messages
  create task-scoped interaction state and execute queries; that limited POST
  surface must be explicit.
- Do not run DDL, DML, grants, jobs, pipelines, notebooks, or arbitrary SQL.
  A SQL statement beginning with `SELECT` is not automatically safe if it
  invokes a function with side effects or expands into an unbounded scan.
- Do not forward raw finance rows or Genie query results to another model.
  Prefer schemas, aggregates, exception counts, hashes, and approved aliases.

## Authentication decision

### Preferred: OAuth user-to-machine with a named profile

For an attended local workflow, use OAuth user-to-machine (U2M). Databricks
unified authentication handles access-token generation and refresh for the
CLI and SDK. OAuth access tokens are short-lived; the client refreshes them,
so a one-hour token lifetime should not be solved by copying a bearer token
into the agent.

Create a distinct profile rather than altering `DEFAULT`:

```powershell
$databricks = (Get-Command databricks -ErrorAction Stop).Source
$profile = 'FINANCE_READ_ONLY'
$workspaceHost = 'https://<approved-workspace-hostname>'

& $databricks auth login `
    --host $workspaceHost `
    --profile $profile
$authExitCode = $LASTEXITCODE
if ($authExitCode -ne 0) {
    throw "Databricks OAuth login failed with exit code $authExitCode."
}
```

The browser login is an **operator-only** action. Do not automate consent,
accept credentials in chat, capture the browser URL, or let the agent launch
diagnostic CLI commands after login. In OpenCode, command stdout becomes model
context. Even read-only authentication and identity commands can disclose an
email address, workspace host, account or tenant identifier, and authentication
method.

The operator may validate the profile privately using the installed CLI, but
must not paste, screenshot, or route that output to the agent. Agent-visible
identity proof must come only from the approved sanitizing adapter used by
`/dbx-capabilities`. Its external receipt records a preassigned identity alias
or `identityConfirmed: true`, never an email, numeric ID, tenant, hostname,
credential source, or raw exception.

Unified authentication has a method priority. A stale `DATABRICKS_TOKEN`,
`DATABRICKS_HOST`, or other environment setting can select a different method
than the named profile. Invoke every CLI command with `--profile` and every SDK
client with `profile=...`. If observed identity or host does not match the
expected aliases, stop. Do not unset or overwrite corporate environment
configuration on the user's behalf; diagnose the effective method and ask the
operator or administrator to correct it.

### Fallback: personal access token

Databricks documents personal access token (PAT) authentication as legacy and
recommends OAuth where possible. A PAT is scoped to one workspace, remains a
bearer secret, does not refresh itself, and never grants more authority than
its principal. Unused PATs are automatically revoked after 90 days, but that
is not a substitute for a short configured lifetime and revocation process.

Use a PAT only when all of the following are true:

- OAuth is unavailable for a documented reason;
- company policy and the workspace administrator allow PAT use;
- the token has the minimum required API scopes and shortest practical
  lifetime;
- the profile is stored by the approved local credential mechanism outside
  the repository and sync roots;
- revocation ownership and expiry are known; and
- the agent can use the profile without ever receiving the token value.

If approved, enter the token only at the CLI's interactive prompt:

```powershell
$databricks = (Get-Command databricks -ErrorAction Stop).Source
$profile = 'FINANCE_PAT_FALLBACK'

& $databricks configure --profile $profile
$configureExitCode = $LASTEXITCODE
if ($configureExitCode -ne 0) {
    throw "Databricks profile configuration failed with exit code $configureExitCode."
}
```

Do not use `echo`, a pipeline, `--token`, a here-string, clipboard automation,
or `DATABRICKS_TOKEN` in an agent-launched command. Do not run commands that
materialize a token for diagnostic convenience. For unattended production
automation, request a dedicated service principal with OAuth M2M and narrowly
assigned permissions; do not schedule a personal U2M login or PAT.

## Capability proof before data access

Run capability discovery once per authenticated session or after an identity,
workspace, VPN, proxy, role, or policy change. Capability proof is metadata
only; it does not authorize a subsequent query or write.

### Sanitizing adapter inventory

Do not let the agent invoke the Databricks CLI or SDK inventory APIs directly.
Read-only responses are still sensitive model input: full objects can contain
emails, IDs, owners, paths, comments, connection metadata, storage locations,
and workspace hosts. A shell pipeline that prints raw JSON and promises to
sanitize it later has already crossed the disclosure boundary.

`/dbx-capabilities` may call only an existing, approved local adapter. The
adapter is the trust boundary and must:

1. accept a fixed `profile_alias`, a bounded nonrecursive `workspace_path_alias`,
   and catalog/schema aliases from a private approved allowlist;
2. resolve those aliases locally, outside the prompt and repository;
3. use a pinned SDK and named unified-auth profile internally
   (`WorkspaceClient(profile=PROFILE)`), without accepting a token parameter;
4. enforce explicit per-endpoint page, item, byte, and elapsed-time caps before
   enumeration begins, and stop when any cap is reached;
5. project each returned object immediately into approved booleans, states, and
   counts instead of accumulating or serializing SDK objects;
6. map raw IDs, names, paths, and hosts to preassigned private aliases before
   writing stdout, stderr, status, or receipts;
7. omit comments, owners, emails, locations, properties, JDBC/HTTP metadata,
   notebook source, query text, and row data unconditionally;
8. emit one small versioned JSON result containing only the approved schema;
9. return `truncated: true` and `INCONCLUSIVE` when a bound is reached rather
   than silently treating a partial inventory as complete; and
10. fail closed with `MISSING_PREREQUISITE` when the adapter, alias map, profile,
    or sanitizer version is unavailable.

The agent-facing invocation is therefore the OpenCode command, not a raw CLI
or Python snippet:

```text
/dbx-capabilities profile_alias=<approved-profile-alias> workspace_path_alias=<approved-path-alias> catalog_alias=<approved-catalog-alias> schema_alias=<approved-schema-alias>
```

No adapter is bundled by this public repository. Installation and credential
setup remain operator/IT actions. Do not substitute ad hoc PowerShell, `curl`,
CLI output, or an inline SDK script when the adapter is absent. Do not use
recursive workspace listing unless the exact folder, expected object count,
pagination bound, and business purpose are documented in the private adapter
policy.

### What each successful read actually proves

| Probe | Observed claim | It does not prove |
|---|---|---|
| `current-user me` | The broker authenticated an identity in this workspace | The identity is approved for this task or has data/write access |
| warehouse list | The identity can discover returned warehouse metadata | It can use, start, stop, resize, or administer a warehouse |
| bounded workspace list | Returned objects are visible under that exact path | Notebook contents can be exported, executed, or changed |
| catalog/schema/table list | Returned metadata is discoverable | Every object is approved or queryable |
| table metadata | The object identity and selected metadata were returned | Current row access, snapshot stability, or semantic correctness |
| successful `SELECT` | That exact statement ran under the current context | Broader SQL is safe or later snapshots will match |
| successful Genie response | The exact Agent processed the question | The SQL, answer, grain, joins, or totals are correct |

## Permission boundaries

Keep platform permissions and company approval separate. The adapter must use
the intersection of both:

```text
effective scope = Databricks-visible objects ∩ private approved allowlist
```

Typical platform gates include:

- Workspace objects: object/folder ACLs such as read or run permissions.
- SQL warehouse: the relevant `CAN USE` or embedded-compute behavior for the
  selected interface.
- Unity Catalog metadata: metastore visibility, `BROWSE`, ownership, or other
  metadata permissions.
- Direct table queries: normally `USE CATALOG`, `USE SCHEMA`, and `SELECT`,
  plus any row filter, column mask, dynamic view, and credential boundary.
- Genie consumption: the required workspace entitlement, at least the
  consumer permission on the exact Genie Agent, and data privileges for the
  underlying objects. Current Genie sharing behavior can use compute
  credentials embedded by the author while still enforcing each end user's
  Unity Catalog permissions.
- Genie authoring or export: elevated Agent permissions. This runbook does not
  authorize them.

Some current Conversation API prerequisites and older deployment patterns
also describe direct `CAN USE` access on a Pro or serverless SQL warehouse.
Do not guess which model the workspace uses. Record the current documented
configuration and the exact sanitized response from the capability probe.

An empty Genie answer can be the correct security result when row filters,
column masks, or missing object privileges remove the data. It is not evidence
that the table is empty. A `403` is a permission or policy signal, not an
invitation to refresh the token or try another endpoint.

## OpenCode command surface

Implement two narrow orchestration commands rather than giving the model raw
REST and arbitrary SQL.

### `/dbx-capabilities`

Purpose: prove identity and bounded read capabilities without returning
business rows.

Accepted inputs:

- `profile_alias` from a fixed local allowlist;
- optional `workspace_path_alias` from a fixed local allowlist;
- optional `catalog_alias` and `schema_alias` from fixed local allowlists;
- `include_jobs=false` by default;
- explicit page and object-count caps.

Allowed operations:

- current user metadata projected to `identityConfirmed` and a local alias;
- list warehouses, returning only alias, state, type, and a capability result;
- one nonrecursive workspace listing under an approved path;
- catalogs, schemas, tables, and functions under approved aliases;
- optional bounded job/run status metadata when separately approved.

Forbidden operations:

- arbitrary paths or identifiers supplied by the prompt;
- recursive root listing, notebook export, command execution, or job run;
- warehouse start, stop, resize, configuration, or permission changes;
- schema, table, function, volume, share, recipient, or grant changes;
- returning raw object comments, owners, storage locations, URLs, source code,
  query text, or rows.

Synthetic invocation:

```text
/dbx-capabilities profile_alias=finance-readonly \
  workspace_path_alias=migration-sandbox \
  catalog_alias=finance-curated \
  schema_alias=reconciliation \
  max_objects=100
```

Expected output shape:

```json
{
  "schemaVersion": 1,
  "operation": "dbx-capabilities",
  "mode": "read-only-metadata",
  "identityConfirmed": true,
  "workspaceAlias": "workspace-a",
  "profileAlias": "finance-readonly",
  "capabilities": {
    "warehousesListed": true,
    "workspacePathListed": true,
    "catalogsListed": true,
    "schemasListed": true,
    "tablesListed": true,
    "arbitrarySqlExposed": false,
    "writesExposed": false
  },
  "counts": {
    "warehouses": 2,
    "workspaceObjects": 7,
    "catalogs": 3,
    "schemas": 4,
    "tables": 12
  },
  "warnings": [],
  "status": "observed"
}
```

All names and counts above are synthetic.

### `/dbx-genie-probe`

Purpose: ask one approved question of one exact Genie Agent and return a
sanitized hypothesis package for deterministic validation.

Accepted inputs:

- `profile_alias` and `space_alias`, resolved privately to fixed values;
- a bounded question built from an approved template and nonsensitive
  parameters;
- a new task/session label;
- an optional deterministic `check_id` for the validation that must follow;
- deadline, poll interval, result-row cap, and result-byte cap.

Allowed operations:

- start one new conversation for the task;
- poll that message to a documented terminal status;
- send bounded follow-ups only within the same task;
- retrieve a bounded attachment result when needed for an approved check;
- compute a private SQL hash and extract approved source aliases;
- report whether a trusted-asset indicator was present.

Forbidden operations:

- accepting a raw space ID or hostname from the model;
- using `include_all=true` to inspect other users' conversations;
- deleting conversations or messages;
- exporting or updating the serialized Agent definition;
- re-executing expired query results without a new approval decision;
- downloading full results or signed external links;
- printing generated SQL, business rows, prompts, or Agent instructions to a
  public receipt;
- calling a write-capable SQL interface to “verify” the answer.

Synthetic invocation:

```text
/dbx-genie-probe profile_alias=finance-readonly \
  space_alias=finance-migration \
  question_template=identify-source-grain \
  report_alias=report-a \
  period_alias=current-close \
  check_id=grain-and-balance-v1 \
  deadline_seconds=600 \
  max_result_rows=100
```

Expected output shape:

```json
{
  "schemaVersion": 1,
  "operation": "dbx-genie-probe",
  "mode": "bounded-analytical-read",
  "spaceAlias": "finance-migration",
  "conversationAlias": "conversation-20260805-001",
  "messageAlias": "message-001",
  "terminalState": "COMPLETED",
  "elapsedSeconds": 42.7,
  "generatedSqlPresent": true,
  "generatedSqlSha256": "<sha256>",
  "trustedAssetIndicatorPresent": false,
  "queryResultTruncated": false,
  "sourceAliases": ["table-a", "metric-view-b"],
  "requiredValidation": "grain-and-balance-v1",
  "validationStatus": "NOT_RUN",
  "conclusion": "UNVERIFIED_HYPOTHESIS",
  "warnings": []
}
```

The conclusion cannot become `VERIFIED` inside the Genie probe. A separate,
deterministic reconciliation command must evaluate the frozen contract.

## Direct Genie Conversation API

A generic Databricks SDK, SQL connector, or MCP connection does not
automatically inherit a Genie Agent's curated instructions. Addressing the
exact Agent by its private `space_id` provides its configured tables, metric
views, descriptions, example SQL, joins, trusted assets, and instructions as
context. Those assets improve grounding but do not guarantee correctness.

Use a new conversation for each report, migration, investigation, or user
session. Reusing an old thread can leak irrelevant assumptions into a new
question. Follow-ups within the same task can reuse the `conversation_id`.

### SDK example

The SDK waiter provides a bounded call without exposing a bearer token:

```python
from datetime import timedelta

from databricks.sdk import WorkspaceClient

PROFILE = "FINANCE_READ_ONLY"
SPACE_ID = "<resolved-private-space-id>"

w = WorkspaceClient(profile=PROFILE)

message = w.genie.start_conversation_and_wait(
    space_id=SPACE_ID,
    content=(
        "For <synthetic-report-alias>, identify the candidate business grain, "
        "keys, date semantics, currency, sign convention, and source objects. "
        "Do not propose writes."
    ),
    enable_visualization=False,
    timeout=timedelta(minutes=10),
)

follow_up = w.genie.create_message_and_wait(
    space_id=SPACE_ID,
    conversation_id=message.conversation_id,
    content=(
        "State which assumptions remain unverified and propose aggregate, "
        "duplicate-key, and anti-join checks. Do not change data."
    ),
    enable_visualization=False,
    timeout=timedelta(minutes=10),
)
```

Do not `print(message)` or serialize the whole object. Inspect attachments in
memory, enforce size and row caps, hash generated SQL, and return only the
approved projection. The SDK's current nondeprecated result method is
`get_message_attachment_query_result`; do not use legacy result helpers in new
code. Result-expiry handling must not silently re-execute a query.

### REST shapes

These are documentation shapes, not instructions to paste a bearer token into
an agent shell. Authentication is supplied by the approved client credential
broker and is intentionally omitted from every example:

```http
POST /api/2.0/genie/spaces/{space_id}/start-conversation
Content-Type: application/json

{"content":"<approved-bounded-question>","enable_visualization":false}
```

```http
GET /api/2.0/genie/spaces/{space_id}/conversations/{conversation_id}/messages/{message_id}
```

```http
POST /api/2.0/genie/spaces/{space_id}/conversations/{conversation_id}/messages
Content-Type: application/json

{"content":"<approved-bounded-follow-up>","enable_visualization":false}
```

```http
GET /api/2.0/genie/spaces/{space_id}/conversations/{conversation_id}/messages/{message_id}/attachments/{attachment_id}/query-result
```

Poll the same message ID. Intermediate states can include `SUBMITTED`,
`PENDING_WAREHOUSE`, and `EXECUTING_QUERY`; terminal or exceptional states can
include `COMPLETED`, `FAILED`, `CANCELLED`, or `QUERY_RESULT_EXPIRED`. Inspect
the current API schema rather than hard-coding that list as exhaustive. The
`attachments` field can be populated incrementally, but only a declared
terminal state plus postconditions completes the probe.

Do not confuse the two documented query-result URL examples retained across
API versions. New wrappers should use the canonical `attachments/{attachment_id}/query-result`
form from the current reference and pin a tested SDK version.

## Genie MCP and SQL MCP boundaries

The per-Agent managed MCP endpoint is:

```text
https://<workspace-hostname>/api/2.0/mcp/genie/<genie-space-id>
```

It uses the `genie` OAuth scope and Databricks documents it as read-only. It
invokes Genie as a tool but does not pass the surrounding agent conversation
history into the Genie API. Use it for isolated questions. Use the Conversation
API when explicit multi-turn task context is required. In either case, Unity
Catalog security remains enforced and the response still requires validation.

The broad managed Databricks SQL MCP endpoint is:

```text
https://<workspace-hostname>/api/2.0/mcp/sql
```

Databricks explicitly documents this server as **read and write**. Do not add
it to the production finance OpenCode configuration merely because the current
prompt asks for a read. Prompt instructions are not a technical write barrier.
If an approved use case later requires it, isolate it to a nonproduction
workspace and identity, inspect the exact exposed tool schema, add server-side
least privilege, and require the repository's write gates.

The managed Unity Catalog function MCP can expose a predefined function as a
narrower tool, but “predefined” does not mean read-only. Review the function
body, owner, definer/invoker behavior, data access, parameters, result bounds,
and side effects before allowlisting it.

## Deterministic finance validation

Genie is useful for discovering candidate objects, translating business terms,
and proposing SQL. It is not the certification layer. Freeze a comparison
contract and execute a separately reviewed, parameterized query or local
validation script.

At minimum, define and test:

1. source and target snapshot time or Delta version;
2. business grain and complete business key;
3. document, line, company, ledger, fiscal year/period, and date semantics;
4. timezone and inclusive/exclusive cutoff rules;
5. transaction, local, group, and reporting currency behavior;
6. unit scale, decimal type, rounding stage, and tolerance;
7. debit/credit or signed-amount convention;
8. null, blank, zero, reversal, cancellation, and late-arrival behavior;
9. hierarchy/reference-data version; and
10. expected row-level security or column masking.

Evaluate in layers:

- row counts and schema fingerprint;
- required-field null counts;
- duplicate counts at the declared key;
- min/max business dates and fiscal periods;
- global decimal totals by measure and currency;
- grouped totals by low-cardinality control dimensions;
- missing/extra keys with anti-joins;
- changed-value counts and bounded, privately retained exception samples;
- repeatability against the same recorded snapshots.

A matching grand total is insufficient. A plausible generated SQL statement,
trusted-asset indicator, completed API status, HTTP 200, or zero process exit
code is also insufficient. The receipt can state `passed` only when every
declared invariant meets its tolerance.

## Timers, polling, and apparent hangs

Distinguish four facts:

- an attached local supervisor is alive;
- its direct child had not exited at the latest heartbeat;
- the remote request has a current state for the exact operation ID; and
- business work has actually progressed.

Only the third is remote-operation evidence, and none alone proves correct
results. For a bounded command that fits within the host's wall-clock limit,
run the maintained adapter under `runwatch`:

```powershell
$python = (Get-Command python -ErrorAction Stop).Source
$statusRoot = 'C:\ApprovedLocalRunStatus'
$statusName = 'dbx-genie.{0}.runwatch.json' -f `
    ([guid]::NewGuid().ToString('D'))
$statusPath = Join-Path $statusRoot $statusName
$adapter = 'C:\ApprovedProject\dbx_agent_adapter.py'

$arguments = @(
    '-m'
    'runwatch'
    '--heartbeat-seconds'
    '15'
    '--status-out'
    $statusPath
    '--label'
    'dbx-genie-probe'
    '--'
    $python
    $adapter
    'genie-probe'
    '--profile-alias'
    'finance-readonly'
    '--space-alias'
    'finance-migration'
    '--question-template'
    'identify-source-grain'
    '--deadline-seconds'
    '600'
)

& $python @arguments
$runExitCode = $LASTEXITCODE
```

The paths are synthetic. The status directory must satisfy the local fixed
volume and ACL requirements in the observability reference. `runwatch` proves
local liveness only and cannot extend an OpenCode hard timeout. The adapter
must separately emit a sanitized status event whenever the exact Genie message
state changes:

```json
{
  "event": "remote-state",
  "operationAlias": "genie-message-001",
  "state": "EXECUTING_QUERY",
  "elapsedSeconds": 30.2,
  "pollSequence": 4,
  "lastPollUtc": "2026-08-05T16:00:30.200Z"
}
```

Use monotonic elapsed time, a fixed deadline, a bounded poll count, and
backoff appropriate to the endpoint. Preserve the same operation IDs across
polls. Never submit a second question because the first poll was quiet. If the
client credential expires after the remote request was accepted, refresh
authentication and resume polling the same message; do not duplicate it.

If expected runtime can exceed the agent host limit, run the exact reviewed
command in an approved terminal or durable job runner and return only the
sanitized receipt. A stale local heartbeat makes the outcome unknown; it does
not prove the Databricks query stopped.

## Failure taxonomy

| Observation | Likely class | Safe response |
|---|---|---|
| CLI and SDK report different users or hosts | Auth precedence, stale environment variable, wrong profile, or different config file | Stop; record sanitized effective method and aliases; require the same explicit profile everywhere |
| Browser OAuth succeeds but API returns `401` | Expired/revoked token, wrong audience/host, broken refresh, or clock/proxy problem | Reauthenticate through the approved broker; do not paste or inspect token contents |
| API returns `403` | Missing entitlement, object ACL, UC privilege, warehouse permission, OAuth scope, workspace policy, or network policy | Identify the exact gate and stop; retrying or refreshing cannot create permission |
| API returns `404` for a known object | Wrong workspace/ID, no visibility, deleted/moved object, or endpoint/version mismatch | Re-prove workspace alias and allowlisted ID privately; do not enumerate broadly to find it |
| API returns `429` | Request or workspace rate limit, warehouse/capacity pressure, or service throttling | Honor `Retry-After`; use bounded retries with jitter; reduce polling or query fan-out |
| API returns `5xx` | Databricks service, gateway, proxy, or transient backend failure | Preserve request alias and sanitized error; retry only the documented idempotent read or continue polling an accepted operation |
| Warehouse remains pending | Warehouse start latency, capacity, queue, permission, or policy | Continue bounded polling if authorized; do not start/resize/change the warehouse |
| Genie state is `FAILED` | Interpretation, generated SQL, compute, data permission, or execution failure | Record sanitized error class and SQL hash; do not paraphrase partial output as an answer |
| Genie state is `QUERY_RESULT_EXPIRED` | Statement result retention elapsed | Mark result unavailable; do not silently invoke re-execution because it creates new compute and a new snapshot |
| Genie returns empty results | Valid no-data result, UC denial, row filter, column mask, or mismatched question | Compare with an approved deterministic control; do not infer that the table is empty |
| Genie answer changes between runs | Different conversation context, generated SQL, snapshot, model behavior, or curated Agent version | Start clean task conversations; hash SQL; record snapshot and Agent alias; rely on deterministic checks |
| Result is truncated or exceeds caps | Query/result bound is unsuitable | Reject it as validation evidence; tighten the question or run an approved aggregate template |
| SDK method or response field is missing | Unpinned/outdated SDK, API evolution, or copied example from another cloud/version | Record versions; consult current primary reference; update and test the private adapter deliberately |
| Command is quiet but `runwatch` is live | Child is alive, blocked, waiting, or computing | Inspect remote operation state and deadline; heartbeat alone is not progress |
| OpenCode kills the process at its fixed timeout | Host wall-clock limit, not necessarily Databricks failure | Recover the remote operation ID and inspect it from an approved runner; never assume cancellation or duplicate the request |
| Query completed but finance checks differ | Snapshot, grain, date, currency, sign, joins, hierarchy, or actual defect | Follow `databricks-reconciliation.md`; do not add an unexplained filter or tolerance |

Never retry indefinitely. Record attempt number, reason, bounded backoff, and
whether the request is safe to repeat. POSTing a new Genie message is not the
same as polling an existing message.

## Sanitized receipts

Keep the private evidence package and public-safe receipt separate. The
private package may contain access-controlled IDs, generated SQL, bounded
exceptions, and query results when policy allows. The public-safe receipt must
contain none of those values.

Minimum receipt fields:

```json
{
  "schemaVersion": 1,
  "runId": "00000000-0000-0000-0000-000000000000",
  "startedUtc": "2026-08-05T16:00:00.000Z",
  "finishedUtc": "2026-08-05T16:01:00.000Z",
  "elapsedSeconds": 60.0,
  "operation": "dbx-genie-probe",
  "mode": "bounded-analytical-read",
  "toolVersions": {
    "adapter": "<version>",
    "databricksSdk": "<version>"
  },
  "workspaceAlias": "workspace-a",
  "profileAlias": "finance-readonly",
  "spaceAlias": "finance-migration",
  "identityConfirmed": true,
  "remoteOperationAlias": "genie-message-001",
  "terminalState": "COMPLETED",
  "generatedSqlSha256": "<sha256>",
  "resultTruncated": false,
  "validationCheckId": "grain-and-balance-v1",
  "validationStatus": "PASSED",
  "assertionCounts": {
    "passed": 8,
    "failed": 0,
    "notRun": 0
  },
  "warnings": [],
  "conclusion": "VERIFIED"
}
```

Use aliases or hashes for workspace, warehouse, catalog, schema, table,
notebook, job, Genie Agent, conversation, message, statement, query, and user
identities. Exclude:

- hostnames, tenant/account/workspace IDs, emails, and internal paths;
- bearer values, profile contents, headers, signed URLs, and environment dumps;
- raw questions that disclose business context;
- generated SQL text, comments, table names, and source code;
- raw rows, sample documents, amounts, customer/vendor data, and exceptions;
- full error bodies or stack traces that contain request URLs or identifiers.

Label conclusions `OBSERVED`, `INFERRED`, `UNVERIFIED_HYPOTHESIS`, `VERIFIED`,
`FAILED`, or `INCONCLUSIVE`. A Genie response normally begins as
`UNVERIFIED_HYPOTHESIS`; only independent assertions can promote it.

## Primary references

Authentication and clients:

- [Databricks CLI authentication](https://docs.databricks.com/aws/en/dev-tools/cli/authentication)
- [OAuth user-to-machine authentication](https://docs.databricks.com/aws/en/dev-tools/auth/oauth-u2m)
- [Databricks unified authentication](https://docs.databricks.com/aws/en/dev-tools/auth/unified-auth)
- [Personal access token authentication (legacy)](https://docs.databricks.com/aws/en/dev-tools/auth/pat)
- [Databricks SDK for Python authentication](https://docs.databricks.com/aws/en/dev-tools/sdk-python#authenticate-the-databricks-sdk-for-python)

Inventory and data access:

- [Current user API](https://docs.databricks.com/api/workspace/currentuser/me)
- [SQL warehouses API](https://docs.databricks.com/api/workspace/warehouses/list)
- [Workspace objects API](https://docs.databricks.com/api/workspace/workspace)
- [Catalogs API](https://docs.databricks.com/api/workspace/catalogs/list)
- [Schemas API](https://docs.databricks.com/api/workspace/schemas/list)
- [Tables API](https://docs.databricks.com/api/workspace/tables/list)
- [Unity Catalog privileges and securable objects](https://docs.databricks.com/aws/en/data-governance/unity-catalog/manage-privileges/privileges)
- [SQL Statement Execution API](https://docs.databricks.com/api/workspace/statementexecution)

Genie and MCP:

- [Use the Genie Agents API](https://learn.microsoft.com/en-us/azure/databricks/genie-agents/conversation-api)
- [Genie API reference](https://docs.databricks.com/api/workspace/genie/startconversation)
- [Create, configure, and share a Genie Agent](https://learn.microsoft.com/en-us/azure/databricks/genie-agents/set-up)
- [Genie data-access behavior](https://learn.microsoft.com/en-us/azure/databricks/genie-agents/concepts)
- [Databricks SDK for Python Genie service](https://databricks-sdk-py.readthedocs.io/en/latest/workspace/dashboards/genie.html)
- [Azure Databricks managed MCP servers](https://learn.microsoft.com/en-us/azure/databricks/generative-ai/mcp/managed-mcp)

The repository examples are cloud-neutral where the API is common, while the
Microsoft Learn links describe Azure Databricks behavior. Confirm the current
cloud-specific page, workspace policy, CLI version, SDK version, OAuth scopes,
and API schema in the approved environment before implementation.
