from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest


ROOT = Path(__file__).resolve().parents[2]


def _environment() -> dict[str, str]:
    environment = os.environ.copy()
    existing = environment.get("PYTHONPATH")
    source = str(ROOT / "src")
    environment["PYTHONPATH"] = (
        source if not existing else os.pathsep.join((source, existing))
    )
    return environment


def _command(*arguments: str) -> list[str]:
    return [sys.executable, "-m", "runwatch", *arguments]


def test_heartbeats_show_elapsed_time_and_preserve_child_stdout(
    tmp_path: Path,
) -> None:
    status_path = tmp_path / "status.runwatch.json"
    child = "import time; time.sleep(0.35); print('child-result')"

    completed = subprocess.run(
        _command(
            "--heartbeat-seconds",
            "0.1",
            "--status-out",
            str(status_path),
            "--label",
            "xml-validation",
            "--",
            sys.executable,
            "-c",
            child,
        ),
        cwd=ROOT,
        env=_environment(),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    assert completed.returncode == 0
    assert completed.stdout == "child-result\n"
    assert completed.stderr.count("[runwatch]") >= 2
    assert "state=running" in completed.stderr
    assert "elapsed=00:00:00" in completed.stderr
    assert "state=exited" in completed.stderr
    payload = json.loads(status_path.read_text(encoding="utf-8"))
    assert payload["state"] == "exited"
    assert payload["terminal"] is True
    assert payload["child"]["started"] is True
    assert payload["child"]["observedRunning"] is False
    assert payload["child"]["exitCode"] == 0
    assert payload["guarantees"] == {
        "livenessOnly": True,
        "processTreeContained": False,
        "progressVerified": False,
        "survivesSupervisor": False,
    }
    assert payload["heartbeatSequence"] >= 2
    assert f"run={payload['runId']}" in completed.stderr
    assert not status_path.read_bytes().startswith(b"\xef\xbb\xbf")
    assert list(tmp_path.glob(".status.runwatch.json.*.tmp")) == []


def test_status_file_is_observable_while_child_is_running(tmp_path: Path) -> None:
    status_path = tmp_path / "status.runwatch.json"
    process = subprocess.Popen(
        _command(
            "--heartbeat-seconds",
            "0.1",
            "--status-out",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            "import time; time.sleep(0.6)",
        ),
        cwd=ROOT,
        env=_environment(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        deadline = time.monotonic() + 3
        running_payload: dict[str, object] | None = None
        while time.monotonic() < deadline:
            if status_path.exists():
                candidate = json.loads(status_path.read_text(encoding="utf-8"))
                if candidate["state"] == "running":
                    running_payload = candidate
                    break
            time.sleep(0.025)

        assert running_payload is not None
        child_payload = running_payload["child"]
        assert isinstance(child_payload, dict)
        assert child_payload["observedRunning"] is True
        assert running_payload["terminal"] is False
        assert running_payload["heartbeatSequence"] >= 1
        stdout, stderr = process.communicate(timeout=5)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

    assert process.returncode == 0
    assert stdout == ""
    assert "state=exited" in stderr


@pytest.mark.parametrize("child_exit_code", [0, 1, 7, 37, 255])
def test_child_exit_code_is_propagated_and_recorded(
    tmp_path: Path,
    child_exit_code: int,
) -> None:
    status_path = tmp_path / f"exit-{child_exit_code}.runwatch.json"

    completed = subprocess.run(
        _command(
            "--status-out",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            f"raise SystemExit({child_exit_code})",
        ),
        cwd=ROOT,
        env=_environment(),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    payload = json.loads(status_path.read_text(encoding="utf-8"))
    assert completed.returncode == child_exit_code
    assert payload["state"] == "exited"
    assert payload["terminal"] is True
    assert payload["child"]["exitCode"] == child_exit_code
    assert "state=exited" in completed.stderr
    assert f"exit={child_exit_code}" in completed.stderr


def test_inherited_stdout_and_stderr_do_not_introduce_pipe_deadlock() -> None:
    chunk_count = 128
    chunk_size = 8192
    child = (
        "import os\n"
        f"for _ in range({chunk_count}):\n"
        f" os.write(1, b'\\x00' * {chunk_size})\n"
        f" os.write(2, b'\\xff' * {chunk_size})\n"
    )

    completed = subprocess.run(
        _command("--heartbeat-seconds", "0.1", "--", sys.executable, "-c", child),
        cwd=ROOT,
        env=_environment(),
        capture_output=True,
        timeout=15,
        check=False,
    )

    assert completed.returncode == 0
    assert completed.stdout == b"\x00" * (chunk_count * chunk_size)
    assert completed.stderr.count(b"\xff") == chunk_count * chunk_size
    assert b"state=exited" in completed.stderr


def test_tokenized_arguments_round_trip_without_a_shell() -> None:
    arguments = ["space value", "", 'quote"value', "trailing\\"]
    child = "import json,sys; print(json.dumps(sys.argv[1:]))"

    completed = subprocess.run(
        _command("--", sys.executable, "-c", child, *arguments),
        cwd=ROOT,
        env=_environment(),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    assert completed.returncode == 0
    assert json.loads(completed.stdout) == arguments
    assert "state=exited" in completed.stderr


def test_status_and_wrapper_errors_do_not_echo_command_or_sensitive_paths(
    tmp_path: Path,
) -> None:
    status_path = tmp_path / "status.runwatch.json"
    sensitive_argument = "Confidential_Client_Alpha_2026.xml"
    missing_executable = tmp_path / "ConfidentialMissingExecutable_83919.exe"
    missing_executable.write_bytes(b"not-an-executable")
    missing_executable.chmod(0o700)

    completed = subprocess.run(
        _command(
            "--status-out",
            str(status_path),
            "--",
            str(missing_executable),
            sensitive_argument,
        ),
        cwd=ROOT,
        env=_environment(),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    status_text = status_path.read_text(encoding="utf-8")
    assert completed.returncode == 125
    for marker in (sensitive_argument, missing_executable.name, str(tmp_path)):
        assert marker not in status_text
        assert marker not in completed.stderr
    payload = json.loads(status_text)
    assert payload["state"] == "launch-failed"
    assert payload["terminal"] is True
    assert payload["child"]["started"] is False
    assert payload["child"]["exitCode"] is None
    assert set(payload) == {
        "cancellation",
        "child",
        "elapsedSeconds",
        "finishedUtc",
        "guarantees",
        "heartbeatSeconds",
        "heartbeatSequence",
        "label",
        "runId",
        "schemaVersion",
        "staleAfterSeconds",
        "startedUtc",
        "state",
        "terminal",
        "updatedUtc",
    }
    assert set(payload["child"]) == {
        "exitCode",
        "observedRunning",
        "pid",
        "started",
    }
    assert set(payload["cancellation"]) == {"method", "requested"}


def test_closed_heartbeat_sink_does_not_cancel_child(tmp_path: Path) -> None:
    status_path = tmp_path / "closed-stderr.runwatch.json"
    marker = tmp_path / "child-finished"
    child = (
        "import time; from pathlib import Path; time.sleep(0.3); "
        f"Path({str(marker)!r}).write_text('finished')"
    )
    process = subprocess.Popen(
        _command(
            "--heartbeat-seconds",
            "0.1",
            "--status-out",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            child,
        ),
        cwd=ROOT,
        env=_environment(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    assert process.stderr is not None
    process.stderr.close()

    assert process.wait(timeout=5) == 0
    assert marker.read_text(encoding="utf-8") == "finished"
    payload = json.loads(status_path.read_text(encoding="utf-8"))
    assert payload["state"] == "exited"
    assert payload["child"]["exitCode"] == 0


def test_status_is_always_complete_json_during_atomic_replacement(
    tmp_path: Path,
) -> None:
    status_path = tmp_path / "atomic.runwatch.json"
    process = subprocess.Popen(
        _command(
            "--heartbeat-seconds",
            "0.1",
            "--status-out",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            "import time; time.sleep(0.75)",
        ),
        cwd=ROOT,
        env=_environment(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    observed_sequences: list[int] = []
    deadline = time.monotonic() + 5
    try:
        while process.poll() is None and time.monotonic() < deadline:
            if status_path.exists():
                payload = json.loads(status_path.read_text(encoding="utf-8"))
                observed_sequences.append(payload["heartbeatSequence"])
            time.sleep(0.005)
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

    final_payload = json.loads(status_path.read_text(encoding="utf-8"))
    assert observed_sequences
    assert observed_sequences == sorted(observed_sequences)
    assert final_payload["state"] == "exited"
    assert final_payload["terminal"] is True
    assert list(tmp_path.glob(".atomic.runwatch.json.*.tmp")) == []


@pytest.mark.skipif(os.name == "nt", reason="symlink regression uses POSIX semantics")
def test_exposed_run_id_cannot_be_used_for_status_temp_symlink_attack(
    tmp_path: Path,
) -> None:
    status_path = tmp_path / "tamper.runwatch.json"
    victim = tmp_path / "victim.txt"
    victim.write_text("untouched", encoding="utf-8")
    process = subprocess.Popen(
        _command(
            "--heartbeat-seconds",
            "0.1",
            "--status-out",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            "import time; time.sleep(0.65)",
        ),
        cwd=ROOT,
        env=_environment(),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    legacy_temp: Path | None = None
    try:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if status_path.exists():
                payload = json.loads(status_path.read_text(encoding="utf-8"))
                if payload["state"] == "running":
                    legacy_temp = status_path.with_name(
                        f".{status_path.name}.{payload['runId']}.tmp"
                    )
                    legacy_temp.symlink_to(victim)
                    break
            time.sleep(0.025)
        assert legacy_temp is not None
        assert process.wait(timeout=5) == 0
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

    assert victim.read_text(encoding="utf-8") == "untouched"
    assert status_path.is_file()
    assert not status_path.is_symlink()


def test_only_one_wrapper_can_own_a_status_target(tmp_path: Path) -> None:
    status_path = tmp_path / "exclusive.runwatch.json"
    marker = tmp_path / "launch-count.txt"
    child = (
        "import time; from pathlib import Path; "
        f"p=Path({str(marker)!r}); "
        "p.write_text((p.read_text() if p.exists() else '') + 'x'); "
        "time.sleep(0.5)"
    )
    processes = [
        subprocess.Popen(
            _command(
                "--heartbeat-seconds",
                "0.1",
                "--status-out",
                str(status_path),
                "--",
                sys.executable,
                "-c",
                child,
            ),
            cwd=ROOT,
            env=_environment(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(8)
    ]
    return_codes = [process.wait(timeout=8) for process in processes]

    assert return_codes.count(0) == 1
    assert all(code in {0, 2, 125} for code in return_codes)
    assert marker.read_text(encoding="utf-8") == "x"
    payload = json.loads(status_path.read_text(encoding="utf-8"))
    assert payload["state"] == "exited"
    assert not list(tmp_path.glob(".exclusive.runwatch.json.*.tmp"))
    assert not list(tmp_path.glob(".exclusive.runwatch.json.lock"))


def test_invalid_status_paths_fail_before_launch_without_path_disclosure(
    tmp_path: Path,
) -> None:
    marker = tmp_path / "child-ran"
    missing_parent = tmp_path / "SensitiveMissingDirectory" / "status.json"
    child = f"from pathlib import Path; Path({str(marker)!r}).write_text('ran')"

    completed = subprocess.run(
        _command(
            "--status-out",
            str(missing_parent),
            "--",
            sys.executable,
            "-c",
            child,
        ),
        cwd=ROOT,
        env=_environment(),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    assert completed.returncode == 2
    assert not marker.exists()
    assert str(missing_parent) not in completed.stderr
    payload = json.loads(completed.stderr)
    assert payload["error"]["code"] == "invalid_runwatch_arguments"


def test_existing_status_is_not_overwritten_or_used_to_launch(
    tmp_path: Path,
) -> None:
    marker = tmp_path / "child-ran"
    status_path = tmp_path / "prior.runwatch.json"
    original = b'{"prior":true}\n'
    status_path.write_bytes(original)
    child = f"from pathlib import Path; Path({str(marker)!r}).write_text('ran')"

    completed = subprocess.run(
        _command(
            "--status-out",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            child,
        ),
        cwd=ROOT,
        env=_environment(),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    assert completed.returncode == 2
    assert not marker.exists()
    assert status_path.read_bytes() == original
    assert str(status_path) not in completed.stderr


def test_unc_status_path_is_rejected_without_launch(tmp_path: Path) -> None:
    marker = tmp_path / "child-ran"
    child = f"from pathlib import Path; Path({str(marker)!r}).write_text('ran')"

    completed = subprocess.run(
        _command(
            "--status-out",
            r"\\server\share\status.json",
            "--",
            sys.executable,
            "-c",
            child,
        ),
        cwd=ROOT,
        env=_environment(),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    assert completed.returncode == 2
    assert not marker.exists()
    assert r"\server\share" not in completed.stderr


@pytest.mark.skipif(os.name == "nt", reason="POSIX permission regression")
def test_shared_status_directory_is_rejected_before_launch(
    tmp_path: Path,
) -> None:
    shared = tmp_path / "shared"
    shared.mkdir(mode=0o777)
    shared.chmod(0o777)
    marker = tmp_path / "child-ran"
    child = f"from pathlib import Path; Path({str(marker)!r}).write_text('ran')"

    completed = subprocess.run(
        _command(
            "--status-out",
            str(shared / "status.runwatch.json"),
            "--",
            sys.executable,
            "-c",
            child,
        ),
        cwd=ROOT,
        env=_environment(),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    assert completed.returncode == 2
    assert not marker.exists()
    assert "owner-controlled and non-shared" in completed.stderr


def test_stale_threshold_must_be_at_least_three_heartbeats(
    tmp_path: Path,
) -> None:
    marker = tmp_path / "child-ran"
    child = f"from pathlib import Path; Path({str(marker)!r}).write_text('ran')"

    completed = subprocess.run(
        _command(
            "--heartbeat-seconds",
            "10",
            "--stale-after-seconds",
            "29",
            "--",
            sys.executable,
            "-c",
            child,
        ),
        cwd=ROOT,
        env=_environment(),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )

    assert completed.returncode == 2
    assert not marker.exists()
    assert "at least 3 x heartbeat-seconds" in completed.stderr


@pytest.mark.skipif(os.name == "nt", reason="POSIX signal regression")
def test_keyboard_interrupt_is_terminal_without_inventing_success(
    tmp_path: Path,
) -> None:
    status_path = tmp_path / "interrupt.runwatch.json"
    process = subprocess.Popen(
        _command(
            "--heartbeat-seconds",
            "0.1",
            "--cancel-grace-seconds",
            "0.2",
            "--status-out",
            str(status_path),
            "--",
            sys.executable,
            "-c",
            "import time; time.sleep(30)",
        ),
        cwd=ROOT,
        env=_environment(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    deadline = time.monotonic() + 5
    try:
        while time.monotonic() < deadline:
            if status_path.exists():
                payload = json.loads(status_path.read_text(encoding="utf-8"))
                if payload["state"] == "running":
                    break
            time.sleep(0.025)
        else:
            pytest.fail("runwatch did not publish a running heartbeat")

        process.send_signal(2)
        stdout, stderr = process.communicate(timeout=5)
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)

    final_payload = json.loads(status_path.read_text(encoding="utf-8"))
    assert process.returncode == 130
    assert stdout == ""
    assert "state=interrupted" in stderr
    assert final_payload["state"] == "interrupted"
    assert final_payload["terminal"] is True
    assert final_payload["cancellation"]["requested"] is True
    assert final_payload["cancellation"]["method"] in {
        "already-exited",
        "root-kill",
        "root-terminate",
        "unconfirmed",
    }
    assert final_payload["child"]["exitCode"] != 0
