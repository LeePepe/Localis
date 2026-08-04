/**
 * screens-activity.js — three surfaces the approved answers require.
 *
 *   09  Return to app       backgrounded streaming is a real promise, so the
 *                           moment you come back needs designing, not assuming
 *   10  Activity            what the machine is actually doing — rendered by
 *                           field presence, never a placeholder
 *   02e Skills · not loaded  the never-connected catalog state spec specified:
 *                           never an error, never a spinner
 *   11  Detached/interrupted still-running-elsewhere vs genuinely-lost — the
 *                           dangerous action is absent, not merely restyled
 *
 * DATA HONESTY
 * ------------
 * Everything drawn here is classified in the README as CERTAIN (a contract
 * request to the bridge) or CLIENT (derived locally). Nothing is invented: a
 * wireframe showing a number the bridge cannot produce is a promise someone
 * else has to keep.
 *
 * Telemetry renders BY FIELD PRESENCE. A value the backend does not report
 * makes its row disappear — there are no placeholder slots, because a
 * permanent "not available" implies the number is coming. And no cost figure
 * in any form: pricing moves with model and plan, so an on-device calculation
 * is stale the moment it renders.
 */
(function (global) {
  'use strict';

  var M = global.M;
  var esc = M.esc, note = M.note, badge = M.badge, pill = M.pill;
  var hostMark = M.hostMark, qualified = M.qualified;
  var statusBar = M.statusBar, sessionRow = M.sessionRow, dock = M.dock;

  // ── 09. Return to app ───────────────────────────────────────────────────

  var returning = {
    id: 'returning',
    name: 'Return to app',
    idx: '09',
    desc: 'You closed the app mid-generation and came back. Three things could have happened while you were away, and all three are on this screen.',
    notes: [
      ['1', '<b>"While you were away" is a real section, not a badge.</b> The app promises generation continues on the host without you. A promise you cannot see kept is indistinguishable from a bug, so returning surfaces what changed as its own band at the top — it collapses on scroll and does not appear when nothing happened.'],
      ['2', '<b>Finished while away.</b> The most common case and the one worth optimising: it is a normal row with a <i>changed</i> marker, not an alert. Nothing is demanded of you.'],
      ['3', '<b>Still streaming.</b> Confirms the promise literally — it kept running on a machine you were not looking at. The elapsed time is counted from the host\'s clock, not from when the app reopened, because the app being closed is not part of the story.'],
      ['4', '<b>Failed while away — this is the case that justifies the whole band.</b> Something broke on a machine you could not see, minutes ago, and it will still be broken. It sorts above the successes for exactly that reason.'],
      ['5', '<b>The failure states WHEN it broke and how far it got.</b> "Failed 8 minutes in, after 3 tool calls" is actionable; "Error" is not. You need to know whether the work is worth resuming or restarting.'],
      ['6', '<b>Resume is offered inline, not buried in the thread.</b> The recovery action lives where you discover the problem.'],
      ['7', '<b>Unread counts are per host</b>, so returning after a long absence tells you which machine was busy — the aggregate would flatten exactly the distinction multi-host exists to make.'],
      ['8', '<b>The band is dismissible and never blocks.</b> It is a report on what happened, so it must not become a modal gate between you and the app.']
    ],
    flows: [
      'Tap a changed row → <code>Chat thread</code>, scrolled to what is new',
      'Tap <code>Resume</code> → retries on the same host and backend',
      'Dismiss → an ordinary Sessions list'
    ],
    pins: null,
    render: function () {
      return statusBar() +
        '<div class="navbar large">' +
          '<div class="lt-row"><div class="lt">Sessions</div>' +
            '<span class="host-switch" data-goto="host-picker">' + hostMark('mac-studio') +
              '<span class="hname">mac-studio</span>' +
              '<span class="caret-d">&#9662;</span></span>' +
          '</div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll docked">' +
          '<div class="away-band" data-note="1">' +
            '<div class="away-head">' +
              '<span class="away-title">While you were away</span>' +
              '<span class="away-meta" data-note="7">mac-studio 2 &middot; macbook 1</span>' +
              '<span class="away-x" data-note="8">&times;</span>' +
            '</div>' +

            '<div class="away-row bad" data-goto="chat" data-note="4">' +
              badge('codex') +
              '<div class="rmain">' +
                '<div class="rtop"><span class="rtitle">Migrate test suite</span>' +
                  '<span class="rtime">14m ago</span></div>' +
                '<div class="rsub" data-note="5">Failed 8 minutes in, after 3 tool calls — ' +
                  'connection refused on port 7331.</div>' +
                '<div class="rmeta">' + qualified('codex', 'mac-studio') +
                  pill('error', 'Failed') +
                  '<span class="mini-btn" data-note="6">Resume</span></div>' +
              '</div></div>' +

            '<div class="away-row" data-goto="chat" data-note="3">' +
              badge('claude') +
              '<div class="rmain">' +
                '<div class="rtop"><span class="rtitle">Refactor auth module</span>' +
                  '<span class="rtime">running 6m</span></div>' +
                '<div class="rsub">Still generating on the host — it never stopped.</div>' +
                '<div class="rmeta">' + qualified('claude', 'mac-studio') +
                  pill('streaming', 'Streaming') + '</div>' +
              '</div></div>' +

            '<div class="away-row" data-goto="chat" data-note="2">' +
              badge('hermes') +
              '<div class="rmain">' +
                '<div class="rtop"><span class="rtitle">Review PR #482</span>' +
                  '<span class="rtime">22m ago</span></div>' +
                '<div class="rsub">Finished while you were away &middot; 4 new messages</div>' +
                '<div class="rmeta">' + qualified('hermes', 'macbook') +
                  pill('connected', 'Finished') + '</div>' +
              '</div></div>' +
          '</div>' +

          '<div class="section-header"><span>Earlier</span></div>' +
          '<div class="list">' +
            sessionRow({
              backend: 'openclaw', host: 'mac-studio', title: 'Localis spec notes',
              time: 'Mon', preview: 'Summarised the bridge options and flagged the two that ' +
                'need a decision before scaffolding.',
              status: 'idle', statusText: 'Idle', goto: 'chat'
            }) +
          '</div>' +
          '<div class="footnote">Generation runs on the host, not on this device. Closing ' +
            'Localis — or losing signal — does not stop it.</div>' +
        '</div></div>' +
        dock({
          active: 'sessions', searchGoto: 'search',
          island: { go: 'new-session', glyph: '+', title: 'New session' }
        });
    }
  };

  // ── 10. Activity ────────────────────────────────────────────────────────

  var activity = {
    id: 'activity',
    name: 'Activity',
    idx: '10',
    desc: 'What the machine is actually doing right now. The highest-value signal in the app: you are remote from a computer running commands on your behalf.',
    notes: [
      ['1', '<b>Reached from the thread, not a tab.</b> Activity is <i>about</i> this session, so it is a detail of it. Making it a destination would imply a dashboard the app does not have.'],
      ['2', '<b>The live tool call is the headline.</b> For a CLI agent acting on your machine, "what is it doing right now" outranks every other number here — you are not in the room, and it is running commands. This is drawn as the top item, not a log entry.'],
      ['3', '<b>Tool calls are a timeline with durations</b>, newest first, each naming the actual command. This is what makes a long generation legible instead of a spinner: you can see it is working, on what, and whether it is stuck.'],
      ['4', '<b>A failed tool call is shown, not swallowed</b> — with its exit status, in the flow of the run rather than as a separate error surface. The run continued; the record says so.'],
      ['5', '<b>Model and workspace, because both change the meaning of the output</b> — which model wrote it, and which directory it could touch. The workspace answers "what can this thing actually reach", which matters far more on a machine you are not sitting at. It is shown <b>abbreviated</b> (<code>~/dev/…</code>) because telemetry carries no absolute paths: the bridge shortens it before sending, so a screenshot of this screen never leaks a home directory.'],
      ['6', '<b>Rendered by field presence, never as a placeholder.</b> Token usage is real data the bridge reports, so it is shown as real data. A backend that does not report it makes this row <i>disappear</i> — it does not leave a slot saying "not available". I drew that empty slot first and it was wrong: a permanent "not reported yet" is its own kind of lie, because it implies the number is coming. Absent data is absent. <b>No cost figure</b>, in any form: pricing moves with model and plan, so a currency value computed on-device is stale the moment it renders.'],
      ['7', '<b>Elapsed and message counts are certain</b> — the client can derive both without any new bridge capability. They are separated from the pending row so the distinction between "known" and "not yet" is visible rather than implied.'],
      ['8', '<b>Stop is here as well as in the composer.</b> If you opened this screen because something looked wrong, the fix should not require going back.']
    ],
    flows: [
      'Tap back → <code>Chat thread</code>',
      'Tap <code>Stop</code> → ends the run on the host',
      'Tap a tool call → its full output (not drawn)'
    ],
    pins: null,
    render: function () {
      /** `meta` is a list of author-written fragments, joined with a middot.
          Passing a pre-joined string through esc() would print the entity. */
      function tool(name, meta, state, noteId) {
        return '<div class="tool' + (state ? ' ' + state : '') + '"' + note(noteId) + '>' +
          '<span class="tdot"></span>' +
          '<div class="tmain">' +
            '<div class="tname">' + esc(name) + '</div>' +
            '<div class="tmeta">' + meta.map(esc).join(' &middot; ') + '</div>' +
          '</div></div>';
      }
      return statusBar() +
        '<div class="navbar">' +
          '<div class="nb-left"><span class="nb-btn" data-goto="chat" data-note="1">' +
            '&#8249; Thread</span></div>' +
          '<div class="nb-title"><div class="t">Activity</div>' +
            '<div class="s" style="display:flex;justify-content:center">' +
              qualified('claude', 'mac-studio') + '</div></div>' +
          '<div class="nb-right"><span class="mini-btn danger" data-note="8">Stop</span></div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll" style="padding-bottom:24px">' +

          '<div class="now-card" data-note="2">' +
            '<div class="now-label">Running now</div>' +
            '<div class="now-cmd">swift test --package-path Packages/TransportKit</div>' +
            '<div class="now-meta">' + pill('streaming', 'Streaming') +
              '<span class="mono-strong">42s elapsed</span></div>' +
          '</div>' +

          '<div class="section-header" data-note="3"><span>Tool calls</span>' +
            '<span style="font-family:var(--mono);color:var(--text-3)">7</span></div>' +
          '<div class="list">' +
            tool('swift test', ['running', '42s'], 'live') +
            tool('read_file  Sources/TransportKit/Client.swift', ['0.2s']) +
            tool('swift build', ['exit 1', '6.4s', '2 errors'], 'bad', '4') +
            tool('edit_file  Sources/TransportKit/Client.swift', ['0.4s']) +
            tool('grep  "URLSession"', ['0.1s', '14 matches']) +
          '</div>' +

          '<div class="section-header"><span>This run</span></div>' +
          '<div class="card">' +
            '<div class="field" data-note="5"><span class="flabel">Model</span>' +
              '<span class="fvalue mono-strong">claude-opus-5</span></div>' +
            '<div class="field"><span class="flabel">Workspace</span>' +
              '<span class="fvalue mono-strong">~/dev/Localis</span></div>' +
            '<div class="field" data-note="7"><span class="flabel">Elapsed</span>' +
              '<span class="fvalue mono-strong">4m 12s</span></div>' +
            '<div class="field"><span class="flabel">Messages</span>' +
              '<span class="fvalue mono-strong">18</span></div>' +
            '<div class="field" data-note="6"><span class="flabel">Tokens</span>' +
              '<span class="fvalue mono-strong">14,208 in &middot; 3,891 out</span></div>' +
          '</div>' +

          '<div class="footnote">Everything above is read from the host as it happens. ' +
            'Localis does not run anything on this device.</div>' +
        '</div></div>';
    }
  };

  // ── 02e. Skills · catalog not loaded ────────────────────────────────────

  var skillsEmpty = {
    id: 'skills-empty',
    name: 'Skills &middot; not loaded',
    idx: '02e',
    desc: 'You typed / but this host has never been reached this launch. The state spec specified: never an error, never a spinner.',
    notes: [
      ['1', '<b>An empty state, not an error.</b> Nothing has gone wrong — the catalog lives on a machine that is asleep. Errors are for things that failed; this is a thing that has not happened yet, and the difference should be visible at a glance.'],
      ['2', '<b>It names the host it is waiting for.</b> The catalog is per host, so "no skills" is meaningless without saying whose. This is the same rule that qualifies every backend.'],
      ['3', '<b>No spinner.</b> A spinner promises something is in flight and about to resolve. Nothing is in flight — the machine is asleep — so a spinner would be a lie that never resolves.'],
      ['4', '<b>The composer stays fully usable.</b> The catalog being unavailable does not disable typing: <code>/</code> is a client-side text operation, and gating the composer on a remote fetch would make an unreachable machine feel like a broken app.'],
      ['5', '<b>Reconnecting is offered but not demanded.</b> One tap if you want it; otherwise carry on typing and it will populate when the host returns.'],
      ['6', '<b>A cached catalog is used when there is one</b>, marked stale. This screen is only the never-connected-this-launch case — the rarer of the two, and the only one with nothing to show.']
    ],
    flows: [
      'Keep typing → an ordinary message, no skill',
      'Tap <code>Wake mac-studio</code> → <code>Host picker</code>',
      'Host returns → the list populates in place'
    ],
    pins: null,
    render: function () {
      return statusBar() +
        '<div class="navbar">' +
          '<div class="nb-left"><span class="nb-btn" data-goto="sessions">&#8249;</span></div>' +
          '<div class="nb-title"><div class="t">Translate release notes</div>' +
            '<div class="s" style="display:flex;justify-content:center">' +
              qualified('kimi', 'nas') + '</div></div>' +
          '<div class="nb-right">' + pill('offline', 'Asleep') + '</div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll bottom" style="padding-bottom:210px">' +
          '<div class="thread">' +
            '<div class="msg me"><div class="bubble">已完成第一版翻译，术语表已对齐。</div></div>' +
            '<div class="msg ai"><div class="mhead">' + badge('kimi', 'sm') +
              '<span class="who">Kimi &middot; nas</span></div>' +
              '<div class="bubble">好的，我会保持术语一致。下一批什么时候给我？</div></div>' +
          '</div>' +
        '</div></div>' +
        '<div class="edge-fade bottom" style="height:150px"></div>' +
        '<div class="fzpanel glass opaque" data-note="1">' +
          '<div class="fzhead" data-note="2">' + hostMark('nas') +
            '<span>Skills on <b>nas</b></span></div>' +
          '<div class="fz-empty" data-note="3">' +
            '<div class="fz-empty-t">Not loaded yet</div>' +
            '<div class="fz-empty-s">Skills are files on <b>nas</b>. It has been asleep since ' +
              'you opened Localis, so there is nothing to list — not an error, just not here yet.' +
            '</div>' +
            '<div class="mini-btn wide" data-goto="host-picker" data-note="5">Wake nas</div>' +
          '</div>' +
        '</div>' +
        '<div class="fzcomposer glass opaque" data-note="4">' +
          '<div class="composer-bar">' +
            '<span class="backend-switcher" data-goto="backend-picker">' + badge('kimi', 'sm') +
              '<span style="display:flex;flex-direction:column;line-height:1.15;' +
                'align-items:flex-start"><span>Kimi</span>' +
                '<span style="font-family:var(--mono);font-size:9px;color:var(--text-3);' +
                  'font-weight:500">nas</span></span>' +
              '<span style="color:var(--text-3)">&#9662;</span></span>' +
            '<span class="cfield typed" data-note="6">/<span class="caret"></span></span>' +
          '</div>' +
        '</div>';
    }
  };


  // ── 11. Detached vs interrupted ─────────────────────────────────────────

  var detached = {
    id: 'detached',
    name: 'Detached vs interrupted',
    idx: '11',
    desc: 'Two states that look alike and mean opposite things. Confusing them starts a second job on the user\'s machine, so the design makes that mistake impossible rather than merely unlikely.',
    notes: [
      ['1', '<b>Detached: the connection dropped, the host did not.</b> It is still generating — you simply stopped watching. The copy says where the work is, because that is the whole distinction: nothing is lost and nothing needs redoing.'],
      ['2', '<b>Detached offers CANCEL, and does not render RETRY at all.</b> Not greyed out, not hidden behind a confirm — <i>absent</i>. Retrying something that is still running spawns a second run on the user\'s Mac, so the safe design is not to make the dangerous control look different, it is to make it not exist. Two states that look alike and carry asymmetric cost should differ in <i>what you can do</i>, not in what color they are.'],
      ['3', '<b>Interrupted: the content is genuinely gone.</b> The host does not support resume, or the retention window expired, or the output was truncated. Nothing is running anywhere, so retry is the correct and only offer.'],
      ['4', '<b>The two states are visually distinct as well</b> — streaming blue with a live pulse vs a neutral broken-thread rule. But the visual difference is the second line of defence. The first is that the harmful action is not present.'],
      ['5', '<b>Each says WHY, not just what.</b> "nas does not support resume" is actionable — it tells you this is a property of that machine, not a random failure, and that the same thing will happen next time.'],
      ['6', '<b>Resume support is per host and shown where it matters.</b> An older bridge simply does not have it, so the app must not promise continuity it cannot deliver on that machine. The host row says so before you start a long run there.'],
      ['7', '<b>Partial output is kept and marked</b>, never discarded. Truncated text is still worth reading, and deleting it to keep the transcript tidy would destroy the only record of a long run.'],
      ['8', '<b>Reconnecting is passive.</b> Detached resolves itself when the connection returns — no button, because there is nothing for you to do and offering an action would imply there was.']
    ],
    flows: [
      'Detached → connection returns → streaming resumes in place',
      'Detached → <code>Cancel</code> → stops the run on the host',
      'Interrupted → <code>Retry</code> → a fresh run, same host and backend'
    ],
    pins: null,
    render: function () {
      return statusBar() +
        '<div class="navbar">' +
          '<div class="nb-left"><span class="nb-btn" data-goto="sessions">&#8249;</span></div>' +
          '<div class="nb-title"><div class="t">Two ways a run ends early</div>' +
            '<div class="s">detached &middot; interrupted</div></div>' +
          '<div class="nb-right"></div>' +
        '</div>' +
        '<div class="body"><div class="body-scroll" style="padding-bottom:20px">' +

          '<div class="section-header"><span>Detached &mdash; still running</span></div>' +
          '<div class="thread" style="padding-bottom:10px">' +
            '<div class="msg ai"><div class="mhead">' + badge('claude', 'sm') +
              '<span class="who">Claude &middot; mac-studio</span></div>' +
              '<div class="bubble">Two things stand out. First, the actor isolation is right ' +
              'but the await ordering still allows a second caller in&hellip;</div>' +
              '<div class="state-strip detached" data-note="1">' +
                '<span class="pulse"></span>' +
                '<div class="st-main">' +
                  '<div class="st-t">Still running on mac-studio</div>' +
                  '<div class="st-s" data-note="8">You went offline; the host kept going. ' +
                    'This resumes on its own when the connection returns.</div>' +
                '</div>' +
                '<span class="mini-btn danger" data-note="2">Cancel</span>' +
              '</div>' +
            '</div>' +
          '</div>' +

          '<div class="section-header"><span>Interrupted &mdash; content lost</span></div>' +
          '<div class="thread" style="padding-bottom:10px">' +
            '<div class="msg ai"><div class="mhead">' + badge('kimi', 'sm') +
              '<span class="who">Kimi &middot; nas</span></div>' +
              '<div class="bubble">第一部分已翻译完成，术语表&hellip;' +
                '<span class="trunc" data-note="7">output ends here</span></div>' +
              '<div class="state-strip interrupted" data-note="3">' +
                '<span class="brk"></span>' +
                '<div class="st-main">' +
                  '<div class="st-t">Interrupted &mdash; nothing is running</div>' +
                  '<div class="st-s" data-note="5">nas does not support resume, so the rest of ' +
                    'this reply was lost when the connection dropped.</div>' +
                '</div>' +
                '<span class="mini-btn">Retry</span>' +
              '</div>' +
            '</div>' +
          '</div>' +

          '<div class="section-header" data-note="4"><span>Why they must not look alike</span></div>' +
          '<div class="card" style="margin:0 14px">' +
            '<div class="cmp-row"><span class="cmp-k">Detached</span>' +
              '<span class="cmp-v">host is working &middot; <b>cancel only</b></span></div>' +
            '<div class="cmp-row"><span class="cmp-k">Interrupted</span>' +
              '<span class="cmp-v">nothing running &middot; <b>retry</b></span></div>' +
            '<div class="cmp-row bad"><span class="cmp-k">The bug</span>' +
              '<span class="cmp-v">retry while detached &rarr; <b>two runs on one machine</b></span></div>' +
          '</div>' +

          '<div class="section-header" data-note="6"><span>Resume is per host</span></div>' +
          '<div class="list">' +
            '<div class="row"><span>' + hostMark('mac-studio') + '</span>' +
              '<div class="rmain"><div class="rtop">' +
                '<span class="rtitle">mac-studio</span></div>' +
                '<div class="rmeta">' + pill('connected', 'Resumes after disconnect') + '</div>' +
              '</div></div>' +
            '<div class="row"><span>' + hostMark('nas') + '</span>' +
              '<div class="rmain"><div class="rtop">' +
                '<span class="rtitle">nas</span></div>' +
                '<div class="rmeta">' + pill('idle', 'No resume &mdash; older bridge') + '</div>' +
              '</div></div>' +
          '</div>' +
          '<div class="footnote">Resume is a host capability, off by default. Where a machine ' +
            'cannot resume, the app does not promise it will.</div>' +
        '</div></div>';
    }
  };

  global.ScreensActivity = [returning, activity, skillsEmpty, detached];
  global.Screens = (global.Screens || []).concat(global.ScreensActivity);
})(window);
