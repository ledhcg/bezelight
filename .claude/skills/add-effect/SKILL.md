---
name: add-effect
description: Add a new light effect (LightMode) to Bezelight end to end: enum case, params, engine frames, UI card, localisation, test. Use when asked to add or change an animation or effect.
---
# Add an effect

1. `LightMode`: add a case. Its raw value is persisted, so choose it carefully and never rename it later.
2. `EffectParams`: add fields only if the effect has settings; decode each with a default so old settings files still load.
3. `EffectEngine.animate`: generate frames. Stay allocation-light and frame-rate independent (use `dt`).
4. UI: add a card in `Sources/Bezelight/EffectCards.swift` (`AnimationCard`) built from `Surfaces.swift` pieces.
5. Strings: add every new key to all five `Localizable.strings` files (en first).
6. Test: add a test next to the others in `Tests/BezelightCoreTests`.
7. Do not copy code from projects whose licence is not MIT-compatible.
8. Run `swift build && swift test`; check the card in light and dark; add a `CHANGELOG.md` line.
