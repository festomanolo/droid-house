//
//  droid_houseApp.swift
//  droid house
//
//  Created by festomanolo on 28/01/2026.
//

import SwiftUI

@main
struct droid_houseApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .toolbarBackground(.clear, for: .windowToolbar)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}
