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

  function relLuminance(r, g, b) {
    var lin = function (x) {
      return x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
  }

  function onColor(hex) {
    var c = hexToRgb(hex);
    var L = relLuminance(c[0], c[1], c[2]);
    return 1.05 / (L + 0.05) >= (L + 0.05) / 0.05 ? '#ffffff' : '#000000';
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
