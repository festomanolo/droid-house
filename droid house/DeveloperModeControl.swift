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
