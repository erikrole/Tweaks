---
name: verify
description: Prove a Tweaks change works before committing or opening a PR, without applying any tweak to Erik's Mac; use before every commit that touches Tweaks/, TweaksTests/, FinderSync/, MediaReader/, Packages/, project.yml or scripts.
---

# Verify a Tweaks change

Goal: evidence, not a green unit test. Run the cheap checks first, then the real build.
Runs in the checkout on Erik's Mac, never on a work NAS share; all output goes under the
ignored `build/verify/`. Judge every step by its exit code, not by `tail`.

**Never apply a tweak to this Mac to test it.** The normal app changes keyboard, Caps Lock,
audio, display dimming, power assertions, Wi-Fi, mounted shares, the clipboard, Downloads and
disks. Background behavior is checked by the unit tests (the XCTest host skips startup and
tests inject their backends) and by Erik's own live checks. Live NAS, Accessibility, power,
network and real Finder behavior are not proven by anything here; say so in the report.

## 0. Setup (always)

```bash
mkdir -p build/verify
defaults export com.erole.Tweaks - > build/verify/prefs-before.plist   # the only domain the app writes (plus test suites)
ps -axo pid=,comm= | grep -E '/Tweaks$|/TweaksFinderSync$' | tee build/verify/running-before.txt   # usually the installed app: leave it alone
ls ~/Library/Preferences | grep -E '^(NativeSettings|Tweaks[A-Za-z]+)-[0-9A-F-]{36}\.plist$' > build/verify/prefs-files-before.txt
pluginkit -m -A -D -v -i com.erole.Tweaks.FinderSync > build/verify/pluginkit-before.txt   # -A -D: every copy, not just the elected one
```

Never `pkill` Tweaks: its Quit path restores dimming, Wi-Fi and file work. Kill only a PID you started.
List processes by executable (`ps ... comm`), not `pgrep -lf Tweaks`, which also matches your own shell in this checkout.

## 1. Cheap checks (always, ~1 min)

```bash
xcodegen generate > build/verify/xcodegen.log 2>&1; echo "exit $?"; git status --short Tweaks.xcodeproj
xcodebuild -project Tweaks.xcodeproj -scheme Tweaks -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/verify/DerivedData CODE_SIGNING_ALLOWED=NO test > build/verify/test.log 2>&1; echo "exit $?"
grep -E "Executed .* tests|\*\* TEST (SUCCEEDED|FAILED) \*\*|: error:" build/verify/test.log | tail -3
swift test --package-path Packages/FinderUtilitiesKit > build/verify/package-test.log 2>&1; echo "exit $?"
grep -E "Executed .* tests|Test run with|recorded an issue|error:" build/verify/package-test.log | tail -3
```

Want: exit 0 each, the app's last `Executed N tests, with 3 tests skipped and 0 failures`
(205 on 2026-11-17; the skips are the two opt-in `FileWorkProfileTests` and the live share check) and `** TEST SUCCEEDED **`;
the package's `Test run with 19 tests ... passed` plus 5 XCTest (3 benchmark skips). Don't grep
plain `failed`: it matches test names. A sandbox denial from Xcode/Swift caches is not a result.

Only when the diff touches its area (not run in the 2026-11-17 dry run, as noted):

| Diff touches | Also run |
|---|---|
| one area, while iterating | `-only-testing:TweaksTests/<Class>[/<method>]` on the xcodebuild line above |
| Release-only code, `#if DEBUG`, testability | the same line with `-configuration Release ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES` (AGENTS.md; not run: the dry-run diff had no Release-only code) |
| download/ZIP/file-work speed, render polling, `FileWork` | `./scripts/benchmark.sh`, then `./scripts/profile-file-work.sh` (AGENTS.md; slow timed runs that need an otherwise idle Mac; not run: no performance code changed) |

## 2. Build and launch the real app (always, ~30 s)

```bash
./script/build_and_run.sh --build-only > build/verify/release-build.log 2>&1; echo "exit $?"
grep -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*|: error:" build/verify/release-build.log | tail -2
```

`--build-only` is the only safe mode: a clean Release build signed with Developer ID into
`.build/local-run`, plus `codesign --verify --deep --strict`. Never run it with no argument,
`--verify` or `--install-built`: those replace `/Applications/Tweaks.app` and need Erik to quit his copy.

Then launch the Debug build from step 1. `InstanceGuard` lets only `/Applications/Tweaks.app`
run, so this copy must quit by itself before it touches settings or starts any tweak:

```bash
APP="$PWD/build/verify/DerivedData/Build/Products/Debug/Tweaks.app"
[ -d /Applications/Tweaks.app ] || { echo "SKIP launch: no installed app, InstanceGuard would let this copy run"; exit 1; }
"$APP/Contents/MacOS/Tweaks" > build/verify/launch.log 2>&1 & P=$!
for i in $(seq 50); do kill -0 $P 2>/dev/null || break; sleep 0.2; done
if kill -0 $P 2>/dev/null; then echo "FAIL: debug copy still running"; kill $P; else wait $P; echo "exited $?"; fi
ps -axo pid=,comm= | grep -E '/Tweaks$|/TweaksFinderSync$' | diff build/verify/running-before.txt - && echo "installed copy untouched"
defaults export com.erole.Tweaks - | diff build/verify/prefs-before.plist - && echo "prefs unchanged"
```

Want `exited 0` within a second, the same installed PID, and no prefs diff. A debug copy that
stays up is a failure (it would start real tweaks): kill that PID at once and tell Erik.
Skip this launch when the diff touches `TweaksApp.swift` startup, `InstanceGuard` or anything that
runs before it, until you have reread that path and know the guard still runs first.

## 3. Drive the changed flow

Pick what matches the change:

- **Settings UI / layout / copy (~10 s):** real AppKit renders of all nine pages, light and dark,
  from the test host with throwaway defaults and no background tweaks:
  ```bash
  TEST_RUNNER_TWEAKS_SETTINGS_CAPTURE_DIR="$PWD/build/verify/settings" xcodebuild -project Tweaks.xcodeproj -scheme Tweaks \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath build/verify/DerivedData CODE_SIGNING_ALLOWED=NO \
    -only-testing:TweaksTests/VerificationRegressionTests/testSettingsPagesHaveUsableGeometryBeforeAndAfterDisplay test \
    > build/verify/settings.log 2>&1; echo "exit $?"; ls build/verify/settings | wc -l   # want 18
  ```
  The variable must be in the environment with the `TEST_RUNNER_` prefix; as an xcodebuild
  argument it is silently dropped. Files are `NSAppearanceName{Aqua,DarkAqua}-<n>.png` at 960x760,
  n = 0 General, 1 Audio, 2 Files & Finder, 3 Copied Links, 4 Keep Awake, 5 Windows, 6 Network,
  7 Shortcuts, 8 Activity. Open the pages you changed in both schemes and look. Known: in light
  captures the selected sidebar row is a black pill with no visible label (unconfirmed in a live window).
  Status lines show the test host's state ("Accessibility permission needed"), not Erik's.
- **A background tweak, file work, network, audio, power, disks, Finder menu, Overcast, updater:**
  run that area's test class (`-only-testing:TweaksTests/<Class>`) and read its assertions for the
  case you changed. If no test covers it, add one with injected backends (AGENTS.md says how for each
  area). The live behavior is Erik's to check after install; list it under "not verified".
- **Install path / signing / project.yml:** step 2's `--build-only` covers signing; installing is Erik's call.

Look at the output yourself. "It built" is not verification.

## 4. Clean up (always)

```bash
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for b in build/verify/DerivedData/Build/Products/Debug/Tweaks.app{/Contents/PlugIns/TweaksFinderSync.appex,} \
         .build/local-run/Build/Products/Release/Tweaks.app{/Contents/PlugIns/TweaksFinderSync.appex,}; do
  [ -e "$b" ] && $LSR -u "$PWD/$b"; done
$LSR -dump | grep -c "$PWD"                       # want 0; "failed to scan ... -10814 from spotlight" for the appex is noise
pluginkit -m -A -D -v -i com.erole.Tweaks.FinderSync | diff build/verify/pluginkit-before.txt - && echo "Finder extension unchanged"
# Tests leave empty suite-domain plists behind; remove only the ones this run added.
# cfprefsd can write one back seconds after rm, so sweep until a check finds none (up to 30 s).
added() { ls ~/Library/Preferences | grep -E '^(NativeSettings|Tweaks[A-Za-z]+)-[0-9A-F-]{36}\.plist$' | comm -13 build/verify/prefs-files-before.txt -; }
for n in $(seq 10); do added | while read f; do rm -f ~/Library/Preferences/"$f"; done; sleep 3; [ -z "$(added)" ] && break; done
[ -z "$(added)" ] && echo "no test plists left" || echo "WARN: test plists left: $(added | tr '\n' ' ')"
defaults export com.erole.Tweaks - | diff build/verify/prefs-before.plist - && echo "prefs unchanged"
ps -axo pid=,comm= | grep -E '/Tweaks$|/TweaksFinderSync$' | diff build/verify/running-before.txt - && echo "same Tweaks processes as before"
```

If a worktree copy shows up in the pluginkit diff, remove it with `pluginkit -r <that .appex path>`.
The installed app can write its own prefs while you work, so read a non-empty prefs diff before
blaming your run. If it is yours, don't `defaults delete` the domain while the installed app runs
(it reads it live): show Erik the diff. With the app not running, restore exactly with
`defaults delete com.erole.Tweaks; defaults import com.erole.Tweaks build/verify/prefs-before.plist`
(not exercised in the dry run: nothing changed the domain and the installed app was running).
Never launch or quit the installed app from this skill.

## 5. Report the evidence

In the commit message, add one trailer line:

```
Verified: xcodebuild test (N tests, 3 skipped, 0 failures), FinderUtilitiesKit (19 + 5), build_and_run --build-only, debug launch quit by InstanceGuard, <what you drove and saw>
```

Use `Verified: none (<reason>)` if you truly couldn't verify. Never leave it out.
Name the live behavior you did not check. In the thread reply, attach the settings PNGs you looked at.

## Rules when something fails

- **Three strikes.** Fix and rerun up to 3 rounds. If it still fails, stop and tell Erik
  what fails, what you tried and the exact output. Don't keep going.
- **Never game the check.** No skipping or disabling tests, no adding sleeps, no rerunning
  until it passes, no loosening an assertion to match new output, no editing this skill to
  make your change pass.
- **Flaky test?** Find the root cause. If you can't, say so to Erik with the evidence;
  don't silently delete or retry it.
- **When a bug slips past this skill**, add the check that would have caught it here
  (one line in the table or step 3), in the same PR as the fix.
