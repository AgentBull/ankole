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
SCRIPT=/workspace/library-containers/skills/jupyter-live-kernel/scripts/jupyter_live_kernel.py
BOOTSTRAP=/workspace/library-containers/skills/jupyter-live-kernel/scripts/ensure_python_env.sh
NOTEBOOK_DIR=/workspace/user-files/notebooks
AGENT_PYTHON=/workspace/user-files/.ankole/python/bin/python
```

Default to system Python. Create the per-agent env only when needed:

```bash
bash "$BOOTSTRAP"
uv pip install --python "$AGENT_PYTHON" <package>
```

The bootstrap uses `uv venv --system-site-packages`, so the env sees the image baseline and stores only package deltas.

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
bash /workspace/library-containers/skills/jupyter-live-kernel/scripts/smoke_live_kernel.sh
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
