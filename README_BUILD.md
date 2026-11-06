# Building and Releasing MaceStream

## 1. Development requirements

- Xcode 16.4 or newer with macOS SDK and command-line tools.
- macOS 13 or newer on the target machine.
- Docker Desktop **only when regenerating the Linux engine artifacts**.
- Python 3 and `cpio`, used by the engine build recipe.

The application target uses Swift and Apple frameworks only. Users do not need any of the development dependencies.

## 2. Generate the engine

Generate both guest architectures. They are not interchangeable because vfkit does not emulate a different CPU:

```bash
./scripts/build_macos_engine_image.sh
MACESTREAM_ENGINE_ARCH=x86_64 ./scripts/build_macos_engine_image.sh
```

On Intel, generate the ARM64 guest explicitly instead:

```bash
MACESTREAM_ENGINE_ARCH=arm64 ./scripts/build_macos_engine_image.sh
```

The script pins vfkit 0.5.1 (macOS 13 deployment target) and AceStream 3.2.11 with SHA-256 hashes. It creates:

```text
MaceStream/Resources/Engine/
├── vfkit                         # Universal macOS executable
├── arm64/
│   ├── vmlinuz
│   ├── initramfs.cpio.gz
│   └── runtime/
└── x86_64/
    ├── vmlinuz
    ├── initramfs.cpio.gz
    └── runtime/
```

These generated files are ignored by Git. The current short virtio-fs mount tags (`mace-runtime` and `mace-rosetta`) are intentional; changing them requires an initramfs rebuild and a real vfkit boot test.

On Apple Silicon the ARM64 Linux kernel boots natively and the official x86_64 AceStream process runs through Linux Rosetta. On Intel both the guest and engine run natively x86_64.

## 3. Build and test

Open `MaceStream.xcodeproj` directly, or use the command line:

```bash
xcodebuild -project MaceStream.xcodeproj \
  -scheme MaceStream \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  build
```

Run all unit tests with local ad-hoc signing:

```bash
xcodebuild -project MaceStream.xcodeproj \
  -scheme MaceStream \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  test
```

The test host detects XCTest and does not launch a real VM. CI therefore tests Swift logic without requiring generated engine binaries. The packaging script still requires both real guest architectures.

## 4. Local package

For a package used only on your own Mac:

```bash
MACESTREAM_ALLOW_ADHOC=1 \
MACESTREAM_DIST_DIR="$PWD/.cache/local-dist" \
./scripts/package_macos.sh
```

Ad-hoc or non-notarized packages must not be distributed to users.

## 5. Developer ID and notarization

The packaging script selects the first **Developer ID Application** certificate automatically. Set `MACOS_SIGNING_IDENTITY` to choose another identity.

Create a notarytool keychain profile once:

```bash
xcrun notarytool store-credentials "macestream-notary"
```

Use an Apple **app-specific password**, not the normal Apple account password. Then build:

```bash
export MACESTREAM_NOTARY_PROFILE="macestream-notary"
./scripts/package_macos.sh
```

The script:

1. Builds a universal Release app with macOS 13 as deployment target.
2. Verifies both Linux guest directories and the universal vfkit binary.
3. Removes Xcode-specific RPATHs.
4. Signs Swift libraries, vfkit with virtualization entitlements, the app and DMG from inside out.
5. Runs strict codesign verification.
6. Submits the DMG for notarization, staples the ticket and validates Gatekeeper and DMG integrity.

App Store Connect API credentials can be used instead of the keychain profile through `APP_STORE_CONNECT_API_KEY_PATH`, `APP_STORE_CONNECT_API_KEY_ID` and `APP_STORE_CONNECT_API_ISSUER_ID`.

## 6. Runtime smoke test

Close any running MaceStream instance, then run:

```bash
./scripts/smoke_test_macos.sh
```

The test starts the Release app, discovers its loopback-only ephemeral listener and calls `get_version`. Success looks like:

```text
AceStream engine API verified (127.0.0.1:52534): ... "version": "3.2.11" ...
```

It terminates only the app and child VM that it started. Logs are in `.cache/macos-smoke.log`, `~/Library/Application Support/MaceStream/Logs/engine.log` and `vm-serial.log`.

## 7. Prepare the CI engine prerelease

After generating and testing both architectures:

```bash
./scripts/prepare_macos_engine_release.sh

gh release create engine-macos-v1 \
  .cache/engine-release/macestream-engine-macos-universal-v1.tar.gz \
  .cache/engine-release/macestream-engine-macos-universal-v1.tar.gz.sha256 \
  --prerelease \
  --title "MaceStream Universal Engine v1" \
  --notes "Build-time engine archive; not an app release."
```

Do not replace an engine archive under a tag already used by an app release. Bump the engine tag and asset name together when the engine changes.

## 8. GitHub Actions

`ci.yml` builds and tests pushes to `main` and pull requests without engine binaries.

The release workflow expects these secrets:

| Secret | Purpose |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Developer ID certificate and private key as Base64 |
| `MACOS_CERTIFICATE_PASSWORD` | P12 export password |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password |
| `APPLE_TEAM_ID` | Apple Developer Team ID |
| `MACOS_SIGNING_IDENTITY` | Optional full certificate name |

Upload the P12 and its password as separate secrets:

```bash
base64 -i DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64
gh secret set MACOS_CERTIFICATE_PASSWORD
```

Never commit certificates, passwords, provisioning files or notarization credentials.

## 9. Troubleshooting

- **The VM log stops before “virtual machine is running”:** check vfkit version, virtio-fs mount tags and virtualization entitlement; do not debug AVPlayer first.
- **The VM runs but API does not respond:** inspect `vm-serial.log`, Linux Rosetta mounting, the `vmw_vsock_virtio_transport` module and `/var/log/vsock-proxy.log` inside the guest. Local playback uses vsock, not host-to-guest IP routing.
- **Port 6878 is already used on the host:** this is not a MaceStream conflict. The app deliberately uses a separate ephemeral loopback port.
- **A link returns stats but no video:** distinguish engine failure from an AVFoundation codec/container limitation. Copy diagnostics before clearing logs.
- **The app cannot open a downloaded engine binary:** verify its SHA-256, file permissions, codesign chain and quarantine state; never bypass these checks globally.
