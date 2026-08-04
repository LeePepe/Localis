# DesignKit — the porting contract

Everything `Packages/DesignKit` needs in order to implement this design system
in SwiftUI **without guessing**. The prototype is the reference implementation;
this file is the specification of it.

The rule that makes the rest work: **`tokens.js` is the only file in the
prototype where a hex literal may appear.** DesignKit should preserve that
property — one file owns the raw values, everything else consumes semantic
tokens. If a view file contains a color literal, that is a bug.

---

## 1. The pipeline

```
seed (ONE hex)  ─┬─→ primary palette   (10 tokens, HSB-derived)
                 └─→ chart palette      (8 tokens, hue-rotated)

neutral preset  ───→ surface + text     (7 tokens, fixed ramp)
                 └─→ glass + fade       (9 tokens, derived from the ramp)

fixed constants ───→ semantic           (3 tokens, NEVER seed-derived)
```

36 tokens total, all a pure function of `(seed, neutralPreset, isDark)`.
No token is hand-authored per screen; no view computes a color.

```swift
// The whole API surface, conceptually:
struct Tokens {
    static func build(seed: Color, neutral: NeutralPreset, dark: Bool) -> Tokens
}
```

## 2. Primary palette — derived, do not hand-pick

Convert the seed to HSB and derive. **Light and dark use different formulas**
— dark is not light with an inverted ramp.

| Token | Light | Dark |
|---|---|---|
| `primary` | `(h, s, b)` | `(h, s−0.05, b+0.06)` |
| `primaryHover` | `(h, s, b−0.08)` | `(h, s, b+0.08)` |
| `primaryActive` | `(h, s, b−0.14)` | `(h, s, b+0.14)` |
| `primarySubtle` | `(h, s×0.18, 0.97)` | `(h, s×0.45, 0.18)` |
| `primaryMuted` | `(h, s×0.4, 0.90)` | `(h, s×0.5, 0.26)` |
| `primaryBorder` | `(h, s×0.55, 0.80)` | `(h, s×0.55, 0.36)` |
| `primaryText` | `(h, min(1, s+0.1), b−0.2)` | `(h, s×0.7, b+0.28)` |
| `onPrimary` | WCAG pick — see below | same |
| `onPrimarySubtle` | = `primaryText` | = `primaryText` |
| `ring` | = `primary` | = `primary` |

All S and B values clamp to `[0, 1]` **after** the arithmetic, not before.

`onPrimary` is computed, never assumed — but **not** by the naive "whichever
of black/white scores higher":

```
L = 0.2126·lin(r) + 0.7152·lin(g) + 0.0722·lin(b)
    where lin(x) = x ≤ 0.03928 ? x/12.92 : ((x+0.055)/1.055)^2.4

whiteContrast = 1.05 / (L + 0.05)
onPrimary     = whiteContrast ≥ 3.0 ? white : black
```

**Why the 3.0 floor rather than the higher ratio.** On Apple Blue the pure
comparison picks *black* (5.23 vs 4.02 for white). That passes WCAG and still
looks broken — every platform ships white on blue, and users read black as a
rendering fault. 3.0 is the WCAG floor for large/bold text, which is what a
filled button label is. The result is correct across the range:

| Seed | white | black | Picks |
|---|---|---|---|
| appleBlue `#007AFF` | 4.02 | 5.23 | **white** |
| purple `#8E4EC6` | 5.18 | 4.06 | **white** |
| teal `#12A594` | 3.07 | 6.84 | **white** |
| orange `#F76B15` | 2.97 | 7.07 | **black** |
| yellow `#F7E600` | 1.29 | 16.27 | **black** |

Do not hardcode white: a light seed is a supported choice and must yield black.
This was a real bug found in the prototype — the naive rule was rendering black
labels on Apple Blue.

**Preset seeds:** `appleBlue #007AFF` (default), `blue #0090FF`,
`purple #8E4EC6`, `teal #12A594`, `orange #F76B15`.

## 3. Semantic colors — fixed, never derived

These carry meaning, so they must not move when the seed does. A "success"
that shifts hue with branding is no longer a signal.

| | Light | Dark |
|---|---|---|
| `success` | `#34C759` | `#30D158` |
| `warning` | `#FF9500` | `#FF9F0A` |
| `danger` | `#FF3B30` | `#FF453A` |

Apple's system values, deliberately.

## 4. Neutrals — two presets, fixed ramps

`slate` (default) and `neutral`. Seven values each per mode:
`bg` `card` `inner` `text1` `text2` `text3` `border`.

Elevation for **in-flow** surfaces is the luminance tier `bg < card < inner`
plus a 1px `border`, and **no shadow**. See §6 for the one exception.

```
slate light   bg #F9F9FB  card #FFFFFF  inner #F0F0F3
              text1 #1C2024  text2 #60646C  text3 #80838D  border #D9D9E0
slate dark    bg #111113  card #18191B  inner #212225
              text1 #EDEEF0  text2 #B0B4BA  text3 #777B84  border #363A3F
neutral light bg #FAFAFA  card #FFFFFF  inner #F5F5F5
              text1 #171717  text2 #525252  text3 #737373  border #E5E5E5
neutral dark  bg #171717  card #262626  inner #2E2E2E
              text1 #FAFAFA  text2 #A3A3A3  text3 #737373  border #404040
```

## 5. Chart palette — backend identity by hue

Backends are identified by hue, from **the same seed** — not a second palette.
Rotate the seed hue by these degree offsets, then apply fixed S/B:

```
offsets = [0, −15, 40, 95, 130, 175, −70, 210]
light:  S 0.72  B 0.62
dark:   S 0.66  B 0.82
```

Assignment is stable per backend name (`claude → 1`, `openclaw → 3`,
`hermes → 4`, `kimi → 6`, `codex → 8`), so a backend keeps its color across
hosts and launches. Two machines running Claude show the *same* hue — they are
disambiguated by the host name, never by color. See §8.

## 6. Liquid Glass — two grades, chosen by content

**This is the one place the flat-elevation rule is overridden, and only for
floating chrome.** In-flow surfaces (cards, list rows, sheets, fields) stay
flat: a card is not glass.

Floating chrome is an exhaustive list — tab bar, create island, activated
search field, chat composer, host switcher pill. **Anything else that grows a
shadow is a bug.**

```
--glass          card @ 0.70 light / 0.58 dark
--glass-solid    card @ 0.92 light / 0.88 dark
--glass-line     text1 @ 0.09 light / 0.00 dark
--glass-highlight  card @ 0.85 light / text1 @ 0.16 dark
--glass-shadow   light: 0 8px 24px text1@0.14, 0 1px 2px text1@0.08
                 dark:  0 8px 26px black@0.55, 0 1px 3px black@0.40
--fade-0/1/2     bg @ 0 / 0.78 / 0.97 light — 0 / 0.72 / 0.96 dark
```

Material: `blur(28px) saturate(180%)` → `.ultraThinMaterial` plus a tint;
match the measured opacities above rather than accepting the system default.

**Which grade to use is decided by content type, not aesthetics:**

- `--glass` — short, high-contrast content: tab labels, an icon, a status pill.
- `--glass-solid` — **running text you read or edit**: the search field, the
  chat composer, the backend picker menu.

The second grade exists because Liquid Glass's documented failure mode is body
copy over a busy backdrop. **Where legibility and material consistency
conflict, legibility wins.** This is a deliberate deviation from uniform
material and it must survive into DesignKit.

Two further contrast guards to carry over: the selected tab sits on a tinted
capsule (`primary @ 14%`) rather than relying on accent color against a moving
backdrop; and the specular edge is a **single hairline** (`border-top`), not a
gradient wash that would lower contrast across the whole surface.

**Accessibility:** under Reduce Transparency, both grades become opaque `card`.
The layout must not depend on seeing through anything.

## 7. Layout constants

| | Value | Why |
|---|---|---|
| Floating chrome inset | **21pt** L/R/B | iOS 26 tab bar metric |
| Tab bar height | 56pt (46pt minimized) | |
| Tab label | ~11pt SF | iOS 26 metric |
| Create island | 56×56pt capsule | |
| Bottom edge fade | 132pt, **fade only — no blur** | Top edge uses blur + fade; they are not symmetric |
| iPad reading measure | **~700pt**, centred | Extra canvas buys context, never longer lines |
| iPad sidebar | 352pt | |
| Corner radii | card 14 · inner 10 · control 8 · capsule 999 | |

## 8. Non-negotiables that are not colors

1. **Status is always a colored pill**, never grey text. One vocabulary:
   `connected` · `streaming` · `idle` · `error`/`offline`. Dot plus label —
   never color alone, so it survives color-blindness and greyscale.
2. **All numbers are tabular** (`.monospacedDigit()`). Latency, counts,
   elapsed time, timestamps.
3. **A backend is never named without its host.** Identity is
   `(hostId, backendName)`; render as `Claude · mac-studio` with the host in
   mono. Two machines can both run Claude.
4. **Three type levels minimum** on any information-carrying row.
5. **Host marks are square-ish and neutral**; backend badges are
   round-cornered and tinted. A machine must never be mistakable for an AI.
   (Where this document says "host" it means the UI concept — the domain type
   is `LocalisHost`, renamed by `core` to avoid colliding with
   `Foundation.Host`. Nothing visual depends on the name.)
6. **No hardcoded user-facing strings** — same rule as colors.
7. **Telemetry renders by field presence.** A value the backend does not report
   makes its row disappear; never render a placeholder slot for data that may
   never arrive, because a permanent "not available" implies it is coming.
8. **Where two states carry asymmetric cost, they differ in available
   actions, not just styling.** `detached` (host still running) must not render
   a retry control at all — restyling it would still let a mis-tap start a
   second job on the user's machine.

## 9. Where the prototype's own rules live

| File | Owns |
|---|---|
| `tokens.js` | every hex literal; the full derivation |
| `styles.css` | flat in-flow components |
| `glass.css` | the entire iOS 26 delta |
| `pad.css` | the entire iPhone → iPad delta |
| `activity.css` | activity / return-to-app components |
| `viewer.css` | the review harness — **does not ship** |

`glass.css` and `pad.css` are separate precisely so they can be read as specs
rather than diffed out of a larger file.

---

## 10. Type ramp — from `design/hifi/type.js`

Every step maps to an iOS text style, so Dynamic Type works by default rather
than being retrofitted. `swift` is the exact call.

| Step | pt / line | Weight | Track | SwiftUI | Use |
|---|---|---|---|---|---|
| display | 34 / 41 | 700 | −0.4 | `.largeTitle.weight(.bold)` | Screen large titles |
| title1 | 28 / 34 | 700 | −0.3 | `.title.weight(.bold)` | Empty-state headline |
| title2 | 22 / 28 | 650 | −0.2 | `.title2.weight(.semibold)` | Sheet titles |
| headline | 17 / 22 | 600 | 0 | `.headline` | Row titles, nav title |
| body | 17 / 24 | 400 | 0 | `.body` | **Message text — the only long-form style** |
| callout | 16 / 21 | 400 | 0 | `.callout` | Composer, search field |
| subhead | 15 / 20 | 400 | 0 | `.subheadline` | Row previews |
| footnote | 13 / 18 | 400 | 0 | `.footnote` | Row metadata |
| caption | 12 / 16 | 400 | 0 | `.caption` | Timestamps, pill labels |
| tabLabel | 11 / 13 | 500 | +0.06 | `.caption2.weight(.medium)` | Tab bar |
| sectionLabel | 11 / 14 | 650 | +0.7 CAPS | `.caption2.weight(.semibold)` | LIVE, RECENT |
| mono | 12 / 17 | 500 | +0.2 | `.system(.caption, design: .monospaced)` | Host names, numerics |
| code | 13 / 19 | 400 | 0 | `.system(.footnote, design: .monospaced)` | Code blocks |

**Tracking is 0 almost everywhere.** Only three cases deviate, each for a
reason: display sizes get a small negative (SF Pro's optical sizing does not
fully compensate at large sizes); all-caps gets a positive (caps remove the
word-shape cue, so letters need air); mono gets a touch (digits otherwise
collide). Tracking every step is a common way to make text look designed and
read worse.

**Monospace is semantic, not decorative.** It marks machine-generated text — a
hostname, a path, a number the machine reported. If a value was typed by a
human it is not mono.

**`mono`, `caption` and `footnote` are tabular** (`.monospacedDigit()`). A
latency readout that reflows between 8ms and 88ms reads as instability in the
connection rather than in the typography.

## 11. Icons — SF Symbols, named

The hi-fi mockup draws SVG paths so it renders in a browser. **The app should
use the SF Symbol**, which gets Dynamic Type, optical alignment and weight
matching for free. The mapping is the deliverable:

| Meaning | SF Symbol |
|---|---|
| Sessions tab | `bubble.left.and.bubble.right` |
| Settings tab | `gearshape` |
| Search | `magnifyingglass` |
| New session | `plus` |
| Send | `arrow.up` |
| Stop generating | `stop.fill` |
| Back | `chevron.left` |
| Disclosure | `chevron.right` |
| Menu / switcher | `chevron.down` |
| Selected | `checkmark` |
| Skills | `slash.forward` |
| Retry | `arrow.clockwise` |
| Session info | `info.circle` |
| Host · mac | `desktopcomputer` |
| Host · laptop | `laptopcomputer` |
| Host · NAS | `externaldrive` |
| Host · VPS | `cloud` |
| Tool call | `wrench.and.screwdriver` |
| Sidebar toggle (iPad) | `sidebar.leading` |

Stroked, not filled, at 16–24pt: a stroked glyph holds its shape against a
translucent backdrop where a filled one becomes a blob. Two exceptions where
mass *is* the signal: `stop.fill` and the status dot.

## 12. Motion — two durations, two curves

```
--dur-fast   140ms   presses, row highlights
--dur-base   260ms   sheet and panel transitions
--ease-out   cubic-bezier(0.2, 0.9, 0.3, 1)
--ease-spring cubic-bezier(0.34, 1.3, 0.5, 1)   — press feedback only
```

**Continuous motion is spent in exactly two places**, because it is a strong
signal and using it decoratively devalues it:

1. The streaming caret (1.05s, stepped — a blink, not a fade).
2. The `streaming` status dot (1.6s breathe). Idle dots do not move.

Everything else is transition-on-interaction. Under **Reduce Motion**, all of
it is disabled — every animated state is *also* conveyed statically by a pill
label or a glyph, so nothing is lost.

## 13. Accessibility floors

- **Reduce Transparency**: both glass grades collapse to opaque `card`; edge
  fades are removed. **The accent island keeps its fill** — it was never
  translucent, and draining it would remove the app's only accent-filled
  control. Reduced transparency asks for opacity, not for loss of hierarchy.
- **Reduce Motion**: as above.
- **Hit targets ≥ 44×44pt**, enforced by an expanded tappable region rather
  than by padding, so a small glyph can stay visually small.
- **Focus ring** on every interactive element (`--ring`, 2pt, 2pt offset).
  Not optional: iPad has hardware keyboards.
- **Status is never color alone** — always a dot *and* a label.
- **Hairlines are 0.5pt** on retina, not 1pt.
