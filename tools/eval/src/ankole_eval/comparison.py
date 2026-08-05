from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from ankole_eval import SCHEMA_VERSION
from ankole_eval.suite import EvalError

_HARNESS_AXES = (
    "agent",
    "model",
    "environment",
    "agent_setup_timeout_sec",
    "agent_kwargs",
    "agent_env",
    "required_env",
)


def compare_runs(baseline_dir: Path, candidate_dir: Path) -> tuple[dict[str, Any], int]:
    baseline = _load_run(baseline_dir)
    candidate = _load_run(candidate_dir)
    reasons: list[str] = []

    if baseline["suite"].get("digest") != candidate["suite"].get("digest"):
        reasons.append("suite contract or task digests changed")
    if baseline["runner"].get("version") != candidate["runner"].get("version"):
        reasons.append("Harbor version changed")
    if baseline["runner"].get("python") != candidate["runner"].get("python"):
        reasons.append("Python version changed")

    axes = _changed_axes(baseline, candidate)
    if len(axes) > 1:
        reasons.append("more than one experiment axis changed: " + ", ".join(axes))
    if "source" in axes and (
        baseline.get("source", {}).get("dirty") is True
        or candidate.get("source", {}).get("dirty") is True
    ):
        reasons.append("a source comparison includes a dirty workspace")

    baseline_summary = _load_related(baseline_dir, baseline, "summary")
    candidate_summary = _load_related(candidate_dir, candidate, "summary")
    baseline_evidence = _load_related(baseline_dir, baseline, "evidence")
    candidate_evidence = _load_related(candidate_dir, candidate, "evidence")

    primary = baseline["suite"].get("primary")
    if not isinstance(primary, dict):
        raise EvalError("Baseline run has no frozen primary outcome.")
    baseline_value = _reward_mean(baseline_summary, primary)
    candidate_value = _reward_mean(candidate_summary, primary)
    improvement = _improvement(baseline_value, candidate_value, primary)
    minimum_delta = primary.get("minimum_delta")
    primary_passed = (
        isinstance(minimum_delta, (int, float))
        and improvement is not None
        and improvement >= float(minimum_delta)
    )

    baseline_infrastructure = len(_list(baseline_summary.get("infrastructure_errors")))
    candidate_infrastructure = len(
        _list(candidate_summary.get("infrastructure_errors"))
    )
    evidence_passed = bool(baseline_evidence.get("meets_minimum")) and bool(
        candidate_evidence.get("meets_minimum")
    )
    candidate_guardrails = _list(candidate_summary.get("guardrails"))
    guardrails_passed = bool(candidate_guardrails) and all(
        isinstance(guardrail, dict) and guardrail.get("passed") is True
        for guardrail in candidate_guardrails
    )
    statuses_passed = (
        baseline.get("status") == "complete" and candidate.get("status") == "complete"
    )

    comparable = not reasons
    passed = (
        comparable
        and statuses_passed
        and baseline_infrastructure == 0
        and candidate_infrastructure == 0
        and evidence_passed
        and guardrails_passed
        and primary_passed
    )
    comparison = {
        "schema_version": SCHEMA_VERSION,
        "comparable": comparable,
        "passed": passed,
        "reasons": reasons,
        "suite": baseline["suite"].get("id"),
        "baseline": {
            "run_id": baseline.get("run_id"),
            "variant": baseline.get("variant", {}).get("id"),
            "primary_mean": baseline_value,
            "infrastructure_errors": baseline_infrastructure,
            "evidence_grade": baseline_evidence.get("actual_grade"),
        },
        "candidate": {
            "run_id": candidate.get("run_id"),
            "variant": candidate.get("variant", {}).get("id"),
            "primary_mean": candidate_value,
            "infrastructure_errors": candidate_infrastructure,
            "evidence_grade": candidate_evidence.get("actual_grade"),
            "guardrails": candidate_guardrails,
        },
        "experiment_axes": axes,
        "primary": {
            **primary,
            "improvement": improvement,
            "passed": primary_passed,
        },
        "gates": {
            "statuses_complete": statuses_passed,
            "infrastructure_clean": (
                baseline_infrastructure == 0 and candidate_infrastructure == 0
            ),
            "evidence": evidence_passed,
            "guardrails": guardrails_passed,
        },
    }
    if not comparable:
        return comparison, 2
    return comparison, 0 if passed else 1


def _changed_axes(baseline: dict[str, Any], candidate: dict[str, Any]) -> list[str]:
    axes: list[str] = []
    if baseline.get("source", {}).get("workspace_digest") != candidate.get(
        "source", {}
    ).get("workspace_digest"):
        axes.append("source")
    baseline_harness = baseline.get("variant", {}).get("harness", {})
    candidate_harness = candidate.get("variant", {}).get("harness", {})
    for axis in _HARNESS_AXES:
        if baseline_harness.get(axis) != candidate_harness.get(axis):
            axes.append(axis)
    return axes


def _load_run(run_dir: Path) -> dict[str, Any]:
    value = _load_json(run_dir.resolve() / "run.json")
    if value.get("schema_version") != SCHEMA_VERSION:
        raise EvalError(f"Unsupported run schema in {run_dir}.")
    for field in ("suite", "variant", "source", "runner", "summary", "evidence"):
        if field not in value:
            raise EvalError(f"Run {run_dir} has no {field!r} field.")
    return value


def _load_related(run_dir: Path, run: dict[str, Any], field: str) -> dict[str, Any]:
    relative = run.get(field)
    if not isinstance(relative, str):
        raise EvalError(f"Run {run_dir} has an invalid {field!r} path.")
    root = run_dir.resolve()
    path = (root / relative).resolve()
    if path.parent != root:
        raise EvalError(f"Run {run_dir} has an unsafe {field!r} path.")
    return _load_json(path)


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise EvalError(f"Cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise EvalError(f"{path} is not a JSON object.")
    return value


def _reward_mean(summary: dict[str, Any], primary: dict[str, Any]) -> float | None:
    cohort_name = primary.get("cohort")
    reward_name = primary.get("reward")
    cohorts = summary.get("cohorts")
    cohort = cohorts.get(cohort_name) if isinstance(cohorts, dict) else None
    means = cohort.get("reward_means") if isinstance(cohort, dict) else None
    value = means.get(reward_name) if isinstance(means, dict) else None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


def _improvement(
    baseline: float | None, candidate: float | None, primary: dict[str, Any]
) -> float | None:
    if baseline is None or candidate is None:
        return None
    if primary.get("direction") == "maximize":
        return candidate - baseline
    if primary.get("direction") == "minimize":
        return baseline - candidate
    return None


def _list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []
