import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import Network
import Combine
import SwiftUI

// MARK: - Studio Camera & Microphone Engine
//
// Receives hardware-accelerated 1080p/4K 60FPS video and raw 48 kHz uncompressed
// bit-perfect stereo PCM audio from the Android phone over ADB socket (port 8082).
//
// Decodes H.264 using VideoToolbox, feeds SwiftUI's display layer, monitors
// real-time audio dBFS levels, routes mic audio directly to BoomAudio (macOS virtual
// microphone), and provides native photo snapshot, 60fps video, and audio-only recording.

@MainActor
final class StudioCamEngine: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case connecting(String)
        case live
        case failed(String)

        var isBusy: Bool {
            if case .connecting = self { return true }
            return false
        }
        var isLive: Bool { self == .live }
    }

    struct LensOption: Identifiable, Hashable {
        let id: String
        let title: String
        let focalDescription: String
        let systemImage: String
        let facing: String // "back" or "front"
        let zoomPreset: Float
    }

    static let availableLenses: [LensOption] = [
        LensOption(id: "back_ultra", title: "Ultra-Wide", focalDescription: "0.5x Ultra-Wide • 13mm", systemImage: "arrow.up.left.and.arrow.down.right", facing: "back", zoomPreset: 0.5),
        LensOption(id: "back_wide", title: "Main Lens", focalDescription: "1.0x Wide Angle • 24mm", systemImage: "camera.fill", facing: "back", zoomPreset: 1.0),
        LensOption(id: "back_tele", title: "Telephoto", focalDescription: "3.0x Telephoto • 70mm", systemImage: "scope", facing: "back", zoomPreset: 3.0),
        LensOption(id: "front", title: "Front Camera", focalDescription: "Selfie Portrait • 22mm", systemImage: "person.crop.square", facing: "front", zoomPreset: 1.0)
    ]

    // MARK: - Subsystems

    @Published var audioRouter = StudioAudioRouter()
    @Published var captureManager = StudioCaptureManager()
    @Published var virtualCamManager = StudioVirtualCamManager()

    // MARK: - Published State

    @Published private(set) var state: State = .idle
    @Published private(set) var streamInfo: StudioCamProtocol.StreamInfo?
    @Published private(set) var framesDecoded: Int = 0
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var videoBitrate: Double = 0
    @Published private(set) var audioBitrate: Double = 0
    @Published private(set) var latencyMs: Double = 0

    // Audio Metering (dBFS)
    @Published private(set) var audioPeakDbL: Float = -60.0
    @Published private(set) var audioPeakDbR: Float = -60.0
    @Published private(set) var audioRmsDbL: Float = -60.0
    @Published private(set) var audioRmsDbR: Float = -60.0
    @Published private(set) var isAudioClipping: Bool = false
    @Published private(set) var isAudioActive: Bool = false

    // Configuration & Camera Controls
    @Published var selectedLens: String = "back_wide"
    @Published var zoomRatio: Float = 1.0
    @Published var isTorchOn: Bool = false
    @Published var selectedResolution: String = "1080p"
    @Published var selectedFPS: Int = 60
    @Published var videoTargetBitrate: Int = 35_000_000 // 35 Mbps visually lossless
    @Published var unprocessedMic: Bool = true          // Pure hardware fidelity

    /// Display surface for the live camera viewfinder
    let displayLayer = AVSampleBufferDisplayLayer()

    /// Latest hardware-decoded CVPixelBuffer (BGRA) for snapshots, video recording & virtual camera
    @Published private(set) var latestPixelBuffer: CVPixelBuffer?

    // MARK: - Private Pipelines

    private var connection: NWConnection?
    private var parser = StudioCamStreamParser()
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var spsData: Data?
    private var ppsData: Data?

    private var adbPath: String = ADBLocator.resolve()
    private var deviceSerial: String?

    // Stats
    private var statsTimer: Timer?
    private var videoBytesWindow = 0
    private var audioBytesWindow = 0
    private var framesWindow = 0
    private var firstPTS: Int64?
    private var firstWallClock: CFTimeInterval?

    // MARK: - Lifecycle

    override init() {
        super.init()
        configureDisplayLayer()
    }

    private func configureDisplayLayer() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        var timebase: CMTimebase?
        let status = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        if status == noErr, let timebase {
            CMTimebaseSetTime(timebase, time: .zero)
            CMTimebaseSetRate(timebase, rate: 1.0)
            displayLayer.controlTimebase = timebase
        }
    }

    // MARK: - Control

    func start(serial: String) {
        guard !state.isLive, !state.isBusy else { return }
        deviceSerial = serial
        framesDecoded = 0
        parser.reset()
        formatDescription = nil
        spsData = nil
        ppsData = nil
        firstPTS = nil
        firstWallClock = nil
        // Activate virtual mic routing so BoomAudio receives audio immediately
        audioRouter.isStreamActive = true
        audioRouter.refreshDevices()
        if audioRouter.isVirtualMicRoutingActive {
            audioRouter.startVirtualMic()
        }
        if audioRouter.isMonitorEnabled {
            audioRouter.startMonitor()
        }

        beginStatsTimer()

        Task {
            await startStudioStream(serial: serial)
        }
    }

    func stop() {
        statsTimer?.invalidate()
        statsTimer = nil

        connection?.cancel()
        connection = nil

        audioRouter.isStreamActive = false
        audioRouter.stopVirtualMic()
        audioRouter.stopMonitor()

        if captureManager.currentMode.isRecording {
            if case .recordingVideo = captureManager.currentMode {
                captureManager.stopVideoRecording()
            } else {
                captureManager.stopAudioOnlyRecording()
            }
        }

        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        if let serial = deviceSerial {
            Task { await requestStudioStop(serial: serial) }
        }

        displayLayer.flushAndRemoveImage()
        state = .idle
        streamInfo = nil
        isAudioActive = false
        videoBitrate = 0
        audioBitrate = 0
        measuredFPS = 0
        latencyMs = 0
        audioPeakDbL = -60.0
        audioPeakDbR = -60.0
        audioRmsDbL = -60.0
        audioRmsDbR = -60.0
        isAudioClipping = false
        latestPixelBuffer = nil
        isTorchOn = false
    }

    func toggle(serial: String) {
        if state.isLive || state.isBusy {
            stop()
        } else {
            start(serial: serial)
        }
    }

    // MARK: - Dynamic Lens & Zoom Controls

    func switchLens(to lensId: String) {
        selectedLens = lensId
        if let lens = Self.availableLenses.first(where: { $0.id == lensId }) {
            zoomRatio = lens.zoomPreset
        }

        if state.isLive {
            Task {
                await sendLensRequest(lensId: lensId)
            }
        }
    }

    func setZoomRatio(_ ratio: Float) {
        let clamped = max(0.5, min(10.0, ratio))
        zoomRatio = clamped

        if state.isLive {
            Task {
                await sendZoomRequest(zoomRatio: clamped)
            }
        }
    }

    func toggleTorch() {
        isTorchOn.toggle()
        if state.isLive {
            Task {
                await sendTorchRequest(enabled: isTorchOn)
            }
        }
    }

    private func sendLensRequest(lensId: String) async {
        guard let url = URL(string: "http://127.0.0.1:8080/api/studio/lens") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["lensId": lensId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func sendZoomRequest(zoomRatio: Float) async {
        guard let url = URL(string: "http://127.0.0.1:8080/api/studio/zoom") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["zoomRatio": zoomRatio]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func sendTorchRequest(enabled: Bool) async {
        guard let url = URL(string: "http://127.0.0.1:8080/api/studio/torch") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["enabled": enabled]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Stream Setup

    private func startStudioStream(serial: String) async {
        state = .connecting("Forwarding Studio port \(StudioCamProtocol.defaultPort)...")

        let forwarded = await runADB([
            "-s", serial, "forward",
            "tcp:\(StudioCamProtocol.defaultPort)",
            "tcp:\(StudioCamProtocol.defaultPort)"
        ])

        guard forwarded != nil else {
            state = .failed("Could not forward ADB port \(StudioCamProtocol.defaultPort).")
            return
        }

        // Ensure companion app is active so hardware camera/mic access is granted
        _ = await runADB([
            "-s", serial, "shell",
            "am", "start", "-n", "com.droidhouse.companion/.MainActivity",
            "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER"
        ])

        state = .connecting("Starting camera sensor & studio mic on phone...")

        // Reset any stale session before starting
        await requestStudioStop(serial: serial)
        try? await Task.sleep(nanoseconds: 300_000_000)

        do {
            try await requestStudioStart()
        } catch {
            state = .failed("Companion failed to activate Studio Camera & Mic: \(error.localizedDescription)")
            return
        }

        state = .connecting("Connecting studio feed...")
        try? await Task.sleep(nanoseconds: 200_000_000)
        openSocket()
    }

    private func openSocket() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: StudioCamProtocol.defaultPort)!
        )
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOptions)

        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receiveLoop()
                case .failed(let err):
                    if self.state.isBusy || self.state.isLive {
                        self.state = .failed("Socket connection failed: \(err.localizedDescription)")
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        self.connection = conn
        conn.start(queue: .global(qos: .userInteractive))
    }

    private func receiveLoop() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { @MainActor in
                    self.ingestBytes(data)
                }
            }
            if err != nil || isComplete {
                Task { @MainActor in
                    if self.state.isLive {
                        self.state = .failed("Studio stream was closed by phone.")
                    }
                }
                return
            }
            Task { @MainActor in
                self.receiveLoop()
            }
        }
    }

    private func ingestBytes(_ data: Data) {
        parser.append(data)
        do {
            let packets = try parser.drain()
            for packet in packets {
                handlePacket(packet)
            }
        } catch {
            state = .failed("Stream parse error: \(error.localizedDescription)")
            connection?.cancel()
        }
    }

    private func handlePacket(_ packet: StudioCamProtocol.Packet) {
        switch packet.type {
        case .streamInfo:
            if let info = try? JSONDecoder().decode(StudioCamProtocol.StreamInfo.self, from: packet.payload) {
                self.streamInfo = info
            }

        case .videoConfig:
            applyVideoParameterSets(from: packet.payload)

        case .videoFrame:
            videoBytesWindow += packet.payload.count
            decodeVideoFrame(packet)

        case .audioConfig:
            break

        case .audioFrame:
            audioBytesWindow += packet.payload.count
            isAudioActive = true
            processStudioAudio(packet.payload, pts: packet.presentationTimeUs)

        case .heartbeat:
            break
        }

        trackLatency(pts: packet.presentationTimeUs)
    }

    private func trackLatency(pts: Int64) {
        let now = CACurrentMediaTime()
        guard let firstPTS = self.firstPTS, let firstWall = self.firstWallClock else {
            self.firstPTS = pts
            self.firstWallClock = now
            return
        }
        let devElapsed = Double(pts - firstPTS) / 1_000_000.0
        let hostElapsed = now - firstWall
        let drift = (hostElapsed - devElapsed) * 1000
        latencyMs = latencyMs == 0 ? max(0, drift) : (latencyMs * 0.85 + max(0, drift) * 0.15)
    }

    // MARK: - Video Pipeline & Hardware Decoding

    private func applyVideoParameterSets(from annexB: Data) {
        let nals = AnnexB.nalUnits(in: annexB)
        for nal in nals {
            switch AnnexB.type(of: nal) {
            case AnnexB.sps: spsData = nal
            case AnnexB.pps: ppsData = nal
            default: break
            }
        }
        buildFormatDescriptionAndDecompressor()
    }

    private func buildFormatDescriptionAndDecompressor() {
        guard let sps = spsData, let pps = ppsData else { return }
        var desc: CMVideoFormatDescription?
        let params: [Data] = [sps, pps]
        let pointers = params.map { ($0 as NSData).bytes.bindMemory(to: UInt8.self, capacity: $0.count) }
        let sizes = params.map { $0.count }

        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &desc
        )

        if status == noErr, let desc {
            self.formatDescription = desc
            createDecompressionSession(desc)
        }
    }

    private func createDecompressionSession(_ desc: CMVideoFormatDescription) {
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
            decompressionSession = nil
        }

        let destinationAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            decompressionSessionOut: &newSession
        )

        if status == noErr {
            self.decompressionSession = newSession
        }
    }

    private func handleDecodedPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        self.latestPixelBuffer = pixelBuffer

        // Feed active video recording if running
        captureManager.appendVideoPixelBuffer(pixelBuffer, presentationTime: presentationTime)

        // Feed virtual camera driver
        virtualCamManager.publishFrame(pixelBuffer)
    }

    private func decodeVideoFrame(_ packet: StudioCamProtocol.Packet) {
        guard let formatDescription else { return }

        let nals = AnnexB.nalUnits(in: packet.payload)
        guard !nals.isEmpty else { return }
        let avcc = AnnexB.avccBuffer(from: nals)

        var blockBuffer: CMBlockBuffer?
        let allocator = kCFAllocatorDefault
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: allocator,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return }

        avcc.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                CMBlockBufferReplaceDataBytes(
                    with: base,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: avcc.count
                )
            }
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleTiming = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(selectedFPS)),
            presentationTimeStamp: CMTime(value: packet.presentationTimeUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )

        var sampleSize = avcc.count
        let sbStatus = CMSampleBufferCreateReady(
            allocator: allocator,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &sampleTiming,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sbStatus == noErr, let sampleBuffer else { return }

        // Attach display flags for immediate presentation in viewfinder
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        displayLayer.enqueue(sampleBuffer)
        framesDecoded += 1
        framesWindow += 1

        if !state.isLive {
            state = .live
        }

        // Hardware decode into raw CVPixelBuffer via VideoToolbox
        if let session = decompressionSession {
            var flagsOut: VTDecodeInfoFlags = []
            _ = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: &flagsOut
            ) { [weak self] status, _, imageBuffer, pts, _ in
                guard status == noErr, let imageBuffer else { return }
                Task { @MainActor in
                    self?.handleDecodedPixelBuffer(imageBuffer, presentationTime: pts)
                }
            }
        }
    }

    // MARK: - Audio Pipeline (Bit-Perfect PCM & BoomAudio Virtual Mic Routing)

    private func processStudioAudio(_ pcm: Data, pts: Int64) {
        let channels = 2
        let bytesPerSample = 2 // 16-bit signed
        let frameCount = pcm.count / (channels * bytesPerSample)
        guard frameCount > 0 else { return }

        var maxL: Float = 0
        var maxR: Float = 0
        var sumSquaresL: Float = 0
        var sumSquaresR: Float = 0

        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let samples = base.assumingMemoryBound(to: Int16.self)

            for i in 0..<frameCount {
                let sampleL = Float(Int16(littleEndian: samples[i * 2])) / 32768.0
                let sampleR = Float(Int16(littleEndian: samples[i * 2 + 1])) / 32768.0

                let absL = abs(sampleL)
                let absR = abs(sampleR)

                if absL > maxL { maxL = absL }
                if absR > maxR { maxR = absR }

                sumSquaresL += sampleL * sampleL
                sumSquaresR += sampleR * sampleR
            }
        }

        let rmsL = sqrt(sumSquaresL / Float(frameCount))
        let rmsR = sqrt(sumSquaresR / Float(frameCount))

        let peakDbL = maxL > 0.0001 ? 20.0 * log10(maxL) : -60.0
        let peakDbR = maxR > 0.0001 ? 20.0 * log10(maxR) : -60.0
        let rmsDbL = rmsL > 0.0001 ? 20.0 * log10(rmsL) : -60.0
        let rmsDbR = rmsR > 0.0001 ? 20.0 * log10(rmsR) : -60.0

        // Smooth with fast attack, gentle release
        audioPeakDbL = max(peakDbL, audioPeakDbL - 1.5)
        audioPeakDbR = max(peakDbR, audioPeakDbR - 1.5)
        audioRmsDbL = max(rmsDbL, audioRmsDbL - 1.0)
        audioRmsDbR = max(rmsDbR, audioRmsDbR - 1.0)
        isAudioClipping = maxL >= 0.999 || maxR >= 0.999

        // 1. Ingest into CoreAudio router -> BoomAudio virtual mic & speaker monitor
        audioRouter.ingestPCM(pcm)

        // 2. Feed active media recordings
        let cmPts = CMTime(value: pts, timescale: 1_000_000)
        captureManager.appendAudioPCM(pcm, frameCount: frameCount, presentationTime: cmPts)
        captureManager.appendAudioOnlyPCM(pcm, frameCount: frameCount)
    }

    // MARK: - REST Bridge Controls

    private func requestStudioStart() async throws {
        guard let url = URL(string: "http://127.0.0.1:8080/api/studio/start") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "camera": true,
            "lensId": selectedLens,
            "resolution": selectedResolution,
            "fps": selectedFPS,
            "bitRate": videoTargetBitrate,
            "mic": true,
            "micUnprocessed": unprocessedMic
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "StudioCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "Phone returned non-200"])
        }
    }

    private func requestStudioStop(serial: String) async {
        guard let url = URL(string: "http://127.0.0.1:8080/api/studio/stop") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Stats

    private func beginStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.measuredFPS = Double(self.framesWindow)
                self.videoBitrate = Double(self.videoBytesWindow * 8)
                self.audioBitrate = Double(self.audioBytesWindow * 8)
                self.framesWindow = 0
                self.videoBytesWindow = 0
                self.audioBytesWindow = 0
            }
        }
    }

    private func runADB(_ arguments: [String]) async -> String? {
        let path = self.adbPath
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        continuation.resume(returning: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        continuation.resume(returning: nil)
                    }
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
