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

**Windows and notifications** (need Accessibility permission)
- ⌃⌥⌘N closes every notification on screen.
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
```

## License

Tweaks is released under the MIT License.
