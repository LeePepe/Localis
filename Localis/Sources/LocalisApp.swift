import DesignKit
import LocalisModels
import LocalisUI
import SessionStore
import SwiftUI

/// Localis — an iOS chat client for the AI agents running on your own machines.
@main
struct LocalisApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .designTheme()
        }
    }
}
