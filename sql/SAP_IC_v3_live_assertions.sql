-- SAP IC v3 live assertions
-- Dialect: Databricks / Spark SQL
-- Prerequisite: run SAP_IC_reconciliation_v3_sandbox.sql in the same session.
-- Every numbered violation query must return zero rows unless marked CONTROL
-- TOTAL or EXPECTED EXCEPTION. This file is read-only.

-- 1. Parameter boundary is an end-of-day snapshot.
SELECT '01_PARAMETER_BOUNDARY' AS assertion_name, *
FROM ic_v3_params
WHERE cutoff_exclusive<>DATE_ADD(as_of_date,1)
   OR source_client IS NULL
   OR reconciliation_run_id IS NULL
   OR rule_version IS NULL;

SELECT
  '01B_PARAMETER_CONTROL' AS assertion_name,
  parameter_row_count, invalid_cutoff_row_count,
  invalid_required_parameter_count, parameter_control_status
FROM ic_v3_parameter_control
WHERE parameter_control_status<>'PASS';

-- 2. Scope rules are unique. Duplicate rules would multiply source items.
SELECT
  '02_ACCOUNT_SCOPE_UNIQUE' AS assertion_name,
  source_system_id, source_client, company_code, source_family, gl_account,
  COUNT(*) AS rule_count
FROM ic_v3_account_scope
GROUP BY source_system_id, source_client, company_code, source_family, gl_account
HAVING COUNT(*)<>1;

SELECT
  '02B_GRIR_ACCOUNT_SCOPE_UNIQUE' AS assertion_name,
  source_system_id, source_client, company_code, gl_account,
  scope_row_count, scope_rule_count, scope_control_status
FROM ic_v3_grir_account_scope_control
WHERE scope_control_status<>'PASS';

SELECT
  '02C_AR_AP_SOURCE_FAMILY_COVERAGE' AS assertion_name,
  source_family, match_side, physical_row_count, source_family_status
FROM ic_v3_source_family_coverage_control
WHERE source_family_status<>'PRESENT';

SELECT
  '02D_GRIR_FI_SOURCE_POPULATION_PRESENT' AS assertion_name,
  COUNT(*) AS scoped_physical_row_count
FROM ic_v3_grir_line_physical
HAVING COUNT(*)=0;

-- EXPECTED EXCEPTION until the wildcard pilot rows are replaced.
SELECT
  '02E_ACCOUNT_SCOPE_COMPANY_EXPLICIT' AS assertion_name,
  source_system_id, source_client, company_code, source_family,
  match_side, gl_account, scope_rule_id
FROM ic_v3_account_scope
WHERE company_code='*';

-- 3. Every native source key has one financial payload after as-of selection.
SELECT
  '03_SOURCE_KEY_PAYLOAD_UNIQUE' AS assertion_name,
  source_item_id, physical_copy_count, distinct_payload_count,
  physical_source_count, asof_candidate_copy_count, physical_signed_amount_dc,
  physical_gross_amount_dc, source_key_status
FROM ic_v3_source_key_control
WHERE source_key_status<>'PASS'
  AND asof_candidate_copy_count>0;

SELECT '03B_NATIVE_ITEM_KEY_COMPLETE' AS assertion_name, *
FROM ic_v3_item_native_key_quarantine;

SELECT '03C_POSTING_DATE_VALID' AS assertion_name, *
FROM ic_v3_item_preasof_quarantine;

SELECT '03D_AMOUNT_CURRENCY_SIGN_VALID' AS assertion_name, *
FROM ic_v3_item_data_quality_exception;

SELECT '03E_SOURCE_INDEX_LIFECYCLE_CONSISTENT' AS assertion_name, *
FROM ic_v3_item_source_lifecycle_exception;

-- 4. The certified item fact retains every clean item exactly once.
WITH expected AS (
  SELECT COUNT(*) AS n,
         CAST(SUM(signed_amount_dc) AS DECIMAL(38,6)) AS signed_dc,
         CAST(SUM(ABS(signed_amount_dc)) AS DECIMAL(38,6)) AS gross_dc
  FROM ic_v3_item_base
), actual AS (
  SELECT COUNT(*) AS n,
         COUNT(DISTINCT source_item_id) AS distinct_n,
         CAST(SUM(signed_amount_dc) AS DECIMAL(38,6)) AS signed_dc,
         CAST(SUM(ABS(signed_amount_dc)) AS DECIMAL(38,6)) AS gross_dc
  FROM ic_v3_item_fact
)
SELECT
  '04_ITEM_FACT_CONSERVATION' AS assertion_name,
  e.n AS expected_rows, a.n AS actual_rows, a.distinct_n,
  e.signed_dc AS expected_signed_dc, a.signed_dc AS actual_signed_dc,
  e.gross_dc AS expected_gross_dc, a.gross_dc AS actual_gross_dc
FROM expected e CROSS JOIN actual a
WHERE e.n<>a.n OR a.n<>a.distinct_n
   OR e.signed_dc<>a.signed_dc OR e.gross_dc<>a.gross_dc;

SELECT '04B_OFFICIAL_POPULATION_CONSERVATION' AS assertion_name, *
FROM ic_v3_arap_population_control
WHERE population_control_status<>'PASS';

-- 5. Blank posted partners were not filtered before the evidence waterfall.
--    This query is an EXPECTED EXCEPTION summary, not a failure by itself.
SELECT
  '05_BLANK_POSTED_PARTNER_EXPOSURE' AS assertion_name,
  match_side, partner_resolution_status, document_currency,
  COUNT(*) AS item_count,
  CAST(SUM(signed_amount_dc) AS DECIMAL(38,6)) AS signed_dc,
  CAST(SUM(ABS(signed_amount_dc)) AS DECIMAL(38,6)) AS gross_dc
FROM ic_v3_item_fact
WHERE posted_partner_raw IS NULL
GROUP BY match_side, partner_resolution_status, document_currency
ORDER BY match_side, partner_resolution_status, document_currency;

-- EXPECTED EXCEPTION: sole backup candidates for blank/missing posted partners.
-- These rows are hypotheses and are never included in official AR/AP OOB.
SELECT
  '05B_DIAGNOSTIC_PARTNER_CANDIDATE_OOB' AS assertion_name,
  source_system_id, source_client,
  candidate_entity_lo, candidate_entity_hi, document_currency,
  candidate_item_count, candidate_ar_item_count, candidate_ap_item_count,
  candidate_ar_amount_dc, candidate_ap_amount_dc,
  candidate_arap_net_dc, candidate_gross_dc,
  candidate_pair_status, diagnostic_limit
FROM ic_v3_diagnostic_partner_candidate_pair_summary
ORDER BY candidate_gross_dc DESC, source_system_id, source_client,
         candidate_entity_lo, candidate_entity_hi, document_currency;

-- 6. Partner resolution has exactly one exhaustive result per item.
SELECT
  '06_PARTNER_RESOLUTION_CARDINALITY' AS assertion_name,
  i.source_item_id,
  COUNT(r.source_item_id) AS resolution_count
FROM ic_v3_item_fact i
LEFT JOIN ic_v3_partner_resolution r
  ON r.source_item_id=i.source_item_id
GROUP BY i.source_item_id
HAVING COUNT(r.source_item_id)<>1;

SELECT
  '06B_PARTNER_STATUS_DOMAIN' AS assertion_name,
  partner_resolution_status,
  COUNT(*) AS item_count
FROM ic_v3_partner_resolution
WHERE COALESCE(partner_resolution_status,'PARTNER_RESOLUTION_STATUS_MISSING')
      NOT IN (
  'POSTED','DERIVED_UNIQUE','DERIVED_UNIQUE_DIAGNOSTIC',
  'AMBIGUOUS','CONFLICT','CONFLICT_SELF','UNRESOLVED'
)
GROUP BY partner_resolution_status;

-- 7. A match-eligible partner is populated and never self-referential.
SELECT
  '07_PARTNER_MATCH_ELIGIBILITY' AS assertion_name,
  i.source_item_id, i.owner_entity_id, i.resolved_partner_entity_id,
  i.partner_resolution_status, i.partner_match_eligible
FROM ic_v3_item_fact i
WHERE i.partner_match_eligible IS NULL
   OR (i.partner_match_eligible AND i.resolved_partner_entity_id IS NULL)
   OR (i.partner_match_eligible AND i.owner_entity_id=i.resolved_partner_entity_id)
   OR (i.partner_match_eligible
       AND COALESCE(i.partner_resolution_status,'PARTNER_RESOLUTION_STATUS_MISSING')
             NOT IN ('POSTED','DERIVED_UNIQUE'));

-- 8. Allocation conserves document and local currency for every item.
SELECT
  '08_ALLOCATION_CONSERVATION' AS assertion_name,
  source_item_id, allocation_row_count, distinct_allocation_id_count,
  source_amount_dc, allocated_amount_dc, allocation_residual_dc,
  source_amount_lc, allocated_amount_lc, allocation_residual_lc,
  allocation_control_status
FROM ic_v3_allocation_control
WHERE COALESCE(allocation_control_status,'ALLOCATION_CONTROL_STATUS_MISSING')<>'PASS'
   OR allocation_residual_dc IS NULL
   OR allocation_residual_lc IS NULL
   OR allocation_residual_dc<>CAST(0 AS DECIMAL(38,6))
   OR allocation_residual_lc<>CAST(0 AS DECIMAL(38,6));

-- 9. Mapping ambiguity remains visible and cannot duplicate allocation value.
SELECT
  '09_PROFIT_CENTER_MAP_AMBIGUITY' AS assertion_name,
  company_code, profit_center, mapping_row_count, ou_count,
  profit_center_map_status
FROM ic_v3_profit_center_map_control
WHERE ou_count>1;

SELECT
  '09B_OU_BU_MAP_AMBIGUITY' AS assertion_name,
  operating_unit, hierarchy_row_count, bu_count, ou_bu_map_status
FROM ic_v3_ou_bu_map_control
WHERE bu_count>1;

-- EXPECTED EXCEPTION: these documents cannot use offset-based splitting; they
-- may still use a unique profit center on the exact FI line.
SELECT
  '09C_UNSAFE_OFFSET_DOCUMENT_STRUCTURE' AS assertion_name,
  source_item_id, document_physical_line_count,
  target_line_physical_count, subledger_line_physical_count,
  other_subledger_line_count, unsupported_offset_line_count,
  invalid_line_key_count,
  document_structure_status
FROM ic_v3_offset_document_control
WHERE document_structure_status<>'SINGLE_SUBLEDGER_TARGET';

-- 10. Each eligible source item has exactly one selected membership.
SELECT
  '10_MATCH_MEMBERSHIP_CARDINALITY' AS assertion_name,
  source_item_id, membership_count,
  invalid_match_status_count, invalid_match_rule_count,
  membership_control_status
FROM ic_v3_match_membership_control
WHERE membership_control_status<>'PASS';

-- 11. The sandbox has no certified automatic transaction-reference rule.
SELECT
  '11_NO_UNGOVERNED_CONFIRMED_MATCH' AS assertion_name,
  match_group_id, match_rule_id, member_count, ar_count, ap_count,
  ar_total_dc, ap_total_dc, residual_dc, group_status
FROM ic_v3_match_group
WHERE group_status LIKE 'CONFIRMED%'
   OR group_status LIKE 'APPROVED%';

-- 12. Zero-net pairs with unassigned gross are explicitly risky, not balanced.
SELECT
  '12_ZERO_NET_UNASSIGNED_NOT_BALANCED' AS assertion_name,
  entity_lo, entity_hi, document_currency,
  arap_net_dc, gross_exposure_dc, confirmed_gross_dc,
  suggested_gross_dc, unmatched_gross_dc, pair_status
FROM ic_v3_pair_currency_summary
WHERE arap_net_dc=CAST(0 AS DECIMAL(38,6))
  AND confirmed_gross_dc<gross_exposure_dc
  AND pair_status<>'ZERO_NET_UNASSIGNED_RISK';

-- 13. Pair summary has one row at its published grain.
SELECT
  '13_PAIR_SUMMARY_GRAIN' AS assertion_name,
  reconciliation_run_id, as_of_date, cutoff_exclusive,
  entity_lo, entity_hi, document_currency,
  COUNT(*) AS row_count
FROM ic_v3_pair_currency_summary
GROUP BY reconciliation_run_id, as_of_date, cutoff_exclusive,
         entity_lo, entity_hi, document_currency
HAVING COUNT(*)<>1;

-- 14. Reporting-currency totals are complete only with one approved rate/item.
SELECT
  '14_FX_STATUS_CONSISTENCY' AS assertion_name,
  f.source_item_id, f.document_currency, f.reporting_currency,
  f.fx_status, f.approved_direct_multiplier, f.signed_amount_reporting
FROM ic_v3_item_fx f
WHERE f.fx_status IS NULL
   OR (f.fx_status IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
       AND f.signed_amount_reporting IS NULL)
   OR (COALESCE(f.fx_status,'MISSING_FX_STATUS')
         NOT IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
       AND f.signed_amount_reporting IS NOT NULL);

SELECT
  '14B_INCOMPLETE_FX_NOT_CERTIFIED' AS assertion_name,
  entity_lo, entity_hi, reporting_currency,
  unresolved_fx_item_count, unresolved_fx_gross_dc,
  partial_arap_net_reporting, reporting_total_status
FROM ic_v3_pair_reporting_summary
WHERE unresolved_fx_item_count>0
  AND reporting_total_status<>'INCOMPLETE_FX_DO_NOT_CERTIFY_TOTAL';

SELECT
  '14C_FX_APPROVAL_DOMAIN' AS assertion_name,
  fx_multiplier_contract_approved
FROM ic_v3_params
WHERE fx_multiplier_contract_approved IS NULL;

-- 15. GR/IR FI line identity and PO-history event identity are unique.
SELECT
  '15_GRIR_FI_LINE_UNIQUE' AS assertion_name,
  grir_fi_line_id, physical_row_count, payload_count, line_control_status
FROM ic_v3_grir_line_control
WHERE line_control_status<>'PASS';

SELECT
  '15B_GRIR_EVENT_KEY_VALID_AND_UNIQUE' AS assertion_name,
  source_system_id, source_client, company_code,
  purchase_order, purchase_order_item, event_id,
  physical_row_count, payload_count, invalid_native_key_count,
  invalid_posting_date_count, invalid_event_amount_count,
  invalid_event_quantity_count, event_key_status
FROM ic_v3_grir_event_key_control
WHERE event_key_status<>'PASS';

SELECT '15C_GRIR_FI_POPULATION_CONSERVATION' AS assertion_name, *
FROM ic_v3_grir_fi_conservation_control
WHERE conservation_status<>'PASS';

SELECT '15D_GRIR_EVENT_POPULATION_CONSERVATION' AS assertion_name, *
FROM ic_v3_grir_event_conservation_control
WHERE COALESCE(conservation_status,'CONSERVATION_STATUS_MISSING')<>'PASS';

SELECT
  '15E_GRIR_HEADER_OR_DATE_VALID' AS assertion_name,
  grir_fi_line_id, source_system_id, source_client, company_code,
  fiscal_year, accounting_document, line_item_number,
  header_status, posting_date_status, clearing_date_status,
  clearing_document, clearing_fiscal_year,
  clearing_reference_status, clearing_control_status,
  asof_population_status, signed_amount_dc
FROM ic_v3_grir_fi_candidate
WHERE COALESCE(header_status,'HEADER_STATUS_MISSING')<>'HEADER_RESOLVED'
   OR COALESCE(posting_date_status,'POSTING_DATE_STATUS_MISSING')<>'VALID'
   OR COALESCE(clearing_control_status,'MISSING_CLEARING_CONTROL') NOT IN (
        'NOT_CLEARED','CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED');

-- 16. Multiple account assignments never receive a replicated FI amount.
--     They are intentionally marked unallocated at assignment level.
SELECT
  '16_GRIR_MULTI_ASSIGNMENT_FAIL_CLOSED' AS assertion_name,
  grir_po_item_id, source_system_id, source_client, company_code,
  purchase_order, purchase_order_item, account_assignment_count,
  assignment_link_status, open_fi_amount_lc
FROM ic_v3_grir_po_item_lifecycle
WHERE account_assignment_count>1
  AND COALESCE(assignment_link_status,'ASSIGNMENT_LINK_STATUS_MISSING')
      <>'MULTIPLE_ASSIGNMENTS_FI_AMOUNT_UNALLOCATED';

-- 17. GR/IR timing support is hard-disabled in the sandbox.
SELECT
  '17_GRIR_SUPPORT_MUST_REMAIN_DISABLED' AS assertion_name,
  arap_source_item_id, grir_po_item_id, explanation_status,
  causal_sign_status, lifecycle_exception_type,
  grir_candidates_for_arap, arap_candidates_for_grir,
  candidate_physical_row_count, pair_physical_control_status,
  automation_eligibility_status, buyer_ap_presence_status,
  supported_amount_dc, diagnostic_amount_status,
  diagnostic_bounded_overlap_dc, diagnostic_uncovered_ar_dc,
  arap_amount_dc, grir_open_amount_dc
FROM ic_v3_arap_grir_link
WHERE supported_amount_dc IS NOT NULL
   OR COALESCE(automation_eligibility_status,'AUTOMATION_STATUS_MISSING')
        <>'BLOCKED_CONTRACT_INCOMPLETE'
   OR COALESCE(pair_physical_control_status,'PAIR_CONTROL_STATUS_MISSING')<>'PASS'
   OR explanation_status LIKE '%TIMING_SUPPORTED%'
   OR (diagnostic_amount_status='ONE_TO_ONE_PAIRWISE_DIAGNOSTIC_NOT_CAUSAL_SUPPORT'
       AND (diagnostic_bounded_overlap_dc IS NULL
            OR diagnostic_uncovered_ar_dc IS NULL))
   OR (COALESCE(diagnostic_amount_status,'DIAGNOSTIC_AMOUNT_STATUS_MISSING')
         <>'ONE_TO_ONE_PAIRWISE_DIAGNOSTIC_NOT_CAUSAL_SUPPORT'
       AND (diagnostic_bounded_overlap_dc IS NOT NULL
            OR diagnostic_uncovered_ar_dc IS NOT NULL));

SELECT
  '17B_GRIR_LINK_PAIR_GRAIN_UNIQUE' AS assertion_name,
  arap_source_item_id, grir_po_item_id, COUNT(*) AS row_count
FROM ic_v3_arap_grir_link
GROUP BY arap_source_item_id, grir_po_item_id
HAVING COUNT(*)<>1;

-- 18. CONTROL TOTAL: exact AR/AP source tie-out grain for SAP/Finance comparison.
SELECT
  '18_ARAP_CONTROL_TOTAL' AS control_name,
  reconciliation_run_id, as_of_date, source_system_id, source_client,
  company_code, gl_account, match_side, document_currency,
  COUNT(*) AS item_count,
  CAST(SUM(signed_amount_dc) AS DECIMAL(38,6)) AS signed_amount_dc,
  CAST(SUM(ABS(signed_amount_dc)) AS DECIMAL(38,6)) AS gross_amount_dc,
  CAST(SUM(signed_amount_lc) AS DECIMAL(38,6)) AS signed_amount_lc
FROM ic_v3_item_fact
GROUP BY reconciliation_run_id, as_of_date, source_system_id, source_client,
         company_code, gl_account, match_side, document_currency
ORDER BY source_system_id, source_client, company_code,
         gl_account, match_side, document_currency;

-- 19. CONTROL TOTAL: FI GR/IR open balance. Tie this independently to SAP.
SELECT
  '19_GRIR_FI_CONTROL_TOTAL' AS control_name,
  reconciliation_run_id, as_of_date, source_system_id, source_client,
  company_code, grir_account, document_currency,
  COUNT(*) AS fi_line_count,
  CAST(SUM(signed_amount_dc) AS DECIMAL(38,6)) AS signed_amount_dc,
  CAST(SUM(ABS(signed_amount_dc)) AS DECIMAL(38,6)) AS gross_amount_dc,
  CAST(SUM(signed_amount_lc) AS DECIMAL(38,6)) AS signed_amount_lc
FROM ic_v3_grir_fi_open_line
GROUP BY reconciliation_run_id, as_of_date, source_system_id, source_client,
         company_code, grir_account, document_currency
ORDER BY source_system_id, source_client, company_code,
         grir_account, document_currency;

-- 20. Final component and product release status.
SELECT
  '20A_RELEASE_GATE_MANIFEST_COMPLETE' AS assertion_name,
  gate_scope, gate_name, expected_gate, expected_gate_row_count,
  actual_gate_row_count,
  manifest_status, effective_gate_status
FROM ic_v3_release_gate_manifest_control
WHERE COALESCE(manifest_status,'MISSING_MANIFEST_STATUS')<>'EXPECTED_GATE_PRESENT'
   OR effective_gate_status IS NULL;

SELECT
  '20B_PRODUCT_SCOPE_MANIFEST_UNIQUE' AS assertion_name,
  product_name, required_gate_scope,
  scope_mapping_row_count, scope_mapping_status
FROM ic_v3_product_scope_control
WHERE COALESCE(scope_mapping_status,'MISSING_SCOPE_MAPPING_STATUS')<>'PASS';

SELECT
  s.gate_scope, s.failed_gate_count, s.warning_gate_count,
  s.manifest_exception_count, s.release_status
FROM ic_v3_release_status s
ORDER BY s.gate_scope;

SELECT
  p.product_name, p.expected_scope_count, p.manifest_scope_count,
  p.duplicate_scope_mapping_count,
  p.required_gate_count, p.matched_gate_count,
  p.missing_scope_or_gate_count, p.failed_gate_count, p.warning_gate_count,
  p.product_release_status
FROM ic_v3_product_release_status p
ORDER BY p.product_name;

-- 21. Currency keys are canonical at ingestion, before grouping or FX lookup.
SELECT
  '21_CURRENCY_CANONICALIZATION' AS assertion_name,
  source_object, native_id, currency
FROM (
  SELECT 'ARAP_ITEM' AS source_object, source_item_id AS native_id,
         document_currency AS currency
  FROM ic_v3_item_fact
  UNION ALL
  SELECT 'GRIR_FI_LINE', grir_fi_line_id, document_currency
  FROM ic_v3_grir_fi_open_line
  UNION ALL
  SELECT 'GRIR_EKBE_EVENT', event_id, event_currency
  FROM ic_v3_grir_po_history_event
) x
WHERE currency IS NOT NULL
  AND currency<>NULLIF(UPPER(TRIM(currency)),'');

-- 22. EXPECTED EXCEPTION: exact BSEG verification failures prevent management
--     allocation but remain available for root-cause review.
SELECT
  '22_BSEG_IDENTITY_OR_AMOUNT_EXCEPTION' AS assertion_name,
  source_item_id, bseg_physical_count, bseg_payload_count,
  sole_bseg_gl_account, sole_account_type, sole_bseg_debit_credit_code,
  sole_bseg_signed_amount_dc, sole_bseg_signed_amount_lc, bseg_line_status
FROM ic_v3_item_bseg_line_control
WHERE bseg_line_status<>'BSEG_LINE_RESOLVED';

-- 23. EXPECTED EXCEPTION: malformed/negative offset rows are retained and
--     fail closed; they must never disappear through an ingestion predicate.
SELECT
  '23_OFFSET_KEY_PAYLOAD_OR_SIGN_EXCEPTION' AS assertion_name,
  source_item_id, offset_line_id, physical_row_count, payload_count,
  invalid_native_key_count, invalid_raw_amount_count, offset_line_status
FROM ic_v3_offset_line_control
WHERE offset_line_status<>'PASS';

-- 24. Match-status gross buckets partition the pair exposure exactly. Invalid
--     one-sided/nonreciprocal groups cannot be labeled suggested gross.
SELECT
  '24_PAIR_GROSS_STATUS_PARTITION' AS assertion_name,
  entity_lo, entity_hi, document_currency,
  gross_exposure_dc, confirmed_gross_dc, suggested_gross_dc,
  unmatched_gross_dc, invalid_group_gross_dc, pair_status
FROM ic_v3_pair_currency_summary
WHERE gross_exposure_dc<>
      confirmed_gross_dc+suggested_gross_dc+unmatched_gross_dc+invalid_group_gross_dc
   OR (invalid_group_gross_dc>CAST(0 AS DECIMAL(38,6))
       AND pair_status<>'INVALID_MATCH_GROUP_EVIDENCE_EXPOSED');

-- 25. EXPECTED EXCEPTION: PO-item EKBE facts repeat when the lifecycle has
--     multiple FI account/currency slices. Aggregate the canonical
--     ic_v3_grir_po_event_summary instead of summing these lifecycle columns.
SELECT
  '25_GRIR_EVENT_MEASURES_NONADDITIVE' AS assertion_name,
  grir_po_item_id, source_system_id, source_client, company_code,
  purchase_order, purchase_order_item, po_item_fi_slice_count,
  event_measure_additivity_status
FROM ic_v3_grir_po_item_lifecycle
WHERE COALESCE(event_measure_additivity_status,'EVENT_ADDITIVITY_STATUS_MISSING')
      <>'ADDITIVE_AT_THIS_GRAIN';

-- 26. EXPECTED EXCEPTION: EKBE-ZEKKN cannot certify assignment completeness
--     without EKBE_MA/EKKN (or a released equivalent) and allocation controls.
SELECT
  '26_GRIR_ASSIGNMENT_BASIS_INCOMPLETE' AS assertion_name,
  grir_po_item_id, purchase_order, purchase_order_item,
  assignment_basis_status, assignment_link_status,
  account_assignment_count, null_assignment_event_count
FROM ic_v3_grir_po_item_lifecycle
WHERE COALESCE(assignment_basis_status,'ASSIGNMENT_BASIS_STATUS_MISSING')
        <>'ASSIGNMENT_LEVEL_HISTORY_INGESTED'
   OR COALESCE(assignment_link_status,'ASSIGNMENT_LINK_STATUS_MISSING')
        <>'PO_ITEM_UNIQUE_ASSIGNMENT';

-- 27. GR/IR FI raw SAP amounts obey the nonnegative-WRBTR/DMBTR contract.
SELECT
  '27_GRIR_RAW_AMOUNT_SIGN_VALID' AS assertion_name,
  grir_fi_line_id, source_system_id, source_client,
  company_code, fiscal_year, accounting_document, line_item_number,
  debit_credit_code, raw_amount_dc, raw_amount_lc, raw_amount_status
FROM ic_v3_grir_fi_open_line
WHERE COALESCE(raw_amount_status,'RAW_AMOUNT_STATUS_MISSING')
        <>'NONNEGATIVE_RAW_AMOUNT'
   OR signed_amount_dc IS NULL OR signed_amount_lc IS NULL;

-- 28. GR/IR workqueue may expose raw-presence hypotheses, but it cannot route
--     business follow-up while archive/reversal/clearing controls are missing.
SELECT
  '28_GRIR_WORKQUEUE_ROUTING_FAIL_CLOSED' AS assertion_name,
  grir_po_item_id, history_basis_status, reversal_status,
  clearing_control_exception_line_count, raw_presence_hypothesis,
  routing_safety_status, recommended_owner_queue, recommended_next_check
FROM ic_v3_grir_workqueue
WHERE (clearing_control_exception_line_count IS NULL
        OR clearing_control_exception_line_count>0
        OR COALESCE(po_owner_status,'PO_OWNER_STATUS_MISSING')
             <>'CONFIRMED_PO_OWNER'
        OR COALESCE(event_control_status,'EVENT_CONTROL_STATUS_MISSING')
             <>'PRESENCE_DIAGNOSTIC_REVERSAL_MAP_INCOMPLETE'
        OR COALESCE(history_basis_status,'HISTORY_BASIS_STATUS_MISSING')
             <>'EKBE_AND_EKBEH_COVERAGE_CERTIFIED'
        OR COALESCE(reversal_status,'REVERSAL_STATUS_MISSING')
             <>'REVERSAL_LINEAGE_COMPLETE'
        OR COALESCE(assignment_basis_status,'ASSIGNMENT_BASIS_STATUS_MISSING')
             <>'ASSIGNMENT_LEVEL_HISTORY_INGESTED'
        OR COALESCE(assignment_link_status,'ASSIGNMENT_LINK_STATUS_MISSING')
             <>'PO_ITEM_UNIQUE_ASSIGNMENT'
        OR raw_presence_hypothesis IS NULL)
  AND (routing_safety_status='ELIGIBLE_FOR_BUSINESS_ROUTING'
       OR recommended_owner_queue IN (
            'SUPPLIER_INVOICE_FOLLOWUP',
            'RECEIPT_OR_SERVICE_ENTRY_REVIEW',
            'GRIR_CLEARING_OR_VARIANCE_REVIEW'));

-- 29. Parameter strings in this sandbox are descriptive only. No production
--     readiness gate may turn green without an immutable evidence registry.
SELECT
  '29_NO_SELF_ATTESTED_PRODUCTION_READINESS' AS assertion_name,
  gate_name, gate_status, violating_rows, violating_gross_dc, gate_detail
FROM ic_v3_release_gate
WHERE gate_scope='PRODUCTION_READINESS' AND gate_status='PASS';

-- EXPECTED EXCEPTION until EKBEH and reversal mappings are implemented.
SELECT
  '30_GRIR_HISTORY_AND_REVERSAL_BASIS_INCOMPLETE' AS assertion_name,
  grir_po_item_id, purchase_order, purchase_order_item,
  history_basis_status, reversal_status, raw_presence_hypothesis
FROM ic_v3_grir_workqueue
WHERE COALESCE(history_basis_status,'HISTORY_BASIS_STATUS_MISSING')
        <>'EKBE_AND_EKBEH_COVERAGE_CERTIFIED'
   OR COALESCE(reversal_status,'REVERSAL_STATUS_MISSING')
        <>'REVERSAL_LINEAGE_COMPLETE';
