import Testing

@testable import Localis

/// App-target assembly checks.
///
/// **This suite is RED on purpose until the assembly layer lands (#16).**
///
/// It replaces a test that constructed `RootView()` and called itself "the
/// wiring check". That test passed for as long as it existed, and what it
/// actually proved was that a view holding a hardcoded
/// `InMemorySessionRepository` can be initialised. Meanwhile `ChatService`,
/// `BridgeClient` and `SwiftDataSessionRepository` had never been constructed
/// in production at all.
///
/// A green test whose own doc comment says "wiring check" is worse than no
/// test: the next person looking for assembly coverage reads that line and
/// stops looking. Red says the true thing.
@Suite("App target assembly")
struct LocalisAppTests {
    @Test("the root view can be constructed")
    func rootViewConstructs() {
        // Kept from the old suite with its claim corrected. This is a smoke
        // test: it proves the view initialises, and nothing whatsoever about
        // what it is connected to.
        _ = RootView()
    }

    @Test("FAILS until the app assembles a real chat stack, not an in-memory stub")
    func appAssemblesRealDependencies() {
        // What has to become true for this to pass (#16, milestone A):
        //
        //   1. `RootView` stops hardcoding `InMemorySessionRepository()` and
        //      takes a `SwiftDataSessionRepository` over
        //      `SessionStoreContainer.onDisk()`.
        //   2. The app constructs a real `ChatService` on that same repository,
        //      so a sent turn is persisted by the code path that runs in
        //      production.
        //   3. `TranscriptView` and `ComposerView` are reachable from
        //      `LocalisApp` — today they have zero references outside their own
        //      package.
        //
        // The failure is recorded unconditionally rather than derived from some
        // inspectable flag. Anything cleverer would be a second thing that can
        // quietly start passing for the wrong reason, which is the exact defect
        // being corrected here. Real assertions over the composition root
        // replace this in the commit that builds it; `scripts/check-wiring.sh`
        // covers the same gap from the outside meanwhile.
        Issue.record(
            """
            The app target does not assemble its own layers. project.yml declares \
            ChatService, TransportKit and SkillsKit as app-target dependencies \
            and no file under Localis/Sources/ imports any of them; RootView \
            holds a hardcoded InMemorySessionRepository. Nothing the user types \
            can reach a real agent or survive a relaunch. Tracked as #16 — \
            delete this test in the commit that wires the composition root.
            """
        )
    }
}
