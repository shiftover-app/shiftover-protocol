import XCTest
@testable import ShiftoverProtocol

final class SharingTests: XCTestCase {
    func testSharingRelayNamespaceAndInvitationRoundTrip() throws {
        let route = try XCTUnwrap(RelayRoute.sharing(baseURL: "wss://relay.example"))
        XCTAssertEqual(route.connectURL(role: .phone)?.path, "/share/v1/connect")
        let now = Date()
        let invite = ShareInvitation(projectID: UUID(), projectName: "Project", hostName: "Host",
            address: "relay", port: 443, publicKey: Data(repeating: 1, count: 32), now: now, relay: route)
        XCTAssertEqual(ShareInvitation.parse(try XCTUnwrap(invite.url()), now: now)?.relay, route)
        for base in ["ws://public.example", "wss://user:secret@relay.example", "wss://relay.example?secret=x",
                     "wss://relay.example#secret", "file:///tmp", "wss://relay.example/../bad"] {
            XCTAssertNil(RelayRoute.sharing(baseURL: base), base)
        }
        XCTAssertNotNil(RelayRoute.sharing(baseURL: "ws://127.0.0.1:8787"))
        XCTAssertFalse(RelayRoute(url: "wss://relay.example", token: route.token).isSharingRoute)
    }

    func testSecretOnlyInFragmentAndExpiry() throws {
        let now = Date()
        let invitation = ShareInvitation(projectID: UUID(), projectName: "Project", hostName: "Host",
            address: "192.0.2.1", port: 4310, publicKey: Data(repeating: 1, count: 32), now: now)
        for landing in [nil, URL(string: "https://example.invalid/join")] {
            let url = try XCTUnwrap(invitation.url(landingPage: landing))
            XCTAssertNil(url.query)
            XCTAssertEqual(ShareInvitation.parse(url, now: now), invitation)
            XCTAssertNil(ShareInvitation.parse(url, now: now.addingTimeInterval(600)))
        }
        XCTAssertNil(ShareInvitation.parse(URL(string: "shiftover://join#garbage")!))
    }
    /// The Return guard's two events survive the wire, and a build that
    /// predates them fails to decode them (and skips them) rather than
    /// misreading them as another event.
    func testReturnGuardEventsRoundTrip() throws {
        let pane = UUID()
        for event in [ServerEvent.commandHeld(paneID: pane, command: "git push --force", reason: "Force-pushing rewrites the branch."),
                      .commandDecided(paneID: pane, command: "git push --force", allowed: false, reason: "Blocked by Marko"),
                      .commandDecided(paneID: pane, command: "ls", allowed: true, reason: nil),
                      .hostColorsChanged(TerminalColorsDTO(foreground: "#cdd6f4", background: "#1e1e2e",
                                                           ansi: Array(repeating: "#000000", count: 16)))] {
            XCTAssertEqual(try JSONDecoder().decode(ServerEvent.self, from: JSONEncoder().encode(event)), event)
        }
    }

    /// An attachment from a desktop that predates the colours still decodes.
    func testTerminalAttachmentColorsAreOptionalAndValidated() throws {
        let old = Data(#"{"paneID":"6A4C0E2B-1D2E-4C5B-9F7A-2B3C4D5E6F70","cols":80,"rows":24,"backfill":""}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(TerminalAttachment.self, from: old).colors)
        let colors = TerminalColorsDTO(foreground: "#cdd6f4", background: "#1e1e2e", cursor: "#f5e0dc",
                                       ansi: Array(repeating: "#45475a", count: 16))
        XCTAssertTrue(colors.isValid)
        let attachment = TerminalAttachment(paneID: UUID(), cols: 80, rows: 24, backfill: Data(), colors: colors)
        XCTAssertEqual(try JSONDecoder().decode(TerminalAttachment.self, from: JSONEncoder().encode(attachment)), attachment)
        XCTAssertFalse(TerminalColorsDTO(foreground: "red", background: "#000000", ansi: []).isValid)
    }

    func testCodeBoundToHandshakeAndLayoutBackwardsCompatible() throws {
        let one = ShareInvitation.confirmationCode(handshakeHash: Data([1]))
        XCTAssertEqual(one.count, 6)
        XCTAssertNotEqual(one, ShareInvitation.confirmationCode(handshakeHash: Data([2])))
        let pane = UUID()
        let tab = WorkspaceTabDTO(id: UUID(), projectID: UUID(), worktreeID: UUID(), title: "Tab",
            panes: [], layout: .split(vertical: false, children: [.pane(pane), .pane(UUID())], weights: [1, 2]))
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceTabDTO.self, from: JSONEncoder().encode(tab)), tab)
    }
    func testGuestCannotUseOwnerMutationsOrLegacyAttach() {
        let id = UUID()
        let denied: [RPCMethod] = [.attachTerminal(paneID: id), .providerUsage, .fleetSummary,
            .notificationPresence(mode: nil, rssi: nil), .createTerminalTab(worktreeID: id, requestID: id),
            .gitMutate(worktreeID: id, action: .push, expectedRevision: "", requestID: id),
            .replyToAgent(worktreeID: id, text: "run"), .submitShellCommand(paneID: id, promptID: id, command: "run"),
            .beginAttachment(worktreeID: id, name: "file", size: 1), .listConversations(projectID: nil)]
        for method in denied { XCTAssertEqual(method.guestScope, .denied, "\(method)") }
        XCTAssertEqual(RPCMethod.attachSharedTerminal(paneID: id).guestScope, .pane(id))
        XCTAssertEqual(RPCMethod.readWorkspaceFile(worktreeID: id, path: "file").guestScope, .worktree(id))
    }
}
