# Accessibility & Theming

- **Dark-mode-first palette**: Primary surfaces center on dark tones (Canvas/Surface/Card) with strokes boosted to 38% (Stroke) and 34% (StrokeMuted) opacity in dark mode. Borders now meet ≥3.0:1 contrast on dark surfaces and cards.
- **Risk badge safety** (dark mode ratios):  
  - Low: foreground/background ≥6.5:1  
  - Medium: ≥7.8:1  
  - High: ≥4.9:1  
  All three satisfy WCAG 2.1 AA for small text.
- **Accent fallbacks**: `Colors.preferredAccent(for:)` prefers the user's macOS accent if it keeps ≥4.5:1 contrast against Canvas; otherwise it falls back to the app's Accent token. Use this for interactive highlights and badges.
- **Dynamic Type**: Typography tokens now use text styles (headline/body/caption/footnote) so they scale with user Content Size. Card tiles wrap titles/metadata at accessibility sizes; metadata grids collapse to a single column when Dynamic Type enters accessibility categories.
- **Reduced motion**: Motion tokens already honor the system Reduce Motion setting; hover/board/modal animations disable automatically.

History: 2025-11-25 — Documented contrast targets, accent fallback, and scaling behavior.
