#!/usr/bin/env bash
set -euo pipefail

ENV_DIR="${ANKOLE_AGENT_PYTHON_ENV:-${HOME}/.ankole/python}"
IMAGE_PYTHON="$(python -c 'import sys; print(sys.executable)')"

if [ ! -x "$ENV_DIR/bin/python" ]; then
  mkdir -p "$(dirname "$ENV_DIR")"
  uv venv --system-site-packages --python "$IMAGE_PYTHON" "$ENV_DIR"
fi

"$IMAGE_PYTHON" - "$ENV_DIR" <<'PY'
from pathlib import Path
import sys
import sysconfig

packages = Path(sysconfig.get_path("purelib", vars={"base": sys.argv[1], "platbase": sys.argv[1]}))
if not packages.is_dir():
    sys.exit("Agent Python env must use the image Python version. Set ANKOLE_AGENT_PYTHON_ENV to a new directory.")
packages.joinpath("ankole-image.pth").write_text(sysconfig.get_path("purelib") + "\n")
PY

"$ENV_DIR/bin/python" - <<'PY'
import importlib.util
import sys

required = ["jupyterlab", "ipykernel", "websocket", "jupyter_client", "jupyter_server", "nbformat"]
missing = [name for name in required if importlib.util.find_spec(name) is None]
if missing:
    print("missing packages in agent Python env: " + ", ".join(missing), file=sys.stderr)
    sys.exit(1)
PY

echo "$ENV_DIR/bin/python"
