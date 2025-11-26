- Keep source assets read-only; no raster edits needed.
- Extract hex values and font names directly from the design doc where present.
- Design reference (from provided screenshots in `project/phase-2-ui-foundations/design/`):
  - Palette: canvas/background ~#0c0c0c with surface cards at #222222 and borders at #2a2a2a; primary text around #eaeaea, muted labels near #959595. Accents: purple #b87efe (parallel tag), blue #66a0fd (links/branch), green #66dc7e (low/success), amber #f5ca0f (medium/warning), red #ee6e6c (high/danger).
  - Typography: system sans (SF) feel; titles/section headers ~18 pt semibold; card titles and primary labels ~15–16 pt medium; body copy and field values ~14 pt regular; metadata labels/capsules ~12–13 pt medium with slight letter spacing.
  - Spacing & radius: page gutters roughly 24 px; column gaps ~24 px; card padding ~16 px with 12 px vertical spacing between blocks; control heights ~36 px; pills and inputs radius ~10 px; cards/surfaces radius ~12 px; chips/badges use 10 px radius with 4 px inset padding.
  - Motion cues (for downstream implementation): use short ease-out for taps/hover (160–200 ms, cubic-bezier 0.4, 0.0, 0.2, 1), slightly longer surface/layout transitions (220–260 ms with the same curve), and springy drag/expand interactions with gentle damping (response ~0.25 s, damping ratio ~0.85) to keep the kanban feel responsive without overshoot.
  
- Provide previews/examples for quick visual validation.
- Keep values in one place to avoid drift; no hard-coded colors in views.
