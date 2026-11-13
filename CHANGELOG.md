# Changelog

## Unreleased

- Away no longer dims the screen while another app keeps the display on for video.
  `caffeinate -d` holds and Tweaks' own hold are ignored; Dim now still dims.
- A video that starts while Away is dark brings the screen back. Dim now during
  playback stays dark.
- Away at the lock screen holds only the Mac awake, so the lock screen can sleep
  instead of staying lit all night. Unlocking takes the display hold back.
- Keep Awake sessions survive a Tweaks relaunch (reinstall, update, crash, restart).
  Stopping it, or an end condition, forgets the session; expired ones don't resume.
- Turning off "keep display on" during Away no longer lets the screen sleep and lock.
- A tweaks:// link that launches Tweaks is no longer dropped.

## 0.1.11 — 2026-11-07

- Add Send to Overcast to Finder and Files & Finder. Review downloaded MP3/M4A
  files, sign in once using Overcast's QR or email flow, and upload from Tweaks.
- Send batches sequentially, confirm new uploaded items, and guard quit and
  updates while uploading. Stop/failed batches require review before retrying.
- Preserve Finder action file selections with menu tags across Finder's process
  boundary. The local Run helper installs cleanly signed builds with backups.
- Publish the signed, notarized Apple Silicon update through the existing updater.

See [verification and remaining acceptance checks](docs/overcast-2026-11-07.md).

## 0.1.9 - 2026-10-26

- Install stable updates automatically at launch (Settings > General > Update automatically, on by default). A failed update stops retrying after two tries.

## 0.1.8 - 2026-10-23

- Add signed ZIP self-updates through AppUpdater, preserving save and busy safeguards.
- Publish a notarized Apple Silicon release requiring macOS 27 or later.

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
