#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import subprocess
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ALLOWLIST_PATH = REPO_ROOT / "tools" / "lint" / "map_frame_allowlist.txt"


def load_allowlist() -> set[str]:
    entries = set()
    for line in ALLOWLIST_PATH.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        entries.add(line)
    return entries


def run_rg() -> list[tuple[str, str]]:
    rg_cmd = [
        "rg",
        "--no-heading",
        "--line-number",
        "--glob",
        "!*.md",
        r"\bmap_frame\(",
    ]
    proc = subprocess.run(
        rg_cmd,
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    if proc.returncode not in (0, 1):
        sys.stderr.write(proc.stderr)
        raise SystemExit(proc.returncode)

    matches = []
    for line in proc.stdout.strip().splitlines():
        if not line:
            continue
        path, lineno, rest = line.split(":", 2)
        matches.append((path, lineno))
    return matches


def main() -> None:
    allowlist = load_allowlist()
    violations: list[str] = []

    for path, lineno in run_rg():
        if path in allowlist:
            continue
        violations.append(f"{path}:{lineno}")

    if violations:
        sys.stderr.write("map_frame() referenced outside the approved allow-list:\n")
        for entry in violations:
            sys.stderr.write(f"  {entry}\n")
        sys.stderr.write(
            "Either migrate the caller to vm_map_owned_frame or extend "
            "tools/lint/map_frame_allowlist.txt with a justification.\n"
        )
        raise SystemExit(1)


if __name__ == "__main__":
    main()
