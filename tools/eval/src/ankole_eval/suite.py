from __future__ import annotations

import hashlib
import json
import re
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from ankole_eval import HARBOR_VERSION, SCHEMA_VERSION

TOOL_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = TOOL_ROOT.parents[1]
SUITES_ROOT = TOOL_ROOT / "suites"

_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_ENV_PATTERN = re.compile(r"^[A-Z_][A-Z0-9_]*$")
_SENSITIVE_ENV_PATTERN = re.compile(
    r"(KEY|SECRET|TOKEN|PASSWORD|CREDENTIAL|AUTH)", re.IGNORECASE
)
_ENV_TEMPLATE_PATTERN = re.compile(r"^\$\{[A-Z_][A-Z0-9_]*\}$")
_GRADES = {"none": 0, "D": 1, "C": 2, "B": 3, "A": 4}


class EvalError(ValueError):
    """A user-actionable evaluation configuration error."""


@dataclass(frozen=True)
class PrimaryOutcome:
    reward: str
    cohort: str
    direction: str
    minimum_delta: float

    def as_dict(self) -> dict[str, Any]:
        return {
            "reward": self.reward,
            "cohort": self.cohort,
            "direction": self.direction,
            "minimum_delta": self.minimum_delta,
        }


@dataclass(frozen=True)
class Guardrail:
    name: str
    reward: str
    cohort: str
    minimum_mean: float

    def as_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "reward": self.reward,
            "cohort": self.cohort,
            "minimum_mean": self.minimum_mean,
        }


@dataclass(frozen=True)
class Harness:
    agent: str
    environment: str
    model: str | None
    agent_setup_timeout_sec: float | None
    agent_kwargs: dict[str, Any]
    agent_env: dict[str, str]
    required_env: tuple[str, ...]

    def as_dict(self) -> dict[str, Any]:
        return {
            "agent": self.agent,
            "environment": self.environment,
            "model": self.model,
            "agent_setup_timeout_sec": self.agent_setup_timeout_sec,
            "agent_kwargs": self.agent_kwargs,
            "agent_env": self.agent_env,
            "required_env": list(self.required_env),
        }


@dataclass(frozen=True)
class Variant:
    id: str
    description: str
    change_owner: str
    overrides: dict[str, Any]

    def as_dict(self) -> dict[str, Any]:
        return {
            "description": self.description,
            "change_owner": self.change_owner,
            "overrides": self.overrides,
        }


@dataclass(frozen=True)
class Suite:
    manifest_path: Path
    id: str
    capability: str
    owner: str
    selection_tasks: tuple[str, ...]
    held_out_tasks: tuple[str, ...]
    primary: PrimaryOutcome
    minimum_evidence_grade: str
    harness: Harness
    guardrails: tuple[Guardrail, ...]
    variants: dict[str, Variant]

    @property
    def root(self) -> Path:
        return self.manifest_path.parent

    @property
    def tasks_root(self) -> Path:
        return self.root / "tasks"

    @property
    def task_ids(self) -> tuple[str, ...]:
        return self.selection_tasks + self.held_out_tasks

    def task_path(self, task_id: str) -> Path:
        return self.tasks_root / task_id

    def cohort_for(self, task_id: str) -> str:
        if task_id in self.selection_tasks:
            return "selection"
        if task_id in self.held_out_tasks:
            return "held_out"
        raise EvalError(f"Harbor returned unknown task {task_id!r}.")

    def resolved_harness(self, variant_id: str) -> dict[str, Any]:
        try:
            variant = self.variants[variant_id]
        except KeyError as exc:
            choices = ", ".join(sorted(self.variants))
            raise EvalError(
                f"Unknown variant {variant_id!r}; choose one of: {choices}."
            ) from exc

        resolved = self.harness.as_dict()
        for key, value in variant.overrides.items():
            if key in {"agent_kwargs", "agent_env"}:
                resolved[key] = {**resolved[key], **value}
            else:
                resolved[key] = value

        overlap = set(resolved["agent_env"]) & set(resolved["required_env"])
        if overlap:
            names = ", ".join(sorted(overlap))
            raise EvalError(
                "Harness environment values and required_env overlap: " + names
            )
        return resolved

    def task_digests(self) -> dict[str, str]:
        return {
            task_id: hash_tree(self.task_path(task_id)) for task_id in self.task_ids
        }

    def frozen_contract(self) -> dict[str, Any]:
        contract = {
            "schema_version": SCHEMA_VERSION,
            "id": self.id,
            "capability": self.capability,
            "owner": self.owner,
            "selection_tasks": list(self.selection_tasks),
            "held_out_tasks": list(self.held_out_tasks),
            "primary": self.primary.as_dict(),
            "minimum_evidence_grade": self.minimum_evidence_grade,
            "harness": self.harness.as_dict(),
            "guardrails": [guardrail.as_dict() for guardrail in self.guardrails],
            "variants": {
                variant_id: self.variants[variant_id].as_dict()
                for variant_id in sorted(self.variants)
            },
            "task_digests": self.task_digests(),
        }
        contract["digest"] = digest_json(contract)
        return contract


def load_suite(reference: str | Path) -> Suite:
    manifest_path = _resolve_manifest(reference)
    try:
        raw = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise EvalError(f"Cannot read {manifest_path}: {exc}") from exc

    _only_keys(
        raw,
        {
            "schema_version",
            "id",
            "capability",
            "owner",
            "selection_tasks",
            "held_out_tasks",
            "primary",
            "evidence",
            "harness",
            "guardrails",
            "variants",
        },
        "eval.toml",
    )

    schema_version = raw.get("schema_version")
    if schema_version != SCHEMA_VERSION:
        raise EvalError(
            f"eval.toml schema_version must be {SCHEMA_VERSION}, got "
            f"{schema_version!r}."
        )

    suite_id = _identifier(raw.get("id"), "id")
    capability = _nonempty_string(raw.get("capability"), "capability")
    owner = _nonempty_string(raw.get("owner"), "owner")
    selection_tasks = _task_ids(raw.get("selection_tasks"), "selection_tasks")
    held_out_tasks = _task_ids(raw.get("held_out_tasks"), "held_out_tasks")
    overlap = set(selection_tasks) & set(held_out_tasks)
    if overlap:
        raise EvalError(
            "selection_tasks and held_out_tasks overlap: " + ", ".join(sorted(overlap))
        )

    primary = _parse_primary(_table(raw.get("primary"), "primary"))
    evidence = _table(raw.get("evidence"), "evidence")
    _only_keys(evidence, {"minimum_grade"}, "evidence")
    minimum_grade = evidence.get("minimum_grade")
    if minimum_grade not in {"A", "B", "C", "D"}:
        raise EvalError("evidence.minimum_grade must be A, B, C, or D.")

    harness = _parse_harness(_table(raw.get("harness"), "harness"), "harness")
    guardrails = _parse_guardrails(raw.get("guardrails"))
    variants = _parse_variants(raw.get("variants"))

    suite = Suite(
        manifest_path=manifest_path,
        id=suite_id,
        capability=capability,
        owner=owner,
        selection_tasks=selection_tasks,
        held_out_tasks=held_out_tasks,
        primary=primary,
        minimum_evidence_grade=minimum_grade,
        harness=harness,
        guardrails=guardrails,
        variants=variants,
    )
    _validate_task_layout(suite)
    for variant_id in suite.variants:
        suite.resolved_harness(variant_id)
    return suite


def validate_harbor_tasks(suite: Suite) -> None:
    from importlib.metadata import version

    from harbor.models.task.task import Task

    installed = version("harbor")
    if installed != HARBOR_VERSION:
        raise EvalError(
            f"Harbor {HARBOR_VERSION} is required, but {installed} is installed."
        )

    for task_id in suite.task_ids:
        task_path = suite.task_path(task_id)
        if not Task.is_valid_dir(task_path):
            raise EvalError(f"{task_path} is not a valid Harbor task.")
        task = Task(task_path)
        if task.name != task_id:
            raise EvalError(
                f"Harbor resolves {task_path.name!r} as {task.name!r}; "
                "the task name must match its directory."
            )


def grade_meets(actual: str, minimum: str) -> bool:
    return _GRADES.get(actual, -1) >= _GRADES[minimum]


def digest_json(value: Any) -> str:
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def hash_tree(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(
        root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()
    ):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        if path.is_symlink():
            digest.update(b"L\0" + relative + b"\0")
            digest.update(path.readlink().as_posix().encode("utf-8"))
        elif path.is_file():
            digest.update(b"F\0" + relative + b"\0")
            with path.open("rb") as file:
                while chunk := file.read(1024 * 1024):
                    digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def _resolve_manifest(reference: str | Path) -> Path:
    candidate = Path(reference).expanduser()
    if not candidate.is_absolute():
        local = Path.cwd() / candidate
        candidate = local if local.exists() else SUITES_ROOT / candidate
    if candidate.is_dir():
        candidate = candidate / "eval.toml"
    try:
        return candidate.resolve(strict=True)
    except FileNotFoundError as exc:
        raise EvalError(f"Evaluation suite not found: {reference}") from exc


def _validate_task_layout(suite: Suite) -> None:
    if not suite.tasks_root.is_dir():
        raise EvalError(f"Suite has no tasks directory: {suite.tasks_root}")

    listed = set(suite.task_ids)
    discovered = {
        path.name
        for path in suite.tasks_root.iterdir()
        if path.is_dir() and (path / "task.toml").is_file()
    }
    missing = listed - discovered
    extra = discovered - listed
    if missing:
        raise EvalError("Missing task directories: " + ", ".join(sorted(missing)))
    if extra:
        raise EvalError("Unlisted task directories: " + ", ".join(sorted(extra)))

    for task_id in suite.task_ids:
        config_path = suite.task_path(task_id) / "task.toml"
        try:
            config = tomllib.loads(config_path.read_text(encoding="utf-8"))
        except (OSError, tomllib.TOMLDecodeError) as exc:
            raise EvalError(f"Cannot read {config_path}: {exc}") from exc
        environment = config.get("environment")
        if not isinstance(environment, dict) or "network_mode" not in environment:
            raise EvalError(
                f"{config_path} must declare environment.network_mode explicitly."
            )


def _parse_primary(raw: dict[str, Any]) -> PrimaryOutcome:
    _only_keys(
        raw,
        {"reward", "cohort", "direction", "minimum_delta"},
        "primary",
    )
    reward = _nonempty_string(raw.get("reward"), "primary.reward")
    cohort = raw.get("cohort")
    if cohort not in {"selection", "held_out", "all"}:
        raise EvalError("primary.cohort must be selection, held_out, or all.")
    direction = raw.get("direction")
    if direction not in {"maximize", "minimize"}:
        raise EvalError("primary.direction must be maximize or minimize.")
    minimum_delta = _number(raw.get("minimum_delta"), "primary.minimum_delta")
    if minimum_delta < 0:
        raise EvalError("primary.minimum_delta must be zero or greater.")
    return PrimaryOutcome(reward, cohort, direction, minimum_delta)


def _parse_harness(raw: dict[str, Any], context: str) -> Harness:
    _only_keys(
        raw,
        {
            "agent",
            "environment",
            "model",
            "agent_setup_timeout_sec",
            "agent_kwargs",
            "agent_env",
            "required_env",
        },
        context,
    )
    agent = _nonempty_string(raw.get("agent"), f"{context}.agent")
    environment = _nonempty_string(raw.get("environment"), f"{context}.environment")
    model_value = raw.get("model")
    model = (
        _nonempty_string(model_value, f"{context}.model")
        if model_value is not None
        else None
    )
    setup_timeout_value = raw.get("agent_setup_timeout_sec")
    agent_setup_timeout_sec = (
        _number(setup_timeout_value, f"{context}.agent_setup_timeout_sec")
        if setup_timeout_value is not None
        else None
    )
    if agent_setup_timeout_sec is not None and agent_setup_timeout_sec <= 0:
        raise EvalError(f"{context}.agent_setup_timeout_sec must be greater than zero.")
    agent_kwargs = _json_mapping(raw.get("agent_kwargs", {}), f"{context}.agent_kwargs")
    agent_env = _string_mapping(raw.get("agent_env", {}), f"{context}.agent_env")
    _validate_safe_env(agent_env, f"{context}.agent_env")
    required_env = _env_names(raw.get("required_env", []), f"{context}.required_env")
    return Harness(
        agent=agent,
        environment=environment,
        model=model,
        agent_setup_timeout_sec=agent_setup_timeout_sec,
        agent_kwargs=agent_kwargs,
        agent_env=agent_env,
        required_env=required_env,
    )


def _parse_guardrails(value: Any) -> tuple[Guardrail, ...]:
    if not isinstance(value, list) or not value:
        raise EvalError("guardrails must contain at least one guardrail table.")
    guardrails: list[Guardrail] = []
    names: set[str] = set()
    for index, item in enumerate(value):
        context = f"guardrails[{index}]"
        raw = _table(item, context)
        _only_keys(raw, {"name", "reward", "cohort", "minimum_mean"}, context)
        name = _nonempty_string(raw.get("name"), f"{context}.name")
        if name in names:
            raise EvalError(f"Duplicate guardrail name: {name!r}.")
        names.add(name)
        reward = _nonempty_string(raw.get("reward"), f"{context}.reward")
        cohort = raw.get("cohort")
        if cohort not in {"selection", "held_out", "all"}:
            raise EvalError(f"{context}.cohort must be selection, held_out, or all.")
        minimum = _number(raw.get("minimum_mean"), f"{context}.minimum_mean")
        guardrails.append(Guardrail(name, reward, cohort, minimum))
    return tuple(guardrails)


def _parse_variants(value: Any) -> dict[str, Variant]:
    raw_variants = _table(value, "variants")
    if not raw_variants:
        raise EvalError("variants must contain at least one named variant.")
    variants: dict[str, Variant] = {}
    override_keys = {"agent", "environment", "model", "agent_kwargs", "agent_env"}
    for variant_id, value in raw_variants.items():
        _identifier(variant_id, f"variants.{variant_id}")
        context = f"variants.{variant_id}"
        raw = _table(value, context)
        _only_keys(raw, {"description", "change_owner", *override_keys}, context)
        description = _nonempty_string(raw.get("description"), f"{context}.description")
        change_owner = _nonempty_string(
            raw.get("change_owner"), f"{context}.change_owner"
        )
        overrides: dict[str, Any] = {}
        for key in override_keys & raw.keys():
            field = f"{context}.{key}"
            if key in {"agent", "environment", "model"}:
                overrides[key] = _nonempty_string(raw[key], field)
            elif key == "agent_kwargs":
                overrides[key] = _json_mapping(raw[key], field)
            else:
                overrides[key] = _string_mapping(raw[key], field)
                _validate_safe_env(overrides[key], field)
        variants[variant_id] = Variant(
            id=variant_id,
            description=description,
            change_owner=change_owner,
            overrides=overrides,
        )
    return variants


def _validate_safe_env(values: dict[str, str], context: str) -> None:
    for key, value in values.items():
        if not _ENV_PATTERN.fullmatch(key):
            raise EvalError(f"{context} contains invalid environment name {key!r}.")
        if _SENSITIVE_ENV_PATTERN.search(key) and not _ENV_TEMPLATE_PATTERN.fullmatch(
            value
        ):
            raise EvalError(
                f"{context}.{key} looks sensitive and must use a ${{NAME}} reference."
            )


def _only_keys(raw: dict[str, Any], allowed: set[str], context: str) -> None:
    unknown = set(raw) - allowed
    if unknown:
        raise EvalError(f"Unknown {context} fields: " + ", ".join(sorted(unknown)))


def _table(value: Any, context: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise EvalError(f"{context} must be a TOML table.")
    return value


def _nonempty_string(value: Any, context: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise EvalError(f"{context} must be a nonempty string.")
    return value.strip()


def _identifier(value: Any, context: str) -> str:
    identifier = _nonempty_string(value, context)
    if not _ID_PATTERN.fullmatch(identifier):
        raise EvalError(f"{context} must use lowercase letters, digits, and hyphens.")
    return identifier


def _task_ids(value: Any, context: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise EvalError(f"{context} must contain at least one task ID.")
    task_ids = tuple(_identifier(item, context) for item in value)
    if len(set(task_ids)) != len(task_ids):
        raise EvalError(f"{context} contains duplicate task IDs.")
    return task_ids


def _number(value: Any, context: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise EvalError(f"{context} must be a number.")
    return float(value)


def _json_mapping(value: Any, context: str) -> dict[str, Any]:
    raw = _table(value, context)
    try:
        json.dumps(raw, ensure_ascii=False)
    except (TypeError, ValueError) as exc:
        raise EvalError(f"{context} must contain JSON-compatible values.") from exc
    return raw


def _string_mapping(value: Any, context: str) -> dict[str, str]:
    raw = _table(value, context)
    if not all(
        isinstance(key, str) and isinstance(item, str) for key, item in raw.items()
    ):
        raise EvalError(f"{context} keys and values must be strings.")
    return raw


def _env_names(value: Any, context: str) -> tuple[str, ...]:
    if not isinstance(value, list):
        raise EvalError(f"{context} must be a list of environment names.")
    names: list[str] = []
    for item in value:
        if not isinstance(item, str) or not _ENV_PATTERN.fullmatch(item):
            raise EvalError(f"{context} contains invalid environment name {item!r}.")
        names.append(item)
    if len(set(names)) != len(names):
        raise EvalError(f"{context} contains duplicate environment names.")
    return tuple(names)
