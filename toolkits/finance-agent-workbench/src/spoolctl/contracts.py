"""Stable, JSON-friendly contracts for :mod:`spoolctl`.

The contracts deliberately contain no company-specific field names.  XML names
use the ElementTree/Clark expanded-name form (``{namespace-uri}local-name``),
which prevents two namespaces with the same local name from being conflated.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any, Literal


DEFAULT_MAX_ROW_BYTES = 8 * 1024 * 1024
DEFAULT_MAX_VALUES_PER_ROW = 10_000
DEFAULT_MAX_FIELDS_PER_ROW = 2_048
DEFAULT_MAX_NESTING_DEPTH = 256
DEFAULT_MAX_DISTINCT_QNAMES = 4_096
DEFAULT_MAX_MARKUP_TOKEN_BYTES = 1024 * 1024
DEFAULT_MAX_CHARACTER_DATA_BYTES = 8 * 1024 * 1024


@dataclass(frozen=True, slots=True)
class XmlLimits:
    """Hard parser limits; every value is configurable but never unbounded."""

    max_row_bytes: int = DEFAULT_MAX_ROW_BYTES
    max_values_per_row: int = DEFAULT_MAX_VALUES_PER_ROW
    max_fields_per_row: int = DEFAULT_MAX_FIELDS_PER_ROW
    max_nesting_depth: int = DEFAULT_MAX_NESTING_DEPTH
    max_distinct_qnames: int = DEFAULT_MAX_DISTINCT_QNAMES
    max_markup_token_bytes: int = DEFAULT_MAX_MARKUP_TOKEN_BYTES
    max_character_data_bytes: int = DEFAULT_MAX_CHARACTER_DATA_BYTES

    def __post_init__(self) -> None:
        for field_name in (
            "max_row_bytes",
            "max_values_per_row",
            "max_fields_per_row",
            "max_nesting_depth",
            "max_distinct_qnames",
            "max_markup_token_bytes",
            "max_character_data_bytes",
        ):
            if getattr(self, field_name) <= 0:
                raise ValueError(f"{field_name} must be a positive integer")

    def to_dict(self) -> dict[str, int]:
        return asdict(self)


DEFAULT_XML_LIMITS = XmlLimits()


@dataclass(frozen=True, slots=True)
class ExpandedQName:
    """An XML qualified name split into namespace URI and local name."""

    namespace_uri: str | None
    local_name: str

    def __post_init__(self) -> None:
        if not self.local_name or self.local_name.strip() != self.local_name:
            raise ValueError("XML local names must be non-empty and unpadded")
        if any(character in self.local_name for character in "{}"):
            raise ValueError("XML local names cannot contain braces")
        if self.namespace_uri == "":
            object.__setattr__(self, "namespace_uri", None)

    @classmethod
    def from_expanded(cls, value: str) -> "ExpandedQName":
        """Parse ElementTree's ``{uri}local`` notation or an unqualified name."""

        if not isinstance(value, str) or not value:
            raise ValueError("An XML name must be a non-empty string")
        if value.startswith("{"):
            closing_brace = value.find("}")
            if closing_brace <= 1 or closing_brace == len(value) - 1:
                raise ValueError(
                    "Namespaced XML names must use '{namespace-uri}local-name'"
                )
            return cls(value[1:closing_brace], value[closing_brace + 1 :])
        if "{" in value or "}" in value:
            raise ValueError(
                "Namespaced XML names must use '{namespace-uri}local-name'"
            )
        return cls(None, value)

    @property
    def expanded(self) -> str:
        """Return ElementTree's namespace-aware expanded-name representation."""

        if self.namespace_uri is None:
            return self.local_name
        return f"{{{self.namespace_uri}}}{self.local_name}"

    def to_dict(self) -> dict[str, str | None]:
        return {
            "expanded": self.expanded,
            "namespace_uri": self.namespace_uri,
            "local_name": self.local_name,
        }


@dataclass(frozen=True, slots=True)
class SourceReceipt:
    """Identity and integrity evidence for the exact local bytes inspected."""

    source_name: str
    byte_count: int
    sha256: str
    detected_encoding: str | None = None

    def __post_init__(self) -> None:
        if self.byte_count < 0:
            raise ValueError("byte_count cannot be negative")
        if len(self.sha256) != 64 or any(
            character not in "0123456789abcdef" for character in self.sha256
        ):
            raise ValueError("sha256 must be a lowercase 64-character hex digest")

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True, slots=True)
class FieldProfile:
    """Occurrence statistics for one expanded XML name inside row elements."""

    qname: ExpandedQName
    occurrence_count: int
    non_empty_count: int

    def __post_init__(self) -> None:
        if self.occurrence_count < 0 or self.non_empty_count < 0:
            raise ValueError("field counts cannot be negative")
        if self.non_empty_count > self.occurrence_count:
            raise ValueError("non_empty_count cannot exceed occurrence_count")

    def to_dict(self) -> dict[str, Any]:
        return {
            "qname": self.qname.to_dict(),
            "occurrence_count": self.occurrence_count,
            "non_empty_count": self.non_empty_count,
        }


@dataclass(frozen=True, slots=True)
class InspectionManifest:
    """Result returned only after the XML parser has reached a valid EOF."""

    source: SourceReceipt
    root_qname: ExpandedQName
    row_qname: ExpandedQName
    row_count: int
    required_fields: tuple[ExpandedQName, ...]
    missing_required_counts: tuple[tuple[str, int], ...]
    fields: tuple[FieldProfile, ...]
    limits: XmlLimits = DEFAULT_XML_LIMITS
    completed_eof: Literal[True] = True
    format_version: Literal["1"] = "1"

    def __post_init__(self) -> None:
        if self.row_count < 0:
            raise ValueError("row_count cannot be negative")
        for name, count in self.missing_required_counts:
            ExpandedQName.from_expanded(name)
            if count < 0 or count > self.row_count:
                raise ValueError("missing required counts must be within row_count")

    @property
    def has_missing_required_fields(self) -> bool:
        return any(count > 0 for _, count in self.missing_required_counts)

    def to_dict(self) -> dict[str, Any]:
        return {
            "format_version": self.format_version,
            "completed_eof": self.completed_eof,
            "source": self.source.to_dict(),
            "root_qname": self.root_qname.to_dict(),
            "row_qname": self.row_qname.to_dict(),
            "row_count": self.row_count,
            "required_fields": [field.to_dict() for field in self.required_fields],
            "missing_required_counts": dict(self.missing_required_counts),
            "fields": [field.to_dict() for field in self.fields],
            "limits": self.limits.to_dict(),
        }


@dataclass(frozen=True, slots=True)
class NormalizationReceipt:
    """Evidence for an atomically committed normalized JSON Lines file."""

    manifest: InspectionManifest
    output_name: str
    output_byte_count: int
    output_sha256: str
    committed: Literal[True] = True

    def __post_init__(self) -> None:
        if self.output_byte_count < 0:
            raise ValueError("output_byte_count cannot be negative")
        if len(self.output_sha256) != 64 or any(
            character not in "0123456789abcdef" for character in self.output_sha256
        ):
            raise ValueError(
                "output_sha256 must be a lowercase 64-character hex digest"
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "committed": self.committed,
            "output_name": self.output_name,
            "output_byte_count": self.output_byte_count,
            "output_sha256": self.output_sha256,
            "manifest": self.manifest.to_dict(),
        }


@dataclass(frozen=True, slots=True)
class ErrorEnvelope:
    """Machine-readable CLI error response."""

    code: str
    message: str
    error_type: str
    line: int | None = None
    column: int | None = None

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "ok": False,
            "error": {
                "code": self.code,
                "type": self.error_type,
                "message": self.message,
            },
        }
        if self.line is not None:
            payload["error"]["line"] = self.line
        if self.column is not None:
            payload["error"]["column"] = self.column
        return payload
