# Databricks Genie handoff — AR/AP intercompany OOB pilot

Authoritative implementation:
[`sql/SAP_IC_reconciliation_v3_arap_only.sql`](../sql/SAP_IC_reconciliation_v3_arap_only.sql)

## Objective

Validate a tightly governed calculation of **posted customer/vendor
intercompany AR/AP out-of-balance** at a specified accounting cutoff.

The controlled measure is:

```text
AR/AP OOB = signed intercompany AR + signed intercompany AP
```

The certified grain is:

```text
as-of date
+ source system and SAP client
+ unordered legal-entity pair
+ document currency
```

Never add amounts across document currencies. Transaction matching explains the
balance but is not required to calculate the legal-entity-pair OOB.

## Hard scope boundary

This handoff covers only posted customer/vendor AR/AP and the controls already
implemented in the authoritative SQL.

**GR/IR, purchase-order history, goods movements, invoice-receipt analysis,
receipt accruals, and logistics root-cause investigation are out of scope.**

Genie must not query or propose `EKKO`, `EKPO`, `EKBE`, `EKBEH`, `EKKN`,
`EKBE_MA`, `MKPF`, `MSEG`, `MATDOC`, `RBKP`, `RSEG`, `RBCO`, or a substitute
procurement object. If a seller AR item has no buyer AP item, report the posted
AR/AP timing exception. Do not try to explain it with procurement data in this
project.

Do not:

- add another accounting population, source table, netting category, or
  reconciliation process;
- include manual-G/L amounts in the certified subledger result;
- rewrite or simplify the accounting SQL;
- create fuzzy joins or infer partners from text, names, dates, amounts, or
  historical frequency;
- hide unresolved, ambiguous, conflicting, or missing-partner records;
- use `MAX`, `MIN`, `FIRST`, `ANY_VALUE`, or arbitrary `ROW_NUMBER` to conceal
  cardinality problems;
- apply an arbitrary fiscal-year or posting-date lower bound to an as-of open
  population;
- run an enterprise-wide query before the bounded pilot passes.

If live metadata does not satisfy the existing contract, stop and report the
mismatch. Do not invent a table, column, key, filter, or accounting rule.

## Permitted inputs

The permitted SAP source objects are exactly:

```text
BSID, BSAD, BSIK, BSAK, BKPF, BSEG, T001, KNA1, LFA1
```

The only other permitted inputs are the three governed reference objects
already used by the SQL:

```text
qlk_c.c_ocs_sql.ocs_kairos_emea_prof_ctr
common.business_structures.bu_ou_div_hierarchy
ocs.pharos_silver.r_ecc_forex_table
```

`BSEG-EBELN` and `BSEG-EBELP` occur only inside exact FI-line payload controls.
Their presence does not authorize a purchasing join or a new reconciliation
scope.

## First message to Genie

Paste this instruction before asking any data question:

```text
Work only on the posted intercompany customer/vendor AR/AP OOB pilot defined in
sql/SAP_IC_reconciliation_v3_arap_only.sql. Do not add or query GR/IR,
purchase-order history, goods movements, invoice-receipt, receipt-accrual, or
other procurement sources. Do not rewrite the accounting logic.

For each answer, return the exact SQL you executed, catalog/schema/object names,
snapshot or watermark, row count, distinct native-key count, signed amount,
gross amount, exception count/gross, and query ID/profile link. State UNKNOWN
when evidence is unavailable. A prose-only answer is not sufficient.

Begin with metadata and zero-row schema checks. Do not run the full
reconciliation or an enterprise-wide scan.
```

## Minimum source-field contract

Preserve leading zeros by treating SAP identifiers as strings. Genie must
verify the exact loaded names, types, and nullability before execution.

| Object | Required fields |
|---|---|
| `BSID` | `MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT, AUGBL, ZUONR, SGTXT, KUNNR, VBUND, WAERS, WRBTR, DMBTR, SHKZG, hdr__oper` |
| `BSAD` | `MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT, AUGBL, ZUONR, SGTXT, KUNNR, VBUND, WAERS, WRBTR, DMBTR, SHKZG, hdr__oper` |
| `BSIK` | `MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT, AUGBL, ZUONR, SGTXT, LIFNR, VBUND, WAERS, WRBTR, DMBTR, SHKZG, hdr__oper` |
| `BSAK` | `MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT, AUGBL, ZUONR, SGTXT, LIFNR, VBUND, WAERS, WRBTR, DMBTR, SHKZG, hdr__oper` |
| `BKPF` | `MANDT, BUKRS, GJAHR, BELNR, BVORG, BLART, BKTXT, STBLG, BUDAT, WAERS, hdr__oper` |
| `BSEG` | `MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, KOART, SHKZG, WRBTR, DMBTR, VBUND, PRCTR, KOSTL, EBELN, EBELP, hdr__oper` |
| `T001` | `MANDT, BUKRS, RCOMP, BUTXT, LAND1, KTOPL, WAERS, hdr__oper` |
| `KNA1` | `MANDT, KUNNR, VBUND, hdr__oper` |
| `LFA1` | `MANDT, LIFNR, VBUND, hdr__oper` |

If replication renamed a field, return the verified source-to-target mapping
and type. A similar-looking name is not proof of equivalence.

## Bounded metadata request

Ask Genie:

```text
For the nine permitted SAP objects only, return their exact Unity Catalog
locations and the exact name, data type, nullability, and ordinal position of
the required fields. Use system.information_schema.columns. Do not read data,
use SELECT *, suggest substitute objects, or broaden scope.
```

Template:

```sql
SELECT
  table_catalog,
  table_schema,
  LOWER(table_name) AS table_name,
  column_name,
  data_type,
  is_nullable,
  ordinal_position
FROM system.information_schema.columns
WHERE table_catalog = '<catalog>'
  AND table_schema = '<schema>'
  AND LOWER(table_name) IN
      ('bsid','bsad','bsik','bsak','bkpf','bseg','t001','kna1','lfa1')
ORDER BY table_name, ordinal_position;
```

## CDC and snapshot contract

The SQL currently treats literal `D` as deleted and null/blank `hdr__oper` as
active. Compilation does not prove that convention.

Ask Genie to return, for each permitted object:

```sql
SELECT
  COALESCE(CAST(hdr__oper AS STRING), '<NULL>') AS raw_operation,
  COUNT(*) AS physical_rows
FROM <catalog>.<schema>.<object>
WHERE CAST(MANDT AS STRING) = '<client>'
GROUP BY COALESCE(CAST(hdr__oper AS STRING), '<NULL>')
ORDER BY raw_operation;
```

The evidence must identify:

- the owner of the replication contract;
- the meaning of every raw operation value;
- whether the objects are current-state, append-only history, or mixed;
- how multiple versions of one SAP key are ordered;
- actual ingestion, extraction-batch, sequence, snapshot, or watermark fields;
- whether all inputs can be reconstructed at one coherent source state;
- whether cleared-item history is retained for items cleared after the cutoff;
- late-arriving, replayed, archived, and physical-delete behavior.

Do not change the CDC predicate until the source owner confirms the contract.

## Pilot scope

Begin with:

```text
one source system
one SAP client
one company code
one Finance-approved customer reconciliation account
one Finance-approved vendor reconciliation account
one accounting cutoff
complete as-of open/cleared history for that scope
```

Do **not** impose a convenient one-month or current-year posting window. An old
invoice can still be open at the current cutoff.

The governed account matrix must have this grain:

```text
source_system_id
source_client
company_code
chart_of_accounts
match_side
gl_account
effective_from
effective_to
scope_rule_id
finance_approval_id
```

No wildcard company is permitted for certification. Confirm `BSEG-KOART='D'`
for customer items, `BSEG-KOART='K'` for vendor items, and exactly one
`T001-RCOMP`, `T001-KTOPL`, and `T001-WAERS` for the selected company.

## Native keys and cardinality

| Population | Required key |
|---|---|
| Customer/vendor item | `source system + MANDT + BUKRS + GJAHR + BELNR + BUZEI` |
| FI header | `source system + MANDT + BUKRS + GJAHR + BELNR` |
| Company | `source system + MANDT + BUKRS` |
| Customer master | `source system + MANDT + KUNNR` |
| Vendor master | `source system + MANDT + LIFNR` |

Every duplicate must be classified as an identical physical duplicate,
conflicting payload, valid open/cleared lifecycle representation, or
unexplained. Do not deduplicate an unexplained population.

After executing the SQL, return:

```sql
SELECT source_key_status,
       COUNT(*) AS native_key_count,
       SUM(physical_copy_count) AS physical_rows,
       CAST(SUM(physical_gross_amount_dc) AS DECIMAL(38,6)) AS physical_gross_dc
FROM ic_v3_source_key_control
GROUP BY source_key_status
ORDER BY source_key_status;

SELECT header_status, COUNT(*) AS header_key_count
FROM ic_v3_item_header_control
GROUP BY header_status
ORDER BY header_status;

SELECT bseg_line_status, COUNT(*) AS source_item_count
FROM ic_v3_item_bseg_line_control
GROUP BY bseg_line_status
ORDER BY bseg_line_status;
```

## Trading-partner evidence

Posted item `VBUND` is authoritative. Same-document, `BKPF-BVORG`, and current
customer/vendor-master evidence remain separately labelled diagnostics unless a
governed rule explicitly promotes them.

For blank posted `VBUND`, return the item key, side, currency, signed/gross
amount, every evidence method, distinct candidate count, disagreements,
diagnostic candidate if unique, and final resolution status.

Blank, ambiguous, conflicting, and diagnostic-only records must remain in the
population denominator and exception exposure. They cannot be discarded or
automatically promoted to make the match rate look better.

## Required financial controls

Use exact `DECIMAL`, never floating-point amounts, sampling, or extrapolation.

```sql
SELECT allocation_control_status,
       COUNT(*) AS source_item_count,
       CAST(SUM(ABS(allocation_residual_dc)) AS DECIMAL(38,6)) AS residual_dc,
       CAST(SUM(ABS(allocation_residual_lc)) AS DECIMAL(38,6)) AS residual_lc
FROM ic_v3_allocation_control
GROUP BY allocation_control_status
ORDER BY allocation_control_status;

SELECT *
FROM ic_v3_population_bridge
ORDER BY source_system_id, source_client, currency_bucket, population_bucket;

SELECT * FROM ic_v3_arap_population_control;

SELECT
  reconciliation_run_id,
  as_of_date,
  source_system_id,
  source_client,
  entity_lo,
  entity_hi,
  document_currency,
  ar_item_count,
  ap_item_count,
  ar_amount_dc,
  ap_amount_dc,
  arap_net_dc,
  gross_exposure_dc,
  unmatched_gross_dc,
  invalid_group_gross_dc,
  pair_status
FROM ic_v3_pair_currency_summary
ORDER BY entity_lo, entity_hi, document_currency;
```

The evidence packet must prove, separately by document currency:

```text
accepted item population
= resolved-pair population + explicit exception populations

source item amount = sum of its allocation rows
resolved item counts and amounts = pair-summary counts and amounts
AR amount + AP amount = pair OOB
```

A zero net does not prove completeness. Gross exposure, AR/AP side counts,
exception exposure, and population conservation must also pass.

## Execution sequence

1. Run metadata and zero-row checks only.
2. Obtain the CDC, retention, and coherent-snapshot contract.
3. Obtain Finance approval for the exact company/chart/account scope.
4. Capture independent source row counts and document-currency control totals.
5. Execute the authoritative AR/AP SQL unchanged in one development session.
6. Read `ic_v3_product_release_status` before any financial result.
7. Inspect all 30 embedded release-gate rows and their manifest controls. Do
   not run the mixed-scope assertion pack from the larger reference package.
8. Produce the key, partner, allocation, population, and pair evidence.
9. Tie to an independently produced SAP balance at the identical cutoff.
10. Review `EXPLAIN FORMATTED` and the executed query profile.
11. Expand only one controlled dimension after Finance signs off on the pilot.

## Immediate stop conditions

Stop and do not publish if:

- a required object or field is missing or guessed;
- SAP identifiers lost leading zeros;
- CDC/current-row or snapshot semantics are unproven;
- AR or AP source coverage is incomplete;
- company/account scope is wildcarded, ambiguous, or unapproved;
- a native key has unexplained duplicate or conflicting payloads;
- posting, clearing, header, amount, sign, or currency data is invalid;
- open and cleared indexes contradict one another;
- exact BKPF or BSEG lineage is absent;
- missing or disputed partner exposure is omitted;
- allocation or population conservation has a nonzero residual;
- currencies are combined;
- any required gate is missing, null, or failing;
- the SAP tie-out has an unexplained difference;
- the query profile shows an uncontrolled enterprise scan;
- Genie proposes changing the accounting logic or broadening scope.

A stopped pilot is a valid result. Return the failed evidence and responsible
owner; do not manufacture a passing answer.

## Required Genie response format

```text
Run ID:
As-of date and cutoff-exclusive date:
Source system and client:
Company and chart:
AR/AP accounts:
Document currencies present:
Snapshot ID or per-object watermarks:
Exact SQL executed:
Query ID/profile link:
Rows returned:
Distinct native-key count:
Signed amount by currency:
Gross amount by currency:
Exception count and gross by currency:
Release-gate status:
Assumptions:
Unresolved questions:
Decision: STOPPED | VALIDATION_ONLY | READY_FOR_FINANCE_TIE_OUT
```

Attach machine-readable results. Include zero counts explicitly and state
`UNKNOWN` when evidence is unavailable. Genie may inspect metadata, execute
bounded validation SQL, and summarize evidence. It may not rewrite or execute a
replacement accounting implementation.
