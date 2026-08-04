import Foundation
import SwiftData

/// Assembles the SwiftData container.
///
/// One decision is non-negotiable and lives here so it cannot be forgotten at a
/// call site: **CloudKit is off** (`cloudKitDatabase: .none`). Transcripts carry
/// code, paths, and whatever the user typed at their agent; constitution I keeps
/// all of it on the device.
public enum SessionStoreContainer {
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
        return try ModelContainer(for: schema, configurations: [configuration])
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
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
