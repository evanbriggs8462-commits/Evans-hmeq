# Power BI Tool and Service Boundaries

Use the narrowest tool that can perform and prove the operation. A tool's ability to connect to a model does not imply that it can safely edit, validate, process, save, or publish every artifact.

For a capacity workspace, published semantic model, Power BI REST request,
XMLA endpoint, MCP server, refresh operation, or expiring token, also load
[Power BI Premium workspace operations](power-bi-premium-workspace-runbook.md).

## Capability boundary

| Operation | Correct boundary | Required evidence |
|---|---|---|
| Discover accessible workspaces/models | Ordinary Power BI REST, or an MCP only when its advertised tool schema supports the exact read | Exact read endpoint/tool, signed-in identity source, sanitized target, response classification |
| Inspect refresh history | Ordinary Power BI REST | Exact target, bounded history request, status/error classification |
| Start, poll, or cancel a service refresh | Prefer enhanced Power BI REST for asynchronous polling; service XMLA/TMSL is also supported | Separate authorization, request ID, terminal state, per-object evidence, postconditions |
| Run DAX queries, inspect DMVs, test totals, or analyze query performance | DAX Studio | Query text or hash, target identity, result assertions, timings if relevant |
| Inspect measures, columns, relationships, partitions, roles, or annotations | DAX Studio, Tabular Editor 2, read-only local Modeling MCP, or XMLA, depending on metadata needed | Exported inventory or canonical metadata fingerprint |
| Edit a published semantic model through TOM | Tabular Editor 2, local Modeling MCP, or deterministic TOM wrapper over service XMLA | Private baseline, proposed diff, explicit live-write gate, round-trip diff |
| Assign an M expression to a published partition | Tabular Editor 2/TOM or TMDL can store the expression | Exact partition, before/after hash, then a separate M evaluation gate |
| Execute or validate Power Query M and discover its resulting schema | Desktop/test before promotion, or explicitly authorized refresh of the exact service model | Successful evaluation/refresh plus expected schema and data assertions |
| Refresh, recalculate, or process a Desktop model from an external tool | Do not issue the external processing command | Perform processing in the supported host and retain its result |
| Save metadata in a Tabular Editor window connected to service XMLA | Immediate controlled live write to the shared model | Exact target, backup, diff, authorization, reconnect and behavioral proof |
| Save Desktop/PBIP locally | Local artifact write | Exact destination, reopen, source-control diff, local validation |
| Deploy, publish, republish, overwrite, or replace a shared artifact | Supported deployment workflow after a separate high-impact gate | Backup, exact destination, impact review, post-deploy reconnect and tests |
| Change pages, visuals, bookmarks, or report layout | Power BI Desktop/PBIP or supported report-authoring workflow | Artifact diff, reopen, visual/report validation |

## Facts to preserve

- DAX Studio is for querying, inspection, testing, export, and performance analysis. It is not a Power Query editor and does not by itself save a PBIX model change.
- Ordinary Power BI REST is an operational/control plane, not a general TOM editor. XMLA/TOM is the normal model-metadata plane; Desktop/PBIP owns the report layer.
- Tabular Editor 2 edits semantic-model metadata through TOM. It does not continuously validate the model while edits are authored, and `Ctrl+S` against a service XMLA database writes to the live shared model immediately.
- External processing commands are unsupported against a model loaded in Power BI Desktop. Authorized capacity-backed service models can be processed through service XMLA/TOM/TMSL or enhanced REST; do not transfer the Desktop restriction to the service.
- Tabular Editor 2 may assign M text to a partition expression. It cannot execute Power Query M, prove that the M is valid, discover the evaluated schema, or verify service credentials. A successful TOM write proves only that metadata was written.
- Build supports read/query scenarios. XMLA mutation needs model Write plus applicable OAuth, tenant, capacity, ownership, gateway, and model-category gates. A successful read proves none of the remaining gates.
- Before the first XMLA write to a Desktop-authored published model, preserve the original PBIX and a private canonical metadata baseline. Microsoft documents that the service model might no longer be downloadable as PBIX afterward.
- Start the local Modeling MCP with `--readonly` for discovery. Repository policy prohibits `--skipconfirmation`; its first-modification prompt never replaces the explicit write gate.

Confirm the installed Power BI Desktop and external-tool versions before relying on version-specific behavior. Do not infer compatibility solely from a visible connection.

## Metadata-write gate

Before applying a TOM change:

1. Echo sanitized aliases for the exact workspace, model, connection, table, object type, and object name while confirming the live IDs only inside the approved environment. Stop on ambiguity.
2. Export a canonical baseline of affected objects to approved private storage and retain the original PBIX/PBIP when applicable.
3. Produce a minimal proposed diff. Do not combine unrelated changes.
4. Validate names, dependencies, data types, format strings, expressions, relationships, and compatibility level as far as static inspection permits.
5. Obtain explicit authorization for the live write.
6. Apply the smallest change through a deterministic script or reviewed TE2 action.
7. Reconnect and re-export the object. Compare the round-trip metadata with the proposal.
8. Run independent DAX assertions. If M changed, evaluate it in Desktop/test before promotion or through an explicitly authorized targeted service refresh; verify schema and expected data behavior.
9. Treat refresh, deployment, publish, and replacement as separate operations with their own gates. Record the outcome in a sanitized receipt.

## Validation pipeline

Use this order so a later success cannot hide an earlier defect:

1. **Inventory:** model identity, compatibility level, affected objects, dependencies, partitions, relationships, and expression hashes.
2. **Static checks:** missing references, duplicate names, incompatible data types, suspicious relationship direction/cardinality, and deterministic formatting.
3. **Candidate diff:** exact intended metadata delta with no live mutation.
4. **TOM round trip:** write only after approval, reconnect, and confirm the persisted metadata.
5. **DAX behavior:** execute known assertions at total and sliced grains. Include blank, duplicate, and filter-context edge cases.
6. **Power Query behavior:** when M or a partition changed, execute refresh/evaluation in the exact approved Desktop/test/service host and compare columns, data types, row counts, and representative aggregates.
7. **Service-operation proof:** for asynchronous refresh, capture the request ID, poll terminal state, inspect object-level results, and then run independent assertions.
8. **Artifact behavior:** reconnect to the service or reopen the saved artifact, repeat critical assertions, and only then consider deployment, publish, or replacement complete.

## Stop conditions

Stop and report the gap when:

- the target model or object cannot be identified uniquely;
- a backup or rollback path is missing;
- the requested Desktop action depends on an unsupported external processing command;
- M cannot be evaluated in a supported Power Query host;
- a metadata write succeeded but its round-trip or behavioral validation failed;
- the selected service-side route lacks its own capability gate (for example,
  XMLA Read Write plus model Write for XMLA/TOM, or the endpoint-specific
  Fabric REST permissions), a private baseline, or a retained original
  PBIX/PBIP when the model was Desktop-authored;
- a Modeling MCP transaction is open, uncommitted, or in an unknown state;
- the operation would overwrite or publish without explicit confirmation.

## Primary sources

- [Microsoft: External tools in Power BI Desktop](https://learn.microsoft.com/en-us/power-bi/transform-model/desktop-external-tools)
- [Microsoft: Semantic model connectivity with the XMLA endpoint](https://learn.microsoft.com/en-us/fabric/enterprise/powerbi/service-premium-connect-tools)
- [Microsoft: Enhanced refresh with the Power BI REST API](https://learn.microsoft.com/en-us/power-bi/connect-data/asynchronous-refresh)
- [Microsoft: Semantic model permissions](https://learn.microsoft.com/en-us/power-bi/connect-data/service-datasets-permissions)
- [Tabular Editor: Importing tables and Power Query limitations](https://docs.tabulareditor.com/en/how-tos/Importing-Tables.html)
- [DAX Studio: Feature documentation](https://daxstudio.org/docs/category/features/)
