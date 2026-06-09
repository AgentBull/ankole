#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from contextlib import contextmanager
from importlib import metadata
from pathlib import Path
from typing import Any, Iterator


DEFAULT_WORKSPACE = Path("/workspace/user-files/browser")
DEFAULT_STATE_DIR = Path("/workspace/user-files/.bullx/browser")
DEFAULT_VIEWPORT = {"width": 1280, "height": 1800}
DEFAULT_PREINSTALLED_CAMOUFOX = Path("/opt/camoufox")


class BrowserError(RuntimeError):
    pass


def _json_default(value: Any) -> str:
    if isinstance(value, Path):
        return str(value)
    return str(value)


def print_json(value: Any) -> None:
    print(json.dumps(value, default=_json_default, ensure_ascii=False, sort_keys=True))


def run_python_module(args: list[str], *, timeout: int = 120) -> dict[str, Any]:
    command = [sys.executable, "-m", "camoufox", *args]
    started = time.time()
    process = subprocess.run(command, text=True, capture_output=True, timeout=timeout, check=False)
    return {
        "command": command,
        "exit_code": process.returncode,
        "stdout": process.stdout,
        "stderr": process.stderr,
        "elapsed_seconds": round(time.time() - started, 3),
    }


def workspace_root() -> Path:
    return Path(os.environ.get("BULLX_BROWSER_WORKSPACE", str(DEFAULT_WORKSPACE)))


def state_root() -> Path:
    return Path(os.environ.get("BULLX_BROWSER_STATE_DIR", str(DEFAULT_STATE_DIR)))


def session_name(value: str | None) -> str:
    raw = (value or os.environ.get("BULLX_BROWSER_SESSION") or os.environ.get("BULLX_AGENT_UID") or "default").strip()
    safe = "".join(char if char.isalnum() or char in "._-" else "-" for char in raw)
    return safe[:96] or "default"


def task_name(value: str | None) -> str:
    raw = (value or f"task-{int(time.time())}").strip()
    safe = "".join(char if char.isalnum() or char in "._-" else "-" for char in raw)
    return safe[:96] or f"task-{int(time.time())}"


def prepare_env(session: str) -> dict[str, Path]:
    base = state_root()
    home = base / "home" / session
    profile = base / "profiles" / session
    downloads = workspace_root() / "downloads" / session
    for path in (base, home, profile, downloads, workspace_root()):
        path.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("HOME", str(home))
    os.environ.setdefault("BULLX_BROWSER_PROFILE_DIR", str(profile))
    os.environ.setdefault("BULLX_BROWSER_DOWNLOADS_DIR", str(downloads))
    return {"home": home, "profile": profile, "downloads": downloads}


def import_checks() -> dict[str, bool]:
    import importlib.util

    return {
        "camoufox": importlib.util.find_spec("camoufox") is not None,
        "playwright": importlib.util.find_spec("playwright") is not None,
    }


def preinstalled_camoufox_dir() -> Path:
    return Path(os.environ.get("BULLX_CAMOUFOX_PREINSTALLED_DIR", str(DEFAULT_PREINSTALLED_CAMOUFOX)))


def cache_has_browser(path: Path | None) -> bool:
    if path is None or not path.exists():
        return False
    return (path / "version.json").exists() and any((path / name).exists() for name in ("camoufox", "camoufox.exe"))


def chmod_tree_755(path: Path) -> None:
    for child in path.rglob("*"):
        try:
            child.chmod(0o755)
        except FileNotFoundError:
            pass
    path.chmod(0o755)


def bootstrap_preinstalled_camoufox(install_path: Path | None) -> dict[str, Any]:
    source = preinstalled_camoufox_dir()
    result: dict[str, Any] = {"source": source, "target": install_path, "used": False}
    if install_path is None:
        result["reason"] = "camoufox path is unavailable"
        return result
    if cache_has_browser(install_path):
        result["reason"] = "target already has a browser binary"
        return result
    if not cache_has_browser(source):
        result["reason"] = "preinstalled browser binary is unavailable"
        return result

    install_path.parent.mkdir(parents=True, exist_ok=True)
    if install_path.exists():
        shutil.rmtree(install_path)
    started = time.time()
    shutil.copytree(source, install_path)
    chmod_tree_755(install_path)
    result["used"] = True
    result["elapsed_seconds"] = round(time.time() - started, 3)
    return result


def ensure_camoufox_available(fetch: bool) -> dict[str, Any]:
    checks = import_checks()
    result: dict[str, Any] = {"python": sys.version.split()[0], "modules": checks}
    if not checks["camoufox"]:
        result["ok"] = False
        result["error"] = "camoufox Python package is not installed"
        return result

    try:
        result["package_version"] = metadata.version("camoufox")
    except metadata.PackageNotFoundError:
        result["package_version"] = None
    result["path"] = run_python_module(["path"], timeout=30)
    install_path = Path(str(result["path"]["stdout"]).strip()) if result["path"]["exit_code"] == 0 else None
    result["bootstrap"] = bootstrap_preinstalled_camoufox(install_path)
    if fetch and not cache_has_browser(install_path):
        result["fetch"] = run_python_module(["fetch"], timeout=900)
        result["path"] = run_python_module(["path"], timeout=30)
        install_path = Path(str(result["path"]["stdout"]).strip()) if result["path"]["exit_code"] == 0 else None
    installed_versions = []
    if install_path and install_path.exists():
        installed_versions = sorted(child.name for child in install_path.iterdir() if child.is_dir())
    result["browser_installed"] = cache_has_browser(install_path)
    result["installed_versions"] = installed_versions
    result["ok"] = checks["playwright"] and result["package_version"] is not None
    result["ready"] = result["ok"] and result["browser_installed"]
    return result


def require_camoufox_ready(fetch: bool) -> dict[str, Any]:
    status = ensure_camoufox_available(fetch=fetch)
    if not status.get("ready"):
        raise BrowserError(
            "camoufox browser binary is not ready; run browser_doctor(fetch=true) or preinstall it at "
            f"{preinstalled_camoufox_dir()}"
        )
    return status


@contextmanager
def launch_browser(headless: str, profile_dir: Path | None = None) -> Iterator[Any]:
    try:
        from camoufox.sync_api import NewBrowser
        from playwright.sync_api import sync_playwright
    except Exception as exc:  # pragma: no cover - exercised in image smoke.
        raise BrowserError(f"failed to import camoufox: {exc}") from exc

    if headless == "false":
        value: bool | str = False
    elif headless == "virtual":
        value = "virtual"
    else:
        value = True
    with sync_playwright() as playwright:
        browser_or_context = NewBrowser(
            playwright,
            headless=value,
            persistent_context=profile_dir is not None,
            **({"user_data_dir": str(profile_dir)} if profile_dir is not None else {}),
        )
        try:
            yield browser_or_context
        finally:
            browser_or_context.close()


def task_dir(session: str, task: str) -> Path:
    path = workspace_root() / "tasks" / session / task
    path.mkdir(parents=True, exist_ok=True)
    return path


def latest_path(session: str) -> Path:
    path = state_root() / "sessions" / session
    path.mkdir(parents=True, exist_ok=True)
    return path / "latest.json"


def capture_page(args: argparse.Namespace) -> dict[str, Any]:
    session = session_name(args.session)
    env_paths = prepare_env(session)
    task = task_name(args.task_id)
    out_dir = task_dir(session, task)
    screenshot_path = out_dir / "screenshot.png"
    text_path = out_dir / "page.txt"
    html_path = out_dir / "page.html"

    if args.auto_fetch:
        require_camoufox_ready(fetch=True)
    else:
        require_camoufox_ready(fetch=False)

    started = time.time()
    profile_mode = args.profile_mode
    profile_dir = env_paths["profile"] if profile_mode == "persistent" else None
    with launch_browser(args.headless, profile_dir=profile_dir) as browser:
        page = browser.new_page()
        page.set_viewport_size(DEFAULT_VIEWPORT)
        page.goto(args.url, wait_until=args.wait_until, timeout=args.timeout_ms)
        if args.wait_after_ms:
            page.wait_for_timeout(args.wait_after_ms)
        title = page.title()
        url = page.url
        try:
            text = page.locator("body").inner_text(timeout=5000)
        except Exception:
            text = ""
        html = page.content()
        if args.screenshot:
            page.screenshot(path=str(screenshot_path), full_page=False)

    text_path.write_text(text, encoding="utf-8")
    html_path.write_text(html, encoding="utf-8")
    result = {
        "ok": True,
        "operation": "open",
        "profile_mode": profile_mode,
        "profile": profile_dir,
        "session": session,
        "task_id": task,
        "url": url,
        "title": title,
        "elapsed_seconds": round(time.time() - started, 3),
        "artifacts": {
            "directory": out_dir,
            "screenshot": screenshot_path if args.screenshot else None,
            "text": text_path,
            "html": html_path,
        },
        "text_preview": text[:2000],
    }
    latest_path(session).write_text(json.dumps(result, default=_json_default, indent=2), encoding="utf-8")
    return result


def extract_page(args: argparse.Namespace) -> dict[str, Any]:
    if args.url:
        capture_args = argparse.Namespace(**vars(args))
        capture_args.screenshot = False
        opened = capture_page(capture_args)
        text_path = Path(opened["artifacts"]["text"])
        text = text_path.read_text(encoding="utf-8")
        return {
            "ok": True,
            "operation": "extract",
            "session": opened["session"],
            "url": opened["url"],
            "title": opened["title"],
            "format": args.format,
            "text": text,
            "artifacts": opened["artifacts"],
            "profile_mode": opened.get("profile_mode"),
        }

    session = session_name(args.session)
    latest = latest_path(session)
    if not latest.exists():
        raise BrowserError(f"no previous browser capture for session {session!r}; pass --url")
    state = json.loads(latest.read_text(encoding="utf-8"))
    text_path = Path(state["artifacts"]["text"])
    text = text_path.read_text(encoding="utf-8")
    return {
        "ok": True,
        "operation": "extract",
        "session": session,
        "url": state.get("url"),
        "title": state.get("title"),
        "format": args.format,
        "text": text,
        "artifacts": state.get("artifacts"),
    }


def run_script(args: argparse.Namespace) -> dict[str, Any]:
    session = session_name(args.session)
    prepare_env(session)
    task = task_name(args.task_id)
    root = task_dir(session, task)
    final_root = root / "final_runs"
    final_root.mkdir(parents=True, exist_ok=True)
    next_index = 1
    for child in final_root.glob("run_*"):
        try:
            next_index = max(next_index, int(child.name.split("_", 1)[1]) + 1)
        except Exception:
            continue
    run_dir = final_root / f"run_{next_index}"
    screenshots = run_dir / "screenshots"
    screenshots.mkdir(parents=True, exist_ok=True)

    source = Path(args.script)
    if not source.exists():
        raise BrowserError(f"script does not exist: {source}")
    final_script = run_dir / "final_script.py"
    shutil.copyfile(source, final_script)

    env = os.environ.copy()
    env.update(
        {
            "BULLX_BROWSER_SESSION": session,
            "BULLX_BROWSER_RUN_DIR": str(run_dir),
            "BULLX_BROWSER_SCREENSHOT_DIR": str(screenshots),
            "BULLX_BROWSER_PROFILE_DIR": str(state_root() / "profiles" / session),
            "BULLX_BROWSER_PROFILE_MODE": args.profile_mode,
            "BULLX_BROWSER_HEADLESS": args.headless,
        }
    )
    if args.start_url:
        env["BULLX_BROWSER_START_URL"] = args.start_url
    if args.auto_fetch:
        ensure_camoufox_available(fetch=True)
    else:
        ensure_camoufox_available(fetch=False)

    started = time.time()
    process = subprocess.run(
        [sys.executable, str(final_script)],
        cwd=str(run_dir),
        text=True,
        capture_output=True,
        timeout=args.timeout_ms / 1000,
        env=env,
        check=False,
    )
    (run_dir / "stdout.txt").write_text(process.stdout, encoding="utf-8")
    (run_dir / "stderr.txt").write_text(process.stderr, encoding="utf-8")
    log_path = run_dir / "final_script_log.txt"
    if not log_path.exists():
        log_path.write_text(process.stdout, encoding="utf-8")
    result = {
        "ok": process.returncode == 0,
        "operation": "run",
        "profile_mode": args.profile_mode,
        "session": session,
        "task_id": task,
        "exit_code": process.returncode,
        "elapsed_seconds": round(time.time() - started, 3),
        "artifacts": {
            "task_directory": root,
            "run_directory": run_dir,
            "final_script": final_script,
            "screenshots": screenshots,
            "stdout": run_dir / "stdout.txt",
            "stderr": run_dir / "stderr.txt",
            "log": log_path,
        },
        "stdout_preview": process.stdout[:2000],
        "stderr_preview": process.stderr[:2000],
    }
    latest_path(session).write_text(json.dumps(result, default=_json_default, indent=2), encoding="utf-8")
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="BullX browser runtime wrapper around Camoufox.")
    parser.add_argument("--json", action="store_true", help="Print compact JSON output.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    doctor = subparsers.add_parser("doctor", help="Check browser runtime availability.")
    doctor.add_argument("--fetch", action="store_true", help="Fetch the Camoufox browser binary if needed.")

    open_parser = subparsers.add_parser("open", help="Open a URL and capture rendered page artifacts.")
    add_capture_args(open_parser, url_required=True)

    extract = subparsers.add_parser("extract", help="Extract text from a URL or the latest session capture.")
    add_capture_args(extract, url_required=False)
    extract.add_argument("--format", choices=["text", "markdown", "json"], default="text")

    run = subparsers.add_parser("run", help="Run a browser automation Python script with BullX artifact paths.")
    run.add_argument("--session")
    run.add_argument("--task-id")
    run.add_argument("--script", required=True)
    run.add_argument("--start-url")
    run.add_argument("--timeout-ms", type=int, default=180000)
    run.add_argument("--headless", choices=["true", "false", "virtual"], default="true")
    run.add_argument("--profile-mode", choices=["ephemeral", "persistent"], default="persistent")
    run.add_argument("--auto-fetch", action="store_true")
    return parser


def add_capture_args(parser: argparse.ArgumentParser, *, url_required: bool) -> None:
    parser.add_argument("--session")
    parser.add_argument("--task-id")
    parser.add_argument("--url", required=url_required)
    parser.add_argument("--timeout-ms", type=int, default=60000)
    parser.add_argument("--wait-until", choices=["load", "domcontentloaded", "networkidle", "commit"], default="domcontentloaded")
    parser.add_argument("--wait-after-ms", type=int, default=0)
    parser.add_argument("--headless", choices=["true", "false", "virtual"], default="true")
    parser.add_argument("--profile-mode", choices=["ephemeral", "persistent"], default="ephemeral")
    parser.add_argument("--auto-fetch", action="store_true")
    parser.add_argument("--screenshot", action=argparse.BooleanOptionalAction, default=True)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "doctor":
            result = ensure_camoufox_available(fetch=args.fetch)
        elif args.command == "open":
            result = capture_page(args)
        elif args.command == "extract":
            result = extract_page(args)
        elif args.command == "run":
            result = run_script(args)
        else:  # pragma: no cover
            raise BrowserError(f"unsupported command: {args.command}")
        print_json(result)
        return 0 if result.get("ok", False) else 1
    except Exception as exc:
        print_json({"ok": False, "error": str(exc), "type": exc.__class__.__name__})
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
