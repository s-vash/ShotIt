#!/bin/zsh
# Builds a Release ShotIt.app and packages it as dist/ShotIt-<version>.dmg (drag-to-Applications layout).
#
# Signing (not notarized, so Gatekeeper will still block the first launch on other Macs; see the README):
#   default            "ShotIt Local" certificate if present (create it with tools/make-signing-cert.sh), else ad-hoc.
#                      Signing every release with the SAME certificate keeps users' Screen Recording / Accessibility
#                      grants across updates. Keep a backup of that certificate; losing it resets everyone's grants once.
#   --adhoc            ad-hoc signature. Works everywhere, but users re-grant permissions after every update.
#   SIGN_IDENTITY=...  use another identity (for example a Developer ID certificate).
set -euo pipefail
cd "${0:A:h}/.."

ADHOC=0
[[ "${1:-}" == "--adhoc" ]] && ADHOC=1

if ! xcode-select -p >/dev/null 2>&1 || ! command -v xcodebuild >/dev/null; then
  echo "error: Xcode is required" >&2; exit 1
fi
command -v xcodegen >/dev/null || { echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2; exit 1 }

IDENTITY="-"
if (( ! ADHOC )); then
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then IDENTITY="$SIGN_IDENTITY"
  elif security find-identity -p codesigning | grep -q '"ShotIt Local"'; then IDENTITY="ShotIt Local"
  else echo "note: no \"ShotIt Local\" certificate; using an ad-hoc signature (run tools/make-signing-cert.sh to keep permissions across updates)" >&2
  fi
fi

xcodegen generate >/dev/null
# Universal binary (Apple Silicon + Intel) regardless of the machine this runs on.
xcodebuild -project ShotIt.xcodeproj -scheme ShotIt -configuration Release -derivedDataPath build/DerivedData \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build | tail -1

APP=build/DerivedData/Build/Products/Release/ShotIt.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
# Drop debug symbols: they carry absolute build paths (home directory, username) and are useless to users.
strip -S "$APP/Contents/MacOS/ShotIt"
codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Signed with: $([[ $IDENTITY == - ]] && echo ad-hoc || echo $IDENTITY)  |  archs: $(lipo -archs "$APP/Contents/MacOS/ShotIt")"

STAGE=build/dmg
DMG="dist/ShotIt-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/ShotIt.app"
cp LICENSE "$STAGE/LICENSE.txt"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/First launch.txt" <<TXT
ShotIt is not notarized by Apple, so macOS blocks it the first time.

1. Drag ShotIt into Applications and open it. macOS shows a warning: click Done.
2. Open System Settings > Privacy & Security, scroll to the message about ShotIt and click "Open Anyway".
3. Confirm with your password. Then allow Screen & System Audio Recording when asked, and relaunch ShotIt.

Terminal alternative:  xattr -dr com.apple.quarantine /Applications/ShotIt.app
TXT
hdiutil create -volname "ShotIt $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Refuse to ship a DMG that still embeds this machine's home directory.
if LC_ALL=C grep -rqa "$HOME" "$STAGE/ShotIt.app"; then
  echo "error: the app still contains '$HOME' (build paths); not shipping $DMG" >&2; rm -rf "$STAGE" "$DMG"; exit 1
fi
rm -rf "$STAGE"
echo "Created $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
