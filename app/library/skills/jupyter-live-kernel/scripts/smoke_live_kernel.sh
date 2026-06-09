#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${SCRIPT:-/workspace/library-containers/skills/jupyter-live-kernel/scripts/jupyter_live_kernel.py}"
NOTEBOOK_DIR="${NOTEBOOK_DIR:-/workspace/user-files/notebooks}"
PORT="${PORT:-8888}"
NOTEBOOK_PATH="${NOTEBOOK_PATH:-scratch.ipynb}"

mkdir -p "$NOTEBOOK_DIR" /workspace/temp

python -m jupyter lab \
  --no-browser \
  --ip=127.0.0.1 \
  --port="$PORT" \
  --port-retries=0 \
  --notebook-dir="$NOTEBOOK_DIR" \
  --allow-root \
  --IdentityProvider.token='' \
  --ServerApp.password='' \
  --ServerApp.disable_check_xsrf=True \
  > /workspace/temp/jupyter-smoke.log 2>&1 &

jupyter_pid=$!
cleanup() {
  kill "$jupyter_pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in $(seq 1 30); do
  if python "$SCRIPT" servers --compact | grep -q "\"port\":$PORT"; then
    break
  fi
  sleep 1
done

python - <<'PY'
import json
import os
import pathlib

notebook_dir = pathlib.Path(os.environ.get("NOTEBOOK_DIR", "/workspace/user-files/notebooks"))
path = notebook_dir / os.environ.get("NOTEBOOK_PATH", "scratch.ipynb")
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
  > /workspace/temp/jupyter-smoke-session.json

python "$SCRIPT" execute --port "$PORT" --path "$NOTEBOOK_PATH" --code $'x = 41\nprint(x)' --compact \
  > /workspace/temp/jupyter-smoke-step1.json
python "$SCRIPT" execute --port "$PORT" --path "$NOTEBOOK_PATH" --code 'x + 1' --compact \
  > /workspace/temp/jupyter-smoke-step2.json

python - <<'PY'
import json

result = json.load(open("/workspace/temp/jupyter-smoke-step2.json"))
texts = [event.get("data", {}).get("text/plain") for event in result["events"]]
assert "42" in texts, texts
print("JUPYTER_LIVE_KERNEL_SMOKE_OK")
PY
