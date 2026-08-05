from __future__ import annotations

import hashlib

import pytest

from spoolctl.contracts import (
    DEFAULT_XML_LIMITS,
    ExpandedQName,
    FieldProfile,
    InspectionManifest,
    NormalizationReceipt,
    SourceReceipt,
    XmlLimits,
)


def _source_receipt() -> SourceReceipt:
    return SourceReceipt(
        source_name="sample.xml",
        byte_count=12,
        sha256=hashlib.sha256(b"sample-bytes").hexdigest(),
        detected_encoding="utf-8",
    )


def test_expanded_qname_preserves_namespace_identity() -> None:
    qualified = ExpandedQName.from_expanded("{urn:example:ledger}PostingDate")
    unqualified = ExpandedQName.from_expanded("PostingDate")

    assert qualified.namespace_uri == "urn:example:ledger"
    assert qualified.local_name == "PostingDate"
    assert qualified.expanded == "{urn:example:ledger}PostingDate"
    assert unqualified.expanded == "PostingDate"
    assert qualified != unqualified


@pytest.mark.parametrize(
    "invalid",
    ["", "{urn:example}", "{}row", "{urn:example", "row}"],
)
def test_expanded_qname_rejects_ambiguous_or_incomplete_names(invalid: str) -> None:
    with pytest.raises(ValueError):
        ExpandedQName.from_expanded(invalid)


def test_manifest_serializes_to_stable_json_friendly_shape() -> None:
    row = ExpandedQName.from_expanded("{urn:example}row")
    field = ExpandedQName.from_expanded("{urn:example}date")
    manifest = InspectionManifest(
        source=_source_receipt(),
        root_qname=ExpandedQName.from_expanded("{urn:example}root"),
        row_qname=row,
        row_count=2,
        required_fields=(field,),
        missing_required_counts=((field.expanded, 1),),
        fields=(FieldProfile(field, occurrence_count=2, non_empty_count=1),),
    )

    payload = manifest.to_dict()

    assert payload["completed_eof"] is True
    assert payload["row_count"] == 2
    assert payload["row_qname"]["expanded"] == "{urn:example}row"
    assert payload["missing_required_counts"] == {"{urn:example}date": 1}
    assert payload["fields"][0]["non_empty_count"] == 1
    assert payload["limits"] == DEFAULT_XML_LIMITS.to_dict()
    assert manifest.has_missing_required_fields is True


def test_receipts_validate_digest_shape_and_counts() -> None:
    with pytest.raises(ValueError, match="sha256"):
        SourceReceipt("bad.xml", 1, "not-a-digest")

    manifest = InspectionManifest(
        source=_source_receipt(),
        root_qname=ExpandedQName(None, "root"),
        row_qname=ExpandedQName(None, "row"),
        row_count=0,
        required_fields=(),
        missing_required_counts=(),
        fields=(),
    )
    output_digest = hashlib.sha256(b"").hexdigest()
    receipt = NormalizationReceipt(
        manifest=manifest,
        output_name="rows.jsonl",
        output_byte_count=0,
        output_sha256=output_digest,
    )

    assert receipt.to_dict()["committed"] is True
    assert receipt.to_dict()["output_sha256"] == output_digest


def test_default_xml_limits_are_finite_and_overridable() -> None:
    assert DEFAULT_XML_LIMITS.to_dict() == {
        "max_row_bytes": 8 * 1024 * 1024,
        "max_values_per_row": 10_000,
        "max_fields_per_row": 2_048,
        "max_nesting_depth": 256,
        "max_distinct_qnames": 4_096,
        "max_markup_token_bytes": 1024 * 1024,
        "max_character_data_bytes": 8 * 1024 * 1024,
    }
    assert XmlLimits(max_row_bytes=1024).max_row_bytes == 1024

    with pytest.raises(ValueError, match="max_nesting_depth"):
        XmlLimits(max_nesting_depth=0)
