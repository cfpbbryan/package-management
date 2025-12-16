"""Generate a pip freeze report into the project directory.

Usage (from the project root)::

    python freeze-python-packages.py

This script is intended for Windows Server 2019 environments where the
repository lives at ``C:\\admin\\package-management``. It shells out to
``py -m pip freeze`` so that the environment resolution mirrors manual
usage, and writes the results to ``python_requirements.txt`` in the project
root.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

OUTPUT_PATH = Path(__file__).resolve().parent / "python_requirements.txt"


def freeze_packages(output_path: Path) -> None:
    """Run ``pip freeze`` via the available Python launcher and write it out.

    The parent directory is created if it does not already exist.
    """

    output_path.parent.mkdir(parents=True, exist_ok=True)

    launcher = shutil.which("py") or sys.executable
    command = [launcher, "-m", "pip", "freeze"]

    result = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
    )

    output_path.write_text(result.stdout, encoding="utf-8")



def main() -> None:
    freeze_packages(OUTPUT_PATH)


if __name__ == "__main__":
    main()
