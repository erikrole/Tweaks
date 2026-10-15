# Tweaks validation — 2026-10-12

Local working-tree validation based on commit
`8f31d1a5ca1be1b2161e86fdf117085221e240fd`, using Xcode 27.0 (27A266a),
macOS 27.0.1 (26A434), and the arm64 macOS destination. No commit, push,
installation, signing, notarization, or deployment was performed for this pass.

## Findings and focused fixes

- **Finder menu delay:** the synchronous metadata path waited up to 150 ms locally
  or one second on network/cloud paths. It now starts background work and returns
  the cached state immediately. A cold menu can show Loading until reopened.
- **Downloads overwrite:** a new regression reproduced ordinary `rename`
  replacing an existing destination and deleting its original contents. The fix
  uses atomic `renamex_np(RENAME_EXCL)`. Existing files and hardlinks are preserved;
  unsupported filesystems leave the source alone. Actual APFS case-only renames
  still pass their integration test.
- **Watcher restart:** pending size/mtime candidates survived stop/start and could
  let a replacement file reuse an old settling timestamp. Stop now clears them;
  a deterministic regression verifies a fresh settling interval.
- **DMG responsiveness:** a test emitted a runtime warning about signature
  inspection on the main thread. `AppIdentity.read` is now async and performs its
  blocking bundle/Security reads in a utility task. The final Release run no longer
  emits that warning. No installer confirmation or identity rule changed.
- **Build cleanup:** generated extension version was 1.0 while the app was 0.1.0.
  XcodeGen now supplies both version fields from build settings; built Release
  plists read back as 0.1.0 for both targets. Fixed one Swift isolation warning and
  two deprecated C-string conversion warnings.

## Tests

Baseline: 42 app tests, one live-share skip, zero failures; 16 package tests passed.
The new overwrite regression failed before the fix, confirming the lost source
and replaced destination bytes in a temporary fixture.

Final full app suite: **47 tests, one skipped, zero failures** in both Debug and
Release, including the final async identity adjustment. The live-share test
skipped because no network share was mounted.

Package correctness: **17 Swift Testing tests passed** in both Debug and Release.
Its three opt-in XCTest benchmarks skip during ordinary correctness runs, then
all pass when enabled. Two app benchmarks also pass.

Commands used (logs under `.build/validation/`):

```sh
xcodegen generate
xcodebuild -project Tweaks.xcodeproj -scheme Tweaks -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/validation/DerivedData \
  CODE_SIGNING_ALLOWED=NO test
swift test --package-path Packages/FinderUtilitiesKit
swift test --package-path Packages/FinderUtilitiesKit -c release
xcodebuild -project Tweaks.xcodeproj -scheme Tweaks -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/validation/DerivedData \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES test
./scripts/benchmark.sh
git diff --check
```

The initial sandboxed builds could not write Xcode/Swift caches and were rerun
with required host access. The first Release test build lacked testability;
`ENABLE_TESTABILITY=YES` corrected the test invocation. Neither setup failure is
counted as a passing test. Xcode still reports the informational App Intents
metadata-extraction warning because these targets do not link AppIntents.

## Optimized benchmarks

Means calculated from XCTest's individual samples, in milliseconds. Cold metadata
uses five measured samples; other benchmarks use ten. Both sides use the same
workload and Release optimization. The baseline Finder helper retained the exact
previous prefetch-and-wait behavior before its wait was removed.

| Operation | Before | After |
| --- | ---: | ---: |
| Cold network menu metadata, simulated slow provider | 990.102 ms | 0.011 ms |
| 10,000 cached metadata lookups | 5.542 ms | 5.053 ms |
| Clean and join 10,000 paths | 16.131 ms | 14.541 ms |
| Process CPU sample plus render-process scan | 12.822 ms | 14.197 ms |
| Clean 1,000 tracked links | 8.720 ms | 8.577 ms |

Only the cold-menu improvement reflects an intentional performance change.
The other paths serve as reference measurements: process/link timings vary during
app startup, with relative standard deviations around 46–48% in the final run.
There is no supported claim of improvement or regression for those paths. Future
comparisons should repeat on an otherwise idle Mac with the same process workload.

These are operation benchmarks, not end-to-end Finder timing or whole-app CPU,
memory, wakeup, or battery measurements. The slow provider performs no network I/O.
Live SMB recovery, cloud placeholder behavior, Accessibility, real sleep/wake,
and installed-app/extension behavior remain unverified in this pass.
