import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import Network
import Combine
import SwiftUI

// MARK: - AeroCast Engine
//
// Receives the device's screen and audio over `adb forward tcp:8081`, decodes
// H.264 through VideoToolbox into an AVSampleBufferDisplayLayer, and plays the
// captured PCM through AVAudioEngine.
//
// Two source modes are supported:
//   • .companion — the DroidHouse companion app streams screen *and* audio via
//     MediaProjection. This is the full-fat path.
//   • .screenRecord — a pure-adb fallback using `screenrecord --output-format=h264`.
//     Video only (Android exposes no audio over adb), but it needs nothing
//     installed on the device.

@MainActor
final class AeroCastEngine: NSObject, ObservableObject {

    enum Source: String, CaseIterable, Identifiable {
        case companion = "Companion"
        case screenRecord = "ADB Direct"

        var id: String { rawValue }

        var detail: String {
            switch self {
            case .companion:
                return "Screen + audio via the DroidHouse companion"
            case .screenRecord:
                return "Screen only, no companion app required"
            }
        }

        var systemImage: String {
            switch self {
            case .companion: return "app.connected.to.app.below.fill"
            case .screenRecord: return "cable.connector"
            }
        }
    }

    enum State: Equatable {
        case idle
        case preparing(String)
        case streaming
        case failed(String)

        var isBusy: Bool {
            if case .preparing = self { return true }
            return false
        }

        var isLive: Bool { self == .streaming }
    }

    // MARK: Published state

    @Published private(set) var state: State = .idle
    @Published private(set) var streamInfo: AeroCastProtocol.StreamInfo?
    @Published private(set) var framesDecoded: Int = 0
    @Published private(set) var videoBitrate: Double = 0      // bits/sec, smoothed
    @Published private(set) var audioBitrate: Double = 0
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var isAudioActive: Bool = false
    @Published private(set) var latencyMs: Double = 0

    @Published var source: Source = .companion
    @Published var isAudioEnabled: Bool = true {
        didSet { applyAudioEnabled() }
    }
    @Published var volume: Float = 1.0 {
        didSet { playerNode.volume = volume }
    }

    /// The layer the SwiftUI view renders. Owned here so it survives view
    /// rebuilds and keeps its enqueued frames.
    let displayLayer = AVSampleBufferDisplayLayer()

    // MARK: Private state

    private var connection: NWConnection?
    private var parser = AeroCastStreamParser()
    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?

    private var recordProcess: Process?
    private var recordReadSource: DispatchSourceRead?

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    private var audioEngineRunning = false

    private var adbPath: String = ADBLocator.resolve()
    private var deviceSerial: String?

    private var firstFrameWatchdog: Task<Void, Never>?
    private var statsTimer: Timer?
    private var videoBytesWindow: Int = 0
    private var audioBytesWindow: Int = 0
    private var framesWindow: Int = 0
    private var firstPacketPTS: Int64?
    private var firstPacketWallClock: CFTimeInterval?

    // MARK: Lifecycle

    override init() {
        super.init()
        configureDisplayLayer()
        configureAudioGraph()
    }

    private func configureDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        // Let the layer present frames the instant they arrive rather than
        // pacing them against a host clock — this is a live mirror, not
        // playback, so latency matters more than perfectly even cadence.
        let controlTimebase = makeImmediateTimebase()
        displayLayer.controlTimebase = controlTimebase
    }

    private func makeImmediateTimebase() -> CMTimebase? {
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        guard status == noErr, let timebase else { return nil }
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 1.0)
        return timebase
    }

    private func configureAudioGraph() {
        audioEngine.attach(playerNode)
        // 44.1 kHz stereo float — the standard node format. Incoming Int16 PCM
        // is converted into this before scheduling.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        audioFormat = format
        if let format {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        }
        playerNode.volume = volume
    }

    // MARK: - Public control

    func start(serial: String) {
        guard !state.isLive, !state.isBusy else { return }
        deviceSerial = serial
        framesDecoded = 0
        parser.reset()
        formatDescription = nil
        spsData = nil
        ppsData = nil
        firstPacketPTS = nil
        firstPacketWallClock = nil
        displayLayer.flush()

        beginStatsTimer()

        switch source {
        case .companion:
            Task { await startCompanionStream(serial: serial) }
        case .screenRecord:
            Task { await startScreenRecordStream(serial: serial) }
        }
    }

    func stop() {
        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = nil
        statsTimer?.invalidate()
        statsTimer = nil

        connection?.cancel()
        connection = nil

        recordReadSource?.cancel()
        recordReadSource = nil
        if let recordProcess, recordProcess.isRunning {
            recordProcess.terminate()
        }
        recordProcess = nil

        stopAudio()

        if let serial = deviceSerial, source == .companion {
            Task { await requestCompanionStop(serial: serial) }
        }

        displayLayer.flushAndRemoveImage()
        state = .idle
        streamInfo = nil
        isAudioActive = false
        videoBitrate = 0
        audioBitrate = 0
        measuredFPS = 0
        latencyMs = 0
    }

    func toggle(serial: String) {
        if state.isLive || state.isBusy {
            stop()
        } else {
            start(serial: serial)
        }
    }

    // MARK: - Companion path

    private func startCompanionStream(serial: String) async {
        state = .preparing("Forwarding port \(AeroCastProtocol.port)…")

        let forwarded = await runADB(
            ["-s", serial, "forward", "tcp:\(AeroCastProtocol.port)", "tcp:\(AeroCastProtocol.port)"]
        )
        guard forwarded != nil else {
            state = .failed("Could not forward port \(AeroCastProtocol.port) over adb.")
            return
        }

        state = .preparing("Asking the companion to start casting…")

        // Kick the companion into projection mode. It will surface the system
        // MediaProjection consent dialog on the phone the first time.
        do {
            try await requestCompanionStart()
        } catch {
            state = .failed("Companion did not accept the cast request: \(error.localizedDescription)")
            return
        }

        state = .preparing("Waiting for the first frame…")
        openSocket()
        startFirstFrameWatchdog()
    }

    /// Fails loudly if no frame ever arrives.
    ///
    /// Without this the pane sits on "Waiting for the first frame…" forever
    /// whenever the phone side silently fails — which tells the user nothing
    /// and looks like a hang rather than a problem they can act on.
    private func startFirstFrameWatchdog() {
        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            guard !Task.isCancelled, let self else { return }
            guard !self.state.isLive else { return }

            let streaming = await CompanionSync.shared.aeroCastStatus()
            guard !self.state.isLive else { return }

            let reason = streaming
                ? "The phone says it is casting but no video arrived on port \(AeroCastProtocol.port). Check that `adb forward` is still up."
                : "The phone never started casting. Approve the screen-capture prompt on the device, or switch to ADB Direct."

            // stop() resets state to .idle, so the reason is applied after it.
            self.stop()
            self.state = .failed(reason)
        }
    }

    private func requestCompanionStart() async throws {
        guard let url = URL(string: "http://127.0.0.1:8080/api/aerocast/start") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "audio": isAudioEnabled,
            "video": true
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ADBError.commandFailed("Companion returned HTTP \(http.statusCode)")
        }
    }

    private func requestCompanionStop(serial: String) async {
        guard let url = URL(string: "http://127.0.0.1:8080/api/aerocast/stop") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        _ = try? await URLSession.shared.data(for: request)
    }

    private func openSocket() {
        let endpoint = NWEndpoint.hostPort(
            host: .init("127.0.0.1"),
            port: .init(rawValue: AeroCastProtocol.port)!
        )

        let params = NWParameters.tcp
        // Screen mirroring is latency-critical; coalescing small packets would
        // add a frame of lag for nothing.
        if let tcp = params.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            // Generous, because the phone may be sitting on the screen-capture
            // consent dialog: nothing is listening on 8081 until it's approved.
            tcp.connectionTimeout = 60
        }

        let conn = NWConnection(to: endpoint, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                guard let self else { return }
                switch newState {
                case .ready:
                    self.receiveNext()
                case .failed(let error):
                    self.state = .failed("AeroCast socket failed: \(error.localizedDescription)")
                    self.stopAudio()
                case .cancelled:
                    break
                case .waiting(let error):
                    self.state = .preparing("Waiting on companion… (\(error.localizedDescription))")
                default:
                    break
                }
            }
        }

        conn.start(queue: .global(qos: .userInteractive))
    }

    private func receiveNext() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                Task { @MainActor in self.ingest(data) }
            }

            if let error {
                Task { @MainActor in
                    self.state = .failed("AeroCast receive error: \(error.localizedDescription)")
                    self.stopAudio()
                }
                return
            }

            if isComplete {
                Task { @MainActor in
                    if self.state.isLive {
                        self.state = .failed("Companion closed the AeroCast stream.")
                    }
                    self.stopAudio()
                }
                return
            }

            Task { @MainActor in self.receiveNext() }
        }
    }

    // MARK: - Packet handling

    private func ingest(_ data: Data) {
        parser.append(data)

        let packets: [AeroCastProtocol.Packet]
        do {
            packets = try parser.drain()
        } catch {
            state = .failed(error.localizedDescription)
            connection?.cancel()
            return
        }

        for packet in packets {
            handle(packet)
        }
    }

    private func handle(_ packet: AeroCastProtocol.Packet) {
        switch packet.type {
        case .streamInfo:
            if let info = try? JSONDecoder().decode(AeroCastProtocol.StreamInfo.self, from: packet.payload) {
                streamInfo = info
                rebuildAudioFormat(sampleRate: info.sampleRate, channels: info.channels)
            }

        case .videoConfig:
            applyParameterSets(from: packet.payload)

        case .videoFrame:
            decodeVideo(packet)

        case .audioConfig:
            if let info = try? JSONDecoder().decode(AeroCastProtocol.StreamInfo.self, from: packet.payload) {
                rebuildAudioFormat(sampleRate: info.sampleRate, channels: info.channels)
            }

        case .audioFrame:
            audioBytesWindow += packet.payload.count
            playPCM(packet.payload)

        case .heartbeat:
            break
        }

        trackLatency(for: packet)
    }

    /// Estimates end-to-end lag by comparing how far the device's presentation
    /// clock has advanced against our own wall clock since the first packet.
    private func trackLatency(for packet: AeroCastProtocol.Packet) {
        guard packet.type == .videoFrame else { return }
        let now = CACurrentMediaTime()

        guard let firstPTS = firstPacketPTS, let firstWall = firstPacketWallClock else {
            firstPacketPTS = packet.presentationTimeUs
            firstPacketWallClock = now
            return
        }

        let deviceElapsed = Double(packet.presentationTimeUs - firstPTS) / 1_000_000.0
        let hostElapsed = now - firstWall
        let drift = (hostElapsed - deviceElapsed) * 1000
        // Smooth heavily: individual frames jitter far more than the trend.
        latencyMs = latencyMs == 0 ? max(0, drift) : (latencyMs * 0.9 + max(0, drift) * 0.1)
    }

    // MARK: - Video

    private func applyParameterSets(from annexB: Data) {
        let nals = AnnexB.nalUnits(in: annexB)
        for nal in nals {
            switch AnnexB.type(of: nal) {
            case AnnexB.sps: spsData = nal
            case AnnexB.pps: ppsData = nal
            default: break
            }
        }
        buildFormatDescription()
    }

    private func buildFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }

        var description: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OSStatus(-1)
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }

        guard status == noErr, let description else {
            state = .failed("Could not build a video format description from the device's SPS/PPS.")
            return
        }

        formatDescription = description
        displayLayer.flush()
    }

    private func decodeVideo(_ packet: AeroCastProtocol.Packet) {
        videoBytesWindow += packet.payload.count

        var nals = AnnexB.nalUnits(in: packet.payload)
        guard !nals.isEmpty else { return }

        // Some encoders inline the parameter sets ahead of every IDR. Harvest
        // them, then strip them out of the frame we hand to the decoder.
        var sawParameterSet = false
        for nal in nals {
            switch AnnexB.type(of: nal) {
            case AnnexB.sps: spsData = nal; sawParameterSet = true
            case AnnexB.pps: ppsData = nal; sawParameterSet = true
            default: break
            }
        }
        if sawParameterSet && formatDescription == nil {
            buildFormatDescription()
        }
        nals.removeAll { AnnexB.type(of: $0) == AnnexB.sps || AnnexB.type(of: $0) == AnnexB.pps }

        guard !nals.isEmpty, let formatDescription else { return }

        let avcc = AnnexB.avccBuffer(from: nals)
        guard let sampleBuffer = makeSampleBuffer(
            avcc: avcc,
            formatDescription: formatDescription,
            presentationTimeUs: packet.presentationTimeUs
        ) else { return }

        enqueue(sampleBuffer)
    }

    private func makeSampleBuffer(
        avcc: Data,
        formatDescription: CMVideoFormatDescription,
        presentationTimeUs: Int64
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?

        // CMBlockBuffer takes ownership of this allocation; the custom
        // allocator hands it straight back to malloc when the buffer dies.
        let length = avcc.count
        let memory = malloc(length)
        guard let memory else { return nil }
        avcc.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: length)

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memory,
            blockLength: length,
            blockAllocator: kCFAllocatorMalloc,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            free(memory)
            return nil
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = length
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: presentationTimeUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else { return nil }

        // Present as soon as decoded — this is a mirror, not a movie.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }

    private func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer

        if renderer.status == .failed {
            renderer.flush()
        }

        renderer.enqueue(sampleBuffer)

        framesDecoded += 1
        framesWindow += 1

        if !state.isLive {
            firstFrameWatchdog?.cancel()
            firstFrameWatchdog = nil
            state = .streaming
            startAudioIfNeeded()
        }
    }

    // MARK: - Audio

    private func rebuildAudioFormat(sampleRate: Int, channels: Int) {
        guard sampleRate > 0, channels > 0 else { return }
        let desired = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels)
        )
        guard let desired, desired != audioFormat else { return }

        let wasRunning = audioEngineRunning
        stopAudio()
        audioFormat = desired
        audioEngine.disconnectNodeOutput(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: desired)
        if wasRunning { startAudioIfNeeded() }
    }

    private func startAudioIfNeeded() {
        guard isAudioEnabled, !audioEngineRunning, audioFormat != nil else { return }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            playerNode.play()
            audioEngineRunning = true
            isAudioActive = true
        } catch {
            // A failed audio graph must not take the video down with it.
            isAudioActive = false
            audioEngineRunning = false
        }
    }

    private func stopAudio() {
        guard audioEngineRunning else {
            isAudioActive = false
            return
        }
        playerNode.stop()
        audioEngine.stop()
        audioEngineRunning = false
        isAudioActive = false
    }

    private func applyAudioEnabled() {
        if isAudioEnabled {
            if state.isLive { startAudioIfNeeded() }
        } else {
            stopAudio()
        }
    }

    /// Converts interleaved signed 16-bit PCM into the engine's deinterleaved
    /// float format and schedules it for playback.
    private func playPCM(_ pcm: Data) {
        guard isAudioEnabled, let format = audioFormat else { return }
        startAudioIfNeeded()
        guard audioEngineRunning else { return }

        let channels = Int(format.channelCount)
        let bytesPerFrame = 2 * channels
        let frameCount = pcm.count / bytesPerFrame
        guard frameCount > 0 else { return }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let channelData = buffer.floatChannelData else { return }

        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let samples = base.assumingMemoryBound(to: Int16.self)
            let scale = Float(1.0 / 32768.0)
            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    // The wire is little-endian; so is every Mac we run on, but
                    // be explicit rather than rely on it.
                    let raw = Int16(littleEndian: samples[frame * channels + channel])
                    channelData[channel][frame] = Float(raw) * scale
                }
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - ADB direct (screenrecord) path

    private func startScreenRecordStream(serial: String) async {
        state = .preparing("Reading the device's display size…")

        // screenrecord defaults to the panel's native resolution, which many
        // encoders reject; ask the device what it actually is and cap it.
        let (width, height) = await deviceDisplaySize(serial: serial)
        streamInfo = AeroCastProtocol.StreamInfo(
            width: width, height: height,
            sampleRate: 0, channels: 0,
            videoBitRate: 8_000_000, frameRate: nil,
            deviceName: serial
        )

        state = .preparing("Starting screenrecord on the device…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            adbPath, "-s", serial, "exec-out",
            "screenrecord",
            "--output-format=h264",
            "--bit-rate=8000000",
            "--size=\(width)x\(height)",
            "-"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            state = .failed("Could not launch screenrecord: \(error.localizedDescription)")
            return
        }

        recordProcess = process

        // screenrecord emits a raw Annex-B elementary stream with no framing of
        // its own, so we accumulate and split on access-unit delimiters.
        let handle = pipe.fileHandleForReading
        var pending = Data()

        handle.readabilityHandler = { [weak self] fileHandle in
            let chunk = fileHandle.availableData
            guard !chunk.isEmpty else {
                fileHandle.readabilityHandler = nil
                Task { @MainActor in
                    guard let self else { return }
                    if self.state.isLive {
                        self.state = .failed("screenrecord ended (it caps out at ~3 minutes per run).")
                    }
                }
                return
            }
            pending.append(chunk)

            // Hand over everything up to the last start code; keep the tail,
            // which may be a partial NAL.
            guard let lastStart = Self.lastStartCodeIndex(in: pending), lastStart > 0 else { return }
            let complete = pending.prefix(lastStart)
            pending.removeFirst(lastStart)

            let payload = Data(complete)
            Task { @MainActor in
                guard let self else { return }
                self.handleRawAnnexB(payload)
            }
        }

        state = .preparing("Waiting for the first frame…")
    }

    /// Parses `wm size` for the panel's real resolution, scaled so the long
    /// edge sits at 1080 (screenrecord's encoder is happiest there) and both
    /// dimensions are even, which H.264 requires.
    private func deviceDisplaySize(serial: String) async -> (Int, Int) {
        let fallback = (1080, 1920)

        guard let output = await runADB(["-s", serial, "shell", "wm", "size"]) else {
            return fallback
        }

        // Prefer an override if the user has one set — that's what's actually
        // being rendered.
        let lines = output.components(separatedBy: .newlines)
        let line = lines.first(where: { $0.contains("Override size") })
            ?? lines.first(where: { $0.contains("Physical size") })

        guard let line,
              let colon = line.firstIndex(of: ":") else { return fallback }

        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        let parts = value.split(separator: "x")
        guard parts.count == 2,
              var width = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              var height = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              width > 0, height > 0 else { return fallback }

        let longEdge = max(width, height)
        if longEdge > 1080 {
            let scale = 1080.0 / Double(longEdge)
            width = Int(Double(width) * scale)
            height = Int(Double(height) * scale)
        }

        return (width - (width % 2), height - (height % 2))
    }

    /// Index of the final Annex-B start code in a buffer, used to cut cleanly
    /// between access units.
    private nonisolated static func lastStartCodeIndex(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { return nil }
        var i = bytes.count - 4
        while i >= 0 {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                return i
            }
            i -= 1
        }
        return nil
    }

    private func handleRawAnnexB(_ data: Data) {
        let nals = AnnexB.nalUnits(in: data)
        guard !nals.isEmpty else { return }

        var frameNals: [Data] = []
        for nal in nals {
            switch AnnexB.type(of: nal) {
            case AnnexB.sps:
                spsData = nal
                if ppsData != nil { buildFormatDescription() }
            case AnnexB.pps:
                ppsData = nal
                if spsData != nil { buildFormatDescription() }
            default:
                frameNals.append(nal)
            }
        }

        guard !frameNals.isEmpty, let formatDescription else { return }

        videoBytesWindow += data.count

        // screenrecord gives no timestamps, so synthesise a 60 fps clock.
        let pts = Int64(framesDecoded) * 16_666
        let avcc = AnnexB.avccBuffer(from: frameNals)
        guard let sampleBuffer = makeSampleBuffer(
            avcc: avcc,
            formatDescription: formatDescription,
            presentationTimeUs: pts
        ) else { return }

        enqueue(sampleBuffer)
    }

    // MARK: - Stats

    private func beginStatsTimer() {
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.videoBitrate = self.videoBitrate * 0.4 + Double(self.videoBytesWindow * 8) * 0.6
                self.audioBitrate = self.audioBitrate * 0.4 + Double(self.audioBytesWindow * 8) * 0.6
                self.measuredFPS = self.measuredFPS * 0.4 + Double(self.framesWindow) * 0.6
                self.videoBytesWindow = 0
                self.audioBytesWindow = 0
                self.framesWindow = 0
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    // MARK: - ADB helper

    private func runADB(_ arguments: [String]) async -> String? {
        let adb = adbPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [adb] + arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
