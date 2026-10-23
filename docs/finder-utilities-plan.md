# Finder Utilities rebuild plan

Source of the old app (v0.1.0, built 2026-08-20) is lost; this plan is based on strings recovered from the installed binary. Items marked [Q] are open questions for Erik.

## Guiding decisions
1. Copy Path never touches the disk: output is built from URL strings plus an in-memory mount table, so it is fast on APFS, a dead SMB share, or a Box placeholder.
2. `menu(for:)` does no I/O (target < 5 ms). It reads only the settings snapshot, mount table and metadata cache.
3. Pure core, thin shell: all path logic lives in a Foundation-only Swift package `FinderUtilitiesKit` (testable with `swift test`). FinderSync and SwiftUI targets are thin adapters.
4. Metadata is best effort, cancellable, isolated, and must never materialize cloud files or hang Finder.
5. Interim (approved by Erik 2026-10-12): the extension carries `com.apple.security.temporary-exception.files.absolute-path.read-only` for `/` so the Inspect Media submenu can read files. Replace the temporary-exception entitlement (M3): the extension does zero file I/O; a non-sandboxed host-app Inspector reads files.
6. Defaults: NFC output, POSIX paths as Finder shows them (no symlink resolution), newline-joined multi-select, raw strings only on the pasteboard (never public.file-url).

## Layout
XcodeGen `project.yml` (Swift 6, macOS 27, hardened runtime, Developer ID, like UpdateBar). Targets: FinderUtilities (SwiftUI app), FinderUtilitiesFinderSync (appex, com.erole.FinderUtilities.FinderSync), FinderUtilitiesTests. Package `Packages/FinderUtilitiesKit` with Model/, Paths/ (PathCleaner, PathNormalizer, ProviderRoots, MountTable, RulesEngine, Formatters) and Metadata/ (provider protocol, cache). Extension: FinderSyncExtension, MenuBuilder (pure), MountMonitor, ScopeController, Clipboard, Metadata providers + IOGuard. Docs: AGENTS.md, README.md, ROADMAP.md, docs/releasing.md, docs/manual-test-matrix.md. Settings shared via app group (Team-ID-prefixed id) + Darwin notification.

## Share-drive and local robustness
- Scope: monitor `/` plus every mounted volume root plus ~/Library/CloudStorage; debounce 300 ms; only reassign directoryURLs when the set changes.
- Mounts: `getfsstat(MNT_NOWAIT)` (never blocks on a hung server) plus NSWorkspace mount/unmount/rename notifications.
- Identity-based matching on server + share (from the mount table), so `/Volumes/name-1` duplicate mounts and renamed mount points map correctly. Longest-prefix fallback.
- Path normalization: strip /System/Volumes/Data firmlinks, map /private/var|tmp|etc, NFC-compare names (SMB/HFS often return NFD), no symlink resolution (I/O can hang).
- Cloud roots: Box-Box, GoogleDrive-<email>/My Drive and Shared drives, OneDrive, Dropbox, iCloud Drive, plus legacy ~/Box and /Volumes/GoogleDrive. Use the real home from getpwuid, not NSHomeDirectory (sandbox container).
- Outputs: Cleaned (parity), Original, smb:// URL, file:// URL, shell-escaped, and user mapping rules (e.g. Windows UNC `\\server\share\...`) matched by server/share identity.
- Metadata: Spotlight, ImageIO, AVFoundation (no subprocesses); timeouts (2 s local, 4 s network); per-volume circuit breaker (2 timeouts in 60 s => 5 min cool-down); concurrency cap per volume; dataless files detected via lstat SF_DATALESS and guarded with the no-materialize iopolicy; cloud files are never downloaded unless the user opts in.
- Clipboard: `.string` only, strip NULs, 8 MB cap, org.nspasteboard.source marker.
- Logging: OSLog categories with privacy-annotated paths, signposts on menu build.

## Testing
- Package tests (Swift Testing) driven by fixtures/paths.json, 40+ cases: local, firmlinks, SMB/AFP/NFS/WebDAV mounts, duplicate `-1` mounts, share names with spaces, nested mounts, Box, Google Drive (multi-account, shared drives, legacy), OneDrive/Dropbox/iCloud, NFD vs NFC, special characters and newlines in names, shell-escape round trip, 10k-item selection speed.
- Fake providers for metadata: timeout, hang, circuit breaker, cancellation, dataless short-circuit.
- Xcode tests for MenuBuilder, MountMonitor parsing, Clipboard (private pasteboard).
- Manual matrix (docs/manual-test-matrix.md): mount SMB while Finder runs, duplicate mount, pull the cable on a mounted share, unmount while running, Box/Drive online-only files (must stay un-downloaded), 5,000-file selection, 50 GB video on SMB, NFD names, live settings change, custom scope, fresh account with notarized build, coexistence with other Finder Sync extensions.

## Milestones
- M0 Scaffold + repo, CI, empty extension showing a menu item (~1 day).
- M1 Parity: PathCleaner, Copy Path / Original Path, settings UI, Inspect Media submenu with guards (~2-3 days). Needs 10-20 real example paths from Erik first.
- M2 Share-drive robustness: MountMonitor, ScopeController, identity matching, SMB/UNC outputs, circuit breaker, rules editor (~3-4 days).
- M3 Improvements: host-app Inspector, drop temporary-exception entitlement, shell/file-URL variants, diagnostics, rule import/export (~3-5 days).
- M4 Release: Developer ID signing, notarization, DMG, cleanup of the old registered extension (~1 day).

## Risks
Finder Sync de-emphasized by Apple (keep core reusable for a Services/Shortcuts fallback); `/` scope not covering /Volumes on some macOS versions (explicit volume roots, verify on 14/15/26); uncancellable AVFoundation reads on hung SMB (caps, breaker, out-of-process Inspector); legacy FUSE Drive volumes lack dataless flags (treat as network); app-group id must match signing exactly (add nonce self-check); old and new builds sharing a bundle id.

## Open questions for Erik
1. Exact output for `/Volumes/users/shares/Media/Foo.mov`: `Media/Foo.mov`, `/Media/Foo.mov`, or other? What was the "Clean path marker"?
2. Box / Google Drive shortened forms (`Box/...`, `My Drive/...`)? Keep the account when several are signed in?
3. Which Windows/UNC targets matter (FQDN vs short name, drive letters)?
4. Which Inspect Media fields do you use (codec, resolution, fps, duration, timecode, bitrate, color space, audio channels)?
5. Is a separate Inspector window acceptable instead of live values in the right-click submenu?
6. Should the host app be sandboxed / a menu-bar (LSUIElement) app like UpdateBar?
7. Which macOS versions are in use? Is AFP still used?
8. Is a public repo OK (team ID and app group id appear in config)?
9. Can you share `defaults read com.erole.FinderUtilities` and a handful of real paths for test fixtures?

## Ranked improvement ideas
1. Identity-based share mapping to Windows UNC / smb:// links.
2. "Copy as link" for Box / Google Drive files (feasibility unknown).
3. Paste-to-open: resolve a pasted UNC/smb/cleaned path to the local path, mount if needed, reveal in Finder.
4. Services / Shortcuts "Copy Path" fallback (works in Open/Save panels and if Finder Sync breaks).
5. Batch media inspector with CSV export.
6. Relative path to a project root or between selections.
7. Token templates for custom formats ({path}, {name}, {parent}, {smb}, {unc}).
8. Share health indicator in the toolbar menu.
