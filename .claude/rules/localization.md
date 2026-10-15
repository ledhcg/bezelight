---
paths:
  - "Sources/BezelightCore/Resources/**"
  - "Sources/BezelightCore/Localizer.swift"
  - "Resources/Info.plist"
---
# Localisation

- Five languages: en (source of truth), vi, zh-Hans, ja, ko. A key exists in all of them or the test fails.
- Keys are `area.name`. Placeholders (`%d`, `%@`) are identical in every language; never concatenate fragments.
- Sentence case, no trailing period on labels, imperative verbs on buttons.
- Native language names are never translated (`AppLanguage.nativeName`).
- New language: see the `add-language` skill. Run `swift test` (LocalizationCoverageTests).
