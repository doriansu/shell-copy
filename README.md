# Shell Copy

A small macOS menu bar app that joins wrapped clipboard text, so copied terminal output is ready to paste. Built with Swift and AppKit.

- Join Chinese and English prose with offline rules.
- Optionally use Jev / TypeSafe or bjev / ByteDance to judge line breaks.
- Restore the original text and formatting after an unwanted conversion.
- Check for updates from the menu bar with Sparkle.

```text
seedmux-lite-
  team

↓

seedmux-lite-team
```

## Get started

Requires macOS 13 or later. To build from source, install a Swift 5.9+ toolchain, such as Xcode Command Line Tools, then run from the repository root:

```sh
bash scripts/check.sh
open "build/Shell Copy.app"
```

The script runs tests and builds an ad-hoc signed app for the current Mac. The first build downloads Sparkle. For a build without tests, use `bash scripts/build-app.sh`.

Release downloads and notes are on [GitHub Releases](https://github.com/doriansu/shell-copy/releases). Ad-hoc builds are not notarized by Apple; Gatekeeper may block downloaded copies on first launch.

## Usage

1. Open Shell Copy from the menu bar. There is no Dock icon or main window.
2. Enable **Automatically Join Wrapped Lines**. It starts off on first launch.
3. Copy new text, wait for processing to finish, then paste.

Enabling the app leaves the current clipboard unchanged. Local rules are the default and work offline. The app checks for new copies every 300 ms, so pasting immediately can still paste the original text.

Choose **Restore Original Text** to undo the latest conversion while that copy is still current. **Last Copy Details** explains what was joined, kept or skipped. **Check for Updates…** checks for a newer release; installation requires confirmation.

### Optional AI

Save a key through the provider's **API Key…** menu item, then select it under **Processing Method**. Jev uses TypeSafe; bjev requires access to the ByteDance internal service. Copy new text after switching modes.

| Setting | Default | Behavior |
| --- | --- | --- |
| Combine AI with Local Rules | On | Combine validated AI judgments with local rules. |
| Use Local Rules If AI Fails | Off | Allow offline processing when an AI request fails. Otherwise keep the original. |

AI modes send the full eligible plain-text copy to the selected service. Keys are stored separately in macOS Keychain. Requests have a five-second deadline; the original remains available to paste while processing. See [setup, key import and privacy](docs/usage.md).

## Limits and privacy

- Line-break detection is heuristic. Intentional breaks can be joined, and some wraps will be missed. Use Restore for unwanted changes.
- Converted copies are plain text. Restore recovers the saved original formatting, but only until the next external copy or app exit.
- Files, images, multiple clipboard items and unsupported formats are skipped. Plain text over 1 MiB is skipped; AI requests are limited to 12 KiB and 64 nonblank line boundaries.
- Clipboard contents are not logged or saved to disk. Undo holds one item in memory, up to 8 MiB. Local mode sends no text to an AI service; update checks contact GitHub.

## Documentation

- [Usage and privacy](docs/usage.md): menu settings, API keys, supported clipboard formats and undo.
- [Processing rules](docs/processing.md): local heuristics, AI decisions and hybrid behavior.
- [Development](docs/development.md): builds, tests and source layout.
- [AI evaluation](docs/evaluation.md): live-test commands, observed results and known failures.
- [Publishing and updates](docs/publishing.md): signing, release preparation and updater tests.
