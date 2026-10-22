# Tweaks

Tweaks is a small background app for macOS that does a handful of quality-of-life
things, chosen from the Supercharge features actually in use on one Mac. It has no
menu bar icon; open it again from Finder, Spotlight or Raycast to see its settings,
where every tweak has its own control.

Settings uses a native macOS sidebar with General, Audio, Files & Finder, Copied
Links, Keep Awake, Windows, Network, Shortcuts and Activity pages. Standard controls
and grouped sections follow system light/dark appearance and accent colors. The
window is resizable. ⌘, opens Settings, ⌘W closes it while Tweaks keeps running,
and the explicit Quit command (⌘Q) quits through the normal recovery checks.

**Keyboard and sound**
- Caps Lock with no delay: a normal tap toggles it instantly (the HID
  `CapsLockDelayOverride` property, reapplied on wake and every fifteen minutes). Turning it
  off restores each keyboard's previous delay from this boot, or macOS's usual
  quarter-second hold if Tweaks never saw another value.
- One **Volume limits** section combines the default wake maximum (40% until you
  change it) and optional per-device limits. Existing wake and device switches and
  saved rules are preserved. When both apply, the lower maximum wins.
- Optional volume limits for individual output devices, with an option to mute the
  next output when switching away from a selected device. Limits never raise the
  volume, including quieter individual channels; master and channel-only software
  controls are supported. Devices with their own hardware control are identified in settings. The
  default wake maximum also applies if it remains enabled.
- A speaker icon in the menu bar only while sound is muted; click it to unmute.
- The play/pause key no longer opens Music; opening Music yourself still works.

**Downloads**
- File extensions lowercased as downloads land (`IMG_0001.JPG` → `IMG_0001.jpg`).
- Calendar invites (`.ics`) open in Fantastical with their alarms removed, then go to
  the Trash.
- When a disk image you downloaded mounts with a single app inside, Tweaks offers to
  copy it to Applications (the old copy goes to the Trash), eject the image, trash the
  `.dmg` and open the app. If the old app cannot go to Trash, its recovery path is
  shown. If eject fails, the downloaded image is kept.
- Optional duplicate-download review compares new files with existing files in
  Downloads. Exact matches stay intact, with **Show Both**, **Keep Both**, and
  **Trash New Copy** actions. The trash action checks both files again. Duplicate
  ZIPs and invites are not automatically extracted/imported. Empty files, links,
  hard links, and files with resource forks are excluded; review entries last for
  the current app session.

**More downloads and clipboard**
- New `.zip` downloads are extracted next to the archive (one item comes out as is,
  several go in a folder named after the zip), then the zip goes to the Trash.
- Tracking parameters (`utm_…`, `fbclid`, YouTube and Spotify `si=`, X `s=`/`t=`, …)
  are stripped from copied links within a few seconds; a fast paste can happen
  before cleaning. Only a clipboard holding a single http(s)
  link is touched, and password-manager items never are.
- **Clean Link Now** runs immediately, including when automatic cleaning is off or
  paused. **Restore Original** restores all original clipboard formats only while
  Tweaks still owns that clipboard generation. Site exclusions cover the named
  domain and its subdomains. An optional global shortcut starts unassigned.

**Automatic actions and history**
- Feature controls show Ready, Working, Active, Waiting, Paused, Blocked or Off.
  Activity highlights active and attention-needed features, with Show all features
  for a complete overview. Manual Keep Awake and render holds are shown separately.
- In **Activity**, pause Downloads processing, disk-image offers and automatic link
  cleaning for 15/30/60 minutes or until a chosen date/time, change a pause, or resume
  early. An optional unassigned shortcut toggles a 30-minute pause. Saved feature switches do not change;
  the deadline survives relaunch and expires after sleep. Files received while
  paused remain untouched on resume. Already-started file transactions finish;
  pending disk-image offers are canceled. Manual actions remain available.
- **Activity → Recent actions** shows the latest 100 download, installer, duplicate-review,
  image-export, link, volume and pause actions from the current session. Clear it
  at any time. History and original clipboard contents stay in memory only.

**Sleep**
- Tweaks tries to eject idle external drives as the Mac sleeps; busy drives remain
  connected. If one refuses, you are told after wake.
- **Eject Idle External Drives** is also available on demand, with an optional
  configurable shortcut. It checks mounted sibling volumes on each physical drive,
  reports blocking processes, and uses normal eject without force. Running render
  engines, unknown drive mappings, and unreadable open-file checks stop eject work.
- The Mac stays awake (the display can still sleep) while After Effects, aerender,
  Media Encoder or Premiere is busy, until two minutes after the work stops.

**Network**
- Optional **Move GlobalProtect to Ethernet** detects usable wired Ethernet on USB
  and Thunderbolt docks, including Satechi and CalDigit TS5 Plus. If GlobalProtect
  stays on Wi-Fi, it briefly reconnects Wi-Fi to move the tunnel, then restores
  Wi-Fi. It verifies the wired router and VPN gateway first, leaves user-disabled
  Wi-Fi alone, and makes one attempt per connection with a five-minute cooldown.
  It never changes VPN authentication; Duo may still be required by the VPN.
  Turning the feature off or quitting restores any Wi-Fi state it owns.
- Network shares are unmounted as the Mac sleeps and remounted after wake once the
  server answers. Unresolved restores persist across further sleeps and app restarts;
  network changes trigger retries, with a one-minute retry after the initial attempts.
- **Keep work shares connected** retries after dock, VPN route/DNS and wake changes,
  with short retries while the VPN settles and a five-minute fallback. Mount requests
  time out after 25 seconds and cancel without waiting forever for the system helper.
  A verified macOS SMB account-lookup hang can reset that user's share helper only
  when no network shares are mounted and no sleep/unmount work is running; resets
  have a ten-minute cooldown. Active shares are left connected. Saved keychain
  credentials are used; VPN/Duo authentication still needs the user when requested.
  Empty macOS mount reservations can be reused to preserve the usual /Volumes path;
  files and mount folders are never deleted or renamed. The server list and enable
  switch remain separate, and turning the switch off cancels pending work.

**Keep Awake** (replaces caffeinate)
- Two modes, both running until you stop them:
  - **Away** (A): the Mac stays awake and never reaches the lock
    screen, so you and remote agents can always get in. The display never sleeps;
    instead the built-in screen fades to 0 (external displays fade to black) after
    two idle minutes and comes back on any key or mouse input. **Dim now** (Z) starts Away already dimmed. The Mac
    stays unlocked while Away runs.
  - **Screen stays on** (O): no dimming, no sleep, for renders or anything you
    want to watch.
- Tap Hyper+/ (⌃⌥⇧⌘/) for Screen stays on; hold it for Away. Tap or hold again to
  stop. The menu bar shows a sun or a moon for the running mode; click it for the
  panel: two mode cards, ⌥-click Away (or Z) to dim now, Stop (S). Arrow keys move,
  Return starts, Esc closes. Shortcuts are changeable in the Tweaks window.
- Renders keep the Mac awake on their own with the "Awake while rendering" tweak.
- A pill appears when a session starts or stops. Any session stops at 15% battery
  when unplugged.
- Settings and the menu-bar panel offer 30 minutes, 1/2/4 hours, a chosen date/time,
  or a chosen running app in addition to Until I stop it. These are session choices;
  they do not change your existing shortcut behavior or saved defaults. Invalid
  deadlines and apps that have exited leave the running session unchanged.
- Links for scripts: `tweaks://awake/away`, `/screenon`, `/screenoff` (Dim now),
  `/stop`, `/toggle`, `/menu`. The older timed links (`?minutes=`, `?hours=`,
  `?until=`, `?app=`, `?done=render|downloads|upload|copy`) still work.

**Finder** (formerly Finder Utilities)
- Copy Path with NAS, Box and Google Drive roots shortened
  (`/Volumes/users/shares/Media/Foo.mov` → `Media/Foo.mov`), Copy Original Path, and
  Inspect Media (frame size, frame rate, duration, codec, alpha, color, audio, DPI).
  Turn it on in System Settings › Login Items & Extensions › Finder Extensions. The
  path logic lives in `Packages/FinderUtilitiesKit`; see
  `docs/finder-utilities-plan.md`. AVFoundation and ImageIO live in
  `TweaksMedia.bundle` and are loaded the first time Inspect Media reads a real
  file, so Finder Sync does not keep them mapped while it is idle.
- Finder menus open without waiting for metadata. A first lookup may show
  “Loading…”; reopen the menu to see the cached result.
- **Quick Image Actions…** opens selected images in Tweaks for JPEG, PNG, or HEIC
  export, original-size or 1024/2048/4096-pixel longest-edge resizing, and optional
  metadata removal (including location). Up to 20 images per selection; originals
  remain intact and exports use unique names beside them. JPEG transparency is
  composited on white. Animated/multi-page input is rejected. The same panel is
  available in Tweaks settings without the Finder extension.

**Windows and notifications** (need Accessibility permission)
- Hyper+N (⌃⌥⇧⌘N) closes every notification on screen.
- "Shortcut is running" banners from Shortcuts close themselves.
- The green window button fills the screen without macOS full screen; click it again
  to restore the window. Hold ⌥ for normal full screen.
- Apps you pick (Preview and TextEdit to start) quit when their last window closes.
- Optional saved window layouts for each monitor arrangement. Enable **Restore
  saved window layouts**, arrange your windows, and choose **Save This Layout**.
  Tweaks restores matching open windows when that exact display setup returns;
  manual save/restore shortcuts are configurable. Closed, full-screen, minimized,
  or ambiguous windows are left alone. Window identity is stored as a fingerprint.

The new automatic window-layout, device-volume, duplicate-review, and Ethernet
VPN handoff features are off by default. The new save/restore/eject shortcuts start unassigned; choose their
keys in **Shortcuts** and enable the corresponding feature. Image export and the
manual eject button run only when selected.

Nothing runs as root and there is no helper. Downloads watching starts after an
asynchronous snapshot of existing files; only later arrivals are processed. File
checks, renames, invite preparation, ZIP validation/extraction, and DMG file work
run in the background so they do not block settings or shortcuts. ZIPs extract one
at a time, and files changed while queued must settle again before extraction.

The settings window, Keep Awake panel and HUD are AppKit. SwiftUI is not linked, so
an idle Tweaks process does not map it. Finder Sync is loaded in the app only while
the settings window is open. Polls that used to run all the time (Accessibility,
copied links, Shortcut banners, quit-on-last-window, render CPU) now wait longer,
or don't run until the thing they watch is actually happening. Turning a tweak off
stops its timer or observer; Caps Lock, Keep Awake and the green button also put
back the delay, the sleep assertion, or the window frames they changed. Network
shares unmounted for sleep are still remounted if that switch is turned off before
they come back.

## Build and run

[Version 0.1.7](docs/dock-hang-2026-10-22.md) is Developer ID-signed, notarized,
stapled and installed locally as build 10, from source `7222203`. It repairs a
confirmed network-context release crash; the CalDigit incident's full system
freeze remains unattributed and physical reconnect acceptance is open.
The [0.1.6 release](docs/status-controls-2026-10-22.md) adds live feature
status, Keep Awake durations and expanded pause controls while preserving existing
settings and shortcuts. The [0.1.5 native Settings rebuild](docs/native-settings-2026-10-22.md)
introduced the AppKit sidebar and grouped pages. The [0.1.4 audio and actions release](docs/audio-actions-2026-10-22.md)
introduced consolidated audio limits, immediate link actions, temporary pause and
session history.
Debug and Release each pass 190 tests with two expected skips; the Finder package
passes 19 tests and all required Release benchmarks pass.

The [0.1.3 share recovery report](docs/share-recovery-2026-10-20.md) records bounded
mounts, dock/VPN retries and guarded recovery, plus the 2026-10-21 hardening pass.
That report includes the earlier Developer ID-signed build 6 and its NAS-access
verification. Live
unplug/stall testing remains deferred while Adobe has files open on the share.

The [0.1.1 repair report](docs/repair-2026-10-17.md) records fixes and verification
for every confirmed defect in the [2026-10-17 audit](docs/verification-2026-10-17.md).
Build 3 (source `8ff89bc`) was signed, notarized and installed locally; final Debug
and Release checks each passed 121 tests with three expected skips and no failures.
Hardware, network and physical-input acceptance remain separate from fixture tests.

Requirements: macOS 14 or later, Xcode, and XcodeGen.

```sh
xcodegen generate
xcodebuild -project Tweaks.xcodeproj -scheme Tweaks -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Test

```sh
xcodebuild -project Tweaks.xcodeproj -scheme Tweaks -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
(cd Packages/FinderUtilitiesKit && swift test)
```

The app test host skips normal background-tweak startup. Download tests use
temporary fixtures. The live-share check skips when no network share is mounted.

## Performance benchmarks

```sh
./scripts/benchmark.sh
./scripts/profile-file-work.sh
```

Runs optimized package and app benchmarks sequentially, with local logs under
`.build/validation/`. It measures cold Finder metadata lookup, cached lookups,
10,000-path cleaning, render polling, link cleaning, and Downloads scans/completion
checks using 10,000-file temporary folders. App results include median/p95 wall
latency and process CPU time after warm-up. Package benchmarks are
opt-in and are skipped by ordinary `swift test`. Release app tests need
`ENABLE_TESTABILITY=YES`; the script supplies it without changing release settings.

The file-work profile measures main-queue scheduling delay, main-thread CPU, and
elapsed time for 100 newly finished downloads and a ZIP containing 2,000 files.
It uses one warm-up and five measured repetitions; ordinary tests skip it.

See the [file-work profiling results](docs/file-work-profile-2026-10-12.md),
[earlier performance results](docs/performance-2026-10-12.md), and
[initial validation report](docs/validation-2026-10-12.md) for measurements,
regression fixes, and the live checks still outstanding.

See [the five-feature validation report](docs/features-2026-10-12.md) for the new
layouts, volume limits, image actions, safe eject, and duplicate review, including
hardware and installed-extension checks still outstanding.

## License

Tweaks is released under the MIT License.
