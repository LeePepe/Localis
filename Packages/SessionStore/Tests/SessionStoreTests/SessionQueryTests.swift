import Foundation
import Testing

@testable import SessionStore

import LocalisModels

/// The composite-key red line (Amendment A §1.1, FR-029/FR-037):
/// a backend name like `claude` may exist on two machines at once, so every
/// query narrowed by backend MUST also carry the host. `SessionQuery` enforces
/// that in the type system — `hostID` is non-optional and no initializer takes
/// a `backendID` without one, so a backend-only query is unrepresentable rather
/// than merely discouraged.
@Suite("SessionQuery — composite (hostID, backendID) key")
struct SessionQueryTests {
    private static let hostA = HostID(rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    private static let hostB = HostID(rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)

    @Test("a host-only query does not narrow by backend")
    func hostOnlyQuery() {
        let query = SessionQuery(hostID: Self.hostA)

        #expect(query.hostID == Self.hostA)
        #expect(query.backendID == nil)
    }

    @Test("narrowing by backend keeps the host bound")
    func backendNarrowingKeepsHost() {
        let query = SessionQuery(hostID: Self.hostA, backendID: "claude")

        #expect(query.hostID == Self.hostA)
        #expect(query.backendID == "claude")
    }

    @Test("same backend name on two hosts produces two distinct queries")
    func sameBackendNameOnTwoHostsIsNotEqual() {
        let onA = SessionQuery(hostID: Self.hostA, backendID: "claude")
        let onB = SessionQuery(hostID: Self.hostB, backendID: "claude")

        #expect(onA != onB)
    }

    @Test("matching is scoped by host — a same-named backend on another host misses")
    func matchesIsHostScoped() {
        let query = SessionQuery(hostID: Self.hostA, backendID: "claude")

        #expect(query.matches(hostID: Self.hostA, backendID: "claude"))
        #expect(!query.matches(hostID: Self.hostB, backendID: "claude"))
        #expect(!query.matches(hostID: Self.hostA, backendID: "codex"))
    }

    @Test("a host-only query matches every backend on that host and none elsewhere")
    func hostOnlyMatching() {
        let query = SessionQuery(hostID: Self.hostA)

        #expect(query.matches(hostID: Self.hostA, backendID: "claude"))
        #expect(query.matches(hostID: Self.hostA, backendID: "codex"))
        #expect(!query.matches(hostID: Self.hostB, backendID: "claude"))
    }

    @Test("the orphan query is the unattributed host and matches only unattributed rows")
    func orphanQueryIsUnattributed() {
        #expect(SessionQuery.unattributed.hostID == .unattributed)
        #expect(SessionQuery.unattributed.isUnattributedQuery)
        #expect(SessionQuery(hostID: Self.hostA).isUnattributedQuery == false)

        #expect(SessionQuery.unattributed.matches(hostID: nil, backendID: "claude"))
        #expect(!SessionQuery.unattributed.matches(hostID: Self.hostA, backendID: "claude"))
    }

    @Test("a real host query never matches an unattributed session")
    func realHostQueryExcludesUnattributed() {
        #expect(!SessionQuery(hostID: Self.hostA).matches(hostID: nil, backendID: "claude"))
        #expect(!SessionQuery(hostID: Self.hostA).matches(hostID: .unattributed, backendID: "claude"))
    }
}
