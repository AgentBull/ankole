from __future__ import annotations

import hashlib
import json
import os
import platform
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

from ankole_eval import HARBOR_VERSION, SCHEMA_VERSION
from ankole_eval.evidence import build_evidence_index
from ankole_eval.suite import EvalError, REPO_ROOT, Suite
from ankole_eval.summary import summarize_job


def execute_suite(
    suite: Suite,
    variant_id: str,
    output: Path | None,
    n_concurrent: int,
    quiet: bool,
) -> tuple[Path, int]:
    harness = suite.resolved_harness(variant_id)
    _require_environment(harness["required_env"])
    run_dir = _allocate_run_dir(suite.id, variant_id, output)
    harbor_root = run_dir / "harbor"
    job_dir = harbor_root / "job"
    config_path = run_dir / "harbor-config.json"
    log_path = run_dir / "harbor.log"
    summary_path = run_dir / "summary.json"
    evidence_path = run_dir / "evidence.json"
    manifest_path = run_dir / "run.json"

    contract = suite.frozen_contract()
    source = source_state(REPO_ROOT)
    harbor_config = _harbor_config(
        suite=suite,
        harness=harness,
        harbor_root=harbor_root,
        n_concurrent=n_concurrent,
        quiet=quiet,
    )
    _write_json(config_path, harbor_config)

    command = [
        sys.executable,
        "-m",
        "harbor.cli.main",
        "run",
        "--config",
        str(config_path),
        "--yes",
    ]
    started_at = _now()
    run_manifest: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_dir.name,
        "status": "running",
        "started_at": started_at,
        "finished_at": None,
        "suite_manifest": _display_path(suite.manifest_path),
        "suite": contract,
        "variant": {
            "id": variant_id,
            "description": suite.variants[variant_id].description,
            "change_owner": suite.variants[variant_id].change_owner,
            "harness": harness,
        },
        "source": source,
        "runner": {
            "name": "harbor",
            "version": HARBOR_VERSION,
            "python": platform.python_version(),
            "command": command,
        },
        "harbor_job": "harbor/job",
        "summary": "summary.json",
        "evidence": "evidence.json",
    }
    _write_json(manifest_path, run_manifest)

    harbor_exit_code = _run_harbor(command, log_path)
    summary = summarize_job(job_dir, suite, harbor_exit_code)
    evidence = build_evidence_index(job_dir, suite.minimum_evidence_grade)
    _write_json(summary_path, summary)
    _write_json(evidence_path, evidence)

    run_manifest["status"] = (
        "complete"
        if harbor_exit_code == 0 and (job_dir / "result.json").is_file()
        else "infrastructure_error"
    )
    run_manifest["finished_at"] = _now()
    run_manifest["acceptance"] = {
        "infrastructure_errors": len(summary["infrastructure_errors"]),
        "evidence_meets_minimum": evidence["meets_minimum"],
    }
    _write_json(manifest_path, run_manifest)

    print(f"[eval] run: {run_dir}")
    print(
        "[eval] evidence: "
        f"{evidence['actual_grade']} (minimum {evidence['minimum_grade']})"
    )
    print(f"[eval] infrastructure errors: {len(summary['infrastructure_errors'])}")
    valid = (
        run_manifest["status"] == "complete"
        and not summary["infrastructure_errors"]
        and evidence["meets_minimum"]
    )
    return run_dir, 0 if valid else 2


def source_state(repo_root: Path) -> dict[str, Any]:
    revision = _git_text(repo_root, "rev-parse", "HEAD").strip()
    status_bytes = _git_bytes(
        repo_root,
        "status",
        "--porcelain=v1",
        "-z",
        "--untracked-files=all",
    )
    status_text = _git_text(
        repo_root,
        "status",
        "--porcelain=v1",
        "--untracked-files=all",
    )
    dirty_paths = sorted(
        line[3:] for line in status_text.splitlines() if len(line) >= 4
    )

    digest = hashlib.sha256()
    digest.update(revision.encode("utf-8") + b"\0")
    digest.update(status_bytes)
    digest.update(
        _git_bytes(repo_root, "diff", "--binary", "--no-ext-diff", "HEAD", "--")
    )

    untracked = _git_bytes(
        repo_root, "ls-files", "--others", "--exclude-standard", "-z"
    )
    for encoded_path in sorted(path for path in untracked.split(b"\0") if path):
        relative = os.fsdecode(encoded_path)
        path = repo_root / relative
        digest.update(b"U\0" + encoded_path + b"\0")
        if path.is_symlink():
            digest.update(os.fsencode(path.readlink()))
        elif path.is_file():
            with path.open("rb") as file:
                while chunk := file.read(1024 * 1024):
                    digest.update(chunk)

    return {
        "revision": revision,
        "dirty": bool(status_bytes),
        "workspace_digest": "sha256:" + digest.hexdigest(),
        "dirty_paths": dirty_paths,
    }


def _harbor_config(
    suite: Suite,
    harness: dict[str, Any],
    harbor_root: Path,
    n_concurrent: int,
    quiet: bool,
) -> dict[str, Any]:
    agent_env = {name: f"${{{name}}}" for name in harness["required_env"]} | harness[
        "agent_env"
    ]
    agent: dict[str, Any] = {
        "name": harness["agent"],
        "kwargs": harness["agent_kwargs"],
        "env": agent_env,
    }
    if harness["model"] is not None:
        agent["model_name"] = harness["model"]
    if harness["agent_setup_timeout_sec"] is not None:
        agent["override_setup_timeout_sec"] = harness["agent_setup_timeout_sec"]

    environment = (
        {"import_path": harness["environment"]}
        if ":" in harness["environment"]
        else {"type": harness["environment"]}
    )
    return {
        "job_name": "job",
        "jobs_dir": str(harbor_root),
        "n_attempts": 1,
        "n_concurrent_trials": n_concurrent,
        "quiet": quiet,
        "environment": environment,
        "agents": [agent],
        "tasks": [
            {"path": str(suite.task_path(task_id))} for task_id in suite.task_ids
        ],
    }


def _allocate_run_dir(suite_id: str, variant_id: str, output: Path | None) -> Path:
    if output is None:
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        run_id = f"{timestamp}-{variant_id}-{uuid4().hex[:8]}"
        candidate = REPO_ROOT / "var" / "eval" / "runs" / suite_id / run_id
    else:
        candidate = output.expanduser()
        if not candidate.is_absolute():
            candidate = Path.cwd() / candidate
    if candidate.exists():
        raise EvalError(f"Run output already exists: {candidate}")
    candidate.mkdir(parents=True)
    return candidate.resolve()


def _require_environment(names: list[str]) -> None:
    missing = [name for name in names if not os.environ.get(name)]
    if missing:
        raise EvalError(
            "Missing required environment variables: " + ", ".join(sorted(missing))
        )


def _run_harbor(command: list[str], log_path: Path) -> int:
    environment = os.environ.copy()
    environment["HARBOR_TELEMETRY"] = "0"
    environment["PYTHONUNBUFFERED"] = "1"
    print("[eval] starting Harbor")
    try:
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(
                command,
                cwd=REPO_ROOT,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert process.stdout is not None
            try:
                for line in process.stdout:
                    print(line, end="")
                    log.write(line)
                    log.flush()
            except KeyboardInterrupt:
                process.terminate()
                process.wait(timeout=10)
                raise
            return process.wait()
    except OSError as exc:
        log_path.write_text(f"Cannot start Harbor: {exc}\n", encoding="utf-8")
        return 127


def _write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def _git_bytes(repo_root: Path, *arguments: str) -> bytes:
    try:
        result = subprocess.run(
            ["git", *arguments],
            cwd=repo_root,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise EvalError(f"Cannot freeze Git source state: {exc}") from exc
    return result.stdout


def _git_text(repo_root: Path, *arguments: str) -> str:
    return _git_bytes(repo_root, *arguments).decode("utf-8", errors="replace")


def _display_path(path: Path) -> str:
    try:
        return path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return str(path)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
