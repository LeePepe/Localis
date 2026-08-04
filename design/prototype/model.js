/**
 * model.js — the prototype's data + shared partials.
 *
 * Split out of screens.js when hosts became first-class: the screens got
 * longer and the vocabulary got shared, so the vocabulary now lives in one
 * place. Pure functions returning strings; nothing here mutates.
 */
(function (global) {
  'use strict';

  // ── Hosts ──────────────────────────────────────────────────────────────
  // A host is a machine running the Localis bridge. It is first-class: it
  // owns backends, it owns sessions, and it has its own reachability.
  // `kind` drives the glyph and the copy only — never behaviour.
  var HOSTS = {
    'mac-studio': {
      id: 'mac-studio', name: 'mac-studio', kind: 'mac', glyph: '&#9635;',
      reach: 'up', latency: '12 ms', seen: 'now',
      desc: 'Mac Studio · study'
    },
    'macbook': {
      id: 'macbook', name: 'macbook-pro', kind: 'mac', glyph: '&#9636;',
      reach: 'up', latency: '38 ms', seen: 'now',
      desc: 'MacBook Pro · with you'
    },
    'nas': {
      id: 'nas', name: 'nas', kind: 'nas', glyph: '&#9707;',
      reach: 'down', latency: '—', seen: '6m ago',
      desc: 'Synology · basement', reason: 'Host asleep'
    }
  };

  var HOST_ORDER = ['mac-studio', 'macbook', 'nas'];

  // ── Backends ───────────────────────────────────────────────────────────
  // A backend NAME is global; a backend INSTANCE is (host, name). The same
  // name can run on two machines and they are genuinely different backends.
  // Each name gets a chart-palette slot derived from the ONE seed — identity
  // by hue, not a second palette.
  var BACKENDS = {
    claude:   { label: 'Claude',   abbr: 'CL', chart: 1 },
    openclaw: { label: 'OpenClaw', abbr: 'OC', chart: 3 },
    hermes:   { label: 'Hermes',   abbr: 'HM', chart: 4 },
    kimi:     { label: 'Kimi',     abbr: 'KM', chart: 6 },
    codex:    { label: 'Codex',    abbr: 'CX', chart: 8 }
  };

  /** Which backends each host actually runs — deliberately overlapping. */
  var HOST_BACKENDS = {
    'mac-studio': ['claude', 'openclaw', 'codex'],
    'macbook': ['claude', 'hermes'],
    'nas': ['kimi', 'codex']
  };

  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  // ── Shared partials ────────────────────────────────────────────────────

  function attr(name, v) { return v ? ' ' + name + '="' + v + '"' : ''; }

  function note(n) { return attr('data-note', n); }

  /** Backend badge, tinted from the seed-derived chart palette. */
  function badge(key, size) {
    var b = BACKENDS[key];
    var v = 'var(--chart-' + b.chart + ')';
    return '<div class="badge ' + (size || '') + '" style="background:color-mix(in srgb,' + v +
      ' 16%,transparent);color:' + v + ';border-color:color-mix(in srgb,' + v +
      ' 34%,transparent)">' + b.abbr + '</div>';
  }

  /** Host mark — square-ish and neutral so it reads as a machine, not an AI. */
  function hostMark(hostId, size) {
    var h = HOSTS[hostId];
    var cls = h.reach === 'up' ? '' : (h.reach === 'down' ? ' down' : ' unknown');
    return '<div class="host-mark' + (size === 'lg' ? ' lg' : '') + cls + '">' +
      h.glyph + '<span class="rdot"></span></div>';
  }

  /**
   * A backend qualified by its host. Used everywhere a backend is named,
   * because "Claude" alone is ambiguous the moment two machines run it.
   */
  function qualified(backendKey, hostId) {
    return '<span class="qualified"><span>' + BACKENDS[backendKey].label + '</span>' +
      '<span class="qsep">&middot;</span>' +
      '<span class="qhost">' + esc(HOSTS[hostId].name) + '</span></span>';
  }

  function pill(kind, text) {
    return '<span class="pill ' + kind + '"><span class="dot"></span>' + esc(text) + '</span>';
  }

  function statusBar() {
    return '<div class="status-bar"><span>9:41</span>' +
      '<span class="sb-right"><span>&#9679;&#9679;&#9679;</span><i></i></span></div>';
  }

  /** Host switcher pill — current host, one tap to the host list. */
  function hostSwitch(hostId, noteId) {
    var h = HOSTS[hostId];
    return '<span class="host-switch" data-goto="host-picker"' + note(noteId) + '>' +
      hostMark(hostId) + '<span class="hname">' + esc(h.name) + '</span>' +
      '<span class="caret-d">&#9662;</span></span>';
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

  /**
   * Session row. A session belongs to exactly one host, permanently.
   *
   * `sel` is an iPad affordance: in a split view the list keeps a persistent
   * selection because the detail pane is always showing one of these rows.
   * On iPhone the row is pushed and popped, so nothing stays selected.
   *
   * There is no skill pill. A skill is text you inserted while typing, so a
   * session is never "a /code-review session" — the row would be claiming a
   * relationship the data no longer has.
   */
  function sessionRow(o) {
    return '<div class="row' + (o.swipe ? ' swipe' : '') + (o.sel ? ' sel' : '') + '"' +
      note(o.note) + attr('data-goto', o.goto) + '>' +
      '<span' + note(o.badgeNote) + '>' + badge(o.backend) + '</span>' +
      '<div class="rmain">' +
        '<div class="rtop"><span class="rtitle">' + esc(o.title) + '</span>' +
        '<span class="rtime">' + esc(o.time) + '</span></div>' +
        '<div class="rsub">' + esc(o.preview) + '</div>' +
        '<div class="rmeta"><span' + note(o.hostNote) + '>' +
          qualified(o.backend, o.host) + '</span>' +
        '<span' + note(o.statusNote) + '>' + pill(o.status, o.statusText) + '</span>' +
        '</div>' +
      '</div>' +
      '<span class="chev">&#8250;</span></div>';
  }

  /**
   * The app's destinations. One list, so iPhone and iPad cannot drift.
   *
   * TWO destinations, not three. Skills stopped being a place the moment they
   * became an input accelerator — you reach them by typing `/` where you were
   * already typing, so a Skills tab would be a door to a room with nothing in
   * it. The bar stays a bar rather than collapsing into a segmented control
   * because it still has to house `Tab(role: .search)`, and because two tabs
   * leave the search affordance and the create island more room than three did.
   */
  var TABS = [
    { id: 'sessions', label: 'Sessions', ic: '&#9776;', go: 'sessions' },
    { id: 'settings', label: 'Settings', ic: '&#9881;', go: 'settings' }
  ];

  /**
   * The tab bar itself, minus the edge it is anchored to. iPhone floats it at
   * the bottom (thumb); iPadOS 26 floats it at the top of the window. Same
   * capsule, same material, same search role — only the anchor differs, so
   * only the anchor is a parameter.
   */
  function tabBar(opts) {
    var o = opts || {};
    return '<div class="tabbar-float' + (o.top ? ' top' : '') + ' glass' +
      (o.mini ? ' mini' : '') + '"' + note(o.barNote) + '>' +
      TABS.map(function (t) {
        return '<div class="tab' + (t.id === o.active ? ' on' : '') +
          '" data-goto="' + t.go + '">' +
          '<span class="ic">' + t.ic + '</span><span>' + t.label + '</span></div>';
      }).join('') +
      // Tab(role: .search) — an affordance, not a fourth destination, so it
      // carries no label on iPhone and sits past a hairline on both.
      '<div class="tab search"' + attr('data-goto', o.searchGoto) + note(o.searchNote) + '>' +
        '<span class="ic">&#9906;</span>' +
        (o.top ? '<span>Search</span>' : '') + '</div>' +
      '</div>';
  }

  /**
   * The bottom furniture: a floating Liquid Glass tab bar plus, optionally,
   * a separate accent island for the primary create action.
   *
   * The tab bar does not span the full width. That is what frees the
   * bottom-right corner — the most reachable point for a right thumb — for
   * the create action, and it is why search can be a tab without fighting it.
   */
  function dock(opts) {
    var o = opts || {};
    var island = o.island
      ? '<div class="island glass accent"' + attr('data-goto', o.island.go) +
        note(o.island.note) + ' title="' + esc(o.island.title) + '">' +
        o.island.glyph + '</div>'
      : '';

    return '<div class="edge-fade bottom"></div><div class="dock">' +
      tabBar(o) + island + '</div>';
  }

  /**
   * Skills. An input accelerator, not a subsystem: type `/`, filter, and the
   * template lands in the composer as ordinary editable text. There is no
   * library screen, no parameter form, and no transcript provenance — once
   * inserted it is just a message you wrote.
   *
   * `template` carries [placeholders] verbatim. They are inserted VISIBLE and
   * typed over; editing in the composer IS the parameter mechanism, which is
   * why the entity needs nothing beyond id / name / summary / template.
   *
   * The catalog is per host (`/v1/skills`), so it is scoped to the session's
   * host — see the picker screen for the unreachable-host case.
   */
  var SKILLS = [
    { id: 'code-review', summary: 'Review a diff: correctness, then risk, then style.',
      template: 'Review {{what}} for correctness, then risk, then style.', recent: true },
    { id: 'brainstorming', summary: 'Widen the option space before committing.',
      template: 'Give me {{n}} genuinely different approaches to {{problem}}.', recent: true },
    { id: 'research', summary: 'Gather sources, then answer with citations.',
      template: 'Research {{topic}} and answer with citations.' },
    { id: 'debug', summary: 'Reproduce, isolate, then propose the smallest fix.',
      template: 'Debug {{symptom}}. Reproduce it, isolate it, propose the smallest fix.' },
    { id: 'translate', summary: 'Translate while holding a fixed glossary.',
      template: 'Translate {{text}} into {{language}}, holding the glossary fixed.' },
    { id: 'refactor', summary: 'Restructure without changing behaviour.',
      template: 'Refactor {{target}} without changing observable behaviour.' }
  ];

  /**
   * Subsequence match — the "fuzzy" in fuzzy filter. `cdrv` matches
   * `code-review`. Returns the matched character indices so the picker can
   * show WHY a row matched, or null. Pure; allocates a new array.
   */
  function fuzzy(query, candidate) {
    if (!query) return [];
    var q = query.toLowerCase(), c = candidate.toLowerCase();
    var hits = [], qi = 0;
    for (var i = 0; i < c.length && qi < q.length; i++) {
      if (c[i] === q[qi]) { hits.push(i); qi++; }
    }
    return qi === q.length ? hits : null;
  }

  /** Render a name with its matched characters marked. */
  function highlight(name, hits) {
    var set = {};
    (hits || []).forEach(function (i) { set[i] = true; });
    return name.split('').map(function (ch, i) {
      return set[i] ? '<b class="fz">' + esc(ch) + '</b>' : esc(ch);
    }).join('');
  }

  global.M = {
    HOSTS: HOSTS,
    HOST_ORDER: HOST_ORDER,
    BACKENDS: BACKENDS,
    HOST_BACKENDS: HOST_BACKENDS,
    esc: esc,
    attr: attr,
    note: note,
    badge: badge,
    hostMark: hostMark,
    qualified: qualified,
    pill: pill,
    statusBar: statusBar,
    hostSwitch: hostSwitch,
    sparkline: sparkline,
    sessionRow: sessionRow,
    SKILLS: SKILLS,
    fuzzy: fuzzy,
    highlight: highlight,
    TABS: TABS,
    tabBar: tabBar,
    dock: dock
  };
})(window);
