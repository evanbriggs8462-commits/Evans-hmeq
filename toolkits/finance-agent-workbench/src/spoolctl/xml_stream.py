"""Safe, streaming inspection and normalization for already-local XML files.

This module intentionally does not copy from network shares, resolve URLs, use
XInclude, or construct a full XML document tree.  A caller must first stage the
source onto reliable local storage.  Security preflight and SHA-256 calculation
are a bounded-memory pass; parsing is a second bounded-memory pass so the exact
bytes parsed can be checked against the receipt.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
import codecs
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any, BinaryIO
from xml.etree import ElementTree as ET

from .contracts import (
    DEFAULT_XML_LIMITS,
    ExpandedQName,
    FieldProfile,
    InspectionManifest,
    NormalizationReceipt,
    SourceReceipt,
    XmlLimits,
)


_READ_CHUNK_BYTES = 1024 * 1024
_URI_SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")
_DECLARED_ENCODING = re.compile(
    br"<\?xml[^>]*\bencoding\s*=\s*['\"]([^'\"]+)['\"]", re.IGNORECASE
)
_FORBIDDEN_XML_MARKERS = tuple(
    marker
    for token in ("<!DOCTYPE", "<!ENTITY")
    for marker in (
        token.encode("ascii"),
        token.encode("utf-16-le"),
        token.encode("utf-16-be"),
        token.encode("utf-32-le"),
        token.encode("utf-32-be"),
    )
)
_FORBIDDEN_OVERLAP = max(len(marker) for marker in _FORBIDDEN_XML_MARKERS) - 1
_WINDOWS_DRIVE_UNKNOWN = 0
_WINDOWS_DRIVE_NO_ROOT_DIR = 1
_WINDOWS_DRIVE_REMOTE = 4


class SpoolXmlError(Exception):
    """Base class for expected, machine-classifiable spoolctl failures."""

    code = "spool_xml_error"
    exit_code = 1

    def __init__(
        self,
        message: str,
        *,
        line: int | None = None,
        column: int | None = None,
    ) -> None:
        super().__init__(message)
        self.line = line
        self.column = column


class SourceValidationError(SpoolXmlError):
    code = "invalid_local_source"
    exit_code = 3


class RemoteSourceRejectedError(SourceValidationError):
    code = "remote_source_rejected"


class SourceReadError(SpoolXmlError):
    code = "source_read_failed"
    exit_code = 3


class UnsafeXmlError(SpoolXmlError):
    code = "unsafe_xml_declaration"
    exit_code = 4


class MalformedXmlError(SpoolXmlError):
    code = "malformed_or_truncated_xml"
    exit_code = 5


class SourceChangedError(SpoolXmlError):
    code = "source_changed_during_inspection"
    exit_code = 5


class XmlLimitError(SpoolXmlError):
    """Base class for deterministic parser resource-limit failures."""

    code = "xml_limit_exceeded"
    exit_code = 8


class RowByteLimitError(XmlLimitError):
    code = "row_byte_limit_exceeded"


class RowValueLimitError(XmlLimitError):
    code = "row_value_limit_exceeded"


class RowFieldLimitError(XmlLimitError):
    code = "row_field_limit_exceeded"


class NestingDepthLimitError(XmlLimitError):
    code = "nesting_depth_limit_exceeded"


class DistinctQNameLimitError(XmlLimitError):
    code = "distinct_qname_limit_exceeded"


class MarkupTokenLimitError(XmlLimitError):
    code = "markup_token_limit_exceeded"


class CharacterDataLimitError(XmlLimitError):
    code = "character_data_limit_exceeded"


class NoRowsFoundError(SpoolXmlError):
    code = "row_tag_not_found"
    exit_code = 6


class MissingRequiredFieldsError(SpoolXmlError):
    code = "missing_required_fields"
    exit_code = 6

    def __init__(self, manifest: InspectionManifest) -> None:
        missing = ", ".join(
            f"{name} ({count} row{'s' if count != 1 else ''})"
            for name, count in manifest.missing_required_counts
            if count
        )
        super().__init__(f"Required XML fields are missing or empty: {missing}")
        self.manifest = manifest


class OutputValidationError(SpoolXmlError):
    code = "invalid_local_output"
    exit_code = 7


class OutputCommitError(SpoolXmlError):
    code = "output_commit_failed"
    exit_code = 7


@dataclass(frozen=True, slots=True)
class _FileIdentity:
    size: int
    modified_ns: int
    device: int
    inode: int

    @classmethod
    def from_stat(cls, stat_result: os.stat_result) -> "_FileIdentity":
        return cls(
            size=stat_result.st_size,
            modified_ns=stat_result.st_mtime_ns,
            device=stat_result.st_dev,
            inode=stat_result.st_ino,
        )


class _RawLexicalGuard:
    """Bound XML tokens and text segments before bytes reach Expat."""

    _SPECIAL_PREFIXES = ("<?", "<!--", "<![CDATA[")

    def __init__(self, encoding: str, limits: XmlLimits) -> None:
        try:
            decoder_type = codecs.getincrementaldecoder(encoding)
        except LookupError as error:
            raise MalformedXmlError("The declared XML encoding is unsupported") from error
        self._decoder = decoder_type(errors="strict")
        normalized = encoding.lower().replace("_", "-")
        self._measure_encoding = "utf-8" if normalized == "utf-8-sig" else encoding
        self._limits = limits
        self._mode = "text"
        self._quote: str | None = None
        self._prefix = ""
        self._carry = ""
        self._markup_bytes = 0
        self._text_bytes = 0

    def _byte_length(self, value: str) -> int:
        try:
            return len(value.encode(self._measure_encoding))
        except (LookupError, UnicodeError) as error:
            raise MalformedXmlError("The XML encoding is invalid") from error

    def _add_markup(self, value: str) -> None:
        self._markup_bytes += self._byte_length(value)
        if self._markup_bytes > self._limits.max_markup_token_bytes:
            raise MarkupTokenLimitError(
                "An XML markup token exceeded the configured safety limit"
            )

    def _add_text(self, value: str) -> None:
        self._text_bytes += self._byte_length(value)
        if self._text_bytes > self._limits.max_character_data_bytes:
            raise CharacterDataLimitError(
                "An XML character-data segment exceeded the configured safety limit"
            )

    def feed(self, block: bytes) -> None:
        try:
            decoded = self._decoder.decode(block, final=False)
        except UnicodeError as error:
            raise MalformedXmlError("The XML byte encoding is invalid") from error
        self._carry = self._process(self._carry + decoded, final=False)

    def finish(self) -> None:
        try:
            decoded = self._decoder.decode(b"", final=True)
        except UnicodeError as error:
            raise MalformedXmlError("The XML byte encoding is incomplete") from error
        remainder = self._process(self._carry + decoded, final=True)
        if remainder:
            if self._mode == "text":
                self._add_text(remainder)
            else:
                self._add_markup(remainder)
        self._carry = ""

    def _process(self, data: str, *, final: bool) -> str:
        index = 0
        while index < len(data):
            if self._mode == "text":
                marker = data.find("<", index)
                if marker < 0:
                    self._add_text(data[index:])
                    return ""
                self._add_text(data[index:marker])
                self._text_bytes = 0
                self._mode = "pending"
                self._prefix = "<"
                self._markup_bytes = 0
                self._add_markup("<")
                index = marker + 1
                continue

            if self._mode == "pending":
                self._prefix += data[index]
                self._add_markup(data[index])
                index += 1
                if self._prefix == "<?":
                    self._mode = "pi"
                elif self._prefix == "<!--":
                    self._mode = "comment"
                elif self._prefix == "<![CDATA[":
                    self._mode = "cdata"
                    self._text_bytes = 0
                elif not any(
                    special.startswith(self._prefix)
                    for special in self._SPECIAL_PREFIXES
                ):
                    self._mode = "tag"
                continue

            if self._mode == "tag":
                candidates = [
                    (position, token)
                    for token in ('"', "'", ">")
                    if (position := data.find(token, index)) >= 0
                ]
                if not candidates:
                    self._add_markup(data[index:])
                    return ""
                position, token = min(candidates)
                self._add_markup(data[index : position + 1])
                index = position + 1
                if token == ">":
                    self._mode = "text"
                    self._markup_bytes = 0
                    self._text_bytes = 0
                else:
                    self._mode = "tag_quote"
                    self._quote = token
                continue

            if self._mode == "tag_quote":
                assert self._quote is not None
                position = data.find(self._quote, index)
                if position < 0:
                    self._add_markup(data[index:])
                    return ""
                self._add_markup(data[index : position + 1])
                index = position + 1
                self._mode = "tag"
                self._quote = None
                continue

            terminator = {
                "comment": "-->",
                "pi": "?>",
                "cdata": "]]>",
            }[self._mode]
            position = data.find(terminator, index)
            if position < 0:
                keep = 0 if final else len(terminator) - 1
                safe_end = max(index, len(data) - keep)
                segment = data[index:safe_end]
                if self._mode == "cdata":
                    self._add_text(segment)
                else:
                    self._add_markup(segment)
                return data[safe_end:]

            segment = data[index:position]
            if self._mode == "cdata":
                self._add_text(segment)
                self._markup_bytes = 0
                self._add_markup(terminator)
            else:
                self._add_markup(segment + terminator)
            index = position + len(terminator)
            self._mode = "text"
            self._markup_bytes = 0
            self._text_bytes = 0
        return ""


def _looks_remote(value: str) -> bool:
    stripped = value.strip()
    return (
        stripped.startswith("\\\\")
        or stripped.startswith("//")
        or _URI_SCHEME.match(stripped) is not None
    )


def _basename_fingerprint(path: Path) -> str:
    digest = hashlib.sha256(path.name.encode("utf-8", errors="surrogatepass"))
    return f"name-sha256:{digest.hexdigest()[:16]}"


def _windows_drive_type(path: Path) -> int | None:
    """Return ``GetDriveTypeW`` for Windows paths; return ``None`` elsewhere."""

    if os.name != "nt":
        return None
    import ctypes

    root = path.anchor
    if not root:
        return _WINDOWS_DRIVE_NO_ROOT_DIR
    get_drive_type = ctypes.windll.kernel32.GetDriveTypeW
    get_drive_type.argtypes = [ctypes.c_wchar_p]
    get_drive_type.restype = ctypes.c_uint
    return int(get_drive_type(root))


def _reject_remote_source_drive(path: Path) -> None:
    drive_type = _windows_drive_type(path)
    if drive_type == _WINDOWS_DRIVE_REMOTE:
        raise RemoteSourceRejectedError(
            "Mapped network drives are rejected; stage the XML on a local drive first"
        )
    if drive_type in {_WINDOWS_DRIVE_UNKNOWN, _WINDOWS_DRIVE_NO_ROOT_DIR}:
        raise SourceValidationError(
            "Could not verify that the Windows XML source is on a local drive"
        )


def _reject_remote_output_drive(path: Path) -> None:
    drive_type = _windows_drive_type(path)
    if drive_type == _WINDOWS_DRIVE_REMOTE:
        raise OutputValidationError(
            "Mapped network-drive outputs are rejected; publish from local storage"
        )
    if drive_type in {_WINDOWS_DRIVE_UNKNOWN, _WINDOWS_DRIVE_NO_ROOT_DIR}:
        raise OutputValidationError(
            "Could not verify that the Windows output is on a local drive"
        )


def _local_source_path(source: str | os.PathLike[str]) -> Path:
    raw = os.fspath(source)
    if not raw:
        raise SourceValidationError("The XML source path is empty")
    if _looks_remote(raw):
        raise RemoteSourceRejectedError(
            "Network, UNC, and URI sources are rejected; stage the XML locally first"
        )
    # Probe a drive-letter path before resolve/stat/open can touch a mapped share.
    _reject_remote_source_drive(Path(os.path.abspath(raw)))
    try:
        path = Path(raw).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise SourceValidationError("The local XML source is unavailable") from error
    if not path.is_file():
        raise SourceValidationError(
            "The local XML source is not a regular file"
        )
    _reject_remote_source_drive(path)
    return path


def _local_output_path(destination: str | os.PathLike[str]) -> Path:
    raw = os.fspath(destination)
    if not raw:
        raise OutputValidationError("The output path is empty")
    if _looks_remote(raw):
        raise OutputValidationError(
            "Network, UNC, and URI outputs are rejected; write locally before publishing"
        )
    # Probe a drive-letter path before resolving its parent can touch a share.
    _reject_remote_output_drive(Path(os.path.abspath(raw)))
    candidate = Path(raw)
    try:
        parent = candidate.parent.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise OutputValidationError(
            "The local output directory is unavailable"
        ) from error
    if not parent.is_dir():
        raise OutputValidationError(
            "The local output parent is not a directory"
        )
    output = parent / candidate.name
    _reject_remote_output_drive(output)
    if output.exists() and output.is_dir():
        raise OutputValidationError("The output path is a directory")
    if output.is_symlink():
        raise OutputValidationError("Symbolic-link outputs are rejected")
    return output


def _detect_encoding(prefix: bytes) -> str | None:
    if prefix.startswith(codecs.BOM_UTF8):
        return "utf-8-sig"
    # UTF-32 BOMs begin with a UTF-16 BOM prefix; test the longer marks first.
    if prefix.startswith(codecs.BOM_UTF32_LE):
        return "utf-32-le"
    if prefix.startswith(codecs.BOM_UTF32_BE):
        return "utf-32-be"
    if prefix.startswith(codecs.BOM_UTF16_LE):
        return "utf-16-le"
    if prefix.startswith(codecs.BOM_UTF16_BE):
        return "utf-16-be"

    match = _DECLARED_ENCODING.search(prefix[:1024])
    if match is not None:
        try:
            return match.group(1).decode("ascii").lower()
        except UnicodeDecodeError:
            return None
    if prefix.startswith(b"\x00<\x00?"):
        return "utf-16-be"
    if prefix.startswith(b"<\x00?\x00"):
        return "utf-16-le"
    if prefix.startswith(b"\x00\x00\x00<"):
        return "utf-32-be"
    if prefix.startswith(b"<\x00\x00\x00"):
        return "utf-32-le"
    return None


def _security_scan(overlap: bytes, block: bytes) -> bytes:
    security_window = (overlap + block).upper()
    if any(marker in security_window for marker in _FORBIDDEN_XML_MARKERS):
        raise UnsafeXmlError("DTD and ENTITY declarations are not allowed in spool XML")
    return security_window[-_FORBIDDEN_OVERLAP:]


def _scan_and_hash(
    stream: BinaryIO,
    source_name: str,
    limits: XmlLimits = DEFAULT_XML_LIMITS,
) -> SourceReceipt:
    """Hash and reject DTD/entity declarations before ElementTree is invoked."""

    sha256 = hashlib.sha256()
    byte_count = 0
    overlap = b""
    prefix = b""
    detected_encoding: str | None = None
    lexical_guard: _RawLexicalGuard | None = None

    while True:
        try:
            block = stream.read(_READ_CHUNK_BYTES)
        except OSError as error:
            raise SourceReadError("Failed while reading the local XML source") from error
        if not block:
            break
        if not prefix:
            prefix = block[:1024]
            detected_encoding = _detect_encoding(prefix)
            lexical_guard = _RawLexicalGuard(
                detected_encoding or "utf-8",
                limits,
            )
        sha256.update(block)
        byte_count += len(block)
        overlap = _security_scan(overlap, block)
        assert lexical_guard is not None
        lexical_guard.feed(block)

    if lexical_guard is None:
        lexical_guard = _RawLexicalGuard("utf-8", limits)
    lexical_guard.finish()

    return SourceReceipt(
        source_name=source_name,
        byte_count=byte_count,
        sha256=sha256.hexdigest(),
        detected_encoding=detected_encoding,
    )


def _coerce_qname(value: str | ExpandedQName) -> ExpandedQName:
    if isinstance(value, ExpandedQName):
        return value
    return ExpandedQName.from_expanded(value)


def _coerce_required_fields(
    values: Iterable[str | ExpandedQName],
) -> tuple[ExpandedQName, ...]:
    unique: dict[str, ExpandedQName] = {}
    for value in values:
        qname = _coerce_qname(value)
        unique.setdefault(qname.expanded, qname)
    return tuple(unique.values())


def _build_manifest(
    *,
    source: SourceReceipt,
    root_name: str,
    row_qname: ExpandedQName,
    row_count: int,
    required_fields: tuple[ExpandedQName, ...],
    missing_required: Mapping[str, int],
    occurrences: Mapping[str, int],
    non_empty: Mapping[str, int],
    limits: XmlLimits,
) -> InspectionManifest:
    field_names = sorted(occurrences)
    return InspectionManifest(
        source=source,
        root_qname=ExpandedQName.from_expanded(root_name),
        row_qname=row_qname,
        row_count=row_count,
        required_fields=required_fields,
        missing_required_counts=tuple(
            (field.expanded, missing_required.get(field.expanded, 0))
            for field in required_fields
        ),
        fields=tuple(
            FieldProfile(
                qname=ExpandedQName.from_expanded(name),
                occurrence_count=occurrences[name],
                non_empty_count=non_empty.get(name, 0),
            )
            for name in field_names
        ),
        limits=limits,
    )


@dataclass(slots=True)
class _ElementFrame:
    qname: str
    is_row_root: bool
    text_chunks: list[str] | None
    accepts_direct_text: bool = True


class _StreamingXmlTarget:
    """XMLParser target that never creates or retains Element objects."""

    def __init__(
        self,
        *,
        row_qname: ExpandedQName,
        required_fields: tuple[ExpandedQName, ...],
        on_row: Callable[[int, Mapping[str, Sequence[str]]], None] | None,
        limits: XmlLimits,
    ) -> None:
        self.row_qname = row_qname
        self.required_fields = required_fields
        self.on_row = on_row
        self.limits = limits
        self.stack: list[_ElementFrame] = []
        self.current_fields: dict[str, list[str]] | None = None
        self.current_text_bytes = 0
        self.current_value_count = 0
        self.root_name: str | None = None
        self.row_count = 0
        self.occurrences: Counter[str] = Counter()
        self.non_empty: Counter[str] = Counter()
        self.missing_required: Counter[str] = Counter()
        self.distinct_qnames: set[str] = set()

    def start(self, tag: str, attributes: Mapping[str, str]) -> None:
        del attributes  # Expat owns this bounded mapping only for the callback.
        if self.root_name is None:
            self.root_name = tag
        self.distinct_qnames.add(tag)
        if len(self.distinct_qnames) > self.limits.max_distinct_qnames:
            raise DistinctQNameLimitError(
                "XML distinct names exceeded the configured safety limit"
            )

        starts_row = self.current_fields is None and tag == self.row_qname.expanded
        if starts_row:
            self.current_fields = defaultdict(list)
            self.current_text_bytes = 0
            self.current_value_count = 0
        elif self.current_fields is not None and self.stack:
            # ElementTree's Element.text excludes tail text after the first
            # child. Preserve that prior normalization contract.
            self.stack[-1].accepts_direct_text = False
        collect_text = self.current_fields is not None
        self.stack.append(
            _ElementFrame(
                qname=tag,
                is_row_root=starts_row,
                text_chunks=[] if collect_text else None,
            )
        )
        if len(self.stack) > self.limits.max_nesting_depth:
            raise NestingDepthLimitError(
                "XML nesting exceeded the configured safety limit"
            )

    def data(self, value: str) -> None:
        if self.current_fields is None or not self.stack or not value:
            return
        self.current_text_bytes += len(value.encode("utf-8"))
        if self.current_text_bytes > self.limits.max_row_bytes:
            raise RowByteLimitError(
                "A row exceeded the configured byte/text safety limit"
            )
        chunks = self.stack[-1].text_chunks
        assert chunks is not None
        if self.stack[-1].accepts_direct_text:
            chunks.append(value)

    def end(self, tag: str) -> None:
        if not self.stack:
            raise MalformedXmlError("The XML element stack is inconsistent")
        frame = self.stack.pop()
        if frame.qname != tag:
            raise MalformedXmlError("The XML element stack is inconsistent")

        if self.current_fields is None:
            return
        if frame.is_row_root:
            self._finish_row()
            return

        self.current_value_count += 1
        if self.current_value_count > self.limits.max_values_per_row:
            raise RowValueLimitError(
                "A row exceeded the configured value-count safety limit"
            )
        if (
            frame.qname not in self.current_fields
            and len(self.current_fields) >= self.limits.max_fields_per_row
        ):
            raise RowFieldLimitError(
                "A row exceeded the configured field-count safety limit"
            )
        value = "".join(frame.text_chunks or ()).strip()
        self.occurrences[frame.qname] += 1
        if value:
            self.non_empty[frame.qname] += 1
        self.current_fields[frame.qname].append(value)

    def _finish_row(self) -> None:
        assert self.current_fields is not None
        self.row_count += 1
        for required in self.required_fields:
            values = self.current_fields.get(required.expanded, ())
            if not any(value.strip() for value in values):
                self.missing_required[required.expanded] += 1
        if self.on_row is not None:
            self.on_row(self.row_count, self.current_fields)
        self.current_fields = None
        self.current_text_bytes = 0
        self.current_value_count = 0

    def comment(self, text: str) -> None:
        del text

    def pi(self, target: str, text: str | None) -> None:
        del target, text

    def doctype(
        self,
        name: str,
        public_id: str | None,
        system_id: str | None,
    ) -> None:
        del name, public_id, system_id
        raise UnsafeXmlError("DTD and ENTITY declarations are not allowed in spool XML")

    def close(self) -> None:
        if self.stack or self.current_fields is not None:
            raise MalformedXmlError("The XML ended with incomplete elements")


def _parse_open_stream(
    stream: BinaryIO,
    *,
    receipt: SourceReceipt,
    row_qname: ExpandedQName,
    required_fields: tuple[ExpandedQName, ...],
    on_row: Callable[[int, Mapping[str, Sequence[str]]], None] | None,
    strict_required: bool,
    allow_empty: bool,
    limits: XmlLimits,
) -> InspectionManifest:
    """Parse callbacks to strict EOF without constructing an Element tree."""

    target = _StreamingXmlTarget(
        row_qname=row_qname,
        required_fields=required_fields,
        on_row=on_row,
        limits=limits,
    )
    parser = ET.XMLParser(target=target)
    raw_sha256 = hashlib.sha256()
    raw_byte_count = 0
    overlap = b""
    lexical_guard: _RawLexicalGuard | None = None
    decoder: Any = None
    first_decoded = True

    try:
        while True:
            block = stream.read(_READ_CHUNK_BYTES)
            if not block:
                break
            if lexical_guard is None:
                encoding = _detect_encoding(block[:1024]) or "utf-8"
                lexical_guard = _RawLexicalGuard(encoding, limits)
                if encoding.lower().replace("_", "-").startswith("utf-32"):
                    try:
                        decoder = codecs.getincrementaldecoder(encoding)(
                            errors="strict"
                        )
                    except LookupError as error:
                        raise MalformedXmlError(
                            "The declared XML encoding is unsupported"
                        ) from error

            overlap = _security_scan(overlap, block)
            lexical_guard.feed(block)
            raw_sha256.update(block)
            raw_byte_count += len(block)
            if decoder is None:
                parser.feed(block)
            else:
                try:
                    decoded = decoder.decode(block, final=False)
                except UnicodeError as error:
                    raise MalformedXmlError(
                        "The XML byte encoding is invalid"
                    ) from error
                if first_decoded:
                    decoded = decoded.lstrip("\ufeff")
                    first_decoded = False
                parser.feed(decoded)

        if lexical_guard is None:
            lexical_guard = _RawLexicalGuard("utf-8", limits)
        lexical_guard.finish()
        if decoder is not None:
            try:
                decoded = decoder.decode(b"", final=True)
            except UnicodeError as error:
                raise MalformedXmlError(
                    "The XML byte encoding is incomplete"
                ) from error
            if decoded:
                parser.feed(decoded)
        parser.close()
    except ET.ParseError as error:
        line: int | None = None
        column: int | None = None
        if getattr(error, "position", None):
            line, column = error.position
        raise MalformedXmlError(
            "The XML is malformed or truncated before a valid end of file",
            line=line,
            column=column,
        ) from error

    if target.root_name is None:
        raise MalformedXmlError("The XML is empty and has no document element")
    if raw_byte_count != receipt.byte_count or raw_sha256.hexdigest() != receipt.sha256:
        raise SourceChangedError(
            "The XML bytes changed between security preflight and parsing"
        )
    if target.row_count == 0 and not allow_empty:
        raise NoRowsFoundError(
            f"No row elements matched the expanded name {row_qname.expanded!r}"
        )

    manifest = _build_manifest(
        source=receipt,
        root_name=target.root_name,
        row_qname=row_qname,
        row_count=target.row_count,
        required_fields=required_fields,
        missing_required=target.missing_required,
        occurrences=target.occurrences,
        non_empty=target.non_empty,
        limits=limits,
    )
    if strict_required and manifest.has_missing_required_fields:
        raise MissingRequiredFieldsError(manifest)
    return manifest


def _inspect_with_staged_sink(
    source: str | os.PathLike[str],
    *,
    row_qname: str | ExpandedQName,
    required_fields: Iterable[str | ExpandedQName],
    on_row: Callable[[int, Mapping[str, Sequence[str]]], None] | None,
    strict_required: bool,
    allow_empty: bool,
    limits: XmlLimits,
) -> InspectionManifest:
    source_path = _local_source_path(source)
    row_name = _coerce_qname(row_qname)
    requirements = _coerce_required_fields(required_fields)

    try:
        with source_path.open("rb") as stream:
            before = _FileIdentity.from_stat(os.fstat(stream.fileno()))
            receipt = _scan_and_hash(
                stream,
                _basename_fingerprint(source_path),
                limits,
            )
            stream.seek(0)
            manifest = _parse_open_stream(
                stream,
                receipt=receipt,
                row_qname=row_name,
                required_fields=requirements,
                on_row=on_row,
                strict_required=strict_required,
                allow_empty=allow_empty,
                limits=limits,
            )
            after = _FileIdentity.from_stat(os.fstat(stream.fileno()))
    except SpoolXmlError:
        raise
    except OSError as error:
        raise SourceReadError("Failed while reading the local XML source") from error

    if before != after:
        raise SourceChangedError("The local XML file changed while it was inspected")
    return manifest


def inspect_xml(
    source: str | os.PathLike[str],
    *,
    row_qname: str | ExpandedQName,
    required_fields: Iterable[str | ExpandedQName] = (),
    strict_required: bool = True,
    allow_empty: bool = False,
    limits: XmlLimits = DEFAULT_XML_LIMITS,
) -> InspectionManifest:
    """Inspect a local XML file and return a manifest only after valid EOF.

    ``row_qname`` and every required field must use expanded/Clark notation for
    namespaced XML, for example ``"{urn:example:spool}row"``.  A bare name
    intentionally matches only an unqualified element.
    """

    return _inspect_with_staged_sink(
        source,
        row_qname=row_qname,
        required_fields=required_fields,
        on_row=None,
        strict_required=strict_required,
        allow_empty=allow_empty,
        limits=limits,
    )


def normalize_jsonl(
    source: str | os.PathLike[str],
    destination: str | os.PathLike[str],
    *,
    row_qname: str | ExpandedQName,
    required_fields: Iterable[str | ExpandedQName] = (),
    strict_required: bool = True,
    allow_empty: bool = False,
    limits: XmlLimits = DEFAULT_XML_LIMITS,
) -> NormalizationReceipt:
    """Normalize rows to JSON Lines and atomically publish after valid EOF.

    Each line has ``row_number`` plus a ``fields`` mapping.  Field keys are
    expanded XML names and values are arrays so duplicate elements are retained
    without silently overwriting data.  The temporary file lives beside the
    destination; any parse, schema, or commit failure removes it and leaves an
    existing destination untouched.
    """

    source_path = _local_source_path(source)
    output_path = _local_output_path(destination)
    if source_path == output_path:
        raise OutputValidationError("The normalized output cannot replace its source")

    temporary_path: Path | None = None
    output_sha256 = hashlib.sha256()
    output_byte_count = 0

    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{output_path.name}.",
            suffix=".tmp",
            dir=output_path.parent,
        )
        temporary_path = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as output_stream:

            def write_row(
                row_number: int, fields: Mapping[str, Sequence[str]]
            ) -> None:
                nonlocal output_byte_count
                record = {
                    "row_number": row_number,
                    "fields": {
                        name: list(fields[name]) for name in sorted(fields)
                    },
                }
                encoded = (
                    json.dumps(
                        record,
                        ensure_ascii=False,
                        separators=(",", ":"),
                        sort_keys=True,
                    )
                    + "\n"
                ).encode("utf-8")
                try:
                    output_stream.write(encoded)
                except OSError as error:
                    raise OutputCommitError(
                        "Failed while writing the staged normalized output"
                    ) from error
                output_sha256.update(encoded)
                output_byte_count += len(encoded)

            manifest = _inspect_with_staged_sink(
                source_path,
                row_qname=row_qname,
                required_fields=required_fields,
                on_row=write_row,
                strict_required=strict_required,
                allow_empty=allow_empty,
                limits=limits,
            )
            output_stream.flush()
            os.fsync(output_stream.fileno())

        os.replace(temporary_path, output_path)
        temporary_path = None
    except SpoolXmlError:
        raise
    except OSError as error:
        raise OutputCommitError(
            "Could not atomically commit the normalized output"
        ) from error
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink(missing_ok=True)
            except OSError:
                pass

    return NormalizationReceipt(
        manifest=manifest,
        output_name=_basename_fingerprint(output_path),
        output_byte_count=output_byte_count,
        output_sha256=output_sha256.hexdigest(),
    )


def write_json_transactional(
    payload: Mapping[str, Any],
    destination: str | os.PathLike[str],
    *,
    pretty: bool = False,
) -> None:
    """Atomically write a JSON receipt/manifest to a local destination."""

    output_path = _local_output_path(destination)
    options: dict[str, Any] = {
        "ensure_ascii": False,
        "sort_keys": True,
    }
    if pretty:
        options["indent"] = 2
    else:
        options["separators"] = (",", ":")
    encoded = (json.dumps(dict(payload), **options) + "\n").encode("utf-8")

    temporary_path: Path | None = None
    try:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{output_path.name}.",
            suffix=".tmp",
            dir=output_path.parent,
        )
        temporary_path = Path(temporary_name)
        with os.fdopen(descriptor, "wb") as output_stream:
            output_stream.write(encoded)
            output_stream.flush()
            os.fsync(output_stream.fileno())
        os.replace(temporary_path, output_path)
        temporary_path = None
    except OSError as error:
        raise OutputCommitError(
            "Could not atomically commit the JSON output"
        ) from error
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink(missing_ok=True)
            except OSError:
                pass
