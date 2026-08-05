from __future__ import annotations

import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from ankole_eval import SCHEMA_VERSION
from ankole_eval.suite import Suite


def summarize_job(job_dir: Path, suite: Suite, harbor_exit_code: int) -> dict[str, Any]:
    infrastructure_errors: list[dict[str, Any]] = []
    result = _read_result(job_dir, infrastructure_errors)
    embedded_trials = result.get("trial_results") if result is not None else None
    if isinstance(embedded_trials, list) and embedded_trials:
        raw_trials = embedded_trials
    else:
        raw_trials = _read_trial_results(job_dir, infrastructure_errors)
    if not isinstance(raw_trials, list):
        infrastructure_errors.append(
            _error("InvalidJobResult", None, "trial_results is not a list")
        )
        raw_trials = []

    trials: list[dict[str, Any]] = []
    counts: Counter[str] = Counter()
    required_rewards = {
        suite.primary.reward,
        *(guardrail.reward for guardrail in suite.guardrails),
    }
    for raw_trial in raw_trials:
        if not isinstance(raw_trial, dict):
            infrastructure_errors.append(
                _error("InvalidTrialResult", None, "trial result is not an object")
            )
            continue
        task_name = raw_trial.get("task_name")
        trial_name = raw_trial.get("trial_name")
        if not isinstance(task_name, str) or task_name not in suite.task_ids:
            infrastructure_errors.append(
                _error(
                    "UnknownTask",
                    trial_name if isinstance(trial_name, str) else None,
                    f"unknown task {task_name!r}",
                )
            )
            continue

        counts[task_name] += 1
        exception = raw_trial.get("exception_info")
        if isinstance(exception, dict):
            infrastructure_errors.append(
                _error(
                    str(exception.get("exception_type", "TrialException")),
                    trial_name if isinstance(trial_name, str) else None,
                    str(exception.get("exception_message", "trial failed")),
                )
            )

        rewards = _rewards(raw_trial)
        for reward in sorted(required_rewards - rewards.keys()):
            infrastructure_errors.append(
                _error(
                    "MissingReward",
                    trial_name if isinstance(trial_name, str) else None,
                    f"task {task_name!r} has no {reward!r} reward",
                )
            )
        trials.append(
            {
                "task": task_name,
                "cohort": suite.cohort_for(task_name),
                "trial": trial_name,
                "rewards": rewards,
                "exception": exception,
            }
        )

    for task_id in suite.task_ids:
        if counts[task_id] != 1:
            infrastructure_errors.append(
                _error(
                    "TrialCardinality",
                    None,
                    f"task {task_id!r} produced {counts[task_id]} trials; expected 1",
                )
            )
    if harbor_exit_code != 0:
        infrastructure_errors.append(
            _error(
                "HarborExit",
                None,
                f"Harbor exited with status {harbor_exit_code}",
            )
        )

    cohorts = {
        "all": _aggregate(trials),
        "selection": _aggregate(
            [trial for trial in trials if trial["cohort"] == "selection"]
        ),
        "held_out": _aggregate(
            [trial for trial in trials if trial["cohort"] == "held_out"]
        ),
    }
    guardrails = []
    for guardrail in suite.guardrails:
        cohort = cohorts[guardrail.cohort]
        value = cohort["reward_means"].get(guardrail.reward)
        count = cohort["reward_counts"].get(guardrail.reward, 0)
        guardrails.append(
            {
                **guardrail.as_dict(),
                "actual_mean": value,
                "n_scored": count,
                "passed": (
                    value is not None
                    and count == cohort["n_trials"]
                    and value >= guardrail.minimum_mean
                ),
            }
        )

    return {
        "schema_version": SCHEMA_VERSION,
        "harbor_exit_code": harbor_exit_code,
        "primary": suite.primary.as_dict(),
        "cohorts": cohorts,
        "guardrails": guardrails,
        "infrastructure_errors": infrastructure_errors,
        "trials": trials,
    }


def _read_result(
    job_dir: Path, infrastructure_errors: list[dict[str, Any]]
) -> dict[str, Any] | None:
    path = job_dir / "result.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        infrastructure_errors.append(
            _error("MissingJobResult", None, f"Harbor did not write {path}")
        )
        return None
    except (OSError, json.JSONDecodeError) as exc:
        infrastructure_errors.append(
            _error("InvalidJobResult", None, f"Cannot read {path}: {exc}")
        )
        return None
    if not isinstance(value, dict):
        infrastructure_errors.append(
            _error("InvalidJobResult", None, f"{path} is not a JSON object")
        )
        return None
    return value


def _read_trial_results(
    job_dir: Path, infrastructure_errors: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    trials: list[dict[str, Any]] = []
    if not job_dir.is_dir():
        return trials
    for child in sorted(job_dir.iterdir(), key=lambda path: path.name):
        if not child.is_dir():
            continue
        path = child / "result.json"
        if not path.exists():
            continue
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            infrastructure_errors.append(
                _error("InvalidTrialResult", child.name, f"Cannot read {path}: {exc}")
            )
            continue
        if not isinstance(value, dict):
            infrastructure_errors.append(
                _error("InvalidTrialResult", child.name, f"{path} is not an object")
            )
            continue
        trials.append(value)
    return trials


def _rewards(raw_trial: dict[str, Any]) -> dict[str, float]:
    verifier = raw_trial.get("verifier_result")
    raw_rewards = verifier.get("rewards") if isinstance(verifier, dict) else None
    if not isinstance(raw_rewards, dict):
        return {}
    rewards: dict[str, float] = {}
    for key, value in raw_rewards.items():
        if (
            isinstance(key, str)
            and isinstance(value, (int, float))
            and not isinstance(value, bool)
        ):
            rewards[key] = float(value)
    return rewards


def _aggregate(trials: list[dict[str, Any]]) -> dict[str, Any]:
    values: dict[str, list[float]] = defaultdict(list)
    for trial in trials:
        for reward, value in trial["rewards"].items():
            values[reward].append(value)
    return {
        "n_trials": len(trials),
        "n_exceptions": sum(trial["exception"] is not None for trial in trials),
        "reward_counts": {
            reward: len(items) for reward, items in sorted(values.items())
        },
        "reward_means": {
            reward: sum(items) / len(items) for reward, items in sorted(values.items())
        },
    }


def _error(error_type: str, trial: str | None, message: str) -> dict[str, Any]:
    return {"type": error_type, "trial": trial, "message": message}
