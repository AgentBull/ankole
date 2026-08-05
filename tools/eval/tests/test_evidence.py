from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from ankole_eval.evidence import build_evidence_index
from ankole_eval.suite import load_suite
from ankole_eval.summary import summarize_job


class EvidenceTest(unittest.TestCase):
    def test_run_grade_is_the_lowest_trial_grade(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            job_dir = Path(directory)
            trials = [
                {"task_name": "complete", "trial_name": "complete-trial"},
                {"task_name": "outcome", "trial_name": "outcome-trial"},
            ]
            _write_json(job_dir / "result.json", {"n_total_trials": 2})
            complete = job_dir / "complete-trial"
            _write_json(complete / "result.json", trials[0])
            _write_json(complete / "agent/evidence/provider-input/request.json", {})
            _write_json(complete / "agent/trajectory.json", {})
            _write_json(complete / "artifacts/evidence/lifecycle/events.json", {})
            _write_json(complete / "verifier/reward.json", {"reward": 1})
            outcome = job_dir / "outcome-trial"
            _write_json(outcome / "result.json", trials[1])

            evidence = build_evidence_index(job_dir, "D")

            self.assertEqual(
                [trial["grade"] for trial in evidence["trials"]], ["A", "D"]
            )
            self.assertEqual(evidence["actual_grade"], "D")
            self.assertTrue(evidence["meets_minimum"])

    def test_summary_reads_harbor_native_per_trial_results(self) -> None:
        suite = load_suite("smoke")
        with tempfile.TemporaryDirectory() as directory:
            job_dir = Path(directory)
            _write_json(job_dir / "result.json", {"n_total_trials": 2})
            for task in suite.task_ids:
                trial = f"{task}__trial"
                _write_json(
                    job_dir / trial / "result.json",
                    {
                        "task_name": task,
                        "trial_name": trial,
                        "verifier_result": {
                            "rewards": {"reward": 1, "artifact_verified": 1}
                        },
                        "exception_info": None,
                    },
                )

            summary = summarize_job(job_dir, suite, 0)

            self.assertEqual(summary["infrastructure_errors"], [])
            self.assertEqual(summary["cohorts"]["all"]["reward_means"]["reward"], 1)


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
