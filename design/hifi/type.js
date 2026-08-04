/**
 * type.js — the hi-fi type scale.
 *
 * The prototype fixed structure and left type deliberately plain. Hi-fi fixes
 * the actual ramp, and it has to be exact: `Packages/DesignKit` ports these to
 * SwiftUI `Font` values, so a size or a tracking value left to taste here
 * becomes a guess there.
 *
 * BUILT ON THE SYSTEM SCALE, NOT INVENTED
 * ---------------------------------------
 * Every step maps to an iOS text style, so Dynamic Type works by default
 * rather than being retrofitted. The `swift` field is the exact SwiftUI call.
 * Where we deviate from the system size, the reason is in `why` — and there
 * are only three deviations in the whole ramp.
 *
 * TRACKING
 * --------
 * SF Pro's optical sizing already tightens large text, so tracking is only
 * applied where the platform does not: display sizes get a small negative,
 * all-caps labels get a positive, and mono gets a touch of positive to stop
 * digits from colliding. Everything else is 0 — tracking every step is a
 * common way to make text look designed and read worse.
 */
(function (global) {
  'use strict';

  var TYPE = {
    /* Display — large titles. The only sizes that get negative tracking. */
    display: {
      size: 34, lineHeight: 41, weight: 700, tracking: -0.4,
      style: 'largeTitle', swift: '.largeTitle.weight(.bold)',
      use: 'Screen large titles: Sessions, Settings'
    },
    title1: {
      size: 28, lineHeight: 34, weight: 700, tracking: -0.3,
      style: 'title', swift: '.title.weight(.bold)',
      use: 'Empty-state headline, sheet titles on iPad'
    },
    title2: {
      size: 22, lineHeight: 28, weight: 650, tracking: -0.2,
      style: 'title2', swift: '.title2.weight(.semibold)',
      use: 'Sheet titles, iPad detail header'
    },

    /* Body — the reading sizes. Tracking 0: the platform is already right. */
    headline: {
      size: 17, lineHeight: 22, weight: 600, tracking: 0,
      style: 'headline', swift: '.headline',
      use: 'Row titles, nav bar title, the first line you read on a row'
    },
    body: {
      size: 17, lineHeight: 24, weight: 400, tracking: 0,
      style: 'body', swift: '.body',
      use: 'Message text. The only style used for long-form reading.'
    },
    callout: {
      size: 16, lineHeight: 21, weight: 400, tracking: 0,
      style: 'callout', swift: '.callout',
      use: 'Composer input, search field'
    },
    subhead: {
      size: 15, lineHeight: 20, weight: 400, tracking: 0,
      style: 'subheadline', swift: '.subheadline',
      use: 'Row previews, secondary description'
    },
    footnote: {
      size: 13, lineHeight: 18, weight: 400, tracking: 0,
      style: 'footnote', swift: '.footnote',
      use: 'Row metadata, explanatory copy under a control'
    },
    caption: {
      size: 12, lineHeight: 16, weight: 400, tracking: 0,
      style: 'caption', swift: '.caption',
      use: 'Timestamps, counts, pill labels'
    },

    /* Deviations from the system scale — three, each justified. */
    tabLabel: {
      size: 11, lineHeight: 13, weight: 500, tracking: 0.06,
      style: 'caption2', swift: '.caption2.weight(.medium)',
      why: 'iOS 26 tab-bar metric. Slightly tracked because it sits on ' +
           'translucent glass, where tight small text loses definition.',
      use: 'Floating tab bar labels'
    },
    sectionLabel: {
      size: 11, lineHeight: 14, weight: 650, tracking: 0.7, caps: true,
      style: 'caption2', swift: '.caption2.weight(.semibold)',
      why: 'All-caps needs positive tracking to stay legible — caps remove ' +
           'the word-shape cue that lets you read a word without spelling it.',
      use: 'Section headers: LIVE, RECENT, THIS RUN'
    },
    mono: {
      size: 12, lineHeight: 17, weight: 500, tracking: 0.2, mono: true,
      style: 'caption', swift: '.system(.caption, design: .monospaced)',
      why: 'Host names, latency, token counts, paths. Monospace is a ' +
           'semantic choice, not a decorative one: it marks machine-generated ' +
           'text — a hostname, a number the machine reported, a path.',
      use: 'Host names, all numerics that change'
    },
    code: {
      size: 13, lineHeight: 19, weight: 400, tracking: 0, mono: true,
      style: 'footnote', swift: '.system(.footnote, design: .monospaced)',
      use: 'Code blocks in transcripts, tool-call names'
    }
  };

  /**
   * Numbers must not reflow as they change. A latency readout jittering
   * between 8ms and 88ms because the glyphs differ in width reads as
   * instability in the connection rather than in the typography.
   */
  var TABULAR = ['mono', 'caption', 'footnote'];

  function css(key) {
    var t = TYPE[key];
    var out = 'font-size:' + t.size + 'px;line-height:' + t.lineHeight +
      'px;font-weight:' + t.weight + ';letter-spacing:' + t.tracking + 'px';
    if (t.caps) out += ';text-transform:uppercase';
    if (t.mono) out += ';font-family:var(--mono)';
    if (TABULAR.indexOf(key) !== -1) out += ';font-variant-numeric:tabular-nums';
    return out;
  }

  /** Emit the whole ramp as utility classes, so screens never inline a size. */
  function stylesheet() {
    return Object.keys(TYPE).map(function (k) {
      return '.t-' + k + '{' + css(k) + '}';
    }).join('\n');
  }

  global.Type = { TYPE: TYPE, css: css, stylesheet: stylesheet, TABULAR: TABULAR };
})(window);
