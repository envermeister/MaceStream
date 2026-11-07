import Foundation

struct TransportStreamSegment: Equatable {
    let index: Int
    let data: Data
    let duration: Double
}

struct TransportStreamSegmenter {
    enum SegmenterError: Error, Equatable {
        case invalidStream
        case segmentTooLarge
    }

    private enum VideoCodec {
        case h264
        case h265
        case mpeg2
    }

    private struct StreamDescription {
        let pid: Int
        let streamType: UInt8
        let languageDescriptor: [UInt8]?
        let codec: VideoCodec?
    }

    private let packetSize = 188
    private let syncByte: UInt8 = 0x47
    private let targetDuration: Double
    private let maximumSegmentBytes: Int

    private var pending = Data()
    private var isSynchronized = false
    private var pat: Data?
    private var pmt: Data?
    private var normalizedPAT: Data?
    private var normalizedPMT: Data?
    private var pmtPID: Int?
    private var videoPID: Int?
    private var videoCodec: VideoCodec?
    private var currentSegment = Data()
    private var currentSegmentStartPTS: UInt64?
    private var nextSegmentIndex = 0

    init(targetDuration: Double = 2, maximumSegmentBytes: Int = 64 * 1024 * 1024) {
        self.targetDuration = max(0.5, targetDuration)
        self.maximumSegmentBytes = max(packetSize * 16, maximumSegmentBytes)
    }

    mutating func append(_ data: Data) throws -> [TransportStreamSegment] {
        pending.append(data)
        var completedSegments: [TransportStreamSegment] = []

        while true {
            if !isSynchronized {
                try synchronize()
                guard isSynchronized else { break }
            }
            guard pending.count >= packetSize else { break }
            guard pending.first == syncByte else {
                isSynchronized = false
                continue
            }

            let packet = Data(pending.prefix(packetSize))
            pending = Data(pending.dropFirst(packetSize))
            if let segment = try process(packet) {
                completedSegments.append(segment)
            }
        }
        return completedSegments
    }

    private mutating func synchronize() throws {
        let bytes = [UInt8](pending)
        let verificationPackets = 5

        for offset in 0..<packetSize {
            let lastSyncOffset = offset + (verificationPackets - 1) * packetSize
            guard lastSyncOffset < bytes.count else { continue }
            var matches = true
            for packetIndex in 0..<verificationPackets {
                if bytes[offset + packetIndex * packetSize] != syncByte {
                    matches = false
                    break
                }
            }
            if matches {
                pending = Data(pending.dropFirst(offset))
                isSynchronized = true
                return
            }
        }

        if bytes.count >= packetSize * (verificationPackets + 1) {
            throw SegmenterError.invalidStream
        }
    }

    private mutating func process(_ packet: Data) throws -> TransportStreamSegment? {
        let bytes = [UInt8](packet)
        guard bytes.count == packetSize else { return nil }
        let pid = Int(bytes[1] & 0x1f) << 8 | Int(bytes[2])

        if pid == 0 {
            pat = packet
            if let payload = psiPayload(in: bytes) {
                parsePAT(payload)
            }
            return nil
        }
        if pid == pmtPID {
            pmt = packet
            if let payload = psiPayload(in: bytes) {
                parsePMT(payload)
            }
            return nil
        }

        guard pid == videoPID,
              let codec = videoCodec,
              payloadUnitStart(in: bytes),
              isRandomAccess(codec: codec, packet: bytes),
              let pts = presentationTimestamp(in: bytes) else {
            try appendToCurrentSegment(packet)
            return nil
        }

        if let startPTS = currentSegmentStartPTS {
            let elapsed = timestampDifference(from: startPTS, to: pts) / 90_000
            if elapsed >= targetDuration, !currentSegment.isEmpty {
                let completed = TransportStreamSegment(
                    index: nextSegmentIndex,
                    data: currentSegment,
                    duration: elapsed
                )
                nextSegmentIndex += 1
                startSegment(with: packet, pts: pts)
                return completed
            }
        }

        if currentSegmentStartPTS == nil {
            startSegment(with: packet, pts: pts)
        } else {
            try appendToCurrentSegment(packet)
        }
        return nil
    }

    private mutating func startSegment(with packet: Data, pts: UInt64) {
        currentSegment = Data()
        currentSegment.reserveCapacity(2 * 1024 * 1024)
        if let pat = normalizedPAT ?? pat { currentSegment.append(pat) }
        if let pmt = normalizedPMT ?? pmt { currentSegment.append(pmt) }
        currentSegment.append(packet)
        currentSegmentStartPTS = pts
    }

    private mutating func appendToCurrentSegment(_ packet: Data) throws {
        guard currentSegmentStartPTS != nil else { return }
        guard currentSegment.count + packet.count <= maximumSegmentBytes else {
            throw SegmenterError.segmentTooLarge
        }
        currentSegment.append(packet)
    }

    private func payloadOffset(in packet: [UInt8]) -> Int? {
        let adaptationControl = (packet[3] >> 4) & 0x03
        guard adaptationControl == 1 || adaptationControl == 3 else { return nil }
        var offset = 4
        if adaptationControl == 3 {
            guard offset < packet.count else { return nil }
            offset += 1 + Int(packet[offset])
        }
        return offset < packet.count ? offset : nil
    }

    private func payloadUnitStart(in packet: [UInt8]) -> Bool {
        packet[1] & 0x40 != 0
    }

    private func psiPayload(in packet: [UInt8]) -> [UInt8]? {
        guard payloadUnitStart(in: packet), let offset = payloadOffset(in: packet) else { return nil }
        let pointer = Int(packet[offset])
        let tableOffset = offset + 1 + pointer
        guard tableOffset + 3 <= packet.count else { return nil }
        return Array(packet[tableOffset...])
    }

    private mutating func parsePAT(_ table: [UInt8]) {
        guard table.count >= 12, table[0] == 0 else { return }
        let sectionLength = Int(table[1] & 0x0f) << 8 | Int(table[2])
        let sectionEnd = min(table.count, 3 + sectionLength)
        guard sectionEnd >= 12 else { return }

        var offset = 8
        while offset + 4 <= sectionEnd - 4 {
            let programNumber = Int(table[offset]) << 8 | Int(table[offset + 1])
            if programNumber != 0 {
                let newPMTPID = Int(table[offset + 2] & 0x1f) << 8 | Int(table[offset + 3])
                if pmtPID != newPMTPID {
                    pmtPID = newPMTPID
                    pmt = nil
                    normalizedPAT = nil
                    normalizedPMT = nil
                    videoPID = nil
                    videoCodec = nil
                    currentSegmentStartPTS = nil
                    currentSegment = Data()
                }
                return
            }
            offset += 4
        }
    }

    private mutating func parsePMT(_ table: [UInt8]) {
        guard table.count >= 16, table[0] == 2 else { return }
        let sectionLength = Int(table[1] & 0x0f) << 8 | Int(table[2])
        let sectionEnd = min(table.count, 3 + sectionLength)
        let programInfoLength = Int(table[10] & 0x0f) << 8 | Int(table[11])
        guard sectionEnd >= 16, 12 + programInfoLength <= sectionEnd - 4 else { return }
        let programInfo = Array(table[12..<(12 + programInfoLength)])
        var requiresNormalization = containsDescriptor(0x09, in: programInfo)
        var offset = 12 + programInfoLength
        var streams: [StreamDescription] = []
        var selectedVideo: StreamDescription?

        while offset + 5 <= sectionEnd - 4 {
            let originalType = table[offset]
            let elementaryPID = Int(table[offset + 1] & 0x1f) << 8 | Int(table[offset + 2])
            let esInfoLength = Int(table[offset + 3] & 0x0f) << 8 | Int(table[offset + 4])
            let descriptorEnd = offset + 5 + esInfoLength
            guard descriptorEnd <= sectionEnd - 4 else { break }
            let descriptors = Array(table[(offset + 5)..<descriptorEnd])
            if containsDescriptor(0x09, in: descriptors) {
                requiresNormalization = true
            }

            let codec: VideoCodec?
            switch originalType {
            case 0x1b: codec = .h264
            case 0x24: codec = .h265
            case 0x02: codec = .mpeg2
            default: codec = nil
            }
            if let normalizedType = normalizedStreamType(originalType: originalType, descriptors: descriptors) {
                if normalizedType != originalType {
                    requiresNormalization = true
                }
                let stream = StreamDescription(
                    pid: elementaryPID,
                    streamType: normalizedType,
                    languageDescriptor: descriptor(0x0a, in: descriptors),
                    codec: codec
                )
                streams.append(stream)
                if codec == .h264 {
                    selectedVideo = stream
                } else if selectedVideo == nil, codec != nil {
                    selectedVideo = stream
                }
            }
            offset = descriptorEnd
        }

        normalizedPAT = nil
        normalizedPMT = nil
        if requiresNormalization, let selectedVideo, let pmtPID {
            makeNormalizedTables(streams: streams, pmtPID: pmtPID, pcrPID: selectedVideo.pid)
        }
        if videoPID != selectedVideo?.pid {
            currentSegmentStartPTS = nil
            currentSegment = Data()
        }
        videoPID = selectedVideo?.pid
        videoCodec = selectedVideo?.codec
    }

    private func normalizedStreamType(originalType: UInt8, descriptors: [UInt8]) -> UInt8? {
        switch originalType {
        case 0x02, 0x1b, 0x24:
            return originalType
        case 0x03, 0x04, 0x0f, 0x11, 0x81, 0x87:
            return originalType
        case 0x06:
            if containsDescriptor(0x7a, in: descriptors) || containsRegistration("EAC3", in: descriptors)
                || containsRegistration("E-AC-3", in: descriptors) {
                return 0x87
            }
            if containsDescriptor(0x6a, in: descriptors) || containsRegistration("AC-3", in: descriptors) {
                return 0x81
            }
            return nil
        default:
            return nil
        }
    }

    private func containsDescriptor(_ tag: UInt8, in descriptors: [UInt8]) -> Bool {
        descriptor(tag, in: descriptors) != nil
    }

    private func descriptor(_ tag: UInt8, in descriptors: [UInt8]) -> [UInt8]? {
        var offset = 0
        while offset + 2 <= descriptors.count {
            let length = Int(descriptors[offset + 1])
            let end = offset + 2 + length
            guard end <= descriptors.count else { return nil }
            if descriptors[offset] == tag {
                return Array(descriptors[offset..<end])
            }
            offset = end
        }
        return nil
    }

    private func containsRegistration(_ registration: String, in descriptors: [UInt8]) -> Bool {
        guard let descriptor = descriptor(0x05, in: descriptors), descriptor.count >= 6 else { return false }
        let value = String(decoding: descriptor[2...], as: UTF8.self)
        return value == registration
    }

    private mutating func makeNormalizedTables(streams: [StreamDescription], pmtPID: Int, pcrPID: Int) {
        let patTable: [UInt8] = [
            0x00, 0xb0, 0x00, 0x00, 0x01, 0xc1, 0x00, 0x00,
            0x00, 0x01, 0xe0 | UInt8((pmtPID >> 8) & 0x1f), UInt8(pmtPID & 0xff)
        ]
        var pmtTable: [UInt8] = [
            0x02, 0xb0, 0x00, 0x00, 0x01, 0xc1, 0x00, 0x00,
            0xe0 | UInt8((pcrPID >> 8) & 0x1f), UInt8(pcrPID & 0xff), 0xf0, 0x00
        ]
        for stream in streams {
            let descriptors = stream.languageDescriptor ?? []
            pmtTable.append(contentsOf: [
                stream.streamType,
                0xe0 | UInt8((stream.pid >> 8) & 0x1f), UInt8(stream.pid & 0xff),
                0xf0 | UInt8((descriptors.count >> 8) & 0x0f), UInt8(descriptors.count & 0xff)
            ])
            pmtTable.append(contentsOf: descriptors)
        }

        if let pat = makePSIPacket(pid: 0, table: patTable),
           let pmt = makePSIPacket(pid: pmtPID, table: pmtTable) {
            normalizedPAT = pat
            normalizedPMT = pmt
        }
    }

    private func makePSIPacket(pid: Int, table: [UInt8]) -> Data? {
        var table = table
        let sectionLength = table.count - 3 + 4
        guard sectionLength <= 0x3ff, table.count + 4 + 5 <= packetSize else { return nil }
        table[1] = table[1] & 0xf0 | UInt8((sectionLength >> 8) & 0x0f)
        table[2] = UInt8(sectionLength & 0xff)
        let crc = crc32MPEG(table)
        table.append(UInt8((crc >> 24) & 0xff))
        table.append(UInt8((crc >> 16) & 0xff))
        table.append(UInt8((crc >> 8) & 0xff))
        table.append(UInt8(crc & 0xff))

        var packet = [UInt8](repeating: 0xff, count: packetSize)
        packet[0] = syncByte
        packet[1] = 0x40 | UInt8((pid >> 8) & 0x1f)
        packet[2] = UInt8(pid & 0xff)
        packet[3] = 0x10
        packet[4] = 0
        packet.replaceSubrange(5..<(5 + table.count), with: table)
        return Data(packet)
    }

    private func crc32MPEG(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                if crc & 0x80000000 != 0 {
                    crc = (crc << 1) ^ 0x04c11db7
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    private func pesPayloadOffset(in packet: [UInt8]) -> Int? {
        guard let offset = payloadOffset(in: packet), offset + 9 <= packet.count,
              packet[offset] == 0, packet[offset + 1] == 0, packet[offset + 2] == 1 else {
            return nil
        }
        let payloadOffset = offset + 9 + Int(packet[offset + 8])
        return payloadOffset <= packet.count ? payloadOffset : nil
    }

    private func presentationTimestamp(in packet: [UInt8]) -> UInt64? {
        guard let offset = payloadOffset(in: packet), offset + 14 <= packet.count,
              packet[offset] == 0, packet[offset + 1] == 0, packet[offset + 2] == 1,
              packet[offset + 7] & 0x80 != 0 else {
            return nil
        }
        let bytes = packet
        let index = offset + 9
        return UInt64(bytes[index] >> 1 & 0x07) << 30
            | UInt64(bytes[index + 1]) << 22
            | UInt64(bytes[index + 2] >> 1) << 15
            | UInt64(bytes[index + 3]) << 7
            | UInt64(bytes[index + 4] >> 1)
    }

    private func isRandomAccess(codec: VideoCodec, packet: [UInt8]) -> Bool {
        guard let payloadOffset = pesPayloadOffset(in: packet), payloadOffset < packet.count else {
            return false
        }
        let payload = packet
        var index = payloadOffset
        var foundVPS = false
        var foundSPS = false
        var foundPPS = false

        while index + 4 < payload.count {
            guard payload[index] == 0, payload[index + 1] == 0 else {
                index += 1
                continue
            }
            let startCodeLength: Int
            if payload[index + 2] == 1 {
                startCodeLength = 3
            } else if index + 3 < payload.count, payload[index + 2] == 0, payload[index + 3] == 1 {
                startCodeLength = 4
            } else {
                index += 1
                continue
            }

            let nalOffset = index + startCodeLength
            guard nalOffset < payload.count else { return false }
            switch codec {
            case .h264:
                let nalType = payload[nalOffset] & 0x1f
                if nalType == 5 { return true }
                if nalType == 7 { foundSPS = true }
                if nalType == 8 { foundPPS = true }
            case .h265:
                let nalType = (payload[nalOffset] >> 1) & 0x3f
                if (16...21).contains(nalType) { return true }
                if nalType == 32 { foundVPS = true }
                if nalType == 33 { foundSPS = true }
                if nalType == 34 { foundPPS = true }
            case .mpeg2:
                if startCodeLength == 3, payload[nalOffset] == 0,
                   nalOffset + 2 < payload.count, payload[nalOffset + 2] >> 3 & 0x07 == 1 {
                    return true
                }
            }
            index = nalOffset + 1
        }
        switch codec {
        case .h264:
            return foundSPS && foundPPS
        case .h265:
            return foundVPS && foundSPS && foundPPS
        case .mpeg2:
            return false
        }
    }

    private func timestampDifference(from start: UInt64, to end: UInt64) -> Double {
        let modulus: UInt64 = 1 << 33
        if end >= start {
            return Double(end - start)
        }
        if start - end > modulus / 2 {
            return Double(end + modulus - start)
        }
        return 0
    }
}
