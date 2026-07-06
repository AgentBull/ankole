---
name: jupyter-live-kernel
description: Use for iterative Python via a live Jupyter notebook kernel, especially data science, DataFrame inspection, notebook editing, and stateful API exploration. Prefer command for one-shot scripts.
default_enabled: true
tags:
  - python
  - jupyter
  - notebook
  - data-science
  - hamelnb
  - repl
category: data-science
metadata:
  implementation: hamelnb
  upstream: https://github.com/hamelsmu/hamelnb/tree/main/skills/jupyter-live-kernel
  vendored_script_sha256: c04e0f329e508256b046694a8d1ea2d2d2e5753b82218cbf67d7ad0001bd9f44
---

# Jupyter Live Kernel

This is Ankole's built-in wrapper around hamelnb. The implementation is the vendored hamelnb `jupyter_live_kernel.py` helper, not a separate Ankole notebook engine.

Use this skill when a task benefits from a live notebook kernel: variables persist across executions, notebook cells can be inspected or edited, and clean verification can restart and run the notebook from the saved file.

Prefer:

- `command` for one-shot Python scripts.
- `interactive_terminal` for starting Jupyter and long-running server processes.
- This skill when you would normally want a Jupyter notebook or stateful Python REPL.

## Runtime

Ankole Agent Computer images provide system Python, JupyterLab, ipykernel, and the hamelnb helper dependencies. A per-agent Python environment is optional and only for custom packages or version isolation.

```bash
SCRIPT=/repo/app/library/skills/jupyter-live-kernel/scripts/jupyter_live_kernel.py
BOOTSTRAP=/repo/app/library/skills/jupyter-live-kernel/scripts/ensure_python_env.sh
NOTEBOOK_DIR=/workspace/user-files/notebooks
AGENT_PYTHON=/workspace/user-files/.ankole/python/bin/python
```

Default to system Python. Create the per-agent env only when needed:

```bash
bash "$BOOTSTRAP"
uv pip install --python "$AGENT_PYTHON" <package>
```

The bootstrap uses `uv venv --system-site-packages`, so the env sees the image baseline and stores only package deltas.

## File Analysis And Artifact Delivery

When the user asks for analysis of an uploaded file and expects a chart or file
back, do not stop after saying that the server/session has started. Finish the
artifact path first, verify it exists, then call `reply_attachment` when a file
should be sent back.

Prefer one foreground `command` call for this batch workflow. The command may
start Jupyter in the background inside its own shell, but keep server startup,
session creation, `jupyter_live_kernel.py execute`, artifact verification, and
cleanup in that same shell command. Do not split "start Jupyter" and "execute
analysis" into separate tool calls unless you use `interactive_terminal` to keep
the server process alive.

For readiness, use the explicit local REST API (`curl http://127.0.0.1:$PORT/...`)
rather than `jupyter_live_kernel.py servers`; server discovery can miss a
freshly-started server in constrained worker environments. When calling the
hamelnb helper, pass `--server-url "http://127.0.0.1:$PORT/"` so it does not
depend on discovery.

For non-trivial multi-line Python, avoid shell-escaping the whole program into
`--code`. For a disposable scratch script under `/workspace/temp`, create the
code file inside the same foreground `command` with a single-quoted heredoc and
then pass `--code-file`. This keeps ordinary Python syntax intact and avoids
quoting bugs in f-strings, JSON, paths, or SQL. Use `patch` instead when
modifying an existing user/repo file; this workflow is only for temporary
generated analysis code.

Minimal shape:

```bash
set -euo pipefail
SCRIPT=/repo/app/library/skills/jupyter-live-kernel/scripts/jupyter_live_kernel.py
NOTEBOOK_DIR=/workspace/user-files/notebooks
NOTEBOOK_PATH=analysis.ipynb
ANALYSIS_CODE_FILE=/workspace/temp/analysis_code.py
PORT=8888
ARTIFACT_PATH=/workspace/user-files/analysis/result.png
export NOTEBOOK_DIR NOTEBOOK_PATH ARTIFACT_PATH
mkdir -p "$NOTEBOOK_DIR" /workspace/temp "$(dirname "$ARTIFACT_PATH")"

cat > "$ANALYSIS_CODE_FILE" <<'PY'
# Task-specific Python goes here. Read uploaded inputs and write ARTIFACT_PATH.
PY

python -m jupyter lab \
  --no-browser --ip=127.0.0.1 --port="$PORT" --port-retries=0 \
  --notebook-dir="$NOTEBOOK_DIR" --allow-root \
  --IdentityProvider.token='' --ServerApp.password='' \
  --ServerApp.disable_check_xsrf=True \
  > /workspace/temp/jupyter-analysis.log 2>&1 &
jupyter_pid=$!
cleanup() { kill "$jupyter_pid" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$PORT/api/sessions" >/dev/null && break
  sleep 1
done

python - <<'PY'
import json, pathlib, os
path = pathlib.Path(os.environ.get("NOTEBOOK_DIR", "/workspace/user-files/notebooks")) / os.environ.get("NOTEBOOK_PATH", "analysis.ipynb")
path.write_text(json.dumps({
    "cells": [{"cell_type": "code", "execution_count": None, "metadata": {}, "outputs": [], "source": ""}],
    "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}},
    "nbformat": 4,
    "nbformat_minor": 5
}))
PY

curl -sf -X POST "http://127.0.0.1:$PORT/api/sessions" \
  -H "Content-Type: application/json" \
  -d "{\"path\":\"$NOTEBOOK_PATH\",\"type\":\"notebook\",\"name\":\"$NOTEBOOK_PATH\",\"kernel\":{\"name\":\"python3\"}}" \
  >/workspace/temp/jupyter-analysis-session.json

# ANALYSIS_CODE_FILE should contain task-specific Python code that reads the
# uploaded input, computes the requested result, and writes ARTIFACT_PATH under
# /workspace/user-files.
python "$SCRIPT" execute --port "$PORT" --path "$NOTEBOOK_PATH" \
  --server-url "http://127.0.0.1:$PORT/" --code-file "$ANALYSIS_CODE_FILE" --compact

test -s "$ARTIFACT_PATH"
```

## Start Jupyter

Start one Jupyter server per agent workspace. In the computer container, root execution and local REST API access require explicit flags:

```bash
mkdir -p "$NOTEBOOK_DIR" /workspace/temp
python -m jupyter lab \
  --no-browser \
  --ip=127.0.0.1 \
  --port=8888 \
  --port-retries=0 \
  --notebook-dir="$NOTEBOOK_DIR" \
  --allow-root \
  --IdentityProvider.token='' \
  --ServerApp.password='' \
  --ServerApp.disable_check_xsrf=True \
  > /workspace/temp/jupyter.log 2>&1
```

Use `interactive_terminal` for this command so the server persists across tool calls. If using the per-agent env, replace `python` with `"$AGENT_PYTHON"`.

## Create A Live Notebook Session

If no notebook exists, create a scratch notebook:

```bash
mkdir -p "$NOTEBOOK_DIR"
python - <<'PY'
import json, pathlib
path = pathlib.Path("/workspace/user-files/notebooks/scratch.ipynb")
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
curl -sf -X POST http://127.0.0.1:8888/api/sessions \
  -H "Content-Type: application/json" \
  -d '{"path":"scratch.ipynb","type":"notebook","name":"scratch.ipynb","kernel":{"name":"python3"}}'
```

hamelnb executes against live notebook sessions. If `execute` says no live session matched the path, create or select the session first.

## Core Loop

Use compact JSON output unless debugging.

```bash
python "$SCRIPT" servers --compact
python "$SCRIPT" notebooks --port 8888 --compact
python "$SCRIPT" contents --port 8888 --path scratch.ipynb --compact
python "$SCRIPT" execute --port 8888 --path scratch.ipynb --code $'x = 41\nprint(x)' --compact
python "$SCRIPT" execute --port 8888 --path scratch.ipynb --code 'x + 1' --compact
python "$SCRIPT" variables --port 8888 --path scratch.ipynb list --compact
```

The upstream hamelnb script supports `uv run "$SCRIPT" ...` through inline metadata. In Ankole, prefer `python "$SCRIPT" ...` because the computer image already owns the required dependencies.

Smoke test the bundled integration:

```bash
bash /repo/app/library/skills/jupyter-live-kernel/scripts/smoke_live_kernel.sh
```

## Target Selection

Resolve targets in this order:

1. Server: if multiple servers are reachable, ask which port or URL to use.
2. Notebook path: if multiple live notebooks exist, ask which path to use.
3. Session: if multiple sessions match a path, ask which session ID to pin.

Once selected, keep using the same `--port`, `--path`, and when needed `--session-id` until the user asks to switch.

## Editing And Verification

Use `contents` to get cell IDs before editing:

```bash
python "$SCRIPT" edit --port 8888 --path scratch.ipynb replace-source --cell-id <cell-id> --source $'x = 42\nx' --compact
python "$SCRIPT" edit --port 8888 --path scratch.ipynb insert --at-index 1 --cell-type code --source $'print("hello")' --compact
```

Keep `restart`, `run-all`, and `restart-run-all` for explicit verification or reset requests:

```bash
python "$SCRIPT" restart-run-all --port 8888 --path scratch.ipynb --save-outputs --compact
```

## Failure Handling

- First execution after server start can timeout while the kernel initializes; retry once.
- If the server returns 403, restart it with disabled token/password and `--ServerApp.disable_check_xsrf=True`.
- If package imports fail, decide whether the package belongs in the system baseline or the per-agent env. Task-specific packages go in `/workspace/user-files/.ankole/python`.
- `contents` reads the saved notebook file. Unsaved browser edits are not visible to hamelnb until saved.
