# Release helper

`release_common.sh` in this repository is the source for the shared helper used by the personal apps. Each app keeps its own copy, so release builds do not need another repository or a network download.

After changing the source helper, run these commands from Clippie:

```sh
uv run --no-project python -S scripts/sync-release-helpers.py
uv run --no-project python -S scripts/sync-release-helpers.py --check
```

Use `--workspace /path/to/personal-apps` when the other app repositories are in a different folder. The command discovers repositories with a supported `release/Release.plist` and updates only their helper file. Review and commit each repository separately.

App names, icons, permissions, and signing settings belong in each app's `release/Release.plist`. Mailie's Rust/native build and Ntfy Notifier's login registration remain in their app-specific entry scripts.
