from __future__ import annotations

import unittest
from pathlib import Path

from ankole_eval.runner import _harbor_config
from ankole_eval.suite import load_suite


class RunnerConfigTest(unittest.TestCase):
    def test_local_tasks_remain_adhoc_for_harbor_default_metric(self) -> None:
        suite = load_suite("smoke")

        config = _harbor_config(
            suite=suite,
            harness=suite.resolved_harness("baseline"),
            harbor_root=Path("/tmp/harbor"),
            n_concurrent=1,
            quiet=False,
        )

        self.assertEqual(
            config["tasks"],
            [{"path": str(suite.task_path(task_id))} for task_id in suite.task_ids],
        )

    def test_suite_can_extend_agent_setup_timeout(self) -> None:
        suite = load_suite("a2-bp-stance")

        config = _harbor_config(
            suite=suite,
            harness=suite.resolved_harness("baseline"),
            harbor_root=Path("/tmp/harbor"),
            n_concurrent=1,
            quiet=False,
        )

        self.assertEqual(config["agents"][0]["override_setup_timeout_sec"], 900.0)


if __name__ == "__main__":
    unittest.main()
