#!/bin/zsh
# Builds ShotIt (Release) and installs it to /Applications/ShotIt.app.
# A stable install path keeps the Dock/Settings icon and the Screen Recording permission from getting confused
# with throw-away build folders.
set -euo pipefail
cd "${0:A:h}/.."

if ! xcode-select -p >/dev/null 2>&1 || ! command -v xcodebuild >/dev/null; then
  echo "error: Xcode is required (install it from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app)" >&2; exit 1
fi
if ! command -v xcodegen >/dev/null; then
  echo "error: xcodegen not found. Install it with: brew install xcodegen" >&2; exit 1
fi
xcodegen generate >/dev/null
xcodebuild -project ShotIt.xcodeproj -scheme ShotIt -configuration Release -derivedDataPath build/DerivedData build | tail -1
# Ad-hoc signatures change on every build, so macOS treats each install as a new app and asks for Screen Recording
# again. Signing with a certificate keeps the designated requirement (bundle id + certificate) stable.
# Uses the local self-signed "ShotIt Local" certificate (create it once with tools/make-signing-cert.sh).
# Override with SIGN_IDENTITY="<name or hash>".
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning | grep -q '"ShotIt Local"'; then IDENTITY="ShotIt Local"; fi
APP=build/DerivedData/Build/Products/Release/ShotIt.app
if [[ -n "$IDENTITY" ]]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  echo "warning: no signing certificate; ad-hoc signed, so permissions reset on every install. Run tools/make-signing-cert.sh once." >&2
fi
# One-time migration: grants made to a build signed differently (ad-hoc, or another certificate) can never match
# this signature, so clear them once; the next launch asks again and the grant then sticks. Skipped when the
# installed app already carries the same signing requirement, which keeps existing grants.
if [[ -n "$IDENTITY" && -d /Applications/ShotIt.app ]]; then
  old=$(codesign -d -r- /Applications/ShotIt.app 2>&1 | grep designated || true)
  new=$(codesign -d -r- "$APP" 2>&1 | grep designated || true)
  if [[ "$old" != "$new" ]]; then
    for svc in ScreenCapture Accessibility ListenEvent PostEvent; do tccutil reset "$svc" com.shotit.app >/dev/null 2>&1 || true; done
    echo "Signing identity changed: cleared old permissions. Re-grant Screen Recording / Accessibility once."
  fi
fi
pkill -x ShotIt 2>/dev/null || true
rm -rf /Applications/ShotIt.app
ditto "$APP" /Applications/ShotIt.app
open /Applications/ShotIt.app
echo "Installed /Applications/ShotIt.app"
