# SAP intercompany Genie Agent playbook

Date: 2026-09-03  
Purpose: let business users explore certified intercompany reconciliation results without allowing generated SQL to recreate SAP extraction, partner derivation, matching, allocation, FX, or GR/IR logic.

Object names below are proposed placeholders. Replace `finance_ic` catalog/schema names with the governed names in the target workspace.

## Operating boundary

Genie is the conversation and exploration layer, not the reconciliation engine.

The engine must already have produced:

- exact, point-in-time source populations;
- one-row partner-resolution decisions with evidence trace;
- match groups and members;
- conserved profit-center allocations;
- PO-item GR/IR lifecycle exceptions;
- source/control totals and a certified publication status.

Generated, read-only SQL can still be financially wrong through fan-out, currency mixing, arbitrary `MAX`, incomplete date logic, or use of stale mappings. The Agent therefore gets no direct access to raw SAP facts, mapping tables, partner-evidence candidates, or match-candidate edges.

Databricks recommends concise, well-documented and simplified/prejoined datasets for Genie. It also recommends expressing business semantics through SQL expressions and example SQL before relying on free-text instructions. [Databricks: Curate an effective Genie Agent](https://docs.databricks.com/aws/en/genie-agents/best-practices)

## 1. Certified Agent surface

Keep the initial surface to these objects:

| Object | Grain | Purpose | Direct user access |
|---|---|---|---|
| `finance_ic.semantic.ic_reconciliation_metrics` | Certified allocation/snapshot semantic grain | Standard OOB, coverage, matching, aging, and allocation measures. | Yes, through the Agent and dashboards. |
| `finance_ic.semantic.ic_exception_detail_secure` | One certified source-item allocation per exception/cutoff | Bounded drill-through with raw source keys and resolution states. | Restricted. |
| `finance_ic.semantic.ic_match_trace_secure` | One match member per match group | Explain exactly which documents make up a match or residual. | Restricted. |
| `finance_ic.semantic.grir_exception_metrics` | PO item/account assignment/cutoff | GR/IR lifecycle reporting. | Yes, with sensitive references masked as required. |
| Trusted Unity Catalog table functions | Parameterized, bounded result | Official balance, exception, and trace questions. | `EXECUTE` only. |

Do **not** add any of these to the Agent:

- BSEG, BKPF, ACDOCA, BSID/BSAD, BSIK/BSAK, VBRK/VBRP, VBFA, EKKO/EKPO/EKBE;
- entity, account, FX, profit-center, or legacy crosswalk tables;
- `ic_partner_evidence`;
- AR/AP or AR/GRIR candidate-edge tables;
- staging objects that have not passed publication controls.

Hide duplicate, low-level technical, or confusing columns from Agent context even when the secure view still contains them. Hiding a column improves context but does not replace Unity Catalog permissions. [Databricks: Tune Genie Agent quality](https://docs.databricks.com/aws/en/genie-agents/tune-quality)

## 2. Semantic contract

### Required fields

The reconciliation metric surface should expose clearly named fields:

```text
certification_status
as_of_date
as_of_timestamp
source_watermark_status
reconciliation_run_id
rule_version
mapping_version
fx_version

reconciliation_scope          -- AR_AP, GR_IR, ELIMINATION
currency_type                 -- DOCUMENT, LOCAL, GROUP
currency
owner_global_entity_id/name
partner_global_entity_id/name
directional_entity_pair_id
unordered_entity_pair_id
owner_company_code
source_system / client
account_display_group

owner_profit_center / partner_profit_center
owner_ou / partner_ou
owner_bu / partner_bu
allocation_status

partner_resolution_status
partner_resolution_method
partner_evidence_tier
financial_match_status
difference_type
cause_code
resolution_status
close_status

posting_age_bucket
due_age_bucket
partner_posting_lag_bucket
case_age_bucket
```

Do not name a field `amount` when several currency bases exist. Use explicit columns such as `signed_amount_dc`, `signed_amount_lc`, and `signed_amount_gc`, or expose separate semantic objects/functions for each currency basis.

### Exact measures

Recommended measures, each with a documented sign and denominator:

| Measure | Definition |
|---|---|
| `ic_candidate_signed` | Exact sum of signed source/allocation amount within one currency basis and currency. |
| `ic_candidate_gross` | Exact sum of absolute source/allocation amount. |
| `ar_signed` / `ap_signed` | Exact directional AR or AP sums. |
| `pair_oob_signed` | AR plus AP signed residual for one entity pair, cutoff, currency type, and currency. Never includes GR/IR. |
| `posted_partner_gross` | Gross amount whose source line carried a mapped posted partner. |
| `derived_partner_gross` | Gross amount resolved through an approved unique fallback. |
| `unresolved_partner_gross` | Gross amount with no selected canonical partner. |
| `ambiguous_or_conflicting_partner_gross` | Gross amount withheld from automatic pairing because evidence was nonunique or conflicting. |
| `matched_side_gross` | Gross allocated amount on source sides with an approved match status; label it as side gross to avoid implying one transaction value. |
| `unmatched_gross` | Gross unallocated/unmatched amount, including zero-net groups. |
| `supported_unmatched_gross` | Unmatched exposure with approved support/reason and evidence. |
| `unexplained_gross` | Unmatched exposure without approved support. |
| `allocation_residual` | Original source amount minus sum of allocations, by source item and currency. |
| `zero_net_unassigned_gross` | Gross unassigned amount in groups whose signed pair residual is within the balance tolerance. |
| `grir_open_signed` | GR/IR signed amount within its own PO-item lifecycle fact. |

Use fixed-scale `DECIMAL`, exact `SUM`, and exact `COUNT` for published finance measures. Never use `approx_*`, samples, `FLOAT`/`DOUBLE` control arithmetic, limited-row extrapolation, or `try_sum` for certification.

### Metric-view sketch

This illustrates the semantic intent; adjust syntax to the workspace runtime and approved source schema.

```yaml
version: 1.1
comment: 'Certified global intercompany reconciliation metrics. Never use for uncertified runs.'
source: finance_ic.gold.ic_certified_allocation_snapshot
filter: certification_status = 'CERTIFIED'

fields:
  - name: as_of_date
    expr: as_of_date
  - name: currency_type
    expr: currency_type
  - name: currency
    expr: currency
  - name: owner_entity
    expr: owner_global_entity_name
  - name: partner_entity
    expr: partner_global_entity_name
  - name: entity_pair
    expr: unordered_entity_pair_id
  - name: financial_match_status
    expr: financial_match_status
  - name: partner_resolution_status
    expr: partner_resolution_status
  - name: difference_type
    expr: difference_type
  - name: owner_profit_center
    expr: owner_profit_center
  - name: partner_profit_center
    expr: partner_profit_center

measures:
  - name: pair_oob_signed
    expr: SUM(signed_amount) FILTER (WHERE reconciliation_scope = 'AR_AP' AND item_role IN ('AR','AP'))
  - name: candidate_gross
    expr: SUM(ABS(signed_amount)) FILTER (WHERE reconciliation_scope = 'AR_AP')
  - name: unresolved_partner_gross
    expr: SUM(ABS(signed_amount)) FILTER (WHERE partner_resolution_status = 'UNRESOLVED')
  - name: unexplained_gross
    expr: SUM(ABS(unmatched_amount)) FILTER (WHERE resolution_status IN ('OPEN','INVESTIGATING'))
```

Metric views centralize measures, fields, filters, joins, and agent metadata so reports and Genie use the same definitions. [Databricks: Metric-view modeling](https://docs.databricks.com/aws/en/uc-semantics/metric-views/basic-modeling) Agent metadata provides display names, formats, and synonyms. [Databricks: Agent metadata](https://docs.databricks.com/aws/en/uc-semantics/agent-metadata)

The safe default is no semantic-layer join at all: build the certified allocation snapshot at the required grain. If a metric view uses a many-to-one dimension join, continuously prove dimension uniqueness and referential coverage. Declared cardinality is not a substitute for data tests.

### Materialization strategy

Use aggregated materializations for predictable dashboards such as entity pair × close × currency × status, and an unaggregated materialization only when ad hoc slicing justifies its cost. Databricks can route metric-view queries to compatible materializations automatically. [Databricks: Metric-view materialization](https://docs.databricks.com/aws/en/uc-semantics/metric-views/materialization)

For finance, there is an important freshness caveat: metric-view materialization currently uses `relaxed` rewrite mode, which does not verify materialization freshness, SQL settings, or determinism before choosing the fast path. A query that matches a materialization can therefore read its last refresh while another query falls back to live source data. Point the metric view at immutable certified run snapshots, align refresh after certification, return `reconciliation_run_id`/`as_of_timestamp` in every answer, and consider an unaggregated materialization when all query shapes must read one consistent snapshot. Do not point an official-close Agent at a mutable “latest” fact without an explicit certified-run boundary.

Security affects the design:

- A metric view or source using row-level security, column masks, or ABAC cannot use metric-view materialization.
- For homogeneous access, use materialized metric views plus object grants.
- For user/entity-specific access, build protected internal aggregates, then expose secure dynamic/nonmaterialized views and a nonmaterialized metric view over the permitted result.
- Disable Agent entity matching for sensitive identifiers and for dynamic/secure views as required. Representative values are generated using the author’s permissions and become shared Agent context. Tables with row filters/masks are excluded automatically, but views over protected data require explicit care. [Databricks: Tune Genie Agent quality](https://docs.databricks.com/aws/en/genie-agents/tune-quality)

## 3. Trusted functions

Put finance-critical logic behind Unity Catalog SQL table functions so Genie can call it but cannot rewrite its internal SQL. Databricks treats registered SQL functions and exact parameterized examples as trusted assets. [Databricks: Tune Genie Agent quality](https://docs.databricks.com/aws/en/genie-agents/tune-quality)

Recommended interfaces:

```text
tf_ic_pair_summary(
  as_of_date, currency_type, currency,
  owner_entity, partner_entity, account_display_group
)

tf_ic_unresolved_partner_exposure(
  as_of_date, currency_type, currency,
  source_system, owner_entity, materiality
)

tf_ic_exception_drilldown(
  as_of_date, entity_pair, currency_type, currency,
  difference_type, resolution_status, max_rows
)

tf_ic_match_trace(match_group_id)

tf_grir_po_item_exceptions(
  as_of_date, owner_entity, partner_entity,
  lifecycle_exception_type, minimum_age_days, materiality
)
```

Function requirements:

- reject or safely handle missing cutoff/currency parameters;
- query only certified runs unless an engineering-only function is explicitly named;
- apply exact currency predicates before aggregation;
- return cutoff, run, rule, mapping, FX, and source-watermark versions;
- apply bounded drill-through after all financial filters;
- never resolve a partner, create a match, or recompute an allocation at query time;
- return a clear row when a requested close is uncertified or source-incomplete.
- expose GR/IR `history_basis_status`, `reversal_status`,
  `clearing_control_status`, and `routing_safety_status`; raw EKBE presence must
  not become a supplier/receipt action while EKBEH or reversal lineage is absent.

## 4. Paste-ready general instructions

Use one short, coherent global instruction block. Encode metrics in metric-view SQL expressions and difficult question shapes in examples/functions.

```text
This Agent reports only from certified intercompany reconciliation assets.

For official balances, OOB, unmatched amounts, missing-partner exposure, or
reconciliation status, use the certified metric view or an approved trusted
SQL function. Never recreate partner, matching, FX, allocation, or GR/IR logic.

For official period reporting, use the latest CERTIFIED close unless the user
specifies another as-of date. For operational reporting, use the latest
CERTIFIED operational run. Always state the selected as-of timestamp,
source-watermark status, rule version, currency type, and currency.

Never add, compare, or net amounts across currencies or currency types. If the
request does not identify a usable currency basis, ask for clarification or
return separate groups by currency type and currency.

OOB means the published AR plus AP residual. GR/IR is never included in OOB.
Only show a GR/IR timing explanation when the published record has confirmed
buyer/seller and PO-item lineage, EKBE plus EKBEH coverage, resolved reversal
and clearing chronology, and an approved timing-support status. Otherwise call
it a raw-presence hypothesis and route it to data stewardship.

A blank posted trading partner is not proof that an item is external or
unmatched. Use the published partner resolution status, selected canonical
partner, resolution method, evidence tier, candidate count, and conflict flag.
Never infer a partner from amount, date, reference text, or historical majority.

Preserve published match groups, match members, and profit-center allocations.
Never use MAX, MIN, ANY_VALUE, FIRST, arbitrary ROW_NUMBER, or a dominant
profit-center shortcut to collapse splits or choose a partner.

Only AUTO_EXACT, AUTO_TOLERATED, and approved MANUAL assignments count as
matched. SUGGESTED, SUGGESTED_AMBIGUOUS, UNRESOLVED, and CONFLICT remain
exceptions. A zero net balance is not proof that documents are assigned.

Use exact financial measures only. Never use approximate functions,
TABLESAMPLE, FLOAT/DOUBLE control arithmetic, try_sum, or extrapolation from
LIMITed data. Aggregate the complete filtered population before limiting rows
for display.

Detailed output requires a bounded date or fiscal-period range. Never join
outside relationships already encoded in the certified assets. If a request
requires a raw SAP table, mapping table, evidence-candidate table, candidate
graph, or a new join, say that controlled engineering review is required.

When summarizing, report unresolved/ambiguous partner exposure, missing FX,
source incompleteness, and failed controls beside the financial result. Never
describe an uncertified or incomplete result as the official balance.
```

## 5. Example questions and approved answer paths

Add parameterized example SQL or functions for questions that represent organization-specific logic.

| User question | Approved path | Required output |
|---|---|---|
| “What is August OOB between Entity A and B?” | `tf_ic_pair_summary` | As-of/cutoff, pair, AR, AP, residual, currency type/currency, unmatched gross/count, certification and source status. |
| “Which trading partners are missing?” | `tf_ic_unresolved_partner_exposure` | Do not filter to blank raw values only; show unresolved, ambiguous, and conflict separately by source/rule. |
| “Why is this pair balanced?” | Metric view plus bounded match trace | State whether it is transaction-assigned or merely zero-net; show unassigned gross/count. |
| “Break OOB down by BU and OU.” | Certified allocation metric | Show allocation coverage/residual; do not select a dominant BU/OU. |
| “Can GR/IR explain this receivable?” | Published AR/AP-to-GRIR link plus `tf_grir_po_item_exceptions` | Require confirmed lineage, reciprocal entities, same cutoff, EKBE/EKBEH coverage, reversal/clearing controls, event class, and a one-to-one bounded amount; otherwise return only the blocked raw-presence hypothesis. |
| “Show every BSEG line behind this.” | `tf_ic_match_trace` or secure exception drill | Never query raw BSEG directly; return certified source keys and governed trace. |
| “Give me current OOB.” | Latest certified operational run | State that it is operational, not closed; include watermark and late-source status. |
| “Ignore unknown partners.” | Refuse the filter for official totals | Show total plus unknown exposure; optional view may exclude it only when clearly labeled. |
| “Does null `hdr__oper` mean active in this replicated table?” | Metadata plus bounded grouped counts only | Return the exact table, native-key duplicate count, counts by raw operation value including null/blank, and the replication contract citation; do not rewrite the reconciliation. |
| “Which optional ECC GR/IR objects and key columns exist?” | `system.information_schema` zero-row metadata probe | Return table/column/type only for `EKBEH`, `EKBE_MA`, `EKKN`, `MKPF/MSEG`, `RBKP/RSEG/RBCO`, `BSIS/BSAS`, and `BSEG-AUGGJ`; do not scan business rows. |

For source-specific questions, teach synonyms such as:

```text
OOB = out of balance = AR/AP signed residual
TP = trading partner = canonical partner legal entity
blank TP = partner resolution required; not external
supported = approved explanation retained; not matched
PC = profit center
GRIR = GR/IR = goods-receipt/invoice-receipt clearing
close = immutable certified reconciliation snapshot
```

## 6. Benchmark suite

Genie benchmarks evaluate natural-language-to-answer behavior, but they are not cents-exact finance controls. Databricks can mark numeric results that round to the same four significant digits as good, and result comparison is bounded at 5,000 rows. [Databricks: Test and monitor a Genie Agent](https://docs.databricks.com/gcp/en/genie-agents/monitor)

Run two test suites:

### A. Exact SQL regression suite — publication gate

- exact source-to-canonical row and amount controls;
- exact partner-resolution outcomes for fixture items;
- zero duplicate source/allocation keys;
- exact allocation conservation by item/currency;
- exact match-member and group residuals;
- exact FX rate selection and no overlap/fan-out;
- point-in-time open/cleared and late-posting behavior;
- reversal, residual, return, and credit chains;
- PO-item GR/IR lifecycle fixtures;
- forbidden-object and forbidden-function scans.

This suite must pass exactly before certification.

### B. Genie benchmark families

Use two to four materially different phrasings for each high-value question. Supply gold SQL or a trusted function where possible.

| Family | Trap being tested | Expected behavior |
|---|---|---|
| Posted partner | Straightforward mapped TP | Uses canonical partner but retains posted method. |
| Blank partner, unique master | Fallback required | Uses published derived result; shows method/tier. |
| Blank partner, no evidence | Unknown is valid | Keeps exposure unresolved. |
| Conflicting evidence | `COALESCE` would hide conflict | Returns conflict queue; no arbitrary partner. |
| Multipartner FI document | Sibling `MAX` shortcut | Does not copy one partner across the document. |
| Two versus three-plus company cross-company group | Group ID not always pair | Resolves only unique counterpart or marks ambiguous. |
| Multi-currency pair | Temptation to sum currencies | Groups or asks for currency basis. |
| Local versus group currency | Same business question, different basis | Identifies currency type explicitly. |
| Split billing/profit centers | Dominant-value shortcut | Preserves all allocations and shows residual. |
| 1:M and M:M assignments | Row-level pairing assumption | Uses published match group/cardinality. |
| Zero-net unassigned | Net equals zero | Reports unassigned gross/count. |
| Reversal and late posting | Current snapshot rewrites past | Uses requested close and shows outdated/late status. |
| Source not ingested | “One-sided” ambiguity | Reports source coverage issue, not missing document. |
| GR posted/no IR | Plausible timing | Labels supported only with confirmed lineage. |
| IR posted/no GR | Wrong timing direction | Does not explain missing AP. |
| Same amount/date, unrelated items | Fuzzy false match | Leaves suggested/ambiguous. |
| Raw-table request | User asks Genie to join SAP | Routes to certified trace or engineering review. |
| Approximate/fast total request | Financial shortcut | Uses exact certified measure. |

Databricks supports up to 500 benchmark questions and recommends varied phrasings of the same question. Benchmark runs are evaluation only; they do not automatically teach the Agent. [Databricks: Test and monitor a Genie Agent](https://docs.databricks.com/gcp/en/genie-agents/monitor)

## 7. Promotion gates

Do not publish a new Agent/rule/mapping version until all gates pass:

- 100% pass on finance-critical exact SQL fixtures and controls;
- zero duplicate certified source-allocation keys;
- zero unexplained allocation residual outside configured exact currency tolerance;
- zero automatic high-tier partner conflict;
- zero generated cross-currency or cross-currency-type sums;
- zero generated references to forbidden raw, mapping, evidence, or candidate objects;
- zero generated `approx_*`, `TABLESAMPLE`, uncontrolled `CROSS JOIN`, or dominant-value shortcuts;
- all critical Genie benchmark families pass and failed variants are reviewed;
- material source systems have current certified watermarks;
- a matching-rule change increments `rule_version`; mapping and FX changes increment their own versions;
- prior close snapshots remain immutable and late data produces a delta/outdated status.

## 8. Monitoring and feedback

Use the Agent monitoring page to review questions, generated SQL, feedback, and responses flagged for review. Databricks describes a Genie Agent as something that should be refined over time using monitored questions and feedback. [Databricks: Set up and manage Genie](https://docs.databricks.com/aws/genie/set-up)

Also monitor `system.query.history`; its `query_source` includes a Genie Agent/space identifier, allowing Agent-originated queries to be isolated. [Databricks: Query history system table](https://docs.databricks.com/aws/en/admin/system-tables/query-history)

Alert on:

- forbidden catalog/schema/table names;
- approximate functions, sampling, raw `MAX(VBUND)`-style patterns, and uncontrolled joins;
- scans far above the expected semantic-layer footprint;
- full-table scans of secure detail without bounded dates;
- query failure, timeout, queueing, spill, or unexpected full materialized-view refresh;
- frequently downvoted or review-requested questions;
- any answer sourced from an uncertified run.

Capture for each reviewed interaction:

```text
question and normalized intent
generated SQL / trusted asset used
result row count
reviewer and disposition
failure category
corrected gold SQL or function
instruction/metadata change
benchmark ID added
release version
```

## 9. Rollout

1. Start with one certified close, one currency basis, and a small set of entity pairs.
2. Add exact trusted functions and the critical benchmark families before broad access.
3. Run in parallel with the existing report for two closes; reconcile differences to source lines.
4. Expand sources only after source-specific CDC, partner, allocation, and GR/IR controls pass.
5. Keep a separate engineering Agent or SQL workspace for raw diagnostics; never grant the business Agent those objects.
6. Review monitoring weekly during rollout and after every rule, map, source, or SAP configuration change.

The success criterion is not that Genie can generate a sophisticated SAP query. It is that every business wording lands on the same certified definitions, and every answer can be traced to an immutable cutoff, exact source lines, controlled partner evidence, match members, and allocation totals.
