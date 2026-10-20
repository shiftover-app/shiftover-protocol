import XCTest
@testable import ShiftoverProtocol

/// Collaborators (PLAN_52 Phase 2): which projects are the same repository,
/// and the one-use link that pairs two Macs.
final class CollaborationTests: XCTestCase {
    func testEveryFormOfARemoteNamesTheSameRepository() {
        let forms = ["git@github.com:Marko/9loops.git", "https://github.com/marko/9loops",
                     "https://marko:token@github.com/Marko/9loops.git/", "ssh://git@github.com:22/marko/9loops.git",
                     "ssh://git@github.com/marko/9loops", "  git@github.com:marko/9loops  "]
        for form in forms { XCTAssertEqual(RepoIdentity.normalizedOrigin(form), "github.com/marko/9loops", form) }
        XCTAssertNotEqual(RepoIdentity.normalizedOrigin("git@github.com:marko/other.git"), "github.com/marko/9loops")
        XCTAssertNotEqual(RepoIdentity.normalizedOrigin("git@gitlab.com:marko/9loops.git"), "github.com/marko/9loops")
        for local in ["/Users/marko/repos/9loops", "file:///Users/marko/9loops", "../9loops", "~/9loops", "", "github.com"] {
            XCTAssertNil(RepoIdentity.normalizedOrigin(local), local)
        }
    }

    func testProjectsMatchBySameRemoteOrASharedRootCommit() {
        let ssh = RepoIdentity(originURL: "git@github.com:marko/9loops.git", rootCommits: ["a1"])
        let https = RepoIdentity(originURL: "https://github.com/marko/9loops", rootCommits: [])
        let fork = RepoIdentity(originURL: "git@github.com:ann/9loops.git", rootCommits: ["a1", "b2"])
        let other = RepoIdentity(originURL: "git@github.com:marko/other.git", rootCommits: ["c3"])
        XCTAssertTrue(ssh.matches(https))
        XCTAssertTrue(ssh.matches(fork), "a fork shares the root commit")
        XCTAssertFalse(https.matches(fork), "nothing in common")
        XCTAssertFalse(ssh.matches(other))
        XCTAssertFalse(RepoIdentity(originHash: nil, rootCommits: []).matches(RepoIdentity(originHash: nil, rootCommits: [])),
                       "two unknown repositories are not the same one")
        XCTAssertEqual(RepoIdentity(originHash: nil, rootCommits: Array(repeating: "x", count: 20)).rootCommits.count, 8)
    }

    func testTheInvitationIsOneLinkWithItsSecretInTheFragment() throws {
        let now = Date()
        let route = try XCTUnwrap(RelayRoute.sharing(baseURL: "wss://relay.example"))
        let invite = CollaboratorInvitation(hostName: "Marko's Mac", address: "192.0.2.1", port: 4310,
                                            publicKey: Data(repeating: 1, count: 32), now: now, relay: route)
        for landing in [nil, URL(string: "https://example.invalid/collaborate")] {
            let url = try XCTUnwrap(invite.url(landingPage: landing))
            XCTAssertNil(url.query)
            XCTAssertEqual(CollaboratorInvitation.parse(url, now: now), invite)
            XCTAssertNil(CollaboratorInvitation.parse(url, now: now.addingTimeInterval(600)), "expired")
            XCTAssertNil(ShareInvitation.parse(url, now: now), "not a share link")
        }
        let share = ShareInvitation(projectID: UUID(), projectName: "P", hostName: "H", address: "192.0.2.1",
                                    port: 4310, publicKey: Data(repeating: 1, count: 32), now: now)
        XCTAssertNil(CollaboratorInvitation.parse(try XCTUnwrap(share.url()), now: now), "not a collaborator link")
        XCTAssertNil(CollaboratorInvitation.parse(URL(string: "shiftover://collaborate#garbage")!))
        let phoneRoute = RelayRoute(url: "wss://relay.example", token: route.token)
        let bad = CollaboratorInvitation(hostName: "M", address: "192.0.2.1", port: 4310,
                                         publicKey: Data(repeating: 1, count: 32), now: now, relay: phoneRoute)
        XCTAssertNil(CollaboratorInvitation.parse(try XCTUnwrap(bad.url()), now: now), "a phone route is not a sharing route")
    }

    func testRegisteringIsAConnectionScopedRead() {
        let method = RPCMethod.registerCollaborator(CollaboratorRoute(address: "192.0.2.2", port: 4310, relay: nil))
        XCTAssertEqual(method.guestScope, .connection)
        XCTAssertFalse(method.isWrite)
        XCTAssertFalse(CollaboratorRoute(address: "evil/../host", port: 1, relay: nil).isValid)
        XCTAssertFalse(CollaboratorRoute(address: "192.0.2.2", port: 0, relay: nil).isValid)
    }

    func testAProjectFromAnOlderMacHasNoIdentity() throws {
        let decoded = try JSONDecoder().decode(ProjectDTO.self, from: Data(#"{"id":"\#(UUID())","name":"9loops","isGit":true}"#.utf8))
        XCTAssertNil(decoded.repoIdentity)
        var project = ProjectDTO(id: UUID(), name: "9loops", isGit: true)
        project.repoIdentity = RepoIdentity(originURL: "git@github.com:marko/9loops.git", rootCommits: ["a1"])
        XCTAssertEqual(try JSONDecoder().decode(ProjectDTO.self, from: JSONEncoder().encode(project)), project)
    }
}
