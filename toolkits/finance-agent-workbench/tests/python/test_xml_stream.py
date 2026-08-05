from __future__ import annotations

import codecs
from dataclasses import replace
import hashlib
import json
from pathlib import Path
import tracemalloc

import pytest

import spoolctl.xml_stream as xml_stream
from spoolctl.cli import main
from spoolctl.contracts import DEFAULT_XML_LIMITS, XmlLimits
from spoolctl.xml_stream import (
    CharacterDataLimitError,
    DistinctQNameLimitError,
    MalformedXmlError,
    MarkupTokenLimitError,
    MissingRequiredFieldsError,
    NestingDepthLimitError,
    NoRowsFoundError,
    OutputValidationError,
    RemoteSourceRejectedError,
    RowByteLimitError,
    RowFieldLimitError,
    RowValueLimitError,
    SourceChangedError,
    UnsafeXmlError,
    inspect_xml,
    normalize_jsonl,
)


def _write(path: Path, content: bytes) -> Path:
    path.write_bytes(content)
    return path


def test_streaming_inspection_uses_expanded_namespace_names(tmp_path: Path) -> None:
    content = b"""<?xml version="1.0" encoding="UTF-8"?>
<s:spool xmlns:s="urn:example:spool" xmlns:f="urn:example:fields">
  <s:row><f:id>1</f:id><f:date>2026-01-31</f:date></s:row>
  <s:row><f:id>2</f:id><f:date>2026-02-28</f:date></s:row>
</s:spool>
"""
    source = _write(tmp_path / "namespaced.xml", content)

    manifest = inspect_xml(
        source,
        row_qname="{urn:example:spool}row",
        required_fields=("{urn:example:fields}id", "{urn:example:fields}date"),
    )

    profiles = {field.qname.expanded: field for field in manifest.fields}
    assert manifest.completed_eof is True
    assert manifest.root_qname.expanded == "{urn:example:spool}spool"
    assert manifest.row_count == 2
    assert manifest.source.byte_count == len(content)
    assert manifest.source.sha256 == hashlib.sha256(content).hexdigest()
    assert profiles["{urn:example:fields}id"].occurrence_count == 2
    assert profiles["{urn:example:fields}date"].non_empty_count == 2


def test_utf16_bom_is_parsed_from_binary_input(tmp_path: Path) -> None:
    text = """<?xml version="1.0" encoding="utf-16"?>
<root><row><value>caf\u00e9</value></row></root>"""
    content = text.encode("utf-16")
    source = _write(tmp_path / "utf16.xml", content)

    manifest = inspect_xml(
        source,
        row_qname="row",
        required_fields=("value",),
    )

    assert manifest.row_count == 1
    assert manifest.source.detected_encoding in {"utf-16-le", "utf-16-be"}
    assert manifest.source.sha256 == hashlib.sha256(content).hexdigest()


def test_utf32_bom_is_detected_before_overlapping_utf16_bom() -> None:
    assert (
        xml_stream._detect_encoding(codecs.BOM_UTF32_LE + b"rest")
        == "utf-32-le"
    )
    assert (
        xml_stream._detect_encoding(codecs.BOM_UTF32_BE + b"rest")
        == "utf-32-be"
    )


@pytest.mark.parametrize(
    ("codec", "bom", "detected"),
    [
        ("utf-32-le", codecs.BOM_UTF32_LE, "utf-32-le"),
        ("utf-32-be", codecs.BOM_UTF32_BE, "utf-32-be"),
    ],
)
def test_utf32_binary_input_is_streamed_without_dom(
    tmp_path: Path, codec: str, bom: bytes, detected: str
) -> None:
    text = (
        '<?xml version="1.0" encoding="utf-32"?>'
        "<root><row><value>1</value></row></root>"
    )
    source = _write(tmp_path / "utf32.xml", bom + text.encode(codec))

    manifest = inspect_xml(source, row_qname="row", required_fields=("value",))

    assert manifest.row_count == 1
    assert manifest.source.detected_encoding == detected


def test_successful_normalization_preserves_duplicate_fields(tmp_path: Path) -> None:
    source = _write(
        tmp_path / "valid.xml",
        b"<root><row><code>A</code><code>B</code></row></root>",
    )
    destination = tmp_path / "rows.jsonl"

    receipt = normalize_jsonl(
        source,
        destination,
        row_qname="row",
        required_fields=("code",),
    )

    output_bytes = destination.read_bytes()
    record = json.loads(output_bytes)
    assert record == {
        "row_number": 1,
        "fields": {"code": ["A", "B"]},
    }
    assert receipt.committed is True
    assert receipt.output_byte_count == len(output_bytes)
    assert receipt.output_sha256 == hashlib.sha256(output_bytes).hexdigest()


def test_truncation_after_a_complete_row_never_publishes_output(
    tmp_path: Path,
) -> None:
    source = _write(
        tmp_path / "truncated.xml",
        b"<root><row><id>1</id></row><row><id>2</id></row>",
    )
    destination = _write(tmp_path / "rows.jsonl", b"previous-good-output\n")

    with pytest.raises(MalformedXmlError) as captured:
        normalize_jsonl(source, destination, row_qname="row")

    assert captured.value.line is not None
    assert destination.read_bytes() == b"previous-good-output\n"
    assert list(tmp_path.glob(".rows.jsonl.*.tmp")) == []


def test_malformed_closing_tag_is_classified(tmp_path: Path) -> None:
    source = _write(
        tmp_path / "malformed.xml",
        b"<root><row><id>1</id></wrong></root>",
    )

    with pytest.raises(MalformedXmlError) as captured:
        inspect_xml(source, row_qname="row")

    assert captured.value.code == "malformed_or_truncated_xml"
    assert captured.value.line == 1


def test_missing_required_fields_fail_after_eof_and_do_not_commit(
    tmp_path: Path,
) -> None:
    source = _write(
        tmp_path / "missing.xml",
        b"<root><row><id>1</id></row><row><id> </id></row></root>",
    )
    destination = _write(tmp_path / "rows.jsonl", b"trusted\n")

    with pytest.raises(MissingRequiredFieldsError) as captured:
        normalize_jsonl(
            source,
            destination,
            row_qname="row",
            required_fields=("id", "date"),
        )

    missing = dict(captured.value.manifest.missing_required_counts)
    assert captured.value.manifest.completed_eof is True
    assert missing == {"id": 1, "date": 2}
    assert destination.read_bytes() == b"trusted\n"

    report_only = inspect_xml(
        source,
        row_qname="row",
        required_fields=("id", "date"),
        strict_required=False,
    )
    assert dict(report_only.missing_required_counts) == missing


def test_doctype_and_entity_declarations_are_rejected_in_preflight(
    tmp_path: Path,
) -> None:
    source = _write(
        tmp_path / "entity.xml",
        b"""<?xml version="1.0"?>
<!DOCTYPE root [<!ENTITY example "expanded">]>
<root><row><value>&example;</value></row></root>""",
    )

    with pytest.raises(UnsafeXmlError, match="DTD and ENTITY"):
        inspect_xml(source, row_qname="row")


def test_no_matching_rows_is_not_silent_by_default(tmp_path: Path) -> None:
    source = _write(tmp_path / "empty-set.xml", b"<root><item /></root>")

    with pytest.raises(NoRowsFoundError):
        inspect_xml(source, row_qname="row")

    manifest = inspect_xml(source, row_qname="row", allow_empty=True)
    assert manifest.row_count == 0
    assert manifest.completed_eof is True


def test_unc_sources_are_rejected_without_access_attempt() -> None:
    with pytest.raises(RemoteSourceRejectedError):
        inspect_xml(r"\\server\share\spool.xml", row_qname="row")


def test_windows_mapped_source_drive_is_rejected_with_stdlib_probe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = _write(tmp_path / "mapped.xml", b"<root><row /></root>")
    monkeypatch.setattr(
        xml_stream,
        "_windows_drive_type",
        lambda _path: xml_stream._WINDOWS_DRIVE_REMOTE,
    )

    with pytest.raises(RemoteSourceRejectedError, match="Mapped network drives"):
        inspect_xml(source, row_qname="row")


def test_windows_mapped_output_drive_is_rejected_with_stdlib_probe(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = _write(tmp_path / "local.xml", b"<root><row /></root>")
    destination = tmp_path / "rows.jsonl"

    def drive_type(path: Path) -> int:
        return xml_stream._WINDOWS_DRIVE_REMOTE if path.name == destination.name else 3

    monkeypatch.setattr(xml_stream, "_windows_drive_type", drive_type)

    with pytest.raises(OutputValidationError, match="network-drive outputs"):
        normalize_jsonl(source, destination, row_qname="row")


@pytest.mark.parametrize(
    ("content", "limits", "error_type"),
    [
        (
            b"<root><row><value>0123456789</value></row></root>",
            replace(DEFAULT_XML_LIMITS, max_row_bytes=5),
            RowByteLimitError,
        ),
        (
            b"<root><row><a>1</a><a>2</a></row></root>",
            replace(DEFAULT_XML_LIMITS, max_values_per_row=1),
            RowValueLimitError,
        ),
        (
            b"<root><row><a>1</a><b>2</b></row></root>",
            replace(DEFAULT_XML_LIMITS, max_fields_per_row=1),
            RowFieldLimitError,
        ),
        (
            b"<root><row><a><b>1</b></a></row></root>",
            replace(DEFAULT_XML_LIMITS, max_nesting_depth=3),
            NestingDepthLimitError,
        ),
        (
            b"<root><row><a>1</a></row></root>",
            replace(DEFAULT_XML_LIMITS, max_distinct_qnames=2),
            DistinctQNameLimitError,
        ),
        (
            b'<root><outside value="' + (b"x" * 256) + b'"/><row /></root>',
            replace(DEFAULT_XML_LIMITS, max_markup_token_bytes=128),
            MarkupTokenLimitError,
        ),
        (
            b"<root>" + (b"x" * 256) + b"<row /></root>",
            replace(DEFAULT_XML_LIMITS, max_character_data_bytes=128),
            CharacterDataLimitError,
        ),
    ],
)
def test_every_resource_limit_fails_transactionally(
    tmp_path: Path,
    content: bytes,
    limits: XmlLimits,
    error_type: type[Exception],
) -> None:
    source = _write(tmp_path / "bounded.xml", content)
    destination = _write(tmp_path / "rows.jsonl", b"previous-good-output\n")

    with pytest.raises(error_type):
        normalize_jsonl(
            source,
            destination,
            row_qname="row",
            limits=limits,
        )

    assert destination.read_bytes() == b"previous-good-output\n"
    assert list(tmp_path.glob(".rows.jsonl.*.tmp")) == []


def test_large_text_outside_rows_is_not_retained(tmp_path: Path) -> None:
    outside_size = 9 * 1024 * 1024
    source = tmp_path / "large-outside-text.xml"
    source.write_bytes(
        b"<root>"
        + (b"x" * outside_size)
        + b"<row><id>1</id></row></root>"
    )
    limits = replace(
        DEFAULT_XML_LIMITS,
        max_character_data_bytes=10 * 1024 * 1024,
    )

    tracemalloc.start()
    try:
        manifest = inspect_xml(
            source,
            row_qname="row",
            required_fields=("id",),
            limits=limits,
        )
        _, peak_bytes = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()

    assert manifest.row_count == 1
    assert peak_bytes < 24 * 1024 * 1024


def test_normalization_preserves_element_text_not_child_tail_text(
    tmp_path: Path,
) -> None:
    source = _write(
        tmp_path / "direct-text.xml",
        b"<root><row><a>before<b>x</b>after</a></row></root>",
    )
    destination = tmp_path / "rows.jsonl"

    normalize_jsonl(source, destination, row_qname="row")
    record = json.loads(destination.read_text(encoding="utf-8"))

    assert record["fields"]["a"] == ["before"]
    assert record["fields"]["b"] == ["x"]


def test_source_change_between_hash_and_parse_is_rejected_transactionally(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = _write(
        tmp_path / "mutable.xml",
        b"<root><row><id>1</id></row></root>",
    )
    destination = _write(tmp_path / "rows.jsonl", b"trusted\n")
    original_scan = xml_stream._scan_and_hash

    def scan_then_mutate(
        stream: object, source_name: str, limits: XmlLimits
    ) -> object:
        receipt = original_scan(stream, source_name, limits)
        source.write_bytes(b"<root><row><id>2</id></row></root>")
        return receipt

    monkeypatch.setattr(xml_stream, "_scan_and_hash", scan_then_mutate)

    with pytest.raises(SourceChangedError):
        normalize_jsonl(source, destination, row_qname="row")

    assert destination.read_bytes() == b"trusted\n"
    assert list(tmp_path.glob(".rows.jsonl.*.tmp")) == []


def test_cli_errors_do_not_leak_sensitive_source_or_output_paths(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    secret_source_name = "Confidential_Client_Alpha_2026.xml"
    missing_source = tmp_path / secret_source_name

    assert main(["inspect", str(missing_source), "--row-tag", "row"]) == 3
    source_error = capsys.readouterr().err
    assert str(missing_source) not in source_error
    assert secret_source_name not in source_error

    source = _write(tmp_path / "valid.xml", b"<root><row /></root>")
    secret_directory_name = "Secret_Reconciliation_Output"
    secret_output_name = "Client_Balance_Detail.jsonl"
    missing_output = tmp_path / secret_directory_name / secret_output_name

    assert (
        main(
            [
                "inspect",
                str(source),
                "--row-tag",
                "row",
                "--rows-out",
                str(missing_output),
            ]
        )
        == 7
    )
    output_error = capsys.readouterr().err
    assert str(missing_output) not in output_error
    assert secret_directory_name not in output_error
    assert secret_output_name not in output_error


def test_cli_emits_machine_readable_json(
    tmp_path: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    source = _write(
        tmp_path / "cli.xml",
        b"<root><row><id>1</id></row></root>",
    )

    exit_code = main(
        [
            "inspect",
            str(source),
            "--row-tag",
            "row",
            "--required-field",
            "id",
        ]
    )
    captured = capsys.readouterr()
    payload = json.loads(captured.out)

    assert exit_code == 0
    assert captured.err == ""
    assert payload["ok"] is True
    assert payload["manifest"]["completed_eof"] is True
    assert payload["manifest"]["row_count"] == 1
    assert payload["manifest"]["limits"]["max_markup_token_bytes"] == 1024 * 1024
    assert (
        payload["manifest"]["limits"]["max_character_data_bytes"]
        == 8 * 1024 * 1024
    )
    assert "cli.xml" not in captured.out
