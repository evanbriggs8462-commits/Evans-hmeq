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
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "power-bi-boundaries.md",
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "power-bi-premium-workspace-runbook.md",
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "power-bi-report-authoring.md",
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "databricks-agent-access.md",
        ROOT / "docs" / "security-boundaries.md",
        ROOT / "docs" / "long-running-task-observability.md",
        ROOT / "src" / "runwatch" / "cli.py",
        ROOT / "tests" / "python" / "test_runwatch.py",
    ]
    assert all(path.is_file() for path in required)


def test_opencode_profiles_are_model_agnostic_and_private() -> None:
    config = json.loads((ROOT / "opencode.json").read_text(encoding="utf-8"))

    assert config["share"] == "disabled"
    assert "model" not in config

    for profile_name in (
        "finance-scout",
        "finance-compute",
        "finance-build",
        "finance-verifier",
        "finance-deep",
    ):
        assert "model" not in config["agent"][profile_name]
        assert "reasoningEffort" not in config["agent"][profile_name]
        bash_policy = config["agent"][profile_name]["permission"]["bash"]
        if profile_name in {"finance-scout", "finance-compute", "finance-verifier"}:
            assert bash_policy == {"*": "deny"}
        else:
            assert bash_policy == {"*": "ask"}

    assert config["agent"]["finance-scout"]["permission"]["edit"] == "deny"
    assert config["agent"]["finance-compute"]["permission"]["edit"] == "deny"
    assert config["agent"]["finance-verifier"]["permission"]["edit"] == "deny"


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
        ".databricks/",
        ".databrickscfg",
        "dbx-state/",
        "genie-state/",
        "genie-transcripts/",
        "query-results/",
        "*.pbip",
        "*.pbir",
        "*.Report/",
        "*.SemanticModel/",
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
        assert config["agent"][profile_name]["permission"]["bash"]["*"] == "ask"


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


def test_power_bi_premium_runbook_is_routed_and_complete() -> None:
    skill_path = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "SKILL.md"
    )
    skill = skill_path.read_text(encoding="utf-8")
    relative_runbook = "references/power-bi-premium-workspace-runbook.md"
    runbook_path = skill_path.parent / relative_runbook
    runbook = runbook_path.read_text(encoding="utf-8")

    assert relative_runbook in skill
    assert runbook_path.is_file()
    for trigger in (
        "Premium/Fabric workspace",
        "Power BI REST API",
        "XMLA endpoint",
        "Power BI MCP",
        "refresh history",
        "enhanced refresh",
        "expiring access token",
        "published semantic model",
    ):
        assert trigger in skill

    required_headings = (
        "## REST means REST, not reset",
        "## Tool-selection matrix",
        "## Identify the Power BI MCP server",
        "## Four independent permission gates",
        "## Read-only capability inventory",
        "## REST inventory and refresh history",
        "## DAX validation",
        "## Standard and enhanced refresh",
        "## XMLA and Tabular Editor 2",
        "## M partitions and service validation",
        "## Token expiry and resumable polling",
        "## Change and approval gates",
        "## Failure classification",
        "## Sanitized receipt",
        "## Synthetic command templates",
        "## Primary sources",
    )
    required_literals = (
        "REST is not a general TOM",
        "Build",
        "Contributor",
        "202 Accepted",
        "requestId",
        "transactional",
        "partialBatch",
        "RefreshUserPermissions",
        "one call per user per hour",
        "cannot be downloaded back as a PBIX",
        "service refresh",
        "access token",
        "`401`",
        "`403`",
        "Power BI MCP",
        "Tabular Editor 2",
        "--readonly",
        "--skipconfirmation",
        "IsError=true",
    )
    for heading in required_headings:
        assert heading in runbook
    for literal in required_literals:
        assert literal in runbook


def test_power_bi_desktop_and_service_processing_are_not_conflated() -> None:
    agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    boundary = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "power-bi-boundaries.md"
    ).read_text(encoding="utf-8")
    operating_model = (ROOT / "docs" / "agent-operating-model.md").read_text(
        encoding="utf-8"
    )
    combined = "\n".join((agents, boundary, operating_model))

    assert "unsupported against a model loaded in Power BI Desktop" in combined
    assert "service XMLA/TOM/TMSL" in combined
    assert "enhanced REST" in combined
    assert "immediate live" in combined
    assert "June 2025" not in combined


def test_pbi_capabilities_command_is_read_only_and_approval_gated() -> None:
    config = json.loads((ROOT / "opencode.json").read_text(encoding="utf-8"))
    command = config["command"]["pbi-capabilities"]
    template = command["template"]

    assert command["agent"] == "finance-scout"
    assert "read-only capability inventory" in template
    assert "Never request, print, persist, decode, or accept a bearer token" in template
    for prohibited in (
        "Do not trigger or cancel refresh",
        "refresh permissions",
        "take ownership",
        "rebind a report",
        "change schedules or parameters",
        "commit an MCP transaction",
        "apply service TMDL",
        "call Fabric updateDefinition",
        "save or deploy metadata",
        "modify any service object",
    ):
        assert prohibited in template
    for profile_name in ("finance-build", "finance-deep"):
        assert config["agent"][profile_name]["permission"]["bash"]["*"] == "ask"


def test_public_power_bi_guidance_contains_only_synthetic_targets() -> None:
    public_files = [
        ROOT / "AGENTS.md",
        ROOT / "README.md",
        ROOT / "docs" / "agent-operating-model.md",
        ROOT / "docs" / "security-boundaries.md",
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
        / "power-bi-boundaries.md",
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "power-bi-premium-workspace-runbook.md",
    ]
    combined = "\n".join(path.read_text(encoding="utf-8") for path in public_files)

    assert re.search(
        r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-"
        r"[89ab][0-9a-f]{3}-[0-9a-f]{12}\b",
        combined,
    ) is None
    assert re.search(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", combined) is None
    assert re.search(r"(?i)Authorization\s*:\s*Bearer\s+\S+", combined) is None
    assert "PBI_MODELING_MCP_ACCESS_TOKEN=" not in combined
    for placeholder in (
        "<workspace-guid>",
        "<semantic-model-guid>",
        "<uri-encoded-workspace>",
        "<semantic-model-name>",
    ):
        assert placeholder in combined


def test_databricks_agent_access_is_routed_and_complete() -> None:
    skill = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "SKILL.md"
    ).read_text(encoding="utf-8")
    runbook_path = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "databricks-agent-access.md"
    )
    runbook = runbook_path.read_text(encoding="utf-8")

    assert "references/databricks-agent-access.md" in skill
    for trigger in (
        "OAuth U2M/M2M",
        "CLI profiles",
        "Python SDK",
        "Genie Conversation API",
        "Databricks MCP",
    ):
        assert trigger in skill

    for heading in (
        "## Authentication decision",
        "## Capability proof before data access",
        "## Permission boundaries",
        "## OpenCode command surface",
        "## Direct Genie Conversation API",
        "## Genie MCP and SQL MCP boundaries",
        "## Deterministic finance validation",
        "## Timers, polling, and apparent hangs",
        "## Failure taxonomy",
        "## Sanitized receipts",
        "## Primary references",
    ):
        assert heading in runbook

    for literal in (
        "OAuth user-to-machine",
        "WorkspaceClient(profile=PROFILE)",
        "private approved allowlist",
        "/api/2.0/mcp/genie/",
        "/api/2.0/mcp/sql",
        "read and write",
        "runwatch",
        "UNVERIFIED_HYPOTHESIS",
    ):
        assert literal in runbook

    assert "### Sanitizing adapter inventory" in runbook
    assert "full objects can contain" in runbook
    assert "project each returned object immediately" in runbook
    assert "fail closed with `MISSING_PREREQUISITE`" in runbook
    assert "--output json" not in runbook
    assert re.search(r"list\s*\(\s*w\.[A-Za-z_]+\.list\s*\(", runbook) is None
    assert "$databricks current-user me" not in runbook
    assert "$databricks warehouses list" not in runbook


def test_dbx_capabilities_is_metadata_only_and_token_safe() -> None:
    config = json.loads((ROOT / "opencode.json").read_text(encoding="utf-8"))
    command = config["command"]["dbx-capabilities"]
    template = command["template"]

    assert command["agent"] == "finance-scout"
    assert "MISSING_PREREQUISITE" in template
    assert "bounded nonrecursive approved workspace path" in template
    assert "aliases, counts, capability booleans" in template
    for prohibited in (
        "Never request, print, persist, decode, export, or accept a bearer token",
        "Do not run SQL",
        "start or stop compute",
        "export or run a notebook",
        "run or cancel a job",
        "recurse from a workspace/catalog root",
        "change grants",
        "install packages",
        "modify any Databricks object",
    ):
        assert prohibited in template


def test_dbx_genie_probe_discloses_state_compute_and_unverified_result() -> None:
    config = json.loads((ROOT / "opencode.json").read_text(encoding="utf-8"))
    command = config["command"]["dbx-genie-probe"]
    template = command["template"]

    assert command["agent"] == "finance-compute"
    assert "one task-scoped Genie interaction" in template
    assert "conversation state" in template
    assert "read query/warehouse compute" in template
    assert "deadline, poll bound, result row/byte caps" in template
    assert "generated-SQL hash" in template
    assert "broad Databricks SQL MCP" in template
    assert "must remain UNVERIFIED_HYPOTHESIS" in template
    assert "Do not use" in template
    assert "or claim VERIFIED" in template


def test_power_bi_report_authoring_is_routed_and_complete() -> None:
    skill = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "SKILL.md"
    ).read_text(encoding="utf-8")
    runbook = (
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "power-bi-report-authoring.md"
    ).read_text(encoding="utf-8")

    assert "references/power-bi-report-authoring.md" in skill
    for trigger in (
        "report pages",
        "blank canvas space",
        "PBIP/PBIR",
        "Report Authoring/Design/Planner/Management",
        "Desktop Bridge",
        "getDefinition?format=PBIR",
        "updateDefinition",
    ):
        assert trigger in skill

    for literal in (
        "powerbi-report-authoring",
        "powerbi-report-management",
        "Power BI Desktop Bridge",
        "PBIR-Legacy",
        "getDefinition?format=PBIR",
        "updateDefinition",
        "whole-definition replacement",
        "sensitivity label",
        "202 Accepted",
        "Retry-After",
    ):
        assert literal in runbook

    for gate in (
        "### Gate A: read-only baseline",
        "### Gate B: local candidate",
        "### Gate C: development deployment",
        "### Gate D: shared or production deployment",
    ):
        assert gate in runbook


def test_new_reference_internal_links_resolve() -> None:
    references = [
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "databricks-agent-access.md",
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "power-bi-report-authoring.md",
    ]

    for reference in references:
        content = reference.read_text(encoding="utf-8")
        for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", content):
            if target.startswith(("https://", "http://", "#")):
                continue
            assert (reference.parent / target).resolve().is_file(), (
                reference,
                target,
            )


def test_new_guidance_has_no_live_databricks_or_auth_identifiers() -> None:
    files = [
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "databricks-agent-access.md",
        ROOT
        / ".opencode"
        / "skills"
        / "finance-data-reliability"
        / "references"
        / "power-bi-report-authoring.md",
    ]
    combined = "\n".join(path.read_text(encoding="utf-8") for path in files)

    assert re.search(r"(?i)\bdapi[a-z0-9]{20,}\b", combined) is None
    assert re.search(
        r"(?i)https://adb-[0-9]+\.[0-9]+\.azuredatabricks\.net", combined
    ) is None
    assert re.search(r"(?i)Authorization\s*:\s*Bearer\s+\S+", combined) is None
    assert re.search(
        r"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b",
        combined,
    ) is None
    assert re.search(
        r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", combined
    ) is None
