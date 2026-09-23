import Foundation
import CoreAudio
import AudioToolbox
import AVFAudio
import Combine

// MARK: - Studio Audio Router
//
// Enumerates CoreAudio devices, discovers virtual audio sinks (e.g. BoomAudio,
// BlackHole, Loopback), and routes bit-perfect 48 kHz stereo PCM audio directly
// into BoomAudio so macOS applications (Zoom, Teams, Meet, Discord, FaceTime)
// detect and receive the phone's studio microphone.
//
// Also provides an independent local monitor pipeline to Mac speakers.

@MainActor
final class StudioAudioRouter: ObservableObject {

    struct DeviceInfo: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let isVirtual: Bool
        let isBoomAudio: Bool
        let hasOutput: Bool
        let hasInput: Bool
    }

    // MARK: - Published State

    @Published private(set) var availableOutputDevices: [DeviceInfo] = []
    @Published var selectedDeviceID: AudioDeviceID? {
        didSet {
            if oldValue != selectedDeviceID {
                configureVirtualMicPipeline()
            }
        }
    }

    @Published var isVirtualMicRoutingActive: Bool = true {
        didSet {
            if isVirtualMicRoutingActive {
                startVirtualMic()
            } else {
                stopVirtualMic()
            }
        }
    }

    @Published private(set) var activeTargetDeviceName: String = "Detecting..."
    @Published private(set) var isBoomAudioDetected: Bool = false
    @Published private(set) var isVirtualMicPumping: Bool = false

    // Local Speaker Monitor (Mac Speakers / Headphones)
    @Published var isMonitorEnabled: Bool = false {
        didSet {
            if isMonitorEnabled { startMonitor() } else { stopMonitor() }
        }
    }
    @Published var monitorVolume: Float = 0.8 {
        didSet { monitorPlayer.volume = monitorVolume }
    }

    // Metering for routed audio
    @Published private(set) var routedPeakDbL: Float = -60.0
    @Published private(set) var routedPeakDbR: Float = -60.0

    // MARK: - Audio Engines

    // 1. Virtual Mic Output Engine (feeds BoomAudio / virtual device)
    private let virtualEngine = AVAudioEngine()
    private let virtualPlayer = AVAudioPlayerNode()
    private var virtualFormat: AVAudioFormat?
    private var isVirtualEngineRunning = false

    // 2. Local Monitor Engine (feeds Mac speakers)
    private let monitorEngine = AVAudioEngine()
    private let monitorPlayer = AVAudioPlayerNode()
    private var monitorFormat: AVAudioFormat?
    private var isMonitorEngineRunning = false

    // MARK: - Lifecycle

    init() {
        refreshDevices()
        setupAudioGraphs()
    }

    deinit {
        // Stop engines
    }

    // MARK: - Device Discovery

    func refreshDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr, dataSize > 0 else { return }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard getStatus == noErr else { return }

        var devices: [DeviceInfo] = []
        var detectedBoom: DeviceInfo?

        for id in deviceIDs {
            // Check output streams
            var outStreamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outStreamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &outStreamAddr, 0, nil, &outStreamSize)
            let hasOutput = outStreamSize > 0

            // Check input streams
            var inStreamAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var inStreamSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &inStreamAddr, 0, nil, &inStreamSize)
            let hasInput = inStreamSize > 0

            guard hasOutput else { continue }

            // Device Name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameCF: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let nameResult = withUnsafeMutablePointer(to: &nameCF) { ptr in
                AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, ptr)
            }
            let name = nameResult == noErr ? (nameCF as String) : "Audio Device \(id)"

            // Device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidCF: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let uidResult = withUnsafeMutablePointer(to: &uidCF) { ptr in
                AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, ptr)
            }
            let uid = uidResult == noErr ? (uidCF as String) : "\(id)"

            let lowerName = name.lowercased()
            let isBoom = lowerName.contains("boom") || uid.lowercased().contains("boom")
            let isVirtual = isBoom || lowerName.contains("blackhole") || lowerName.contains("loopback") || lowerName.contains("soundflower") || lowerName.contains("virtual")

            let info = DeviceInfo(
                id: id,
                name: name,
                uid: uid,
                isVirtual: isVirtual,
                isBoomAudio: isBoom,
                hasOutput: hasOutput,
                hasInput: hasInput
            )
            devices.append(info)

            if isBoom && detectedBoom == nil {
                detectedBoom = info
            }
        }

        self.availableOutputDevices = devices
        self.isBoomAudioDetected = detectedBoom != nil

        // Auto-select BoomAudio if available; otherwise pick first virtual device or default output
        if let boom = detectedBoom {
            self.selectedDeviceID = boom.id
            self.activeTargetDeviceName = "\(boom.name) (Virtual Mic)"
        } else if let virtual = devices.first(where: { $0.isVirtual }) {
            self.selectedDeviceID = virtual.id
            self.activeTargetDeviceName = "\(virtual.name) (Virtual Mic)"
        } else if let first = devices.first {
            self.selectedDeviceID = first.id
            self.activeTargetDeviceName = first.name
        }
    }

    // MARK: - Setup Graphs

    private func setupAudioGraphs() {
        let standardFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        virtualFormat = standardFormat
        monitorFormat = standardFormat

        // 1. Virtual Mic Output Engine
        virtualEngine.attach(virtualPlayer)
        if let format = virtualFormat {
            virtualEngine.connect(virtualPlayer, to: virtualEngine.mainMixerNode, format: format)
        }

        // 2. Local Monitor Engine
        monitorEngine.attach(monitorPlayer)
        if let format = monitorFormat {
            monitorEngine.connect(monitorPlayer, to: monitorEngine.mainMixerNode, format: format)
        }
        monitorPlayer.volume = monitorVolume

        configureVirtualMicPipeline()
    }

    private func configureVirtualMicPipeline() {
        guard let deviceID = selectedDeviceID else { return }

        let wasRunning = isVirtualEngineRunning
        if wasRunning {
            virtualPlayer.stop()
            virtualEngine.stop()
            isVirtualEngineRunning = false
        }

        if let audioUnit = virtualEngine.outputNode.audioUnit {
            var targetID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &targetID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                print("StudioAudioRouter: failed to set current device on output unit: \(status)")
            }
        }

        if let device = availableOutputDevices.first(where: { $0.id == deviceID }) {
            activeTargetDeviceName = device.isBoomAudio ? "\(device.name) (Virtual Mic)" : device.name
        }

        if wasRunning || isVirtualMicRoutingActive {
            startVirtualMic()
        }
    }

    // MARK: - Engine Controls

    func startVirtualMic() {
        guard !isVirtualEngineRunning else { return }
        do {
            virtualEngine.prepare()
            try virtualEngine.start()
            virtualPlayer.play()
            isVirtualEngineRunning = true
            isVirtualMicPumping = true
        } catch {
            print("StudioAudioRouter: failed to start virtual audio engine: \(error)")
            isVirtualEngineRunning = false
            isVirtualMicPumping = false
        }
    }

    func stopVirtualMic() {
        guard isVirtualEngineRunning else { return }
        virtualPlayer.stop()
        virtualEngine.stop()
        isVirtualEngineRunning = false
        isVirtualMicPumping = false
    }

    func startMonitor() {
        guard !isMonitorEngineRunning else { return }
        do {
            monitorEngine.prepare()
            try monitorEngine.start()
            monitorPlayer.play()
            isMonitorEngineRunning = true
        } catch {
            print("StudioAudioRouter: failed to start monitor engine: \(error)")
            isMonitorEngineRunning = false
        }
    }

    func stopMonitor() {
        guard isMonitorEngineRunning else { return }
        monitorPlayer.stop()
        monitorEngine.stop()
        isMonitorEngineRunning = false
    }

    // MARK: - PCM Delivery

    /// Ingests raw 48 kHz stereo 16-bit PCM from phone and schedules it onto
    /// the virtual audio engine (BoomAudio) and/or the local speaker monitor.
    func ingestPCM(_ pcm: Data) {
        let channels = 2
        let bytesPerSample = 2
        let frameCount = pcm.count / (channels * bytesPerSample)
        guard frameCount > 0 else { return }

        guard let format = virtualFormat else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = buffer.floatChannelData else { return }

        var maxL: Float = 0
        var maxR: Float = 0

        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let samples = base.assumingMemoryBound(to: Int16.self)
            let scale = Float(1.0 / 32768.0)

            for i in 0..<frameCount {
                let sL = Float(Int16(littleEndian: samples[i * 2])) * scale
                let sR = Float(Int16(littleEndian: samples[i * 2 + 1])) * scale

                channelData[0][i] = sL
                channelData[1][i] = sR

                let absL = abs(sL)
                let absR = abs(sR)
                if absL > maxL { maxL = absL }
                if absR > maxR { maxR = absR }
            }
        }

        let peakL = maxL > 0.0001 ? 20.0 * log10(maxL) : -60.0
        let peakR = maxR > 0.0001 ? 20.0 * log10(maxR) : -60.0
        routedPeakDbL = max(peakL, routedPeakDbL - 1.5)
        routedPeakDbR = max(peakR, routedPeakDbR - 1.5)

        // Feed BoomAudio / virtual mic
        if isVirtualEngineRunning && isVirtualMicRoutingActive {
            virtualPlayer.scheduleBuffer(buffer, completionHandler: nil)
        }

        // Feed local speaker monitor if enabled
        if isMonitorEngineRunning && isMonitorEnabled {
            monitorPlayer.scheduleBuffer(buffer, completionHandler: nil)
        }
    }
}
