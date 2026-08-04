# Localis — Prototype (原型图)

Wireframe-level prototype of the Localis iOS app: a chat client for the AI
tools already running on the machines you own (Claude, OpenClaw, Hermes, Kimi,
Codex).

**This is a prototype, not a design.** It fixes *structure, hierarchy,
information architecture and state* — what goes on each screen, what outranks
what, and what happens when things are streaming or broken. Icons are dashed
placeholders, illustration is absent, and the visual treatment is deliberately
plain. Hi-fi visual design (设计图) is the **next** step and is gated on your
approval of this one.

## What changed in this revision

Four things you asked for, plus their knock-on effects:

1. **iOS 26 Liquid Glass** — floating translucent chrome replaces flat opaque
   bars. See *Design language*, which states exactly what this overrides and
   what it leaves alone, because `Packages/DesignKit` has to follow.
2. **Reachable controls moved to the bottom** — search is now a tab in the
   floating bar, create is a separate island, and both sit in the thumb arc.
   No primary control is top-anchored any more.
3. **Multiple hosts** — a host is a first-class object. Sessions, Settings, the
   backend picker and first-run were all rebuilt around it, and a new host
   picker (01c) was added.
4. **iPad split-view** — screens 07 and 08. Sessions and the thread side by
   side, and what the app degrades to when the second pane goes away.
5. **Skills cut down to an input accelerator** — no library screen, no
   parameter forms, no transcript provenance. Type `/`, filter, the text lands
   in the composer. See *Skills*, below.
6. **Backgrounded streaming and machine activity got real screens** (09, 10)
   now that both are confirmed product commitments rather than open questions.
   See *What the machine is doing*, below.

Mac is not in scope, and nothing here assumes it.

## How to view

```bash
open design/prototype/index.html
```

No build step, no dependencies — a browser and eight files.

| Control | What it does |
|---|---|
| **View** | `All screens` (board) / `One screen` (device + design notes) |
| **Screen** | Jump to any screen. Also deep-linkable: `index.html#chat` |
| **Mode** | Light / dark — both are real targets, and glass behaves differently in each |
| **Seed** | Swap the seed color; every screen re-themes, glass included |
| **Neutral** | `slate` (default) / `neutral` |
| **Annotations** | Numbered pins on the frames, matched to the notes panel |
| **Hotspots** | Outlines every tappable region |

The prototype is click-through: session row → chat, host pill → host picker,
backend switcher → picker, search tab → activated search, and so on.

## The screens

| # | Screen | What it settles |
|---|---|---|
| 01 | **Sessions** | Home. Sessions across every machine, each with host, backend and live status. Floating tab bar, search tab, create island. |
| 01b | **Search · activated** | What tapping the search tab does: field rises over the keyboard, tab bar collapses. The clearest statement of the bottom-anchoring rule. |
| 01c | **Host picker** | Switching machines, and where a new one is paired. One tap from the title row. |
| 02 | **Chat thread** | One conversation mid-stream — and the answer to "how does a bottom composer coexist with a floating tab bar". |
| 02b | **Backend picker** | Switching backend mid-thread, grouped by host, where two machines can both run Claude. |
| 02c | **Skill picker · /** | The whole of skills: type `/`, fuzzy-filter, insert. Not a sheet — the composer growing upward. |
| 02d | **Composer · filled** | What insertion produces: template text, placeholders visible, cursor on the first. No form, no next step. |
| 02e | **Skills · not loaded** | You typed `/` but the host has never been reached this launch. Never an error, never a spinner. |
| 03 | **New session** | Host (pre-filled) + backend. One sheet, no wizard. |
| 05 | **Settings · Hosts** | A *list* of machines, not one bridge address. |
| 06 | **First run · no hosts** | The state a new user actually lands in. |
| 07 | **iPad · split view** | Sessions and the thread at once. What the extra canvas is *for*. |
| 08 | **iPad · focused** | The sidebar collapsed — one layout covering hide, portrait, and narrow Split View. |
| 09 | **Return to app** | You closed the app mid-generation. Finished, still-streaming, and failed-while-away, all on one screen. |
| 10 | **Activity** | What the machine is doing right now: live command, tool-call timeline, model, workspace, tokens. |
| 11 | **Detached vs interrupted** | Still-running-elsewhere vs genuinely-lost. The one offers cancel, the other retry — and never both. |

Screen 06 exists because a prototype that only shows the happy path hides its
worst problems. Screen 01b exists because "search moved to the bottom" is a
claim you should be able to check rather than take on trust. Screens 09, 10 and
02e live in `screens-activity.js`; 07 and 08 in `screens-ipad.js`; the rest in
`screens.js`.

## iPad — where the rule lands differently

The iPad layer is `pad.css` + `screens-ipad.js`, kept separate for the same
reason `glass.css` is: it is a readable delta rather than something to diff out.

**Bottom-anchoring was never a rule about the bottom.** It was a rule about
where the thumb is. An iPhone is held one-handed; an 11-inch iPad is held
two-handed or propped on a desk, and iPadOS 26 floats its tab bar at the *top*
of the window. So the same rule produces the platform's answer here:

| | iPhone | iPad |
|---|---|---|
| Destinations + search | floating capsule, **bottom**, 21pt inset | same capsule, same material, **top** of the window, labels shown |
| Host switcher | pill in the large title | trailing corner of the top chrome, beside the destinations it scopes |
| Create | accent island, bottom-**trailing** | accent island, bottom-**leading** of the sidebar — the trailing corner now abuts the composer |
| Navigation | push and pop | persistent selection; the detail pane is always showing a row |
| Composer | 21pt inset, full width | 21pt inset, capped to the **reading measure** |

Three calls worth disagreeing with:

- **The transcript is capped at a reading measure (~700pt) and centred**, not
  stretched to the pane. The extra canvas buys *context* — two panes at once —
  never longer lines. This is also what makes 08 cheap: collapsing the sidebar
  re-centres the text without reflowing a single line, so nothing you were
  reading moves.
- **The sidebar is flat, not glass.** It is in-flow, and it holds the densest
  running text in the app. Both halves of the material rule agree.
- **One collapsed state covers three causes** — hidden by choice, portrait, and
  narrow Split View. Below the compact threshold it becomes the *iPhone*
  layout rather than a squeezed iPad one, which is why both layers are built
  from the same partials in `model.js`.

## Skills — an accelerator, not a subsystem

Skills solve exactly one problem: **getting known text into the composer
fast.** Everything that did not serve that was cut.

| Was | Now |
|---|---|
| A Skills **tab** with a library, sources and usage counts | Gone. Skills are reached by typing `/` where you were already typing |
| A **parameter form** for skills with placeholders | Gone. Placeholders are inserted **visible** and typed over — editing in the composer *is* the parameter mechanism |
| A **system divider** in the transcript recording invocation | Gone. Once inserted it is a message you wrote |
| A skill pill on session rows | Gone. A session is not "a /code-review session" |
| Skill as step 3 of New Session | Gone. You cannot know which skill you want before writing anything |

What this buys, beyond simplicity: the skill entity collapses to
**`id / name / summary / template`** — no parameter schema, no invocation
records, nothing to garbage-collect. The picker is drawn against exactly those
four fields.

**The `/` picker is now the entire feature, so it is built for speed.** Fuzzy
subsequence matching filters on every keystroke (`re` finds `code-review`,
`research`, `translate` and `refactor`), matched characters are marked so it is
visible *why* a row survived, and the best match is pre-selected so the
keyboard-only path is `/`, two letters, Return. It is not a sheet — it is the
composer growing upward, so the thread stays readable behind it and there is
nothing to present or dismiss.

**Two destinations, not three.** With the Skills tab gone the app has Sessions
and Settings. The bar stays a bar rather than becoming a segmented control,
because it still has to house `Tab(role: .search)` — and two tabs leave the
search affordance and the create island more room than three did, which
directly helps the bottom congestion that screen 02 exists to solve.

**The catalog is host-scoped** (`/v1/skills` lives on the machine), so the
picker names whose skills it is showing, for the same reason every backend is
qualified. Behaviour when that host is unreachable is with `spec`; my
recommendation is a cached catalog marked stale with insertion still allowed,
since inserting text costs nothing offline.

## What the machine is doing — and what is real

Two confirmed commitments drive screens 09 and 10:

**Generation continues on the host while the app is closed.** That is a
promise, and a promise you cannot see kept is indistinguishable from a bug — so
returning to the app surfaces what changed as its own band. Three outcomes, all
drawn: *finished while away* (a row with a changed marker, demanding nothing),
*still streaming* (the promise kept literally, elapsed counted from the host's
clock), and *failed while away* — which sorts **above** the successes, because
something broke on a machine you could not see and is still broken. The failure
states when it broke and how far it got: "failed 8 minutes in, after 3 tool
calls" is actionable where "Error" is not.

**Show what is available; render nothing where there is nothing.** For a CLI agent acting
on your machine, *what it is doing right now* outranks every other metric — you
are not in the room and it is running commands. So the live tool call is the
headline of screen 10, over a timeline of calls with durations and exit status.

### What the bridge must provide — a contract request for `spec`

Nothing here is invented. Every element is classified. **CERTAIN** means: I am
asking for it in `contracts/bridge-protocol.md`, and without it the screen
loses a feature. **CLIENT** means the app derives it with no new bridge
capability.

| Element | Class | What the bridge emits | Where |
|---|---|---|---|
| Current activity — thinking / running a tool | **CERTAIN** | Tool-start: `{ name, args, startedAt }` | 10, headline |
| Tool completion | **CERTAIN** | Tool-end: `{ name, endedAt, exitStatus }` | 10, timeline |
| Token usage | **CERTAIN** | `usage`: prompt / completion / total | 10, "This run" |
| Model name | **CERTAIN** | Field on the backend/session descriptor | 10, "This run" |
| Workspace path | **CERTAIN** | Abbreviated by the bridge (`~/dev/foo`) — never absolute | 10, "This run" |
| Terminal outcome | **CERTAIN** | `finished`/`failed` + reason + timestamp, readable **after reconnect** | 09, all rows |
| Resume support | **CERTAIN** | Per-host capability, default off | 11, host rows |
| Elapsed, message count, unread-per-host | CLIENT | — derived from timestamps | 09, 10 |

**Not in v1: cost in currency.** Pricing moves with model and plan, so a figure
computed on-device is stale the moment it renders. No money value is drawn
anywhere. If it is wanted later the bridge computes and sends a display string.

**Two rules that shape the layout**, both from `spec`:

1. **Render by field presence — never leave a placeholder hole.** If a backend
   does not report tokens, that block simply does not appear. *I got this wrong
   first:* I drew a labelled empty slot reading "not reported yet", on the
   reasoning that an honest gap beats a fake number. Half right — a fake number
   is worse, but a permanent empty slot is also a lie, because it implies the
   value is coming. Absent data should be absent.
2. **Telemetry carries no transcript text, no absolute paths, no tokens.** A
   working directory is shown only in the abbreviated form the bridge sends.

Unknown telemetry keys are ignored by an open envelope, so adding a field later
(queue depth, remaining quota, context used) is a bridge change with **no iOS
release** — which is the real reason no placeholder slots are needed.

The load-bearing row is **terminal outcome**: screen 09 only works if a state
reached while the client was disconnected is still readable on reconnect. A
live-only event stream is not enough, because the app was closed exactly when
the interesting thing happened. That is the difference between the
backgrounded-streaming promise being *visible* and merely being *true*.

## Detached is not interrupted — a safety distinction

`spec`'s Amendment C splits a state that used to be one, and the split is a
safety property rather than a taxonomy:

- **detached** — the connection dropped, **the host is still generating**.
  Offers **cancel**. Resolves itself when the connection returns.
- **interrupted** — the content is genuinely lost (no resume support, retention
  expired, output truncated). Offers **retry**.

Retrying something that is still running starts a **second job on the user's
machine**. So `detached` does not render a retry control *at all* — not greyed,
not behind a confirm, absent. Two states that look alike and carry asymmetric
cost should differ in **what you can do**, not merely in what color they are.
The visual difference — live blue pulse vs a static dashed rule — is the second
line of defence, not the first.

Resume is a **per-host capability, off by default**, so an older bridge behaves
the old way. Screen 11 shows both, because the app must not promise continuity
on a machine that cannot deliver it.

## Design language — the reconciliation

The prototype uses the `my-designer` design language reconciled with iOS 26.
`Packages/DesignKit` will have to follow, so here is the precise delta.

### Unchanged — still binding

- **One seed color themes everything.** `appleBlue` (`#007AFF`) by default.
  `tokens.js` is a port of the skill's `color-system.ts`, now extended with
  `--glass-*` and `--fade-*` derived from the same neutral ramp. Hex literals
  appear in that one file and nowhere else — glass included.
- **Semantic colors are fixed** and never seed-derived.
- **Status is always a colored pill**, never grey text. One vocabulary:
  `connected` · `streaming` · `idle` · `error` / `offline`.
- **Three type levels minimum**; all numbers tabular.
- **Backend identity is a hue** from the seed-derived chart palette.

### Changed — and only here

> **Old rule:** elevation is luminance tiers (`bg` < `card` < `inner`) plus a
> 1px border. No drop shadows.
>
> **New rule:** that still holds for *in-flow* surfaces — cards, list rows,
> sheets, fields. A card is not glass. But **floating chrome** now gets Liquid
> Glass: translucent material, inset from the edges, capsule-shaped, and
> carrying the system's only shadows.

"Floating chrome" is an exhaustive list: the tab bar, the create island, the
activated search field, the chat composer, and the host switcher pill. Anything
else that grows a shadow is a bug.

Concretely:

| | Before | After |
|---|---|---|
| Tab bar | opaque, edge-to-edge, flush to the bottom | floating capsule, 21pt inset L/R/B, translucent, minimizes on scroll |
| Content edge | hard cut at the bar's top border | progressive **fade** (bottom = fade only, no blur; top edge = blur + fade) |
| Elevation of chrome | luminance tier + 1px border | material + floating inset + shadow |
| Search | row at the top of the list | `Tab(role: .search)` in the bar; activates upward over the keyboard |
| Create | `+` in the top-right nav bar | accent glass island, bottom-right |

### Where translucency was deliberately refused

Liquid Glass has drawn real criticism for contrast and legibility, and the
failure mode is specific: **body copy over a busy backdrop**. So the material
comes in two grades, and the choice is made by content type, not by aesthetics:

- `--glass` (~0.70 light / 0.58 dark) — chrome with short, high-contrast
  content: tab labels, an icon, a status pill. Backdrop showing through is
  legible here because there is nothing long to read.
- `--glass-solid` (~0.92 light / 0.88 dark) — **the search field, the chat
  composer, and the backend picker menu**. You read and edit running text in
  these, so they are near-opaque. This is an intentional deviation from
  uniform material, and it should survive into DesignKit.

Two more contrast guards worth carrying over: the selected tab sits on a tinted
capsule rather than relying on accent color alone against a moving backdrop,
and the specular edge is a single hairline, not a gradient wash that would
lower contrast across the whole surface.

### SwiftUI vocabulary

Kept deliberately buildable — every affordance drawn here maps to a real API:

- `Tab(..., role: .search)` — the search tab
- `.searchable(text:placement:.automatic)` in a `NavigationStack` — bottom on iOS
- `.searchToolbarBehavior(.minimize)` — the compact overlay and bar collapse
- Tab bar minimize-on-scroll, selected destination in the accent color, ~11pt
  SF labels

## Decisions this prototype makes

The substantive calls — the things worth disagreeing with.

1. **Two destinations plus a search role: Sessions · Settings · 🔍.** Search is
   an affordance, not a third destination, so it carries no label and sits past
   a hairline. Skills is not here — it is not a place, it is what `/` does.
2. **The tab bar does not span the full width.** That is what frees the
   bottom-right corner — the most reachable point for a right thumb — for the
   primary create action as its own island. Create means the same thing on
   every tab: "make the thing this tab is about".
3. **A thread hides the tab bar, and the composer takes the dock slot.** This
   is the answer to the hardest layout in the app. A thread is a pushed
   destination, not a tab root, so there is exactly one piece of bottom
   furniture at a time — never a composer stacked on a tab bar. In-thread
   search consequently lives in the nav bar, because the bottom is spoken for.
4. **A host is first-class, but never a gate.** The host switcher is a pill in
   the title row, pre-filled with the last host used. New Session shows the
   host as an already-answered step-one. The common path is unchanged from the
   single-host design: zero extra taps.
5. **A session belongs to exactly one host, permanently.** The transcript and
   the running process live on that machine, so "move this session to another
   machine" is not offered. Choosing another host's backend in the picker
   starts a *new* session there, and the row says so before you tap it.
6. **A backend is identified by `(host, backend)`, and is never named alone.**
   Two machines can both run Claude. Every surface that names a backend
   qualifies it with the host in mono type; the picker groups by host with an
   always-visible header.
7. **There is no global "bridge connected" state any more.** With several
   machines there is no single truth to report. Sessions shows a derived
   aggregate ("2 of 3 hosts"); reachability itself is per host, and per backend
   within a host.
8. **An unreachable host does not hide its sessions.** They appear dimmed under
   that host's header with the reason. Hiding them would read as data loss, and
   they will resume.
9. **Switching backends applies to the next message only.** History stays
   attributed. Still the most confusable behaviour in the app, so it is stated
   inline in the picker.
10. **Live sessions outrank recency, across all hosts** — the thing that needs
    you is never scrolled off for being on your other machine.
11. **The transcript records no skill provenance.** A skill only ever put text
    in the composer; by the time a message is sent the text is yours, and a
    "used /research" marker would claim a relationship the data does not have.
12. **The skill catalog is host-scoped**, like backends — `/v1/skills` lives on
    the machine. So the picker names whose skills it is showing, and two
    machines may legitimately offer different ones.
13. **Session titles are optional**, derived from the first message.
14. **iPad moves the tab bar to the top, and that is the same rule as iPhone's
    bottom bar** — both put destinations where the hand actually is on that
    device. Identical capsule, identical material, identical search role.
15. **The extra iPad canvas buys context, not size.** Two panes at once, a
    capped reading measure, and deliberate gutters — never a wider line of
    prose.

## Settled — the answers this revision was built on

Every open question from the first round is now closed:

1. **Pairing model** — stays abstract. Per host, so there is no global
   connection setting.
2. **Sessions cannot move between hosts** (FR-030). The backend picker's
   "starts a new session there" is compliant: it creates, it does not migrate.
3. **~3 hosts, degrading to ~6.** Beyond that the host picker wants search.
4. **No Skills tab** — skills are an accelerator, not a destination.
5. **Machine activity: show what exists; absent data is absent.** No
   placeholder slots, no cost figure. See above.
6. **Backgrounded streaming: confirmed** as a real promise. Screen 09 is what
   keeping it looks like.
7. **iPad is a peer**, not a companion. Same app, same features — the sidebar
   keeps its width.

One thing I would still flag rather than assume: the **freed third tab slot**.
The app is at two destinations, and my recommendation is to leave it that way —
two tabs give the search affordance and the create island more room, and
inventing a destination to fill a slot is how apps grow features nobody asked
for. If something belongs there it should arrive by earning a place.

## What is deliberately not here

Host detail/pairing flow, skill detail/editor, message-level context menus,
onboarding past first-run, iPad multitasking beyond the collapsed state, and
all iconography. Mac is out of scope by decision. Flag any you consider
essential to judge the concept.

## Files

```
design/prototype/
├── index.html       # viewer shell: theming, navigation, pins
├── tokens.js        # seed color system + Liquid Glass materials (only hex here)
├── model.js         # hosts, backends, and the shared partials
├── screens.js       # the iPhone screens + their design notes
├── screens-ipad.js  # the iPad screens, built from the same partials
├── screens-activity.js  # return-to-app, activity, catalog-not-loaded
├── styles.css       # flat in-flow components (cards, rows, sheets)
├── glass.css        # the iOS 26 layer — the delta from the old language
├── pad.css          # the iPad layer — the delta from the iPhone layout
├── activity.css     # activity / return-to-app components
├── viewer.css       # the review harness — does NOT ship
├── DESIGNKIT.md     # the porting contract for Packages/DesignKit
└── README.md        # this file
```

**[`DESIGNKIT.md`](./DESIGNKIT.md) is the handoff document.** Everything
`Packages/DesignKit` needs to implement this in SwiftUI without guessing: the
full seed→token derivation with both light and dark formulas, the two material
grades and the rule for choosing between them, the fixed semantic values, the
layout constants, and the non-negotiables that are not colors. Every value in
it is verified against `tokens.js` rather than transcribed by hand.

`glass.css` and `pad.css` are separate on purpose: each is exactly what has to
be adopted downstream, readable without diffing it out of the rest.

Annotation pins are positioned by measuring the elements they point at, so they
cannot drift out of sync when a layout changes. A note whose subject sits below
the fold is marked in the notes panel instead of being dropped silently.
