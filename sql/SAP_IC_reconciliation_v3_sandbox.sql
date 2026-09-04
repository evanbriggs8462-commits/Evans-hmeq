-- SAP intercompany reconciliation v3 - conservative ECC sandbox
-- Dialect: Databricks / Spark SQL
--
-- PURPOSE
--   Build an auditable AR/AP open-item reconciliation and a separate GR/IR
--   diagnostic sidecar without modifying any permanent object.
--
-- EXECUTION CONTRACT
--   1. Run every statement in this file, in order, in one Databricks SQL
--      session or notebook session.
--   2. Edit ic_v3_params and ic_v3_account_scope before each controlled run.
--   3. Inspect ic_v3_release_gate before publishing any result.
--   4. The controlled transaction-currency OOB is
--      ic_v3_pair_currency_summary.arap_net_dc only after the corresponding
--      product release status is eligible. Exceptions remain in the population
--      bridge and block certification. GR/IR is never added or subtracted.
--
-- SAFETY
--   This file creates TEMP VIEWs only. It does not write permanent data.
--   Current KNA1/LFA1 values are diagnostic-only and cannot be enabled by a
--   parameter switch. A governed effective-dated evidence rule is required.
--   FX multiplication is disabled until the quotation/factor contract for
--   r_ecc_forex_table has been approved by Finance.
--   Replicated hdr__oper NULL/blank is currently treated as an active row and
--   only literal D as deleted. Do not certify a source until each adapter's
--   CDC contract proves that convention plus current-state key uniqueness.

-- OPTIONAL ECC / S/4 DISCOVERY CATALOG (COMMENTS ONLY; NO DEPENDENCY BELOW)
--   Fields vary by SAP release and by the replication product. Verify each
--   object and column in Unity Catalog before designing an adapter. Never
--   SELECT * from these large objects for discovery.
--
--   Suggested zero-row UC probes (edit catalog/schema first):
--     -- SELECT table_name FROM system.information_schema.tables
--     -- WHERE table_catalog='qlk_c' AND table_schema='c_ocs_ecc_old'
--     --   AND LOWER(table_name) IN ('acdoca','bsis','bsas','faglflexa',
--     --     'fagl_splinfo','fagl_splinfo_val','ekbeh','ekbe_ma','ekkn',
--     --     'mkpf','mseg','matdoc','rbkp','rseg','rbco','icadocm');
--     -- SELECT table_name,column_name,data_type
--     -- FROM system.information_schema.columns
--     -- WHERE table_catalog='qlk_c' AND table_schema='c_ocs_ecc_old'
--     --   AND LOWER(table_name) IN (...) ORDER BY table_name,ordinal_position;
--
--   FI population / provenance
--   * BSIS + BSAS: ECC open/cleared G/L items. Look for MANDT, BUKRS,
--     GJAHR, BELNR, BUZEI, HKONT, BUDAT, AUGDT, SHKZG, WRBTR, DMBTR,
--     WAERS, VBUND, PRCTR, ZUONR. Candidate source for GR/IR or manual-GL
--     as-of positions only after open-item-management scope is certified.
--   * SKA1 + SKB1: KTOPL/SAKNR and BUKRS/HKONT, plus XBILK, MITKZ,
--     XOPVW/XLGCLR where available. Use to govern balance-sheet,
--     reconciliation-account and open-item account scope; not matching proof.
--   * BSEC: one-time customer/vendor detail keyed by FI document/item. Useful
--     exception enrichment; never infer a trading partner from a name alone.
--   * BKPF origin/reversal tuple: AWTYP, AWKEY, AWSYS, STBLG, STJAH, BVORG,
--     XBLNR. Parse AWKEY by AWTYP and namespace by AWSYS/source/client.
--   * BSEG invoice/reference fields: REBZG, REBZJ, REBZZ, XREF1, XREF2,
--     XREF3 plus KOART/HKONT/KUNNR/LIFNR/EBELN/EBELP. Native typed links are
--     stronger than free text, but still require reciprocal/cardinality tests.
--
--   S/4 accounting-model alternative (ADAPTER, NOT AN EXTRA UNION)
--   * ACDOCA or released I_GLAccountLineItemRawData/I_JournalEntryItem:
--     RLDNR, RBUKRS, GJAHR, BELNR, DOCLN, RACCT, RASSC, PRCTR, PPRCTR,
--     KUNNR, LIFNR, EBELN, EBELP and currency-type amount fields. Prefer for
--     S/4 ledger/trading-company/partner-profit-center reporting. Certify
--     ledger, currency type and ACDOCA-to-entry-view grain; ACDOCA and BSEG
--     are not assumed one-to-one and must not both feed the same value fact.
--   * ICADOCM: S/4 ICMR matching document, assignment/status, rule/reason and
--     cutoff fields. Potential governed result evidence only when the source,
--     matching method/version and roll-in completeness are pinned.
--
--   Native document-split / legacy profit-center alternatives
--   * FAGL_SPLINFO + FAGL_SPLINFO_VAL: FI document/item, split characteristic,
--     currency and value. Preferred ECC New-GL management allocation when
--     activation/history completeness and value conservation are proven.
--   * FAGLFLEXA (New GL) or GLPCA (classic PCA): ledger/company/year/document
--     keys, account, PRCTR/PPRCTR/RASSC and currency amounts. Build a separate
--     system adapter and reconcile to FI; do not join/union as BSEG line grain.
--   * CEPC/CEPCT and CSKS: KOKRS, PRCTR/KOSTL, DATAB/DATBI and descriptive
--     attributes. Good effective-dated dimension validation; not amount split
--     evidence by itself.
--
--   Entity / partner namespace
--   * T000 + T001 + T880: client logical-system context, BUKRS, RCOMP, WAERS,
--     KTOPL and company identifiers. RCOMP/VBUND is source-local; map it to a
--     dated canonical enterprise entity before matching different instances.
--   * KNA1/LFA1 VBUND; S/4 CVI_CUST_LINK/CVI_VEND_LINK + BUT000. Current
--     master values are candidate evidence only unless historically versioned
--     and proven one-to-one to the canonical entity.
--
--   GR/IR event and assignment lineage
--   * EKKO + EKPO: MANDT/EBELN/EBELP, company code, supplier, currency,
--     deletion/completion flags, GR-based invoice-verification and PO-item
--     attributes. Use for ownership/scope and diagnostics; a current PO row is
--     not proof of the coding or status that existed when an event posted.
--   * EKBE + EKBEH (or I_PurchaseOrderHistoryAPI01): EBELN, EBELP, ZEKKN,
--     VGABE, BEWTP, GJAHR, BELNR, BUZEI, BWART, SHKZG, BUDAT,
--     LFBNR/LFGJA/LFPOS, quantity and value/currency fields. Use a many-to-many
--     PO-item event ledger; VGABE alone is not a complete reversal/value rule.
--   * EKBE_MA + EKKN: EBELN, EBELP, ZEKKN and assignment distribution fields.
--     Needed before assignment-level GR/IR attribution; current EKKN ranks
--     below posted material/invoice/FI coding.
--   * ECC MKPF+MSEG versus S/4 MATDOC/I_MaterialDocumentItem_2: material
--     document year/number/item, PO/item, movement type, posting date and
--     reversal references. Choose the native model; never union MATDOC with
--     MSEG compatibility output.
--   * RBKP+RSEG (+RBCO when available): invoice year/number/item, PO/item,
--     ZEKKN, LFBNR/LFGJA/LFPOS, status and reversal fields. Typed native links
--     can prove provenance; shared PO/item/amount/date alone remains candidate.
--
--   SD-side AR provenance
--   * VBRK + VBRP + VBFA: billing header/item and predecessor/successor flow.
--     Useful for exact billing-to-FI/source references and cancellations;
--     many-to-many document flow must never be treated as a unique AR/AP pair.
--
--   Complete SAP FX contract, if the enterprise table is insufficient
--   * TCURR + TCURF + TCURN + TCURX: rate, factors, quotation/direction and
--     decimal shifts. TCURR alone is not a safe reporting-currency multiplier.

-- ============================================================================
-- 0. CONTROLLED RUN PARAMETERS
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_params AS
SELECT
  'OCS_ECC_OLD'                                      AS source_system_id,
  '010'                                              AS source_client,
  DATE '2026-08-31'                                  AS as_of_date,
  DATE '2026-09-01'                                  AS cutoff_exclusive,
  'USD'                                              AS reporting_currency,
  CAST(0.01 AS DECIMAL(38,6))                        AS exact_tolerance,
  'IC_V3_SANDBOX_2026_08_31'                         AS reconciliation_run_id,
  'IC_RULE_V3_0_0'                                   AS rule_version,
  'CURRENT_UNVERSIONED'                              AS profit_center_map_version,
  'CURRENT_UNVERSIONED'                              AS entity_map_version,
  'CURRENT_UNVERSIONED'                              AS fx_version,
  'NOT_CAPTURED'                                     AS source_snapshot_id,
  'SOURCE_LOCAL_ONLY'                                AS entity_resolution_mode,
  'PILOT_GLOBAL_NOT_EFFECTIVE_DATED'                 AS account_scope_governance,
  'NOT_CERTIFIED'                                    AS source_contract_certification_id,
  'TEMP_VIEW_SANDBOX'                                AS execution_mode,
  'NOT_IMPLEMENTED'                                  AS grir_event_rule_version,
  'NOT_IMPLEMENTED'                                  AS grir_value_basis_version,
  'NOT_IMPLEMENTED'                                  AS grir_reversal_rule_version,
  'NOT_IMPLEMENTED'                                  AS buyer_ap_completeness_contract,
  'NOT_IMPLEMENTED'                                  AS cross_system_lineage_version,
  FALSE                                              AS fx_multiplier_contract_approved;

-- Replace this inline pilot scope with an effective-dated governed table.
-- The original SQL labeled all AR rows 10250000 without filtering HKONT;
-- this scope corrects that defect. Confirm the AR account with Finance.
CREATE OR REPLACE TEMP VIEW ic_v3_account_scope AS
SELECT *
FROM VALUES
  ('OCS_ECC_OLD','010','*','AR_SUBLEDGER','AR','0010250000','OPEN_ITEM','AR_10250000_PILOT'),
  ('OCS_ECC_OLD','010','*','AP_SUBLEDGER','AP','0020850000','OPEN_ITEM','AP_20850000_PILOT'),
  ('OCS_ECC_OLD','010','*','AP_SUBLEDGER','AP','0020850001','OPEN_ITEM','AP_20850001_PILOT'),
  ('OCS_ECC_OLD','010','*','AP_SUBLEDGER','AP','0020850003','OPEN_ITEM','AP_20850003_PILOT'),
  ('OCS_ECC_OLD','010','*','AP_SUBLEDGER','AP','0020858000','OPEN_ITEM','AP_20858000_PILOT')
AS t(
  source_system_id,
  source_client,
  company_code,
  source_family,
  match_side,
  gl_account,
  position_semantics,
  scope_rule_id
);

CREATE OR REPLACE TEMP VIEW ic_v3_grir_account_scope AS
SELECT *
FROM VALUES
  ('OCS_ECC_OLD','010','*','0020110000','OPEN_ITEM','GRIR_20110000_PILOT')
AS t(source_system_id, source_client, company_code, gl_account,
     position_semantics, scope_rule_id);

-- Manual G/L IC accounts are deliberately not mixed into the subledger
-- snapshot until open-item-management or balance-from-inception semantics are
-- approved by account/company. They remain visible in a diagnostic view below.
CREATE OR REPLACE TEMP VIEW ic_v3_manual_account_scope AS
SELECT *
FROM VALUES
  ('OCS_ECC_OLD','010','0020850002','Z1','UNAPPROVED_POSITION_SEMANTICS'),
  ('OCS_ECC_OLD','010','0020850002','ME','UNAPPROVED_POSITION_SEMANTICS'),
  ('OCS_ECC_OLD','010','0020858002','Z1','UNAPPROVED_POSITION_SEMANTICS'),
  ('OCS_ECC_OLD','010','0020858002','ME','UNAPPROVED_POSITION_SEMANTICS')
AS t(source_system_id, source_client, gl_account, document_type, scope_status);

-- ============================================================================
-- 1. EXACT AR/AP SOURCE-ITEM SNAPSHOT
--    Native identity includes source system, SAP client and BUZEI.
--    Blank trading partners are retained.
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_item_physical AS
SELECT
  p.source_system_id,
  CAST(i.MANDT AS STRING)                             AS source_client,
  'AR_SUBLEDGER'                                     AS source_family,
  'BSID'                                             AS physical_source,
  s.match_side,
  s.scope_rule_id,
  CAST(i.BUKRS AS STRING)                            AS company_code,
  CAST(i.GJAHR AS STRING)                            AS fiscal_year,
  CAST(i.BELNR AS STRING)                            AS accounting_document,
  CAST(i.BUZEI AS STRING)                            AS line_item_number,
  CAST(i.HKONT AS STRING)                            AS gl_account,
  TRY_CAST(i.BUDAT AS DATE)                          AS posting_date,
  CASE
    WHEN TRIM(COALESCE(CAST(i.AUGDT AS STRING), ''))
         IN ('','00000000','0001-01-01','0101-01-01') THEN NULL
    ELSE TRY_CAST(i.AUGDT AS DATE)
  END                                                AS clearing_date,
  CASE
    WHEN TRIM(COALESCE(CAST(i.AUGDT AS STRING), ''))
         IN ('','00000000','0001-01-01','0101-01-01') THEN 'INITIAL'
    WHEN TRY_CAST(i.AUGDT AS DATE) IS NULL THEN 'INVALID'
    ELSE 'VALID'
  END                                                AS clearing_date_status,
  CASE WHEN TRIM(COALESCE(CAST(i.AUGBL AS STRING),'')) IN ('','0000000000')
       THEN NULL ELSE TRIM(CAST(i.AUGBL AS STRING)) END AS clearing_document,
  NULLIF(TRIM(CAST(i.ZUONR AS STRING)), '')           AS assignment_reference,
  NULLIF(TRIM(CAST(i.SGTXT AS STRING)), '')           AS item_text,
  NULLIF(TRIM(CAST(i.KUNNR AS STRING)), '')           AS customer_id,
  CAST(NULL AS STRING)                               AS vendor_id,
  NULLIF(TRIM(CAST(i.VBUND AS STRING)), '')           AS posted_partner_raw,
  NULLIF(UPPER(TRIM(CAST(i.WAERS AS STRING))),'')     AS document_currency,
  TRY_CAST(i.WRBTR AS DECIMAL(38,6))                 AS raw_amount_dc,
  TRY_CAST(i.DMBTR AS DECIMAL(38,6))                 AS raw_amount_lc,
  CASE
    WHEN TRY_CAST(i.WRBTR AS DECIMAL(38,6)) IS NULL
      OR TRY_CAST(i.DMBTR AS DECIMAL(38,6)) IS NULL
      THEN 'MISSING_OR_INVALID_RAW_AMOUNT'
    WHEN TRY_CAST(i.WRBTR AS DECIMAL(38,6))<0
      OR TRY_CAST(i.DMBTR AS DECIMAL(38,6))<0
      THEN 'NEGATIVE_RAW_AMOUNT'
    ELSE 'NONNEGATIVE_RAW_AMOUNT'
  END                                                AS raw_amount_status,
  CAST(CASE WHEN i.SHKZG='S' AND TRY_CAST(i.WRBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(i.WRBTR AS DECIMAL(38,6))
            WHEN i.SHKZG='H' AND TRY_CAST(i.WRBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(i.WRBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                       AS signed_amount_dc,
  CAST(CASE WHEN i.SHKZG='S' AND TRY_CAST(i.DMBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(i.DMBTR AS DECIMAL(38,6))
            WHEN i.SHKZG='H' AND TRY_CAST(i.DMBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(i.DMBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                       AS signed_amount_lc,
  CAST(i.SHKZG AS STRING)                            AS debit_credit_code,
  p.as_of_date,
  p.cutoff_exclusive,
  p.reconciliation_run_id,
  p.rule_version
FROM qlk_c.c_ocs_ecc_old.bsid i
CROSS JOIN ic_v3_params p
JOIN ic_v3_account_scope s
  ON s.source_system_id=p.source_system_id
 AND s.source_client=CAST(i.MANDT AS STRING)
 AND (s.company_code='*' OR s.company_code=CAST(i.BUKRS AS STRING))
 AND s.source_family='AR_SUBLEDGER'
 AND s.gl_account=CAST(i.HKONT AS STRING)
WHERE CAST(i.MANDT AS STRING)=p.source_client
  AND UPPER(COALESCE(i.hdr__oper,'')) <> 'D'
  AND (TRY_CAST(i.BUDAT AS DATE)<p.cutoff_exclusive
       OR TRY_CAST(i.BUDAT AS DATE) IS NULL)

UNION ALL

SELECT
  p.source_system_id, CAST(i.MANDT AS STRING),
  'AR_SUBLEDGER', 'BSAD', s.match_side, s.scope_rule_id,
  CAST(i.BUKRS AS STRING), CAST(i.GJAHR AS STRING),
  CAST(i.BELNR AS STRING), CAST(i.BUZEI AS STRING),
  CAST(i.HKONT AS STRING), TRY_CAST(i.BUDAT AS DATE),
  CASE WHEN TRIM(COALESCE(CAST(i.AUGDT AS STRING),''))
       IN ('','00000000','0001-01-01','0101-01-01') THEN NULL
       ELSE TRY_CAST(i.AUGDT AS DATE) END,
  CASE WHEN TRIM(COALESCE(CAST(i.AUGDT AS STRING),''))
       IN ('','00000000','0001-01-01','0101-01-01') THEN 'INITIAL'
       WHEN TRY_CAST(i.AUGDT AS DATE) IS NULL THEN 'INVALID' ELSE 'VALID' END,
  CASE WHEN TRIM(COALESCE(CAST(i.AUGBL AS STRING),'')) IN ('','0000000000')
       THEN NULL ELSE TRIM(CAST(i.AUGBL AS STRING)) END,
  NULLIF(TRIM(CAST(i.ZUONR AS STRING)), ''),
  NULLIF(TRIM(CAST(i.SGTXT AS STRING)), ''),
  NULLIF(TRIM(CAST(i.KUNNR AS STRING)), ''), CAST(NULL AS STRING),
  NULLIF(TRIM(CAST(i.VBUND AS STRING)), ''),
  NULLIF(UPPER(TRIM(CAST(i.WAERS AS STRING))),''),
  TRY_CAST(i.WRBTR AS DECIMAL(38,6)), TRY_CAST(i.DMBTR AS DECIMAL(38,6)),
  CASE WHEN TRY_CAST(i.WRBTR AS DECIMAL(38,6)) IS NULL
             OR TRY_CAST(i.DMBTR AS DECIMAL(38,6)) IS NULL
         THEN 'MISSING_OR_INVALID_RAW_AMOUNT'
       WHEN TRY_CAST(i.WRBTR AS DECIMAL(38,6))<0
             OR TRY_CAST(i.DMBTR AS DECIMAL(38,6))<0 THEN 'NEGATIVE_RAW_AMOUNT'
       ELSE 'NONNEGATIVE_RAW_AMOUNT' END,
  CAST(CASE WHEN i.SHKZG='S' AND TRY_CAST(i.WRBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(i.WRBTR AS DECIMAL(38,6))
            WHEN i.SHKZG='H' AND TRY_CAST(i.WRBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(i.WRBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6)),
  CAST(CASE WHEN i.SHKZG='S' AND TRY_CAST(i.DMBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(i.DMBTR AS DECIMAL(38,6))
            WHEN i.SHKZG='H' AND TRY_CAST(i.DMBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(i.DMBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6)),
  CAST(i.SHKZG AS STRING), p.as_of_date, p.cutoff_exclusive,
  p.reconciliation_run_id, p.rule_version
FROM qlk_c.c_ocs_ecc_old.bsad i
CROSS JOIN ic_v3_params p
JOIN ic_v3_account_scope s
  ON s.source_system_id=p.source_system_id
 AND s.source_client=CAST(i.MANDT AS STRING)
 AND (s.company_code='*' OR s.company_code=CAST(i.BUKRS AS STRING))
 AND s.source_family='AR_SUBLEDGER'
 AND s.gl_account=CAST(i.HKONT AS STRING)
WHERE CAST(i.MANDT AS STRING)=p.source_client
  AND UPPER(COALESCE(i.hdr__oper,'')) <> 'D'
  AND (TRY_CAST(i.BUDAT AS DATE)<p.cutoff_exclusive
       OR TRY_CAST(i.BUDAT AS DATE) IS NULL)

UNION ALL

SELECT
  p.source_system_id, CAST(i.MANDT AS STRING),
  'AP_SUBLEDGER', 'BSIK', s.match_side, s.scope_rule_id,
  CAST(i.BUKRS AS STRING), CAST(i.GJAHR AS STRING),
  CAST(i.BELNR AS STRING), CAST(i.BUZEI AS STRING),
  CAST(i.HKONT AS STRING), TRY_CAST(i.BUDAT AS DATE),
  CASE WHEN TRIM(COALESCE(CAST(i.AUGDT AS STRING),''))
       IN ('','00000000','0001-01-01','0101-01-01') THEN NULL
       ELSE TRY_CAST(i.AUGDT AS DATE) END,
  CASE WHEN TRIM(COALESCE(CAST(i.AUGDT AS STRING),''))
       IN ('','00000000','0001-01-01','0101-01-01') THEN 'INITIAL'
       WHEN TRY_CAST(i.AUGDT AS DATE) IS NULL THEN 'INVALID' ELSE 'VALID' END,
  CASE WHEN TRIM(COALESCE(CAST(i.AUGBL AS STRING),'')) IN ('','0000000000')
       THEN NULL ELSE TRIM(CAST(i.AUGBL AS STRING)) END,
  NULLIF(TRIM(CAST(i.ZUONR AS STRING)), ''),
  NULLIF(TRIM(CAST(i.SGTXT AS STRING)), ''),
  CAST(NULL AS STRING), NULLIF(TRIM(CAST(i.LIFNR AS STRING)), ''),
  NULLIF(TRIM(CAST(i.VBUND AS STRING)), ''),
  NULLIF(UPPER(TRIM(CAST(i.WAERS AS STRING))),''),
  TRY_CAST(i.WRBTR AS DECIMAL(38,6)), TRY_CAST(i.DMBTR AS DECIMAL(38,6)),
  CASE WHEN TRY_CAST(i.WRBTR AS DECIMAL(38,6)) IS NULL
             OR TRY_CAST(i.DMBTR AS DECIMAL(38,6)) IS NULL
         THEN 'MISSING_OR_INVALID_RAW_AMOUNT'
       WHEN TRY_CAST(i.WRBTR AS DECIMAL(38,6))<0
             OR TRY_CAST(i.DMBTR AS DECIMAL(38,6))<0 THEN 'NEGATIVE_RAW_AMOUNT'
       ELSE 'NONNEGATIVE_RAW_AMOUNT' END,
  CAST(CASE WHEN i.SHKZG='S' AND TRY_CAST(i.WRBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(i.WRBTR AS DECIMAL(38,6))
            WHEN i.SHKZG='H' AND TRY_CAST(i.WRBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(i.WRBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6)),
  CAST(CASE WHEN i.SHKZG='S' AND TRY_CAST(i.DMBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(i.DMBTR AS DECIMAL(38,6))
            WHEN i.SHKZG='H' AND TRY_CAST(i.DMBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(i.DMBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6)),
  CAST(i.SHKZG AS STRING), p.as_of_date, p.cutoff_exclusive,
  p.reconciliation_run_id, p.rule_version
FROM qlk_c.c_ocs_ecc_old.bsik i
CROSS JOIN ic_v3_params p
JOIN ic_v3_account_scope s
  ON s.source_system_id=p.source_system_id
 AND s.source_client=CAST(i.MANDT AS STRING)
 AND (s.company_code='*' OR s.company_code=CAST(i.BUKRS AS STRING))
 AND s.source_family='AP_SUBLEDGER'
 AND s.gl_account=CAST(i.HKONT AS STRING)
WHERE CAST(i.MANDT AS STRING)=p.source_client
  AND UPPER(COALESCE(i.hdr__oper,'')) <> 'D'
  AND (TRY_CAST(i.BUDAT AS DATE)<p.cutoff_exclusive
       OR TRY_CAST(i.BUDAT AS DATE) IS NULL)

UNION ALL

SELECT
  p.source_system_id, CAST(i.MANDT AS STRING),
  'AP_SUBLEDGER', 'BSAK', s.match_side, s.scope_rule_id,
  CAST(i.BUKRS AS STRING), CAST(i.GJAHR AS STRING),
  CAST(i.BELNR AS STRING), CAST(i.BUZEI AS STRING),
  CAST(i.HKONT AS STRING), TRY_CAST(i.BUDAT AS DATE),
  CASE WHEN TRIM(COALESCE(CAST(i.AUGDT AS STRING),''))
       IN ('','00000000','0001-01-01','0101-01-01') THEN NULL
       ELSE TRY_CAST(i.AUGDT AS DATE) END,
  CASE WHEN TRIM(COALESCE(CAST(i.AUGDT AS STRING),''))
       IN ('','00000000','0001-01-01','0101-01-01') THEN 'INITIAL'
       WHEN TRY_CAST(i.AUGDT AS DATE) IS NULL THEN 'INVALID' ELSE 'VALID' END,
  CASE WHEN TRIM(COALESCE(CAST(i.AUGBL AS STRING),'')) IN ('','0000000000')
       THEN NULL ELSE TRIM(CAST(i.AUGBL AS STRING)) END,
  NULLIF(TRIM(CAST(i.ZUONR AS STRING)), ''),
  NULLIF(TRIM(CAST(i.SGTXT AS STRING)), ''),
  CAST(NULL AS STRING), NULLIF(TRIM(CAST(i.LIFNR AS STRING)), ''),
  NULLIF(TRIM(CAST(i.VBUND AS STRING)), ''),
  NULLIF(UPPER(TRIM(CAST(i.WAERS AS STRING))),''),
  TRY_CAST(i.WRBTR AS DECIMAL(38,6)), TRY_CAST(i.DMBTR AS DECIMAL(38,6)),
  CASE WHEN TRY_CAST(i.WRBTR AS DECIMAL(38,6)) IS NULL
             OR TRY_CAST(i.DMBTR AS DECIMAL(38,6)) IS NULL
         THEN 'MISSING_OR_INVALID_RAW_AMOUNT'
       WHEN TRY_CAST(i.WRBTR AS DECIMAL(38,6))<0
             OR TRY_CAST(i.DMBTR AS DECIMAL(38,6))<0 THEN 'NEGATIVE_RAW_AMOUNT'
       ELSE 'NONNEGATIVE_RAW_AMOUNT' END,
  CAST(CASE WHEN i.SHKZG='S' AND TRY_CAST(i.WRBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(i.WRBTR AS DECIMAL(38,6))
            WHEN i.SHKZG='H' AND TRY_CAST(i.WRBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(i.WRBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6)),
  CAST(CASE WHEN i.SHKZG='S' AND TRY_CAST(i.DMBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(i.DMBTR AS DECIMAL(38,6))
            WHEN i.SHKZG='H' AND TRY_CAST(i.DMBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(i.DMBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6)),
  CAST(i.SHKZG AS STRING), p.as_of_date, p.cutoff_exclusive,
  p.reconciliation_run_id, p.rule_version
FROM qlk_c.c_ocs_ecc_old.bsak i
CROSS JOIN ic_v3_params p
JOIN ic_v3_account_scope s
  ON s.source_system_id=p.source_system_id
 AND s.source_client=CAST(i.MANDT AS STRING)
 AND (s.company_code='*' OR s.company_code=CAST(i.BUKRS AS STRING))
 AND s.source_family='AP_SUBLEDGER'
 AND s.gl_account=CAST(i.HKONT AS STRING)
WHERE CAST(i.MANDT AS STRING)=p.source_client
  AND UPPER(COALESCE(i.hdr__oper,'')) <> 'D'
  AND (TRY_CAST(i.BUDAT AS DATE)<p.cutoff_exclusive
       OR TRY_CAST(i.BUDAT AS DATE) IS NULL);

-- Rows with an invalid posting date cannot be placed on either side of the
-- cutoff. Retain them here and fail the release instead of letting SQL NULL
-- comparison silently remove them.
CREATE OR REPLACE TEMP VIEW ic_v3_item_native_key_quarantine AS
SELECT
  source_system_id, source_client, source_family, physical_source,
  company_code, fiscal_year, accounting_document, line_item_number,
  gl_account, posting_date, document_currency,
  raw_amount_dc, raw_amount_lc, raw_amount_status, signed_amount_dc,
  'NULL_OR_BLANK_NATIVE_KEY_COMPONENT'                AS quarantine_reason,
  as_of_date, cutoff_exclusive, reconciliation_run_id
FROM ic_v3_item_physical
WHERE NULLIF(TRIM(source_system_id),'') IS NULL
   OR NULLIF(TRIM(source_client),'') IS NULL
   OR NULLIF(TRIM(company_code),'') IS NULL
   OR NULLIF(TRIM(fiscal_year),'') IS NULL
   OR NULLIF(TRIM(accounting_document),'') IS NULL
   OR NULLIF(TRIM(line_item_number),'') IS NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_item_normalized AS
SELECT
  source_system_id, source_client, source_family, physical_source,
  match_side, scope_rule_id, company_code, fiscal_year,
  accounting_document, line_item_number, gl_account, posting_date,
  clearing_date, clearing_date_status, clearing_document,
  CASE
    WHEN physical_source IN ('BSID','BSIK')
     AND clearing_date_status='INITIAL' AND clearing_document IS NULL
      THEN 'OPEN_INDEX_LIFECYCLE_CONSISTENT'
    WHEN physical_source IN ('BSID','BSIK')
      THEN 'OPEN_INDEX_HAS_CLEARING_EVIDENCE'
    WHEN physical_source IN ('BSAD','BSAK') AND clearing_date_status='INVALID'
      THEN 'CLEARED_INDEX_INVALID_CLEARING_DATE'
    WHEN physical_source IN ('BSAD','BSAK') AND clearing_date_status='INITIAL'
      THEN 'CLEARED_INDEX_MISSING_CLEARING_DATE'
    WHEN physical_source IN ('BSAD','BSAK') AND clearing_document IS NULL
      THEN 'CLEARED_INDEX_MISSING_CLEARING_DOCUMENT'
    WHEN physical_source IN ('BSAD','BSAK') AND posting_date IS NULL
      THEN 'CLEARED_INDEX_POSTING_DATE_UNAVAILABLE'
    WHEN physical_source IN ('BSAD','BSAK') AND clearing_date<posting_date
      THEN 'CLEARED_INDEX_CLEARING_BEFORE_POSTING'
    WHEN physical_source IN ('BSAD','BSAK') AND clearing_date_status='VALID'
      THEN 'CLEARED_INDEX_LIFECYCLE_CONSISTENT'
    ELSE 'SOURCE_INDEX_LIFECYCLE_INVALID'
  END                                                AS source_lifecycle_status,
  assignment_reference, item_text, customer_id, vendor_id,
  posted_partner_raw, document_currency,
  raw_amount_dc, raw_amount_lc, raw_amount_status,
  signed_amount_dc, signed_amount_lc, debit_credit_code,
  as_of_date, cutoff_exclusive,
  reconciliation_run_id, rule_version,
  SHA2(CONCAT_WS('||',
       CONCAT('source_system=',COALESCE(source_system_id,'<NULL>')),
       CONCAT('client=',COALESCE(source_client,'<NULL>')),
       CONCAT('company=',COALESCE(company_code,'<NULL>')),
       CONCAT('fiscal_year=',COALESCE(fiscal_year,'<NULL>')),
       CONCAT('document=',COALESCE(accounting_document,'<NULL>')),
       CONCAT('line=',COALESCE(line_item_number,'<NULL>'))),256)
                                                      AS source_item_id,
  SHA2(TO_JSON(NAMED_STRUCT(
       'family',source_family,'side',match_side,'scope_rule',scope_rule_id,
       'account',gl_account,
       'posting_date',posting_date,'clearing_date',clearing_date,
       'clearing_status',clearing_date_status,
       'clearing_document',clearing_document,
       'source_lifecycle_status',CASE
         WHEN physical_source IN ('BSID','BSIK')
          AND clearing_date_status='INITIAL' AND clearing_document IS NULL
           THEN 'OPEN_INDEX_LIFECYCLE_CONSISTENT'
         WHEN physical_source IN ('BSID','BSIK')
           THEN 'OPEN_INDEX_HAS_CLEARING_EVIDENCE'
         WHEN physical_source IN ('BSAD','BSAK') AND clearing_date_status='INVALID'
           THEN 'CLEARED_INDEX_INVALID_CLEARING_DATE'
         WHEN physical_source IN ('BSAD','BSAK') AND clearing_date_status='INITIAL'
           THEN 'CLEARED_INDEX_MISSING_CLEARING_DATE'
         WHEN physical_source IN ('BSAD','BSAK') AND clearing_document IS NULL
           THEN 'CLEARED_INDEX_MISSING_CLEARING_DOCUMENT'
         WHEN physical_source IN ('BSAD','BSAK') AND posting_date IS NULL
           THEN 'CLEARED_INDEX_POSTING_DATE_UNAVAILABLE'
         WHEN physical_source IN ('BSAD','BSAK') AND clearing_date<posting_date
           THEN 'CLEARED_INDEX_CLEARING_BEFORE_POSTING'
         WHEN physical_source IN ('BSAD','BSAK') AND clearing_date_status='VALID'
           THEN 'CLEARED_INDEX_LIFECYCLE_CONSISTENT'
         ELSE 'SOURCE_INDEX_LIFECYCLE_INVALID' END,
       'assignment',assignment_reference,'item_text',item_text,
       'customer',customer_id,
       'vendor',vendor_id,'partner',posted_partner_raw,
       'currency',document_currency,
       'raw_amount_dc',raw_amount_dc,'raw_amount_lc',raw_amount_lc,
       'raw_amount_status',raw_amount_status,
       'amount_dc',signed_amount_dc,'amount_lc',signed_amount_lc,
       'debit_credit_code',debit_credit_code)),256)    AS source_payload_hash
FROM ic_v3_item_physical
WHERE NULLIF(TRIM(source_system_id),'') IS NOT NULL
  AND NULLIF(TRIM(source_client),'') IS NOT NULL
  AND NULLIF(TRIM(company_code),'') IS NOT NULL
  AND NULLIF(TRIM(fiscal_year),'') IS NOT NULL
  AND NULLIF(TRIM(accounting_document),'') IS NOT NULL
  AND NULLIF(TRIM(line_item_number),'') IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_item_preasof_quarantine AS
SELECT
  source_item_id, source_system_id, source_client, source_family,
  physical_source, company_code, fiscal_year, accounting_document,
  line_item_number, gl_account, posting_date, clearing_date,
  clearing_date_status, source_lifecycle_status,
  posted_partner_raw, document_currency,
  raw_amount_dc, raw_amount_lc, raw_amount_status,
  signed_amount_dc, signed_amount_lc, debit_credit_code,
  'INVALID_OR_NULL_POSTING_DATE'                     AS quarantine_reason,
  as_of_date, cutoff_exclusive, reconciliation_run_id
FROM ic_v3_item_normalized
WHERE posting_date IS NULL;

-- Apply only the posting cutoff before lifecycle-copy control. Clearing-state
-- filtering happens later, so a stale open copy cannot hide a cleared copy.
CREATE OR REPLACE TEMP VIEW ic_v3_item_cutoff_candidate AS
SELECT
  source_system_id, source_client, source_family, physical_source,
  match_side, scope_rule_id, company_code, fiscal_year,
  accounting_document, line_item_number, gl_account, posting_date,
  clearing_date, clearing_date_status, clearing_document,
  source_lifecycle_status,
  assignment_reference, item_text, customer_id, vendor_id,
  posted_partner_raw, document_currency,
  raw_amount_dc, raw_amount_lc, raw_amount_status,
  signed_amount_dc, signed_amount_lc, debit_credit_code,
  as_of_date, cutoff_exclusive,
  reconciliation_run_id, rule_version, source_item_id, source_payload_hash
FROM ic_v3_item_normalized
WHERE posting_date<cutoff_exclusive;

CREATE OR REPLACE TEMP VIEW ic_v3_source_key_control AS
SELECT
  source_item_id,
  COUNT(*)                                           AS physical_copy_count,
  COUNT(DISTINCT source_payload_hash)                AS distinct_payload_count,
  COUNT(DISTINCT physical_source)                    AS physical_source_count,
  SUM(CASE
    WHEN COALESCE(source_lifecycle_status,'MISSING_SOURCE_LIFECYCLE_STATUS')
         NOT IN (
           'OPEN_INDEX_LIFECYCLE_CONSISTENT',
           'CLEARED_INDEX_LIFECYCLE_CONSISTENT')
      OR clearing_date_status='INITIAL'
      OR clearing_date>=cutoff_exclusive
      OR clearing_date_status='INVALID'
      OR clearing_date IS NULL
      OR COALESCE(clearing_date_status,'MISSING_CLEARING_DATE_STATUS')
           NOT IN ('INITIAL','VALID','INVALID')
    THEN 1 ELSE 0 END)                              AS asof_candidate_copy_count,
  CAST(SUM(signed_amount_dc) AS DECIMAL(38,6))       AS physical_signed_amount_dc,
  CAST(SUM(ABS(signed_amount_dc)) AS DECIMAL(38,6))  AS physical_gross_amount_dc,
  CASE
    WHEN COUNT(*)=1 AND COUNT(DISTINCT source_payload_hash)=1 THEN 'PASS'
    WHEN COUNT(DISTINCT source_payload_hash)=1
      THEN 'FAIL_DUPLICATE_PHYSICAL_COPY'
    ELSE 'FAIL_CONFLICTING_SOURCE_PAYLOADS'
  END                                                AS source_key_status
FROM ic_v3_item_cutoff_candidate
GROUP BY source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_item_asof_physical AS
SELECT
  c.source_system_id, c.source_client, c.source_family, c.physical_source,
  c.match_side, c.scope_rule_id, c.company_code, c.fiscal_year,
  c.accounting_document, c.line_item_number, c.gl_account, c.posting_date,
  c.clearing_date, c.clearing_date_status, c.clearing_document,
  c.source_lifecycle_status,
  c.assignment_reference, c.item_text, c.customer_id, c.vendor_id,
  c.posted_partner_raw, c.document_currency,
  c.raw_amount_dc, c.raw_amount_lc, c.raw_amount_status,
  c.signed_amount_dc, c.signed_amount_lc, c.debit_credit_code,
  c.as_of_date, c.cutoff_exclusive,
  c.reconciliation_run_id, c.rule_version,
  c.source_item_id, c.source_payload_hash
FROM ic_v3_item_cutoff_candidate c
WHERE c.clearing_date_status='INITIAL'
   OR c.clearing_date>=c.cutoff_exclusive
   OR c.clearing_date_status='INVALID'
   OR c.clearing_date IS NULL
   OR COALESCE(c.clearing_date_status,'MISSING_CLEARING_DATE_STATUS')
        NOT IN ('INITIAL','VALID','INVALID')
   OR COALESCE(c.source_lifecycle_status,'MISSING_SOURCE_LIFECYCLE_STATUS')
      NOT IN (
        'OPEN_INDEX_LIFECYCLE_CONSISTENT',
        'CLEARED_INDEX_LIFECYCLE_CONSISTENT');

-- Conflicting copies are not guessed away. This is the quarantine surface.
CREATE OR REPLACE TEMP VIEW ic_v3_item_quarantine AS
SELECT
  p.source_item_id, p.source_system_id, p.source_client,
  p.physical_source, p.source_family, p.match_side, p.company_code,
  p.fiscal_year, p.accounting_document, p.line_item_number,
  p.gl_account, p.posting_date, p.clearing_date,
  p.clearing_date_status, p.source_lifecycle_status,
  p.posted_partner_raw, p.document_currency,
  p.raw_amount_dc, p.raw_amount_lc, p.raw_amount_status,
  p.signed_amount_dc, p.signed_amount_lc, p.source_payload_hash,
  c.physical_copy_count, c.distinct_payload_count,
  c.asof_candidate_copy_count, c.source_key_status,
  p.as_of_date, p.cutoff_exclusive, p.reconciliation_run_id
FROM ic_v3_item_cutoff_candidate p
JOIN ic_v3_source_key_control c
  ON c.source_item_id=p.source_item_id
WHERE COALESCE(c.source_key_status,'FAIL_SOURCE_KEY_STATUS_MISSING')<>'PASS'
  AND c.asof_candidate_copy_count>0;

-- source_key_control requires exactly one physical row. DISTINCT is defensive;
-- it is not an authorized duplicate-collapse policy.
CREATE OR REPLACE TEMP VIEW ic_v3_item_base AS
SELECT DISTINCT
  p.source_item_id, p.source_system_id, p.source_client,
  p.source_family, p.match_side, p.scope_rule_id, p.company_code,
  p.fiscal_year, p.accounting_document, p.line_item_number,
  p.gl_account, p.posting_date, p.clearing_date,
  p.clearing_date_status, p.clearing_document,
  p.source_lifecycle_status,
  p.assignment_reference, p.item_text, p.customer_id, p.vendor_id,
  p.posted_partner_raw, p.document_currency,
  p.raw_amount_dc, p.raw_amount_lc, p.raw_amount_status,
  p.signed_amount_dc, p.signed_amount_lc, p.debit_credit_code,
  p.as_of_date, p.cutoff_exclusive, p.reconciliation_run_id,
  p.rule_version, p.source_payload_hash,
  c.physical_copy_count, c.physical_source_count
FROM ic_v3_item_asof_physical p
JOIN ic_v3_source_key_control c
  ON c.source_item_id=p.source_item_id
WHERE c.source_key_status='PASS';

-- ============================================================================
-- 2. HEADER AND LEGAL-ENTITY CONTROLS
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_item_header_raw AS
SELECT
  i.source_system_id, i.source_client, i.company_code, i.fiscal_year,
  i.accounting_document,
  NULLIF(TRIM(CAST(h.BVORG AS STRING)), '')            AS cross_company_reference,
  NULLIF(TRIM(CAST(h.BLART AS STRING)), '')            AS document_type,
  NULLIF(TRIM(CAST(h.BKTXT AS STRING)), '')            AS header_text,
  NULLIF(TRIM(CAST(h.STBLG AS STRING)), '')            AS reversal_document,
  TRY_CAST(h.BUDAT AS DATE)                           AS header_posting_date,
  NULLIF(UPPER(TRIM(CAST(h.WAERS AS STRING))),'')     AS header_currency,
  SHA2(TO_JSON(NAMED_STRUCT(
    'bvorg',NULLIF(TRIM(CAST(h.BVORG AS STRING)),''),
    'blart',NULLIF(TRIM(CAST(h.BLART AS STRING)),''),
    'bktxt',NULLIF(TRIM(CAST(h.BKTXT AS STRING)),''),
    'budat',TRY_CAST(h.BUDAT AS DATE),
    'waers',NULLIF(UPPER(TRIM(CAST(h.WAERS AS STRING))),''),
    'stblg',NULLIF(TRIM(CAST(h.STBLG AS STRING)),''))),256)
                                                      AS header_payload_hash
FROM (
  SELECT DISTINCT source_system_id, source_client, company_code,
         fiscal_year, accounting_document
  FROM ic_v3_item_base
) i
JOIN qlk_c.c_ocs_ecc_old.bkpf h
  ON CAST(h.MANDT AS STRING)=i.source_client
 AND CAST(h.BUKRS AS STRING)=i.company_code
 AND CAST(h.GJAHR AS STRING)=i.fiscal_year
 AND CAST(h.BELNR AS STRING)=i.accounting_document
 AND UPPER(COALESCE(h.hdr__oper,'')) <> 'D';

CREATE OR REPLACE TEMP VIEW ic_v3_item_header_control AS
SELECT
  source_system_id, source_client, company_code, fiscal_year,
  accounting_document,
  COUNT(*)                                           AS header_physical_count,
  COUNT(DISTINCT header_payload_hash)                AS header_payload_count,
  CASE
    WHEN COUNT(*)=1 AND COUNT(DISTINCT header_payload_hash)=1 THEN 'RESOLVED'
    WHEN COUNT(DISTINCT header_payload_hash)=1 THEN 'DUPLICATE_PHYSICAL_HEADER'
    ELSE 'CONFLICT'
  END                                                AS header_status
FROM ic_v3_item_header_raw
GROUP BY source_system_id, source_client, company_code, fiscal_year,
         accounting_document;

CREATE OR REPLACE TEMP VIEW ic_v3_item_header_unique AS
SELECT DISTINCT
  r.source_system_id, r.source_client, r.company_code, r.fiscal_year,
  r.accounting_document, r.cross_company_reference, r.document_type,
  r.header_text, r.reversal_document, r.header_posting_date,
  r.header_currency
FROM ic_v3_item_header_raw r
JOIN ic_v3_item_header_control c
  ON c.source_system_id=r.source_system_id
 AND c.source_client=r.source_client
 AND c.company_code=r.company_code
 AND c.fiscal_year=r.fiscal_year
 AND c.accounting_document=r.accounting_document
WHERE c.header_status='RESOLVED';

CREATE OR REPLACE TEMP VIEW ic_v3_company_map_control AS
SELECT
  p.source_system_id,
  CAST(t.MANDT AS STRING)                            AS source_client,
  CAST(t.BUKRS AS STRING)                            AS company_code,
  COUNT(DISTINCT NULLIF(UPPER(TRIM(CAST(t.RCOMP AS STRING))),''))
                                                      AS company_entity_count,
  CASE
    WHEN COUNT(DISTINCT NULLIF(UPPER(TRIM(CAST(t.RCOMP AS STRING))),''))=1
      THEN MIN(NULLIF(UPPER(TRIM(CAST(t.RCOMP AS STRING))),''))
  END                                                AS sole_company_entity_id,
  MIN(NULLIF(TRIM(CAST(t.BUTXT AS STRING)),''))       AS company_name,
  MIN(NULLIF(TRIM(CAST(t.LAND1 AS STRING)),''))       AS company_country,
  CASE
    WHEN COUNT(DISTINCT NULLIF(UPPER(TRIM(CAST(t.RCOMP AS STRING))),''))=1
      THEN 'RESOLVED_SOURCE_LOCAL_ENTITY'
    WHEN COUNT(DISTINCT NULLIF(UPPER(TRIM(CAST(t.RCOMP AS STRING))),''))=0
      THEN 'UNRESOLVED_NO_RCOMP'
    ELSE 'AMBIGUOUS_RCOMP'
  END                                                AS owner_entity_status
FROM qlk_c.c_ocs_ecc_old.t001 t
CROSS JOIN ic_v3_params p
WHERE CAST(t.MANDT AS STRING)=p.source_client
  AND UPPER(COALESCE(t.hdr__oper,'')) <> 'D'
GROUP BY p.source_system_id, CAST(t.MANDT AS STRING), CAST(t.BUKRS AS STRING);

CREATE OR REPLACE TEMP VIEW ic_v3_item_legal_base AS
SELECT
  i.source_item_id, i.source_system_id, i.source_client,
  i.source_family, i.match_side, i.scope_rule_id, i.company_code,
  i.fiscal_year, i.accounting_document, i.line_item_number,
  i.gl_account, i.posting_date, i.clearing_date,
  i.clearing_date_status, i.clearing_document,
  i.source_lifecycle_status,
  i.assignment_reference, i.item_text, i.customer_id, i.vendor_id,
  i.posted_partner_raw, i.document_currency,
  i.raw_amount_dc, i.raw_amount_lc, i.raw_amount_status,
  i.signed_amount_dc, i.signed_amount_lc, i.debit_credit_code,
  i.as_of_date, i.cutoff_exclusive, i.reconciliation_run_id,
  i.rule_version, i.source_payload_hash,
  i.physical_copy_count, i.physical_source_count,
  h.cross_company_reference, h.document_type, h.header_text,
  h.reversal_document,
  CASE
    WHEN h.accounting_document IS NULL THEN 'MISSING_OR_CONFLICTING'
    WHEN h.header_posting_date IS NULL THEN 'HEADER_POSTING_DATE_INVALID'
    WHEN h.header_posting_date<>i.posting_date THEN 'HEADER_POSTING_DATE_MISMATCH'
    WHEN h.header_currency IS NULL OR TRIM(h.header_currency)=''
      THEN 'HEADER_CURRENCY_INVALID'
    WHEN UPPER(TRIM(h.header_currency))<>UPPER(TRIM(i.document_currency))
      THEN 'HEADER_CURRENCY_MISMATCH'
    ELSE 'RESOLVED'
  END                                                AS header_status,
  c.sole_company_entity_id                           AS owner_entity_id,
  COALESCE(c.owner_entity_status,'UNRESOLVED_COMPANY_CODE')
                                                      AS owner_entity_status,
  c.company_name, c.company_country
FROM ic_v3_item_base i
LEFT JOIN ic_v3_item_header_unique h
  ON h.source_system_id=i.source_system_id
 AND h.source_client=i.source_client
 AND h.company_code=i.company_code
 AND h.fiscal_year=i.fiscal_year
 AND h.accounting_document=i.accounting_document
LEFT JOIN ic_v3_company_map_control c
  ON c.source_system_id=i.source_system_id
 AND c.source_client=i.source_client
 AND c.company_code=i.company_code;

-- ============================================================================
-- 3. PARTNER EVIDENCE AND RESOLUTION
--    Evidence is atomic. No MAX/MIN value is used to choose among candidates.
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_customer_partner_candidate AS
SELECT DISTINCT
  p.source_system_id, CAST(k.MANDT AS STRING) AS source_client,
  CAST(k.KUNNR AS STRING) AS customer_id,
  NULLIF(UPPER(TRIM(CAST(k.VBUND AS STRING))), '')    AS candidate_partner_entity_id
FROM qlk_c.c_ocs_ecc_old.kna1 k
CROSS JOIN ic_v3_params p
WHERE CAST(k.MANDT AS STRING)=p.source_client
  AND UPPER(COALESCE(k.hdr__oper,'')) <> 'D'
  AND NULLIF(TRIM(CAST(k.VBUND AS STRING)),'') IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_customer_partner_control AS
SELECT
  source_system_id, source_client, customer_id,
  COUNT(DISTINCT candidate_partner_entity_id)        AS candidate_count,
  CASE WHEN COUNT(DISTINCT candidate_partner_entity_id)=1
       THEN MIN(candidate_partner_entity_id) END     AS sole_candidate
FROM ic_v3_customer_partner_candidate
GROUP BY source_system_id, source_client, customer_id;

CREATE OR REPLACE TEMP VIEW ic_v3_vendor_partner_candidate AS
SELECT DISTINCT
  p.source_system_id, CAST(v.MANDT AS STRING) AS source_client,
  CAST(v.LIFNR AS STRING) AS vendor_id,
  NULLIF(UPPER(TRIM(CAST(v.VBUND AS STRING))), '')    AS candidate_partner_entity_id
FROM qlk_c.c_ocs_ecc_old.lfa1 v
CROSS JOIN ic_v3_params p
WHERE CAST(v.MANDT AS STRING)=p.source_client
  AND UPPER(COALESCE(v.hdr__oper,'')) <> 'D'
  AND NULLIF(TRIM(CAST(v.VBUND AS STRING)),'') IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_vendor_partner_control AS
SELECT
  source_system_id, source_client, vendor_id,
  COUNT(DISTINCT candidate_partner_entity_id)        AS candidate_count,
  CASE WHEN COUNT(DISTINCT candidate_partner_entity_id)=1
       THEN MIN(candidate_partner_entity_id) END     AS sole_candidate
FROM ic_v3_vendor_partner_candidate
GROUP BY source_system_id, source_client, vendor_id;

CREATE OR REPLACE TEMP VIEW ic_v3_same_document_partner AS
SELECT DISTINCT
  i.source_item_id,
  NULLIF(UPPER(TRIM(CAST(b.VBUND AS STRING))), '')    AS candidate_partner_entity_id
FROM ic_v3_item_legal_base i
JOIN qlk_c.c_ocs_ecc_old.bseg b
  ON CAST(b.MANDT AS STRING)=i.source_client
 AND CAST(b.BUKRS AS STRING)=i.company_code
 AND CAST(b.GJAHR AS STRING)=i.fiscal_year
 AND CAST(b.BELNR AS STRING)=i.accounting_document
 AND UPPER(COALESCE(b.hdr__oper,'')) <> 'D'
WHERE NULLIF(UPPER(TRIM(CAST(b.VBUND AS STRING))), '') IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_bvorg_partner AS
SELECT DISTINCT
  a.source_item_id,
  b.owner_entity_id                                  AS candidate_partner_entity_id
FROM ic_v3_item_legal_base a
JOIN ic_v3_item_legal_base b
  ON b.source_system_id=a.source_system_id
 AND b.source_client=a.source_client
 AND b.cross_company_reference=a.cross_company_reference
 AND b.source_item_id<>a.source_item_id
 AND b.owner_entity_id<>a.owner_entity_id
WHERE a.cross_company_reference IS NOT NULL
  AND a.owner_entity_id IS NOT NULL
  AND b.owner_entity_id IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_partner_evidence AS
SELECT
  i.source_item_id,
  SHA2(CONCAT_WS('||',i.source_item_id,'POSTED_LINE',
       UPPER(TRIM(i.posted_partner_raw))),256)        AS evidence_id,
  'POSTED_LINE'                                      AS evidence_type,
  10                                                 AS evidence_tier,
  UPPER(TRIM(i.posted_partner_raw))                  AS candidate_partner_entity_id,
  TRUE                                               AS automation_eligible,
  TRUE                                               AS authoritative,
  'POSTED_ON_EXACT_SUBLEDGER_ITEM'                   AS evidence_quality
FROM ic_v3_item_legal_base i
WHERE NULLIF(TRIM(i.posted_partner_raw),'') IS NOT NULL

UNION ALL

SELECT
  i.source_item_id,
  SHA2(CONCAT_WS('||',i.source_item_id,'BVORG',b.candidate_partner_entity_id),256),
  'CROSS_COMPANY_REFERENCE', 20, b.candidate_partner_entity_id,
  FALSE, FALSE, 'SOURCE_SCOPED_BVORG_DIAGNOSTIC_ONLY'
FROM ic_v3_item_legal_base i
JOIN ic_v3_bvorg_partner b ON b.source_item_id=i.source_item_id

UNION ALL

SELECT
  i.source_item_id,
  SHA2(CONCAT_WS('||',i.source_item_id,'SAME_DOCUMENT',d.candidate_partner_entity_id),256),
  'SAME_FI_DOCUMENT_POSTED_LINE', 30, d.candidate_partner_entity_id,
  FALSE, FALSE,
  'SIBLING_LINE_NOT_HISTORICAL_MASTER'
FROM ic_v3_item_legal_base i
JOIN ic_v3_same_document_partner d ON d.source_item_id=i.source_item_id

UNION ALL

SELECT
  i.source_item_id,
  SHA2(CONCAT_WS('||',i.source_item_id,'CUSTOMER_MASTER_CURRENT',
       m.candidate_partner_entity_id),256),
  'CUSTOMER_MASTER_CURRENT', 40, m.candidate_partner_entity_id,
  FALSE, FALSE,
  CASE WHEN c.candidate_count=1 THEN 'CURRENT_SNAPSHOT_UNIQUE'
       ELSE 'CURRENT_SNAPSHOT_AMBIGUOUS' END
FROM ic_v3_item_legal_base i
JOIN ic_v3_customer_partner_candidate m
  ON m.source_system_id=i.source_system_id
 AND m.source_client=i.source_client
 AND m.customer_id=i.customer_id
JOIN ic_v3_customer_partner_control c
  ON c.source_system_id=m.source_system_id
 AND c.source_client=m.source_client
 AND c.customer_id=m.customer_id
WHERE i.match_side='AR'

UNION ALL

SELECT
  i.source_item_id,
  SHA2(CONCAT_WS('||',i.source_item_id,'VENDOR_MASTER_CURRENT',
       m.candidate_partner_entity_id),256),
  'VENDOR_MASTER_CURRENT', 40, m.candidate_partner_entity_id,
  FALSE, FALSE,
  CASE WHEN c.candidate_count=1 THEN 'CURRENT_SNAPSHOT_UNIQUE'
       ELSE 'CURRENT_SNAPSHOT_AMBIGUOUS' END
FROM ic_v3_item_legal_base i
JOIN ic_v3_vendor_partner_candidate m
  ON m.source_system_id=i.source_system_id
 AND m.source_client=i.source_client
 AND m.vendor_id=i.vendor_id
JOIN ic_v3_vendor_partner_control c
  ON c.source_system_id=m.source_system_id
 AND c.source_client=m.source_client
 AND c.vendor_id=m.vendor_id
WHERE i.match_side='AP';

CREATE OR REPLACE TEMP VIEW ic_v3_partner_selected_tier AS
SELECT
  source_item_id,
  MIN(evidence_tier)                                 AS selected_automatic_tier
FROM ic_v3_partner_evidence
WHERE automation_eligible
  AND candidate_partner_entity_id IS NOT NULL
GROUP BY source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_partner_stats AS
SELECT
  i.source_item_id,
  COUNT(DISTINCT e.candidate_partner_entity_id)      AS all_candidate_count,
  COUNT(DISTINCT CASE WHEN e.automation_eligible
                      THEN e.candidate_partner_entity_id END)
                                                      AS automatic_candidate_count,
  COUNT(DISTINCT CASE WHEN e.authoritative
                      THEN e.candidate_partner_entity_id END)
                                                      AS authoritative_candidate_count,
  COUNT(DISTINCT CASE WHEN e.evidence_type='POSTED_LINE'
                      THEN e.candidate_partner_entity_id END)
                                                      AS posted_candidate_count,
  COUNT(DISTINCT CASE
    WHEN e.automation_eligible
     AND e.evidence_tier=t.selected_automatic_tier
    THEN e.candidate_partner_entity_id END)           AS selected_candidate_count,
  MIN(CASE WHEN e.evidence_type='POSTED_LINE'
           THEN e.candidate_partner_entity_id END)    AS posted_candidate,
  MIN(CASE WHEN e.automation_eligible
            AND e.evidence_tier=t.selected_automatic_tier
           THEN e.candidate_partner_entity_id END)    AS selected_candidate,
  MIN(e.candidate_partner_entity_id)                  AS sole_diagnostic_candidate,
  t.selected_automatic_tier
FROM ic_v3_item_legal_base i
LEFT JOIN ic_v3_partner_evidence e
  ON e.source_item_id=i.source_item_id
LEFT JOIN ic_v3_partner_selected_tier t
  ON t.source_item_id=i.source_item_id
GROUP BY i.source_item_id, t.selected_automatic_tier;

CREATE OR REPLACE TEMP VIEW ic_v3_partner_resolution_pre AS
SELECT
  i.source_item_id,
  s.all_candidate_count, s.automatic_candidate_count,
  s.authoritative_candidate_count,
  s.posted_candidate_count, s.selected_candidate_count,
  s.selected_automatic_tier,
  CASE
    WHEN s.all_candidate_count=0 THEN 'UNRESOLVED'
    WHEN s.posted_candidate_count>1 THEN 'AMBIGUOUS'
    WHEN s.posted_candidate_count=1 AND s.authoritative_candidate_count>1
      THEN 'CONFLICT'
    WHEN s.posted_candidate_count=1 THEN 'POSTED'
    WHEN s.automatic_candidate_count>1 OR s.selected_candidate_count>1 THEN 'AMBIGUOUS'
    WHEN s.automatic_candidate_count=1
     AND s.authoritative_candidate_count<=1 THEN 'DERIVED_UNIQUE'
    WHEN s.all_candidate_count=1 THEN 'DERIVED_UNIQUE_DIAGNOSTIC'
    ELSE 'AMBIGUOUS'
  END                                                AS partner_resolution_status_pre,
  CASE
    WHEN s.posted_candidate_count=1 AND s.authoritative_candidate_count=1
      THEN s.posted_candidate
    WHEN s.posted_candidate_count=0
     AND s.automatic_candidate_count=1
     AND s.authoritative_candidate_count<=1
      THEN s.selected_candidate
    ELSE NULL
  END                                                AS resolved_partner_entity_id_pre,
  CASE WHEN s.all_candidate_count=1
       THEN s.sole_diagnostic_candidate END          AS diagnostic_partner_entity_id
FROM ic_v3_item_legal_base i
JOIN ic_v3_partner_stats s ON s.source_item_id=i.source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_partner_resolution AS
SELECT
  i.source_item_id,
  CASE
    WHEN r.resolved_partner_entity_id_pre=i.owner_entity_id
      THEN 'CONFLICT_SELF'
    ELSE r.partner_resolution_status_pre
  END                                                AS partner_resolution_status,
  CASE
    WHEN r.resolved_partner_entity_id_pre=i.owner_entity_id THEN NULL
    ELSE r.resolved_partner_entity_id_pre
  END                                                AS resolved_partner_entity_id,
  r.diagnostic_partner_entity_id,
  r.all_candidate_count, r.automatic_candidate_count,
  r.authoritative_candidate_count,
  r.posted_candidate_count, r.selected_candidate_count,
  r.selected_automatic_tier,
  CASE
    WHEN r.resolved_partner_entity_id_pre IS NOT NULL
     AND r.all_candidate_count>1 THEN 'NONAUTHORITATIVE_EVIDENCE_DISAGREES'
    ELSE 'NO_NONAUTHORITATIVE_DISAGREEMENT'
  END                                                AS partner_diagnostic_status,
  CASE
    WHEN r.partner_resolution_status_pre IN ('POSTED','DERIVED_UNIQUE')
     AND i.source_lifecycle_status IN (
           'OPEN_INDEX_LIFECYCLE_CONSISTENT',
           'CLEARED_INDEX_LIFECYCLE_CONSISTENT')
     AND r.resolved_partner_entity_id_pre<>i.owner_entity_id THEN TRUE
    ELSE FALSE
  END                                                AS partner_match_eligible
FROM ic_v3_item_legal_base i
JOIN ic_v3_partner_resolution_pre r ON r.source_item_id=i.source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_item_fact AS
SELECT
  i.source_item_id, i.source_system_id, i.source_client,
  i.source_family, i.match_side, i.scope_rule_id, i.company_code,
  i.owner_entity_id, i.owner_entity_status,
  r.resolved_partner_entity_id, r.diagnostic_partner_entity_id,
  r.partner_resolution_status, r.partner_match_eligible,
  r.partner_diagnostic_status,
  r.all_candidate_count, r.automatic_candidate_count,
  r.authoritative_candidate_count,
  i.fiscal_year, i.accounting_document, i.line_item_number,
  i.gl_account, i.document_type, i.posting_date, i.clearing_date,
  i.clearing_date_status, i.clearing_document,
  i.source_lifecycle_status,
  i.assignment_reference,
  NULLIF(UPPER(TRIM(i.assignment_reference)),'')     AS normalized_assignment_reference,
  i.item_text, i.customer_id, i.vendor_id,
  i.posted_partner_raw, i.document_currency,
  i.raw_amount_dc, i.raw_amount_lc, i.raw_amount_status,
  i.signed_amount_dc, i.signed_amount_lc, i.debit_credit_code,
  i.cross_company_reference, i.reversal_document,
  i.header_status, i.company_name, i.company_country,
  i.as_of_date, i.cutoff_exclusive, i.reconciliation_run_id,
  i.rule_version, i.physical_copy_count, i.physical_source_count
FROM ic_v3_item_legal_base i
JOIN ic_v3_partner_resolution r ON r.source_item_id=i.source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_item_data_quality_exception AS
SELECT
  source_item_id, source_system_id, source_client,
  company_code, fiscal_year, accounting_document, line_item_number,
  document_currency, raw_amount_dc, raw_amount_lc, raw_amount_status,
  signed_amount_dc, signed_amount_lc, debit_credit_code,
  CONCAT_WS(';',
    CASE WHEN document_currency IS NULL OR TRIM(document_currency)=''
         THEN 'DOCUMENT_CURRENCY_MISSING' END,
    CASE WHEN COALESCE(raw_amount_status,'MISSING_RAW_AMOUNT_STATUS')
                   <>'NONNEGATIVE_RAW_AMOUNT'
         THEN COALESCE(raw_amount_status,'MISSING_RAW_AMOUNT_STATUS') END,
    CASE WHEN signed_amount_dc IS NULL THEN 'DOCUMENT_AMOUNT_OR_SIGN_INVALID' END,
    CASE WHEN signed_amount_lc IS NULL THEN 'LOCAL_AMOUNT_OR_SIGN_INVALID' END,
    CASE WHEN debit_credit_code NOT IN ('S','H') OR debit_credit_code IS NULL
         THEN 'DEBIT_CREDIT_CODE_INVALID' END
  )                                                   AS data_quality_exception,
  reconciliation_run_id, as_of_date, cutoff_exclusive
FROM ic_v3_item_fact
WHERE document_currency IS NULL OR TRIM(document_currency)=''
   OR COALESCE(raw_amount_status,'MISSING_RAW_AMOUNT_STATUS')
        <>'NONNEGATIVE_RAW_AMOUNT'
   OR signed_amount_dc IS NULL OR signed_amount_lc IS NULL
   OR debit_credit_code NOT IN ('S','H') OR debit_credit_code IS NULL;

-- BSID/BSIK are open indexes; BSAD/BSAK are cleared indexes. A row whose
-- clearing fields contradict its physical index is retained and release-blocked.
CREATE OR REPLACE TEMP VIEW ic_v3_item_source_lifecycle_exception AS
SELECT
  source_item_id, source_system_id, source_client, source_family,
  company_code, fiscal_year, accounting_document, line_item_number,
  posting_date, clearing_date, clearing_date_status, clearing_document,
  source_lifecycle_status, signed_amount_dc,
  physical_copy_count, physical_source_count,
  reconciliation_run_id, as_of_date, cutoff_exclusive
FROM ic_v3_item_fact
WHERE COALESCE(source_lifecycle_status,'MISSING_SOURCE_LIFECYCLE_STATUS')
      NOT IN (
  'OPEN_INDEX_LIFECYCLE_CONSISTENT',
  'CLEARED_INDEX_LIFECYCLE_CONSISTENT'
);

-- ============================================================================
-- 4. EXACT FI-LINE DETAIL AND CONSERVED MANAGEMENT ALLOCATION
--    Matching remains at legal-item grain. Allocation occurs afterward.
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_item_bseg_line_raw AS
SELECT
  i.source_item_id,
  NULLIF(UPPER(TRIM(CAST(b.PRCTR AS STRING))), '')    AS posted_profit_center,
  NULLIF(UPPER(TRIM(CAST(b.KOSTL AS STRING))), '')    AS posted_cost_center,
  NULLIF(TRIM(CAST(b.EBELN AS STRING)), '')           AS purchase_order,
  NULLIF(TRIM(CAST(b.EBELP AS STRING)), '')           AS purchase_order_item,
  CAST(b.HKONT AS STRING)                             AS bseg_gl_account,
  CAST(b.KOART AS STRING)                             AS account_type,
  CAST(b.SHKZG AS STRING)                            AS bseg_debit_credit_code,
  CAST(CASE WHEN b.SHKZG='S' AND TRY_CAST(b.WRBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(b.WRBTR AS DECIMAL(38,6))
            WHEN b.SHKZG='H' AND TRY_CAST(b.WRBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(b.WRBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                       AS bseg_signed_amount_dc,
  CAST(CASE WHEN b.SHKZG='S' AND TRY_CAST(b.DMBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(b.DMBTR AS DECIMAL(38,6))
            WHEN b.SHKZG='H' AND TRY_CAST(b.DMBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(b.DMBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                       AS bseg_signed_amount_lc,
  SHA2(TO_JSON(NAMED_STRUCT(
    'prctr',NULLIF(UPPER(TRIM(CAST(b.PRCTR AS STRING))),''),
    'kostl',NULLIF(UPPER(TRIM(CAST(b.KOSTL AS STRING))),''),
    'ebeln',NULLIF(TRIM(CAST(b.EBELN AS STRING)),''),
    'ebelp',NULLIF(TRIM(CAST(b.EBELP AS STRING)),''),
    'hkont',CAST(b.HKONT AS STRING),
    'koart',CAST(b.KOART AS STRING),
    'shkzg',CAST(b.SHKZG AS STRING),
    'wrbtr',TRY_CAST(b.WRBTR AS DECIMAL(38,6)),
    'dmbtr',TRY_CAST(b.DMBTR AS DECIMAL(38,6)))),256) AS bseg_payload_hash
FROM ic_v3_item_fact i
JOIN qlk_c.c_ocs_ecc_old.bseg b
  ON CAST(b.MANDT AS STRING)=i.source_client
 AND CAST(b.BUKRS AS STRING)=i.company_code
 AND CAST(b.GJAHR AS STRING)=i.fiscal_year
 AND CAST(b.BELNR AS STRING)=i.accounting_document
 AND CAST(b.BUZEI AS STRING)=i.line_item_number
 AND UPPER(COALESCE(b.hdr__oper,'')) <> 'D';

CREATE OR REPLACE TEMP VIEW ic_v3_item_bseg_line_control AS
SELECT
  i.source_item_id,
  COUNT(r.source_item_id)                            AS bseg_physical_count,
  COUNT(DISTINCT r.bseg_payload_hash)                AS bseg_payload_count,
  COUNT(DISTINCT r.posted_profit_center)             AS profit_center_count,
  COUNT(DISTINCT CASE
    WHEN r.purchase_order IS NOT NULL AND r.purchase_order_item IS NOT NULL
      THEN CONCAT_WS('||',r.purchase_order,r.purchase_order_item) END)
                                                      AS po_item_count,
  MIN(r.posted_profit_center)                        AS sole_profit_center,
  MIN(r.purchase_order)                              AS sole_purchase_order,
  MIN(r.purchase_order_item)                         AS sole_purchase_order_item,
  MIN(r.bseg_gl_account)                             AS sole_bseg_gl_account,
  MIN(r.account_type)                                AS sole_account_type,
  MIN(r.bseg_debit_credit_code)                      AS sole_bseg_debit_credit_code,
  MIN(r.bseg_signed_amount_dc)                       AS sole_bseg_signed_amount_dc,
  MIN(r.bseg_signed_amount_lc)                       AS sole_bseg_signed_amount_lc,
  CASE
    WHEN COUNT(r.source_item_id)=0 THEN 'BSEG_LINE_MISSING'
    WHEN COUNT(r.source_item_id)=1
     AND COUNT(DISTINCT r.bseg_payload_hash)=1
     AND MIN(r.bseg_gl_account)=i.gl_account
     AND ((i.match_side='AR' AND MIN(r.account_type)='D')
       OR (i.match_side='AP' AND MIN(r.account_type)='K'))
     AND MIN(r.bseg_debit_credit_code)=i.debit_credit_code
     AND MIN(r.bseg_signed_amount_dc)=i.signed_amount_dc
     AND MIN(r.bseg_signed_amount_lc)=i.signed_amount_lc
      THEN 'BSEG_LINE_RESOLVED'
    WHEN COUNT(r.source_item_id)=1
     AND COUNT(DISTINCT r.bseg_payload_hash)=1
      AND (MIN(r.bseg_gl_account)<>i.gl_account
        OR (i.match_side='AR' AND MIN(r.account_type)<>'D')
        OR (i.match_side='AP' AND MIN(r.account_type)<>'K')
        OR MIN(r.bseg_debit_credit_code)<>i.debit_credit_code
        OR MIN(r.bseg_debit_credit_code) IS NULL)
      THEN 'BSEG_LINE_ACCOUNT_OR_TYPE_MISMATCH'
    WHEN COUNT(r.source_item_id)=1
     AND COUNT(DISTINCT r.bseg_payload_hash)=1
      THEN 'BSEG_LINE_AMOUNT_OR_SIGN_MISMATCH'
    WHEN COUNT(DISTINCT r.bseg_payload_hash)=1 THEN 'BSEG_LINE_DUPLICATE_PHYSICAL'
    ELSE 'BSEG_LINE_CONFLICT'
  END                                                AS bseg_line_status
FROM ic_v3_item_fact i
LEFT JOIN ic_v3_item_bseg_line_raw r
  ON r.source_item_id=i.source_item_id
GROUP BY i.source_item_id, i.gl_account, i.match_side,
         i.debit_credit_code, i.signed_amount_dc, i.signed_amount_lc;

CREATE OR REPLACE TEMP VIEW ic_v3_item_po_evidence AS
SELECT
  source_item_id,
  CASE WHEN bseg_line_status='BSEG_LINE_RESOLVED' AND po_item_count=1
       THEN sole_purchase_order END                  AS purchase_order,
  CASE WHEN bseg_line_status='BSEG_LINE_RESOLVED' AND po_item_count=1
       THEN sole_purchase_order_item END             AS purchase_order_item,
  CASE
    WHEN bseg_line_status<>'BSEG_LINE_RESOLVED' THEN 'BSEG_LINE_NOT_UNIQUE'
    WHEN po_item_count=1 THEN 'FI_LINE_PO_REFERENCE_PRESENT'
    WHEN po_item_count=0 THEN 'NO_PO_ITEM_ON_FI_LINE'
    ELSE 'PO_ITEM_AMBIGUOUS'
  END                                                AS po_lineage_status
FROM ic_v3_item_bseg_line_control;

CREATE OR REPLACE TEMP VIEW ic_v3_profit_center_map_control AS
SELECT
  UPPER(TRIM(CAST(CompCode AS STRING)))               AS company_code,
  UPPER(TRIM(CAST(Prof_ctr AS STRING)))               AS profit_center,
  COUNT(*)                                           AS mapping_row_count,
  COUNT(DISTINCT NULLIF(TRIM(CAST(OU AS STRING)),'')) AS ou_count,
  MIN(NULLIF(TRIM(CAST(OU AS STRING)),''))            AS sole_ou,
  CASE
    WHEN COUNT(DISTINCT NULLIF(TRIM(CAST(OU AS STRING)),''))=1
      THEN 'RESOLVED'
    WHEN COUNT(DISTINCT NULLIF(TRIM(CAST(OU AS STRING)),''))=0
      THEN 'UNRESOLVED'
    ELSE 'AMBIGUOUS'
  END                                                AS profit_center_map_status
FROM qlk_c.c_ocs_sql.ocs_kairos_emea_prof_ctr
GROUP BY UPPER(TRIM(CAST(CompCode AS STRING))),
         UPPER(TRIM(CAST(Prof_ctr AS STRING)));

CREATE OR REPLACE TEMP VIEW ic_v3_ou_bu_map_control AS
SELECT
  TRIM(CAST(OU AS STRING))                           AS operating_unit,
  COUNT(*)                                           AS hierarchy_row_count,
  COUNT(DISTINCT LPAD(TRIM(CAST(BU AS STRING)),6,'0'))
                                                      AS bu_count,
  MIN(LPAD(TRIM(CAST(BU AS STRING)),6,'0'))           AS sole_bu,
  CASE
    WHEN COUNT(DISTINCT LPAD(TRIM(CAST(BU AS STRING)),6,'0'))=1
      THEN 'RESOLVED'
    WHEN COUNT(DISTINCT LPAD(TRIM(CAST(BU AS STRING)),6,'0'))=0
      THEN 'UNRESOLVED'
    ELSE 'AMBIGUOUS'
  END                                                AS ou_bu_map_status
FROM common.business_structures.bu_ou_div_hierarchy
WHERE NULLIF(TRIM(CAST(OU AS STRING)),'') IS NOT NULL
  AND NULLIF(TRIM(CAST(BU AS STRING)),'') IS NOT NULL
  AND TRIM(CAST(OU AS STRING))<>'1999'
GROUP BY TRIM(CAST(OU AS STRING));

CREATE OR REPLACE TEMP VIEW ic_v3_document_item_count AS
SELECT
  source_system_id, source_client, company_code, fiscal_year,
  accounting_document,
  COUNT(*)                                           AS scoped_item_count
FROM ic_v3_item_fact
GROUP BY source_system_id, source_client, company_code, fiscal_year,
         accounting_document;

-- A document-offset split is admissible only when the target is the sole
-- customer/vendor line in the complete FI document. Counting only scoped items
-- could otherwise misattribute shared revenue/cost offsets to one IC item.
CREATE OR REPLACE TEMP VIEW ic_v3_offset_document_control AS
SELECT
  i.source_item_id,
  COUNT(b.BUZEI)                                      AS document_physical_line_count,
  SUM(CASE WHEN CAST(b.BUZEI AS STRING)=i.line_item_number
           THEN 1 ELSE 0 END)                        AS target_line_physical_count,
  SUM(CASE WHEN CAST(b.KOART AS STRING) IN ('D','K')
           THEN 1 ELSE 0 END)                        AS subledger_line_physical_count,
  SUM(CASE WHEN CAST(b.KOART AS STRING) IN ('D','K')
            AND CAST(b.BUZEI AS STRING)<>i.line_item_number
           THEN 1 ELSE 0 END)                        AS other_subledger_line_count,
  SUM(CASE WHEN COALESCE(CAST(b.KOART AS STRING),'<NULL>')
                    NOT IN ('D','K','S')
           THEN 1 ELSE 0 END)                        AS unsupported_offset_line_count,
  SUM(CASE WHEN NULLIF(TRIM(CAST(b.BUZEI AS STRING)),'') IS NULL
           THEN 1 ELSE 0 END)                        AS invalid_line_key_count,
  CASE
    WHEN SUM(CASE WHEN NULLIF(TRIM(CAST(b.BUZEI AS STRING)),'') IS NULL
                  THEN 1 ELSE 0 END)>0
      THEN 'DOCUMENT_HAS_INVALID_LINE_KEY'
    WHEN SUM(CASE WHEN CAST(b.BUZEI AS STRING)=i.line_item_number
                  THEN 1 ELSE 0 END)<>1
      THEN 'TARGET_LINE_NOT_PHYSICALLY_UNIQUE'
    WHEN SUM(CASE WHEN CAST(b.KOART AS STRING) IN ('D','K')
                  THEN 1 ELSE 0 END)<>1
      THEN 'MULTIPLE_OR_MISSING_SUBLEDGER_LINES'
    WHEN SUM(CASE WHEN CAST(b.KOART AS STRING) IN ('D','K')
                   AND CAST(b.BUZEI AS STRING)<>i.line_item_number
                  THEN 1 ELSE 0 END)<>0
      THEN 'OTHER_SUBLEDGER_LINE_PRESENT'
    WHEN SUM(CASE WHEN COALESCE(CAST(b.KOART AS STRING),'<NULL>')
                           NOT IN ('D','K','S')
                  THEN 1 ELSE 0 END)>0
      THEN 'UNSUPPORTED_NON_GL_OFFSET_LINE_PRESENT'
    ELSE 'SINGLE_SUBLEDGER_TARGET'
  END                                                AS document_structure_status
FROM ic_v3_item_fact i
LEFT JOIN qlk_c.c_ocs_ecc_old.bseg b
  ON CAST(b.MANDT AS STRING)=i.source_client
 AND CAST(b.BUKRS AS STRING)=i.company_code
 AND CAST(b.GJAHR AS STRING)=i.fiscal_year
 AND CAST(b.BELNR AS STRING)=i.accounting_document
 AND UPPER(COALESCE(b.hdr__oper,''))<>'D'
GROUP BY i.source_item_id, i.line_item_number;

CREATE OR REPLACE TEMP VIEW ic_v3_offset_line_raw AS
SELECT
  i.source_item_id,
  NULLIF(TRIM(CAST(b.BUZEI AS STRING)),'')           AS offset_line_item,
  NULLIF(UPPER(TRIM(CAST(b.PRCTR AS STRING))), '')   AS offset_profit_center,
  TRY_CAST(b.WRBTR AS DECIMAL(38,6))                 AS raw_offset_amount_dc,
  TRY_CAST(b.DMBTR AS DECIMAL(38,6))                 AS raw_offset_amount_lc,
  CAST(b.SHKZG AS STRING)                            AS offset_debit_credit_code,
  CASE
    WHEN TRY_CAST(b.WRBTR AS DECIMAL(38,6)) IS NULL
      OR TRY_CAST(b.DMBTR AS DECIMAL(38,6)) IS NULL
      THEN 'MISSING_OR_INVALID_RAW_AMOUNT'
    WHEN TRY_CAST(b.WRBTR AS DECIMAL(38,6))<0
      OR TRY_CAST(b.DMBTR AS DECIMAL(38,6))<0
      THEN 'NEGATIVE_RAW_AMOUNT'
    WHEN CAST(b.SHKZG AS STRING) NOT IN ('S','H') OR b.SHKZG IS NULL
      THEN 'INVALID_DEBIT_CREDIT_CODE'
    ELSE 'NONNEGATIVE_RAW_AMOUNT'
  END                                                AS raw_offset_amount_status,
  CAST(CASE WHEN b.SHKZG='S' AND TRY_CAST(b.WRBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(b.WRBTR AS DECIMAL(38,6))
            WHEN b.SHKZG='H' AND TRY_CAST(b.WRBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(b.WRBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                       AS offset_signed_amount_dc,
  CAST(CASE WHEN b.SHKZG='S' AND TRY_CAST(b.DMBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(b.DMBTR AS DECIMAL(38,6))
            WHEN b.SHKZG='H' AND TRY_CAST(b.DMBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(b.DMBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                      AS offset_signed_amount_lc,
  SHA2(CONCAT_WS('||',
       CONCAT('source_item=',i.source_item_id),
       CONCAT('offset_line=',COALESCE(NULLIF(TRIM(CAST(b.BUZEI AS STRING)),''),'<NULL>'))),256)
                                                      AS offset_line_id,
  SHA2(TO_JSON(NAMED_STRUCT(
       'profit_center',NULLIF(UPPER(TRIM(CAST(b.PRCTR AS STRING))),''),
       'shkzg',CAST(b.SHKZG AS STRING),
       'wrbtr',TRY_CAST(b.WRBTR AS DECIMAL(38,6)),
       'dmbtr',TRY_CAST(b.DMBTR AS DECIMAL(38,6)))),256) AS offset_payload_hash
FROM ic_v3_item_fact i
JOIN ic_v3_document_item_count d
  ON d.source_system_id=i.source_system_id
 AND d.source_client=i.source_client
 AND d.company_code=i.company_code
 AND d.fiscal_year=i.fiscal_year
 AND d.accounting_document=i.accounting_document
 AND d.scoped_item_count=1
JOIN ic_v3_offset_document_control ds
  ON ds.source_item_id=i.source_item_id
 AND ds.document_structure_status='SINGLE_SUBLEDGER_TARGET'
JOIN qlk_c.c_ocs_ecc_old.bseg b
  ON CAST(b.MANDT AS STRING)=i.source_client
 AND CAST(b.BUKRS AS STRING)=i.company_code
 AND CAST(b.GJAHR AS STRING)=i.fiscal_year
 AND CAST(b.BELNR AS STRING)=i.accounting_document
 AND CAST(b.BUZEI AS STRING)<>i.line_item_number
 AND CAST(b.KOART AS STRING)='S'
 AND UPPER(COALESCE(b.hdr__oper,'')) <> 'D';

CREATE OR REPLACE TEMP VIEW ic_v3_offset_line_control AS
SELECT
  source_item_id, offset_line_id,
  COUNT(*)                                           AS physical_row_count,
  COUNT(DISTINCT offset_payload_hash)                AS payload_count,
  SUM(CASE WHEN offset_line_item IS NULL THEN 1 ELSE 0 END)
                                                       AS invalid_native_key_count,
  SUM(CASE WHEN raw_offset_amount_status<>'NONNEGATIVE_RAW_AMOUNT'
                 OR offset_debit_credit_code IS NULL
                 OR offset_debit_credit_code NOT IN ('S','H')
                 OR offset_signed_amount_dc IS NULL
                 OR offset_signed_amount_lc IS NULL
           THEN 1 ELSE 0 END)                        AS invalid_raw_amount_count,
  CASE
    WHEN SUM(CASE WHEN offset_line_item IS NULL THEN 1 ELSE 0 END)>0
      THEN 'FAIL_INVALID_OFFSET_LINE_KEY'
    WHEN SUM(CASE WHEN raw_offset_amount_status<>'NONNEGATIVE_RAW_AMOUNT'
                       OR offset_debit_credit_code IS NULL
                       OR offset_debit_credit_code NOT IN ('S','H')
                       OR offset_signed_amount_dc IS NULL
                       OR offset_signed_amount_lc IS NULL
                  THEN 1 ELSE 0 END)>0
      THEN 'FAIL_INVALID_OFFSET_AMOUNT_OR_SIGN'
    WHEN COUNT(*)=1 AND COUNT(DISTINCT offset_payload_hash)=1 THEN 'PASS'
    WHEN COUNT(DISTINCT offset_payload_hash)=1 THEN 'FAIL_DUPLICATE_PHYSICAL_OFFSET'
    ELSE 'FAIL_CONFLICTING_OFFSET_PAYLOAD'
  END                                                AS offset_line_status
FROM ic_v3_offset_line_raw
GROUP BY source_item_id, offset_line_id;

CREATE OR REPLACE TEMP VIEW ic_v3_offset_line_unique AS
SELECT
  r.source_item_id, r.offset_line_item, r.offset_profit_center,
  r.raw_offset_amount_dc, r.raw_offset_amount_lc,
  r.offset_debit_credit_code, r.raw_offset_amount_status,
  r.offset_signed_amount_dc, r.offset_signed_amount_lc,
  r.offset_line_id
FROM ic_v3_offset_line_raw r
JOIN ic_v3_offset_line_control c
  ON c.source_item_id=r.source_item_id
 AND c.offset_line_id=r.offset_line_id
WHERE c.offset_line_status='PASS';

CREATE OR REPLACE TEMP VIEW ic_v3_offset_item_key_exception AS
SELECT
  source_item_id,
  SUM(CASE WHEN COALESCE(offset_line_status,'OFFSET_LINE_STATUS_MISSING')<>'PASS'
           THEN 1 ELSE 0 END)
                                                      AS invalid_offset_line_count
FROM ic_v3_offset_line_control
GROUP BY source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_offset_control AS
SELECT
  i.source_item_id,
  MIN(ds.document_structure_status)                  AS document_structure_status,
  COUNT(o.offset_line_item)                          AS offset_line_count,
  COALESCE(MIN(x.invalid_offset_line_count),0)       AS invalid_offset_line_count,
  SUM(CASE WHEN o.offset_profit_center IS NULL THEN 1 ELSE 0 END)
                                                      AS blank_profit_center_count,
  SUM(CASE
    WHEN o.offset_signed_amount_dc*i.signed_amount_dc>=0 THEN 1 ELSE 0 END)
                                                      AS same_sign_offset_count,
  CAST(COALESCE(SUM(o.offset_signed_amount_dc),0) AS DECIMAL(38,6))
                                                      AS offset_total_dc,
  CAST(COALESCE(SUM(o.offset_signed_amount_lc),0) AS DECIMAL(38,6))
                                                      AS offset_total_lc,
  CAST(COALESCE(SUM(ABS(o.offset_signed_amount_dc)),0) AS DECIMAL(38,6))
                                                      AS offset_gross_dc,
  CASE
    WHEN i.signed_amount_dc IS NULL OR i.signed_amount_lc IS NULL
      THEN 'SOURCE_ITEM_AMOUNT_MISSING_OR_INVALID'
    WHEN COALESCE(MIN(ds.document_structure_status),
                  'DOCUMENT_STRUCTURE_STATUS_MISSING')<>'SINGLE_SUBLEDGER_TARGET'
      THEN CONCAT('OFFSET_UNSAFE_',COALESCE(MIN(ds.document_structure_status),
                                            'DOCUMENT_STRUCTURE_STATUS_MISSING'))
    WHEN COALESCE(MIN(x.invalid_offset_line_count),0)>0
      THEN 'OFFSET_LINE_KEY_OR_PAYLOAD_INVALID'
    WHEN COUNT(o.offset_line_item)=0 THEN 'NO_GL_OFFSET_SIGNAL'
    WHEN SUM(CASE WHEN o.offset_profit_center IS NULL THEN 1 ELSE 0 END)>0
      THEN 'OFFSET_PROFIT_CENTER_MISSING'
    WHEN SUM(CASE
           WHEN o.offset_signed_amount_dc*i.signed_amount_dc>=0
           THEN 1 ELSE 0 END)>0
      THEN 'OFFSET_SIGN_MIXED'
    WHEN CAST(COALESCE(SUM(o.offset_signed_amount_dc),0) AS DECIMAL(38,6))
         +i.signed_amount_dc<>CAST(0 AS DECIMAL(38,6))
      THEN 'OFFSET_DOES_NOT_EXACTLY_BALANCE_ITEM_DC'
    WHEN CAST(COALESCE(SUM(o.offset_signed_amount_lc),0) AS DECIMAL(38,6))
         +i.signed_amount_lc<>CAST(0 AS DECIMAL(38,6))
      THEN 'OFFSET_DOES_NOT_EXACTLY_BALANCE_ITEM_LC'
    ELSE 'SAFE_SINGLE_ITEM_DOCUMENT_OFFSET'
  END                                                AS offset_allocation_status
FROM ic_v3_item_fact i
LEFT JOIN ic_v3_offset_line_unique o
  ON o.source_item_id=i.source_item_id
LEFT JOIN ic_v3_offset_document_control ds
  ON ds.source_item_id=i.source_item_id
LEFT JOIN ic_v3_offset_item_key_exception x
  ON x.source_item_id=i.source_item_id
GROUP BY i.source_item_id, i.signed_amount_dc, i.signed_amount_lc;

CREATE OR REPLACE TEMP VIEW ic_v3_offset_by_profit_center AS
SELECT
  o.source_item_id,
  o.offset_profit_center                             AS owner_profit_center_raw,
  CAST(-SUM(o.offset_signed_amount_dc) AS DECIMAL(38,6))
                                                      AS allocated_amount_dc,
  CAST(-SUM(o.offset_signed_amount_lc) AS DECIMAL(38,6))
                                                      AS allocated_amount_lc
FROM ic_v3_offset_line_unique o
JOIN ic_v3_offset_control c
  ON c.source_item_id=o.source_item_id
 AND c.offset_allocation_status='SAFE_SINGLE_ITEM_DOCUMENT_OFFSET'
GROUP BY o.source_item_id, o.offset_profit_center;

CREATE OR REPLACE TEMP VIEW ic_v3_allocation_seed AS
-- Exact line profit center: one full-value allocation.
SELECT
  i.source_item_id,
  c.sole_profit_center                              AS owner_profit_center_raw,
  'EXACT_FI_LINE_PROFIT_CENTER'                     AS allocation_method,
  CAST(i.signed_amount_dc AS DECIMAL(38,6))         AS allocated_amount_dc,
  CAST(i.signed_amount_lc AS DECIMAL(38,6))         AS allocated_amount_lc
FROM ic_v3_item_fact i
JOIN ic_v3_item_bseg_line_control c
  ON c.source_item_id=i.source_item_id
WHERE c.bseg_line_status='BSEG_LINE_RESOLVED'
  AND c.profit_center_count=1
  AND i.signed_amount_dc IS NOT NULL
  AND i.signed_amount_lc IS NOT NULL

UNION ALL

-- A split is accepted only for a document with one scoped source item where
-- all nonzero G/L offsets have profit centers, are opposite-sign, and exactly
-- offset the item. Every split row is retained.
SELECT
  i.source_item_id,
  o.owner_profit_center_raw,
  'EXACT_BALANCING_GL_OFFSETS'                       AS allocation_method,
  o.allocated_amount_dc,
  o.allocated_amount_lc
FROM ic_v3_item_fact i
JOIN ic_v3_item_bseg_line_control b
  ON b.source_item_id=i.source_item_id
JOIN ic_v3_offset_control c
  ON c.source_item_id=i.source_item_id
 AND c.offset_allocation_status='SAFE_SINGLE_ITEM_DOCUMENT_OFFSET'
JOIN ic_v3_offset_by_profit_center o
  ON o.source_item_id=i.source_item_id
WHERE b.bseg_line_status='BSEG_LINE_RESOLVED'
  AND COALESCE(b.profit_center_count,0)=0
  AND i.signed_amount_dc IS NOT NULL
  AND i.signed_amount_lc IS NOT NULL

UNION ALL

-- If neither method is proven, keep the entire amount in one explicit
-- unallocated child. Nothing disappears and no dominant BU is manufactured.
SELECT
  i.source_item_id,
  CAST(NULL AS STRING)                               AS owner_profit_center_raw,
  CASE
    WHEN i.signed_amount_dc IS NULL OR i.signed_amount_lc IS NULL
      THEN 'UNALLOCATED_SOURCE_ITEM_AMOUNT_MISSING_OR_INVALID'
    WHEN COALESCE(b.bseg_line_status,'BSEG_LINE_STATUS_MISSING')
         <>'BSEG_LINE_RESOLVED'
      THEN 'UNALLOCATED_BSEG_LINE_NOT_UNIQUE'
    WHEN b.profit_center_count IS NULL
      THEN 'UNALLOCATED_PROFIT_CENTER_CONTROL_MISSING'
    WHEN b.profit_center_count>1 THEN 'UNALLOCATED_EXACT_PC_AMBIGUOUS'
    ELSE CONCAT('UNALLOCATED_',COALESCE(c.offset_allocation_status,
                                        'OFFSET_ALLOCATION_STATUS_MISSING'))
  END                                                AS allocation_method,
  CAST(i.signed_amount_dc AS DECIMAL(38,6))          AS allocated_amount_dc,
  CAST(i.signed_amount_lc AS DECIMAL(38,6))          AS allocated_amount_lc
FROM ic_v3_item_fact i
JOIN ic_v3_item_bseg_line_control b
  ON b.source_item_id=i.source_item_id
JOIN ic_v3_offset_control c
  ON c.source_item_id=i.source_item_id
WHERE NOT COALESCE(
        b.bseg_line_status='BSEG_LINE_RESOLVED'
        AND b.profit_center_count=1
        AND i.signed_amount_dc IS NOT NULL
        AND i.signed_amount_lc IS NOT NULL,
        FALSE)
  AND NOT COALESCE(
        b.bseg_line_status='BSEG_LINE_RESOLVED'
        AND COALESCE(b.profit_center_count,0)=0
        AND c.offset_allocation_status='SAFE_SINGLE_ITEM_DOCUMENT_OFFSET'
        AND i.signed_amount_dc IS NOT NULL
        AND i.signed_amount_lc IS NOT NULL,
        FALSE);

CREATE OR REPLACE TEMP VIEW ic_v3_item_allocation AS
SELECT
  SHA2(CONCAT_WS('||',a.source_item_id,a.allocation_method,
       COALESCE(a.owner_profit_center_raw,'<UNALLOCATED>')),256)
                                                      AS allocation_id,
  a.source_item_id,
  a.owner_profit_center_raw,
  CASE WHEN pc.ou_count=1 THEN pc.sole_ou END         AS owner_operating_unit,
  CASE WHEN pc.ou_count=1 AND hb.bu_count=1
       THEN hb.sole_bu END                           AS owner_business_unit,
  a.allocation_method,
  CASE
    WHEN a.owner_profit_center_raw IS NULL THEN 'UNALLOCATED'
    WHEN pc.profit_center IS NULL THEN 'PROFIT_CENTER_UNMAPPED'
    WHEN pc.ou_count<>1 THEN 'PROFIT_CENTER_MAPPING_AMBIGUOUS'
    WHEN hb.operating_unit IS NULL THEN 'OU_UNMAPPED'
    WHEN hb.bu_count<>1 THEN 'OU_TO_BU_AMBIGUOUS'
    ELSE 'ALLOCATED_AND_MAPPED'
  END                                                AS allocation_status,
  a.allocated_amount_dc,
  CAST(
    a.allocated_amount_lc
    + CASE
        -- The deterministic minimum component receives arithmetic rounding
        -- only; it is not used to choose a business allocation.
        WHEN CONCAT_WS('||',a.allocation_method,
             COALESCE(a.owner_profit_center_raw,'<UNALLOCATED>'))
             =MIN(CONCAT_WS('||',a.allocation_method,
                  COALESCE(a.owner_profit_center_raw,'<UNALLOCATED>')))
              OVER (PARTITION BY a.source_item_id)
        THEN i.signed_amount_lc
             -SUM(a.allocated_amount_lc) OVER (PARTITION BY a.source_item_id)
        ELSE CAST(0 AS DECIMAL(38,6))
      END
    AS DECIMAL(38,6))                                AS allocated_amount_lc,
  p.profit_center_map_version
FROM ic_v3_allocation_seed a
CROSS JOIN ic_v3_params p
JOIN ic_v3_item_fact i
  ON i.source_item_id=a.source_item_id
LEFT JOIN ic_v3_profit_center_map_control pc
  ON pc.company_code=UPPER(TRIM(i.company_code))
 AND pc.profit_center=a.owner_profit_center_raw
LEFT JOIN ic_v3_ou_bu_map_control hb
  ON hb.operating_unit=pc.sole_ou;

CREATE OR REPLACE TEMP VIEW ic_v3_allocation_control AS
SELECT
  i.source_item_id,
  COUNT(a.allocation_id)                             AS allocation_row_count,
  COUNT(DISTINCT a.allocation_id)                    AS distinct_allocation_id_count,
  CAST(i.signed_amount_dc AS DECIMAL(38,6))          AS source_amount_dc,
  CAST(COALESCE(SUM(a.allocated_amount_dc),0) AS DECIMAL(38,6))
                                                      AS allocated_amount_dc,
  CAST(i.signed_amount_dc-COALESCE(SUM(a.allocated_amount_dc),0)
       AS DECIMAL(38,6))                             AS allocation_residual_dc,
  CAST(i.signed_amount_lc AS DECIMAL(38,6))          AS source_amount_lc,
  CAST(COALESCE(SUM(a.allocated_amount_lc),0) AS DECIMAL(38,6))
                                                      AS allocated_amount_lc,
  CAST(i.signed_amount_lc-COALESCE(SUM(a.allocated_amount_lc),0)
       AS DECIMAL(38,6))                             AS allocation_residual_lc,
  CASE
    WHEN i.signed_amount_dc IS NULL OR i.signed_amount_lc IS NULL
      THEN 'FAIL_NULL_SOURCE_AMOUNT'
    WHEN COUNT(a.allocation_id)=0 THEN 'FAIL_MISSING_ALLOCATION'
    WHEN SUM(CASE WHEN a.allocated_amount_dc IS NULL
                       OR a.allocated_amount_lc IS NULL THEN 1 ELSE 0 END)>0
      THEN 'FAIL_NULL_ALLOCATED_AMOUNT'
    WHEN COUNT(a.allocation_id)<>COUNT(DISTINCT a.allocation_id)
      THEN 'FAIL_DUPLICATE_ALLOCATION_ID'
    WHEN i.signed_amount_dc<>CAST(COALESCE(SUM(a.allocated_amount_dc),0)
                                  AS DECIMAL(38,6))
      THEN 'FAIL_NONCONSERVING_ALLOCATION'
    WHEN i.signed_amount_lc<>CAST(COALESCE(SUM(a.allocated_amount_lc),0)
                                  AS DECIMAL(38,6))
      THEN 'FAIL_NONCONSERVING_LOCAL_ALLOCATION'
    ELSE 'PASS'
  END                                                AS allocation_control_status
FROM ic_v3_item_fact i
LEFT JOIN ic_v3_item_allocation a
  ON a.source_item_id=i.source_item_id
GROUP BY i.source_item_id, i.signed_amount_dc, i.signed_amount_lc;

-- ============================================================================
-- 5. LEGAL-ENTITY MATCH GROUPS
--    Match before allocation, in transaction currency, by explicit evidence.
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_match_eligible_item AS
SELECT
  i.source_item_id, i.source_system_id, i.source_client,
  i.match_side, i.owner_entity_id, i.resolved_partner_entity_id,
  LEAST(i.owner_entity_id,i.resolved_partner_entity_id) AS entity_lo,
  GREATEST(i.owner_entity_id,i.resolved_partner_entity_id) AS entity_hi,
  i.document_currency, i.signed_amount_dc,
  i.cross_company_reference, i.normalized_assignment_reference,
  i.posting_date, i.as_of_date, i.cutoff_exclusive,
  i.reconciliation_run_id, i.rule_version
FROM ic_v3_item_fact i
WHERE i.header_status='RESOLVED'
  AND i.raw_amount_status='NONNEGATIVE_RAW_AMOUNT'
  AND i.debit_credit_code IN ('S','H')
  AND i.signed_amount_dc IS NOT NULL
  AND i.signed_amount_lc IS NOT NULL
  AND i.owner_entity_status='RESOLVED_SOURCE_LOCAL_ENTITY'
  AND i.partner_match_eligible
  AND i.owner_entity_id<>i.resolved_partner_entity_id
  AND i.document_currency IS NOT NULL
  AND TRIM(i.document_currency)<>'';

CREATE OR REPLACE TEMP VIEW ic_v3_bvorg_group_member AS
SELECT
  SHA2(CONCAT_WS('||',reconciliation_run_id,'BVORG',source_system_id,
       source_client,cross_company_reference,document_currency),256)
                                                      AS match_group_id,
  source_item_id, source_system_id, source_client,
  match_side, owner_entity_id, resolved_partner_entity_id,
  entity_lo, entity_hi, document_currency, signed_amount_dc,
  cross_company_reference                            AS normalized_reference,
  reconciliation_run_id, rule_version
FROM ic_v3_match_eligible_item
WHERE cross_company_reference IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_bvorg_group AS
SELECT
  match_group_id, source_system_id, source_client, document_currency,
  normalized_reference, reconciliation_run_id, rule_version,
  COUNT(*)                                           AS member_count,
  SUM(CASE WHEN match_side='AR' THEN 1 ELSE 0 END)   AS ar_count,
  SUM(CASE WHEN match_side='AP' THEN 1 ELSE 0 END)   AS ap_count,
  COUNT(DISTINCT entity_lo)                          AS entity_lo_count,
  COUNT(DISTINCT entity_hi)                          AS entity_hi_count,
  COUNT(DISTINCT CASE WHEN match_side='AR'
       THEN CONCAT_WS('>',owner_entity_id,resolved_partner_entity_id) END)
                                                      AS ar_direction_count,
  COUNT(DISTINCT CASE WHEN match_side='AP'
       THEN CONCAT_WS('>',owner_entity_id,resolved_partner_entity_id) END)
                                                      AS ap_direction_count,
  MIN(CASE WHEN match_side='AR' THEN owner_entity_id END)
                                                      AS ar_owner,
  MIN(CASE WHEN match_side='AR' THEN resolved_partner_entity_id END)
                                                      AS ar_partner,
  MIN(CASE WHEN match_side='AP' THEN owner_entity_id END)
                                                      AS ap_owner,
  MIN(CASE WHEN match_side='AP' THEN resolved_partner_entity_id END)
                                                      AS ap_partner,
  CAST(SUM(CASE WHEN match_side='AR' THEN signed_amount_dc ELSE 0 END)
       AS DECIMAL(38,6))                             AS ar_total_dc,
  CAST(SUM(CASE WHEN match_side='AP' THEN signed_amount_dc ELSE 0 END)
       AS DECIMAL(38,6))                             AS ap_total_dc,
  CAST(SUM(signed_amount_dc) AS DECIMAL(38,6))       AS residual_dc,
  CASE
    WHEN SUM(CASE WHEN match_side='AR' THEN 1 ELSE 0 END)=0
      OR SUM(CASE WHEN match_side='AP' THEN 1 ELSE 0 END)=0
      THEN 'BVORG_ONE_SIDED'
    WHEN COUNT(DISTINCT entity_lo)<>1 OR COUNT(DISTINCT entity_hi)<>1
      THEN 'BVORG_MULTIPLE_ENTITY_PAIRS'
    WHEN COUNT(DISTINCT CASE WHEN match_side='AR'
         THEN CONCAT_WS('>',owner_entity_id,resolved_partner_entity_id) END)<>1
      OR COUNT(DISTINCT CASE WHEN match_side='AP'
         THEN CONCAT_WS('>',owner_entity_id,resolved_partner_entity_id) END)<>1
      THEN 'BVORG_AMBIGUOUS_DIRECTION'
    WHEN NOT (
      MIN(CASE WHEN match_side='AR' THEN owner_entity_id END)=
        MIN(CASE WHEN match_side='AP' THEN resolved_partner_entity_id END)
      AND
      MIN(CASE WHEN match_side='AR' THEN resolved_partner_entity_id END)=
        MIN(CASE WHEN match_side='AP' THEN owner_entity_id END)
    ) THEN 'BVORG_NONRECIPROCAL'
    WHEN CAST(SUM(signed_amount_dc) AS DECIMAL(38,6))=CAST(0 AS DECIMAL(38,6))
      THEN 'SUGGESTED_BVORG_EXACT_SOURCE_SCOPED'
    ELSE 'SUGGESTED_BVORG_LINKED_RESIDUAL'
  END                                                AS group_status
FROM ic_v3_bvorg_group_member
GROUP BY match_group_id, source_system_id, source_client,
         document_currency, normalized_reference,
         reconciliation_run_id, rule_version;

CREATE OR REPLACE TEMP VIEW ic_v3_bvorg_selected_member AS
SELECT
  m.match_group_id, m.source_item_id,
  g.group_status                                     AS match_status,
  'BVORG'                                            AS match_rule_id
FROM ic_v3_bvorg_group_member m
JOIN ic_v3_bvorg_group g
  ON g.match_group_id=m.match_group_id;

CREATE OR REPLACE TEMP VIEW ic_v3_reference_group_member AS
SELECT
  SHA2(CONCAT_WS('||',i.reconciliation_run_id,'ZUONR',i.source_system_id,
       i.source_client,i.entity_lo,i.entity_hi,i.document_currency,
       i.normalized_assignment_reference),256)       AS match_group_id,
  i.source_item_id, i.source_system_id, i.source_client,
  i.match_side, i.owner_entity_id, i.resolved_partner_entity_id,
  i.entity_lo, i.entity_hi, i.document_currency, i.signed_amount_dc,
  i.normalized_assignment_reference                  AS normalized_reference,
  i.reconciliation_run_id, i.rule_version
FROM ic_v3_match_eligible_item i
LEFT ANTI JOIN ic_v3_bvorg_selected_member b
  ON b.source_item_id=i.source_item_id
WHERE i.normalized_assignment_reference IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_reference_group AS
SELECT
  match_group_id, source_system_id, source_client,
  entity_lo, entity_hi, document_currency, normalized_reference,
  reconciliation_run_id, rule_version,
  COUNT(*)                                           AS member_count,
  SUM(CASE WHEN match_side='AR' THEN 1 ELSE 0 END)   AS ar_count,
  SUM(CASE WHEN match_side='AP' THEN 1 ELSE 0 END)   AS ap_count,
  COUNT(DISTINCT CASE WHEN match_side='AR'
       THEN CONCAT_WS('>',owner_entity_id,resolved_partner_entity_id) END)
                                                      AS ar_direction_count,
  COUNT(DISTINCT CASE WHEN match_side='AP'
       THEN CONCAT_WS('>',owner_entity_id,resolved_partner_entity_id) END)
                                                      AS ap_direction_count,
  MIN(CASE WHEN match_side='AR' THEN owner_entity_id END)
                                                      AS ar_owner,
  MIN(CASE WHEN match_side='AR' THEN resolved_partner_entity_id END)
                                                      AS ar_partner,
  MIN(CASE WHEN match_side='AP' THEN owner_entity_id END)
                                                      AS ap_owner,
  MIN(CASE WHEN match_side='AP' THEN resolved_partner_entity_id END)
                                                      AS ap_partner,
  CAST(SUM(CASE WHEN match_side='AR' THEN signed_amount_dc ELSE 0 END)
       AS DECIMAL(38,6))                             AS ar_total_dc,
  CAST(SUM(CASE WHEN match_side='AP' THEN signed_amount_dc ELSE 0 END)
       AS DECIMAL(38,6))                             AS ap_total_dc,
  CAST(SUM(signed_amount_dc) AS DECIMAL(38,6))       AS residual_dc,
  CASE
    WHEN SUM(CASE WHEN match_side='AR' THEN 1 ELSE 0 END)=0
      OR SUM(CASE WHEN match_side='AP' THEN 1 ELSE 0 END)=0
      THEN 'SUGGESTED_REFERENCE_ONE_SIDED'
    WHEN COUNT(DISTINCT CASE WHEN match_side='AR'
         THEN CONCAT_WS('>',owner_entity_id,resolved_partner_entity_id) END)<>1
      OR COUNT(DISTINCT CASE WHEN match_side='AP'
         THEN CONCAT_WS('>',owner_entity_id,resolved_partner_entity_id) END)<>1
      THEN 'SUGGESTED_REFERENCE_AMBIGUOUS_DIRECTION'
    WHEN NOT (
      MIN(CASE WHEN match_side='AR' THEN owner_entity_id END)=
        MIN(CASE WHEN match_side='AP' THEN resolved_partner_entity_id END)
      AND
      MIN(CASE WHEN match_side='AR' THEN resolved_partner_entity_id END)=
        MIN(CASE WHEN match_side='AP' THEN owner_entity_id END)
    ) THEN 'SUGGESTED_REFERENCE_NONRECIPROCAL'
    WHEN CAST(SUM(signed_amount_dc) AS DECIMAL(38,6))=CAST(0 AS DECIMAL(38,6))
     AND SUM(CASE WHEN match_side='AR' THEN 1 ELSE 0 END)=1
     AND SUM(CASE WHEN match_side='AP' THEN 1 ELSE 0 END)=1
      THEN 'SUGGESTED_REFERENCE_1_TO_1_EXACT_UNGOVERNED'
    WHEN CAST(SUM(signed_amount_dc) AS DECIMAL(38,6))=CAST(0 AS DECIMAL(38,6))
      THEN 'SUGGESTED_REFERENCE_M_TO_N_EXACT'
    ELSE 'SUGGESTED_REFERENCE_RESIDUAL'
  END                                                AS group_status
FROM ic_v3_reference_group_member
GROUP BY match_group_id, source_system_id, source_client,
         entity_lo, entity_hi, document_currency, normalized_reference,
         reconciliation_run_id, rule_version;

CREATE OR REPLACE TEMP VIEW ic_v3_match_group AS
SELECT
  match_group_id, 'BVORG' AS match_rule_id,
  source_system_id, source_client,
  CAST(NULL AS STRING) AS entity_lo,
  CAST(NULL AS STRING) AS entity_hi,
  document_currency, normalized_reference,
  member_count, ar_count, ap_count,
  ar_total_dc, ap_total_dc, residual_dc, group_status,
  reconciliation_run_id, rule_version
FROM ic_v3_bvorg_group

UNION ALL

SELECT
  match_group_id, 'ZUONR', source_system_id, source_client,
  entity_lo, entity_hi, document_currency, normalized_reference,
  member_count, ar_count, ap_count,
  ar_total_dc, ap_total_dc, residual_dc, group_status,
  reconciliation_run_id, rule_version
FROM ic_v3_reference_group;

CREATE OR REPLACE TEMP VIEW ic_v3_match_membership AS
SELECT
  b.source_item_id, b.match_group_id,
  b.match_status, b.match_rule_id
FROM ic_v3_bvorg_selected_member b

UNION ALL

SELECT
  m.source_item_id, m.match_group_id,
  g.group_status AS match_status,
  'ZUONR' AS match_rule_id
FROM ic_v3_reference_group_member m
JOIN ic_v3_reference_group g
  ON g.match_group_id=m.match_group_id

UNION ALL

SELECT
  i.source_item_id,
  CAST(NULL AS STRING)                               AS match_group_id,
  'UNMATCHED'                                        AS match_status,
  CAST(NULL AS STRING)                               AS match_rule_id
FROM ic_v3_match_eligible_item i
LEFT ANTI JOIN (
  SELECT source_item_id FROM ic_v3_bvorg_selected_member
  UNION ALL
  SELECT source_item_id FROM ic_v3_reference_group_member
) m ON m.source_item_id=i.source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_match_membership_control AS
SELECT
  i.source_item_id,
  COUNT(m.source_item_id)                            AS membership_count,
  SUM(CASE
    WHEN m.source_item_id IS NOT NULL
     AND COALESCE(m.match_status,'MISSING_MATCH_STATUS') NOT IN (
       'UNMATCHED',
       'SUGGESTED_BVORG_EXACT_SOURCE_SCOPED',
       'SUGGESTED_BVORG_LINKED_RESIDUAL',
       'BVORG_ONE_SIDED','BVORG_MULTIPLE_ENTITY_PAIRS',
       'BVORG_AMBIGUOUS_DIRECTION','BVORG_NONRECIPROCAL',
       'SUGGESTED_REFERENCE_ONE_SIDED',
       'SUGGESTED_REFERENCE_AMBIGUOUS_DIRECTION',
       'SUGGESTED_REFERENCE_NONRECIPROCAL',
       'SUGGESTED_REFERENCE_1_TO_1_EXACT_UNGOVERNED',
       'SUGGESTED_REFERENCE_M_TO_N_EXACT',
       'SUGGESTED_REFERENCE_RESIDUAL')
    THEN 1 ELSE 0 END)                               AS invalid_match_status_count,
  SUM(CASE
    WHEN m.source_item_id IS NULL THEN 0
    WHEN m.match_status='UNMATCHED'
     AND (m.match_group_id IS NOT NULL OR m.match_rule_id IS NOT NULL) THEN 1
    WHEN m.match_status LIKE '%BVORG%'
     AND (NULLIF(TRIM(m.match_group_id),'') IS NULL
          OR COALESCE(m.match_rule_id,'MISSING_MATCH_RULE')<>'BVORG') THEN 1
    WHEN m.match_status LIKE 'SUGGESTED_REFERENCE%'
     AND (NULLIF(TRIM(m.match_group_id),'') IS NULL
          OR COALESCE(m.match_rule_id,'MISSING_MATCH_RULE')<>'ZUONR') THEN 1
    WHEN COALESCE(m.match_status,'MISSING_MATCH_STATUS')<>'UNMATCHED'
     AND m.match_status NOT LIKE '%BVORG%'
     AND m.match_status NOT LIKE 'SUGGESTED_REFERENCE%' THEN 1
    ELSE 0 END)                                      AS invalid_match_rule_count,
  CASE
    WHEN COUNT(m.source_item_id)<>1 THEN 'FAIL_MEMBERSHIP_CARDINALITY'
    WHEN SUM(CASE
      WHEN COALESCE(m.match_status,'MISSING_MATCH_STATUS') NOT IN (
        'UNMATCHED',
        'SUGGESTED_BVORG_EXACT_SOURCE_SCOPED',
        'SUGGESTED_BVORG_LINKED_RESIDUAL',
        'BVORG_ONE_SIDED','BVORG_MULTIPLE_ENTITY_PAIRS',
        'BVORG_AMBIGUOUS_DIRECTION','BVORG_NONRECIPROCAL',
        'SUGGESTED_REFERENCE_ONE_SIDED',
        'SUGGESTED_REFERENCE_AMBIGUOUS_DIRECTION',
        'SUGGESTED_REFERENCE_NONRECIPROCAL',
        'SUGGESTED_REFERENCE_1_TO_1_EXACT_UNGOVERNED',
        'SUGGESTED_REFERENCE_M_TO_N_EXACT',
        'SUGGESTED_REFERENCE_RESIDUAL')
      THEN 1 ELSE 0 END)>0 THEN 'FAIL_MATCH_STATUS_DOMAIN'
    WHEN SUM(CASE
      WHEN m.match_status='UNMATCHED'
       AND (m.match_group_id IS NOT NULL OR m.match_rule_id IS NOT NULL) THEN 1
      WHEN m.match_status LIKE '%BVORG%'
       AND (NULLIF(TRIM(m.match_group_id),'') IS NULL
            OR COALESCE(m.match_rule_id,'MISSING_MATCH_RULE')<>'BVORG') THEN 1
      WHEN m.match_status LIKE 'SUGGESTED_REFERENCE%'
       AND (NULLIF(TRIM(m.match_group_id),'') IS NULL
            OR COALESCE(m.match_rule_id,'MISSING_MATCH_RULE')<>'ZUONR') THEN 1
      WHEN COALESCE(m.match_status,'MISSING_MATCH_STATUS')<>'UNMATCHED'
       AND m.match_status NOT LIKE '%BVORG%'
       AND m.match_status NOT LIKE 'SUGGESTED_REFERENCE%' THEN 1
      ELSE 0 END)>0 THEN 'FAIL_MATCH_RULE_LINEAGE'
    ELSE 'PASS'
  END                                                AS membership_control_status
FROM ic_v3_match_eligible_item i
LEFT JOIN ic_v3_match_membership m
  ON m.source_item_id=i.source_item_id
GROUP BY i.source_item_id;

-- ============================================================================
-- 6. FX RESOLUTION FOR REPORTING ONLY
--    Transaction matching above never depends on translated currency.
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_fx_rate_normalized AS
SELECT DISTINCT
  UPPER(TRIM(CAST(From_Curr AS STRING)))              AS from_currency,
  UPPER(TRIM(CAST(To_Curr AS STRING)))                AS to_currency,
  UPPER(TRIM(CAST(Rate_Type AS STRING)))              AS rate_type,
  TRY_CAST(Date_From AS DATE)                         AS valid_from,
  TRY_CAST(Date_To AS DATE)                           AS valid_to_inclusive,
  TRY_CAST(Exchange_Rate AS DECIMAL(38,12))           AS raw_exchange_rate,
  CASE WHEN UPPER(TRIM(CAST(Rate_Type AS STRING)))='CPM' THEN 10
       WHEN UPPER(TRIM(CAST(Rate_Type AS STRING)))='1001' THEN 20
       ELSE 99 END                                    AS rate_priority,
  SHA2(CONCAT_WS('||',
       UPPER(TRIM(CAST(From_Curr AS STRING))),
       UPPER(TRIM(CAST(To_Curr AS STRING))),
       UPPER(TRIM(CAST(Rate_Type AS STRING))),
       CAST(TRY_CAST(Date_From AS DATE) AS STRING),
       CAST(TRY_CAST(Date_To AS DATE) AS STRING),
       CAST(TRY_CAST(Exchange_Rate AS DECIMAL(38,12)) AS STRING)),256)
                                                      AS fx_rate_id
FROM ocs.pharos_silver.r_ecc_forex_table f
CROSS JOIN ic_v3_params p
WHERE UPPER(TRIM(CAST(f.To_Curr AS STRING)))=p.reporting_currency
  AND UPPER(TRIM(CAST(f.Rate_Type AS STRING))) IN ('CPM','1001')
  AND NULLIF(TRIM(CAST(f.From_Curr AS STRING)),'') IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_fx_candidate AS
SELECT
  i.source_item_id, r.fx_rate_id, r.rate_type, r.rate_priority,
  r.valid_from, r.valid_to_inclusive, r.raw_exchange_rate
FROM ic_v3_item_fact i
CROSS JOIN ic_v3_params p
JOIN ic_v3_fx_rate_normalized r
  ON r.from_currency=UPPER(TRIM(i.document_currency))
 AND r.to_currency=p.reporting_currency
 AND i.posting_date>=r.valid_from
 AND i.posting_date<=r.valid_to_inclusive
WHERE UPPER(TRIM(i.document_currency))<>p.reporting_currency;

CREATE OR REPLACE TEMP VIEW ic_v3_fx_selected_priority AS
SELECT source_item_id, MIN(rate_priority) AS selected_priority
FROM ic_v3_fx_candidate
GROUP BY source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_fx_candidate_control AS
SELECT
  i.source_item_id,
  COUNT(DISTINCT CASE WHEN c.rate_priority=s.selected_priority
                      THEN c.fx_rate_id END)          AS selected_rate_row_count,
  COUNT(DISTINCT CASE WHEN c.rate_priority=s.selected_priority
                      THEN c.raw_exchange_rate END)   AS selected_rate_value_count,
  MIN(CASE WHEN c.rate_priority=s.selected_priority
           THEN c.raw_exchange_rate END)             AS selected_raw_exchange_rate,
  MIN(CASE WHEN c.rate_priority=s.selected_priority
           THEN c.rate_type END)                     AS selected_rate_type,
  s.selected_priority
FROM ic_v3_item_fact i
LEFT JOIN ic_v3_fx_selected_priority s
  ON s.source_item_id=i.source_item_id
LEFT JOIN ic_v3_fx_candidate c
  ON c.source_item_id=i.source_item_id
GROUP BY i.source_item_id, s.selected_priority;

CREATE OR REPLACE TEMP VIEW ic_v3_item_fx AS
SELECT
  i.source_item_id,
  i.document_currency,
  p.reporting_currency,
  c.selected_rate_type,
  c.selected_raw_exchange_rate,
  CASE
    WHEN UPPER(TRIM(i.document_currency))=p.reporting_currency
      THEN 'NATIVE_REPORTING_CURRENCY'
    WHEN c.selected_rate_row_count=0 THEN 'MISSING_RATE'
    WHEN c.selected_rate_row_count>1
      OR c.selected_rate_value_count>1 THEN 'AMBIGUOUS_RATE'
    WHEN c.selected_raw_exchange_rate IS NULL
      OR c.selected_raw_exchange_rate<=0 THEN 'INVALID_RATE'
    WHEN COALESCE(p.fx_multiplier_contract_approved,FALSE)=FALSE
      THEN 'UNAPPROVED_QUOTATION_OR_FACTOR_SEMANTICS'
    ELSE 'RESOLVED'
  END                                                AS fx_status,
  CASE
    WHEN UPPER(TRIM(i.document_currency))=p.reporting_currency
      THEN CAST(1 AS DECIMAL(38,12))
    WHEN c.selected_rate_row_count=1
     AND c.selected_rate_value_count=1
     AND c.selected_raw_exchange_rate>0
     AND COALESCE(p.fx_multiplier_contract_approved,FALSE)=TRUE
      THEN c.selected_raw_exchange_rate
  END                                                AS approved_direct_multiplier,
  CASE
    WHEN UPPER(TRIM(i.document_currency))=p.reporting_currency
      THEN CAST(i.signed_amount_dc AS DECIMAL(38,6))
    WHEN c.selected_rate_row_count=1
     AND c.selected_rate_value_count=1
     AND c.selected_raw_exchange_rate>0
     AND COALESCE(p.fx_multiplier_contract_approved,FALSE)=TRUE
      THEN CAST(i.signed_amount_dc*c.selected_raw_exchange_rate AS DECIMAL(38,6))
  END                                                AS signed_amount_reporting,
  p.fx_version
FROM ic_v3_item_fact i
CROSS JOIN ic_v3_params p
LEFT JOIN ic_v3_fx_candidate_control c
  ON c.source_item_id=i.source_item_id;

-- ============================================================================
-- 7. CERTIFIABLE LEGAL-PAIR AND MANAGEMENT OUTPUTS
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_pair_currency_summary AS
SELECT
  i.reconciliation_run_id, i.as_of_date, i.cutoff_exclusive,
  i.rule_version,
  LEAST(i.owner_entity_id,i.resolved_partner_entity_id) AS entity_lo,
  GREATEST(i.owner_entity_id,i.resolved_partner_entity_id) AS entity_hi,
  i.document_currency,
  COUNT(*)                                           AS item_count,
  SUM(CASE WHEN i.match_side='AR' THEN 1 ELSE 0 END) AS ar_item_count,
  SUM(CASE WHEN i.match_side='AP' THEN 1 ELSE 0 END) AS ap_item_count,
  CAST(SUM(CASE WHEN i.match_side='AR' THEN i.signed_amount_dc ELSE 0 END)
       AS DECIMAL(38,6))                             AS ar_amount_dc,
  CAST(SUM(CASE WHEN i.match_side='AP' THEN i.signed_amount_dc ELSE 0 END)
       AS DECIMAL(38,6))                             AS ap_amount_dc,
  CAST(SUM(i.signed_amount_dc) AS DECIMAL(38,6))     AS arap_net_dc,
  CAST(SUM(ABS(i.signed_amount_dc)) AS DECIMAL(38,6)) AS gross_exposure_dc,
  CAST(0 AS DECIMAL(38,6))                            AS confirmed_gross_dc,
  CAST(SUM(CASE
    WHEN m.match_status IN (
      'SUGGESTED_BVORG_EXACT_SOURCE_SCOPED',
      'SUGGESTED_BVORG_LINKED_RESIDUAL',
      'SUGGESTED_REFERENCE_1_TO_1_EXACT_UNGOVERNED',
      'SUGGESTED_REFERENCE_M_TO_N_EXACT',
      'SUGGESTED_REFERENCE_RESIDUAL')
    THEN ABS(i.signed_amount_dc) ELSE 0 END) AS DECIMAL(38,6))
                                                      AS suggested_gross_dc,
  CAST(SUM(CASE WHEN m.match_status='UNMATCHED'
                THEN ABS(i.signed_amount_dc) ELSE 0 END) AS DECIMAL(38,6))
                                                      AS unmatched_gross_dc,
  CAST(SUM(CASE
    WHEN COALESCE(m.match_status,'MISSING_MATCH_STATUS') NOT IN (
      'UNMATCHED',
      'SUGGESTED_BVORG_EXACT_SOURCE_SCOPED',
      'SUGGESTED_BVORG_LINKED_RESIDUAL',
      'SUGGESTED_REFERENCE_1_TO_1_EXACT_UNGOVERNED',
      'SUGGESTED_REFERENCE_M_TO_N_EXACT',
      'SUGGESTED_REFERENCE_RESIDUAL')
    THEN ABS(i.signed_amount_dc) ELSE 0 END) AS DECIMAL(38,6))
                                                      AS invalid_group_gross_dc,
  CASE
    WHEN SUM(CASE
      WHEN COALESCE(m.match_status,'MISSING_MATCH_STATUS') NOT IN (
        'UNMATCHED',
        'SUGGESTED_BVORG_EXACT_SOURCE_SCOPED',
        'SUGGESTED_BVORG_LINKED_RESIDUAL',
        'SUGGESTED_REFERENCE_1_TO_1_EXACT_UNGOVERNED',
        'SUGGESTED_REFERENCE_M_TO_N_EXACT',
        'SUGGESTED_REFERENCE_RESIDUAL')
      THEN 1 ELSE 0 END)>0
      THEN 'INVALID_MATCH_GROUP_EVIDENCE_EXPOSED'
    WHEN CAST(SUM(i.signed_amount_dc) AS DECIMAL(38,6))=CAST(0 AS DECIMAL(38,6))
      THEN 'ZERO_NET_UNASSIGNED_RISK'
    ELSE 'OUT_OF_BALANCE'
  END                                                AS pair_status
FROM ic_v3_item_fact i
JOIN ic_v3_match_membership m
  ON m.source_item_id=i.source_item_id
WHERE i.owner_entity_status='RESOLVED_SOURCE_LOCAL_ENTITY'
  AND i.partner_match_eligible
GROUP BY i.reconciliation_run_id, i.as_of_date, i.cutoff_exclusive,
         i.rule_version,
         LEAST(i.owner_entity_id,i.resolved_partner_entity_id),
         GREATEST(i.owner_entity_id,i.resolved_partner_entity_id),
         i.document_currency;

CREATE OR REPLACE TEMP VIEW ic_v3_pair_reporting_summary AS
SELECT
  i.reconciliation_run_id, i.as_of_date, i.cutoff_exclusive,
  LEAST(i.owner_entity_id,i.resolved_partner_entity_id) AS entity_lo,
  GREATEST(i.owner_entity_id,i.resolved_partner_entity_id) AS entity_hi,
  f.reporting_currency,
  COUNT(*)                                           AS item_count,
  SUM(CASE WHEN f.fx_status IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
           THEN 0 ELSE 1 END)                        AS unresolved_fx_item_count,
  CAST(SUM(CASE WHEN f.fx_status IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
                THEN 0 ELSE ABS(i.signed_amount_dc) END) AS DECIMAL(38,6))
                                                      AS unresolved_fx_gross_dc,
  CAST(SUM(f.signed_amount_reporting) AS DECIMAL(38,6))
                                                      AS partial_arap_net_reporting,
  CASE
    WHEN SUM(CASE WHEN f.fx_status IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
                  THEN 0 ELSE 1 END)=0
      THEN 'COMPLETE'
    ELSE 'INCOMPLETE_FX_DO_NOT_CERTIFY_TOTAL'
  END                                                AS reporting_total_status
FROM ic_v3_item_fact i
JOIN ic_v3_item_fx f ON f.source_item_id=i.source_item_id
WHERE i.owner_entity_status='RESOLVED_SOURCE_LOCAL_ENTITY'
  AND i.partner_match_eligible
GROUP BY i.reconciliation_run_id, i.as_of_date, i.cutoff_exclusive,
         LEAST(i.owner_entity_id,i.resolved_partner_entity_id),
         GREATEST(i.owner_entity_id,i.resolved_partner_entity_id),
         f.reporting_currency;

CREATE OR REPLACE TEMP VIEW ic_v3_partner_exception_summary AS
SELECT
  reconciliation_run_id, as_of_date, cutoff_exclusive,
  source_system_id, source_client, match_side,
  partner_resolution_status, document_currency,
  COUNT(*)                                           AS item_count,
  CAST(SUM(signed_amount_dc) AS DECIMAL(38,6))       AS signed_amount_dc,
  CAST(SUM(ABS(signed_amount_dc)) AS DECIMAL(38,6))  AS gross_exposure_dc
FROM ic_v3_item_fact
WHERE NOT COALESCE(partner_match_eligible,FALSE)
   OR COALESCE(owner_entity_status,'OWNER_ENTITY_STATUS_MISSING')
        <>'RESOLVED_SOURCE_LOCAL_ENTITY'
GROUP BY reconciliation_run_id, as_of_date, cutoff_exclusive,
         source_system_id, source_client, match_side,
         partner_resolution_status, document_currency;

-- A separate hypothesis surface makes missing-VBUND recovery useful without
-- contaminating the official pair result. It uses only one distinct diagnostic
-- candidate per item and remains non-publishable until its evidence rule is
-- effective-dated, backtested and promoted through controlled code.
CREATE OR REPLACE TEMP VIEW ic_v3_diagnostic_partner_candidate_pair_summary AS
SELECT
  reconciliation_run_id, as_of_date, cutoff_exclusive,
  source_system_id, source_client,
  LEAST(owner_entity_id,diagnostic_partner_entity_id) AS candidate_entity_lo,
  GREATEST(owner_entity_id,diagnostic_partner_entity_id) AS candidate_entity_hi,
  document_currency,
  COUNT(*)                                           AS candidate_item_count,
  SUM(CASE WHEN match_side='AR' THEN 1 ELSE 0 END)   AS candidate_ar_item_count,
  SUM(CASE WHEN match_side='AP' THEN 1 ELSE 0 END)   AS candidate_ap_item_count,
  CAST(SUM(CASE WHEN match_side='AR' THEN signed_amount_dc ELSE 0 END)
       AS DECIMAL(38,6))                             AS candidate_ar_amount_dc,
  CAST(SUM(CASE WHEN match_side='AP' THEN signed_amount_dc ELSE 0 END)
       AS DECIMAL(38,6))                             AS candidate_ap_amount_dc,
  CAST(SUM(signed_amount_dc) AS DECIMAL(38,6))       AS candidate_arap_net_dc,
  CAST(SUM(ABS(signed_amount_dc)) AS DECIMAL(38,6)) AS candidate_gross_dc,
  CASE WHEN CAST(SUM(signed_amount_dc) AS DECIMAL(38,6))=CAST(0 AS DECIMAL(38,6))
       THEN 'DIAGNOSTIC_ZERO_NET_NOT_RECONCILED'
       ELSE 'DIAGNOSTIC_OUT_OF_BALANCE' END          AS candidate_pair_status,
  'SINGLE_DISTINCT_CANDIDATE_NOT_APPROVED_FOR_OFFICIAL_OOB'
                                                      AS diagnostic_limit
FROM ic_v3_item_fact
WHERE header_status='RESOLVED'
  AND raw_amount_status='NONNEGATIVE_RAW_AMOUNT'
  AND signed_amount_dc IS NOT NULL AND signed_amount_lc IS NOT NULL
  AND owner_entity_status='RESOLVED_SOURCE_LOCAL_ENTITY'
  AND partner_resolution_status='DERIVED_UNIQUE_DIAGNOSTIC'
  AND diagnostic_partner_entity_id IS NOT NULL
  AND diagnostic_partner_entity_id<>owner_entity_id
GROUP BY reconciliation_run_id, as_of_date, cutoff_exclusive,
         source_system_id, source_client,
         LEAST(owner_entity_id,diagnostic_partner_entity_id),
         GREATEST(owner_entity_id,diagnostic_partner_entity_id),
         document_currency;

CREATE OR REPLACE TEMP VIEW ic_v3_item_population_bucket AS
SELECT
  source_item_id, reconciliation_run_id, as_of_date, cutoff_exclusive,
  source_system_id, source_client, company_code, match_side,
  COALESCE(NULLIF(TRIM(document_currency),''),'<MISSING>') AS currency_bucket,
  signed_amount_dc,
  CASE
    WHEN document_currency IS NULL OR TRIM(document_currency)=''
      OR COALESCE(raw_amount_status,'MISSING_RAW_AMOUNT_STATUS')
           <>'NONNEGATIVE_RAW_AMOUNT'
      OR signed_amount_dc IS NULL OR signed_amount_lc IS NULL
      OR debit_credit_code NOT IN ('S','H') OR debit_credit_code IS NULL
      THEN 'DATA_QUALITY_EXCEPTION'
    WHEN COALESCE(header_status,'HEADER_STATUS_MISSING')<>'RESOLVED'
      THEN 'HEADER_EXCEPTION'
    WHEN COALESCE(owner_entity_status,'OWNER_ENTITY_STATUS_MISSING')
         <>'RESOLVED_SOURCE_LOCAL_ENTITY'
      THEN 'OWNER_ENTITY_EXCEPTION'
    WHEN NOT COALESCE(partner_match_eligible,FALSE) THEN 'PARTNER_EXCEPTION'
    ELSE 'RESOLVED_PAIR_POPULATION'
  END                                                AS population_bucket
FROM ic_v3_item_fact;

CREATE OR REPLACE TEMP VIEW ic_v3_population_bridge AS
SELECT
  reconciliation_run_id, as_of_date, cutoff_exclusive,
  source_system_id, source_client, currency_bucket, population_bucket,
  COUNT(*)                                           AS item_count,
  CAST(SUM(signed_amount_dc) AS DECIMAL(38,6))       AS signed_amount_dc,
  CAST(SUM(ABS(signed_amount_dc)) AS DECIMAL(38,6))  AS gross_amount_dc
FROM ic_v3_item_population_bucket
GROUP BY reconciliation_run_id, as_of_date, cutoff_exclusive,
         source_system_id, source_client, currency_bucket, population_bucket;

CREATE OR REPLACE TEMP VIEW ic_v3_confirmed_one_to_one_group AS
SELECT match_group_id
FROM ic_v3_match_group
-- No transaction-reference rule in this sandbox is certified for automatic
-- counterpart attribution. Promotion requires a versioned, backtested rule.
WHERE FALSE;

CREATE OR REPLACE TEMP VIEW ic_v3_counterpart_item AS
SELECT
  a.source_item_id,
  b.source_item_id                                  AS counterpart_source_item_id,
  a.match_group_id
FROM ic_v3_match_membership a
JOIN ic_v3_confirmed_one_to_one_group g
  ON g.match_group_id=a.match_group_id
JOIN ic_v3_match_membership b
  ON b.match_group_id=a.match_group_id
 AND b.source_item_id<>a.source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_counterpart_org_control AS
SELECT
  c.source_item_id,
  c.counterpart_source_item_id,
  COUNT(DISTINCT a.owner_operating_unit)             AS counterpart_ou_count,
  COUNT(DISTINCT a.owner_business_unit)              AS counterpart_bu_count,
  MIN(a.owner_operating_unit)                        AS sole_counterpart_ou,
  MIN(a.owner_business_unit)                         AS sole_counterpart_bu,
  SUM(CASE WHEN a.allocation_status='ALLOCATED_AND_MAPPED'
           THEN 0 ELSE 1 END)                        AS incomplete_allocation_row_count,
  CAST(SUM(CASE WHEN a.allocation_status='ALLOCATED_AND_MAPPED'
                THEN 0 ELSE ABS(a.allocated_amount_dc) END) AS DECIMAL(38,6))
                                                      AS incomplete_allocation_gross_dc
FROM ic_v3_counterpart_item c
LEFT JOIN ic_v3_item_allocation a
  ON a.source_item_id=c.counterpart_source_item_id
GROUP BY c.source_item_id, c.counterpart_source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_management_allocation_detail AS
SELECT
  i.reconciliation_run_id, i.as_of_date, i.cutoff_exclusive,
  i.source_item_id, i.match_side, i.company_code,
  i.owner_entity_id, i.resolved_partner_entity_id,
  i.document_currency, i.signed_amount_dc,
  m.match_group_id, m.match_rule_id, m.match_status,
  a.allocation_id, a.owner_profit_center_raw,
  a.owner_operating_unit, a.owner_business_unit,
  a.allocation_method, a.allocation_status,
  a.allocated_amount_dc, a.allocated_amount_lc,
  'LOCAL_CURRENCY_CODE_NOT_INGESTED_DO_NOT_AGGREGATE_ACROSS_COMPANIES'
                                                      AS local_currency_status,
  CASE WHEN c.counterpart_ou_count=1
             AND c.incomplete_allocation_row_count=0
       THEN c.sole_counterpart_ou END
                                                      AS partner_operating_unit,
  CASE WHEN c.counterpart_bu_count=1
             AND c.incomplete_allocation_row_count=0
       THEN c.sole_counterpart_bu END
                                                      AS partner_business_unit,
  CASE
    WHEN c.source_item_id IS NULL THEN 'NO_CONFIRMED_1_TO_1_COUNTERPART'
    WHEN c.counterpart_ou_count=1 AND c.counterpart_bu_count=1
     AND c.incomplete_allocation_row_count=0
      THEN 'COUNTERPART_ORG_UNIQUE'
    ELSE 'COUNTERPART_SPLIT_OR_MAPPING_AMBIGUOUS'
  END                                                AS partner_org_status
FROM ic_v3_item_fact i
JOIN ic_v3_item_allocation a ON a.source_item_id=i.source_item_id
LEFT JOIN ic_v3_match_membership m ON m.source_item_id=i.source_item_id
LEFT JOIN ic_v3_counterpart_org_control c
  ON c.source_item_id=i.source_item_id;

-- The separate diagnostic exposes manual-account population without pretending
-- that a one-year movement window is an open-item balance.
CREATE OR REPLACE TEMP VIEW ic_v3_manual_gl_diagnostic AS
SELECT
  p.reconciliation_run_id, p.as_of_date, p.cutoff_exclusive,
  p.source_system_id, CAST(b.MANDT AS STRING) AS source_client,
  SHA2(CONCAT_WS('||',p.source_system_id,CAST(b.MANDT AS STRING),
       CAST(b.BUKRS AS STRING),CAST(b.GJAHR AS STRING),
       CAST(b.BELNR AS STRING),CAST(b.BUZEI AS STRING)),256)
                                                      AS source_item_id,
  CAST(b.BUKRS AS STRING) AS company_code,
  CAST(b.GJAHR AS STRING) AS fiscal_year,
  CAST(b.BELNR AS STRING) AS accounting_document,
  CAST(b.BUZEI AS STRING) AS line_item_number,
  CAST(b.HKONT AS STRING) AS gl_account,
  CAST(h.BLART AS STRING) AS document_type,
  TRY_CAST(h.BUDAT AS DATE) AS posting_date,
  NULLIF(UPPER(TRIM(CAST(b.VBUND AS STRING))),'') AS posted_partner_raw,
  NULLIF(UPPER(TRIM(CAST(h.WAERS AS STRING))),'') AS document_currency,
  TRY_CAST(b.WRBTR AS DECIMAL(38,6)) AS raw_amount_dc,
  TRY_CAST(b.DMBTR AS DECIMAL(38,6)) AS raw_amount_lc,
  CASE
    WHEN TRY_CAST(b.WRBTR AS DECIMAL(38,6)) IS NULL
      OR TRY_CAST(b.DMBTR AS DECIMAL(38,6)) IS NULL
      THEN 'MISSING_OR_INVALID_RAW_AMOUNT'
    WHEN TRY_CAST(b.WRBTR AS DECIMAL(38,6))<0
      OR TRY_CAST(b.DMBTR AS DECIMAL(38,6))<0
      THEN 'NEGATIVE_RAW_AMOUNT'
    WHEN CAST(b.SHKZG AS STRING) NOT IN ('S','H') OR b.SHKZG IS NULL
      THEN 'INVALID_DEBIT_CREDIT_CODE'
    ELSE 'NONNEGATIVE_RAW_AMOUNT'
  END AS raw_amount_status,
  CAST(CASE WHEN b.SHKZG='S' AND TRY_CAST(b.WRBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(b.WRBTR AS DECIMAL(38,6))
            WHEN b.SHKZG='H' AND TRY_CAST(b.WRBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(b.WRBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                      AS signed_amount_dc,
  CAST(CASE WHEN b.SHKZG='S' AND TRY_CAST(b.DMBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(b.DMBTR AS DECIMAL(38,6))
            WHEN b.SHKZG='H' AND TRY_CAST(b.DMBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(b.DMBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                      AS signed_amount_lc,
  s.scope_status,
  'EXCLUDED_FROM_CERTIFIED_ARAP_UNTIL_POSITION_SEMANTICS_APPROVED'
                                                      AS publication_status
FROM qlk_c.c_ocs_ecc_old.bseg b
JOIN qlk_c.c_ocs_ecc_old.bkpf h
  ON h.MANDT=b.MANDT AND h.BUKRS=b.BUKRS
 AND h.GJAHR=b.GJAHR AND h.BELNR=b.BELNR
CROSS JOIN ic_v3_params p
JOIN ic_v3_manual_account_scope s
  ON s.source_system_id=p.source_system_id
 AND s.source_client=CAST(b.MANDT AS STRING)
 AND s.gl_account=CAST(b.HKONT AS STRING)
 AND s.document_type=CAST(h.BLART AS STRING)
WHERE CAST(b.MANDT AS STRING)=p.source_client
  AND TRY_CAST(h.BUDAT AS DATE)<p.cutoff_exclusive
  AND UPPER(COALESCE(b.hdr__oper,''))<>'D'
  AND UPPER(COALESCE(h.hdr__oper,''))<>'D';

-- ============================================================================
-- 8. GR/IR FI OPEN-LINE SIDECAR
--    This is deliberately separate from AR/AP OOB.
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_grir_line_physical AS
SELECT
  p.source_system_id,
  CAST(b.MANDT AS STRING)                            AS source_client,
  CAST(b.BUKRS AS STRING)                            AS company_code,
  CAST(b.GJAHR AS STRING)                            AS fiscal_year,
  CAST(b.BELNR AS STRING)                            AS accounting_document,
  CAST(b.BUZEI AS STRING)                            AS line_item_number,
  CAST(b.HKONT AS STRING)                            AS grir_account,
  NULLIF(UPPER(TRIM(CAST(b.PRCTR AS STRING))), '')   AS posted_profit_center,
  NULLIF(TRIM(CAST(b.LIFNR AS STRING)), '')           AS posted_vendor,
  NULLIF(UPPER(TRIM(CAST(b.VBUND AS STRING))), '')   AS posted_partner_raw,
  NULLIF(TRIM(CAST(b.EBELN AS STRING)), '')           AS purchase_order,
  NULLIF(TRIM(CAST(b.EBELP AS STRING)), '')           AS purchase_order_item,
  CASE
    WHEN TRIM(COALESCE(CAST(b.AUGDT AS STRING),''))
         IN ('','00000000','0001-01-01','0101-01-01') THEN NULL
    ELSE TRY_CAST(b.AUGDT AS DATE)
  END                                                AS clearing_date,
  CASE
    WHEN TRIM(COALESCE(CAST(b.AUGDT AS STRING),''))
         IN ('','00000000','0001-01-01','0101-01-01') THEN 'INITIAL'
    WHEN TRY_CAST(b.AUGDT AS DATE) IS NULL THEN 'INVALID'
    ELSE 'VALID'
  END                                                AS clearing_date_status,
  CASE WHEN TRIM(COALESCE(CAST(b.AUGBL AS STRING),'')) IN ('','0000000000')
       THEN NULL ELSE TRIM(CAST(b.AUGBL AS STRING)) END AS clearing_document,
  CASE WHEN TRIM(COALESCE(CAST(b.AUGGJ AS STRING),'')) IN ('','0000')
       THEN NULL ELSE TRIM(CAST(b.AUGGJ AS STRING)) END AS clearing_fiscal_year,
  CAST(b.SHKZG AS STRING)                            AS debit_credit_code,
  TRY_CAST(b.WRBTR AS DECIMAL(38,6))                 AS raw_amount_dc,
  TRY_CAST(b.DMBTR AS DECIMAL(38,6))                 AS raw_amount_lc,
  CASE
    WHEN TRY_CAST(b.WRBTR AS DECIMAL(38,6)) IS NULL
      OR TRY_CAST(b.DMBTR AS DECIMAL(38,6)) IS NULL
      THEN 'MISSING_OR_INVALID_RAW_AMOUNT'
    WHEN TRY_CAST(b.WRBTR AS DECIMAL(38,6))<0
      OR TRY_CAST(b.DMBTR AS DECIMAL(38,6))<0
      THEN 'NEGATIVE_RAW_AMOUNT'
    WHEN CAST(b.SHKZG AS STRING) NOT IN ('S','H') OR b.SHKZG IS NULL
      THEN 'INVALID_DEBIT_CREDIT_CODE'
    ELSE 'NONNEGATIVE_RAW_AMOUNT'
  END                                                AS raw_amount_status,
  CAST(CASE WHEN b.SHKZG='S' AND TRY_CAST(b.WRBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(b.WRBTR AS DECIMAL(38,6))
            WHEN b.SHKZG='H' AND TRY_CAST(b.WRBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(b.WRBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                      AS signed_amount_dc,
  CAST(CASE WHEN b.SHKZG='S' AND TRY_CAST(b.DMBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(b.DMBTR AS DECIMAL(38,6))
            WHEN b.SHKZG='H' AND TRY_CAST(b.DMBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(b.DMBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                      AS signed_amount_lc,
  p.as_of_date, p.cutoff_exclusive, p.reconciliation_run_id,
  s.scope_rule_id,
  CASE
    WHEN NULLIF(TRIM(p.source_system_id),'') IS NULL
      OR NULLIF(TRIM(CAST(b.MANDT AS STRING)),'') IS NULL
      OR NULLIF(TRIM(CAST(b.BUKRS AS STRING)),'') IS NULL
      OR NULLIF(TRIM(CAST(b.GJAHR AS STRING)),'') IS NULL
      OR NULLIF(TRIM(CAST(b.BELNR AS STRING)),'') IS NULL
      OR NULLIF(TRIM(CAST(b.BUZEI AS STRING)),'') IS NULL
      THEN 'INVALID_NATIVE_KEY'
    ELSE 'VALID_NATIVE_KEY'
  END                                                AS native_key_status,
  SHA2(CONCAT_WS('||',
       CONCAT('source_system=',COALESCE(p.source_system_id,'<NULL>')),
       CONCAT('client=',COALESCE(CAST(b.MANDT AS STRING),'<NULL>')),
       CONCAT('company=',COALESCE(CAST(b.BUKRS AS STRING),'<NULL>')),
       CONCAT('fiscal_year=',COALESCE(CAST(b.GJAHR AS STRING),'<NULL>')),
       CONCAT('document=',COALESCE(CAST(b.BELNR AS STRING),'<NULL>')),
       CONCAT('line=',COALESCE(CAST(b.BUZEI AS STRING),'<NULL>'))),256)
                                                      AS grir_fi_line_id,
  SHA2(TO_JSON(NAMED_STRUCT(
       'account',CAST(b.HKONT AS STRING),
       'prctr',NULLIF(UPPER(TRIM(CAST(b.PRCTR AS STRING))),''),
       'vendor',NULLIF(TRIM(CAST(b.LIFNR AS STRING)),''),
       'partner',NULLIF(UPPER(TRIM(CAST(b.VBUND AS STRING))),''),
       'po',NULLIF(TRIM(CAST(b.EBELN AS STRING)),''),
       'po_item',NULLIF(TRIM(CAST(b.EBELP AS STRING)),''),
       'clearing_date',TRY_CAST(b.AUGDT AS DATE),
       'clearing_document',CASE
         WHEN TRIM(COALESCE(CAST(b.AUGBL AS STRING),'')) IN ('','0000000000')
           THEN NULL ELSE TRIM(CAST(b.AUGBL AS STRING)) END,
       'clearing_fiscal_year',CASE
         WHEN TRIM(COALESCE(CAST(b.AUGGJ AS STRING),'')) IN ('','0000')
           THEN NULL ELSE TRIM(CAST(b.AUGGJ AS STRING)) END,
       'shkzg',CAST(b.SHKZG AS STRING),
       'wrbtr',TRY_CAST(b.WRBTR AS DECIMAL(38,6)),
       'dmbtr',TRY_CAST(b.DMBTR AS DECIMAL(38,6)))),256) AS grir_line_payload_hash
FROM qlk_c.c_ocs_ecc_old.bseg b
CROSS JOIN ic_v3_params p
JOIN ic_v3_grir_account_scope s
  ON s.source_system_id=p.source_system_id
 AND s.source_client=CAST(b.MANDT AS STRING)
 AND (s.company_code='*' OR s.company_code=CAST(b.BUKRS AS STRING))
 AND s.gl_account=CAST(b.HKONT AS STRING)
WHERE CAST(b.MANDT AS STRING)=p.source_client
  AND UPPER(COALESCE(b.hdr__oper,''))<>'D';

CREATE OR REPLACE TEMP VIEW ic_v3_grir_line_control AS
SELECT
  grir_fi_line_id,
  COUNT(*)                                           AS physical_row_count,
  COUNT(DISTINCT grir_line_payload_hash)             AS payload_count,
  SUM(CASE WHEN native_key_status<>'VALID_NATIVE_KEY' THEN 1 ELSE 0 END)
                                                      AS invalid_native_key_count,
  CASE WHEN SUM(CASE WHEN native_key_status<>'VALID_NATIVE_KEY' THEN 1 ELSE 0 END)>0
         THEN 'FAIL_INVALID_NATIVE_KEY'
       WHEN COUNT(*)=1 AND COUNT(DISTINCT grir_line_payload_hash)=1 THEN 'PASS'
       WHEN COUNT(DISTINCT grir_line_payload_hash)=1
         THEN 'FAIL_DUPLICATE_PHYSICAL_FI_LINE'
       ELSE 'FAIL_CONFLICTING_FI_LINE_PAYLOADS' END  AS line_control_status
FROM ic_v3_grir_line_physical
GROUP BY grir_fi_line_id;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_line_unique AS
SELECT DISTINCT
  l.source_system_id, l.source_client, l.company_code, l.fiscal_year,
  l.accounting_document, l.line_item_number, l.grir_account,
  l.posted_profit_center, l.posted_vendor, l.posted_partner_raw,
  l.purchase_order, l.purchase_order_item,
  l.clearing_date, l.clearing_date_status,
  l.clearing_document, l.clearing_fiscal_year, l.debit_credit_code,
  l.raw_amount_dc, l.raw_amount_lc, l.raw_amount_status,
  l.signed_amount_dc, l.signed_amount_lc,
  l.as_of_date, l.cutoff_exclusive, l.reconciliation_run_id,
  l.scope_rule_id, l.grir_fi_line_id, l.grir_line_payload_hash
FROM ic_v3_grir_line_physical l
JOIN ic_v3_grir_line_control c
  ON c.grir_fi_line_id=l.grir_fi_line_id
WHERE c.line_control_status='PASS';

-- Clearing is accepted only when AUGDT/AUGBL/AUGGJ agree and the referenced
-- BKPF header resolves uniquely at the same company/client. This prevents a
-- parseable but impossible clearing date from silently deleting an open item.
CREATE OR REPLACE TEMP VIEW ic_v3_grir_clearing_header_raw AS
SELECT
  l.grir_fi_line_id,
  l.source_system_id, l.source_client, l.company_code,
  l.clearing_fiscal_year, l.clearing_document,
  TRY_CAST(h.BUDAT AS DATE)                           AS clearing_header_posting_date,
  SHA2(TO_JSON(NAMED_STRUCT(
    'budat',TRY_CAST(h.BUDAT AS DATE),
    'stblg',NULLIF(TRIM(CAST(h.STBLG AS STRING)),''))),256)
                                                       AS clearing_header_payload_hash
FROM ic_v3_grir_line_unique l
JOIN qlk_c.c_ocs_ecc_old.bkpf h
  ON CAST(h.MANDT AS STRING)=l.source_client
 AND CAST(h.BUKRS AS STRING)=l.company_code
 AND CAST(h.GJAHR AS STRING)=l.clearing_fiscal_year
 AND CAST(h.BELNR AS STRING)=l.clearing_document
 AND UPPER(COALESCE(h.hdr__oper,''))<>'D'
WHERE l.clearing_date_status='VALID'
  AND l.clearing_document IS NOT NULL
  AND l.clearing_fiscal_year IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_clearing_control AS
SELECT
  l.grir_fi_line_id,
  COUNT(h.grir_fi_line_id)                           AS clearing_header_physical_count,
  COUNT(DISTINCT h.clearing_header_payload_hash)     AS clearing_header_payload_count,
  MIN(h.clearing_header_posting_date)                AS clearing_header_posting_date,
  CASE
    WHEN l.clearing_date_status='INITIAL'
     AND l.clearing_document IS NULL
     AND l.clearing_fiscal_year IS NULL THEN 'NOT_CLEARED'
    WHEN l.clearing_date_status='INVALID' THEN 'INVALID_CLEARING_DATE'
    WHEN l.clearing_date_status='INITIAL'
      OR l.clearing_date IS NULL
      OR l.clearing_document IS NULL
      OR l.clearing_fiscal_year IS NULL
      THEN 'INCONSISTENT_CLEARING_FIELDS'
    WHEN COUNT(h.grir_fi_line_id)=0 THEN 'CLEARING_HEADER_MISSING'
    WHEN COUNT(h.grir_fi_line_id)=1
     AND COUNT(DISTINCT h.clearing_header_payload_hash)=1
     AND MIN(h.clearing_header_posting_date) IS NULL
      THEN 'CLEARING_HEADER_DATE_INVALID'
    WHEN COUNT(h.grir_fi_line_id)=1
     AND COUNT(DISTINCT h.clearing_header_payload_hash)=1
     AND MIN(h.clearing_header_posting_date)=l.clearing_date
      THEN 'CLEARING_REFERENCE_RESOLVED'
    WHEN COUNT(h.grir_fi_line_id)=1
     AND COUNT(DISTINCT h.clearing_header_payload_hash)=1
      THEN 'CLEARING_HEADER_DATE_MISMATCH'
    WHEN COUNT(DISTINCT h.clearing_header_payload_hash)=1
      THEN 'CLEARING_HEADER_DUPLICATE_PHYSICAL'
    ELSE 'CLEARING_HEADER_CONFLICT'
  END                                                AS clearing_reference_status
FROM ic_v3_grir_line_unique l
LEFT JOIN ic_v3_grir_clearing_header_raw h
  ON h.grir_fi_line_id=l.grir_fi_line_id
GROUP BY l.grir_fi_line_id, l.clearing_date, l.clearing_date_status,
         l.clearing_document, l.clearing_fiscal_year;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_header_raw AS
SELECT
  d.source_system_id, d.source_client, d.company_code, d.fiscal_year,
  d.accounting_document,
  TRY_CAST(h.BUDAT AS DATE)                           AS posting_date,
  NULLIF(UPPER(TRIM(CAST(h.WAERS AS STRING))),'')    AS document_currency,
  NULLIF(TRIM(CAST(h.STBLG AS STRING)),'')            AS reversal_document,
  NULLIF(TRIM(CAST(h.BVORG AS STRING)),'')            AS cross_company_reference,
  SHA2(TO_JSON(NAMED_STRUCT(
    'budat',TRY_CAST(h.BUDAT AS DATE),
    'waers',NULLIF(UPPER(TRIM(CAST(h.WAERS AS STRING))),''),
    'stblg',NULLIF(TRIM(CAST(h.STBLG AS STRING)),''),
    'bvorg',NULLIF(TRIM(CAST(h.BVORG AS STRING)),''))),256)
                                                      AS header_payload_hash
FROM (
  SELECT DISTINCT source_system_id, source_client, company_code,
         fiscal_year, accounting_document
  FROM ic_v3_grir_line_unique
) d
JOIN qlk_c.c_ocs_ecc_old.bkpf h
  ON CAST(h.MANDT AS STRING)=d.source_client
 AND CAST(h.BUKRS AS STRING)=d.company_code
 AND CAST(h.GJAHR AS STRING)=d.fiscal_year
 AND CAST(h.BELNR AS STRING)=d.accounting_document
 AND UPPER(COALESCE(h.hdr__oper,''))<>'D';

CREATE OR REPLACE TEMP VIEW ic_v3_grir_header_control AS
SELECT
  d.source_system_id, d.source_client, d.company_code, d.fiscal_year,
  d.accounting_document,
  COUNT(h.accounting_document)                       AS header_physical_count,
  COUNT(DISTINCT h.header_payload_hash)              AS header_payload_count,
  CASE
    WHEN COUNT(h.accounting_document)=0 THEN 'HEADER_MISSING'
    WHEN COUNT(h.accounting_document)=1
     AND COUNT(DISTINCT h.header_payload_hash)=1 THEN 'HEADER_RESOLVED'
    WHEN COUNT(DISTINCT h.header_payload_hash)=1 THEN 'HEADER_DUPLICATE_PHYSICAL'
    ELSE 'HEADER_CONFLICT'
  END                                                AS header_status
FROM (
  SELECT DISTINCT source_system_id, source_client, company_code,
         fiscal_year, accounting_document
  FROM ic_v3_grir_line_unique
) d
LEFT JOIN ic_v3_grir_header_raw h
  ON h.source_system_id=d.source_system_id
 AND h.source_client=d.source_client
 AND h.company_code=d.company_code
 AND h.fiscal_year=d.fiscal_year
 AND h.accounting_document=d.accounting_document
GROUP BY d.source_system_id, d.source_client, d.company_code,
         d.fiscal_year, d.accounting_document;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_header_unique AS
SELECT DISTINCT
  h.source_system_id, h.source_client, h.company_code, h.fiscal_year,
  h.accounting_document, h.posting_date, h.document_currency,
  h.reversal_document, h.cross_company_reference
FROM ic_v3_grir_header_raw h
JOIN ic_v3_grir_header_control c
  ON c.source_system_id=h.source_system_id
 AND c.source_client=h.source_client
 AND c.company_code=h.company_code
 AND c.fiscal_year=h.fiscal_year
 AND c.accounting_document=h.accounting_document
WHERE c.header_status='HEADER_RESOLVED';

CREATE OR REPLACE TEMP VIEW ic_v3_grir_fi_candidate AS
WITH enriched AS (
  SELECT
    l.grir_fi_line_id, l.source_system_id, l.source_client,
    l.company_code, cm.sole_company_entity_id        AS owner_entity_id,
    COALESCE(cm.owner_entity_status,'UNRESOLVED_COMPANY_CODE')
                                                       AS owner_entity_status,
    l.fiscal_year, l.accounting_document, l.line_item_number,
    l.grir_account, l.posted_profit_center, l.posted_vendor,
    l.posted_partner_raw, l.purchase_order, l.purchase_order_item,
    h.posting_date, l.clearing_date, l.clearing_date_status,
    l.clearing_document, l.clearing_fiscal_year,
    cr.clearing_header_physical_count,
    cr.clearing_header_payload_count,
    cr.clearing_header_posting_date,
    cr.clearing_reference_status,
    CASE
      WHEN cr.grir_fi_line_id IS NULL
        OR cr.clearing_reference_status IS NULL
        THEN 'MISSING_CLEARING_CONTROL'
      WHEN cr.clearing_reference_status='NOT_CLEARED' THEN 'NOT_CLEARED'
      WHEN cr.clearing_reference_status<>'CLEARING_REFERENCE_RESOLVED'
        THEN cr.clearing_reference_status
      WHEN h.posting_date IS NULL THEN 'ORIGINAL_POSTING_DATE_UNAVAILABLE'
      WHEN l.clearing_date<h.posting_date
        THEN 'INVALID_CLEARING_BEFORE_POSTING'
      ELSE 'CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED'
    END                                                AS clearing_control_status,
    h.document_currency, l.debit_credit_code,
    l.raw_amount_dc, l.raw_amount_lc, l.raw_amount_status,
    l.signed_amount_dc, l.signed_amount_lc,
    h.reversal_document,
    CASE WHEN h.reversal_document IS NULL THEN 'NO_REVERSAL_REFERENCE'
         ELSE 'PARTIAL_REVERSAL_REFERENCE_STJAH_NOT_INGESTED' END
                                                       AS fi_reversal_status,
    h.cross_company_reference,
    COALESCE(c.header_status,'HEADER_MISSING')         AS header_status,
    CASE WHEN h.posting_date IS NULL THEN 'INVALID_OR_NULL'
         ELSE 'VALID' END                             AS posting_date_status,
    l.as_of_date, l.cutoff_exclusive, l.reconciliation_run_id,
    l.scope_rule_id
  FROM ic_v3_grir_line_unique l
  LEFT JOIN ic_v3_grir_header_control c
    ON c.source_system_id=l.source_system_id
   AND c.source_client=l.source_client
   AND c.company_code=l.company_code
   AND c.fiscal_year=l.fiscal_year
   AND c.accounting_document=l.accounting_document
  LEFT JOIN ic_v3_grir_header_unique h
    ON h.source_system_id=l.source_system_id
   AND h.source_client=l.source_client
   AND h.company_code=l.company_code
   AND h.fiscal_year=l.fiscal_year
   AND h.accounting_document=l.accounting_document
  LEFT JOIN ic_v3_grir_clearing_control cr
    ON cr.grir_fi_line_id=l.grir_fi_line_id
  LEFT JOIN ic_v3_company_map_control cm
    ON cm.source_system_id=l.source_system_id
   AND cm.source_client=l.source_client
   AND cm.company_code=l.company_code
)
SELECT
  grir_fi_line_id, source_system_id, source_client,
  company_code, owner_entity_id, owner_entity_status,
  fiscal_year, accounting_document, line_item_number,
  grir_account, posted_profit_center, posted_vendor,
  posted_partner_raw, purchase_order, purchase_order_item,
  posting_date, clearing_date, clearing_date_status,
  clearing_document, clearing_fiscal_year,
  clearing_header_physical_count, clearing_header_payload_count,
  clearing_header_posting_date, clearing_reference_status,
  clearing_control_status,
  document_currency, debit_credit_code,
  raw_amount_dc, raw_amount_lc, raw_amount_status,
  signed_amount_dc, signed_amount_lc,
  reversal_document, fi_reversal_status, cross_company_reference,
  header_status, posting_date_status,
  CASE
    WHEN header_status<>'HEADER_RESOLVED' THEN 'QUARANTINE_HEADER'
    WHEN posting_date_status<>'VALID' THEN 'QUARANTINE_INVALID_POSTING_DATE'
    WHEN posting_date>=cutoff_exclusive THEN 'EXCLUDE_POST_CUTOFF'
    WHEN clearing_control_status='CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED'
     AND clearing_date<cutoff_exclusive THEN 'EXCLUDE_CLEARED_PRE_CUTOFF'
    WHEN clearing_control_status IN (
           'NOT_CLEARED','CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED')
      THEN 'INCLUDE_AS_OF_OPEN'
    ELSE 'INCLUDE_BUT_FAIL_CLEARING_CONTROL'
  END                                                AS asof_population_status,
  as_of_date, cutoff_exclusive, reconciliation_run_id, scope_rule_id
FROM enriched;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_fi_open_line_pre AS
SELECT
  grir_fi_line_id, source_system_id, source_client,
  company_code, owner_entity_id, owner_entity_status,
  fiscal_year, accounting_document, line_item_number,
  grir_account, posted_profit_center, posted_vendor,
  posted_partner_raw, purchase_order, purchase_order_item,
  posting_date, clearing_date, clearing_date_status,
  clearing_document, clearing_fiscal_year,
  clearing_header_physical_count, clearing_header_payload_count,
  clearing_header_posting_date, clearing_reference_status,
  clearing_control_status,
  document_currency, debit_credit_code,
  raw_amount_dc, raw_amount_lc, raw_amount_status,
  signed_amount_dc, signed_amount_lc,
  reversal_document, fi_reversal_status,
  cross_company_reference, header_status, asof_population_status,
  posting_date_status,
  as_of_date, cutoff_exclusive, reconciliation_run_id, scope_rule_id
FROM ic_v3_grir_fi_candidate
WHERE asof_population_status IN (
  'INCLUDE_AS_OF_OPEN','INCLUDE_BUT_FAIL_CLEARING_CONTROL'
);

-- ============================================================================
-- 9. GR/IR PARTNER EVIDENCE
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_grir_partner_evidence AS
SELECT
  g.grir_fi_line_id,
  'GRIR_LINE_POSTED'                                 AS evidence_type,
  10                                                 AS evidence_tier,
  g.posted_partner_raw                              AS candidate_partner_entity_id,
  TRUE                                               AS automation_eligible,
  TRUE                                               AS authoritative,
  'POSTED_ON_EXACT_GRIR_FI_LINE'                     AS evidence_quality
FROM ic_v3_grir_fi_open_line_pre g
WHERE g.posted_partner_raw IS NOT NULL

UNION ALL

SELECT DISTINCT
  g.grir_fi_line_id,
  'GRIR_LINE_VENDOR_MASTER_CURRENT', 25,
  UPPER(TRIM(CAST(v.VBUND AS STRING))),
  FALSE, FALSE,
  'EXACT_FI_LINE_VENDOR_CURRENT_SNAPSHOT_NOT_HISTORICAL'
FROM ic_v3_grir_fi_open_line_pre g
JOIN qlk_c.c_ocs_ecc_old.lfa1 v
  ON CAST(v.MANDT AS STRING)=g.source_client
 AND CAST(v.LIFNR AS STRING)=g.posted_vendor
 AND UPPER(COALESCE(v.hdr__oper,''))<>'D'
WHERE g.posted_vendor IS NOT NULL
  AND NULLIF(TRIM(CAST(v.VBUND AS STRING)),'') IS NOT NULL

UNION ALL

SELECT DISTINCT
  g.grir_fi_line_id,
  'PO_VENDOR_MASTER_CURRENT', 30,
  UPPER(TRIM(CAST(v.VBUND AS STRING))),
  FALSE, FALSE,
  'CURRENT_SNAPSHOT_NOT_HISTORICAL'
FROM ic_v3_grir_fi_open_line_pre g
JOIN qlk_c.c_ocs_ecc_old.ekko e
  ON CAST(e.MANDT AS STRING)=g.source_client
 AND CAST(e.EBELN AS STRING)=g.purchase_order
 AND UPPER(COALESCE(e.hdr__oper,''))<>'D'
JOIN qlk_c.c_ocs_ecc_old.lfa1 v
  ON v.MANDT=e.MANDT AND v.LIFNR=e.LIFNR
 AND UPPER(COALESCE(v.hdr__oper,''))<>'D'
WHERE NULLIF(TRIM(CAST(v.VBUND AS STRING)),'') IS NOT NULL

UNION ALL

SELECT DISTINCT
  g.grir_fi_line_id,
  'FI_DOCUMENT_POSTED_LINE', 20,
  UPPER(TRIM(CAST(b.VBUND AS STRING))),
  FALSE, FALSE,
  'SIBLING_FI_LINE'
FROM ic_v3_grir_fi_open_line_pre g
JOIN qlk_c.c_ocs_ecc_old.bseg b
  ON CAST(b.MANDT AS STRING)=g.source_client
 AND CAST(b.BUKRS AS STRING)=g.company_code
 AND CAST(b.GJAHR AS STRING)=g.fiscal_year
 AND CAST(b.BELNR AS STRING)=g.accounting_document
 AND UPPER(COALESCE(b.hdr__oper,''))<>'D'
WHERE NULLIF(TRIM(CAST(b.VBUND AS STRING)),'') IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_partner_stats AS
SELECT
  g.grir_fi_line_id,
  COUNT(DISTINCT e.candidate_partner_entity_id)      AS all_candidate_count,
  COUNT(DISTINCT CASE WHEN e.automation_eligible
                      THEN e.candidate_partner_entity_id END)
                                                      AS automatic_candidate_count,
  COUNT(DISTINCT CASE WHEN e.evidence_type='GRIR_LINE_POSTED'
                      THEN e.candidate_partner_entity_id END)
                                                      AS posted_candidate_count,
  MIN(CASE WHEN e.evidence_type='GRIR_LINE_POSTED'
           THEN e.candidate_partner_entity_id END)   AS posted_candidate,
  MIN(CASE WHEN e.automation_eligible
           THEN e.candidate_partner_entity_id END)   AS automatic_candidate,
  MIN(e.candidate_partner_entity_id)                 AS diagnostic_candidate
FROM ic_v3_grir_fi_open_line_pre g
LEFT JOIN ic_v3_grir_partner_evidence e
  ON e.grir_fi_line_id=g.grir_fi_line_id
GROUP BY g.grir_fi_line_id;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_partner_resolution AS
SELECT
  g.grir_fi_line_id,
  CASE
    WHEN s.all_candidate_count=0 THEN 'UNRESOLVED'
    WHEN s.posted_candidate_count=1 AND s.all_candidate_count>1 THEN 'CONFLICT'
    WHEN s.posted_candidate_count=1
     AND s.posted_candidate=g.owner_entity_id THEN 'CONFLICT_SELF'
    WHEN s.posted_candidate_count=1 THEN 'POSTED'
    WHEN s.automatic_candidate_count>1 THEN 'AMBIGUOUS'
    WHEN s.automatic_candidate_count=1 AND s.all_candidate_count=1
     AND s.automatic_candidate=g.owner_entity_id THEN 'CONFLICT_SELF'
    WHEN s.automatic_candidate_count=1 AND s.all_candidate_count=1
      THEN 'DERIVED_UNIQUE'
    WHEN s.all_candidate_count=1 THEN 'DERIVED_UNIQUE_DIAGNOSTIC'
    ELSE 'AMBIGUOUS'
  END                                                AS partner_resolution_status,
  CASE
    WHEN s.posted_candidate_count=1 AND s.all_candidate_count=1
     AND s.posted_candidate<>g.owner_entity_id THEN s.posted_candidate
    WHEN s.posted_candidate_count=0
     AND s.automatic_candidate_count=1 AND s.all_candidate_count=1
     AND s.automatic_candidate<>g.owner_entity_id THEN s.automatic_candidate
  END                                                AS resolved_partner_entity_id,
  CASE WHEN s.all_candidate_count=1
       THEN s.diagnostic_candidate END               AS diagnostic_partner_entity_id,
  s.all_candidate_count, s.automatic_candidate_count
FROM ic_v3_grir_fi_open_line_pre g
JOIN ic_v3_grir_partner_stats s
  ON s.grir_fi_line_id=g.grir_fi_line_id;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_fi_open_line AS
SELECT
  g.grir_fi_line_id, g.source_system_id, g.source_client,
  g.company_code, g.owner_entity_id, g.owner_entity_status,
  r.resolved_partner_entity_id, r.diagnostic_partner_entity_id,
  r.partner_resolution_status,
  g.fiscal_year, g.accounting_document, g.line_item_number,
  g.grir_account, g.posted_profit_center, g.posted_vendor,
  g.posted_partner_raw, g.purchase_order, g.purchase_order_item,
  g.posting_date, g.clearing_date, g.clearing_date_status,
  g.clearing_document, g.clearing_fiscal_year,
  g.clearing_header_physical_count, g.clearing_header_payload_count,
  g.clearing_header_posting_date, g.clearing_reference_status,
  g.clearing_control_status,
  g.document_currency, g.debit_credit_code,
  g.raw_amount_dc, g.raw_amount_lc, g.raw_amount_status,
  g.signed_amount_dc, g.signed_amount_lc,
  g.reversal_document, g.fi_reversal_status,
  g.cross_company_reference, g.header_status, g.asof_population_status,
  g.posting_date_status,
  g.as_of_date, g.cutoff_exclusive, g.reconciliation_run_id,
  g.scope_rule_id
FROM ic_v3_grir_fi_open_line_pre g
JOIN ic_v3_grir_partner_resolution r
  ON r.grir_fi_line_id=g.grir_fi_line_id;

-- ============================================================================
-- 10. GR/IR PO-HISTORY EVENT AND LIFECYCLE OBJECTS
--     VGABE 1/2 is used only for a presence-oriented SAP-standard diagnostic.
--     Exact value/reversal automation remains disabled until a governed rule
--     table plus AREWR/AREWB/AREWW and reversal-reference fields are ingested.
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_grir_po_scope AS
SELECT DISTINCT
  source_system_id, source_client, company_code,
  purchase_order, purchase_order_item, cutoff_exclusive
FROM ic_v3_grir_fi_open_line
WHERE purchase_order IS NOT NULL AND purchase_order_item IS NOT NULL;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_po_owner_raw AS
SELECT
  l.source_system_id, l.source_client, l.purchase_order,
  CAST(e.BUKRS AS STRING)                            AS po_owner_company_code,
  NULLIF(TRIM(CAST(e.LIFNR AS STRING)),'')            AS po_vendor,
  SHA2(TO_JSON(NAMED_STRUCT(
       'owner_company',CAST(e.BUKRS AS STRING),
       'vendor',NULLIF(TRIM(CAST(e.LIFNR AS STRING)),''))),256)
                                                      AS po_header_payload_hash
FROM (
  SELECT DISTINCT source_system_id, source_client, purchase_order
  FROM ic_v3_grir_po_scope
) l
JOIN qlk_c.c_ocs_ecc_old.ekko e
  ON CAST(e.MANDT AS STRING)=l.source_client
 AND CAST(e.EBELN AS STRING)=l.purchase_order
 AND UPPER(COALESCE(e.hdr__oper,''))<>'D';

CREATE OR REPLACE TEMP VIEW ic_v3_grir_po_owner_control AS
SELECT
  l.source_system_id, l.source_client, l.purchase_order,
  COUNT(r.purchase_order)                            AS po_header_physical_count,
  COUNT(DISTINCT r.po_header_payload_hash)           AS po_header_payload_count,
  COUNT(DISTINCT r.po_owner_company_code)            AS po_owner_count,
  MIN(r.po_owner_company_code)                       AS sole_po_owner_company_code,
  CASE
    WHEN COUNT(r.purchase_order)=0 THEN 'PO_HEADER_MISSING'
    WHEN COUNT(r.purchase_order)=1
     AND COUNT(DISTINCT r.po_header_payload_hash)=1
     AND COUNT(DISTINCT r.po_owner_company_code)=1 THEN 'PO_OWNER_RESOLVED'
    WHEN COUNT(DISTINCT r.po_header_payload_hash)=1
      THEN 'PO_HEADER_DUPLICATE_PHYSICAL'
    ELSE 'PO_HEADER_OR_OWNER_CONFLICT'
  END                                                AS po_owner_control_status
FROM (
  SELECT DISTINCT source_system_id, source_client, purchase_order
  FROM ic_v3_grir_po_scope
) l
LEFT JOIN ic_v3_grir_po_owner_raw r
  ON r.source_system_id=l.source_system_id
 AND r.source_client=l.source_client
 AND r.purchase_order=l.purchase_order
GROUP BY l.source_system_id, l.source_client, l.purchase_order;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_po_scope_controlled AS
SELECT
  s.source_system_id, s.source_client, s.company_code,
  s.purchase_order, s.purchase_order_item, s.cutoff_exclusive,
  c.sole_po_owner_company_code,
  CASE
    WHEN c.po_owner_control_status IS NULL
      THEN 'PO_OWNER_CONTROL_MISSING'
    WHEN c.po_owner_control_status<>'PO_OWNER_RESOLVED'
      THEN c.po_owner_control_status
    WHEN c.sole_po_owner_company_code IS NULL
      THEN 'PO_OWNER_COMPANY_MISSING'
    WHEN c.sole_po_owner_company_code<>s.company_code
      THEN 'PO_OWNER_CONFLICTS_WITH_GRIR_COMPANY'
    ELSE 'CONFIRMED_PO_OWNER'
  END                                                AS po_owner_status
FROM ic_v3_grir_po_scope s
LEFT JOIN ic_v3_grir_po_owner_control c
  ON c.source_system_id=s.source_system_id
 AND c.source_client=s.source_client
 AND c.purchase_order=s.purchase_order;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_po_history_event_physical AS
SELECT
  s.source_system_id,
  CAST(e.MANDT AS STRING)                            AS source_client,
  s.company_code,
  CAST(e.EBELN AS STRING)                            AS purchase_order,
  CAST(e.EBELP AS STRING)                            AS purchase_order_item,
  NULLIF(TRIM(CAST(e.ZEKKN AS STRING)),'')            AS account_assignment_number,
  CAST(e.VGABE AS STRING)                            AS purchasing_history_document_type,
  CAST(e.BEWTP AS STRING)                            AS purchasing_history_category,
  CAST(e.BWART AS STRING)                            AS goods_movement_type,
  CAST(e.GJAHR AS STRING)                            AS history_document_year,
  CAST(e.BELNR AS STRING)                            AS history_document,
  CAST(e.BUZEI AS STRING)                            AS history_document_item,
  TRY_CAST(e.BUDAT AS DATE)                          AS event_posting_date,
  CASE WHEN TRY_CAST(e.BUDAT AS DATE) IS NULL THEN 'INVALID_OR_NULL'
       ELSE 'VALID' END                              AS event_posting_date_status,
  CAST(e.SHKZG AS STRING)                            AS debit_credit_code,
  NULLIF(UPPER(TRIM(CAST(e.WAERS AS STRING))),'')    AS event_currency,
  TRY_CAST(e.MENGE AS DECIMAL(38,6))                 AS raw_quantity,
  TRY_CAST(e.WRBTR AS DECIMAL(38,6))                 AS raw_document_amount,
  TRY_CAST(e.DMBTR AS DECIMAL(38,6))                 AS raw_local_amount,
  CASE
    WHEN TRY_CAST(e.WRBTR AS DECIMAL(38,6)) IS NULL
      OR TRY_CAST(e.DMBTR AS DECIMAL(38,6)) IS NULL
      THEN 'MISSING_OR_INVALID_EVENT_AMOUNT'
    WHEN TRY_CAST(e.WRBTR AS DECIMAL(38,6))<0
      OR TRY_CAST(e.DMBTR AS DECIMAL(38,6))<0
      THEN 'NEGATIVE_EVENT_AMOUNT'
    WHEN CAST(e.SHKZG AS STRING) NOT IN ('S','H') OR e.SHKZG IS NULL
      THEN 'INVALID_EVENT_DEBIT_CREDIT_CODE'
    ELSE 'NONNEGATIVE_EVENT_AMOUNT'
  END                                                AS raw_event_amount_status,
  CASE
    WHEN TRY_CAST(e.MENGE AS DECIMAL(38,6)) IS NULL
      THEN 'MISSING_OR_INVALID_EVENT_QUANTITY'
    WHEN TRY_CAST(e.MENGE AS DECIMAL(38,6))<0
      THEN 'NEGATIVE_EVENT_QUANTITY'
    WHEN CAST(e.SHKZG AS STRING) NOT IN ('S','H') OR e.SHKZG IS NULL
      THEN 'INVALID_EVENT_DEBIT_CREDIT_CODE'
    ELSE 'NONNEGATIVE_EVENT_QUANTITY'
  END                                                AS raw_event_quantity_status,
  CAST(CASE WHEN e.SHKZG='S' AND TRY_CAST(e.MENGE AS DECIMAL(38,6))>=0
             THEN TRY_CAST(e.MENGE AS DECIMAL(38,6))
            WHEN e.SHKZG='H' AND TRY_CAST(e.MENGE AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(e.MENGE AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                      AS raw_signed_quantity,
  CAST(CASE WHEN e.SHKZG='S' AND TRY_CAST(e.WRBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(e.WRBTR AS DECIMAL(38,6))
            WHEN e.SHKZG='H' AND TRY_CAST(e.WRBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(e.WRBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                      AS raw_signed_document_amount,
  CAST(CASE WHEN e.SHKZG='S' AND TRY_CAST(e.DMBTR AS DECIMAL(38,6))>=0
             THEN TRY_CAST(e.DMBTR AS DECIMAL(38,6))
            WHEN e.SHKZG='H' AND TRY_CAST(e.DMBTR AS DECIMAL(38,6))>=0
             THEN -TRY_CAST(e.DMBTR AS DECIMAL(38,6)) END AS DECIMAL(38,6))
                                                      AS raw_signed_local_amount,
  CASE WHEN CAST(e.VGABE AS STRING)='1' THEN 'GR'
       WHEN CAST(e.VGABE AS STRING)='2' THEN 'IR'
       ELSE 'OTHER' END                              AS event_family,
  CASE WHEN CAST(e.VGABE AS STRING) IN ('1','2')
       THEN 'SAP_STANDARD_PRESENCE_CLASSIFIED'
       ELSE 'UNMAPPED_EVENT' END                     AS event_mapping_status,
  CASE
    WHEN NULLIF(TRIM(s.source_system_id),'') IS NULL
      OR NULLIF(TRIM(CAST(e.MANDT AS STRING)),'') IS NULL
      OR NULLIF(TRIM(CAST(e.EBELN AS STRING)),'') IS NULL
      OR NULLIF(TRIM(CAST(e.EBELP AS STRING)),'') IS NULL
      OR NULLIF(TRIM(CAST(e.VGABE AS STRING)),'') IS NULL
      OR NULLIF(TRIM(CAST(e.GJAHR AS STRING)),'') IS NULL
      OR NULLIF(TRIM(CAST(e.BELNR AS STRING)),'') IS NULL
      OR NULLIF(TRIM(CAST(e.BUZEI AS STRING)),'') IS NULL
      THEN 'INVALID_NATIVE_EVENT_KEY'
    ELSE 'VALID_NATIVE_EVENT_KEY'
  END                                                AS native_event_key_status,
  SHA2(CONCAT_WS('||',
       CONCAT('source_system=',COALESCE(s.source_system_id,'<NULL>')),
       CONCAT('client=',COALESCE(CAST(e.MANDT AS STRING),'<NULL>')),
       CONCAT('po=',COALESCE(CAST(e.EBELN AS STRING),'<NULL>')),
       CONCAT('po_item=',COALESCE(CAST(e.EBELP AS STRING),'<NULL>')),
       CONCAT('assignment=',COALESCE(NULLIF(TRIM(CAST(e.ZEKKN AS STRING)),''),'<NULL>')),
       CONCAT('vgabe=',COALESCE(CAST(e.VGABE AS STRING),'<NULL>')),
       CONCAT('history_year=',COALESCE(CAST(e.GJAHR AS STRING),'<NULL>')),
       CONCAT('history_document=',COALESCE(CAST(e.BELNR AS STRING),'<NULL>')),
       CONCAT('history_item=',COALESCE(CAST(e.BUZEI AS STRING),'<NULL>'))),256)
                                                      AS event_id,
  SHA2(TO_JSON(NAMED_STRUCT(
       'bewtp',CAST(e.BEWTP AS STRING),
       'bwart',CAST(e.BWART AS STRING),
       'posting_date',TRY_CAST(e.BUDAT AS DATE),
       'shkzg',CAST(e.SHKZG AS STRING),
       'currency',NULLIF(UPPER(TRIM(CAST(e.WAERS AS STRING))),''),
       'quantity',TRY_CAST(e.MENGE AS DECIMAL(38,6)),
       'wrbtr',TRY_CAST(e.WRBTR AS DECIMAL(38,6)),
       'dmbtr',TRY_CAST(e.DMBTR AS DECIMAL(38,6)))),256) AS event_payload_hash,
  s.cutoff_exclusive
FROM qlk_c.c_ocs_ecc_old.ekbe e
JOIN ic_v3_grir_po_scope_controlled s
  ON CAST(e.MANDT AS STRING)=s.source_client
 AND CAST(e.EBELN AS STRING)=s.purchase_order
 AND CAST(e.EBELP AS STRING)=s.purchase_order_item
 AND s.po_owner_status='CONFIRMED_PO_OWNER'
WHERE (TRY_CAST(e.BUDAT AS DATE)<s.cutoff_exclusive
       OR TRY_CAST(e.BUDAT AS DATE) IS NULL)
  AND UPPER(COALESCE(e.hdr__oper,''))<>'D';

CREATE OR REPLACE TEMP VIEW ic_v3_grir_event_key_control AS
SELECT
  source_system_id, source_client, company_code,
  purchase_order, purchase_order_item, event_id,
  COUNT(*)                                           AS physical_row_count,
  COUNT(DISTINCT event_payload_hash)                 AS payload_count,
  SUM(CASE WHEN native_event_key_status<>'VALID_NATIVE_EVENT_KEY'
           THEN 1 ELSE 0 END)                        AS invalid_native_key_count,
  SUM(CASE WHEN event_posting_date_status<>'VALID' THEN 1 ELSE 0 END)
                                                      AS invalid_posting_date_count,
  SUM(CASE WHEN raw_event_amount_status<>'NONNEGATIVE_EVENT_AMOUNT'
           THEN 1 ELSE 0 END)                        AS invalid_event_amount_count,
  SUM(CASE WHEN raw_event_quantity_status<>'NONNEGATIVE_EVENT_QUANTITY'
           THEN 1 ELSE 0 END)                        AS invalid_event_quantity_count,
  CASE
    WHEN SUM(CASE WHEN native_event_key_status<>'VALID_NATIVE_EVENT_KEY'
                  THEN 1 ELSE 0 END)>0 THEN 'FAIL_INVALID_NATIVE_EVENT_KEY'
    WHEN SUM(CASE WHEN event_posting_date_status<>'VALID' THEN 1 ELSE 0 END)>0
      THEN 'FAIL_INVALID_EVENT_POSTING_DATE'
    WHEN SUM(CASE WHEN raw_event_amount_status<>'NONNEGATIVE_EVENT_AMOUNT'
                  THEN 1 ELSE 0 END)>0
      THEN 'FAIL_INVALID_EVENT_AMOUNT_OR_SIGN'
    WHEN SUM(CASE WHEN raw_event_quantity_status<>'NONNEGATIVE_EVENT_QUANTITY'
                  THEN 1 ELSE 0 END)>0
      THEN 'FAIL_INVALID_EVENT_QUANTITY_OR_SIGN'
    WHEN COUNT(*)<>1 THEN 'FAIL_DUPLICATE_PHYSICAL_EVENT'
    WHEN COUNT(DISTINCT event_payload_hash)<>1 THEN 'FAIL_EVENT_PAYLOAD_CONFLICT'
    ELSE 'PASS'
  END                                                AS event_key_status
FROM ic_v3_grir_po_history_event_physical
GROUP BY source_system_id, source_client, company_code,
         purchase_order, purchase_order_item, event_id;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_po_history_event AS
SELECT
  e.source_system_id, e.source_client, e.company_code,
  e.purchase_order, e.purchase_order_item,
  e.account_assignment_number,
  e.purchasing_history_document_type,
  e.purchasing_history_category, e.goods_movement_type,
  e.history_document_year, e.history_document, e.history_document_item,
  e.event_posting_date, e.event_posting_date_status,
  e.debit_credit_code, e.event_currency,
  e.raw_quantity, e.raw_document_amount, e.raw_local_amount,
  e.raw_event_amount_status, e.raw_event_quantity_status,
  e.raw_signed_quantity, e.raw_signed_document_amount,
  e.raw_signed_local_amount, e.event_family,
  e.event_mapping_status, e.event_id, e.cutoff_exclusive
FROM ic_v3_grir_po_history_event_physical e
JOIN ic_v3_grir_event_key_control c
  ON c.source_system_id=e.source_system_id
 AND c.source_client=e.source_client
 AND c.company_code=e.company_code
 AND c.purchase_order=e.purchase_order
 AND c.purchase_order_item=e.purchase_order_item
 AND c.event_id=e.event_id
WHERE c.event_key_status='PASS';

CREATE OR REPLACE TEMP VIEW ic_v3_grir_po_event_quality AS
SELECT
  source_system_id, source_client, company_code,
  purchase_order, purchase_order_item,
  COUNT(*)                                           AS raw_event_key_count,
  SUM(CASE WHEN event_key_status<>'PASS' THEN 1 ELSE 0 END)
                                                      AS rejected_event_key_count,
  SUM(invalid_posting_date_count)                    AS invalid_event_date_count
  ,SUM(invalid_event_amount_count)                   AS invalid_event_amount_count
  ,SUM(invalid_event_quantity_count)                 AS invalid_event_quantity_count
FROM ic_v3_grir_event_key_control
GROUP BY source_system_id, source_client, company_code,
         purchase_order, purchase_order_item;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_po_event_summary AS
SELECT
  s.source_system_id, s.source_client, s.company_code,
  s.purchase_order, s.purchase_order_item, s.cutoff_exclusive,
  s.po_owner_status,
  COALESCE(q.raw_event_key_count,0)                  AS raw_event_key_count,
  COALESCE(q.rejected_event_key_count,0)             AS rejected_event_key_count,
  COALESCE(q.invalid_event_date_count,0)             AS invalid_event_date_count,
  COALESCE(q.invalid_event_amount_count,0)           AS invalid_event_amount_count,
  COALESCE(q.invalid_event_quantity_count,0)         AS invalid_event_quantity_count,
  COUNT(e.event_id)                                  AS accepted_event_count,
  COUNT(DISTINCT e.event_id)                         AS event_id_count,
  SUM(CASE WHEN e.event_family='GR' THEN 1 ELSE 0 END) AS gr_event_count,
  SUM(CASE WHEN e.event_family='IR' THEN 1 ELSE 0 END) AS ir_event_count,
  SUM(CASE WHEN e.event_family='OTHER' THEN 1 ELSE 0 END)
                                                      AS other_event_count,
  SUM(CASE WHEN e.event_mapping_status='UNMAPPED_EVENT' THEN 1 ELSE 0 END)
                                                      AS unmapped_event_count,
  COUNT(DISTINCT e.account_assignment_number)        AS account_assignment_count,
  SUM(CASE WHEN e.event_id IS NOT NULL
            AND e.account_assignment_number IS NULL THEN 1 ELSE 0 END)
                                                      AS null_assignment_event_count,
  MIN(e.event_posting_date)                          AS first_event_date,
  MAX(e.event_posting_date)                          AS last_event_date,
  CAST(SUM(CASE WHEN e.event_family='GR' THEN e.raw_signed_quantity ELSE 0 END)
       AS DECIMAL(38,6))                             AS diagnostic_gr_signed_quantity,
  CAST(SUM(CASE WHEN e.event_family='IR' THEN e.raw_signed_quantity ELSE 0 END)
       AS DECIMAL(38,6))                             AS diagnostic_ir_signed_quantity,
  CAST(SUM(CASE WHEN e.event_family='GR' THEN e.raw_signed_local_amount ELSE 0 END)
       AS DECIMAL(38,6))                             AS diagnostic_gr_signed_local_value,
  CAST(SUM(CASE WHEN e.event_family='IR' THEN e.raw_signed_local_amount ELSE 0 END)
       AS DECIMAL(38,6))                             AS diagnostic_ir_signed_local_value,
  'UNIT_NOT_INGESTED_DO_NOT_AGGREGATE_QUANTITY'      AS quantity_basis_status,
  'EKBE_ZEKKN_ONLY_EKBE_MA_NOT_INGESTED'             AS assignment_basis_status,
  CASE
    WHEN COALESCE(s.po_owner_status,'PO_OWNER_STATUS_MISSING')
         <>'CONFIRMED_PO_OWNER'
      THEN COALESCE(s.po_owner_status,'PO_OWNER_STATUS_MISSING')
    WHEN COALESCE(q.rejected_event_key_count,0)>0
      THEN 'EVENT_KEY_DATE_AMOUNT_QUANTITY_OR_SIGN_FAILURE'
    WHEN COUNT(e.event_id)=0 THEN 'PO_HISTORY_MISSING'
    WHEN SUM(CASE WHEN e.event_mapping_status='UNMAPPED_EVENT' THEN 1 ELSE 0 END)>0
      THEN 'EVENT_MAPPING_INCOMPLETE'
    ELSE 'PRESENCE_DIAGNOSTIC_REVERSAL_MAP_INCOMPLETE'
  END                                                AS event_control_status,
  CASE
    WHEN COUNT(e.event_id)=0 THEN 'NO_ASSIGNMENT_HISTORY'
    WHEN SUM(CASE WHEN e.event_id IS NOT NULL
                   AND e.account_assignment_number IS NULL THEN 1 ELSE 0 END)>0
     AND COUNT(DISTINCT e.account_assignment_number)>0
      THEN 'ASSIGNMENT_HISTORY_PARTIAL'
    WHEN COUNT(DISTINCT e.account_assignment_number)=0 THEN 'NO_ASSIGNMENT_HISTORY'
    WHEN COUNT(DISTINCT e.account_assignment_number)=1 THEN 'PO_ITEM_UNIQUE_ASSIGNMENT'
    ELSE 'MULTIPLE_ASSIGNMENTS_FI_AMOUNT_UNALLOCATED'
  END                                                AS assignment_link_status
FROM ic_v3_grir_po_scope_controlled s
LEFT JOIN ic_v3_grir_po_history_event e
  ON e.source_system_id=s.source_system_id
 AND e.source_client=s.source_client
 AND e.company_code=s.company_code
 AND e.purchase_order=s.purchase_order
 AND e.purchase_order_item=s.purchase_order_item
 AND e.cutoff_exclusive=s.cutoff_exclusive
LEFT JOIN ic_v3_grir_po_event_quality q
  ON q.source_system_id=s.source_system_id
 AND q.source_client=s.source_client
 AND q.company_code=s.company_code
 AND q.purchase_order=s.purchase_order
 AND q.purchase_order_item=s.purchase_order_item
GROUP BY s.source_system_id, s.source_client, s.company_code,
         s.purchase_order, s.purchase_order_item, s.cutoff_exclusive,
         s.po_owner_status, q.raw_event_key_count,
         q.rejected_event_key_count, q.invalid_event_date_count,
         q.invalid_event_amount_count, q.invalid_event_quantity_count;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_fi_po_summary AS
SELECT
  f.source_system_id, f.source_client, f.company_code,
  f.owner_entity_id, f.owner_entity_status,
  f.grir_account, f.document_currency,
  CASE WHEN f.document_currency IS NULL OR TRIM(f.document_currency)=''
       THEN 'DOCUMENT_CURRENCY_MISSING' ELSE 'DOCUMENT_CURRENCY_PRESENT' END
                                                      AS document_currency_status,
  'LOCAL_CURRENCY_CODE_NOT_INGESTED'                 AS local_currency_status,
  s.po_owner_status,
  f.purchase_order, f.purchase_order_item,
  f.as_of_date, f.cutoff_exclusive, f.reconciliation_run_id,
  COUNT(*)                                           AS open_fi_line_count,
  SUM(CASE WHEN COALESCE(f.clearing_control_status,'MISSING_CLEARING_CONTROL') NOT IN (
                 'NOT_CLEARED','CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED')
           THEN 1 ELSE 0 END)                        AS clearing_control_exception_line_count,
  CAST(SUM(f.signed_amount_dc) AS DECIMAL(38,6))     AS open_fi_amount_dc,
  CAST(SUM(f.signed_amount_lc) AS DECIMAL(38,6))     AS open_fi_amount_lc,
  CAST(SUM(ABS(f.signed_amount_dc)) AS DECIMAL(38,6)) AS gross_fi_amount_dc,
  CAST(SUM(ABS(f.signed_amount_lc)) AS DECIMAL(38,6)) AS gross_fi_amount_lc,
  COUNT(DISTINCT f.resolved_partner_entity_id)       AS resolved_partner_count,
  MIN(f.resolved_partner_entity_id)                  AS sole_resolved_partner_entity_id,
  SUM(CASE WHEN f.partner_resolution_status IN ('POSTED','DERIVED_UNIQUE')
            THEN 0 ELSE 1 END)                        AS partner_exception_line_count,
  MIN(f.posting_date)                                AS oldest_fi_posting_date,
  MAX(f.posting_date)                                AS newest_fi_posting_date
FROM ic_v3_grir_fi_open_line f
JOIN ic_v3_grir_po_scope_controlled s
  ON s.source_system_id=f.source_system_id
 AND s.source_client=f.source_client
 AND s.company_code=f.company_code
 AND s.purchase_order=f.purchase_order
 AND s.purchase_order_item=f.purchase_order_item
 AND s.cutoff_exclusive=f.cutoff_exclusive
WHERE f.purchase_order IS NOT NULL AND f.purchase_order_item IS NOT NULL
GROUP BY f.source_system_id, f.source_client, f.company_code,
         f.owner_entity_id, f.owner_entity_status,
         f.grir_account, f.document_currency, s.po_owner_status,
         f.purchase_order, f.purchase_order_item,
         f.as_of_date, f.cutoff_exclusive, f.reconciliation_run_id;

-- EKBE is a PO-item fact, while FI is sliced by GR/IR account and document
-- currency. The same PO-item event measures therefore repeat across FI slices.
-- This control makes that non-additivity explicit and machine-testable.
CREATE OR REPLACE TEMP VIEW ic_v3_grir_po_item_slice_control AS
SELECT
  source_system_id, source_client, company_code,
  purchase_order, purchase_order_item,
  as_of_date, cutoff_exclusive, reconciliation_run_id,
  COUNT(*)                                           AS po_item_fi_slice_count,
  CASE WHEN COUNT(*)=1 THEN 'ADDITIVE_AT_THIS_GRAIN'
       ELSE 'PO_ITEM_EVENT_MEASURES_REPEATED_DO_NOT_SUM_ACROSS_SLICES' END
                                                      AS event_measure_additivity_status
FROM ic_v3_grir_fi_po_summary
GROUP BY source_system_id, source_client, company_code,
         purchase_order, purchase_order_item,
         as_of_date, cutoff_exclusive, reconciliation_run_id;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_po_item_lifecycle AS
SELECT
  SHA2(CONCAT_WS('||',
       CONCAT('run=',COALESCE(f.reconciliation_run_id,'<NULL>')),
       CONCAT('source_system=',COALESCE(f.source_system_id,'<NULL>')),
       CONCAT('client=',COALESCE(f.source_client,'<NULL>')),
       CONCAT('company=',COALESCE(f.company_code,'<NULL>')),
       CONCAT('po=',COALESCE(f.purchase_order,'<NULL>')),
       CONCAT('po_item=',COALESCE(f.purchase_order_item,'<NULL>')),
       CONCAT('grir_account=',COALESCE(f.grir_account,'<NULL>')),
       CONCAT('document_currency=',COALESCE(f.document_currency,'<NULL>'))),256)
                                                       AS grir_po_item_id,
  f.source_system_id, f.source_client, f.company_code,
  f.owner_entity_id, f.owner_entity_status,
  CASE WHEN f.resolved_partner_count=1
        AND f.partner_exception_line_count=0
       THEN f.sole_resolved_partner_entity_id END    AS resolved_partner_entity_id,
  CASE
    WHEN f.partner_exception_line_count>0 THEN 'FI_LINE_PARTNER_EXCEPTION'
    WHEN f.resolved_partner_count=1 THEN 'RESOLVED'
    WHEN f.resolved_partner_count=0 THEN 'UNRESOLVED'
    ELSE 'AMBIGUOUS'
  END                                                AS partner_resolution_status,
  f.purchase_order, f.purchase_order_item,
  f.grir_account, f.document_currency,
  f.document_currency_status, f.local_currency_status,
  f.po_owner_status,
  'PO_ITEM_GRIR_ACCOUNT_DOCUMENT_CURRENCY'            AS lifecycle_grain,
  sc.po_item_fi_slice_count,
  sc.event_measure_additivity_status,
  f.open_fi_line_count,
  f.clearing_control_exception_line_count,
  f.open_fi_amount_dc, f.open_fi_amount_lc,
  f.gross_fi_amount_dc, f.gross_fi_amount_lc,
  COALESCE(e.raw_event_key_count,0)                  AS raw_event_key_count,
  COALESCE(e.rejected_event_key_count,0)             AS rejected_event_key_count,
  COALESCE(e.invalid_event_date_count,0)             AS invalid_event_date_count,
  COALESCE(e.invalid_event_amount_count,0)           AS invalid_event_amount_count,
  COALESCE(e.invalid_event_quantity_count,0)         AS invalid_event_quantity_count,
  COALESCE(e.accepted_event_count,0)                 AS accepted_event_count,
  COALESCE(e.event_id_count,0)                       AS event_id_count,
  COALESCE(e.gr_event_count,0)                       AS gr_event_count,
  COALESCE(e.ir_event_count,0)                       AS ir_event_count,
  COALESCE(e.other_event_count,0)                    AS other_event_count,
  COALESCE(e.unmapped_event_count,0)                 AS unmapped_event_count,
  COALESCE(e.account_assignment_count,0)             AS account_assignment_count,
  COALESCE(e.null_assignment_event_count,0)          AS null_assignment_event_count,
  e.first_event_date, e.last_event_date,
  e.diagnostic_gr_signed_quantity,
  e.diagnostic_ir_signed_quantity,
  e.diagnostic_gr_signed_local_value,
  e.diagnostic_ir_signed_local_value,
  COALESCE(e.event_control_status,'PO_HISTORY_MISSING') AS event_control_status,
  COALESCE(e.assignment_link_status,'NO_ASSIGNMENT_HISTORY')
                                                       AS assignment_link_status,
  COALESCE(e.quantity_basis_status,
           'UNIT_NOT_INGESTED_DO_NOT_AGGREGATE_QUANTITY')
                                                       AS quantity_basis_status,
  COALESCE(e.assignment_basis_status,
           'EKBE_ZEKKN_ONLY_EKBE_MA_NOT_INGESTED')
                                                       AS assignment_basis_status,
  'EKBE_ONLY_EKBEH_NOT_INGESTED'                      AS history_basis_status,
  'DIAGNOSTIC_EKBE_DMBTR_NOT_CERTIFIED_GRIR_CLEARING_VALUE'
                                                       AS value_basis_status,
  'REVERSAL_REFERENCE_INCOMPLETE'                    AS reversal_status,
  p.grir_event_rule_version                          AS event_rule_version,
  CASE
    WHEN COALESCE(f.po_owner_status,'PO_OWNER_STATUS_MISSING')
         <>'CONFIRMED_PO_OWNER'
      THEN COALESCE(f.po_owner_status,'PO_OWNER_STATUS_MISSING')
    WHEN COALESCE(f.document_currency_status,
                  'DOCUMENT_CURRENCY_STATUS_MISSING')
         <>'DOCUMENT_CURRENCY_PRESENT'
      THEN COALESCE(f.document_currency_status,
                    'DOCUMENT_CURRENCY_STATUS_MISSING')
    WHEN COALESCE(e.event_control_status,'PO_HISTORY_MISSING')
         <>'PRESENCE_DIAGNOSTIC_REVERSAL_MAP_INCOMPLETE'
      THEN COALESCE(e.event_control_status,'PO_HISTORY_MISSING')
    WHEN COALESCE(e.gr_event_count,0)>0 AND COALESCE(e.ir_event_count,0)=0
      THEN 'PRESENCE_DIAGNOSTIC_GR_SEEN_IR_NOT_SEEN'
    WHEN COALESCE(e.ir_event_count,0)>0 AND COALESCE(e.gr_event_count,0)=0
      THEN 'PRESENCE_DIAGNOSTIC_IR_SEEN_GR_NOT_SEEN'
    WHEN COALESCE(e.gr_event_count,0)>0 AND COALESCE(e.ir_event_count,0)>0
     AND ABS(f.open_fi_amount_dc)>p.exact_tolerance
      THEN 'PRESENCE_DIAGNOSTIC_BOTH_EVENTS_WITH_OPEN_FI_RESIDUAL'
    WHEN COALESCE(e.other_event_count,0)>0
      THEN 'PRESENCE_DIAGNOSTIC_OTHER_EVENT'
    ELSE 'PRESENCE_DIAGNOSTIC_OTHER_OPEN_GRIR'
  END                                                AS lifecycle_exception_type,
  'NOT_TESTED_ACROSS_COMPLETE_BUYER_AP_POPULATION'    AS buyer_ap_presence_status,
  'BLOCKED_CONTRACT_INCOMPLETE'                      AS automation_eligibility_status,
  'DIAGNOSTIC_ONLY_CONTRACT_INCOMPLETE'              AS arap_relevance,
  f.oldest_fi_posting_date, f.newest_fi_posting_date,
  f.as_of_date, f.cutoff_exclusive, f.reconciliation_run_id
FROM ic_v3_grir_fi_po_summary f
CROSS JOIN ic_v3_params p
JOIN ic_v3_grir_po_item_slice_control sc
  ON sc.source_system_id=f.source_system_id
 AND sc.source_client=f.source_client
 AND sc.company_code=f.company_code
 AND sc.purchase_order=f.purchase_order
 AND sc.purchase_order_item=f.purchase_order_item
 AND sc.as_of_date=f.as_of_date
 AND sc.cutoff_exclusive=f.cutoff_exclusive
 AND sc.reconciliation_run_id=f.reconciliation_run_id
LEFT JOIN ic_v3_grir_po_event_summary e
  ON e.source_system_id=f.source_system_id
 AND e.source_client=f.source_client
 AND e.company_code=f.company_code
 AND e.purchase_order=f.purchase_order
 AND e.purchase_order_item=f.purchase_order_item
 AND e.cutoff_exclusive=f.cutoff_exclusive;

-- Operationally useful routing without claiming a monetary GR-to-IR match.
-- Each reason is a hypothesis/check queue backed by the explicit status fields.
CREATE OR REPLACE TEMP VIEW ic_v3_grir_workqueue AS
SELECT
  grir_po_item_id, reconciliation_run_id, as_of_date, cutoff_exclusive,
  source_system_id, source_client, company_code,
  owner_entity_id, resolved_partner_entity_id, partner_resolution_status,
  purchase_order, purchase_order_item, grir_account, document_currency,
  local_currency_status,
  open_fi_line_count, clearing_control_exception_line_count,
  open_fi_amount_dc, gross_fi_amount_dc,
  oldest_fi_posting_date, newest_fi_posting_date,
  DATEDIFF(as_of_date,oldest_fi_posting_date)         AS oldest_open_age_days,
  CASE
    WHEN as_of_date IS NULL OR oldest_fi_posting_date IS NULL THEN 'AGE_UNKNOWN'
    WHEN DATEDIFF(as_of_date,oldest_fi_posting_date)<=30 THEN 'AGE_000_030'
    WHEN DATEDIFF(as_of_date,oldest_fi_posting_date)<=60 THEN 'AGE_031_060'
    WHEN DATEDIFF(as_of_date,oldest_fi_posting_date)<=90 THEN 'AGE_061_090'
    WHEN DATEDIFF(as_of_date,oldest_fi_posting_date)<=180 THEN 'AGE_091_180'
    ELSE 'AGE_181_PLUS'
  END                                                AS aging_bucket,
  lifecycle_exception_type, po_owner_status, event_control_status,
  assignment_link_status, assignment_basis_status,
  history_basis_status, event_measure_additivity_status, reversal_status,
  lifecycle_exception_type                           AS raw_presence_hypothesis,
  CASE
    WHEN clearing_control_exception_line_count IS NULL
      THEN 'BLOCKED_CLEARING_CONTROL_MISSING'
    WHEN clearing_control_exception_line_count>0
      THEN 'BLOCKED_CLEARING_CONTROL'
    WHEN COALESCE(po_owner_status,'PO_OWNER_STATUS_MISSING')
         <>'CONFIRMED_PO_OWNER'
      THEN 'BLOCKED_PO_OWNER_CONTROL'
    WHEN COALESCE(event_control_status,'EVENT_CONTROL_STATUS_MISSING')
         <>'PRESENCE_DIAGNOSTIC_REVERSAL_MAP_INCOMPLETE'
      THEN 'BLOCKED_EVENT_CONTROL'
    WHEN COALESCE(history_basis_status,'HISTORY_BASIS_STATUS_MISSING')
         <>'EKBE_AND_EKBEH_COVERAGE_CERTIFIED'
      OR COALESCE(reversal_status,'REVERSAL_STATUS_MISSING')
         <>'REVERSAL_LINEAGE_COMPLETE'
      THEN 'BLOCKED_HISTORY_OR_REVERSAL_INCOMPLETE'
    WHEN COALESCE(assignment_basis_status,'ASSIGNMENT_BASIS_STATUS_MISSING')
         <>'ASSIGNMENT_LEVEL_HISTORY_INGESTED'
      OR COALESCE(assignment_link_status,'ASSIGNMENT_LINK_STATUS_MISSING')
         <>'PO_ITEM_UNIQUE_ASSIGNMENT'
      THEN 'BLOCKED_ASSIGNMENT_LINEAGE'
    WHEN lifecycle_exception_type IS NULL
      THEN 'BLOCKED_LIFECYCLE_CLASSIFICATION_MISSING'
    ELSE 'ELIGIBLE_FOR_BUSINESS_ROUTING'
  END                                                AS routing_safety_status,
  CASE
    WHEN clearing_control_exception_line_count IS NULL
      THEN 'SAP_FI_CLEARING_DATA_STEWARDSHIP'
    WHEN clearing_control_exception_line_count>0
      THEN 'SAP_FI_CLEARING_DATA_STEWARDSHIP'
    WHEN COALESCE(po_owner_status,'PO_OWNER_STATUS_MISSING')
         <>'CONFIRMED_PO_OWNER'
      THEN 'DATA_STEWARDSHIP_PO_OWNERSHIP'
    WHEN COALESCE(event_control_status,'PO_HISTORY_MISSING')='PO_HISTORY_MISSING'
      THEN 'DATA_STEWARDSHIP_PO_HISTORY_COMPLETENESS'
    WHEN COALESCE(event_control_status,'EVENT_CONTROL_STATUS_MISSING')
         <>'PRESENCE_DIAGNOSTIC_REVERSAL_MAP_INCOMPLETE'
      THEN 'SAP_EVENT_RULE_STEWARDSHIP'
    WHEN COALESCE(history_basis_status,'HISTORY_BASIS_STATUS_MISSING')
         <>'EKBE_AND_EKBEH_COVERAGE_CERTIFIED'
      THEN 'SAP_PO_HISTORY_ARCHIVE_STEWARDSHIP'
    WHEN COALESCE(reversal_status,'REVERSAL_STATUS_MISSING')
         <>'REVERSAL_LINEAGE_COMPLETE'
      THEN 'SAP_EVENT_REVERSAL_STEWARDSHIP'
    WHEN COALESCE(assignment_basis_status,'ASSIGNMENT_BASIS_STATUS_MISSING')
         <>'ASSIGNMENT_LEVEL_HISTORY_INGESTED'
      OR COALESCE(assignment_link_status,'ASSIGNMENT_LINK_STATUS_MISSING')
         <>'PO_ITEM_UNIQUE_ASSIGNMENT'
      THEN 'ACCOUNT_ASSIGNMENT_REVIEW'
    WHEN lifecycle_exception_type IS NULL
      THEN 'GRIR_DATA_QUALITY_STEWARDSHIP'
    WHEN lifecycle_exception_type='PRESENCE_DIAGNOSTIC_GR_SEEN_IR_NOT_SEEN'
      THEN 'SUPPLIER_INVOICE_FOLLOWUP'
    WHEN lifecycle_exception_type='PRESENCE_DIAGNOSTIC_IR_SEEN_GR_NOT_SEEN'
      THEN 'RECEIPT_OR_SERVICE_ENTRY_REVIEW'
    WHEN lifecycle_exception_type=
         'PRESENCE_DIAGNOSTIC_BOTH_EVENTS_WITH_OPEN_FI_RESIDUAL'
      THEN 'GRIR_CLEARING_OR_VARIANCE_REVIEW'
    ELSE 'GRIR_ANALYST_REVIEW'
  END                                                AS recommended_owner_queue,
  CASE
    WHEN clearing_control_exception_line_count IS NULL
      THEN 'Restore the clearing-control result before interpreting or routing this PO item.'
    WHEN clearing_control_exception_line_count>0
      THEN 'Resolve AUGDT/AUGBL/AUGGJ and referenced BKPF chronology before treating the FI amount as open.'
    WHEN COALESCE(po_owner_status,'PO_OWNER_STATUS_MISSING')
         <>'CONFIRMED_PO_OWNER'
      THEN 'Resolve the EKKO purchasing-company owner and its agreement with the GR/IR company.'
    WHEN COALESCE(event_control_status,'PO_HISTORY_MISSING')='PO_HISTORY_MISSING'
      THEN 'Verify EKBE/EKBEH extraction, PO owner and cutoff before business follow-up.'
    WHEN COALESCE(event_control_status,'EVENT_CONTROL_STATUS_MISSING')
         <>'PRESENCE_DIAGNOSTIC_REVERSAL_MAP_INCOMPLETE'
      THEN 'Resolve event-key, date, amount, sign or mapping controls before interpreting PO history.'
    WHEN COALESCE(history_basis_status,'HISTORY_BASIS_STATUS_MISSING')
         <>'EKBE_AND_EKBEH_COVERAGE_CERTIFIED'
      THEN 'Load and reconcile EKBE plus EKBEH before interpreting GR-only or IR-only presence.'
    WHEN COALESCE(reversal_status,'REVERSAL_STATUS_MISSING')
         <>'REVERSAL_LINEAGE_COMPLETE'
      THEN 'Build native reversal lineage before routing invoice, receipt or clearing follow-up.'
    WHEN COALESCE(assignment_basis_status,'ASSIGNMENT_BASIS_STATUS_MISSING')
         <>'ASSIGNMENT_LEVEL_HISTORY_INGESTED'
      OR COALESCE(assignment_link_status,'ASSIGNMENT_LINK_STATUS_MISSING')
         <>'PO_ITEM_UNIQUE_ASSIGNMENT'
      THEN 'Load and reconcile assignment-level PO history before using an assignment-specific explanation.'
    WHEN lifecycle_exception_type IS NULL
      THEN 'Restore the lifecycle classification before routing this PO item.'
    WHEN lifecycle_exception_type='PRESENCE_DIAGNOSTIC_GR_SEEN_IR_NOT_SEEN'
      THEN 'Check posted/parked supplier invoice, invoice block and expected invoice timing.'
    WHEN lifecycle_exception_type='PRESENCE_DIAGNOSTIC_IR_SEEN_GR_NOT_SEEN'
      THEN 'Check goods receipt/service entry, non-valuated receipt and reversal timing.'
    WHEN lifecycle_exception_type=
         'PRESENCE_DIAGNOSTIC_BOTH_EVENTS_WITH_OPEN_FI_RESIDUAL'
      THEN 'Check quantities, price differences, delivery costs, reversals and clearing state.'
    ELSE 'Review native FI, material and invoice references at the same cutoff.'
  END                                                AS recommended_next_check,
  'RAW_PRESENCE_HYPOTHESIS_NOT_ACCOUNTING_CONCLUSION' AS workqueue_evidence_limit
FROM ic_v3_grir_po_item_lifecycle;

-- GR/IR FI lines with no exact PO/item remain visible here. They are not
-- forced into a PO lifecycle by document, amount or date proximity.
CREATE OR REPLACE TEMP VIEW ic_v3_grir_lineage_exception AS
SELECT
  reconciliation_run_id, as_of_date, cutoff_exclusive,
  source_system_id, source_client, company_code,
  grir_fi_line_id, fiscal_year, accounting_document,
  line_item_number, document_currency,
  signed_amount_dc, signed_amount_lc,
  CASE
    WHEN purchase_order IS NULL AND purchase_order_item IS NULL
      THEN 'PO_AND_ITEM_MISSING'
    WHEN purchase_order IS NULL THEN 'PO_MISSING'
    WHEN purchase_order_item IS NULL THEN 'PO_ITEM_MISSING'
  END                                                AS lineage_exception
FROM ic_v3_grir_fi_open_line
WHERE purchase_order IS NULL OR purchase_order_item IS NULL;

-- ============================================================================
-- 11. BOUNDED AR/AP-to-GRIR EXPLANATION CANDIDATES
--     These rows are metadata only. They never change arap_net_dc.
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_arap_grir_link_candidate AS
SELECT
  i.source_item_id                                   AS arap_source_item_id,
  g.grir_po_item_id,
  i.signed_amount_dc                                 AS arap_amount_dc,
  g.open_fi_amount_dc                                AS grir_open_amount_dc,
  i.document_currency,
  i.reconciliation_run_id,
  i.cutoff_exclusive,
  i.match_side,
  m.match_status,
  mc.membership_control_status,
  g.arap_relevance,
  g.lifecycle_exception_type,
  g.clearing_control_exception_line_count,
  g.event_control_status,
  g.assignment_link_status,
  g.history_basis_status,
  g.reversal_status,
  g.buyer_ap_presence_status,
  g.automation_eligibility_status
FROM ic_v3_item_fact i
JOIN ic_v3_item_po_evidence po
  ON po.source_item_id=i.source_item_id
 AND po.po_lineage_status='FI_LINE_PO_REFERENCE_PRESENT'
JOIN ic_v3_match_membership m
  ON m.source_item_id=i.source_item_id
 AND m.match_status IN (
       'UNMATCHED','BVORG_ONE_SIDED','SUGGESTED_REFERENCE_ONE_SIDED')
JOIN ic_v3_match_membership_control mc
  ON mc.source_item_id=i.source_item_id
 AND mc.membership_control_status='PASS'
JOIN ic_v3_grir_po_item_lifecycle g
  ON g.source_system_id=i.source_system_id
 AND g.source_client=i.source_client
 AND g.purchase_order=po.purchase_order
 AND g.purchase_order_item=po.purchase_order_item
 AND g.owner_entity_id=i.resolved_partner_entity_id
 AND g.resolved_partner_entity_id=i.owner_entity_id
 AND g.document_currency=i.document_currency
 AND g.cutoff_exclusive=i.cutoff_exclusive
WHERE i.match_side='AR'
  AND i.partner_match_eligible;

CREATE OR REPLACE TEMP VIEW ic_v3_arap_grir_candidate_unique AS
SELECT DISTINCT *
FROM ic_v3_arap_grir_link_candidate;

-- Count rows before candidate de-duplication. This prevents two physical join
-- paths for the same AR/PO pair from looking one-to-one merely because the
-- ambiguity counters below use distinct opposite-side identifiers.
CREATE OR REPLACE TEMP VIEW ic_v3_arap_grir_pair_physical_control AS
SELECT
  arap_source_item_id,
  grir_po_item_id,
  COUNT(*)                                           AS candidate_physical_row_count,
  CASE WHEN COUNT(*)=1 THEN 'PASS'
       ELSE 'FAIL_PAIR_PHYSICAL_CARDINALITY' END     AS pair_physical_control_status
FROM ic_v3_arap_grir_link_candidate
GROUP BY arap_source_item_id, grir_po_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_arap_candidate_count AS
SELECT
  arap_source_item_id,
  COUNT(DISTINCT grir_po_item_id)                    AS grir_candidates_for_arap
FROM ic_v3_arap_grir_candidate_unique
GROUP BY arap_source_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_candidate_count AS
SELECT
  grir_po_item_id,
  COUNT(DISTINCT arap_source_item_id)                AS arap_candidates_for_grir
FROM ic_v3_arap_grir_candidate_unique
GROUP BY grir_po_item_id;

CREATE OR REPLACE TEMP VIEW ic_v3_arap_grir_link AS
SELECT DISTINCT
  c.arap_source_item_id, c.grir_po_item_id,
  ac.grir_candidates_for_arap, gc.arap_candidates_for_grir,
  pc.candidate_physical_row_count, pc.pair_physical_control_status,
  'PROBABLE_SOURCE_LOCAL_PO_REFERENCE_AND_RECIPROCAL_CODE'
                                                       AS lineage_tier,
  CASE
    WHEN pc.pair_physical_control_status<>'PASS'
      THEN 'DIAGNOSTIC_ONLY_PHYSICAL_PAIR_NONUNIQUE'
    WHEN ac.grir_candidates_for_arap<>1 OR gc.arap_candidates_for_grir<>1
      THEN 'DIAGNOSTIC_ONLY_AMBIGUOUS_PROBABLE_LINEAGE'
    WHEN c.clearing_control_exception_line_count>0
      THEN 'DIAGNOSTIC_ONLY_CLEARING_CONTROL_FAILURE'
    WHEN c.arap_amount_dc IS NULL OR c.grir_open_amount_dc IS NULL
      THEN 'DIAGNOSTIC_ONLY_AMOUNT_MISSING_OR_INVALID'
    WHEN c.arap_amount_dc<=CAST(0 AS DECIMAL(38,6))
      THEN 'DIAGNOSTIC_ONLY_AR_IS_NOT_A_DEBIT_RECEIVABLE'
    WHEN c.grir_open_amount_dc>=CAST(0 AS DECIMAL(38,6))
      THEN 'DIAGNOSTIC_ONLY_GRIR_IS_NOT_A_CREDIT_RECEIPT_ACCRUAL'
    WHEN c.event_control_status<>'PRESENCE_DIAGNOSTIC_REVERSAL_MAP_INCOMPLETE'
      THEN 'DIAGNOSTIC_ONLY_EVENT_CONTROL_FAILURE'
    WHEN c.assignment_link_status IN (
         'NO_ASSIGNMENT_HISTORY','ASSIGNMENT_HISTORY_PARTIAL',
         'MULTIPLE_ASSIGNMENTS_FI_AMOUNT_UNALLOCATED')
      THEN 'DIAGNOSTIC_ONLY_ASSIGNMENT_LINEAGE_INCOMPLETE'
    WHEN c.lifecycle_exception_type<>'PRESENCE_DIAGNOSTIC_GR_SEEN_IR_NOT_SEEN'
      THEN 'DIAGNOSTIC_ONLY_NOT_GR_ONLY_RAW_PRESENCE'
    WHEN c.history_basis_status<>'EKBE_AND_EKBEH_COVERAGE_CERTIFIED'
      OR c.reversal_status<>'REVERSAL_LINEAGE_COMPLETE'
      THEN 'DIAGNOSTIC_ONLY_HISTORY_OR_REVERSAL_INCOMPLETE'
    ELSE 'DIAGNOSTIC_ONLY_BUYER_AP_ABSENCE_AND_CROSS_SYSTEM_LINEAGE_NOT_PROVEN'
  END                                                AS explanation_status,
  CASE
    WHEN pc.pair_physical_control_status<>'PASS'
      THEN 'SIGN_DIRECTION_NOT_EVALUATED_PAIR_NONUNIQUE'
    WHEN c.arap_amount_dc IS NULL OR c.grir_open_amount_dc IS NULL
      THEN 'SIGN_DIRECTION_UNKNOWN_AMOUNT_MISSING_OR_INVALID'
    WHEN c.arap_amount_dc>CAST(0 AS DECIMAL(38,6))
     AND c.grir_open_amount_dc<CAST(0 AS DECIMAL(38,6))
      THEN 'SIGN_DIRECTION_COMPATIBLE_WITH_GR_NOT_IR_HYPOTHESIS'
    ELSE 'SIGN_DIRECTION_NOT_EXPLANATORY'
  END                                                AS causal_sign_status,
  'BLOCKED_CONTRACT_INCOMPLETE'                      AS automation_eligibility_status,
  c.buyer_ap_presence_status,
  CAST(NULL AS DECIMAL(38,6))                        AS supported_amount_dc,
  CAST(NULL AS DECIMAL(38,6))                        AS support_coverage_pct,
  CASE
    WHEN pc.pair_physical_control_status='PASS'
     AND ac.grir_candidates_for_arap=1
     AND gc.arap_candidates_for_grir=1
     AND c.clearing_control_exception_line_count=0
     AND c.lifecycle_exception_type='PRESENCE_DIAGNOSTIC_GR_SEEN_IR_NOT_SEEN'
     AND c.arap_amount_dc>CAST(0 AS DECIMAL(38,6))
     AND c.grir_open_amount_dc<CAST(0 AS DECIMAL(38,6))
      THEN 'ONE_TO_ONE_PAIRWISE_DIAGNOSTIC_NOT_CAUSAL_SUPPORT'
    ELSE 'NUMERIC_DIAGNOSTIC_SUPPRESSED_AMBIGUOUS_OR_NONCAUSAL'
  END                                                AS diagnostic_amount_status,
  CAST(CASE
    WHEN pc.pair_physical_control_status='PASS'
     AND ac.grir_candidates_for_arap=1
     AND gc.arap_candidates_for_grir=1
     AND c.clearing_control_exception_line_count=0
     AND c.lifecycle_exception_type='PRESENCE_DIAGNOSTIC_GR_SEEN_IR_NOT_SEEN'
     AND c.arap_amount_dc>CAST(0 AS DECIMAL(38,6))
     AND c.grir_open_amount_dc<CAST(0 AS DECIMAL(38,6))
    THEN LEAST(ABS(c.arap_amount_dc),ABS(c.grir_open_amount_dc)) END
       AS DECIMAL(38,6))                             AS diagnostic_bounded_overlap_dc,
  CAST(CASE
    WHEN pc.pair_physical_control_status='PASS'
     AND ac.grir_candidates_for_arap=1
     AND gc.arap_candidates_for_grir=1
     AND c.clearing_control_exception_line_count=0
     AND c.lifecycle_exception_type='PRESENCE_DIAGNOSTIC_GR_SEEN_IR_NOT_SEEN'
     AND c.arap_amount_dc>CAST(0 AS DECIMAL(38,6))
     AND c.grir_open_amount_dc<CAST(0 AS DECIMAL(38,6))
    THEN GREATEST(ABS(c.arap_amount_dc)-ABS(c.grir_open_amount_dc),0) END
       AS DECIMAL(38,6))                             AS diagnostic_uncovered_ar_dc,
  c.lifecycle_exception_type, c.clearing_control_exception_line_count,
  c.history_basis_status, c.reversal_status,
  c.arap_amount_dc, c.grir_open_amount_dc,
  c.document_currency, c.reconciliation_run_id, c.cutoff_exclusive
FROM ic_v3_arap_grir_candidate_unique c
JOIN ic_v3_arap_candidate_count ac
  ON ac.arap_source_item_id=c.arap_source_item_id
JOIN ic_v3_grir_candidate_count gc
  ON gc.grir_po_item_id=c.grir_po_item_id
JOIN ic_v3_arap_grir_pair_physical_control pc
  ON pc.arap_source_item_id=c.arap_source_item_id
 AND pc.grir_po_item_id=c.grir_po_item_id;

-- ============================================================================
-- 12. RELEASE GATES
--     A FAIL blocks the named publication scope. WARN is published exposure.
-- ============================================================================

CREATE OR REPLACE TEMP VIEW ic_v3_source_family_coverage_control AS
SELECT
  e.source_family, e.match_side,
  COUNT(i.source_family)                             AS physical_row_count,
  CASE WHEN COUNT(i.source_family)>0 THEN 'PRESENT'
       ELSE 'ABSENT_OR_UNPROVEN_ZERO' END            AS source_family_status
FROM (
  SELECT * FROM VALUES
    ('AR_SUBLEDGER','AR'),
    ('AP_SUBLEDGER','AP')
  AS x(source_family, match_side)
) e
LEFT JOIN ic_v3_item_physical i
  ON i.source_family=e.source_family
 AND i.match_side=e.match_side
GROUP BY e.source_family, e.match_side;

CREATE OR REPLACE TEMP VIEW ic_v3_parameter_control AS
SELECT
  COUNT(*)                                           AS parameter_row_count,
  SUM(CASE WHEN cutoff_exclusive=DATE_ADD(as_of_date,1)
           THEN 0 ELSE 1 END)                        AS invalid_cutoff_row_count,
  SUM(CASE
    WHEN NULLIF(TRIM(source_system_id),'') IS NULL
      OR NULLIF(TRIM(source_client),'') IS NULL
      OR as_of_date IS NULL OR cutoff_exclusive IS NULL
      OR NULLIF(TRIM(reporting_currency),'') IS NULL
      OR reporting_currency<>UPPER(TRIM(reporting_currency))
      OR exact_tolerance IS NULL OR exact_tolerance<0
      OR NULLIF(TRIM(reconciliation_run_id),'') IS NULL
      OR NULLIF(TRIM(rule_version),'') IS NULL
      OR fx_multiplier_contract_approved IS NULL
    THEN 1 ELSE 0 END)                              AS invalid_required_parameter_count,
  CASE
    WHEN COUNT(*)<>1 THEN 'FAIL_PARAMETER_ROW_COUNT'
    WHEN SUM(CASE WHEN cutoff_exclusive=DATE_ADD(as_of_date,1)
                  THEN 0 ELSE 1 END)>0 THEN 'FAIL_CUTOFF_BOUNDARY'
    WHEN SUM(CASE
      WHEN NULLIF(TRIM(source_system_id),'') IS NULL
        OR NULLIF(TRIM(source_client),'') IS NULL
        OR as_of_date IS NULL OR cutoff_exclusive IS NULL
        OR NULLIF(TRIM(reporting_currency),'') IS NULL
        OR reporting_currency<>UPPER(TRIM(reporting_currency))
        OR exact_tolerance IS NULL OR exact_tolerance<0
        OR NULLIF(TRIM(reconciliation_run_id),'') IS NULL
        OR NULLIF(TRIM(rule_version),'') IS NULL
        OR fx_multiplier_contract_approved IS NULL
      THEN 1 ELSE 0 END)>0 THEN 'FAIL_REQUIRED_PARAMETER_DOMAIN'
    ELSE 'PASS'
  END                                                AS parameter_control_status
FROM ic_v3_params;

CREATE OR REPLACE TEMP VIEW ic_v3_account_scope_control AS
SELECT
  source_system_id, source_client, company_code, source_family, gl_account,
  COUNT(*)                                           AS scope_row_count,
  COUNT(DISTINCT match_side)                         AS match_side_count,
  COUNT(DISTINCT position_semantics)                 AS position_semantics_count,
  COUNT(DISTINCT scope_rule_id)                      AS scope_rule_count,
  CASE
    WHEN SUM(CASE
      WHEN NULLIF(TRIM(source_system_id),'') IS NULL
        OR NULLIF(TRIM(source_client),'') IS NULL
        OR NULLIF(TRIM(company_code),'') IS NULL
        OR NULLIF(TRIM(source_family),'') IS NULL
        OR NULLIF(TRIM(gl_account),'') IS NULL
        OR NULLIF(TRIM(match_side),'') IS NULL
        OR NULLIF(TRIM(position_semantics),'') IS NULL
        OR NULLIF(TRIM(scope_rule_id),'') IS NULL
      THEN 1 ELSE 0 END)>0 THEN 'FAIL_SCOPE_KEY_INCOMPLETE'
    WHEN source_family NOT IN ('AR_SUBLEDGER','AP_SUBLEDGER')
      OR (source_family='AR_SUBLEDGER' AND MIN(match_side)<>'AR')
      OR (source_family='AP_SUBLEDGER' AND MIN(match_side)<>'AP')
      OR MIN(position_semantics)<>'OPEN_ITEM'
      OR COUNT(DISTINCT scope_rule_id)<>1
      THEN 'FAIL_SCOPE_SEMANTICS'
    WHEN COUNT(*)=1
     AND COUNT(DISTINCT match_side)=1
     AND COUNT(DISTINCT position_semantics)=1
     AND COUNT(DISTINCT scope_rule_id)=1 THEN 'PASS'
    ELSE 'FAIL_SCOPE_NOT_UNIQUE'
  END                                                AS scope_control_status
FROM ic_v3_account_scope
GROUP BY source_system_id, source_client, company_code, source_family, gl_account;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_account_scope_control AS
SELECT
  source_system_id, source_client, company_code, gl_account,
  COUNT(*)                                           AS scope_row_count,
  COUNT(DISTINCT position_semantics)                 AS position_semantics_count,
  COUNT(DISTINCT scope_rule_id)                      AS scope_rule_count,
  CASE WHEN SUM(CASE
              WHEN NULLIF(TRIM(source_system_id),'') IS NULL
                OR NULLIF(TRIM(source_client),'') IS NULL
                OR NULLIF(TRIM(company_code),'') IS NULL
                OR NULLIF(TRIM(gl_account),'') IS NULL
                OR NULLIF(TRIM(position_semantics),'') IS NULL
                OR NULLIF(TRIM(scope_rule_id),'') IS NULL
              THEN 1 ELSE 0 END)>0
       THEN 'FAIL_SCOPE_KEY_INCOMPLETE'
       WHEN COUNT(*)=1
             AND COUNT(DISTINCT position_semantics)=1
             AND MIN(position_semantics)='OPEN_ITEM'
             AND COUNT(DISTINCT scope_rule_id)=1
       THEN 'PASS' ELSE 'FAIL_SCOPE_NOT_UNIQUE' END  AS scope_control_status
FROM ic_v3_grir_account_scope
GROUP BY source_system_id, source_client, company_code, gl_account;

-- This bridge proves that the official resolved-pair output plus explicit
-- exceptions partitions item_fact without loss or fanout. Numeric comparisons
-- are conservation tests only; no unlike currencies are reported as a total.
CREATE OR REPLACE TEMP VIEW ic_v3_arap_population_control AS
SELECT
  i.item_count, i.distinct_item_count,
  b.bucket_item_count,
  i.signed_amount_dc AS item_signed_amount_dc,
  b.signed_amount_dc AS bucket_signed_amount_dc,
  i.gross_amount_dc AS item_gross_amount_dc,
  b.gross_amount_dc AS bucket_gross_amount_dc,
  rb.resolved_item_count,
  ps.pair_item_count,
  rb.resolved_signed_amount_dc,
  ps.pair_signed_amount_dc,
  rb.resolved_gross_amount_dc,
  ps.pair_gross_amount_dc,
  CASE
    WHEN i.item_count<>i.distinct_item_count THEN 'FAIL_DUPLICATE_ITEM_FACT_KEY'
    WHEN i.item_count<>b.bucket_item_count THEN 'FAIL_POPULATION_BUCKET_COUNT'
    WHEN i.signed_amount_dc<>b.signed_amount_dc
      OR i.gross_amount_dc<>b.gross_amount_dc THEN 'FAIL_POPULATION_BUCKET_AMOUNT'
    WHEN rb.resolved_item_count<>ps.pair_item_count
      THEN 'FAIL_RESOLVED_PAIR_ITEM_COUNT'
    WHEN rb.resolved_signed_amount_dc<>ps.pair_signed_amount_dc
      OR rb.resolved_gross_amount_dc<>ps.pair_gross_amount_dc
      THEN 'FAIL_RESOLVED_PAIR_AMOUNT'
    ELSE 'PASS'
  END                                                AS population_control_status
FROM (
  SELECT COUNT(*) AS item_count,
         COUNT(DISTINCT source_item_id) AS distinct_item_count,
         CAST(COALESCE(SUM(signed_amount_dc),0) AS DECIMAL(38,6)) AS signed_amount_dc,
         CAST(COALESCE(SUM(ABS(signed_amount_dc)),0) AS DECIMAL(38,6)) AS gross_amount_dc
  FROM ic_v3_item_fact
) i
CROSS JOIN (
  SELECT CAST(COALESCE(SUM(item_count),0) AS BIGINT) AS bucket_item_count,
         CAST(COALESCE(SUM(signed_amount_dc),0) AS DECIMAL(38,6)) AS signed_amount_dc,
         CAST(COALESCE(SUM(gross_amount_dc),0) AS DECIMAL(38,6)) AS gross_amount_dc
  FROM ic_v3_population_bridge
) b
CROSS JOIN (
  SELECT COUNT(*) AS resolved_item_count,
         CAST(COALESCE(SUM(signed_amount_dc),0) AS DECIMAL(38,6)) AS resolved_signed_amount_dc,
         CAST(COALESCE(SUM(ABS(signed_amount_dc)),0) AS DECIMAL(38,6)) AS resolved_gross_amount_dc
  FROM ic_v3_item_population_bucket
  WHERE population_bucket='RESOLVED_PAIR_POPULATION'
) rb
CROSS JOIN (
  SELECT CAST(COALESCE(SUM(item_count),0) AS BIGINT) AS pair_item_count,
         CAST(COALESCE(SUM(arap_net_dc),0) AS DECIMAL(38,6)) AS pair_signed_amount_dc,
         CAST(COALESCE(SUM(gross_exposure_dc),0) AS DECIMAL(38,6)) AS pair_gross_amount_dc
  FROM ic_v3_pair_currency_summary
) ps;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_fi_conservation_control AS
SELECT
  f.open_line_count, f.distinct_open_line_count,
  s.summarized_line_count, x.lineage_exception_line_count,
  f.open_signed_dc,
  CAST(s.summarized_signed_dc+x.lineage_exception_signed_dc AS DECIMAL(38,6))
                                                       AS accounted_signed_dc,
  f.open_gross_dc,
  CAST(s.summarized_gross_dc+x.lineage_exception_gross_dc AS DECIMAL(38,6))
                                                       AS accounted_gross_dc,
  f.open_signed_lc,
  CAST(s.summarized_signed_lc+x.lineage_exception_signed_lc AS DECIMAL(38,6))
                                                       AS accounted_signed_lc,
  f.open_gross_lc,
  CAST(s.summarized_gross_lc+x.lineage_exception_gross_lc AS DECIMAL(38,6))
                                                       AS accounted_gross_lc,
  CASE
    WHEN f.open_line_count<>f.distinct_open_line_count
      THEN 'FAIL_DUPLICATE_OPEN_FI_LINE_ID'
    WHEN f.open_line_count<>s.summarized_line_count+x.lineage_exception_line_count
      THEN 'FAIL_LINE_COUNT_CONSERVATION'
    WHEN f.open_signed_dc<>CAST(s.summarized_signed_dc+x.lineage_exception_signed_dc AS DECIMAL(38,6))
      OR f.open_gross_dc<>CAST(s.summarized_gross_dc+x.lineage_exception_gross_dc AS DECIMAL(38,6))
      OR f.open_signed_lc<>CAST(s.summarized_signed_lc+x.lineage_exception_signed_lc AS DECIMAL(38,6))
      OR f.open_gross_lc<>CAST(s.summarized_gross_lc+x.lineage_exception_gross_lc AS DECIMAL(38,6))
      THEN 'FAIL_AMOUNT_CONSERVATION'
    ELSE 'PASS'
  END                                                AS conservation_status
FROM (
  SELECT COUNT(*) AS open_line_count,
         COUNT(DISTINCT grir_fi_line_id) AS distinct_open_line_count,
         CAST(COALESCE(SUM(signed_amount_dc),0) AS DECIMAL(38,6)) AS open_signed_dc,
         CAST(COALESCE(SUM(ABS(signed_amount_dc)),0) AS DECIMAL(38,6)) AS open_gross_dc,
         CAST(COALESCE(SUM(signed_amount_lc),0) AS DECIMAL(38,6)) AS open_signed_lc,
         CAST(COALESCE(SUM(ABS(signed_amount_lc)),0) AS DECIMAL(38,6)) AS open_gross_lc
  FROM ic_v3_grir_fi_open_line
) f
CROSS JOIN (
  SELECT CAST(COALESCE(SUM(open_fi_line_count),0) AS BIGINT) AS summarized_line_count,
         CAST(COALESCE(SUM(open_fi_amount_dc),0) AS DECIMAL(38,6)) AS summarized_signed_dc,
         CAST(COALESCE(SUM(gross_fi_amount_dc),0) AS DECIMAL(38,6)) AS summarized_gross_dc,
         CAST(COALESCE(SUM(open_fi_amount_lc),0) AS DECIMAL(38,6)) AS summarized_signed_lc,
         CAST(COALESCE(SUM(gross_fi_amount_lc),0) AS DECIMAL(38,6)) AS summarized_gross_lc
  FROM ic_v3_grir_fi_po_summary
) s
CROSS JOIN (
  SELECT COUNT(*) AS lineage_exception_line_count,
         CAST(COALESCE(SUM(signed_amount_dc),0) AS DECIMAL(38,6)) AS lineage_exception_signed_dc,
         CAST(COALESCE(SUM(ABS(signed_amount_dc)),0) AS DECIMAL(38,6)) AS lineage_exception_gross_dc,
         CAST(COALESCE(SUM(signed_amount_lc),0) AS DECIMAL(38,6)) AS lineage_exception_signed_lc,
         CAST(COALESCE(SUM(ABS(signed_amount_lc)),0) AS DECIMAL(38,6)) AS lineage_exception_gross_lc
  FROM ic_v3_grir_lineage_exception
) x;

CREATE OR REPLACE TEMP VIEW ic_v3_grir_event_conservation_control AS
SELECT
  p.raw_physical_event_rows,
  a.accepted_event_rows,
  c.rejected_physical_event_rows,
  CASE
    WHEN p.raw_physical_event_rows
         <>a.accepted_event_rows+c.rejected_physical_event_rows
      THEN 'FAIL_EVENT_POPULATION_CONSERVATION'
    ELSE 'PASS'
  END                                                AS conservation_status
FROM (
  SELECT COUNT(*) AS raw_physical_event_rows
  FROM ic_v3_grir_po_history_event_physical
) p
CROSS JOIN (
  SELECT COUNT(*) AS accepted_event_rows
  FROM ic_v3_grir_po_history_event
) a
CROSS JOIN (
  SELECT CAST(COALESCE(SUM(CASE
              WHEN COALESCE(event_key_status,'EVENT_KEY_STATUS_MISSING')<>'PASS'
                                THEN physical_row_count ELSE 0 END),0) AS BIGINT)
                                                       AS rejected_physical_event_rows
  FROM ic_v3_grir_event_key_control
) c;

CREATE OR REPLACE TEMP VIEW ic_v3_release_gate AS
SELECT
  'ARAP' AS gate_scope,
  'SOURCE_ITEM_KEY_AND_PAYLOAD_UNIQUE' AS gate_name,
  CASE WHEN COUNT(DISTINCT source_item_id)=0 THEN 'PASS' ELSE 'FAIL' END AS gate_status,
  COUNT(DISTINCT source_item_id) AS violating_rows,
  CAST(COALESCE(SUM(ABS(signed_amount_dc)),0) AS DECIMAL(38,6)) AS violating_gross_dc,
  'Conflicting BSID/BSAD/BSIK/BSAK copies are quarantined, never selected.' AS gate_detail
FROM ic_v3_item_quarantine

UNION ALL

SELECT
  'ARAP','POSTING_DATE_VALID_AND_VISIBLE',
  CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  COUNT(*),
  CAST(COALESCE(SUM(ABS(signed_amount_dc)),0) AS DECIMAL(38,6)),
  'Null or invalid posting dates are quarantined before as-of selection.'
FROM ic_v3_item_preasof_quarantine

UNION ALL

SELECT
  'ARAP','REQUIRED_AMOUNT_CURRENCY_AND_SIGN_VALID',
  CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  COUNT(*),
  CAST(COALESCE(SUM(ABS(COALESCE(signed_amount_dc,raw_amount_dc))),0)
       AS DECIMAL(38,6)),
  'Missing currency/amount or invalid SHKZG blocks pair publication.'
FROM ic_v3_item_data_quality_exception

UNION ALL

SELECT
  'ARAP','CLEARING_DATE_VALID',
  CASE WHEN SUM(CASE
         WHEN COALESCE(clearing_date_status,'MISSING_CLEARING_DATE_STATUS')
                NOT IN ('INITIAL','VALID') THEN 1 ELSE 0 END)=0
       THEN 'PASS' ELSE 'FAIL' END,
  SUM(CASE WHEN COALESCE(clearing_date_status,'MISSING_CLEARING_DATE_STATUS')
                     NOT IN ('INITIAL','VALID') THEN 1 ELSE 0 END),
  CAST(SUM(CASE
    WHEN COALESCE(clearing_date_status,'MISSING_CLEARING_DATE_STATUS')
           NOT IN ('INITIAL','VALID')
                THEN ABS(signed_amount_dc) ELSE 0 END) AS DECIMAL(38,6)),
  'Malformed clearing dates are retained but block close certification.'
FROM ic_v3_item_fact

UNION ALL

SELECT
  'ARAP','SOURCE_INDEX_LIFECYCLE_CONSISTENT',
  CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  COUNT(*),
  CAST(COALESCE(SUM(ABS(signed_amount_dc)),0) AS DECIMAL(38,6)),
  'Open-index rows must have initial clearing fields; cleared-index rows need a valid clearing date/document on or after posting. Contradictions stay visible and cannot match.'
FROM ic_v3_item_source_lifecycle_exception

UNION ALL

SELECT
  'ARAP','FI_HEADER_RESOLVED',
  CASE WHEN SUM(CASE WHEN COALESCE(header_status,'HEADER_STATUS_MISSING')
                           <>'RESOLVED' THEN 1 ELSE 0 END)=0
       THEN 'PASS' ELSE 'FAIL' END,
  SUM(CASE WHEN COALESCE(header_status,'HEADER_STATUS_MISSING')<>'RESOLVED'
           THEN 1 ELSE 0 END),
  CAST(SUM(CASE WHEN COALESCE(header_status,'HEADER_STATUS_MISSING')<>'RESOLVED'
                THEN ABS(signed_amount_dc) ELSE 0 END) AS DECIMAL(38,6)),
  'Missing or conflicting BKPF headers block certified lineage.'
FROM ic_v3_item_fact

UNION ALL

SELECT
  'ARAP','OWNER_LEGAL_ENTITY_RESOLVED',
  CASE WHEN SUM(CASE WHEN COALESCE(owner_entity_status,'OWNER_ENTITY_STATUS_MISSING')
                           <>'RESOLVED_SOURCE_LOCAL_ENTITY'
                     THEN 1 ELSE 0 END)=0 THEN 'PASS' ELSE 'FAIL' END,
  SUM(CASE WHEN COALESCE(owner_entity_status,'OWNER_ENTITY_STATUS_MISSING')
                  <>'RESOLVED_SOURCE_LOCAL_ENTITY'
           THEN 1 ELSE 0 END),
  CAST(SUM(CASE WHEN COALESCE(owner_entity_status,'OWNER_ENTITY_STATUS_MISSING')
                       <>'RESOLVED_SOURCE_LOCAL_ENTITY'
                THEN ABS(signed_amount_dc) ELSE 0 END) AS DECIMAL(38,6)),
  'T001 BUKRS-to-RCOMP must be unique; cross-instance global xref is still required.'
FROM ic_v3_item_fact

UNION ALL

SELECT
  'ARAP','PARTNER_EXCEPTION_EXPOSURE',
  CASE WHEN SUM(CASE WHEN NOT COALESCE(partner_match_eligible,FALSE)
                     THEN 1 ELSE 0 END)=0
       THEN 'PASS' ELSE 'FAIL' END,
  SUM(CASE WHEN NOT COALESCE(partner_match_eligible,FALSE) THEN 1 ELSE 0 END),
  CAST(SUM(CASE WHEN NOT COALESCE(partner_match_eligible,FALSE)
                THEN ABS(signed_amount_dc) ELSE 0 END) AS DECIMAL(38,6)),
  'Unresolved, diagnostic-only, ambiguous, conflicting and self partners remain in exposure.'
FROM ic_v3_item_fact

UNION ALL

SELECT
  'ARAP','ALLOCATION_CONSERVES_EVERY_ITEM',
  CASE WHEN SUM(CASE
         WHEN COALESCE(allocation_control_status,'ALLOCATION_CONTROL_STATUS_MISSING')
                <>'PASS' THEN 1 ELSE 0 END)=0
       THEN 'PASS' ELSE 'FAIL' END,
  SUM(CASE
    WHEN COALESCE(allocation_control_status,'ALLOCATION_CONTROL_STATUS_MISSING')
           <>'PASS' THEN 1 ELSE 0 END),
  CAST(SUM(ABS(allocation_residual_dc)) AS DECIMAL(38,6)),
  'Split allocation must sum exactly to each source item.'
FROM ic_v3_allocation_control

UNION ALL

SELECT
  'ARAP','MATCH_MEMBERSHIP_CARDINALITY',
  CASE WHEN SUM(CASE
         WHEN COALESCE(membership_control_status,'MEMBERSHIP_CONTROL_STATUS_MISSING')
                <>'PASS' THEN 1 ELSE 0 END)=0
       THEN 'PASS' ELSE 'FAIL' END,
  SUM(CASE
    WHEN COALESCE(membership_control_status,'MEMBERSHIP_CONTROL_STATUS_MISSING')
           <>'PASS' THEN 1 ELSE 0 END),
  CAST(0 AS DECIMAL(38,6)),
  'Every eligible source item has exactly one selected match status.'
FROM ic_v3_match_membership_control

UNION ALL

SELECT
  'ARAP','SUGGESTED_MATCH_GROUPS_RECIPROCAL',
  CASE WHEN COALESCE(SUM(CASE
              WHEN COALESCE(group_status,'MISSING_MATCH_GROUP_STATUS') NOT IN (
                'SUGGESTED_BVORG_EXACT_SOURCE_SCOPED',
                'SUGGESTED_BVORG_LINKED_RESIDUAL',
                'SUGGESTED_REFERENCE_1_TO_1_EXACT_UNGOVERNED',
                'SUGGESTED_REFERENCE_M_TO_N_EXACT',
                'SUGGESTED_REFERENCE_RESIDUAL')
              THEN 1 ELSE 0 END),0)=0 THEN 'PASS' ELSE 'WARN' END,
  COALESCE(SUM(CASE
    WHEN COALESCE(group_status,'MISSING_MATCH_GROUP_STATUS') NOT IN (
      'SUGGESTED_BVORG_EXACT_SOURCE_SCOPED',
      'SUGGESTED_BVORG_LINKED_RESIDUAL',
      'SUGGESTED_REFERENCE_1_TO_1_EXACT_UNGOVERNED',
      'SUGGESTED_REFERENCE_M_TO_N_EXACT',
      'SUGGESTED_REFERENCE_RESIDUAL')
    THEN 1 ELSE 0 END),0),
  CAST(COALESCE(SUM(CASE
    WHEN COALESCE(group_status,'MISSING_MATCH_GROUP_STATUS') NOT IN (
      'SUGGESTED_BVORG_EXACT_SOURCE_SCOPED',
      'SUGGESTED_BVORG_LINKED_RESIDUAL',
      'SUGGESTED_REFERENCE_1_TO_1_EXACT_UNGOVERNED',
      'SUGGESTED_REFERENCE_M_TO_N_EXACT',
      'SUGGESTED_REFERENCE_RESIDUAL')
    THEN ABS(ar_total_dc)+ABS(ap_total_dc) ELSE 0 END),0) AS DECIMAL(38,6)),
  'One-sided, nonreciprocal or ambiguous reference groups remain visible but are excluded from suggested matched gross.'
FROM ic_v3_match_group

UNION ALL

SELECT
  'REPORTING_FX','FX_COMPLETE_AND_APPROVED',
  CASE WHEN SUM(CASE WHEN COALESCE(fx_status,'MISSING_FX_STATUS')
                              NOT IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
                     THEN 1 ELSE 0 END)=0 THEN 'PASS' ELSE 'FAIL' END,
  SUM(CASE WHEN COALESCE(fx_status,'MISSING_FX_STATUS')
                     NOT IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
           THEN 1 ELSE 0 END),
  CAST(SUM(CASE WHEN COALESCE(fx_status,'MISSING_FX_STATUS')
                          NOT IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
                THEN ABS(i.signed_amount_dc) ELSE 0 END) AS DECIMAL(38,6)),
  'FX totals cannot publish until rate uniqueness and quotation/factor semantics pass.'
FROM ic_v3_item_fx f
JOIN ic_v3_item_fact i ON i.source_item_id=f.source_item_id

UNION ALL

SELECT
  'MANUAL_GL','MANUAL_GL_POSITION_SEMANTICS_APPROVED',
  CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  COUNT(*),
  CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled while any configured manual IC account lacks a governed open-item or balance-from-inception fact; zero recent movements cannot prove a zero position.'
FROM ic_v3_manual_account_scope

UNION ALL

SELECT
  'GRIR','GRIR_FI_SOURCE_POPULATION_PRESENT',
  CASE WHEN COUNT(*)>0 THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN COUNT(*)>0 THEN CAST(0 AS BIGINT) ELSE CAST(1 AS BIGINT) END,
  CAST(0 AS DECIMAL(38,6)),
  'At least one scoped physical FI row is required in the sandbox; a certified source manifest is required to distinguish a true zero balance from an absent BSEG feed.'
FROM ic_v3_grir_line_physical

UNION ALL

SELECT
  'GRIR','GRIR_FI_LINE_UNIQUE',
  CASE WHEN SUM(CASE
         WHEN COALESCE(line_control_status,'LINE_CONTROL_STATUS_MISSING')<>'PASS'
         THEN 1 ELSE 0 END)=0
       THEN 'PASS' ELSE 'FAIL' END,
  SUM(CASE WHEN COALESCE(line_control_status,'LINE_CONTROL_STATUS_MISSING')<>'PASS'
           THEN 1 ELSE 0 END),
  CAST(0 AS DECIMAL(38,6)),
  'Every BSEG GR/IR FI line must have one payload.'
FROM ic_v3_grir_line_control

UNION ALL

SELECT
  'GRIR','GRIR_HEADER_AND_CLEARING_VALID',
  CASE WHEN SUM(CASE
    WHEN COALESCE(header_status,'HEADER_STATUS_MISSING')<>'HEADER_RESOLVED'
      OR COALESCE(posting_date_status,'POSTING_DATE_STATUS_MISSING')<>'VALID'
      OR COALESCE(clearing_control_status,'MISSING_CLEARING_CONTROL') NOT IN (
           'NOT_CLEARED','CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED')
    THEN 1 ELSE 0 END)=0 THEN 'PASS' ELSE 'FAIL' END,
  SUM(CASE
    WHEN COALESCE(header_status,'HEADER_STATUS_MISSING')<>'HEADER_RESOLVED'
      OR COALESCE(posting_date_status,'POSTING_DATE_STATUS_MISSING')<>'VALID'
      OR COALESCE(clearing_control_status,'MISSING_CLEARING_CONTROL') NOT IN (
           'NOT_CLEARED','CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED')
    THEN 1 ELSE 0 END),
  CAST(SUM(CASE
    WHEN COALESCE(header_status,'HEADER_STATUS_MISSING')<>'HEADER_RESOLVED'
      OR COALESCE(posting_date_status,'POSTING_DATE_STATUS_MISSING')<>'VALID'
      OR COALESCE(clearing_control_status,'MISSING_CLEARING_CONTROL') NOT IN (
           'NOT_CLEARED','CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED')
    THEN ABS(signed_amount_dc) ELSE 0 END) AS DECIMAL(38,6)),
  'Missing/conflicting headers, impossible chronology, incomplete AUGDT/AUGBL/AUGGJ, or an unresolved clearing BKPF remain visible and block the FI diagnostic.'
FROM ic_v3_grir_fi_candidate

UNION ALL

SELECT
  'GRIR_LIFECYCLE','PO_HISTORY_PRESENCE_DIAGNOSTIC_COMPLETE',
  CASE WHEN COALESCE(SUM(CASE
              WHEN COALESCE(event_control_status,'EVENT_CONTROL_STATUS_MISSING')
                   <>'PRESENCE_DIAGNOSTIC_REVERSAL_MAP_INCOMPLETE'
              THEN 1 ELSE 0 END),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  COALESCE(SUM(CASE
    WHEN COALESCE(event_control_status,'EVENT_CONTROL_STATUS_MISSING')
         <>'PRESENCE_DIAGNOSTIC_REVERSAL_MAP_INCOMPLETE'
    THEN 1 ELSE 0 END),0),
  CAST(0 AS DECIMAL(38,6)),
  'All scoped PO items have unique, dated, basic-mapped history; this approves presence diagnostics only.'
FROM ic_v3_grir_po_event_summary

UNION ALL

SELECT
  'GRIR_LIFECYCLE','PO_HISTORY_ARCHIVE_COVERAGE_CERTIFIED',
  'FAIL', CAST(1 AS BIGINT), CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled: this sandbox reads EKBE only. Reconcile EKBE plus EKBEH (or the released PO History API) before interpreting GR-only or IR-only presence.'
FROM ic_v3_params

UNION ALL

SELECT
  'GRIR_LIFECYCLE','EVENT_REVERSAL_LINEAGE_COMPLETE',
  'FAIL', CAST(1 AS BIGINT), CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled: raw presence cannot route business follow-up until native GR/IR reversal references and event effects are mapped and reconciled.'
FROM ic_v3_params

UNION ALL

SELECT
  'GRIR_AUTOMATION','EXACT_VALUE_REVERSAL_AND_EVENT_RULE_CONTRACT',
  'FAIL',
  CAST(1 AS BIGINT),
  CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled: requires governed event effects, reversal lineage, AREWR/AREWB/AREWW, multiple assignment, buyer-AP completeness and cross-system provenance.'
FROM ic_v3_params

UNION ALL

SELECT
  'RUN_CONTROL','ONE_PARAMETER_ROW_AND_EXCLUSIVE_CUTOFF',
  CASE WHEN parameter_control_status='PASS' THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN parameter_control_status='PASS' THEN CAST(0 AS BIGINT)
       ELSE CAST(1 AS BIGINT) END,
  CAST(0 AS DECIMAL(38,6)),
  'Exactly one parameter row is required and cutoff_exclusive must equal as_of_date plus one day.'
FROM ic_v3_parameter_control

UNION ALL

SELECT
  'ARAP','ACCOUNT_SCOPE_UNIQUE',
  CASE WHEN COALESCE(SUM(CASE
              WHEN COALESCE(scope_control_status,'SCOPE_CONTROL_STATUS_MISSING')<>'PASS'
              THEN 1 ELSE 0 END),0)=0
       THEN 'PASS' ELSE 'FAIL' END,
  COALESCE(SUM(CASE
    WHEN COALESCE(scope_control_status,'SCOPE_CONTROL_STATUS_MISSING')<>'PASS'
    THEN 1 ELSE 0 END),0),
  CAST(0 AS DECIMAL(38,6)),
  'Each source/client/company/family/account maps to exactly one side, position semantic and governed rule.'
FROM ic_v3_account_scope_control

UNION ALL

SELECT
  'ARAP','ACCOUNT_SCOPE_COMPANY_EXPLICIT',
  CASE WHEN COALESCE(SUM(CASE WHEN company_code='*' THEN 1 ELSE 0 END),0)=0
       THEN 'PASS' ELSE 'FAIL' END,
  COALESCE(SUM(CASE WHEN company_code='*' THEN 1 ELSE 0 END),0),
  CAST(0 AS DECIMAL(38,6)),
  'Wildcard company scope is diagnostic only. Replace each * with approved company codes because G/L semantics are company/chart-of-accounts specific.'
FROM ic_v3_account_scope

UNION ALL

SELECT
  'ARAP','ACCOUNT_SCOPE_COVERAGE_REGISTRY_CERTIFIED',
  'FAIL', CAST(1 AS BIGINT), CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled in this file: an explicit company/account list defines a pilot but cannot prove enterprise completeness without a controller-owned effective-dated scope registry and source tie-out.'
FROM ic_v3_params

UNION ALL

SELECT
  'ARAP','AR_AND_AP_SOURCE_FAMILIES_PRESENT',
  CASE WHEN SUM(CASE
         WHEN COALESCE(source_family_status,'SOURCE_FAMILY_STATUS_MISSING')<>'PRESENT'
         THEN 1 ELSE 0 END)=0
       THEN 'PASS' ELSE 'FAIL' END,
  SUM(CASE
    WHEN COALESCE(source_family_status,'SOURCE_FAMILY_STATUS_MISSING')<>'PRESENT'
    THEN 1 ELSE 0 END),
  CAST(0 AS DECIMAL(38,6)),
  'Both AR and AP extracts must be evidenced. Row presence is only a minimum check; the certified source manifest and SAP tie-out prove completeness.'
FROM ic_v3_source_family_coverage_control

UNION ALL

SELECT
  'ARAP','NATIVE_ITEM_KEY_COMPLETE',
  CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  COUNT(*),
  CAST(COALESCE(SUM(ABS(signed_amount_dc)),0) AS DECIMAL(38,6)),
  'Null or blank MANDT/BUKRS/GJAHR/BELNR/BUZEI components never enter the item fact.'
FROM ic_v3_item_native_key_quarantine

UNION ALL

SELECT
  'ARAP','OFFICIAL_POPULATION_PARTITIONS_AND_CONSERVES',
  CASE WHEN population_control_status='PASS' THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN population_control_status='PASS' THEN CAST(0 AS BIGINT)
       ELSE CAST(1 AS BIGINT) END,
  CAST(ABS(item_gross_amount_dc-bucket_gross_amount_dc)
       +ABS(resolved_gross_amount_dc-pair_gross_amount_dc) AS DECIMAL(38,6)),
  'Every item is exactly one resolved-pair or exception row; resolved-pair item count, signed amount and gross amount tie to the pair output.'
FROM ic_v3_arap_population_control

UNION ALL

SELECT
  'MANAGEMENT','OWNER_SPLIT_MAPPING_COMPLETE',
  CASE WHEN COALESCE(SUM(CASE
              WHEN COALESCE(allocation_status,'ALLOCATION_STATUS_MISSING')
                   <>'ALLOCATED_AND_MAPPED'
                              THEN 1 ELSE 0 END),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  COALESCE(SUM(CASE WHEN COALESCE(allocation_status,'ALLOCATION_STATUS_MISSING')
                          <>'ALLOCATED_AND_MAPPED'
                    THEN 1 ELSE 0 END),0),
  CAST(COALESCE(SUM(CASE
    WHEN COALESCE(allocation_status,'ALLOCATION_STATUS_MISSING')
           <>'ALLOCATED_AND_MAPPED'
                         THEN ABS(allocated_amount_dc) ELSE 0 END),0) AS DECIMAL(38,6)),
  'Unallocated, ambiguous and unmapped profit-center/OU/BU rows block certified management splits.'
FROM ic_v3_item_allocation

UNION ALL

SELECT
  'MANAGEMENT_COUNTERPART','COUNTERPART_ORG_LINEAGE_UNIQUE',
  CASE WHEN COALESCE(SUM(CASE
              WHEN COALESCE(partner_org_status,'PARTNER_ORG_STATUS_MISSING')
                   <>'COUNTERPART_ORG_UNIQUE' THEN 1 ELSE 0 END),0)=0
       THEN 'PASS' ELSE 'FAIL' END,
  COALESCE(SUM(CASE
    WHEN COALESCE(partner_org_status,'PARTNER_ORG_STATUS_MISSING')
         <>'COUNTERPART_ORG_UNIQUE'
                    THEN 1 ELSE 0 END),0),
  CAST(COALESCE(SUM(CASE
    WHEN COALESCE(partner_org_status,'PARTNER_ORG_STATUS_MISSING')
         <>'COUNTERPART_ORG_UNIQUE'
                         THEN ABS(allocated_amount_dc) ELSE 0 END),0) AS DECIMAL(38,6)),
  'Partner OU/BU requires an approved one-to-one transaction lineage and complete counterpart allocation.'
FROM ic_v3_management_allocation_detail

UNION ALL

SELECT
  'MANAGEMENT_LC','LOCAL_CURRENCY_CODE_INGESTED',
  'FAIL', CAST(1 AS BIGINT), CAST(0 AS DECIMAL(38,6)),
  'T001-WAERS or an equivalent effective company-currency source must label every local-currency amount.'
FROM ic_v3_params

UNION ALL

SELECT
  'GRIR','GRIR_ACCOUNT_SCOPE_UNIQUE',
  CASE WHEN COALESCE(SUM(CASE
              WHEN COALESCE(scope_control_status,'SCOPE_CONTROL_STATUS_MISSING')<>'PASS'
              THEN 1 ELSE 0 END),0)=0
       THEN 'PASS' ELSE 'FAIL' END,
  COALESCE(SUM(CASE
    WHEN COALESCE(scope_control_status,'SCOPE_CONTROL_STATUS_MISSING')<>'PASS'
    THEN 1 ELSE 0 END),0),
  CAST(0 AS DECIMAL(38,6)),
  'Each GR/IR source/client/company wildcard/account has one governed scope rule.'
FROM ic_v3_grir_account_scope_control

UNION ALL

SELECT
  'GRIR','REQUIRED_FI_AMOUNT_CURRENCY_AND_SIGN_VALID',
  CASE WHEN COALESCE(SUM(CASE
              WHEN document_currency IS NULL OR TRIM(document_currency)=''
                OR COALESCE(raw_amount_status,'RAW_AMOUNT_STATUS_MISSING')
                     <>'NONNEGATIVE_RAW_AMOUNT'
                OR signed_amount_dc IS NULL OR signed_amount_lc IS NULL
                OR debit_credit_code IS NULL OR debit_credit_code NOT IN ('S','H')
              THEN 1 ELSE 0 END),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  COALESCE(SUM(CASE
    WHEN document_currency IS NULL OR TRIM(document_currency)=''
      OR COALESCE(raw_amount_status,'RAW_AMOUNT_STATUS_MISSING')
           <>'NONNEGATIVE_RAW_AMOUNT'
      OR signed_amount_dc IS NULL OR signed_amount_lc IS NULL
      OR debit_credit_code IS NULL OR debit_credit_code NOT IN ('S','H')
    THEN 1 ELSE 0 END),0),
  CAST(COALESCE(SUM(CASE
    WHEN document_currency IS NULL OR TRIM(document_currency)=''
      OR COALESCE(raw_amount_status,'RAW_AMOUNT_STATUS_MISSING')
           <>'NONNEGATIVE_RAW_AMOUNT'
      OR signed_amount_dc IS NULL OR signed_amount_lc IS NULL
      OR debit_credit_code IS NULL OR debit_credit_code NOT IN ('S','H')
    THEN ABS(COALESCE(signed_amount_dc,raw_amount_dc)) ELSE 0 END),0) AS DECIMAL(38,6)),
  'Open GR/IR FI rows require valid sign, document currency, and document/local amounts.'
FROM ic_v3_grir_fi_open_line

UNION ALL

SELECT
  'GRIR','FI_TO_PO_SUMMARY_OR_LINEAGE_EXCEPTION_CONSERVES',
  CASE WHEN conservation_status='PASS' THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN conservation_status='PASS' THEN CAST(0 AS BIGINT)
       ELSE CAST(1 AS BIGINT) END,
  CAST(ABS(open_gross_dc-accounted_gross_dc) AS DECIMAL(38,6)),
  'Every open FI line and signed/gross amount lands in a PO/account/currency slice or the explicit no-PO exception.'
FROM ic_v3_grir_fi_conservation_control

UNION ALL

SELECT
  'GRIR','PARTNER_AND_OWNER_EXCEPTION_EXPOSURE',
  CASE WHEN COALESCE(SUM(CASE
              WHEN COALESCE(owner_entity_status,'OWNER_ENTITY_STATUS_MISSING')
                     <>'RESOLVED_SOURCE_LOCAL_ENTITY'
                OR COALESCE(partner_resolution_status,
                            'PARTNER_RESOLUTION_STATUS_MISSING')
                     NOT IN ('POSTED','DERIVED_UNIQUE')
              THEN 1 ELSE 0 END),0)=0 THEN 'PASS' ELSE 'WARN' END,
  COALESCE(SUM(CASE
    WHEN COALESCE(owner_entity_status,'OWNER_ENTITY_STATUS_MISSING')
           <>'RESOLVED_SOURCE_LOCAL_ENTITY'
      OR COALESCE(partner_resolution_status,'PARTNER_RESOLUTION_STATUS_MISSING')
           NOT IN ('POSTED','DERIVED_UNIQUE')
    THEN 1 ELSE 0 END),0),
  CAST(COALESCE(SUM(CASE
    WHEN COALESCE(owner_entity_status,'OWNER_ENTITY_STATUS_MISSING')
           <>'RESOLVED_SOURCE_LOCAL_ENTITY'
      OR COALESCE(partner_resolution_status,'PARTNER_RESOLUTION_STATUS_MISSING')
           NOT IN ('POSTED','DERIVED_UNIQUE')
    THEN ABS(signed_amount_dc) ELSE 0 END),0) AS DECIMAL(38,6)),
  'FI/PO diagnostics remain visible by company, but partner-based GR/IR interpretation is incomplete.'
FROM ic_v3_grir_fi_open_line

UNION ALL

SELECT
  'GRIR_LIFECYCLE','PO_OWNER_CONFIRMED',
  CASE WHEN COALESCE(SUM(CASE
              WHEN COALESCE(po_owner_status,'PO_OWNER_STATUS_MISSING')
                   <>'CONFIRMED_PO_OWNER'
                              THEN 1 ELSE 0 END),0)=0 THEN 'PASS' ELSE 'FAIL' END,
  COALESCE(SUM(CASE
    WHEN COALESCE(po_owner_status,'PO_OWNER_STATUS_MISSING')
         <>'CONFIRMED_PO_OWNER'
                    THEN 1 ELSE 0 END),0),
  CAST(0 AS DECIMAL(38,6)),
  'EKKO owner must be unique and equal the company carrying the scoped GR/IR FI line.'
FROM ic_v3_grir_po_scope_controlled

UNION ALL

SELECT
  'GRIR_LIFECYCLE','PO_ITEM_LINEAGE_COMPLETE',
  CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END,
  COUNT(*),
  CAST(COALESCE(SUM(ABS(signed_amount_dc)),0) AS DECIMAL(38,6)),
  'Every open GR/IR FI line must carry a controlled PO/item to enter the lifecycle; missing lineage remains in the explicit exception view.'
FROM ic_v3_grir_lineage_exception

UNION ALL

SELECT
  'GRIR_LIFECYCLE','EVENT_POPULATION_CONSERVES',
  CASE WHEN conservation_status='PASS' THEN 'PASS' ELSE 'FAIL' END,
  CASE WHEN conservation_status='PASS' THEN CAST(0 AS BIGINT)
       ELSE CAST(1 AS BIGINT) END,
  CAST(0 AS DECIMAL(38,6)),
  'Every landed EKBE physical row is either one accepted event or retained in duplicate/conflict/date quarantine.'
FROM ic_v3_grir_event_conservation_control

UNION ALL

SELECT
  'GRIR_LIFECYCLE','ACCOUNT_ASSIGNMENT_HISTORY_COMPLETE',
  CASE WHEN COALESCE(SUM(CASE
              WHEN COALESCE(assignment_basis_status,
                            'ASSIGNMENT_BASIS_STATUS_MISSING')
                     <>'ASSIGNMENT_LEVEL_HISTORY_INGESTED'
                OR COALESCE(assignment_link_status,
                            'ASSIGNMENT_LINK_STATUS_MISSING')
                     <>'PO_ITEM_UNIQUE_ASSIGNMENT'
              THEN 1 ELSE 0 END),0)=0 THEN 'PASS' ELSE 'WARN' END,
  COALESCE(SUM(CASE
    WHEN COALESCE(assignment_basis_status,'ASSIGNMENT_BASIS_STATUS_MISSING')
         <>'ASSIGNMENT_LEVEL_HISTORY_INGESTED'
      OR COALESCE(assignment_link_status,'ASSIGNMENT_LINK_STATUS_MISSING')
         <>'PO_ITEM_UNIQUE_ASSIGNMENT'
    THEN 1 ELSE 0 END),0),
  CAST(0 AS DECIMAL(38,6)),
  'EKBE-ZEKKN alone cannot distinguish a legitimate no-assignment item from missing EKBE_MA/EKKN detail; no, partial or multiple assignment history is warning-only.'
FROM ic_v3_grir_po_event_summary

UNION ALL

SELECT
  'GRIR_LIFECYCLE','EVENT_MEASURES_ADDITIVE_AT_LIFECYCLE_GRAIN',
  CASE WHEN COALESCE(SUM(CASE
              WHEN COALESCE(event_measure_additivity_status,
                            'EVENT_ADDITIVITY_STATUS_MISSING')
                   <>'ADDITIVE_AT_THIS_GRAIN'
              THEN 1 ELSE 0 END),0)=0 THEN 'PASS' ELSE 'WARN' END,
  COALESCE(SUM(CASE
    WHEN COALESCE(event_measure_additivity_status,
                  'EVENT_ADDITIVITY_STATUS_MISSING')
         <>'ADDITIVE_AT_THIS_GRAIN'
    THEN 1 ELSE 0 END),0),
  CAST(0 AS DECIMAL(38,6)),
  'EKBE event measures are PO-item facts and repeat across GR/IR-account/document-currency FI slices; aggregate ic_v3_grir_po_event_summary, not the lifecycle slice rows.'
FROM ic_v3_grir_po_item_slice_control

UNION ALL

SELECT
  'GRIR_AUTOMATION','SUPPORTED_AMOUNT_EMISSION_DISABLED',
  CASE WHEN COUNT(supported_amount_dc)=0
             AND COALESCE(SUM(CASE
                   WHEN COALESCE(automation_eligibility_status,
                                 'AUTOMATION_STATUS_MISSING')
                        <>'BLOCKED_CONTRACT_INCOMPLETE'
                                   THEN 1 ELSE 0 END),0)=0
       THEN 'PASS' ELSE 'FAIL' END,
  COUNT(supported_amount_dc)
    +COALESCE(SUM(CASE
          WHEN COALESCE(automation_eligibility_status,'AUTOMATION_STATUS_MISSING')
               <>'BLOCKED_CONTRACT_INCOMPLETE'
                       THEN 1 ELSE 0 END),0),
  CAST(COALESCE(SUM(ABS(supported_amount_dc)),0) AS DECIMAL(38,6)),
  'The sandbox may show bounded numeric overlap, but supported amount must remain null and automation blocked.'
FROM ic_v3_arap_grir_link

UNION ALL

SELECT
  'PRODUCTION_READINESS','SOURCE_CONTRACT_CERTIFIED',
  'FAIL', CAST(1 AS BIGINT),
  CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled in this file: a typed source-contract certification must be joined from an immutable evidence registry; editing a parameter label is not approval.'
FROM ic_v3_params

UNION ALL

SELECT
  'PRODUCTION_READINESS','SPECIAL_GL_AND_TRANSACTION_CLASSIFICATION_GOVERNED',
  'FAIL', CAST(1 AS BIGINT), CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled: ingest and govern UMSKZ/special-GL and relevant transaction classes before claiming complete enterprise AR/AP scope.'
FROM ic_v3_params

UNION ALL

SELECT
  'PRODUCTION_READINESS','CONSISTENT_SOURCE_SNAPSHOT_CAPTURED',
  'FAIL', CAST(1 AS BIGINT),
  CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled in this file: all SAP facts and masters need a registry-backed extraction watermark or time-travel snapshot; a text ID is not evidence.'
FROM ic_v3_params

UNION ALL

SELECT
  'PRODUCTION_READINESS','GLOBAL_EFFECTIVE_DATED_ENTITY_XREF',
  'FAIL', CAST(1 AS BIGINT),
  CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled in this file: cross-instance ECC/S4/legacy matching requires an effective-dated canonical-entity xref selected by an immutable registry join.'
FROM ic_v3_params

UNION ALL

SELECT
  'PRODUCTION_READINESS','REFERENCE_DATA_VERSIONS_PINNED',
  'FAIL', CAST(1 AS BIGINT),
  CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled in this file: profit-center and FX rows must be filtered by registry-backed immutable versions; text version labels cannot certify the joins.'
FROM ic_v3_params

UNION ALL

SELECT
  'PRODUCTION_READINESS','ACCOUNT_SCOPE_EFFECTIVE_DATED_AND_GOVERNED',
  'FAIL', CAST(1 AS BIGINT),
  CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled in this file: pilot literals require a joined effective-dated scope registry with company/chart context, controller approval and position semantics.'
FROM ic_v3_params

UNION ALL

SELECT
  'PRODUCTION_READINESS','RUN_SCOPED_MATERIALIZED_STAGES',
  'FAIL', CAST(1 AS BIGINT),
  CAST(0 AS DECIMAL(38,6)),
  'Hard-disabled in this temp-view sandbox: billion-row source, control, resolution and allocation stages must be materialized and evidenced by the run registry.'
FROM ic_v3_params;

CREATE OR REPLACE TEMP VIEW ic_v3_expected_release_gate AS
SELECT * FROM VALUES
  ('ARAP','SOURCE_ITEM_KEY_AND_PAYLOAD_UNIQUE'),
  ('ARAP','POSTING_DATE_VALID_AND_VISIBLE'),
  ('ARAP','REQUIRED_AMOUNT_CURRENCY_AND_SIGN_VALID'),
  ('ARAP','CLEARING_DATE_VALID'),
  ('ARAP','SOURCE_INDEX_LIFECYCLE_CONSISTENT'),
  ('ARAP','FI_HEADER_RESOLVED'),
  ('ARAP','OWNER_LEGAL_ENTITY_RESOLVED'),
  ('ARAP','PARTNER_EXCEPTION_EXPOSURE'),
  ('ARAP','ALLOCATION_CONSERVES_EVERY_ITEM'),
  ('ARAP','MATCH_MEMBERSHIP_CARDINALITY'),
  ('ARAP','SUGGESTED_MATCH_GROUPS_RECIPROCAL'),
  ('MANUAL_GL','MANUAL_GL_POSITION_SEMANTICS_APPROVED'),
  ('ARAP','ACCOUNT_SCOPE_UNIQUE'),
  ('ARAP','ACCOUNT_SCOPE_COMPANY_EXPLICIT'),
  ('ARAP','ACCOUNT_SCOPE_COVERAGE_REGISTRY_CERTIFIED'),
  ('ARAP','AR_AND_AP_SOURCE_FAMILIES_PRESENT'),
  ('ARAP','NATIVE_ITEM_KEY_COMPLETE'),
  ('ARAP','OFFICIAL_POPULATION_PARTITIONS_AND_CONSERVES'),
  ('REPORTING_FX','FX_COMPLETE_AND_APPROVED'),
  ('GRIR','GRIR_FI_LINE_UNIQUE'),
  ('GRIR','GRIR_FI_SOURCE_POPULATION_PRESENT'),
  ('GRIR','GRIR_HEADER_AND_CLEARING_VALID'),
  ('GRIR','GRIR_ACCOUNT_SCOPE_UNIQUE'),
  ('GRIR','REQUIRED_FI_AMOUNT_CURRENCY_AND_SIGN_VALID'),
  ('GRIR','FI_TO_PO_SUMMARY_OR_LINEAGE_EXCEPTION_CONSERVES'),
  ('GRIR','PARTNER_AND_OWNER_EXCEPTION_EXPOSURE'),
  ('GRIR_LIFECYCLE','PO_HISTORY_PRESENCE_DIAGNOSTIC_COMPLETE'),
  ('GRIR_LIFECYCLE','PO_HISTORY_ARCHIVE_COVERAGE_CERTIFIED'),
  ('GRIR_LIFECYCLE','EVENT_REVERSAL_LINEAGE_COMPLETE'),
  ('GRIR_LIFECYCLE','PO_OWNER_CONFIRMED'),
  ('GRIR_LIFECYCLE','PO_ITEM_LINEAGE_COMPLETE'),
  ('GRIR_LIFECYCLE','EVENT_POPULATION_CONSERVES'),
  ('GRIR_LIFECYCLE','ACCOUNT_ASSIGNMENT_HISTORY_COMPLETE'),
  ('GRIR_LIFECYCLE','EVENT_MEASURES_ADDITIVE_AT_LIFECYCLE_GRAIN'),
  ('GRIR_AUTOMATION','EXACT_VALUE_REVERSAL_AND_EVENT_RULE_CONTRACT'),
  ('GRIR_AUTOMATION','SUPPORTED_AMOUNT_EMISSION_DISABLED'),
  ('RUN_CONTROL','ONE_PARAMETER_ROW_AND_EXCLUSIVE_CUTOFF'),
  ('MANAGEMENT','OWNER_SPLIT_MAPPING_COMPLETE'),
  ('MANAGEMENT_COUNTERPART','COUNTERPART_ORG_LINEAGE_UNIQUE'),
  ('MANAGEMENT_LC','LOCAL_CURRENCY_CODE_INGESTED'),
  ('PRODUCTION_READINESS','SOURCE_CONTRACT_CERTIFIED'),
  ('PRODUCTION_READINESS','SPECIAL_GL_AND_TRANSACTION_CLASSIFICATION_GOVERNED'),
  ('PRODUCTION_READINESS','CONSISTENT_SOURCE_SNAPSHOT_CAPTURED'),
  ('PRODUCTION_READINESS','GLOBAL_EFFECTIVE_DATED_ENTITY_XREF'),
  ('PRODUCTION_READINESS','REFERENCE_DATA_VERSIONS_PINNED'),
  ('PRODUCTION_READINESS','ACCOUNT_SCOPE_EFFECTIVE_DATED_AND_GOVERNED'),
  ('PRODUCTION_READINESS','RUN_SCOPED_MATERIALIZED_STAGES')
AS x(gate_scope, gate_name);

CREATE OR REPLACE TEMP VIEW ic_v3_expected_release_gate_key_control AS
SELECT
  gate_scope, gate_name,
  COUNT(*)                                           AS expected_gate_row_count,
  CASE WHEN COUNT(*)=1 THEN 'PASS'
       ELSE 'FAIL_DUPLICATE_EXPECTED_GATE_KEY' END   AS expected_gate_key_status
FROM ic_v3_expected_release_gate
GROUP BY gate_scope, gate_name;

CREATE OR REPLACE TEMP VIEW ic_v3_release_gate_key_control AS
SELECT
  gate_scope, gate_name,
  COUNT(*)                                           AS gate_row_count,
  COUNT(DISTINCT gate_status)                        AS gate_status_count,
  CASE
    WHEN COUNT(*)<>1 THEN 'FAIL_DUPLICATE_GATE_KEY'
    WHEN COUNT(DISTINCT gate_status)<>1 THEN 'FAIL_AMBIGUOUS_GATE_STATUS'
    WHEN MIN(gate_status) NOT IN ('PASS','WARN','FAIL') THEN 'FAIL_UNKNOWN_GATE_STATUS'
    ELSE 'PASS'
  END                                                AS gate_key_control_status,
  CASE
    WHEN COUNT(*)=1 AND COUNT(DISTINCT gate_status)=1
     AND MIN(gate_status) IN ('PASS','WARN','FAIL') THEN MIN(gate_status)
    ELSE 'FAIL'
  END                                                AS actual_gate_status
FROM ic_v3_release_gate
GROUP BY gate_scope, gate_name;

CREATE OR REPLACE TEMP VIEW ic_v3_release_gate_manifest_control AS
SELECT
  COALESCE(e.gate_scope,a.gate_scope)                 AS gate_scope,
  COALESCE(e.gate_name,a.gate_name)                   AS gate_name,
  CASE WHEN e.gate_name IS NOT NULL THEN TRUE ELSE FALSE END
                                                       AS expected_gate,
  COALESCE(e.expected_gate_row_count,0)                AS expected_gate_row_count,
  COALESCE(a.gate_row_count,0)                        AS actual_gate_row_count,
  CASE
    WHEN e.gate_name IS NULL THEN 'UNMANIFESTED_ACTUAL_GATE'
    WHEN a.gate_name IS NULL THEN 'MISSING_EXPECTED_GATE'
    WHEN COALESCE(e.expected_gate_key_status,
                  'FAIL_EXPECTED_GATE_KEY_STATUS_MISSING')<>'PASS'
      THEN COALESCE(e.expected_gate_key_status,
                    'FAIL_EXPECTED_GATE_KEY_STATUS_MISSING')
    WHEN COALESCE(a.gate_key_control_status,
                  'FAIL_ACTUAL_GATE_KEY_STATUS_MISSING')<>'PASS'
      THEN COALESCE(a.gate_key_control_status,
                    'FAIL_ACTUAL_GATE_KEY_STATUS_MISSING')
    ELSE 'EXPECTED_GATE_PRESENT'
  END                                                AS manifest_status,
  CASE
    WHEN e.gate_name IS NULL OR a.gate_name IS NULL
      OR COALESCE(e.expected_gate_key_status,
                  'FAIL_EXPECTED_GATE_KEY_STATUS_MISSING')<>'PASS'
      OR COALESCE(a.gate_key_control_status,
                  'FAIL_ACTUAL_GATE_KEY_STATUS_MISSING')<>'PASS' THEN 'FAIL'
    ELSE COALESCE(a.actual_gate_status,'FAIL')
  END                                                AS effective_gate_status
FROM ic_v3_expected_release_gate_key_control e
FULL OUTER JOIN ic_v3_release_gate_key_control a
  ON a.gate_scope=e.gate_scope
 AND a.gate_name=e.gate_name;

CREATE OR REPLACE TEMP VIEW ic_v3_release_status AS
SELECT
  gate_scope,
  SUM(CASE WHEN COALESCE(effective_gate_status,'FAIL')='FAIL' THEN 1 ELSE 0 END)
                                                       AS failed_gate_count,
  SUM(CASE WHEN COALESCE(effective_gate_status,'FAIL')='WARN' THEN 1 ELSE 0 END)
                                                       AS warning_gate_count,
  SUM(CASE WHEN COALESCE(manifest_status,'MISSING_MANIFEST_STATUS')
                     <>'EXPECTED_GATE_PRESENT' THEN 1 ELSE 0 END)
                                                       AS manifest_exception_count,
  CASE
    WHEN SUM(CASE WHEN COALESCE(effective_gate_status,'FAIL')='FAIL'
                  THEN 1 ELSE 0 END)>0
      THEN 'BLOCKED'
    WHEN SUM(CASE WHEN COALESCE(effective_gate_status,'FAIL')='WARN'
                  THEN 1 ELSE 0 END)>0
      THEN 'ELIGIBLE_WITH_EXPLICIT_WARNINGS'
    ELSE 'ELIGIBLE_FOR_CONTROLLED_PUBLICATION'
  END                                                AS release_status
FROM ic_v3_release_gate_manifest_control
GROUP BY gate_scope;

-- Product-level status prevents a green component from being interpreted as a
-- green enterprise report. Each product explicitly declares its required
-- component scopes.
CREATE OR REPLACE TEMP VIEW ic_v3_product_catalog AS
SELECT * FROM VALUES
  ('ARAP_TRANSACTION_CURRENCY_SANDBOX',2),
  ('ARAP_ENTERPRISE_PRODUCTION',4),
  ('MANAGEMENT_OWNER_SPLIT_DC_SANDBOX',3),
  ('MANAGEMENT_COUNTERPART_SPLIT_DC_SANDBOX',4),
  ('MANAGEMENT_SPLIT_LC_ENTERPRISE',7),
  ('REPORTING_CURRENCY_ENTERPRISE',5),
  ('GRIR_FI_DIAGNOSTIC_SANDBOX',2),
  ('GRIR_PO_LIFECYCLE_DIAGNOSTIC_SANDBOX',3),
  ('GRIR_AUTOMATION',5)
AS x(product_name, expected_scope_count);

CREATE OR REPLACE TEMP VIEW ic_v3_product_scope_manifest AS
SELECT * FROM VALUES
  ('ARAP_TRANSACTION_CURRENCY_SANDBOX','RUN_CONTROL'),
  ('ARAP_TRANSACTION_CURRENCY_SANDBOX','ARAP'),
  ('ARAP_ENTERPRISE_PRODUCTION','RUN_CONTROL'),
  ('ARAP_ENTERPRISE_PRODUCTION','ARAP'),
  ('ARAP_ENTERPRISE_PRODUCTION','MANUAL_GL'),
  ('ARAP_ENTERPRISE_PRODUCTION','PRODUCTION_READINESS'),
  ('MANAGEMENT_OWNER_SPLIT_DC_SANDBOX','RUN_CONTROL'),
  ('MANAGEMENT_OWNER_SPLIT_DC_SANDBOX','ARAP'),
  ('MANAGEMENT_OWNER_SPLIT_DC_SANDBOX','MANAGEMENT'),
  ('MANAGEMENT_COUNTERPART_SPLIT_DC_SANDBOX','RUN_CONTROL'),
  ('MANAGEMENT_COUNTERPART_SPLIT_DC_SANDBOX','ARAP'),
  ('MANAGEMENT_COUNTERPART_SPLIT_DC_SANDBOX','MANAGEMENT'),
  ('MANAGEMENT_COUNTERPART_SPLIT_DC_SANDBOX','MANAGEMENT_COUNTERPART'),
  ('MANAGEMENT_SPLIT_LC_ENTERPRISE','RUN_CONTROL'),
  ('MANAGEMENT_SPLIT_LC_ENTERPRISE','ARAP'),
  ('MANAGEMENT_SPLIT_LC_ENTERPRISE','MANAGEMENT'),
  ('MANAGEMENT_SPLIT_LC_ENTERPRISE','MANAGEMENT_COUNTERPART'),
  ('MANAGEMENT_SPLIT_LC_ENTERPRISE','MANAGEMENT_LC'),
  ('MANAGEMENT_SPLIT_LC_ENTERPRISE','MANUAL_GL'),
  ('MANAGEMENT_SPLIT_LC_ENTERPRISE','PRODUCTION_READINESS'),
  ('REPORTING_CURRENCY_ENTERPRISE','RUN_CONTROL'),
  ('REPORTING_CURRENCY_ENTERPRISE','ARAP'),
  ('REPORTING_CURRENCY_ENTERPRISE','REPORTING_FX'),
  ('REPORTING_CURRENCY_ENTERPRISE','MANUAL_GL'),
  ('REPORTING_CURRENCY_ENTERPRISE','PRODUCTION_READINESS'),
  ('GRIR_FI_DIAGNOSTIC_SANDBOX','RUN_CONTROL'),
  ('GRIR_FI_DIAGNOSTIC_SANDBOX','GRIR'),
  ('GRIR_PO_LIFECYCLE_DIAGNOSTIC_SANDBOX','RUN_CONTROL'),
  ('GRIR_PO_LIFECYCLE_DIAGNOSTIC_SANDBOX','GRIR'),
  ('GRIR_PO_LIFECYCLE_DIAGNOSTIC_SANDBOX','GRIR_LIFECYCLE'),
  ('GRIR_AUTOMATION','RUN_CONTROL'),
  ('GRIR_AUTOMATION','GRIR'),
  ('GRIR_AUTOMATION','GRIR_LIFECYCLE'),
  ('GRIR_AUTOMATION','GRIR_AUTOMATION'),
  ('GRIR_AUTOMATION','PRODUCTION_READINESS')
AS x(product_name, required_gate_scope);

CREATE OR REPLACE TEMP VIEW ic_v3_product_scope_control AS
SELECT
  product_name, required_gate_scope,
  COUNT(*)                                           AS scope_mapping_row_count,
  CASE WHEN COUNT(*)=1 THEN 'PASS'
       ELSE 'FAIL_DUPLICATE_PRODUCT_SCOPE_MAPPING' END
                                                      AS scope_mapping_status
FROM ic_v3_product_scope_manifest
GROUP BY product_name, required_gate_scope;

CREATE OR REPLACE TEMP VIEW ic_v3_product_release_status AS
SELECT
  p.product_name,
  p.expected_scope_count,
  COUNT(DISTINCT m.required_gate_scope)              AS manifest_scope_count,
  COUNT(DISTINCT CASE
                 WHEN COALESCE(m.scope_mapping_status,
                               'MISSING_SCOPE_MAPPING_STATUS')<>'PASS'
                      THEN m.required_gate_scope END) AS duplicate_scope_mapping_count,
  COUNT(c.gate_name)                                 AS required_gate_count,
  SUM(CASE WHEN COALESCE(c.actual_gate_row_count,0)>0 THEN 1 ELSE 0 END)
                                                       AS matched_gate_count,
  CAST(
    CASE WHEN p.expected_scope_count IS NULL OR p.expected_scope_count<=0
         THEN 1
         ELSE ABS(p.expected_scope_count-COUNT(DISTINCT m.required_gate_scope)) END
    +COUNT(DISTINCT CASE
                    WHEN COALESCE(m.scope_mapping_status,
                                  'MISSING_SCOPE_MAPPING_STATUS')<>'PASS'
                         THEN m.required_gate_scope END)
    +SUM(CASE WHEN m.required_gate_scope IS NOT NULL AND c.gate_name IS NULL
              THEN 1 ELSE 0 END)
    AS BIGINT)                                       AS missing_scope_or_gate_count,
  CAST(
    CASE WHEN p.expected_scope_count IS NULL OR p.expected_scope_count<=0
         THEN 1
         ELSE ABS(p.expected_scope_count-COUNT(DISTINCT m.required_gate_scope)) END
    +COUNT(DISTINCT CASE
                    WHEN COALESCE(m.scope_mapping_status,
                                  'MISSING_SCOPE_MAPPING_STATUS')<>'PASS'
                         THEN m.required_gate_scope END)
    +SUM(CASE WHEN m.required_gate_scope IS NOT NULL
                   AND (c.gate_name IS NULL
                        OR COALESCE(c.effective_gate_status,'FAIL')='FAIL')
              THEN 1 ELSE 0 END)
    AS BIGINT)                                       AS failed_gate_count,
  SUM(CASE WHEN COALESCE(c.effective_gate_status,'FAIL')='WARN'
           THEN 1 ELSE 0 END)
                                                       AS warning_gate_count,
  CASE
    WHEN p.expected_scope_count IS NULL OR p.expected_scope_count<=0
      OR p.expected_scope_count<>COUNT(DISTINCT m.required_gate_scope)
      OR COUNT(DISTINCT CASE
                        WHEN COALESCE(m.scope_mapping_status,
                                      'MISSING_SCOPE_MAPPING_STATUS')<>'PASS'
                             THEN m.required_gate_scope END)>0
      OR SUM(CASE WHEN m.required_gate_scope IS NOT NULL
                       AND (c.gate_name IS NULL
                            OR COALESCE(c.effective_gate_status,'FAIL')='FAIL')
                  THEN 1 ELSE 0 END)>0 THEN 'BLOCKED'
    WHEN SUM(CASE WHEN COALESCE(c.effective_gate_status,'FAIL')='WARN'
                  THEN 1 ELSE 0 END)>0
      THEN 'ELIGIBLE_WITH_EXPLICIT_WARNINGS'
    ELSE 'ELIGIBLE_FOR_CONTROLLED_PUBLICATION'
  END                                                AS product_release_status
FROM ic_v3_product_catalog p
LEFT JOIN ic_v3_product_scope_control m
  ON m.product_name=p.product_name
LEFT JOIN ic_v3_release_gate_manifest_control c
  ON c.gate_scope=m.required_gate_scope
GROUP BY p.product_name, p.expected_scope_count;

-- Default final result: the controls, not a misleading top-25 OOB list.
-- Read ic_v3_product_release_status first. Query ic_v3_pair_currency_summary
-- only when the requested product is eligible; use
-- ic_v3_management_allocation_detail for controlled BU/OU drill-down.
SELECT
  product_name, expected_scope_count, manifest_scope_count,
  duplicate_scope_mapping_count,
  required_gate_count, matched_gate_count,
  missing_scope_or_gate_count, failed_gate_count, warning_gate_count,
  product_release_status
FROM ic_v3_product_release_status
ORDER BY product_name;
