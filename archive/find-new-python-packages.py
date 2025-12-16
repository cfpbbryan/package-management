"""Report and append packages present in a new list but missing from requirements.

Usage (from the project root)::

    python find-new-python-packages.py

The script reads a ``new.txt`` file (one package name per line, no versions)
and compares it against ``python_requirements.txt``. It prints any packages
that are present in the new list but absent from the requirements, then
appends each one to ``python_requirements.txt`` with its latest version from
PyPI. Package names are compared case-insensitively and with hyphens and
underscores treated as equivalent for basic normalization.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from pathlib import Path
from typing import Iterable


def extract_package_names(lines: Iterable[str]) -> set[str]:
    """Normalize package identifiers from requirement-style file contents."""

    names: set[str] = set()
    for raw_line in lines:
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue

        if line.startswith("-e") or line.startswith("--editable"):
            _, _, line = line.partition("=")
            line = line.strip().removeprefix("-e").strip()

        base = re.split(r"[<>=!~\s]", line, maxsplit=1)[0]
        base = base.split("[", 1)[0]

        if base:
            names.add(base.replace("_", "-").lower())

    return names


def find_missing_packages(new_path: Path, requirements_path: Path) -> set[str]:
    """Return packages present in ``new_path`` but absent from ``requirements_path``."""

    new_packages = extract_package_names(new_path.read_text(encoding="utf-8").splitlines())
    if requirements_path.exists():
        existing_packages = extract_package_names(
            requirements_path.read_text(encoding="utf-8").splitlines()
        )
    else:
        existing_packages = set()

    return new_packages - existing_packages


def fetch_latest_version(package: str, timeout: float = 10.0) -> str:
    """Return the latest version of ``package`` available on PyPI."""

    url = f"https://pypi.org/pypi/{package}/json"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"Failed to fetch {package!r} metadata from PyPI: {exc}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Failed to reach PyPI for {package!r}: {exc}") from exc

    version = payload.get("info", {}).get("version")
    if not version:
        raise RuntimeError(f"No version information available for {package!r} on PyPI")

    return version


def main() -> None:
    new_path = Path("new.txt")
    requirements_path = Path("python_requirements.txt")

    missing = find_missing_packages(new_path, requirements_path)
    if not missing:
        print("No new packages detected.")
        return

    additions: list[str] = []
    print("New packages not present in requirements (appending with latest versions):")
    for package in sorted(missing):
        version = fetch_latest_version(package)
        requirement = f"{package}=={version}"
        additions.append(requirement)
        print(f"- {requirement}")

    existing_content = requirements_path.read_text(encoding="utf-8") if requirements_path.exists() else ""
    needs_newline = bool(existing_content) and not existing_content.endswith("\n")
    with requirements_path.open("a", encoding="utf-8") as handle:
        if needs_newline:
            handle.write("\n")

        handle.write("\n".join(additions))
        handle.write("\n")


if __name__ == "__main__":
    main()
