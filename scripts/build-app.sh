#!/usr/bin/env bash
# Builds build/MemeCam.app (+ embedded CMIO camera extension when signing material exists).
#
# Usage: scripts/build-app.sh [--install] [--run] [--release [path/to/appstoreconnect.env]]
#   --install  copy to /Applications/MemeCam.app (quits a running MemeCam first)
#   --run      open the app afterwards (the installed copy when --install is given)
#   --release  Developer ID signing (~/.memecam-signing/release.env, from setup-signing.py
#              --distribution), then build/MemeCam.dmg, notarize it with the ASC API key from
#              the given env file (default ~/Workspace/vps/porovnu/secrets/appstoreconnect.env)
#              and staple the ticket. The DMG then opens on any Mac.
#
# Signing material comes from `uv run --script scripts/setup-signing.py` and lives in
# ~/.memecam-signing/{signing.env, MemeCam.provisionprofile, CameraExtension.provisionprofile}.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ID="com.hexarch.memecam"
EXT_ID="com.hexarch.memecam.camera-extension"
SHORT_VERSION="1.0"
# Monotonic, period-separated integers: sysextd replaces the extension only when this grows.
BUILD_NUMBER="$(date +%Y%m%d).$(date +%H%M%S)"
MIN_MACOS="15.0"

BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/MemeCam.app"
EXT_BUNDLE="$APP/Contents/Library/SystemExtensions/$EXT_ID.systemextension"
EXT_EXE_DIR="$BUILD_DIR/extension"
GEN_DIR="$BUILD_DIR/generated"
SIGN_DIR="$HOME/.memecam-signing"
INSTALL_PATH="/Applications/MemeCam.app"

INSTALL=0
RUN=0
RELEASE=0
ASC_ENV="$HOME/Workspace/vps/porovnu/secrets/appstoreconnect.env"
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    --release) RELEASE=1 ;;
    *.env) ASC_ENV="$arg" ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
step "Building MemeCam (release, arm64)"
swift build --package-path "$ROOT" -c release --arch arm64
BIN_DIR="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)"
[[ -x "$BIN_DIR/MemeCam" ]] || die "missing $BIN_DIR/MemeCam"

# ---------------------------------------------------------------------------------------------
step "Compiling camera extension"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$EXT_EXE_DIR"
# main.swift holds top-level code, so no -parse-as-library.
swiftc -O -wmo -swift-version 6 \
  -target "arm64-apple-macos$MIN_MACOS" -sdk "$SDK" \
  -module-name MemeCamCameraExtension \
  "$ROOT"/CameraExtension/*.swift \
  -o "$EXT_EXE_DIR/$EXT_ID"

# ---------------------------------------------------------------------------------------------
step "Assembling $APP (build $BUILD_NUMBER)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MemeCam" "$APP/Contents/MacOS/MemeCam"
cp -R "$ROOT/Resources/Memes" "$APP/Contents/Resources/Memes"
cp -R "$ROOT/Resources/Models" "$APP/Contents/Resources/Models"

ICON_KEY=""
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>MemeCam</string>
	<key>CFBundleIdentifier</key><string>$APP_ID</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>MemeCam</string>
	<key>CFBundleDisplayName</key><string>MemeCam</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
	<key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSCameraUseContinuityCameraDeviceType</key><true/>
	<key>NSCameraUsageDescription</key><string>MemeCam watches your face and hands to pick a matching meme.</string>
	<key>NSSystemExtensionUsageDescription</key><string>MemeCam installs a virtual camera named “MemeCam” that Discord, Telegram and other apps can use.</string>
	$ICON_KEY
</dict>
</plist>
PLIST
plutil -lint -s "$APP/Contents/Info.plist"

# ---------------------------------------------------------------------------------------------
SIGN_ENV="$SIGN_DIR/signing.env"
PROFILE_SUFFIX=""
TIMESTAMP="--timestamp=none"
if [[ $RELEASE == 1 ]]; then
  SIGN_ENV="$SIGN_DIR/release.env"
  PROFILE_SUFFIX="-DeveloperID"
  TIMESTAMP="--timestamp"   # notarization requires a secure timestamp
  [[ -f "$SIGN_ENV" ]] || die "$SIGN_ENV missing — run: uv run --script scripts/setup-signing.py --distribution"
fi
read_env() { grep -E "^$1=" "$SIGN_ENV" | head -1 | cut -d= -f2- | tr -d '"' ; }
profile_value() { security cms -D -i "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null || true; }

SIGNED=0
if [[ -f "$SIGN_ENV" ]]; then
  TEAM_ID="$(read_env TEAM_ID)"
  SIGN_IDENTITY="$(read_env SIGN_IDENTITY)"
  APP_PROFILE="$SIGN_DIR/MemeCam$PROFILE_SUFFIX.provisionprofile"
  EXT_PROFILE="$SIGN_DIR/CameraExtension$PROFILE_SUFFIX.provisionprofile"
  [[ -n "$TEAM_ID" && -n "$SIGN_IDENTITY" ]] || die "$SIGN_DIR/signing.env must define TEAM_ID and SIGN_IDENTITY"
  [[ -f "$APP_PROFILE" && -f "$EXT_PROFILE" ]] || die "provisioning profiles missing in $SIGN_DIR (re-run scripts/setup-signing.py)"
  security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
    || die "signing identity $SIGN_IDENTITY not in keychain (re-run scripts/setup-signing.py)"
  for p in "$APP_PROFILE" "$EXT_PROFILE"; do
    team="$(profile_value "$p" TeamIdentifier.0)"
    [[ -z "$team" || "$team" == "$TEAM_ID" ]] || die "$(basename "$p") belongs to team $team, expected $TEAM_ID"
  done

  step "Embedding camera extension (team $TEAM_ID)"
  mkdir -p "$EXT_BUNDLE/Contents/MacOS" "$GEN_DIR"
  cp "$EXT_EXE_DIR/$EXT_ID" "$EXT_BUNDLE/Contents/MacOS/$EXT_ID"
  sed -e "s/__TEAM_ID__/$TEAM_ID/g" -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/g" \
      -e "s/__SHORT_VERSION__/$SHORT_VERSION/g" \
      "$ROOT/CameraExtension/Info.plist.template" > "$EXT_BUNDLE/Contents/Info.plist"
  plutil -lint -s "$EXT_BUNDLE/Contents/Info.plist"
  cp "$EXT_PROFILE" "$EXT_BUNDLE/Contents/embedded.provisionprofile"
  cp "$APP_PROFILE" "$APP/Contents/embedded.provisionprofile"

  sed -e "s/__TEAM_ID__/$TEAM_ID/g" "$ROOT/CameraExtension/CameraExtension.entitlements.template" \
    > "$GEN_DIR/CameraExtension.entitlements"
  cat > "$GEN_DIR/MemeCam.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.system-extension.install</key><true/>
	<key>com.apple.security.application-groups</key><array><string>$TEAM_ID.$APP_ID</string></array>
	<key>com.apple.application-identifier</key><string>$TEAM_ID.$APP_ID</string>
	<key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
	<key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
ENT
  plutil -lint -s "$GEN_DIR/CameraExtension.entitlements" "$GEN_DIR/MemeCam.entitlements"

  step "Signing (inside-out, hardened runtime)"
  codesign --force --options runtime $TIMESTAMP -s "$SIGN_IDENTITY" \
    --entitlements "$GEN_DIR/CameraExtension.entitlements" "$EXT_BUNDLE"
  codesign --force --options runtime $TIMESTAMP -s "$SIGN_IDENTITY" \
    --entitlements "$GEN_DIR/MemeCam.entitlements" "$APP"
  SIGNED=1
else
  step "Ad-hoc signing (no camera extension)"
  mkdir -p "$GEN_DIR"
  cat > "$GEN_DIR/MemeCam-adhoc.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.device.camera</key><true/>
</dict>
</plist>
ENT
  codesign --force -s - --entitlements "$GEN_DIR/MemeCam-adhoc.entitlements" "$APP"
fi

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
summary() { codesign -dvv "$1" 2>&1 | grep -E '^(Identifier|Format|Authority|TeamIdentifier|Signature|CodeDirectory)' || true; }
echo "-- app"; summary "$APP"
if [[ $SIGNED == 1 ]]; then
  echo "-- extension"; summary "$EXT_BUNDLE"
fi

if [[ $SIGNED == 0 ]]; then
  cat <<'MSG'

  !! Built WITHOUT the virtual camera. The extension compiled fine but was not embedded because
  !! ~/.memecam-signing/signing.env is missing. To enable the "MemeCam" camera run:
  !!     uv run --script scripts/setup-signing.py
  !! then re-run scripts/build-app.sh --install
MSG
fi

# ---------------------------------------------------------------------------------------------
if [[ $RELEASE == 1 ]]; then
  [[ $SIGNED == 1 ]] || die "release build was not signed"
  DMG="$ROOT/build/MemeCam.dmg"
  step "Creating $DMG"
  STAGE="$(mktemp -d)"
  ditto "$APP" "$STAGE/MemeCam.app"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname MemeCam -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
  rm -rf "$STAGE"
  codesign --force --timestamp -s "$SIGN_IDENTITY" "$DMG"

  step "Notarizing (takes a few minutes)"
  asc() { grep -E "^$1=" "$ASC_ENV" | head -1 | cut -d= -f2- | tr -d '"' ; }
  KEY_ID="$(asc ASC_KEY_ID)"; ISSUER="$(asc ASC_ISSUER_ID)"
  KEY_FILE="$(asc ASC_KEY_PATH)"; KEY_FILE="${KEY_FILE/#\~/$HOME}"
  [[ -f "$KEY_FILE" ]] || KEY_FILE="$(dirname "$ASC_ENV")/AuthKey_$KEY_ID.p8"
  [[ -n "$KEY_ID" && -n "$ISSUER" && -f "$KEY_FILE" ]] || die "ASC API key not found via $ASC_ENV"
  OUT_JSON="$(xcrun notarytool submit "$DMG" --key "$KEY_FILE" --key-id "$KEY_ID" --issuer "$ISSUER" \
              --wait --timeout 45m --output-format json)" || true
  STATUS="$(printf '%s' "$OUT_JSON" | plutil -extract status raw -o - - 2>/dev/null || echo unknown)"
  SUB_ID="$(printf '%s' "$OUT_JSON" | plutil -extract id raw -o - - 2>/dev/null || echo)"
  if [[ "$STATUS" != "Accepted" ]]; then
    [[ -n "$SUB_ID" ]] && xcrun notarytool log "$SUB_ID" --key "$KEY_FILE" --key-id "$KEY_ID" --issuer "$ISSUER" || true
    die "notarization status: $STATUS"
  fi
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
  printf '\nRelease DMG: %s (notarized, runs on any Mac)\n' "$DMG"
fi

if [[ $INSTALL == 1 ]]; then
  step "Installing to $INSTALL_PATH"
  if pgrep -x MemeCam >/dev/null; then
    osascript -e "tell application id \"$APP_ID\" to quit" >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -x MemeCam >/dev/null || break; sleep 0.25; done
    pkill -x MemeCam 2>/dev/null || true
  fi
  rm -rf "$INSTALL_PATH"
  ditto "$APP" "$INSTALL_PATH"
  echo "installed $INSTALL_PATH"
fi

if [[ $RUN == 1 ]]; then
  target="$APP"
  [[ $INSTALL == 1 ]] && target="$INSTALL_PATH"
  step "Opening $target"
  open "$target"
fi

printf '\nDone: %s\n' "$APP"
