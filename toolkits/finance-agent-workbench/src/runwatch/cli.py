"""Run a child command with sanitized elapsed-time heartbeats.

Runwatch is an attached liveness observer, not a durable scheduler. A hard
parent-host termination can stop this wrapper without a final status update and
may also stop the child. A fresh heartbeat proves only that the supervisor
observed the direct child had not exited at that instant.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time
from typing import NoReturn, Sequence
import uuid


SCHEMA_VERSION = 1
WRAPPER_FAILURE_EXIT = 125
INTERRUPTED_EXIT = 130
DEFAULT_HEARTBEAT_SECONDS = 15.0
MIN_INTERVAL_SECONDS = 0.1
MAX_INTERVAL_SECONDS = 3600.0
DEFAULT_CANCEL_GRACE_SECONDS = 5.0
_LABEL_PATTERN = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$")
_FILE_ATTRIBUTE_REPARSE_POINT = 0x400
_WINDOWS_DRIVE_FIXED = 3


class _CliUsageError(Exception):
    pass


class _StatusPathError(Exception):
    pass


class _StatusWriteError(Exception):
    pass


class _JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise _CliUsageError(message)


class _AtomicStatusWriter:
    def __init__(self, path: Path | None, run_id: str) -> None:
        self._path = path
        self._run_id = run_id
        self._lock_path = (
            path.with_name(f".{path.name}.lock") if path is not None else None
        )
        self._lock_descriptor: int | None = None

    def acquire(self) -> None:
        if self._lock_path is None or self._path is None:
            return
        try:
            _validate_status_storage(self._path)
        except _StatusPathError as error:
            raise _StatusWriteError(
                "The sanitized status storage boundary could not be revalidated."
            ) from error
        if os.path.lexists(self._path):
            raise _StatusWriteError(
                "The sanitized status target is already owned by another run."
            )
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_NOFOLLOW", 0)
        descriptor: int | None = None
        try:
            descriptor = os.open(self._lock_path, flags, 0o600)
            lock_stat = os.fstat(descriptor)
            if not stat.S_ISREG(lock_stat.st_mode):
                raise OSError("status ownership marker is not a regular file")
            os.write(descriptor, (self._run_id + "\n").encode("ascii"))
            os.fsync(descriptor)
            self._lock_descriptor = descriptor
        except OSError as error:
            try:
                if descriptor is not None:
                    os.close(descriptor)
            except OSError:
                pass
            raise _StatusWriteError(
                "Exclusive ownership of the sanitized status target could not "
                "be established."
            ) from error

    def write(self, payload: dict[str, object]) -> None:
        if self._path is None:
            return
        if self._lock_descriptor is None:
            raise _StatusWriteError(
                "Exclusive ownership of the sanitized status target is missing."
            )
        try:
            _validate_status_storage(self._path)
        except _StatusPathError as error:
            raise _StatusWriteError(
                "The sanitized status storage boundary could not be revalidated."
            ) from error

        encoded = (
            json.dumps(
                payload,
                ensure_ascii=True,
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        ).encode("utf-8")
        temporary: Path | None = None
        descriptor: int | None = None
        try:
            for _ in range(16):
                candidate = self._path.with_name(
                    f".{self._path.name}.{uuid.uuid4().hex}.tmp"
                )
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                flags |= getattr(os, "O_NOFOLLOW", 0)
                try:
                    descriptor = os.open(candidate, flags, 0o600)
                    temporary = candidate
                    break
                except FileExistsError:
                    continue
            if descriptor is None or temporary is None:
                raise OSError("a unique status temporary file could not be created")

            descriptor_stat = os.fstat(descriptor)
            if not stat.S_ISREG(descriptor_stat.st_mode):
                raise OSError("status temporary is not a regular file")
            with os.fdopen(descriptor, "wb") as stream:
                descriptor = None
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())

            name_stat = temporary.lstat()
            if (
                not stat.S_ISREG(name_stat.st_mode)
                or name_stat.st_dev != descriptor_stat.st_dev
                or name_stat.st_ino != descriptor_stat.st_ino
            ):
                raise OSError("status temporary identity changed before publication")

            last_replace_error: OSError | None = None
            for attempt in range(5):
                try:
                    os.replace(temporary, self._path)
                    temporary = None
                    last_replace_error = None
                    break
                except OSError as error:
                    last_replace_error = error
                    if attempt < 4:
                        time.sleep(0.02 * (2**attempt))
            if last_replace_error is not None:
                raise last_replace_error
        except OSError as error:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            if temporary is not None:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    pass
            raise _StatusWriteError(
                "The sanitized status file could not be published atomically."
            ) from error

    def release(self) -> None:
        if self._lock_descriptor is None or self._lock_path is None:
            return
        try:
            descriptor_stat = os.fstat(self._lock_descriptor)
        except OSError:
            descriptor_stat = None
        try:
            os.close(self._lock_descriptor)
        except OSError:
            pass
        self._lock_descriptor = None
        try:
            name_stat = self._lock_path.lstat()
            if (
                descriptor_stat is not None
                and name_stat.st_dev == descriptor_stat.st_dev
                and name_stat.st_ino == descriptor_stat.st_ino
            ):
                self._lock_path.unlink()
        except OSError:
            pass


def _utc_now() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def _bounded_seconds(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if (
        not math.isfinite(parsed)
        or parsed < MIN_INTERVAL_SECONDS
        or parsed > MAX_INTERVAL_SECONDS
    ):
        raise argparse.ArgumentTypeError(
            f"must be between {MIN_INTERVAL_SECONDS} and "
            f"{MAX_INTERVAL_SECONDS} seconds"
        )
    return parsed


def _parser() -> argparse.ArgumentParser:
    parser = _JsonArgumentParser(
        prog="runwatch",
        description=(
            "Run a bounded noninteractive command while emitting sanitized "
            "elapsed-time heartbeats to stderr. This does not provide durability "
            "beyond the parent host's process lifetime."
        ),
    )
    parser.add_argument(
        "--heartbeat-seconds",
        type=_bounded_seconds,
        default=DEFAULT_HEARTBEAT_SECONDS,
        help="Seconds between liveness heartbeats (default: 15)",
    )
    parser.add_argument(
        "--stale-after-seconds",
        type=_bounded_seconds,
        help=(
            "Observer staleness threshold; default is max(60, 3 x heartbeat) "
            "and a supplied value must be at least 3 x heartbeat"
        ),
    )
    parser.add_argument(
        "--cancel-grace-seconds",
        type=_bounded_seconds,
        default=DEFAULT_CANCEL_GRACE_SECONDS,
        help="Seconds to wait after direct-child terminate before kill (default: 5)",
    )
    parser.add_argument(
        "--status-out",
        help=(
            "Optional absolute path for an atomically replaced sanitized JSON "
            "status file; its parent must already exist on approved local storage"
        ),
    )
    parser.add_argument(
        "--label",
        default="long-task",
        help="Nonsensitive label using only letters, numbers, dot, dash, underscore",
    )
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="Absolute child executable and tokenized arguments after --",
    )
    return parser


def _is_reparse_point(stat_result: os.stat_result) -> bool:
    attributes = getattr(stat_result, "st_file_attributes", 0)
    return bool(attributes & _FILE_ATTRIBUTE_REPARSE_POINT)


def _windows_drive_type(path: Path) -> int | None:
    if os.name != "nt":
        return None
    try:
        import ctypes

        root = path.anchor
        if not root:
            return None
        return int(ctypes.windll.kernel32.GetDriveTypeW(str(root)))
    except (AttributeError, OSError, ValueError):
        return None


def _is_within(candidate: Path, root: Path) -> bool:
    candidate_text = os.path.normcase(os.path.abspath(str(candidate)))
    root_text = os.path.normcase(os.path.abspath(str(root)))
    try:
        return os.path.commonpath([candidate_text, root_text]) == root_text
    except (OSError, ValueError) as error:
        raise _StatusPathError(
            "The configured local-storage boundary could not be evaluated."
        ) from error


def _has_windows_stream(path: Path) -> bool:
    if os.name != "nt":
        return False
    _drive, tail = os.path.splitdrive(str(path))
    return ":" in tail


def _assert_no_reparse_ancestry(path: Path) -> None:
    current = path
    while True:
        try:
            current_stat = current.lstat()
        except OSError as error:
            raise _StatusPathError(
                "The local path ancestry could not be verified."
            ) from error
        if stat.S_ISLNK(current_stat.st_mode) or _is_reparse_point(current_stat):
            raise _StatusPathError(
                "The local path must not traverse a reparse point."
            )
        if current == current.parent:
            break
        current = current.parent


def _validate_status_storage(path: Path) -> None:
    parent = path.parent
    try:
        parent_stat = parent.stat()
    except OSError as error:
        raise _StatusPathError(
            "The status directory could not be verified."
        ) from error
    if not stat.S_ISDIR(parent_stat.st_mode):
        raise _StatusPathError(
            "The status directory must already exist on approved local storage."
        )

    _assert_no_reparse_ancestry(parent)
    if _has_windows_stream(path):
        raise _StatusPathError("Windows alternate data streams are not allowed.")

    drive_type = _windows_drive_type(path)
    if os.name == "nt" and drive_type != _WINDOWS_DRIVE_FIXED:
        raise _StatusPathError(
            "The status path must be on a ready fixed local volume."
        )

    if os.name != "nt":
        if parent_stat.st_uid != os.geteuid() or (
            parent_stat.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
        ):
            raise _StatusPathError(
                "The status directory must be owner-controlled and non-shared."
            )

    for environment_name in ("OneDrive", "OneDriveCommercial", "OneDriveConsumer"):
        configured = os.environ.get(environment_name)
        if configured and _is_within(path, Path(configured)):
            raise _StatusPathError(
                "The status path must not be inside a configured sync root."
            )

    if os.path.lexists(path):
        try:
            target_stat = path.lstat()
        except OSError as error:
            raise _StatusPathError(
                "The existing status target could not be verified."
            ) from error
        if not stat.S_ISREG(target_stat.st_mode) or _is_reparse_point(target_stat):
            raise _StatusPathError(
                "The existing status target must be a regular local file."
            )


def _validate_status_path(raw_path: str | None) -> Path | None:
    if raw_path is None:
        return None
    if raw_path.startswith(("\\\\", "//")) or "://" in raw_path:
        raise _StatusPathError(
            "The status path must be on approved local storage."
        )

    path = Path(raw_path)
    if not path.is_absolute():
        raise _StatusPathError("The status path must be absolute.")
    if os.path.lexists(path):
        raise _StatusPathError(
            "The status target must not already exist; use a unique run file."
        )
    _validate_status_storage(path)
    return path


def _validate_executable(command: Sequence[str]) -> None:
    executable = command[0]
    if executable.startswith(("\\\\", "//")) or "://" in executable:
        raise _CliUsageError(
            "the child executable must be an absolute local path"
        )
    executable_path = Path(executable)
    if not executable_path.is_absolute():
        raise _CliUsageError(
            "the child executable must be an absolute local path"
        )
    if _has_windows_stream(executable_path):
        raise _CliUsageError(
            "the child executable must not use an alternate data stream"
        )
    if os.name == "nt":
        try:
            executable_stat = executable_path.lstat()
        except OSError as error:
            raise _CliUsageError(
                "the child executable must be an existing regular local file"
            ) from error
        if (
            not stat.S_ISREG(executable_stat.st_mode)
            or stat.S_ISLNK(executable_stat.st_mode)
            or _is_reparse_point(executable_stat)
        ):
            raise _CliUsageError(
                "the child executable must be an existing regular local file"
            )
        try:
            _assert_no_reparse_ancestry(executable_path.parent)
        except _StatusPathError as error:
            raise _CliUsageError(
                "the child executable path ancestry could not be verified"
            ) from error
    else:
        try:
            if not executable_path.resolve(strict=True).is_file():
                raise OSError("executable target is not a regular file")
        except OSError as error:
            raise _CliUsageError(
                "the child executable must be an existing regular local file"
            ) from error
    if (
        os.name == "nt"
        and _windows_drive_type(executable_path) != _WINDOWS_DRIVE_FIXED
    ):
        raise _CliUsageError(
            "the child executable must be on a ready fixed local volume"
        )
    if os.name == "nt" and executable_path.suffix.lower() in {
        ".bat",
        ".cmd",
        ".ps1",
    }:
        raise _CliUsageError(
            "the child executable must be a native executable; invoke scripts "
            "through an explicit trusted interpreter"
        )
    for environment_name in ("OneDrive", "OneDriveCommercial", "OneDriveConsumer"):
        configured = os.environ.get(environment_name)
        if not configured:
            continue
        try:
            inside_sync_root = _is_within(executable_path, Path(configured))
        except _StatusPathError as error:
            raise _CliUsageError(
                "the child executable storage boundary could not be verified"
            ) from error
        if inside_sync_root:
            raise _CliUsageError(
                "the child executable must not be inside a configured sync root"
            )


def _duration(seconds: float) -> str:
    whole = max(0, int(seconds))
    hours, remainder = divmod(whole, 3600)
    minutes, secs = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def _emit_heartbeat(
    *,
    run_id: str,
    label: str,
    state: str,
    elapsed_seconds: float,
    sequence: int,
    child_pid: int | None,
    exit_code: int | None = None,
) -> None:
    fields = [
        "[runwatch]",
        f"run={run_id}",
        f"label={label}",
        f"state={state}",
        f"elapsed={_duration(elapsed_seconds)}",
        f"heartbeat={sequence}",
    ]
    if child_pid is not None:
        fields.append(f"pid={child_pid}")
    if exit_code is not None:
        fields.append(f"exit={exit_code}")
    try:
        sys.stderr.write(" ".join(fields) + "\n")
        sys.stderr.flush()
    except (OSError, ValueError):
        # Loss of the human-readable stream must not terminate the child. The
        # atomic status file remains the machine-readable observation channel.
        try:
            stderr_descriptor = sys.stderr.fileno()
            with open(os.devnull, "wb", buffering=0) as sink:
                os.dup2(sink.fileno(), stderr_descriptor)
        except (AttributeError, OSError, ValueError):
            pass


def _status_payload(
    *,
    run_id: str,
    label: str,
    state: str,
    terminal: bool,
    started_utc: str,
    finished_utc: str | None,
    started_monotonic: float,
    heartbeat_sequence: int,
    heartbeat_seconds: float,
    stale_after_seconds: float,
    child_pid: int | None,
    child_started: bool,
    child_observed_running: bool,
    child_exit_code: int | None,
    cancellation_requested: bool,
    cancellation_method: str | None = None,
) -> dict[str, object]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "runId": run_id,
        "label": label,
        "state": state,
        "terminal": terminal,
        "startedUtc": started_utc,
        "updatedUtc": _utc_now(),
        "finishedUtc": finished_utc,
        "elapsedSeconds": round(
            max(0.0, time.monotonic() - started_monotonic), 3
        ),
        "heartbeatSequence": heartbeat_sequence,
        "heartbeatSeconds": heartbeat_seconds,
        "staleAfterSeconds": stale_after_seconds,
        "child": {
            "pid": child_pid,
            "started": child_started,
            "observedRunning": child_observed_running,
            "exitCode": child_exit_code,
        },
        "cancellation": {
            "requested": cancellation_requested,
            "method": cancellation_method,
        },
        "guarantees": {
            "livenessOnly": True,
            "progressVerified": False,
            "survivesSupervisor": False,
            "processTreeContained": False,
        },
    }


def _terminate_child(
    process: subprocess.Popen[bytes],
    cancel_grace_seconds: float,
) -> str:
    if process.poll() is not None:
        return "already-exited"

    if os.name == "nt":
        try:
            process.send_signal(getattr(signal, "CTRL_BREAK_EVENT"))
            process.wait(timeout=cancel_grace_seconds)
            return "ctrl-break"
        except (AttributeError, OSError, subprocess.TimeoutExpired):
            pass

    try:
        process.terminate()
        process.wait(timeout=cancel_grace_seconds)
        return "root-terminate"
    except (OSError, subprocess.TimeoutExpired):
        try:
            process.kill()
            process.wait(timeout=cancel_grace_seconds)
            return "root-kill"
        except (OSError, subprocess.TimeoutExpired):
            return "unconfirmed"


def _run(
    command: Sequence[str],
    *,
    label: str,
    heartbeat_seconds: float,
    stale_after_seconds: float,
    cancel_grace_seconds: float,
    status_path: Path | None,
) -> int:
    run_id = str(uuid.uuid4())
    started_utc = _utc_now()
    started_monotonic = time.monotonic()
    status_writer = _AtomicStatusWriter(status_path, run_id)
    heartbeat_sequence = 0

    starting = _status_payload(
        run_id=run_id,
        label=label,
        state="starting",
        terminal=False,
        started_utc=started_utc,
        finished_utc=None,
        started_monotonic=started_monotonic,
        heartbeat_sequence=heartbeat_sequence,
        heartbeat_seconds=heartbeat_seconds,
        stale_after_seconds=stale_after_seconds,
        child_pid=None,
        child_started=False,
        child_observed_running=False,
        child_exit_code=None,
        cancellation_requested=False,
    )
    try:
        status_writer.acquire()
        status_writer.write(starting)
    except _StatusWriteError:
        status_writer.release()
        _emit_heartbeat(
            run_id=run_id,
            label=label,
            state="wrapper-failed",
            elapsed_seconds=0.0,
            sequence=heartbeat_sequence,
            child_pid=None,
            exit_code=WRAPPER_FAILURE_EXIT,
        )
        return WRAPPER_FAILURE_EXIT

    try:
        creation_flags = (
            getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
            if os.name == "nt"
            else 0
        )
        process = subprocess.Popen(
            list(command),
            stdin=subprocess.DEVNULL,
            stdout=None,
            stderr=None,
            shell=False,
            close_fds=True,
            creationflags=creation_flags,
        )
    except (OSError, ValueError):
        heartbeat_sequence += 1
        failed = _status_payload(
            run_id=run_id,
            label=label,
            state="launch-failed",
            terminal=True,
            started_utc=started_utc,
            finished_utc=_utc_now(),
            started_monotonic=started_monotonic,
            heartbeat_sequence=heartbeat_sequence,
            heartbeat_seconds=heartbeat_seconds,
            stale_after_seconds=stale_after_seconds,
            child_pid=None,
            child_started=False,
            child_observed_running=False,
            child_exit_code=None,
            cancellation_requested=False,
        )
        try:
            status_writer.write(failed)
        except _StatusWriteError:
            pass
        _emit_heartbeat(
            run_id=run_id,
            label=label,
            state="launch-failed",
            elapsed_seconds=time.monotonic() - started_monotonic,
            sequence=heartbeat_sequence,
            child_pid=None,
            exit_code=WRAPPER_FAILURE_EXIT,
        )
        status_writer.release()
        return WRAPPER_FAILURE_EXIT

    next_heartbeat = started_monotonic
    child_exit_code: int | None = None
    interrupted = False
    cancellation_method: str | None = None
    status_write_failed = False
    try:
        while True:
            child_exit_code = process.poll()
            now = time.monotonic()
            if child_exit_code is not None:
                break
            if now >= next_heartbeat:
                heartbeat_sequence += 1
                _emit_heartbeat(
                    run_id=run_id,
                    label=label,
                    state="running",
                    elapsed_seconds=now - started_monotonic,
                    sequence=heartbeat_sequence,
                    child_pid=process.pid,
                )
                running = _status_payload(
                    run_id=run_id,
                    label=label,
                    state="running",
                    terminal=False,
                    started_utc=started_utc,
                    finished_utc=None,
                    started_monotonic=started_monotonic,
                    heartbeat_sequence=heartbeat_sequence,
                    heartbeat_seconds=heartbeat_seconds,
                    stale_after_seconds=stale_after_seconds,
                    child_pid=process.pid,
                    child_started=True,
                    child_observed_running=True,
                    child_exit_code=None,
                    cancellation_requested=False,
                )
                try:
                    status_writer.write(running)
                except _StatusWriteError:
                    status_write_failed = True
                next_heartbeat = now + heartbeat_seconds
            time.sleep(min(0.1, max(0.01, next_heartbeat - now)))
    except KeyboardInterrupt:
        interrupted = True
        cancellation_method = _terminate_child(process, cancel_grace_seconds)
        child_exit_code = process.poll()
    finally:
        if process.poll() is None:
            _terminate_child(process, cancel_grace_seconds)
        if child_exit_code is None:
            child_exit_code = process.poll()

    final_state = "interrupted" if interrupted else "exited"
    final_exit = INTERRUPTED_EXIT if interrupted else child_exit_code
    if final_exit is None:
        final_state = "wrapper-failed"
        final_exit = WRAPPER_FAILURE_EXIT

    heartbeat_sequence += 1
    final_payload = _status_payload(
        run_id=run_id,
        label=label,
        state=final_state,
        terminal=True,
        started_utc=started_utc,
        finished_utc=_utc_now(),
        started_monotonic=started_monotonic,
        heartbeat_sequence=heartbeat_sequence,
        heartbeat_seconds=heartbeat_seconds,
        stale_after_seconds=stale_after_seconds,
        child_pid=process.pid,
        child_started=True,
        child_observed_running=False,
        child_exit_code=child_exit_code,
        cancellation_requested=interrupted,
        cancellation_method=cancellation_method,
    )
    try:
        status_writer.write(final_payload)
    except _StatusWriteError:
        status_write_failed = True

    final_state_for_stderr = (
        "status-update-failed" if status_write_failed else final_state
    )
    _emit_heartbeat(
        run_id=run_id,
        label=label,
        state=final_state_for_stderr,
        elapsed_seconds=time.monotonic() - started_monotonic,
        sequence=heartbeat_sequence,
        child_pid=process.pid,
        exit_code=final_exit,
    )
    status_writer.release()
    return final_exit


def main(argv: Sequence[str] | None = None) -> int:
    parser = _parser()
    try:
        arguments = parser.parse_args(argv)
        command = list(arguments.command)
        if command and command[0] == "--":
            command = command[1:]
        if not command:
            raise _CliUsageError("a child command is required after --")
        if not _LABEL_PATTERN.fullmatch(arguments.label):
            raise _CliUsageError(
                "label must contain only letters, numbers, dot, dash, or underscore"
            )
        _validate_executable(command)
        status_path = _validate_status_path(arguments.status_out)
        stale_after_seconds = (
            max(60.0, 3 * arguments.heartbeat_seconds)
            if arguments.stale_after_seconds is None
            else arguments.stale_after_seconds
        )
        if stale_after_seconds < 3 * arguments.heartbeat_seconds:
            raise _CliUsageError(
                "stale-after-seconds must be at least 3 x heartbeat-seconds"
            )
    except (_CliUsageError, _StatusPathError) as error:
        sys.stderr.write(
            json.dumps(
                {
                    "ok": False,
                    "error": {
                        "code": "invalid_runwatch_arguments",
                        "message": str(error),
                    },
                },
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        )
        return 2

    return _run(
        command,
        label=arguments.label,
        heartbeat_seconds=arguments.heartbeat_seconds,
        stale_after_seconds=stale_after_seconds,
        cancel_grace_seconds=arguments.cancel_grace_seconds,
        status_path=status_path,
    )
