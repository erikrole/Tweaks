# Audio and automatic actions — 2026-10-22

Tweaks 0.1.4 build 7 combines the existing wake and device volume controls in
General. The wake maximum is configurable; its default stays at 40%. Existing
switches and device-rule data are retained without a migration. Wake and device
limits still combine by taking the lower ceiling; quieter channels are never raised.

Files now offers a 30-minute pause of automatic Downloads actions, disk-image
offers and clipboard cleaning. The saved switches stay unchanged, and a separate
expiry survives restart and sleep. Arrivals during a pause are included in the
resume snapshot and are not processed retrospectively. Transactions already
publishing files finish; canceled DMG sessions cannot revive after resume.

The same page provides Clean Link Now, Restore Original and per-domain exclusions.
Cleaning works manually even when automatic cleaning is disabled or paused. The
optional shortcut is unassigned. Protected/rich clipboard items are not touched;
restoration checks the clipboard ownership generation, including around writes.
Original contents remain in memory only and expire when the clipboard changes.

Recent actions keeps at most 100 entries in memory, newest first. Downloads,
installer outcomes, manual duplicate decisions, image exports, link operations,
volume adjustments and pause changes feed the list. No clipboard contents or
history are written to disk; Clear Recent Actions removes the current list.

## Verification

- XcodeGen generation and Debug build passed.
- Debug and Release each discovered 172 tests: 170 passed, two expected profile
  skips, zero failures. Release uses `ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES`.
- FinderUtilitiesKit passed all 19 tests.
- Required Release benchmarks passed (three package and four app checks). App
  median/p95 timings in milliseconds: render poll 5.573/5.860; 10,000-file download
  completion check 4.902/5.555; existing-directory scan 3.701/3.929; 1,000 link
  cleanups 4.457/4.574. These are host measurements, not a battery-savings claim.
- New regressions cover unchanged legacy preferences/rule bytes, stricter wake
  ceilings, private-pasteboard cleanup/restore and concurrent ownership changes,
  protected clipboard items, domain exclusions, pause persistence/expiry, canceled
  installer generations, paused arrivals, actual rename logging and bounded history.
- Independent read-only review found no remaining blockers after the clipboard
  ownership, canceled-installer and restore-state fixes.
- `git diff --check` passed. The complete live preference export matched its
  pre-work snapshot after implementation and tests; no keys changed.

## Installed release

- Source revision: `371fb6ca2518df071cee208c4f9996d4e6f2cce0`.
- Version 0.1.4 build 7 was Developer ID-signed, accepted by Apple's notary
  service, stapled and installed at `/Applications/Tweaks.app`. Signature
  verification and Gatekeeper's Notarized Developer ID assessment passed.
- The signed app showed the preserved 40% wake maximum, disabled device-limit
  switch, existing device choices and existing shortcut assignments. The new
  cleaning shortcut remains unassigned. No Accessibility waiting banner appeared;
  the installed app reports Accessibility trust.
- The live Files page showed immediate link controls, exclusions, temporary pause
  and recent actions with usable geometry. A pause/resume cycle updated the status
  and history while leaving feature switches unchanged.
- The complete preference export after installation and pause/resume matched the
  pre-work snapshot exactly: zero keys changed. The pause deadline was cleared.
- The pre-existing Away session was resumed and confirmed in the signed app's
  Sleep page and actual power assertions. No user clipboard contents were changed
  for live checks; link cleaning and restoration used private pasteboards in tests.
- The two unrelated `.claude` files retained their original hashes. The previous
  signed app and preference export remain backed up privately outside the repository.

No real share faults, physical device switches, wake-volume changes or user
Downloads fixtures were used by tests. Physical wake/audio transitions remain
separate acceptance work; the new policy and channel behavior have fixture coverage.
