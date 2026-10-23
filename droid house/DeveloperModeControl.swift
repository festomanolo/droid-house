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
