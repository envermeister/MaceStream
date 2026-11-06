# Architecture

## Process layout

```text
MaceStream (SwiftUI / AppKit)
├── PlaybackController ── AVPlayer / AVPlayerItem / AVPlayerLayer
├── AceStreamClient ───── URLSession
├── EngineController ──── vfkit process + health monitoring
└── TCPRelay ──────────── Network.framework
         │ 127.0.0.1:<ephemeral port>
         │ vfkit Unix socket + virtio-vsock
         ▼
   Linux guest localhost:6878
   └── Official AceStream engine
            │
            └── NAT used only for external P2P/network traffic
```

The guest runs without Docker on the user's Mac. vfkit uses Virtualization.framework. Its runtime is mounted read-only over virtio-fs and the writable cache stays on the host under the user's Caches directory.

### Why virtio-vsock?

The local API/video path does not depend on host-to-guest IP routing. A small Python proxy inside the guest accepts AF_VSOCK connections and forwards them to AceStream on `127.0.0.1:6878`. vfkit maps these connections to a short-lived Unix socket on the host. `TCPRelay` bridges that socket to the app's loopback listener.

This avoids vmnet bridge failures, Docker address conflicts and accidental LAN exposure while retaining NAT for the engine's outbound peer-to-peer connectivity. The guest also has a dedicated `192.168.64.23` address for diagnostics, but MaceStream does not connect to that address for playback.

## Why two Linux guests?

vfkit does not emulate a different CPU architecture. A universal Mach-O app cannot boot an ARM64 kernel on Intel or an x86_64 kernel on Apple Silicon. The package therefore contains:

- `Engine/vfkit`: universal macOS executable with a macOS 13 deployment target.
- `Engine/arm64`: ARM64 kernel/initramfs used on Apple Silicon.
- `Engine/x86_64`: x86_64 kernel/initramfs used on Intel.

`EngineController` queries the machine rather than the architecture the app happens to be running under, so the correct guest is also selected when the app itself runs through Rosetta. The official AceStream engine is x86_64 in both guests; Apple Silicon uses Linux Rosetta through virtio-fs.

## Loopback relay

`TCPRelay` binds an operating-system-selected port on `127.0.0.1`, not on a public interface. It forwards independent full-duplex TCP connections to vfkit's Unix/vsock endpoint and supports TCP half-close in both directions. API and playback URLs returned by AceStream are rewritten to the dynamic loopback endpoint.

This avoids killing unknown processes, conflicts with another AceStream installation and accidental LAN exposure.

## State ownership

- `AppEnvironment` owns stores and controllers and coordinates shutdown.
- `EngineController` serializes start/stop/cache operations, owns only the vfkit process it launched, and waits for process exit with a bounded SIGKILL fallback.
- `PlaybackController` owns the player, current engine session, media observations, statistics and bounded retry operations.
- Monotonic operation IDs plus item-identity checks invalidate late callbacks when a user switches links or stops playback.
- `HistoryStore` and `SettingsStore` perform small atomic JSON writes locally.

## Playback policy

`AVPlayerItem.preferredForwardBufferDuration` receives the selected target. `AVPlayer.automaticallyWaitsToMinimizeStalling` and paused live-network behavior are configurable. KVO, player notifications, access logs and engine statistics are kept separate so the UI can distinguish engine prebuffering from AVPlayer buffering.

A failed session has one pending retry task at a time and receives at most two automatic reconnect attempts with increasing delay. The budget resets after 30 seconds of sustained playback. The user can stop or manually retry at any point. Operations are cancelled when their owner changes streams or the application exits.

## Distribution and trust

Generated engine artifacts are excluded from Git. Build recipes pin vfkit and AceStream downloads with SHA-256 hashes. The packaging script checks universal Mach-O architectures, requires macOS 13 compatibility in both app/vfkit slices, removes developer-specific RPATHs, signs nested components from the inside out and supports Apple notarization and stapling.
