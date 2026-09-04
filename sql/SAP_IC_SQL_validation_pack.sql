-- SAP IC reconciliation validation pack
-- Dialect: Databricks / Spark SQL
-- Run each numbered statement separately.
-- This pack is diagnostic: it does not modify data.
-- Replace client 010, account lists, and the example as-of date with governed values.

-- ============================================================================
-- 1. Prove what the current AR population actually contains.
--    Any HKONT other than the governed IC AR set proves that hardcoding
--    gl_account='10250000' mislabels records.
-- ============================================================================
WITH ar_index AS (
  SELECT 'BSID' AS source_table,
         MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, WAERS, SHKZG, WRBTR
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE MANDT = '010'
    AND TRIM(COALESCE(VBUND, '')) <> ''
    AND UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL

  SELECT 'BSAD',
         MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, WAERS, SHKZG, WRBTR
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE MANDT = '010'
    AND TRIM(COALESCE(VBUND, '')) <> ''
    AND UPPER(COALESCE(hdr__oper, '')) <> 'D'
)
SELECT source_table,
       HKONT,
       WAERS,
       COUNT(*) AS physical_rows,
       COUNT(DISTINCT NAMED_STRUCT(
         'mandt', MANDT, 'bukrs', BUKRS, 'gjahr', GJAHR,
         'belnr', BELNR, 'buzei', BUZEI
       )) AS distinct_fi_items,
       SUM(CASE
             WHEN SHKZG = 'S' THEN WRBTR
             WHEN SHKZG = 'H' THEN -WRBTR
           END) AS signed_document_amount
FROM ar_index
GROUP BY source_table, HKONT, WAERS
ORDER BY source_table, HKONT, WAERS;


-- ============================================================================
-- 2. Test native-key uniqueness after the current delete filter.
--    Nonzero duplicate_rows means hdr__oper filtering alone has not resolved
--    source state, or the assumed key is incomplete.
-- ============================================================================
WITH source_rows AS (
  SELECT 'BSID' AS table_name, MANDT, BUKRS, GJAHR, BELNR, BUZEI
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL
  SELECT 'BSAD', MANDT, BUKRS, GJAHR, BELNR, BUZEI
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL
  SELECT 'BSIK', MANDT, BUKRS, GJAHR, BELNR, BUZEI
  FROM qlk_c.c_ocs_ecc_old.bsik
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL
  SELECT 'BSAK', MANDT, BUKRS, GJAHR, BELNR, BUZEI
  FROM qlk_c.c_ocs_ecc_old.bsak
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL
  SELECT 'BSEG', MANDT, BUKRS, GJAHR, BELNR, BUZEI
  FROM qlk_c.c_ocs_ecc_old.bseg
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
)
SELECT table_name,
       COUNT(*) AS physical_rows,
       COUNT(DISTINCT NAMED_STRUCT(
         'mandt', MANDT, 'bukrs', BUKRS, 'gjahr', GJAHR,
         'belnr', BELNR, 'buzei', BUZEI
       )) AS distinct_native_keys,
       COUNT(*) - COUNT(DISTINCT NAMED_STRUCT(
         'mandt', MANDT, 'bukrs', BUKRS, 'gjahr', GJAHR,
         'belnr', BELNR, 'buzei', BUZEI
       )) AS duplicate_rows
FROM source_rows
GROUP BY table_name
ORDER BY table_name;


-- ============================================================================
-- 3. Quantify the AR document-level anti-join defect.
--    wrong_suppression_rows are currently open BSID items for which another
--    line in the same document is in BSAD, but that exact BUZEI is not.
-- ============================================================================
WITH open_items AS (
  SELECT MANDT, BUKRS, GJAHR, BELNR, BUZEI
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE MANDT = '010'
    AND TRIM(COALESCE(VBUND, '')) <> ''
    AND UPPER(COALESCE(hdr__oper, '')) <> 'D'
),
cleared_docs AS (
  SELECT DISTINCT MANDT, BUKRS, GJAHR, BELNR
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE MANDT = '010'
    AND TRIM(COALESCE(VBUND, '')) <> ''
    AND UPPER(COALESCE(hdr__oper, '')) <> 'D'
),
cleared_items AS (
  SELECT DISTINCT MANDT, BUKRS, GJAHR, BELNR, BUZEI
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE MANDT = '010'
    AND TRIM(COALESCE(VBUND, '')) <> ''
    AND UPPER(COALESCE(hdr__oper, '')) <> 'D'
)
SELECT COUNT(*) AS current_open_rows,
       SUM(CASE WHEN cd.BELNR IS NOT NULL THEN 1 ELSE 0 END)
         AS rows_suppressed_by_current_document_antijoin,
       SUM(CASE WHEN cd.BELNR IS NOT NULL AND ci.BUZEI IS NULL THEN 1 ELSE 0 END)
         AS wrong_suppression_rows,
       SUM(CASE WHEN ci.BUZEI IS NOT NULL THEN 1 ELSE 0 END)
         AS exact_open_cleared_key_overlap_rows
FROM open_items o
LEFT JOIN cleared_docs cd
  ON cd.MANDT = o.MANDT
 AND cd.BUKRS = o.BUKRS
 AND cd.GJAHR = o.GJAHR
 AND cd.BELNR = o.BELNR
LEFT JOIN cleared_items ci
  ON ci.MANDT = o.MANDT
 AND ci.BUKRS = o.BUKRS
 AND ci.GJAHR = o.GJAHR
 AND ci.BELNR = o.BELNR
 AND ci.BUZEI = o.BUZEI;


-- ============================================================================
-- 4A. Show valid one-company-to-many-company-code mappings.
--     These must not be relabeled as foreign/one-sided merely because BUKRS is
--     not unique for one T001-RCOMP value.
-- ============================================================================
SELECT MANDT,
       TRIM(RCOMP) AS company_id,
       COUNT(DISTINCT TRIM(BUKRS)) AS company_code_count,
       SORT_ARRAY(COLLECT_SET(TRIM(BUKRS))) AS company_codes
FROM qlk_c.c_ocs_ecc_old.t001
WHERE MANDT = '010'
  AND TRIM(COALESCE(RCOMP, '')) <> ''
  AND UPPER(COALESCE(hdr__oper, '')) <> 'D'
GROUP BY MANDT, TRIM(RCOMP)
HAVING COUNT(DISTINCT TRIM(BUKRS)) > 1
ORDER BY company_code_count DESC, company_id;


-- ============================================================================
-- 4B. Find ambiguous profit-center and OU mappings.
-- ============================================================================
SELECT 'PROFIT_CENTER_TO_OU' AS issue_type,
       CAST(CompCode AS STRING) AS scope_1,
       CAST(Prof_ctr AS STRING) AS scope_2,
       COUNT(*) AS physical_rows,
       COUNT(DISTINCT OU) AS target_count,
       SORT_ARRAY(COLLECT_SET(CAST(OU AS STRING))) AS targets
FROM qlk_c.c_ocs_sql.ocs_kairos_emea_prof_ctr
GROUP BY CompCode, Prof_ctr
HAVING COUNT(*) > 1 OR COUNT(DISTINCT OU) > 1

UNION ALL

SELECT 'OU_TO_BU',
       CAST(OU AS STRING),
       NULL,
       COUNT(*),
       COUNT(DISTINCT LPAD(BU, 6, '0')),
       SORT_ARRAY(COLLECT_SET(LPAD(BU, 6, '0')))
FROM common.business_structures.bu_ou_div_hierarchy
WHERE TRIM(COALESCE(BU, '')) <> ''
  AND TRIM(COALESCE(OU, '')) <> ''
  AND OU <> '1999'
GROUP BY OU
HAVING COUNT(*) > 1 OR COUNT(DISTINCT LPAD(BU, 6, '0')) > 1;


-- ============================================================================
-- 5. Compare the standard FI-to-billing bridge with the unsafe BELNR=VBELN
--    assumption. Review rows with unsafe-only or multiple standard links.
-- ============================================================================
WITH ar_items AS (
  SELECT MANDT, BUKRS, GJAHR, BELNR, BUZEI
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE MANDT = '010'
    AND TRIM(COALESCE(VBUND, '')) <> ''
    AND UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL

  SELECT MANDT, BUKRS, GJAHR, BELNR, BUZEI
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE MANDT = '010'
    AND TRIM(COALESCE(VBUND, '')) <> ''
    AND UPPER(COALESCE(hdr__oper, '')) <> 'D'
),
item_links AS (
  SELECT a.MANDT, a.BUKRS, a.GJAHR, a.BELNR, a.BUZEI,
         COUNT(DISTINCT vbrk.VBELN) AS standard_billing_docs,
         COUNT(DISTINCT unsafe_vbrp.VBELN) AS unsafe_number_collisions
  FROM ar_items a
  LEFT JOIN qlk_c.c_ocs_ecc_old.vbrk vbrk
    ON vbrk.MANDT = a.MANDT
   AND vbrk.BUKRS = a.BUKRS
   AND vbrk.GJAHR = a.GJAHR
   AND vbrk.BELNR = a.BELNR
   AND UPPER(COALESCE(vbrk.hdr__oper, '')) <> 'D'
  LEFT JOIN qlk_c.c_ocs_ecc_old.vbrp unsafe_vbrp
    ON unsafe_vbrp.MANDT = a.MANDT
   AND unsafe_vbrp.VBELN = a.BELNR
   AND UPPER(COALESCE(unsafe_vbrp.hdr__oper, '')) <> 'D'
  GROUP BY a.MANDT, a.BUKRS, a.GJAHR, a.BELNR, a.BUZEI
)
SELECT CASE
         WHEN standard_billing_docs = 1 AND unsafe_number_collisions = 0
           THEN 'STANDARD_ONLY'
         WHEN standard_billing_docs = 1 AND unsafe_number_collisions > 0
           THEN 'BOTH_PRESENT_COMPARE_IDS'
         WHEN standard_billing_docs = 0 AND unsafe_number_collisions > 0
           THEN 'UNSAFE_ONLY_NUMBER_COLLISION'
         WHEN standard_billing_docs > 1
           THEN 'AMBIGUOUS_STANDARD_LINK'
         ELSE 'NO_BILLING_LINK'
       END AS link_status,
       COUNT(*) AS fi_item_count
FROM item_links
GROUP BY 1
ORDER BY fi_item_count DESC;


-- ============================================================================
-- 6. Profile real billing/profit-center splits through VBRK -> VBRP.
--    The current query assigns every row below with bu_count > 1 to only one BU.
-- ============================================================================
WITH ar_items AS (
  SELECT MANDT, BUKRS, GJAHR, BELNR, BUZEI, WRBTR, WAERS
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE MANDT = '010'
    AND TRIM(COALESCE(VBUND, '')) <> ''
    AND UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL

  SELECT MANDT, BUKRS, GJAHR, BELNR, BUZEI, WRBTR, WAERS
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE MANDT = '010'
    AND TRIM(COALESCE(VBUND, '')) <> ''
    AND UPPER(COALESCE(hdr__oper, '')) <> 'D'
),
split_profile AS (
  SELECT a.MANDT, a.BUKRS, a.GJAHR, a.BELNR, a.BUZEI,
         MAX(a.WAERS) AS WAERS,
         MAX(a.WRBTR) AS source_item_amount,
         COUNT(DISTINCT NAMED_STRUCT('vbeln', p.VBELN, 'posnr', p.POSNR))
           AS billing_item_count,
         COUNT(DISTINCT h.BU) AS bu_count,
         COUNT(DISTINCT pc.OU) AS ou_count,
         SORT_ARRAY(COLLECT_SET(h.BU)) AS billing_bus,
         SORT_ARRAY(COLLECT_SET(CAST(pc.OU AS STRING))) AS billing_ous
  FROM ar_items a
  JOIN qlk_c.c_ocs_ecc_old.vbrk k
    ON k.MANDT = a.MANDT
   AND k.BUKRS = a.BUKRS
   AND k.GJAHR = a.GJAHR
   AND k.BELNR = a.BELNR
   AND UPPER(COALESCE(k.hdr__oper, '')) <> 'D'
  JOIN qlk_c.c_ocs_ecc_old.vbrp p
    ON p.MANDT = k.MANDT
   AND p.VBELN = k.VBELN
   AND UPPER(COALESCE(p.hdr__oper, '')) <> 'D'
  LEFT JOIN qlk_c.c_ocs_sql.ocs_kairos_emea_prof_ctr pc
    ON pc.CompCode = a.BUKRS
   AND pc.Prof_ctr = p.PRCTR
  LEFT JOIN common.business_structures.bu_ou_div_hierarchy h
    ON h.OU = pc.OU
   AND h.BU <> ''
   AND h.OU <> '1999'
  GROUP BY a.MANDT, a.BUKRS, a.GJAHR, a.BELNR, a.BUZEI
)
SELECT *
FROM split_profile
WHERE bu_count > 1 OR ou_count > 1
ORDER BY bu_count DESC, ou_count DESC, billing_item_count DESC;


-- ============================================================================
-- 7. Show sales-order rows that can fan out the final AR result after ranking.
-- ============================================================================
SELECT vbak.MANDT,
       vbak.VBELN AS sales_order,
       COUNT(*) AS joined_item_rows,
       COUNT(DISTINCT vbap.PSTYV) AS item_category_count,
       SORT_ARRAY(COLLECT_SET(vbap.PSTYV)) AS item_categories
FROM qlk_c.c_ocs_ecc_old.vbak vbak
JOIN qlk_c.c_ocs_ecc_old.vbap vbap
  ON vbap.MANDT = vbak.MANDT
 AND vbap.VBELN = vbak.VBELN
WHERE vbak.MANDT = '010'
  AND UPPER(COALESCE(vbak.hdr__oper, '')) <> 'D'
  AND UPPER(COALESCE(vbap.hdr__oper, '')) <> 'D'
  AND (
    vbak.AUART IN ('ZCPL','TA','ZFC','ZQF1','ZTA','ZQQ','ZKM')
    OR vbap.PSTYV IN ('AFC','AFN','TAC','TAN','ZKMC','ZKMN')
  )
GROUP BY vbak.MANDT, vbak.VBELN
HAVING COUNT(DISTINCT vbap.PSTYV) > 1
ORDER BY joined_item_rows DESC;


-- ============================================================================
-- 8. Detect FX duplicates and inclusive-date overlaps.
--    Any result can duplicate a financial item in the current range joins.
-- ============================================================================
WITH raw_rates AS (
  SELECT From_Curr, To_Curr, Rate_Type, Date_From, Date_To,
         CAST(Exchange_Rate AS DECIMAL(38, 12)) AS Exchange_Rate,
         ROW_NUMBER() OVER (
           ORDER BY From_Curr, To_Curr, Date_From, Date_To,
                    Rate_Type, Exchange_Rate
         ) AS rate_row_id
  FROM ocs.pharos_silver.r_ecc_forex_table
  WHERE To_Curr = 'USD'
    AND Rate_Type IN ('CPM', '1001')
    AND TRIM(COALESCE(From_Curr, '')) <> ''
)
SELECT a.From_Curr,
       a.Rate_Type AS rate_type_a,
       a.Date_From AS a_start,
       a.Date_To AS a_end,
       a.Exchange_Rate AS rate_a,
       b.Rate_Type AS rate_type_b,
       b.Date_From AS b_start,
       b.Date_To AS b_end,
       b.Exchange_Rate AS rate_b
FROM raw_rates a
JOIN raw_rates b
  ON a.From_Curr = b.From_Curr
 AND a.To_Curr = b.To_Curr
 AND a.rate_row_id < b.rate_row_id
 -- Inclusive overlap, matching the current query's join semantics.
 AND a.Date_From <= b.Date_To
 AND b.Date_From <= a.Date_To
ORDER BY a.From_Curr, a.Date_From, b.Date_From;


-- ============================================================================
-- 9. Reconstruct a consistent AR/AP key-date population.
--    Example cutoff: through 2026-08-31, expressed as exclusive 2026-09-01.
--    Compare these totals to trusted SAP key-date reports before enrichment.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-08-31' AS as_of_date,
         DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt
),
operational_items AS (
  SELECT 'AR' AS item_class, 'BSID' AS current_index,
         MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT,
         CASE
           WHEN TRIM(COALESCE(CAST(AUGDT AS STRING), ''))
                IN ('', '00000000', '0001-01-01', '0101-01-01') THEN NULL
           ELSE TO_DATE(AUGDT)
         END AS clearing_date,
         WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END AS amount_dc
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL

  SELECT 'AR', 'BSAD', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT,
         CASE
           WHEN TRIM(COALESCE(CAST(AUGDT AS STRING), ''))
                IN ('', '00000000', '0001-01-01', '0101-01-01') THEN NULL
           ELSE TO_DATE(AUGDT)
         END,
         WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL

  SELECT 'AP', 'BSIK', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT,
         CASE
           WHEN TRIM(COALESCE(CAST(AUGDT AS STRING), ''))
                IN ('', '00000000', '0001-01-01', '0101-01-01') THEN NULL
           ELSE TO_DATE(AUGDT)
         END,
         WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsik
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL

  SELECT 'AP', 'BSAK', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT,
         CASE
           WHEN TRIM(COALESCE(CAST(AUGDT AS STRING), ''))
                IN ('', '00000000', '0001-01-01', '0101-01-01') THEN NULL
           ELSE TO_DATE(AUGDT)
         END,
         WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsak
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
),
as_of_items AS (
  SELECT i.*
  FROM operational_items i
  CROSS JOIN params p
  WHERE i.MANDT = p.mandt
    AND i.BUDAT < p.cutoff_exclusive
    AND (i.clearing_date IS NULL OR i.clearing_date >= p.cutoff_exclusive)
)
SELECT item_class,
       current_index,
       BUKRS,
       HKONT,
       WAERS,
       COUNT(*) AS item_rows,
       COUNT(DISTINCT NAMED_STRUCT(
         'mandt', MANDT, 'bukrs', BUKRS, 'gjahr', GJAHR,
         'belnr', BELNR, 'buzei', BUZEI
       )) AS distinct_items,
       SUM(amount_dc) AS signed_document_amount,
       MIN(BUDAT) AS oldest_posting_date,
       MAX(BUDAT) AS newest_posting_date
FROM as_of_items
GROUP BY item_class, current_index, BUKRS, HKONT, WAERS
ORDER BY item_class, BUKRS, HKONT, WAERS, current_index;


-- ============================================================================
-- 10. Measure current GR/IR PO-item and partner-recovery coverage.
--     This demonstrates the rows lost by same-document-vendor-only logic.
-- ============================================================================
WITH grir AS (
  SELECT b.MANDT, b.BUKRS, b.GJAHR, b.BELNR, b.BUZEI,
         b.HKONT, b.EBELN, b.EBELP, b.PRCTR, b.VBUND,
         k.BUDAT, k.WAERS,
         CASE WHEN b.SHKZG = 'S' THEN b.WRBTR
              WHEN b.SHKZG = 'H' THEN -b.WRBTR END AS amount_dc
  FROM qlk_c.c_ocs_ecc_old.bseg b
  JOIN qlk_c.c_ocs_ecc_old.bkpf k
    ON k.MANDT = b.MANDT
   AND k.BUKRS = b.BUKRS
   AND k.GJAHR = b.GJAHR
   AND k.BELNR = b.BELNR
  WHERE b.MANDT = '010'
    AND b.HKONT = '0020110000'
    AND UPPER(COALESCE(b.hdr__oper, '')) <> 'D'
    AND UPPER(COALESCE(k.hdr__oper, '')) <> 'D'
),
document_vendor AS (
  SELECT b.MANDT, b.BUKRS, b.GJAHR, b.BELNR,
         COUNT(DISTINCT COALESCE(
           NULLIF(TRIM(b.VBUND), ''), NULLIF(TRIM(l.VBUND), '')
         ))
           AS partner_count,
         MAX(COALESCE(
           NULLIF(TRIM(b.VBUND), ''), NULLIF(TRIM(l.VBUND), '')
         ))
           AS unique_partner_candidate
  FROM qlk_c.c_ocs_ecc_old.bseg b
  LEFT JOIN qlk_c.c_ocs_ecc_old.lfa1 l
    ON l.MANDT = b.MANDT
   AND l.LIFNR = b.LIFNR
   AND UPPER(COALESCE(l.hdr__oper, '')) <> 'D'
  WHERE b.MANDT = '010'
    AND b.KOART = 'K'
    AND UPPER(COALESCE(b.hdr__oper, '')) <> 'D'
  GROUP BY b.MANDT, b.BUKRS, b.GJAHR, b.BELNR
),
po_vendor AS (
  SELECT e.MANDT, e.EBELN,
         COUNT(DISTINCT NULLIF(TRIM(l.VBUND), '')) AS partner_count,
         MAX(NULLIF(TRIM(l.VBUND), '')) AS unique_partner_candidate
  FROM qlk_c.c_ocs_ecc_old.ekko e
  LEFT JOIN qlk_c.c_ocs_ecc_old.lfa1 l
    ON l.MANDT = e.MANDT
   AND l.LIFNR = e.LIFNR
   AND UPPER(COALESCE(l.hdr__oper, '')) <> 'D'
  WHERE e.MANDT = '010'
    AND UPPER(COALESCE(e.hdr__oper, '')) <> 'D'
  GROUP BY e.MANDT, e.EBELN
)
SELECT COUNT(*) AS grir_fi_lines,
       SUM(CASE WHEN TRIM(COALESCE(g.EBELN, '')) <> ''
                     AND TRIM(COALESCE(g.EBELP, '')) <> '' THEN 1 ELSE 0 END)
         AS lines_with_po_item,
       SUM(CASE WHEN TRIM(COALESCE(g.VBUND, '')) <> '' THEN 1 ELSE 0 END)
         AS lines_with_posted_vbund,
       SUM(CASE WHEN TRIM(COALESCE(g.VBUND, '')) = ''
                     AND dv.partner_count = 1 THEN 1 ELSE 0 END)
         AS lines_recoverable_from_same_fi_document,
       SUM(CASE WHEN TRIM(COALESCE(g.VBUND, '')) = ''
                     AND COALESCE(dv.partner_count, 0) <> 1
                     AND pv.partner_count = 1 THEN 1 ELSE 0 END)
         AS additional_lines_recoverable_from_po_vendor,
       SUM(CASE WHEN TRIM(COALESCE(g.VBUND, '')) = ''
                     AND COALESCE(dv.partner_count, 0) <> 1
                     AND COALESCE(pv.partner_count, 0) <> 1 THEN 1 ELSE 0 END)
         AS unresolved_partner_lines,
       SUM(CASE WHEN TRIM(COALESCE(g.EBELN, '')) = ''
                     OR TRIM(COALESCE(g.EBELP, '')) = '' THEN 1 ELSE 0 END)
         AS no_po_item_lines
FROM grir g
LEFT JOIN document_vendor dv
  ON dv.MANDT = g.MANDT
 AND dv.BUKRS = g.BUKRS
 AND dv.GJAHR = g.GJAHR
 AND dv.BELNR = g.BELNR
LEFT JOIN po_vendor pv
  ON pv.MANDT = g.MANDT
 AND pv.EBELN = g.EBELN;


-- ============================================================================
-- 11. Build the minimum defensible open GR/IR PO-item balance at one cutoff.
--     This is a foundation for PO-history root-cause enrichment, not yet the
--     final GR-versus-IR event classifier.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-08-31' AS as_of_date,
         DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt
),
grir_open_lines AS (
  SELECT b.MANDT, b.BUKRS, b.GJAHR, b.BELNR, b.BUZEI,
         b.HKONT, b.EBELN, b.EBELP, b.PRCTR, b.VBUND,
         k.BUDAT, k.WAERS,
         CASE
           WHEN TRIM(COALESCE(CAST(b.AUGDT AS STRING), ''))
                IN ('', '00000000', '0001-01-01', '0101-01-01') THEN NULL
           ELSE TO_DATE(b.AUGDT)
         END AS clearing_date,
         CASE WHEN b.SHKZG = 'S' THEN b.WRBTR
              WHEN b.SHKZG = 'H' THEN -b.WRBTR END AS amount_dc,
         CASE WHEN b.SHKZG = 'S' THEN b.DMBTR
              WHEN b.SHKZG = 'H' THEN -b.DMBTR END AS amount_lc
  FROM qlk_c.c_ocs_ecc_old.bseg b
  JOIN qlk_c.c_ocs_ecc_old.bkpf k
    ON k.MANDT = b.MANDT
   AND k.BUKRS = b.BUKRS
   AND k.GJAHR = b.GJAHR
   AND k.BELNR = b.BELNR
  CROSS JOIN params p
  WHERE b.MANDT = p.mandt
    AND b.HKONT = '0020110000'
    AND k.BUDAT < p.cutoff_exclusive
    AND (
      TRIM(COALESCE(CAST(b.AUGDT AS STRING), ''))
        IN ('', '00000000', '0001-01-01', '0101-01-01')
      OR TO_DATE(b.AUGDT) >= p.cutoff_exclusive
    )
    AND UPPER(COALESCE(b.hdr__oper, '')) <> 'D'
    AND UPPER(COALESCE(k.hdr__oper, '')) <> 'D'
)
SELECT MANDT,
       BUKRS,
       HKONT,
       NULLIF(TRIM(EBELN), '') AS purchase_order,
       NULLIF(TRIM(EBELP), '') AS purchase_order_item,
       PRCTR,
       WAERS,
       COUNT(*) AS fi_line_count,
       SUM(amount_dc) AS open_amount_dc,
       SUM(amount_lc) AS open_amount_lc,
       MIN(BUDAT) AS oldest_posting_date,
       MAX(BUDAT) AS newest_posting_date,
       COUNT(DISTINCT NULLIF(TRIM(VBUND), '')) AS posted_partner_count
FROM grir_open_lines
GROUP BY MANDT, BUKRS, HKONT,
         NULLIF(TRIM(EBELN), ''), NULLIF(TRIM(EBELP), ''),
         PRCTR, WAERS
ORDER BY ABS(open_amount_lc) DESC;


-- ============================================================================
-- 12. Profile the actual EKBE event vocabulary attached to open GR/IR PO items.
--     Do not hardcode GR/IR meaning from sign alone. Use this result to build a
--     governed VGABE/BEWTP/BWART/reversal event map for this ECC instance.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-08-31' AS as_of_date,
         DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt
),
open_grir_po_items AS (
  SELECT DISTINCT b.MANDT, b.BUKRS, b.EBELN, b.EBELP
  FROM qlk_c.c_ocs_ecc_old.bseg b
  JOIN qlk_c.c_ocs_ecc_old.bkpf k
    ON k.MANDT = b.MANDT
   AND k.BUKRS = b.BUKRS
   AND k.GJAHR = b.GJAHR
   AND k.BELNR = b.BELNR
  CROSS JOIN params p
  WHERE b.MANDT = p.mandt
    AND b.HKONT = '0020110000'
    AND TRIM(COALESCE(b.EBELN, '')) <> ''
    AND TRIM(COALESCE(b.EBELP, '')) <> ''
    AND k.BUDAT < p.cutoff_exclusive
    AND (
      TRIM(COALESCE(CAST(b.AUGDT AS STRING), ''))
        IN ('', '00000000', '0001-01-01', '0101-01-01')
      OR TO_DATE(b.AUGDT) >= p.cutoff_exclusive
    )
    AND UPPER(COALESCE(b.hdr__oper, '')) <> 'D'
    AND UPPER(COALESCE(k.hdr__oper, '')) <> 'D'
)
SELECT e.VGABE,
       e.BEWTP,
       e.BWART,
       e.SHKZG,
       e.WAERS,
       COUNT(*) AS history_event_rows,
       COUNT(DISTINCT NAMED_STRUCT(
         'mandt', e.MANDT, 'ebeln', e.EBELN, 'ebelp', e.EBELP,
         'gjahr', e.GJAHR, 'belnr', e.BELNR, 'buzei', e.BUZEI
       )) AS distinct_history_events,
       COUNT(DISTINCT e.ZEKKN) AS account_assignment_count,
       SUM(CASE WHEN e.SHKZG = 'S' THEN e.MENGE
                WHEN e.SHKZG = 'H' THEN -e.MENGE END) AS signed_quantity,
       SUM(CASE WHEN e.SHKZG = 'S' THEN e.WRBTR
                WHEN e.SHKZG = 'H' THEN -e.WRBTR END) AS signed_po_currency_value,
       SUM(CASE WHEN e.SHKZG = 'S' THEN e.DMBTR
                WHEN e.SHKZG = 'H' THEN -e.DMBTR END) AS signed_local_value,
       MIN(e.BUDAT) AS first_event_date,
       MAX(e.BUDAT) AS last_event_date
FROM qlk_c.c_ocs_ecc_old.ekbe e
JOIN open_grir_po_items p
  ON p.MANDT = e.MANDT
 AND p.EBELN = e.EBELN
 AND p.EBELP = e.EBELP
WHERE UPPER(COALESCE(e.hdr__oper, '')) <> 'D'
GROUP BY e.VGABE, e.BEWTP, e.BWART, e.SHKZG, e.WAERS
ORDER BY history_event_rows DESC;


-- ============================================================================
-- 13. Demonstrate the current three-way classifier's over-explanation defect.
--     The first row is called TIMING_EXPLAINED by the existing rule even though
--     adding GR/IR worsens a 2,000 residual to -8,000.
-- ============================================================================
WITH examples AS (
  SELECT * FROM VALUES
    (CAST(2000 AS DECIMAL(18,2)), CAST(-10000 AS DECIMAL(18,2))),
    (CAST(2000 AS DECIMAL(18,2)), CAST(-2000 AS DECIMAL(18,2))),
    (CAST(2000 AS DECIMAL(18,2)), CAST(-800 AS DECIMAL(18,2))),
    (CAST(2000 AS DECIMAL(18,2)), CAST(1500 AS DECIMAL(18,2)))
  AS t(ar_ap_oob, grir_balance)
)
SELECT ar_ap_oob,
       grir_balance,
       ar_ap_oob + grir_balance AS residual_after_grir,
       CASE
         WHEN ABS(ar_ap_oob) < 1000 THEN 'BALANCED'
         WHEN ABS(grir_balance) < 1000 THEN 'STRUCTURAL'
         WHEN SIGN(ar_ap_oob) = SIGN(grir_balance) THEN 'COMPOUNDING'
         WHEN ABS(grir_balance) >= 0.5 * ABS(ar_ap_oob) THEN 'TIMING_EXPLAINED'
         ELSE 'PARTIAL_TIMING'
       END AS current_rule_with_1000_threshold,
       CASE
         WHEN SIGN(ar_ap_oob) <> SIGN(grir_balance)
          AND ABS(ar_ap_oob + grir_balance) < ABS(ar_ap_oob)
           THEN 'NUMERICALLY_IMPROVES_BUT_STILL_NEEDS_CAUSAL_LINEAGE'
         ELSE 'DOES_NOT_EXPLAIN'
       END AS safer_numeric_diagnostic
FROM examples;


-- ============================================================================
-- 14. Controls to run after materializing a revised candidate view.
--     Replace candidate_view/allocation_view/pair_summary with actual objects.
-- ============================================================================
-- SELECT source_item_key, COUNT(*)
-- FROM candidate_view
-- GROUP BY source_item_key
-- HAVING COUNT(*) > 1;

-- SELECT source_item_key,
--        MAX(source_amount_dc) AS source_amount_dc,
--        SUM(allocated_amount_dc) AS allocated_amount_dc,
--        MAX(source_amount_dc) - SUM(allocated_amount_dc) AS allocation_residual_dc
-- FROM allocation_view
-- GROUP BY source_item_key
-- HAVING ABS(MAX(source_amount_dc) - SUM(allocated_amount_dc)) > 0.01;

-- SELECT pair_key, cutoff_exclusive, COUNT(*)
-- FROM pair_summary
-- GROUP BY pair_key, cutoff_exclusive
-- HAVING COUNT(*) > 1;

-- SELECT pair_key, cutoff_exclusive
-- FROM pair_summary
-- WHERE normal_balance_classification IS NOT NULL
--   AND (missing_fx_count > 0
--        OR ambiguous_entity_count > 0
--        OR unallocated_amount_usd <> 0
--        OR enrichment_fanout_count > 0);

-- SELECT grir_link_id
-- FROM ic_grir_link
-- WHERE explanation_status = 'TIMING_EXPLAINED_GR_NOT_IR'
--   AND (lineage_tier <> 'CONFIRMED'
--        OR grir_balance_sign <> 'CREDIT'
--        OR same_cutoff_flag <> 1
--        OR reciprocal_entity_flag <> 1);


-- ============================================================================
-- 15. Quantify blank-partner exposure that the current AR/AP predicates remove.
--     This is restricted to an example governed account list and one cutoff.
--     Replace the accounts before use. Run uniqueness diagnostic 2 first.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt
),
account_scope AS (
  SELECT * FROM VALUES
    ('AR', '0010250000'),
    ('AP', '0020850000'),
    ('AP', '0020850001'),
    ('AP', '0020850003'),
    ('AP', '0020858000')
  AS t(item_class, hkont)
),
operational_items AS (
  SELECT 'AR' AS item_class, 'BSID' AS source_table,
         MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT,
         VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END AS amount_dc
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL

  SELECT 'AR', 'BSAD',
         MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT,
         VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL

  SELECT 'AP', 'BSIK',
         MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT,
         VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsik
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL

  SELECT 'AP', 'BSAK',
         MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT,
         VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsak
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
),
as_of_scoped AS (
  SELECT i.*
  FROM operational_items i
  JOIN account_scope s
    ON s.item_class = i.item_class
   AND s.hkont = i.HKONT
  CROSS JOIN params p
  WHERE i.MANDT = p.mandt
    AND i.BUDAT < p.cutoff_exclusive
    AND (
      TRIM(COALESCE(CAST(i.AUGDT AS STRING), ''))
        IN ('', '00000000', '0001-01-01', '0101-01-01')
      OR TO_DATE(i.AUGDT) >= p.cutoff_exclusive
    )
)
SELECT item_class,
       source_table,
       BUKRS,
       HKONT,
       WAERS,
       CASE WHEN TRIM(COALESCE(VBUND, '')) = ''
            THEN 'MISSING_POSTED_PARTNER'
            ELSE 'POSTED_PARTNER_PRESENT' END AS partner_population_class,
       COUNT(*) AS physical_rows,
       COUNT(DISTINCT NAMED_STRUCT(
         'mandt', MANDT, 'bukrs', BUKRS, 'gjahr', GJAHR,
         'belnr', BELNR, 'buzei', BUZEI
       )) AS distinct_items,
       SUM(amount_dc) AS signed_amount_dc,
       SUM(ABS(amount_dc)) AS gross_amount_dc
FROM as_of_scoped
GROUP BY item_class, source_table, BUKRS, HKONT, WAERS,
         CASE WHEN TRIM(COALESCE(VBUND, '')) = ''
              THEN 'MISSING_POSTED_PARTNER'
              ELSE 'POSTED_PARTNER_PRESENT' END
ORDER BY item_class, BUKRS, HKONT, WAERS, partner_population_class;


-- ============================================================================
-- 16. Profile current customer/vendor-master evidence without overwriting VBUND.
--     This is a diagnostic only: current KNA1/LFA1 is not historical truth.
--     Production resolution requires an as-of/SCD2 master and one evidence row
--     per candidate. partner_count > 1 must remain ambiguous.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt
),
account_scope AS (
  SELECT * FROM VALUES
    ('AR', '0010250000'),
    ('AP', '0020850000'),
    ('AP', '0020850001'),
    ('AP', '0020850003'),
    ('AP', '0020858000')
  AS t(item_class, hkont)
),
items AS (
  SELECT 'AR' AS item_class, 'BSID' AS source_table,
         MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT,
         KUNNR AS counterparty_account, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END AS amount_dc
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL
  SELECT 'AR', 'BSAD', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT, AUGDT, KUNNR, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL
  SELECT 'AP', 'BSIK', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT, AUGDT, LIFNR, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsik
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'

  UNION ALL
  SELECT 'AP', 'BSAK', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT, AUGDT, LIFNR, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsak
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
),
as_of_scoped AS (
  SELECT i.*
  FROM items i
  JOIN account_scope s
    ON s.item_class = i.item_class
   AND s.hkont = i.HKONT
  CROSS JOIN params p
  WHERE i.MANDT = p.mandt
    AND i.BUDAT < p.cutoff_exclusive
    AND (
      TRIM(COALESCE(CAST(i.AUGDT AS STRING), ''))
        IN ('', '00000000', '0001-01-01', '0101-01-01')
      OR TO_DATE(i.AUGDT) >= p.cutoff_exclusive
    )
),
customer_master AS (
  SELECT MANDT, KUNNR AS counterparty_account,
         COUNT(DISTINCT NULLIF(TRIM(VBUND), '')) AS partner_count,
         MAX(NULLIF(TRIM(VBUND), '')) AS candidate_partner
  FROM qlk_c.c_ocs_ecc_old.kna1
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
  GROUP BY MANDT, KUNNR
),
vendor_master AS (
  SELECT MANDT, LIFNR AS counterparty_account,
         COUNT(DISTINCT NULLIF(TRIM(VBUND), '')) AS partner_count,
         MAX(NULLIF(TRIM(VBUND), '')) AS candidate_partner
  FROM qlk_c.c_ocs_ecc_old.lfa1
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
  GROUP BY MANDT, LIFNR
),
enriched AS (
  SELECT i.*,
         CASE WHEN i.item_class = 'AR' THEN COALESCE(c.partner_count, 0)
              ELSE COALESCE(v.partner_count, 0) END AS master_partner_count,
         CASE WHEN i.item_class = 'AR' THEN c.candidate_partner
              ELSE v.candidate_partner END AS master_candidate_partner
  FROM as_of_scoped i
  LEFT JOIN customer_master c
    ON i.item_class = 'AR'
   AND c.MANDT = i.MANDT
   AND c.counterparty_account = i.counterparty_account
  LEFT JOIN vendor_master v
    ON i.item_class = 'AP'
   AND v.MANDT = i.MANDT
   AND v.counterparty_account = i.counterparty_account
)
SELECT item_class,
       BUKRS,
       HKONT,
       WAERS,
       CASE
         WHEN TRIM(COALESCE(VBUND, '')) = '' AND master_partner_count = 1
           THEN 'MISSING_UNIQUE_CURRENT_MASTER_CANDIDATE'
         WHEN TRIM(COALESCE(VBUND, '')) = '' AND master_partner_count > 1
           THEN 'MISSING_AMBIGUOUS_CURRENT_MASTER'
         WHEN TRIM(COALESCE(VBUND, '')) = ''
           THEN 'MISSING_NO_CURRENT_MASTER_PARTNER'
         WHEN master_partner_count = 1
          AND TRIM(VBUND) <> master_candidate_partner
           THEN 'POSTED_CURRENT_MASTER_CONFLICT'
         WHEN master_partner_count = 1
           THEN 'POSTED_CURRENT_MASTER_AGREE'
         ELSE 'POSTED_MASTER_NOT_TESTABLE'
       END AS evidence_class,
       COUNT(*) AS item_rows,
       SUM(amount_dc) AS signed_amount_dc,
       SUM(ABS(amount_dc)) AS gross_amount_dc
FROM enriched
GROUP BY item_class, BUKRS, HKONT, WAERS,
         CASE
           WHEN TRIM(COALESCE(VBUND, '')) = '' AND master_partner_count = 1
             THEN 'MISSING_UNIQUE_CURRENT_MASTER_CANDIDATE'
           WHEN TRIM(COALESCE(VBUND, '')) = '' AND master_partner_count > 1
             THEN 'MISSING_AMBIGUOUS_CURRENT_MASTER'
           WHEN TRIM(COALESCE(VBUND, '')) = ''
             THEN 'MISSING_NO_CURRENT_MASTER_PARTNER'
           WHEN master_partner_count = 1
            AND TRIM(VBUND) <> master_candidate_partner
             THEN 'POSTED_CURRENT_MASTER_CONFLICT'
           WHEN master_partner_count = 1
             THEN 'POSTED_CURRENT_MASTER_AGREE'
           ELSE 'POSTED_MASTER_NOT_TESTABLE'
         END
ORDER BY item_class, BUKRS, HKONT, WAERS, evidence_class;


-- ============================================================================
-- 17. Measure same-document partner evidence for blank-partner items.
--     UNIQUE is only a candidate. SAP document-type configuration and other
--     strong evidence still must be checked before automatic use.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt
),
account_scope AS (
  SELECT * FROM VALUES
    ('AR', '0010250000'),
    ('AP', '0020850000'),
    ('AP', '0020850001'),
    ('AP', '0020850003'),
    ('AP', '0020858000')
  AS t(item_class, hkont)
),
items AS (
  SELECT 'AR' AS item_class, 'BSID' AS source_table,
         MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT,
         VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END AS amount_dc
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
  UNION ALL
  SELECT 'AR', 'BSAD', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT, AUGDT, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
  UNION ALL
  SELECT 'AP', 'BSIK', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT, AUGDT, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsik
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
  UNION ALL
  SELECT 'AP', 'BSAK', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT, AUGDT, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsak
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
),
blank_scoped AS (
  SELECT i.*
  FROM items i
  JOIN account_scope s
    ON s.item_class = i.item_class
   AND s.hkont = i.HKONT
  CROSS JOIN params p
  WHERE i.MANDT = p.mandt
    AND i.BUDAT < p.cutoff_exclusive
    AND TRIM(COALESCE(i.VBUND, '')) = ''
    AND (
      TRIM(COALESCE(CAST(i.AUGDT AS STRING), ''))
        IN ('', '00000000', '0001-01-01', '0101-01-01')
      OR TO_DATE(i.AUGDT) >= p.cutoff_exclusive
    )
),
target_docs AS (
  SELECT DISTINCT MANDT, BUKRS, GJAHR, BELNR
  FROM blank_scoped
),
document_partners AS (
  SELECT d.MANDT, d.BUKRS, d.GJAHR, d.BELNR,
         COUNT(DISTINCT NULLIF(TRIM(b.VBUND), '')) AS partner_count,
         MAX(NULLIF(TRIM(b.VBUND), '')) AS candidate_partner
  FROM target_docs d
  JOIN qlk_c.c_ocs_ecc_old.bseg b
    ON b.MANDT = d.MANDT
   AND b.BUKRS = d.BUKRS
   AND b.GJAHR = d.GJAHR
   AND b.BELNR = d.BELNR
   AND UPPER(COALESCE(b.hdr__oper, '')) <> 'D'
  GROUP BY d.MANDT, d.BUKRS, d.GJAHR, d.BELNR
)
SELECT i.item_class,
       i.BUKRS,
       i.HKONT,
       i.WAERS,
       CASE WHEN COALESCE(d.partner_count, 0) = 0
              THEN 'NO_SIBLING_PARTNER'
            WHEN d.partner_count = 1
              THEN 'UNIQUE_SIBLING_CANDIDATE_NOT_YET_APPROVED'
            ELSE 'AMBIGUOUS_MULTIPLE_SIBLING_PARTNERS'
       END AS sibling_evidence_class,
       COUNT(*) AS item_rows,
       SUM(i.amount_dc) AS signed_amount_dc,
       SUM(ABS(i.amount_dc)) AS gross_amount_dc
FROM blank_scoped i
LEFT JOIN document_partners d
  ON d.MANDT = i.MANDT
 AND d.BUKRS = i.BUKRS
 AND d.GJAHR = i.GJAHR
 AND d.BELNR = i.BELNR
GROUP BY i.item_class, i.BUKRS, i.HKONT, i.WAERS,
         CASE WHEN COALESCE(d.partner_count, 0) = 0
                THEN 'NO_SIBLING_PARTNER'
              WHEN d.partner_count = 1
                THEN 'UNIQUE_SIBLING_CANDIDATE_NOT_YET_APPROVED'
              ELSE 'AMBIGUOUS_MULTIPLE_SIBLING_PARTNERS'
         END
ORDER BY i.item_class, i.BUKRS, i.HKONT, i.WAERS,
         sibling_evidence_class;


-- ============================================================================
-- 18. Holdout backtest for current customer/vendor master fallback.
--     This masks the posted partner logically and asks whether current master
--     would reproduce it. It is NOT a production precision estimate until the
--     master is reconstructed as of posting date and time-based holdouts are
--     used. False-assignment dollars matter as much as row precision.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt
),
account_scope AS (
  SELECT * FROM VALUES
    ('AR', '0010250000'),
    ('AP', '0020850000'),
    ('AP', '0020850001'),
    ('AP', '0020850003'),
    ('AP', '0020858000')
  AS t(item_class, hkont)
),
posted_items AS (
  SELECT 'AR' AS item_class, 'BSID' AS source_table,
         MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT,
         KUNNR AS counterparty_account, TRIM(VBUND) AS hidden_truth_partner,
         WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END AS amount_dc
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
    AND TRIM(COALESCE(VBUND, '')) <> ''
  UNION ALL
  SELECT 'AR', 'BSAD', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT, AUGDT, KUNNR, TRIM(VBUND), WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
    AND TRIM(COALESCE(VBUND, '')) <> ''
  UNION ALL
  SELECT 'AP', 'BSIK', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT, AUGDT, LIFNR, TRIM(VBUND), WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsik
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
    AND TRIM(COALESCE(VBUND, '')) <> ''
  UNION ALL
  SELECT 'AP', 'BSAK', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT,
         BUDAT, AUGDT, LIFNR, TRIM(VBUND), WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsak
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
    AND TRIM(COALESCE(VBUND, '')) <> ''
),
as_of_scoped AS (
  SELECT i.*
  FROM posted_items i
  JOIN account_scope s
    ON s.item_class = i.item_class
   AND s.hkont = i.HKONT
  CROSS JOIN params p
  WHERE i.MANDT = p.mandt
    AND i.BUDAT < p.cutoff_exclusive
    AND (
      TRIM(COALESCE(CAST(i.AUGDT AS STRING), ''))
        IN ('', '00000000', '0001-01-01', '0101-01-01')
      OR TO_DATE(i.AUGDT) >= p.cutoff_exclusive
    )
),
customer_master AS (
  SELECT MANDT, KUNNR AS counterparty_account,
         COUNT(DISTINCT NULLIF(TRIM(VBUND), '')) AS partner_count,
         MAX(NULLIF(TRIM(VBUND), '')) AS candidate_partner
  FROM qlk_c.c_ocs_ecc_old.kna1
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
  GROUP BY MANDT, KUNNR
),
vendor_master AS (
  SELECT MANDT, LIFNR AS counterparty_account,
         COUNT(DISTINCT NULLIF(TRIM(VBUND), '')) AS partner_count,
         MAX(NULLIF(TRIM(VBUND), '')) AS candidate_partner
  FROM qlk_c.c_ocs_ecc_old.lfa1
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
  GROUP BY MANDT, LIFNR
),
scored AS (
  SELECT i.*,
         CASE WHEN i.item_class = 'AR' THEN COALESCE(c.partner_count, 0)
              ELSE COALESCE(v.partner_count, 0) END AS candidate_count,
         CASE WHEN i.item_class = 'AR' THEN c.candidate_partner
              ELSE v.candidate_partner END AS predicted_partner
  FROM as_of_scoped i
  LEFT JOIN customer_master c
    ON i.item_class = 'AR'
   AND c.MANDT = i.MANDT
   AND c.counterparty_account = i.counterparty_account
  LEFT JOIN vendor_master v
    ON i.item_class = 'AP'
   AND v.MANDT = i.MANDT
   AND v.counterparty_account = i.counterparty_account
)
SELECT item_class,
       source_table,
       BUKRS,
       HKONT,
       WAERS,
       COUNT(*) AS labeled_items,
       SUM(CASE WHEN candidate_count = 1 THEN 1 ELSE 0 END)
         AS uniquely_eligible_items,
       SUM(CASE WHEN candidate_count = 1
                     AND predicted_partner = hidden_truth_partner
                THEN 1 ELSE 0 END) AS correct_items,
       SUM(CASE WHEN candidate_count = 1
                     AND predicted_partner <> hidden_truth_partner
                THEN 1 ELSE 0 END) AS false_auto_items,
       SUM(CASE WHEN candidate_count = 1
                     AND predicted_partner <> hidden_truth_partner
                THEN ABS(amount_dc) ELSE 0 END) AS false_auto_gross_amount_dc,
       SUM(CASE WHEN candidate_count = 1
                     AND predicted_partner = hidden_truth_partner
                THEN ABS(amount_dc) ELSE 0 END) AS correct_gross_amount_dc,
       SUM(CASE WHEN candidate_count = 1 THEN ABS(amount_dc) ELSE 0 END)
         AS eligible_gross_amount_dc,
       CASE WHEN SUM(CASE WHEN candidate_count = 1 THEN 1 ELSE 0 END) = 0
              THEN NULL
            ELSE SUM(CASE WHEN candidate_count = 1
                               AND predicted_partner = hidden_truth_partner
                          THEN 1 ELSE 0 END) * 1.0
                 / SUM(CASE WHEN candidate_count = 1 THEN 1 ELSE 0 END)
       END AS diagnostic_row_precision
FROM scored
GROUP BY item_class, source_table, BUKRS, HKONT, WAERS
ORDER BY item_class, BUKRS, HKONT, WAERS, source_table;


-- ============================================================================
-- 19. Find pair/currency groups that look balanced in aggregate while still
--     containing substantial gross documents. Without match assignments this
--     is NOT evidence that the underlying transactions reconcile.
--     Replace the example 1,000 / 100,000 thresholds before use.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt
),
account_scope AS (
  SELECT * FROM VALUES
    ('AR', '0010250000'),
    ('AP', '0020850000'),
    ('AP', '0020850001'),
    ('AP', '0020850003'),
    ('AP', '0020858000')
  AS t(item_class, hkont)
),
items AS (
  SELECT 'AR' AS item_class, MANDT, BUKRS, GJAHR, BELNR, BUZEI,
         HKONT, BUDAT, AUGDT, TRIM(VBUND) AS partner_company_id, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END AS amount_dc
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
    AND TRIM(COALESCE(VBUND, '')) <> ''
  UNION ALL
  SELECT 'AR', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT,
         AUGDT, TRIM(VBUND), WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
    AND TRIM(COALESCE(VBUND, '')) <> ''
  UNION ALL
  SELECT 'AP', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT,
         AUGDT, TRIM(VBUND), WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsik
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
    AND TRIM(COALESCE(VBUND, '')) <> ''
  UNION ALL
  SELECT 'AP', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT,
         AUGDT, TRIM(VBUND), WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsak
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
    AND TRIM(COALESCE(VBUND, '')) <> ''
),
as_of_scoped AS (
  SELECT i.*
  FROM items i
  JOIN account_scope s
    ON s.item_class = i.item_class
   AND s.hkont = i.HKONT
  CROSS JOIN params p
  WHERE i.MANDT = p.mandt
    AND i.BUDAT < p.cutoff_exclusive
    AND (
      TRIM(COALESCE(CAST(i.AUGDT AS STRING), ''))
        IN ('', '00000000', '0001-01-01', '0101-01-01')
      OR TO_DATE(i.AUGDT) >= p.cutoff_exclusive
    )
),
company_code_map AS (
  SELECT MANDT, BUKRS, MAX(NULLIF(TRIM(RCOMP), '')) AS owner_company_id
  FROM qlk_c.c_ocs_ecc_old.t001
  WHERE TRIM(COALESCE(RCOMP, '')) <> ''
    AND UPPER(COALESCE(hdr__oper, '')) <> 'D'
  GROUP BY MANDT, BUKRS
  HAVING COUNT(DISTINCT NULLIF(TRIM(RCOMP), '')) = 1
),
pair_items AS (
  SELECT i.*,
         c.owner_company_id,
         LEAST(c.owner_company_id, i.partner_company_id) AS pair_low,
         GREATEST(c.owner_company_id, i.partner_company_id) AS pair_high
  FROM as_of_scoped i
  JOIN company_code_map c
    ON c.MANDT = i.MANDT
   AND c.BUKRS = i.BUKRS
)
SELECT pair_low,
       pair_high,
       WAERS,
       COUNT(*) AS item_rows,
       COUNT(DISTINCT NAMED_STRUCT(
         'mandt', MANDT, 'bukrs', BUKRS, 'gjahr', GJAHR,
         'belnr', BELNR, 'buzei', BUZEI
       )) AS distinct_items,
       COUNT(DISTINCT NAMED_STRUCT(
         'mandt', MANDT, 'bukrs', BUKRS, 'gjahr', GJAHR, 'belnr', BELNR
       )) AS distinct_documents,
       SUM(amount_dc) AS pair_net_amount_dc,
       SUM(ABS(amount_dc)) AS pair_gross_amount_dc
FROM pair_items
GROUP BY pair_low, pair_high, WAERS
HAVING ABS(SUM(amount_dc)) < 1000
   AND SUM(ABS(amount_dc)) >= 100000
ORDER BY pair_gross_amount_dc DESC;


-- ============================================================================
-- 20. Build an atomic GR/IR partner-evidence conflict profile.
--     A unique candidate is not yet a timing explanation. It first needs
--     PO-item lifecycle classification, reciprocal entities, and direct lineage.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt,
         '0020110000' AS grir_hkont
),
grir AS (
  SELECT b.MANDT, b.BUKRS, b.GJAHR, b.BELNR, b.BUZEI,
         b.HKONT, b.EBELN, b.EBELP, b.LIFNR,
         NULLIF(TRIM(b.VBUND), '') AS posted_partner,
         k.BUDAT, k.WAERS,
         CASE WHEN b.SHKZG = 'S' THEN b.WRBTR
              WHEN b.SHKZG = 'H' THEN -b.WRBTR END AS amount_dc
  FROM qlk_c.c_ocs_ecc_old.bseg b
  JOIN qlk_c.c_ocs_ecc_old.bkpf k
    ON k.MANDT = b.MANDT
   AND k.BUKRS = b.BUKRS
   AND k.GJAHR = b.GJAHR
   AND k.BELNR = b.BELNR
  CROSS JOIN params p
  WHERE b.MANDT = p.mandt
    AND b.HKONT = p.grir_hkont
    AND k.BUDAT < p.cutoff_exclusive
    AND (
      TRIM(COALESCE(CAST(b.AUGDT AS STRING), ''))
        IN ('', '00000000', '0001-01-01', '0101-01-01')
      OR TO_DATE(b.AUGDT) >= p.cutoff_exclusive
    )
    AND UPPER(COALESCE(b.hdr__oper, '')) <> 'D'
    AND UPPER(COALESCE(k.hdr__oper, '')) <> 'D'
),
evidence AS (
  SELECT MANDT, BUKRS, GJAHR, BELNR, BUZEI,
         'GRIR_LINE_POSTED' AS evidence_type,
         posted_partner AS candidate_partner
  FROM grir
  WHERE posted_partner IS NOT NULL

  UNION ALL

  SELECT g.MANDT, g.BUKRS, g.GJAHR, g.BELNR, g.BUZEI,
         'FI_DOCUMENT_LINE_POSTED', NULLIF(TRIM(b.VBUND), '')
  FROM grir g
  JOIN qlk_c.c_ocs_ecc_old.bseg b
    ON b.MANDT = g.MANDT
   AND b.BUKRS = g.BUKRS
   AND b.GJAHR = g.GJAHR
   AND b.BELNR = g.BELNR
   AND UPPER(COALESCE(b.hdr__oper, '')) <> 'D'
  WHERE TRIM(COALESCE(b.VBUND, '')) <> ''

  UNION ALL

  SELECT g.MANDT, g.BUKRS, g.GJAHR, g.BELNR, g.BUZEI,
         'FI_DOCUMENT_VENDOR_MASTER', NULLIF(TRIM(l.VBUND), '')
  FROM grir g
  JOIN qlk_c.c_ocs_ecc_old.bseg b
    ON b.MANDT = g.MANDT
   AND b.BUKRS = g.BUKRS
   AND b.GJAHR = g.GJAHR
   AND b.BELNR = g.BELNR
   AND b.KOART = 'K'
   AND TRIM(COALESCE(b.LIFNR, '')) <> ''
   AND UPPER(COALESCE(b.hdr__oper, '')) <> 'D'
  JOIN qlk_c.c_ocs_ecc_old.lfa1 l
    ON l.MANDT = b.MANDT
   AND l.LIFNR = b.LIFNR
   AND UPPER(COALESCE(l.hdr__oper, '')) <> 'D'
  WHERE TRIM(COALESCE(l.VBUND, '')) <> ''

  UNION ALL

  SELECT g.MANDT, g.BUKRS, g.GJAHR, g.BELNR, g.BUZEI,
         'PO_VENDOR_MASTER', NULLIF(TRIM(l.VBUND), '')
  FROM grir g
  JOIN qlk_c.c_ocs_ecc_old.ekko e
    ON e.MANDT = g.MANDT
   AND e.EBELN = g.EBELN
   AND UPPER(COALESCE(e.hdr__oper, '')) <> 'D'
  JOIN qlk_c.c_ocs_ecc_old.lfa1 l
    ON l.MANDT = e.MANDT
   AND l.LIFNR = e.LIFNR
   AND UPPER(COALESCE(l.hdr__oper, '')) <> 'D'
  WHERE TRIM(COALESCE(g.EBELN, '')) <> ''
    AND TRIM(COALESCE(l.VBUND, '')) <> ''
),
evidence_summary AS (
  SELECT MANDT, BUKRS, GJAHR, BELNR, BUZEI,
         COUNT(DISTINCT candidate_partner) AS candidate_partner_count,
         COUNT(DISTINCT evidence_type) AS evidence_type_count,
         MAX(candidate_partner) AS unique_candidate_when_count_one
  FROM evidence
  WHERE candidate_partner IS NOT NULL
  GROUP BY MANDT, BUKRS, GJAHR, BELNR, BUZEI
)
SELECT g.BUKRS,
       g.HKONT,
       g.WAERS,
       CASE
         WHEN g.posted_partner IS NOT NULL
          AND COALESCE(s.candidate_partner_count, 0) > 1
           THEN 'POSTED_PARTNER_CONFLICT'
         WHEN g.posted_partner IS NOT NULL
           THEN 'POSTED_PARTNER_NO_CONFLICT_FOUND'
         WHEN COALESCE(s.candidate_partner_count, 0) = 1
           THEN 'UNIQUE_DERIVED_CANDIDATE_NOT_YET_APPROVED'
         WHEN COALESCE(s.candidate_partner_count, 0) > 1
           THEN 'AMBIGUOUS_DERIVED_CANDIDATES'
         ELSE 'UNRESOLVED_NO_CANDIDATE'
       END AS partner_evidence_class,
       COUNT(*) AS grir_line_rows,
       SUM(CASE WHEN TRIM(COALESCE(g.EBELN, '')) <> ''
                     AND TRIM(COALESCE(g.EBELP, '')) <> ''
                THEN 1 ELSE 0 END) AS lines_with_po_item,
       SUM(g.amount_dc) AS signed_amount_dc,
       SUM(ABS(g.amount_dc)) AS gross_amount_dc
FROM grir g
LEFT JOIN evidence_summary s
  ON s.MANDT = g.MANDT
 AND s.BUKRS = g.BUKRS
 AND s.GJAHR = g.GJAHR
 AND s.BELNR = g.BELNR
 AND s.BUZEI = g.BUZEI
GROUP BY g.BUKRS, g.HKONT, g.WAERS,
         CASE
           WHEN g.posted_partner IS NOT NULL
            AND COALESCE(s.candidate_partner_count, 0) > 1
             THEN 'POSTED_PARTNER_CONFLICT'
           WHEN g.posted_partner IS NOT NULL
             THEN 'POSTED_PARTNER_NO_CONFLICT_FOUND'
           WHEN COALESCE(s.candidate_partner_count, 0) = 1
             THEN 'UNIQUE_DERIVED_CANDIDATE_NOT_YET_APPROVED'
           WHEN COALESCE(s.candidate_partner_count, 0) > 1
             THEN 'AMBIGUOUS_DERIVED_CANDIDATES'
           ELSE 'UNRESOLVED_NO_CANDIDATE'
         END
ORDER BY g.BUKRS, g.WAERS, partner_evidence_class;


-- ============================================================================
-- 21. Quantify manual IC G/L activity omitted by the nonblank-VBUND predicate.
--     This is PERIOD ACTIVITY, not an open balance, unless Finance proves each
--     account is open-item managed and supplies a valid key-date clearing rule.
--     Replace account/document-type scope before use.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-01-01' AS period_start,
         DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt
),
manual_scope AS (
  SELECT * FROM VALUES
    ('0020850002', 'Z1'),
    ('0020850002', 'ME'),
    ('0020858002', 'Z1'),
    ('0020858002', 'ME')
  AS t(hkont, blart)
),
manual_activity AS (
  SELECT b.MANDT, b.BUKRS, b.GJAHR, b.BELNR, b.BUZEI,
         b.HKONT, k.BLART, k.BUDAT, k.WAERS, b.VBUND,
         CASE WHEN b.SHKZG = 'S' THEN b.WRBTR
              WHEN b.SHKZG = 'H' THEN -b.WRBTR END AS amount_dc
  FROM qlk_c.c_ocs_ecc_old.bseg b
  JOIN qlk_c.c_ocs_ecc_old.bkpf k
    ON k.MANDT = b.MANDT
   AND k.BUKRS = b.BUKRS
   AND k.GJAHR = b.GJAHR
   AND k.BELNR = b.BELNR
  JOIN manual_scope s
    ON s.hkont = b.HKONT
   AND s.blart = k.BLART
  CROSS JOIN params p
  WHERE b.MANDT = p.mandt
    AND k.BUDAT >= p.period_start
    AND k.BUDAT < p.cutoff_exclusive
    AND UPPER(COALESCE(b.hdr__oper, '')) <> 'D'
    AND UPPER(COALESCE(k.hdr__oper, '')) <> 'D'
)
SELECT BUKRS,
       HKONT,
       BLART,
       WAERS,
       CASE WHEN TRIM(COALESCE(VBUND, '')) = ''
              THEN 'MISSING_POSTED_PARTNER'
            ELSE 'POSTED_PARTNER_PRESENT'
       END AS partner_population_class,
       COUNT(*) AS line_rows,
       COUNT(DISTINCT NAMED_STRUCT(
         'mandt', MANDT, 'bukrs', BUKRS, 'gjahr', GJAHR,
         'belnr', BELNR, 'buzei', BUZEI
       )) AS distinct_items,
       SUM(amount_dc) AS signed_period_activity_dc,
       SUM(ABS(amount_dc)) AS gross_period_activity_dc
FROM manual_activity
GROUP BY BUKRS, HKONT, BLART, WAERS,
         CASE WHEN TRIM(COALESCE(VBUND, '')) = ''
                THEN 'MISSING_POSTED_PARTNER'
              ELSE 'POSTED_PARTNER_PRESENT'
         END
ORDER BY BUKRS, HKONT, BLART, WAERS, partner_population_class;


-- ============================================================================
-- 22. Profile BKPF-BVORG as cross-company evidence for blank-partner items.
--     A BVORG can involve more than two company codes. Only exactly two mapped
--     canonical company IDs yields a unique counterpart candidate, and even
--     that must be conflict-checked against master/application evidence.
-- ============================================================================
WITH params AS (
  SELECT DATE '2026-09-01' AS cutoff_exclusive,
         '010' AS mandt
),
account_scope AS (
  SELECT * FROM VALUES
    ('AR', '0010250000'),
    ('AP', '0020850000'),
    ('AP', '0020850001'),
    ('AP', '0020850003'),
    ('AP', '0020858000')
  AS t(item_class, hkont)
),
items AS (
  SELECT 'AR' AS item_class, MANDT, BUKRS, GJAHR, BELNR, BUZEI,
         HKONT, BUDAT, AUGDT, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END AS amount_dc
  FROM qlk_c.c_ocs_ecc_old.bsid
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
  UNION ALL
  SELECT 'AR', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT,
         AUGDT, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsad
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
  UNION ALL
  SELECT 'AP', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT,
         AUGDT, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsik
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
  UNION ALL
  SELECT 'AP', MANDT, BUKRS, GJAHR, BELNR, BUZEI, HKONT, BUDAT,
         AUGDT, VBUND, WAERS,
         CASE WHEN SHKZG = 'S' THEN WRBTR
              WHEN SHKZG = 'H' THEN -WRBTR END
  FROM qlk_c.c_ocs_ecc_old.bsak
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
),
blank_scoped AS (
  SELECT i.*
  FROM items i
  JOIN account_scope s
    ON s.item_class = i.item_class
   AND s.hkont = i.HKONT
  CROSS JOIN params p
  WHERE i.MANDT = p.mandt
    AND i.BUDAT < p.cutoff_exclusive
    AND TRIM(COALESCE(i.VBUND, '')) = ''
    AND (
      TRIM(COALESCE(CAST(i.AUGDT AS STRING), ''))
        IN ('', '00000000', '0001-01-01', '0101-01-01')
      OR TO_DATE(i.AUGDT) >= p.cutoff_exclusive
    )
),
target_transactions AS (
  SELECT i.*,
         NULLIF(TRIM(k.BVORG), '') AS bvorg
  FROM blank_scoped i
  JOIN qlk_c.c_ocs_ecc_old.bkpf k
    ON k.MANDT = i.MANDT
   AND k.BUKRS = i.BUKRS
   AND k.GJAHR = i.GJAHR
   AND k.BELNR = i.BELNR
   AND UPPER(COALESCE(k.hdr__oper, '')) <> 'D'
),
company_code_map AS (
  SELECT MANDT, BUKRS, MAX(NULLIF(TRIM(RCOMP), '')) AS company_id
  FROM qlk_c.c_ocs_ecc_old.t001
  WHERE UPPER(COALESCE(hdr__oper, '')) <> 'D'
    AND TRIM(COALESCE(RCOMP, '')) <> ''
  GROUP BY MANDT, BUKRS
  HAVING COUNT(DISTINCT NULLIF(TRIM(RCOMP), '')) = 1
),
bvorg_company_sets AS (
  SELECT t.MANDT, t.BUKRS, t.GJAHR, t.BELNR, t.BUZEI,
         COUNT(DISTINCT cm.company_id) AS company_id_count,
         COUNT(DISTINCT k2.BUKRS) AS company_code_count,
         COUNT(DISTINCT CASE
           WHEN cm.company_id <> owner_cm.company_id THEN cm.company_id
         END) AS other_company_id_count,
         MAX(CASE
           WHEN cm.company_id <> owner_cm.company_id THEN cm.company_id
         END) AS unique_other_company_when_count_one
  FROM target_transactions t
  LEFT JOIN company_code_map owner_cm
    ON owner_cm.MANDT = t.MANDT
   AND owner_cm.BUKRS = t.BUKRS
  LEFT JOIN qlk_c.c_ocs_ecc_old.bkpf k2
    ON t.bvorg IS NOT NULL
   AND k2.MANDT = t.MANDT
   AND TRIM(k2.BVORG) = t.bvorg
   AND UPPER(COALESCE(k2.hdr__oper, '')) <> 'D'
  LEFT JOIN company_code_map cm
    ON cm.MANDT = k2.MANDT
   AND cm.BUKRS = k2.BUKRS
  GROUP BY t.MANDT, t.BUKRS, t.GJAHR, t.BELNR, t.BUZEI
)
SELECT t.item_class,
       t.BUKRS,
       t.HKONT,
       t.WAERS,
       CASE
         WHEN t.bvorg IS NULL THEN 'NO_BVORG'
         WHEN COALESCE(s.company_id_count, 0) = 2
          AND COALESCE(s.other_company_id_count, 0) = 1
           THEN 'UNIQUE_BVORG_COUNTERPARTY_CANDIDATE'
         WHEN COALESCE(s.company_id_count, 0) > 2
           THEN 'MULTI_COMPANY_BVORG_AMBIGUOUS'
         WHEN COALESCE(s.company_code_count, 0) > 1
          AND COALESCE(s.company_id_count, 0) <= 1
           THEN 'MULTI_CODE_SAME_OR_UNMAPPED_COMPANY'
         ELSE 'BVORG_NOT_ENOUGH_MAPPED_EVIDENCE'
       END AS bvorg_evidence_class,
       COUNT(*) AS item_rows,
       SUM(t.amount_dc) AS signed_amount_dc,
       SUM(ABS(t.amount_dc)) AS gross_amount_dc
FROM target_transactions t
LEFT JOIN bvorg_company_sets s
  ON s.MANDT = t.MANDT
 AND s.BUKRS = t.BUKRS
 AND s.GJAHR = t.GJAHR
 AND s.BELNR = t.BELNR
 AND s.BUZEI = t.BUZEI
GROUP BY t.item_class, t.BUKRS, t.HKONT, t.WAERS,
         CASE
           WHEN t.bvorg IS NULL THEN 'NO_BVORG'
           WHEN COALESCE(s.company_id_count, 0) = 2
            AND COALESCE(s.other_company_id_count, 0) = 1
             THEN 'UNIQUE_BVORG_COUNTERPARTY_CANDIDATE'
           WHEN COALESCE(s.company_id_count, 0) > 2
             THEN 'MULTI_COMPANY_BVORG_AMBIGUOUS'
           WHEN COALESCE(s.company_code_count, 0) > 1
            AND COALESCE(s.company_id_count, 0) <= 1
             THEN 'MULTI_CODE_SAME_OR_UNMAPPED_COMPANY'
           ELSE 'BVORG_NOT_ENOUGH_MAPPED_EVIDENCE'
         END
ORDER BY t.item_class, t.BUKRS, t.HKONT, t.WAERS,
         bvorg_evidence_class;
