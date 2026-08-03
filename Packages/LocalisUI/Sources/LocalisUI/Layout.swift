import CoreGraphics

/// Layout constants from the porting contract that DesignKit does not yet own.
///
/// **This type is a placeholder for a gap, not a home.** The design system's own
/// rule is that one file owns the raw values and no view computes one; these
/// belong in `DesignKit`'s token set beside `Space` and `Radius`. They live here
/// only because DesignKit ships `Space.contentMaxWidth = 1200`, which is a
/// dashboard measure, and the contract asks for something different for reading.
///
/// Kept in a single file with the contract line quoted for each value, so the
/// migration is a move rather than a re-derivation, and so no `body` anywhere
/// gains a numeric literal in the meantime.
enum Layout {
    /// iPad reading measure: **~700pt, centred**.
    ///
    /// Contract §7: "Extra canvas buys context, never longer lines." The
    /// distinction from `Space.contentMaxWidth` (1200) is deliberate — that one
    /// is for dashboards, where the extra width carries more information; a
    /// transcript is prose, and prose gets harder to read as the measure grows.
    static let readingMeasure: CGFloat = 700

    /// Floating chrome inset, L/R/B: **21pt** (iOS 26 tab bar metric).
    static let chromeInset: CGFloat = 21

    /// Bottom edge fade: **132pt, fade only — no blur.**
    ///
    /// Contract §7 notes the top and bottom edges are deliberately not
    /// symmetric: the top uses blur plus fade, the bottom only fades.
    static let bottomFade: CGFloat = 132
}
