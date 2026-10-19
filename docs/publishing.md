# Publishing and updates

[← README](../README.md)

## In-app updates and publishing

Sparkle 2.10.0 handles version comparison, update windows, downloading, signature validation, installation and relaunch. The app requires both a signed appcast and an EdDSA-signed archive, verified before extraction. Automatic download/installation and system profiling are disabled. Checking updates contacts GitHub, which receives ordinary request metadata such as IP address and User-Agent; it does not send clipboard contents or model API keys. Existing preferences and keychain item identifiers are unchanged.

The feed is `https://github.com/doriansu/shell-copy/releases/latest/download/appcast.xml`. Both this file and the ZIP are GitHub Release assets. No custom server, GitHub Pages or GitHub token in the app is needed. Until the first release containing these assets is published, manual checks report a download error; background failures do not block clipboard processing. Versions older than 1.1.0 do not have an updater and must be replaced manually once.

### One-time publisher setup

The public update key, feed URL, version and update defaults live in `Config/Release.plist`. The matching private key lives in the publisher's login keychain under Sparkle account `local.shell-copy.app.sparkle`; it is not in the repository or app. Back up that private key securely before distributing the first updater-enabled version. Losing it can prevent updates to already installed copies. Never generate a replacement key just to fix a build or commit a private-key export.

By default, release preparation requires your own **Developer ID Application** signing identity and a stored `notarytool` keychain profile. Do not use an employer's certificate without authorization. Without a paid Apple membership, explicitly use `ALLOW_ADHOC_RELEASE=1` to prepare an ad-hoc, unnotarized release. This retains Sparkle signatures for both the feed and archive, but macOS may block first launch. Do not disable system-wide security protections. See Apple's [notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and Sparkle's [setup and signing guide](https://sparkle-project.org/documentation/).

### Prepare a release

1. Update `CFBundleShortVersionString` and strictly increase the integer `CFBundleVersion` in `Config/Release.plist`. Keep the bundle identifier and signing public key stable.
2. Write release notes in a local Markdown file. For notarized releases, set `CODE_SIGN_IDENTITY` and `NOTARYTOOL_PROFILE`. For ad-hoc releases, clearly disclose the lack of Apple notarization in the notes.
3. Run `bash scripts/prepare-release.sh /path/to/release-notes.md`, or `ALLOW_ADHOC_RELEASE=1 bash scripts/prepare-release.sh /path/to/release-notes.md` without Apple credentials.
4. Create a draft GitHub Release tagged `v<version>` from the tested source commit. Upload exactly `build/releases/<version>/ShellCopy-<version>.zip` and `build/releases/<version>/appcast.xml`.
5. Publish the draft as a normal, latest release only after both assets are present. Verify both public downloads, then test updating an older installed copy.

The script runs tests, builds a universal app, signs its nested components, packages it, and generates and verifies Sparkle signatures. The default mode also submits for notarization and staples the ticket; the explicit ad-hoc mode skips those Apple steps. It refuses mismatched signing keys, custom test configuration and overwriting an existing release directory. It does not publish or push anything. A failed attempt leaves its files for inspection; move that version's output directory aside before retrying. Do not modify the archive or appcast after signing. When publishing newer releases, always attach the appcast; a release without it breaks the `latest` feed URL.

The feed currently contains one universal release targeting macOS 13+. If a future version drops an OS or architecture, retain compatible older entries in a cumulative feed before publishing that change. Never decrease the build number to roll back a release; publish the fix with a higher build number.

### Failure and consistency policy

Release assets and the feed are served across GitHub's caches. A stale feed can delay an update, which is preferable to interrupting clipboard use. Publishing a draft with both assets minimizes the interval in which a feed points to a missing archive. Failed downloads or invalid signatures leave the installed app intact. Automatic retries follow Sparkle's schedule rather than a busy polling loop. This is eventual discovery of immutable releases, not shared mutable application state; no distributed lock or database is needed.

Before public distribution, test the standard update window's install, remind-later/skip and download-cancel paths, offline behavior, no-update behavior, tampered signatures, and a complete old-to-new install/relaunch. Test notarized copies downloaded through a browser too: local ad-hoc tests do not exercise Gatekeeper or app translocation. Install the app in a writable Applications folder, not inside a mounted read-only disk image. Restarting loses the in-memory clipboard undo snapshot, but not saved preferences or keychain credentials.

`python3 scripts/test-update-integration.py` runs the real Sparkle updater against disposable test apps and a loopback-only HTTP server. It uses a fresh test signing key, checks automatic discovery, cancellation, tampered feeds/archives, installation and current-version behavior, and leaves logs in the printed temporary directory. It needs a logged-in macOS GUI session and permission to launch the test apps. The test apps default to local rules with clipboard rewriting off and use unique preference domains; they do not use your API keys. Add `--ui` to inspect the standard update window manually, then stop with Ctrl-C. A timeout is a failure, not a skipped test.
