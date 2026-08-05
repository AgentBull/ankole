from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from ankole_eval import SCHEMA_VERSION
from ankole_eval.suite import grade_meets

_SURFACES = (
    "provider_input",
    "semantic_execution",
    "lifecycle",
    "outcome",
)


def build_evidence_index(job_dir: Path, minimum_grade: str) -> dict[str, Any]:
    job_dir = job_dir.resolve()
    trials = _job_trials(job_dir)
    indexed_trials: list[dict[str, Any]] = []
    for trial in trials:
        trial_name = trial.get("trial_name")
        task_name = trial.get("task_name")
        if not isinstance(trial_name, str) or not isinstance(task_name, str):
            continue
        trial_dir = _safe_trial_dir(job_dir, trial_name)
        surfaces: dict[str, list[dict[str, Any]]] = {
            surface: [] for surface in _SURFACES
        }
        if trial_dir is not None:
            for path in sorted(
                (item for item in trial_dir.rglob("*") if item.is_file()),
                key=lambda item: item.relative_to(trial_dir).as_posix(),
            ):
                surface = _classify(path.relative_to(trial_dir))
                if surface is None:
                    continue
                surfaces[surface].append(_file_record(path, job_dir))
        present = {surface for surface, files in surfaces.items() if files}
        indexed_trials.append(
            {
                "task": task_name,
                "trial": trial_name,
                "grade": _grade(present),
                "surfaces": surfaces,
            }
        )

    run_grade = _minimum_grade([trial["grade"] for trial in indexed_trials])
    return {
        "schema_version": SCHEMA_VERSION,
        "minimum_grade": minimum_grade,
        "actual_grade": run_grade,
        "meets_minimum": grade_meets(run_grade, minimum_grade),
        "trials": indexed_trials,
        "conventions": {
            "provider_input": "agent/evidence/provider-input/",
            "semantic_execution": (
                "agent/trajectory.json or agent/evidence/semantic-execution/"
            ),
            "lifecycle": "artifacts/evidence/lifecycle/",
            "outcome": (
                "result.json, verifier/reward.*, or verifier/evidence/outcome/"
            ),
        },
    }


def _job_trials(job_dir: Path) -> list[dict[str, Any]]:
    result_path = job_dir / "result.json"
    try:
        result = json.loads(result_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    trials = result.get("trial_results")
    if isinstance(trials, list) and trials:
        return [trial for trial in trials if isinstance(trial, dict)]

    discovered: list[dict[str, Any]] = []
    for child in sorted(job_dir.iterdir(), key=lambda path: path.name):
        if not child.is_dir():
            continue
        try:
            trial = json.loads((child / "result.json").read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(trial, dict):
            discovered.append(trial)
    return discovered


def _safe_trial_dir(job_dir: Path, trial_name: str) -> Path | None:
    candidate = (job_dir / trial_name).resolve()
    root = job_dir.resolve()
    if candidate.parent != root or not candidate.is_dir():
        return None
    return candidate


def _classify(relative: Path) -> str | None:
    parts = relative.parts
    if _contains(parts, ("agent", "evidence", "provider-input")):
        return "provider_input"
    if _contains(parts, ("agent", "evidence", "semantic-execution")):
        return "semantic_execution"
    if relative.name == "trajectory.json" and "agent" in parts:
        return "semantic_execution"
    if _contains(parts, ("artifacts", "evidence", "lifecycle")):
        return "lifecycle"
    if parts == ("result.json",):
        return "outcome"
    if _contains(parts, ("verifier", "evidence", "outcome")):
        return "outcome"
    if "verifier" in parts and relative.name in {"reward.txt", "reward.json"}:
        return "outcome"
    return None


def _contains(parts: tuple[str, ...], sequence: tuple[str, ...]) -> bool:
    length = len(sequence)
    return any(parts[index : index + length] == sequence for index in range(len(parts)))


def _file_record(path: Path, job_dir: Path) -> dict[str, Any]:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return {
        "path": path.relative_to(job_dir).as_posix(),
        "sha256": digest.hexdigest(),
        "bytes": path.stat().st_size,
    }


def _grade(present: set[str]) -> str:
    if set(_SURFACES) <= present:
        return "A"
    if {"semantic_execution", "lifecycle", "outcome"} <= present:
        return "B"
    if {"semantic_execution", "outcome"} <= present:
        return "C"
    if "outcome" in present:
        return "D"
    return "none"


def _minimum_grade(grades: list[str]) -> str:
    if not grades:
        return "none"
    order = {"none": 0, "D": 1, "C": 2, "B": 3, "A": 4}
    return min(grades, key=order.__getitem__)
