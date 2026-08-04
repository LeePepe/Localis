import Foundation
import SwiftData

/// Assembles the SwiftData container.
///
/// One decision is non-negotiable and lives here so it cannot be forgotten at a
/// call site: **CloudKit is off** (`cloudKitDatabase: .none`). Transcripts carry
/// code, paths, and whatever the user typed at their agent; constitution I keeps
/// all of it on the device.
public enum SessionStoreContainer {
    /// Serializes container construction across the process.
    ///
    /// `ModelContainer(for:configurations:)` ends up in CoreData's
    /// `createTriggersForEntities:`, which builds each entity's derived-attribute
    /// trigger SQL into an `NSMutableDictionary` without synchronization. Two
    /// builds reaching that dictionary at once corrupt it and the process takes
    /// SIGSEGV inside `-[__NSDictionaryM setObject:forKey:]` — it does not throw,
    /// so no caller can catch it and no test can report it.
    ///
    /// The app builds exactly one container at launch, so this lock is never
    /// contended in production. It is here rather than at the call sites because
    /// the crash is in CoreData's own state, not in any one caller's: a gate that
    /// only some callers took would still leave the dictionary racing.
    private static let constructionLock = NSLock()

    /// Every entity the store persists.
    public static let schema = Schema([
        StoredSession.self,
        StoredMessage.self,
        StoredBackend.self,
        StoredHost.self,
    ])

    /// On-disk container for the app.
    ///
    /// - Parameter url: override for the store file; defaults to SwiftData's
    ///   standard location.
    public static func onDisk(at url: URL? = nil) throws -> ModelContainer {
        let configuration =
            if let url {
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            } else {
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
            }
        return try makeContainer(configuration)
    }

    /// In-memory container for tests and previews.
    ///
    /// Same schema and the same CloudKit setting as production — a test
    /// container that differed in either would be testing a different store.
    public static func inMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try makeContainer(configuration)
    }

    /// The one place a `ModelContainer` is constructed.
    ///
    /// Both factories funnel here so the lock cannot be bypassed by adding a
    /// third one later.
    private static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
        constructionLock.lock()
        defer { constructionLock.unlock() }
        duringConstruction?()
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Run inside the construction lock. Tests only.
    ///
    /// Mutual exclusion is not observable from outside the factory: a probe
    /// wrapped around the call counts callers *waiting* for the lock, and those
    /// overlap by design. Proving the lock is held — rather than merely present
    /// in the source — needs a vantage point inside the critical section.
    nonisolated(unsafe) static var duringConstruction: (() -> Void)?
}
