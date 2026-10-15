# Tweaks

Tweaks is a small background app for macOS that does a handful of quality-of-life
things, chosen from the Supercharge features actually in use on one Mac. It has no
menu bar icon; open it again from Finder, Spotlight or Raycast to see its settings,
where every tweak has its own switch.

**Keyboard and sound**
- Caps Lock with no delay: a normal tap toggles it instantly (`hidutil`
  `CapsLockDelayOverride`, reapplied on wake and every fifteen minutes). Turning it
  off puts the previous delay back, or macOS's usual quarter-second hold if Tweaks
  never saw another value.
- Volume capped at 40% after waking.
- Optional volume limits for individual output devices, with an option to mute the
  next output when switching away from a selected device. Limits never raise the
  volume; devices with their own hardware control are identified in settings. The
  separate 40% wake cap also applies if it remains enabled.
- A speaker icon in the menu bar only while sound is muted; click it to unmute.
- The play/pause key no longer opens Music; opening Music yourself still works.

**Downloads**
- File extensions lowercased as downloads land (`IMG_0001.JPG` → `IMG_0001.jpg`).
- Calendar invites (`.ics`) open in Fantastical with their alarms removed, then go to
  the Trash.
- When a disk image you downloaded mounts with a single app inside, Tweaks offers to
  copy it to Applications (the old copy goes to the Trash), eject the image, trash the
  `.dmg` and open the app.
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
  are stripped from links as you copy them. Only a clipboard holding a single http(s)
  link is touched, and password-manager items never are.

**Sleep**
- External drives are ejected as the Mac sleeps; if one refuses, you're told after wake.
- **Eject Idle External Drives** is also available on demand, with an optional
  configurable shortcut. It checks mounted sibling volumes on each physical drive,
  reports blocking processes, and uses normal eject without force. Running render
  engines, unknown drive mappings, and unreadable open-file checks stop eject work.
- The Mac stays awake (the display can still sleep) while After Effects, aerender,
  Media Encoder or Premiere is busy, until two minutes after the work stops.

**Network**
- Network shares are unmounted as the Mac sleeps and remounted after wake once the
  server answers, so waking on another network doesn't stall.
- Work shares (the NAS share to start) are mounted whenever their server is reachable,
  on the office network or over VPN, with the keychain password.

**Keep Awake** (replaces caffeinate)
- Shortcuts are changeable in the Tweaks window (Keep Awake, the Keep Awake panel,
  Screen off, Clear notifications). Turning Keep Awake off releases the sleep
  assertion, so the Mac can sleep again. By default, tap Hyper+/ (⌃⌥⇧⌘/) to keep the Mac awake for 12 hours; tap again to stop, or, in
  the last five minutes, to add an hour.
- Hold Hyper+/ (or click the menu bar cup) for the Keep Awake panel, centered on the
  screen you're on: Recent choices; 1–12 hours (number keys); until it's done (render
  finishes, downloads finish, upload finishes, NAS copy finishes); until a time; until
  an app quits; indefinitely (I); screen off with the Mac awake (Z); display on (D); only while plugged in (P); stop (S).
  Arrow keys move, Return starts, Esc closes.
- "Until it's done" waits for the job to look finished for a quiet period (3 min for
  renders, 2 for uploads, 1 for downloads and NAS copies) so a pause between files
  doesn't end it early.
- A pill appears near the bottom of the screen when it starts or stops, and five
  minutes before a timed session ends. The menu bar cup shows time left (optional).
- Only while plugged in pauses the hold on battery and resumes it on power; any
  session stops at 15% battery when unplugged.
- Links for scripts: `tweaks://awake?minutes=60`,
  `tweaks://awake?hours=2`, `tweaks://awake?until=18:30`,
  `tweaks://awake?app=com.adobe.ame.application.26`,
  `tweaks://awake?done=render|downloads|upload|copy`, add `&display=1` or `&power=1`,
  and `tweaks://awake/stop`, `/toggle`, `/menu` or `/screenoff`.

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

The new automatic window-layout, device-volume, and duplicate-review features are
off by default. The new save/restore/eject shortcuts start unassigned; choose their
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
