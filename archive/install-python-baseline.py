"""Install packages from the local baseline mirror into the global site-packages.

Usage (from the project root)::

    python install-python-baseline.py

The script is intended for Windows environments where the package mirror lives
at ``C:\\admin\\python_mirror`` and the requirements file is maintained in this
repository. It enforces running from an elevated command prompt or PowerShell
session so packages are installed to the system ``site-packages``.
"""

from __future__ import annotations

import ctypes
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

DEFAULT_REQUIREMENTS = Path(__file__).resolve().parent / "python_requirements.txt"
DEFAULT_MIRROR = Path(r"C:\\admin\\python_mirror")


def run_command(command: list[str], description: str, *, env: dict[str, str] | None = None) -> None:
    """Run a command and raise a descriptive error on failure."""

    try:
        subprocess.run(command, check=True, env=env)
    except subprocess.CalledProcessError as exc:
        raise SystemExit(f"Failed to {description}: {exc}") from exc


def ensure_windows() -> None:
    """Abort if the host is not Windows."""

    if platform.system() != "Windows":
        raise SystemExit("This script is intended to run on Windows hosts only.")


def ensure_admin() -> None:
    """Exit when the current process is not elevated."""

    try:
        is_admin = bool(ctypes.windll.shell32.IsUserAnAdmin())
    except OSError:
        is_admin = False

    if not is_admin:
        raise SystemExit(
            "Run this script from an elevated Command Prompt or PowerShell session "
            "so packages install into the global site-packages."
        )


def install_baseline(requirements_path: Path, mirror_path: Path) -> None:
    """Install packages from the local mirror using the Windows Python launcher."""

    ensure_windows()
    ensure_admin()

    launcher = shutil.which("py") or sys.executable
    env = dict(os.environ)
    env.pop("PIP_NO_INDEX", None)

    command = [
        launcher,
        "-m",
        "pip",
        "install",
        "--no-index",
        f"--find-links={mirror_path}",
        "-r",
        str(requirements_path),
        "--force-reinstall",
        "--no-deps",
    ]

    run_command(command, "install packages from the local mirror", env=env)


def main() -> None:
    install_baseline(DEFAULT_REQUIREMENTS, DEFAULT_MIRROR)


if __name__ == "__main__":
    main()
