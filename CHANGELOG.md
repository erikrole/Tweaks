# Changelog

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
