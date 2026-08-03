/**
 * screens.js — Localis prototype screen definitions.
 *
 * Each entry is one phone frame: metadata + an HTML render + annotation pins.
 * Wireframe-level on purpose: structure, hierarchy, IA and state — using the
 * my-designer design language as the vocabulary (luminance-tier elevation,
 * >=3 type levels, tabular numbers, status-as-pills). Hi-fi visual design is a
 * later step, gated on user approval.
 */
(function (global) {
  'use strict';

  // ── Backends ───────────────────────────────────────────────────────────
  // Each backend gets a distinct chart-palette slot, derived from the ONE
  // seed. This is identity-by-hue, not a second palette.
  var BACKENDS = {
    claude:   { label: 'Claude',   abbr: 'CL', chart: 1 },
    openclaw: { label: 'OpenClaw', abbr: 'OC', chart: 3 },
    hermes:   { label: 'Hermes',   abbr: 'HM', chart: 4 },
    kimi:     { label: 'Kimi',     abbr: 'KM', chart: 6 },
    codex:    { label: 'Codex',    abbr: 'CX', chart: 8 }
  };

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  /** Backend badge tinted from the seed-derived chart palette. */
  function badge(key, size) {
    var b = BACKENDS[key];
    var v = 'var(--chart-' + b.chart + ')';
    return '<div class="badge ' + (size || '') + '" style="background:color-mix(in srgb,' + v +
      ' 16%,transparent);color:' + v + ';border-color:color-mix(in srgb,' + v +
      ' 34%,transparent)">' + b.abbr + '</div>';
  }

  function pill(kind, text) {
    return '<span class="pill ' + kind + '"><span class="dot"></span>' + esc(text) + '</span>';
  }

  function statusBar() {
    return '<div class="status-bar"><span>9:41</span>' +
      '<span class="sb-right"><span>&#9679;&#9679;&#9679;</span><i></i></span></div>';
  }

  function sparkline(points, colorVar) {
    var w = 62, h = 22;
    var max = Math.max.apply(null, points);
    var min = Math.min.apply(null, points);
    var span = max - min || 1;
    var d = points.map(function (p, i) {
      var x = (i / (points.length - 1)) * w;
      var y = h - ((p - min) / span) * (h - 3) - 1.5;
      return (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1);
    }).join(' ');
    var c = colorVar || 'var(--primary)';
    return '<svg class="spark" width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '">' +
      '<path d="' + d + ' L' + w + ' ' + h + ' L0 ' + h + ' Z" fill="' + c + '" opacity="0.13"/>' +
      '<path d="' + d + '" fill="none" stroke="' + c + '" stroke-width="1.5" ' +
      'stroke-linecap="round" stroke-linejoin="round"/></svg>';
  }

  function sessionRow(o) {
    return '<div class="row' + (o.swipe ? ' swipe' : '') + '"' +
      (o.note ? ' data-note="' + o.note + '"' : '') +
      (o.goto ? ' data-goto="' + o.goto + '"' : '') + '>' +
      '<span' + (o.badgeNote ? ' data-note="' + o.badgeNote + '"' : '') + '>' + badge(o.backend) + '</span>' +
      '<div class="rmain">' +
        '<div class="rtop"><span class="rtitle">' + esc(o.title) + '</span>' +
        '<span class="rtime">' + esc(o.time) + '</span></div>' +
        '<div class="rsub">' + esc(o.preview) + '</div>' +
        '<div class="rmeta"><span class="backend-name">' + BACKENDS[o.backend].label + '</span>' +
        '<span' + (o.statusNote ? ' data-note="' + o.statusNote + '"' : '') + '>' +
          pill(o.status, o.statusText) + '</span>' +
        (o.skill ? '<span class="pill neutral"' + (o.skillNote ? ' data-note="' + o.skillNote + '"' : '') +
          '>/' + esc(o.skill) + '</span>' : '') +
        '</div>' +
      '</div>' +
      '<span class="chev">&#8250;</span></div>';
  }

  function tabbar(active) {
    var tabs = [
      { id: 'sessions', label: 'Sessions', ic: '&#9776;', go: 'sessions' },
      { id: 'skills', label: 'Skills', ic: '&#9670;', go: 'skills' },
      { id: 'settings', label: 'Settings', ic: '&#9881;', go: 'settings' }
    ];
    return '<div class="tabbar">' + tabs.map(function (t) {
      return '<div class="tab' + (t.id === active ? ' on' : '') + '" data-goto="' + t.go + '">' +
        '<span class="ic">' + t.ic + '</span><span>' + t.label + '</span></div>';
    }).join('') + '</div>';
  }

  // ── 1. Sessions list ─────────────────────────────────────────────────────

  var sessions = {
    id: 'sessions',
    name: 'Sessions',
    idx: '01',
    desc: 'Home. Every concurrent conversation with a local AI, each with its own backend and live status.',
    notes: [
      ['1', '<b>Large title + running count.</b> The count is the multi-session promise made visible; tabular numerals so it does not jitter as sessions stream.'],
      ['2', '<b>Global bridge state.</b> One pill for the Mac bridge itself. If this goes <i>offline</i>, every row below is stale — so it lives above them, not per-row.'],
      ['3', '<b>Backend filter chips.</b> Scoped to backends that actually have sessions. "All" is the default.'],
      ['4', '<b>Backend badge.</b> Two-letter mark tinted from a seed-derived chart hue, so a backend is identifiable before any text is read.'],
      ['5', '<b>Session status pill.</b> connected / streaming / idle / error. Colored fill + label — never grey text alone. Streaming dot pulses.'],
      ['6', '<b>Live rows sort to the top.</b> Streaming and error sessions outrank recency, so the thing that needs you is never scrolled off.'],
      ['7', '<b>Armed skill shown on the row</b> when a session was started with one, so you know its mode without opening it.'],
      ['8', '<b>Swipe actions:</b> rename, change backend, delete. Long-press = same menu, for reachability.'],
      ['9', '<b>New session.</b> Primary create affordance, top-right per iOS convention.']
    ],
    flows: [
      'Tap a row → <code>Chat thread</code>',
      'Tap <code>+</code> → <code>New session</code>',
      'Tap <code>Skills</code> / <code>Settings</code> tab → those screens'
    ],
    pins: null,
    render: function () {
      return statusBar() +
        '<div class="navbar large">' +
          '<div class="lt-row"><div class="lt" data-note="1">Sessions</div>' +
          '<div style="display:flex;align-items:center;gap:14px">' +
            '<span class="nb-icon" title="Filter">&#8942;</span>' +
            '<span class="nb-icon" data-goto="new-session" data-note="9" title="New session">+</span>' +
          '</div></div>' +
          '<div style="display:flex;align-items:center;gap:8px;margin:6px 0 2px">' +
            '<span data-note="2">' + pill('connected', 'Bridge connected') + '</span>' +
            '<span style="font-size:11px;color:var(--text-2);font-family:var(--mono)">mac-studio.local &middot; 5 backends</span>' +
          '</div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll">' +
          '<div class="search"><span>&#9906;</span><span>Search sessions and messages</span></div>' +
          '<div class="chip-row" data-note="3">' +
            '<span class="chip on">All &middot; 6</span>' +
            '<span class="chip">Claude 2</span>' +
            '<span class="chip">OpenClaw 1</span>' +
            '<span class="chip">Hermes 1</span>' +
            '<span class="chip">Kimi 1</span>' +
            '<span class="chip">Codex 1</span>' +
          '</div>' +
          '<div class="section-header" data-note="6"><span>Live</span>' +
            '<span style="font-family:var(--mono);color:var(--text-3)">2</span></div>' +
          '<div class="list">' +
            sessionRow({
              backend: 'claude', title: 'Refactor auth module', time: 'now',
              preview: 'Extracting the token refresh into its own actor so the retry loop stops racing the keychain read…',
              status: 'streaming', statusText: 'Streaming', goto: 'chat',
              badgeNote: '4', statusNote: '5'
            }) +
            sessionRow({
              backend: 'codex', title: 'Migrate test suite', time: '2m',
              preview: 'Connection refused on port 7331 — the codex host stopped responding mid-run.',
              status: 'error', statusText: 'Error', goto: 'chat'
            }) +
          '</div>' +
          '<div class="section-header"><span>Recent</span><span style="font-family:var(--mono);color:var(--text-3)">4</span></div>' +
          '<div class="list">' +
            sessionRow({
              backend: 'openclaw', title: 'Weekend trip planning', time: '18m',
              preview: 'Three routes that keep total drive time under four hours, ranked by how scenic the middle leg is.',
              status: 'connected', statusText: 'Connected', skill: 'research', skillNote: '7'
            }) +
            sessionRow({
              backend: 'hermes', title: 'Review PR #482', time: '1h',
              preview: 'The migration looks reversible, but the down-path drops the index without recreating it.',
              status: 'idle', statusText: 'Idle', skill: 'code-review', swipe: true, note: '8'
            }) +
            sessionRow({
              backend: 'kimi', title: 'Translate release notes', time: 'Yesterday',
              preview: '已完成第一版翻译，术语表已对齐。',
              status: 'idle', statusText: 'Idle'
            }) +
            sessionRow({
              backend: 'claude', title: 'Localis spec notes', time: 'Mon',
              preview: 'Summarised the bridge options and flagged the two that need a decision before scaffolding.',
              status: 'idle', statusText: 'Idle'
            }) +
          '</div>' +
          '<div class="footnote">Sessions run on your Mac. Closing the app does not stop a generation — it keeps streaming and syncs when you return.</div>' +
        '</div></div>' +
        tabbar('sessions');
    }
  };

  // ── 2. Chat thread ───────────────────────────────────────────────────────

  var chat = {
    id: 'chat',
    name: 'Chat thread',
    idx: '02',
    desc: 'One conversation. Streaming response in flight, with the backend switcher and skills affordance in reach.',
    notes: [
      ['1', '<b>Back to sessions</b> carries an unread/live count, so leaving a streaming session still shows the others working.'],
      ['2', '<b>Title + backend subtitle.</b> Which local AI is answering is permanent context, not a hidden setting.'],
      ['3', '<b>Session status pill</b> in the nav bar, same vocabulary as the list — one status language across screens.'],
      ['4', '<b>Skill invocation is a system divider</b> in the transcript, not a hidden prefix. You can see when the conversation changed mode.'],
      ['5', '<b>Streaming bubble</b> with a caret, tokens appearing live. The <i>Stop</i> control replaces <i>Send</i> while generating.'],
      ['6', '<b>Backend switcher</b> in the composer. Switching mid-thread is a first-class act — tap opens the picker (screen 02b).'],
      ['7', '<b>Skills affordance.</b> The <code>/</code> button opens the skill picker; typing <code>/</code> in the field does the same.'],
      ['8', '<b>Armed skill chip</b> above the field shows the active mode and can be dismissed with one tap.'],
      ['9', '<b>Per-message actions</b> (copy, retry, retry-on-another-backend) appear on the last AI message.']
    ],
    flows: [
      'Tap backend switcher → <code>Backend picker</code>',
      'Tap <code>/</code> → <code>Skill picker</code>',
      'Tap back → <code>Sessions</code>'
    ],
    pins: null,
    render: function () {
      return statusBar() +
        '<div class="navbar">' +
          '<div class="nb-left"><span class="nb-btn" data-goto="sessions" data-note="1">&#8249; ' +
            '<span class="pill streaming" style="margin-left:2px">2</span></span></div>' +
          '<div class="nb-title" data-note="2"><div class="t">Refactor auth module</div>' +
            '<div class="s">Claude &middot; mac-studio.local</div></div>' +
          '<div class="nb-right"><span data-note="3">' + pill('streaming', 'Streaming') + '</span></div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll bottom"><div class="thread">' +
          '<div class="msg me"><div class="bubble">Look at how we refresh the auth token — it races the keychain read on cold start.</div></div>' +
          '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
            '<span class="who">Claude</span></div>' +
            '<div class="bubble">Found it. <code style="font-family:var(--mono);font-size:13px">TokenStore.refresh()</code> ' +
            'reads from the keychain on a background queue while the session task is already awaiting the result.</div></div>' +
          '<div class="divider-sys" data-note="4">&#9670; Skill ' +
            '<b style="color:var(--primary-text);margin:0 3px">/code-review</b> applied</div>' +
          '<div class="msg me"><div class="bubble">Review the fix with that skill.</div></div>' +
          '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
            '<span class="who">Claude</span>' + pill('streaming', 'Generating') + '</div>' +
            '<div class="bubble" data-note="5">Two things stand out. First, the actor isolation is right but the ' +
            '<code style="font-family:var(--mono);font-size:13px">await</code> ordering still allows a second caller in:' +
            '<div class="code">actor TokenStore {\n  private var refresh: Task&lt;Token, Error&gt;?\n\n  func token() async throws -&gt; Token {\n    if let refresh { return try await</div>' +
            '<span class="caret"></span></div>' +
            '<div class="msg-actions" data-note="9"><span>Copy</span><span>Retry</span><span>Retry on…</span></div>' +
          '</div>' +
        '</div></div></div>' +
        '<div class="composer">' +
          '<div class="armed-row"><span class="armed" data-note="8">&#9670; /code-review <span class="x">&times;</span></span></div>' +
          '<div class="composer-bar">' +
            '<span class="backend-switcher" data-goto="backend-picker" data-note="6">' + badge('claude', 'sm') +
              ' Claude <span style="color:var(--text-3)">&#9662;</span></span>' +
            '<span class="cbtn" data-goto="skill-picker" data-note="7" title="Skills">/</span>' +
            '<span class="cfield">Message…</span>' +
            '<span class="cbtn stop" title="Stop generating">&#9632;</span>' +
          '</div>' +
        '</div>';
    }
  };

  // ── 2b. Backend picker (overlay on chat) ─────────────────────────────────

  var backendPicker = {
    id: 'backend-picker',
    name: 'Backend picker',
    idx: '02b',
    desc: 'Switch which local AI answers, mid-thread. Reachability, availability and consequence are all on screen.',
    notes: [
      ['1', '<b>Anchored to the switcher</b> it came from, not a full-screen push — you never lose the thread.'],
      ['2', '<b>Reachability is per-backend.</b> A backend can be down while the bridge is up; unreachable entries are dimmed and unselectable, with the reason inline.'],
      ['3', '<b>Consequence stated in place:</b> switching applies to the <i>next</i> message; history stays attributed to whoever wrote it. This is the single most confusable behaviour in the app.'],
      ['4', '<b>Manage backends</b> escapes to Settings rather than dead-ending when the one you want is missing.']
    ],
    flows: [
      'Tap a backend → back to <code>Chat</code> with the new one armed',
      'Tap <code>Manage</code> → <code>Settings</code>',
      'Tap scrim → dismiss'
    ],
    pins: null,
    render: function () {
      var rows = [
        { k: 'claude', d: 'Ready · 12ms', sel: true },
        { k: 'openclaw', d: 'Ready · 31ms' },
        { k: 'hermes', d: 'Ready · 44ms' },
        { k: 'kimi', d: 'Ready · 58ms' },
        { k: 'codex', d: 'Unreachable · connection refused', off: true, note: '2' }
      ];
      return chat.render() +
        '<div class="scrim" data-goto="chat"></div>' +
        '<div class="menu" style="left:14px;bottom:96px;width:290px">' +
          '<div class="mtitle" data-note="1">Answer with</div>' +
          rows.map(function (r) {
            return '<div class="mrow' + (r.sel ? ' sel' : '') + (r.off ? ' opt dim' : '') + '" data-goto="chat"' +
              (r.note ? ' data-note="' + r.note + '"' : '') + '>' +
              badge(r.k, 'md') +
              '<div style="min-width:0"><div style="font-weight:600">' + BACKENDS[r.k].label + '</div>' +
              '<div style="font-size:11px;color:' + (r.off ? 'var(--danger)' : 'var(--text-2)') +
              ';font-family:var(--mono)">' + esc(r.d) + '</div></div>' +
              (r.sel ? '<span class="check">&#10003;</span>' : '') + '</div>';
          }).join('') +
          '<div data-note="3" style="padding:9px 13px;font-size:11px;color:var(--text-2);background:var(--inner);border-top:1px solid var(--border);line-height:1.45">' +
            'Applies to your next message. Earlier replies stay attributed to the backend that wrote them.' +
          '</div>' +
          '<div class="mrow" data-goto="settings" data-note="4" style="color:var(--primary);border-top:1px solid var(--border)">' +
            '&#9881; Manage backends…</div>' +
        '</div>';
    }
  };

  // ── 2c. Skill picker (overlay on chat) ───────────────────────────────────

  var skillPicker = {
    id: 'skill-picker',
    name: 'Skill picker',
    idx: '02c',
    desc: 'Invoke a reusable chat skill from inside the thread — the slash-command surface.',
    notes: [
      ['1', '<b>Half-height sheet</b> so the thread stays visible behind it — the skill is applied <i>to this conversation</i>, and the context proves it.'],
      ['2', '<b>Type-to-filter mirrors the <code>/</code> field.</b> Opening the sheet and typing <code>/co</code> in the composer are the same interaction.'],
      ['3', '<b>Recent first.</b> Skill use is heavily repetitive; alphabetical would bury the two you actually run.'],
      ['4', '<b>Each row previews what the skill does</b> in one line — a bare name is unusable once you have more than about six.'],
      ['5', '<b>Skills that take an argument</b> are marked, so tapping leads to a filled composer instead of firing immediately.'],
      ['6', '<b>Browse all</b> escapes to the full Skills browser (screen 04).']
    ],
    flows: [
      'Tap a skill → <code>Chat</code> with it armed',
      'Tap <code>Browse all</code> → <code>Skills</code>',
      'Swipe down / scrim → dismiss'
    ],
    pins: null,
    render: function () {
      function srow(name, desc, arg, recent, note) {
        return '<div class="opt" data-goto="chat"' + (note ? ' data-note="' + note + '"' : '') + '>' +
          '<div class="badge md" style="background:var(--primary-subtle);color:var(--primary-text);' +
            'border-color:var(--primary-border)">&#9670;</div>' +
          '<div class="otext"><div class="oname">/' + esc(name) +
            (arg ? '<span class="pill neutral">takes input</span>' : '') +
            (recent ? '<span class="pill neutral">recent</span>' : '') + '</div>' +
            '<div class="odesc">' + esc(desc) + '</div></div>' +
          '<span class="chev" style="color:var(--text-3)">&#8250;</span></div>';
      }
      return chat.render() +
        '<div class="scrim" data-goto="chat"></div>' +
        '<div class="sheet" style="max-height:62%" data-note="1">' +
          '<div class="grabber"></div>' +
          '<div class="sheet-nav"><span></span><span class="t">Skills</span>' +
            '<span class="nb-btn" style="justify-self:end" data-goto="skills" data-note="6">Browse all</span></div>' +
          '<div class="sheet-body">' +
            '<div class="search" data-note="2"><span>/</span><span>Filter skills…</span></div>' +
            '<div class="section-header" data-note="3">Recently used</div>' +
            '<div class="list">' +
              srow('code-review', 'Review a diff for correctness, then risk, then style.', false, true, '4') +
              srow('brainstorming', 'Widen the option space before committing to one.', false, true) +
            '</div>' +
            '<div class="section-header">All skills</div>' +
            '<div class="list">' +
              srow('research', 'Gather sources, then answer with citations.', true, false, '5') +
              srow('debug', 'Reproduce, isolate, then propose the smallest fix.', true) +
              srow('translate', 'Translate while holding a fixed glossary.', true) +
            '</div>' +
          '</div>' +
        '</div>';
    }
  };

  // ── 3. New session ───────────────────────────────────────────────────────

  var newSession = {
    id: 'new-session',
    name: 'New session',
    idx: '03',
    desc: 'Pick a backend, optionally arm a skill, start. Two decisions, one screen — no wizard.',
    notes: [
      ['1', '<b>Modal sheet, not a push.</b> Creating a session is cancellable and shallow; a nav push would imply a longer commitment.'],
      ['2', '<b>Backend choice is step one and required.</b> It is the only field with no safe default — the rest can be changed later without consequence.'],
      ['3', '<b>Live reachability per backend,</b> checked when the sheet opens. An unreachable backend is visible but unselectable, with the reason stated.'],
      ['4', '<b>Skill is explicitly optional</b> — "None" is a real, pre-selected row, so an empty choice is never ambiguous.'],
      ['5', '<b>Title is optional and auto-derived</b> from the first message if left blank. Naming a conversation before having it is a chore.'],
      ['6', '<b>Start is disabled until a backend is chosen,</b> and the button restates the choice so the last thing you read is what you get.']
    ],
    flows: [
      'Tap <code>Start session</code> → <code>Chat</code>',
      'Tap <code>Cancel</code> → <code>Sessions</code>',
      'Tap skill row → inline skill list'
    ],
    pins: null,
    render: function () {
      function brow(k, meta, sel, off, note) {
        return '<div class="opt' + (sel ? ' sel' : '') + (off ? ' dim' : '') + '"' +
          (note ? ' data-note="' + note + '"' : '') + '>' +
          badge(k, 'md') +
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
            '<div class="section-header" data-note="2">1 &middot; Backend ' +
              '<span style="color:var(--danger)">Required</span></div>' +
            '<div class="list">' +
              brow('claude', 'Ready · 12ms', true) +
              brow('openclaw', 'Ready · 31ms') +
              brow('hermes', 'Ready · 44ms') +
              brow('kimi', 'Ready · 58ms') +
              brow('codex', 'Unreachable · connection refused', false, true, '3') +
            '</div>' +
            '<div class="section-header">2 &middot; Start with a skill <span style="color:var(--text-3)">Optional</span></div>' +
            '<div class="list">' +
              '<div class="opt sel" data-note="4"><div class="badge md" style="background:var(--inner);color:var(--text-3);' +
                'border-color:var(--border)">&#8212;</div>' +
                '<div class="otext"><div class="oname">None</div>' +
                '<div class="odesc">Plain conversation. You can add a skill any time.</div></div>' +
                '<span class="radio">&#10003;</span></div>' +
              '<div class="opt"><div class="badge md" style="background:var(--primary-subtle);' +
                'color:var(--primary-text);border-color:var(--primary-border)">&#9670;</div>' +
                '<div class="otext"><div class="oname">/code-review</div>' +
                '<div class="odesc">Review a diff for correctness, then risk, then style.</div></div>' +
                '<span class="radio"></span></div>' +
              '<div class="opt"><div class="badge md" style="background:var(--primary-subtle);' +
                'color:var(--primary-text);border-color:var(--primary-border)">&#9670;</div>' +
                '<div class="otext"><div class="oname">/research</div>' +
                '<div class="odesc">Gather sources, then answer with citations.</div></div>' +
                '<span class="radio"></span></div>' +
              '<div class="opt" data-goto="skills"><div class="badge md" style="background:var(--inner);' +
                'color:var(--primary);border-color:var(--border)">&#8942;</div>' +
                '<div class="otext"><div class="oname" style="color:var(--primary)">Browse all skills</div></div>' +
                '<span class="chev" style="color:var(--text-3)">&#8250;</span></div>' +
            '</div>' +
            '<div class="section-header">3 &middot; Title <span style="color:var(--text-3)">Optional</span></div>' +
            '<div class="card"><div class="field" data-note="5">' +
              '<span class="fvalue" style="margin:0;text-align:left;flex:1;color:var(--text-3)">' +
              'Named from your first message</span></div></div>' +
          '</div>' +
          '<div class="sheet-foot">' +
            '<div class="btn" data-note="6">Start session with Claude</div>' +
          '</div>' +
        '</div>';
    }
  };

  // ── 4. Skills browser ────────────────────────────────────────────────────

  var skills = {
    id: 'skills',
    name: 'Skills',
    idx: '04',
    desc: 'The reusable prompt/skill library — installed skills, their source, and what each one is for.',
    notes: [
      ['1', '<b>Skills are a peer of sessions,</b> not a settings sub-page — they are content you build up and reuse.'],
      ['2', '<b>Coverage metric with a sparkline.</b> Installed count and 30-day usage together answer "is my library actually earning its keep".'],
      ['3', '<b>Grouped by source</b> (bundled / repo / yours), following the shape of engineering-skill repos like mattpocock/skills. Source determines update behaviour, so it drives the grouping.'],
      ['4', '<b>Every skill states its purpose in one line</b> — the "when to use this" line, which is what a skill actually is.'],
      ['5', '<b>Backend compatibility.</b> A skill can be tuned for specific backends; the row says so rather than failing later.'],
      ['6', '<b>Usage count, tabular,</b> makes stale skills obvious without a separate audit screen.'],
      ['7', '<b>Add from repo / write your own.</b> The install path is on the browser, not hidden in settings.'],
      ['8', '<b>Tapping a skill</b> opens its detail: full prompt body, arguments, edit, and "start a session with this".']
    ],
    flows: [
      'Tap a skill → skill detail (not yet drawn)',
      'Tap <code>+</code> → add from repo / write your own',
      'Tab bar → <code>Sessions</code> / <code>Settings</code>'
    ],
    pins: null,
    render: function () {
      function srow(name, desc, uses, compat, note, compatNote) {
        return '<div class="row"' + (note ? ' data-note="' + note + '"' : '') + '>' +
          '<div class="badge" style="background:var(--primary-subtle);color:var(--primary-text);' +
            'border-color:var(--primary-border)">&#9670;</div>' +
          '<div class="rmain">' +
            '<div class="rtop"><span class="rtitle">/' + esc(name) + '</span>' +
            '<span class="rtime"' + (uses === '42' ? ' data-note="6"' : '') + '>' + esc(uses) + ' uses</span></div>' +
            '<div class="rsub">' + esc(desc) + '</div>' +
            (compat ? '<div class="rmeta"><span class="pill neutral"' +
              (compatNote ? ' data-note="' + compatNote + '"' : '') + '>' + esc(compat) + '</span></div>' : '') +
          '</div><span class="chev">&#8250;</span></div>';
      }
      return statusBar() +
        '<div class="navbar large">' +
          '<div class="lt-row"><div class="lt" data-note="1">Skills</div>' +
          '<div style="display:flex;align-items:center;gap:14px">' +
            '<span class="nb-icon" title="Sort">&#8942;</span>' +
            '<span class="nb-icon" data-note="7" title="Add skill">+</span>' +
          '</div></div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll">' +
          '<div class="search"><span>&#9906;</span><span>Search skills</span></div>' +
          '<div class="card"><div class="card-inner metric-row" data-note="2">' +
            '<div class="metric"><div class="mv">11</div><div class="ml">skills installed</div></div>' +
            '<div class="metric"><div class="mv">128</div><div class="ml">runs, last 30 days</div></div>' +
            sparkline([3, 6, 4, 9, 7, 12, 10, 16, 14, 19]) +
          '</div></div>' +
          '<div class="section-header" data-note="3"><span>Bundled</span>' +
            '<span style="font-family:var(--mono);color:var(--text-3)">4</span></div>' +
          '<div class="list">' +
            srow('code-review', 'Review a diff for correctness, then risk, then style.', '42', 'All backends', '8') +
            srow('brainstorming', 'Widen the option space before committing to one.', '31', 'All backends', '4') +
            srow('debug', 'Reproduce, isolate, then propose the smallest fix.', '19', 'All backends') +
          '</div>' +
          '<div class="section-header"><span>From repo &middot; mattpocock/skills</span>' +
            '<span class="pill connected">Synced</span></div>' +
          '<div class="list">' +
            srow('test-driven-development', 'Write the failing test first, then the smallest passing change.',
              '17', 'Claude · Codex', null, '5') +
            srow('writing-plans', 'Turn a vague ask into a reviewable, ordered plan.', '12', 'All backends') +
          '</div>' +
          '<div class="section-header"><span>Yours</span><span style="font-family:var(--mono);color:var(--text-3)">4</span></div>' +
          '<div class="list">' +
            srow('translate', 'Translate while holding a fixed glossary.', '9', 'Kimi') +
            srow('standup', 'Turn my notes into a three-line standup update.', '4', 'All backends') +
          '</div>' +
          '<div class="footnote">Skills are prompt templates with a "when to use" line. Repo skills update when you pull; ' +
            'your own live only on this device and your Mac.</div>' +
        '</div></div>' +
        tabbar('skills');
    }
  };

  // ── 5. Settings / connection ─────────────────────────────────────────────

  var settings = {
    id: 'settings',
    name: 'Settings &middot; Connection',
    idx: '05',
    desc: 'Where the Mac bridge is configured. Deliberately abstract — the transport is still being decided by the spec.',
    notes: [
      ['1', '<b>Connection is the first and largest block.</b> If it is wrong, nothing else in the app works, so it outranks appearance and everything below.'],
      ['2', '<b>Reachability shown as a pill plus a measured number,</b> not just "connected" — latency is what tells you whether it is <i>usably</i> connected.'],
      ['3', '<b>Host address is one abstract field.</b> Whether this ends up as a LAN address, a pairing code, or a relay URL is a spec decision — the screen holds the slot without committing.'],
      ['4', '<b>Per-backend health list.</b> The bridge being up does not mean each backend is; each gets its own pill and last-seen time.'],
      ['5', '<b>Re-test is an explicit action,</b> not something you infer from pulling to refresh.'],
      ['6', '<b>Open decision marked in the UI.</b> Pairing/auth model is unresolved; the prototype shows the placeholder rather than inventing a flow the spec may contradict.'],
      ['7', '<b>Appearance follows the one seed system</b> — light/dark/system only, no theme fork.']
    ],
    flows: [
      'Tap host → edit address',
      'Tap a backend → backend detail',
      'Tab bar → <code>Sessions</code> / <code>Skills</code>'
    ],
    pins: null,
    render: function () {
      function hrow(k, status, text, seen, note) {
        return '<div class="field"' + (note ? ' data-note="' + note + '"' : '') + '>' + badge(k, 'md') +
          '<span class="flabel" style="margin-left:2px">' + BACKENDS[k].label + '</span>' +
          '<span style="margin-left:auto;display:flex;align-items:center;gap:8px">' +
          '<span style="font-size:11px;color:var(--text-3);font-family:var(--mono)">' + esc(seen) + '</span>' +
          pill(status, text) + '</span></div>';
      }
      return statusBar() +
        '<div class="navbar large"><div class="lt-row"><div class="lt">Settings</div></div></div>' +
        '<div class="body"><div class="body-scroll">' +
          '<div class="section-header" data-note="1">Connection</div>' +
          '<div class="card">' +
            '<div class="field"><span class="flabel">Status</span>' +
              '<span data-note="2" style="margin-left:auto;display:flex;align-items:center;gap:8px">' +
              '<span style="font-family:var(--mono);font-size:13px;font-variant-numeric:tabular-nums">12 ms</span>' +
              pill('connected', 'Connected') + '</span></div>' +
            '<div class="field"><span class="flabel">Host / bridge</span>' +
              '<span class="fvalue mono-strong" data-note="3">mac-studio.local</span>' +
              '<span class="chev" style="color:var(--text-3)">&#8250;</span></div>' +
            '<div class="field"><span class="flabel">Pairing</span>' +
              '<span class="fvalue">Not configured</span>' +
              '<span class="chev" style="color:var(--text-3)">&#8250;</span></div>' +
            '<div class="field"><span class="flabel">Reconnect automatically</span>' +
              '<span style="margin-left:auto"><span class="toggle on"></span></span></div>' +
            '<div style="padding:10px 12px"><div class="btn ghost sm" data-note="5">Test connection</div></div>' +
          '</div>' +
          '<div class="tbd" data-note="6"><b>Open &middot; spec decision</b>' +
            'The transport and pairing model are still being decided. This screen holds one abstract ' +
            '"host / bridge address" slot plus a pairing row; whether that resolves to a LAN address, a ' +
            'QR pairing code, or a relay URL does not change the layout.</div>' +
          '<div class="section-header"><span>Backends</span><span class="pill connected">4 of 5 up</span></div>' +
          '<div class="card">' +
            hrow('claude', 'connected', 'Ready', '12ms', '4') +
            hrow('openclaw', 'connected', 'Ready', '31ms') +
            hrow('hermes', 'connected', 'Ready', '44ms') +
            hrow('kimi', 'connected', 'Ready', '58ms') +
            hrow('codex', 'offline', 'Offline', '2m ago') +
          '</div>' +
          '<div class="section-header" data-note="7">Appearance</div>' +
          '<div class="card">' +
            '<div class="field"><span class="flabel">Theme</span>' +
              '<span class="fvalue mono-strong">System</span>' +
              '<span class="chev" style="color:var(--text-3)">&#8250;</span></div>' +
            '<div class="field"><span class="flabel">Accent</span>' +
              '<span class="fvalue mono-strong">Apple Blue</span>' +
              '<span class="chev" style="color:var(--text-3)">&#8250;</span></div>' +
          '</div>' +
          '<div class="section-header">About</div>' +
          '<div class="card">' +
            '<div class="field"><span class="flabel">Version</span>' +
              '<span class="fvalue">0.1.0 (prototype)</span></div>' +
          '</div>' +
          '<div class="footnote">Localis talks only to your own machine. No conversation leaves your network.</div>' +
        '</div></div>' +
        tabbar('settings');
    }
  };

  // ── 6. Empty / first-run state ───────────────────────────────────────────

  var empty = {
    id: 'empty',
    name: 'First run &middot; not connected',
    idx: '06',
    desc: 'The state a new user actually lands in: no bridge, no sessions. The wireframe has to survive this.',
    notes: [
      ['1', '<b>Failure is stated as a pill, at the top,</b> in the same slot the healthy state uses — the layout does not reorganise between states.'],
      ['2', '<b>The empty state names the one blocking action.</b> "No sessions yet" alone would be useless when the real problem is upstream.'],
      ['3', '<b>Primary action is connecting, not creating.</b> Creating a session while the bridge is down would fail — so it is demoted to secondary.'],
      ['4', '<b>The Mac-side prerequisite is spelled out,</b> because it is genuinely not discoverable from the phone.'],
      ['5', '<b>Skills stay reachable while offline</b> — you can read and write skills without a bridge, so the tab is not disabled.']
    ],
    flows: [
      'Tap <code>Connect to your Mac</code> → <code>Settings</code>',
      'Tab bar → <code>Skills</code> still available offline'
    ],
    pins: null,
    render: function () {
      return statusBar() +
        '<div class="navbar large">' +
          '<div class="lt-row"><div class="lt">Sessions</div>' +
            '<div><span class="nb-icon" style="opacity:0.4">+</span></div></div>' +
          '<div style="display:flex;align-items:center;gap:8px;margin:6px 0 2px">' +
            '<span data-note="1">' + pill('offline', 'No bridge') + '</span>' +
            '<span style="font-size:11px;color:var(--text-2);font-family:var(--mono)">Not configured</span>' +
          '</div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll" style="display:flex;align-items:center;justify-content:center;padding:0 28px">' +
          '<div style="text-align:center;margin-top:-60px">' +
            '<div style="width:64px;height:64px;border-radius:18px;border:1px dashed var(--border);' +
              'display:grid;place-items:center;margin:0 auto 16px;color:var(--text-3);font-size:24px">&#9633;</div>' +
            '<div style="font-size:20px;font-weight:650;letter-spacing:-0.02em" data-note="2">Connect to your Mac</div>' +
            '<div style="font-size:14px;color:var(--text-2);line-height:1.5;margin-top:7px">' +
              'Localis talks to the AI tools already running on your machine. ' +
              'Point it at your Mac to start a session.</div>' +
            '<div class="btn" style="margin-top:22px" data-goto="settings" data-note="3">Connect to your Mac</div>' +
            '<div class="btn ghost" style="margin-top:10px" data-goto="skills" data-note="5">Browse skills offline</div>' +
            '<div style="font-size:11px;color:var(--text-3);margin-top:20px;line-height:1.55" data-note="4">' +
              'Requires the Localis helper running on your Mac, on the same network.</div>' +
          '</div>' +
        '</div></div>' +
        tabbar('sessions');
    }
  };

  global.Screens = [sessions, chat, backendPicker, skillPicker, newSession, skills, settings, empty];
})(window);
