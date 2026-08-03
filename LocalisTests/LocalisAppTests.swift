import Testing

@testable import Localis

/// App-target smoke test.
///
/// Layer logic is covered by the SPM package suites (`swift test`, seconds, no
/// simulator). This bundle exists so the app target itself is exercised by
/// `xcodebuild test` in CI — it is the wiring check, not the logic check.
@Suite("App target")
struct LocalisAppTests {
    @Test("the root view can be constructed")
    func rootViewConstructs() {
        _ = RootView()
    }
}
