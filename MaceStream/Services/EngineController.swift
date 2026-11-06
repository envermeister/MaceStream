import AppKit
import Darwin
import Foundation

@MainActor
final class EngineController: ObservableObject {
    @Published private(set) var status = EngineStatus()

    private let paths: SupportPaths
    private let client: AceStreamClient
    private var process: Process?
    private var relay: TCPRelay?
    private var vsockSocketURL: URL?
    private var healthTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleID = UUID()
    private var logHandle: FileHandle?
    private var operation: UInt = 0

    init(paths: SupportPaths = .production, client: AceStreamClient = AceStreamClient()) {
        self.paths = paths
        self.client = client
    }

    var endpoint: EngineEndpoint? { status.endpoint }

    func start() async {
        await enqueue { await self.performStart() }
    }

    private func performStart() async {
        operation &+= 1
        let ticket = operation
        await releaseResources()
        guard ticket == operation else { return }

        status = EngineStatus(
            phase: .starting,
            message: "Starting AceStream engine",
            detail: "Preparing isolated Linux environment…"
        )

        do {
            try paths.createDirectories()
            let resources = try engineResources()
            let socketURL = try prepareVsockSocket()
            try launchEngine(resources: resources, ticket: ticket, socketURL: socketURL)
            let (relay, port) = try await TCPRelay.start(upstreamSocketPath: socketURL.path)
            guard ticket == operation else {
                relay.stop()
                return
            }
            self.relay = relay
            let endpoint = EngineEndpoint(host: "127.0.0.1", port: port)
            status.endpoint = endpoint
            status.detail = "Local bridge: 127.0.0.1:\(port)"
            healthTask = Task { [weak self] in
                await self?.monitorHealth(ticket: ticket, endpoint: endpoint)
            }
        } catch {
            guard ticket == operation else { return }
            await releaseResources()
            status = EngineStatus(
                phase: .failed,
                message: "Engine failed to start",
                detail: error.localizedDescription,
                endpoint: status.endpoint
            )
        }
    }

    func restart() async {
        await start()
    }

    func stop() async {
        await enqueue { await self.performStop() }
    }

    private func performStop() async {
        operation &+= 1
        await releaseResources()
        status = EngineStatus()
    }

    func clearCacheAndRestart() async {
        await enqueue {
            await self.performStop()
            do {
                if FileManager.default.fileExists(atPath: self.paths.cacheDirectory.path) {
                    try FileManager.default.removeItem(at: self.paths.cacheDirectory)
                }
                try self.paths.createDirectories()
            } catch {
                self.status = EngineStatus(
                    phase: .failed,
                    message: "Could not clear engine cache",
                    detail: error.localizedDescription
                )
                return
            }
            await self.performStart()
        }
    }

    func waitUntilReady() async -> Bool {
        if status.isReady { return true }
        if status.phase != .starting {
            await start()
        }
        let ticket = operation
        for _ in 0..<750 {
            if status.isReady { return true }
            if status.phase == .failed || status.phase == .stopped || ticket != operation {
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func revealLogs() {
        try? paths.createDirectories()
        NSWorkspace.shared.activateFileViewerSelecting([paths.engineLogURL])
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let previous = lifecycleTask
        let id = UUID()
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        lifecycleID = id
        lifecycleTask = task
        await task.value
        if lifecycleID == id { lifecycleTask = nil }
    }

    private func launchEngine(resources: EngineResources, ticket: UInt, socketURL: URL) throws {
        let process = Process()
        process.executableURL = resources.vfkit
        process.currentDirectoryURL = paths.cacheDirectory

        var arguments = [
            "--cpus", "2",
            "--memory", "512",
            "--bootloader",
            "linux,kernel=\(resources.kernel.path),initrd=\(resources.initramfs.path),cmdline=console=hvc0 quiet",
            "--device", "virtio-net,nat,mac=52:54:00:4D:43:53",
            "--device", "virtio-serial,logFilePath=\(paths.serialLogURL.path)",
            "--device", "virtio-rng",
            "--device", "virtio-vsock,port=6878,socketURL=\(socketURL.path),connect",
            "--device", "virtio-fs,sharedDir=\(resources.runtime.path),mountTag=mace-runtime"
        ]
        if Self.isAppleSilicon {
            arguments.append(contentsOf: [
                "--device", "rosetta,mountTag=mace-rosetta,install"
            ])
        }
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MACESTREAM_CACHE_DIR": paths.cacheDirectory.path
        ]) { _, new in new }

        if FileManager.default.fileExists(atPath: paths.engineLogURL.path) {
            try FileManager.default.removeItem(at: paths.engineLogURL)
        }
        guard FileManager.default.createFile(atPath: paths.engineLogURL.path, contents: nil) else {
            throw EngineControllerError.logUnavailable
        }
        let logHandle = try FileHandle(forWritingTo: paths.engineLogURL)
        self.logHandle = logHandle
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.processDidExit(terminatedProcess, ticket: ticket)
            }
        }

        guard FileManager.default.isExecutableFile(atPath: resources.vfkit.path) else {
            throw EngineControllerError.missingResources(
                "vfkit is not executable. The packaging script must validate engine file permissions."
            )
        }
        try process.run()
        self.process = process
    }

    private func monitorHealth(ticket: UInt, endpoint: EngineEndpoint) async {
        let startedAt = ContinuousClock.now
        var consecutiveFailures = 0

        while !Task.isCancelled && ticket == operation {
            do {
                let version = try await client.getVersion(endpoint: endpoint)
                guard ticket == operation else { return }
                consecutiveFailures = 0
                status = EngineStatus(
                    phase: .ready,
                    message: "Engine ready",
                    detail: "127.0.0.1:\(endpoint.port)",
                    version: version,
                    endpoint: endpoint
                )
            } catch {
                guard !Task.isCancelled, ticket == operation else { return }
                consecutiveFailures += 1
                let wasReady = status.phase == .ready
                let elapsed = ContinuousClock.now - startedAt
                if !wasReady && elapsed >= .seconds(60) {
                    await failEngine(
                        message: "Engine is not responding",
                        detail: "The API was not ready within 60 seconds. \(error.localizedDescription)",
                        ticket: ticket
                    )
                    return
                }
                if wasReady && consecutiveFailures >= 3 {
                    await failEngine(
                        message: "Engine disconnected",
                        detail: error.localizedDescription,
                        ticket: ticket,
                        version: status.version
                    )
                    return
                }
                if !wasReady {
                    status.phase = .starting
                    status.message = "Starting AceStream engine"
                }
            }

            let delay: UInt64 = status.isReady ? 5_000_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delay)
        }
    }

    private func failEngine(
        message: String,
        detail: String,
        ticket: UInt,
        version: String? = nil
    ) async {
        await enqueue {
            guard ticket == self.operation else { return }
            let endpoint = self.status.endpoint
            await self.releaseResources(cancelHealthTask: false)
            guard ticket == self.operation else { return }
            self.status = EngineStatus(
                phase: .failed,
                message: message,
                detail: detail,
                version: version,
                endpoint: endpoint
            )
        }
    }

    private func processDidExit(_ terminatedProcess: Process, ticket: UInt) {
        guard ticket == operation else { return }
        healthTask?.cancel()
        healthTask = nil
        relay?.stop()
        relay = nil
        if let vsockSocketURL {
            try? FileManager.default.removeItem(at: vsockSocketURL)
            self.vsockSocketURL = nil
        }
        process = nil
        try? logHandle?.close()
        logHandle = nil
        status = EngineStatus(
            phase: .failed,
            message: "Engine process exited",
            detail: "vfkit exit code: \(terminatedProcess.terminationStatus). Open logs in Settings › Engine.",
            endpoint: status.endpoint
        )
    }

    private func releaseResources(cancelHealthTask: Bool = true) async {
        if cancelHealthTask { healthTask?.cancel() }
        healthTask = nil
        relay?.stop()
        relay = nil

        let processToStop = process
        process = nil
        processToStop?.terminationHandler = nil
        if let processToStop, processToStop.isRunning {
            processToStop.terminate()
            if await waitForExit(processToStop, attempts: 60) == false {
                Darwin.kill(processToStop.processIdentifier, SIGKILL)
                _ = await waitForExit(processToStop, attempts: 20)
            }
        }
        try? logHandle?.close()
        logHandle = nil
        if let vsockSocketURL {
            try? FileManager.default.removeItem(at: vsockSocketURL)
            self.vsockSocketURL = nil
        }
    }

    private func prepareVsockSocket() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "macestream-\(getuid())-\(ProcessInfo.processInfo.processIdentifier).sock"
        )
        guard url.path.utf8.count < 100 else {
            throw EngineControllerError.socketPathTooLong
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        vsockSocketURL = url
        return url
    }

    private func waitForExit(_ process: Process, attempts: Int) async -> Bool {
        for _ in 0..<max(1, attempts) {
            if !process.isRunning { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !process.isRunning
    }

    private func engineResources() throws -> EngineResources {
        guard let engineRoot = Bundle.main.resourceURL?.appendingPathComponent("Engine", isDirectory: true) else {
            throw EngineControllerError.missingResources("App resource directory not found.")
        }
        let resources = EngineResources(
            root: engineRoot.appendingPathComponent(Self.guestArchitecture, isDirectory: true),
            vfkit: engineRoot.appendingPathComponent("vfkit")
        )
        let requiredFiles = [
            resources.vfkit,
            resources.kernel,
            resources.initramfs,
            resources.engine,
            resources.python
        ]
        for file in requiredFiles where !FileManager.default.fileExists(atPath: file.path) {
            throw EngineControllerError.missingResources(
                "Missing engine file: \(file.lastPathComponent). For development, run scripts/build_macos_engine_image.sh."
            )
        }
        return resources
    }

#if DEBUG
    func presentForCapture() {
        let endpoint = EngineEndpoint(host: "127.0.0.1", port: 52542)
        status = EngineStatus(
            phase: .ready,
            message: "Engine ready",
            detail: "127.0.0.1:52542",
            version: "3.2.11",
            endpoint: endpoint
        )
    }
#endif

    private static var guestArchitecture: String {
        isAppleSilicon ? "arm64" : "x86_64"
    }

    private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }
}

private struct EngineResources {
    let root: URL
    let vfkit: URL
    var kernel: URL { root.appendingPathComponent("vmlinuz") }
    var initramfs: URL { root.appendingPathComponent("initramfs.cpio.gz") }
    var runtime: URL { root.appendingPathComponent("runtime", isDirectory: true) }
    var engine: URL { runtime.appendingPathComponent("opt/acestream/acestreamengine") }
    var python: URL { runtime.appendingPathComponent("usr/bin/python3.10") }
}

private enum EngineControllerError: LocalizedError {
    case missingResources(String)
    case logUnavailable
    case socketPathTooLong

    var errorDescription: String? {
        switch self {
        case .missingResources(let message): return message
        case .logUnavailable: return "Could not create the engine log file."
        case .socketPathTooLong: return "The temporary vsock socket path is too long."
        }
    }
}
