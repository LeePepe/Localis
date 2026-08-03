import SwiftUI
import Testing

@testable import DesignKit

@Suite("Seed color system")
struct ColorSystemTests {
    @Test("all preset seeds parse to a hex")
    func seeds() {
        #expect(Seed.allCases.count == 5)
        #expect(Seed.blue.hex == "#0090FF")
        #expect(Seed.appleBlue.hex == "#007AFF")
    }

    @Test("primary palette makes a real WCAG contrast choice for onPrimary")
    func palette() {
        let light = makePrimaryPalette(seed: Seed.appleBlue.color, isDark: false)
        let dark = makePrimaryPalette(seed: Seed.appleBlue.color, isDark: true)

        #expect(light.onPrimary == .white || light.onPrimary == .black)
        #expect(dark.onPrimary == .white || dark.onPrimary == .black)
    }

    @Test("chart palette has 8 stops in both schemes")
    func charts() {
        #expect(chartPalette(seed: Seed.teal.color, isDark: false).count == 8)
        #expect(chartPalette(seed: Seed.teal.color, isDark: true).count == 8)
    }

    @Test("hex initializer round-trips a known color")
    func hexParsing() {
        #expect(Color(hex: "#FFFFFF") == Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 1))
        #expect(Color(hex: "000000") == Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1))
    }

    @Test("neutral palettes differ between light and dark")
    func neutralsDifferByScheme() {
        #expect(Neutral.slate.palette(isDark: false).bg != Neutral.slate.palette(isDark: true).bg)
        #expect(Neutral.neutral.palette(isDark: false).card != Neutral.neutral.palette(isDark: true).card)
    }
}

@Suite("Theme")
struct ThemeTests {
    @Test("theme resolves all three layers")
    func resolve() {
        let theme = Theme(seed: .purple, neutral: .neutral, isDark: true)

        #expect(theme.seed == .purple)
        #expect(theme.charts.count == 8)
        #expect(theme.chart(8) == theme.chart(0)) // wraps
    }

    @Test("semantic colors are fixed regardless of seed")
    func semanticFixed() {
        let a = Theme(seed: .blue, neutral: .slate, isDark: false)
        let b = Theme(seed: .orange, neutral: .slate, isDark: false)

        #expect(a.success == b.success) // green=good never breaks
        #expect(a.danger == b.danger)
        #expect(a.warning == b.warning)
    }

    @Test("the default theme is the Localis brand seed")
    func defaultSeed() {
        #expect(Theme().seed == .appleBlue)
        #expect(Theme().neutral == .slate)
    }
}
