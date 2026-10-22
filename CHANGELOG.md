# Changelog

## 0.1.6 — 2026-10-22

- Show live feature status and a compact Activity overview, including network
  reconnects, pending recovery, permissions, shortcuts, volume and render holds.
- Add Keep Awake durations, a chosen end time and a chosen running app to Settings
  and the menu-bar panel, preserving existing shortcut behavior and defaults.
- Add 15/30/60-minute and chosen-time automation pauses, plus an optional unassigned
  pause/resume shortcut. Saved switches and existing assignments are unchanged.
- Guard late network status callbacks, retain chosen-app launch identity, and
  update visible countdowns independently of the menu-bar countdown preference.

See [verification and release status](docs/status-controls-2026-10-22.md).

## 0.1.5 — 2026-10-22

- Rebuild Settings with native sidebar navigation, grouped controls, system
  appearance and a resizable window. Give Audio, Copied Links, Shortcuts and
  Activity dedicated pages while preserving every existing control and preference.
- Add standard Settings, Edit and Window menus, including ⌘, to open Settings,
  ⌘W to close it and the explicit ⌘Q Quit command.
- Cancel shortcut recording when switching panes, changing windows or closing
  Settings so hidden controls cannot capture later keystrokes.

See [validation and release status](docs/native-settings-2026-10-22.md).

## 0.1.4 — 2026-10-22

- Consolidate wake and per-device volume controls, with a configurable default
  wake maximum and existing switches and device rules preserved.
- Pause automatic Downloads, disk-image offers and link cleaning for 30 minutes
  without changing saved feature choices; retain the deadline across relaunch.
- Show the latest 100 file, link, volume and pause actions in session-only history.
- Clean copied links immediately, restore the original while clipboard ownership
  is unchanged, and exclude selected sites. The optional shortcut is unassigned.

See [validation and release status](docs/audio-actions-2026-10-22.md).

## 0.1.1 — 2026-10-17

- Repair settings construction and page layout, preserving usable share, app and audio controls.
- Preserve configured shares separately from enablement and retain unresolved sleep restores through cancellation, late unmounts and restarts.
- Restore Caps Lock delay per keyboard; detect shortcut conflicts by physical keys and show registration errors.
- Restrict DMG handling to Downloads, retain replaced-app recovery copies, and keep disk images when eject fails.
- Support channel-only audio controls without raising quieter channels.
- Make Option-green explicitly enter/exit supported macOS full screen and retry ZIPs while Archive Utility is busy.
- Explain Keep Awake activity estimates, clipboard timing and busy-drive sleep-eject limits.

Build 3 adds the installed-layout repair and is signed, notarized and installed locally.
See [verification and acceptance boundaries](docs/repair-2026-10-17.md).
