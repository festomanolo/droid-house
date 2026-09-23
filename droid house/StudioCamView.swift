import SwiftUI
import AVFoundation

// MARK: - Studio Camera & Microphone View
//
// High-fidelity spatial interface for 60 FPS video streaming, 48 kHz bit-perfect
// audio routing into BoomAudio (virtual mic), multi-camera lens switching (Ultra-Wide,
// Main, Telephoto), smooth zoom, flashlight control, and native Mac photo/video/audio capture.

struct StudioCamView: View {
    @ObservedObject var adbService: ADBService
    @StateObject private var engine = StudioCamEngine()

    @State private var showSettingsSheet = false
    @State private var showSystemInputGuide = false
    @State private var showZoomSlider = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch engine.state {
            case .idle:
                idleStage
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .connecting(let message):
                connectingStage(message)
                    .transition(.opacity)
            case .failed(let message):
                failureStage(message)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .live:
                liveStage
                    .transition(.opacity)
            }

            // Visual Flash Effect for Snapshot Capture
            if engine.captureManager.isFlashActive {
                Color.white.opacity(0.75)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.22), value: engine.captureManager.isFlashActive)
            }
        }
        .animation(Spatial.Motion.cinematic, value: engine.state)
        .overlay(alignment: .top) {
            if engine.state.isLive {
                topHUD
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if engine.state.isLive {
                VStack(spacing: 10) {
                    if let toast = engine.captureManager.toastNotification {
                        captureToast(toast)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .padding(.bottom, 16)
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            studioSettingsSheet
        }
        .sheet(isPresented: $showSystemInputGuide) {
            systemInputGuideSheet
        }
        .onDisappear {
            engine.stop()
        }
        .onChange(of: adbService.selectedDevice?.id) { _, _ in
            if engine.state.isLive { engine.stop() }
        }
    }

    // MARK: - Idle Stage

    private var idleStage: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.dhAccentMint.opacity(0.35), .clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 120
                        )
                    )
                    .frame(width: 240, height: 240)

                Image(systemName: "video.badge.waveform.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, Color.dhAccentMint],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 8) {
                Text("Studio Camera & Microphone")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)

                Text("Stream uncompressed 48 kHz studio audio and visually lossless 60 FPS video directly to your Mac. Routed to BoomAudio for system-wide virtual mic input.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            // Specs feature pills
            HStack(spacing: 16) {
                specPill(icon: "waveform.circle.fill", title: "BoomAudio Virtual Mic", detail: "48 kHz PCM • Auto-Routed")
                specPill(icon: "camera.metering.matrix", title: "Triple-Lens Camera", detail: "0.5x Ultra • 1x Wide • 3x Tele")
                specPill(icon: "record.circle", title: "Native Mac Recording", detail: "Photo, 60fps Video & WAV")
            }
            .padding(.vertical, 6)

            // Lens Selector Bar (Works in Idle mode)
            lensSelectorBar

            HStack(spacing: 14) {
                Button {
                    guard let serial = adbService.selectedDevice?.id else { return }
                    engine.start(serial: serial)
                } label: {
                    Label("Start Studio Broadcast", systemImage: "play.fill")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(
                    SpatialButtonStyle(
                        depth: .floating,
                        tint: .dhAccentMint,
                        padding: EdgeInsets(top: 11, leading: 24, bottom: 11, trailing: 24)
                    )
                )
                .disabled(adbService.selectedDevice == nil)

                Button {
                    showSystemInputGuide = true
                } label: {
                    Label("Mac Virtual Mic & Cam Setup", systemImage: "macbook.and.iphone")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(SpatialButtonStyle(depth: .surface))
            }

            if adbService.selectedDevice == nil {
                Label("Connect phone over USB or Wi-Fi to begin", systemImage: "iphone.slash")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.audioRouter.isBoomAudioDetected ? Color.dhAccentMint : Color.orange)
                        .frame(width: 7, height: 7)
                    Text("Target Virtual Mic: \(engine.audioRouter.activeTargetDeviceName)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(40)
    }

    private func specPill(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color.dhAccentMint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassSurface(.surface)
    }

    private var lensSelectorBar: some View {
        HStack(spacing: 8) {
            ForEach(StudioCamEngine.availableLenses) { lens in
                let isSelected = engine.selectedLens == lens.id
                Button {
                    engine.switchLens(to: lens.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: lens.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                        Text(lens.title)
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .glassSurface(.surface, highlighted: isSelected, tint: isSelected ? .dhAccentMint : nil)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Connecting Stage

    private func connectingStage(_ message: String) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(Color.dhAccentMint)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button("Cancel") { engine.stop() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(40)
    }

    // MARK: - Failure Stage

    private func failureStage(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)

            Text("Studio Broadcast Stopped")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 12) {
                Button {
                    guard let serial = adbService.selectedDevice?.id else { return }
                    engine.start(serial: serial)
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(SpatialButtonStyle(depth: .floating, tint: .dhAccentMint))

                Button("Dismiss") { engine.stop() }
                    .buttonStyle(SpatialButtonStyle(depth: .surface))
            }
        }
        .padding(40)
    }

    // MARK: - Live Stage

    private var liveStage: some View {
        GeometryReader { _ in
            ZStack {
                AeroCastDisplayView(layer: engine.displayLayer)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 24, y: 10)

                // Recording Indicator Badge (Top Left of Viewfinder)
                if engine.captureManager.currentMode.isRecording {
                    VStack {
                        HStack {
                            recordingBadge
                                .padding(.leading, 18)
                                .padding(.top, 18)
                            Spacer()
                        }
                        Spacer()
                    }
                }

                // Live Studio Audio Level Meter Overlay (Right Edge)
                HStack {
                    Spacer()
                    studioVUMeterOverlay
                        .padding(.trailing, 20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 64)
            .padding(.bottom, 94)
        }
    }

    // MARK: - Recording Badge

    private var recordingBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .shadow(color: .red.opacity(0.8), radius: 4)

            Text(isRecordingVideo ? "REC VIDEO" : "REC AUDIO")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(engine.captureManager.durationString)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)

            Text(String(format: "%.1f MB", engine.captureManager.recordedSizeMB))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(.floating)
    }

    // MARK: - Top HUD

    private var topHUD: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: .red.opacity(0.8), radius: 4)

                Text("STUDIO LIVE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(1.1)
                    .foregroundStyle(.white)
            }

            Divider().frame(height: 12).overlay(Color.white.opacity(0.2))

            hudChip(value: "\(engine.selectedResolution) @ \(engine.selectedFPS)p", label: "format")
            hudChip(value: String(format: "%.0f", engine.measuredFPS), label: "fps")
            hudChip(value: bitrateText(engine.videoBitrate), label: "video")

            // BoomAudio Output indicator chip
            HStack(spacing: 5) {
                Circle()
                    .fill(engine.audioRouter.isVirtualMicPumping ? Color.dhAccentMint : Color.gray)
                    .frame(width: 6, height: 6)
                VStack(spacing: 1) {
                    Text("BoomAudio")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.dhAccentMint)
                    Text("VIRTUAL MIC")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 6)

            hudChip(value: String(format: "%.0f ms", engine.latencyMs), label: "latency")

            if engine.isAudioClipping {
                Text("CLIP")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(.floating)
        .foregroundStyle(.white)
    }

    private func hudChip(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 7.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(minWidth: 42)
    }

    private func bitrateText(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond > 1000 else { return "—" }
        return String(format: "%.1fM", bitsPerSecond / 1_000_000)
    }

    // MARK: - Dual Stereo Studio VU Meter

    private var studioVUMeterOverlay: some View {
        VStack(spacing: 8) {
            Text("STUDIO MIC")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: 6) {
                vuBar(peakDb: engine.audioPeakDbL, rmsDb: engine.audioRmsDbL, label: "L")
                vuBar(peakDb: engine.audioPeakDbR, rmsDb: engine.audioRmsDbR, label: "R")
            }
            .frame(height: 130)

            Text(String(format: "%.0f dB", max(engine.audioPeakDbL, engine.audioPeakDbR)))
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .glassSurface(.floating)
    }

    private func vuBar(peakDb: Float, rmsDb: Float, label: String) -> some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.12))

                    let heightFraction = CGFloat(max(0, (rmsDb + 60.0) / 60.0))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [.red, .yellow, .green],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: geo.size.height * heightFraction)

                    let peakFraction = CGFloat(max(0, (peakDb + 60.0) / 60.0))
                    Rectangle()
                        .fill(peakDb >= -0.5 ? Color.red : Color.white)
                        .frame(height: 2)
                        .offset(y: -geo.size.height * peakFraction)
                }
            }
            .frame(width: 8)

            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Bottom Controls Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Stop button
            Button {
                engine.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(Color.red.opacity(0.85)))
            .cursor(.interactive)
            .help("Stop studio feed")

            Divider().frame(height: 20).overlay(Color.white.opacity(0.15))

            // 1. Dynamic Lens Switcher Buttons (Ultra-Wide, Wide, Telephoto, Front)
            HStack(spacing: 5) {
                ForEach(StudioCamEngine.availableLenses) { lens in
                    let isSelected = engine.selectedLens == lens.id
                    Button {
                        engine.switchLens(to: lens.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: lens.systemImage)
                                .font(.system(size: 10, weight: .semibold))
                            Text(lens.title)
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .foregroundStyle(.white)
                        .glassSurface(.surface, highlighted: isSelected, tint: isSelected ? .dhAccentMint : nil)
                    }
                    .buttonStyle(.plain)
                    .help(lens.focalDescription)
                }
            }

            // 2. Continuous Zoom Slider Toggle & Preset Pills
            Button {
                withAnimation(Spatial.Motion.crisp) { showZoomSlider.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11))
                    Text(String(format: "%.1fx", engine.zoomRatio))
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .glassSurface(.surface, highlighted: showZoomSlider, tint: showZoomSlider ? .dhAccentMint : nil)
            }
            .buttonStyle(.plain)
            .help("Adjust camera zoom")

            if showZoomSlider {
                HStack(spacing: 6) {
                    Slider(value: Binding(
                        get: { Double(engine.zoomRatio) },
                        set: { engine.setZoomRatio(Float($0)) }
                    ), in: 0.5...10.0)
                    .frame(width: 90)
                    .controlSize(.mini)
                    .tint(Color.dhAccentMint)

                    ForEach([0.5, 1.0, 3.0, 5.0], id: \.self) { z in
                        Button(String(format: "%.1fx", z)) {
                            engine.setZoomRatio(Float(z))
                        }
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .scale))
            }

            // 3. Torch / Flashlight Button
            Button {
                engine.toggleTorch()
            } label: {
                Image(systemName: engine.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(engine.isTorchOn ? Color.yellow : .white.opacity(0.6))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Toggle phone camera flashlight")

            Divider().frame(height: 20).overlay(Color.white.opacity(0.15))

            // 4. Media Capture Controls: [Photo Snapshot], [Record Video], [Record Audio Alone]
            HStack(spacing: 8) {
                // Shutter Button (Photo Snapshot)
                Button {
                    engine.captureManager.captureSnapshot(from: engine.latestPixelBuffer)
                } label: {
                    Image(systemName: "camera.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.dhAccentMint)
                }
                .buttonStyle(.plain)
                .help("Capture high-resolution photo snapshot (Cmd+S)")

                // Record Video Button
                Button {
                    if case .recordingVideo = engine.captureManager.currentMode {
                        engine.captureManager.stopVideoRecording()
                    } else {
                        engine.captureManager.startVideoRecording(
                            width: engine.selectedResolution == "4K" ? 3840 : 1920,
                            height: engine.selectedResolution == "4K" ? 2160 : 1080,
                            fps: engine.selectedFPS
                        )
                    }
                } label: {
                    Image(systemName: isRecordingVideo ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(isRecordingVideo ? Color.red : .white)
                }
                .buttonStyle(.plain)
                .help(isRecordingVideo ? "Stop video recording" : "Record 60 FPS video with studio audio")

                // Record Audio Alone Button
                Button {
                    if case .recordingAudio = engine.captureManager.currentMode {
                        engine.captureManager.stopAudioOnlyRecording()
                    } else {
                        engine.captureManager.startAudioOnlyRecording()
                    }
                } label: {
                    Image(systemName: isRecordingAudio ? "waveform.circle" : "waveform.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(isRecordingAudio ? Color.purple : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(isRecordingAudio ? "Stop audio recording" : "Record uncompressed 48 kHz studio audio alone (WAV)")
            }

            Divider().frame(height: 20).overlay(Color.white.opacity(0.15))

            // 5. Speaker Monitor Toggle
            Button {
                withAnimation(Spatial.Motion.crisp) { engine.audioRouter.isMonitorEnabled.toggle() }
            } label: {
                Image(systemName: engine.audioRouter.isMonitorEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(engine.audioRouter.isMonitorEnabled ? Color.dhAccentMint : .white.opacity(0.5))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(engine.audioRouter.isMonitorEnabled ? "Mute Mac speakers (Virtual mic keeps streaming)" : "Listen to phone mic on Mac speakers")

            if engine.audioRouter.isMonitorEnabled {
                Slider(value: $engine.audioRouter.monitorVolume, in: 0...1)
                    .frame(width: 70)
                    .controlSize(.mini)
                    .tint(Color.dhAccentMint)
            }

            // Settings Sheet Button
            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Studio broadcast & BoomAudio routing settings")

            // System Guide
            Button {
                showSystemInputGuide = true
            } label: {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Mac system input device guide")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(.floating)
    }

    private var isRecordingVideo: Bool {
        if case .recordingVideo = engine.captureManager.currentMode { return true }
        return false
    }

    private var isRecordingAudio: Bool {
        if case .recordingAudio = engine.captureManager.currentMode { return true }
        return false
    }

    // MARK: - Capture Toast

    private func captureToast(_ message: String) -> some View {
        HStack(spacing: 12) {
            if let thumb = engine.captureManager.lastSavedThumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.dhAccentMint)
            }

            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)

            if engine.captureManager.lastSavedURL != nil {
                Button("Show in Finder") {
                    engine.captureManager.revealLastSavedInFinder()
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dhAccentMint)
                .buttonStyle(.plain)
            }

            Button {
                engine.captureManager.toastNotification = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(.floating)
    }

    // MARK: - Settings & System Input Sheets

    private var studioSettingsSheet: some View {
        VStack(spacing: 20) {
            Text("Studio Broadcast & Audio Routing")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Form {
                Section("Target Virtual Mic (macOS Input)") {
                    Picker("Device", selection: $engine.audioRouter.selectedDeviceID) {
                        ForEach(engine.audioRouter.availableOutputDevices) { dev in
                            Text(dev.isBoomAudio ? "★ \(dev.name) (Virtual Mic)" : dev.name)
                                .tag(dev.id as AudioDeviceID?)
                        }
                    }

                    Toggle("Route phone mic to selected virtual device", isOn: $engine.audioRouter.isVirtualMicRoutingActive)
                        .help("Pumps uncompressed 48 kHz PCM directly into BoomAudio so macOS apps hear your phone microphone.")
                }

                Section("Video Stream") {
                    Picker("Resolution", selection: $engine.selectedResolution) {
                        Text("1080p (Full HD)").tag("1080p")
                        Text("4K (Ultra HD)").tag("4K")
                        Text("720p (HD)").tag("720p")
                    }

                    Picker("Framerate", selection: $engine.selectedFPS) {
                        Text("60 FPS (Ultra Smooth)").tag(60)
                        Text("30 FPS").tag(30)
                    }

                    Toggle("Pure Unprocessed Studio Audio", isOn: $engine.unprocessedMic)
                        .help("Captures raw microphone capsule audio without Android noise suppression or AGC.")
                }
            }
            .formStyle(.grouped)

            Button("Done") { showSettingsSheet = false }
                .buttonStyle(SpatialButtonStyle(depth: .surface))
        }
        .padding(24)
        .frame(width: 480, height: 380)
        .background(Color.black.opacity(0.94))
    }

    private var systemInputGuideSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.dhAccentMint)
                Text("Using as Native Mac Input")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Close") { showSystemInputGuide = false }
                    .buttonStyle(.plain)
            }

            Text("DroidHouse streams phone camera & studio microphone into your Mac with zero lag:")
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.75))

            VStack(alignment: .leading, spacing: 14) {
                guideItem(
                    step: "1",
                    title: "BoomAudio Microphone Routing (Active)",
                    description: "DroidHouse automatically streams 48 kHz stereo PCM into BoomAudio. In System Settings → Sound → Input (or Zoom/Teams/Meet/Discord settings), select 'BoomAudio'. The microphone detects and transmits audio instantly!"
                )

                guideItem(
                    step: "2",
                    title: "Hardware Camera & Lens Switching",
                    description: "Switch seamlessly between 0.5x Ultra-Wide, 1.0x Main Lens, and 3.0x Telephoto. Use the zoom slider up to 10x and toggle phone flashlight on the fly."
                )

                guideItem(
                    step: "3",
                    title: "Native Mac Recording & Snapshots",
                    description: "Snap instant high-resolution photos (saved to Pictures/DroidHouse), record 60 FPS video with synced audio (Movies/DroidHouse), or record studio WAV audio alone (Music/DroidHouse)."
                )

                guideItem(
                    step: "4",
                    title: "Virtual Webcam for OBS & QuickTime",
                    description: "Select 'DroidHouse Studio Window' in OBS or use the CoreMediaIO camera extension. Live 60 FPS frames are decoded via VideoToolbox hardware acceleration."
                )
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 540, height: 460)
        .background(Color.black.opacity(0.95))
    }

    private func guideItem(step: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(step)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.dhAccentMint.opacity(0.2)))
                .foregroundStyle(Color.dhAccentMint)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }
}
