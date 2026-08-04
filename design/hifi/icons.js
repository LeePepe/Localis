/**
 * icons.js — the drawn icon set.
 *
 * The prototype used dashed placeholder boxes. Hi-fi draws them for real, as
 * inline SVG on a 24-unit grid with a 1.6 stroke.
 *
 * WHY DRAWN HERE RATHER THAN NAMED
 * --------------------------------
 * Every icon below maps to an SF Symbol, named in `sf`. The app should use
 * the SF Symbol — it gets Dynamic Type, optical alignment, and the platform's
 * own weight matching for free. These paths exist so the hi-fi mockup renders
 * in a browser at the right visual weight, and so the SF Symbol chosen for
 * each meaning is written down rather than left to whoever implements it.
 *
 * `stroke` and not `fill`: at the sizes used here (16–24pt) a stroked icon
 * holds its shape against a translucent backdrop, where a filled one turns
 * into a blob. The two exceptions are marked `solid` — a selected tab and a
 * status dot, where mass IS the signal.
 */
(function (global) {
  'use strict';

  var P = {
    /* Destinations */
    sessions: { sf: 'bubble.left.and.bubble.right',
      d: 'M3.2 6.6a2.4 2.4 0 0 1 2.4-2.4h8.6a2.4 2.4 0 0 1 2.4 2.4v4.6a2.4 2.4 0 0 1-2.4 2.4H8.4l-3.6 2.8v-2.8a2.4 2.4 0 0 1-1.6-2.4z M11.4 14.2v.6a2.4 2.4 0 0 0 2.4 2.4h2.8l3 2.4v-2.4a2.4 2.4 0 0 0 1.2-2.4v-3.4a2.4 2.4 0 0 0-2.4-2.4h-1.6' },
    settings: { sf: 'gearshape',
      d: 'M12 15.2a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4z M19.4 12c0-.5-.05-1-.14-1.47l2-1.5-2-3.46-2.36.9a7.4 7.4 0 0 0-2.55-1.48L14 2.6h-4l-.35 2.39a7.4 7.4 0 0 0-2.55 1.48l-2.36-.9-2 3.46 2 1.5a7.5 7.5 0 0 0 0 2.94l-2 1.5 2 3.46 2.36-.9a7.4 7.4 0 0 0 2.55 1.48L10 21.4h4l.35-2.39a7.4 7.4 0 0 0 2.55-1.48l2.36.9 2-3.46-2-1.5c.09-.48.14-.97.14-1.47z' },
    search: { sf: 'magnifyingglass',
      d: 'M10.8 17.6a6.8 6.8 0 1 0 0-13.6 6.8 6.8 0 0 0 0 13.6z M15.8 15.8 20.4 20.4' },

    /* Actions */
    plus: { sf: 'plus', d: 'M12 5v14 M5 12h14' },
    send: { sf: 'arrow.up', d: 'M12 19V5 M5.6 11.4 12 5l6.4 6.4' },
    stop: { sf: 'stop.fill', solid: true, d: 'M7.5 7.5h9v9h-9z' },
    close: { sf: 'xmark', d: 'M6.4 6.4 17.6 17.6 M17.6 6.4 6.4 17.6' },
    back: { sf: 'chevron.left', d: 'M14.6 5.4 8 12l6.6 6.6' },
    chevron: { sf: 'chevron.right', d: 'M9.4 5.4 16 12l-6.6 6.6' },
    caretDown: { sf: 'chevron.down', d: 'M5.6 9.4 12 15.8l6.4-6.4' },
    check: { sf: 'checkmark', d: 'M5 12.6 9.8 17.4 19 6.6' },
    slash: { sf: 'slash.forward', d: 'M15.4 4.6 8.6 19.4' },
    retry: { sf: 'arrow.clockwise',
      d: 'M19.2 12a7.2 7.2 0 1 1-2.4-5.36 M19.2 4.4v3.8h-3.8' },
    info: { sf: 'info.circle',
      d: 'M12 20.4a8.4 8.4 0 1 0 0-16.8 8.4 8.4 0 0 0 0 16.8z M12 11v5.2 M12 7.8v.2' },

    /* Machines — square-ish silhouettes. A host must never be mistakable for
       a backend badge, so none of these are round. */
    mac: { sf: 'desktopcomputer',
      d: 'M4 5.6h16v10H4z M9 19.4h6 M12 15.6v3.8' },
    laptop: { sf: 'laptopcomputer',
      d: 'M5.4 6.4h13.2v8.4H5.4z M3 17.6h18' },
    nas: { sf: 'externaldrive',
      d: 'M3.6 7.2h16.8v4.2H3.6z M3.6 12.6h16.8v4.2H3.6z M6.6 9.3h.02 M6.6 14.7h.02' },
    vps: { sf: 'cloud',
      d: 'M7 17.4a3.8 3.8 0 0 1-.3-7.58 5.2 5.2 0 0 1 10.06-1.3A3.9 3.9 0 0 1 17.4 17.4z' },

    /* State */
    dot: { sf: 'circle.fill', solid: true, d: 'M12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8z' },
    tool: { sf: 'wrench.and.screwdriver',
      d: 'M4.6 6.2a3.4 3.4 0 0 0 4.5 4.5l7.5 7.5a1.7 1.7 0 0 0 2.4-2.4l-7.5-7.5a3.4 3.4 0 0 0-4.5-4.5l2.3 2.3-1.4 1.4z' },
    sidebar: { sf: 'sidebar.leading',
      d: 'M3.6 5.4h16.8v13.2H3.6z M9.4 5.4v13.2' },
    skill: { sf: 'text.append',
      d: 'M4 7h11 M4 12h11 M4 17h6 M17.5 14v7 M14 17.5h7' }
  };

  /**
   * @param name  key in P
   * @param size  rendered px (the grid is 24, so this scales the viewBox)
   * @param cls   extra classes
   */
  function icon(name, size, cls) {
    var p = P[name];
    if (!p) return '';
    var s = size || 24;
    // Stroke width is scaled so a 16px icon does not look heavier than a 24px
    // one — constant *visual* weight, not constant stroke.
    var sw = (1.6 * (24 / s)).toFixed(2);
    var body = p.solid
      ? '<path d="' + p.d + '" fill="currentColor"/>'
      : '<path d="' + p.d + '" fill="none" stroke="currentColor" stroke-width="' +
        sw + '" stroke-linecap="round" stroke-linejoin="round"/>';
    return '<svg class="ic' + (cls ? ' ' + cls : '') + '" width="' + s +
      '" height="' + s + '" viewBox="0 0 24 24" aria-hidden="true" ' +
      'data-sf="' + p.sf + '">' + body + '</svg>';
  }

  /** The SF Symbol a given icon maps to — the thing DesignKit actually needs. */
  function symbolFor(name) { return P[name] ? P[name].sf : null; }

  global.Icons = { icon: icon, symbolFor: symbolFor, PATHS: P };
})(window);
