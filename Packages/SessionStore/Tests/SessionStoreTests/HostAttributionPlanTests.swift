import Foundation
import Testing

@testable import SessionStore

import LocalisModels

/// Migration must never lose a conversation (FR-038, Amendment A §1.7).
///
/// Sessions written before `hostID` existed have no host attribution. The
/// backfill rule is decided here as a pure function so it can be exhausted in a
/// table without a container:
///
/// - exactly one paired host → every legacy session belongs to it;
/// - zero or two-or-more → attribution is unknowable, so the sessions become
///   read-only (`orphaned`) and wait for the user. Never deleted.
@Suite("Host attribution backfill")
struct HostAttributionPlanTests {
    private static let hostA = HostID(rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    private static let hostB = HostID(rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)

    @Test("exactly one paired host backfills every legacy session to it")
    func singleHostBackfills() {
        #expect(HostAttributionPlan.resolve(pairedHosts: [Self.hostA]) == .backfill(Self.hostA))
    }

    @Test("no paired host leaves sessions orphaned rather than deleted")
    func noHostOrphans() {
        #expect(HostAttributionPlan.resolve(pairedHosts: []) == .orphan)
    }

    @Test("two or more paired hosts leave sessions orphaned — attribution is a guess")
    func ambiguousHostsOrphan() {
        #expect(HostAttributionPlan.resolve(pairedHosts: [Self.hostA, Self.hostB]) == .orphan)
    }

    @Test("the same host listed twice is still one host")
    func duplicateHostIDsAreDeduplicated() {
        #expect(HostAttributionPlan.resolve(pairedHosts: [Self.hostA, Self.hostA]) == .backfill(Self.hostA))
    }

    @Test("applying a backfill plan attributes a legacy session without dropping it")
    func backfillAssignsHost() {
        let plan = HostAttributionPlan.backfill(Self.hostA)

        #expect(plan.attribution(forLegacySessionWith: nil) == .attributed(Self.hostA))
    }

    @Test("applying an orphan plan marks read-only rather than deleting")
    func orphanPlanMarksReadOnly() {
        #expect(HostAttributionPlan.orphan.attribution(forLegacySessionWith: nil) == .orphaned)
    }

    @Test("a session that already has a host is never re-attributed")
    func alreadyAttributedIsUntouched() {
        // Even a plan that would backfill to A must leave a session already on B alone.
        let plan = HostAttributionPlan.backfill(Self.hostA)

        #expect(plan.attribution(forLegacySessionWith: Self.hostB) == .attributed(Self.hostB))
    }

    @Test("the unattributed marker does not count as an existing attribution")
    func unattributedMarkerIsNotAHost() {
        // Otherwise a legacy row — which projects as `.unattributed` — would look
        // already placed, and migration would never backfill it.
        let plan = HostAttributionPlan.backfill(Self.hostA)

        #expect(plan.attribution(forLegacySessionWith: .unattributed) == .attributed(Self.hostA))
    }

    @Test("no plan can ever produce a delete")
    func noPlanDeletes() {
        // Exhaustive: whatever the plan and whatever the prior attribution, the
        // outcome keeps the session. Deleting a conversation is only ever an
        // explicit user action (FR-027).
        let plans: [HostAttributionPlan] = [.backfill(Self.hostA), .orphan]
        for plan in plans {
            for existing in [nil, Self.hostB, HostID.unattributed] {
                let outcome = plan.attribution(forLegacySessionWith: existing)
                #expect(outcome.keepsSession)
            }
        }
    }
}
