# Motion Tokens

- **hover**: easeInOut, 0.16s — card hover/press affordances.
- **board**: snappy, 0.22s, extraBounce 0.10 — drag/drop, column/card layout changes.
- **modal**: easeInOut, 0.18s — detail modal mode transitions.

## Reduced Motion
- When macOS **Reduce Motion** is enabled, the above animations are disabled (no implicit animation).
- Hover state changes become instant; drag/drop layout changes snap without animation; modal mode switches update without animation.

## Application Map
- Card hover: `DesignTokens.Motion.hover` (or disabled under Reduce Motion).
- Board/column/card layout changes: `DesignTokens.Motion.board`.
- Detail modal mode switching: `DesignTokens.Motion.modal`.
- Focus/keyboard: cards are focusable with Tab; Space/Return activate (open modal); accent focus ring applied. Hover/tint changes remain visible when motion is reduced.
