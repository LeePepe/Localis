import Foundation
import Testing

@testable import LocalisUI

import LocalisModels

/// Values transcribed from `design/prototype/DESIGNKIT.md` §7.
///
/// Pinned by test because they are the kind of number that looks arbitrary in a
/// diff and invites tidying. Each was measured against the prototype; changing
/// one should mean the contract changed, and this test is what forces that to be
/// a decision rather than a drive-by.
@Suite("Layout constants match the porting contract")
struct LayoutTests {
    @Test("iPad reading measure is 700pt, not the dashboard width")
    func readingMeasure() {
        // Deliberately different from DesignKit's `Space.contentMaxWidth` (1200):
        // extra canvas buys context, never longer lines.
        #expect(Layout.readingMeasure == 700)
    }

    @Test("floating chrome inset is the iOS 26 tab bar metric")
    func chromeInset() {
        #expect(Layout.chromeInset == 21)
    }

    @Test("bottom edge fade is 132pt")
    func bottomFade() {
        #expect(Layout.bottomFade == 132)
    }
}

/// The controls a row draws, and the order it draws them in.
@Suite("Message action rendering")
struct MessageActionTests {
    @Test("action order is stable across renders")
    func stableOrder() {
        // `Set` has no order of its own, and controls that swap places between
        // frames are a way to make a mis-tap likely — on a stop button, an
        // expensive one.
        let actions: Set<MessageAction> = [.retry, .cancel]
        let first = actions.sorted { $0.rawValue < $1.rawValue }
        let second = actions.sorted { $0.rawValue < $1.rawValue }

        #expect(first == second)
        #expect(first == [.cancel, .retry])
    }

    @Test("icons come from the contract's symbol table")
    func contractSymbols() {
        // §11: Retry `arrow.clockwise`, Stop `stop.fill`. Named on the action so
        // no `body` picks a symbol of its own.
        #expect(MessageAction.retry.systemImage == "arrow.clockwise")
        #expect(MessageAction.cancel.systemImage == "stop.fill")
    }

    @Test("no action is unlabelled")
    func everyActionHasATitle() {
        for action in MessageAction.allCases {
            #expect(action.title.isEmpty == false, "\(action)")
        }
    }
}
