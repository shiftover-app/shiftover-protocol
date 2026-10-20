// MARK: - RemoteEndpointTests
//
// Every case here is one that was observed on a real network, not one imagined
// to round out a matrix. The IPv6 link-local cases are the bug: Bonjour resolved
// `fe80::5ce9:1eff:fe5b:e06b%bridge107`, the zone was stripped, the brackets
// were never added, and `URL(string:)` returned nil — so pairing failed before a
// single packet was sent.
//
// The expectations were checked against a live Shiftover listener, so these
// pin observed behaviour rather than a reading of the RFC:
//
//     ws://192.168.0.36:56658                       → opens
//     ws://[fe80::c93:8c55:bf6d:c86d%25en0]:56658   → opens
//     ws://fe80::c93:8c55:bf6d:c86d:56658           → URL(string:) is nil
//     ws://[fe80::c93:8c55:bf6d:c86d]:56658         → fails, no route

import XCTest
@testable import ShiftoverClient

final class RemoteEndpointTests: XCTestCase {

    // MARK: - Authority formatting

    func testIPv4PassesThroughUnchanged() {
        XCTAssertEqual(RemoteEndpoint.urlAuthorityHost("192.168.0.36"), "192.168.0.36")
    }

    func testHostnamePassesThroughUnchanged() {
        XCTAssertEqual(RemoteEndpoint.urlAuthorityHost("markos-macbook-pro.local"),
                       "markos-macbook-pro.local")
    }

    func testGlobalIPv6IsBracketed() {
        XCTAssertEqual(RemoteEndpoint.urlAuthorityHost("2a01:4f8:c17:1234::1"),
                       "[2a01:4f8:c17:1234::1]")
    }

    /// The case that actually broke pairing.
    func testLinkLocalIPv6KeepsItsZoneAndEscapesIt() {
        XCTAssertEqual(RemoteEndpoint.urlAuthorityHost("fe80::c93:8c55:bf6d:c86d%en0"),
                       "[fe80::c93:8c55:bf6d:c86d%25en0]")
    }

    /// Bonjour named the interface `bridge107` on the machine this was found on
    /// — zone ids are not always `enN`, so nothing may pattern-match them.
    func testZoneMayBeAnyInterfaceName() {
        XCTAssertEqual(RemoteEndpoint.urlAuthorityHost("fe80::5ce9:1eff:fe5b:e06b%bridge107"),
                       "[fe80::5ce9:1eff:fe5b:e06b%25bridge107]")
    }

    /// Formatting must be idempotent: an already-escaped, already-bracketed
    /// address that goes round again must not become `%2525` inside `[[…]]`.
    func testFormattingIsIdempotent() {
        let once = RemoteEndpoint.urlAuthorityHost("fe80::1%en0")
        XCTAssertEqual(RemoteEndpoint.urlAuthorityHost(once), once)
    }

    // MARK: - URL construction

    func testLinkLocalProducesAUsableURL() {
        let endpoint = RemoteEndpoint(host: "fe80::c93:8c55:bf6d:c86d%en0", port: 56658)
        let url = endpoint.webSocketURL()

        // Nil is the specific failure being guarded against — it fails before
        // any networking, so it never looks like a network problem.
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "ws://[fe80::c93:8c55:bf6d:c86d%25en0]:56658")
        XCTAssertEqual(url?.port, 56658)
    }

    func testIPv4ProducesAUsableURL() {
        let url = RemoteEndpoint(host: "192.168.0.36", port: 56658).webSocketURL()
        XCTAssertEqual(url?.absoluteString, "ws://192.168.0.36:56658")
        XCTAssertEqual(url?.host, "192.168.0.36")
    }

    func testHostnameProducesAUsableURL() {
        let url = RemoteEndpoint(host: "markos-macbook-pro.local", port: 56658).webSocketURL()
        XCTAssertEqual(url?.absoluteString, "ws://markos-macbook-pro.local:56658")
    }

    /// The kernel assigns the listener's port, so it can land anywhere in the
    /// ephemeral range — including above `Int16.max`, where a sloppy width
    /// conversion would wrap.
    func testHighPortSurvives() {
        let url = RemoteEndpoint(host: "192.168.0.36", port: 65535).webSocketURL()
        XCTAssertEqual(url?.port, 65535)
    }

    /// Garbage in gives nil rather than a URL that fails much later, somewhere
    /// less diagnosable.
    func testEmptyHostYieldsNoURL() {
        XCTAssertNil(RemoteEndpoint(host: "", port: 56658).webSocketURL())
    }
}
