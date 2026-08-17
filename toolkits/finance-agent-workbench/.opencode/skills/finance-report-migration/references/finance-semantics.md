# Finance Semantics and Hierarchy Rules

## Why this layer exists

Most finance-report migration failures are semantic rather than syntactic. SQL
can run, M can refresh, and DAX can return a plausible total while the result
uses the wrong grain, ledger, hierarchy version, sign, currency, or exclusion.
Write the semantic contract before optimizing a query.

## Minimum semantic contract

For each material metric or output table, record:

| Field | Required decision |
|---|---|
| Business meaning | What decision or control the metric supports |
| Grain | One row per exact business key and time state |
| Sources | Approved source aliases and snapshot/version |
| Keys | Natural/surrogate keys and uniqueness expectations |
| Measures | Formula, aggregation, numerator/denominator, and non-additive behavior |
| Dates | Posting, document, shipment, fiscal, FX, snapshot, and effective-date roles |
| Ledger/version | Actual, plan, forecast, profitability, consolidation, or other view |
| Currency | Transaction, local, group/reporting currency and conversion timing |
| Signs | Debit/credit, revenue/cost presentation, trailing-minus, and reversal rules |
| Hierarchies | OU/BU/plant/account/product/profit-center/market path and effective dates |
| Joins | Cardinality, unmatched policy, bridge logic, and duplicate expectations |
| Null behavior | Difference among missing, not applicable, blank, zero, and unknown |
| Filters | Inclusion/exclusion rules, intercompany treatment, status, and organizational scope |
| Tolerance | Exact, absolute, relative, rounding, and stage where tolerance applies |

No model should infer an omitted field from a familiar finance convention when
the choice could change results.

## Grain and join discipline

1. State the intended grain in one sentence before writing a join.
2. Prove uniqueness of each supposed dimension key at the relevant effective
   date or snapshot.
3. Calculate pre-join and post-join row counts, distinct business keys, and
   additive control totals.
4. Classify every unmatched row. Do not hide it with an inner join or coalesce.
5. Detect one-to-many and many-to-many amplification explicitly. A matching
   grand total after offsetting duplicate errors is still a failure.
6. Keep source identity columns until reconciliation is complete.

## Effective-dated hierarchies

Treat account, business-unit, product, plant, market, and profit-center maps as
versioned data, not static labels.

- Identify the effective-start and effective-end convention, including open
  ends and inclusive/exclusive boundaries.
- Decide whether the report uses transaction-date, posting-date, fiscal-period,
  or current hierarchy assignment.
- Detect overlaps and gaps for the same member.
- Preserve unmapped and multiply mapped exceptions as evidence.
- Do not join today's hierarchy to historical facts unless the business rule
  explicitly requires a current-state restatement.
- When a hierarchy exists in several systems, record which system owns each
  level and how conflicts are resolved.

## Accounts, ledgers, and signs

- Do not assume GL, SPL, PCA/profitability, planning, or consolidation ledgers
  are interchangeable. Expand local abbreviations in the private contract.
- Record whether revenue and margin are stored or displayed positive/negative.
- Normalize SAP-style trailing minus only under an explicit numeric parser.
- Distinguish reversals, credits, debit/credit indicators, statistical rows,
  allocations, and eliminations.
- Reconcile both raw signed amounts and presentation amounts when sign logic is
  changing layers.
- Preserve source precision; round only at the contractually defined stage.

## Currency and FX

Record source currency, target currency, rate type, rate date, triangulation,
precision, and missing-rate behavior. Separate these questions:

1. Was the source already converted?
2. Which date selects the rate?
3. Is the measure additive after conversion?
4. Are actuals, plan, backlog, and orders using the same rate policy?
5. Does the report show local, group, reporting, or constant currency?

Do not repair a variance by changing the rate date until the snapshots and
currency columns have been aligned.

## Gross margin and markup logic

For any standard, sales, or integrated gross-margin metric, record:

- exact revenue and cost components;
- numerator and denominator, including zero-denominator behavior;
- whether price, standard cost, actual cost, freight, duty, overhead,
  intercompany markup, intracompany markup, eliminations, and FX are included;
- the organizational and product grain at which components are valid; and
- whether percentages are recalculated from totals or averaged from rows.

Never hardcode a target percentage from public context. The current target and
approved formula belong in the private overlay or task brief.

## Blank, zero, and missing

Keep these distinct until the semantic contract says otherwise:

- `null` or blank: no value supplied or no applicable relationship;
- zero: measured value is exactly zero;
- unknown member: relationship was expected but mapping failed;
- not applicable: metric intentionally has no value at this grain;
- suppressed/filtered: value exists but is not exposed in the current view.

Power Query, SQL, DAX, and visuals handle these states differently. Test them
at each boundary.

## Required negative fixtures

Every reusable migration workflow should include synthetic cases for:

- duplicate join amplification;
- overlapping and missing effective-date mappings;
- trailing-minus and locale-specific numeric text;
- blank-versus-zero behavior;
- zero-denominator margin;
- late-arriving or changing snapshots;
- mismatched fiscal/calendar periods;
- missing or duplicate FX rates;
- intercompany/intracompany inclusion changes; and
- a grand total that matches while a plant/product subgroup does not.
