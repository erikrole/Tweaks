import AppKit
import SystemConfiguration

/// Reminds you once to reconnect GlobalProtect when you leave the dock with it turned off.
/// It only watches; it never connects, disconnects or reroutes the VPN.
struct VPNReminderState: Equatable, Sendable {
    /// Docked on wired Ethernet with the VPN off at some point since the last reminder.
    private(set) var dockedWithoutVPN = false

    /// Feed each network snapshot; true means remind now.
    mutating func update(wired: Bool, vpnUp: Bool) -> Bool {
        if vpnUp { dockedWithoutVPN = false; return false }
        if wired { dockedWithoutVPN = true; return false }
        guard dockedWithoutVPN else { return false }
        dockedWithoutVPN = false
        return true
    }
}

@MainActor
final class VPNReminder {
    private var store: SCDynamicStore?
    private var state = VPNReminderState()
    private var pending: DispatchWorkItem?
    static let globalProtect = "/Applications/GlobalProtect.app"

    func start() {
        guard store == nil, FileManager.default.fileExists(atPath: Self.globalProtect) else { return }
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "Tweaks.vpn-reminder" as CFString, { _, _, info in
            guard let info else { return }
            MainActor.assumeIsolated { Unmanaged<VPNReminder>.fromOpaque(info).takeUnretainedValue().changed() }
        }, &context)
        guard let store else { return }
        SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/IPv4"] as CFArray,
                                          ["State:/Network/Interface/en[0-9]+/Link", "State:/Network/Service/.*/IPv4"] as CFArray)
        SCDynamicStoreSetDispatchQueue(store, .main)
        Notifier.requestPermission()
        evaluate()
    }

    func stop() {
        pending?.cancel(); pending = nil
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
        state = VPNReminderState()
    }

    /// Undocking sends a burst of changes; look once things settle.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func evaluate() {
        guard let store else { return }
        let vpnUp = SCDynamicStoreCopyValue(store, "State:/Network/Service/gpd.pan/IPv4" as CFString) != nil
        if state.update(wired: Self.wiredActive(store), vpnUp: vpnUp) {
            Notifier.post(title: "Reconnect GlobalProtect", body: "You left the wired network with the VPN off.")
            HUD.show("Reconnect GlobalProtect", symbol: "lock.shield", duration: 4)
        }
    }

    /// A wired Ethernet service (not phone tethering) with an address and a router.
    private static func wiredActive(_ store: SCDynamicStore) -> Bool {
        guard let prefs = SCPreferencesCreate(nil, "Tweaks.vpn-reminder" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return false }
        return services.contains { service in
            guard SCNetworkServiceGetEnabled(service), let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  EthernetHandoffPolicy.isWired(type: type, name: name,
                                                displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? ""),
                  let id = SCNetworkServiceGetServiceID(service) as String?,
                  let link = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(name)/Link" as CFString) as? [String: Any],
                  link["Active"] as? Bool == true,
                  let ip = SCDynamicStoreCopyValue(store, "State:/Network/Service/\(id)/IPv4" as CFString) as? [String: Any],
                  ip["Router"] as? String != nil else { return false }
            return true
        }
    }
}
