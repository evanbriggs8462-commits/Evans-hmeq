---
name: migrate-finance-query
description: Translate and harden finance data-acquisition logic into a reviewable candidate, especially Power Query M, Excel/folder combine-file or XML transformations moving to Databricks SQL, Python, or a revised M query. Use for query recreation, source replacement, transformation mapping, folding/performance analysis, schema drift, or moving stable logic upstream while preserving grain and finance semantics.
---

# Migrate a Finance Query

1. Load `finance-report-migration`, the migration playbook, finance semantics,
   and every matching `finance-data-reliability` reference.
2. Require an inventory and an `approved`, evidenced semantic contract for
   every rule the executable candidate depends on. If the contract remains
   draft/blocked, produce only a mapping or non-executable skeleton and mark
   the dependent logic `MISSING_CONTEXT`.
3. Map every source step to inputs, operation, output grain, row/control-total
   check, target equivalent, and risk. Trace helper/sample-file functions as one
   program.
4. Preserve explicit types, decimal precision, locale, encoding, nulls, signs,
   dates, source identity, join cardinality, and exceptions.
   If a merge/expand multiplies rows, use the semantic contract to choose one
   of four explicit outcomes: reject/exception-route a broken unique lookup,
   aggregate a legitimate one-to-many source to the declared grain, select an
   effective-dated row with proven non-overlap, or return `MISSING_CONTEXT`.
   Never hide amplification with `DISTINCT` or an arbitrary row number.
5. Produce the smallest local candidate plus structural, row-count, key,
   grouped-total, and negative-fixture tests.
6. Mark performance changes separately from business-logic changes.
7. Stop at the candidate unless an exact governed write/deployment is
   authorized. Query execution authority does not imply schema write authority.

Never force agreement by deleting exceptions, using absolute values, broad
`COALESCE`, bidirectional relationships, or unproven filters.
