#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${SCRIPT:-/repo/app/library/skills/jupyter-live-kernel/scripts/jupyter_live_kernel.py}"
NOTEBOOK_DIR="${NOTEBOOK_DIR:-/workspace/user-files/notebooks}"
JUPYTER_SOCKET="${JUPYTER_SOCKET:-/workspace/temp/jupyter-smoke.sock}"
NOTEBOOK_PATH="${NOTEBOOK_PATH:-scratch.ipynb}"
export JUPYTER_SOCKET NOTEBOOK_DIR NOTEBOOK_PATH

mkdir -p "$NOTEBOOK_DIR" /workspace/temp
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
  > /workspace/temp/jupyter-smoke.log 2>&1 &

jupyter_pid=$!
cleanup() {
  kill "$jupyter_pid" >/dev/null 2>&1 || true
  wait "$jupyter_pid" >/dev/null 2>&1 || true
  rm -f "$JUPYTER_SOCKET"
}
trap cleanup EXIT

ready=false
for _ in $(seq 1 30); do
  if curl -sf --unix-socket "$JUPYTER_SOCKET" "http://localhost/api/sessions" >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != true ]; then
  cat /workspace/temp/jupyter-smoke.log >&2
  exit 1
fi

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

curl -sf --unix-socket "$JUPYTER_SOCKET" -X POST "http://localhost/api/sessions" \
  -H "Content-Type: application/json" \
  -d "{\"path\":\"$NOTEBOOK_PATH\",\"type\":\"notebook\",\"name\":\"$NOTEBOOK_PATH\",\"kernel\":{\"name\":\"python3\"}}" \
  > /workspace/temp/jupyter-smoke-session.json

python "$SCRIPT" servers --compact > /workspace/temp/jupyter-smoke-servers.json
python "$SCRIPT" execute --socket "$JUPYTER_SOCKET" --path "$NOTEBOOK_PATH" --code $'x = 41\nprint(x)' --compact \
  > /workspace/temp/jupyter-smoke-step1.json
python "$SCRIPT" execute --socket "$JUPYTER_SOCKET" --path "$NOTEBOOK_PATH" --code 'x + 1' --compact \
  > /workspace/temp/jupyter-smoke-step2.json

python - <<'PY'
import json
import os

result = json.load(open("/workspace/temp/jupyter-smoke-step2.json"))
texts = [event.get("data", {}).get("text/plain") for event in result["events"]]
assert "42" in texts, texts
assert result["transport"] == "websocket+unix", result
servers = json.load(open("/workspace/temp/jupyter-smoke-servers.json"))["servers"]
expected_socket = os.environ.get("JUPYTER_SOCKET", "/workspace/temp/jupyter-smoke.sock")
assert any(server["server"]["socket"] == expected_socket for server in servers), servers
print("JUPYTER_LIVE_KERNEL_SMOKE_OK")
PY
