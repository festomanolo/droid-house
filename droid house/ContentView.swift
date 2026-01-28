//
//  ContentView.swift
//  droid house
//
//  Created by festomanolo on 28/01/2026.
//

import SwiftUI
import QuickLook

struct ContentView: View {
    enum ExplorerTab: String, CaseIterable, Identifiable {
        case device
        case transfers

        var id: String { rawValue }
        var title: String {
            switch self {
            case .device: return "Device"
            case .transfers: return "Transfers"
            }
        }
        var systemImage: String {
            switch self {
            case .device: return "iphone.gen2"
            case .transfers: return "arrow.up.arrow.down.circle"
            }
        }
    }

    @StateObject private var adbService = ADBService()
    @ObservedObject var transferManager = TransferManager.shared
    
    @State private var selectedTab: ExplorerTab = .device
    @State private var layoutMode: MainExplorerView.LayoutMode = .icon
    @State private var searchText: String = ""
    @State private var previewURL: URL?
    @State private var isUploading = false
    @State private var uploadStatusText = ""
    @State private var selectedDevice: ADBDevice?
    @State private var selectedFile: RemoteFile?
    @State private var showWirelessSheet = false
    @State private var wirelessIP = ""
    @State private var detectedIP: String?
    @State private var showInspector = true
    
    @AppStorage("appThemeColor") private var appThemeColor: String = "blue"
    
    private func colorFromName(_ name: String) -> Color {
        switch name {
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "green": return .green
        case "yellow": return .yellow
        case "gray": return .gray
        default: return .blue
        }
    }

    var body: some View {
        explorerContent
            .quickLookPreview($previewURL)
            .onAppear {
                Task {
                    await adbService.detectDevices()
                }
            }
            .sheet(isPresented: $showWirelessSheet) {
                wirelessConnectionSheet
            }
            .tint(colorFromName(appThemeColor))
    }

    private var explorerContent: some View {
        NavigationSplitView {
            SidebarView(adbService: adbService, selectedDevice: $selectedDevice)
        } detail: {
            Group {
                switch selectedTab {
                case .device:
                    MainExplorerView(
                        adbService: adbService,
                        layoutMode: $layoutMode,
                        searchText: $searchText,
                        previewURL: $previewURL,
                        isUploading: $isUploading,
                        uploadStatusText: $uploadStatusText,
                        selectedFile: $selectedFile
                    )
                case .transfers:
                    TransfersView()
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            FilePreviewPanel(file: selectedFile, adbService: adbService)
                .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 24) { // Increased spacing between groups
                    // 1. Global Refresh (Left)
                    Button {
                        Task {
                            await adbService.detectDevices()
                            if let device = adbService.selectedDevice {
                                await adbService.fetchStorageInfo(device: device)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 24)) // Increased size
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh All")
                    
                    // 2. Tabs (Center - Restored Style)
                    HStack(spacing: 6) {
                        ForEach(ExplorerTab.allCases) { tab in
                            Button {
                                selectedTab = tab
                            } label: {
                                Label(tab.title, systemImage: tab.systemImage)
                                    .labelStyle(.titleAndIcon)
                                    .font(.system(size: 13, weight: .medium)) // Slightly larger font
                                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                                    .padding(.horizontal, 16) // Increased padding
                                    .padding(.vertical, 8)    // Increased padding
                                    .background(
                                        Capsule()
                                            .fill(selectedTab == tab ? Color.primary.opacity(0.12) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(Capsule().fill(.ultraThinMaterial))
                    
                    Spacer() // Push indicators to the right
                    
                    // 3. Status & Storage (Right)
                    HStack(spacing: 16) {
                        if !transferManager.activeTransfers.isEmpty {
                            TransferStatusPill()
                        }
                        
                        Divider().frame(height: 24) // Taller divider
                        
                        HStack(spacing: 12) {
                            ForEach(adbService.storageInfo) { info in
                                StorageIndicatorView(info: info)
                            }
                        }
                    }
                }
            }

            ToolbarItemGroup(placement: .navigation) {
                Picker("View", selection: $layoutMode) {
                    ForEach(MainExplorerView.LayoutMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage)
                            .symbolRenderingMode(.monochrome)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            ToolbarItem(placement: .automatic) {
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        await adbService.listFiles(path: adbService.currentPath)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolRenderingMode(.monochrome)
                }
                .help("Refresh")
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    prepareWirelessConnection()
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .symbolRenderingMode(.monochrome)
                }
                .help("Wireless Connect")
            }
            
            ToolbarItem(placement: .automatic) {
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                        .symbolRenderingMode(.monochrome)
                }
                .help("Toggle Inspector")
            }
        }
    }

    private var wirelessConnectionSheet: some View {
        VStack(spacing: 20) {
            Text("Wireless Connection")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Device IP Address")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                TextField("192.168.x.x", text: $wirelessIP)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                
                if let detected = detectedIP {
                    Button("Use detected: \(detected)") {
                        wirelessIP = detected
                    }
                    .font(.caption)
                }
            }
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    showWirelessSheet = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Connect") {
                    Task {
                        try? await adbService.connectWireless(ip: wirelessIP)
                        showWirelessSheet = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(wirelessIP.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 300)
    }

    private func prepareWirelessConnection() {
        Task {
            detectedIP = await adbService.getDeviceIP()
            if let ip = detectedIP {
                wirelessIP = ip
            }
            showWirelessSheet = true
        }
    }
}

#Preview {
    ContentView()
}
