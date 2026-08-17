# Databricks Reconciliation

Treat reconciliation as an evidence problem, not a query-generation contest. Freeze the comparison contract before deciding that either system is wrong.

Before authenticating, inventorying a workspace, selecting CLI/SDK/MCP, or
calling Genie, read [Databricks agent access](databricks-agent-access.md).
That reference governs identity, allowlists, compute/query side effects, and
the boundary between a Genie hypothesis and deterministic validation.

## Read-only boundary

Default to metadata reads, `SELECT`, and explain/query-history operations permitted by the environment. Do not run `CREATE`, `REPLACE`, `INSERT`, `UPDATE`, `DELETE`, `MERGE`, `COPY INTO`, `OPTIMIZE`, `VACUUM`, grants, job changes, schedule changes, or cluster/warehouse changes without an exact authorized target and the controlled-write gate.

Use the configured credential mechanism. Never print, copy, commit, or move a token into a command, script, receipt, notebook, or configuration example. Fully qualify approved catalog, schema, and table names at execution time, but sanitize internal identifiers in Git and shared examples.

## Freeze the comparison contract

Document these values before writing the final comparison:

- source and target snapshots or extraction times;
- business grain and business keys;
- date field, timezone, fiscal/calendar interpretation, inclusivity, and cutoff;
- measures, units, currency conversion rule, sign convention, scale, and rounding;
- null, blank, zero, cancellation, reversal, and duplicate behavior;
- joins and hierarchy/reference-data versions;
- allowed absolute and relative tolerances;
- expected late-arriving or backdated data.

If one of these is unknown, label the result provisional. A matching grand total does not prove matching records, and a record mismatch does not prove a transformation defect until snapshot and grain are aligned.

## Reconcile from coarse to fine

1. **Input integrity:** verify staged file hash, size, stable completion, parser status, row count, schema fingerprint, and date bounds.
2. **Target identity:** verify workspace/endpoint, catalog, schema, object, object type, and any available table version or timestamp.
3. **Shape:** compare column presence, logical types, null counts, duplicate-key counts, row counts, and min/max dates.
4. **Global measures:** compare counts and decimal aggregates using explicit casts and documented rounding.
5. **Grouped measures:** compare by date period and stable business dimensions. Start with low-cardinality groups that expose cutoff, currency, sign, or hierarchy errors.
6. **Key-level exceptions:** isolate missing keys, extra keys, duplicates, and value differences only after the aggregate layer points to a bounded area.
7. **Repeatability:** rerun against the same snapshots. If the result changes, investigate snapshot drift before transformation logic.

Avoid binary floating-point for financial comparisons. Cast to a suitable decimal type and apply rounding only at the contract-defined stage. Preserve null separately from zero unless the business rule explicitly equates them.

## Mismatch triage

Check in this order:

1. Different extraction time, table version, refresh state, or late-arriving data.
2. Date cutoff, timestamp-to-date conversion, timezone, fiscal period, or inclusive endpoint.
3. Grain mismatch, duplicate multiplication, many-to-many joins, or filtering after a join.
4. Currency, unit scaling, decimal precision, rounding stage, or sign convention.
5. Null/blank/zero behavior, cancellations, reversals, or excluded status values.
6. Reference-data or hierarchy version differences.
7. Parser/schema drift, including renamed fields, optional elements, or unexpected types.
8. Actual transformation or source-data defect.

Do not “fix” a mismatch by adding an unexplained filter, tolerance, sign flip, deduplication, or hard-coded adjustment. State which evidence supports the rule.

## Query discipline

- Select only required columns and constrain date ranges early.
- Use deterministic filters and explicit casts. Avoid `SELECT *` in reconciliation evidence.
- Hash or version query text in the receipt; do not copy sensitive SQL or sample rows into Git.
- Bound exception samples and redact sensitive values. Prefer counts and grouped summaries in logs.
- Record the query ID when available, target identity in sanitized form, elapsed time, and whether caching may have affected timing.
- Use `EXPLAIN` for performance diagnosis; do not change compute configuration as an incidental fix.

## Reconciliation receipt

Record:

- run ID and UTC interval;
- read-only mode and tool/runtime versions;
- sanitized source/target identifiers and snapshot information;
- input and query hashes;
- contract: grain, keys, dates, measures, currency/sign/rounding rules, tolerances;
- row, duplicate, null, and schema checks;
- global and grouped differences;
- counts of missing, extra, duplicate, and changed keys;
- observed failure class, remaining hypotheses, warnings, and final status.

Mark the run **failed** when an invariant breaks, **inconclusive** when snapshots or rules cannot be aligned, and **passed** only when all declared checks meet their tolerances.
