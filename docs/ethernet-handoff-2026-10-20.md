# Ethernet VPN handoff — 2026-10-20

Tweaks 0.1.2 build 4 adds **Network > Move GlobalProtect to Ethernet**. It is off
by default; the current user explicitly requested enabling it on their Mac.

## Behavior

The feature selects enabled, linked Ethernet services with a usable IPv4 address
and router in macOS service priority order. It uses interface type rather than a
dock name, manufacturer, speed, or fixed BSD device number, so USB Ethernet and
Thunderbolt Ethernet (including Satechi and CalDigit TS5 Plus) use the same path.
Wi-Fi, bridge, and tunnel interfaces cannot be selected as wired destinations.

It reads only the existing GlobalProtect portal hostname from its preferences.
It requires macOS to identify `gpd.pan` as the default tunnel owner and the VPN
endpoint to have a static host route still using Wi-Fi. Before touching Wi-Fi,
it checks the wired router and opens an Ethernet-bound TCP connection to the VPN
gateway. The resolved endpoint is reused during the handoff so transient VPN DNS
loss cannot stall the transition.

Wi-Fi is briefly cycled and restored; the feature checks the wired VPN route and
HTTPS afterward. It leaves manually disabled Wi-Fi alone, never edits VPN or MFA
configuration, and allows one attempt per connection with a five-minute cooldown.
Network and file work run on a utility queue. Network changes trigger checks;
a 30-second fallback handles recovery without frequent idle polling.

Recovery state is saved atomically before Wi-Fi powers off. Disabling the feature,
quitting, restarting, and an interrupted handoff all restore owned Wi-Fi state.
A failed restoration keeps recovery retries running and cancels app quit. A
canceled quit resumes monitoring according to the saved feature switch. App
relaunch waits for the old process to exit rather than using a fixed delay.

## Checks

- Debug app suite: 130 tests discovered, 3 expected skips, 0 failures.
- FinderUtilitiesKit: 19 tests passed.
- Required Release benchmarks: package and app checks passed.
- Policy regressions cover USB/Thunderbolt detection, other-VPN rejection,
  user-disabled Wi-Fi, missing Ethernet, duplicate-attempt cooldown, and safe
  portal hostname parsing.
- Recovery regressions use injected commands, never actual network power changes;
  a failed restore blocks quit and continues retrying while disabled, and stopping
  without owned Wi-Fi state performs no power writes.

Tweaks 0.1.2 build 4 is Developer ID-signed, notarized, stapled, and installed at
`/Applications/Tweaks.app`; Gatekeeper reports Notarized Developer ID. All existing
preferences are unchanged, Accessibility remains trusted, and only
`preferEthernetForVPN=true` was added through the installed Network switch.

The installed app passed a live Ethernet-service disable/enable test: GlobalProtect
recovered over Wi-Fi with working HTTPS, then Tweaks handed it back to Ethernet,
restored Wi-Fi, and verified HTTPS. The standalone agent and process are absent.
The old app and prototype files remain in the task's recovery directory.

The CalDigit at work is not physically connected during this implementation and
requires a separate live acceptance check. No physical dock unplug or reboot/login
test is implied by the network-service transition test.

## Local state and recovery

The feature's state and bounded event logs live in
`~/Library/Application Support/com.erole.Tweaks/EthernetHandoff/`. There is no
separate app, launch agent, root daemon, or stored VPN credential. Turn the Network
switch off to disable the feature. The earlier standalone prototype was unloaded
and its files preserved outside the repository.

## Hardening — 2026-10-21

- Logout, restart and shutdown are never held up. Wi-Fi restore is tried once and
  any pending restore finishes at the next launch from saved state. Every quit has
  an eight-second deadline. If a user quit can't restore Wi-Fi, Tweaks keeps running
  and keeps retrying.
- A stop or quit during a handoff skips the post-restore verification instead of
  waiting on it.
- The restore-retry and inspection timers are separate, so re-enabling after a failed
  restore can't orphan a timer. Restore retries back off from 5 seconds to 5 minutes.
- A `state.json` that exists but can't be read is treated as a pending restore, so
  Wi-Fi is turned back on rather than left off. Older files without the new key decode.
- iPhone, iPad and Android USB tethering are never treated as wired Ethernet.
- One attempt per wired connection, VPN gateway and VPN address, saved across launches.
  A flapping dock or sleep/wake doesn't cycle Wi-Fi again for the same VPN session.

Known limit: the gateway is taken from the GlobalProtect portal host (`LastUrl`).
When a portal hands out a different gateway, the static-route check doesn't match
and the handoff simply doesn't run.
