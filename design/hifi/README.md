# Localis — 设计图 (hi-fi)

The visual design, built on the approved prototype.

```bash
open design/hifi/index.html
```

## What this is, and what it is not

The prototype (`design/prototype/`) settled **structure, hierarchy, IA and
state** and deliberately refused visual treatment — dashed icon placeholders,
ad-hoc type sizes, flat surfaces. It was approved on that basis.

This layer supplies the visual design **on top of that exact structure**. It
loads the prototype's own stylesheets and renders the prototype's own screens,
then layers type, icons, material and motion over them. That is deliberate:
the two versions are literally the same markup, so they cannot drift. **If a
layout moved between the two, that is a bug here, not an improvement** — the
prototype is the approved artefact.

## What hi-fi adds

| | Prototype | 设计图 |
|---|---|---|
| Type | ad-hoc px sizes | 13-step ramp, every step mapped to an iOS text style |
| Icons | dashed placeholder boxes | drawn glyphs, each mapped to a named SF Symbol |
| Elevation | one soft shadow | contact + ambient shadow, specular top rim |
| Motion | none | two durations, two curves — continuous motion in exactly 2 places |
| Hairlines | 1px | 0.5px on retina |
| Density | approximate | 4pt grid throughout |
| Accessibility | asserted | Reduce Transparency is a **toggle in the viewer** |

## The viewer

Same controls as the prototype, plus one: **Transparency · Normal / Reduced**.

That toggle exists because "the layout does not depend on translucency" is a
claim, and claims in a design review should be checkable rather than taken on
trust — the same reason screen 01b draws the keyboard. Flip it and the glass
grades collapse to opaque, the edge fades disappear, and the layout does not
move.

One thing deliberately survives that toggle: **the accent island keeps its
fill.** It was never translucent — it is a solid primary surface — and draining
it to grey would remove the app's only accent-filled control. Reduce
Transparency asks for opacity, not for a loss of hierarchy.

## Decisions this layer makes

1. **Continuous motion is spent in exactly two places** — the streaming caret
   and the `streaming` status dot. Motion is a strong signal for "happening
   now", and spending it on decoration would devalue it everywhere. Idle dots
   do not move. Everything else animates only in response to a touch.

2. **Monospace is semantic.** It marks machine-generated text: a hostname, a
   path, a number the machine reported. If a human typed it, it is not mono.
   This is why host names are mono and session titles are not.

3. **Tracking is 0 almost everywhere.** Three deviations, each with a reason
   (see `DESIGNKIT.md` §10). Tracking every step is a common way to make text
   look designed and read worse.

4. **Icons are stroked, not filled**, at the sizes used here — a stroked glyph
   holds its shape against a translucent backdrop where a filled one becomes a
   blob. Two exceptions where mass *is* the signal: stop, and the status dot.

5. **Wireframe annotations are gone.** The prototype captioned affordances in
   the artwork ("swipe → rename · delete") because a wireframe has to explain
   what it is not drawing. A finished design shows the gesture instead of
   labelling it.

6. **Two shadows, not one.** A tight contact shadow anchors a floating element
   to the surface; a wide ambient one gives it height. A single shadow always
   reads as either unanchored or pasted flat.

## Files

```
design/hifi/
├── index.html   # viewer — loads the prototype's screens, layers hi-fi on top
├── type.js      # the 13-step type ramp, each step mapped to an iOS text style
├── icons.js     # drawn glyphs + their SF Symbol names
├── hifi.css     # material, motion, density, accessibility floors
└── README.md    # this file
```

No literal colors and no literal font sizes appear in `hifi.css` — every value
resolves to a token from `tokens.js` or a step from `type.js`, for the same
reason the prototype held that line: `Packages/DesignKit` has to port this, and
a value invented in a stylesheet is a value someone has to guess at.

## Handoff

**[`../prototype/DESIGNKIT.md`](../prototype/DESIGNKIT.md)** is the single
porting contract, now covering both layers: color derivation (§1–6), layout
constants (§7), non-negotiables (§8–9), and from this layer the type ramp
(§10), SF Symbol mapping (§11), motion (§12) and accessibility floors (§13).

Every value in it is verified against source by script rather than transcribed
— the color tables against `tokens.js`, the type table against `type.js`, and
the icon table against `icons.js`. That check is worth keeping: it is what
caught the on-color bug that was rendering black labels on Apple Blue.
