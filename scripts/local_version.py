#!/usr/bin/env python3
"""Versioning and changelog for local CLI State deliveries."""

import argparse
from datetime import datetime
from pathlib import Path
import re


def read_version(project):
    text = project.read_text()
    version = re.search(r'^    MARKETING_VERSION: "(0\.\d+\.\d+)"$', text, re.M)
    build = re.search(r'^    CURRENT_PROJECT_VERSION: "(\d{1,4})"$', text, re.M)
    if not version or not build:
        raise ValueError("Expected a 0.x.x marketing version and a four-digit build budget")
    return version.group(1), int(build.group(1))


def bump(project, marketing=None):
    old_version, old_build = read_version(project)
    if marketing is not None:
        if not re.fullmatch(r'0\.\d+\.\d+', marketing):
            raise ValueError("Release version must have the form 0.x.x")
        if tuple(map(int, marketing.split('.'))) <= tuple(map(int, old_version.split('.'))):
            raise ValueError("Release version must increase")
    if old_build >= 9999:
        raise ValueError("Four-digit build limit reached; choose a new version policy explicitly")
    version = marketing or old_version
    build = old_build + 1
    text = project.read_text()
    text = re.sub(r'^    MARKETING_VERSION: ".*"$', f'    MARKETING_VERSION: "{version}"', text, count=1, flags=re.M)
    text = re.sub(r'^    CURRENT_PROJECT_VERSION: ".*"$', f'    CURRENT_PROJECT_VERSION: "{build:04d}"', text, count=1, flags=re.M)
    project.write_text(text)
    return version, build


def record(project, changelog, notes):
    version, build = read_version(project)
    heading = f"## {version} ({build:04d})"
    old = changelog.read_text() if changelog.exists() else "# Changelog\n"
    if heading + " — " in old:
        raise ValueError(f"Changelog already contains {heading}")
    if not notes or any(not note.strip() for note in notes):
        raise ValueError("A concrete changelog entry is required")
    date = datetime.now().astimezone().strftime('%Y-%m-%d')
    entry = f"{heading} — {date}\n\n" + "\n".join(f"- {note}" for note in notes)
    body = old.removeprefix("# Changelog").lstrip()
    changelog.write_text("# Changelog\n\n" + entry + "\n\n" + body)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["build", "release", "record", "show"])
    parser.add_argument("notes", nargs="*")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    project = root / "project.yml"
    if args.action == "build":
        version, build = bump(project)
    elif args.action == "release":
        if len(args.notes) != 1:
            parser.error("release requires one 0.x.x version")
        version, build = bump(project, args.notes[0])
    else:
        if args.action == "record":
            record(project, root / "CHANGELOG.md", args.notes)
        version, build = read_version(project)
    print(f"{version} ({build:04d})")


if __name__ == "__main__":
    main()
