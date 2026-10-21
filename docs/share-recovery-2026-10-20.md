# Work-share recovery — 2026-10-20

Tweaks 0.1.3 build 5 extends the existing **Keep work shares connected** switch.
Existing enablement and configured URLs are preserved. No separate app or root
helper is installed, and VPN credentials and MFA policy are unchanged.

Mounts use NetFS async requests, a 25-second deadline, explicit cancellation and a
global lease shared with sleep unmounts. NetFS does not call completion after
cancellation, so Tweaks owns continuation completion and ignores late callbacks.
SystemConfiguration route, DNS and link changes, NWPath and wake trigger retries.
A settling burst retries after 5, 15, 30 and 60 seconds; the idle fallback remains
five minutes. Failed attempts back off for five minutes.

After a timed-out attempt with the server still reachable, recovery requires two
separated samples matching the observed SMB account-lookup/main-thread-lock hang.
The helper must be the same user, exact system executable, PID and process start
identity. Rejected cancellations retain a quarantined request. A later enabled check can
observe the captured helper exiting or adopt the request under a fresh network
epoch and repeat the guarded recovery. Exact request IDs protect later attempts
from old callbacks. A final serialized gate rechecks operation generation, zero mounted
network shares, no unmounts and no sleep before SIGTERM. Missing mount-table or
sample data fails closed. Reset checks have a persistent ten-minute cooldown.
Other same-user applications share this system helper; recovery therefore skips
when a network share is mounted or the known hang cannot be confirmed. It never
force-unmounts a connected share or bypasses VPN/Duo sign-in.

An empty owned local macOS 0111 mount reservation can be reused with NetFS's
MountAtMountDir option. Symlinks, populated folders and other permissions are
rejected. Temporary owner-read permission is restored through the verified file
descriptor; no user files or mount folders are deleted or renamed.

Logs are bounded and contain no server URLs or credentials, under
~/Library/Application Support/com.erole.Tweaks/ShareRecovery/.

## Validation

- Debug app suite: 144 discovered, 142 passed, two expected profile skips, zero failures.
- FinderUtilitiesKit: 19 tests passed.
- Injected tests cover timeout without callback, cancellation and late completion,
  rejected-cancellation quarantine, later recovery under a fresh network epoch,
  global serialization across servers, preserved active shares, unknown mount-table
  state, sleep/unmount/disabled guards, structured hang matching, directory symlinks
  and populated folders, VPN settling retries and network-event coalescing.
- Required Release benchmarks passed (package and four app measurements).
- Build 5 is Developer ID-signed, notarized, stapled and installed at
  /Applications/Tweaks.app. Apple submission: 05049ba3-e81c-41f0-9e1d-ee08e4c08f2e.
  Gatekeeper reports Notarized Developer ID.
- Installed Network settings show Keep work shares connected and Move GlobalProtect
  to Ethernet enabled. The installed process and extension are running; all
  pre-existing preferences and Accessibility trust are preserved.
- The current share remains readable at /Volumes/users, with the VPN default on
  utun0 and its gateway transported over wired en11. No share was disconnected,
  no live helper was reset and no share files were written during this acceptance.

The current NAS is in active use by Adobe dynamiclink and Finder. Do not unmount
it merely for acceptance or stop the user's applications. Live disconnect/hang
recovery therefore needs a later idle-share window; unit tests use injected system
operations and never manufacture a real system-helper hang.


## Hardening — 2026-10-21

- Network changes during a reachability check or mount no longer cancel it. They ask
  for one more pass, debounced by two seconds, so a VPN settling can't trigger a burst
  of cancelled NetFS requests and quarantines. Link changes are watched on physical
  `en` interfaces only, not awdl, llw or utun.
- NetFS completions arrive on the attempt's own serial queue and clear the request
  there, so a deadline can never cancel a request NetFS already finished and freed.
- Helper exit is judged by process start time alone. A PID reused by another user's
  process or another executable now counts as exited.
- `sample` runs on its own dispatch queue instead of blocking the Swift concurrency
  pool, and a stuck `sample` is killed.
- The sleep gate is set from the connectivity watcher too, so recovery holds off
  during sleep even with "unmount before sleep" turned off.
- Mount reservations match share names with spaces or other encoded characters.
- Open-file checks (Downloads renames, unzip, DMG, duplicates, sleep unmounts, safe
  eject) no longer use `proc_listpidspath`, which hung for minutes on a
  Virtualization.framework VM process on this Mac. They scan each process's open
  files by device and inode, skip Virtualization VM processes, and are bounded to five
  seconds. A slow or incomplete scan counts as "in use", so nothing is touched. The
  scan covers open files, not a process's working directory or memory-mapped files.
