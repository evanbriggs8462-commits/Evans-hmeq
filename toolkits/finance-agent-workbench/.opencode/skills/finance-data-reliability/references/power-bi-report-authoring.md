# Power BI Report Authoring and Published-Report Promotion

Use this reference when an agent must create or modify Power BI report pages,
visuals, slicers, filters, bookmarks, layout, formatting, or themes. It covers
Microsoft's preview report skills, PBIP/PBIR files, the Power BI Desktop Bridge,
and the controlled retrieval and replacement of an existing report definition
in a Fabric workspace.

This is public tooling guidance. Never commit an actual report definition,
screenshot, workspace or item ID, semantic-model name, connection string,
access token, sensitivity label, internal theme or image, query text, filter
selection, or business value to this public repository. PBIR is source-control
friendly, but that does **not** make a company's PBIR safe to publish.

## Preview status and hard boundary

Power BI Projects, PBIR, the Power BI report skills, the Power BI MCP servers,
and the Power BI Desktop Bridge are documented as preview features as of this
reference. Their installation, command names, schemas, tenant availability,
and behavior can change. Before a repeatable run:

1. Record the installed Power BI Desktop version and the exact version of the
   Microsoft Skills for Fabric `powerbi-authoring` bundle.
2. Inspect the installed skill and CLI help instead of recalling an older
   command or JSON shape.
3. Confirm that the tenant permits the preview and that the target report is
   stored or retrievable in PBIR, not only PBIR-Legacy.
4. Work from an approved private baseline and a development copy.
5. Treat every Fabric create, update, publish, overwrite, rebind, or delete as
   a separate remote write. A prior approval to edit local files is not approval
   to publish them.

PBIR enables supported programmatic editing of the report layer. It does not
turn report authoring into an unconstrained canvas REST API. The supported
workflow edits the PBIR definition, validates it, renders it in Desktop, and
only then replaces the deployed definition after an explicit high-impact gate.

## Choose the correct skill or tool

The four Microsoft report skills are complementary, not interchangeable.

| Need | Correct skill/tool | What it owns | What it must not own |
|---|---|---|---|
| Decide what a report should look like | `powerbi-report-design` | Audience-oriented page archetypes, chart choice, layout, color, typography, accessibility, anti-pattern review, and a structured design brief | PBIR file writes or Fabric transport |
| Guide a new report from requirements to an approved plan | `powerbi-report-planner` | Requirements, semantic-model inspection, locked brief, implementation plan, approval point, and orchestration after approval | Guessing PBIR JSON or silently publishing |
| Make a concrete report-layer change | `powerbi-report-authoring` | PBIR pages, visuals, filters, slicers, bookmarks, themes, formatting, validation, Desktop reload, and screenshot verification | Semantic-model metadata, data queries as evidence, or Fabric item CRUD |
| Move a complete report definition to or from Fabric | `powerbi-report-management` | Fabric report item discovery and CRUD, PBIR definition download/upload, LRO handling, and binding checks | Designing a report or constructing PBIR content from memory |
| Add or change a measure, column, relationship, table, or model metadata | Local Power BI Modeling MCP or another reviewed TOM/TMDL workflow | Semantic-model layer | Report pages, visual placement, or report formatting |
| Query an existing semantic model for analysis | Remote Power BI MCP, DAX Studio, or a bounded DAX API route | Query and insight layer | Model or report authoring |
| Verify the local rendered report | Power BI Desktop Bridge | Status, reload, and page screenshots for a running local Desktop instance | Fabric deployment or proof that service publication succeeded |

Routing examples:

- "Add one card to a known blank area using an existing measure" is a direct
  Report Authoring task after the target page, measure, and layout are fixed.
- "Make this finance report executive-ready" starts with Report Design, then
  passes an approved design brief to Report Authoring.
- "Build a new report from this model" starts with Report Planner.
- "Download or upload this report definition" uses Report Management for
  transport, with Report Authoring responsible for any PBIR content changes.
- "Create the measure needed by the card" is a semantic-model task and needs a
  separate model-change gate before the report binds to it.

Do not ask the Modeling MCP to create a visual. Do not ask Report Authoring to
create a model measure. Do not ask Report Management to invent report JSON.

## What PBIR and PBIP change

A Power BI Project (PBIP) stores source-control-oriented report and semantic
model artifacts in folders. Enhanced report format (PBIR) separates pages,
visuals, bookmarks, and other report metadata into documented JSON files with
public schemas. Typical PBIR report parts include:

```text
<REPORT_ALIAS>.Report/
  definition.pbir
  definition/
    report.json
    version.json
    pages/
      pages.json
      <PAGE_ALIAS>/
        page.json
        visuals/
          <VISUAL_ALIAS>/
            visual.json
            mobile.json        # when present
    bookmarks/                 # when present
  StaticResources/             # when present
```

PBIR supports operations such as copying visuals or pages and applying batch
edits. A visual's metadata can include its page position, size, z-order,
tab order, query bindings, filters, interactions, and formatting. Therefore an
authoring tool can add a visual into available canvas space, but only after it
checks all of those surrounding contracts.

PBIR is not automatically public-safe. Microsoft documents that PBIR metadata
can persist semantic-model data values, including filter values and slicer
selections. A report can also contain internal field names, measure names,
custom themes, images, custom visual metadata, bookmarks, report-level
measures, and a semantic-model reference. Keep all real PBIR and rendered
screenshots in approved private storage and exclude them from public Git.

### PBIR-Legacy is not an authoring substitute

PBIR-Legacy uses a monolithic `report.json` and does not support the same
external editing workflow. For the Microsoft report skills, request PBIR
explicitly:

```http
POST https://api.fabric.microsoft.com/v1/workspaces/<WORKSPACE_ID>/reports/<REPORT_ID>/getDefinition?format=PBIR
```

If the result is PBIR-Legacy or the tenant/report cannot provide PBIR, stop.
Use Power BI Desktop to create or convert an approved private PBIP/PBIR copy,
or follow the organization's supported migration path. Do not transform the
legacy payload into invented enhanced-format files.

PBIR conversion is itself a version transition. Preserve an independent copy
before conversion. Desktop's and the service's temporary conversion backups
are useful recovery aids, not a replacement for a controlled baseline owned by
the team.

## Minimum contract for a visual edit

Before changing even one visual, establish a candidate-change contract. Keep
live IDs and internal names in ignored local configuration; a public receipt
uses aliases and hashes only.

```yaml
operation: candidate_report_edit
publish_authorized: false
target:
  environment: TEST
  workspace_alias: FINANCE_TEST
  report_alias: VARIANCE_REVIEW
  page_alias: EXECUTIVE_SUMMARY
baseline:
  definition_sha256: <SHA256>
  retrieved_utc: <UTC_TIMESTAMP>
requested_change:
  action: add_visual
  visual_type: cardVisual
  purpose: show a synthetic variance measure
  semantic_binding_alias: METRIC_VARIANCE_AMOUNT
  proposed_region: TOP_RIGHT_OPEN_SLOT
expected_scope:
  - definition/pages/<PAGE_ALIAS>/visuals/<NEW_VISUAL_ALIAS>/visual.json
  - definition/pages/<PAGE_ALIAS>/page.json  # only if actually required
must_not_change:
  - semantic_model_reference
  - page_order
  - bookmarks
  - filters
  - unrelated_visuals
  - sensitivity_label
validation:
  - pbir_schema
  - semantic_binding
  - no_overlap
  - desktop_reload
  - desktop_screenshot_review
  - source_control_diff
```

For insertion into "blank space," do not infer that an empty-looking rectangle
is unused. Inspect:

- page width, height, display mode, and mobile layout;
- every visual bounding box, z-order, tab order, and hidden state;
- selection-pane objects, buttons, shapes, tooltips, drillthrough targets, and
  bookmarks that can occupy or depend on that region;
- existing visual interactions and page/report filters;
- accessibility reading order, alt text, contrast, and focus behavior;
- the exact table, column, or measure binding and its expected data type;
- responsive behavior and the rendered result at the expected display size.

## Controlled workflow for an existing published report

Use this sequence for a report already published to a Fabric/Power BI
workspace. Steps 1 through 6 create and validate a local candidate. Step 7 is a
separate high-impact remote replacement.

### 1. Resolve identity, target, and permissions without mutation

Resolve the exact workspace and report by ID inside the approved environment.
Do not rely on display name alone. Record sanitized aliases in the receipt and
stop if name resolution returns zero or multiple matches.

For Fabric `getDefinition` and `updateDefinition`, Microsoft currently requires:

- read **and** write permission on the report; and
- delegated scope `Report.ReadWrite.All` or `Item.ReadWrite.All`.

Supported identity types include users, service principals, and managed
identities, subject to tenant policy and the caller's effective permissions.
A successful list or get-report call does not prove definition read/write
permission. Do not test write capability by publishing a harmless-looking
change.

### 2. Retrieve the exact PBIR baseline

Call the Fabric report definition endpoint with `format=PBIR` and no token in
the command text, log, transcript, or repository:

```http
POST https://api.fabric.microsoft.com/v1/workspaces/<WORKSPACE_ID>/reports/<REPORT_ID>/getDefinition?format=PBIR
```

Authentication is supplied by the approved client credential broker. Do not
construct, print, or persist an authorization header in the agent workflow.

The endpoint is a POST even though it retrieves a definition. A successful
response returns a collection of definition parts. Each part has a relative
path and a payload, currently commonly `InlineBase64`.

Baseline rules:

1. Store the raw response and decoded parts in a new approved private run
   directory outside public Git and sync roots.
2. Reject absolute paths, parent traversal, duplicate paths, unexpected
   payload types, invalid base64, and paths outside the candidate root before
   decoding any part.
3. Preserve all returned parts, including parts the proposed edit does not
   understand. Omitting an unchanged part from a later full definition can
   remove it.
4. Generate a manifest of relative paths, byte counts, and SHA-256 hashes.
5. Verify the definition is PBIR, contains required parts, and references the
   expected semantic model alias. Never print the live connection string.
6. Make the baseline directory immutable to the authoring step. Copy it to a
   candidate directory before edits.

`getDefinition` is not a complete backup of the report's world. It does not
back up semantic-model data, model metadata, credentials, gateway mappings,
permissions, app state, subscriptions, deployment configuration, or the
sensitivity label. Back up and validate each affected layer separately.

### 3. Handle sensitivity labels explicitly

Microsoft documents three material label behaviors for these operations:

- The sensitivity label is not included in the public report definition
  returned by `getDefinition`.
- `getDefinition` is blocked for a report with an encrypted sensitivity label.
- `updateDefinition` does not change the report's sensitivity label.

Consequences:

- Do not interpret a definition without a label field as an unlabeled report.
- Do not remove, downgrade, copy, or bypass a label to make automation work.
- Treat an encrypted-label block as a policy stop, not a parsing or token bug.
- After any authorized update, independently verify the report still has the
  expected label through an approved UI or label-management control.
- A report definition copied into private storage must still be handled at the
  classification required by its source, even though the label is absent from
  the exported definition.

### 4. Materialize a local PBIP/PBIR candidate

Report Management owns the download/transport mechanics. Report Authoring owns
the files after a valid PBIR project exists locally.

Create a candidate from the decoded baseline rather than from an empty report.
Confirm `definition.pbir` binds to the intended development semantic model.
For Fabric deployment, Microsoft documents a `byConnection` reference; never
reuse an unreviewed production connection in a test candidate or invent a
semantic-model ID.

Before Desktop opens the candidate:

- ensure the current Desktop file has no unsaved work;
- retain a private baseline commit or equivalent immutable snapshot;
- prohibit tools from writing to the baseline copy;
- confirm that model entity and measure names used by every affected visual
  exist in the target semantic model;
- keep report and model edits in separate diffs and approvals.

### 5. Author the smallest report-layer delta

Use `powerbi-report-authoring` for the concrete PBIR edit. If the visual design
is not fixed, use `powerbi-report-design` first and approve its structured brief.
For a broad new report, use `powerbi-report-planner` and do not begin file writes
until its plan is approved.

Authoring rules:

1. Inspect the installed skill and current CLI capability metadata before
   selecting visual roles, enum values, formatting objects, selectors, or
   expression encodings.
2. Never guess PBIR JSON from memory, copy undocumented internal structures
   from an unrelated report, or make a global find-and-replace without an
   exact schema-aware predicate.
3. Touch the minimum set of files. Review unexpected formatting churn,
   regenerated identifiers, page-order changes, and unrelated visual edits.
4. Preserve page, visual, and bookmark identifiers unless the operation
   intentionally creates a new object.
5. Keep visual type, role bindings, query references, sort fields, filters,
   and semantic-model entity/property names internally consistent.
6. Include desktop and mobile layout considerations when the report supports
   mobile consumption.
7. Do not update the semantic model merely because a desired visual field is
   missing. Stop and open a separately reviewed model-change proposal.

### 6. Validate the local candidate and rendered output

Static JSON validity is necessary but insufficient. Use the authoring skill's
current validation path after each logical batch, then validate rendered output
with a supported local Power BI Desktop instance.

The Microsoft documentation currently describes this loop:

```text
PBIR edit
  -> validate report structure and schemas
  -> inspect source-control diff
  -> Desktop Bridge status / unsaved-change check
  -> reload PBIR in Desktop
  -> capture affected page screenshot
  -> independent visual review
  -> iterate or stop
```

The Desktop Bridge is local-only and preview. It can report the open file and
unsaved-change state, reload a PBIR definition, and capture page screenshots.
Each Desktop window has its own local named pipe and only one bridge operation
runs at a time. Discover the current bridge manifest before using a method.

Required checks:

- validation exits successfully with no ignored schema errors;
- the candidate reopens or reloads in Desktop;
- Desktop is showing the exact candidate path, not another report window;
- no unsaved human edits are discarded;
- the intended visual renders without an error icon or empty frame;
- values, units, format strings, conditional colors, titles, and totals are
  plausible against a separate deterministic DAX check;
- visual bounds do not overlap or clip at the target page size;
- slicers, filters, drill, tooltip, bookmark, button, and interaction behavior
  still works where affected;
- keyboard/tab order and contrast remain acceptable;
- screenshots contain no sensitive data before they leave approved storage;
- a canonical diff shows only the approved change.

A screenshot proves rendered appearance at one moment. It does not prove
correct finance logic, RLS behavior, refresh correctness, every interaction,
or how the report renders in the service. Use independent semantic-model and
service checks for those conclusions.

### 7. Review the complete deployment payload

Fabric `updateDefinition` **overrides** the report definition. Treat it as a
whole-definition replacement, not as a patch to one visual. Before requesting
publish approval:

1. Rebuild the definition payload from the validated candidate, including
   every required and preserved part.
2. Compare its path manifest with the baseline. Explain every added, removed,
   or changed part.
3. Verify the semantic model binding against the exact target environment.
4. Preserve a separately restorable copy of the original full definition and
   its manifest.
5. Record the rollback route: another explicitly authorized whole-definition
   update using the original baseline, followed by the same validation.
6. Confirm the target report has not changed since baseline retrieval. If a
   current re-download has a different manifest, stop and reconcile the
   concurrent change instead of overwriting it.
7. Obtain explicit approval naming the exact workspace, report, candidate
   hash, semantic-model target, and expected impact.

The optional `updateMetadata=true` parameter can update item metadata from a
supplied `.platform` part. Do not enable it by habit. Omit it unless changing
that metadata is specifically required, reviewed, and approved.

### 8. Replace the deployed definition only after approval

The endpoint shape is:

```http
POST https://api.fabric.microsoft.com/v1/workspaces/<WORKSPACE_ID>/reports/<REPORT_ID>/updateDefinition
Content-Type: application/json

{
  "definition": {
    "parts": [
      {
        "path": "<RELATIVE_PBIR_PART_PATH>",
        "payload": "<INLINE_BASE64>",
        "payloadType": "InlineBase64"
      }
    ]
  }
}
```

This template is deliberately incomplete and synthetic. Use the current
Microsoft Report Management skill or documented Fabric REST schema to assemble
the complete payload; do not paste a token or real definition into source
control. Publishing must be a distinct command or tool call that cannot be
triggered by the local authoring step.

### 9. Poll long-running operations correctly

`getDefinition`, create, and `updateDefinition` can return immediately with
`200`/`201`, or return `202 Accepted` for a long-running operation (LRO). A
`202` is not success and does not mean a new definition is active.

For `202`, capture these response headers without exposing credentials:

- `Location`: operation state URL;
- `x-ms-operation-id`: stable operation ID;
- `Retry-After`: minimum delay in seconds before the next poll.

Poll the exact operation, honor `Retry-After`, use a bounded overall deadline,
and stop only on a documented terminal state. If the state succeeds and the
operation has a result, retrieve the result using the returned location or the
operation result endpoint. Treat `429` the same way: honor `Retry-After`; do not
launch parallel retries. Preserve the operation ID in a private run receipt.

Never:

- call `updateDefinition` again because the first response was `202`;
- infer progress from an agent heartbeat or elapsed timer;
- poll without a deadline;
- replace a failed operation with a new publish before classifying its state;
- report success before terminal state and post-deployment validation.

### 10. Verify the deployed report independently

After the update reaches a successful terminal state:

1. Retrieve the report and a fresh `getDefinition?format=PBIR` result.
2. Materialize it into a separate verification directory.
3. Compare its normalized path/hash manifest with the approved candidate.
4. Verify the semantic-model binding and sensitivity label independently.
5. Open the exact service report through the approved route and test the
   affected page, visual, filters, bookmarks, navigation, and interactions.
6. Run deterministic DAX assertions against the bound model for the visual's
   important totals and slices.
7. Confirm that unrelated pages and critical visuals still render.
8. Record the observed operation result, round-trip comparison, and behavioral
   checks. Label anything not tested as unverified.

If any postcondition fails, stop. Do not stack another speculative edit on top
of an unknown deployed state. Assess whether the approved original definition
can be restored safely and obtain the required rollback authorization.

## Approval gates

Use distinct gates so an agent cannot turn local design approval into a live
overwrite.

### Gate A: read-only baseline

Permits target discovery, permission inspection, `getDefinition`, private
decode, manifest generation, and report/model inventory. It does not permit
conversion, local file mutation, service mutation, or publication.

### Gate B: local candidate

Permits copying the baseline into a private candidate, editing PBIR files,
validating, opening/reloading in Desktop, and capturing private screenshots.
It does not permit a Fabric create, update, delete, rebind, or publish.

### Gate C: development deployment

Permits replacing the exact named development-copy report definition with the
exact approved candidate hash. It requires a baseline, rollback artifact,
concurrency check, LRO poll, and postconditions.

### Gate D: shared or production deployment

Requires a fresh explicit confirmation after development evidence is reviewed.
Name the exact target, candidate, semantic-model binding, expected downtime or
consumer impact, rollback artifact, approver, and validation window. Do not
combine this gate with model, data-source, permission, label, gateway, app, or
refresh changes.

## Recommended dev-copy pattern

For a shared finance report, use a separate development report bound to an
approved development or test model where possible:

```text
published baseline (read-only retrieval)
  -> private immutable baseline
  -> local candidate branch
  -> PBIR validation
  -> Desktop screenshot and deterministic DAX checks
  -> dedicated development report deployment
  -> service smoke test and peer review
  -> explicit production gate
  -> whole-definition production update
  -> round-trip and behavior proof
```

Do not use a production report as the first renderer for a new visual. Do not
use a consumer-visible workspace as temporary agent scratch space. Do not bind
a development report to production by copying an opaque `definition.pbir`
connection unchanged.

## Diff and validation policy

The candidate review must answer:

- Which exact PBIR parts changed?
- Which new/removed identifiers are expected?
- Did the semantic-model reference change?
- Did page order, active page, bookmarks, filters, custom themes, resources,
  mobile layout, interactions, or report-level measures change?
- Does every visual binding resolve in the target model?
- Did Desktop validate and render the candidate?
- Were screenshots and deterministic DAX assertions reviewed?
- Is the candidate manifest identical to the deployed round trip?
- Can the original complete definition still be restored?

Reject the candidate when a one-visual request produces unexplained churn
across unrelated pages or when a formatter rewrites the entire definition.
Readable JSON does not make a broad diff safe.

## Sanitized receipt

A public-safe report-authoring receipt can record:

```json
{
  "run_id": "<RANDOM_RUN_ID>",
  "started_utc": "<UTC_TIMESTAMP>",
  "ended_utc": "<UTC_TIMESTAMP>",
  "mode": "candidate|development-write|production-write",
  "workspace_alias": "<SANITIZED_ALIAS>",
  "report_alias": "<SANITIZED_ALIAS>",
  "page_alias": "<SANITIZED_ALIAS>",
  "baseline_manifest_sha256": "<SHA256>",
  "candidate_manifest_sha256": "<SHA256>",
  "changed_part_count": 1,
  "added_part_count": 1,
  "removed_part_count": 0,
  "pbir_validation": "passed|failed|not_run",
  "desktop_reload": "passed|failed|not_run",
  "screenshot_review": "passed|failed|not_run",
  "semantic_binding_check": "passed|failed|not_run",
  "publish_authorized": false,
  "fabric_operation_alias": "<HASH_OR_REDACTED>",
  "terminal_state": "not_started|succeeded|failed|unknown",
  "round_trip_manifest_match": "passed|failed|not_run",
  "warnings": []
}
```

Keep actual IDs, paths, definition parts, screenshots, operation URLs, error
details, labels, access tokens, and business values in the approved private
receipt. A hash or sanitized alias may still be sensitive under company policy;
follow that policy before sharing it externally.

## What not to do

- Do not directly edit a live service report as the first implementation step.
- Do not treat `updateDefinition` as a one-visual PATCH; it overrides the report
  definition.
- Do not let an agent publish merely because it successfully edited local JSON.
- Do not generate PBIR JSON from memory or undocumented reverse engineering
  when the Report Authoring skill and public schemas are available.
- Do not hand PBIR mechanics to Design, Planner, Management, or Modeling MCP.
- Do not hand semantic-model mutations to Report Authoring.
- Do not use Report Management deletion as cleanup without a separate
  destructive-action confirmation.
- Do not ignore an encrypted sensitivity-label block or attempt to bypass it.
- Do not assume the exported definition includes or preserves proof of the
  sensitivity label.
- Do not decode definition parts without path-traversal and duplicate-path
  checks.
- Do not omit unknown unchanged parts from a full replacement payload.
- Do not use `updateMetadata=true` unless `.platform` metadata mutation is an
  intentional and approved part of the change.
- Do not overwrite a report if a new baseline hash shows a concurrent change.
- Do not reload Desktop while it contains unsaved human changes.
- Do not accept schema validation alone as visual or finance validation.
- Do not accept a screenshot alone as evidence of correct DAX or security.
- Do not commit real PBIR, screenshots, local settings, access tokens, internal
  identifiers, or semantic-model values to this public repository.
- Do not use preview features in production without the organization's tenant,
  security, compliance, support, and rollback review.

## Primary sources

- [Microsoft: Power BI Report Authoring skill](https://learn.microsoft.com/en-us/power-bi/developer/agentic/power-bi-report-authoring-skill-overview)
- [Microsoft: Power BI Report Design skill](https://learn.microsoft.com/en-us/power-bi/developer/agentic/power-bi-report-design-skill-overview)
- [Microsoft: Power BI Report Planner and Management skills](https://learn.microsoft.com/en-us/power-bi/developer/agentic/power-bi-planner-fabric-skill-overview)
- [Microsoft: Power BI agentic capabilities overview](https://learn.microsoft.com/en-us/power-bi/developer/agentic/power-bi-agentic-overview)
- [Microsoft: Power BI Desktop Bridge](https://learn.microsoft.com/en-us/power-bi/developer/agentic/power-bi-desktop-bridge-overview)
- [Microsoft: Power BI MCP servers overview](https://learn.microsoft.com/en-us/power-bi/developer/mcp/mcp-servers-overview)
- [Microsoft: Enhanced report format (PBIR)](https://learn.microsoft.com/en-us/power-bi/developer/embedded/projects-enhanced-report-format)
- [Microsoft: Power BI Desktop project report folder and PBIR limitations](https://learn.microsoft.com/en-us/power-bi/developer/projects/projects-report)
- [Microsoft: Fabric report definition structure](https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/report-definition)
- [Microsoft: Get Report Definition](https://learn.microsoft.com/en-us/rest/api/fabric/report/items/get-report-definition)
- [Microsoft: Update Report Definition](https://learn.microsoft.com/en-us/rest/api/fabric/report/items/update-report-definition)
- [Microsoft: Fabric long-running operations](https://learn.microsoft.com/en-us/rest/api/fabric/articles/long-running-operation)
- [Microsoft: Skills for Fabric](https://github.com/microsoft/skills-for-fabric)
