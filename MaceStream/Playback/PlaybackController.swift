import AVFoundation
import CoreMedia
import Foundation

@MainActor
final class PlaybackController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case buffering
        case playing
        case paused
        case failed
    }

    struct MediaTrack: Identifiable {
        let id = UUID()
        let title: String
        let language: String?
        let option: AVMediaSelectionOption
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var currentLink: AceStreamLink?
    @Published private(set) var displayTitle: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var statistics = PlaybackStats.empty
    @Published private(set) var bufferedSeconds: Double = 0
    @Published private(set) var observedBitrate: Double = 0
    @Published private(set) var indicatedBitrate: Double = 0
    @Published private(set) var mediaStallCount: Int = 0
    @Published private(set) var videoDescription: String?
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var selectedAudioTrackID: UUID?
    @Published private(set) var selectedSubtitleTrackID: UUID?
    @Published private(set) var volume: Double
    @Published private(set) var isMuted: Bool
    #if DEBUG
    @Published private(set) var isShowingCapturePreview = false
    #endif

    let player = AVPlayer()

    private let engine: EngineController
    private let settings: SettingsStore
    private let history: HistoryStore
    private let client: AceStreamClient

    private var session: StreamSession?
    private var localStream: LocalHLSStream?
    private var playbackTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var statisticsTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var stablePlaybackTask: Task<Void, Never>?
    private var operation: UInt = 0
    private var retryCount = 0

    private var playerObservations: [NSKeyValueObservation] = []
    private var itemObservations: [NSKeyValueObservation] = []
    private var itemNotifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?

    init(
        engine: EngineController,
        settings: SettingsStore,
        history: HistoryStore,
        client: AceStreamClient = AceStreamClient()
    ) {
        self.engine = engine
        self.settings = settings
        self.history = history
        self.client = client
        volume = settings.value.volume
        isMuted = settings.value.isMuted
        player.volume = Float(volume)
        player.isMuted = isMuted
        player.actionAtItemEnd = .pause
        applySettings()
        observePlayer()
    }

    var hasActiveStream: Bool { currentLink != nil }
    var isBusy: Bool { phase == .connecting || phase == .buffering }
    var canTogglePlayPause: Bool {
        currentLink != nil && phase != .failed && phase != .connecting &&
            player.currentItem?.status == .readyToPlay
    }

    var formattedObservedBitrate: String {
        Self.formatBitrate(observedBitrate)
    }

    var formattedIndicatedBitrate: String {
        Self.formatBitrate(indicatedBitrate)
    }

    var bufferDescription: String {
        guard bufferedSeconds.isFinite, bufferedSeconds > 0 else { return "—" }
        return String(format: "%.1f s", bufferedSeconds)
    }

    func play(_ link: AceStreamLink, title: String? = nil) {
        retryCount = 0
        beginPlaying(link, title: title)
    }

    func retry() {
        guard let currentLink else { return }
        retryCount = 0
        beginPlaying(currentLink, title: displayTitle)
    }

    func stop() {
        let previousSession = invalidatePlayback()
        currentLink = nil
        displayTitle = nil
        phase = .idle
        errorMessage = nil
        notice = nil
        if let previousSession {
            Task { await client.stopStream(previousSession) }
        }
    }

    func shutdown() async {
        let previousSession = invalidatePlayback()
        phase = .idle
        if let previousSession {
            await client.stopStream(previousSession)
        }
    }

    func togglePlayPause() {
        guard canTogglePlayPause else { return }
        switch player.timeControlStatus {
        case .playing:
            player.pause()
            phase = .paused
        case .paused:
            player.play()
            if player.currentItem?.isPlaybackLikelyToKeepUp == true {
                phase = .playing
            } else {
                phase = .buffering
                scheduleWatchdog(ticket: operation)
            }
        case .waitingToPlayAtSpecifiedRate:
            player.pause()
            phase = .paused
        @unknown default:
            break
        }
    }

    func setVolume(_ value: Double, persist: Bool = false) {
        volume = value.clamped(to: 0...1)
        player.volume = Float(volume)
        if volume > 0, isMuted {
            isMuted = false
            player.isMuted = false
        }
        if persist {
            settings.update { settings in
                settings.volume = volume
                settings.isMuted = isMuted
            }
        }
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
        settings.update { $0.isMuted = isMuted }
    }

    func applySettings() {
        player.automaticallyWaitsToMinimizeStalling = settings.value.automaticallyWaitsToMinimizeStalling
        player.currentItem?.preferredForwardBufferDuration = settings.value.playerBufferSeconds
        player.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = settings.value.keepsLiveStreamActiveWhilePaused
    }

    func selectAudioTrack(_ track: MediaTrack) {
        guard let audioGroup else { return }
        player.currentItem?.select(track.option, in: audioGroup)
        selectedAudioTrackID = track.id
    }

    func selectSubtitleTrack(_ track: MediaTrack?) {
        guard let subtitleGroup else { return }
        player.currentItem?.select(track?.option, in: subtitleGroup)
        selectedSubtitleTrackID = track?.id
    }

    private func beginPlaying(_ link: AceStreamLink, title: String?) {
        let previousSession = invalidatePlayback()
        let ticket = operation
        currentLink = link
        displayTitle = title?.isEmpty == false ? title : "AceStream \(link.shortID)"
        errorMessage = nil
        notice = nil
        phase = .connecting

        playbackTask = Task { [weak self] in
            guard let self else { return }
            if let previousSession {
                await self.client.stopStream(previousSession)
            }
            guard self.isCurrent(ticket) else { return }
            await self.startStream(link, ticket: ticket)
        }
    }

    private func startStream(_ link: AceStreamLink, ticket: UInt) async {
        guard await engine.waitUntilReady(), isCurrent(ticket) else {
            guard isCurrent(ticket) else { return }
            fail(
                engine.status.detail ?? "The AceStream engine is not ready. Restart it in Settings › Engine.",
                ticket: ticket
            )
            return
        }
        guard let endpoint = engine.endpoint else {
            fail("Local engine endpoint not found.", ticket: ticket)
            return
        }

        do {
            let newSession = try await client.startStream(contentID: link.contentID, endpoint: endpoint)
            guard isCurrent(ticket) else {
                await client.stopStream(newSession)
                return
            }
            session = newSession
            history.record(link)
            phase = .buffering
            startStatistics(ticket: ticket)
            scheduleWatchdog(ticket: ticket, timeout: 90)

            let stream = LocalHLSStream()
            localStream = stream
            stream.onFailure = { [weak self, weak stream] error in
                Task { @MainActor [weak self, weak stream] in
                    guard let self, let stream,
                          self.localStream === stream,
                          self.isCurrent(ticket) else { return }
                    self.fail(error.localizedDescription, ticket: ticket)
                }
            }
            let playlistURL = try await stream.start(rawURL: newSession.playbackURL)
            guard isCurrent(ticket) else {
                stream.stop()
                await client.stopStream(newSession)
                return
            }

            let item = AVPlayerItem(url: playlistURL)
            configure(item)
            observe(item, ticket: ticket)
            player.replaceCurrentItem(with: item)
            phase = .buffering
            player.play()
            scheduleWatchdog(ticket: ticket)
        } catch {
            guard isCurrent(ticket) else { return }
            if error is CancellationError || Task.isCancelled { return }
            fail(error.localizedDescription, ticket: ticket)
        }
    }

    private func invalidatePlayback() -> StreamSession? {
        operation &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        retryTask?.cancel()
        retryTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        stablePlaybackTask?.cancel()
        stablePlaybackTask = nil
        localStream?.stop()
        localStream = nil
        detachItem()
        player.pause()
        player.replaceCurrentItem(with: nil)
        let previousSession = session
        session = nil
        statistics = .empty
        bufferedSeconds = 0
        observedBitrate = 0
        indicatedBitrate = 0
        mediaStallCount = 0
        videoDescription = nil
        #if DEBUG
        isShowingCapturePreview = false
        #endif
        clearMediaTracks()
        return previousSession
    }

    private func observePlayer() {
        playerObservations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.updatePlaybackState()
            }
        })
        playerObservations.append(player.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.player.status == .failed,
                      self.player.currentItem?.status == .failed else { return }
                self.fail(
                    self.player.error?.localizedDescription ?? "AVPlayer stopped due to an unknown error.",
                    ticket: self.operation
                )
            }
        })
    }

    private func observe(_ item: AVPlayerItem, ticket: UInt) {
        itemObservations.append(item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.isCurrent(item, ticket: ticket) else { return }
                switch item.status {
                case .readyToPlay:
                    self.updateVideoDescription(item)
                    self.loadMediaTracks(item)
                    self.updatePlaybackState()
                case .failed:
                    self.fail(
                        item.error?.localizedDescription ?? "AVFoundation could not open the stream.",
                        ticket: ticket
                    )
                default:
                    break
                }
            }
        })
        itemObservations.append(item.observe(\.loadedTimeRanges, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.isCurrent(item, ticket: ticket) else { return }
                self.updateBufferedDuration()
            }
        })
        itemObservations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item,
                      self.isCurrent(item, ticket: ticket),
                      item.isPlaybackBufferEmpty else { return }
                self.phase = .buffering
                self.scheduleWatchdog(ticket: ticket)
            }
        })
        itemObservations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.isCurrent(item, ticket: ticket) else { return }
                self.updatePlaybackState()
            }
        })

        let center = NotificationCenter.default
        itemNotifications.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.isCurrent(item, ticket: ticket) else { return }
                self.phase = .buffering
                self.scheduleWatchdog(ticket: ticket)
            }
        })
        itemNotifications.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] notification in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.isCurrent(item, ticket: ticket) else { return }
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                self.fail(error?.localizedDescription ?? "The stream ended unexpectedly.", ticket: ticket)
            }
        })

        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.isCurrent(item, ticket: ticket) else { return }
                self.updateBufferedDuration()
                self.updateAccessLog()
            }
        }
    }

    private func updatePlaybackState() {
        guard currentLink != nil, player.currentItem != nil, phase != .failed else { return }
        switch player.timeControlStatus {
        case .playing:
            phase = .playing
            notice = nil
            watchdogTask?.cancel()
            watchdogTask = nil
            scheduleStablePlaybackReset(ticket: operation)
        case .waitingToPlayAtSpecifiedRate:
            stablePlaybackTask?.cancel()
            stablePlaybackTask = nil
            phase = .buffering
            scheduleWatchdog(ticket: operation)
        case .paused:
            stablePlaybackTask?.cancel()
            stablePlaybackTask = nil
            if phase == .playing { phase = .paused }
        @unknown default:
            break
        }
    }

    private func scheduleStablePlaybackReset(ticket: UInt) {
        guard stablePlaybackTask == nil else { return }
        stablePlaybackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self else { return }
            self.stablePlaybackTask = nil
            guard !Task.isCancelled, self.isCurrent(ticket), self.phase == .playing else { return }
            self.retryCount = 0
        }
    }

    private func updateBufferedDuration() {
        guard let item = player.currentItem else {
            bufferedSeconds = 0
            return
        }
        let current = item.currentTime()
        let currentSeconds = CMTimeGetSeconds(current)
        guard currentSeconds.isFinite else { return }

        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            guard start.isFinite, end.isFinite else { continue }
            if currentSeconds >= start - 0.5 && currentSeconds <= end {
                bufferedSeconds = max(0, end - currentSeconds)
                return
            }
        }
        bufferedSeconds = 0
    }

    private func updateAccessLog() {
        guard let event = player.currentItem?.accessLog()?.events.last else { return }
        observedBitrate = max(0, event.observedBitrate)
        indicatedBitrate = max(0, event.indicatedBitrate)
        mediaStallCount = max(0, event.numberOfStalls)
    }

    private func startStatistics(ticket: UInt) {
        statisticsTask?.cancel()
        statisticsTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isCurrent(ticket) else { return }
                if let statisticsURL = self.session?.statisticsURL {
                    if let newStatistics = try? await self.client.fetchStatistics(url: statisticsURL),
                       self.isCurrent(ticket) {
                        self.statistics = newStatistics
                    }
                }
                self.updateAccessLog()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func scheduleWatchdog(ticket: UInt, timeout: UInt64 = 30) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            guard !Task.isCancelled, let self, self.isCurrent(ticket) else { return }
            guard self.phase == .connecting || self.phase == .buffering else { return }
            self.fail("The stream did not provide enough data within \(timeout) seconds.", ticket: ticket)
        }
    }

    private func fail(_ message: String, ticket: UInt) {
        guard isCurrent(ticket), currentLink != nil, phase != .failed, retryTask == nil else { return }
        if retryCount < 2 {
            retryCount += 1
            let attempt = retryCount
            notice = "Connection lost. Retrying (\(attempt)/2)…"
            let link = currentLink
            let title = displayTitle
            quiescePlayerForFailure()
            phase = .buffering
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                guard !Task.isCancelled, let self, let link, self.isCurrent(ticket) else { return }
                self.retryTask = nil
                self.beginPlaying(link, title: title)
            }
            return
        }

        quiescePlayerForFailure()
        phase = .failed
        errorMessage = message
        notice = nil
    }

    private func quiescePlayerForFailure() {
        watchdogTask?.cancel()
        watchdogTask = nil
        statisticsTask?.cancel()
        statisticsTask = nil
        stablePlaybackTask?.cancel()
        stablePlaybackTask = nil
        localStream?.stop()
        localStream = nil
        detachItem()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func loadMediaTracks(_ item: AVPlayerItem) async {
        let asset = item.asset
        let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard player.currentItem === item else { return }

        audioGroup = audible
        subtitleGroup = legible
        audioTracks = audible?.options.map { Self.mediaTrack($0) } ?? []
        subtitleTracks = legible?.options.map { Self.mediaTrack($0) } ?? []

        if let audible,
           let selected = item.currentMediaSelection.selectedMediaOption(in: audible) {
            selectedAudioTrackID = audioTracks.first { $0.option == selected }?.id
        }
        if let legible,
           let selected = item.currentMediaSelection.selectedMediaOption(in: legible) {
            selectedSubtitleTrackID = subtitleTracks.first { $0.option == selected }?.id
        } else {
            selectedSubtitleTrackID = nil
        }
    }

    private func loadMediaTracks(_ item: AVPlayerItem) {
        Task { [weak self, weak item] in
            guard let item else { return }
            await self?.loadMediaTracks(item)
        }
    }

    private func updateVideoDescription(_ item: AVPlayerItem) {
        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            var parts: [String] = []
            let size = item.presentationSize
            if size.width > 0, size.height > 0 {
                parts.append("\(Int(size.width)) × \(Int(size.height))")
            }
            if let videoTrack = item.tracks.first(where: { $0.assetTrack?.mediaType == .video })?.assetTrack {
                let frameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
                if frameRate > 0 {
                    parts.append(String(format: "%g fps", frameRate))
                }
                let descriptions = (try? await videoTrack.load(.formatDescriptions)) ?? []
                if let description = descriptions.first {
                    let codec = CMFormatDescriptionGetMediaSubType(description)
                    if let name = Self.fourCC(codec) { parts.insert(name, at: 0) }
                }
            }
            guard self.player.currentItem === item else { return }
            self.videoDescription = parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private static func mediaTrack(_ option: AVMediaSelectionOption) -> MediaTrack {
        MediaTrack(
            title: option.displayName,
            language: option.locale?.identifier,
            option: option
        )
    }

    private func configure(_ item: AVPlayerItem) {
        detachItem()
        item.preferredForwardBufferDuration = settings.value.playerBufferSeconds
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = settings.value.keepsLiveStreamActiveWhilePaused
    }

    private func detachItem() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        itemObservations.forEach { $0.invalidate() }
        itemObservations.removeAll()
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications.removeAll()
    }

    private func clearMediaTracks() {
        audioGroup = nil
        subtitleGroup = nil
        audioTracks = []
        subtitleTracks = []
        selectedAudioTrackID = nil
        selectedSubtitleTrackID = nil
    }

    private func isCurrent(_ ticket: UInt) -> Bool {
        ticket == operation
    }

    private func isCurrent(_ item: AVPlayerItem, ticket: UInt) -> Bool {
        isCurrent(ticket) && player.currentItem === item
    }

#if DEBUG
    func presentForCapture() {
        currentLink = AceStreamLink(rawValue: "0123456789abcdef0123456789abcdef01234567")
        displayTitle = "Sports Replay · Sample"
        statistics = PlaybackStats(
            status: "dl",
            progress: 100,
            downloadSpeed: 1840,
            uploadSpeed: 96,
            peers: 18,
            downloadedBytes: 84_000_000,
            uploadedBytes: 2_400_000
        )
        bufferedSeconds = 8.4
        observedBitrate = 6_400_000
        indicatedBitrate = 8_000_000
        mediaStallCount = 0
        videoDescription = "1920 × 1080 · H264 · 50 fps"
        errorMessage = nil
        notice = nil
        isShowingCapturePreview = true
        phase = .playing
    }

    func prepareForRetryTesting() {
        currentLink = AceStreamLink(rawValue: "0123456789abcdef0123456789abcdef01234567")
        displayTitle = "Retry test"
        phase = .playing
        retryCount = 0
        errorMessage = nil
        notice = nil
    }

    func simulateFailureForTesting() {
        fail("Test failure", ticket: operation)
    }

    var hasPendingRetryForTesting: Bool { retryTask != nil }
    var retryCountForTesting: Int { retryCount }
#endif

    private static func fourCC(_ value: FourCharCode) -> String? {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
    }

    private static func formatBitrate(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond > 0 else { return "—" }
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.2f Mb/s", bitsPerSecond / 1_000_000)
        }
        return String(format: "%.0f Kb/s", bitsPerSecond / 1_000)
    }
}
