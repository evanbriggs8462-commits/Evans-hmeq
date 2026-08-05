from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def test_required_agent_files_exist() -> None:
    required = [
        ROOT / "AGENTS.md",
        ROOT / "opencode.json",
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "SKILL.md",
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "large-xml-smb-runbook.md",
        ROOT / "docs" / "security-boundaries.md",
        ROOT / "docs" / "long-running-task-observability.md",
        ROOT / "src" / "runwatch" / "cli.py",
        ROOT / "tests" / "python" / "test_runwatch.py",
    ]
    assert all(path.is_file() for path in required)


def test_opencode_profiles_are_explicit_and_private() -> None:
    config = json.loads((ROOT / "opencode.json").read_text(encoding="utf-8"))

    assert config["share"] == "disabled"
    assert config["model"] == "azure/gpt-5.3-codex"
    assert config["agent"]["finance-build"]["reasoningEffort"] == "medium"
    assert config["agent"]["finance-deep"]["reasoningEffort"] == "high"

    for profile_name in ("finance-build", "finance-deep"):
        bash_policy = config["agent"][profile_name]["permission"]["bash"]
        assert bash_policy == {"*": "ask"}


def test_skill_name_matches_directory() -> None:
    skill_path = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "SKILL.md"
    )
    content = skill_path.read_text(encoding="utf-8")
    match = re.search(r"(?m)^name:\s*([a-z0-9-]+)\s*$", content)

    assert match is not None
    assert match.group(1) == skill_path.parent.name
    assert re.search(r"(?m)^description:\s*\S", content)


def test_data_artifacts_are_ignored() -> None:
    ignored = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()

    for pattern in (
        "*.xml",
        "*.parquet",
        "*.pbix",
        ".env",
        "runs/",
        "local_staging/",
        "run-status/",
        ".runwatch/",
        "*.runwatch.json",
        "*.runwatch.json.*.tmp",
        "*.runwatch.json.lock",
    ):
        assert pattern in ignored


def test_large_xml_runbook_is_mandatory_and_routed() -> None:
    agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    skill = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "SKILL.md"
    ).read_text(encoding="utf-8")
    relative_runbook = "references/large-xml-smb-runbook.md"
    skill_path = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "SKILL.md"
    )

    assert relative_runbook in skill
    assert "large XML" in skill
    assert "VPN/SMB" in skill
    assert "interactive shell timeout" in skill
    assert "large-xml-smb-runbook.md" in agents
    assert "before issuing another content-reading or copy command" in agents
    assert (skill_path.parent / relative_runbook).is_file()
    powershell_runbook = (
        ROOT / "docs" / "powershell-reliability.md"
    ).read_text(encoding="utf-8")
    assert "../.opencode/skills/finance-data-reliability/references/" in (
        powershell_runbook
    )
    assert "large-xml-smb-runbook.md" in powershell_runbook


def test_large_xml_runbook_preserves_incident_guardrails() -> None:
    runbook = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "large-xml-smb-runbook.md"
    ).read_text(encoding="utf-8")

    required_headings = (
        "## Phase 2: metadata-only remote preflight",
        "## Phase 3: understand bounded reads before using one",
        "## Phase 4: never validate XML with regex",
        "## Phase 5: choose a real local staging destination",
        "## Phase 6: stage exactly once through the supported wrapper",
        "## Phase 7: parse only the finalized local artifact",
        "## Phase 8: acceptance gates",
        "## Public Git and prompt hygiene",
        "## What permanent agent learning means",
    )
    required_literals = (
        "path.read_bytes()[:8000]",
        "open(\"rb\")",
        "Get-Content -TotalCount",
        "`$?`",
        "OneDrive",
        "Stage-Spool.ps1",
        "completed_eof: true",
        "ChildProcess.kill",
        "datetime.utcnow()",
        "regex",
        "120000 ms",
        "Start-Job",
        "artifact.relativePath",
        "Git history",
        "revoke or rotate",
    )

    for heading in required_headings:
        assert heading in runbook
    for literal in required_literals:
        assert literal in runbook


def test_public_runbook_uses_only_synthetic_identity_and_paths() -> None:
    runbook = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "large-xml-smb-runbook.md"
    ).read_text(encoding="utf-8")

    assert re.search(r"(?i)C:\\Users\\[^<\s]+", runbook) is None
    assert "OneDrive - " not in runbook
    assert re.search(r"(?i)\\\\(?!server\\approved-share)", runbook) is None
    assert "'\\\\server\\approved-share" in runbook


def test_runwatch_is_documented_routed_and_approval_gated() -> None:
    agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    skill_path = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "SKILL.md"
    )
    skill = skill_path.read_text(encoding="utf-8")
    documentation = (
        ROOT / "docs" / "long-running-task-observability.md"
    ).read_text(encoding="utf-8")
    project = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    config = json.loads((ROOT / "opencode.json").read_text(encoding="utf-8"))

    link = re.search(
        r"\[[^]]*long-running task observability[^]]*\]\(([^)]+)\)",
        skill,
        flags=re.IGNORECASE,
    )
    assert link is not None
    assert (skill_path.parent / link.group(1)).resolve().is_file()
    assert "timer" in skill
    assert "heartbeat" in skill
    assert "no output" in skill
    assert "docs/long-running-task-observability.md" in agents
    assert "liveness" in agents
    assert "not automatically a" in documentation
    assert "progress meter" in documentation
    assert "cannot override a fixed maximum wall-clock timeout" in documentation
    assert "stale nonterminal" in documentation
    assert "runwatch = \"runwatch.cli:main\"" in project

    for profile_name in ("finance-build", "finance-deep"):
        assert config["agent"][profile_name]["permission"]["bash"] == {
            "*": "ask"
        }


def test_public_examples_use_synthetic_paths_and_identities() -> None:
    public_files = [
        ROOT / "AGENTS.md",
        ROOT / "README.md",
        *sorted((ROOT / "docs").glob("*.md")),
        *sorted(
            (
                ROOT
                / ".opencode"
                / "skills"
                / "finance-data-reliability"
            ).rglob("*.md")
        ),
        *sorted((ROOT / "scripts").glob("*.ps1")),
    ]
    combined = "\n".join(path.read_text(encoding="utf-8") for path in public_files)

    assert re.search(r"(?i)C:\\Users\\[^<\s]+", combined) is None
    assert re.search(r"(?i)OneDrive\s+-\s+[^<\r\n]+", combined) is None

    single_quoted_unc = re.compile(r"'(\\\\([^\\']+)[^']*)'")
    for match in single_quoted_unc.finditer(combined):
        assert match.group(2).lower() in {"server", "?", "."}
