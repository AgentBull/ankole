from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ankole_eval.suite import EvalError, load_suite, validate_harbor_tasks


class SuiteTest(unittest.TestCase):
    def test_smoke_suite_is_complete_and_harbor_valid(self) -> None:
        suite = load_suite("smoke")

        validate_harbor_tasks(suite)

        self.assertEqual(suite.selection_tasks, ("smoke-selection",))
        self.assertEqual(suite.held_out_tasks, ("smoke-held-out",))
        self.assertEqual(suite.minimum_evidence_grade, "D")
        self.assertTrue(suite.frozen_contract()["digest"].startswith("sha256:"))

    def test_unknown_manifest_field_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "eval.toml").write_text(
                "schema_version = 1\nid = 'bad'\nunknown = true\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(EvalError, "Unknown eval.toml fields"):
                load_suite(root)

    def test_sensitive_literal_environment_value_is_rejected(self) -> None:
        suite = load_suite("smoke")
        manifest = suite.manifest_path.read_text(encoding="utf-8").replace(
            "required_env = []",
            'required_env = []\n\n[harness.agent_env]\nAPI_TOKEN = "secret"',
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "eval.toml").write_text(manifest, encoding="utf-8")

            with self.assertRaises(EvalError):
                load_suite(root)


if __name__ == "__main__":
    unittest.main()
