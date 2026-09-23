#!/usr/bin/env python3
"""Remove duplicate CLI State bundles, preserving the installed app and user data."""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

BUNDLE_ID = "com.clistate.app"


def is_clistate(path):
    if path.is_symlink():
        return False
    try:
        with (path / "Contents/Info.plist").open("rb") as source:
            return plistlib.load(source).get("CFBundleIdentifier") == BUNDLE_ID
    except (OSError, ValueError, plistlib.InvalidFileException):
        return False


def find_copies(roots, installed):
    copies = set()
    for root in roots:
        root = Path(root)
        if not root.exists() or root.is_symlink():
            continue
        for directory, children, _ in os.walk(root, followlinks=False):
            path = Path(directory)
            if path.suffix == ".app":
                children[:] = []
                if path.resolve() != installed.resolve() and is_clistate(path):
                    copies.add(path.resolve())
            else:
                children[:] = [name for name in children if name not in {".git", "SourcePackages", "node_modules", ".build"}]
    return sorted(copies)


def remove_copies(copies, installed):
    # Never remove the only usable copy if installation failed.
    if not is_clistate(installed):
        raise ValueError("A verified installed CLI State bundle is required before cleanup")
    for path in copies:
        if path.resolve() == installed.resolve() or not is_clistate(path):
            continue
        shutil.rmtree(path)
        print(f"Removed duplicate: {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    installed = Path("/Applications/CLIState.app")
    roots = [Path("/Applications"), Path.home() / "Applications", root]
    roots += list(Path("/tmp").glob("clistate-*"))
    roots += list(Path(tempfile.gettempdir()).glob("clistate-*"))
    copies = set(find_copies(roots, installed))
    spotlight = subprocess.run(["/usr/bin/mdfind", f'kMDItemCFBundleIdentifier == "{BUNDLE_ID}"'], capture_output=True, text=True, check=True)
    for line in spotlight.stdout.splitlines():
        path = Path(line)
        if path.suffix == ".app" and is_clistate(path) and path.resolve() != installed.resolve():
            copies.add(path.resolve())
    if args.dry_run:
        for path in sorted(copies):
            print(path)
    else:
        remove_copies(sorted(copies), installed)


if __name__ == "__main__":
    main()
