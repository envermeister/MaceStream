#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ENGINE_ROOT="$ROOT_DIR/MaceStream/Resources/Engine"
TARGET_ARCH=${MACESTREAM_ENGINE_ARCH:-$(uname -m)}
WORK_DIR="$ROOT_DIR/.build/macestream-engine-$TARGET_ARCH"
VFKIT_VERSION=${VFKIT_VERSION:-0.5.1}
VFKIT_SHA256=${VFKIT_SHA256:-6adf8ab2fb0a3b7e7d778554bdc4ae8a8d9e8f984cebffd4e0c8ff8ea5f08447}
IMAGE_TAG=macestream-engine-rootfs:3.2.11

for command in docker curl shasum tar cpio gzip python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Required developer tool not found: %s\n' "$command" >&2
    exit 1
  fi
done
if ! docker info >/dev/null 2>&1; then
  printf 'Docker is not running. Docker is only required to build the image; end users do not need Docker.\n' >&2
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'This script must run on macOS.\n' >&2
  exit 1
fi
case "$TARGET_ARCH" in
  arm64|aarch64)
    TARGET_ARCH=arm64
    DOCKER_PLATFORM=linux/arm64
    ;;
  x86_64|amd64)
    TARGET_ARCH=x86_64
    DOCKER_PLATFORM=linux/amd64
    ;;
  *) printf 'MACESTREAM_ENGINE_ARCH must be arm64 or x86_64.\n' >&2; exit 1 ;;
esac
OUTPUT_DIR="$ENGINE_ROOT/$TARGET_ARCH"
WORK_DIR="$ROOT_DIR/.build/macestream-engine-$TARGET_ARCH"

mkdir -p "$OUTPUT_DIR" "$WORK_DIR/rootfs"
VFKIT_PATH="$ENGINE_ROOT/vfkit"
VFKIT_URL="https://github.com/crc-org/vfkit/releases/download/v${VFKIT_VERSION}/vfkit"
if [ ! -f "$VFKIT_PATH" ] || ! printf '%s  %s\n' "$VFKIT_SHA256" "$VFKIT_PATH" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl -fL --retry 3 "$VFKIT_URL" -o "$VFKIT_PATH.download"
  printf '%s  %s\n' "$VFKIT_SHA256" "$VFKIT_PATH.download" | shasum -a 256 -c -
  mv "$VFKIT_PATH.download" "$VFKIT_PATH"
fi
chmod 0755 "$VFKIT_PATH"
"$VFKIT_PATH" --version

docker build \
  --platform "$DOCKER_PLATFORM" \
  --target rootfs \
  --tag "$IMAGE_TAG" \
  --file "$ROOT_DIR/scripts/docker/Dockerfile" \
  "$ROOT_DIR"

CONTAINER_ID=$(docker create --platform "$DOCKER_PLATFORM" "$IMAGE_TAG")
cleanup() {
  docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

rm -rf "$WORK_DIR/rootfs"
mkdir -p "$WORK_DIR/rootfs"
docker export "$CONTAINER_ID" -o "$WORK_DIR/rootfs.tar"
tar -xf "$WORK_DIR/rootfs.tar" -C "$WORK_DIR/rootfs"
cp "$WORK_DIR/rootfs/boot/vmlinuz" "$OUTPUT_DIR/vmlinuz"
rm -rf "$WORK_DIR/rootfs/boot" "$OUTPUT_DIR/runtime"
mkdir -p "$OUTPUT_DIR/runtime/usr/bin" "$OUTPUT_DIR/runtime/usr/lib" "$OUTPUT_DIR/runtime/usr/local/lib"
mv "$WORK_DIR/rootfs/opt" "$OUTPUT_DIR/runtime/opt"
mv "$WORK_DIR/rootfs/usr/bin/python3.10" "$OUTPUT_DIR/runtime/usr/bin/python3.10"
mv "$WORK_DIR/rootfs/usr/bin/python3" "$OUTPUT_DIR/runtime/usr/bin/python3"
mv "$WORK_DIR/rootfs/usr/lib/python3.10" "$OUTPUT_DIR/runtime/usr/lib/python3.10"
mv "$WORK_DIR/rootfs/usr/lib/x86_64-linux-gnu" "$OUTPUT_DIR/runtime/usr/lib/x86_64-linux-gnu"
mv "$WORK_DIR/rootfs/usr/local/lib/python3.10" "$OUTPUT_DIR/runtime/usr/local/lib/python3.10"
ln -s /runtime/opt "$WORK_DIR/rootfs/opt"
ln -s /runtime/usr/bin/python3.10 "$WORK_DIR/rootfs/usr/bin/python3.10"
ln -s /runtime/usr/bin/python3 "$WORK_DIR/rootfs/usr/bin/python3"
ln -s /runtime/usr/lib/python3.10 "$WORK_DIR/rootfs/usr/lib/python3.10"
ln -s /runtime/usr/lib/x86_64-linux-gnu "$WORK_DIR/rootfs/usr/lib/x86_64-linux-gnu"
ln -s /runtime/usr/local/lib/python3.10 "$WORK_DIR/rootfs/usr/local/lib/python3.10"
python3 "$ROOT_DIR/scripts/relativize_runtime_symlinks.py" "$OUTPUT_DIR/runtime"
(
  cd "$WORK_DIR/rootfs"
  find . -print | cpio -o -H newc 2>/dev/null | gzip -9
) > "$OUTPUT_DIR/initramfs.cpio.gz"

for artifact in vmlinuz initramfs.cpio.gz runtime/opt/acestream/acestreamengine runtime/usr/bin/python3.10; do
  if [ ! -s "$OUTPUT_DIR/$artifact" ]; then
    printf 'Could not build engine artifact: %s\n' "$artifact" >&2
    exit 1
  fi
done
if [ ! -s "$ENGINE_ROOT/vfkit" ]; then
  printf 'Could not build engine artifact: vfkit\n' >&2
  exit 1
fi
rm -f "$OUTPUT_DIR/runtime/opt/acestream/data/webui/cert/engine.pem"
if find "$OUTPUT_DIR/runtime/opt/acestream/data" -name '*.pem' -exec grep -l 'PRIVATE KEY' {} + | grep -q .; then
  printf 'Private key material found in the engine data. Refusing to package it.\n' >&2
  exit 1
fi
printf 'MaceStream %s engine files are ready: %s\n' "$TARGET_ARCH" "$OUTPUT_DIR"
