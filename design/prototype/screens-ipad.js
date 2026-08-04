/**
 * screens-ipad.js — the iPad layer (pass B).
 *
 * Split from screens.js so neither file outgrows the 800-line ceiling and so
 * the iPad delta reads on its own. Every screen here is built from the SAME
 * partials as the phone screens (model.js) — if a divergence is not stated in
 * a design note, it does not exist.
 *
 * THE ONE STRUCTURAL DIFFERENCE
 * -----------------------------
 * iPhone put the reachable controls at the bottom. That was a rule about
 * where the thumb is, not about the bottom edge. An iPad is held two-handed
 * or propped on a desk, and iPadOS 26 floats the tab bar at the TOP of the
 * window — so the same rule lands elsewhere: destinations and search move to
 * the top chrome, while create and compose stay at the bottom of their own
 * column, where a resting thumb still is.
 */
(function (global) {
  'use strict';

  var M = global.M;
  var esc = M.esc, note = M.note, badge = M.badge, pill = M.pill;
  var hostMark = M.hostMark, qualified = M.qualified, hostSwitch = M.hostSwitch;
  var statusBar = M.statusBar, sessionRow = M.sessionRow, tabBar = M.tabBar;

  /** iPad status bar carries no notch cut-out, so it is one flat row. */
  function padStatus() {
    return '<div class="status-bar"><span>9:41 Mon 3 Aug</span>' +
      '<span class="sb-right"><span>&#9679;&#9679;&#9679;</span><i></i></span></div>';
  }

  /**
   * The top chrome: sidebar toggle (leading), floating tab bar (centred),
   * host switcher (trailing). The tab bar is the identical capsule from the
   * phone — `M.tabBar({top:true})` — anchored to the other edge.
   */
  function padChrome(o) {
    var opts = o || {};
    return '<div class="pad-chrome">' +
      '<div class="lead">' +
        '<span class="side-toggle glass' + (opts.sidebarOff ? ' off' : '') + '"' +
          note(opts.toggleNote) + ' data-goto="' + (opts.toggleGo || 'pad-sessions') + '">' +
          '<span class="ic"></span><span>' +
          (opts.sidebarOff ? 'Show sessions' : 'Sessions') + '</span></span>' +
      '</div>' +
      tabBar({
        top: true, active: opts.active,
        searchGoto: opts.searchGoto, searchNote: opts.searchNote,
        barNote: opts.barNote
      }) +
      '<div class="trail">' + hostSwitch(opts.host || 'mac-studio', opts.hostNote) + '</div>' +
    '</div>';
  }

  // ── 07. iPad · Sessions + Chat (the split) ──────────────────────────────

  var padSessions = {
    id: 'pad-sessions',
    name: 'iPad &middot; split view',
    idx: '07',
    pad: true,
    desc: 'The same app on an 11-inch iPad, landscape. Sessions and the thread are visible at once — which changes what the layout is FOR, not just how big it is.',
    notes: [
      ['1', '<b>The tab bar moves to the top — and that is the same rule, not a different one.</b> Bottom-anchoring on iPhone was about where a thumb reaches on a one-handed device. An iPad is held two-handed or propped, iPadOS 26 floats its tab bar at the top of the window, and the bottom of a 1194pt canvas is nowhere near a resting thumb. Identical capsule, identical material, identical search role — only the anchored edge changed. It gains labels here because there is room and the row is no longer a thumb target.'],
      ['2', '<b>Search stays a tab</b>, in the same relative position past the same hairline. Activating it drops a field under the bar rather than over a keyboard, because a hardware keyboard is likely and the software one covers the bottom half of the screen — the one place there is no content to protect on iPhone, and the detail pane on iPad.'],
      ['3', '<b>The host switcher moves to the trailing corner</b> of the top chrome. On iPhone it lived in the large title because the title was the only persistent surface; here the chrome is persistent, so host — which scopes the whole window — belongs beside the destinations it scopes.'],
      ['4', '<b>The sidebar is flat, not glass.</b> It is in-flow, and it holds the densest running text in the app (six previews, stacked). Both halves of the rule in glass.css point the same way: only floating chrome is translucent, and body copy never sits on a moving backdrop.'],
      ['5', '<b>Selection is persistent and visible.</b> This is the real structural difference from iPhone: there is no push-and-pop, so a row is always selected and the detail pane is always showing it. Accent bar plus tint, not just a highlight, because it must survive against a scrolling list.'],
      ['6', '<b>Host grouping earns its keep here.</b> On the phone it is a header you scroll past; on iPad every host is on screen at once, so the sidebar is the closest thing the app has to a map of your machines.'],
      ['7', '<b>Create stays bottom-anchored, but moves to the LEADING corner.</b> Its trailing corner now abuts the composer in the next pane, and two accent controls a few points apart would read as one control with two meanings. It also lands directly under the list it creates into.'],
      ['8', '<b>The transcript is capped at a reading measure and centred</b>, not stretched to the pane. The extra canvas buys CONTEXT — two panes at once — never longer lines. The gutters are deliberate, and they are where message actions and timestamps go rather than crowding the bubble.'],
      ['9', '<b>The composer matches the measure, not the window</b>, and floats the same 21pt from the bottom of its own pane. It is still the opaque glass for the same reason as on iPhone.'],
      ['10', '<b>A hardware keyboard is assumed to exist.</b> Shortcuts are shown inline rather than hidden in a menu — this is the first surface in the app where a physical keyboard is likely, and it changes what "reachable" means again.'],
      ['11', '<b>Two panes, one host scope.</b> The window is scoped to a host; the sidebar can show all of them. The thread can never disagree with the sidebar about which machine it is on, because the thread is always the selected row.']
    ],
    flows: [
      'Tap a sidebar row → the detail pane swaps, no navigation',
      'Tap the host switcher → <code>Host picker</code>',
      'Tap <code>+</code> → <code>New session</code>',
      'Collapse the sidebar → <code>iPad &middot; focused</code>'
    ],
    pins: null,
    render: function () {
      return padStatus() +
        padChrome({
          active: 'sessions', barNote: '1',
          searchGoto: 'pad-sessions', searchNote: '2',
          host: 'mac-studio', hostNote: '3',
          toggleGo: 'pad-chat'
        }) +
        '<div class="pad-body">' +

          // ── Sidebar ──────────────────────────────────────────────────
          '<div class="pad-side" data-note="4">' +
            '<div class="pad-side-head">' +
              '<div style="display:flex;align-items:center;gap:8px;margin-bottom:2px">' +
                '<span style="font-size:20px;font-weight:700">Sessions</span>' +
                '<span style="margin-left:auto">' + pill('connected', '2 of 3') + '</span>' +
              '</div>' +
              '<div class="chip-row" style="padding-left:0;padding-right:0">' +
                '<span class="chip on">All hosts &middot; 6</span>' +
                '<span class="chip">Live 2</span>' +
              '</div>' +
            '</div>' +
            '<div class="pad-side-scroll">' +
              '<div class="section-header"><span>Live</span>' +
                '<span style="font-family:var(--mono);color:var(--text-3)">2</span></div>' +
              '<div class="list">' +
                sessionRow({
                  backend: 'claude', host: 'mac-studio', title: 'Refactor auth module',
                  time: 'now', sel: true, note: '5',
                  preview: 'Extracting the token refresh into its own actor…',
                  status: 'streaming', statusText: 'Streaming'
                }) +
                sessionRow({
                  backend: 'codex', host: 'mac-studio', title: 'Migrate test suite',
                  time: '2m', preview: 'Connection refused on port 7331 —',
                  status: 'error', statusText: 'Error'
                }) +
              '</div>' +
              '<div class="section-header"><span>Recent</span>' +
                '<span style="font-family:var(--mono);color:var(--text-3)">3</span></div>' +
              '<div class="list">' +
                sessionRow({
                  backend: 'claude', host: 'macbook', title: 'Weekend trip planning',
                  time: '18m', preview: 'Three routes under four hours, ranked…',
                  status: 'connected', statusText: 'Connected'
                }) +
                sessionRow({
                  backend: 'hermes', host: 'macbook', title: 'Review PR #482',
                  time: '1h', preview: 'The migration looks reversible, but…',
                  status: 'idle', statusText: 'Idle'
                }) +
                sessionRow({
                  backend: 'openclaw', host: 'mac-studio', title: 'Localis spec notes',
                  time: 'Mon', preview: 'Summarised the bridge options and flagged…',
                  status: 'idle', statusText: 'Idle'
                }) +
              '</div>' +
              '<div class="host-group" data-note="6">' + hostMark('nas') +
                '<span>nas</span>' +
                '<span class="pill offline" style="margin-left:6px">Asleep</span></div>' +
              '<div class="list" style="opacity:0.55">' +
                sessionRow({
                  backend: 'kimi', host: 'nas', title: 'Translate release notes',
                  time: 'Yest.', preview: '已完成第一版翻译，术语表已对齐。',
                  status: 'idle', statusText: 'Idle'
                }) +
              '</div>' +
            '</div>' +
            '<div class="edge-fade bottom" style="height:88px"></div>' +
            '<div class="pad-side-dock">' +
              '<div class="island glass accent" data-goto="new-session" data-note="7" ' +
                'title="New session">+</div>' +
            '</div>' +
          '</div>' +

          // ── Detail: the thread ───────────────────────────────────────
          '<div class="pad-detail">' +
            '<div class="pad-detail-head">' +
              '<div data-note="11"><div class="dt">Refactor auth module</div>' +
                '<div class="ds">' + qualified('claude', 'mac-studio') + '</div></div>' +
              '<div class="dacts">' + pill('streaming', 'Streaming') +
                '<span class="dbtn" title="Search in thread">&#9906;</span>' +
                '<span class="dbtn" title="Session info">i</span></div>' +
            '</div>' +
            '<div class="pad-detail-body">' +
              '<div class="body-scroll" style="padding-bottom:120px">' +
                '<div class="measure" data-note="8"><div class="thread">' +
                  '<div class="msg me"><div class="bubble">Look at how we refresh the auth ' +
                    'token — it races the keychain read on cold start.</div></div>' +
                  '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
                    '<span class="who">Claude &middot; mac-studio</span></div>' +
                    '<div class="bubble">Found it. <code style="font-family:var(--mono);' +
                    'font-size:13px">TokenStore.refresh()</code> reads from the keychain on a ' +
                    'background queue while the session task is already awaiting the result.' +
                    '</div></div>' +
                  '<div class="msg me"><div class="bubble">Review the fix for correctness, then risk.</div></div>' +
                  '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
                    '<span class="who">Claude &middot; mac-studio</span>' +
                    pill('streaming', 'Generating') + '</div>' +
                    '<div class="bubble">Two things stand out. First, the actor isolation is ' +
                    'right but the <code style="font-family:var(--mono);font-size:13px">await' +
                    '</code> ordering still allows a second caller in:' +
                    '<div class="code">actor TokenStore {\n  private var refresh: Task&lt;Token, Error&gt;?\n\n  func token() async throws -&gt; Token {\n    if let refresh { return try await</div>' +
                    '<span class="caret"></span></div>' +
                    '<div class="msg-actions"><span>Copy</span><span>Retry</span>' +
                      '<span>Retry on…</span></div>' +
                  '</div>' +
                '</div></div>' +
              '</div>' +
              '<div class="edge-fade bottom" style="height:104px"></div>' +
              '<div class="composer-float pad glass opaque" data-note="9">' +
                  '<div class="kbdrow"><span class="kbd" data-note="10">&#8984;&#8617; send' +
                  '</span></div>' +
                '<div class="composer-bar">' +
                  '<span class="backend-switcher" data-goto="backend-picker">' +
                    badge('claude', 'sm') +
                    '<span style="display:flex;flex-direction:column;line-height:1.15;' +
                      'align-items:flex-start"><span>Claude</span>' +
                      '<span style="font-family:var(--mono);font-size:9px;color:var(--text-3);' +
                        'font-weight:500">mac-studio</span></span>' +
                    '<span style="color:var(--text-3)">&#9662;</span></span>' +
                  '<span class="cbtn" data-goto="skill-picker" title="Skills">/</span>' +
                  '<span class="cfield">Message…</span>' +
                  '<span class="cbtn stop" title="Stop generating">&#9632;</span>' +
                '</div>' +
              '</div>' +
            '</div>' +
          '</div>' +
        '</div>';
    }
  };

  // ── 08. iPad · focused / compact width ──────────────────────────────────

  var padChat = {
    id: 'pad-chat',
    name: 'iPad &middot; focused',
    idx: '08',
    pad: true,
    desc: 'The sidebar collapsed — by choice, by portrait, or by a narrow Split View. What the app degrades to when the second pane goes away.',
    notes: [
      ['1', '<b>One layout, three causes.</b> The sidebar collapses when you hide it, when the iPad is in portrait, and when the app is in a narrow Split View or Slide Over. Drawing one state for all three is the point: the app must not have three layouts to maintain, and the user must not learn three.'],
      ['2', '<b>The toggle stays where it was and changes label, not position.</b> The way back is in the same pixel the way out was — collapsing a pane must never leave you hunting for the list.'],
      ['3', '<b>The tab bar does not move or shrink.</b> Destinations are the last thing that should reflow when the window does; this is the one piece of chrome that is identical in every iPad state.'],
      ['4', '<b>The thread keeps the SAME reading measure</b> it had beside the sidebar. That is the payoff of capping it: hiding the sidebar re-centres the text but does not reflow a single line, so nothing you were reading moves. Only the gutters grow.'],
      ['5', '<b>The collapsed sidebar leaves a trace, not a hole.</b> Session title and its qualified backend stay in the detail header, so a collapsed pane never costs you the answer to "which machine is this?".'],
      ['6', '<b>Create moves back into the detail chrome</b> when its column is gone. It is the only control here that has no home of its own, and losing it silently would be worse than moving it.'],
      ['7', '<b>Below a threshold this becomes the iPhone layout, not a squeezed iPad one</b> — floating bottom tab bar, pushed navigation. That is the compact size class doing its job, and it is why the two layouts share every partial: the switch is a layout change, never a different app.']
    ],
    flows: [
      'Tap the toggle → <code>iPad &middot; split view</code>',
      'Narrower than a threshold → the iPhone layout (screens 01–02)',
      'Tap the backend switcher → <code>Backend picker</code>'
    ],
    pins: null,
    render: function () {
      return padStatus() +
        padChrome({
          active: 'sessions', sidebarOff: true, toggleNote: '2',
          searchGoto: 'pad-sessions', barNote: '3',
          host: 'mac-studio', toggleGo: 'pad-sessions'
        }) +
        '<div class="pad-body" data-note="1">' +
          '<div class="pad-detail">' +
            '<div class="pad-detail-head">' +
              '<div data-note="5"><div class="dt">Refactor auth module</div>' +
                '<div class="ds">' + qualified('claude', 'mac-studio') + '</div></div>' +
              '<div class="dacts">' + pill('streaming', 'Streaming') +
                '<span class="dbtn" title="Search in thread">&#9906;</span>' +
                '<span class="dbtn" data-goto="new-session" data-note="6" ' +
                  'title="New session" style="border-style:solid;border-color:var(--primary-border);' +
                  'color:var(--primary)">+</span></div>' +
            '</div>' +
            '<div class="pad-detail-body">' +
              '<div class="body-scroll" style="padding-bottom:120px">' +
                '<div class="measure" data-note="4"><div class="thread">' +
                  '<div class="msg me"><div class="bubble">Look at how we refresh the auth ' +
                    'token — it races the keychain read on cold start.</div></div>' +
                  '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
                    '<span class="who">Claude &middot; mac-studio</span></div>' +
                    '<div class="bubble">Found it. <code style="font-family:var(--mono);' +
                    'font-size:13px">TokenStore.refresh()</code> reads from the keychain on a ' +
                    'background queue while the session task is already awaiting the result.' +
                    '</div></div>' +
                  '<div class="msg me"><div class="bubble">Review the fix for correctness, then risk.</div></div>' +
                  '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
                    '<span class="who">Claude &middot; mac-studio</span>' +
                    pill('streaming', 'Generating') + '</div>' +
                    '<div class="bubble">Two things stand out. First, the actor isolation is ' +
                    'right but the <code style="font-family:var(--mono);font-size:13px">await' +
                    '</code> ordering still allows a second caller in:' +
                    '<div class="code">actor TokenStore {\n  private var refresh: Task&lt;Token, Error&gt;?\n\n  func token() async throws -&gt; Token {\n    if let refresh { return try await</div>' +
                    '<span class="caret"></span></div>' +
                    '<div class="msg-actions"><span>Copy</span><span>Retry</span>' +
                      '<span>Retry on…</span></div>' +
                  '</div>' +
                '</div></div>' +
              '</div>' +
              '<div class="pad-gutter-note l" data-note="7">Narrower than this and the ' +
                'compact size class takes over — the iPhone layout, not a squeezed iPad one.</div>' +
              '<div class="edge-fade bottom" style="height:104px"></div>' +
              '<div class="composer-float pad glass opaque">' +
                  '<div class="kbdrow"><span class="kbd">&#8984;&#8617; send</span></div>' +
                '<div class="composer-bar">' +
                  '<span class="backend-switcher" data-goto="backend-picker">' +
                    badge('claude', 'sm') +
                    '<span style="display:flex;flex-direction:column;line-height:1.15;' +
                      'align-items:flex-start"><span>Claude</span>' +
                      '<span style="font-family:var(--mono);font-size:9px;color:var(--text-3);' +
                        'font-weight:500">mac-studio</span></span>' +
                    '<span style="color:var(--text-3)">&#9662;</span></span>' +
                  '<span class="cbtn" data-goto="skill-picker" title="Skills">/</span>' +
                  '<span class="cfield">Message…</span>' +
                  '<span class="cbtn stop" title="Stop generating">&#9632;</span>' +
                '</div>' +
              '</div>' +
            '</div>' +
          '</div>' +
        '</div>';
    }
  };

  global.ScreensPad = [padSessions, padChat];
  global.Screens = (global.Screens || []).concat(global.ScreensPad);
})(window);
