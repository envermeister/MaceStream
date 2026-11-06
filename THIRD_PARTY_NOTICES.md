# Third-Party Notices

MaceStream's application code is written in Swift and links only to Apple frameworks.

The optional generated application bundle contains the following separate components. Their inclusion does not relicense them under MaceStream's source license.

## vfkit 0.5.1

- Project: https://github.com/crc-org/vfkit
- Binary: downloaded from the pinned GitHub release and verified with SHA-256 in `scripts/build_macos_engine_image.sh`.
- License: Apache License 2.0. See `licenses/vfkit-LICENSE`.

## AceStream Engine 3.2.11

- Project: https://acestream.media/
- Download: the official Ubuntu 22.04 x86_64 package, pinned by URL and SHA-256 in `scripts/docker/Dockerfile`.
- AceStream is third-party software and is not covered by MaceStream's source license.
- The upstream `data/webui/cert/engine.pem` file is deliberately removed because it contains private key material. The engine regenerates its local certificate as needed; no private key is shipped in MaceStream releases.

**Review AceStream's current license and redistribution terms before publishing a DMG that embeds the engine.** Excluding generated binaries from this repository does not grant redistribution permission for release packages. If permission is not available, distribute only the source and let each user obtain the engine under terms applicable to them.

## Minimal Linux guest

The generated guest contains an Alpine Linux kernel and BusyBox userspace, plus selected Ubuntu/Python runtime files required by AceStream. These components retain their own licenses and notices. The build recipe is available in `scripts/docker/` for inspection and reproduction.

Apple, macOS, Swift, AVFoundation and other Apple product names are trademarks of Apple Inc. AceStream and vfkit are the property of their respective owners.
