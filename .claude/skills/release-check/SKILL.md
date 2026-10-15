---
name: release-check
description: Pre-release checklist for Bezelight: version bump, changelog, tests, universal build, signing, helper checks. Use when preparing a release or tag.
---
# Release check

1. `git status` clean on `main`; `CHANGELOG.md` has the version and date; `README` badges and numbers still true.
2. `swift build -c release && swift test`.
3. `VERSION=x.y.z BUILD=n scripts/build-app.sh` (universal). The script verifies signature, helper architectures and helper behaviour.
4. Open `dist/Bezelight.app`: icon is the "b" mark, window looks right in light and dark, language switch works.
5. Tag `vx.y.z`; `.github/workflows/release.yml` publishes. Never force-push tags.
6. Version lives in `scripts/build-app.sh` defaults and is substituted into `Resources/Info.plist`; keep them in step.
