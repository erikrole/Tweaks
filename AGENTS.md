# Tweaks development

Native macOS 14+ Swift 6 app with an embedded Finder Sync extension. Follow the
parent workspace instructions. `project.yml` is the XcodeGen source of truth;
run `xcodegen generate` after changing project settings or file membership.

## Checks

```sh
xcodegen generate
xcodebuild -project Tweaks.xcodeproj -scheme Tweaks -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
swift test --package-path Packages/FinderUtilitiesKit
./scripts/benchmark.sh
```

For full Release tests, add `-configuration Release ENABLE_TESTABILITY=YES
ONLY_ACTIVE_ARCH=YES` to the Xcode test command (replacing Debug). Keep testability
as a command-line override, not a shipping build setting. Xcode and Swift need
access to their normal caches/test services; a sandbox denial is not a test result.

## Boundaries

- `AppDelegate` suppresses background-tweak startup in the XCTest host. Do not
  launch the normal app just to run a unit test: it can change keyboard behavior,
  clipboard contents, downloads, power assertions, and mounted shares.
- Download regressions use temporary fixtures. Renames must use an atomic
  no-overwrite operation; an existence check plus ordinary rename is unsafe.
- Downloads startup is asynchronous: `start()` is idempotent while pending,
  `isRunning` becomes true after the initial snapshot, and `waitUntilReady()` gives
  tests a barrier before creating new arrivals. `scan(now:)` is async and takes an
  explicit time for deterministic settling tests.
- Each download session owns its serial utility queue. Directory state stays on
  that queue; settings/cancellation/readiness use the session lock. Do not perform
  filesystem work while holding the lock or on the main actor. Archive and DMG file
  transactions use `FileWork.queue`, separately from discovery, so ZIP backlog
  cannot postpone watcher startup. Archive extraction is serialized.
- Capture `FileVersion` when queuing archive or invite work. Revalidate before
  processing/publishing/trashing; changed or reopened archives must settle again.
  Cancellation prevents queued work; an already-started move/trash transaction
  finishes. Never overwrite a distinct destination.
- `DownloadDirectory.names(in:)` reads names without URL/resource prefetch. A failed
  listing must preserve the watcher's seen set. Keep hidden-file, directory, Unicode,
  and settling regressions green when changing this path.
- Render polling uses one `CPUSampler` pass. Idle/unreadable render engines count as
  present even without CPU data. Its raw-path prefilter must remain a superset of
  every renderer matcher; PID reuse must not produce synthetic CPU spikes.
- Finder's synchronous menu path must not wait on metadata or perform file I/O.
  `MetadataService.menuState(for:)` starts background work and returns cached state.
- Bundle/signature reads stay off the main actor through async `AppIdentity.read`.
  App replacement retains a recovery backup until Trash succeeds. A failed image
  eject must retain the downloaded image. Use disposable bundles for these tests.
- New automatic features are opt-in (`Tweak.defaultEnabled`); new global shortcuts
  default to unassigned. Do not enable them in a user's preferences while testing.
- Window layout AX calls run on a dedicated serial queue, with bounded messaging
  timeouts and cancellation. Match the exact display arrangement and a unique
  app/window fingerprint; persist no raw window titles or document paths.
- Share enablement uses `autoConnectShares`; configured URLs use
  `autoConnectShareURLs`. Preserve legacy migration and disabled intent. Pending
  sleep restores persist separately; cancellation must never discard them. Keep
  unmounts in flight gated until their callbacks finish, including after wake.
- Share mounts use the cancellable NetFS async API and one global mount/reset
  lease. Timeout/cancel must finish without a NetFS callback. Observe route, DNS,
  link and wake changes; do not stack attempts while VPN routes settle. Reset only
  a same-user, exact-path/start-identity NetAuthSysAgent with the known SMB account
  lookup hang in two separated samples, no mounted network shares, and no sleep or
  unmount work. Unknown mount-table state fails closed. Reuse only empty owned
  local macOS mount reservations; never delete mount folders or force unmount.
  Recovery tests inject their backend and must never reset a real system helper.
- SystemConfiguration context retain/release callbacks can run on its internal
  notification queue, even when change notifications target main. Use top-level
  nonisolated C callbacks with a Sendable context box, weak actor ownership, and
  generation checks before delivering changes. Exercise the real callback pointers
  on a background queue without subscribing or changing the network in regressions.
- Caps Lock originals are per HID service and boot session. Consume an original
  only after a successful restore. Tests inject writes; do not change real HID
  settings in ordinary tests.
- Audio limits use device UIDs and property listeners. Bound adjustment attempts
  and suppress repeated above-limit readbacks: hardware may round scalar writes.
  Compare the entire channel snapshot for suppression, and never raise a quieter
  channel while capping another.
- Audio consolidation retains the `wakeVolumeLimit`, `deviceVolumeLimits` and
  `deviceVolumeRules` preferences byte-for-byte. `audioWakeMaximum` defaults to
  40% without writing a migration; an enabled device cap can only lower it further.
- Temporary pause overrides Downloads, DMG offers and automatic link cleaning,
  never their saved switches. Persist only its expiry; leave arrivals during the
  pause untouched on resume. Cancel pending work, finish started file transactions,
  and invalidate DMG session identities across stop/restart.
- Recent actions are bounded to 100 session-only entries; never persist the log or
  original links. Manual link cleaning shares automatic protected-item guards and
  site exclusions. Clipboard restore requires the original ownership count before
  and after writing, and must not replace a newer copy. Tests use private pasteboards.
- Image requests from Finder only open a review panel in the host. Export uses
  ImageIO off-main, a private staging directory, and atomic no-overwrite publishing.
  Keep originals intact, reject multi-frame input, and test metadata/orientation.
  The Finder extension keeps its existing read-only sandbox entitlement.
- Safe eject resolves APFS containers to physical disks before grouping all mounted
  siblings. Unknown/multi-store mappings fail closed. Revalidate identities and
  render activity after querying open files; never use force. Tests inject the
  backend and must not eject a real disk.
- Duplicate review hashes in streaming chunks on the download session queue, with
  cancellation. Revalidate identities and all bytes before explicit trash; skip
  resource forks and hard links. A duplicate bypasses automatic ZIP/invite actions.
- Keep generated benchmarks, DerivedData, xcresults, private data, and credentials
  out of commits. `.build/validation/` is ignored. Share aggregate measurements in
  docs with their configuration and limitations.
- Settings uses an AppKit source-list sidebar and nine grouped pages. Keep system
  colors and inherited appearance; do not reintroduce a fixed palette or force Aqua.
  Document columns use Auto Layout inside a manually sized scroll document. Measure
  against the detail pane, not the whole window, and account for group insets. Keep
  every page's light/dark, minimum/expanded size geometry checks green and check
  installed runtime logs for app constraint/geometry faults.
  Symbolize unfamiliar AppKit warnings before assigning them to app layout; the
  macOS window-sharing indicator can emit negative-size warnings during capture.
- Settings navigation and construction must not write feature preferences. Preserve
  all tweak controls, shortcuts and manual actions. Cancel shortcut recording when
  switching panes, losing the key window or closing Settings. Closing the window
  leaves background work running; the native Quit command follows guarded shutdown.
- Feature status is execution state, not a saved enable switch. Guard asynchronous
  status delivery with the originating generation, and deduplicate per generation.
  Keep pending recovery visible while disabled; never call an unverified/failed
  audio write Ready. History excludes repeated progress and identical failures.
- Keep Awake duration/mode and pause pickers are session-only until explicitly
  started. Reject invalid deadlines and stale app launch identities without replacing
  a session. Visible countdowns work with the menu-bar countdown disabled. Dynamic
  date/app controls must request scroll-document measurement. New pause shortcuts
  start unassigned and must not rewrite existing shortcut data.
- After tests and installation, verify Accessibility against the actual signed
  app. An allowed TCC record for a development identity does not establish trust
  for a Developer ID build with the same bundle ID. Preserve the permission scope;
  any required local authentication must be completed by the user.
- Ethernet VPN handoffs stay on their utility queue. Require a live wired router,
  an Ethernet-bound gateway probe, and GlobalProtect ownership before cycling
  Wi-Fi. Preserve user-disabled Wi-Fi, save recovery state before power changes,
  restore on cancellation/quit/restart, and never change VPN credentials or MFA.
  Tests must inject policy inputs and never toggle a real network interface.
- Open-file checks go through `OpenFiles`, which scans per process by device and
  inode, skips Virtualization.framework VM processes and is bounded; never call
  `proc_listpidspath` or `lsof` directly (both hung on a VM process). Timeouts and
  incomplete scans must fail safe as "in use".
- Live NAS, Accessibility, power, and real Finder behavior require separate live
  evidence; passing isolated tests does not establish those behaviors.
- `scripts/capture-dock-diagnostics.py` is a manual read-only collector. Run as the
  logged-in user, never root; keep raw logs/preferences in private ignored output.
  Preserve bounded command/recording deadlines, signal-safe cancellation, owned
  child cleanup, PID-specific sample names and explicit partial manifests. A
  protected WindowServer sample failure is missing evidence, not a passing check.
  The same boundary applies to directory/VPN daemons. USB inventory includes private
  device identifiers; keep it local. USB network-class interfaces do not by
  themselves establish Internet tethering. A log-show query may exceed its requested
  end; locally enforce boot/time bounds and mark interrupted output incomplete.
  The CalDigit physical reconnect remains deferred until explicitly authorized.

App benchmarks perform five warm-ups and thirty measured iterations, printing
`PERF_RESULT` JSON with median/p95 wall latency and mean process CPU time. Compare
Release with Release on the same host; keep compilation and other benchmarks from
overlapping the timed run. Large Downloads benchmarks create and remove 10,000-file
temporary fixtures; setup/teardown is outside the timed interval.

`./scripts/profile-file-work.sh` runs the opt-in Release responsiveness profiles:
one warm-up plus five measured repetitions of 100 new downloads and a 2,000-file
ZIP. A 2 ms main-queue timer measures scheduling delay, alongside elapsed time and
main-thread CPU. Its setup/drain are outside elapsed/CPU timing; delay includes the
20 ms drain needed to catch a final synchronous stall. These profiles are skipped
in ordinary test runs. Do not overlap compilation or other benchmarks with them.
