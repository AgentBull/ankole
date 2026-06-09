#!/usr/bin/env bash
set -euo pipefail

ENV_DIR="${BULLX_AGENT_PYTHON_ENV:-/workspace/user-files/.bullx/python}"
PYTHON_VERSION="${BULLX_AGENT_PYTHON_VERSION:-3.12}"

if [ ! -x "$ENV_DIR/bin/python" ]; then
  mkdir -p "$(dirname "$ENV_DIR")"
  uv venv --system-site-packages --python "$PYTHON_VERSION" "$ENV_DIR"
fi

"$ENV_DIR/bin/python" - <<'PY'
import importlib.util
import sys

required = ["jupyterlab", "ipykernel", "requests", "websocket", "jupyter_client", "jupyter_server", "nbformat"]
missing = [name for name in required if importlib.util.find_spec(name) is None]
if missing:
    print("missing packages in agent Python env: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
PY

echo "$ENV_DIR/bin/python"
