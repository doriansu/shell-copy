# Development

[← README](../README.md)

## Build and launch

Requires macOS 13 or later and an installed Swift 5.9+ toolchain, such as Xcode Command Line Tools.

```sh
bash scripts/check.sh
open "build/Shell Copy.app"
```

`check.sh` runs the tests, builds a release executable for the current Mac's architecture and creates an ad-hoc signed app at `build/Shell Copy.app`. For a build without tests, run `bash scripts/build-app.sh`. Outputs and Swift caches stay in `.build/` and `build/`. No installation or login item is created. The app has a menu bar icon and no Dock icon or main window.

The first build downloads the pinned Sparkle dependency. `UNIVERSAL=1 bash scripts/build-app.sh` builds for both Apple Silicon and Intel. The build bundles Sparkle, its installer helpers and license, and verifies nested code signatures. Ad-hoc signing does not establish publisher identity or provide Apple notarization; GitHub downloads may be blocked by Gatekeeper on first launch.

Tests use uniquely named macOS pasteboards and disposable preferences suites. They never read or write the general clipboard. Cloud tests intercept HTTP through `URLProtocol`; they make no live API calls and need no credentials. Clipboard tests need access to the local macOS pasteboard server; an agent sandbox that denies that access must run the acceptance command with authorized sandbox escalation. A missing pasteboard fails acceptance rather than silently skipping tests.

## Source

- `Sources/ShellCopyCore/LineNormalizer.swift`: deterministic text-only rules.
- `Sources/ShellCopyCore/SystemOneNormalizer.swift`: bounded System One requests, protected boundaries, typed response validation, and deterministic reconstruction.
- `Sources/ShellCopyCore/CloudProvider.swift`: separate endpoints, models, and decision thresholds.
- `Sources/ShellCopyCore/ClipboardController.swift`: clipboard eligibility, snapshot, change-count checks and enable/restore state.
- `Sources/ShellCopy/main.swift`: menu and polling timer.
- `Sources/ShellCopy/ApplicationMenu.swift`: standard application/Edit menu and text-editing shortcuts.
- `Sources/ShellCopy/APIKeyStore.swift`: separate macOS keychain storage for each provider.
- `Sources/ShellCopy/APIKeyFile.swift`: bounded plain-text key import.
- `Sources/ShellCopy/UpdateController.swift`: Sparkle integration and update menu state.
- `Config/Release.plist`: release versions, public update key and update policy.
- `scripts/prepare-release.sh`: release preparation with Sparkle signatures, optional Apple notarization, and no automatic publishing.
- `Tests/ShellCopyCoreTests/`: normalizer examples and real isolated-pasteboard state/race tests.
- `Tests/ShellCopyAppTests/`: AppKit shortcut dispatch and secure-field paste tests using synthetic keys and isolated pasteboards.
