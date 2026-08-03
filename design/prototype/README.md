# Localis — Prototype (原型图)

Wireframe-level prototype of the Localis iOS app: a chat client for the AI tools
already running on your own machine (Claude, OpenClaw, Hermes, Kimi, Codex).

**This is a prototype, not a design.** It fixes *structure, hierarchy,
information architecture and state* — what goes on each screen, what outranks
what, and what happens when things are streaming or broken. Icons are dashed
placeholders, illustration is absent, and the visual treatment is deliberately
plain. Hi-fi visual design (设计图) is the **next** step and is gated on your
approval of this one.

## How to view

```bash
open design/prototype/index.html
```

No build step, no dependencies — three files and a browser.

| Control | What it does |
|---|---|
| **View** | `All screens` (board, everything at once) / `One screen` (device + design notes) |
| **Screen** | Jump to any screen. Also deep-linkable: `index.html#chat` |
| **Mode** | Light / dark — both are real targets, so check both |
| **Seed** | Swap the seed color and watch every screen re-theme. Default `appleBlue` |
| **Neutral** | `slate` (default) / `neutral` |
| **Annotations** | Numbered pins on the frames, matched to the design notes panel |
| **Hotspots** | Outlines every tappable region, so you can see what is clickable |

Click any screen's caption on the board, or any pin-outlined control inside a
frame, to navigate. The prototype is click-through: session row → chat, backend
switcher → picker, `/` → skills, and so on.

## The screens

| # | Screen | What it settles |
|---|---|---|
| 01 | **Sessions** | The home surface. Multiple concurrent sessions, each with a backend badge and a live status pill. Live sessions sort above recent ones. |
| 02 | **Chat thread** | One conversation, mid-stream. Backend switcher and skills affordance both live in the composer. |
| 02b | **Backend picker** | Switching which local AI answers, mid-thread, with per-backend reachability. |
| 02c | **Skill picker** | The slash-command surface, opened from inside a thread. |
| 03 | **New session** | Pick backend (required) + skill (optional) + title (optional). One sheet, no wizard. |
| 04 | **Skills** | The reusable skill library, grouped by source (bundled / repo / yours). |
| 05 | **Settings · Connection** | Where the Mac bridge is configured. Deliberately abstract — see open questions. |
| 06 | **First run · not connected** | The state a new user actually lands in: no bridge, no sessions. |

Screen 06 exists because a prototype that only shows the happy path hides its
worst problems. The empty/disconnected state is where most chat apps fall apart,
so it is drawn at the same fidelity as the rest.

## Design language

Borrowed wholesale from the `my-designer` skill's one design language, so the
prototype and the eventual SwiftUI app share a vocabulary rather than diverging:

- **One seed color themes everything.** `appleBlue` (`#007AFF`) by default,
  neutral `slate`. `design/prototype/tokens.js` is a verbatim port of the
  skill's `color-system.ts` — same HSB derivation, same WCAG on-color math. Hex
  literals appear in that one file and nowhere else.
- **Semantic colors are fixed** and never seed-derived, so green = good and
  red = bad can never break when the seed changes.
- **Elevation is luminance tiers** (`bg` < `card` < `inner`) plus a 1px border.
  No drop shadows.
- **Status is always a colored pill**, never grey text. One status vocabulary
  across every screen: `connected` · `streaming` · `idle` · `error` / `offline`.
- **Three type levels minimum**, and all numbers are tabular/monospaced so
  latency figures and counts don't jitter as they update.
- **Backend identity is a hue**, drawn from the seed-derived chart palette —
  identity without a second palette.

## Decisions this prototype makes

These are the substantive calls. They are the things worth disagreeing with.

1. **Three tabs: Sessions · Skills · Settings.** Skills are a peer of sessions,
   not a settings sub-page, because they are content you accumulate and reuse.
2. **Session status is per-session; connection status is global.** The bridge
   gets one pill at the top of the list; each session gets its own. They fail
   independently and conflating them would hide real problems.
3. **Live sessions outrank recent ones.** Sorting purely by recency would let a
   streaming or errored session scroll out of sight.
4. **The backend switcher lives in the composer, not in settings.** Switching
   which AI answers is a conversational act, so it sits where you are typing.
5. **Switching backends applies to the next message only.** History stays
   attributed to whoever wrote it. This is the most confusable behaviour in the
   app, so it is stated inline in the picker rather than left implicit.
6. **Skill invocation is visible in the transcript** as a system divider, not a
   hidden prompt prefix — you can see where the conversation changed mode.
7. **Reachability is per-backend, checked at the point of choice.** A backend
   can be down while the bridge is up; unreachable ones appear dimmed with the
   reason, rather than being hidden or failing after you commit.
8. **Session titles are optional** and derived from the first message. Naming a
   conversation before having it is a chore.

## Open questions — for you

These need your call before hi-fi design starts. The first two are the ones that
could change layout.

1. **Connection model (blocking, owned by the spec).** Screen 05 holds one
   abstract "host / bridge address" field plus a pairing row. Whether that
   resolves to a LAN address, a QR pairing code, or a relay URL doesn't change
   the layout — but if the answer turns out to be *multiple hosts* (several Macs,
   or a Mac plus a remote box), then a host becomes a first-class object and both
   Sessions and Settings need rework. **Is one host per install a safe assumption?**

2. **Do sessions map 1:1 onto backends?** The prototype assumes a session has
   one backend at a time, which you can switch. The alternative — one session
   fanning a question out to several backends and comparing answers — is a
   genuinely different product and a different chat screen. Worth deciding now,
   because it is expensive to retrofit.

3. **Is the Skills browser a real tab, or is the in-chat picker enough?**
   It earns a tab if you author and edit skills on the phone. If skills are
   really authored on the Mac and only *used* on the phone, screen 04 could
   collapse into the picker and the third tab could become something else.

4. **How much does the phone need to show about what the Mac is doing?**
   Token counts, cost, model name, tool calls, running processes — the prototype
   shows almost none of it. That is a deliberate floor, not a conclusion.

5. **Streaming while backgrounded.** The prototype states that generation
   continues when you leave the app and syncs when you return. That is a product
   promise with real implementation cost — confirm it is one you want to make.

6. **iPad and Mac?** Everything here is drawn at iPhone width. If iPad is in
   scope, the sessions/chat split-view is a layout decision that should be made
   now rather than adapted later.

## What is deliberately not here

Skill detail/editor, search results, message-level context menus, onboarding
past first-run, error recovery beyond the offline state, notification design,
and all iconography. These are next-step work, not oversights — flag any you
consider essential to judge the concept.

## Files

```
design/prototype/
├── index.html    # the prototype shell: viewer, theming, navigation, pins
├── screens.js    # every screen's structure + its design notes
├── tokens.js     # the seed color system (port of my-designer's color-system.ts)
├── styles.css    # phone-frame components and the shell chrome
└── README.md     # this file
```

Annotation pins are positioned by measuring the elements they point at, so they
cannot drift out of sync when a layout changes. A note whose subject sits below
the fold is marked in the notes panel instead of being dropped silently.
