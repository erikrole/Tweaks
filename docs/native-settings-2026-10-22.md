# Native Settings — 2026-10-22

Tweaks 0.1.5 build 8 replaces the fixed paper palette and segmented navigation
with an AppKit source-list sidebar, semantic system colors and grouped controls.
The nine pages are General, Audio, Files & Finder, Copied Links, Keep Awake,
Windows, Network, Shortcuts and Activity. The window resizes from 760 × 540 to
1100 × 1000 points. It follows system appearance without changing macOS preferences.

All 24 feature controls, eight shortcut recorders and existing manual actions
remain wired to the same models. No feature keys or defaults are migrated.
Shortcut recording stops when navigating, losing window focus or closing Settings.
Standard responder-chain menus provide text editing, Settings (⌘,), Close (⌘W),
and explicit Quit (⌘Q). Closing the window keeps the background app running;
Quit still uses the guarded Wi-Fi recovery and shutdown path.

## Verification

- Geometry regressions cover every page in Aqua and Dark Aqua, at minimum and
  expanded window sizes, before and after showing the window.
- A separate preference regression checks every tweak and shortcut remains
  represented, its displayed state matches the saved value, and construction and
  navigation leave the isolated preference domain unchanged.
- Independent read-only reviews found no lost controls, default changes,
  lifecycle blockers or native-menu shutdown issues.
- FinderUtilitiesKit passed all 19 tests. The live preference export after
  implementation and initial tests matched the pre-work snapshot exactly.

- Debug and Release each discovered 173 tests: 171 passed, two expected profile
  skips, zero failures. Release used `ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES`.
- XcodeGen generation, the Debug build and `git diff --check` passed.

- All seven Release benchmarks passed. App median/p95 latency was 4.51/5.13 ms
  for render polling, 4.65/5.03 ms for a 10,000-item completion check,
  3.86/4.75 ms for an existing 10,000-item scan, and 4.46/4.53 ms for 1,000 link
  cleanups. Compilation and other benchmarks did not overlap the timed runs.

## Installed release

[Tweaks 0.1.5](https://github.com/erikrole/Tweaks/releases/tag/v0.1.5) is published,
Developer ID-signed, notarized, stapled and installed at `/Applications/Tweaks.app`.
The app and tag contain source revision
`030ac9ac025119d24eee20f201543693b093baac`. Strict signature verification (including
the Finder extension), Gatekeeper assessment and stapled-ticket validation passed.
Apple accepted notarization submission `c490c339-8bfd-4999-9987-02b95cd874c0`.

Installed checks confirmed native sidebar selection, grouped controls, standard
text editing, all nine pages, shortcut recording cancellation on navigation, and
the Settings keyboard shortcut. Closing Settings retained the same background
process; the native Quit command completed graceful shutdown. Away mode was
restored and verified in the UI and with both power assertions. Accessibility
remained trusted. The final installed Activity page displays the corrected label,
"Automatic actions follow your saved settings."

The complete live preference export after final installation matched the pre-work
snapshot exactly: zero changed keys. Both unrelated local handoff files also
retained their original SHA-256 hashes. Private exports and bundles stay outside
version control.

The published ZIP and checksum asset sizes and SHA-256 digests match the local
artifacts. The app ZIP digest is
`4710f296f7b006e8b1f6d6db0342b4a0439bd3de24ed240acd8b6d6437d19e38`.

Each installed capture session logged twelve geometry warnings, symbolized
against its live process. Every stack contained AppKit's
`NSThemeFrame._positionSharingIndicator`
and window-sharing indicator code; no app constraint failure was recorded. macOS
also logged CoreAudio device/factory messages and a denied WindowServer task-port
lookup. These do not establish hardware audio or unrelated network acceptance.

The installed app, preferences and unrelated file hashes were backed up privately
outside the repository. No production files, output volume, shares, authentication
or feature switches are changed by the UI fixture checks.
