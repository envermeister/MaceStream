#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DERIVED_DATA=${MACESTREAM_DERIVED_DATA:-"$ROOT_DIR/.build/DerivedData"}
APP_PATH="$DERIVED_DATA/Build/Products/Release/MaceStream.app"
DIST_DIR=${MACESTREAM_DIST_DIR:-"$ROOT_DIR/dist"}
ENGINE_SOURCE="$ROOT_DIR/MaceStream/Resources/Engine"
SIGNING_IDENTITY=${MACOS_SIGNING_IDENTITY:-}
NOTARY_PROFILE=${MACESTREAM_NOTARY_PROFILE:-}
ALLOW_ADHOC=${MACESTREAM_ALLOW_ADHOC:-0}
REQUIRE_NOTARIZATION=${MACESTREAM_REQUIRE_NOTARIZATION:-1}
APPLE_ID_VALUE=${APPLE_ID:-}
APPLE_PASSWORD=${APPLE_APP_SPECIFIC_PASSWORD:-}
APPLE_TEAM=${APPLE_TEAM_ID:-}
ASC_KEY_ID=${APP_STORE_CONNECT_API_KEY_ID:-}
ASC_ISSUER_ID=${APP_STORE_CONNECT_API_ISSUER_ID:-}
ASC_KEY_PATH=${APP_STORE_CONNECT_API_KEY_PATH:-}
NOTARY_ARGS=()

for architecture in arm64 x86_64; do
  for artifact in vmlinuz initramfs.cpio.gz runtime/opt/acestream/acestreamengine runtime/usr/bin/python3.10; do
    if [ ! -s "$ENGINE_SOURCE/$architecture/$artifact" ]; then
      printf 'Missing %s engine file: %s\n' "$architecture" "$artifact" >&2
      exit 1
    fi
  done
done
if [ ! -x "$ENGINE_SOURCE/vfkit" ]; then
  printf 'vfkit is missing or not executable.\n' >&2
  exit 1
fi
find "$ENGINE_SOURCE" -name .DS_Store -delete

if [ -z "$SIGNING_IDENTITY" ] && [ "$ALLOW_ADHOC" != "1" ]; then
  while IFS= read -r identity_line; do
    case "$identity_line" in
      *'"Developer ID Application: '*)
        SIGNING_IDENTITY=${identity_line#*\"}
        SIGNING_IDENTITY=${SIGNING_IDENTITY%%\"*}
        break
        ;;
    esac
  done < <(security find-identity -v -p codesigning)
fi
if [ -z "$SIGNING_IDENTITY" ]; then
  if [ "$ALLOW_ADHOC" = "1" ]; then
    SIGNING_IDENTITY="-"
  else
    printf 'No Developer ID Application certificate found. Set MACESTREAM_ALLOW_ADHOC=1 for local testing.\n' >&2
    exit 1
  fi
fi

if [ -n "$NOTARY_PROFILE" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "$ASC_KEY_ID$ASC_ISSUER_ID$ASC_KEY_PATH" ]; then
  if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ] || [ ! -f "$ASC_KEY_PATH" ]; then
    printf 'The App Store Connect API key, key ID, and issuer ID must be provided together.\n' >&2
    exit 1
  fi
  NOTARY_ARGS=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
elif [ -n "$APPLE_ID_VALUE$APPLE_PASSWORD$APPLE_TEAM" ]; then
  if [ -z "$APPLE_ID_VALUE" ] || [ -z "$APPLE_PASSWORD" ] || [ -z "$APPLE_TEAM" ]; then
    printf 'Apple ID, app-specific password, and team ID must be provided together.\n' >&2
    exit 1
  fi
  NOTARY_ARGS=(--apple-id "$APPLE_ID_VALUE" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM")
fi
if [ "$SIGNING_IDENTITY" = "-" ] && [ "${#NOTARY_ARGS[@]}" -gt 0 ]; then
  printf 'Notarization requires a Developer ID signature instead of ad hoc signing.\n' >&2
  exit 1
fi
if [ "$SIGNING_IDENTITY" != "-" ] && [ "$REQUIRE_NOTARIZATION" = "1" ] && [ "${#NOTARY_ARGS[@]}" -eq 0 ]; then
  printf 'MACESTREAM_NOTARY_PROFILE or notarization credentials are required for distribution.\n' >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/.cache"
xcodebuild -quiet \
  -project "$ROOT_DIR/MaceStream.xcodeproj" \
  -scheme MaceStream \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

if [ ! -d "$APP_PATH" ]; then
  printf 'Built app not found: %s\n' "$APP_PATH" >&2
  exit 1
fi
mkdir -p "$APP_PATH/Contents/Resources/Legal"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_PATH/Contents/Resources/Legal/"
cp "$ROOT_DIR/LICENSE" "$APP_PATH/Contents/Resources/Legal/"
cp -R "$ROOT_DIR/licenses" "$APP_PATH/Contents/Resources/Legal/"

APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")
if [[ ! "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  printf 'Invalid app version or build number.\n' >&2
  exit 1
fi

sign_code() {
  local target=$1
  shift
  if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign --force --sign - "$@" "$target"
  else
    codesign --force --options runtime --timestamp \
      --sign "$SIGNING_IDENTITY" "$@" "$target"
  fi
}

require_universal() {
  local binary=$1
  local architectures
  if ! architectures=$(lipo -info "$binary" 2>&1); then
    printf 'Could not read Mach-O architectures: %s\n%s\n' "$binary" "$architectures" >&2
    exit 1
  fi
  case "$architectures" in
    *x86_64*arm64*|*arm64*x86_64*) ;;
    *) printf 'Non-universal component: %s\n%s\n' "$binary" "$architectures" >&2; exit 1 ;;
  esac
}

require_macos13_compatibility() {
  local binary=$1
  if ! vtool -show-build "$binary" | awk '
    /minos / {
      count++
      split($2, version, ".")
      if (version[1] > 13) incompatible = 1
    }
    END { if (count != 2 || incompatible) exit 1 }
  '; then
    printf 'Component does not target macOS 13 on both architectures: %s\n' "$binary" >&2
    vtool -show-build "$binary" >&2
    exit 1
  fi
}

remove_developer_rpaths() {
  local binary=$1
  local rpath
  while IFS= read -r rpath; do
    case "$rpath" in
      /Applications/Xcode*.app/Contents/Developer/*)
        install_name_tool -delete_rpath "$rpath" "$binary"
        ;;
    esac
  done < <(
    otool -l "$binary" | awk '
      $1 == "path" && $0 ~ /\(offset [0-9]+\)$/ {
        sub(/[ \t]+\(offset [0-9]+\)$/, "")
        sub(/^[ \t]*path[ \t]+/, "")
        print
      }
    ' | sort -u
  )
}

if [ -d "$APP_PATH/Contents/Frameworks" ]; then
  while IFS= read -r -d '' library; do
    require_universal "$library"
    remove_developer_rpaths "$library"
    sign_code "$library"
  done < <(find "$APP_PATH/Contents/Frameworks" -type f -name '*.dylib' -print0)

  for framework in "$APP_PATH/Contents/Frameworks/"*.framework; do
    [ -d "$framework" ] || continue
    framework_name=${framework##*/}
    framework_binary="$framework/${framework_name%.framework}"
    if [ -f "$framework_binary" ]; then
      require_universal "$framework_binary"
      remove_developer_rpaths "$framework_binary"
    fi
    sign_code "$framework"
  done
fi

VFKIT_PATH="$APP_PATH/Contents/Resources/Engine/vfkit"
require_universal "$VFKIT_PATH"
require_macos13_compatibility "$VFKIT_PATH"
remove_developer_rpaths "$VFKIT_PATH"
sign_code "$VFKIT_PATH" \
  --entitlements "$ROOT_DIR/MaceStream/MaceStream.entitlements"

APP_BINARY="$APP_PATH/Contents/MacOS/MaceStream"
require_universal "$APP_BINARY"
require_macos13_compatibility "$APP_BINARY"
remove_developer_rpaths "$APP_BINARY"
sign_code "$APP_PATH" \
  --entitlements "$ROOT_DIR/MaceStream/MaceStream.entitlements"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/MaceStream-$APP_VERSION-macOS-universal.dmg"
DMG_ROOT=$(mktemp -d "$DIST_DIR/.MaceStream.XXXXXX")
cleanup() {
  rm -rf "$DMG_ROOT"
}
trap cleanup EXIT
rm -f "$DMG_PATH"
ditto "$APP_PATH" "$DMG_ROOT/MaceStream.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname MaceStream -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH"

if [ "$SIGNING_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
fi

if [ "${#NOTARY_ARGS[@]}" -gt 0 ]; then
  xcrun notarytool submit "$DMG_PATH" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
elif [ "$SIGNING_IDENTITY" != "-" ]; then
  printf 'WARNING: Package was not notarized; do not distribute it.\n' >&2
else
  printf 'WARNING: Package is ad hoc signed and is for local testing only.\n' >&2
fi
hdiutil verify "$DMG_PATH"
printf 'MaceStream package is ready: %s\n' "$DMG_PATH"
