"""Offline confidence harness for SAP_IC_reconciliation_v3_sandbox.sql.

This script consumes no Databricks DBUs.  It performs:

1. Databricks-dialect parsing and static release checks on the delivered SQL.
2. Exact-DECIMAL fixture tests in DuckDB for the key business invariants.
3. Mutation checks proving that known legacy failure modes are detected.

It does not certify live catalog schemas or source control totals.  Those gates
must be run in Databricks using SAP_IC_v3_live_assertions.sql.
"""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
import hashlib
import random
import re
import sys
import traceback

try:
    import duckdb
    import sqlglot
except ImportError as exc:  # pragma: no cover - user-facing bootstrap path
    raise SystemExit(
        "Missing test dependency. Run: "
        f"{sys.executable} -m pip install -r SAP_IC_v3_test_requirements.txt"
    ) from exc


HERE = Path(__file__).resolve().parent
PIPELINE_SQL = HERE / "SAP_IC_reconciliation_v3_sandbox.sql"


@dataclass
class Result:
    name: str
    passed: bool
    detail: str = ""


RESULTS: list[Result] = []


def check(name: str):
    """Decorator that records one independent check and continues on failure."""

    def decorate(fn):
        def wrapped() -> None:
            try:
                fn()
            except Exception as exc:  # collect every failure in one run
                RESULTS.append(Result(name, False, f"{exc}\n{traceback.format_exc()}"))
            else:
                RESULTS.append(Result(name, True))

        wrapped.__name__ = fn.__name__
        return wrapped

    return decorate


def rows_as_dict(con, sql: str, key_index: int = 0) -> dict:
    rows = con.execute(sql).fetchall()
    return {row[key_index]: row[1:] for row in rows}


def extract_view(sql: str, view_name: str, next_view_name: str) -> str:
    start = sql.upper().index(f"CREATE OR REPLACE TEMP VIEW {view_name.upper()}")
    end = sql.upper().index(f"CREATE OR REPLACE TEMP VIEW {next_view_name.upper()}", start)
    return sql[start:end]


def known_hazards(sql: str) -> set[str]:
    """Return legacy anti-patterns that should be mutation-testable."""

    without_comments = re.sub(r"--[^\n]*", " ", sql)
    compact = " ".join(without_comments.upper().split())
    hazards: set[str] = set()
    patterns = {
        "runtime_clock": r"\bCURRENT_(?:DATE|TIMESTAMP)\s*\(?",
        "floating_money": r"\b(?:CAST\s*\([^)]*\s+AS\s+DOUBLE|DOUBLE\s*\(|FLOAT\s*\()",
        "notebook_magic": r"%SQL",
        "invalid_separator": r"\|\|\|\|\|\|",
        "arbitrary_top_n": r"\bLIMIT\s+\d+",
        "fi_beln_to_sd_vbeln": r"(?:BELNR|DOCUMENT_NUMBER)\s*=\s*[^ ]*V(?:BRP\.)?VBELN",
        "missing_fx_to_zero": r"COALESCE\s*\([^,]*(?:FX|REPORTING)[^,]*,\s*0\s*\)",
        "dominant_bu": r"ROW_NUMBER\s*\(\s*\)\s*OVER[^;]*(?:COUNT\s*\(\s*\*\s*\)|\bBU\b)",
        "grir_changes_oob": r"(?:ARAP_NET(?:_DC)?|PAIR_NET_OOB)\s*(?:\+|-)\s*(?:\w+\.)?GR_?IR",
    }
    for name, pattern in patterns.items():
        if re.search(pattern, compact, flags=re.IGNORECASE):
            hazards.add(name)
    return hazards


@check("01_databricks_parse_and_structure")
def test_databricks_parse_and_structure() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8")
    statements = sqlglot.parse(text, read="databricks")
    assert len(statements) >= 80, f"expected staged pipeline, parsed only {len(statements)} statements"
    assert not known_hazards(text), f"forbidden hazards found: {sorted(known_hazards(text))}"

    required_views = {
        "ic_v3_item_quarantine",
        "ic_v3_partner_evidence",
        "ic_v3_partner_resolution",
        "ic_v3_item_allocation",
        "ic_v3_allocation_control",
        "ic_v3_match_group",
        "ic_v3_match_membership",
        "ic_v3_pair_currency_summary",
        "ic_v3_partner_exception_summary",
        "ic_v3_diagnostic_partner_candidate_pair_summary",
        "ic_v3_source_family_coverage_control",
        "ic_v3_arap_population_control",
        "ic_v3_grir_fi_open_line",
        "ic_v3_grir_po_history_event",
        "ic_v3_grir_po_item_lifecycle",
        "ic_v3_grir_workqueue",
        "ic_v3_grir_fi_conservation_control",
        "ic_v3_grir_event_conservation_control",
        "ic_v3_arap_grir_pair_physical_control",
        "ic_v3_arap_grir_link",
        "ic_v3_release_gate",
        "ic_v3_expected_release_gate",
        "ic_v3_expected_release_gate_key_control",
        "ic_v3_release_gate_manifest_control",
        "ic_v3_product_catalog",
        "ic_v3_product_scope_manifest",
        "ic_v3_product_scope_control",
        "ic_v3_product_release_status",
    }
    upper = text.upper()
    missing = [name for name in sorted(required_views) if name.upper() not in upper]
    assert not missing, f"required views missing: {missing}"

    product_contract = {
        "('ARAP_TRANSACTION_CURRENCY_SANDBOX','ARAP')",
        "('ARAP_ENTERPRISE_PRODUCTION','PRODUCTION_READINESS')",
        "('ARAP_ENTERPRISE_PRODUCTION','MANUAL_GL')",
        "('MANAGEMENT_OWNER_SPLIT_DC_SANDBOX','MANAGEMENT')",
        "('MANAGEMENT_COUNTERPART_SPLIT_DC_SANDBOX','MANAGEMENT_COUNTERPART')",
        "('MANAGEMENT_SPLIT_LC_ENTERPRISE','MANAGEMENT_LC')",
        "('REPORTING_CURRENCY_ENTERPRISE','REPORTING_FX')",
        "('GRIR_FI_DIAGNOSTIC_SANDBOX','GRIR')",
        "('GRIR_PO_LIFECYCLE_DIAGNOSTIC_SANDBOX','GRIR_LIFECYCLE')",
        "('GRIR_AUTOMATION','GRIR_AUTOMATION')",
        "('GRIR_AUTOMATION','PRODUCTION_READINESS')",
    }
    compact_upper = re.sub(r"\s+", "", upper)
    missing_product_contract = sorted(
        pair for pair in product_contract if pair not in compact_upper
    )
    assert not missing_product_contract, (
        f"required product/scope mappings missing: {missing_product_contract}"
    )

    pair_sql = extract_view(text, "ic_v3_pair_currency_summary", "ic_v3_pair_reporting_summary")
    assert "GRIR" not in pair_sql.upper(), "official AR/AP pair net references GR/IR"
    assert "SIGNED_AMOUNT_DC" in pair_sql.upper(), "pair net is not transaction-currency based"

    item_sql = extract_view(text, "ic_v3_item_normalized", "ic_v3_item_preasof_quarantine")
    for token in (
        "SOURCE_SYSTEM_ID",
        "SOURCE_CLIENT",
        "COMPANY_CODE",
        "FISCAL_YEAR",
        "ACCOUNTING_DOCUMENT",
        "LINE_ITEM_NUMBER",
    ):
        assert token in item_sql.upper(), f"native identity missing {token}"


@check("02_source_identity_cross_system_and_client")
def test_source_identity_cross_system_and_client() -> None:
    con = duckdb.connect()
    con.execute(
        """
        CREATE TABLE source_rows(
          source_system VARCHAR, client VARCHAR, bukrs VARCHAR,
          gjahr VARCHAR, belnr VARCHAR, buzei VARCHAR
        );
        INSERT INTO source_rows VALUES
          ('ECC_A','010','US10','2026','900001','001'),
          ('ECC_A','020','US10','2026','900001','001'),
          ('ECC_B','010','US10','2026','900001','001'),
          ('ECC_B','020','US10','2026','900001','001');
        """
    )
    exact = con.execute(
        """
        SELECT COUNT(DISTINCT concat_ws('||',source_system,client,bukrs,gjahr,belnr,buzei))
        FROM source_rows
        """
    ).fetchone()[0]
    broken = con.execute(
        "SELECT COUNT(DISTINCT concat_ws('||',bukrs,gjahr,belnr,buzei)) FROM source_rows"
    ).fetchone()[0]
    assert exact == 4
    assert broken == 1, "mutation fixture did not expose cross-system/client collision"


@check("03_exclusive_cutoff_asof_boundaries")
def test_exclusive_cutoff_asof_boundaries() -> None:
    con = duckdb.connect()
    con.execute(
        """
        CREATE TABLE items(id VARCHAR, posting DATE, clearing DATE, clearing_status VARCHAR);
        INSERT INTO items VALUES
          ('posted_0831_open', DATE '2026-08-31', NULL, 'INITIAL'),
          ('posted_0901_open', DATE '2026-09-01', NULL, 'INITIAL'),
          ('cleared_at_cutoff', DATE '2026-08-20', DATE '2026-09-01', 'VALID'),
          ('cleared_before', DATE '2026-08-20', DATE '2026-08-31', 'VALID'),
          ('malformed_visible', DATE '2026-08-20', NULL, 'INVALID');
        """
    )
    selected = {
        r[0]
        for r in con.execute(
            """
            SELECT id FROM items
            WHERE posting < DATE '2026-09-01'
              AND (clearing_status='INITIAL' OR clearing>=DATE '2026-09-01'
                   OR clearing_status='INVALID')
            """
        ).fetchall()
    }
    assert selected == {"posted_0831_open", "cleared_at_cutoff", "malformed_visible"}


@check("04_partner_evidence_statuses_and_blank_population")
def test_partner_evidence_statuses_and_blank_population() -> None:
    con = duckdb.connect()
    con.execute(
        """
        CREATE TABLE items(item VARCHAR, owner VARCHAR, amount DECIMAL(18,2));
        INSERT INTO items VALUES
          ('posted','A',100), ('derived','A',200), ('diagnostic','A',300),
          ('conflict','A',400), ('ambiguous','A',500), ('unresolved','A',600),
          ('self','A',700);
        CREATE TABLE evidence(
          item VARCHAR, candidate VARCHAR, evidence_type VARCHAR,
          evidence_tier INTEGER, automation_eligible BOOLEAN
        );
        INSERT INTO evidence VALUES
          ('posted','B','POSTED_LINE',10,true),
          ('derived','B','BVORG',20,true),
          ('diagnostic','B','MASTER_CURRENT',40,false),
          ('conflict','B','POSTED_LINE',10,true),
          ('conflict','C','MASTER_CURRENT',40,false),
          ('ambiguous','B','SAME_DOCUMENT',30,true),
          ('ambiguous','C','SAME_DOCUMENT',30,true),
          ('self','A','POSTED_LINE',10,true);
        """
    )
    actual = rows_as_dict(
        con,
        """
        WITH stats AS (
          SELECT i.item, i.owner,
            COUNT(DISTINCT e.candidate) AS all_count,
            COUNT(DISTINCT CASE WHEN e.automation_eligible THEN e.candidate END) AS auto_count,
            COUNT(DISTINCT CASE WHEN e.evidence_type='POSTED_LINE' THEN e.candidate END) AS posted_count,
            MIN(CASE WHEN e.evidence_type='POSTED_LINE' THEN e.candidate END) AS posted_candidate,
            MIN(CASE WHEN e.automation_eligible THEN e.candidate END) AS auto_candidate
          FROM items i LEFT JOIN evidence e USING(item)
          GROUP BY i.item, i.owner
        )
        SELECT item,
          CASE
            WHEN all_count=0 THEN 'UNRESOLVED'
            WHEN posted_count=1 AND all_count>1 THEN 'CONFLICT'
            WHEN posted_count=1 AND posted_candidate=owner THEN 'CONFLICT_SELF'
            WHEN posted_count=1 THEN 'POSTED'
            WHEN auto_count>1 THEN 'AMBIGUOUS'
            WHEN auto_count=1 AND all_count=1 AND auto_candidate=owner THEN 'CONFLICT_SELF'
            WHEN auto_count=1 AND all_count=1 THEN 'DERIVED_UNIQUE'
            WHEN all_count=1 THEN 'DERIVED_UNIQUE_DIAGNOSTIC'
            ELSE 'AMBIGUOUS'
          END AS status
        FROM stats ORDER BY item
        """,
    )
    expected = {
        "posted": ("POSTED",),
        "derived": ("DERIVED_UNIQUE",),
        "diagnostic": ("DERIVED_UNIQUE_DIAGNOSTIC",),
        "conflict": ("CONFLICT",),
        "ambiguous": ("AMBIGUOUS",),
        "unresolved": ("UNRESOLVED",),
        "self": ("CONFLICT_SELF",),
    }
    assert actual == expected
    total = con.execute("SELECT SUM(abs(amount)) FROM items").fetchone()[0]
    assert total == Decimal("2800.00"), "blank-partner cases disappeared from the denominator"


@check("05_allocation_split_rounding_and_conservation")
def test_allocation_split_rounding_and_conservation() -> None:
    con = duckdb.connect()
    con.execute(
        """
        CREATE TABLE items(item VARCHAR, amount DECIMAL(18,2));
        INSERT INTO items VALUES ('split_40_60',100.00), ('thirds',100.00), ('negative',-100.00);
        CREATE TABLE signals(item VARCHAR, signal VARCHAR, basis DECIMAL(18,6));
        INSERT INTO signals VALUES
          ('split_40_60','A',40), ('split_40_60','B',60),
          ('thirds','A',1), ('thirds','B',1), ('thirds','C',1),
          ('negative','A',1), ('negative','B',2);
        """
    )
    rows = con.execute(
        """
        WITH base AS (
          SELECT i.item, i.amount, s.signal, s.basis,
            SUM(s.basis) OVER (PARTITION BY i.item) AS total_basis
          FROM items i JOIN signals s USING(item)
        ), preliminary AS (
          SELECT *, CAST(round(amount*basis/total_basis,2) AS DECIMAL(18,2)) AS preliminary
          FROM base
        ), fixed AS (
          SELECT item, signal,
            CAST(preliminary + CASE WHEN signal=MIN(signal) OVER (PARTITION BY item)
              THEN amount-SUM(preliminary) OVER (PARTITION BY item) ELSE 0 END
              AS DECIMAL(18,2)) AS allocated
          FROM preliminary
        )
        SELECT item, signal, allocated FROM fixed ORDER BY item, signal
        """
    ).fetchall()
    by_item: dict[str, list[Decimal]] = {}
    for item, _signal, amount in rows:
        by_item.setdefault(item, []).append(amount)
    assert by_item["split_40_60"] == [Decimal("40.00"), Decimal("60.00")]
    assert by_item["thirds"] == [Decimal("33.34"), Decimal("33.33"), Decimal("33.33")]
    assert sum(by_item["negative"]) == Decimal("-100.00")
    source = {r[0]: r[1] for r in con.execute("SELECT item,amount FROM items").fetchall()}
    assert all(sum(values) == source[item] for item, values in by_item.items())


@check("06_mapping_fanout_fails_closed")
def test_mapping_fanout_fails_closed() -> None:
    con = duckdb.connect()
    con.execute(
        """
        CREATE TABLE source(item VARCHAR, amount DECIMAL(18,2), company VARCHAR, pc VARCHAR);
        INSERT INTO source VALUES ('I1',100,'US10','P1');
        CREATE TABLE pc_map(company VARCHAR, pc VARCHAR, ou VARCHAR);
        INSERT INTO pc_map VALUES ('US10','P1','OU1'),('US10','P1','OU2');
        """
    )
    raw_sum = con.execute(
        "SELECT SUM(amount) FROM source JOIN pc_map USING(company,pc)"
    ).fetchone()[0]
    count = con.execute(
        "SELECT COUNT(DISTINCT ou) FROM pc_map WHERE company='US10' AND pc='P1'"
    ).fetchone()[0]
    assert raw_sum == Decimal("200.00"), "fanout mutation did not double the fixture"
    assert count == 2, "mapping ambiguity control failed to detect both targets"


@check("07_reference_matching_and_zero_net_unassigned_risk")
def test_reference_matching_and_zero_net_unassigned_risk() -> None:
    con = duckdb.connect()
    con.execute(
        """
        CREATE TABLE items(
          item VARCHAR, side VARCHAR, owner VARCHAR, partner VARCHAR,
          curr VARCHAR, ref VARCHAR, amount DECIMAL(18,2)
        );
        INSERT INTO items VALUES
          ('x_ar','AR','A','B','USD','X',100),
          ('x_ap','AP','B','A','USD','X',-100),
          ('m_ar1','AR','A','B','USD','M',60),
          ('m_ar2','AR','A','B','USD','M',40),
          ('m_ap','AP','B','A','USD','M',-100),
          ('u_ar','AR','A','B','USD','U1',250),
          ('u_ap','AP','B','A','USD','U2',-250),
          ('eur_distractor','AP','B','A','EUR','X',-100);
        """
    )
    groups = rows_as_dict(
        con,
        """
        WITH g AS (
          SELECT least(owner,partner) lo, greatest(owner,partner) hi, curr, ref,
            COUNT(*) n,
            SUM(CASE WHEN side='AR' THEN 1 ELSE 0 END) ar_n,
            SUM(CASE WHEN side='AP' THEN 1 ELSE 0 END) ap_n,
            SUM(amount) residual,
            COUNT(DISTINCT CASE WHEN side='AR' THEN owner||'>'||partner END) ar_dir,
            COUNT(DISTINCT CASE WHEN side='AP' THEN owner||'>'||partner END) ap_dir
          FROM items GROUP BY lo,hi,curr,ref
        )
        SELECT ref||'|'||curr,
          CASE
            WHEN ar_n=0 OR ap_n=0 THEN 'ONE_SIDED'
            WHEN ar_dir<>1 OR ap_dir<>1 THEN 'AMBIGUOUS_DIRECTION'
            WHEN residual=0 AND ar_n=1 AND ap_n=1 THEN 'CONFIRMED_1_TO_1'
            WHEN residual=0 THEN 'SUGGESTED_M_TO_N_EXACT'
            ELSE 'SUGGESTED_RESIDUAL'
          END
        FROM g ORDER BY 1
        """,
    )
    assert groups["X|USD"] == ("CONFIRMED_1_TO_1",)
    assert groups["M|USD"] == ("SUGGESTED_M_TO_N_EXACT",)
    assert groups["U1|USD"] == ("ONE_SIDED",)
    assert groups["U2|USD"] == ("ONE_SIDED",)
    assert groups["X|EUR"] == ("ONE_SIDED",)

    net, gross = con.execute(
        "SELECT SUM(amount),SUM(abs(amount)) FROM items WHERE item IN ('u_ar','u_ap')"
    ).fetchone()
    assert net == Decimal("0.00") and gross == Decimal("500.00")
    assert groups["U1|USD"][0] != "CONFIRMED_1_TO_1"

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    membership_control = extract_view(
        text, "ic_v3_match_membership_control", "ic_v3_fx_rate_normalized"
    )
    pair_summary = extract_view(
        text, "ic_v3_pair_currency_summary", "ic_v3_pair_reporting_summary"
    )
    assert "INVALID_MATCH_STATUS_COUNT" in membership_control
    assert "INVALID_MATCH_RULE_COUNT" in membership_control
    assert "FAIL_MATCH_STATUS_DOMAIN" in membership_control
    assert "FAIL_MATCH_RULE_LINEAGE" in membership_control
    assert "MISSING_MATCH_STATUS" in membership_control
    assert re.sub(r"\s+", "", membership_control).count(
        "NULLIF(TRIM(M.MATCH_GROUP_ID),'')ISNULL"
    ) >= 4
    assert pair_summary.count("COALESCE(M.MATCH_STATUS,'MISSING_MATCH_STATUS')") >= 2

    null_status_control = con.execute(
        """
        WITH m(source_item_id,match_status) AS (
          VALUES ('I1',NULL::VARCHAR)
        )
        SELECT CASE
          WHEN COUNT(source_item_id)<>1 THEN 'FAIL_MEMBERSHIP_CARDINALITY'
          WHEN SUM(CASE WHEN COALESCE(match_status,'MISSING_MATCH_STATUS')
                                  NOT IN ('UNMATCHED','VALID_STATUS')
                        THEN 1 ELSE 0 END)>0
            THEN 'FAIL_MATCH_STATUS_DOMAIN'
          ELSE 'PASS' END
        FROM m
        """
    ).fetchone()[0]
    assert null_status_control == "FAIL_MATCH_STATUS_DOMAIN"


@check("08_fx_priority_overlap_and_missing")
def test_fx_priority_overlap_and_missing() -> None:
    con = duckdb.connect()
    con.execute(
        """
        CREATE TABLE items(item VARCHAR, curr VARCHAR, posting DATE);
        INSERT INTO items VALUES
          ('native','USD',DATE '2026-08-15'),
          ('cpm','EUR',DATE '2026-08-15'),
          ('fallback','EUR',DATE '2026-07-15'),
          ('ambiguous','JPY',DATE '2026-08-15'),
          ('missing','GBP',DATE '2026-08-15');
        CREATE TABLE rates(
          rate_id VARCHAR, from_curr VARCHAR, rate_type VARCHAR,
          priority INTEGER, valid_from DATE, valid_to DATE, multiplier DECIMAL(18,8)
        );
        INSERT INTO rates VALUES
          ('eur_cpm','EUR','CPM',10,DATE '2026-08-01',DATE '2026-08-31',1.10),
          ('eur_1001_jul','EUR','1001',20,DATE '2026-07-01',DATE '2026-07-31',1.08),
          ('eur_1001_aug','EUR','1001',20,DATE '2026-08-01',DATE '2026-08-31',1.09),
          ('jpy_a','JPY','CPM',10,DATE '2026-08-01',DATE '2026-08-31',0.0068),
          ('jpy_b','JPY','CPM',10,DATE '2026-08-10',DATE '2026-08-20',0.0069);
        """
    )
    status = rows_as_dict(
        con,
        """
        WITH candidates AS (
          SELECT i.item,r.rate_id,r.priority,r.multiplier
          FROM items i JOIN rates r
            ON r.from_curr=i.curr AND i.posting BETWEEN r.valid_from AND r.valid_to
          WHERE i.curr<>'USD'
        ), prio AS (
          SELECT item,MIN(priority) p FROM candidates GROUP BY item
        ), stats AS (
          SELECT i.item,i.curr,p.p,
            COUNT(DISTINCT CASE WHEN c.priority=p.p THEN c.rate_id END) rate_rows,
            COUNT(DISTINCT CASE WHEN c.priority=p.p THEN c.multiplier END) rate_values
          FROM items i LEFT JOIN prio p USING(item) LEFT JOIN candidates c USING(item)
          GROUP BY i.item,i.curr,p.p
        )
        SELECT item,
          CASE WHEN curr='USD' THEN 'NATIVE'
               WHEN rate_rows=0 THEN 'MISSING'
               WHEN rate_rows>1 OR rate_values>1 THEN 'AMBIGUOUS'
               ELSE 'RESOLVED' END
        FROM stats ORDER BY item
        """,
    )
    assert status == {
        "ambiguous": ("AMBIGUOUS",),
        "cpm": ("RESOLVED",),
        "fallback": ("RESOLVED",),
        "missing": ("MISSING",),
        "native": ("NATIVE",),
    }

    # A release gate must not let SQL three-valued logic turn NULL status into
    # an apparent zero-exception pass.
    gate_status, violating_rows, violating_gross = con.execute(
        """
        WITH item_fx(fx_status,signed_amount_dc) AS (
          VALUES (NULL::VARCHAR,123.45::DECIMAL(18,2))
        )
        SELECT
          CASE WHEN SUM(CASE
                 WHEN COALESCE(fx_status,'MISSING_FX_STATUS')
                        NOT IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
                 THEN 1 ELSE 0 END)=0 THEN 'PASS' ELSE 'FAIL' END,
          SUM(CASE WHEN COALESCE(fx_status,'MISSING_FX_STATUS')
                          NOT IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
                   THEN 1 ELSE 0 END),
          SUM(CASE WHEN COALESCE(fx_status,'MISSING_FX_STATUS')
                          NOT IN ('NATIVE_REPORTING_CURRENCY','RESOLVED')
                   THEN ABS(signed_amount_dc) ELSE 0 END)
        FROM item_fx
        """
    ).fetchone()
    assert (gate_status, violating_rows, violating_gross) == (
        "FAIL",
        1,
        Decimal("123.45"),
    )

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    release = extract_view(text, "ic_v3_release_gate", "ic_v3_expected_release_gate")
    fx_gate = release[
        release.index("'REPORTING_FX','FX_COMPLETE_AND_APPROVED'") :
        release.index("'MANUAL_GL','MANUAL_GL_POSITION_SEMANTICS_APPROVED'")
    ]
    assert fx_gate.count("COALESCE(FX_STATUS,'MISSING_FX_STATUS')") == 3


@check("09_grir_lifecycle_is_a_sidecar")
def test_grir_lifecycle_is_a_sidecar() -> None:
    con = duckdb.connect()
    con.execute(
        """
        CREATE TABLE po_open(po VARCHAR, open_lc DECIMAL(18,2));
        INSERT INTO po_open VALUES ('GR_ONLY',-100),('IR_ONLY',75),('BOTH',-40),('NO_HISTORY',20),('OTHER',10);
        CREATE TABLE events(po VARCHAR, family VARCHAR);
        INSERT INTO events VALUES
          ('GR_ONLY','GR'),('IR_ONLY','IR'),('BOTH','GR'),('BOTH','IR'),('OTHER','OTHER');
        """
    )
    status = rows_as_dict(
        con,
        """
        WITH e AS (
          SELECT p.po,p.open_lc,
            COUNT(ev.family) n,
            SUM(CASE WHEN ev.family='GR' THEN 1 ELSE 0 END) gr_n,
            SUM(CASE WHEN ev.family='IR' THEN 1 ELSE 0 END) ir_n,
            SUM(CASE WHEN ev.family='OTHER' THEN 1 ELSE 0 END) other_n
          FROM po_open p LEFT JOIN events ev USING(po) GROUP BY p.po,p.open_lc
        )
        SELECT po,
          CASE WHEN n=0 THEN 'PO_HISTORY_MISSING'
               WHEN gr_n>0 AND ir_n=0 THEN 'GR_EVENT_SEEN_IR_NOT_SEEN'
               WHEN ir_n>0 AND gr_n=0 THEN 'IR_EVENT_SEEN_GR_NOT_SEEN'
               WHEN gr_n>0 AND ir_n>0 AND abs(open_lc)>0.01 THEN 'BOTH_EVENTS_WITH_OPEN_FI_RESIDUAL'
               WHEN other_n>0 THEN 'OTHER_OR_UNMAPPED_EVENT_ONLY'
               ELSE 'OTHER_OPEN_GRIR' END
        FROM e ORDER BY po
        """,
    )
    assert status["GR_ONLY"] == ("GR_EVENT_SEEN_IR_NOT_SEEN",)
    assert status["IR_ONLY"] == ("IR_EVENT_SEEN_GR_NOT_SEEN",)
    assert status["BOTH"] == ("BOTH_EVENTS_WITH_OPEN_FI_RESIDUAL",)
    assert status["NO_HISTORY"] == ("PO_HISTORY_MISSING",)
    assert status["OTHER"] == ("OTHER_OR_UNMAPPED_EVENT_ONLY",)

    arap_net = Decimal("100.00") + Decimal("-70.00")
    grir_diagnostic = Decimal("-30.00")
    assert arap_net == Decimal("30.00")
    assert arap_net + grir_diagnostic == Decimal("0.00")
    assert arap_net != arap_net + grir_diagnostic, "fixture must prove GR/IR can mask OOB"


@check("10_grir_overlap_never_becomes_supported_amount")
def test_grir_overlap_never_becomes_supported_amount() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    link_sql = extract_view(
        text, "ic_v3_arap_grir_link", "ic_v3_parameter_control"
    )
    assert "CAST(NULL AS DECIMAL(38,6))" in link_sql
    assert "AS SUPPORTED_AMOUNT_DC" in link_sql
    assert "BLOCKED_CONTRACT_INCOMPLETE" in link_sql
    assert "SIGN_DIRECTION_COMPATIBLE_WITH_GR_NOT_IR_HYPOTHESIS" in link_sql
    assert "TIMING_SUPPORTED_BY_GRIR" not in text

    cases = [
        (Decimal("100"), Decimal("-30"), 1, 1, "GR_ONLY", Decimal("30")),
        (Decimal("25"), Decimal("-70"), 1, 1, "GR_ONLY", Decimal("25")),
        (Decimal("100"), Decimal("-30"), 2, 1, "GR_ONLY", None),
        (Decimal("100"), Decimal("-30"), 1, 1, "IR_ONLY", None),
        (Decimal("-50"), Decimal("-80"), 1, 1, "GR_ONLY", None),
        (Decimal("100"), Decimal("80"), 1, 1, "GR_ONLY", None),
    ]
    for arap, grir, arap_candidates, grir_candidates, lifecycle, expected in cases:
        diagnostic_overlap = (
            min(abs(arap), abs(grir))
            if arap_candidates == 1
            and grir_candidates == 1
            and lifecycle == "GR_ONLY"
            and arap > 0
            and grir < 0
            else None
        )
        supported = None
        assert diagnostic_overlap == expected
        if diagnostic_overlap is not None:
            assert diagnostic_overlap <= abs(arap) and diagnostic_overlap <= abs(grir)
        assert supported is None


@check("11_input_order_invariance")
def test_input_order_invariance() -> None:
    records = [
        ("S1", "010", "A", "2026", "1", "001", Decimal("100.00")),
        ("S1", "010", "B", "2026", "2", "001", Decimal("-40.00")),
        ("S2", "020", "A", "2026", "1", "001", Decimal("-60.00")),
    ]

    def digest(values) -> str:
        payload = "\n".join("|".join(map(str, r)) for r in sorted(values))
        return hashlib.sha256(payload.encode()).hexdigest()

    expected = digest(records)
    for seed in range(25):
        shuffled = list(records)
        random.Random(seed).shuffle(shuffled)
        assert digest(shuffled) == expected


@check("12_mutants_are_detected")
def test_mutants_are_detected() -> None:
    mutants = {
        "runtime_clock": "SELECT current_date()",
        "floating_money": "SELECT CAST(amount AS DOUBLE)",
        "notebook_magic": "%sql SELECT 1",
        "invalid_separator": "SELECT 1; |||||| SELECT 2",
        "arbitrary_top_n": "SELECT * FROM oob ORDER BY amount LIMIT 25",
        "fi_beln_to_sd_vbeln": "JOIN vbrp ON ar.BELNR = vbrp.VBELN",
        "missing_fx_to_zero": "SELECT COALESCE(amount_reporting, 0) FROM x",
        "dominant_bu": "SELECT ROW_NUMBER() OVER (PARTITION BY company ORDER BY COUNT(*) DESC, BU) FROM x",
        "grir_changes_oob": "SELECT arap_net + gr_ir AS net_oob FROM x",
    }
    for expected_hazard, sql in mutants.items():
        detected = known_hazards(sql)
        assert expected_hazard in detected, (expected_hazard, detected, sql)


@check("13_one_sided_source_extract_is_blocked")
def test_one_sided_source_extract_is_blocked() -> None:
    con = duckdb.connect()
    rows = con.execute(
        """
        WITH expected(source_family,match_side) AS (
          VALUES ('AR_SUBLEDGER','AR'),('AP_SUBLEDGER','AP')
        ), physical(source_family,match_side) AS (
          VALUES ('AR_SUBLEDGER','AR')
        )
        SELECT e.source_family,
               CASE WHEN COUNT(p.source_family)>0 THEN 'PRESENT'
                    ELSE 'ABSENT_OR_UNPROVEN_ZERO' END AS status
        FROM expected e LEFT JOIN physical p USING(source_family,match_side)
        GROUP BY e.source_family ORDER BY e.source_family
        """
    ).fetchall()
    assert rows == [
        ("AP_SUBLEDGER", "ABSENT_OR_UNPROVEN_ZERO"),
        ("AR_SUBLEDGER", "PRESENT"),
    ]


@check("14_missing_release_gate_blocks_product")
def test_missing_release_gate_blocks_product() -> None:
    con = duckdb.connect()
    status = con.execute(
        """
        WITH expected(scope,gate) AS (
          VALUES ('ARAP','KEY_UNIQUE'),('ARAP','POPULATION_CONSERVES')
        ), actual(scope,gate,status) AS (
          VALUES ('ARAP','KEY_UNIQUE','PASS')
        ), manifest AS (
          SELECT e.scope,e.gate,a.status,
                 CASE WHEN a.gate IS NULL THEN 'FAIL' ELSE a.status END effective_status
          FROM expected e LEFT JOIN actual a USING(scope,gate)
        )
        SELECT CASE WHEN SUM(CASE WHEN effective_status='FAIL' THEN 1 ELSE 0 END)>0
                    THEN 'BLOCKED' ELSE 'ELIGIBLE' END
        FROM manifest
        """
    ).fetchone()[0]
    assert status == "BLOCKED"

    # Final publication boundaries must treat missing status/count metadata as
    # failure, even if a future adapter violates today's non-null producers.
    null_status = con.execute(
        """
        WITH x(effective_gate_status,manifest_status) AS (
          VALUES (NULL::VARCHAR,NULL::VARCHAR)
        )
        SELECT CASE
          WHEN SUM(CASE WHEN COALESCE(effective_gate_status,'FAIL')='FAIL'
                        THEN 1 ELSE 0 END)>0 THEN 'BLOCKED'
          WHEN SUM(CASE WHEN COALESCE(effective_gate_status,'FAIL')='WARN'
                        THEN 1 ELSE 0 END)>0 THEN 'WARN'
          ELSE 'ELIGIBLE' END,
          SUM(CASE WHEN COALESCE(manifest_status,'MISSING_MANIFEST_STATUS')<>
                            'EXPECTED_GATE_PRESENT' THEN 1 ELSE 0 END)
        FROM x
        """
    ).fetchone()
    assert null_status == ("BLOCKED", 1)

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    manifest_control = extract_view(
        text, "ic_v3_release_gate_manifest_control", "ic_v3_release_status"
    )
    release_status = extract_view(
        text, "ic_v3_release_status", "ic_v3_product_catalog"
    )
    product_status = text[
        text.index("CREATE OR REPLACE TEMP VIEW IC_V3_PRODUCT_RELEASE_STATUS") :
    ]
    for token in (
        "FAIL_EXPECTED_GATE_KEY_STATUS_MISSING",
        "FAIL_ACTUAL_GATE_KEY_STATUS_MISSING",
        "COALESCE(A.ACTUAL_GATE_STATUS,'FAIL')",
    ):
        assert token in re.sub(r"\s+", "", manifest_control)
    assert "COALESCE(EFFECTIVE_GATE_STATUS,'FAIL')" in release_status
    assert "MISSING_MANIFEST_STATUS" in release_status
    assert "P.EXPECTED_SCOPE_COUNTISNULLORP.EXPECTED_SCOPE_COUNT<=0" in re.sub(
        r"\s+", "", product_status
    )
    assert "MISSING_SCOPE_MAPPING_STATUS" in product_status
    assert "COALESCE(C.EFFECTIVE_GATE_STATUS,'FAIL')" in product_status


@check("15_lifecycle_conflict_checked_before_open_filter")
def test_lifecycle_conflict_checked_before_open_filter() -> None:
    con = duckdb.connect()
    correct, unsafe = con.execute(
        """
        WITH copies(item_id,physical_source,clearing_date,payload) AS (
          VALUES
            ('I1','BSID',CAST(NULL AS DATE),'OPEN_COPY'),
            ('I1','BSAD',DATE '2026-08-15','CLEARED_COPY')
        ), correct_control AS (
          SELECT COUNT(*) n,COUNT(DISTINCT payload) payloads FROM copies
        ), unsafe_early_filter AS (
          SELECT COUNT(*) n
          FROM copies
          WHERE clearing_date IS NULL OR clearing_date>=DATE '2026-09-01'
        )
        SELECT c.payloads,u.n FROM correct_control c CROSS JOIN unsafe_early_filter u
        """
    ).fetchone()
    assert correct == 2, "complete lifecycle population must expose the conflict"
    assert unsafe == 1, "fixture must demonstrate how an early open filter hides it"


@check("16_grir_missing_po_lineage_blocks_lifecycle")
def test_grir_missing_po_lineage_blocks_lifecycle() -> None:
    con = duckdb.connect()
    status, exceptions = con.execute(
        """
        WITH open_grir(line_id,po,po_item,amount) AS (
          VALUES ('G1',CAST(NULL AS VARCHAR),CAST(NULL AS VARCHAR),100.00::DECIMAL(18,2))
        ), lineage_exception AS (
          SELECT * FROM open_grir WHERE po IS NULL OR po_item IS NULL
        )
        SELECT CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END,COUNT(*)
        FROM lineage_exception
        """
    ).fetchone()
    assert (status, exceptions) == ("FAIL", 1)


@check("17_offset_split_requires_single_subledger_target")
def test_offset_split_requires_single_subledger_target() -> None:
    con = duckdb.connect()
    rows = con.execute(
        """
        WITH lines(doc,line,koart,amount) AS (
          VALUES
            ('SAFE','001','D',100.00),('SAFE','002','S',-40.00),('SAFE','003','S',-60.00),
            ('UNSAFE','001','D',100.00),('UNSAFE','002','K',-20.00),
            ('UNSAFE','003','S',-40.00),('UNSAFE','004','S',-40.00),
            ('UNSUPPORTED','001','D',100.00),('UNSUPPORTED','002','A',-20.00),
            ('UNSUPPORTED','003','S',-80.00)
        )
        SELECT doc,
          CASE WHEN SUM(CASE WHEN koart IN ('D','K') THEN 1 ELSE 0 END)=1
                    AND SUM(CASE WHEN koart NOT IN ('D','K','S') THEN 1 ELSE 0 END)=0
               THEN 'SINGLE_SUBLEDGER_TARGET'
               WHEN SUM(CASE WHEN koart NOT IN ('D','K','S') THEN 1 ELSE 0 END)>0
               THEN 'UNSUPPORTED_NON_GL_OFFSET_LINE_PRESENT'
               ELSE 'MULTIPLE_OR_MISSING_SUBLEDGER_LINES' END status
        FROM lines GROUP BY doc ORDER BY doc
        """
    ).fetchall()
    assert rows == [
        ("SAFE", "SINGLE_SUBLEDGER_TARGET"),
        ("UNSAFE", "MULTIPLE_OR_MISSING_SUBLEDGER_LINES"),
        ("UNSUPPORTED", "UNSUPPORTED_NON_GL_OFFSET_LINE_PRESENT"),
    ]

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    offset = extract_view(text, "ic_v3_offset_control", "ic_v3_offset_by_profit_center")
    seed = extract_view(text, "ic_v3_allocation_seed", "ic_v3_item_allocation")
    assert "SOURCE_ITEM_AMOUNT_MISSING_OR_INVALID" in offset
    assert "DOCUMENT_STRUCTURE_STATUS_MISSING" in offset
    assert "UNALLOCATED_SOURCE_ITEM_AMOUNT_MISSING_OR_INVALID" in seed
    assert seed.count("NOT COALESCE(") >= 2


@check("18_currency_values_are_canonicalized")
def test_currency_values_are_canonicalized() -> None:
    con = duckdb.connect()
    con.execute(
        """
        CREATE TABLE items(side VARCHAR,currency VARCHAR,amount DECIMAL(18,2));
        INSERT INTO items VALUES
          ('AR','USD',100.00),('AP','usd ',-100.00);
        """
    )
    raw_groups = con.execute(
        "SELECT COUNT(DISTINCT currency) FROM items"
    ).fetchone()[0]
    normalized_groups, normalized_net = con.execute(
        """
        SELECT COUNT(*),SUM(net)
        FROM (
          SELECT upper(trim(currency)) currency,SUM(amount) net
          FROM items GROUP BY upper(trim(currency))
        )
        """
    ).fetchone()
    assert raw_groups == 2, "fixture must reproduce whitespace/case fragmentation"
    assert normalized_groups == 1 and normalized_net == Decimal("0.00")

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    item_sql = extract_view(text, "ic_v3_item_physical", "ic_v3_item_native_key_quarantine")
    header_sql = extract_view(text, "ic_v3_grir_header_raw", "ic_v3_grir_header_control")
    event_sql = extract_view(
        text, "ic_v3_grir_po_history_event_physical", "ic_v3_grir_event_key_control"
    )
    for label, sql in (("AR/AP", item_sql), ("GR/IR FI", header_sql), ("EKBE", event_sql)):
        assert "UPPER(TRIM(CAST(" in sql and "WAERS AS STRING" in sql, (
            f"{label} currency is not canonicalized at ingestion"
        )


@check("19_exact_bseg_line_checks_account_type_and_amount")
def test_exact_bseg_line_checks_account_type_and_amount() -> None:
    con = duckdb.connect()
    rows = con.execute(
        """
        WITH expected(id,side,hkont,shkzg,amount_dc,amount_lc) AS (
          VALUES
            ('ok','AR','1000','S',100.00::DECIMAL(18,2),90.00::DECIMAL(18,2)),
            ('wrong_account','AR','1000','S',100.00::DECIMAL(18,2),90.00::DECIMAL(18,2)),
            ('wrong_type','AP','2000','H',-50.00::DECIMAL(18,2),-45.00::DECIMAL(18,2)),
            ('wrong_amount','AP','2000','H',-50.00::DECIMAL(18,2),-45.00::DECIMAL(18,2)),
            ('zero_wrong_sign','AR','1000','S',0.00::DECIMAL(18,2),0.00::DECIMAL(18,2))
        ), bseg(id,hkont,koart,shkzg,amount_dc,amount_lc) AS (
          VALUES
            ('ok','1000','D','S',100.00::DECIMAL(18,2),90.00::DECIMAL(18,2)),
            ('wrong_account','9999','D','S',100.00::DECIMAL(18,2),90.00::DECIMAL(18,2)),
            ('wrong_type','2000','D','H',-50.00::DECIMAL(18,2),-45.00::DECIMAL(18,2)),
            ('wrong_amount','2000','K','H',-49.00::DECIMAL(18,2),-45.00::DECIMAL(18,2)),
            ('zero_wrong_sign','1000','D','H',0.00::DECIMAL(18,2),0.00::DECIMAL(18,2))
        )
        SELECT e.id,
          CASE
            WHEN b.hkont=e.hkont
             AND ((e.side='AR' AND b.koart='D') OR (e.side='AP' AND b.koart='K'))
             AND b.shkzg=e.shkzg
             AND b.amount_dc=e.amount_dc AND b.amount_lc=e.amount_lc
              THEN 'BSEG_LINE_RESOLVED'
            WHEN b.hkont<>e.hkont
              OR (e.side='AR' AND b.koart<>'D')
              OR (e.side='AP' AND b.koart<>'K')
              OR b.shkzg<>e.shkzg OR b.shkzg IS NULL
              THEN 'BSEG_LINE_ACCOUNT_OR_TYPE_MISMATCH'
            ELSE 'BSEG_LINE_AMOUNT_OR_SIGN_MISMATCH'
          END status
        FROM expected e JOIN bseg b USING(id) ORDER BY e.id
        """
    ).fetchall()
    assert rows == [
        ("ok", "BSEG_LINE_RESOLVED"),
        ("wrong_account", "BSEG_LINE_ACCOUNT_OR_TYPE_MISMATCH"),
        ("wrong_amount", "BSEG_LINE_AMOUNT_OR_SIGN_MISMATCH"),
        ("wrong_type", "BSEG_LINE_ACCOUNT_OR_TYPE_MISMATCH"),
        ("zero_wrong_sign", "BSEG_LINE_ACCOUNT_OR_TYPE_MISMATCH"),
    ]

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    control = extract_view(
        text, "ic_v3_item_bseg_line_control", "ic_v3_item_po_evidence"
    )
    for token in (
        "BSEG_GL_ACCOUNT",
        "ACCOUNT_TYPE",
        "BSEG_DEBIT_CREDIT_CODE",
        "SIGNED_AMOUNT_DC",
        "SIGNED_AMOUNT_LC",
    ):
        assert token in control, f"exact BSEG control omits {token}"
    allocation_seed = extract_view(
        text, "ic_v3_allocation_seed", "ic_v3_item_allocation"
    )
    assert (
        "WHEREB.BSEG_LINE_STATUS='BSEG_LINE_RESOLVED'"
        "ANDCOALESCE(B.PROFIT_CENTER_COUNT,0)=0"
        in re.sub(r"\s+", "", allocation_seed)
    ), "offset allocation can bypass exact BSEG identity validation"


@check("20_negative_raw_fi_amounts_fail_closed")
def test_negative_raw_fi_amounts_fail_closed() -> None:
    con = duckdb.connect()
    rows = con.execute(
        """
        WITH source(id,raw_dc,raw_lc,shkzg) AS (
          VALUES
            ('debit',100.00::DECIMAL(18,2),90.00::DECIMAL(18,2),'S'),
            ('credit',100.00::DECIMAL(18,2),90.00::DECIMAL(18,2),'H'),
            ('negative_dc',-100.00::DECIMAL(18,2),90.00::DECIMAL(18,2),'S'),
            ('negative_lc',100.00::DECIMAL(18,2),-90.00::DECIMAL(18,2),'H'),
            ('invalid_sign',100.00::DECIMAL(18,2),90.00::DECIMAL(18,2),'X'),
            ('null_sign',100.00::DECIMAL(18,2),90.00::DECIMAL(18,2),NULL),
            ('null_amount',NULL::DECIMAL(18,2),90.00::DECIMAL(18,2),'S')
        )
        SELECT id,
          CASE WHEN raw_dc IS NULL OR raw_lc IS NULL THEN 'MISSING_OR_INVALID_RAW_AMOUNT'
               WHEN raw_dc<0 OR raw_lc<0 THEN 'NEGATIVE_RAW_AMOUNT'
               WHEN shkzg NOT IN ('S','H') OR shkzg IS NULL
                 THEN 'INVALID_DEBIT_CREDIT_CODE'
               ELSE 'NONNEGATIVE_RAW_AMOUNT' END status,
          CASE WHEN raw_dc>=0 AND shkzg='S' THEN raw_dc
               WHEN raw_dc>=0 AND shkzg='H' THEN -raw_dc END signed_dc
        FROM source ORDER BY id
        """
    ).fetchall()
    by_id = {row[0]: row[1:] for row in rows}
    assert by_id["debit"] == ("NONNEGATIVE_RAW_AMOUNT", Decimal("100.00"))
    assert by_id["credit"] == ("NONNEGATIVE_RAW_AMOUNT", Decimal("-100.00"))
    assert by_id["negative_dc"] == ("NEGATIVE_RAW_AMOUNT", None)
    assert by_id["negative_lc"][0] == "NEGATIVE_RAW_AMOUNT"
    assert by_id["invalid_sign"] == ("INVALID_DEBIT_CREDIT_CODE", None)
    assert by_id["null_sign"] == ("INVALID_DEBIT_CREDIT_CODE", None)
    assert by_id["null_amount"] == ("MISSING_OR_INVALID_RAW_AMOUNT", None)

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    assert text.count("NEGATIVE_RAW_AMOUNT") >= 3, (
        "raw-sign checks must cover AR/AP, GR/IR FI and offset allocation"
    )
    assert "ABS(COALESCE(SIGNED_AMOUNT_DC,RAW_AMOUNT_DC))" in re.sub(r"\s+", "", text)
    data_quality = extract_view(
        text, "ic_v3_item_data_quality_exception", "ic_v3_item_source_lifecycle_exception"
    )
    population = extract_view(
        text, "ic_v3_item_population_bucket", "ic_v3_population_bridge"
    )
    release = extract_view(text, "ic_v3_release_gate", "ic_v3_expected_release_gate")
    assert "MISSING_RAW_AMOUNT_STATUS" in data_quality
    assert "MISSING_RAW_AMOUNT_STATUS" in population
    assert "HEADER_STATUS_MISSING" in population
    assert "OWNER_ENTITY_STATUS_MISSING" in population
    assert "COALESCE(PARTNER_MATCH_ELIGIBLE,FALSE)" in re.sub(r"\s+", "", population)
    assert "MISSING_CLEARING_DATE_STATUS" in release
    assert "ALLOCATION_CONTROL_STATUS_MISSING" in release
    assert "MEMBERSHIP_CONTROL_STATUS_MISSING" in release
    assert "MISSING_MATCH_GROUP_STATUS" in release


@check("21_grir_po_event_measures_flag_nonadditive_slices")
def test_grir_po_event_measures_flag_nonadditive_slices() -> None:
    con = duckdb.connect()
    canonical, repeated, slice_count, status = con.execute(
        """
        WITH fi_slices(po,item,account,currency) AS (
          VALUES ('4500001','10','20110000','USD'),
                 ('4500001','10','20110001','EUR')
        ), event_summary(po,item,event_count) AS (
          VALUES ('4500001','10',1)
        ), slice_control AS (
          SELECT po,item,COUNT(*) slice_count,
            CASE WHEN COUNT(*)=1 THEN 'ADDITIVE_AT_THIS_GRAIN'
                 ELSE 'PO_ITEM_EVENT_MEASURES_REPEATED_DO_NOT_SUM_ACROSS_SLICES' END status
          FROM fi_slices GROUP BY po,item
        ), lifecycle AS (
          SELECT f.*,e.event_count,s.slice_count,s.status
          FROM fi_slices f JOIN event_summary e USING(po,item)
          JOIN slice_control s USING(po,item)
        )
        SELECT (SELECT SUM(event_count) FROM event_summary),
               SUM(event_count),MIN(slice_count),MIN(status)
        FROM lifecycle
        """
    ).fetchone()
    assert canonical == 1 and repeated == 2 and slice_count == 2
    assert status == "PO_ITEM_EVENT_MEASURES_REPEATED_DO_NOT_SUM_ACROSS_SLICES"

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    assert "IC_V3_GRIR_PO_ITEM_SLICE_CONTROL" in text
    assert "EVENT_MEASURES_ADDITIVE_AT_LIFECYCLE_GRAIN" in text
    assert "EKBE_ZEKKN_ONLY_EKBE_MA_NOT_INGESTED" in text


@check("22_invalid_reference_groups_are_not_suggested_gross")
def test_invalid_reference_groups_are_not_suggested_gross() -> None:
    con = duckdb.connect()
    suggested, invalid, unmatched, total = con.execute(
        """
        WITH items(status,amount) AS (
          VALUES
            ('SUGGESTED_BVORG_LINKED_RESIDUAL',100.00::DECIMAL(18,2)),
            ('SUGGESTED_REFERENCE_M_TO_N_EXACT',-80.00::DECIMAL(18,2)),
            ('BVORG_ONE_SIDED',50.00::DECIMAL(18,2)),
            ('SUGGESTED_REFERENCE_NONRECIPROCAL',-40.00::DECIMAL(18,2)),
            ('UNMATCHED',30.00::DECIMAL(18,2))
        )
        SELECT
          SUM(CASE WHEN status IN ('SUGGESTED_BVORG_LINKED_RESIDUAL',
                                   'SUGGESTED_REFERENCE_M_TO_N_EXACT')
                   THEN abs(amount) ELSE 0 END),
          SUM(CASE WHEN status IN ('BVORG_ONE_SIDED',
                                   'SUGGESTED_REFERENCE_NONRECIPROCAL')
                   THEN abs(amount) ELSE 0 END),
          SUM(CASE WHEN status='UNMATCHED' THEN abs(amount) ELSE 0 END),
          SUM(abs(amount))
        FROM items
        """
    ).fetchone()
    assert (suggested, invalid, unmatched, total) == (
        Decimal("180.00"), Decimal("90.00"), Decimal("30.00"), Decimal("300.00")
    )
    assert suggested + invalid + unmatched == total

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    pair_sql = extract_view(text, "ic_v3_pair_currency_summary", "ic_v3_pair_reporting_summary")
    assert "INVALID_GROUP_GROSS_DC" in pair_sql
    assert "SUGGESTED_MATCH_GROUPS_RECIPROCAL" in text


@check("23_invalid_offset_amounts_cannot_disappear")
def test_invalid_offset_amounts_cannot_disappear() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    raw_sql = extract_view(text, "ic_v3_offset_line_raw", "ic_v3_offset_line_control")
    control_sql = extract_view(text, "ic_v3_offset_line_control", "ic_v3_offset_line_unique")
    assert "RAW_OFFSET_AMOUNT_STATUS" in raw_sql
    assert "NEGATIVE_RAW_AMOUNT" in raw_sql
    assert "WHERE B.SHKZG IN" not in raw_sql, (
        "an ingestion WHERE clause can silently discard malformed offsets"
    )
    assert "FAIL_INVALID_OFFSET_AMOUNT_OR_SIGN" in control_sql


@check("24_manual_gl_cannot_pass_on_zero_recent_rows")
def test_manual_gl_cannot_pass_on_zero_recent_rows() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    gate_sql = extract_view(text, "ic_v3_release_gate", "ic_v3_expected_release_gate")
    compact = re.sub(r"\s+", "", gate_sql)
    assert "'MANUAL_GL','MANUAL_GL_POSITION_SEMANTICS_APPROVED'" in compact
    assert "FROMIC_V3_MANUAL_ACCOUNT_SCOPE" in compact
    assert "FROMIC_V3_MANUAL_GL_DIAGNOSTIC" not in compact, (
        "a zero-row movement diagnostic cannot prove a zero manual-GL position"
    )

    product_sql = extract_view(
        text, "ic_v3_product_scope_manifest", "ic_v3_product_release_status"
    )
    compact_product = re.sub(r"\s+", "", product_sql)
    for product in (
        "ARAP_ENTERPRISE_PRODUCTION",
        "MANAGEMENT_SPLIT_LC_ENTERPRISE",
        "REPORTING_CURRENCY_ENTERPRISE",
    ):
        assert f"('{product}','MANUAL_GL')" in compact_product


@check("25_grir_workqueue_is_diagnostic_and_actionable")
def test_grir_workqueue_is_diagnostic_and_actionable() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    workqueue_sql = extract_view(
        text, "ic_v3_grir_workqueue", "ic_v3_grir_lineage_exception"
    )
    for token in (
        "AGING_BUCKET",
        "RECOMMENDED_OWNER_QUEUE",
        "RECOMMENDED_NEXT_CHECK",
        "RAW_PRESENCE_HYPOTHESIS_NOT_ACCOUNTING_CONCLUSION",
        "ROUTING_SAFETY_STATUS",
        "HISTORY_BASIS_STATUS",
    ):
        assert token in workqueue_sql, f"GR/IR workqueue omits {token}"
    assert "SUPPORTED_AMOUNT" not in workqueue_sql
    for sentinel in (
        "PO_OWNER_STATUS_MISSING",
        "EVENT_CONTROL_STATUS_MISSING",
        "HISTORY_BASIS_STATUS_MISSING",
        "REVERSAL_STATUS_MISSING",
        "ASSIGNMENT_BASIS_STATUS_MISSING",
        "ASSIGNMENT_LINK_STATUS_MISSING",
        "BLOCKED_LIFECYCLE_CLASSIFICATION_MISSING",
    ):
        assert sentinel in workqueue_sql
    assert "WHEN AS_OF_DATE IS NULL OR OLDEST_FI_POSTING_DATE IS NULL" in workqueue_sql

    con = duckdb.connect()
    routing, age = con.execute(
        """
        WITH x(clearing_count,po_owner,event_control,history_basis,reversal,
               assignment_basis,assignment_link,lifecycle_type,
               as_of_date,oldest_date) AS (
          VALUES (NULL::BIGINT,NULL::VARCHAR,NULL::VARCHAR,NULL::VARCHAR,
                  NULL::VARCHAR,NULL::VARCHAR,NULL::VARCHAR,NULL::VARCHAR,
                  NULL::DATE,DATE '2026-01-01')
        )
        SELECT CASE
          WHEN clearing_count IS NULL THEN 'BLOCKED_CLEARING_CONTROL_MISSING'
          WHEN clearing_count>0 THEN 'BLOCKED_CLEARING_CONTROL'
          WHEN COALESCE(po_owner,'PO_OWNER_STATUS_MISSING')<>'CONFIRMED_PO_OWNER'
            THEN 'BLOCKED_PO_OWNER_CONTROL'
          WHEN COALESCE(event_control,'EVENT_CONTROL_STATUS_MISSING')<>
               'PRESENCE_DIAGNOSTIC_REVERSAL_MAP_INCOMPLETE'
            THEN 'BLOCKED_EVENT_CONTROL'
          WHEN COALESCE(history_basis,'HISTORY_BASIS_STATUS_MISSING')<>
               'EKBE_AND_EKBEH_COVERAGE_CERTIFIED'
            OR COALESCE(reversal,'REVERSAL_STATUS_MISSING')<>
               'REVERSAL_LINEAGE_COMPLETE'
            THEN 'BLOCKED_HISTORY_OR_REVERSAL_INCOMPLETE'
          WHEN COALESCE(assignment_basis,'ASSIGNMENT_BASIS_STATUS_MISSING')<>
               'ASSIGNMENT_LEVEL_HISTORY_INGESTED'
            OR COALESCE(assignment_link,'ASSIGNMENT_LINK_STATUS_MISSING')<>
               'PO_ITEM_UNIQUE_ASSIGNMENT'
            THEN 'BLOCKED_ASSIGNMENT_LINEAGE'
          WHEN lifecycle_type IS NULL
            THEN 'BLOCKED_LIFECYCLE_CLASSIFICATION_MISSING'
          ELSE 'ELIGIBLE_FOR_BUSINESS_ROUTING' END,
          CASE WHEN as_of_date IS NULL OR oldest_date IS NULL
               THEN 'AGE_UNKNOWN' ELSE 'AGE_KNOWN' END
        FROM x
        """
    ).fetchone()
    assert (routing, age) == ("BLOCKED_CLEARING_CONTROL_MISSING", "AGE_UNKNOWN")


@check("26_grir_event_values_and_assignment_basis_fail_closed")
def test_grir_event_values_and_assignment_basis_fail_closed() -> None:
    con = duckdb.connect()
    statuses = con.execute(
        """
        WITH event(id,amount_dc,amount_lc,quantity,shkzg) AS (
          VALUES
            ('ok',10.00::DECIMAL(18,2),9.00::DECIMAL(18,2),1.00::DECIMAL(18,2),'S'),
            ('negative_amount',-10.00::DECIMAL(18,2),9.00::DECIMAL(18,2),1.00::DECIMAL(18,2),'S'),
            ('negative_quantity',10.00::DECIMAL(18,2),9.00::DECIMAL(18,2),-1.00::DECIMAL(18,2),'H'),
            ('bad_sign',10.00::DECIMAL(18,2),9.00::DECIMAL(18,2),1.00::DECIMAL(18,2),'X'),
            ('null_sign',10.00::DECIMAL(18,2),9.00::DECIMAL(18,2),1.00::DECIMAL(18,2),NULL)
        )
        SELECT id,
          CASE
            WHEN amount_dc IS NULL OR amount_lc IS NULL OR amount_dc<0 OR amount_lc<0
              OR shkzg NOT IN ('S','H') OR shkzg IS NULL
              THEN 'FAIL_EVENT_AMOUNT_OR_SIGN'
            WHEN quantity IS NULL OR quantity<0 THEN 'FAIL_EVENT_QUANTITY_OR_SIGN'
            ELSE 'PASS' END status
        FROM event ORDER BY id
        """
    ).fetchall()
    assert statuses == [
        ("bad_sign", "FAIL_EVENT_AMOUNT_OR_SIGN"),
        ("negative_amount", "FAIL_EVENT_AMOUNT_OR_SIGN"),
        ("negative_quantity", "FAIL_EVENT_QUANTITY_OR_SIGN"),
        ("null_sign", "FAIL_EVENT_AMOUNT_OR_SIGN"),
        ("ok", "PASS"),
    ]

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    event_control = extract_view(
        text, "ic_v3_grir_event_key_control", "ic_v3_grir_po_history_event"
    )
    assert "FAIL_INVALID_EVENT_AMOUNT_OR_SIGN" in event_control
    assert "FAIL_INVALID_EVENT_QUANTITY_OR_SIGN" in event_control
    release = extract_view(text, "ic_v3_release_gate", "ic_v3_expected_release_gate")
    compact = re.sub(r"\s+", "", release)
    assert (
        "COALESCE(ASSIGNMENT_BASIS_STATUS,'ASSIGNMENT_BASIS_STATUS_MISSING')"
        "<>'ASSIGNMENT_LEVEL_HISTORY_INGESTED'"
    ) in compact


@check("27_diagnostic_partner_candidates_do_not_leak_into_official_oob")
def test_diagnostic_partner_candidates_do_not_leak_into_official_oob() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    official = extract_view(
        text, "ic_v3_pair_currency_summary", "ic_v3_pair_reporting_summary"
    )
    diagnostic = extract_view(
        text,
        "ic_v3_diagnostic_partner_candidate_pair_summary",
        "ic_v3_item_population_bucket",
    )
    partner_exception = extract_view(
        text,
        "ic_v3_partner_exception_summary",
        "ic_v3_diagnostic_partner_candidate_pair_summary",
    )
    eligible = extract_view(
        text, "ic_v3_match_eligible_item", "ic_v3_bvorg_group_member"
    )
    assert "DIAGNOSTIC_PARTNER_ENTITY_ID" not in official
    assert "PARTNER_MATCH_ELIGIBLE" in eligible
    assert "PARTNER_RESOLUTION_STATUS='DERIVED_UNIQUE_DIAGNOSTIC'" in re.sub(
        r"\s+", "", diagnostic
    )
    assert "SINGLE_DISTINCT_CANDIDATE_NOT_APPROVED_FOR_OFFICIAL_OOB" in diagnostic
    assert "COALESCE(PARTNER_MATCH_ELIGIBLE,FALSE)" in re.sub(
        r"\s+", "", partner_exception
    )
    assert "OWNER_ENTITY_STATUS_MISSING" in partner_exception


@check("28_invalid_grir_posting_date_blocks_release")
def test_invalid_grir_posting_date_blocks_release() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    release = extract_view(text, "ic_v3_release_gate", "ic_v3_expected_release_gate")
    start = release.index("'GRIR','GRIR_HEADER_AND_CLEARING_VALID'")
    end = release.index("UNION ALL", start)
    gate = release[start:end]
    assert (
        "COALESCE(POSTING_DATE_STATUS,'POSTING_DATE_STATUS_MISSING')<>'VALID'"
        in re.sub(r"\s+", "", gate)
    )

    con = duckdb.connect()
    status = con.execute(
        """
        WITH candidate(header_status,posting_date_status,clearing_control_status) AS (
          VALUES ('HEADER_RESOLVED','INVALID_OR_NULL','NOT_CLEARED')
        )
        SELECT CASE WHEN SUM(CASE
          WHEN header_status<>'HEADER_RESOLVED' OR posting_date_status<>'VALID'
            OR clearing_control_status NOT IN (
                 'NOT_CLEARED','CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED')
            THEN 1 ELSE 0 END)=0
          THEN 'PASS' ELSE 'FAIL' END
        FROM candidate
        """
    ).fetchone()[0]
    assert status == "FAIL"


@check("29_gate_and_product_manifests_reject_duplicates")
def test_gate_and_product_manifests_reject_duplicates() -> None:
    con = duckdb.connect()
    expected_status, product_status = con.execute(
        """
        WITH expected(scope,gate) AS (
          VALUES ('ARAP','KEY_UNIQUE'),('ARAP','KEY_UNIQUE')
        ), expected_control AS (
          SELECT scope,gate,CASE WHEN COUNT(*)=1 THEN 'PASS'
            ELSE 'FAIL_DUPLICATE_EXPECTED_GATE_KEY' END status
          FROM expected GROUP BY scope,gate
        ), product_manifest(product,scope) AS (
          VALUES ('P','ARAP'),('P','ARAP')
        ), product_control AS (
          SELECT product,scope,CASE WHEN COUNT(*)=1 THEN 'PASS'
            ELSE 'FAIL_DUPLICATE_PRODUCT_SCOPE_MAPPING' END status
          FROM product_manifest GROUP BY product,scope
        )
        SELECT (SELECT status FROM expected_control),
               (SELECT status FROM product_control)
        """
    ).fetchone()
    assert expected_status == "FAIL_DUPLICATE_EXPECTED_GATE_KEY"
    assert product_status == "FAIL_DUPLICATE_PRODUCT_SCOPE_MAPPING"

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    assert "FAIL_DUPLICATE_EXPECTED_GATE_KEY" in text
    assert "FAIL_DUPLICATE_PRODUCT_SCOPE_MAPPING" in text


@check("30_parameter_and_account_scope_domains_are_validated")
def test_parameter_and_account_scope_domains_are_validated() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    params = extract_view(text, "ic_v3_parameter_control", "ic_v3_account_scope_control")
    scope = extract_view(text, "ic_v3_account_scope_control", "ic_v3_grir_account_scope_control")
    for token in (
        "REPORTING_CURRENCY<>UPPER(TRIM(REPORTING_CURRENCY))",
        "EXACT_TOLERANCE<0",
        "FX_MULTIPLIER_CONTRACT_APPROVEDISNULL",
        "FAIL_REQUIRED_PARAMETER_DOMAIN",
    ):
        assert token in re.sub(r"\s+", "", params)
    assert "SOURCE_FAMILY NOT IN ('AR_SUBLEDGER','AP_SUBLEDGER')" in scope
    assert "COMPANY_CODE" in scope
    assert "NULLIF(TRIM(SCOPE_RULE_ID),'')ISNULL" in re.sub(r"\s+", "", scope)
    assert "MIN(POSITION_SEMANTICS)<>'OPEN_ITEM'" in re.sub(r"\s+", "", scope)
    arap_control = extract_view(
        text, "ic_v3_account_scope_control", "ic_v3_grir_account_scope_control"
    )
    grir_control = extract_view(
        text, "ic_v3_grir_account_scope_control", "ic_v3_arap_population_control"
    )
    assert "SUM(CASE" in arap_control
    assert "SUM(CASE" in grir_control
    assert "NULLIF(TRIM(MATCH_SIDE),'') IS NULL" in arap_control
    assert "NULLIF(TRIM(POSITION_SEMANTICS),'') IS NULL" in grir_control
    release = extract_view(text, "ic_v3_release_gate", "ic_v3_expected_release_gate")
    assert "'ARAP','ACCOUNT_SCOPE_COMPANY_EXPLICIT'" in release
    assert "'ARAP','ACCOUNT_SCOPE_COVERAGE_REGISTRY_CERTIFIED'" in release
    assert "COMPANY_CODE='*'" in re.sub(r"\s+", "", release)


@check("31_open_and_cleared_index_semantics_fail_closed")
def test_open_and_cleared_index_semantics_fail_closed() -> None:
    con = duckdb.connect()
    rows = con.execute(
        """
        WITH item(id,physical_source,posting_date,clearing_date,
                  clearing_date_status,clearing_document) AS (
          VALUES
            ('open_ok','BSID',DATE '2026-08-01',NULL,'INITIAL',NULL),
            ('open_has_clear','BSID',DATE '2026-08-01',DATE '2026-08-02','VALID','9001'),
            ('cleared_ok','BSAD',DATE '2026-08-01',DATE '2026-08-02','VALID','9002'),
            ('cleared_blank','BSAD',DATE '2026-08-01',NULL,'INITIAL',NULL),
            ('cleared_no_doc','BSAK',DATE '2026-08-01',DATE '2026-08-02','VALID',NULL),
            ('cleared_bad_chronology','BSAK',DATE '2026-08-03',DATE '2026-08-02','VALID','9003')
        )
        SELECT id, CASE
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
          WHEN physical_source IN ('BSAD','BSAK') AND clearing_date<posting_date
            THEN 'CLEARED_INDEX_CLEARING_BEFORE_POSTING'
          WHEN physical_source IN ('BSAD','BSAK') AND clearing_date_status='VALID'
            THEN 'CLEARED_INDEX_LIFECYCLE_CONSISTENT'
          ELSE 'SOURCE_INDEX_LIFECYCLE_INVALID' END status
        FROM item ORDER BY id
        """
    ).fetchall()
    assert dict(rows) == {
        "cleared_bad_chronology": "CLEARED_INDEX_CLEARING_BEFORE_POSTING",
        "cleared_blank": "CLEARED_INDEX_MISSING_CLEARING_DATE",
        "cleared_no_doc": "CLEARED_INDEX_MISSING_CLEARING_DOCUMENT",
        "cleared_ok": "CLEARED_INDEX_LIFECYCLE_CONSISTENT",
        "open_has_clear": "OPEN_INDEX_HAS_CLEARING_EVIDENCE",
        "open_ok": "OPEN_INDEX_LIFECYCLE_CONSISTENT",
    }

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    normalized = extract_view(text, "ic_v3_item_normalized", "ic_v3_item_preasof_quarantine")
    asof = extract_view(text, "ic_v3_item_asof_physical", "ic_v3_item_quarantine")
    exception = extract_view(
        text,
        "ic_v3_item_source_lifecycle_exception",
        "ic_v3_item_bseg_line_raw",
    )
    release = extract_view(text, "ic_v3_release_gate", "ic_v3_expected_release_gate")
    assert "SOURCE_LIFECYCLE_STATUS" in normalized
    assert "MISSING_SOURCE_LIFECYCLE_STATUS" in asof
    assert "MISSING_CLEARING_DATE_STATUS" in asof
    assert "SOURCE_FAMILY" in exception
    assert "PHYSICAL_COPY_COUNT" in exception
    assert "PHYSICAL_SOURCE_COUNT" in exception
    assert "PHYSICAL_SOURCE," not in exception
    assert "SOURCE_INDEX_LIFECYCLE_CONSISTENT" in release
    quarantine = extract_view(text, "ic_v3_item_quarantine", "ic_v3_item_base")
    assert "FAIL_SOURCE_KEY_STATUS_MISSING" in quarantine
    assert text.count(
        "COALESCE(SOURCE_LIFECYCLE_STATUS,'MISSING_SOURCE_LIFECYCLE_STATUS')"
    ) >= 2
    assert "COALESCE(C.SOURCE_LIFECYCLE_STATUS,'MISSING_SOURCE_LIFECYCLE_STATUS')" in text

    null_boundary_hits = con.execute(
        """
        WITH x(source_lifecycle_status) AS (VALUES (NULL::VARCHAR))
        SELECT
          SUM(CASE WHEN COALESCE(source_lifecycle_status,
                                 'MISSING_SOURCE_LIFECYCLE_STATUS') NOT IN (
                         'OPEN_INDEX_LIFECYCLE_CONSISTENT',
                         'CLEARED_INDEX_LIFECYCLE_CONSISTENT')
                   THEN 1 ELSE 0 END),
          COUNT(*) FILTER (WHERE COALESCE(source_lifecycle_status,
                                 'MISSING_SOURCE_LIFECYCLE_STATUS') NOT IN (
                         'OPEN_INDEX_LIFECYCLE_CONSISTENT',
                         'CLEARED_INDEX_LIFECYCLE_CONSISTENT'))
        FROM x
        """
    ).fetchone()
    assert null_boundary_hits == (1, 1)


@check("32_null_offset_sign_is_rejected")
def test_null_offset_sign_is_rejected() -> None:
    con = duckdb.connect()
    status, signed = con.execute(
        """
        WITH x(raw_dc,raw_lc,shkzg) AS (
          VALUES (100.00::DECIMAL(18,2),90.00::DECIMAL(18,2),NULL::VARCHAR)
        )
        SELECT CASE
          WHEN raw_dc IS NULL OR raw_lc IS NULL THEN 'MISSING_OR_INVALID_RAW_AMOUNT'
          WHEN raw_dc<0 OR raw_lc<0 THEN 'NEGATIVE_RAW_AMOUNT'
          WHEN shkzg NOT IN ('S','H') OR shkzg IS NULL
            THEN 'INVALID_DEBIT_CREDIT_CODE'
          ELSE 'NONNEGATIVE_RAW_AMOUNT' END,
          CASE WHEN shkzg='S' THEN raw_dc WHEN shkzg='H' THEN -raw_dc END
        FROM x
        """
    ).fetchone()
    assert status == "INVALID_DEBIT_CREDIT_CODE" and signed is None

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    raw = extract_view(text, "ic_v3_offset_line_raw", "ic_v3_offset_line_control")
    document_control = extract_view(
        text, "ic_v3_offset_document_control", "ic_v3_offset_line_raw"
    )
    assert "NULLIF(TRIM(CAST(B.BUZEI AS STRING)),'')" in raw
    assert "NULLIF(TRIM(CAST(B.BUZEI AS STRING)),'') IS NULL" in document_control
    control = extract_view(text, "ic_v3_offset_line_control", "ic_v3_offset_line_unique")
    compact = re.sub(r"\s+", "", control)
    for token in (
        "OFFSET_DEBIT_CREDIT_CODEISNULL",
        "OFFSET_SIGNED_AMOUNT_DCISNULL",
        "OFFSET_SIGNED_AMOUNT_LCISNULL",
    ):
        assert token in compact, f"offset control omits {token}"


@check("33_grir_clearing_reference_and_chronology_control")
def test_grir_clearing_reference_and_chronology_control() -> None:
    con = duckdb.connect()
    rows = con.execute(
        """
        WITH x(id,posting_date,clearing_date,reference_status) AS (
          VALUES
            ('open',DATE '2026-08-01',NULL,'NOT_CLEARED'),
            ('cleared',DATE '2026-08-01',DATE '2026-08-20','CLEARING_REFERENCE_RESOLVED'),
            ('bad_chronology',DATE '2026-08-21',DATE '2026-08-20','CLEARING_REFERENCE_RESOLVED'),
            ('missing_header',DATE '2026-08-01',DATE '2026-08-20','CLEARING_HEADER_MISSING'),
            ('missing_control',DATE '2026-08-01',DATE '2026-08-20',NULL)
        ), controlled AS (
          SELECT *, CASE
            WHEN reference_status IS NULL THEN 'MISSING_CLEARING_CONTROL'
            WHEN reference_status='NOT_CLEARED' THEN 'NOT_CLEARED'
            WHEN reference_status<>'CLEARING_REFERENCE_RESOLVED' THEN reference_status
            WHEN clearing_date<posting_date THEN 'INVALID_CLEARING_BEFORE_POSTING'
            ELSE 'CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED' END control_status
          FROM x
        )
        SELECT id, CASE
          WHEN control_status='CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED'
           AND clearing_date<DATE '2026-09-01' THEN 'EXCLUDE_CLEARED_PRE_CUTOFF'
          WHEN control_status IN ('NOT_CLEARED','CLEARING_REFERENCE_AND_CHRONOLOGY_RESOLVED')
            THEN 'INCLUDE_AS_OF_OPEN'
          ELSE 'INCLUDE_BUT_FAIL_CLEARING_CONTROL' END population_status
        FROM controlled ORDER BY id
        """
    ).fetchall()
    assert dict(rows) == {
        "bad_chronology": "INCLUDE_BUT_FAIL_CLEARING_CONTROL",
        "cleared": "EXCLUDE_CLEARED_PRE_CUTOFF",
        "missing_header": "INCLUDE_BUT_FAIL_CLEARING_CONTROL",
        "missing_control": "INCLUDE_BUT_FAIL_CLEARING_CONTROL",
        "open": "INCLUDE_AS_OF_OPEN",
    }

    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    assert "IC_V3_GRIR_CLEARING_HEADER_RAW" in text
    assert "IC_V3_GRIR_CLEARING_CONTROL" in text
    assert "CAST(B.AUGGJ AS STRING)" in text
    assert "INVALID_CLEARING_BEFORE_POSTING" in text
    assert "INCLUDE_BUT_FAIL_CLEARING_CONTROL" in text
    assert "COALESCE(CLEARING_CONTROL_STATUS,'MISSING_CLEARING_CONTROL') NOT IN" in text


@check("34_grir_history_and_reversal_block_business_routing")
def test_grir_history_and_reversal_block_business_routing() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    po_scope = extract_view(
        text,
        "ic_v3_grir_po_scope_controlled",
        "ic_v3_grir_po_history_event_physical",
    )
    workqueue = extract_view(text, "ic_v3_grir_workqueue", "ic_v3_grir_lineage_exception")
    release = extract_view(text, "ic_v3_release_gate", "ic_v3_expected_release_gate")
    lifecycle = extract_view(
        text, "ic_v3_grir_po_item_lifecycle", "ic_v3_grir_workqueue"
    )
    assert "PO_OWNER_CONTROL_MISSING" in po_scope
    assert "PO_OWNER_COMPANY_MISSING" in po_scope
    assert "EKBE_ONLY_EKBEH_NOT_INGESTED" in lifecycle
    assert "BLOCKED_HISTORY_OR_REVERSAL_INCOMPLETE" in workqueue
    assert "LOCAL_CURRENCY_STATUS" in workqueue
    assert "OPEN_FI_AMOUNT_LC" not in workqueue
    assert "GROSS_FI_AMOUNT_LC" not in workqueue
    assert workqueue.index("HISTORY_BASIS_STATUS,'HISTORY_BASIS_STATUS_MISSING'") < workqueue.index(
        "WHEN LIFECYCLE_EXCEPTION_TYPE='PRESENCE_DIAGNOSTIC_GR_SEEN_IR_NOT_SEEN'"
    )
    assert "'GRIR_LIFECYCLE','PO_HISTORY_ARCHIVE_COVERAGE_CERTIFIED'" in release
    assert "'GRIR_LIFECYCLE','EVENT_REVERSAL_LINEAGE_COMPLETE'" in release
    for sentinel in (
        "EVENT_CONTROL_STATUS_MISSING",
        "PO_OWNER_STATUS_MISSING",
        "ASSIGNMENT_BASIS_STATUS_MISSING",
        "ASSIGNMENT_LINK_STATUS_MISSING",
        "EVENT_ADDITIVITY_STATUS_MISSING",
        "AUTOMATION_STATUS_MISSING",
    ):
        assert sentinel in release


@check("35_grir_numeric_overlap_is_one_to_one_and_gr_only")
def test_grir_numeric_overlap_is_one_to_one_and_gr_only() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    candidate = extract_view(
        text, "ic_v3_arap_grir_link_candidate", "ic_v3_arap_grir_candidate_unique"
    )
    pair_control = extract_view(
        text,
        "ic_v3_arap_grir_pair_physical_control",
        "ic_v3_arap_candidate_count",
    )
    link = extract_view(text, "ic_v3_arap_grir_link", "ic_v3_parameter_control")
    candidate_compact = re.sub(r"\s+", "", candidate)
    pair_control_compact = re.sub(r"\s+", "", pair_control)
    compact = re.sub(r"\s+", "", link)
    assert "ASSELECTDISTINCT" not in candidate_compact
    assert "JOINIC_V3_MATCH_MEMBERSHIP_CONTROLMCON" in candidate_compact
    assert "MC.MEMBERSHIP_CONTROL_STATUS='PASS'" in candidate_compact
    assert "COUNT(*)ASCANDIDATE_PHYSICAL_ROW_COUNT" in pair_control_compact
    for token in (
        "PC.PAIR_PHYSICAL_CONTROL_STATUS='PASS'",
        "AC.GRIR_CANDIDATES_FOR_ARAP=1",
        "GC.ARAP_CANDIDATES_FOR_GRIR=1",
        "C.LIFECYCLE_EXCEPTION_TYPE='PRESENCE_DIAGNOSTIC_GR_SEEN_IR_NOT_SEEN'",
        "NUMERIC_DIAGNOSTIC_SUPPRESSED_AMBIGUOUS_OR_NONCAUSAL",
    ):
        assert token in compact, f"bounded GR/IR diagnostic omits {token}"


@check("36_production_readiness_cannot_be_self_attested")
def test_production_readiness_cannot_be_self_attested() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    release = extract_view(text, "ic_v3_release_gate", "ic_v3_expected_release_gate")
    for gate_name in (
        "SOURCE_CONTRACT_CERTIFIED",
        "CONSISTENT_SOURCE_SNAPSHOT_CAPTURED",
        "GLOBAL_EFFECTIVE_DATED_ENTITY_XREF",
        "REFERENCE_DATA_VERSIONS_PINNED",
        "ACCOUNT_SCOPE_EFFECTIVE_DATED_AND_GOVERNED",
        "RUN_SCOPED_MATERIALIZED_STAGES",
    ):
        start = release.index(f"'PRODUCTION_READINESS','{gate_name}'")
        end = release.find("UNION ALL", start)
        gate = release[start:] if end < 0 else release[start:end]
        assert "'FAIL'" in gate, f"{gate_name} can be self-attested"
        assert "HARD-DISABLED" in gate, f"{gate_name} lacks evidence-registry warning"


@check("37_malformed_amount_hashes_use_try_cast")
def test_malformed_amount_hashes_use_try_cast() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    for current, following in (
        ("ic_v3_item_bseg_line_raw", "ic_v3_item_bseg_line_control"),
        ("ic_v3_offset_line_raw", "ic_v3_offset_line_control"),
        ("ic_v3_grir_line_physical", "ic_v3_grir_line_control"),
    ):
        view = extract_view(text, current, following)
        compact = re.sub(r"\s+", "", view)
        assert "'WRBTR',TRY_CAST(" in compact
        assert "'DMBTR',TRY_CAST(" in compact
        assert "'WRBTR',CAST(" not in compact
        assert "'DMBTR',CAST(" not in compact


@check("38_null_grir_sign_classification_fails_closed")
def test_null_grir_sign_classification_fails_closed() -> None:
    text = PIPELINE_SQL.read_text(encoding="utf-8").upper()
    fi = extract_view(text, "ic_v3_grir_line_physical", "ic_v3_grir_line_control")
    event = extract_view(
        text,
        "ic_v3_grir_po_history_event_physical",
        "ic_v3_grir_event_key_control",
    )
    fi_compact = re.sub(r"\s+", "", fi)
    event_compact = re.sub(r"\s+", "", event)
    link = extract_view(text, "ic_v3_arap_grir_link", "ic_v3_parameter_control")
    link_compact = re.sub(r"\s+", "", link)
    assert "CAST(B.SHKZGASSTRING)NOTIN('S','H')ORB.SHKZGISNULL" in fi_compact
    assert event_compact.count(
        "CAST(E.SHKZGASSTRING)NOTIN('S','H')ORE.SHKZGISNULL"
    ) >= 2
    assert link_compact.count(
        "C.ARAP_AMOUNT_DCISNULLORC.GRIR_OPEN_AMOUNT_DCISNULL"
    ) >= 2
    assert "DIAGNOSTIC_ONLY_AMOUNT_MISSING_OR_INVALID" in link_compact
    assert "SIGN_DIRECTION_UNKNOWN_AMOUNT_MISSING_OR_INVALID" in link_compact


def main() -> int:
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()

    width = max(len(r.name) for r in RESULTS)
    for result in RESULTS:
        print(f"{'PASS' if result.passed else 'FAIL'}  {result.name:<{width}}")
        if not result.passed:
            print(result.detail)
    passed = sum(r.passed for r in RESULTS)
    print(f"\n{passed}/{len(RESULTS)} checks passed")
    return 0 if passed == len(RESULTS) else 1


if __name__ == "__main__":
    raise SystemExit(main())
