#!/usr/bin/env python3

import argparse
from pathlib import Path
import plistlib


def main():
    parser = argparse.ArgumentParser(description="Sync the shared release helper into app repositories.")
    parser.add_argument("--workspace", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent / "lib" / "release_common.sh"
    content = source.read_bytes()
    changed = []
    checked = []
    for repository in sorted(args.workspace.iterdir()):
        config = repository / "release" / "Release.plist"
        if not (repository / ".git").exists() or not config.is_file():
            continue
        backend = plistlib.loads(config.read_bytes()).get("BuildBackend")
        if backend not in {"swiftpm", "cargo+swiftc"}:
            continue
        target = repository / "scripts" / "lib" / "release_common.sh"
        checked.append(repository.name)
        if target.is_file() and target.read_bytes() == content:
            continue
        changed.append(repository.name)
        if not args.check:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
            target.chmod(source.stat().st_mode & 0o777)
    if not checked:
        parser.error("No supported app repositories were found")
    if args.check and changed:
        print("Release helpers differ: " + ", ".join(changed))
        return 1
    print("Release helpers " + ("checked: " if args.check else "synced: ") + ", ".join(checked))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
