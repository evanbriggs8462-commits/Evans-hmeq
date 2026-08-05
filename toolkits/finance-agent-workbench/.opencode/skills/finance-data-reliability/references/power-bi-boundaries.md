# Power BI External-Tool Boundaries

Use the narrowest tool that can perform and prove the operation. A tool's ability to connect to a model does not imply that it can safely edit, validate, process, save, or publish every artifact.

## Capability boundary

| Operation | Correct boundary | Required evidence |
|---|---|---|
| Run DAX queries, inspect DMVs, test totals, or analyze query performance | DAX Studio | Query text or hash, target identity, result assertions, timings if relevant |
| Inspect measures, columns, relationships, partitions, roles, or annotations | DAX Studio or Tabular Editor 2, depending on metadata needed | Exported inventory or canonical metadata fingerprint |
| Edit semantic-model metadata through TOM | Tabular Editor 2 or a deterministic TOM wrapper | Baseline export, proposed diff, explicit write gate, round-trip diff |
| Assign an M expression to a partition | Tabular Editor 2 can write the expression as TOM metadata | Exact partition target, before/after expression hash, then host-based M validation |
| Execute or validate Power Query M and discover its resulting schema | Power BI Desktop or another supported Power Query host | Successful evaluation/refresh plus expected schema and row assertions |
| Refresh, recalculate, or process a Desktop model from an external tool | Do not issue the external processing command | Perform processing in the supported host and retain its result |
| Save, publish, overwrite, or replace a shared artifact | Use the supported Power BI workflow after a separate high-impact gate | Backup, exact destination, post-save reopen, refresh/test, publication receipt |

## Facts to preserve

- DAX Studio is for querying, inspection, testing, export, and performance analysis. It is not a Power Query editor and does not by itself save a PBIX model change.
- Tabular Editor 2 edits semantic-model metadata through the Tabular Object Model. It does not continuously validate the model while edits are being authored.
- Power BI Desktop releases from June 2025 onward support all TOM metadata write operations. External processing commands are still forbidden; metadata write support is not processing support.
- Tabular Editor 2 may assign M text to a partition expression. It cannot execute Power Query M, prove that the M is valid, discover the evaluated schema, or verify source credentials. A successful TOM write proves only that metadata was written.

Confirm the installed Power BI Desktop and external-tool versions before relying on version-specific behavior. Do not infer compatibility solely from a visible connection.

## Metadata-write gate

Before applying a TOM change:

1. Echo the exact model, connection, table, object type, and object name. Stop on ambiguity.
2. Export a canonical baseline of affected objects and retain a recoverable backup.
3. Produce a minimal proposed diff. Do not combine unrelated changes.
4. Validate names, dependencies, data types, format strings, expressions, relationships, and compatibility level as far as static inspection permits.
5. Obtain explicit authorization for the live write.
6. Apply the smallest change through a deterministic script or reviewed TE2 action.
7. Reconnect and re-export the object. Compare the round-trip metadata with the proposal.
8. Run independent DAX assertions. If M changed, evaluate it in Power BI Desktop and verify the resulting schema and expected data behavior.
9. Save or publish only through its own gate. Record the outcome in the receipt.

## Validation pipeline

Use this order so a later success cannot hide an earlier defect:

1. **Inventory:** model identity, compatibility level, affected objects, dependencies, partitions, relationships, and expression hashes.
2. **Static checks:** missing references, duplicate names, incompatible data types, suspicious relationship direction/cardinality, and deterministic formatting.
3. **Candidate diff:** exact intended metadata delta with no live mutation.
4. **TOM round trip:** write only after approval, reconnect, and confirm the persisted metadata.
5. **DAX behavior:** execute known assertions at total and sliced grains. Include blank, duplicate, and filter-context edge cases.
6. **Power Query behavior:** when M or a partition changed, execute refresh/evaluation in the supported host and compare columns, data types, row counts, and representative aggregates.
7. **Artifact behavior:** reopen the saved artifact, repeat critical assertions, and only then consider publish or replacement.

## Stop conditions

Stop and report the gap when:

- the target model or object cannot be identified uniquely;
- a backup or rollback path is missing;
- the requested action depends on an unsupported external processing command;
- M cannot be evaluated in a supported Power Query host;
- a metadata write succeeded but its round-trip or behavioral validation failed;
- the operation would overwrite or publish without explicit confirmation.

## Primary sources

- [Microsoft: External tools in Power BI Desktop](https://learn.microsoft.com/en-us/power-bi/transform-model/desktop-external-tools)
- [Tabular Editor: Importing tables and Power Query limitations](https://docs.tabulareditor.com/en/how-tos/Importing-Tables.html)
- [DAX Studio: Feature documentation](https://daxstudio.org/docs/category/features/)
