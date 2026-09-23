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

    // Video Recording with AVAssetWriter
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var audioWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isWriterSessionStarted = false
    private var videoStartTime: CMTime?
    private var recordedVideoURL: URL?

    // Audio Recording with AVAudioFile (Broadcast WAV 48 kHz Linear PCM)
    private var audioFile: AVAudioFile?
    private var audioRecordingURL: URL?
    private var audioRecordFormat: AVAudioFormat?

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
            let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)

            // Video Input (H.264)
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
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vInput,
                sourcePixelBufferAttributes: sourceAttrs
            )

            // Audio Input (AAC 48 kHz stereo 256 kbps)
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

            self.assetWriter = writer
            self.videoWriterInput = vInput
            self.audioWriterInput = aInput
            self.pixelBufferAdaptor = adaptor
            self.isWriterSessionStarted = false
            self.videoStartTime = nil

            let now = Date()
            self.currentMode = .recordingVideo(startDate: now)
            startTicker(from: now, fileURL: fileURL)
            toastNotification = "Recording 60 FPS Video..."
        } catch {
            toastNotification = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    func appendVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard case .recordingVideo = currentMode,
              let writer = assetWriter,
              let adaptor = pixelBufferAdaptor,
              adaptor.assetWriterInput.isReadyForMoreMediaData else { return }

        if !isWriterSessionStarted {
            writer.startSession(atSourceTime: presentationTime)
            videoStartTime = presentationTime
            isWriterSessionStarted = true
        }

        adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
    }

    func appendAudioPCM(_ pcm: Data, frameCount: Int, presentationTime: CMTime) {
        guard case .recordingVideo = currentMode,
              isWriterSessionStarted,
              let audioInput = audioWriterInput,
              audioInput.isReadyForMoreMediaData else { return }

        // Construct CMSampleBuffer for audio
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
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return }

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
        guard let formatDesc else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frameCount), timescale: 48000),
            presentationTimeStamp: presentationTime,
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

        if sbStatus == noErr, let sampleBuffer {
            audioInput.append(sampleBuffer)
        }
    }

    func stopVideoRecording() {
        guard case .recordingVideo = currentMode, let writer = assetWriter else { return }

        stopTicker()
        videoWriterInput?.markAsFinished()
        audioWriterInput?.markAsFinished()

        let destination = recordedVideoURL
        writer.finishWriting { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.currentMode = .idle
                self.assetWriter = nil
                self.videoWriterInput = nil
                self.audioWriterInput = nil
                self.pixelBufferAdaptor = nil

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
        audioRecordFormat = format

        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            self.audioFile = file

            let now = Date()
            self.currentMode = .recordingAudio(startDate: now)
            startTicker(from: now, fileURL: fileURL)
            toastNotification = "Recording Studio Audio (WAV 48kHz)..."
        } catch {
            toastNotification = "Failed to create audio file: \(error.localizedDescription)"
        }
    }

    func appendAudioOnlyPCM(_ pcm: Data, frameCount: Int) {
        guard case .recordingAudio = currentMode,
              let file = audioFile,
              let format = audioRecordFormat else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buffer.int16ChannelData?[0], base, pcm.count)
            }
        }

        try? file.write(from: buffer)
    }

    func stopAudioOnlyRecording() {
        guard case .recordingAudio = currentMode else { return }
        stopTicker()

        audioFile = nil
        currentMode = .idle

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
