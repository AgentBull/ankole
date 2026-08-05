from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Sequence

from ankole_eval.comparison import compare_runs
from ankole_eval.runner import execute_suite
from ankole_eval.suite import EvalError, load_suite, validate_harbor_tasks


def main(arguments: Sequence[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(arguments)
    try:
        if args.command == "validate":
            suite = load_suite(args.suite)
            validate_harbor_tasks(suite)
            contract = suite.frozen_contract()
            print(f"[eval] valid suite: {suite.id}")
            print(f"[eval] contract: {contract['digest']}")
            print(
                "[eval] tasks: "
                f"{len(suite.selection_tasks)} selection, "
                f"{len(suite.held_out_tasks)} held-out"
            )
            print(f"[eval] evidence: minimum grade {suite.minimum_evidence_grade}")
            return 0

        if args.command == "execute":
            suite = load_suite(args.suite)
            validate_harbor_tasks(suite)
            _, exit_code = execute_suite(
                suite=suite,
                variant_id=args.variant,
                output=args.output,
                n_concurrent=args.n_concurrent,
                quiet=args.quiet,
            )
            return exit_code

        if args.command == "compare":
            comparison, exit_code = compare_runs(args.baseline, args.candidate)
            if args.json:
                print(
                    json.dumps(comparison, indent=2, ensure_ascii=False, sort_keys=True)
                )
            else:
                _print_comparison(comparison)
            return exit_code
    except EvalError as exc:
        print(f"[eval] error: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("[eval] interrupted", file=sys.stderr)
        return 130
    raise AssertionError(f"Unhandled command: {args.command}")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tools/eval/run",
        description="Validate, execute, and compare Ankole Harbor evaluation suites.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    validate = commands.add_parser(
        "validate", help="Validate a suite and its Harbor tasks without execution."
    )
    validate.add_argument("suite", help="Built-in suite ID or path to a suite.")

    execute = commands.add_parser(
        "execute", help="Execute one frozen suite variant through Harbor."
    )
    execute.add_argument("suite", help="Built-in suite ID or path to a suite.")
    execute.add_argument("--variant", required=True, help="Variant ID from eval.toml.")
    execute.add_argument(
        "--output",
        type=Path,
        help="New run directory. Defaults to var/eval/runs/<suite>/.",
    )
    execute.add_argument(
        "--n-concurrent",
        type=_positive_integer,
        default=1,
        help="Maximum concurrent Harbor trials. Default: 1.",
    )
    execute.add_argument(
        "--quiet", action="store_true", help="Suppress Harbor's per-trial display."
    )

    compare = commands.add_parser(
        "compare", help="Compare a baseline and candidate frozen run."
    )
    compare.add_argument("baseline", type=Path, help="Baseline run directory.")
    compare.add_argument("candidate", type=Path, help="Candidate run directory.")
    compare.add_argument(
        "--json", action="store_true", help="Print the complete comparison as JSON."
    )
    return parser


def _positive_integer(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return parsed


def _print_comparison(comparison: dict) -> None:
    print(f"[eval] suite: {comparison['suite']}")
    print(
        "[eval] comparable: "
        f"{'yes' if comparison['comparable'] else 'no'}; "
        f"passed: {'yes' if comparison['passed'] else 'no'}"
    )
    axes = comparison["experiment_axes"] or ["repeatability"]
    print("[eval] experiment axis: " + ", ".join(axes))
    primary = comparison["primary"]
    print(
        f"[eval] primary {primary['reward']} ({primary['cohort']}): "
        f"{comparison['baseline']['primary_mean']} -> "
        f"{comparison['candidate']['primary_mean']}; "
        f"improvement {primary['improvement']}"
    )
    for gate, passed in comparison["gates"].items():
        print(f"[eval] gate {gate}: {'pass' if passed else 'fail'}")
    for reason in comparison["reasons"]:
        print(f"[eval] incomparable: {reason}")


if __name__ == "__main__":
    raise SystemExit(main())
