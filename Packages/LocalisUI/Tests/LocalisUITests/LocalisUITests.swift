import Foundation
import Testing

@testable import LocalisUI

import LocalisModels

@Suite("SessionRowState")
struct SessionRowStateTests {
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private static func makeBackend(id: UUID, name: String) throws -> AgentBackend {
        AgentBackend(
            id: id,
            kind: .claude,
            name: name,
            endpoint: try #require(URL(string: "http://127.0.0.1:8080"))
        )
    }

    private static func makeSession(backendID: UUID, messages: [Message]) -> Session {
        Session(
            id: UUID(),
            backendID: backendID,
            title: "Session",
            messages: messages,
            createdAt: t0,
            updatedAt: t0
        )
    }

    @Test("preview shows the last message and the backend name")
    func projectsLastMessage() throws {
        let backendID = UUID()
        let backend = try Self.makeBackend(id: backendID, name: "MacBook Claude")
        let session = Self.makeSession(backendID: backendID, messages: [
            Message(id: UUID(), role: .user, text: "first", createdAt: Self.t0),
            Message(id: UUID(), role: .assistant, text: "second", createdAt: Self.t0)
        ])

        let row = SessionRowState.make(from: session, backends: [backend])

        #expect(row.preview == "second")
        #expect(row.backendName == "MacBook Claude")
        #expect(row.isStreaming == false)
    }

    @Test("an empty transcript reads as 'No messages yet'")
    func emptyTranscriptPlaceholder() throws {
        let backendID = UUID()
        let session = Self.makeSession(backendID: backendID, messages: [])

        let row = SessionRowState.make(
            from: session,
            backends: [try Self.makeBackend(id: backendID, name: "Kimi")]
        )

        #expect(row.preview == "No messages yet")
    }

    @Test("a long preview is elided at the limit")
    func elidesLongPreview() throws {
        let backendID = UUID()
        let long = String(repeating: "x", count: SessionRowState.previewLimit + 20)
        let session = Self.makeSession(backendID: backendID, messages: [
            Message(id: UUID(), role: .assistant, text: long, createdAt: Self.t0)
        ])

        let row = SessionRowState.make(
            from: session,
            backends: [try Self.makeBackend(id: backendID, name: "Kimi")]
        )

        #expect(row.preview.hasSuffix("…"))
        #expect(row.preview.count == SessionRowState.previewLimit + 1)
    }

    @Test("newlines are collapsed so the row stays one line")
    func collapsesNewlines() throws {
        let backendID = UUID()
        let session = Self.makeSession(backendID: backendID, messages: [
            Message(id: UUID(), role: .assistant, text: "line1\nline2", createdAt: Self.t0)
        ])

        let row = SessionRowState.make(
            from: session,
            backends: [try Self.makeBackend(id: backendID, name: "Kimi")]
        )

        #expect(row.preview == "line1 line2")
    }

    @Test("a deleted backend falls back to a placeholder name")
    func unknownBackendFallback() {
        let session = Self.makeSession(backendID: UUID(), messages: [])

        let row = SessionRowState.make(from: session, backends: [])

        #expect(row.backendName == "Unknown agent")
    }

    @Test("a streaming last message marks the row as streaming")
    func detectsStreaming() throws {
        let backendID = UUID()
        let session = Self.makeSession(backendID: backendID, messages: [
            Message(id: UUID(), role: .assistant, text: "par", createdAt: Self.t0, status: .streaming)
        ])

        let row = SessionRowState.make(
            from: session,
            backends: [try Self.makeBackend(id: backendID, name: "Kimi")]
        )

        #expect(row.isStreaming)
    }
}
