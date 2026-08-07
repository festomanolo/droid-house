//
//  ADBLocator.swift
//  droid house
//
//  Robustly discovers the `adb` executable. A macOS GUI app launched from
//  Finder inherits a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), so simply
//  shelling out to "adb" frequently fails even when the developer has adb
//  installed. This locator layers several strategies and caches the result.
//

import Foundation

enum ADBLocator {

    /// UserDefaults key for a user-supplied absolute path override.
    static let overrideKey = "droidhouse.adbPath"

    private static var cached: String?

    /// Absolute path to `adb`, or the bare string "adb" if nothing could be
    /// found (in which case launches should route through `/usr/bin/env`).
    static func resolve() -> String {
        if let cached { return cached }
        let resolved = discover()
        cached = resolved
        return resolved
    }

    /// Forces re-discovery (e.g. after the user edits the override in Settings).
    @discardableResult
    static func refresh() -> String {
        cached = nil
        return resolve()
    }

    /// Whether a concrete, executable adb path was found.
    static var isResolved: Bool { resolve().hasPrefix("/") }

    // MARK: - Discovery

    private static func discover() -> String {
        let fm = FileManager.default

        // 1. Explicit user override.
        if let override = UserDefaults.standard.string(forKey: overrideKey),
           !override.isEmpty,
           fm.isExecutableFile(atPath: override) {
            return override
        }

        // 2. Well-known absolute install locations.
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "/usr/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "\(home)/Android/Sdk/platform-tools/adb",
            "\(home)/Android/sdk/platform-tools/adb"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }

        // 3. Ask the user's interactive login shell — this picks up custom PATH
        //    entries (Android SDK, scrcpy bundles, etc.) that Finder strips.
        if let shellResolved = resolveViaLoginShell(), fm.isExecutableFile(atPath: shellResolved) {
            return shellResolved
        }

        // 4. Last resort: let `/usr/bin/env` try the (minimal) PATH.
        return "adb"
    }

    private static func resolveViaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l login, -i interactive so PATH from the user's profile is loaded.
        process.arguments = ["-lic", "command -v adb"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // command -v can print a shell keyword/alias; only accept a real path.
            return path.hasPrefix("/") ? path : nil
        } catch {
            return nil
        }
    }
}
