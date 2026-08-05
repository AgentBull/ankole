from __future__ import annotations

import json
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path

from ankole_eval.comparison import compare_runs


class ComparisonTest(unittest.TestCase):
    def test_repeat_run_with_passing_gates_is_comparable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "baseline"
            candidate = root / "candidate"
            _write_run(baseline, "baseline")
            _write_run(candidate, "candidate")

            comparison, exit_code = compare_runs(baseline, candidate)

            self.assertEqual(exit_code, 0)
            self.assertTrue(comparison["comparable"])
            self.assertTrue(comparison["passed"])
            self.assertEqual(comparison["experiment_axes"], [])

    def test_source_and_model_change_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "baseline"
            candidate = root / "candidate"
            _write_run(baseline, "baseline")
            _write_run(candidate, "candidate", workspace="sha256:candidate")
            run = json.loads((candidate / "run.json").read_text(encoding="utf-8"))
            run["variant"]["harness"]["model"] = "different-model"
            _write_json(candidate / "run.json", run)

            comparison, exit_code = compare_runs(baseline, candidate)

            self.assertEqual(exit_code, 2)
            self.assertFalse(comparison["comparable"])
            self.assertEqual(comparison["experiment_axes"], ["source", "model"])

    def test_contract_change_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "baseline"
            candidate = root / "candidate"
            _write_run(baseline, "baseline")
            _write_run(candidate, "candidate", contract="sha256:different")

            comparison, exit_code = compare_runs(baseline, candidate)

            self.assertEqual(exit_code, 2)
            self.assertIn(
                "suite contract or task digests changed", comparison["reasons"]
            )

    def test_dirty_source_change_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "baseline"
            candidate = root / "candidate"
            _write_run(baseline, "baseline")
            _write_run(candidate, "candidate", workspace="sha256:candidate")
            run = json.loads((candidate / "run.json").read_text(encoding="utf-8"))
            run["source"]["dirty"] = True
            _write_json(candidate / "run.json", run)

            comparison, exit_code = compare_runs(baseline, candidate)

            self.assertEqual(exit_code, 2)
            self.assertIn(
                "a source comparison includes a dirty workspace",
                comparison["reasons"],
            )


def _write_run(
    root: Path,
    variant: str,
    workspace: str = "sha256:same",
    contract: str = "sha256:contract",
) -> None:
    harness = {
        "agent": "oracle",
        "model": None,
        "environment": "docker",
        "agent_setup_timeout_sec": None,
        "agent_kwargs": {},
        "agent_env": {},
        "required_env": [],
    }
    run = {
        "schema_version": 1,
        "run_id": variant,
        "status": "complete",
        "suite": {
            "id": "smoke",
            "digest": contract,
            "primary": {
                "reward": "reward",
                "cohort": "held_out",
                "direction": "maximize",
                "minimum_delta": 0.0,
            },
        },
        "variant": {"id": variant, "harness": deepcopy(harness)},
        "source": {"workspace_digest": workspace, "dirty": False},
        "runner": {"version": "0.20.0", "python": "3.12.0"},
        "summary": "summary.json",
        "evidence": "evidence.json",
    }
    summary = {
        "cohorts": {
            "held_out": {"reward_means": {"reward": 1.0}},
        },
        "guardrails": [{"name": "safe", "passed": True}],
        "infrastructure_errors": [],
    }
    evidence = {"actual_grade": "D", "meets_minimum": True}
    _write_json(root / "run.json", run)
    _write_json(root / "summary.json", summary)
    _write_json(root / "evidence.json", evidence)


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
