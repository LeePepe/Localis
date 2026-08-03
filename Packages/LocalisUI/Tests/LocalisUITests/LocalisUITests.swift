import Foundation
import Testing

@testable import LocalisUI

import LocalisModels

@Suite("SessionRowState")
struct SessionRowStateTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private static let hostA = HostID(rawValue: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
    private static let hostB = HostID(rawValue: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)

    /// The backends a session's own host advertises, keyed the only way that
    /// names one backend: `(hostID, backendID)`.
    private static func catalogue(
        _ entries: (host: HostID, id: String, name: String)...
    ) -> [BackendRef: AgentBackend] {
        Dictionary(
            uniqueKeysWithValues: entries.map { entry in
                let backend = makeBackend(id: entry.id, name: entry.name)
                return (backend.ref(on: entry.host), backend)
            }
        )
    }

    private static func makeBackend(id: String, name: String) -> AgentBackend {
        AgentBackend(id: id, displayName: name, capabilities: [.streaming])
    }

    private static func makeSession(
        backendID: String,
        messages: [Message],
        hostID: HostID = hostA,
        status: SessionStatus = .idle
    ) -> Session {
        Session(
            id: UUID(),
            hostID: hostID,
            backendID: backendID,
            title: "Session",
            messages: messages,
            createdAt: t0,
            updatedAt: t0,
            status: status
        )
    }

    @Test("preview shows the last message and the backend name")
    func projectsLastMessage() throws {
        let backendID = "claude-sonnet"
        let backend = Self.makeBackend(id: backendID, name: "MacBook Claude")
        let session = Self.makeSession(backendID: backendID, messages: [
            Message(id: UUID(), role: .user, text: "first", createdAt: Self.t0),
            Message(id: UUID(), role: .assistant, text: "second", createdAt: Self.t0)
        ])

        let row = SessionRowState.make(
            from: session,
            backends: [backend.ref(on: Self.hostA): backend]
        )

        #expect(row.preview == "second")
        #expect(row.backendName == "MacBook Claude")
        #expect(row.isStreaming == false)
    }

    @Test("an empty transcript reads as 'No messages yet'")
    func emptyTranscriptPlaceholder() throws {
        let backendID = "claude-sonnet"
        let session = Self.makeSession(backendID: backendID, messages: [])

        let row = SessionRowState.make(
            from: session,
            backends: Self.catalogue((Self.hostA, backendID, "Kimi"))
        )

        #expect(row.preview == "No messages yet")
    }

    @Test("a long preview is elided at the limit")
    func elidesLongPreview() throws {
        let backendID = "claude-sonnet"
        let long = String(repeating: "x", count: SessionRowState.previewLimit + 20)
        let session = Self.makeSession(backendID: backendID, messages: [
            Message(id: UUID(), role: .assistant, text: long, createdAt: Self.t0)
        ])

        let row = SessionRowState.make(
            from: session,
            backends: Self.catalogue((Self.hostA, backendID, "Kimi"))
        )

        #expect(row.preview.hasSuffix("…"))
        #expect(row.preview.count == SessionRowState.previewLimit + 1)
    }

    @Test("newlines are collapsed so the row stays one line")
    func collapsesNewlines() throws {
        let backendID = "claude-sonnet"
        let session = Self.makeSession(backendID: backendID, messages: [
            Message(id: UUID(), role: .assistant, text: "line1\nline2", createdAt: Self.t0)
        ])

        let row = SessionRowState.make(
            from: session,
            backends: Self.catalogue((Self.hostA, backendID, "Kimi"))
        )

        #expect(row.preview == "line1 line2")
    }

    @Test("a deleted backend falls back to a placeholder name")
    func unknownBackendFallback() {
        let session = Self.makeSession(backendID: "orphan-backend", messages: [])

        let row = SessionRowState.make(from: session, backends: [:])

        #expect(row.backendName == "Unknown agent")
    }

    @Test("a streaming last message marks the row as streaming")
    func detectsStreaming() throws {
        let backendID = "claude-sonnet"
        let session = Self.makeSession(backendID: backendID, messages: [
            Message(id: UUID(), role: .assistant, text: "par", createdAt: Self.t0, status: .streaming)
        ])

        let row = SessionRowState.make(
            from: session,
            backends: Self.catalogue((Self.hostA, backendID, "Kimi"))
        )

        #expect(row.isStreaming)
    }

    /// FR-029. Two machines each advertise a backend called `claude`; the row
    /// must name its *own* host's.
    ///
    /// This is not a hypothetical: the session list shipped this bug, and it was
    /// visible in the first screenshot of the assembled app — a laptop session
    /// labelled with the studio's backend name. It survived because the old
    /// signature took `[AgentBackend]`, a type with no host in it, so the
    /// host-blind lookup was the only lookup that could be written.
    @Test("same backend id on two hosts resolves to this session's host")
    func resolvesBackendPerHost() {
        let session = Self.makeSession(backendID: "claude", messages: [], hostID: Self.hostB)

        let row = SessionRowState.make(
            from: session,
            backends: Self.catalogue(
                (Self.hostA, "claude", "Studio Claude"),
                (Self.hostB, "claude", "Laptop Claude")
            )
        )

        #expect(row.backendName == "Laptop Claude")
    }

    /// The other direction: a backend id that exists, but only on a machine
    /// this session does not belong to, is not this session's backend.
    ///
    /// Without this, a lookup could pass the test above by preferring the last
    /// match rather than by matching on host at all.
    @Test("a backend belonging only to another host is not borrowed")
    func doesNotBorrowAnotherHostsBackend() {
        let session = Self.makeSession(backendID: "claude", messages: [], hostID: Self.hostB)

        let row = SessionRowState.make(
            from: session,
            backends: Self.catalogue((Self.hostA, "claude", "Studio Claude"))
        )

        #expect(row.backendName == "Unknown agent")
    }
}
