# Tweaks verification — 2026-10-17

**Historical audit result: not all tweaks worked as advertised.** See the [subsequent 0.1.1 repair report](repair-2026-10-17.md) for repairs and updated verification. The existing suites pass, but additional contract tests fail and the installed settings window raises an exception. All 22 switches, plus Finder actions, Keep Awake options, and login behavior, were inventoried. Coverage below distinguishes real runtime evidence from fixture tests and source review.

## Scope and build identity

- Source: `65a109dfdbe9225737ef65f9aa7b6497b7d64c64` on a clean checkout before the audit.
- Installed target: `/Applications/Tweaks.app`, version **0.1.0 (1)**, arm64, on **macOS 27.0.1 (26A434)**.
- Installed Mach-O UUID: `23644B13-03C0-3C74-AEBD-9519FA0B702A`; CDHash: `c818a5b3f51ae00e35947430ce01f8b51751061f`.
- `codesign --verify --deep --strict --verbose=2` passed. The signature contains a stapled notarization ticket; a new notarization/Gatekeeper assessment was not performed.
- The installed app and its embedded Finder extension were running. PluginKit also lists an older worktree extension registration; the observed extension process runs from `/Applications/Tweaks.app`.
- No source-commit stamp is embedded in the installed app. Source test results are for the commit above; they are not a claim that the installed binary is byte-identical to a build of that commit.
- No application-code fixes, installation, commit, push, or deployment were performed. Only this report and handoff documentation were added/updated. Temporary audit tests were removed from the normal target after recording their failures, and XcodeGen restored the original project.

## Confirmed failures

“Runtime” means reproduced on the installed app or actual macOS services. “Probe” means a new isolated assertion against the advertised contract. “Source” means a concrete code path, without claiming a real device or destructive operation was performed.

1. **P1 — Settings cannot finish opening. Runtime + probe.** Reopening the installed app produced `NSGenericException` from `NSLayoutConstraint.setActive`. An isolated construction of `SettingsWindowController` failed with: “Unable to activate constraint … because they have no common ancestor.” `SettingsChrome.swift:86–89` activates the new row's width constraint against its future parent before callers add the row. `SettingsView.swift:275`, `:294`, and `:306` use this path for shares, apps, and device controls. This blocks normal access to switches and configuration. **Repair:** attach the row before activating its parent-relative constraint; add a settings-construction regression.

2. **P1 — Work-share enablement and the server list overwrite each other. Two probes.** `TweakSettings.swift:113` reads `autoConnectShares` as a Boolean, while `:118–122` and `:138` read/write the same key as an array. Disabling the tweak at `:151` destroys the list. Reloading settings can replace the false value with the currently mounted shares; the following launch defaults the switch back on. The probes reproduced both loss of a synthetic configured URL and re-enablement after two reloads. **Repair:** separate the keys and migrate existing Boolean/array values without discarding either intent.

3. **P2 — Caps Lock restoration cannot read this Mac's actual `hidutil` format. Probe + live format read.** The command returns a `RegistryID / Key / Value` table. `CapsLockDelay.parse` in `SystemTweaks.swift:18–30` accepts only a JSON object. The new table-format probe returned nil for a custom nonzero delay, so applying the tweak cannot preserve that original value and disabling falls back to 250 ms. The existing tests use JSON and miss this. Current HID entries show a zero override, which supports the no-delay setting being applied; it does not prove a physical key tap or custom-value restoration. **Repair:** parse the supported real output and test it, including multiple devices.

4. **P2 — Shortcut conflicts can be displayed as valid assignments. Probe + source.** `Shortcut` includes the display-only `key` string in synthesized equality. `ShortcutStore.set` at `Shortcuts.swift:111` therefore treats identical physical key codes/modifiers with labels `/` and `?` as different shortcuts. The collision probe left both actions assigned. `AccessibilityTweaks.swift:150` ignores the registration return status, so a conflicting registration can leave a displayed shortcut inactive. **Repair:** compare key code/modifiers for conflicts and surface registration failure.

5. **P2 — DMG detection includes folders outside Downloads. Probe.** `DMGInstaller.swift:143–144` uses a textual prefix check. A synthetic `~/Downloads-Archive/App.dmg` was accepted as a download. No real disk image was mounted or installed. **Repair:** compare standardized path components, including the directory boundary.

6. **P2 — Updating from a DMG does not preserve the old app in Trash as documented. Source.** README promises the old copy goes to Trash. `DMGInstaller.swift:71–72` instead replaces it with `backupItemName: nil`; the only later trash call at `:84` targets the downloaded image. There is no recoverable old-app trash step. Also, `detach` at `:163–164` discards failure, and the caller proceeds to trash the image and open the app. **Repair:** make replacement recovery and eject outcomes explicit. No installed app was replaced to demonstrate this.

7. **P2 — Per-device limits misclassify channel-only software volume controls. Source.** `DeviceVolumeLimits.swift:174–177` recognizes only a writable master scalar; `:128–130` listens only to that scalar. `OutputAudio` in `SystemTweaks.swift:133–146` already has a channel 1/2 fallback, but these devices never pass the per-device feature's gate. They are incorrectly labeled hardware-only. A read-only inventory found only **MacBook Pro Speakers**, with a writable master scalar; that connected device is not affected by this particular defect. **Repair:** discover, listen to, and cap all supported volume elements; verify with channel-only hardware or an injected backend.

8. **P2 — Disconnected shares can be forgotten instead of remounting when reachable. Source.** `ShareSleepManager.didWake` at `NetworkTweaks.swift:201–203` clears its persistent-in-object pending list. Only task-local `remaining` survives. Another sleep cancels that task at `:176` and replaces the list with currently mounted shares at `:189`, losing still-disconnected URLs. The retry loop at `:212` also stops after 12 attempts, roughly three minutes plus probe/mount time. A share absent from the separate auto-connect list will not be restored when VPN/server access returns later. **Repair:** retain unresolved URLs across sleep and retry on connectivity changes until success or an explicit user decision.

9. **P2 — Option-green-button does not implement the promised full-screen behavior. Source + platform documentation.** `TweakSettings.swift:76` promises Option for normal full screen. `AccessibilityTweaks.swift:335` simply passes Option-click through unchanged. Native Option-click follows window zoom/restore behavior; it is not an unmodified full-screen click. See Apple's [full-screen guide](https://support.apple.com/guide/mac-help/use-apps-in-full-screen-mchl9c21d2be/mac) and [window guide](https://support.apple.com/guide/mac-help/work-with-app-windows-mchlp2469/mac). **Repair:** perform an explicit supported full-screen action, or change the advertised modifier/behavior. A live Option-click was not performed.

10. **P2 — A ZIP can be skipped permanently while Archive Utility is running. Source.** `DownloadSession.scanOnQueue` marks an arrival seen before dispatching extraction. `DownloadsWatcher.unzip` at `DownloadsTweaks.swift:87–89` returns if any Archive Utility process exists, even if it is handling another archive, without calling `onDeferred`. The file stays seen and does not retry when Archive Utility quits. **Repair:** defer/retry unrelated work while preventing double extraction of the same archive. Ordinary extraction and changed-file retry tests passed; this specific concurrent-app case has no injected regression yet.

## Coverage for every switch

The settings-window defect affects configuration access across all rows. “Partial” is not a pass for the entire end-to-end feature.

| Tweak | Evidence and result | Remaining acceptance |
| --- | --- | --- |
| Caps Lock with no delay | Live override zero; helper tests pass; restoration fails new probe (#3) | Physical tap, keyboard reconnect/wake, restore a custom per-device value |
| Cap volume at 40% after waking | Target calculation never raises low volume; suite passes | Real sleep/wake and readback on multiple outputs |
| Muted menu-bar icon | Listener/start/stop source reviewed; current output inventory succeeds | Actual mute, icon appearance, click-to-unmute, device switch |
| Lowercase extensions in Downloads | Real temporary-folder watcher and collision/hardlink/Unicode/settling/restart tests pass | Installed watcher with a browser download into user Downloads |
| Fantastical calendar invites | Alarm-removal fixtures, including CRLF, pass; open/trash code reviewed | Fantastical open success and actual original-file Trash result |
| Install apps from disk images | Identity/downgrade checks pass; folder-boundary probe fails (#5); recovery/eject mismatch (#6) | Signed disposable DMG install/update, rejection, cancellation, eject failure |
| Block Music launched by play key | Three-second causal-window helper tests pass; observer code reviewed | Physical media key versus intentional Music launch |
| Clear notifications shortcut | Action selection tests pass; shortcut-conflict defect (#4) | Real notification banners/stacks and physical global shortcut |
| Dismiss Shortcut-running banners | Matching tests pass; polling lifecycle reviewed | Real Shortcuts banner on this macOS version |
| Green button fills screen | Geometry and saved-frame decision tests pass; Option behavior mismatch (#9) | Live fill/restore, multi-display geometry, explicit full-screen bypass |
| Eject external drives before sleep | Volume eligibility tests pass; sleep observers and busy/render guards reviewed | Real idle/busy physical media through a sleep/wake cycle |
| Stay awake while rendering | CPU aggregation, PID reuse, idle render-engine detection, and process fixture tests pass | Actual Adobe render, real power assertion, two-minute release |
| Clean copied links | URL cleaning tests pass; clipboard type/concealed-item guards reviewed | Real copy/paste timing and protected clipboard formats |
| Unzip downloaded ZIPs | Real temporary single/multi-item extraction, no-overwrite, cancellation and changed-version cases pass; concurrent Archive Utility gap (#10) | Installed browser arrival and concurrent Archive Utility behavior |
| Quit apps on last window | Had-window/two-successful-empty-answer logic tests pass | Disposable Preview/TextEdit window, unsaved document, app actually quits |
| Disconnect/remount shares for sleep | URL and matching helpers pass; live share test skipped; remount persistence fails source contract (#8) | Actual NAS/VPN sleep, wake and delayed reconnection |
| Keep work shares connected | Two new persistence probes fail (#2) | Keychain-backed mount and network/VPN transitions after repair |
| Keep Awake shortcuts | Parsing/end-reason/quiet-period/recents/timer policy tests pass; real system-sleep assertion created and released in isolated host | Installed physical tap/hold and panel navigation; battery/power transition, every job mode, display-off path; conflict defect (#4) |
| Restore saved window layouts | Display identity, privacy fingerprint and frame fitting tests pass | Accessibility capture/restore and physical display disconnect/reconnect |
| Limit volume per device | Limits/UID persistence/quantization tests pass; connected master control inspected; channel-only defect (#7) | Real USB/Bluetooth switching, volume changes and mute-on-switch-away |
| Safe-eject shortcut | Topology, sibling blockers, revalidation and fail-closed backend tests pass; real read-only inventory succeeds with zero eligible drives | Real idle/busy multi-volume drive, shortcut dispatch, normal non-force eject |
| Review duplicate downloads | Temporary real-file hashing, collision exclusions, cancellation, review-once, and revalidation tests pass | Installed review UI and actual user-approved Trash action |

## Additional surfaces and claim limits

- **Finder Inspect Media: live pass for a local PNG.** The installed extension showed `Loading…` on first open, then `1024×1024`, `77 KB`, alpha present, 8-bit RGB and 144 DPI after reopening. Dimensions match `sips`. This verifies the installed lazy media bundle on this file, not video, SMB or cloud-placeholder behavior.
- **Copy Path / Copy Original Path:** both entries appeared in the live Finder menu; path-cleaning package tests passed. A clipboard write from these entries was not exercised.
- **Quick Image Actions:** menu entry appeared and its handoff was invoked. A usable host panel was not obtained while settings reopening raises the exception. Do not count the click as successful handoff. Isolated JPEG/PNG/HEIC export, resize, orientation, metadata removal/retention, white alpha compositing, multi-frame rejection, and no-overwrite tests all passed. No source image was changed.
- **Keep Awake assertion:** a new runtime test checked actual IOKit assertions for the test process before start, after start, and after stop. This passed. A synthetic Hyper+/ attempt against the installed app produced no observed Tweaks assertion; injected key delivery is not established, so physical shortcut behavior remains unverified rather than a confirmed dispatch defect.
- **“Upload finishes” is a heuristic, not upload completion.** `JobWatcher.swift:89` and `:115–120` use aggregate `en*` outgoing traffic below 100,000 bytes/s for two minutes. A slow active upload can qualify as idle. Downloads completion detects partial-name suffixes only in Downloads; NAS-copy completion checks open files on network volumes. These labels should explain their limits, and a long/slow real job is still required for acceptance.
- **Clipboard cleaning is delayed:** the timer is two seconds with 0.75-second tolerance (`MoreTweaks.swift`, `LinkCleaner`). The pure transformation works, but a fast paste can precede cleaning. This is a timing limitation, not proof that every copied link is cleaned before paste.
- **Launch at login:** installed app was already running from launchd and the stored preference was enabled. No logout/reboot was performed, so actual next-login launch remains unverified.
- **Permissions:** no TCC permissions were granted or reset. A cached Accessibility flag is not used as proof that all AX actions work.
- **Cleanup:** no Tweaks power assertion remained after the audit. The installed process was still running. Tweak choices, shortcut data and the configured share list matched the initial read; the app refreshed its cached Accessibility flag from false to true during inspection.

## Commands and results

All Xcode/Swift commands used normal host caches/test services. The app's XCTest startup guard suppresses ordinary background-tweak startup.

| Check | Result |
| --- | --- |
| `xcodegen generate` | Passed; final regeneration restored the original tracked project |
| Debug app suite, arm64, unsigned test host | 98 discovered: **95 passed, 3 skipped, 0 failed** |
| Release app suite, `ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES` | 98 discovered: **95 passed, 3 skipped, 0 failed** |
| `swift test --package-path Packages/FinderUtilitiesKit` | **19 Swift Testing tests passed**; ordinary opt-in performance tests skipped |
| New contract probes | **5 tests failed**: two share-persistence cases, HID table parsing, shortcut conflict, DMG directory boundary |
| Settings/audio probes | **1 failed** (settings construction), **1 passed** (read-only Core Audio inventory) |
| Runtime power/inventory probes | **2 passed**; real assertion released and no disk ejected |
| `./scripts/benchmark.sh` | **3 package + 4 app benchmark tests passed** |
| Installed signature verification | Passed |

The app-suite skips were the two opt-in file-work profiles and the live-share check because no network share was mounted. Those gaps were not silently counted as passes. The two large file-work profiles were not run in this audit.

Release benchmark medians/p95, 30 samples after five warmups: render poll **2.585/3.035 ms**; 10,000-file completion check **4.365/5.020 ms**; 10,000-file known-directory scan **3.440/3.635 ms**; 1,000 URL cleanups **4.456/4.573 ms**. Cold simulated Finder-menu lookup measured roughly **8–15 microseconds**. No before/after performance change or battery benefit is claimed.

## Retained local evidence and next gate

Logs, xcresults, the synthetic image, and the temporary probe sources are retained under `.build/verification-2026-10-17/` (ignored). Key files: `debug.log`, `release.log`, `package.log`, `audit.log`, `settings-audit.log`, `runtime.log`, `benchmarks.log`, `installed-process-errors.log`, `VerificationAuditTests.swift`, and `RuntimeVerificationTests.swift`. The installed-process log is filtered to PID 969 so test-host layout warnings are not confused with installed failures.

To rerun a probe, copy its Swift file back into `TweaksTests/`, run XcodeGen, and select its test class with `-only-testing:TweaksTests/<class>`. Keep the normal app startup guard in place. The failing probes are preserved as evidence, not relabeled as passing tests.

The next gate is repair of the settings-window exception and the reproduced contract failures, followed by a signed installed-app pass. Full acceptance still needs disposable data plus real notification/media-key, sleep/wake, NAS/VPN, external-drive, audio-switch and monitor-transition scenarios. The audit is **not a release approval**.
