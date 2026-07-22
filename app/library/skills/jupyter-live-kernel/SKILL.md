---
name: jupyter-live-kernel
description: Use for iterative Python via a live Jupyter notebook kernel, especially data science, DataFrame inspection, notebook editing, and stateful API exploration. Prefer a one-shot Python process for stateless scripts.
default_enabled: true
ankole-runtime: background_job
tags:
  - python
  - jupyter
  - notebook
  - data-science
  - hamelnb
  - repl
category: data-science
metadata:
  implementation: hamelnb-uds
  upstream: https://github.com/hamelsmu/hamelnb/tree/main/skills/jupyter-live-kernel
  transport: unix-socket
---

# Jupyter Live Kernel

This is Ankole's built-in Unix-socket adapter around hamelnb. The implementation extends the vendored `jupyter_live_kernel.py` helper rather than introducing a separate notebook engine.

Use this skill when a task benefits from a live notebook kernel: variables persist across executions, notebook cells can be inspected or edited, and clean verification can restart and run the notebook from the saved file.

Prefer:

- One-shot shell execution for short Python scripts.
- Codex unified exec sessions for starting Jupyter and keeping the server process available across calls.
- This skill when you would normally want a Jupyter notebook or stateful Python REPL.

## Runtime

Ankole Agent Computer images provide system Python, JupyterLab, ipykernel, and the hamelnb helper dependencies. A per-agent Python environment is optional and only for custom packages or version isolation.

```bash
SCRIPT=/repo/app/library/skills/jupyter-live-kernel/scripts/jupyter_live_kernel.py
BOOTSTRAP=/repo/app/library/skills/jupyter-live-kernel/scripts/ensure_python_env.sh
NOTEBOOK_DIR="$HOME/user-files/notebooks"
JUPYTER_SOCKET="$PWD/temp/jupyter.sock"
AGENT_PYTHON="$HOME/user-files/.ankole/python/bin/python"
```

All helper traffic to Jupyter Server uses the session-local Unix socket. Do not
start a TCP listener or pass port-based server selectors. Jupyter continues to
own its private server-to-kernel transport internally.

Default to system Python. Create the per-agent env only when needed:

```bash
bash "$BOOTSTRAP"
uv pip install --python "$AGENT_PYTHON" <package>
```

The bootstrap uses `uv venv --system-site-packages`, so the env sees the image baseline and stores only package deltas.

## File Analysis And Artifact Delivery

When the user asks for analysis of an uploaded file and expects a chart or file
back, do not stop after saying that the server/session has started. Finish the
artifact path first, verify it exists under the durable artifacts root, and
report the exact path. The calling main agent owns user-visible attachment
delivery.

For a batch workflow, prefer one foreground shell call. It may start Jupyter in
the background inside its own shell, but keep server startup, session creation,
`jupyter_live_kernel.py execute`, artifact verification, and cleanup in that
same call. For iterative work across calls, start Jupyter in a yielded Codex
unified exec session, retain its session ID, and resume that exact session for
later interaction instead of detaching an untracked process.

For readiness, use the explicit local REST API
(`curl --unix-socket "$JUPYTER_SOCKET" http://localhost/...`)
rather than `jupyter_live_kernel.py servers`; server discovery can miss a
freshly-started server in constrained worker environments. When calling the
hamelnb helper, pass `--socket "$JUPYTER_SOCKET"` so it does not depend on
discovery.

For non-trivial multi-line Python, avoid shell-escaping the whole program into
`--code`. For a disposable scratch script under `temp/` in the current Workspace, create the
code file inside the same foreground `command` with a single-quoted heredoc and
then pass `--code-file`. This keeps ordinary Python syntax intact and avoids
quoting bugs in f-strings, JSON, paths, or SQL. Use `patch` instead when
modifying an existing user/repo file; this workflow is only for temporary
generated analysis code.

Minimal shape:

```bash
set -euo pipefail
SCRIPT=/repo/app/library/skills/jupyter-live-kernel/scripts/jupyter_live_kernel.py
NOTEBOOK_DIR="$HOME/user-files/notebooks"
NOTEBOOK_PATH=analysis.ipynb
SESSION_TEMP="$PWD/temp"
ANALYSIS_CODE_FILE="$SESSION_TEMP/analysis_code.py"
JUPYTER_SOCKET="$SESSION_TEMP/jupyter.sock"
ARTIFACT_PATH="$HOME/user-files/analysis/result.png"
export NOTEBOOK_DIR NOTEBOOK_PATH JUPYTER_SOCKET ARTIFACT_PATH
mkdir -p "$NOTEBOOK_DIR" "$SESSION_TEMP" "$(dirname "$ARTIFACT_PATH")"
rm -f "$JUPYTER_SOCKET"

cat > "$ANALYSIS_CODE_FILE" <<'PY'
# Task-specific Python goes here. Read uploaded inputs and write ARTIFACT_PATH.
PY

python -m jupyter lab \
  --no-browser --ServerApp.sock="$JUPYTER_SOCKET" --ServerApp.sock_mode=0600 \
  --notebook-dir="$NOTEBOOK_DIR" --allow-root \
  --IdentityProvider.token='' --ServerApp.password='' \
  --ServerApp.disable_check_xsrf=True \
  > "$SESSION_TEMP/jupyter-analysis.log" 2>&1 &
jupyter_pid=$!
cleanup() {
  kill "$jupyter_pid" >/dev/null 2>&1 || true
  wait "$jupyter_pid" >/dev/null 2>&1 || true
  rm -f "$JUPYTER_SOCKET"
}
trap cleanup EXIT

ready=false
for _ in $(seq 1 30); do
  if curl -sf --unix-socket "$JUPYTER_SOCKET" http://localhost/api/sessions >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
test "$ready" = true

python - <<'PY'
import json, pathlib, os
path = pathlib.Path(os.environ.get("NOTEBOOK_DIR", str(pathlib.Path.home() / "user-files/notebooks"))) / os.environ.get("NOTEBOOK_PATH", "analysis.ipynb")
path.write_text(json.dumps({
    "cells": [{"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [], "source": ""}],
    "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}},
    "nbformat": 4,
    "nbformat_minor": 5
}))
PY

curl -sf --unix-socket "$JUPYTER_SOCKET" -X POST http://localhost/api/sessions \
  -H "Content-Type: application/json" \
  -d "{\"path\":\"$NOTEBOOK_PATH\",\"type\":\"notebook\",\"name\":\"$NOTEBOOK_PATH\",\"kernel\":{\"name\":\"python3\"}}" \
  >"$SESSION_TEMP/jupyter-analysis-session.json"

# ANALYSIS_CODE_FILE should contain task-specific Python code that reads the
# uploaded input, computes the requested result, and writes ARTIFACT_PATH under
# the Agent Home user-files directory.
python "$SCRIPT" execute --socket "$JUPYTER_SOCKET" --path "$NOTEBOOK_PATH" \
  --code-file "$ANALYSIS_CODE_FILE" --compact

test -s "$ARTIFACT_PATH"
```

## Start Jupyter

Start one Jupyter server per Session or Job Workspace. The socket belongs under
its `temp/` directory. Remove a stale socket before startup:

```bash
SESSION_TEMP="$PWD/temp"
mkdir -p "$NOTEBOOK_DIR" "$SESSION_TEMP"
rm -f "$JUPYTER_SOCKET"
python -m jupyter lab \
  --no-browser \
  --ServerApp.sock="$JUPYTER_SOCKET" \
  --ServerApp.sock_mode=0600 \
  --notebook-dir="$NOTEBOOK_DIR" \
  --allow-root \
  --IdentityProvider.token='' \
  --ServerApp.password='' \
  --ServerApp.disable_check_xsrf=True \
  > "$SESSION_TEMP/jupyter.log" 2>&1
```

Run this command in a yielded Codex unified exec session so the server persists across calls, and retain the returned session ID. If using the per-agent env, replace `python` with `"$AGENT_PYTHON"`.

## Create A Live Notebook Session

If no notebook exists, create a scratch notebook:

```bash
mkdir -p "$NOTEBOOK_DIR"
python - <<'PY'
import json, pathlib
path = pathlib.Path.home() / "user-files/notebooks/scratch.ipynb"
if not path.exists():
    path.write_text(json.dumps({
        "cells": [{"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [], "source": ""}],
        "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}},
        "nbformat": 4,
        "nbformat_minor": 5
    }))
PY
```

Then create the live Jupyter session:

```bash
curl -sf --unix-socket "$JUPYTER_SOCKET" -X POST http://localhost/api/sessions \
  -H "Content-Type: application/json" \
  -d '{"path":"scratch.ipynb","type":"notebook","name":"scratch.ipynb","kernel":{"name":"python3"}}'
```

hamelnb executes against live notebook sessions. If `execute` says no live session matched the path, create or select the session first.

## Core Loop

Use compact JSON output unless debugging.

```bash
python "$SCRIPT" servers --compact
python "$SCRIPT" notebooks --socket "$JUPYTER_SOCKET" --compact
python "$SCRIPT" contents --socket "$JUPYTER_SOCKET" --path scratch.ipynb --compact
python "$SCRIPT" execute --socket "$JUPYTER_SOCKET" --path scratch.ipynb --code $'x = 41\nprint(x)' --compact
python "$SCRIPT" execute --socket "$JUPYTER_SOCKET" --path scratch.ipynb --code 'x + 1' --compact
python "$SCRIPT" variables --socket "$JUPYTER_SOCKET" --path scratch.ipynb list --compact
```

The upstream hamelnb script supports `uv run "$SCRIPT" ...` through inline metadata. In Ankole, prefer `python "$SCRIPT" ...` because the computer image already owns the required dependencies.

Smoke test the bundled integration:

```bash
bash /repo/app/library/skills/jupyter-live-kernel/scripts/smoke_live_kernel.sh
```

## Target Selection

Resolve targets in this order:

1. Server: if multiple Unix-socket servers are reachable, ask which socket path to use.
2. Notebook path: if multiple live notebooks exist, ask which path to use.
3. Session: if multiple sessions match a path, ask which session ID to pin.

Once selected, keep using the same `--socket`, `--path`, and when needed
`--session-id` until the user asks to switch.

## Editing And Verification

Use `contents` to get cell IDs before editing:

```bash
python "$SCRIPT" edit --socket "$JUPYTER_SOCKET" --path scratch.ipynb replace-source --cell-id <cell-id> --source $'x = 42\nx' --compact
python "$SCRIPT" edit --socket "$JUPYTER_SOCKET" --path scratch.ipynb insert --at-index 1 --cell-type code --source $'print("hello")' --compact
```

Keep `restart`, `run-all`, and `restart-run-all` for explicit verification or reset requests:

```bash
python "$SCRIPT" restart-run-all --socket "$JUPYTER_SOCKET" --path scratch.ipynb --save-outputs --compact
```

## Failure Handling

- First execution after server start can timeout while the kernel initializes; retry once.
- If startup reports that the socket is already in use, stop the owning server or remove the stale socket before restarting.
- If the server returns 403, restart it with disabled token/password and `--ServerApp.disable_check_xsrf=True`.
- If package imports fail, decide whether the package belongs in the system baseline or the per-agent env. Task-specific packages go in `~/user-files/.ankole/python`.
- `contents` reads the saved notebook file. Unsaved frontend edits are not visible to hamelnb until saved.
