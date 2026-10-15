---
name: ui-review
description: Review SwiftUI changes in Bezelight against the shared design system (Surfaces.swift, docs/STYLE.md): components, typography, spacing, color, light/dark, localisation, accessibility. Use after any change under Sources/Bezelight.
---
# UI review

Read `docs/STYLE.md` (UI and Localisation sections) and `Sources/Bezelight/Surfaces.swift`, then check the diff:

- [ ] Uses shared surfaces and controls; no system sliders, flat black plates, or ad-hoc materials
- [ ] Fonts by role (`.headline` / `.callout` / `.caption`); no stray fixed sizes
- [ ] Spacing from the scale (4, 8, 12, 14); card radius 14 to 22
- [ ] No hard-coded black/white text; hints legible on glass; works in light and dark
- [ ] macOS 14/15 fallback path still compiles and looks right
- [ ] Fast-changing values live in small observed objects (no whole-panel redraw)
- [ ] Icon-only controls have accessibility labels; state not conveyed by color alone
- [ ] All strings use `tr("key")` and exist in all five languages
- [ ] Long translations (vi, ja, de-length strings) do not truncate

Report findings as `file:line` + fix; then run `swift build && swift test`.
