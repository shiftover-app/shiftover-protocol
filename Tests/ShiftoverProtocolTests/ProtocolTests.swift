import XCTest
@testable import ShiftoverProtocol

// The load-bearing properties of the wire format. These are cheap to run and
// pin the things that would be expensive to discover from a shipped iOS build.

final class FrameTests: XCTestCase {

    func testRoundTripsEveryFrameType() throws {
        let payload = Data("hello".utf8)
        for type in FrameType.allCases {
            let decoded = try XCTUnwrap(Frame.decode(Frame(type: type, payload: payload).encoded()))
            XCTAssertEqual(decoded.type, type)
            XCTAssertEqual(decoded.payload, payload)
        }
    }

    func testEmptyPayloadIsValid() throws {
        let decoded = try XCTUnwrap(Frame.decode(Frame(type: .hello, payload: Data()).encoded()))
        XCTAssertEqual(decoded.type, .hello)
        XCTAssertTrue(decoded.payload.isEmpty)
    }

    /// D16: an unrecognised tag must decode to `nil` so the reader can SKIP it.
    /// If this ever throws or traps instead, a newer peer introducing a frame
    /// type would kill older sessions rather than being ignored by them.
    func testUnknownTagDecodesToNilRatherThanFailing() {
        let unknown = Data([0xFE]) + Data("payload".utf8)
        XCTAssertNil(Frame.decode(unknown))
    }

    func testEmptyMessageDecodesToNil() {
        XCTAssertNil(Frame.decode(Data()))
    }

    /// No two frame types may share a tag — a collision would silently route
    /// bulk bytes into the JSON decoder.
    func testFrameTagsAreUnique() {
        let tags = FrameType.allCases.map(\.rawValue)
        XCTAssertEqual(Set(tags).count, tags.count)
    }
}

final class TerminalPayloadTests: XCTestCase {

    func testRoundTrip() throws {
        let id = UUID()
        let bytes = Data([0x1B, 0x5B, 0x33, 0x31, 0x6D]) // ESC [ 3 1 m
        let decoded = try XCTUnwrap(
            TerminalPayload.decode(TerminalPayload(paneID: id, bytes: bytes).encoded()))
        XCTAssertEqual(decoded.paneID, id)
        XCTAssertEqual(decoded.bytes, bytes)
    }

    /// An attach with no output yet is legitimate — 16 bytes and nothing more.
    func testEmptyBytesIsValid() throws {
        let id = UUID()
        let decoded = try XCTUnwrap(
            TerminalPayload.decode(TerminalPayload(paneID: id, bytes: Data()).encoded()))
        XCTAssertEqual(decoded.paneID, id)
        XCTAssertTrue(decoded.bytes.isEmpty)
    }

    func testTruncatedPayloadDecodesToNil() {
        XCTAssertNil(TerminalPayload.decode(Data(repeating: 0, count: 15)))
        XCTAssertNil(TerminalPayload.decode(Data()))
    }

    func testUUIDByteRoundTripIsStable() throws {
        for _ in 0..<100 {
            let id = UUID()
            XCTAssertEqual(UUID(protocolBytes: id.protocolBytes), id)
        }
        XCTAssertEqual(UUID().protocolBytes.count, 16)
        XCTAssertNil(UUID(protocolBytes: Data(repeating: 0, count: 17)))
    }

    /// Binary framing exists to avoid base64 inflation on the highest-volume
    /// payload (D8). Pin that it actually is compact: 16 bytes of overhead,
    /// not ~4/3 of the body.
    func testOverheadIsFixedSixteenBytes() {
        let body = Data(repeating: 0x41, count: 4096)
        let encoded = TerminalPayload(paneID: UUID(), bytes: body).encoded()
        XCTAssertEqual(encoded.count, body.count + 16)
    }
}

final class VersionNegotiationTests: XCTestCase {

    func testSameVersionIsCompatible() {
        XCTAssertEqual(ProtocolVersion.check(peerVersion: ProtocolVersion.current),
                       .compatible(negotiated: ProtocolVersion.current))
    }

    func testNewerPeerIsRefusedWithNumbers() {
        let result = ProtocolVersion.check(peerVersion: ProtocolVersion.current + 1)
        XCTAssertEqual(result, .peerTooNew(peer: ProtocolVersion.current + 1,
                                           current: ProtocolVersion.current))
        XCTAssertFalse(result.isCompatible)
    }

    func testOlderPeerBelowFloorIsRefused() {
        let result = ProtocolVersion.check(peerVersion: ProtocolVersion.minimumSupported - 1)
        XCTAssertEqual(result, .peerTooOld(peer: ProtocolVersion.minimumSupported - 1,
                                           minimumSupported: ProtocolVersion.minimumSupported))
    }

    func testNegotiatedVersionNeverExceedsWhatWeSpeak() {
        // Widen the floor hypothetically: whatever the peer claims, the
        // negotiated value must stay within our own understanding.
        for peer in ProtocolVersion.minimumSupported...ProtocolVersion.current {
            guard case .compatible(let negotiated) = ProtocolVersion.check(peerVersion: peer) else {
                return XCTFail("expected compatible for peer \(peer)")
            }
            XCTAssertLessThanOrEqual(negotiated, ProtocolVersion.current)
        }
    }

    /// D16 demands an *actionable* refusal. Assert both sides are told to
    /// update the correct thing — a message that blames the wrong end is worse
    /// than no message.
    func testRefusalNamesTheRightSideToUpdate() throws {
        let phoneIsNewer = ProtocolVersion.check(peerVersion: ProtocolVersion.current + 1)

        // Desktop sees a newer phone → the DESKTOP must update.
        let onDesktop = try XCTUnwrap(phoneIsNewer.refusalMessage(localSideIsPhone: false))
        XCTAssertTrue(onDesktop.contains("Mac"), onDesktop)

        // Phone sees a newer desktop → GO must update.
        let onPhone = try XCTUnwrap(phoneIsNewer.refusalMessage(localSideIsPhone: true))
        XCTAssertTrue(onPhone.contains("App Store"), onPhone)

        XCTAssertNil(VersionCompatibility.compatible(negotiated: 1)
            .refusalMessage(localSideIsPhone: true))
    }
}

final class CodableShapeTests: XCTestCase {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    func testHandshakeRoundTrips() throws {
        let hello = Hello(handshake: Data(repeating: 7, count: 96))
        XCTAssertEqual(try roundTrip(hello), hello)
        let ack = HelloAck(handshake: Data(repeating: 3, count: 48))
        XCTAssertEqual(try roundTrip(ack), ack)

        let identity = HelloIdentity(appVersion: "0.4.2", deviceID: UUID(),
                                     deviceName: "Marko's iPhone",
                                     pairingID: "abc123", pairingProof: Data(repeating: 4, count: 32))
        XCTAssertEqual(try roundTrip(identity), identity)
        let payload = HelloAckPayload(appVersion: "0.4.2", hostName: "Markos-MacBook-Pro",
                                      capabilities: [.read, .write, .terminalStream])
        XCTAssertEqual(try roundTrip(payload), payload)
    }

    /// The pairing fields are present only on a first connection. A returning
    /// identity omits them entirely and must still decode — otherwise every
    /// reconnection after the initial QR scan would fail.
    func testIdentityWithoutPairingFieldsRoundTrips() throws {
        let identity = HelloIdentity(appVersion: "0.4.2", deviceID: UUID(), deviceName: "iPhone")
        let decoded = try roundTrip(identity)
        XCTAssertNil(decoded.pairingID)
        XCTAssertNil(decoded.pairingProof)
    }

    /// A peer on a different version sends a `Hello` this build may not be able
    /// to decode in full — v1's, for one. The version must still be readable,
    /// or the refusal cannot say which side to update.
    func testVersionIsReadableFromAHelloOfAnyShape() throws {
        let v1 = """
        {"protocolVersion":1,"appVersion":"0.1","deviceID":"\(UUID().uuidString)",
         "deviceName":"iPhone","publicKey":"AAAA","sessionNonce":"AAAA"}
        """
        XCTAssertNil(try? JSONDecoder().decode(Hello.self, from: Data(v1.utf8)))
        let probe = try JSONDecoder().decode(HandshakeVersionProbe.self, from: Data(v1.utf8))
        XCTAssertEqual(probe.protocolVersion, 1)
        XCTAssertFalse(ProtocolVersion.check(peerVersion: probe.protocolVersion).isCompatible)
    }

    func testEveryRPCMethodRoundTrips() throws {
        let methods: [RPCMethod] = [
            .listProjects,
            .listWorktrees(projectID: nil),
            .listWorktrees(projectID: UUID()),
            .fleetSummary,
            .reviewItems,
            .monitorSummary(worktreeID: UUID()),
            .listPanes(worktreeID: UUID()),
            .replyToAgent(worktreeID: UUID(), text: "keep going"),
            .answerPermission(worktreeID: UUID(), allow: true),
            .enqueueTask(projectID: UUID(), prompt: "fix the flake",
                         agent: .claude, baseBranch: "main"),
            .approveAndMerge(worktreeID: UUID()),
            .createPullRequest(worktreeID: UUID()),
            .requestChanges(worktreeID: UUID(), text: "add a test"),
            .attachTerminal(paneID: UUID()),
            .detachTerminal(paneID: UUID())
        ]
        for method in methods {
            XCTAssertEqual(try roundTrip(RPCRequest(method: method)).method, method)
        }
    }

    func testRPCResultsRoundTrip() throws {
        let results: [RPCResult] = [
            .projects([ProjectDTO(id: UUID(), name: "shiftover", isGit: true)]),
            .fleetSummary(FleetSummaryDTO(queued: 2, working: 3, toReview: 1)),
            .monitorSummary(nil),
            .ok,
            .failure(RPCError(code: .preconditionFailed, message: "worktree is dirty"))
        ]
        for result in results {
            XCTAssertEqual(try roundTrip(RPCResponse(id: UUID(), result: result)).result, result)
        }
    }

    /// `Data` must survive the JSON round trip — the attach backfill rides here,
    /// and a phone that renders a corrupted scrollback is worse than one that
    /// renders none.
    func testTerminalAttachmentPreservesBackfillBytes() throws {
        let backfill = Data((0...255).map(UInt8.init))
        let attachment = TerminalAttachment(paneID: UUID(), cols: 120, rows: 40, backfill: backfill)
        XCTAssertEqual(try roundTrip(attachment).backfill, backfill)
    }

    func testServerEventsRoundTrip() throws {
        let events: [ServerEvent] = [
            .agentStatusChanged(worktreeID: UUID(), previous: .working,
                                current: .permission, message: "Allow edit to src/main.rs?"),
            .worktreesChanged,
            .fleetSummaryChanged(FleetSummaryDTO(queued: 0, working: 1, toReview: 2)),
            .terminalResized(paneID: UUID(), cols: 80, rows: 24),
            .terminalClosed(paneID: UUID()),
            .hostGoingAway(reason: .sleeping)
        ]
        for event in events {
            XCTAssertEqual(try roundTrip(event), event)
        }
    }
}

final class DTOSemanticsTests: XCTestCase {

    func testNeedsAttentionMatchesTheWaitingStates() {
        XCTAssertEqual(
            Set([AgentStatusDTO.input, .permission, .error]),
            Set([AgentStatusDTO.idle, .present, .working, .input,
                 .permission, .done, .error].filter(\.needsAttention)))
    }

    func testContextFractionClampsAndSurvivesUnknownLimit() {
        func summary(used: Int, limit: Int) -> MonitorSummaryDTO {
            MonitorSummaryDTO(agent: "claude", model: "Opus 5", contextUsed: used,
                              contextLimit: limit, estimatedCostUSD: 0, promptCount: 0)
        }
        XCTAssertEqual(summary(used: 100_000, limit: 200_000).contextFraction, 0.5)
        XCTAssertEqual(summary(used: 0, limit: 0).contextFraction, 0)          // no divide-by-zero
        XCTAssertEqual(summary(used: 999, limit: 100).contextFraction, 1)      // clamped
        XCTAssertEqual(summary(used: -5, limit: 100).contextFraction, 0)       // clamped
    }
}

final class RelayVocabularyTests: XCTestCase {

    func testConnectURLAddsThePathAndRole() {
        let route = RelayRoute(url: "wss://cloud.shiftover.app", token: RelayRoute.mintToken())
        XCTAssertEqual(route.connectURL(role: .mac)?.absoluteString,
                       "wss://cloud.shiftover.app/v1/connect?role=mac")
        let local = RelayRoute(url: "ws://127.0.0.1:8787/", token: "t")
        XCTAssertEqual(local.connectURL(role: .phone)?.absoluteString,
                       "ws://127.0.0.1:8787/v1/connect?role=phone")
    }

    func testHTTPURLUsesTheSameHostOverHTTPS() {
        XCTAssertEqual(RelayRoute(url: "wss://cloud.shiftover.app", token: "t")
                        .httpURL(path: "/v1/push")?.absoluteString,
                       "https://cloud.shiftover.app/v1/push")
        XCTAssertEqual(RelayRoute(url: "ws://127.0.0.1:8787", token: "t")
                        .httpURL(path: "/v1/device")?.absoluteString,
                       "http://127.0.0.1:8787/v1/device")
        XCTAssertNil(RelayRoute(url: "https://x", token: "t").httpURL(path: "/v1/push"))
    }

    func testConnectURLRefusesNonWebSocketBases() {
        for bad in ["https://cloud.shiftover.app", "cloud.shiftover.app", "", "wss://"] {
            XCTAssertNil(RelayRoute(url: bad, token: "t").connectURL(role: .mac), bad)
        }
    }

    func testTokensAreThirtyTwoRandomBytes() {
        let tokens = (0..<100).map { _ in RelayRoute.mintToken() }
        XCTAssertEqual(Set(tokens).count, 100)
        for token in tokens {
            XCTAssertEqual(RemotePairing.decodeBase64url(token)?.count, 32)
            // The relay admits `^[A-Za-z0-9_-]{43,128}$`.
            XCTAssertEqual(token.count, 43)
            XCTAssertNil(token.rangeOfCharacter(from: CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").inverted))
        }
    }

    func testPresenceMatchesTheRelaysWords() {
        // Mirrors cloud/src/session.ts. A drifted word is a notice both sides
        // silently ignore.
        XCTAssertEqual(RelayPresence.allCases.map(\.rawValue),
                       ["mac-online", "mac-offline", "phone-online", "phone-offline"])
    }

    func testAckWithoutARelayStillDecodes() throws {
        // A Mac with no relay configured — and every Mac before this field.
        let json = #"{"appVersion":"1.0","hostName":"Mac","capabilities":["read"]}"#
        let payload = try JSONDecoder().decode(HelloAckPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.relay)
    }

    func testAckRelayRoundTrips() throws {
        let payload = HelloAckPayload(appVersion: "1.0", hostName: "Mac", capabilities: [.read],
                                      relay: RelayRoute(url: "wss://x.example", token: "abc"))
        let decoded = try JSONDecoder().decode(HelloAckPayload.self,
                                               from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded, payload)
    }
}

final class WriteClassificationTests: XCTestCase {
    func testWritesAndReads() {
        let id = UUID()
        for write: RPCMethod in [.replyToAgent(worktreeID: id, text: "x"),
                                 .answerPermission(worktreeID: id, allow: true),
                                 .interruptAgent(worktreeID: id),
                                 .setAgentInput(worktreeID: id, text: "x", seq: 1, submit: false),
                                 .approveAndMerge(worktreeID: id),
                                 .createPullRequest(worktreeID: id),
                                 .requestChanges(worktreeID: id, text: "x")] {
            XCTAssertTrue(write.isWrite, "\(write)")
        }
        for read: RPCMethod in [.listProjects, .fleetSummary, .reviewItems,
                                .monitorSummary(worktreeID: id), .attachTerminal(paneID: id),
                                .conversationMessages(conversationID: id, limit: 10)] {
            XCTAssertFalse(read.isWrite, "\(read)")
        }
    }
}
