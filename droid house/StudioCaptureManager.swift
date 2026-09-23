import Foundation
import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import Combine

// MARK: - Studio Media Capture & Recording Manager
//
// Provides high-resolution photo snapshots, 60 FPS video recording (with
// synchronized studio audio), and pure uncompressed studio audio-only WAV
// recording directly to disk on macOS.

@MainActor
final class StudioCaptureManager: ObservableObject {

    enum Mode: Equatable {
        case idle
        case recordingVideo(startDate: Date)
        case recordingAudio(startDate: Date)

        var isRecording: Bool {
            switch self {
            case .idle: return false
            default: return true
            }
        }
    }

    // MARK: - Published State

    @Published private(set) var currentMode: Mode = .idle
    @Published private(set) var durationString: String = "00:00"
    @Published private(set) var recordedSizeMB: Double = 0.0
    @Published private(set) var isFlashActive: Bool = false
    @Published private(set) var lastSavedURL: URL?
    @Published private(set) var lastSavedThumbnail: NSImage?
    @Published var toastNotification: String?

    // High-performance background asset recorder
    private let recorder = StudioAssetRecorder()
    private var recordedVideoURL: URL?
    private var audioRecordingURL: URL?
    private var tickerTimer: Timer?

    // MARK: - Lifecycle

    init() {
        ensureFoldersExist()
    }

    private func ensureFoldersExist() {
        let fm = FileManager.default
        let pictures = fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/DroidHouse", isDirectory: true)
        let movies = fm.homeDirectoryForCurrentUser.appendingPathComponent("Movies/DroidHouse", isDirectory: true)
        let music = fm.homeDirectoryForCurrentUser.appendingPathComponent("Music/DroidHouse", isDirectory: true)

        try? fm.createDirectory(at: pictures, withIntermediateDirectories: true)
        try? fm.createDirectory(at: movies, withIntermediateDirectories: true)
        try? fm.createDirectory(at: music, withIntermediateDirectories: true)
    }

    private func timestampString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - Snapshot Capture

    func captureSnapshot(from pixelBuffer: CVPixelBuffer?) {
        guard let pixelBuffer else {
            toastNotification = "No video frame available for snapshot"
            return
        }

        // Trigger visual flash
        triggerFlash()
        playShutterSound()

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rep = NSCIImageRep(ciImage: ciImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            toastNotification = "Failed to encode photo"
            return
        }

        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/DroidHouse", isDirectory: true)
        let fileURL = folder.appendingPathComponent("DroidHouse_Photo_\(timestampString()).png")

        do {
            try pngData.write(to: fileURL, options: .atomic)
            lastSavedURL = fileURL
            lastSavedThumbnail = nsImage
            toastNotification = "Photo saved to Pictures/DroidHouse"
        } catch {
            toastNotification = "Failed to save photo: \(error.localizedDescription)"
        }
    }

    // MARK: - Video Recording (60 FPS + Synchronized Audio)

    func startVideoRecording(width: Int = 1920, height: Int = 1080, fps: Int = 60) {
        guard !currentMode.isRecording else { return }

        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/DroidHouse", isDirectory: true)
        let fileURL = folder.appendingPathComponent("DroidHouse_Video_\(timestampString()).mp4")
        recordedVideoURL = fileURL

        do {
            try recorder.startVideo(outputURL: fileURL, width: width, height: height, fps: fps)
            let now = Date()
            self.currentMode = .recordingVideo(startDate: now)
            startTicker(from: now, fileURL: fileURL)
            toastNotification = "Recording 60 FPS Video..."
        } catch {
            toastNotification = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    func appendVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard case .recordingVideo = currentMode else { return }
        recorder.appendVideo(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
    }

    func appendAudioPCM(_ pcm: Data, frameCount: Int, presentationTime: CMTime) {
        guard case .recordingVideo = currentMode else { return }
        recorder.appendAudio(pcm: pcm, frameCount: frameCount, presentationTime: presentationTime)
    }

    func stopVideoRecording() {
        guard case .recordingVideo = currentMode else { return }
        stopTicker()
        currentMode = .idle

        let destination = recordedVideoURL
        recorder.stopVideo { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if let destination {
                    self.lastSavedURL = destination
                    self.generateVideoThumbnail(for: destination)
                    self.toastNotification = "Video saved to Movies/DroidHouse"
                }
            }
        }
    }

    // MARK: - Audio-Only Recording (Pure 48 kHz Linear PCM WAV)

    func startAudioOnlyRecording() {
        guard !currentMode.isRecording else { return }

        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/DroidHouse", isDirectory: true)
        let fileURL = folder.appendingPathComponent("DroidHouse_Audio_\(timestampString()).wav")
        audioRecordingURL = fileURL

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true) else {
            toastNotification = "Could not initialize WAV audio format"
            return
        }

        do {
            try recorder.startAudioOnly(outputURL: fileURL, format: format)
            let now = Date()
            self.currentMode = .recordingAudio(startDate: now)
            startTicker(from: now, fileURL: fileURL)
            toastNotification = "Recording Studio Audio (WAV 48kHz)..."
        } catch {
            toastNotification = "Failed to create audio file: \(error.localizedDescription)"
        }
    }

    func appendAudioOnlyPCM(_ pcm: Data, frameCount: Int) {
        guard case .recordingAudio = currentMode else { return }
        recorder.appendAudioOnly(pcm: pcm, frameCount: frameCount)
    }

    func stopAudioOnlyRecording() {
        guard case .recordingAudio = currentMode else { return }
        stopTicker()
        currentMode = .idle
        recorder.stopAudioOnly()

        if let url = audioRecordingURL {
            lastSavedURL = url
            lastSavedThumbnail = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil)
            toastNotification = "Audio saved to Music/DroidHouse"
        }
    }

    // MARK: - Utilities

    private func startTicker(from startDate: Date, fileURL: URL) {
        tickerTimer?.invalidate()
        tickerTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let elapsed = Int(Date().timeIntervalSince(startDate))
                let m = elapsed / 60
                let s = elapsed % 60
                self.durationString = String(format: "%02d:%02d", m, s)

                if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                   let size = attrs[.size] as? UInt64 {
                    self.recordedSizeMB = Double(size) / (1024.0 * 1024.0)
                }
            }
        }
    }

    private func stopTicker() {
        tickerTimer?.invalidate()
        tickerTimer = nil
    }

    private func triggerFlash() {
        isFlashActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.isFlashActive = false
        }
    }

    private func playShutterSound() {
        NSSound(named: "Hero")?.play()
    }

    private func generateVideoThumbnail(for url: URL) {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)

        Task.detached {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                let img = NSImage(cgImage: cgImage, size: NSSize(width: 80, height: 45))
                await MainActor.run { [weak self] in
                    self?.lastSavedThumbnail = img
                }
            }
        }
    }

    func revealLastSavedInFinder() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Dedicated Background Asset Recorder

final class StudioAssetRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.droidhouse.recorderQueue", qos: .userInitiated)
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isSessionStarted = false
    private var sessionStartTime: CMTime = .invalid
    private var lastVideoPTS: CMTime = .invalid
    private var lastAudioPTS: CMTime = .invalid
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?

    func startVideo(outputURL: URL, width: Int, height: Int, fps: Int) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 25_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true

        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adapt = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: sourceAttrs
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 256000
        ]
        let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aInput.expectsMediaDataInRealTime = true

        if writer.canAdd(vInput) { writer.add(vInput) }
        if writer.canAdd(aInput) { writer.add(aInput) }

        writer.startWriting()

        queue.sync {
            self.assetWriter = writer
            self.videoInput = vInput
            self.audioInput = aInput
            self.adaptor = adapt
            self.isSessionStarted = false
            self.sessionStartTime = .invalid
            self.lastVideoPTS = .invalid
            self.lastAudioPTS = .invalid
        }
    }

    func appendVideo(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        queue.async {
            guard let writer = self.assetWriter,
                  let adaptor = self.adaptor else { return }

            if !self.isSessionStarted {
                writer.startSession(atSourceTime: presentationTime)
                self.sessionStartTime = presentationTime
                self.lastVideoPTS = presentationTime
                self.isSessionStarted = true
            }

            var pts = presentationTime
            if self.lastVideoPTS.isValid && pts <= self.lastVideoPTS {
                pts = CMTimeAdd(self.lastVideoPTS, CMTime(value: 1, timescale: 1_000_000))
            }

            if adaptor.assetWriterInput.isReadyForMoreMediaData {
                adaptor.append(pixelBuffer, withPresentationTime: pts)
                self.lastVideoPTS = pts
            }
        }
    }

    func appendAudio(pcm: Data, frameCount: Int, presentationTime: CMTime) {
        queue.async {
            guard self.isSessionStarted,
                  let audioInput = self.audioInput,
                  self.sessionStartTime.isValid else { return }

            var pts = presentationTime
            if pts < self.sessionStartTime {
                pts = self.sessionStartTime
            }
            if self.lastAudioPTS.isValid && pts <= self.lastAudioPTS {
                pts = CMTimeAdd(self.lastAudioPTS, CMTime(value: CMTimeValue(frameCount), timescale: 48000))
            }

            if audioInput.isReadyForMoreMediaData {
                if let sampleBuffer = self.createAudioSampleBuffer(pcm: pcm, frameCount: frameCount, pts: pts) {
                    audioInput.append(sampleBuffer)
                    self.lastAudioPTS = pts
                }
            }
        }
    }

    func stopVideo(completion: @escaping () -> Void) {
        queue.async {
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.assetWriter?.finishWriting {
                self.queue.async {
                    self.assetWriter = nil
                    self.videoInput = nil
                    self.audioInput = nil
                    self.adaptor = nil
                    self.isSessionStarted = false
                    completion()
                }
            }
        }
    }

    func startAudioOnly(outputURL: URL, format: AVAudioFormat) throws {
        let file = try AVAudioFile(forWriting: outputURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        queue.sync {
            self.audioFile = file
            self.audioFormat = format
        }
    }

    func appendAudioOnly(pcm: Data, frameCount: Int) {
        queue.async {
            guard let file = self.audioFile, let format = self.audioFormat else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            buffer.frameLength = AVAudioFrameCount(frameCount)
            pcm.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    memcpy(buffer.int16ChannelData?[0], base, pcm.count)
                }
            }
            try? file.write(from: buffer)
        }
    }

    func stopAudioOnly() {
        queue.sync {
            self.audioFile = nil
            self.audioFormat = nil
        }
    }

    private func createAudioSampleBuffer(pcm: Data, frameCount: Int, pts: CMTime) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let allocator = kCFAllocatorDefault
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: allocator,
            memoryBlock: nil,
            blockLength: pcm.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: pcm.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                CMBlockBufferReplaceDataBytes(
                    with: base,
                    blockBuffer: blockBuffer,
                    offsetIntoDestination: 0,
                    dataLength: pcm.count
                )
            }
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: allocator,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard let formatDesc else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount), timescale: 48000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleSize = pcm.count
        let sbStatus = CMSampleBufferCreateReady(
            allocator: allocator,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        return sbStatus == noErr ? sampleBuffer : nil
    }
}
