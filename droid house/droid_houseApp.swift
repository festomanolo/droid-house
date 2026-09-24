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
