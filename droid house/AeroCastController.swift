import Foundation
import Combine
import AppKit

// MARK: - AeroCast Control
//
// Turns the mirror into a remote: clicks, drags, scrolls, typing and the
// navigation keys are sent back to the phone while it is being cast.
//
// ## How this differs from scrcpy
//
// scrcpy pushes a small server onto the device, launches it through
// `app_process` so it runs as the *shell* user, and then calls the hidden
// `InputManager.injectInputEvent` API over its own binary protocol. That is why
// scrcpy's control feels instant — every event is one write on an already-open
// socket straight into the input pipeline.
//
// DroidHouse takes the supported route: the `input` shell command. The tradeoff
// is honest — `input` spawns a short-lived process on the device per event, so
// expect tens of milliseconds of extra latency versus scrcpy, and very fast
// drags are coalesced rather than reproduced sample-for-sample.
//
// Two things claw most of that back:
//   • a **persistent `adb shell`** session, so we pay the adb round-trip once
//     rather than per event, and
//   • **coalescing** of drag samples, so a fast swipe becomes one `input swipe`
//     instead of a queue of taps we could never keep up with.

@MainActor
final class AeroCastController: ObservableObject {

    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?

    /// The device's real display size in pixels. `input` works in this space,
    /// which is *not* necessarily the encoded stream size — AeroCast may be
    /// downscaling for bandwidth.
    private(set) var deviceSize = CGSize(width: 1080, height: 2400)

    private let adbPath: String
    private var serial: String?

    private var shellProcess: Process?
    private var shellInput: FileHandle?

    /// Serialises writes to the shell's stdin from the main actor.
    private var writeQueue = DispatchQueue(label: "com.droidhouse.aerocast.control")

    init(adbPath: String = ADBLocator.resolve()) {
        self.adbPath = adbPath
    }

    // MARK: - Lifecycle

    func attach(serial: String) async {
        guard self.serial != serial || !isReady else { return }
        detach()

        self.serial = serial
        deviceSize = await fetchPhysicalSize(serial: serial)

        // One long-lived interactive shell. Every subsequent event is a line
        // written to its stdin, which avoids ~60-100ms of adb connection setup
        // that a fresh `adb shell` would cost on every single tap.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [adbPath, "-s", serial, "shell"]

        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            shellProcess = process
            shellInput = stdin.fileHandleForWriting
            isReady = true
            lastError = nil
        } catch {
            isReady = false
            lastError = "Could not open a control shell: \(error.localizedDescription)"
        }
    }

    func detach() {
        if let shellInput {
            // `exit` lets the device-side shell close cleanly; terminating the
            // adb client alone can leave the remote shell lingering.
            try? shellInput.write(contentsOf: Data("exit\n".utf8))
            try? shellInput.close()
        }
        shellInput = nil

        if let shellProcess, shellProcess.isRunning {
            shellProcess.terminate()
        }
        shellProcess = nil

        isReady = false
        serial = nil
    }

    // MARK: - Pointer

    /// Taps at a point given in **normalised** stream coordinates (0...1),
    /// which keeps the view free of any knowledge of device resolution.
    func tap(atNormalised point: CGPoint) {
        let device = denormalise(point)
        send("input tap \(Int(device.x)) \(Int(device.y))")
    }

    func longPress(atNormalised point: CGPoint, milliseconds: Int = 600) {
        let device = denormalise(point)
        // A long press is a zero-distance swipe with a duration — `input` has
        // no dedicated long-press verb.
        send("input swipe \(Int(device.x)) \(Int(device.y)) \(Int(device.x)) \(Int(device.y)) \(milliseconds)")
    }

    func swipe(fromNormalised start: CGPoint, toNormalised end: CGPoint, milliseconds: Int) {
        let a = denormalise(start)
        let b = denormalise(end)
        let duration = max(30, min(3000, milliseconds))
        send("input swipe \(Int(a.x)) \(Int(a.y)) \(Int(b.x)) \(Int(b.y)) \(duration)")
    }

    /// Scroll wheel → a short flick, since `input` has no scroll primitive.
    func scroll(atNormalised point: CGPoint, deltaY: CGFloat) {
        guard abs(deltaY) > 0.5 else { return }

        let origin = denormalise(point)
        // Clamp the travel so a violent trackpad flick doesn't turn into a
        // swipe that leaves the screen and gets interpreted as a system gesture.
        let travel = max(-600, min(600, deltaY * 6))
        let target = CGPoint(
            x: origin.x,
            y: min(deviceSize.height - 10, max(10, origin.y + travel))
        )
        send("input swipe \(Int(origin.x)) \(Int(origin.y)) \(Int(target.x)) \(Int(target.y)) 120")
    }

    private func denormalise(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(deviceSize.width - 1, max(0, point.x * deviceSize.width)),
            y: min(deviceSize.height - 1, max(0, point.y * deviceSize.height))
        )
    }

    // MARK: - Keys

    enum NavigationKey: String, CaseIterable, Identifiable {
        case back = "KEYCODE_BACK"
        case home = "KEYCODE_HOME"
        case recents = "KEYCODE_APP_SWITCH"
        case power = "KEYCODE_POWER"
        case volumeUp = "KEYCODE_VOLUME_UP"
        case volumeDown = "KEYCODE_VOLUME_DOWN"
        case notifications = "KEYCODE_NOTIFICATION"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .back: return "Back"
            case .home: return "Home"
            case .recents: return "Recents"
            case .power: return "Power"
            case .volumeUp: return "Volume Up"
            case .volumeDown: return "Volume Down"
            case .notifications: return "Notifications"
            }
        }

        var systemImage: String {
            switch self {
            case .back: return "chevron.backward"
            case .home: return "circle"
            case .recents: return "square.on.square"
            case .power: return "power"
            case .volumeUp: return "speaker.wave.2.fill"
            case .volumeDown: return "speaker.wave.1.fill"
            case .notifications: return "bell"
            }
        }
    }

    func press(_ key: NavigationKey) {
        send("input keyevent \(key.rawValue)")
    }

    func keyCode(_ code: Int) {
        send("input keyevent \(code)")
    }

    /// Types a string on the device.
    ///
    /// `input text` treats the argument as a shell word *and* gives `%s` a
    /// special meaning (it becomes a space), so the payload is single-quoted
    /// and spaces are converted explicitly.
    func type(_ text: String) {
        guard !text.isEmpty else { return }

        for character in text {
            if character == "\n" {
                send("input keyevent KEYCODE_ENTER")
                continue
            }
            let piece = String(character)
                .replacingOccurrences(of: "'", with: "'\\''")
                .replacingOccurrences(of: " ", with: "%s")
            send("input text '\(piece)'")
        }
    }

    func backspace() {
        send("input keyevent KEYCODE_DEL")
    }

    /// Maps a macOS key event to the device, returning false when there is no
    /// sensible equivalent so the caller can ignore it.
    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Command-modified keys belong to the Mac app (⌘W, ⌘Q …), never the phone.
        if event.modifierFlags.contains(.command) { return false }

        switch event.keyCode {
        case 51:  backspace(); return true                    // delete
        case 36, 76: press(.back); return false               // return handled as text below
        case 53:  press(.back); return true                   // escape → back
        case 123: send("input keyevent KEYCODE_DPAD_LEFT"); return true
        case 124: send("input keyevent KEYCODE_DPAD_RIGHT"); return true
        case 125: send("input keyevent KEYCODE_DPAD_DOWN"); return true
        case 126: send("input keyevent KEYCODE_DPAD_UP"); return true
        default: break
        }

        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return false
        }
        type(characters)
        return true
    }

    // MARK: - Transport

    private func send(_ command: String) {
        guard isReady, let handle = shellInput else { return }
        let line = command + "\n"

        // Off the main actor: a stalled pipe must never freeze the UI.
        writeQueue.async {
            do {
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                Task { @MainActor [weak self] in
                    self?.isReady = false
                    self?.lastError = "Control shell closed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Device metrics

    /// Reads the display size `input` actually addresses — the override size if
    /// one is set (the user changed display resolution), else the physical one.
    private func fetchPhysicalSize(serial: String) async -> CGSize {
        guard let output = await runADB(["-s", serial, "shell", "wm size"]) else {
            return CGSize(width: 1080, height: 2400)
        }

        let lines = output.components(separatedBy: .newlines)
        let line = lines.first(where: { $0.contains("Override size") })
            ?? lines.first(where: { $0.contains("Physical size") })

        guard let line, let colon = line.firstIndex(of: ":") else {
            return CGSize(width: 1080, height: 2400)
        }

        let parts = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: "x")

        guard parts.count == 2,
              let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              w > 0, h > 0 else {
            return CGSize(width: 1080, height: 2400)
        }

        return CGSize(width: w, height: h)
    }

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
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
