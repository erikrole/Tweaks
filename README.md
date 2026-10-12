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

**Windows and notifications** (need Accessibility permission)
- ⌃⌥⌘N closes every notification on screen.
- "Shortcut is running" banners from Shortcuts close themselves.
- The green window button fills the screen without macOS full screen; click it again
  to restore the window. Hold ⌥ for normal full screen.

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
