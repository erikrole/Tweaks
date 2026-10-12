# Tweaks

Tweaks is a small background app for macOS that does a handful of quality-of-life
things, chosen from the Supercharge features actually in use on one Mac. It has no
menu bar icon; open it again from Finder, Spotlight or Raycast to see its settings,
where every tweak has its own switch.

**Keyboard and sound**
- Caps Lock with no delay: a normal tap toggles it instantly (`hidutil`
  `CapsLockDelayOverride`, reapplied on wake and every five minutes).
- Volume capped at 40% after waking.
- A speaker icon in the menu bar only while sound is muted; click it to unmute.
- The play/pause key no longer opens Music; opening Music yourself still works.

**Downloads**
- File extensions lowercased as downloads land (`IMG_0001.JPG` → `IMG_0001.jpg`).
- Calendar invites (`.ics`) open in Fantastical with their alarms removed, then go to
  the Trash.
- When a disk image you downloaded mounts with a single app inside, Tweaks offers to
  copy it to Applications (the old copy goes to the Trash), eject the image, trash the
  `.dmg` and open the app.

**More downloads and clipboard**
- New `.zip` downloads are extracted next to the archive (one item comes out as is,
  several go in a folder named after the zip), then the zip goes to the Trash.
- Tracking parameters (`utm_…`, `fbclid`, YouTube and Spotify `si=`, X `s=`/`t=`, …)
  are stripped from links as you copy them. Only a clipboard holding a single http(s)
  link is touched, and password-manager items never are.

**Sleep**
- External drives are ejected as the Mac sleeps; if one refuses, you're told after wake.
- The Mac stays awake (the display can still sleep) while After Effects, aerender,
  Media Encoder or Premiere is busy, until two minutes after the work stops.

**Network**
- Network shares are unmounted as the Mac sleeps and remounted after wake once the
  server answers, so waking on another network doesn't stall.
- Work shares (the NAS share to start) are mounted whenever their server is reachable,
  on the office network or over VPN, with the keychain password.

**Keep Awake** (replaces caffeinate)
- Tap Hyper+/ (⌃⌥⇧⌘/) to keep the Mac awake for 12 hours; tap again to stop, or, in
  the last five minutes, to add an hour.
- Hold Hyper+/ (or click the menu bar cup) for the Keep Awake panel, centered on the
  screen you're on: Recent choices; 1–12 hours (number keys); until it's done (render
  finishes, downloads finish, upload finishes, NAS copy finishes); until a time; until
  an app quits; indefinitely (I); display on (D); only while plugged in (P); stop (S).
  Arrow keys move, Return starts, Esc closes.
- "Until it's done" waits for the job to look finished for a quiet period (3 min for
  renders, 2 for uploads, 1 for downloads and NAS copies) so a pause between files
  doesn't end it early.
- A pill appears near the bottom of the screen when it starts or stops, and five
  minutes before a timed session ends. The menu bar cup shows time left (optional).
- Only while plugged in pauses the hold on battery and resumes it on power; any
  session stops at 15% battery when unplugged.
- Links for Raycast Quicklinks or scripts: `tweaks://awake?minutes=60`,
  `tweaks://awake?hours=2`, `tweaks://awake?until=18:30`,
  `tweaks://awake?app=com.adobe.ame.application.26`,
  `tweaks://awake?done=render|downloads|upload|copy`, add `&display=1` or `&power=1`,
  and `tweaks://awake/stop`, `/toggle` or `/menu`.

**Finder** (formerly Finder Utilities)
- Copy Path with NAS, Box and Google Drive roots shortened
  (`/Volumes/users/shares/Media/Foo.mov` → `Media/Foo.mov`), Copy Original Path, and
  Inspect Media (frame size, frame rate, duration, codec, alpha, color, audio, DPI).
  Turn it on in System Settings › Login Items & Extensions › Finder Extensions. The
  path logic lives in `Packages/FinderUtilitiesKit`; see
  `docs/finder-utilities-plan.md`.

**Windows and notifications** (need Accessibility permission)
- Hyper+N (⌃⌥⇧⌘N) closes every notification on screen.
- "Shortcut is running" banners from Shortcuts close themselves.
- The green window button fills the screen without macOS full screen; click it again
  to restore the window. Hold ⌥ for normal full screen.
- Apps you pick (Preview and TextEdit to start) quit when their last window closes.

Nothing runs as root and there is no helper. The Downloads tweaks only touch files
that arrive after Tweaks starts.

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

## License

Tweaks is released under the MIT License.
