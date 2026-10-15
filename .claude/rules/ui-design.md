---
paths:
  - "Sources/Bezelight/**/*.swift"
---
# SwiftUI design consistency

- Compose screens from `Surfaces.swift` (`surface`, `capsuleSurface`, `Card`, `SoftSlider`, `ValueSlider`,
  `PrimaryActionStyle`, `StageBackdrop`). Do not introduce system sliders, flat black plates or ad-hoc materials.
- Fonts by role: `.headline`, `.callout`, `.caption`. Colors: `.primary` / `.secondary` or the user's tint;
  never hard-coded black/white text. Hints must stay legible on glass.
- Spacing 4 / 8 / 12 / 14, card radius 14 to 22; 8 between related controls.
- Live values live in small observed objects; do not make a whole panel observe fast-changing state.
- Check light and dark, plus the macOS 14/15 fallback (`#available(macOS 26, *)` paths).
- Icon-only controls need an accessibility label. Never rely on color alone for state.
- Every visible string uses `tr("key")`; add the key to all five `Localizable.strings` files.
