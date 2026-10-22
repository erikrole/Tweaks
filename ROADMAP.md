# Tweaks roadmap

## Current state

Version 0.1.7 repairs the confirmed SystemConfiguration context-release crash found
during investigation of the CalDigit TS5 Plus incident. The reported system freeze
and earlier WindowServer display timeouts remain unattributed; physical dock
acceptance is still open. See [the incident report](docs/dock-hang-2026-10-22.md).
The expanded same-boot timeline includes an LG hotplug out/in sequence, later
WindowServer fence timeout after Tweaks died, and a Bluetooth watchdog restart.
A manual bounded diagnostic collector is prepared and checked against the stable
session. Reconnection remains deferred at the user's instruction; no additional
app behavior or saved preferences changed during the follow-up.

Version 0.1.6 adds live feature status, a compact Activity overview, native Keep
Awake duration/app/time controls, and expanded pause controls with an unassigned
pause/resume shortcut. Existing settings and shortcuts are preserved. See
[status and control verification](docs/status-controls-2026-10-22.md) for checks
and the physical-device acceptance boundaries.

Version 0.1.5 rebuilds Settings with a native source-list sidebar, nine focused
pages, semantic system colors, grouped AppKit controls and a resizable window.
Standard Settings/Edit/Window menus support keyboard navigation and text editing.
Existing preferences and background behavior are retained; shortcut recording
cancels on navigation, focus loss and close. See
[native Settings verification](docs/native-settings-2026-10-22.md).

Version 0.1.4 consolidates audio controls while preserving existing preferences,
adds session-only recent actions and a 30-minute file/link automation pause, and
adds immediate copied-link cleaning with guarded restore and site exclusions.
The new manual cleaning shortcut is unassigned. Release checks and installed
verification are recorded in [the release report](docs/audio-actions-2026-10-22.md).

Version 0.1.3 adds bounded work-share mounts and conservative recovery for the
verified macOS SMB account-lookup hang. Dock, VPN route/DNS and wake events trigger
retries; the normal share path is reused when an empty macOS mount reservation
remains. Active network shares are never force-unmounted for recovery. Debug validation passes 144 discovered tests (two skips, zero failures), the
Finder package passes 19 tests, and Release benchmarks pass. Build 5 is signed,
notarized and installed with existing preferences, Accessibility trust and active
NAS access preserved; see [share recovery](docs/share-recovery-2026-10-20.md).

Version 0.1.2 adds an opt-in Network setting to move a Wi-Fi-bound GlobalProtect
VPN to ready wired Ethernet on USB or Thunderbolt docks. Wi-Fi is restored after
the handoff. Dock detection uses active Ethernet interfaces rather than vendor
names or a fixed port number; the Satechi and CalDigit TS5 Plus follow the same
path. See [implementation and verification](docs/ethernet-handoff-2026-10-20.md).
Build 4 was signed, notarized, and installed locally with existing preferences and
Accessibility trust preserved. Debug app tests (130 discovered, three skips),
19 Finder package tests, and required benchmarks pass. A live Satechi Ethernet
network-service transition moved GlobalProtect automatically and restored Wi-Fi.
The CalDigit at work requires its own physical acceptance check.

Version 0.1.1 repairs all ten confirmed defects from the
[2026-10-17 audit](docs/verification-2026-10-17.md), with permanent regressions for
settings construction, preference migration, physical-key conflicts, per-keyboard
restoration, Downloads scoping/deferral, recoverable app replacement, channel-only
volume controls and share recovery through cancellation/late unmounts. Activity
estimates and delayed clipboard cleanup now have accurate wording. See the
[repair report](docs/repair-2026-10-17.md) for checks and installation evidence.
Build 3 (source `8ff89bc`) was notarized and installed locally. All five settings
pages, Caps Lock HID restoration, preserved preferences and refreshed Accessibility
trust were checked in the installed app. Debug and Release each pass 121 tests
with three expected skips; final Finder-to-host delivery and physical-device
acceptance remain open below.

The 2026-10-12 validation pass adds repeatable Release benchmarks and regression
coverage for Downloads collisions and watcher restarts. Finder menu metadata no
longer blocks the menu, DMG identity inspection runs off the main actor, and the
embedded extension now follows the app's version settings.

The follow-up performance pass reduces render-poll CPU time by 75%, and reduces
CPU time for 10,000-file Downloads watcher/completion checks by 89%/93% on the
measured host. Both full app configurations pass 59 tests, including the existing
live-share check. See [performance results](docs/performance-2026-10-12.md).

See [validation evidence and boundaries](docs/validation-2026-10-12.md).

The file-work pass moves Downloads discovery, settling checks, renames, invite
preparation/cleanup, archive validation/moves, and remaining DMG filesystem calls
off the main actor. Discovery has its own queue; archive extraction is serialized.
File identity checks protect queued work from changed or replaced paths, and
cancelled sessions cannot process later queued files. See
[file-work profiles](docs/file-work-profile-2026-10-12.md) for the measured results.

Five selected additions are implemented locally: saved layouts per monitor setup,
per-device volume limits, Finder image exports, safe-eject action/shortcut, and
duplicate-download review. New automatic behavior is off by default. The additions
preserve originals and require explicit duplicate-trash actions; their file work
stays off the main actor. Debug and Release each pass 90 tests, including 20 new
feature regressions; two opt-in profiles are skipped. The Finder package passes
17 tests. See [feature validation](docs/features-2026-10-12.md) for checks and the
installation boundary.

## Next validation

- Resolve the dock freeze with contemporaneous blocked-thread evidence during a
  separately authorized test. Compare with Tweaks quit, then isolate the LG
  USB-C-to-DisplayPort path. Review main-thread event-tap/AX, dimming/ColorSync and
  audio discovery work as hardening candidates without assigning causality from
  the existing logs. Protected WindowServer capture remains an access boundary.
- On the updated signed app, verify monitor disconnect/reconnect and matching AX
  windows, USB/Bluetooth audio transitions and rounded volume controls, Finder-to-
  host image requests, and safe eject with both idle and busy multi-volume drives.
  These features have fixture coverage; no real window/audio/eject operations have
  been performed for acceptance yet.
- Exercise Finder menus with the signed extension on a real SMB share, a slow or
  disconnected server, and cloud placeholders; verify both responsiveness and the
  Loading-to-cached-result behavior.
- Validate actual NAS disconnect/reconnect and sleep/wake cycles. The existing
  reachability/already-mounted no-op test passed during the performance follow-up.
- With the updated signed build installed, profile idle CPU, wakeups, memory,
  and live Downloads bursts over a longer period. Controlled Release before/after
  file-work profiles and a short sample of the previously installed app are now
  available; they do not establish battery savings or long-running memory behavior.
- Validate actual Accessibility shortcut delivery, wake/sleep behavior, and DMG
  installation in the signed installed app. Accessibility trust is confirmed;
  it does not by itself establish physical-input acceptance.
- Continue the existing Finder plan's host-app Inspector and share robustness work
  after these measurements; this pass does not change entitlements or distribution.
