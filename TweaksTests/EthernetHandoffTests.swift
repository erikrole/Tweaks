import XCTest
@testable import Tweaks

final class EthernetHandoffTests: XCTestCase {
    private let vpn = EthernetVPNRoute("interface: utun0\nflags: <UP,GATEWAY,DONE,STATIC>")
    private let wifi = EthernetVPNRoute("destination: 192.0.2.10\ninterface: en0\nflags: <UP,GATEWAY,HOST,DONE,STATIC>")

    func testUSBAndThunderboltEthernetAreAcceptedWithoutDockNames() {
        XCTAssertTrue(EthernetHandoffPolicy.isWired(type: "Ethernet", name: "en11"))
        XCTAssertTrue(EthernetHandoffPolicy.isWired(type: "Ethernet", name: "en8"))
        XCTAssertFalse(EthernetHandoffPolicy.isWired(type: "IEEE80211", name: "en0"))
        XCTAssertFalse(EthernetHandoffPolicy.isWired(type: "Bridge", name: "bridge0"))
        XCTAssertFalse(EthernetHandoffPolicy.isWired(type: "Ethernet", name: "utun0"))
    }

    func testPortalHostUsesExistingPreferenceAndRejectsCredentialsOrOptions() {
        XCTAssertEqual(EthernetHandoffPolicy.portalHost("vpn.example.edu"), "vpn.example.edu")
        XCTAssertEqual(EthernetHandoffPolicy.portalHost("https://VPN.example.edu/global-protect/"), "vpn.example.edu")
        for invalid in ["https://user:password@vpn.example.edu", "http://vpn.example.edu", "--help", "https://vpn.example.edu:444"] {
            XCTAssertNil(EthernetHandoffPolicy.portalHost(invalid))
        }
    }

    func testOnlyAnOwnedGlobalProtectTunnelPinnedToWifiCanTriggerHandoff() {
        XCTAssertTrue(EthernetHandoffPolicy.shouldHandoff(ethernetReady: true, wifiOn: true, attempted: false,
            secondsSinceAttempt: 301, defaultRoute: vpn, gatewayRoute: wifi, wifiInterface: "en0", globalProtectConnected: true))
        XCTAssertFalse(EthernetHandoffPolicy.shouldHandoff(ethernetReady: true, wifiOn: true, attempted: false,
            secondsSinceAttempt: 301, defaultRoute: vpn, gatewayRoute: wifi, wifiInterface: "en0", globalProtectConnected: false))
        for route in [EthernetVPNRoute("interface: en8\nflags: <HOST,STATIC>"),
                      EthernetVPNRoute("interface: en0\nflags: <HOST,WASCLONED>"), EthernetVPNRoute("")] {
            XCTAssertFalse(EthernetHandoffPolicy.shouldHandoff(ethernetReady: true, wifiOn: true, attempted: false,
                secondsSinceAttempt: 301, defaultRoute: vpn, gatewayRoute: route, wifiInterface: "en0", globalProtectConnected: true))
        }
    }

    func testUserDisabledWifiMissingEthernetAndCooldownPreventPowerChanges() {
        for (ready, on, attempted, elapsed) in [(false, true, false, 301.0), (true, false, false, 301.0),
                                                (true, true, true, 301.0), (true, true, false, 299.0)] {
            XCTAssertFalse(EthernetHandoffPolicy.shouldHandoff(ethernetReady: ready, wifiOn: on, attempted: attempted,
                secondsSinceAttempt: elapsed, defaultRoute: vpn, gatewayRoute: wifi, wifiInterface: "en0", globalProtectConnected: true))
        }
    }
}
