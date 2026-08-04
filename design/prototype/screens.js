/**
 * screens.js — Localis prototype, iPhone screens.
 *
 * Wireframe-level: structure, hierarchy, IA and state. The design language is
 * my-designer's (ONE seed, fixed semantics, status-as-pill, tabular numerals,
 * >=3 type levels) reconciled with iOS 26 Liquid Glass, which replaces the
 * flat-bar rule for FLOATING CHROME only. See glass.css and the README.
 *
 * Two structural rules this file enforces everywhere:
 *   1. Reachable controls live at the BOTTOM. Search is a `Tab(role: .search)`
 *      in the floating tab bar; create is a separate accent island.
 *   2. A backend is never named without its host. `(host, backend)` is the
 *      identity, because two machines can both run "Claude".
 *
 * Skills are an input accelerator, not a destination: there is no library
 * screen and no parameter form. `/` filters, the template lands in the
 * composer as editable text, and the transcript records no provenance.
 */
(function (global) {
  'use strict';

  var M = global.M;
  var esc = M.esc, note = M.note, badge = M.badge, pill = M.pill;
  var hostMark = M.hostMark, qualified = M.qualified, hostSwitch = M.hostSwitch;
  var statusBar = M.statusBar, sessionRow = M.sessionRow, dock = M.dock;
  var HOSTS = M.HOSTS, BACKENDS = M.BACKENDS;
  var SKILLS = M.SKILLS, fuzzy = M.fuzzy, highlight = M.highlight;

  // ── 1. Sessions ─────────────────────────────────────────────────────────

  var sessions = {
    id: 'sessions',
    name: 'Sessions',
    idx: '01',
    desc: 'Home. Every conversation across every machine you own — each with its host, its backend, and its own live status.',
    notes: [
      ['1', '<b>Large title + host switcher.</b> The current host sits in the title row as a pill, not behind a modal. The default is the host you last used, so the common path is <i>zero</i> taps — a host chooser you must clear before every session would be a tax on the most frequent action in the app.'],
      ['2', '<b>Aggregate host health, not a global bridge pill.</b> With several machines there is no single "connected" state to report; "2 of 3 reachable" is derived and tapping it goes to the host list. The old single-bridge pill was a one-host assumption baked into the layout.'],
      ['3', '<b>Scope chip: this host vs all hosts.</b> Sessions are grouped by host when scoped to All, so a machine is never an invisible attribute of a row.'],
      ['4', '<b>Backend badge, qualified by host</b> in the row meta. The badge hue identifies the backend; the mono host name disambiguates <i>which machine\'s</i> Claude this is.'],
      ['5', '<b>Session status pill.</b> connected / streaming / idle / error — colored fill plus label, never grey text. Distinct from host reachability: a session can be errored on a perfectly reachable host.'],
      ['6', '<b>Live rows outrank recency</b>, across all hosts. The thing that needs you is never scrolled off because it happens to be on your other machine.'],
      ['7', '<b>An unreachable host does not hide its sessions.</b> They are shown dimmed under the host\'s own header with the reason, because they still exist and will resume — hiding them would read as data loss.'],
      ['8', '<b>Floating Liquid Glass tab bar</b>, inset 21pt from left/right/bottom, translucent, minimizing on scroll. Content <i>fades</i> under it (bottom edge = fade only, no blur) rather than being cut by a hard bar edge.'],
      ['9', '<b>Search is a tab</b> — <code>Tab(role: .search)</code> — at the bottom-right of the bar, past a hairline and without a label so it reads as an affordance, not a fourth destination. It moved here from the top of the list purely for one-handed reach.'],
      ['10', '<b>New session is its own glass island</b> at the far bottom-right. The tab bar deliberately stops short of the edge to free the single most reachable point on the screen for the primary create action.']
    ],
    flows: [
      'Tap a row → <code>Chat thread</code>',
      'Tap the host pill / host health → <code>Host picker</code>',
      'Tap <code>+</code> island → <code>New session</code>',
      'Tap the search tab → <code>Search (bottom)</code>'
    ],
    pins: null,
    render: function () {
      return statusBar() +
        '<div class="navbar large">' +
          '<div class="lt-row"><div class="lt">Sessions</div>' +
          '<div style="display:flex;align-items:center;gap:10px">' +
            hostSwitch('mac-studio', '1') +
          '</div></div>' +
          '<div style="display:flex;align-items:center;gap:8px;margin:7px 0 2px" data-goto="host-picker">' +
            '<span data-note="2">' + pill('connected', '2 of 3 hosts') + '</span>' +
            '<span style="font-size:11px;color:var(--text-2);font-family:var(--mono)">' +
              '6 sessions &middot; 7 backends</span>' +
          '</div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll docked">' +
          '<div class="chip-row" data-note="3">' +
            '<span class="chip on">All hosts &middot; 6</span>' +
            '<span class="chip">mac-studio 3</span>' +
            '<span class="chip">macbook-pro 2</span>' +
            '<span class="chip">nas 1</span>' +
          '</div>' +
          '<div class="section-header" data-note="6"><span>Live</span>' +
            '<span style="font-family:var(--mono);color:var(--text-3)">2</span></div>' +
          '<div class="list">' +
            sessionRow({
              backend: 'claude', host: 'mac-studio', title: 'Refactor auth module', time: 'now',
              preview: 'Extracting the token refresh into its own actor so the retry loop stops racing the keychain read…',
              status: 'streaming', statusText: 'Streaming', goto: 'chat',
              badgeNote: '4', statusNote: '5'
            }) +
            sessionRow({
              backend: 'codex', host: 'mac-studio', title: 'Migrate test suite', time: '2m',
              preview: 'Connection refused on port 7331 — the codex process stopped responding mid-run.',
              status: 'error', statusText: 'Error', goto: 'chat'
            }) +
          '</div>' +
          '<div class="section-header"><span>Recent</span>' +
            '<span style="font-family:var(--mono);color:var(--text-3)">3</span></div>' +
          '<div class="list">' +
            sessionRow({
              backend: 'claude', host: 'macbook', title: 'Weekend trip planning', time: '18m',
              preview: 'Three routes that keep total drive time under four hours, ranked by how scenic the middle leg is.',
              status: 'connected', statusText: 'Connected', hostNote: '4'
            }) +
            sessionRow({
              backend: 'hermes', host: 'macbook', title: 'Review PR #482', time: '1h',
              preview: 'The migration looks reversible, but the down-path drops the index without recreating it.',
              status: 'idle', statusText: 'Idle', swipe: true
            }) +
            sessionRow({
              backend: 'openclaw', host: 'mac-studio', title: 'Localis spec notes', time: 'Mon',
              preview: 'Summarised the bridge options and flagged the two that need a decision before scaffolding.',
              status: 'idle', statusText: 'Idle'
            }) +
          '</div>' +
          '<div class="host-group" data-note="7">' + hostMark('nas') +
            '<span>nas</span>' +
            '<span class="pill offline" style="margin-left:6px">Host asleep</span>' +
            '<span class="hg-meta">6m ago</span></div>' +
          '<div class="list" style="opacity:0.55">' +
            sessionRow({
              backend: 'kimi', host: 'nas', title: 'Translate release notes', time: 'Yesterday',
              preview: '已完成第一版翻译，术语表已对齐。',
              status: 'idle', statusText: 'Idle'
            }) +
          '</div>' +
          '<div class="footnote">Sessions live on the machine that runs them. Closing the app does not stop a generation — ' +
            'it keeps streaming on that host and syncs when you return.</div>' +
        '</div></div>' +
        dock({
          active: 'sessions', barNote: '8',
          searchGoto: 'search', searchNote: '9',
          island: { go: 'new-session', glyph: '+', title: 'New session', note: '10' }
        });
    }
  };

  // ── 1b. Search, activated (bottom) ──────────────────────────────────────

  var search = {
    id: 'search',
    name: 'Search &middot; activated',
    idx: '01b',
    desc: 'What tapping the search tab does: the field rises over the keyboard, the tab bar collapses. The single clearest example of the bottom-anchoring rule.',
    notes: [
      ['1', '<b>The field animates UP over the keyboard</b> and lands directly above it — thumb, field and keys within one arc. This is the whole reason search moved off the top of the list.'],
      ['2', '<b>The tab bar collapses on activation</b> — <code>.searchToolbarBehavior(.minimize)</code>. Two pieces of floating furniture at the bottom at once would be unreadable, so search takes the slot and the bar yields it.'],
      ['3', '<b>The field is the OPAQUE glass, not the translucent one.</b> You are reading and editing text in it; Liquid Glass\'s documented failure is body copy over a busy backdrop. Deliberate contrast choice — legibility outranks material consistency.'],
      ['4', '<b>Results are scoped across hosts</b> and each result carries its host, so a match never leaves you guessing which machine it is on.'],
      ['5', '<b>Results push down from the top</b> while the query stays at the bottom. Reading order is top-down, reach is bottom-up — they are different problems and are solved separately.'],
      ['6', '<b>Cancel is inside the field</b>, also within thumb reach. There is no top-right dismiss to stretch for.']
    ],
    flows: [
      'Tap a result → <code>Chat thread</code>',
      'Tap <code>Cancel</code> → <code>Sessions</code>'
    ],
    pins: null,
    render: function () {
      function res(title, backend, host, snippet, hostNote) {
        return '<div class="row" data-goto="chat"' + note(hostNote) + '>' +
          badge(backend) +
          '<div class="rmain"><div class="rtop">' +
            '<span class="rtitle">' + esc(title) + '</span></div>' +
            '<div class="rsub">' + esc(snippet) + '</div>' +
            '<div class="rmeta">' + qualified(backend, host) + '</div>' +
          '</div></div>';
      }
      return statusBar() +
        '<div class="navbar large" style="padding-bottom:2px">' +
          '<div class="lt-row"><div class="lt" style="font-size:24px">Search</div></div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll" style="padding-bottom:352px">' +
          '<div class="chip-row">' +
            '<span class="chip on">All hosts</span>' +
            '<span class="chip">Messages</span>' +
            '<span class="chip">Sessions</span>' +
          '</div>' +
          '<div class="section-header" data-note="5"><span>4 results for "keychain"</span></div>' +
          '<div class="list">' +
            res('Refactor auth module', 'claude', 'mac-studio',
              '…races the keychain read on cold start, so the first request after launch…', '4') +
            res('Localis spec notes', 'openclaw', 'mac-studio',
              '…keychain storage for the pairing secret was the option we parked…') +
            res('Review PR #482', 'hermes', 'macbook',
              '…the keychain accessibility class changes between builds…') +
          '</div>' +
        '</div></div>' +
        '<div class="edge-fade bottom" style="height:96px"></div>' +
        '<div class="search-float glass opaque" style="bottom:300px" data-note="1">' +
          '<span style="color:var(--text-3)">&#9906;</span>' +
          '<span style="color:var(--text-1)" data-note="3">keychain<span class="caret" ' +
            'style="height:17px;width:2px"></span></span>' +
          '<span class="cancel" data-goto="sessions" data-note="6">Cancel</span>' +
        '</div>' +
        '<div class="keyboard" data-note="2">' +
          '<div class="krow">' + Array(10).join('<span class="key"></span>') + '<span class="key"></span></div>' +
          '<div class="krow">' + Array(9).join('<span class="key"></span>') + '<span class="key"></span></div>' +
          '<div class="krow"><span class="key wide"></span>' +
            Array(7).join('<span class="key"></span>') + '<span class="key wide"></span></div>' +
          '<div class="krow"><span class="key wide"></span><span class="key space"></span>' +
            '<span class="key wide"></span></div>' +
        '</div>';
    }
  };

  // ── 2. Chat thread ──────────────────────────────────────────────────────

  var chat = {
    id: 'chat',
    name: 'Chat thread',
    idx: '02',
    desc: 'One conversation, mid-stream. The hardest layout in the app: a bottom-anchored composer where the floating tab bar would otherwise be.',
    notes: [
      ['1', '<b>Back carries the live count</b> across all hosts, so leaving a streaming session still shows the others working.'],
      ['2', '<b>Title + qualified backend.</b> The subtitle names the backend <i>and</i> the machine, because "Claude" alone is ambiguous once two hosts run it. This is permanent context, not a hidden setting.'],
      ['3', '<b>Session status pill, and the way into Activity.</b> Same vocabulary as the list — and tapping it opens what the machine is actually doing. The status is the natural question-mark on this screen, so the answer lives behind it rather than behind a separate button.'],
      ['4', '<b>The transcript records no skill provenance.</b> This message was written with <code>/code-review</code>, and nothing here says so — no divider, no badge, no re-invoke affordance. A skill only ever put text in the composer; by the time a message is sent, the text is yours and claiming otherwise would be a fiction the data cannot back.'],
      ['5', '<b>Streaming bubble</b> with a caret. <i>Stop</i> replaces <i>Send</i> while generating.'],
      ['6', '<b>How the composer coexists with the tab bar: it does not.</b> A thread is a pushed destination, not a tab root, so the tab bar is dismissed on push and the glass composer takes the dock slot — same 21pt inset, same material, exactly one piece of bottom furniture at a time. Search within a thread lives in the nav bar, because the bottom is spoken for.'],
      ['7', '<b>Backend switcher stays in the composer</b>, now showing the host too. Switching which AI answers is a conversational act, so it stays where you type — and adding the host costs one line rather than a second control. It offers <i>this host\'s</i> backends as switchable: a session belongs to one machine permanently, because the transcript and the process live there, so picking another host\'s backend starts a new session instead of silently migrating this one.'],
      ['8', '<b>The composer is the opaque glass.</b> Same reasoning as search: it holds text you are composing and reading back, and translucency behind body copy is where Liquid Glass is legitimately criticised.'],
      ['9', '<b>Content fades into the composer</b> rather than being clipped, so the last line is always visibly continuous with the thread.']
    ],
    flows: [
      'Tap the backend switcher → <code>Backend picker</code>',
      'Tap <code>/</code> → <code>Skill picker</code>',
      'Tap the status pill → <code>Activity</code>',
      'Tap back → <code>Sessions</code>'
    ],
    pins: null,
    render: function () {
      return statusBar() +
        '<div class="navbar">' +
          '<div class="nb-left"><span class="nb-btn" data-goto="sessions" data-note="1">&#8249; ' +
            '<span class="pill streaming" style="margin-left:2px">2</span></span></div>' +
          '<div class="nb-title" data-note="2"><div class="t">Refactor auth module</div>' +
            '<div class="s" style="display:flex;justify-content:center">' +
              qualified('claude', 'mac-studio') + '</div></div>' +
          '<div class="nb-right"><span data-note="3" data-goto="activity">' +
            pill('streaming', 'Streaming') + '</span></div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll bottom" style="padding-bottom:152px">' +
          '<div class="thread">' +
          '<div class="msg me"><div class="bubble">Look at how we refresh the auth token — it races the keychain read on cold start.</div></div>' +
          '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
            '<span class="who">Claude &middot; mac-studio</span></div>' +
            '<div class="bubble">Found it. <code style="font-family:var(--mono);font-size:13px">TokenStore.refresh()</code> ' +
            'reads from the keychain on a background queue while the session task is already awaiting the result.</div></div>' +
          '<div class="msg me" data-note="4"><div class="bubble">Review the fix for correctness, ' +
            'then risk.</div></div>' +
          '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
            '<span class="who">Claude &middot; mac-studio</span>' + pill('streaming', 'Generating') + '</div>' +
            '<div class="bubble" data-note="5">Two things stand out. First, the actor isolation is right but the ' +
            '<code style="font-family:var(--mono);font-size:13px">await</code> ordering still allows a second caller in:' +
            '<div class="code">actor TokenStore {\n  private var refresh: Task&lt;Token, Error&gt;?\n\n  func token() async throws -&gt; Token {\n    if let refresh { return try await</div>' +
            '<span class="caret"></span></div>' +
            '<div class="msg-actions"><span>Copy</span><span>Retry</span><span>Retry on…</span></div>' +
          '</div>' +
        '</div></div></div>' +
        '<div class="edge-fade bottom" style="height:112px" data-note="9"></div>' +
        '<div class="composer-float glass opaque" data-note="6">' +
          '<div class="composer-bar">' +
            '<span class="backend-switcher" data-goto="backend-picker" data-note="7">' +
              badge('claude', 'sm') +
              '<span style="display:flex;flex-direction:column;line-height:1.15;align-items:flex-start">' +
                '<span>Claude</span>' +
                '<span style="font-family:var(--mono);font-size:9px;color:var(--text-3);font-weight:500">mac-studio</span>' +
              '</span>' +
              '<span style="color:var(--text-3)">&#9662;</span></span>' +
            '<span class="cbtn" data-goto="skill-picker" title="Skills">/</span>' +
            '<span class="cfield" data-note="8">Message…</span>' +
            '<span class="cbtn stop" title="Stop generating">&#9632;</span>' +
          '</div>' +
        '</div>';
    }
  };

  // ── 2b. Backend picker ──────────────────────────────────────────────────

  var backendPicker = {
    id: 'backend-picker',
    name: 'Backend picker',
    idx: '02b',
    desc: 'Switch which local AI answers, mid-thread — now across several machines, where the same backend name can appear twice.',
    notes: [
      ['1', '<b>Anchored to the switcher</b> it came from, above the composer — you never lose the thread.'],
      ['2', '<b>Grouped by host, host header always visible.</b> This is the whole answer to "the same backend name on two machines": Claude never appears as a bare row, only under the machine that runs it. Latency sits on the host header, since it is a property of the connection, not of the model.'],
      ['3', '<b>This host\'s backends are selectable.</b> Reachability is per-backend and checked at the point of choice — a backend can be down while its host is up.'],
      ['4', '<b>Other hosts\' backends are shown but labelled "new session".</b> They are not hidden, because you genuinely might want Hermes on the laptop — but choosing one cannot migrate this session, so the row says what it will actually do <i>before</i> you tap it.'],
      ['5', '<b>An unreachable host collapses to one row</b> with the reason, rather than listing backends you cannot use.'],
      ['6', '<b>Consequence stated in place:</b> a switch applies to the <i>next</i> message; history stays attributed. Still the most confusable behaviour in the app, so it is written down rather than implied.']
    ],
    flows: [
      'Tap a backend on this host → <code>Chat</code>, newly armed',
      'Tap a backend on another host → <code>New session</code> there',
      'Tap <code>Manage hosts</code> → <code>Settings</code>'
    ],
    pins: null,
    render: function () {
      function brow(k, meta, o) {
        var opt = o || {};
        return '<div class="mrow' + (opt.sel ? ' sel' : '') + (opt.off ? ' dim' : '') +
          '" data-goto="' + (opt.go || 'chat') + '"' + note(opt.note) + '>' +
          badge(k, 'md') +
          '<div style="min-width:0;flex:1 1 auto"><div style="font-weight:600">' +
            BACKENDS[k].label + '</div>' +
          '<div style="font-size:11px;color:' + (opt.off ? 'var(--danger)' : 'var(--text-2)') +
            ';font-family:var(--mono)">' + esc(meta) + '</div></div>' +
          (opt.sel ? '<span class="check">&#10003;</span>' : '') +
          (opt.newSession ? '<span class="pill neutral">new session</span>' : '') + '</div>';
      }
      function hgroup(hostId, noteId) {
        var h = HOSTS[hostId];
        return '<div class="host-group"' + note(noteId) + '>' + hostMark(hostId) +
          '<span>' + esc(h.name) + '</span>' +
          '<span class="hg-meta">' + esc(h.latency) + '</span></div>';
      }
      return chat.render() +
        '<div class="scrim" data-goto="chat"></div>' +
        '<div class="menu glass opaque" style="left:14px;bottom:118px;width:300px;z-index:31">' +
          '<div class="mtitle" data-note="1">Answer with</div>' +
          hgroup('mac-studio', '2') +
          brow('claude', 'Ready · 12ms', { sel: true }) +
          brow('openclaw', 'Ready · 31ms', { note: '3' }) +
          brow('codex', 'Unreachable · connection refused', { off: true }) +
          hgroup('macbook') +
          brow('claude', 'Ready · 38ms', { newSession: true, go: 'new-session', note: '4' }) +
          brow('hermes', 'Ready · 44ms', { newSession: true, go: 'new-session' }) +
          '<div class="host-group" data-note="5">' + hostMark('nas') +
            '<span style="opacity:0.6">nas</span>' +
            '<span class="hg-meta" style="color:var(--danger)">Host asleep</span></div>' +
          '<div data-note="6" style="padding:9px 13px;font-size:11px;color:var(--text-2);' +
            'background:var(--inner);border-top:1px solid var(--border);line-height:1.45">' +
            'Applies to your next message. Earlier replies stay attributed to the backend that wrote them.' +
          '</div>' +
          '<div class="mrow" data-goto="settings" style="color:var(--primary);border-top:1px solid var(--border)">' +
            '&#9881; Manage hosts &amp; backends…</div>' +
        '</div>';
    }
  };

  // ── 2c. Skill picker (the `/` accelerator) ──────────────────────────────

  var skillPicker = {
    id: 'skill-picker',
    name: 'Skill picker &middot; /',
    idx: '02c',
    desc: 'Type / in the composer and filter as you go. This is the whole of skills: get known text into the field fast, then edit it like anything else you typed.',
    notes: [
      ['1', '<b>It is not a sheet any more — it is the composer growing upward.</b> A skill is an input accelerator, so the interaction never leaves the input. No modal to present, none to dismiss, and the thread stays put behind it: you can still read what you are replying to while you pick.'],
      ['2', '<b>The query lives in the composer itself</b>, not in a separate filter field. You typed <code>/cdrv</code> where you were already typing — there is no second text field in this interaction, and nothing to move your hand to.'],
      ['3', '<b>Fuzzy subsequence match, filtering on every keystroke.</b> <code>re</code> finds <code>code-<b class="fz">re</b>view</code>, <code>research</code> and <code>t<b class="fz">r</b>anslat<b class="fz">e</b></code> — matching anywhere in the name, not just the start. Matched characters are marked so it is obvious <i>why</i> a row survived — otherwise a fuzzy filter looks like it is guessing.'],
      ['4', '<b>Best match is pre-selected, and Return takes it.</b> The keyboard-only path is type-slash, type three letters, press Return. Nothing on this screen requires touching the list at all.'],
      ['5', '<b>The list grows UP from the composer</b>, so the first result is the closest to both your thumb and the text you are typing. Ordinary lists read top-down; this one is ordered by proximity to the caret.'],
      ['6', '<b>The one-line summary is the row.</b> There is no detail view to open, no metadata, no usage count — everything a skill has that you would want before inserting it fits on the row, because a skill is now four fields.'],
      ['7', '<b>The catalog is host-scoped</b> — <code>/v1/skills</code> lives on the machine. This says <i>whose</i> skills these are, for the same reason every backend is qualified: two machines can hold different catalogs.'],
      ['8', '<b>Escape hatch, not a browser.</b> A stale-catalog or empty state resolves here rather than in a library screen — see the footer. There is nowhere else to go.']
    ],
    flows: [
      'Type to filter → the list narrows live',
      'Return / tap a row → <code>Composer, filled</code>',
      'Escape / delete the <code>/</code> → back to an ordinary composer'
    ],
    pins: null,
    render: function () {
      var q = 're';
      var matches = SKILLS.map(function (s) {
        return { s: s, hits: fuzzy(q, s.id) };
      }).filter(function (m) { return m.hits; });

      function srow(m, sel, noteId) {
        return '<div class="fzrow' + (sel ? ' sel' : '') + '" data-goto="composer-filled"' +
          note(noteId) + '>' +
          '<span class="fzname">/' + highlight(m.s.id, m.hits) + '</span>' +
          '<span class="fzdesc">' + esc(m.s.summary) + '</span>' +
          (sel ? '<span class="kbd">&#8617;</span>' : '') + '</div>';
      }

      return chat.render() +
        '<div class="scrim soft" data-goto="chat"></div>' +
        '<div class="fzpanel glass opaque" data-note="1">' +
          '<div class="fzhead" data-note="7">' + hostMark('mac-studio') +
            '<span>Skills on <b>mac-studio</b></span>' +
            '<span class="fzcount">' + matches.length + ' of ' + SKILLS.length + '</span></div>' +
          '<div class="fzlist" data-note="5">' +
            matches.map(function (m, i) {
              return srow(m, i === 0, i === 0 ? '4' : (i === 1 ? '6' : null));
            }).join('') +
          '</div>' +
          '<div class="fzfoot" data-note="8">Skills come from the machine this session runs on. ' +
            '<span style="color:var(--primary)">Add one on mac-studio</span></div>' +
        '</div>' +
        '<div class="fzcomposer glass opaque" data-note="2">' +
          '<div class="composer-bar">' +
            '<span class="backend-switcher" data-goto="backend-picker">' + badge('claude', 'sm') +
              '<span style="display:flex;flex-direction:column;line-height:1.15;align-items:flex-start">' +
                '<span>Claude</span><span style="font-family:var(--mono);font-size:9px;' +
                'color:var(--text-3);font-weight:500">mac-studio</span></span>' +
              '<span style="color:var(--text-3)">&#9662;</span></span>' +
            '<span class="cfield typed" data-note="3">/' + esc(q) +
              '<span class="caret"></span></span>' +
          '</div>' +
        '</div>';
    }
  };

  // ── 2d. Composer, filled ────────────────────────────────────────────────

  var composerFilled = {
    id: 'composer-filled',
    name: 'Composer &middot; filled',
    idx: '02d',
    desc: 'What insertion actually produces: the skill\'s text in the field, placeholders visible, cursor on the first one. There is no next step and no form.',
    notes: [
      ['1', '<b>The template lands as ordinary editable text.</b> Not a chip, not a locked prefix, not an attachment — text you could have typed, which means every editing gesture you already know still works on it.'],
      ['2', '<b>Placeholders are VISIBLE and selected, not a form.</b> The first is highlighted with the cursor on it; type to replace, Tab to jump to the next. Editing in the composer <i>is</i> the parameter mechanism, which is why the skill entity needs no parameter schema at all.'],
      ['3', '<b>A count, not a wizard.</b> "1 of 2" tells you something is still blank without gating Send on it — you can send a half-filled template if that is what you meant.'],
      ['4', '<b>Nothing marks this as a skill.</b> No armed chip above the composer, no badge. Once inserted it is a message you wrote, so the transcript records no provenance and there is no re-invoke affordance to design.'],
      ['5', '<b>The composer grew to fit</b> and the thread fades under it, exactly as with typed text. A skill inserting three lines is not a different state — it is just a longer message.'],
      ['6', '<b>Send is enabled the whole time.</b> The accelerator saved you typing; it did not put you in a mode you have to complete or cancel.']
    ],
    flows: [
      'Type → replaces the highlighted placeholder',
      'Tab → next placeholder',
      'Send → an ordinary message; the transcript shows no skill'
    ],
    pins: null,
    render: function () {
      return statusBar() +
        '<div class="navbar">' +
          '<div class="nb-left"><span class="nb-btn" data-goto="sessions">&#8249; ' +
            '<span class="pill streaming" style="margin-left:2px">2</span></span></div>' +
          '<div class="nb-title"><div class="t">Refactor auth module</div>' +
            '<div class="s" style="display:flex;justify-content:center">' +
              qualified('claude', 'mac-studio') + '</div></div>' +
          '<div class="nb-right">' + pill('idle', 'Idle') + '</div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll bottom" style="padding-bottom:196px">' +
          '<div class="thread">' +
          '<div class="msg me"><div class="bubble">Look at how we refresh the auth token — ' +
            'it races the keychain read on cold start.</div></div>' +
          '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
            '<span class="who">Claude &middot; mac-studio</span></div>' +
            '<div class="bubble">Found it. <code style="font-family:var(--mono);font-size:13px">' +
            'TokenStore.refresh()</code> reads from the keychain on a background queue while the ' +
            'session task is already awaiting the result.</div></div>' +
          '<div class="msg me" data-note="4"><div class="bubble">Review the diff on the retry ' +
            'loop for correctness, then risk, then style.</div></div>' +
          '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
            '<span class="who">Claude &middot; mac-studio</span></div>' +
            '<div class="bubble">Correctness first: the retry counter is read outside the ' +
            'actor, so two concurrent failures can both see attempt 0 and retry four times ' +
            'between them.</div></div>' +
        '</div></div></div>' +
        '<div class="edge-fade bottom" style="height:150px" data-note="5"></div>' +
        '<div class="composer-float glass opaque">' +
          '<div class="cfield filled" data-note="1">Review ' +
            '<span class="ph on" data-note="2">{{what}}</span> for correctness, then risk, ' +
            'then <span class="ph">{{style}}</span>.<span class="caret"></span></div>' +
          '<div class="composer-bar" style="margin-top:6px">' +
            '<span class="backend-switcher" data-goto="backend-picker">' + badge('claude', 'sm') +
              '<span style="display:flex;flex-direction:column;line-height:1.15;align-items:flex-start">' +
                '<span>Claude</span><span style="font-family:var(--mono);font-size:9px;' +
                'color:var(--text-3);font-weight:500">mac-studio</span></span>' +
              '<span style="color:var(--text-3)">&#9662;</span></span>' +
            '<span class="cbtn" data-goto="skill-picker" title="Skills">/</span>' +
            '<span class="phcount" data-note="3">1 of 2</span>' +
            '<span class="cbtn send" data-note="6" title="Send">&#8593;</span>' +
          '</div>' +
        '</div>';
    }
  };

  // ── 1c. Host picker ─────────────────────────────────────────────────────

  var hostPicker = {
    id: 'host-picker',
    name: 'Host picker',
    idx: '01c',
    desc: 'Switching machines, and the surface where a new one is paired. Reached from the title-row pill — one tap, never a gate.',
    notes: [
      ['1', '<b>A sheet, not a push.</b> Switching hosts is a lightweight scoping act you may do several times an hour; a nav push would imply you had left Sessions.'],
      ['2', '<b>"All hosts" is a real, first row.</b> The multi-host case is the default view, not an advanced mode — you should not have to pick a machine to see your work.'],
      ['3', '<b>Every host shows reachability, latency and session count</b> in one row. This is the only place all three appear together, and it is what makes "which machine should I use" answerable without navigating.'],
      ['4', '<b>An unreachable host stays selectable.</b> You can read its sessions offline; only starting or resuming generation needs the connection. Greying it out entirely would hide work you still own.'],
      ['5', '<b>Backends are listed under their host</b>, so the "two machines both run Claude" case is visible here rather than discovered later in a picker.'],
      ['6', '<b>Add a host is the last row, always present.</b> Pairing a second machine is the growth path of the whole product; burying it in Settings would make the multi-host model feel like a workaround.'],
      ['7', '<b>Actions sit at the bottom of the sheet</b>, in reach — consistent with every other primary control in this revision.']
    ],
    flows: [
      'Tap a host → <code>Sessions</code>, scoped to it',
      'Tap <code>All hosts</code> → <code>Sessions</code>, ungrouped',
      'Tap <code>Add a host</code> → pairing flow',
      'Tap <code>Manage</code> → <code>Settings</code>'
    ],
    pins: null,
    render: function () {
      function hrow(hostId, o) {
        var opt = o || {};
        var h = HOSTS[hostId];
        var backends = M.HOST_BACKENDS[hostId].map(function (k) {
          return BACKENDS[k].label;
        }).join(' · ');
        return '<div class="opt' + (opt.sel ? ' sel' : '') + '" data-goto="sessions"' +
          note(opt.note) + '>' + hostMark(hostId, 'lg') +
          '<div class="otext"><div class="oname">' + esc(h.name) +
            (opt.sel ? '<span class="pill neutral">current</span>' : '') + '</div>' +
            '<div class="odesc">' + esc(h.desc) + '</div>' +
            '<div class="odesc" style="font-family:var(--mono);font-size:11px;margin-top:3px"' +
              note(opt.bnote) + '>' + esc(backends) + '</div></div>' +
          '<div style="display:flex;flex-direction:column;align-items:flex-end;gap:5px;flex:0 0 auto">' +
            (h.reach === 'up'
              ? pill('connected', h.latency)
              : pill('offline', h.reason || 'Offline')) +
            '<span style="font-size:11px;color:var(--text-3);font-variant-numeric:tabular-nums">' +
              esc(opt.count) + '</span>' +
          '</div></div>';
      }
      return sessions.render() +
        '<div class="scrim" data-goto="sessions"></div>' +
        '<div class="sheet" style="max-height:78%;z-index:31" data-note="1">' +
          '<div class="grabber"></div>' +
          '<div class="sheet-nav">' +
            '<span class="nb-btn" data-goto="sessions">Done</span>' +
            '<span class="t">Hosts</span>' +
            '<span class="nb-btn" style="justify-self:end" data-goto="settings">Manage</span></div>' +
          '<div class="sheet-body">' +
            '<div class="list">' +
              '<div class="opt" data-goto="sessions" data-note="2">' +
                '<div class="host-mark lg" style="border-style:dashed">&#9783;</div>' +
                '<div class="otext"><div class="oname">All hosts</div>' +
                  '<div class="odesc">Every session, grouped by machine.</div></div>' +
                '<span style="font-size:11px;color:var(--text-3);font-variant-numeric:tabular-nums">6</span>' +
              '</div>' +
            '</div>' +
            '<div class="section-header">Your machines</div>' +
            '<div class="list">' +
              hrow('mac-studio', { sel: true, count: '3 sessions', note: '3', bnote: '5' }) +
              hrow('macbook', { count: '2 sessions' }) +
              hrow('nas', { count: '1 session', note: '4' }) +
            '</div>' +
            '<div class="footnote">A session stays on the machine that started it. Switching hosts changes what you ' +
              'are looking at — it never moves a conversation.</div>' +
          '</div>' +
          '<div class="sheet-foot" data-note="7">' +
            '<div class="btn" data-goto="settings" data-note="6">Add a host</div>' +
          '</div>' +
        '</div>';
    }
  };

  // ── 3. New session ──────────────────────────────────────────────────────

  var newSession = {
    id: 'new-session',
    name: 'New session',
    idx: '03',
    desc: 'Host and backend — one sheet, two answered questions. The host defaults, so the multi-host model costs nothing on the common path.',
    notes: [
      ['1', '<b>Modal sheet, not a push.</b> Creating a session is cancellable and shallow.'],
      ['2', '<b>Host is step one and pre-filled with the current host.</b> This is the concession that keeps multi-host from becoming a chore: the machine is <i>shown</i> so it is never a surprise, but it is already answered, so the common path is unchanged from the single-host design.'],
      ['3', '<b>Backends are the chosen host\'s backends</b>, and the list changes when the host does. Nothing else on the sheet is host-dependent.'],
      ['4', '<b>Live reachability per backend,</b> checked when the sheet opens; unreachable ones stay visible with the reason rather than vanishing.'],
      ['5', '<b>No skill step, deliberately.</b> Skills used to be step three here. But a skill is now just text you insert while typing, and you cannot know which one you want before you have written anything — so choosing one up front is a question asked too early. It moved to <code>/</code> in the composer, which is where the writing happens.'],
      ['6', '<b>The action names host and backend together</b>, so the last thing you read before committing is exactly what you get — the one place where the (host, backend) pair is spelled out in full.']
    ],
    flows: [
      'Tap <code>Start</code> → <code>Chat</code>',
      'Tap the host row → inline host list',
      'Tap <code>Cancel</code> → <code>Sessions</code>'
    ],
    pins: null,
    render: function () {
      function brow(k, meta, sel, off, noteId) {
        return '<div class="opt' + (sel ? ' sel' : '') + (off ? ' dim' : '') + '"' +
          note(noteId) + '>' + badge(k, 'md') +
          '<div class="otext"><div class="oname">' + BACKENDS[k].label + '</div>' +
          '<div class="odesc" style="font-family:var(--mono);color:' +
            (off ? 'var(--danger)' : 'var(--text-2)') + '">' + esc(meta) + '</div></div>' +
          '<span class="radio">' + (sel ? '&#10003;' : '') + '</span></div>';
      }
      return statusBar() +
        '<div style="height:46px;background:var(--inner);border-bottom:1px solid var(--border);opacity:0.5"></div>' +
        '<div class="body" style="background:rgb(0 0 0 / 0.28)"></div>' +
        '<div class="sheet" style="max-height:92%;top:56px" data-note="1">' +
          '<div class="grabber"></div>' +
          '<div class="sheet-nav">' +
            '<span class="nb-btn" data-goto="sessions">Cancel</span>' +
            '<span class="t">New session</span><span></span></div>' +
          '<div class="sheet-body">' +
            '<div class="section-header" data-note="2">1 &middot; Host</div>' +
            '<div class="list">' +
              '<div class="opt sel" data-goto="host-picker">' + hostMark('mac-studio', 'lg') +
                '<div class="otext"><div class="oname">mac-studio</div>' +
                  '<div class="odesc">Mac Studio · study · 3 backends ready</div></div>' +
                pill('connected', '12 ms') +
                '<span class="chev" style="color:var(--text-3)">&#8250;</span></div>' +
            '</div>' +
            '<div class="section-header" data-note="3">2 &middot; Backend on mac-studio ' +
              '<span style="color:var(--danger)">Required</span></div>' +
            '<div class="list">' +
              brow('claude', 'Ready · 12ms', true) +
              brow('openclaw', 'Ready · 31ms') +
              brow('codex', 'Unreachable · connection refused', false, true, '4') +
            '</div>' +
            '<div class="section-header" data-note="5">3 &middot; Title <span style="color:var(--text-3)">Optional</span></div>' +
                        '<div class="card"><div class="field">' +
              '<span class="fvalue" style="margin:0;text-align:left;flex:1;color:var(--text-3)">' +
              'Named from your first message</span></div></div>' +
          '</div>' +
          '<div class="sheet-foot">' +
            '<div class="btn" data-goto="chat" data-note="6">Start · Claude on mac-studio</div>' +
          '</div>' +
        '</div>';
    }
  };

  // ── 5. Settings · Hosts ─────────────────────────────────────────────────

  var settings = {
    id: 'settings',
    name: 'Settings &middot; Hosts',
    idx: '05',
    desc: 'Where machines are paired and managed. Rebuilt around a list of hosts rather than one bridge address.',
    notes: [
      ['1', '<b>Hosts are the first and largest block</b>, and they are a <i>list</i>. The single "host / bridge address" field is gone — that field was the single-host assumption in its purest form.'],
      ['2', '<b>Each host is one row: name, kind, reachability, latency, backend count.</b> Tapping opens that host\'s detail — address, pairing, per-backend health, and remove.'],
      ['3', '<b>Reachability is measured per host and shown as a pill plus a number.</b> Latency is what tells you whether a machine is <i>usably</i> reachable, not merely up.'],
      ['4', '<b>An unreachable host is not an error state of the app.</b> A sleeping NAS is normal; it gets a neutral reason ("Host asleep") rather than red alarm, and red is reserved for a host that should be up and is not.'],
      ['5', '<b>Add a host is a full-width primary action</b> at the bottom of the block, not a small "+" in the nav bar. Pairing a second machine is the product\'s growth path.'],
      ['6', '<b>Pairing model still open.</b> Whether that is a QR code, a code you type, or a relay account is a spec decision; the layout holds the slot without committing.'],
      ['7', '<b>Backends are shown per host, not globally.</b> Two machines running Claude produce two rows, and the counts do not merge — merging them would be the exact ambiguity we are designing against.'],
      ['8', '<b>Appearance follows the one-seed system</b> — light/dark/system only, no theme fork.']
    ],
    flows: [
      'Tap a host → host detail (address, pairing, backends, remove)',
      'Tap <code>Add a host</code> → pairing flow',
      'Tab bar → <code>Sessions</code> / <code>Skills</code>'
    ],
    pins: null,
    render: function () {
      function hostRow(hostId, o) {
        var opt = o || {};
        var h = HOSTS[hostId];
        var n = M.HOST_BACKENDS[hostId].length;
        return '<div class="field"' + note(opt.note) + ' style="gap:12px">' +
          hostMark(hostId, 'lg') +
          '<div style="min-width:0;flex:1 1 auto">' +
            '<div style="font-size:15px;font-weight:600">' + esc(h.name) + '</div>' +
            '<div style="font-size:11px;color:var(--text-2);margin-top:1px">' +
              esc(h.desc) + ' &middot; ' + n + ' backends</div></div>' +
          '<div style="display:flex;flex-direction:column;align-items:flex-end;gap:4px;flex:0 0 auto">' +
            (h.reach === 'up' ? pill('connected', 'Ready') : pill('offline', h.reason || 'Offline')) +
            '<span style="font-family:var(--mono);font-size:11px;color:var(--text-3);' +
              'font-variant-numeric:tabular-nums">' + esc(h.reach === 'up' ? h.latency : h.seen) + '</span>' +
          '</div>' +
          '<span class="chev" style="color:var(--text-3)">&#8250;</span></div>';
      }
      return statusBar() +
        '<div class="navbar large"><div class="lt-row"><div class="lt">Settings</div></div></div>' +
        '<div class="body"><div class="body-scroll docked">' +
          '<div class="section-header" data-note="1"><span>Hosts</span>' +
            '<span class="pill connected">2 of 3 reachable</span></div>' +
          '<div class="card">' +
            hostRow('mac-studio', { note: '2' }) +
            hostRow('macbook', { note: '3' }) +
            hostRow('nas', { note: '4' }) +
            '<div style="padding:10px 12px"><div class="btn ghost sm" data-note="5">Add a host</div></div>' +
          '</div>' +
          '<div class="tbd" data-note="6"><b>Open &middot; spec decision</b>' +
            'Pairing and transport are still being decided. Each host holds one abstract address plus a pairing ' +
            'state; whether that resolves to a LAN name, a QR code, or a relay URL does not change this layout. ' +
            'What multi-host <i>does</i> change is that these are per-host, so there is no single global setting.</div>' +
          '<div class="section-header" data-note="7"><span>Backends &middot; by host</span></div>' +
          '<div class="card">' +
            '<div class="host-group" style="border-top:0">' + hostMark('mac-studio') +
              '<span>mac-studio</span><span class="hg-meta">2 of 3 up</span></div>' +
            '<div class="field">' + badge('claude', 'md') +
              '<span class="flabel" style="margin-left:2px">Claude</span>' +
              '<span style="margin-left:auto;display:flex;align-items:center;gap:8px">' +
              '<span style="font-size:11px;color:var(--text-3);font-family:var(--mono)">12ms</span>' +
              pill('connected', 'Ready') + '</span></div>' +
            '<div class="field">' + badge('openclaw', 'md') +
              '<span class="flabel" style="margin-left:2px">OpenClaw</span>' +
              '<span style="margin-left:auto;display:flex;align-items:center;gap:8px">' +
              '<span style="font-size:11px;color:var(--text-3);font-family:var(--mono)">31ms</span>' +
              pill('connected', 'Ready') + '</span></div>' +
            '<div class="field">' + badge('codex', 'md') +
              '<span class="flabel" style="margin-left:2px">Codex</span>' +
              '<span style="margin-left:auto;display:flex;align-items:center;gap:8px">' +
              '<span style="font-size:11px;color:var(--text-3);font-family:var(--mono)">2m ago</span>' +
              pill('offline', 'Offline') + '</span></div>' +
            '<div class="host-group">' + hostMark('macbook') +
              '<span>macbook-pro</span><span class="hg-meta">2 of 2 up</span></div>' +
            '<div class="field">' + badge('claude', 'md') +
              '<span class="flabel" style="margin-left:2px">Claude</span>' +
              '<span style="margin-left:auto;display:flex;align-items:center;gap:8px">' +
              '<span style="font-size:11px;color:var(--text-3);font-family:var(--mono)">38ms</span>' +
              pill('connected', 'Ready') + '</span></div>' +
            '<div class="field">' + badge('hermes', 'md') +
              '<span class="flabel" style="margin-left:2px">Hermes</span>' +
              '<span style="margin-left:auto;display:flex;align-items:center;gap:8px">' +
              '<span style="font-size:11px;color:var(--text-3);font-family:var(--mono)">44ms</span>' +
              pill('connected', 'Ready') + '</span></div>' +
          '</div>' +
          '<div class="section-header" data-note="8">Appearance</div>' +
          '<div class="card">' +
            '<div class="field"><span class="flabel">Theme</span>' +
              '<span class="fvalue mono-strong">System</span>' +
              '<span class="chev" style="color:var(--text-3)">&#8250;</span></div>' +
            '<div class="field"><span class="flabel">Accent</span>' +
              '<span class="fvalue mono-strong">Apple Blue</span>' +
              '<span class="chev" style="color:var(--text-3)">&#8250;</span></div>' +
          '</div>' +
          '<div class="footnote">Localis talks only to machines you have paired. No conversation leaves your network.</div>' +
        '</div></div>' +
        dock({ active: 'settings', searchGoto: 'search' });
    }
  };

  // ── 6. First run ────────────────────────────────────────────────────────

  var empty = {
    id: 'empty',
    name: 'First run &middot; no hosts',
    idx: '06',
    desc: 'The state a new user actually lands in: no machine paired, no sessions. The wireframe has to survive this.',
    notes: [
      ['1', '<b>Failure is stated as a pill in the same slot the healthy state uses</b> — the layout does not reorganise between states. With hosts it reads "No hosts" rather than "No bridge".'],
      ['2', '<b>The empty state names the one blocking action.</b> "No sessions yet" would be useless when the real problem is upstream.'],
      ['3', '<b>Primary action is pairing, not creating.</b> A session with no host would fail, so create is demoted.'],
      ['4', '<b>The copy is plural from day one</b> — "your Mac, and any other machine". Framing the product as single-host at first run and revealing multi-host later would make the second machine feel like an edge case.'],
      ['5', '<b>Two tabs, and the bar still renders at full strength.</b> The bottom furniture never disappears because nothing is connected — Settings is exactly where you go from here, so the bar is the opposite of useless in this state.'],
      ['6', '<b>The create island is dimmed, not removed.</b> Removing it would make the bottom-right corner shift meaning between states; dimming teaches where it lives.']
    ],
    flows: [
      'Tap <code>Pair a machine</code> → <code>Settings</code>',
      'Tab bar → <code>Settings</code>, the only useful destination here'
    ],
    pins: null,
    render: function () {
      return statusBar() +
        '<div class="navbar large">' +
          '<div class="lt-row"><div class="lt">Sessions</div></div>' +
          '<div style="display:flex;align-items:center;gap:8px;margin:7px 0 2px">' +
            '<span data-note="1">' + pill('offline', 'No hosts') + '</span>' +
            '<span style="font-size:11px;color:var(--text-2);font-family:var(--mono)">Nothing paired yet</span>' +
          '</div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll" style="display:flex;align-items:center;' +
          'justify-content:center;padding:0 28px 104px">' +
          '<div style="text-align:center;margin-top:-40px">' +
            '<div style="width:64px;height:64px;border-radius:18px;border:1px dashed var(--border);' +
              'display:grid;place-items:center;margin:0 auto 16px;color:var(--text-3);font-size:24px">&#9633;</div>' +
            '<div style="font-size:20px;font-weight:650;letter-spacing:-0.02em" data-note="2">Pair a machine</div>' +
            '<div style="font-size:14px;color:var(--text-2);line-height:1.5;margin-top:7px" data-note="4">' +
              'Localis talks to the AI tools already running on your machines. Pair your Mac to start — ' +
              'you can add more later, and switch between them.</div>' +
            '<div class="btn" style="margin-top:22px" data-goto="settings" data-note="3">Pair a machine</div>' +
            '<div style="font-size:11px;color:var(--text-3);margin-top:20px;line-height:1.55">' +
              'Requires the Localis helper running on that machine, reachable from this device.</div>' +
          '</div>' +
        '</div></div>' +
        '<div class="edge-fade bottom"></div>' +
        '<div class="dock">' +
          '<div class="tabbar-float glass" data-note="5">' +
            '<div class="tab on"><span class="ic">&#9776;</span><span>Sessions</span></div>' +
            '<div class="tab" data-goto="settings"><span class="ic">&#9881;</span><span>Settings</span></div>' +
            '<div class="tab search" style="opacity:0.4"><span class="ic">&#9906;</span></div>' +
          '</div>' +
          '<div class="island glass accent" style="opacity:0.4" data-note="6">+</div>' +
        '</div>';
    }
  };

  // The iPad screens live in screens-ipad.js and are appended there, so
  // neither file outgrows the size ceiling and the iPad delta reads on its own.
  global.Screens = [
    sessions, search, hostPicker, chat, backendPicker, skillPicker,
    composerFilled,
    newSession, settings, empty
  ];
})(window);
