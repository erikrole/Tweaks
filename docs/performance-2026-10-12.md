# Tweaks performance follow-up — 2026-10-12

This records the second optimization pass. The subsequent
[file-work profiling pass](file-work-profile-2026-10-12.md) moves Downloads scanning
off the main actor and adds responsiveness measurements; its report describes the
current working tree.

Three additional optimizations substantially reduce recurring background work.
This compares a fresh baseline containing the earlier fixes against the current
local working tree. Both are based on Git HEAD
`8f31d1a5ca1be1b2161e86fdf117085221e240fd`. No new commit, push, installation,
signing, notarization, or deployment was performed.

## Results

Release builds on this arm64 Mac, Xcode 27.0, macOS 27.0.1. Each measurement follows
five untimed warm-ups and uses thirty measured iterations. Times below are median
wall latency; CPU reduction compares mean process CPU time for the same operation.

| Operation | Before | After | Speedup | CPU time reduction |
| --- | ---: | ---: | ---: | ---: |
| Downloads completion check, 10,000 files | 63.550 ms | 4.370 ms | 14.5× | 93.3% |
| Watcher scan, 10,000 existing downloads | 33.381 ms | 3.604 ms | 9.3× | 89.3% |
| Render activity poll | 5.547 ms | 1.352 ms | 4.1× | 75.2% |
| 1,000 link cleanups (unchanged control) | 4.365 ms | 4.458 ms | ~1× | ~unchanged |

The 95th-percentile latency also improved: completion checks 71.500 → 4.512 ms;
watcher scans 35.492 → 3.769 ms; render polls 6.033 → 1.577 ms. Corresponding mean
CPU times were 64.804 → 4.353 ms, 33.698 → 3.614 ms, and 5.597 → 1.390 ms.

A separate earlier run of the same final production code measured medians of
5.212 ms, 3.712 ms, and 1.585 ms respectively. Both runs support the improvement;
the table uses the final complete Release test run. The unchanged link-cleaning
control differed by about 2%, illustrating ordinary timing variation.

## What changed

- **Downloads completion:** inspect filename extensions directly, avoiding 10,000
  URL constructions. In-progress suffix matching remains
  case-insensitive and covers the same browser suffixes.
- **Downloads scans:** use a POSIX name-only directory snapshot, then fetch size,
  modification time, and visibility/type only for new finished filenames. Existing
  downloads no longer pay URL/resource prefetch costs on every directory event.
  A failed listing preserves watcher history instead of treating the folder as
  empty. Existing file settling and open-file checks remain in place.
- **Render polling:** combine CPU sampling and idle-engine detection into one
  process scan. Reuse the executable-path buffer, reject unrelated paths before
  allocating Swift strings, and request CPU usage only for relevant executables.
  Waiting/unreadable render engines still count as active. Process start time and
  path prevent a reused PID from producing an artificial CPU spike.

The scan still executes on the main actor; this pass reduces its measured cost.
It does not introduce a stale process cache, change the 15-second render polling
interval, or shorten download settling periods.

## Verification

- **59 app tests passed, zero failures and zero skips**, in both Debug and Release.
- The live-share test passed in both runs: current share reachable, mounting an
  already-mounted share succeeds as a no-op, invalid server is unreachable. This
  does not establish actual sleep/wake disconnection or remount behavior.
- New regressions cover CPU aggregation, idle/unreadable engines, process exit,
  PID reuse, counter rollback, zero elapsed time, and live enumeration of a temporary
  waiting process named `aerender` (a copy of `/bin/sleep`, removed after the test).
- Downloads tests cover Unicode filenames, filename-vs-URL suffix parity, hidden
  files by name and filesystem flag, directories/packages, file growth, and retaining
  existing-file history after a failed directory read. Earlier collision, hardlink,
  and restart regressions remain green.
- Independent read-only review found no blocking regressions in renderer filtering
  or the directory snapshot implementation.
- `git diff --check` and `bash -n scripts/benchmark.sh` passed. The remaining Xcode
  warning is the informational App Intents extraction message. No compiler warnings
  were introduced by these changes.

The first live-enumeration test assertion compared `/var/...` with libproc's
`/private/var/...`. Both URLs now resolve before comparison; the production reader
already found the fixture. The final suites include the corrected assertion.

## Reproduce

```sh
./scripts/benchmark.sh

xcodebuild -project Tweaks.xcodeproj -scheme Tweaks -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/validation/DerivedData \
  CODE_SIGNING_ALLOWED=NO test

xcodebuild -project Tweaks.xcodeproj -scheme Tweaks -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/validation/DerivedData \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES test
```

Local evidence is ignored by Git under `.build/performance-pass2/`: `baseline.log`,
`release.log`, `debug.log`, `results.json`, and the source snapshot used for the
fresh baseline. The benchmark script writes its latest logs to `.build/validation/`.

## Measurement scope

Downloads fixtures are 10,000 empty files on local storage. Creation, deletion,
and watcher startup are outside the timed scan. This exercises large existing
directories, not extraction, large file writes, or hundreds of new arrivals.
Render polling uses the real process list, whose membership and scheduling can
vary. CPU measurements cover the test process during each operation.

These results measure component work. Whole-app idle CPU, wakeups, memory, battery
life, installed-app responsiveness, and live Finder extension behavior still need
separate profiling. The app was exercised through its test host, with normal
background-tweak startup suppressed.
