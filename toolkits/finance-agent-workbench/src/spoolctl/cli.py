"""JSON command-line interface for safe local spool XML inspection."""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from typing import Any, NoReturn

from . import __version__
from .contracts import DEFAULT_XML_LIMITS, ErrorEnvelope, XmlLimits
from .xml_stream import (
    MissingRequiredFieldsError,
    SpoolXmlError,
    inspect_xml,
    normalize_jsonl,
    write_json_transactional,
)


class _CliUsageError(Exception):
    pass


class _JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise _CliUsageError(message)


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a positive integer") from error
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return parsed


def _parser() -> argparse.ArgumentParser:
    parser = _JsonArgumentParser(
        prog="spoolctl",
        description=(
            "Inspect already-local XML with bounded memory, strict EOF validation, "
            "and SHA-256 receipts."
        ),
    )
    parser.add_argument("--version", action="version", version=__version__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    inspect_parser = subparsers.add_parser(
        "inspect",
        help="Inspect a local XML file and optionally normalize its rows to JSONL",
    )
    inspect_parser.add_argument("source", help="Path to an already-local XML file")
    inspect_parser.add_argument(
        "--row-qname",
        "--row-tag",
        required=True,
        dest="row_qname",
        help="Expanded row name, such as '{urn:example}row' or unqualified 'row'",
    )
    inspect_parser.add_argument(
        "--required-field",
        action="append",
        default=[],
        help="Expanded required field name; repeat for multiple fields",
    )
    inspect_parser.add_argument(
        "--rows-out",
        help="Atomically publish normalized UTF-8 JSON Lines after valid EOF",
    )
    inspect_parser.add_argument(
        "--manifest-out",
        help="Atomically write the same JSON result emitted on stdout",
    )
    inspect_parser.add_argument(
        "--allow-missing",
        action="store_true",
        help="Report missing required fields instead of returning an error",
    )
    inspect_parser.add_argument(
        "--allow-empty",
        action="store_true",
        help="Allow a valid document with zero matching row elements",
    )
    inspect_parser.add_argument(
        "--pretty",
        action="store_true",
        help="Pretty-print JSON instead of emitting compact JSON",
    )
    inspect_parser.add_argument(
        "--max-row-bytes",
        type=_positive_int,
        default=DEFAULT_XML_LIMITS.max_row_bytes,
        help="Maximum UTF-8 character-data bytes retained for one row",
    )
    inspect_parser.add_argument(
        "--max-values-per-row",
        type=_positive_int,
        default=DEFAULT_XML_LIMITS.max_values_per_row,
        help="Maximum descendant element values in one row",
    )
    inspect_parser.add_argument(
        "--max-fields-per-row",
        type=_positive_int,
        default=DEFAULT_XML_LIMITS.max_fields_per_row,
        help="Maximum distinct expanded field names in one row",
    )
    inspect_parser.add_argument(
        "--max-nesting-depth",
        type=_positive_int,
        default=DEFAULT_XML_LIMITS.max_nesting_depth,
        help="Maximum XML element nesting depth",
    )
    inspect_parser.add_argument(
        "--max-distinct-qnames",
        type=_positive_int,
        default=DEFAULT_XML_LIMITS.max_distinct_qnames,
        help="Maximum distinct expanded element names in the document",
    )
    inspect_parser.add_argument(
        "--max-markup-token-bytes",
        type=_positive_int,
        default=DEFAULT_XML_LIMITS.max_markup_token_bytes,
        help="Maximum bytes in one tag, attribute block, comment, or PI",
    )
    inspect_parser.add_argument(
        "--max-character-data-bytes",
        type=_positive_int,
        default=DEFAULT_XML_LIMITS.max_character_data_bytes,
        help="Maximum bytes in one contiguous XML character-data segment",
    )
    return parser


def _json_text(payload: dict[str, Any], *, pretty: bool) -> str:
    options: dict[str, Any] = {
        "ensure_ascii": False,
        "sort_keys": True,
    }
    if pretty:
        options["indent"] = 2
    else:
        options["separators"] = (",", ":")
    return json.dumps(payload, **options)


def _emit(payload: dict[str, Any], *, pretty: bool, error: bool = False) -> None:
    stream = sys.stderr if error else sys.stdout
    stream.write(_json_text(payload, pretty=pretty) + "\n")


def _error_payload(error: SpoolXmlError) -> dict[str, Any]:
    payload = ErrorEnvelope(
        code=error.code,
        message=str(error),
        error_type=type(error).__name__,
        line=error.line,
        column=error.column,
    ).to_dict()
    if isinstance(error, MissingRequiredFieldsError):
        payload["error"]["manifest"] = error.manifest.to_dict()
    return payload


def _run_inspect(arguments: argparse.Namespace) -> dict[str, Any]:
    limits = XmlLimits(
        max_row_bytes=arguments.max_row_bytes,
        max_values_per_row=arguments.max_values_per_row,
        max_fields_per_row=arguments.max_fields_per_row,
        max_nesting_depth=arguments.max_nesting_depth,
        max_distinct_qnames=arguments.max_distinct_qnames,
        max_markup_token_bytes=arguments.max_markup_token_bytes,
        max_character_data_bytes=arguments.max_character_data_bytes,
    )
    common = {
        "row_qname": arguments.row_qname,
        "required_fields": arguments.required_field,
        "strict_required": not arguments.allow_missing,
        "allow_empty": arguments.allow_empty,
        "limits": limits,
    }
    if arguments.rows_out:
        receipt = normalize_jsonl(
            arguments.source,
            arguments.rows_out,
            **common,
        )
        return {
            "ok": True,
            "operation": "inspect_and_normalize",
            "receipt": receipt.to_dict(),
        }

    manifest = inspect_xml(arguments.source, **common)
    return {
        "ok": True,
        "operation": "inspect",
        "manifest": manifest.to_dict(),
    }


def main(argv: Sequence[str] | None = None) -> int:
    """Run the CLI and return a process exit code."""

    parser = _parser()
    pretty = False
    try:
        arguments = parser.parse_args(argv)
        pretty = bool(getattr(arguments, "pretty", False))
        if arguments.command != "inspect":
            raise _CliUsageError(f"Unsupported command: {arguments.command}")
        payload = _run_inspect(arguments)
        if arguments.manifest_out:
            write_json_transactional(
                payload,
                arguments.manifest_out,
                pretty=pretty,
            )
        _emit(payload, pretty=pretty)
        return 0
    except _CliUsageError as error:
        payload = ErrorEnvelope(
            code="invalid_arguments",
            message="Command arguments are invalid; use --help for the schema",
            error_type=type(error).__name__,
        ).to_dict()
        _emit(payload, pretty=pretty, error=True)
        return 2
    except ValueError as error:
        payload = ErrorEnvelope(
            code="invalid_qname",
            message=str(error),
            error_type=type(error).__name__,
        ).to_dict()
        _emit(payload, pretty=pretty, error=True)
        return 2
    except SpoolXmlError as error:
        _emit(_error_payload(error), pretty=pretty, error=True)
        return error.exit_code


if __name__ == "__main__":  # pragma: no cover - exercised through console script
    raise SystemExit(main())
