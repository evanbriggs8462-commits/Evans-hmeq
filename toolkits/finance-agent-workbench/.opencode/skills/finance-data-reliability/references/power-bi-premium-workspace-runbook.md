# Power BI Premium Workspace Operations

Use this runbook when an agent must inspect or change a semantic model that is
already published to a Power BI Premium, Premium Per User, Embedded, or Fabric
capacity workspace. It separates Power BI REST, Fabric REST, XMLA/TOM,
Tabular Editor, TMDL, and the two Power BI MCP servers so the agent cannot infer
write capability from a successful read.

This is public tooling guidance. Keep actual workspace names, tenant domains,
model names, GUIDs, access tokens, M, DAX, TMDL, connection details, refresh
errors, and query results in an approved company environment outside this
repository. Treat screenshots, terminal captures, chat exports, MCP
transcripts, HTTP traces, and raw tool logs as sensitive until text/OCR review
proves that internal paths, hosts, identities, IDs, credentials, queries, and
results have been removed.

## Contents

- [REST means REST, not reset](#rest-means-rest-not-reset)
- [Fast architecture](#fast-architecture)
- [Tool-selection matrix](#tool-selection-matrix)
- [Identify the Power BI MCP server](#identify-the-power-bi-mcp-server)
- [Four independent permission gates](#four-independent-permission-gates)
- [Read-only capability inventory](#read-only-capability-inventory)
- [REST inventory and refresh history](#rest-inventory-and-refresh-history)
- [DAX validation](#dax-validation)
- [Standard and enhanced refresh](#standard-and-enhanced-refresh)
- [XMLA and Tabular Editor 2](#xmla-and-tabular-editor-2)
- [TMDL view in the Power BI service](#tmdl-view-in-the-power-bi-service)
- [Measures and relationships](#measures-and-relationships)
- [M partitions and service validation](#m-partitions-and-service-validation)
- [Fabric REST semantic-model definitions](#fabric-rest-semantic-model-definitions)
- [Desktop and PBIP fallback](#desktop-and-pbip-fallback)
- [Backup and rollback limits](#backup-and-rollback-limits)
- [Token expiry and resumable polling](#token-expiry-and-resumable-polling)
- [Change and approval gates](#change-and-approval-gates)
- [Failure classification](#failure-classification)
- [Sanitized receipt](#sanitized-receipt)
- [Synthetic command templates](#synthetic-command-templates)
- [Primary sources](#primary-sources)

## REST means REST, not reset

The product surface is the Power BI **REST API**. It is not a general workspace
"reset" API.

`RefreshUserPermissions` is a narrowly scoped REST operation for a recent
permission grant that has not propagated to API calls. It is not a workspace
reset, cache flush, token refresh, XMLA switch, model repair, or permission
bypass. Microsoft limits it to one call per user per hour and says to wait
about two minutes afterward.

Power BI REST continues to use `/datasets` in many URLs even though the current
user interface calls the object a semantic model. REST is not a general TOM
editor: ordinary Power BI REST operations do not create arbitrary measures,
relationships, calculation groups, or M partitions. Use XMLA/TOM for those
model-metadata operations.

## Fast architecture

Keep these planes separate:

1. **Power BI REST** at `https://api.powerbi.com/v1.0/myorg` discovers accessible
   workspaces and models, inspects refresh state, executes bounded DAX, and
   starts or monitors supported service operations.
2. **XMLA/TOM** at a `powerbi://` workspace endpoint reads and writes tabular
   semantic-model metadata. Tabular Editor, SSMS, TOM, and the local Power BI
   Modeling MCP use this boundary when connected to a Fabric/Power BI service
   semantic model. The local MCP can also target supported Desktop or local
   PBIP/TMDL scenarios, so inspect its actual connection and tools.
3. **Fabric REST** at `https://api.fabric.microsoft.com/v1` manages Fabric
   items. Its semantic-model definition APIs can retrieve or override a full
   TMDL/TMSL definition. An override is not a small patch.
4. **Report authoring** remains a separate layer. Report pages, visuals,
   bookmarks, interactions, and layout are not arbitrary TOM/XMLA objects.

The normal fast path is:

1. Discover and prove capabilities without mutation.
2. Export a private TMDL baseline and preserve the original PBIX/PBIP.
3. After explicit controlled-write authorization, make one reviewed metadata
   change through local Modeling MCP, Tabular Editor, or service TMDL view.
4. Reconnect and prove the persisted diff.
5. Run bounded DAX assertions.
6. If data acquisition changed, start a targeted transactional refresh,
   persist its request ID, poll to a terminal state, and inspect metrics.
7. Prove downstream report behavior and retain a rollback artifact.

## Tool-selection matrix

| Requested result | Preferred route | Boundary |
|---|---|---|
| List accessible workspaces and semantic models | Power BI REST or existing Power BI MCP | Read-only discovery |
| Inspect workspace role | Ordinary workspace REST endpoint | Read-only; not a tenant-admin scan |
| Inspect refresh history or schedule | Power BI REST | Read operation, but some endpoints require model Write or ownership |
| Run a tiny DAX invariant | JSON `executeQueries`, DAX Studio, or XMLA | Read + Build and the relevant tenant setting |
| Return a larger typed DAX result | Arrow `executeDaxQueries` | Supported Premium/Fabric capacity (not Pro or PPU), bounded row/time/memory, every Arrow stream inspected for errors |
| Add or edit a measure | XMLA/TOM through Tabular Editor, local Modeling MCP, or service TMDL view | Immediate live metadata write when connected to the service |
| Edit relationships, roles, calculation groups, or annotations | XMLA/TOM | Controlled live write; dependency and security review required |
| Assign M to a partition or named expression | XMLA/TOM or TMDL | Live metadata write; accepting text does not execute M |
| Evaluate changed M | Test workspace/Desktop before promotion, or explicitly authorized service refresh | Separate data-acquisition gate |
| Refresh a model, table, or partition | Enhanced REST for resumable asynchronous work; XMLA/TMSL also supported | Separate operational write |
| Change report pages, visuals, bookmarks, or layout | Desktop/PBIP/report-authoring workflow | Not a semantic-model XMLA operation |
| Configure data-source credentials | Power BI service semantic-model settings | XMLA cannot store service credentials |
| Change an existing supported parameter or connection detail | Exact REST endpoint, if the model category is supported | Often owner-only; not a general M editor |
| Bind a gateway connection | Service settings or the exact supported REST endpoint | Requires exact gateway/data-source IDs and separate permission |
| Recover a recent permission grant | `RefreshUserPermissions` only when its stated condition is true | One call per user per hour; wait about two minutes |
| Snapshot public semantic-model metadata (not a complete operational backup) | Local Modeling MCP export, Tabular Editor TMDL export, or Fabric `getDefinition` when its Read+Write/scope gates pass | Private metadata artifact; excludes data/credentials and may expose internal information |
| Replace a complete deployed model definition | Reviewed deployment or Fabric `updateDefinition` | High-impact whole-definition operation |

## Identify the Power BI MCP server

Microsoft currently documents two Power BI MCP servers, both in preview:

| Server | Typical connection | Capabilities |
|---|---|---|
| Remote Power BI MCP | Hosted HTTP endpoint | Query data and inspect schema; no general semantic-model editing |
| Local Power BI Modeling MCP | Local `stdio` process named `powerbi-modeling-mcp` | Model metadata read/write, DAX, transactions, partitions, TMDL import/export, and Fabric connections |

Before planning an edit, record a pinned installed version, inspect that
version's `--help`, inspect the MCP server name and actual advertised tool
schemas, and verify `--readonly` really removes mutation tools. Do not use
`@latest` or guess tool names/payloads from an older example in a repeatable
workflow.

The local Modeling MCP currently documents:

- `--readwrite` as the default;
- `--readonly` to remove write operations;
- a confirmation before the first query and first modification;
- `--skipconfirmation`, which must not be used for this workflow;
- interactive or service-principal authentication;
- transaction, database, model, table, measure, relationship, partition,
  named-expression, security, trace, and DAX operations.

Repository policy is stricter than the MCP's one-time confirmation. Use
`--readonly` during discovery. Do not rely on "first modification per database"
as approval for later changes. Never configure `--skipconfirmation`.

The server runs locally but may send retrieved metadata, schemas, or query
results through the MCP client to the selected LLM provider. Confirm the
organization's AI data-handling policy before exposing model content. Monitor
its service activity under application name `MCP-PBIModeling` when Fabric
Workspace Monitor is available.

## Four independent permission gates

A successful connection proves only the gate it crossed. Check all four.

### Gate 1: identity and API authorization

- Confirm the exact signed-in work identity without printing a token or UPN in
  a public receipt.
- A Power BI REST token, Fabric REST token, XMLA interactive session, and MCP
  session are related but not interchangeable proof.
- The requested REST scope must cover the endpoint. `Workspace.Read.All`,
  `Dataset.Read.All`, and `Dataset.ReadWrite.All` are not equivalent.
- Ordinary user endpoints should be the default. A workspace Admin is not a
  Fabric tenant administrator and does not automatically gain `/admin` APIs.

### Gate 2: workspace and semantic-model permission

- Read allows consumption.
- Build allows external querying such as XMLA and Analyze in Excel.
- Write allows XMLA model changes, manual refresh, backup/restore, and most
  semantic-model settings.
- Workspace Contributor, Member, and Admin normally inherit model Write.
  Viewer does not.
- Owner is separate from Write. Only the semantic-model owner can configure
  scheduled refresh, credentials, and automatic aggregations.
- RLS/OLS, guest access, licensing, and service-principal behavior can further
  constrain reads.

Seeing refresh history in the user interface does not prove the caller's token
scope, model ownership, capacity setting, XMLA Write, or gateway permission.

### Gate 3: tenant and capacity settings

- The tenant integration setting allowing XMLA endpoints must permit the user.
- The capacity semantic-model workload's XMLA Endpoint setting must be
  **Read Write** for model mutation.
- Microsoft Learn currently describes read-only as the capacity default, while
  newer Tabular Editor documentation describes read/write as the newer SKU
  default. Inspect the effective setting; do not infer it from either default.
- Execute Queries has its own tenant setting.
- The local and remote MCP servers are preview features with their own tenant
  or client enablement requirements.
- A user who administers a workspace may still be unable to change a capacity
  setting.

### Gate 4: model, owner, source, and operation support

- The workspace must be on Premium, PPU, Embedded, or Fabric capacity for the
  documented XMLA and enhanced-refresh scenarios.
- Capacity assignment is not an editing license. On Premium capacity,
  Admin/Member/Contributor authors still need Pro or PPU; a PPU workspace
  requires PPU. Record license eligibility as a separate prerequisite.
- Unsupported XMLA categories include certain live-connection, REST push, and
  Excel workbook models. Default semantic models cannot be modified through
  XMLA.
- Desktop-authored XMLA writes require enhanced semantic-model metadata.
- Data-source credentials and gateway mappings must already be valid in the
  service for refresh.
- The model may have incremental-refresh policies or system-managed partitions.
- A tenant setting that blocks republish/package refresh can reduce a
  nonowner's effective XMLA capability even with a high workspace role.
- `UpdateParameters` and `UpdateDatasources` explicitly exclude models created
  or modified through the public XMLA endpoint; use TOM/service settings for
  those models.
- Preserve the existing compatibility level unless a reviewed feature requires
  an increase; never select "latest" by habit. Power BI XMLA deployment needs
  compatibility 1500+, programmatic incremental Import policy needs 1550, and
  Hybrid policy needs 1565 plus compatible current client libraries. Treat an
  increase as a separately tested high-impact change.

## Read-only capability inventory

Run this inventory before choosing REST, XMLA, MCP, or Desktop. Do not test
write capability by creating, renaming, refreshing, taking over, or deleting a
temporary object.

Record only sanitized aliases and yes/no/unknown evidence:

1. Exact signed-in identity source: interactive MCP, Power BI PowerShell
   profile, Tabular Editor MFA, or approved application identity.
2. MCP type and version: remote query MCP or local Modeling MCP.
3. Workspace alias, exact ID fingerprint, workspace role, and whether REST says
   it is on dedicated capacity.
4. Semantic-model alias, exact ID fingerprint, model type, storage mode,
   compatibility level, and owner status if visible.
5. REST calls that succeeded and the scopes/permissions they actually prove.
6. XMLA workspace URL copied from Workspace Settings, not reconstructed.
7. XMLA read connectivity, tenant setting, and effective capacity Read Write
   evidence. A read connection does not prove write.
8. Presence of incremental-refresh policies, partition count, large-model
   storage, RLS/OLS, automatic aggregations, and dependent thin reports.
9. Data-source credential/gateway readiness without outputting source names,
   connection strings, or privacy settings.
10. Original PBIX/PBIP retention and private TMDL/Model.bim backup location.
11. Test/development workspace availability and rollback owner.
12. Exact missing prerequisites and the narrowest person who can provide them.

Classify every field as **observed**, **inferred**, or **unknown**. A missing
property in a limited REST response is unknown, not false.

## REST inventory and refresh history

Useful ordinary-user endpoints include:

```text
GET /groups
GET /groups/<workspace-guid>/users
GET /groups/<workspace-guid>/datasets
GET /groups/<workspace-guid>/datasets/<semantic-model-guid>
GET /groups/<workspace-guid>/datasets/<semantic-model-guid>/refreshes?$top=10
GET /groups/<workspace-guid>/datasets/<semantic-model-guid>/refreshSchedule
GET /groups/<workspace-guid>/datasets/<semantic-model-guid>/datasources
GET /groups/<workspace-guid>/datasets/<semantic-model-guid>/parameters
```

Important boundaries:

- `GET /groups` returns workspaces accessible to the caller. Dedicated capacity
  evidence does not prove capacity XMLA Read Write.
- The workspace list cmdlet returns only the first 100 by default unless told
  to return all or a bounded larger page.
- `Get Datasets In Group` returns limited fields to a read-only caller. Missing
  `isRefreshable` must not be interpreted as `false`.
- Refresh history requires a dataset read scope but its endpoint also requires
  caller Write. It excludes OneDrive refresh history.
- Data-source, schedule, parameter, and user APIs each have their own owner,
  permission, and model-category limits.
- `/admin/...` is not the fallback when ordinary calls return too little. It is
  a tenant-admin surface with different authentication and throttling rules.

Do not infer a generic write from these narrow mutation endpoints:

| Endpoint family | Additional boundary |
|---|---|
| `Default.UpdateParameters` | Owner-only; names are case-sensitive; maximum 100; refresh afterward; unsupported after public XMLA modification |
| `Default.UpdateDatasources` | Owner-only; same source type/schema and limited supported sources; unsupported after public XMLA modification |
| `Default.TakeOver` | Transfers ownership to the caller; explicit high-impact authorization |
| `Default.BindToGateway` | Exact gateway and data-source IDs plus data-source-user permission; never let the service select an omitted ID |
| report `Rebind` | Report Write plus Build on the target model; can create cross-workspace shared-model consequences |

Read the current endpoint-specific Microsoft page before any of these writes;
this table is a stop gate, not an executable authorization checklist.

Treat the following as writes, not discovery shortcuts:

- `Default.TakeOver`;
- `RefreshUserPermissions`;
- refresh POST or cancellation;
- schedule, parameter, connection, gateway, or permission changes;
- report rebind;
- query-scale synchronization;
- deployment or definition replacement.

## DAX validation

Use DAX to prove behavior after metadata changes. Keep the query and output
bounded and assert expected values, rather than displaying a plausible table.

### JSON `executeQueries`

Use the older JSON endpoint for small control totals and invariant checks. It
is easiest to consume from PowerShell. Current documented limits include one
query and one result table per call, 100,000 rows or 1,000,000 values,
15 MB, and 120 requests per minute per user. DAX/query failures normally return
HTTP 400, while truncation or multiple-result-table conditions can return HTTP
200 with nested errors and limited data. Inspect top-level, result-level, and
table-level errors; reject any truncation or partial result.

### Arrow `executeDaxQueries`

Use the newer streaming Arrow endpoint for a larger typed reconciliation or
an extract intended for Python, pandas, or Spark:

```text
POST /groups/<workspace-guid>/datasets/<semantic-model-guid>/executeDaxQueries
```

It requires a semantic model on supported Premium or Fabric capacity (not Pro
or PPU), the Execute Queries and XMLA tenant settings, Read + Build, and
`Dataset.Read.All` or `Dataset.ReadWrite.All`. Set
`resultSetRowCountLimit` explicitly because it defaults to 1,000,000 and there
is no pagination. Set `queryTimeout` in seconds and `memoryLimit` in KB. The
response is LZ4-compressed Apache Arrow IPC, and the documented global rate is
120 requests per minute per user.

An Arrow query or permission error can arrive with HTTP 200. A request with
multiple `EVALUATE` statements can return concatenated Arrow IPC streams.
Inspect every stream's schema metadata for `IsError=true`; retain only
sanitized `FaultCode`/`FaultString` classification. Do not treat transport
success or the first non-error stream as a passed assertion.

For both routes:

- record a query hash rather than sensitive DAX in the public receipt;
- specify culture when locale could change formatting;
- test totals and representative filter contexts;
- check blank, duplicate, RLS, and relationship-direction edge cases;
- reject truncation and multi-table warnings;
- do not use a large DAX result as a substitute for governed data export.

## Standard and enhanced refresh

### Standard refresh

A POST containing only `notifyOption` requests the ordinary asynchronous
refresh behavior. Do not rely on enhanced lifecycle semantics for a standard
refresh: current references can expose completed on-demand details in some
cases, while cancellation remains documented for enhanced refresh. Feature-
detect and inspect history rather than assuming every standard refresh has an
individually queryable/cancellable request.

### Enhanced refresh

An enhanced request includes at least one enhanced parameter and **must omit
`notifyOption`**; `notifyOption` belongs only to standard refresh. The caller
needs semantic-model Write plus `Dataset.ReadWrite.All`, and the model must be
on supported Premium/PPU/Embedded capacity.

Prefer a targeted request and `commitMode: transactional`:

```json
{
  "type": "full",
  "commitMode": "transactional",
  "objects": [
    {"table": "<table-name>"}
  ],
  "maxParallelism": 2,
  "retryCount": 0,
  "timeout": "02:00:00"
}
```

Do not copy this request into production without inventorying incremental
policies and confirming the exact target. For a partition, add a synthetic
`"partition": "<partition-name>"` only after matching one exact object.

Operational contract:

1. Snapshot recent refresh history and confirm no current operation.
2. Obtain a separate refresh authorization for the exact target and scope.
3. POST once.
4. Require `202 Accepted`, capture `Location`, `x-ms-request-id`, and the
   `requestId` locally, and then disconnect if desired.
5. Poll that exact request ID on a bounded cadence. `202` means still active; a
   later `200` carries a completed or failed operation record. Honor
   `Retry-After`/`429`; never use a tight loop.
6. Require a terminal status and inspect per-object status, attempts, messages,
   rows, duration, M-engine time, VertiPaq time, external-query time, and memory
   evidence when present.
7. Run DAX and downstream report postconditions.

Cancellation is a separate authorized operational write:

```text
DELETE /groups/<workspace-guid>/datasets/<semantic-model-guid>/refreshes/<request-id>
```

Use it only for an in-progress enhanced refresh, require the documented 200
response, and poll/read back until `Cancelled` is observed. A local process
ending does not prove the service operation was cancelled.

`202 Accepted` is not completion. A zero client exit code is not completion.

Only one refresh operation can run per semantic model. A competing request can
return `400`; inspect the active refresh rather than creating a retry loop.
Power BI can also run one request, queue one, and drop excess requests; dropped
requests may have no queryable status.

`partialBatch` is not a performance toggle for routine use. It can commit a
subset or leave a table empty after failure. It requires exceptional approval,
explicit recovery steps, and different validation. Use `transactional` when
preserving the prior valid data on failure is the requirement. If
`partialBatch` is exceptionally authorized, `applyRefreshPolicy` must be
`false`; the combination with `true` is unsupported.

For incremental-refresh tables, `applyRefreshPolicy`, `effectiveDate`, and
partition selection change semantics. Do not set them by habit. Inventory the
policy and existing partitions, preserve historical partitions for
measure-only deployments, and require a written choice before applying or
bypassing the policy. If an incremental policy exists and
`applyRefreshPolicy` is omitted, it defaults to `true`. Setting it to `false`
preserves current partition definitions, but a table-level `full` then fully
refreshes every selected existing partition. `effectiveDate` changes the
policy's effective current date.

The default per-attempt timeout is five hours and total duration including
retries cannot exceed 24 hours. More retries can multiply the elapsed time.
Enable a bounded retry only after classifying a transient condition. Premium
overload can throttle refresh work; Microsoft documents failure after more
than one hour of throttling. A full refresh can also build a new copy while the
prior model remains queryable, requiring roughly twice the model memory plus
temporary structures. Estimate capacity headroom and prefer exact partitions.
Large semantic-model storage is recommended for XMLA write performance,
especially above 1 GB, but enabling it is an approved model-setting change with
capacity/region prerequisites, not an agent default.
Tile caches are not automatically refreshed by enhanced REST or XMLA refresh;
report access refreshes them later.

## XMLA and Tabular Editor 2

Copy the workspace connection from Workspace Settings > Premium > Workspace
Connection. The general form is:

```text
powerbi://api.powerbi.com/v1.0/<tenant-primary-domain-or-myorg>/<uri-encoded-workspace>
```

Do not reconstruct a real tenant/workspace URL in this public repository. URI
encode the workspace name. When names collide, use the documented workspace
or semantic-model GUID disambiguation pattern.

Use `myorg` for a home-tenant connection. A B2B guest uses the target tenant's
primary domain. Do not adapt this v1 template for My Workspace; My Workspace
uses the documented v2 `/home/myworkspace/<UPN-or-object-ID>` form and newer
client libraries. Prefer copying the exact connection from Workspace Settings.

### Interactive connection

For Tabular Editor 2 or 3:

TE2 supports the documented XMLA endpoints. Current TE3 licensing limits the
Business edition to PPU endpoints while Enterprise supports capacity
endpoints; verify edition before classifying a permission failure.

1. Use File > Open > Model from DB (`Ctrl+Shift+O`).
2. Paste the copied XMLA endpoint.
3. Select the Microsoft Entra MFA identity when the Windows identity might not
   be the intended work account.
4. Select one exact semantic model.
5. Start by exporting Model.bim or TMDL to a company-approved private location.

When Tabular Editor is connected directly to the service database, `Ctrl+S`
writes model metadata to the shared semantic model immediately. It is not a
local save waiting for a later Power BI publish. Treat it as a controlled live
write. A deploy/create/overwrite is high impact.

The safer recurring workflow is remote baseline -> private TMDL -> reviewed
local diff -> test workspace -> production deployment. For a measure-only
deployment, preserve target connections, partitions, roles, and role members.
Never select broad deployment switches without reviewing their exact impact.
Generate/review deployment TMSL first (`-X` in TE2 CLI). Do not deploy target
connections/data sources, table partitions, roles, or role members for a
measure-only change. Since TE2 2.27, shared expressions are omitted unless the
deployment-context `-S` is deliberately included; do not add it by habit.

TE3 Workspace Mode deploys the loaded file to its workspace database on open
or save. Never choose a production semantic model as that database; use a
separate development workspace/database. Do not enable Fabric Git integration
on the workspace that hosts TE workspace databases because XMLA changes and
the branch are not synchronized.

The stable production automation interface today is the Windows TE2 CLI
(`TabularEditor.exe`). It is a WinForms application, so PowerShell automation
must wait for the process and inspect its exit code. Generate and review TMSL
before deployment when possible. The newer cross-platform `te` CLI is a
limited preview currently documented to expire September 30, 2026; do not make
it a production dependency without a new review.

TE2 command-line switches are context-sensitive. In particular, `-S` can mean
running a C# script at the top level or deploying shared expressions in the
deployment options. Do not give an agent an opaque production one-liner. Do
not include connection, partition, role, role-member, or overwrite switches in
a measure-only deployment unless each is intentionally required.

### Service processing versus Desktop processing

External processing commands are unsupported against a model currently
loaded in Power BI Desktop. That Desktop boundary must not be generalized to
the service. Authorized capacity-backed service models can use XMLA/TOM/TMSL
fine-grained refresh and enhanced REST refresh.

Choose processing by the changed object, never whole-model Full by habit:

- measures, KPIs, formatting, descriptions, translations, perspectives, and
  ordinary RLS/OLS metadata normally need no data processing;
- calculated columns/tables/calculation groups and some relationship,
  hierarchy, or removal changes may require `calculate`/recalculation;
- imported columns, partitions, or M generally require a targeted `full` of
  the affected table/partition after schema reconciliation.

Inspect unprocessed-object warnings. In TE2 automation, use `-W` and `-E` so
warnings/errors are not mistaken for a successful deployment.

## TMDL view in the Power BI service

Microsoft now documents TMDL view on the web as a preview. If it is enabled,
it can be the fastest manual option for a small change to the already published
semantic model:

1. Open TMDL View (Preview) from the workspace/model.
2. Stay in View mode while scripting and previewing.
3. Script only the exact object or parent needed.
4. Review the before/after TMDL diff.
5. If Preview/Apply requests a compatibility-level upgrade, cancel. Record the
   required level and route it through the separate compatibility-change gate.
6. Enter Edit mode only after the live-write gate.
7. Apply once, reconnect, and validate.

The web experience requires model Write and uses workspace version history
when available, but its script tabs are discarded when the model or browser
closes. Save the reviewed script privately before applying it.

TMDL View changes metadata only. It does not refresh data. An M or calculated
column change needs a separate refresh. A field rename can break dependent
visuals immediately.

## Measures and relationships

Measures are usually the lowest-impact service-side change because they are
metadata and evaluate at query time. A normal measure edit does not require a
data refresh, but it still requires a live-write gate and behavioral tests.

Preferred measure workflow:

1. Export the affected table/measure baseline.
2. Search by exact name and fail on zero/multiple target tables or duplicate
   measures.
3. Add or update only the measure's expression, format, display folder, and
   reviewed description.
4. Inspect the in-memory or preview diff.
5. Save once.
6. Reconnect and compare the canonical persisted object.
7. Execute small DAX assertions at total and filtered grains.
8. Open dependent thin reports and confirm field discovery/visual behavior.

Relationship, field rename, deletion, RLS/OLS, calculation-group, and
compatibility-level changes can have a much wider blast radius. Treat them as
high impact. Do not use parent-level `createOrReplace` for a one-object edit:
omitted read/write child objects can be deleted.

Thin reports use the shared semantic model. Additive measures can become
available without republishing the semantic model, but report authors may need
to reconnect or refresh field metadata. Renames and deletions can break every
dependent report at once.

## M partitions and service validation

Tabular Editor and TMDL can read or set `Partition.Expression`, and named/shared
expressions can hold Power Query parameters or functions. That proves only
that M text was stored.

TE2 cannot execute or validate an arbitrary Power Query M expression and its
schema-check/import features do not validate Power Query partitions. TE3 has
additional table-schema tooling, but merely editing M still does not prove it
will evaluate in the service.

Use this gate for any M change:

1. Prefer a development/test workspace or Desktop copy for the first
   evaluation.
2. Capture before/after M hashes privately, not the source text publicly.
3. Determine whether output columns, types, privacy levels, gateway routing,
   query folding, or incremental policy could change.
4. If the schema changes, update the model columns and all dependencies as one
   reviewed candidate. Power BI refresh does not automatically redesign the
   table schema for the model.
5. Apply the metadata change only after backup and target confirmation.
6. Use the service's configured credentials/gateway for an explicitly
   authorized targeted transactional refresh.
7. Poll to terminal state and inspect `serviceExceptionJson` only inside the
   approved environment. Persist a sanitized error class, not the raw payload.
8. Run schema, row-count, date-bound, control-total, RLS, relationship, and DAX
   assertions.

XMLA can define connection metadata but cannot set Power BI service data-source
credentials. Only the semantic-model owner can configure credentials and
scheduled refresh. A successful save followed by a credential error is not an
M syntax verdict.

For an incremental table, preserve historical partitions and avoid a full
rebuild unless explicitly intended. A Desktop republish, full deployment, or
partition deployment can replace the service partition layout and force years
of data to reload.

## Fabric REST semantic-model definitions

Current Fabric REST APIs provide another route:

```text
GET  /v1/workspaces/<workspace-guid>/semanticModels
POST /v1/workspaces/<workspace-guid>/semanticModels/<semantic-model-guid>/getDefinition?format=TMDL
POST /v1/workspaces/<workspace-guid>/semanticModels/<semantic-model-guid>/updateDefinition
```

`getDefinition` can return TMDL or TMSL as base64-encoded definition parts.
The definition includes measures and M partitions, so it is valuable for a
private metadata snapshot and source-control workflow. It is a retrieval
`POST`, not a GET. It requires semantic-model Read and Write plus delegated
`SemanticModel.ReadWrite.All` or `Item.ReadWrite.All`, and is blocked for an
encrypted sensitivity label. It does not include model data, credentials,
gateway binding, schedule/history, reports, or a complete recovery image.

Listing semantic models requires an applicable Viewer-or-higher workspace role
and `Workspace.Read.All` or `Workspace.ReadWrite.All`; follow every
`continuationUri`/continuation token. A partial first page is not a complete
inventory.

`updateDefinition` **overrides the definition**. It is a whole-definition
deployment, not a measure or M patch. Require all of the following before use:

1. A successful `POST .../getDefinition?format=TMDL` metadata snapshot of the
   exact target.
2. Decoding only into an approved private run directory.
3. A complete canonical diff and definition manifest.
4. Validation of every part and format; never mix TMDL and TMSL.
5. A test-model round trip.
6. Separate production confirmation and rollback.
7. Long-running operation handling for `202`, `Location`,
   `x-ms-operation-id`, and `Retry-After`.

Leave `updateMetadata` false/omitted unless item display metadata is explicitly
in scope. If `updateMetadata=true`, diff the `.platform` part separately and
obtain confirmation; copying it forward can change item metadata unrelated to
the semantic-model definition.

On Fabric `202`, the body is empty. Store the exact current `Location` and
operation ID only in approved ignored private state, wait for `Retry-After`,
and poll until `Succeeded` or `Failed`. Operation state is not operation
result: after a successful asynchronous `getDefinition`, retrieve the result
from the terminal result URL (including `/v1/operations/<operation-id>/result`
when provided). `updateDefinition` can finish at 200 or as a 202 operation and
may have no separate result. Never parse the initial empty body as a model
definition.

Fabric REST uses a separate resource/scope from ordinary Power BI REST. Do not
assume a Power BI token can call Fabric APIs, and never move either token into
the repository or prompt.

Use XMLA object-scoped edits for small interactive changes. Use full-definition
deployment when the reviewed TMDL source is intentionally authoritative.

## Desktop and PBIP fallback

Retain the original PBIX before the first XMLA write to a Desktop-authored
published model. Microsoft warns that after an XMLA write the semantic model
cannot be downloaded back as a PBIX. Do not promise a download-based rollback.

Once service-side XMLA development begins, avoid two competing sources of
truth. A later Desktop republish can overwrite service changes. Migrate the
canonical model metadata into a company-approved private TMDL workflow and
define who may deploy it.

Microsoft lifecycle guidance recommends PBIP rather than PBIX for source
control and TMDL rather than Model.bim when developing semantic models through
XMLA tools. TMDL splits model objects across readable files, improving diffs
and reviews. The actual files can contain internal hostnames, schemas, paths,
business logic, RLS, roles, and M, so they must not enter this public toolkit.

Use Desktop/PBIP when:

- report pages or layout must change;
- M must be evaluated safely before promotion;
- a schema needs interactive Power Query work;
- the workspace lacks XMLA Write;
- the model category is unsupported by XMLA;
- the organization requires its existing publish/deployment pipeline.

Prefer separate development, test, and production workspaces. Microsoft
explicitly recommends separate environments for lifecycle management rather
than local development directly into production.

## Backup and rollback limits

Name exactly what each recovery artifact can restore:

- TMDL/Model.bim, Fabric `getDefinition`, and Tabular Editor automatic metadata
  backups restore model metadata only. They do not contain VertiPaq data,
  service credentials, gateway binding, refresh schedule/history, sensitivity
  label, or report layout. Enable Tabular Editor automatic metadata backup and
  save/review generated deployment TMSL before a live deployment.
- Service semantic-model version history is conditional, not a guaranteed
  universal rollback. It starts only for eligible saved versions, requires the
  documented permissions/model features, retains a small bounded history, and
  does not replace private source control.
- Full ABF backup/restore requires the documented Premium/PPU setup with an
  approved ADLS Gen2 backup location. Storage, permission, enhanced-format,
  large-model, VNet, and firewall constraints apply.
- The retained original PBIX/PBIP protects the original Desktop source, but a
  later republish can overwrite service-side changes. Decide the authoritative
  source and owner before the first XMLA write.

A metadata snapshot is therefore not a complete operational backup. The
rollback plan must name metadata, data, credentials/gateway, refresh settings,
reports, and the person authorized to restore each missing layer.

## Token expiry and resumable polling

The reported approximately 90-minute lifetime is normal. Microsoft Entra
access tokens normally have a randomized 60-90 minute default lifetime, with
about 75 minutes average. Do not design around a guaranteed 90 minutes.

Rules:

- Never request a token in chat.
- Never decode a token for workflow logic.
- Never print, persist, commit, screenshot, or place a token in a command line,
  MCP JSON file, or connection string.
- Prefer the existing interactive MCP/Azure Identity session or
  `Connect-PowerBIServiceAccount` profile.
- If custom code is approved, use MSAL and its token cache. Try silent
  acquisition first and fall back to interactive only when policy requires it.
- Do not bypass Conditional Access or sign-in-frequency prompts.

An accepted enhanced refresh or Fabric long-running operation runs in the
service. Expiration of the initiating access token does not cancel it. Persist
the exact refresh ID, operation ID, and current `Location` only in an approved,
ignored private state file so polling can resume. Put only a keyed per-run
fingerprint or alias in a shareable receipt. A redacted/hashed ID cannot be used
to poll the operation.

A `401` during a GET/poll normally means reauthenticate and resume. With
approved custom MSAL code, try cached silent acquisition, which can redeem a
cached refresh token, and retry the failed idempotent GET/poll once. If `401`
persists, stop: wrong resource/audience, missing consent, revocation, or
Conditional Access can require a different remedy or interactive sign-in. A
`403` usually points to scope, workspace/item permission, ownership, tenant
setting, capacity setting, or unsupported model type; repeated token refresh
is not a fix.

If a POST response is lost after transmission, its outcome is ambiguous.
Inspect refresh history or current model state before resubmitting. Never
blindly repeat a non-idempotent write because a client timed out.

For local Modeling MCP interactive auth, restart the MCP server to force a new
authentication prompt or switch accounts. If the configuration injects a
`PBI_MODELING_MCP_ACCESS_TOKEN`, treat that as a short-lived secret supplied by
an external broker; remove it from checked-in configuration and prefer
interactive auth for this user-driven workflow.

## Change and approval gates

### Read-only

Allowed after normal scope confirmation:

- list accessible workspaces/models;
- inspect the exact workspace role and limited metadata;
- inspect refresh history;
- connect XMLA read-only;
- export a private metadata snapshot;
- run bounded DAX assertions;
- inventory dependencies and partitions.

Do not use a mutation to prove permission.

### Candidate

Create the exact object-scoped TMDL/TOM/C# diff offline. Include target aliases,
before/after fingerprints, dependencies, refresh impact, downstream reports,
tests, and rollback. Do not call a write-capable MCP transaction an offline
candidate merely because it has not committed yet.

### Controlled live write

Require explicit authorization immediately before:

- any Modeling MCP modification or transaction commit;
- Tabular Editor `Ctrl+S` to a connected service model;
- service TMDL View Apply;
- XMLA/TMSL execution;
- owner-only parameter/connection/schedule operations.

Reconnect and prove the persisted diff before any dependent action. For an MCP
transaction, set a bounded lifetime, roll back on every error or cancellation
path, and verify rollback/commit state in `finally`. The MCP's
first-modification prompt does not replace the repository's per-change gate.

### High impact

Use a separate confirmation for:

- full deploy/overwrite or Fabric `updateDefinition`;
- model/table/partition refresh with material capacity/data impact;
- `partialBatch`;
- incremental-policy changes;
- ownership takeover;
- gateway, schedule, credentials, security, role, or permission changes;
- report rebind;
- rename/delete/compatibility changes affecting multiple consumers;
- production promotion.

## Failure classification

| Observation | Meaning | Safe response |
|---|---|---|
| REST returns `401` during polling | Session token is absent/expired/revoked | Reauthenticate through the approved broker and poll the same request ID |
| `401` persists after one approved silent renewal | Wrong audience/resource, consent, revocation, or Conditional Access is plausible | Stop; inspect auth configuration or complete required interactive sign-in rather than looping |
| REST returns `403` | Authorization/settings/model gate failed | Inspect scope, item role, owner, tenant/capacity setting, and model category; do not retry blindly |
| POST returns `202 Accepted` | Operation exists or was accepted, not completed | Capture `Location`/request ID and poll terminal state |
| Refresh POST returns `400` while another refresh is active | Per-model concurrency rule | Inspect the current refresh; do not start a retry loop |
| Client token expires during refresh | Client can no longer poll with that token | Service job continues; reacquire auth and resume polling |
| XMLA read succeeds but save fails | Build/read works but Write or capacity Read Write may not | Inspect effective model permission and capacity/tenant settings |
| Model is absent from XMLA tools | Unsupported category, discovery restriction, wrong tenant/URL, or propagation delay | Confirm exact model type, endpoint, ownership restriction, and wait only when documented |
| M metadata persists but refresh fails | Stored text is not proof of credentials, gateway, schema, privacy, source, or M behavior | Classify service error, keep metadata/data claims separate, and roll back if required |
| Measure persists but DAX assertion fails | Syntactic acceptance did not prove semantics | Revert the object-scoped diff or correct it in candidate state |
| PBIX download is unavailable after XMLA write | Documented XMLA consequence | Use the retained original and private TMDL source; do not improvise an unsupported recovery |
| Recent permission grant is missing in REST | Permission cache might lag | With approval, call `RefreshUserPermissions` once, wait about two minutes, then retry the read |
| `429` with `Retry-After` | Request or capacity throttling | Honor exact delay and use bounded retries; capacity overload may require workload action |
| Fabric definition request returns `202` | Long-running operation | Follow `Location`, respect `Retry-After`, and poll the operation resource |
| Fabric `202` has an empty body | Expected LRO acceptance surface | Capture `Location` and `x-ms-operation-id`; do not parse it as definition/result data |
| Fabric operation reaches `Failed` | Terminal operation failure | Do not request/use a result; retain sanitized status and execute the rollback/escalation plan |
| Saved poll URL returns `404` | Wrong target/ID, expired operation surface, or lost state is possible | Reconfirm exact private state and target; do not create a replacement write automatically |
| JSON `executeQueries` returns 200 with nested error/truncation | Partial or invalid query result | Fail the assertion and reject all limited data |
| HTTP 200 Arrow response has `IsError=true` | Query/permission failure encoded in the stream | Fail the assertion; record sanitized fault code only |

## Sanitized receipt

Store runtime receipts under an ignored private run directory. A Power BI
receipt should contain:

```json
{
  "run_id": "<generated-run-id>",
  "mode": "read-only|candidate|controlled-write|high-impact",
  "target": {
    "workspace_alias": "<workspace-alias>",
    "workspace_id_fingerprint": "<environment-scoped-hash>",
    "semantic_model_alias": "<semantic-model-alias>",
    "semantic_model_id_fingerprint": "<environment-scoped-hash>"
  },
  "identity_source": "interactive-mcp|powerbi-profile|tabular-editor-mfa|approved-app",
  "capabilities": {
    "power_bi_rest": "observed|unknown",
    "fabric_rest": "observed|unknown",
    "xmla_read": "observed|unknown",
    "xmla_write": "observed|unknown",
    "owner": "observed|unknown"
  },
  "operation": "<sanitized-operation>",
  "request_id": "<environment-scoped-fingerprint-or-null>",
  "metadata_before_hash": "<hash-or-null>",
  "metadata_after_hash": "<hash-or-null>",
  "refresh": {
    "scope": "none|model|table|partition",
    "commit_mode": "none|transactional|partialBatch",
    "terminal_status": "not-started|completed|failed|cancelled|unknown"
  },
  "checks": [],
  "rollback": "ready|used|unavailable",
  "status": "passed|failed|inconclusive"
}
```

Exclude exact GUIDs, tenant/workspace/model names, UPNs, tokens, authorization
headers, cookies, raw request/response bodies, raw `serviceExceptionJson`,
data-source names, connection strings, M, DAX, TMDL, RLS, raw query results,
and internal URLs.

## Synthetic command templates

These examples use placeholders. They are not authority to install modules or
run writes.

### Windows PowerShell 5.1 read-only discovery

Use the Microsoft Power BI PowerShell profile if the approved module is already
installed. Do not auto-install it on a managed workstation.

```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$null = Connect-PowerBIServiceAccount

$workspaceMatches = @(
    Get-PowerBIWorkspace -Name '<workspace-name>'
)
if ($workspaceMatches.Count -ne 1) {
    throw 'Workspace alias did not resolve to exactly one accessible workspace.'
}
$workspace = $workspaceMatches[0]

$modelMatches = @(
    Get-PowerBIDataset -WorkspaceId $workspace.Id `
        -Name '<semantic-model-name>'
)
if ($modelMatches.Count -ne 1) {
    throw 'Model alias did not resolve to exactly one accessible semantic model.'
}
$model = $modelMatches[0]

$historyUrl = 'groups/{0}/datasets/{1}/refreshes?$top=10' -f `
    $workspace.Id, $model.Id
$history = Invoke-PowerBIRestMethod -Url $historyUrl -Method Get `
    -TimeoutSec 60 | ConvertFrom-Json

$history.value | Select-Object refreshType, startTime, endTime, status
```

Keep this console output private; refresh timestamps/status are operational
metadata, not a public receipt. The sample intentionally omits exact IDs,
exception payloads, and source details. Failure of refresh-history access does
not justify takeover or a permission mutation.

### TE2/TE3 candidate measure upsert

Run with F5 to change Tabular Editor's in-memory candidate, inspect the diff,
then use the separate live-save gate. Do not use Apply & Sync automatically.

```csharp
var tableMatches = Model.Tables
    .Where(t => t.Name == "<measure-table>")
    .ToList();
if (tableMatches.Count != 1)
    throw new Exception("Target table did not resolve exactly once.");
var table = tableMatches[0];

var matches = Model.AllMeasures
    .Where(m => m.Name == "<measure-name>")
    .ToList();
if (matches.Count > 1) throw new Exception("Ambiguous measure name.");

var measure = matches.SingleOrDefault();
if (measure != null && measure.Table != table)
    throw new Exception("Existing measure is in a different table; stop for review.");
if (measure == null)
    measure = table.AddMeasure(
        "<measure-name>",
        "DIVIDE([<numerator-measure>], [<denominator-measure>])",
        "<display-folder>");
else
    measure.Expression =
        "DIVIDE([<numerator-measure>], [<denominator-measure>])";

measure.FormatString = "0.0%";
measure.Description = "<approved-description>";
```

### Targeted non-incremental TMSL refresh candidate

Use only after proving the table has no policy or explicitly resolving policy
behavior. Prefer enhanced REST when a resumable asynchronous operation is
needed.

```json
{
  "refresh": {
    "type": "full",
    "objects": [
      {
        "database": "<semantic-model-name>",
        "table": "<table-name>"
      }
    ]
  }
}
```

### Read-only XMLA connectivity probe

This is a TE3 diagnostic only, not a Windows PowerShell 5.1 recipe. Run it with
PowerShell 6.2+ from the Tabular Editor 3 installation folder so dependencies
resolve. On managed Windows PowerShell 5.1, use Tabular Editor/SSMS interactive
MFA unless IT provides a supported client-library bundle. It proves only
connection and database discovery:

```powershell
$xmla = 'powerbi://api.powerbi.com/v1.0/<tenant-primary-domain-or-myorg>/<uri-encoded-workspace>'
$connectionString = (
    'Provider=MSOLAP;Data Source={0};Interactive Login=Always;' +
    'Identity Mode=Connection'
) -f $xmla

Add-Type -Path '.\Microsoft.AnalysisServices.Tabular.dll'
$server = [Microsoft.AnalysisServices.Tabular.Server]::new()
try {
    $server.Connect($connectionString)
    [pscustomobject]@{
        Connected = $true
        DatabaseCount = @($server.Databases).Count
    }
}
finally {
    if ($server.Connected) { $server.Disconnect() }
    $server.Dispose()
}
```

Do not paste an MCP/REST bearer token into this connection string. If exact
database names are needed to select a target, keep that output in the local
confirmation surface and redact it before prompts, receipts, screenshots, or
Git.

## Primary sources

Microsoft:

- [Semantic model connectivity with the XMLA endpoint](https://learn.microsoft.com/en-us/fabric/enterprise/powerbi/service-premium-connect-tools)
- [Semantic model permissions](https://learn.microsoft.com/en-us/power-bi/connect-data/service-datasets-permissions)
- [Workspace roles](https://learn.microsoft.com/en-us/power-bi/collaborate-share/service-roles-new-workspaces)
- [Enhanced refresh with the Power BI REST API](https://learn.microsoft.com/en-us/power-bi/connect-data/asynchronous-refresh)
- [Refresh Dataset In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/refresh-dataset-in-group)
- [Cancel Refresh In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/cancel-refresh-in-group)
- [Get Refresh Execution Details In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/get-refresh-execution-details-in-group)
- [Get Refresh History In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/get-refresh-history-in-group)
- [Get Groups](https://learn.microsoft.com/en-us/rest/api/power-bi/groups/get-groups)
- [Get Datasets In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/get-datasets-in-group)
- [Refresh User Permissions](https://learn.microsoft.com/en-us/rest/api/power-bi/users/refresh-user-permissions)
- [Execute Queries In Group (JSON)](https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/execute-queries-in-group)
- [Execute DAX Queries with Arrow](https://learn.microsoft.com/en-us/power-bi/developer/execute-dax-queries-arrow/overview)
- [Execute DAX Queries In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/execute-dax-queries-in-group)
- [Update Parameters In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/update-parameters-in-group)
- [Update Datasources In Group](https://learn.microsoft.com/en-us/rest/api/power-bi/datasets/update-datasources-in-group)
- [Power BI REST throttling](https://learn.microsoft.com/en-us/rest/api/power-bi/)
- [Work with TMDL view](https://learn.microsoft.com/en-us/power-bi/transform-model/desktop-tmdl-view)
- [Semantic-model version history](https://learn.microsoft.com/en-us/power-bi/transform-model/service-semantic-model-version-history)
- [Premium semantic-model backup and restore](https://learn.microsoft.com/en-us/fabric/enterprise/powerbi/service-premium-backup-restore-dataset)
- [Large semantic models](https://learn.microsoft.com/en-us/fabric/enterprise/powerbi/service-premium-large-models)
- [Develop content and manage changes](https://learn.microsoft.com/en-us/power-bi/guidance/powerbi-implementation-planning-content-lifecycle-management-develop-manage)
- [Access-token lifetime](https://learn.microsoft.com/en-us/entra/identity-platform/access-tokens)
- [Acquire and cache tokens with MSAL](https://learn.microsoft.com/en-us/entra/msal/python/getting-started/acquiring-tokens)
- [Power BI PowerShell cmdlets](https://learn.microsoft.com/en-us/powershell/power-bi/overview)
- [Connect-PowerBIServiceAccount](https://learn.microsoft.com/en-us/powershell/module/microsoftpowerbimgmt.profile/connect-powerbiserviceaccount?view=powerbi-ps)
- [Invoke-PowerBIRestMethod](https://learn.microsoft.com/en-us/powershell/module/microsoftpowerbimgmt.profile/invoke-powerbirestmethod?view=powerbi-ps)
- [Power BI MCP server overview](https://learn.microsoft.com/en-us/power-bi/developer/mcp/mcp-servers-overview)
- [Microsoft Power BI Modeling MCP](https://github.com/microsoft/powerbi-modeling-mcp)
- [Fabric semantic-model definition](https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/semantic-model-definition)
- [List semantic models](https://learn.microsoft.com/en-us/rest/api/fabric/semanticmodel/items/list-semantic-models)
- [Get semantic-model definition](https://learn.microsoft.com/en-us/rest/api/fabric/semanticmodel/items/get-semantic-model-definition)
- [Update semantic-model definition](https://learn.microsoft.com/en-us/rest/api/fabric/semanticmodel/items/update-semantic-model-definition)
- [Fabric long-running operations](https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation)
- [Fabric API scopes](https://learn.microsoft.com/en-us/rest/api/fabric/articles/scopes)

Tabular Editor:

- [Power BI XMLA connectivity](https://docs.tabulareditor.com/en/tutorials/powerbi-xmla.html)
- [Connect to a tabular database](https://docs.tabulareditor.com/en/how-tos/connect-ssas.html)
- [TE2 command-line options](https://docs.tabulareditor.com/en/features/Command-line-Options.html)
- [Workspace Mode](https://docs.tabulareditor.com/en/tutorials/workspace-mode.html)
- [Automatic metadata backup](https://docs.tabulareditor.com/en/how-tos/metadata-backup.html)
- [Work with expressions and DAX properties](https://docs.tabulareditor.com/en/how-tos/scripting-work-with-expressions.html)
- [Power Query import and validation limits](https://docs.tabulareditor.com/en/how-tos/Importing-Tables.html)
