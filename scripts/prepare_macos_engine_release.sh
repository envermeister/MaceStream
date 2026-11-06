#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENGINE_SOURCE="$ROOT_DIR/MaceStream/Resources/Engine"
OUTPUT_DIR=${MACESTREAM_ENGINE_DIST_DIR:-"$ROOT_DIR/.cache/engine-release"}
ARCHIVE_NAME="macestream-engine-macos-universal-v1.tar.gz"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"

for architecture in arm64 x86_64; do
  for artifact in vmlinuz initramfs.cpio.gz runtime/opt/acestream/acestreamengine runtime/usr/bin/python3.10; do
    if [ ! -s "$ENGINE_SOURCE/$architecture/$artifact" ]; then
      printf 'Missing %s engine file: %s\n' "$architecture" "$artifact" >&2
      exit 1
    fi
  done
done
if [ ! -s "$ENGINE_SOURCE/vfkit" ]; then
  printf 'Universal vfkit not found.\n' >&2
  exit 1
fi

ARCHITECTURES=$(lipo -info "$ENGINE_SOURCE/vfkit" 2>&1) || {
  printf 'Could not read vfkit architectures: %s\n' "$ARCHITECTURES" >&2
  exit 1
}
case "$ARCHITECTURES" in
  *x86_64*arm64*|*arm64*x86_64*) ;;
  *) printf 'A universal vfkit binary is required: %s\n' "$ARCHITECTURES" >&2; exit 1 ;;
esac

if find "$ENGINE_SOURCE" -name '*.pem' -exec grep -l 'PRIVATE KEY' {} + | grep -q .; then
  printf 'Private key material found in the engine. Remove it before creating a release archive.\n' >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -f "$ARCHIVE_PATH" "$ARCHIVE_PATH.sha256"
(
  cd "$ROOT_DIR/MaceStream/Resources"
  COPYFILE_DISABLE=1 tar -czf "$ARCHIVE_PATH" Engine
)
(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
  shasum -a 256 -c "$ARCHIVE_NAME.sha256"
)
printf 'Universal engine release assets are ready:\n%s\n%s.sha256\n' "$ARCHIVE_PATH" "$ARCHIVE_PATH"
