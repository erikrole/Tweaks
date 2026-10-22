# Live status and session controls — 2026-10-22

Tweaks 0.1.6 build 9 adds execution status beside each existing feature, with a
compact Activity overview. Ready, Working, Active, Waiting, Paused, Blocked and Off
are distinct from the saved enable switches. Activity initially shows active and
attention-needed states; Show all features includes ready and disabled features.
Manual Keep Awake sessions and render holds are shown independently.

Downloads readiness/failure, work-share reconnects, pending sleep restores,
Ethernet VPN handoffs, volume enforcement, shortcut registration and window-layout
results feed status without starting work from Settings. Network callbacks retain
session identity across cancellation/restarts. Pending share/Wi-Fi recovery stays
visible when its switch is off. Repeated checks and identical failures do not flood
session-only Recent Actions. Audio failures remain blocked until a readback verifies
recovery; quiet channels are never raised.

Keep Awake sessions can run until stopped, for 30 minutes or 1/2/4 hours, until a
chosen date/time, or until a selected running app quits. Both Settings and the
menu-bar panel expose those choices. Process launch identity protects chosen-app
sessions from PID reuse. Past/invalid dates and apps that have exited are rejected
without replacing a running session. Visible countdowns update even when the user
has hidden the menu-bar countdown. Existing tap/hold and Dim Now shortcuts retain
their behavior. Duration choices do not change saved Keep Awake defaults.

Activity offers 15/30/60-minute pauses or a chosen resume time, with Change Pause
and Resume Now. The optional pause/resume shortcut starts unassigned and toggles a
30-minute pause. Saved feature switches are unchanged; arrivals during a pause
remain untouched after resuming. The deadline keeps its existing preference key.

## Verification

Debug and Release each discovered 187 tests: 185 passed, two expected profile skips,
zero failures. Release used `ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES`.
FinderUtilitiesKit passed all 19 tests. The complete live preference export after
implementation/tests matched the original snapshot exactly, including all existing
shortcut data. Independent read-only review found no remaining release blockers.
All seven required Release benchmarks passed. App median/p95 wall latency was
4.41/5.02 ms for render polling, 4.86/5.49 ms for a 10,000-item completion check,
5.29/6.03 ms for an existing 10,000-item scan, and 8.35/8.55 ms for 1,000 link
cleanups. Compilation and other timed work did not overlap those runs. These are
host-specific measurements, not battery-life claims.
Signed installed verification is in progress.

The installed app,
complete preference domain, source revision and unrelated local file hashes were
backed up privately before editing. No preferences or shortcut migrations are added.

Independent review identified cancellation/status races, process identity loss,
hidden-countdown refresh, dynamic document sizing, and typed failure/recovery
states. Fixes include deterministic regressions and the existing all-page Aqua/Dark
Aqua geometry checks at minimum and expanded sizes, including date/app controls.

## Live acceptance boundaries

The current hardware inventory has the built-in display, AirPods and built-in
speakers, and no external physical disk. The other ejectable disk is a virtual disk
image. Adobe processes are active. Physical monitor reconnection and idle/busy
multi-volume drive eject therefore require the corresponding hardware. NAS
sleep/disconnect testing must account for active creative work before interruption.
These remain distinct from injected regression coverage and signed-app UI checks.
