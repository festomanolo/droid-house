import SwiftUI
import AVFoundation
import AppKit

// MARK: - Display surface

/// Hosts the engine's `AVSampleBufferDisplayLayer` inside SwiftUI. The layer is
/// owned by the engine, so the mirror survives every view rebuild.
struct AeroCastDisplayView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = LayerHostView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.hosted = layer
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? LayerHostView else { return }
        if host.hosted !== layer {
            host.hosted?.removeFromSuperlayer()
            host.hosted = layer
            host.layer?.addSublayer(layer)
        }
        host.layoutHostedLayer()
    }

    final class LayerHostView: NSView {
        var hosted: AVSampleBufferDisplayLayer?

        override func layout() {
            super.layout()
            layoutHostedLayer()
        }

        func layoutHostedLayer() {
            // Resizing a video layer through implicit animation produces a
            // visible smear, so the frame change is applied without one.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - AeroCast pane

struct AeroCastView: View {
    @ObservedObject var adbService: ADBService
    @StateObject private var engine = AeroCastEngine()

    @StateObject private var controller = AeroCastController()

    @State private var isHoveringStage = false
    @State private var showsControls = true
    @State private var controlHideWorkItem: DispatchWorkItem?

    /// Whether clicks and keys are forwarded to the phone.
    @AppStorage("aerocast.controlEnabled") private var isControlEnabled = true

    @State private var hoverInsideScreen = false
    @State private var dragStart: CGPoint?
    @State private var dragStartedAt: Date?
    @State private var isKeyboardCaptured = false

    @Namespace private var castNamespace

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch engine.state {
            case .idle:
                idleStage
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .preparing(let message):
                preparingStage(message)
                    .transition(.opacity)
            case .failed(let message):
                failureStage(message)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .streaming:
                liveStage
                    .transition(.opacity)
            }
        }
        .animation(Spatial.Motion.cinematic, value: engine.state)
        .overlay(alignment: .top) {
            if engine.state.isLive && showsControls {
                liveHUD
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if engine.state.isLive && showsControls {
                VStack(spacing: 9) {
                    navigationBar
                    transportBar
                }
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Spatial.Motion.fluid, value: showsControls)
        .onHover { hovering in
            isHoveringStage = hovering
            revealControls()
        }
        // Keys go to the phone only while it's actually mirroring, control is
        // on, and this window is key — otherwise typing anywhere in DroidHouse
        // would leak to the device.
        .captureKeys(enabled: engine.state.isLive && isControlEnabled && isKeyboardCaptured) { event in
            controller.handleKeyEvent(event)
        }
        .onDisappear {
            engine.stop()
            controller.detach()
        }
        .onChange(of: engine.state) { _, newState in
            Task {
                if newState.isLive, let serial = adbService.selectedDevice?.id {
                    await controller.attach(serial: serial)
                } else {
                    controller.detach()
                }
            }
        }
        .onChange(of: adbService.selectedDevice?.id) { _, _ in
            if engine.state.isLive { engine.stop() }
            controller.detach()
        }
    }

    // MARK: Idle

    private var idleStage: some View {
        VStack(spacing: 22) {
            // A slow, breathing bloom behind the glyph so an idle screen still
            // feels alive.
            PhaseAnimator([0.0, 1.0], trigger: engine.state) { phase in
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.dhAccentViolet.opacity(0.35), .clear],
                                center: .center,
                                startRadius: 4,
                                endRadius: 110
                            )
                        )
                        .frame(width: 220, height: 220)
                        .scaleEffect(0.85 + phase * 0.25)
                        .opacity(0.55 + phase * 0.45)

                    Image(systemName: "airplayvideo")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.white, Color.dhAccentViolet],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .scaleEffect(1 + phase * 0.04)
                }
            } animation: { _ in
                .easeInOut(duration: 2.4)
            }

            VStack(spacing: 7) {
                Text("AeroCast")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .matchedGeometryEffect(id: "aerocast-title", in: castNamespace)

                Text("Mirror your device's screen and audio straight into this window.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            sourcePicker

            Button {
                guard let serial = adbService.selectedDevice?.id else { return }
                engine.start(serial: serial)
            } label: {
                Label("Start Casting", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(
                SpatialButtonStyle(
                    depth: .floating,
                    tint: .dhAccentViolet,
                    padding: EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
                )
            )
            .disabled(adbService.selectedDevice == nil)

            if adbService.selectedDevice == nil {
                Label("Connect a device to begin", systemImage: "iphone.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(40)
    }

    private var sourcePicker: some View {
        HStack(spacing: 10) {
            ForEach(AeroCastEngine.Source.allCases) { option in
                let isSelected = engine.source == option
                Button {
                    withAnimation(Spatial.Motion.crisp) { engine.source = option }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(option.rawValue, systemImage: option.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(option.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(.white)
                    .frame(width: 172, alignment: .leading)
                    .padding(11)
                    .glassSurface(.surface, highlighted: isSelected,
                                  tint: isSelected ? .dhAccentViolet : nil)
                }
                .buttonStyle(.plain)
                .cursor(.interactive)
                .scaleEffect(isSelected ? 1.0 : 0.97)
                .opacity(isSelected ? 1 : 0.72)
                .animation(Spatial.Motion.crisp, value: isSelected)
            }
        }
    }

    // MARK: Preparing

    private func preparingStage(_ message: String) -> some View {
        VStack(spacing: 18) {
            // Three dots stepping through discrete phases — a PhaseAnimator is
            // the right tool here precisely because the states are discrete.
            PhaseAnimator([0, 1, 2], trigger: message) { active in
                HStack(spacing: 9) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(index == active ? Color.dhAccentViolet : Color.white.opacity(0.25))
                            .frame(width: 9, height: 9)
                            .scaleEffect(index == active ? 1.45 : 1.0)
                    }
                }
            } animation: { _ in
                .spring(response: 0.34, dampingFraction: 0.55)
            }

            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .contentTransition(.opacity)

            if engine.source == .companion {
                Text("Approve the screen-capture prompt on your phone if it appears.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Button("Cancel") { engine.stop() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .cursor(.interactive)
        }
        .padding(40)
    }

    // MARK: Failure

    private func failureStage(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.orange)

            Text("AeroCast stopped")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    guard let serial = adbService.selectedDevice?.id else { return }
                    engine.start(serial: serial)
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(SpatialButtonStyle(depth: .floating, tint: .dhAccentViolet))

                Button {
                    withAnimation(Spatial.Motion.fluid) {
                        engine.source = engine.source == .companion ? .screenRecord : .companion
                        engine.stop()
                    }
                } label: {
                    Text("Switch to \(engine.source == .companion ? "ADB Direct" : "Companion")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
                .buttonStyle(SpatialButtonStyle(depth: .surface))
            }
        }
        .padding(40)
    }

    // MARK: Live

    private var liveStage: some View {
        GeometryReader { geo in
            let aspect = aspectRatio
            let fitted = fittedSize(in: geo.size, aspect: aspect)

            ZStack {
                AeroCastDisplayView(layer: engine.displayLayer)
                    .frame(width: fitted.width, height: fitted.height)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                isControlEnabled
                                    ? Color.dhAccentMint.opacity(0.35)
                                    : Color.white.opacity(0.12),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
                    .cursor(isControlEnabled ? .interactive : .crosshair)
                    // Pointer control: coordinates are normalised against the
                    // fitted rect here, so the controller never needs to know
                    // anything about window size or letterboxing.
                    .gesture(controlDragGesture(in: fitted))
                    .onContinuousHover { phase in
                        if case .active = phase { hoverInsideScreen = true }
                        else { hoverInsideScreen = false }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Scroll wheel → flick, aimed at the middle of the screen.
            .onScrollWheel(enabled: isControlEnabled && hoverInsideScreen) { deltaY in
                controller.scroll(atNormalised: CGPoint(x: 0.5, y: 0.5), deltaY: deltaY)
            }
        }
        .padding(28)
    }

    /// Drag doubles as tap: a press-and-release that never travels becomes a
    /// tap, anything further becomes a swipe of the matching duration.
    private func controlDragGesture(in fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isControlEnabled else { return }
                if dragStart == nil {
                    dragStart = value.startLocation
                    dragStartedAt = Date()
                }
            }
            .onEnded { value in
                guard isControlEnabled else { return }
                defer { dragStart = nil; dragStartedAt = nil }

                let start = normalise(value.startLocation, in: fitted)
                let end = normalise(value.location, in: fitted)

                let travel = hypot(
                    value.location.x - value.startLocation.x,
                    value.location.y - value.startLocation.y
                )
                let elapsedMs = Int((Date().timeIntervalSince(dragStartedAt ?? Date())) * 1000)

                if travel < 6 {
                    if elapsedMs > 550 {
                        controller.longPress(atNormalised: start, milliseconds: elapsedMs)
                    } else {
                        controller.tap(atNormalised: start)
                    }
                } else {
                    controller.swipe(
                        fromNormalised: start,
                        toNormalised: end,
                        milliseconds: max(60, min(1200, elapsedMs))
                    )
                }
            }
    }

    /// View point → 0...1 within the video rect.
    private func normalise(_ point: CGPoint, in fitted: CGSize) -> CGPoint {
        guard fitted.width > 0, fitted.height > 0 else { return .zero }
        return CGPoint(
            x: min(1, max(0, point.x / fitted.width)),
            y: min(1, max(0, point.y / fitted.height))
        )
    }

    private var aspectRatio: CGFloat {
        guard let info = engine.streamInfo, info.width > 0, info.height > 0 else {
            return 1080.0 / 2400.0
        }
        return CGFloat(info.width) / CGFloat(info.height)
    }

    private func fittedSize(in container: CGSize, aspect: CGFloat) -> CGSize {
        guard container.width > 0, container.height > 0, aspect > 0 else { return .zero }
        let byWidth = CGSize(width: container.width, height: container.width / aspect)
        if byWidth.height <= container.height { return byWidth }
        return CGSize(width: container.height * aspect, height: container.height)
    }

    // MARK: HUD

    private var liveHUD: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                // Steady heartbeat proving frames are still arriving.
                PhaseAnimator([false, true], trigger: engine.framesDecoded / 30) { on in
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                        .shadow(color: .green.opacity(on ? 0.9 : 0.2), radius: on ? 5 : 1)
                        .scaleEffect(on ? 1.2 : 1.0)
                } animation: { _ in
                    .easeInOut(duration: 0.55)
                }

                Text("LIVE")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .kerning(1.1)
                    .foregroundStyle(.white)
            }

            Divider().frame(height: 12).overlay(Color.white.opacity(0.2))

            statChip(value: resolutionText, label: "res")
            statChip(value: String(format: "%.0f", engine.measuredFPS), label: "fps")
            statChip(value: bitrateText(engine.videoBitrate), label: "video")

            if engine.isAudioActive {
                statChip(value: bitrateText(engine.audioBitrate), label: "audio")
            }

            statChip(value: String(format: "%.0f ms", engine.latencyMs), label: "lag")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassSurface(.floating)
        .foregroundStyle(.white)
    }

    private func statChip(value: String, label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label.uppercased())
                .font(.system(size: 7.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(minWidth: 42)
    }

    private var resolutionText: String {
        guard let info = engine.streamInfo, info.width > 0 else { return "—" }
        return "\(info.width)×\(info.height)"
    }

    private func bitrateText(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond > 1000 else { return "—" }
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1fM", bitsPerSecond / 1_000_000)
        }
        return String(format: "%.0fK", bitsPerSecond / 1000)
    }

    // MARK: Device control

    /// The phone's own navigation keys, mirrored as a hardware-style bar.
    private var navigationBar: some View {
        HStack(spacing: 10) {
            ForEach(
                [AeroCastController.NavigationKey.back,
                 .home,
                 .recents,
                 .volumeDown,
                 .volumeUp,
                 .power],
                id: \.id
            ) { key in
                Button {
                    controller.press(key)
                } label: {
                    Image(systemName: key.systemImage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(isControlEnabled ? 0.95 : 0.35))
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.plain)
                .cursor(isControlEnabled ? .interactive : .disallowed)
                .disabled(!isControlEnabled || !controller.isReady)
                .help(key.label)
            }

            Divider().frame(height: 18).overlay(Color.white.opacity(0.15))

            Button {
                withAnimation(Spatial.Motion.crisp) { isKeyboardCaptured.toggle() }
            } label: {
                Image(systemName: isKeyboardCaptured ? "keyboard.fill" : "keyboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isKeyboardCaptured ? Color.dhAccentMint : .white.opacity(0.7))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .cursor(.interactive)
            .disabled(!isControlEnabled)
            .help(isKeyboardCaptured
                  ? "Keyboard is going to the phone — click to release"
                  : "Send keystrokes to the phone")

            Button {
                withAnimation(Spatial.Motion.crisp) {
                    isControlEnabled.toggle()
                    if !isControlEnabled { isKeyboardCaptured = false }
                }
            } label: {
                Image(systemName: isControlEnabled ? "cursorarrow.click.2" : "cursorarrow.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isControlEnabled ? Color.dhAccentMint : .white.opacity(0.5))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.plain)
            .cursor(.interactive)
            .help(isControlEnabled ? "Disable touch control" : "Enable touch control")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassSurface(.floating)
    }

    // MARK: Transport

    private var transportBar: some View {
        HStack(spacing: 16) {
            Button {
                engine.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(Color.red.opacity(0.85)))
            .cursor(.interactive)
            .help("Stop casting")

            Divider().frame(height: 20).overlay(Color.white.opacity(0.15))

            Button {
                withAnimation(Spatial.Motion.crisp) { engine.isAudioEnabled.toggle() }
            } label: {
                Image(systemName: engine.isAudioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(engine.isAudioEnabled ? .white : .white.opacity(0.45))
                    .frame(width: 26, height: 26)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .cursor(.interactive)
            .help(engine.isAudioEnabled ? "Mute device audio" : "Unmute device audio")

            Slider(value: $engine.volume, in: 0...1)
                .frame(width: 110)
                .controlSize(.mini)
                .disabled(!engine.isAudioEnabled)
                .tint(.white)

            Divider().frame(height: 20).overlay(Color.white.opacity(0.15))

            Label(engine.source.rawValue, systemImage: engine.source.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(.floating)
    }

    // MARK: Control auto-hide

    private func revealControls() {
        controlHideWorkItem?.cancel()
        withAnimation(Spatial.Motion.fluid) { showsControls = true }

        guard engine.state.isLive else { return }

        let work = DispatchWorkItem {
            withAnimation(Spatial.Motion.fluid) { showsControls = false }
        }
        controlHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }
}
