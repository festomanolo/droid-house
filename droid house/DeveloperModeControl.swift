import Combine
import SwiftUI

// MARK: - Developer mode switch
//
// One switch for Developer options, USB debugging and Wireless debugging on
// the phone, so a test device can still open banking and payment apps that
// refuse to run with developer mode on.
//
// The companion does the writing (`/api/device/developer`), which works over
// adb and over Wi-Fi. It needs WRITE_SECURE_SETTINGS, which only adb can
// grant, so the first time a phone shows up over adb the Mac grants it. After
// that, a phone with developer mode off (and so no adb) can be switched back
// on from here over Wi-Fi. If the companion isn't reachable over adb, the Mac
// falls back to `settings put` through adb shell.

/// What `/api/device/developer` reports.
nonisolated struct DeveloperModeState: Decodable, Equatable, Sendable {
    let developerOptions: Bool
    let usbDebugging: Bool
    let wirelessDebugging: Bool
    let wirelessPort: Int
    let wirelessSupported: Bool
    let canToggle: Bool
    let grantCommand: String
}

@MainActor
final class DeveloperModeController: ObservableObject {
    static let companionPackage = "com.droidhouse.companion"

    @Published private(set) var state: DeveloperModeState?
    @Published private(set) var isBusy = false
    @Published var message: String?

    /// adb serials already granted this session, so the grant runs once each.
    private var granted: Set<String> = []

    // MARK: Reading

    func refresh(device: ADBDevice, adbPath: String) async {
        guard !isBusy else { return }
        if let fetched = await fetch(device: device) {
            // The grant is what lets every later toggle work without adb.
            if !fetched.canToggle, !device.isCompanionOnly, !granted.contains(device.id),
               await grant(serial: device.id, adbPath: adbPath) {
                state = await fetch(device: device) ?? fetched
            } else {
                state = fetched
            }
        } else if !device.isCompanionOnly {
            state = await shellState(serial: device.id, adbPath: adbPath)
        } else {
            state = nil
        }
    }

    // MARK: Switching

    func setEnabled(_ enabled: Bool, device: ADBDevice, adbService: ADBService) async {
        isBusy = true
        defer { isBusy = false }
        message = nil

        let adbPath = adbService.adbPath
        let host = endpoint(for: device)?.host

        do {
            if let result = try await post(enabled, device: device) {
                state = result
            } else if !device.isCompanionOnly {
                try await shellSet(enabled, serial: device.id, adbPath: adbPath)
                state = await shellState(serial: device.id, adbPath: adbPath)
            } else {
                message = "Couldn't reach the DroidHouse app on the phone."
                return
            }
        } catch {
            message = error.localizedDescription
            return
        }

        if enabled {
            if device.isCompanionOnly, let host {
                await reconnectADB(host: host, adbPath: adbPath)
                await adbService.detectDevices()
            }
        } else if !device.isCompanionOnly {
            message = WiFiCompanionStore.shared.paired.isEmpty
                ? "Debugging is off, so adb disconnects. Pair over Wi-Fi to turn it back on from the Mac."
                : "Debugging is off. Pick the phone's Wi-Fi entry to turn it back on."
        }
    }

    // MARK: Bridge

    private func endpoint(for device: ADBDevice) -> CompanionEndpoint? {
        device.isCompanionOnly ? CompanionLink.wifiEndpoint(for: device.id) : .loopback
    }

    private func fetch(device: ADBDevice) async -> DeveloperModeState? {
        guard let request = endpoint(for: device)?.request("/api/device/developer", timeout: 5),
              let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(DeveloperModeState.self, from: data)
    }

    /// Nil when the bridge is unreachable or predates the endpoint (404).
    private func post(_ enabled: Bool, device: ADBDevice) async throws -> DeveloperModeState? {
        guard var request = endpoint(for: device)?.request("/api/device/developer", method: "POST", timeout: 10) else { return nil }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"enabled":\#(enabled)}"#.utf8)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        switch status {
        case 200:
            return try JSONDecoder().decode(DeveloperModeState.self, from: data)
        case 404:
            return nil
        case 409 where !device.isCompanionOnly:
            // Not granted yet and the shell can do it directly.
            return nil
        default:
            struct Reply: Decodable { let message: String }
            let text = (try? JSONDecoder().decode(Reply.self, from: data))?.message
            throw ADBError.commandFailed(text ?? "The phone answered \(status).")
        }
    }

    // MARK: adb

    private func grant(serial: String, adbPath: String) async -> Bool {
        granted.insert(serial)
        let output = try? await ADBProcess.run(
            adb: adbPath,
            arguments: ["-s", serial, "shell", "pm grant \(Self.companionPackage) android.permission.WRITE_SECURE_SETTINGS"],
            timeout: 10
        )
        return output?.status == 0
    }

    private func shellState(serial: String, adbPath: String) async -> DeveloperModeState? {
        let command = "settings get global development_settings_enabled; settings get global adb_enabled; " +
            "settings get global adb_wifi_enabled; getprop service.adb.tcp.port; getprop ro.build.version.sdk"
        guard let output = try? await ADBProcess.run(adb: adbPath, arguments: ["-s", serial, "shell", command], timeout: 8),
              output.status == 0 else { return nil }
        let lines = output.stdoutString.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 5 else { return nil }
        let wirelessSupported = (Int(lines[4]) ?? 0) >= 30
        let tcpPort = Int(lines[3]) ?? 0
        return DeveloperModeState(
            developerOptions: lines[0] == "1",
            usbDebugging: lines[1] == "1",
            wirelessDebugging: wirelessSupported ? lines[2] == "1" : tcpPort > 0,
            wirelessPort: wirelessSupported ? 0 : tcpPort,
            wirelessSupported: wirelessSupported,
            canToggle: true,
            grantCommand: ""
        )
    }

    private func shellSet(_ enabled: Bool, serial: String, adbPath: String) async throws {
        // adb_enabled goes last when switching off: it ends this very session.
        let command = enabled
            ? "settings put global development_settings_enabled 1; settings put global adb_enabled 1; settings put global adb_wifi_enabled 1"
            : "settings put global adb_wifi_enabled 0; settings put global development_settings_enabled 0; settings put global adb_enabled 0"
        let output = try await ADBProcess.run(adb: adbPath, arguments: ["-s", serial, "shell", command], timeout: 10)
        if enabled, output.status != 0 { throw ADBError.commandFailed(output.errorText) }
    }

    /// Brings adb back after switching debugging on over Wi-Fi: the fixed
    /// `adb tcpip` port before Android 11, or the Wireless debugging service
    /// adb finds over mDNS on 11+ (only for a Mac paired with it before).
    private func reconnectADB(host: String, adbPath: String) async {
        try? await Task.sleep(for: .seconds(2))
        var targets: [String] = []
        if let port = state?.wirelessPort, port > 0 { targets.append("\(host):\(port)") }
        if state?.wirelessSupported == true,
           let output = try? await ADBProcess.run(adb: adbPath, arguments: ["mdns", "services"], timeout: 6) {
            for line in output.stdoutString.split(whereSeparator: \.isNewline)
            where line.contains("_adb-tls-connect") && line.contains(host) {
                if let address = line.split(whereSeparator: \.isWhitespace).last { targets.append(String(address)) }
            }
        }
        for target in targets {
            if let output = try? await ADBProcess.run(adb: adbPath, arguments: ["connect", target], timeout: 8),
               output.stdoutString.contains("connected") { return }
        }
    }
}

// MARK: - Sidebar card

struct DeveloperModeCard: View {
    let device: ADBDevice
    @ObservedObject var adbService: ADBService
    @StateObject private var controller = DeveloperModeController()
    @State private var confirmingOff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((isOn ? Color.orange : Color.secondary).gradient)
                        .frame(width: 26, height: 26)
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Developer Mode")
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(get: { isOn }, set: { request($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .disabled(!canToggle)
                }
            }

            if let message = controller.message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        )
        .help("Turns Developer options, USB debugging and Wireless debugging on or off together")
        .task(id: device.id) {
            controller.message = nil
            while !Task.isCancelled {
