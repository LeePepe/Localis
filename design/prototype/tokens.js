/**
 * tokens.js — Localis prototype color system.
 *
 * Verbatim port of my-designer's `templates/shared/color-system.ts`
 * (same HSB derivation, same WCAG on-color, same preset seeds, same token
 * names). ONE seed drives the whole primary set; semantic colors are FIXED;
 * neutrals come from Radix slate.
 *
 * This file is the ONLY place hex literals may appear. Everything else in the
 * prototype consumes CSS custom properties.
 *
 * Extended for iOS 26 Liquid Glass: the `--glass-*` and `--fade-*` tokens are
 * derived from the same neutral ramp, so translucent chrome re-themes with the
 * seed and the mode like everything else. See `glassTokens`.
 */
(function (global) {
  'use strict';

  var clamp = function (x) { return Math.min(1, Math.max(0, x)); };

  function hexToRgb(hex) {
    var v = parseInt(hex.replace('#', ''), 16);
    return [((v >> 16) & 0xff) / 255, ((v >> 8) & 0xff) / 255, (v & 0xff) / 255];
  }

  function rgbToHsb(r, g, b) {
    var max = Math.max(r, g, b);
    var min = Math.min(r, g, b);
    var d = max - min;
    var h = 0;
    if (d !== 0) {
      if (max === r) h = ((g - b) / d) % 6;
      else if (max === g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h /= 6;
      if (h < 0) h += 1;
    }
    return { h: h, s: max === 0 ? 0 : d / max, b: max };
  }

  function hsbToCss(h, s, br) {
    var i = Math.floor(h * 6);
    var f = h * 6 - i;
    var p = br * (1 - s);
    var q = br * (1 - f * s);
    var t = br * (1 - (1 - f) * s);
    var r = 0, g = 0, b = 0;
    switch (i % 6) {
      case 0: r = br; g = t; b = p; break;
      case 1: r = q; g = br; b = p; break;
      case 2: r = p; g = br; b = t; break;
      case 3: r = p; g = q; b = br; break;
      case 4: r = t; g = p; b = br; break;
      default: r = br; g = p; b = q; break;
    }
    var to255 = function (x) { return Math.round(clamp(x) * 255); };
    return 'rgb(' + to255(r) + ' ' + to255(g) + ' ' + to255(b) + ')';
  }

  /** Hex -> `rgb(r g b / a)`, for the translucent Liquid Glass materials. */
  function rgba(hex, a) {
    var c = hexToRgb(hex);
    var to255 = function (x) { return Math.round(clamp(x) * 255); };
    return 'rgb(' + to255(c[0]) + ' ' + to255(c[1]) + ' ' + to255(c[2]) +
      ' / ' + a + ')';
  }

  function relLuminance(r, g, b) {
    var lin = function (x) {
      return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  }

  /**
   * Label color for a filled accent surface.
   *
   * NOT the naive "pick whichever of black/white has the higher contrast
   * ratio": on a saturated mid-tone like Apple Blue (#007AFF) that arithmetic
   * picks BLACK (5.23 vs 4.02), which passes WCAG and still looks broken —
   * every platform ships white there, and users read it as a rendering fault.
   *
   * The rule instead: white unless white would fall below the 3.0 floor for
   * large/bold text, which is what a button label is. That yields white on
   * blue / purple / teal / red and black on orange / yellow / lime — correct
   * for every preset seed, and it still degrades safely for a seed nobody
   * has tried yet.
   */
  var ON_COLOR_MIN_CONTRAST = 3.0;

  function onColor(hex) {
    var c = hexToRgb(hex);
    var L = relLuminance(c[0], c[1], c[2]);
    var whiteContrast = 1.05 / (L + 0.05);
    return whiteContrast >= ON_COLOR_MIN_CONTRAST ? '#ffffff' : '#000000';
  }

  var SEEDS = {
    blue: '#0090FF',
    purple: '#8E4EC6',
    teal: '#12A594',
    orange: '#F76B15',
    appleBlue: '#007AFF'
  };

  function makePrimaryPalette(seedHex, isDark) {
    var rgb = hexToRgb(seedHex);
    var hsb = rgbToHsb(rgb[0], rgb[1], rgb[2]);
    var h = hsb.h, s = hsb.s, br = hsb.b;
    var c = function (hh, ss, bb) { return hsbToCss(hh, clamp(ss), clamp(bb)); };

    if (isDark) {
      return {
        primary: c(h, s - 0.05, br + 0.06),
        primaryHover: c(h, s, br + 0.08),
        primaryActive: c(h, s, br + 0.14),
        primarySubtle: c(h, s * 0.45, 0.18),
        primaryMuted: c(h, s * 0.5, 0.26),
        primaryBorder: c(h, s * 0.55, 0.36),
        primaryText: c(h, s * 0.7, br + 0.28),
        onPrimary: onColor(seedHex),
        onPrimarySubtle: c(h, s * 0.7, br + 0.28),
        ring: c(h, s - 0.05, br + 0.06)
      };
    }
    return {
      primary: c(h, s, br),
      primaryHover: c(h, s, br - 0.08),
      primaryActive: c(h, s, br - 0.14),
      primarySubtle: c(h, s * 0.18, 0.97),
      primaryMuted: c(h, s * 0.4, 0.9),
      primaryBorder: c(h, s * 0.55, 0.8),
      primaryText: c(h, Math.min(1, s + 0.1), br - 0.2),
      onPrimary: onColor(seedHex),
      onPrimarySubtle: c(h, Math.min(1, s + 0.1), br - 0.2),
      ring: c(h, s, br)
    };
  }

  var CHART_OFFSETS = [0, -15, 40, 95, 130, 175, -70, 210];

  function chartPalette(seedHex, isDark) {
    var rgb = hexToRgb(seedHex);
    var seedHue = rgbToHsb(rgb[0], rgb[1], rgb[2]).h * 360;
    return CHART_OFFSETS.map(function (off) {
      var h = ((((seedHue + off) % 360) + 360) % 360) / 360;
      return isDark ? hsbToCss(h, 0.66, 0.82) : hsbToCss(h, 0.72, 0.62);
    });
  }

  var NEUTRAL = {
    slate: {
      light: { bg: '#F9F9FB', card: '#FFFFFF', inner: '#F0F0F3', text1: '#1C2024', text2: '#60646C', text3: '#80838D', border: '#D9D9E0' },
      dark: { bg: '#111113', card: '#18191B', inner: '#212225', text1: '#EDEEF0', text2: '#B0B4BA', text3: '#777B84', border: '#363A3F' }
    },
    neutral: {
      light: { bg: '#FAFAFA', card: '#FFFFFF', inner: '#F5F5F5', text1: '#171717', text2: '#525252', text3: '#737373', border: '#E5E5E5' },
      dark: { bg: '#171717', card: '#262626', inner: '#2E2E2E', text1: '#FAFAFA', text2: '#A3A3A3', text3: '#737373', border: '#404040' }
    }
  };

  var SEMANTIC = {
    light: { success: '#34C759', warning: '#FF9500', danger: '#FF3B30' },
    dark: { success: '#30D158', warning: '#FF9F0A', danger: '#FF453A' }
  };

  /**
   * Liquid Glass materials (iOS 26).
   *
   * Elevation on floating chrome is now material + inset, not a luminance
   * tier. Two opacities on purpose:
   *
   *   --glass         translucent, for chrome whose content is short and
   *                   high-contrast (tab labels, an icon, a status pill)
   *   --glass-solid   markedly more opaque, for chrome that carries running
   *                   text you must actually read (search field, composer)
   *
   * The second one exists because Liquid Glass's documented failure mode is
   * body text over a busy backdrop. Where legibility and translucency
   * conflict, legibility wins and we spend the material budget elsewhere.
   */
  function glassTokens(n, isDark) {
    return {
      '--glass': rgba(n.card, isDark ? 0.58 : 0.70),
      '--glass-solid': rgba(n.card, isDark ? 0.88 : 0.92),
      // Specular edge: a bright hairline on top, the neutral border below.
      '--glass-line': rgba(n.text1, isDark ? 0.00 : 0.09),
      '--glass-highlight': isDark ? rgba(n.text1, 0.16) : rgba(n.card, 0.85),
      // The only shadows in the system, and only under floating chrome.
      '--glass-shadow': isDark
        ? '0 8px 26px rgb(0 0 0 / 0.55), 0 1px 3px rgb(0 0 0 / 0.4)'
        : '0 8px 24px ' + rgba(n.text1, 0.14) + ', 0 1px 2px ' + rgba(n.text1, 0.08),
      // Progressive edge fade — content dissolving under floating chrome.
      '--fade-0': rgba(n.bg, 0),
      '--fade-1': rgba(n.bg, isDark ? 0.72 : 0.78),
      '--fade-2': rgba(n.bg, isDark ? 0.96 : 0.97)
    };
  }

  function buildTokens(seedHex, neutral, isDark) {
    var p = makePrimaryPalette(seedHex, isDark);
    var n = NEUTRAL[neutral][isDark ? 'dark' : 'light'];
    var sem = SEMANTIC[isDark ? 'dark' : 'light'];
    var charts = chartPalette(seedHex, isDark);

    var vars = {
      '--bg': n.bg,
      '--card': n.card,
      '--inner': n.inner,
      '--text-1': n.text1,
      '--text-2': n.text2,
      '--text-3': n.text3,
      '--border': n.border,
      '--primary': p.primary,
      '--primary-hover': p.primaryHover,
      '--primary-active': p.primaryActive,
      '--primary-subtle': p.primarySubtle,
      '--primary-muted': p.primaryMuted,
      '--primary-border': p.primaryBorder,
      '--primary-text': p.primaryText,
      '--on-primary': p.onPrimary,
      '--on-primary-subtle': p.onPrimarySubtle,
      '--ring': p.ring,
      '--success': sem.success,
      '--warning': sem.warning,
      '--danger': sem.danger
    };
    charts.forEach(function (c, i) { vars['--chart-' + (i + 1)] = c; });

    var glass = glassTokens(n, isDark);
    Object.keys(glass).forEach(function (k) { vars[k] = glass[k]; });
    return vars;
  }

  global.Tokens = {
    SEEDS: SEEDS,
    NEUTRAL: NEUTRAL,
    SEMANTIC: SEMANTIC,
    buildTokens: buildTokens,
    chartPalette: chartPalette
  };
})(window);
