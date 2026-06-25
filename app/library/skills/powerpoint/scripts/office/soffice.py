"""Small LibreOffice wrapper for sandbox-friendly PowerPoint conversion.

Usage mirrors soffice:
    python scripts/office/soffice.py --headless --convert-to pdf output.pptx
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    soffice = shutil.which("soffice") or shutil.which("libreoffice")
    if not soffice:
        print("LibreOffice executable not found: install soffice/libreoffice in the computer image", file=sys.stderr)
        return 127

    profile = Path(os.environ.get("SOFFICE_PROFILE", "/workspace/temp/.bullx/soffice"))
    profile.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env.setdefault("HOME", "/workspace/temp")
    command = [soffice, f"-env:UserInstallation=file://{profile}", *sys.argv[1:]]
    return subprocess.call(command, env=env)


if __name__ == "__main__":
    raise SystemExit(main())
