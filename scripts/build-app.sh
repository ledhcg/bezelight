#!/usr/bin/env bash
# Builds Bezelight.app (universal, release) into ./dist.
#
#   scripts/build-app.sh                       # ad-hoc signed, runs on this Mac
#     (ad-hoc builds get a new identity every time: macOS asks for Screen Recording again.
#      Sign with a stable identity to keep the permission across rebuilds.)
#   CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh
#   VERSION=1.2.0 BUILD=42 scripts/build-app.sh
#   ARCHS="arm64" scripts/build-app.sh         # single architecture (faster)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.3.0}"
BUILD="${BUILD:-1}"
IDENTITY="${CODESIGN_IDENTITY:--}"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="dist/Bezelight.app"

arch_flags=()
for a in $ARCHS; do arch_flags+=(--arch "$a"); done

echo "▸ building ($ARCHS)"
swift build -c release "${arch_flags[@]}"
BIN_DIR="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/Bezelight" "$APP/Contents/MacOS/Bezelight"
# The hook helper that Claude Code / Codex run. The app copies it to ~/.bezelight/bin on request.
cp "$BIN_DIR/bezelight-hook" "$APP/Contents/Helpers/bezelight-hook"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
# SwiftPM resource bundles (localisations) go next to the other app resources.
for b in "$BIN_DIR"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
swift scripts/make-icon.swift Resources/Icon/bezelight-mark.png "$APP/Contents/Resources/AppIcon.icns" >/dev/null

echo "▸ signing ($IDENTITY)"
if [ "$IDENTITY" = "-" ]; then
  cat >&2 <<'WARN'
  note: ad-hoc signature. macOS ties the Screen Recording permission to the app's code hash, which
        changes with every ad-hoc build, so the permission prompt comes back after each rebuild.
        Sign with a stable identity to keep the permission:
          security find-identity -v -p codesigning
          CODESIGN_IDENTITY="<name or SHA-1 of an identity above>" scripts/build-app.sh
        (a free "Apple Development" certificate is enough on your own Mac)
WARN
fi
# A real identity needs a secure timestamp (required for notarization); ad-hoc cannot have one.
if [ "$IDENTITY" = "-" ]; then TS="--timestamp=none"; else TS="--timestamp"; fi
# Sign nested code first (resource bundles, then the helper), then the app (`--deep` is deprecated).
for b in "$APP"/Contents/Resources/*.bundle; do codesign --force $TS -s "$IDENTITY" "$b"; done
codesign --force --options runtime $TS -s "$IDENTITY" --identifier io.github.ledhcg.bezelight.hook "$APP/Contents/Helpers/bezelight-hook"
codesign --force --options runtime $TS -s "$IDENTITY" --identifier io.github.ledhcg.bezelight "$APP"
codesign --verify --strict --deep "$APP"

echo "▸ checking the helper"
HELPER="$APP/Contents/Helpers/bezelight-hook"
codesign --verify --strict "$HELPER"
for a in $ARCHS; do
  lipo -archs "$HELPER" | grep -qw "$a" || { echo "helper is missing architecture $a" >&2; exit 1; }
done
# It must work from inside the bundle, answer {} and never write to stderr.
OUT="$(echo '{}' | BEZELIGHT_HOME="$(mktemp -d)" "$HELPER" claude 2>/tmp/bezelight-hook.err)"
[ "$OUT" = "{}" ] && [ ! -s /tmp/bezelight-hook.err ] || { echo "the helper misbehaves: '$OUT'" >&2; exit 1; }
echo "  $("$HELPER" --version)"
echo "✓ $APP  (v$VERSION, build $BUILD)"
