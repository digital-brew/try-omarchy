#!/usr/bin/env python3
"""Replace the checked-in package lock with a freshly resolved one when it differs.

Prints the per-package version changes so the refresh stays reviewable in the
build log and in the resulting diff.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path, help="checked-in lock to update")
    parser.add_argument("--refreshed", required=True, type=Path, help="freshly resolved lock")
    args = parser.parse_args()

    refreshed = json.loads(args.refreshed.read_text())
    current = json.loads(args.lock.read_text()) if args.lock.is_file() else {}
    if refreshed.get("schemaVersion") != 1 or not isinstance(refreshed.get("packages"), dict):
        print("adopt-package-lock: refreshed lock has an unexpected shape", file=sys.stderr)
        return 1
    if refreshed == current:
        print("[refresh-lock] package lock already matches the mirrors")
        return 0

    old = current.get("packages", {})
    new = refreshed["packages"]
    changes = [
        f"  {name}: {old.get(name, '<new>')} -> {new.get(name, '<removed>')}"
        for name in sorted(set(old) | set(new))
        if old.get(name) != new.get(name)
    ]
    shutil.copyfile(args.refreshed, args.lock)
    print(f"[refresh-lock] adopted {len(changes)} package change(s) into {args.lock.name}:")
    print("\n".join(changes[:40]))
    if len(changes) > 40:
        print(f"  ... and {len(changes) - 40} more")
    print("[refresh-lock] review with: git diff -- guest/packages.lock.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
