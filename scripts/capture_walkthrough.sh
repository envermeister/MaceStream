#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DERIVED_DATA="$ROOT_DIR/.build/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Debug/MaceStream.app"
ASSETS_DIR="$ROOT_DIR/docs/assets"
FRAMES_DIR="$ROOT_DIR/.cache/walkthrough-frames"
NORMALIZED_DIR="$ROOT_DIR/.cache/walkthrough-normalized"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required only to regenerate README media." >&2
  exit 1
fi

mkdir -p "$ASSETS_DIR"
rm -rf "$FRAMES_DIR"
xcodebuild -quiet \
  -project "$ROOT_DIR/MaceStream.xcodeproj" \
  -scheme MaceStream \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  build

MACESTREAM_CAPTURE_DIR="$ASSETS_DIR" \
MACESTREAM_CAPTURE_FRAMES="$FRAMES_DIR" \
"$APP_PATH/Contents/MacOS/MaceStream" \
  >"$ROOT_DIR/.cache/walkthrough-capture.log" 2>&1

rm -rf "$NORMALIZED_DIR"
mkdir -p "$NORMALIZED_DIR"
for frame in "$FRAMES_DIR"/frame-*.png; do
  name=${frame##*/}
  ffmpeg -hide_banner -loglevel error -y \
    -i "$frame" \
    -vf "scale=960:614:force_original_aspect_ratio=decrease:flags=lanczos,pad=960:614:(ow-iw)/2:(oh-ih)/2:black" \
    -frames:v 1 \
    "$NORMALIZED_DIR/$name"
done

ffmpeg -hide_banner -loglevel error -y \
  -framerate 2 \
  -i "$NORMALIZED_DIR/frame-%03d.png" \
  -filter_complex "[0:v]tpad=stop_mode=clone:stop_duration=1,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a" \
  -loop 0 \
  "$ASSETS_DIR/walkthrough.gif"

cp "$ROOT_DIR/MaceStream/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" \
  "$ASSETS_DIR/logo.png"
