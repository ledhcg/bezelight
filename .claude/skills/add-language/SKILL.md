---
name: add-language
description: Add a UI language to Bezelight (strings, Localizer, Info.plist) or fix a translation. Use when asked to translate the app or add a locale.
---
# Add a language

1. Copy `Sources/BezelightCore/Resources/en.lproj` to `<code>.lproj`; translate only the right-hand sides.
   Keep `%d` / `%@` placeholders identical and in a compatible order.
2. Add the case to `AppLanguage` in `Sources/BezelightCore/Localizer.swift` with its native name
   (written in its own language, never translated).
3. Add the code to `CFBundleLocalizations` in `Resources/Info.plist`.
4. Add a `README.<code>.md` only if a maintainer for that language exists; link it from `README.md`.
5. `swift test`: `LocalizationCoverageTests` fails on a missing key or a different placeholder.
6. Check long strings do not truncate in the main window and the menu bar popover.

To fix a single wording, edit that language's `Localizable.strings` only.
