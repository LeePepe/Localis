import Foundation
import SwiftData
import Testing

@testable import SessionStore

/// Guards the serial gate in `SessionStoreContainer`, not the crash itself.
///
/// The crash this package used to take — SIGSEGV inside CoreData's
/// `createTriggersForEntities:` when two `ModelContainer` builds raced — cannot
/// be asserted on directly. It kills the process, so there is nothing left to
/// report, and it is probabilistic: ~2 in 30 full-suite runs. A test that just
/// built containers in parallel and expected no crash would pass whether or not
/// the gate existed. That version was written first and ran 4,800 parallel
/// builds without once reproducing the failure, while the untouched suite
/// crashed twice in 30 runs — the synthetic shape was not the failing shape.
///
/// So this asserts the mechanism instead: construction is mutually exclusive.
/// Remove the lock and `maxObserved` climbs above 1 and this fails
/// deterministically, which is the property the crash repro could not offer.
///
/// `.serialized` because both tests install into the same static observer; run
/// in parallel, one test's teardown clears the other's probe and it silently
/// measures nothing. A `maxObserved` of 0 means the probe never ran — that is a
/// broken test, not a passing one, and the assertion is written to catch it.
@Suite("Container construction is serialized", .serialized)
struct ContainerConcurrencyTests {
    /// Counts how many builds are inside the critical section at once.
    ///
    /// `sample()` is called from inside the factory's lock, holds its own lock
    /// long enough to be seen by any concurrent sampler, and records the peak.
    /// Under a working gate the peak is 1; without one it climbs.
    private final class OverlapProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var maxObserved = 0

        func sample() {
            lock.lock()
            current += 1
            maxObserved = max(maxObserved, current)
            lock.unlock()

            // Stay inside the caller's critical section long enough that a
            // second builder, if one were admitted, would overlap observably.
            Thread.sleep(forTimeInterval: 0.002)

            lock.lock()
            current -= 1
            lock.unlock()
        }
    }

    @Test("concurrent builds never overlap inside the factory")
    func buildsDoNotOverlap() async throws {
        let probe = OverlapProbe()
        let width = 32
        SessionStoreContainer.duringConstruction = { probe.sample() }
        defer { SessionStoreContainer.duringConstruction = nil }

        let containers = try await withThrowingTaskGroup(of: ModelContainer.self) { group in
            for _ in 0..<width {
                group.addTask { try SessionStoreContainer.inMemory() }
            }
            var built: [ModelContainer] = []
            for try await container in group { built.append(container) }
            return built
        }

        #expect(containers.count == width)
        #expect(
            probe.maxObserved == 1,
            """
            \(probe.maxObserved) container builds ran concurrently. CoreData's \
            derived-attribute trigger setup is not thread-safe; overlapping \
            builds corrupt an unsynchronized dictionary and take SIGSEGV.
            """
        )
    }

    @Test("on-disk builds take the same gate")
    func onDiskBuildsTakeTheGate() async throws {
        let probe = OverlapProbe()
        let width = 12
        SessionStoreContainer.duringConstruction = { probe.sample() }
        defer { SessionStoreContainer.duringConstruction = nil }
        let directory = URL.temporaryDirectory
            .appending(path: "localis-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let containers = try await withThrowingTaskGroup(of: ModelContainer.self) { group in
            for index in 0..<width {
                let url = directory.appending(path: "store-\(index).sqlite")
                group.addTask { try SessionStoreContainer.onDisk(at: url) }
            }
            var built: [ModelContainer] = []
            for try await container in group { built.append(container) }
            return built
        }

        #expect(containers.count == width)
        #expect(probe.maxObserved == 1, "on-disk factory bypassed the construction lock")
    }
}
