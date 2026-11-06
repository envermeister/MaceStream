#!/usr/bin/env python3
"""Convert absolute Linux symlinks to relative links compatible with macOS signing."""

from __future__ import annotations

import os
from pathlib import Path
import sys


def main() -> int:
    if len(sys.argv) != 2:
        raise RuntimeError("Usage: relativize_runtime_symlinks.py <runtime-directory>")
    runtime = Path(sys.argv[1]).resolve()
    if not runtime.is_dir():
        raise RuntimeError(f"Runtime directory not found: {runtime}")

    rewritten = 0
    for path in runtime.rglob("*"):
        if not path.is_symlink():
            continue
        target = os.readlink(path)
        if not target.startswith("/"):
            continue
        guest_path = Path(target)
        if guest_path.parts[:3] == ("/", "lib", "x86_64-linux-gnu"):
            mapped = runtime / "usr/lib/x86_64-linux-gnu" / Path(
                *guest_path.parts[3:]
            )
        elif guest_path.parts[:2] in (("/", "opt"), ("/", "usr")):
            mapped = runtime / Path(*guest_path.parts[1:])
        else:
            raise RuntimeError(
                f"Refusing to keep an absolute symlink that points outside the package: {path} -> {target}"
            )
        if not mapped.exists() and not mapped.is_symlink():
            raise RuntimeError(f"Symlink target is missing from the package: {path} -> {target}")
        path.unlink()
        path.symlink_to(os.path.relpath(mapped, path.parent))
        rewritten += 1

    for path in runtime.rglob("*"):
        if path.is_symlink() and not path.exists():
            raise RuntimeError(f"Unresolved package symlink: {path}")
    print(f"Absolute symlinks converted to relative paths: {rewritten}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError) as error:
        print(f"Could not fix runtime symlinks: {error}", file=sys.stderr)
        raise SystemExit(1) from error
