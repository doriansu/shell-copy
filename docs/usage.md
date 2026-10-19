# Usage and privacy

[← README](../README.md)

## Use

The menu contains:

- **Automatically Join Wrapped Lines**: checked when enabled. First launch defaults to off; your choice persists across launches. Enabling, or launching with a saved enabled choice, takes the current clipboard as a baseline and leaves it unchanged. Copy new text to process it.
- **Processing Method**: choose **Local Rules (Offline)**, **Jev (Sends Text to TypeSafe)**, or **bjev (Sends Text to bjev (ByteDance))**. New installs default to local rules. Existing Jev users retain their selected mode and key. The selected method persists; switching cancels pending requests and leaves the current copy unchanged. In either AI mode, the selected service judges the original copy without local normalization. It selects keep, join without a space, or join with one space for each nonblank boundary. Only one service receives a copy. Local mode remains explicitly offline; selecting or upgrading the app does not silently opt you into cloud transmission.
- **Combine AI with Local Rules**: on by default in cloud modes. Combine validated AI judgments with local boundary rules and show the decision source in Last Copy Details. Uncheck for AI-only decisions. This setting does not itself enable failure fallback.
- **Use Local Rules If AI Fails**: off by default; explicitly saved preferences are preserved. Turn this on to allow offline heuristics after a failed AI request. With it off, failures keep the original copy. This setting only affects failures; successful responses follow the separate hybrid/AI-only setting.
- **TypeSafe API Key…** and **bjev (ByteDance) API Key…**: paste a key or choose **Import File…** for a UTF-8 file containing just the key. Each service has a separate macOS keychain item. Updating one never replaces the other. Removing the selected service's key switches to local rules. Keys are never stored in preferences, logs, source, or the app bundle.
- A status line distinguishes local completion without a cloud request, a validated cloud response with accepted/candidate counts, and failure with local fallback or unchanged text. **Last Copy Details** shows why a request was skipped, each boundary's visual-wrap probability, conditional spacing probability, and applied action, clipboard write outcome, and total processing time in milliseconds. Low-probability actions are explicitly shown as kept below threshold. Line numbers refer to the original copy, not a locally transformed intermediate result. Scores are model outputs, not measured accuracy. HTTP/transport error codes are shown without response bodies or credentials. These diagnostics stay in memory for the current copy and clear on the next external copy, a settings/key change, restore, or exit; no copied text or keys appear in them. Tests use intercepted responses; they do not establish live bjev availability.
- **Restore Original Text**: restores the most recent transformed item's original representations. It is disabled when unavailable.
- **Check for Updates…**: checks for a newer compatible release, even if automatic checks are disabled. Sparkle displays release notes and offers installation or deferral. Downloads can be canceled; installation and relaunch require user confirmation.
- **Automatically Check for Updates**: on by default, checks approximately once per day while the app runs. Your choice persists. This enables checking, not silent installation.
- **Quit Shell Copy**.

The app polls every 300 ms with 50 ms timer tolerance. Actual latency can be longer when macOS is busy or asleep. Pasting immediately after copying can paste the original text; several copies between polls expose only the last one. Disabled mode never rewrites the clipboard.

### Enable a cloud service

1. Save or import the corresponding key from its **API Key…** menu item.
2. Choose **Processing Method → Jev** or **Processing Method → bjev**, and enable **Automatically Join Wrapped Lines**.
3. Copy new text and wait for the status to finish before pasting. Use **Restore Original Text** if needed.

**Combine AI with Local Rules** is on by default for cloud modes. Uncheck it for the previous AI-only policy; the choice persists. This does not enable a cloud provider or automatic copying on its own. **Use Local Rules If AI Fails** remains a separate, opt-in fallback setting with existing preferences preserved.

bjev uses the ByteDance internal service. Obtain its key from the playground's **API Key → Generate new API Key** flow. Generating a replacement invalidates old bjev keys. An optional local backup belongs in `.secrets/` (ignored by version control), with directory mode 700 and file mode 600. The app reads imported keys from the keychain after import, not from the backup file.

For setup without copying a secret to the clipboard or shell arguments:

```sh
"build/Shell Copy.app/Contents/MacOS/ShellCopy" --import-api-key bjev "$PWD/.secrets/bjev-api-key.txt" --select
```

Use `jev` for TypeSafe instead. `--select` selects that provider without changing the automatic-joining or fallback preferences. Restart the app to load changes made through this command. The import does not print the key.

The secure key field supports **Command-V** to paste and **Command-A** to select an existing entry for replacement. The app installs standard Edit menu actions so those shortcuts work in its modal dialog.

Every eligible multiline copy in AI mode adds a network round trip, including copies that offline rules could have handled. Requests have a five-second network deadline and responses older than five seconds from the start of processing are discarded. This is a maximum wait, not a fixed delay. There are no automatic retries. The original text remains available to paste while a request is in flight; the app does not intercept or delay Command-V.

A successful conversion writes plain text. Any admitted HTML/RTF formatting is absent from that converted copy. Restore brings back the exact saved bytes of every original representation. The snapshot is kept only in memory, at most one item and 8 MiB total. It expires on restore, the next external clipboard change, or app exit. Turning automatic mode off does not by itself discard it. Restore also works while automatic mode is off. It never reprocesses its own restored copy. This is an undo for the current conversion, not clipboard history.

Only single items with UTF-8 plain text and optional known plain-text, RTF or HTML representations are admitted. The processing markers `com.sindresorhus.Pure-Paste.hasRun` and `x.nspasteboard.ModifiedType` are also accepted and preserved on rewritten copies and undo; their payloads are not sent to AI. Files, URLs with URL representations, images, attachments, multiple items, concealed/transient/auto-generated markers and other unknown app-specific formats are skipped. Last Copy Details lists the rejected type names without showing their payloads. Plain text larger than 1 MiB and snapshots larger than 8 MiB are skipped. The app does not log or save clipboard contents to disk. Both cloud providers use an ephemeral HTTP session with no response cache or credential/cookie storage, and refuse redirects.

Pure Paste compatibility: its [official troubleshooting guide](https://sindresorhus.com/pure-paste) identifies `com.sindresorhus.Pure-Paste.hasRun` as a marker of completed processing. Previously, our format allowlist rejected copies carrying this marker before either AI or local normalization ran. The compatibility exception is limited to the two processing markers observed together; it does not bypass confidential-content protection or allow arbitrary custom formats. Preserving the markers avoids discarding another utility's processing state, but does not guarantee conflict-free operation with every clipboard utility.

Before rewriting or restoring, the app checks the pasteboard change count and abandons stale work if a newer copy arrived. It also checks after claiming pasteboard ownership. AppKit does not provide atomic compare-and-swap across the check/clear/write calls, so there is still a small unavoidable race with other processes during those calls. A detected later change is left for the next poll.

## Limits

Plain text cannot reliably distinguish soft wrapping from intentional newlines. In local mode, unindented wraps, short text and uncertain blocks remain unchanged. Cloud judgment broadens the candidates but can still misjudge them. Some prose will be skipped, and intentional line breaks can still be joined. The recognizers do not parse every programming language or shell command. This app cannot promise lossless reconstruction of arbitrary terminal output; use Restore while the converted copy is still current if a conversion is unwanted.
