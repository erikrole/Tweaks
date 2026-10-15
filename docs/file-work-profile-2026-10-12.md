# File-work profiling — 2026-10-12

Downloads and archive work now run off the main thread. A burst of 100 new
finished files no longer blocks the main queue for seconds. Total file-processing
time remains similar; this pass improves responsiveness rather than throughput.

Both builds are local working trees based on commit
`8f31d1a5ca1be1b2161e86fdf117085221e240fd`, including the earlier optimization
passes. Changes are uncommitted. No push, installation, signing, notarization, or
deployment was performed.

## Before and after

Release, arm64, Xcode 27.0, macOS 27.0.1, same host and fixtures. One untimed warm-up
then five measured repetitions. The queue-delay statistic is the median of each
run's maximum scheduling delay; it is not a per-event p95 or production latency.

| Workload | Main-queue delay before | After | Elapsed before | After |
| --- | ---: | ---: | ---: | ---: |
| 100 new finished downloads | 7,717.981 ms | 0.253 ms | 7,719.907 ms | 7,990.903 ms |
| ZIP containing 2,000 files | 3.910 ms | 1.692 ms | 305.500 ms | 403.897 ms |

Main-thread CPU per download batch fell from **7,716.408 to 77.686 ms** (99.0%).
ZIP main-thread CPU fell from **9.020 to 5.449 ms** (39.6%). These CPU measurements
include the responsiveness timer and main-thread Workspace calls; they do not
measure total worker CPU or energy savings. The worst download scheduling delay
across five runs was 8,926.271 ms before and 0.668 ms after.

The download batch took 3.5% longer in the final run. An earlier optimized run
measured 7,669.201 ms with 0.259 ms main-queue delay, so there is no established
throughput improvement. ZIP elapsed time increased about 98 ms (32%); it now
rechecks whether the queued original is open and verifies its identity before
processing/publishing/trashing. That additional safety work runs in the background.

## Changes

- Each Downloads session has a dedicated serial utility queue for initial listing,
  directory events, settling/open-file checks, renames, and invite preparation.
  Startup is asynchronous and `isRunning` becomes true after the initial snapshot;
  files present in that snapshot are left alone. Tests await readiness explicitly.
- Archive extraction, recursive symlink validation, destination lookup, moves,
  original-file trash, and staging cleanup run on a separate serial utility queue.
  ZIP processing is bounded to one operation at a time, without delaying discovery
  behind an extraction backlog.
- Options, cancellation, and readiness use a short lock; directory state stays on
  the session queue. Stop/restart creates fresh state, and cancelled queued work
  does not process files. An already-started move/trash transaction finishes.
- Queued archive and invite operations capture device/inode, size, mtime, and ctime.
  Replacements or resumed writes are preserved. Changed or temporarily reopened
  archives return to the watcher for another settling interval. Original invite
  trash is revalidated after the successful Fantastical callback. Invite copies
  use unique temporary directories, cleaned up in the background.
- Remaining DMG directory checks, plist parsing, moves/replacement, trash, and
  cleanup use the worker. Install confirmation and Workspace interaction stay on
  the main actor. Staging paths are unique per installation.

Atomic no-overwrite extension renames and existing archive destination behavior
remain covered by regression tests. Archive tree validation now fails closed when
it cannot read the tree. Identity checks narrow pathname races but are not a
filesystem transaction spanning extraction and trash.

## Verification

- Full Debug suite: **70 passed, two opt-in profiles skipped, zero failures**.
- Full Release suite with profiles enabled: **72 passed, zero skips/failures**.
- Eleven new concurrency/identity regressions cover cancellation during blocked
  file checks, options changing mid-scan, overlapping scans, pending-start stop,
  archive backlog isolation, serial background work, changed queued archives,
  changes during extraction, file versions, and unreadable archive trees.
- Both full suites passed the current live-share reachability/already-mounted test;
  this does not establish sleep/wake remount behavior.
- Independent read-only concurrency/filesystem review found no blocking regression
  after startup isolation and file-identity fixes. Its final retry suggestion was
  implemented and covered by a deferred-archive callback assertion.
- After making an implicit strong closure capture explicit to remove a compiler
  warning, **16 Release concurrency/watcher tests passed again**. Profiling numbers
  above are from the preceding full Release run with equivalent capture behavior.
  The final build has only the informational App Intents extraction warning.
- `git diff --check` and shell syntax checks for both scripts passed. The unchanged
  FinderUtilitiesKit package was not retested in this pass; its earlier 17-test
  result is recorded in the initial validation report.

## Installed-app observation

A separate five-second, 1 ms stack sample of the already-running
`/Users/role/Applications/Tweaks.app` (PID 2172) showed a physical footprint of
**18.9 MB**, peak **19.2 MB**, with about 98.9% of sampled main-thread stacks waiting
for events. A process-list snapshot reported 0.0% CPU and 88,144 KiB RSS; RSS and
physical footprint are different metrics. The installed binary was not replaced,
so this is a short observation of the prior installed build, not an after result
or an idle-energy/wakeup benchmark.

## Reproduce and limitations

```sh
./scripts/profile-file-work.sh
```

The script runs only the optimized opt-in profiles. A 2 ms main-queue timer is
primed for 20 ms before each operation and drained for 20 ms afterwards to capture
a final synchronous stall. Priming/draining are excluded from elapsed/CPU timing;
the drain is included in delay observation. Sub-millisecond results are an
approximate scheduling floor, and small ZIP delay changes should not be treated
as precise production UI latency. Setup and teardown are untimed. New-download
measurement covers the settled scan/rename of 100 files, not download transfer
speed or the two-second settling interval. ZIP measurement includes extraction,
validation, publication, and original-file trash.

The XCTest host suppresses normal tweak startup. Actual Fantastical handoff,
interactive DMG installation, settings/shortcut responsiveness in the newly signed
installed app, long-running memory, wakeups, and battery savings remain unverified.
No real user downloads were modified by the controlled profiles.

Local ignored evidence: `.build/performance-pass3/{baseline.log,after-first.log,
release.log,debug.log,final-compile.log,installed-idle.sample.txt,results.json}` and
`before/` source snapshots. The baseline profile source snapshot reconstructs the
same harness with synchronous watcher calls; async calls and readiness waits are
the only after-harness changes. New source is in `Tweaks/FileWork.swift`,
`Tweaks/DownloadsTweaks.swift`, and `Tweaks/DMGInstaller.swift`; regression and
profiling fixtures are in `TweaksTests/FileWorkConcurrencyTests.swift` and
`TweaksTests/FileWorkProfileTests.swift`.
