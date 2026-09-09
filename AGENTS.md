# clippie Agent Notes

Use [shared workspace rules](../AGENTS.md) for UI copy, configuration, repository scope, and release completion.

## Signed Builds

- Build this app with signing enabled.
- When the user asks to build the app, build a signed local Release build.
- When the user asks to build the app, move the built app to `/Applications` after a successful build, then open it from there.
- Do not use ad-hoc or unsigned signing unless the user explicitly asks for it.
- Unsigned builds can cause macOS Accessibility permission to be requested again after rebuilds.

Use:

```bash
./scripts/release-local.sh
```

Build a signed local release app without installing it:

```bash
./scripts/build-release.sh
```

## Signing Expectations

- The app compiles with Swift Package Manager and is packaged/signed by the repo-local release scripts.
- The user has already confirmed local Release builds can use the existing signing setup.
- Use bundle identifier `nl.bentjes.clippie` unless the user asks to change it.
- If signing fails, do not silently switch to an unsigned build. Tell the user what failed.
