import Foundation
import LocalisModels
import SessionStore

/// Writes a small transcript into the real store, for screenshots only.
///
/// **Why this exists rather than a stubbed view.** The transcript and composer
/// can only be *seen* when a session exists, and a fresh install has none. The
/// tempting shortcut is to hand `SessionDetailView` some hardcoded messages —
/// but that would photograph the views, not the assembly, and the whole point
/// of this milestone is to show the layers actually connected. So the seed goes
/// in through `SessionRepository` like any other write: if the store, the
/// projections, or the navigation are broken, the screenshot is broken too.
///
/// **Why it cannot fire in production.** It runs only when the process was
/// launched with `-LocalisDemoSeed`, which is a launch argument the App Store
/// build has no way to receive — arguments come from Xcode schemes, `simctl
/// launch`, and XCUIApplication, none of which exist for a user-installed app.
/// The gate is one condition, checked in one place, so there is nothing to keep
/// in sync.
enum DemoSeed {
    /// The launch argument that turns seeding on. Pass to `simctl launch` after
    /// the bundle id: `xcrun simctl launch <device> com.leepepe.localis
    /// -LocalisDemoSeed`.
    static let launchArgument = "-LocalisDemoSeed"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Opens the first seeded session on launch, so the transcript can be
    /// screenshotted without a tap.
    ///
    /// Kept separate from `launchArgument` because it answers a different
    /// question — one seeds, one navigates — and a single flag that did both
    /// would make "seeded but stayed on the list" unexpressible.
    ///
    /// It pushes a value onto the same `NavigationPath` a tap would push, so
    /// the screen it reveals is reached through `navigationDestination` and the
    /// real repository, not around them. Nothing here fabricates a transcript.
    static let openFirstArgument = "-LocalisDemoOpenFirst"

    static var opensFirstSession: Bool {
        ProcessInfo.processInfo.arguments.contains(openFirstArgument)
    }

    /// Seeds two sessions if the store is empty, and returns quietly otherwise.
    ///
    /// Idempotent by emptiness rather than by id: relaunching the simulator
    /// repeatedly should not stack up duplicates, and a store the developer has
    /// since typed into should not be overwritten by fixtures.
    static func populateIfEmpty(_ repository: any SessionRepository) async {
        do {
            guard try await repository.allSessions().isEmpty else { return }
            for (host, backend, session) in fixtures() {
                try await repository.save(backend, on: host)
                try await repository.create(session)
            }
        } catch {
            // Deliberately silent, and deliberately not fatal. A failed seed
            // leaves the app on its real empty state — which is a true thing to
            // show — whereas crashing would lose the very screen we came for.
        }
    }

    /// Two hosts whose backends share the id `claude`.
    ///
    /// Not decoration: FR-029 says a backend id is unique only within a machine,
    /// and this fixture is the one place a screenshot can show the list
    /// resolving those two to different display names. A single-host fixture
    /// would look identical whether or not the host scoping worked.
    private static func fixtures() -> [(HostID, AgentBackend, Session)] {
        let studio = HostID()
        let laptop = HostID()
        let start = Date(timeIntervalSince1970: 1_754_200_000)

        return [
            (
                studio,
                AgentBackend(id: "claude", displayName: "Studio Claude"),
                Session(
                    id: UUID(),
                    hostID: studio,
                    backendID: "claude",
                    title: "Refactor TransportKit",
                    messages: [
                        Message(
                            id: UUID(),
                            role: .user,
                            text: "Split the SSE parser out of the client so it can be tested without a socket.",
                            createdAt: start
                        ),
                        Message(
                            id: UUID(),
                            role: .assistant,
                            text: """
                                Done — the parser is now a pure value type that takes bytes and \
                                returns events, so the client keeps the socket and nothing else. \
                                The reconnect path got simpler as a result: it replays the cursor \
                                through the same parser instead of having its own copy.
                                """,
                            createdAt: start.addingTimeInterval(6)
                        ),
                        Message(
                            id: UUID(),
                            role: .user,
                            text: "Does that keep the resume cursor across a background suspend?",
                            createdAt: start.addingTimeInterval(90)
                        )
                    ],
                    createdAt: start,
                    updatedAt: start.addingTimeInterval(90),
                    status: .idle
                )
            ),
            (
                laptop,
                AgentBackend(id: "claude", displayName: "Laptop Claude"),
                Session(
                    id: UUID(),
                    hostID: laptop,
                    backendID: "claude",
                    title: "Weekend notes",
                    messages: [],
                    createdAt: start.addingTimeInterval(-86_400),
                    updatedAt: start.addingTimeInterval(-86_400),
                    status: .disconnected
                )
            )
        ]
    }
}
