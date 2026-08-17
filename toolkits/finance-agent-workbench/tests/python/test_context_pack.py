import copy
import json
import re
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError


ROOT = Path(__file__).resolve().parents[2]


def _load_json(relative_path: str) -> dict:
    return json.loads((ROOT / relative_path).read_text(encoding="utf-8"))


def test_context_catalog_routes_to_real_files() -> None:
    catalog = _load_json("context/catalog.json")

    assert catalog["version"] == 1
    for relative_path in catalog["always"]:
        assert (ROOT / relative_path).is_file(), relative_path

    for workflow_group in ("task_workflows", "control_workflows"):
        for workflow in catalog[workflow_group].values():
            assert (ROOT / workflow["skill"]).is_file(), workflow["skill"]
            for relative_path in workflow["references"]:
                assert (ROOT / relative_path).is_file(), relative_path

    task_schema = _load_json("schemas/task-brief.schema.json")
    schema_workflows = set(task_schema["properties"]["workflow_type"]["enum"])
    assert schema_workflows == set(catalog["task_workflows"])

    assert catalog["private_overlay"]["path"] == "context/local-context.json"
    assert (ROOT / catalog["private_overlay"]["example"]).is_file()

    work_context = (
        ".opencode/skills/finance-report-migration/references/work-context.md"
    )
    assert work_context not in catalog["always"]
    assert work_context in catalog["task_workflows"]["inventory"]["references"]
    assert work_context not in catalog["task_workflows"]["platform_discovery"]["references"]
    assert work_context not in catalog["task_workflows"]["failure_diagnosis"]["references"]

    task_example = _load_json("templates/task-brief.example.json")
    route = catalog["task_workflows"][task_example["workflow_type"]]
    required_paths = set(catalog["always"]) | {route["skill"]} | set(route["references"])
    selected_paths = {item["path"] for item in task_example["selected_context"]}
    assert required_paths <= selected_paths

    handoff_example = _load_json("templates/run-handoff.example.json")
    handoff_paths = {item["path"] for item in handoff_example["context_manifest"]}
    assert required_paths <= handoff_paths


def test_migration_skills_have_triggering_frontmatter() -> None:
    expected = {
        "bootstrap-finance-context",
        "prepare-finance-task",
        "inventory-finance-report",
        "resolve-finance-semantics",
        "migrate-finance-query",
        "reconcile-finance-report",
        "profile-finance-refresh",
        "capture-agent-failure",
        "handoff-finance-run",
        "finance-report-migration",
    }
    skills_root = ROOT / ".opencode" / "skills"
    observed = set()

    for skill_path in skills_root.glob("*/SKILL.md"):
        content = skill_path.read_text(encoding="utf-8")
        name_match = re.search(r"(?m)^name:\s*([^\s]+)\s*$", content)
        description_match = re.search(r"(?m)^description:\s*(\S.+)$", content)
        if name_match and name_match.group(1) in expected:
            observed.add(name_match.group(1))
            assert name_match.group(1) == skill_path.parent.name
            assert description_match is not None

    assert observed == expected


def test_ecc_intercompany_brief_is_verbatim_notebook_cell_and_routed() -> None:
    catalog = _load_json("context/catalog.json")
    brief_path = (
        ".opencode/skills/finance-report-migration/references/"
        "ecc-intercompany-reconciliation-v7-implementation-brief.md"
    )

    brief = (ROOT / brief_path).read_text(encoding="utf-8")
    assert brief.startswith(
        "%md\n# Implementation Brief: Correct and Harden the ECC "
        "Intercompany Reconciliation POC\n"
    )
    assert not brief.startswith("---")
    assert "```" not in brief
    for heading in (
        "## 1. Correct the reporting population",
        "## 2. Protect the ECC record grain",
        "## 3. Correct partner assignment",
        "## 4. Separate balance coverage from match eligibility",
        "## 5. Rebuild candidate generation",
        "## 6. Support split-OU and one-to-many billing",
        "## 7. Replace or accurately label the single-pass matcher",
        "## 8. Govern tolerances",
        "## 9. Correct summary mathematics",
        "## 10. Required validation gates",
    ):
        assert heading in brief

    migration_skill = (
        ROOT / ".opencode" / "skills" / "finance-report-migration" / "SKILL.md"
    ).read_text(encoding="utf-8")
    assert "ecc-intercompany-reconciliation-v7-implementation-brief.md" in (
        migration_skill
    )

    for workflow_type in ("query_migration", "reconciliation"):
        route = catalog["task_workflows"][workflow_type]
        narrow_skill = (ROOT / route["skill"]).read_text(encoding="utf-8")
        assert "finance-report-migration" in narrow_skill


SCHEMA_EXAMPLES = (
    ("schemas/task-brief.schema.json", "templates/task-brief.example.json"),
    ("schemas/run-handoff.schema.json", "templates/run-handoff.example.json"),
    (
        "schemas/finance-semantic-contract.schema.json",
        "templates/finance-semantic-contract.example.json",
    ),
    ("schemas/report-inventory.schema.json", "templates/report-inventory.example.json"),
    ("schemas/failure-case.schema.json", "templates/failure-case.example.json"),
)


@pytest.mark.parametrize(("schema_path", "example_path"), SCHEMA_EXAMPLES)
def test_contract_example_validates_against_draft_2020_12(
    schema_path: str, example_path: str
) -> None:
    schema = _load_json(schema_path)
    example = _load_json(example_path)
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema).validate(example)


def test_task_brief_rejects_authority_and_budget_bypass() -> None:
    schema = _load_json("schemas/task-brief.schema.json")
    validator = Draft202012Validator(schema)
    example = _load_json("templates/task-brief.example.json")

    excessive_effect = copy.deepcopy(example)
    excessive_effect["allowed_effects"] = ["LOCAL_READ", "LIVE_HIGH_IMPACT"]
    with pytest.raises(ValidationError):
        validator.validate(excessive_effect)

    excessive_gate = copy.deepcopy(example)
    excessive_gate["highest_permitted_gate"] = "LIVE_HIGH_IMPACT"
    with pytest.raises(ValidationError):
        validator.validate(excessive_gate)

    gate_not_allowed = copy.deepcopy(example)
    gate_not_allowed["highest_permitted_gate"] = "EXTERNAL_READ_OR_COMPUTE"
    with pytest.raises(ValidationError):
        validator.validate(gate_not_allowed)

    inverse_gate_bypass = copy.deepcopy(example)
    inverse_gate_bypass["mode"] = "high-impact"
    inverse_gate_bypass["allowed_effects"] = ["LOCAL_READ", "LIVE_HIGH_IMPACT"]
    inverse_gate_bypass["highest_permitted_gate"] = "LOCAL_READ"
    with pytest.raises(ValidationError):
        validator.validate(inverse_gate_bypass)

    negative_budget = copy.deepcopy(example)
    negative_budget["tool_budget"]["max_files"] = -1
    with pytest.raises(ValidationError):
        validator.validate(negative_budget)

    unknown_budget = copy.deepcopy(example)
    unknown_budget["tool_budget"]["unbounded_queries"] = 1
    with pytest.raises(ValidationError):
        validator.validate(unknown_budget)

    oversized_budget = copy.deepcopy(example)
    oversized_budget["tool_budget"]["max_rows"] = 1_000_001
    with pytest.raises(ValidationError):
        validator.validate(oversized_budget)


def test_handoff_rejects_contradictory_terminal_status() -> None:
    schema = _load_json("schemas/run-handoff.schema.json")
    validator = Draft202012Validator(schema)
    example = _load_json("templates/run-handoff.example.json")

    contradictory_pass = copy.deepcopy(example)
    contradictory_pass["status"] = "passed"
    with pytest.raises(ValidationError):
        validator.validate(contradictory_pass)

    blockerless_block = copy.deepcopy(example)
    blockerless_block["status"] = "blocked"
    blockerless_block["blocker"] = None
    with pytest.raises(ValidationError):
        validator.validate(blockerless_block)

    failed_without_failed_check = copy.deepcopy(example)
    failed_without_failed_check["status"] = "failed"
    with pytest.raises(ValidationError):
        validator.validate(failed_without_failed_check)

    excessive_gate = copy.deepcopy(example)
    excessive_gate["highest_permitted_gate"] = "LIVE_HIGH_IMPACT"
    with pytest.raises(ValidationError):
        validator.validate(excessive_gate)

    valid_pass = copy.deepcopy(example)
    valid_pass["status"] = "passed"
    valid_pass["unresolved"] = []
    valid_pass["blocker"] = None
    valid_pass["claims"][0]["classification"] = "verified"
    valid_pass["checks"] = [
        {
            "name": "artifact-fingerprint",
            "status": "passed",
            "evidence_ref": "receipt:source-fingerprint",
        }
    ]
    validator.validate(valid_pass)


def test_approved_semantic_contract_requires_resolution_and_evidence() -> None:
    schema = _load_json("schemas/finance-semantic-contract.schema.json")
    validator = Draft202012Validator(schema)
    example = _load_json("templates/finance-semantic-contract.example.json")

    unresolved_approval = copy.deepcopy(example)
    unresolved_approval["status"] = "approved"
    with pytest.raises(ValidationError):
        validator.validate(unresolved_approval)

    empty_grain = copy.deepcopy(example)
    empty_grain["status"] = "approved"
    empty_grain["grain"] = ""
    empty_grain["unresolved_questions"] = []
    with pytest.raises(ValidationError):
        validator.validate(empty_grain)


def test_private_context_and_run_state_are_ignored() -> None:
    ignored = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()

    for pattern in (
        "context/local-context.json",
        ".finance-context/",
        "task-state/",
    ):
        assert pattern in ignored


def test_context_boot_and_positive_fallback_are_always_loaded() -> None:
    agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    assert "Context boot protocol" in agents
    assert "finance-report-migration" in agents
    assert "MISSING_PREREQUISITE blocks only the exact unavailable action" in agents
    assert "repo-local candidate" in agents


def test_context_commands_exist_and_route_to_exact_skills() -> None:
    config = _load_json("opencode.json")
    expected = {
        "bootstrap-finance-context": "bootstrap-finance-context",
        "prepare-finance-task": "prepare-finance-task",
        "inventory-finance-report": "inventory-finance-report",
        "resolve-finance-semantics": "resolve-finance-semantics",
        "migrate-finance-query": "migrate-finance-query",
        "reconcile-finance-report": "reconcile-finance-report",
        "profile-finance-refresh": "profile-finance-refresh",
        "capture-agent-failure": "capture-agent-failure",
        "handoff-finance-run": "handoff-finance-run",
    }

    for command_name, skill_name in expected.items():
        command = config["command"][command_name]
        assert skill_name in command["template"]
        assert command["agent"] in {
            "finance-scout",
            "finance-compute",
            "finance-build",
            "finance-verifier",
            "finance-deep",
        }


def test_model_policy_does_not_grant_deep_role_more_authority() -> None:
    policy = _load_json("policies/model-routing.json")
    assert policy["roles"]["investigator"]["writes"] == "no-broader-than-builder"
    assert "do not let the model grade itself" in policy["promotion_rule"]


def test_open_code_roles_are_model_agnostic() -> None:
    config = _load_json("opencode.json")
    assert "model" not in config
    for role in (
        "finance-scout",
        "finance-compute",
        "finance-build",
        "finance-verifier",
        "finance-deep",
    ):
        assert "model" not in config["agent"][role]
        assert "reasoningEffort" not in config["agent"][role]


def test_read_roles_deny_shell_and_genie_uses_disclosed_compute_role() -> None:
    config = _load_json("opencode.json")
    for role in ("finance-scout", "finance-verifier", "finance-compute"):
        assert config["agent"][role]["permission"]["edit"] == "deny"
        assert config["agent"][role]["permission"]["bash"] == {"*": "deny"}

    for role in ("finance-build", "finance-deep"):
        assert config["agent"][role]["permission"]["bash"] == {"*": "ask"}

    assert config["command"]["dbx-genie-probe"]["agent"] == "finance-compute"
    assert config["command"]["validate"]["agent"] == "finance-build"


def test_private_context_fails_closed_without_projection_tooling() -> None:
    agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
    bootstrap = (
        ROOT / ".opencode" / "skills" / "bootstrap-finance-context" / "SKILL.md"
    ).read_text(encoding="utf-8")
    prepare = _load_json("opencode.json")["command"]["prepare-finance-task"]["template"]

    for content in (agents, bootstrap, prepare):
        normalized = " ".join(content.split())
        assert "pre-generated approved projection" in normalized
        assert "MISSING_PREREQUISITE" in normalized
        assert "never ask the model to redact" in normalized.lower()


def test_task_budget_schema_matches_policy_and_has_hard_ceilings() -> None:
    policy = _load_json("policies/tool-budgets.json")
    schema = _load_json("schemas/task-brief.schema.json")
    properties = schema["$defs"]["toolBudget"]["properties"]
    assert set(properties) == set(policy["task_override_fields"])
    assert policy["schema_ceilings"] == {
        key: definition["maximum"] for key, definition in properties.items()
    }


def test_public_context_contains_no_live_auth_or_identity_values() -> None:
    paths = [ROOT / "AGENTS.md", ROOT / "README.md", ROOT / "opencode.json"]
    for pattern in (
        "docs/**/*.md",
        ".opencode/skills/**/*.md",
        "context/*.json",
        "policies/*.json",
        "schemas/*.json",
        "templates/*.json",
        "templates/*.md",
        "scripts/*.ps1",
        "src/**/*.py",
    ):
        paths.extend(sorted(ROOT.glob(pattern)))
    combined = "\n".join(path.read_text(encoding="utf-8") for path in paths)

    assert re.search(r"(?i)\bdapi[a-z0-9]{20,}\b", combined) is None
    assert re.search(r"(?i)Authorization\s*:\s*Bearer\s+\S+", combined) is None
    assert re.search(r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", combined) is None
    assert re.search(
        r"(?i)https://adb-[0-9]+\.[0-9]+\.azuredatabricks\.net", combined
    ) is None
