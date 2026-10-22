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

The first signed candidate passed notarization, stapling, strict signature
verification and Gatekeeper assessment. Installed checks confirmed native sidebar
selection, grouped controls, standard text editing, all nine pages, shortcut
recording cancellation on navigation, and the Settings keyboard shortcut. Closing
Settings retained the same background process. Away mode was restored and verified
in the UI and with both power assertions. Accessibility remained trusted.

The complete live preference export after installation matched the pre-work
snapshot exactly. Installed review found and corrected one stale Activity label
that referred to controls "below" after they moved to other pages. The final
candidate is being revalidated and packaged with that wording correction.

Twelve geometry warnings during native capture were symbolized against the live
process. Every stack contained AppKit's `NSThemeFrame._positionSharingIndicator`
and window-sharing indicator code; no app constraint failure was recorded. macOS
also logged CoreAudio device/factory messages and a denied WindowServer task-port
lookup. These do not establish hardware audio or unrelated network acceptance.

The installed app, preferences and unrelated file hashes were backed up privately
outside the repository. No production files, output volume, shares, authentication
or feature switches are changed by the UI fixture checks.
