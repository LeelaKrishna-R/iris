#!/bin/bash
# Build Iris.app and install it to ~/Applications.
#   ./build.sh            build + install
#   ./build.sh --launch   … and (re)start her (opens the app; she keeps herself running from then on)
# Signed with your Apple Development identity when you have one, so macOS keeps the Screen Recording,
# Microphone and Accessibility grants across rebuilds; otherwise ad-hoc (grants are asked for again).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/Iris.app"
STAGE="$(mktemp -d)/Iris.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp .build/release/Iris "$STAGE/Contents/MacOS/Iris"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
for d in sprites anim live; do [ -d "Resources/$d" ] && cp -R "Resources/$d" "$STAGE/Contents/Resources/$d"; done
[ -f Resources/catalog.json ] && cp Resources/catalog.json "$STAGE/Contents/Resources/catalog.json"
IDENTITY="${IRIS_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --entitlements Resources/Iris.entitlements --sign "$IDENTITY" "$STAGE"
else
  echo "no Apple Development identity: ad-hoc signing (macOS will ask for permissions again after each rebuild)" >&2
  codesign --force --entitlements Resources/Iris.entitlements --sign - "$STAGE"
fi
codesign --verify --strict "$STAGE"
mkdir -p "$HOME/Applications"
if [ "${1:-}" = "--launch" ]; then pkill -x Iris 2>/dev/null || true; sleep 1; fi
rm -rf "$APP"
mv "$STAGE" "$APP"
echo "installed $APP"
if [ "${1:-}" = "--launch" ]; then open "$APP"; echo "started Iris"; fi
