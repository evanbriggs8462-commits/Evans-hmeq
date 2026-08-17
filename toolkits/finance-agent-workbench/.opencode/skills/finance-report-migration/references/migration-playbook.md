# End-to-End Finance Report Migration Playbook

## Definition of done

A migrated report is done only when the relevant forms of parity are proven:

1. **Data parity** — the intended source rows, keys, periods, and amounts agree.
2. **Semantic parity** — measures, hierarchies, relationships, signs, currency,
   blanks, filters, and security behave as intended.
3. **Report parity** — pages, visuals, drill paths, filters, bookmarks, titles,
   tooltips, formatting, and user workflows are preserved or intentionally
   changed.
4. **Operational parity** — refresh timing, credentials/gateway, capacity,
   ownership, failure handling, monitoring, and consumer availability meet the
   agreed service expectation.

Do not collapse these into one “totals match” check.

## Phase 0: prepare the task

Create a task brief before opening several tools or generating code. Record:

- desired business outcome and whether this is recreation, repair,
  optimization, visual authoring, or investigation;
- current artifact and source of truth;
- candidate target and environment;
- comparison grain, time window, measures, dimensions, and tolerances;
- exact prohibitions and the highest possible write gate;
- approved context/capability receipts; and
- required deliverables and stopping condition.

If an existing run handoff has the same task-brief hash and fresh artifacts,
resume it rather than repeating inventory or capability probes.

## Phase 1: inventory the legacy report

Inventory before rewriting. Capture paths or private aliases plus hashes,
versions, and timestamps for:

### Data acquisition

- every Power Query query and group;
- parameters and current values;
- data source kind, path/endpoint alias, navigation step, and privacy/gateway
  dependency;
- helper queries, sample files, transform functions, invoked functions, and
  combine-file orchestration;
- query load/enable-refresh settings;
- native queries, query folding boundaries, buffering, joins, grouping,
  pivots/unpivots, type conversions, locale assumptions, filters, and custom
  functions;
- source file selection rules and snapshot/as-of behavior.

### Semantic model

- tables, columns, data types, formats, hidden state, sort-by columns, and data
  categories;
- measures, calculated columns/tables, calculation groups, perspectives,
  hierarchies, and roles;
- relationships with active state, direction, cardinality, and referential
  integrity assumption;
- partitions, storage mode, incremental-refresh policy, and source expression;
- dependencies and model compatibility level.

### Report layer

- pages, sizes, visibility, themes, and navigation;
- visuals, visual types, positions, bindings, conditional formatting, titles,
  interactions, drill-through, and tooltips;
- page, report, and visual filters; slicer state; bookmarks; buttons; and
  selections;
- custom visuals and unsupported features;
- known blank space and layout constraints when adding a visual.

### Operations and evidence

- refresh schedules/history, duration, failures, overlap, gateway/credentials,
  owners, consumers, subscriptions, and dependencies;
- approved benchmark totals and screenshots, with sensitive artifacts kept
  private;
- known manual adjustments and “tribal knowledge” not encoded in the report.

Output an inventory with `observed`, `inferred`, and `unknown` fields. A
screenshot of relationships or pasted M/DAX is useful evidence but not a full
inventory when machine-readable metadata is available.

## Phase 2: reconstruct the source and transformation contract

For each loaded table or material intermediate query:

1. identify the exact source selection rule;
2. state the input and output grain;
3. map output columns to source fields or transformations;
4. identify types, locale, null, sign, date, and encoding rules;
5. classify filters as business rules, performance filters, or accidental
   limitations;
6. record join keys, cardinality, unmatched behavior, and duplicate risk;
7. separate reusable business logic from report-specific presentation logic;
8. mark every opaque/custom step for a targeted fixture; and
9. distinguish “the old report does this” from “the business requires this.”

### Combine-files and sample-file pattern

Power Query may hide the real transformation across a folder query, parameter,
sample binary, transform-sample query, and generated function. Treat the group
as one program.

- Trace the selected sample and all helper dependencies.
- Test more than the sample file: empty file, alternate column order, optional
  columns, malformed row, encoding change, trailing footer, and schema drift.
- Preserve source-file identity and row lineage until reconciliation passes.
- Do not translate only the outer folder query and assume the helper function
  is boilerplate.

### XML and semi-structured exports

- Stage large remote exports once and parse the verified local copy through the
  reliability runbook.
- Record namespaces, row element, required fields, encoding, EOF, rejected
  records, and source mutation evidence.
- Do not infer record count or validity from a prefix, regex, or a successful
  XML tag search.
- Preserve synthetic fixtures for each observed layout or source quirk.

## Phase 3: map to the governed target

Use bounded metadata and read-only queries to identify candidate Unity Catalog
objects. Genie may accelerate discovery, but it cannot own the mapping.

For each candidate field or table, record:

- source alias and target alias;
- business definition and grain;
- type and nullable behavior;
- key role and expected cardinality;
- snapshot/version/date coverage;
- ledger, currency, sign, hierarchy, and exclusion behavior;
- transformation still required;
- evidence supporting the match; and
- deterministic check that will accept or reject it.

Classify mappings:

- `DIRECT` — same meaning and grain;
- `DERIVED` — explicit reproducible transformation;
- `LOOKUP` — approved mapping/hierarchy relationship;
- `PARTIAL` — coverage or semantics differ;
- `UNKNOWN` — evidence insufficient; or
- `NO_TARGET` — must retain or create another approved source path.

Visibility in Unity Catalog or mention by Genie is not proof of approval,
lineage completeness, or semantic equivalence.

## Phase 4: create the candidate query

Translate transformation logic in small, testable stages. Prefer named CTEs or
views in candidate SQL and keep each stage aligned with the source contract.

### Translation rules

- Preserve filter order when it changes row membership or join behavior.
- Use explicit types and decimal precision; never rely on engine defaults for
  finance amounts.
- Replace locale-sensitive text conversion with an explicit parser and fixture.
- Prove join cardinality and control totals before and after every material
  join.
- Keep an exception output for unmapped, rejected, duplicate, or out-of-scope
  rows.
- Match the required as-of snapshot; do not compare a live table with a frozen
  export without labeling the result inconclusive.
- Push logic upstream only when it is stable, reusable, governed, and proven at
  the required grain. Keep report-specific filter-context behavior in the
  semantic layer when appropriate.
- Do not write a governed table, view, notebook, or job merely because the
  generated SQL passes locally.

### Candidate outputs

Return:

- formatted candidate SQL/M/Python;
- a stage-by-stage lineage table;
- expected schema and uniqueness assertions;
- exception queries and reconciliation queries;
- unsupported transformations; and
- performance hypotheses separately from semantic changes.

## Phase 5: migrate the semantic model

Treat the model as a contract, not a bag of DAX expressions.

1. Recreate or deliberately revise table and column metadata.
2. Map relationships and prove key uniqueness/cardinality.
3. Port measures with their format strings, display folders, dependencies, and
   filter-context tests.
4. Classify calculated columns/tables: retain, move upstream, or replace only
   after parity evidence.
5. Preserve roles/security behavior and test with authorized synthetic cases.
6. Keep incremental refresh, partitions, storage mode, and processing behavior
   explicit.
7. Run independent DAX queries for totals, groups, edge cases, and filter
   context.

### Tool boundaries

- **DAX Studio:** query, inspect, benchmark, and validate DAX/model behavior.
  It does not edit Power Query or report visuals and does not save a PBIX.
- **Tabular Editor 2:** inspect/edit TOM semantic-model metadata. It can store
  M partition text but cannot execute or validate the M. A save to a published
  XMLA model is an immediate shared write.
- **Power BI Desktop/PBIP:** author local Power Query, model, and report-layer
  candidates and render behavior.
- **Modeling MCP/XMLA/TOM:** semantic-model metadata within the target and
  permission boundary; not the report canvas.
- **PBIR/report-authoring tools:** report pages, visuals, layout, filters, and
  themes through a private candidate and separate publication gate.

Never claim that one tool can cross a boundary it does not support.

## Phase 6: preserve or improve the report layer

For one-for-one recreation, preserve page/visual intent even when the backend
changes. Validate:

- field and measure bindings;
- filter and slicer semantics;
- visual-level calculations and conditional formatting;
- sort, drill, tooltip, interaction, and bookmark behavior;
- units, decimals, percentages, negative display, blanks, and titles;
- page geometry, overlap, clipping, responsive behavior, and theme; and
- representative screenshots with only approved synthetic/private data.

For a requested new visual, inventory the page, find bounded free space, clone
an appropriate visual only when its bindings/formatting are understood, assign
unique identifiers, and validate the local PBIR candidate. Do not publish a
whole report definition as an incidental “add one visual” action.

## Phase 7: reconcile in layers

Run reconciliation in this order so a later aggregate does not hide an earlier
structural defect:

1. artifact/schema/version/snapshot checks;
2. row counts and distinct business keys;
3. duplicates, nulls, rejected rows, and unmapped members;
4. global additive control totals;
5. grouped totals by period and critical organization/product dimensions;
6. currency/sign/ledger/component checks;
7. bounded key-level exceptions;
8. DAX/filter-context assertions; and
9. visual and operational checks.

For each discrepancy, classify the most likely layer and the evidence that
supports it. Do not tune logic until the cause is isolated.

Use `INCONCLUSIVE`, not pass, when snapshots, hierarchy versions, rules,
permissions, or evidence cannot be aligned.

## Phase 8: operational readiness and refresh planning

Separate source/warehouse time, result transfer, Power Query/data acquisition,
semantic-model processing, and Power BI capacity queueing.

- Use Power BI/Fabric refresh and capacity evidence for BI-side contention.
- Use bounded Databricks query-history/warehouse evidence for source compute.
- Normalize time zones and correlate by bounded windows and approved aliases.
- Build a baseline across representative business days and close periods.
- Recommend staggered schedules or architectural changes with expected benefit
  and confidence.
- Do not automatically change schedules, warehouse settings, jobs, partitions,
  or queries.

A Databricks query-history record cannot by itself prove Power BI Premium/Fabric
capacity queueing. A long Power BI refresh cannot by itself prove slow SQL.

## Phase 9: package the result

End every material run with:

- final task brief hash;
- inventory and semantic-contract locations;
- candidate diff/artifact hashes;
- checks and their pass/fail/inconclusive results;
- unresolved discrepancies and missing context;
- last verified boundary;
- exact next permitted step; and
- resume instructions that name the relevant skill and reference files.

Do not require the next model to reconstruct decisions from a chat transcript.

## Hard stops

Stop before a dependent change when:

- the grain, ledger, hierarchy version, currency/sign rule, or snapshot cannot
  be established;
- the target or environment is ambiguous;
- a supposed key is not unique and the join policy is unknown;
- the original/source-of-truth artifact or rollback path is missing;
- a candidate diff contains unexplained churn;
- a deterministic reconciliation fails;
- a live write, publication, schedule, refresh, permission, or compute action
  lacks the required gate; or
- a security control blocks the exact action.

A blocked live action does **not** block safe local work. Continue with public
documentation, synthetic fixtures, adapters, tests, candidate code, and an
explicit list of what remains unverified.

