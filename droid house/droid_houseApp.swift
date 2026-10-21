//
//  droid_houseApp.swift
//  droid house
//
//  Created by festomanolo on 28/01/2026.
//

import SwiftUI

@main
struct droid_houseApp: App {
    init() {
        // Writing into a pipe whose reader has exited raises SIGPIPE, and the
        // default action terminates the process. That is exactly what happened
        // when adb died mid-restore (device unplugged, cancel, tar error) while
        // the archive was still being fed to its stdin: the whole app vanished.
        // Ignored, the write fails with EPIPE and the transfer reports an error.
        signal(SIGPIPE, SIG_IGN)

        // Enforce Developer Authorization check on app launch
        guard DeveloperConfig.validateLicense() else {
            fatalError("CRITICAL: Proprietary DroidHouse Developer Key Missing or Invalid. Unauthorized clone detected. Contact festomanolofm@gmail.com.")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .toolbarBackground(.clear, for: .windowToolbar)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}
