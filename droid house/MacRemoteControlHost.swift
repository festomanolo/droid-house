import Foundation
import Network
import CoreGraphics
import AppKit
import Combine

// MARK: - Mac Remote Control Host Service
//
// Manages the secure WebSocket listener on macOS (port 8089) that accepts remote
// input commands from the DroidHouse Android companion app over WAN (Tailscale/Internet)
// or local LAN, synthesizes native CoreGraphics events (mouse, keyboard, shortcuts),
// executes system controls (media, volume, lock, sleep), and streams compressed
// live screen frames with sub-50ms latency.

public final class MacRemoteControlHost: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var isRunning = false
    @Published public private(set) var port: UInt16 = MacRemoteProtocol.defaultPort
    @Published public private(set) var pairingPin: String = ""
    @Published public private(set) var connectedClientName: String?
    @Published public private(set) var connectedClientIP: String?
    @Published public private(set) var isClientAuthenticated = false
    @Published public private(set) var isScreenStreaming = false
    @Published public private(set) var roundTripLatencyMs: Double = 0
    @Published public private(set) var recentEvents: [String] = []

    @Published public private(set) var localIPAddress: String = "Detecting…"
    @Published public private(set) var tailscaleIPAddress: String?
    @Published public private(set) var publicWANIPAddress: String?

    @Published public private(set) var isAccessibilityGranted: Bool = false
    @Published public private(set) var isScreenCaptureGranted: Bool = false

    // MARK: - Configuration

    @Published public var streamFps: Int = 20
    @Published public var streamQuality: Double = 0.55
    @Published public var streamScale: Double = 0.70

    // MARK: - Private State

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var screenStreamTimer: Timer?
    private var cursorMonitorTimer: Timer?
    private var permissionPollTimer: Timer?
    private var lastSentCursorPos: CGPoint = .zero
    private var isMouseDownState: Bool = false
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    private let networkQueue = DispatchQueue(label: "com.droidhouse.remote.network", qos: .userInteractive)
    private let screenQueue = DispatchQueue(label: "com.droidhouse.remote.screen", qos: .userInitiated)

    public static let shared = MacRemoteControlHost()

    public init() {
        loadOrGeneratePin()
        refreshNetworkAddresses()
        checkPermissions()
        startPermissionPolling()
    }

    deinit {
        screenStreamTimer?.invalidate()
        cursorMonitorTimer?.invalidate()
        permissionPollTimer?.invalidate()
        listener?.cancel()
        activeConnection?.cancel()
    }

    // MARK: - Server Lifecycle

    public func startServer(port: UInt16 = MacRemoteProtocol.defaultPort) {
        guard !isRunning else { return }
        self.port = port

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 5

            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true

            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                logEvent("Invalid port: \(port)")
                return
            }

            let listener = try NWListener(using: parameters, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.logEvent("Remote host listening on port \(port)")
                    case .failed(let error):
                        self?.isRunning = false
                        self?.logEvent("Remote host failed: \(error.localizedDescription)")
                    case .cancelled:
                        self?.isRunning = false
                        self?.logEvent("Remote host stopped")
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener.start(queue: networkQueue)
            self.listener = listener
            refreshNetworkAddresses()
        } catch {
            logEvent("Failed to start remote listener: \(error.localizedDescription)")
        }
    }

    public func stopServer() {
        stopScreenStreaming()
        stopCursorMonitoring()
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.connectedClientName = nil
            self.connectedClientIP = nil
            self.isClientAuthenticated = false
        }
        logEvent("Remote host stopped")
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        // Disconnect previous unauthenticated client if any
        if let existing = activeConnection {
            existing.cancel()
        }

        activeConnection = connection

        let endpointDesc = connection.endpoint.debugDescription
        let clientIP = extractIP(from: endpointDesc)

        DispatchQueue.main.async {
            self.isClientAuthenticated = false
            self.connectedClientIP = clientIP
            self.connectedClientName = "Connecting…"
            self.logEvent("New connection from \(clientIP)")
        }

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self = self, let connection = connection, self.activeConnection === connection else { return }
            switch state {
            case .ready:
                self.logEvent("Client socket ready, awaiting PIN auth")
                self.receiveNextMessage(from: connection)
            case .failed(let error):
                self.logEvent("Client disconnected: \(error.localizedDescription)")
                self.handleClientDisconnect()
            case .cancelled:
                self.logEvent("Client connection closed")
                self.handleClientDisconnect()
            default:
                break
            }
        }

        connection.start(queue: networkQueue)
    }

    private func handleClientDisconnect() {
        stopScreenStreaming()
        stopCursorMonitoring()
        activeConnection = nil
        DispatchQueue.main.async {
            self.connectedClientName = nil
            self.connectedClientIP = nil
            self.isClientAuthenticated = false
            self.roundTripLatencyMs = 0
        }
    }

    private func extractIP(from endpointStr: String) -> String {
        let components = endpointStr.split(separator: ":")
        if let first = components.first {
            return String(first).trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\n"))
        }
        return endpointStr
    }

    // MARK: - Message Loop

    private func receiveNextMessage(from connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, context, isComplete, error in
            guard let self = self, let connection = connection, self.activeConnection === connection else { return }

            if let error = error {
                self.logEvent("Receive error: \(error.localizedDescription)")
                self.handleClientDisconnect()
                return
            }

            if let content = content, !content.isEmpty {
                self.processInboundData(content, from: connection)
            }

            // Loop to receive next message
            self.receiveNextMessage(from: connection)
        }
    }

    private func processInboundData(_ data: Data, from connection: NWConnection) {
        guard let envelope = try? jsonDecoder.decode(MacRemoteProtocol.InboundEnvelope.self, from: data) else {
            return
        }

        handleEnvelope(envelope, from: connection)
    }

    private func handleEnvelope(_ envelope: MacRemoteProtocol.InboundEnvelope, from connection: NWConnection) {
        // Authentication check
        if !isClientAuthenticated {
            if envelope.type == "auth" {
                if let pin = envelope.pin, pin == self.pairingPin {
                    let clientName = envelope.deviceName ?? "Android Companion"
                    DispatchQueue.main.async {
                        self.isClientAuthenticated = true
                        self.connectedClientName = clientName
                        self.logEvent("Authenticated successfully: \(clientName)")
                    }

                    let displayID = CGMainDisplayID()
                    let width = Double(CGDisplayPixelsWide(displayID))
                    let height = Double(CGDisplayPixelsHigh(displayID))
                    let hostName = Host.current().localizedName ?? "Mac"

                    let response = MacRemoteProtocol.OutboundEnvelope(
                        type: "auth_ok",
                        success: true,
                        message: "Authentication successful",
                        macName: hostName,
                        screenWidth: width,
                        screenHeight: height,
                        version: MacRemoteProtocol.protocolVersion,
                        timestamp: Date().timeIntervalSince1970,
                        accessibilityGranted: isAccessibilityGranted,
                        screenCaptureGranted: isScreenCaptureGranted
                    )
                    sendMessage(response)
                    self.startCursorMonitoring()
                    self.broadcastCurrentCursor(force: true)
                } else {
                    logEvent("Authentication failed: Invalid PIN '\(envelope.pin ?? "")'")
                    let failResponse = MacRemoteProtocol.OutboundEnvelope(
                        type: "auth_fail",
                        success: false,
                        message: "Invalid pairing PIN"
                    )
                    sendMessage(failResponse)
                    connection.cancel()
                    handleClientDisconnect()
                }
            }
            return
        }

        // Process authenticated commands
        switch envelope.type {
        case "ping":
            let pong = MacRemoteProtocol.OutboundEnvelope(
                type: "pong",
                timestamp: Date().timeIntervalSince1970,
                pingId: envelope.timestamp
            )
            sendMessage(pong)

        case "pong_rtt":
            if let sentTime = envelope.timestamp {
                let rtt = (Date().timeIntervalSince1970 - sentTime) * 1000.0
                DispatchQueue.main.async {
                    self.roundTripLatencyMs = max(1.0, rtt)
                }
            }

        case "mouse_move":
            if let dx = envelope.dx, let dy = envelope.dy {
                synthesizeMouseMove(dx: CGFloat(dx), dy: CGFloat(dy))
            }

        case "mouse_move_abs":
            if let xRatio = envelope.xRatio, let yRatio = envelope.yRatio {
                synthesizeMouseMoveAbs(xRatio: CGFloat(xRatio), yRatio: CGFloat(yRatio))
            }

        case "mouse_click":
            let btn = MacRemoteProtocol.MouseButton(rawValue: envelope.button ?? "left") ?? .left
            synthesizeMouseClick(button: btn)

        case "mouse_double_click":
            synthesizeMouseDoubleClick()

        case "mouse_down":
            let btn = MacRemoteProtocol.MouseButton(rawValue: envelope.button ?? "left") ?? .left
            synthesizeMouseDown(button: btn)

        case "mouse_up":
            let btn = MacRemoteProtocol.MouseButton(rawValue: envelope.button ?? "left") ?? .left
            synthesizeMouseUp(button: btn)

        case "mouse_scroll":
            let dx = envelope.dx ?? 0
            let dy = envelope.dy ?? 0
            synthesizeScroll(dx: CGFloat(dx), dy: CGFloat(dy))

        case "key_text":
            if let text = envelope.text, !text.isEmpty {
                synthesizeKeyText(text)
                logEvent("Typed: \"\(text.prefix(20))\"")
            }

        case "key_press":
            if let keyCode = envelope.keyCode, let keyDown = envelope.keyDown {
                synthesizeKeyCode(keyCode, keyDown: keyDown)
            }

        case "key_combo":
            if let combo = envelope.combo {
                synthesizeKeyCombo(combo)
                logEvent("Shortcut: \(combo)")
            }

        case "system_action":
            if let action = envelope.action {
                executeSystemAction(action)
                logEvent("Action: \(action)")
            }

        case "screen_stream":
            if let enabled = envelope.enabled {
                DispatchQueue.main.async {
                    if let fps = envelope.fps { self.streamFps = max(5, min(60, fps)) }
                    if let quality = envelope.quality { self.streamQuality = max(0.2, min(0.9, quality)) }
                    if let scale = envelope.scale { self.streamScale = max(0.3, min(1.0, scale)) }
                }

                if enabled {
                    startScreenStreaming()
                } else {
                    stopScreenStreaming()
                }
            }

        case "request_frame":
            captureAndSendSingleFrame()

        default:
            break
        }
    }

    public func sendMessage(_ envelope: MacRemoteProtocol.OutboundEnvelope) {
        guard let connection = activeConnection,
              let data = try? jsonEncoder.encode(envelope) else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    public func sendBinaryData(_ data: Data) {
        guard let connection = activeConnection else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    // MARK: - CoreGraphics Event Synthesis

    public func synthesizeMouseMove(dx: CGFloat, dy: CGFloat) {
        guard let currentEvent = CGEvent(source: nil) else { return }
        var currentLoc = currentEvent.location
        let mainDisplay = CGMainDisplayID()
        let screenBounds = CGDisplayBounds(mainDisplay)

        currentLoc.x = min(max(currentLoc.x + dx, screenBounds.minX), screenBounds.maxX - 1)
        currentLoc.y = min(max(currentLoc.y + dy, screenBounds.minY), screenBounds.maxY - 1)

        let moveType: CGEventType = isMouseDownState ? .leftMouseDragged : .mouseMoved
        let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: moveType,
            mouseCursorPosition: currentLoc,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)
        broadcastCurrentCursor(force: true)
    }

    public func synthesizeMouseMoveAbs(xRatio: CGFloat, yRatio: CGFloat) {
        let mainDisplay = CGMainDisplayID()
        let screenBounds = CGDisplayBounds(mainDisplay)

        let targetX = screenBounds.minX + (screenBounds.width * min(max(xRatio, 0.0), 1.0))
        let targetY = screenBounds.minY + (screenBounds.height * min(max(yRatio, 0.0), 1.0))
        let targetPoint = CGPoint(x: targetX, y: targetY)

        let moveType: CGEventType = isMouseDownState ? .leftMouseDragged : .mouseMoved
        let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: moveType,
            mouseCursorPosition: targetPoint,
            mouseButton: .left
        )
        moveEvent?.post(tap: .cghidEventTap)
        broadcastCurrentCursor(force: true)
    }

    public func synthesizeMouseClick(button: MacRemoteProtocol.MouseButton) {
        guard let currentEvent = CGEvent(source: nil) else { return }
        let currentLoc = currentEvent.location

        let downType: CGEventType
        let upType: CGEventType
        let cgButton: CGMouseButton

        switch button {
        case .left:
            downType = .leftMouseDown
            upType = .leftMouseUp
            cgButton = .left
        case .right:
            downType = .rightMouseDown
            upType = .rightMouseUp
            cgButton = .right
        case .middle:
            downType = .otherMouseDown
            upType = .otherMouseUp
            cgButton = .center
        }

        let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: currentLoc, mouseButton: cgButton)
        let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: currentLoc, mouseButton: cgButton)

        downEvent?.post(tap: .cghidEventTap)
        usleep(15_000) // 15ms click duration
        upEvent?.post(tap: .cghidEventTap)
        broadcastCurrentCursor(force: true)
    }

    public func synthesizeMouseDoubleClick() {
        guard let currentEvent = CGEvent(source: nil) else { return }
        let currentLoc = currentEvent.location

        for click in 1...2 {
            let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: currentLoc, mouseButton: .left)
            let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: currentLoc, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(click))

            down?.post(tap: .cghidEventTap)
            usleep(10_000)
            up?.post(tap: .cghidEventTap)
            if click == 1 { usleep(30_000) }
        }
        broadcastCurrentCursor(force: true)
    }

    public func synthesizeMouseDown(button: MacRemoteProtocol.MouseButton) {
        guard let currentEvent = CGEvent(source: nil) else { return }
        let currentLoc = currentEvent.location

        if button == .left { isMouseDownState = true }
        let (type, cgButton) = button == .right ? (CGEventType.rightMouseDown, CGMouseButton.right) : (CGEventType.leftMouseDown, CGMouseButton.left)
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: currentLoc, mouseButton: cgButton)
        event?.post(tap: .cghidEventTap)
        broadcastCurrentCursor(force: true)
    }

    public func synthesizeMouseUp(button: MacRemoteProtocol.MouseButton) {
        guard let currentEvent = CGEvent(source: nil) else { return }
        let currentLoc = currentEvent.location

        if button == .left { isMouseDownState = false }
        let (type, cgButton) = button == .right ? (CGEventType.rightMouseUp, CGMouseButton.right) : (CGEventType.leftMouseUp, CGMouseButton.left)
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: currentLoc, mouseButton: cgButton)
        event?.post(tap: .cghidEventTap)
        broadcastCurrentCursor(force: true)
    }

    public func synthesizeScroll(dx: CGFloat, dy: CGFloat) {
        // macOS natural scroll orientation: dy positive moves document up (wheel down)
        let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy),
            wheel2: Int32(dx),
            wheel3: 0
        )
        scrollEvent?.post(tap: .cghidEventTap)
    }

    public func synthesizeKeyText(_ text: String) {
        for char in text.utf16 {
            var unicodeChar = char
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicodeChar)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicodeChar)
            up?.post(tap: .cghidEventTap)
        }
    }

    public func synthesizeKeyCode(_ keyCode: UInt16, keyDown: Bool) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        event?.post(tap: .cghidEventTap)
    }

    public func synthesizeKeyCombo(_ comboName: String) {
        guard let combo = MacRemoteProtocol.KeyCombo(rawValue: comboName) else { return }

        switch combo {
        case .spotlight:
            // Cmd + Space (keyCode 49 = space)
            pressKeyWithFlags(keyCode: 49, flags: .maskCommand)
        case .appSwitcher:
            // Cmd + Tab (keyCode 48 = tab)
            pressKeyWithFlags(keyCode: 48, flags: .maskCommand)
        case .copy:
            // Cmd + C (keyCode 8 = c)
            pressKeyWithFlags(keyCode: 8, flags: .maskCommand)
        case .paste:
            // Cmd + V (keyCode 9 = v)
            pressKeyWithFlags(keyCode: 9, flags: .maskCommand)
        case .undo:
            // Cmd + Z (keyCode 6 = z)
            pressKeyWithFlags(keyCode: 6, flags: .maskCommand)
        case .selectAll:
            // Cmd + A (keyCode 0 = a)
            pressKeyWithFlags(keyCode: 0, flags: .maskCommand)
        case .save:
            // Cmd + S (keyCode 1 = s)
            pressKeyWithFlags(keyCode: 1, flags: .maskCommand)
        case .enter:
            pressSingleKey(keyCode: 36) // Return
        case .backspace:
            pressSingleKey(keyCode: 51) // Delete
        case .escape:
            pressSingleKey(keyCode: 53) // Esc
        case .tab:
            pressSingleKey(keyCode: 48) // Tab
        case .space:
            pressSingleKey(keyCode: 49) // Space
        case .arrowUp:
            pressSingleKey(keyCode: 126)
        case .arrowDown:
            pressSingleKey(keyCode: 125)
        case .arrowLeft:
            pressSingleKey(keyCode: 123)
        case .arrowRight:
            pressSingleKey(keyCode: 124)
        case .forceQuit:
            // Cmd + Option + Esc (Force Quit Applications)
            pressKeyWithFlags(keyCode: 53, flags: [.maskCommand, .maskAlternate])
        case .closeWindow:
            // Cmd + W
            pressKeyWithFlags(keyCode: 13, flags: .maskCommand)
        case .quitApp:
            // Cmd + Q
            pressKeyWithFlags(keyCode: 12, flags: .maskCommand)
        }
    }

    private func pressSingleKey(keyCode: CGKeyCode) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        down?.post(tap: .cghidEventTap)
        usleep(15_000)
        up?.post(tap: .cghidEventTap)
    }

    private func pressKeyWithFlags(keyCode: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        up?.flags = flags

        down?.post(tap: .cghidEventTap)
        usleep(25_000)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - System Actions

    public func executeSystemAction(_ actionName: String) {
        guard let action = MacRemoteProtocol.SystemAction(rawValue: actionName) else { return }

        switch action {
        case .volumeUp:
            runAppleScript("set volume output volume ((output volume of (get volume settings)) + 6)")
        case .volumeDown:
            runAppleScript("set volume output volume ((output volume of (get volume settings)) - 6)")
        case .volumeMute:
            runAppleScript("set volume output muted (not (output muted of (get volume settings)))")
        case .playPause:
            pressSpecialMediaKey(NX_KEYTYPE_PLAY)
        case .nextTrack:
            pressSpecialMediaKey(NX_KEYTYPE_NEXT)
        case .prevTrack:
            pressSpecialMediaKey(NX_KEYTYPE_PREVIOUS)
        case .brightnessUp:
            pressSpecialMediaKey(NX_KEYTYPE_BRIGHTNESS_UP)
        case .brightnessDown:
            pressSpecialMediaKey(NX_KEYTYPE_BRIGHTNESS_DOWN)
        case .lockScreen:
            lockMacScreen()
        case .sleepDisplay:
            sleepDisplayNow()
        case .sleepMac:
            runAppleScript("tell application \"System Events\" to sleep")
        case .missionControl:
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Mission Control"])
        case .showDesktop:
            pressKeyWithFlags(keyCode: 103, flags: .maskCommand)
        }
    }

    private func pressSpecialMediaKey(_ keyType: Int32) {
        func postKeyEvent(down: Bool) {
            let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xa00) : .init(rawValue: 0xb00)
            let data1 = Int((keyType << 16) | (down ? 0xa00 : 0xb00))
            let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            if let cg = ev?.cgEvent {
                cg.post(tap: .cghidEventTap)
            }
        }

        postKeyEvent(down: true)
        usleep(15_000)
        postKeyEvent(down: false)
    }

    private func lockMacScreen() {
        let lib = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
        if let sym = dlsym(lib, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Void
            let lockFunc = unsafeBitCast(sym, to: LockFn.self)
            lockFunc()
        } else {
            let path = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
            if FileManager.default.fileExists(atPath: path) {
                _ = try? Process.run(URL(fileURLWithPath: path), arguments: ["-suspend"])
            }
        }
    }

    private func sleepDisplayNow() {
        _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pmset"), arguments: ["displaysleepnow"])
    }

    private func runAppleScript(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
            }
        }
    }

    // MARK: - Real-Time Cursor Tracking & Broadcasting

    private func startCursorMonitoring() {
        DispatchQueue.main.async {
            self.cursorMonitorTimer?.invalidate()
            // 60 Hz polling loop for instantaneous mouse tracking
            self.cursorMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.broadcastCurrentCursor(force: false)
            }
        }
    }

    private func stopCursorMonitoring() {
        DispatchQueue.main.async {
            self.cursorMonitorTimer?.invalidate()
            self.cursorMonitorTimer = nil
            self.isMouseDownState = false
        }
    }

    public func broadcastCurrentCursor(force: Bool = false) {
        guard isClientAuthenticated, activeConnection != nil else { return }
        guard let mouseEvent = CGEvent(source: nil) else { return }
        let loc = mouseEvent.location
        let screenBounds = CGDisplayBounds(CGMainDisplayID())

        if !force {
            if abs(loc.x - lastSentCursorPos.x) < 0.5 && abs(loc.y - lastSentCursorPos.y) < 0.5 {
                return
            }
        }

        lastSentCursorPos = loc
        let normX = max(0.0, min(1.0, Double(loc.x - screenBounds.minX) / Double(screenBounds.width)))
        let normY = max(0.0, min(1.0, Double(loc.y - screenBounds.minY) / Double(screenBounds.height)))

        let envelope = MacRemoteProtocol.OutboundEnvelope(
            type: "cursor_pos",
            cursorX: normX,
            cursorY: normY,
            cursorDown: isMouseDownState
        )
        sendMessage(envelope)
    }

    // MARK: - Live Screen Capture & Streaming

    public func startScreenStreaming() {
        guard !isScreenStreaming else { return }
        DispatchQueue.main.async {
            self.isScreenStreaming = true
            self.logEvent("Live screen stream started at \(self.streamFps) FPS")

            let interval = 1.0 / Double(self.streamFps)
            self.screenStreamTimer?.invalidate()
            self.screenStreamTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.captureAndSendSingleFrame()
            }
        }
    }

    public func stopScreenStreaming() {
        DispatchQueue.main.async {
            guard self.isScreenStreaming else { return }
            self.isScreenStreaming = false
            self.screenStreamTimer?.invalidate()
            self.screenStreamTimer = nil
            self.logEvent("Live screen stream paused")
        }
    }

    public func captureAndSendSingleFrame() {
        guard isClientAuthenticated, activeConnection != nil else { return }

        let scale = self.streamScale
        let quality = self.streamQuality

        screenQueue.async { [weak self] in
            guard let self = self else { return }

            guard let cgImage = self.captureDesktopCGImage() else { return }

            let width = cgImage.width
            let height = cgImage.height

            let targetWidth = max(320, Int(Double(width) * scale))
            let targetHeight = max(240, Int(Double(height) * scale))

            // Obtain live cursor position on the display
            let mainDisplay = CGMainDisplayID()
            let screenBounds = CGDisplayBounds(mainDisplay)
            let mouseLoc = CGEvent(source: nil)?.location ?? CGPoint(x: screenBounds.midX, y: screenBounds.midY)
            let normX = max(0.0, min(1.0, Double(mouseLoc.x - screenBounds.minX) / Double(screenBounds.width)))
            let normY = max(0.0, min(1.0, Double(mouseLoc.y - screenBounds.minY) / Double(screenBounds.height)))

            // Render scaled image with cursor drawn into bitmap context
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return }

            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

            // Draw crisp macOS cursor directly onto the frame
            let drawX = CGFloat(normX) * CGFloat(targetWidth)
            let drawY = CGFloat(1.0 - normY) * CGFloat(targetHeight) // CoreGraphics y-axis is inverted
            self.drawMacCursor(in: context, at: CGPoint(x: drawX, y: drawY), scale: CGFloat(scale))

            guard let finalCGImage = context.makeImage() else { return }
            let bitmapRep = NSBitmapImageRep(cgImage: finalCGImage)
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [
                .compressionFactor: NSNumber(value: quality)
            ]

            guard let jpegData = bitmapRep.representation(using: .jpeg, properties: properties) else { return }

            // Construct 16-byte header:
            // [0..3]: Magic 0x44485343 ('DHSC')
            // [4..5]: Width UInt16 big endian
            // [6..7]: Height UInt16 big endian
            // [8..11]: Timestamp UInt32 milliseconds big endian
            // [12..13]: CursorX UInt16 (normalized ratio * 65535) big endian
            // [14..15]: CursorY UInt16 (normalized ratio * 65535) big endian
            var packet = Data(capacity: 16 + jpegData.count)
            var magic = MacRemoteProtocol.screenHeaderMagic.bigEndian
            var w = UInt16(targetWidth).bigEndian
            var h = UInt16(targetHeight).bigEndian
            var ts = UInt32(UInt64(Date().timeIntervalSince1970 * 1000) & 0xFFFFFFFF).bigEndian
            var curX = UInt16(min(65535.0, max(0.0, normX * 65535.0))).bigEndian
            var curY = UInt16(min(65535.0, max(0.0, normY * 65535.0))).bigEndian

            packet.append(Data(bytes: &magic, count: 4))
            packet.append(Data(bytes: &w, count: 2))
            packet.append(Data(bytes: &h, count: 2))
            packet.append(Data(bytes: &ts, count: 4))
            packet.append(Data(bytes: &curX, count: 2))
            packet.append(Data(bytes: &curY, count: 2))
            packet.append(jpegData)

            self.sendBinaryData(packet)
        }
    }

    private func drawMacCursor(in context: CGContext, at point: CGPoint, scale: CGFloat) {
        context.saveGState()

        let s: CGFloat = max(18.0, 24.0 * scale)

        // Drop shadow for pointer
        context.setShadow(offset: CGSize(width: 1.5, height: -2.0), blur: 3.5, color: CGColor(gray: 0, alpha: 0.55))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: point.x, y: point.y))
        path.addLine(to: CGPoint(x: point.x, y: point.y - s * 0.85))
        path.addLine(to: CGPoint(x: point.x + s * 0.22, y: point.y - s * 0.65))
        path.addLine(to: CGPoint(x: point.x + s * 0.42, y: point.y - s * 1.0))
        path.addLine(to: CGPoint(x: point.x + s * 0.58, y: point.y - s * 0.92))
        path.addLine(to: CGPoint(x: point.x + s * 0.38, y: point.y - s * 0.58))
        path.addLine(to: CGPoint(x: point.x + s * 0.68, y: point.y - s * 0.58))
        path.closeSubpath()

        // White arrow fill
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        context.addPath(path)
        context.fillPath()

        // Crisp black border
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
        context.setLineWidth(1.6)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()

        context.restoreGState()
    }

    private func captureDesktopCGImage() -> CGImage? {
        typealias LegacyCaptureFn = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: LegacyCaptureFn.self)
        // 1 = kCGWindowListOptionOnScreenOnly, 0 = kCGNullWindowID, 1 = kCGWindowImageBestResolution
        return fn(.null, 1, 0, 1)?.takeRetainedValue()
    }

    // MARK: - Network IP Discovery


    public func refreshNetworkAddresses() {
        let local = detectLocalIP() ?? "127.0.0.1"
        let tailscale = detectTailscaleIP()

        DispatchQueue.main.async {
            self.localIPAddress = local
            self.tailscaleIPAddress = tailscale
        }

        Task {
            let wan = await fetchPublicWANIP()
            await MainActor.run {
                self.publicWANIPAddress = wan
            }
        }
    }

    private func detectLocalIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = Optional(firstAddr)
        while let current = ptr {
            let interface = current.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if !ip.hasPrefix("127.") {
                        return ip
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return nil
    }

    private func detectTailscaleIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = Optional(firstAddr)
        while let current = ptr {
            let interface = current.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, socklen_t(0), NI_NUMERICHOST)
                let ip = String(cString: hostname)
                if ip.hasPrefix("100.") {
                    return ip
                }
            }
            ptr = current.pointee.ifa_next
        }
        return nil
    }

    private func fetchPublicWANIP() async -> String? {
        guard let url = URL(string: "https://api.ipify.org") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                return ip
            }
        } catch {
            // Ignore offline/failure
        }
        return nil
    }

    // MARK: - Security & PIN

    public func regeneratePin() {
        let randomNum = Int.random(in: 100000...999999)
        let pin = String(randomNum)
        UserDefaults.standard.set(pin, forKey: "droidhouse_mac_remote_pin")
        DispatchQueue.main.async {
            self.pairingPin = pin
            self.logEvent("New pairing PIN generated: \(pin)")
        }
    }

    public func setCustomPin(_ newPin: String) -> Bool {
        let trimmed = newPin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 && trimmed.count <= 32 else {
            return false
        }
        UserDefaults.standard.set(trimmed, forKey: "droidhouse_mac_remote_pin")
        DispatchQueue.main.async {
            self.pairingPin = trimmed
            self.logEvent("Permanent PIN updated: \(trimmed)")
        }
        return true
    }

    private func loadOrGeneratePin() {
        if let saved = UserDefaults.standard.string(forKey: "droidhouse_mac_remote_pin"), saved.count >= 4, saved.count <= 32 {
            pairingPin = saved
        } else {
            regeneratePin()
        }
    }

    // MARK: - Permissions

    public func checkPermissions() {
        let ax = AXIsProcessTrusted()
        let sc = CGPreflightScreenCaptureAccess()
        DispatchQueue.main.async {
            self.isAccessibilityGranted = ax
            self.isScreenCaptureGranted = sc
        }
    }

    public func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        checkPermissions()
    }

    public func requestScreenCapture() {
        CGRequestScreenCaptureAccess()
        checkPermissions()
    }

    private func startPermissionPolling() {
        DispatchQueue.main.async {
            self.permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.checkPermissions()
            }
        }
    }

    // MARK: - Activity Logging

    private func logEvent(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"

        DispatchQueue.main.async {
            self.recentEvents.insert(entry, at: 0)
            if self.recentEvents.count > 25 {
                self.recentEvents.removeLast()
            }
        }
    }
}
