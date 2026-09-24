import SwiftUI
import QuickLook

struct MacOSSplashScreenView: View {
    @Binding var isPresented: Bool
    @State private var logoScale: CGFloat = 0.75
    @State private var logoOpacity: Double = 0.0
    @State private var textOffset: CGFloat = 0
    @State private var textOpacity: Double = 0.0
    @State private var subtitleOpacity: Double = 0.0

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
            
            RadialGradient(
                colors: [Color.blue.opacity(0.3), Color.black.opacity(0.9)],
                center: .center,
                startRadius: 30,
                endRadius: 500
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    // Animated Text shifting from behind logo
                    VStack(spacing: 6) {
                        Text("DROIDHOUSE")
                            .font(.system(size: 38, weight: .black, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [.white, Color(red: 0.2, green: 0.6, blue: 1.0)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: .blue.opacity(0.6), radius: 15, x: 0, y: 4)

                        Text("Wireless Desktop Management & Android Companion")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.75))
                            .opacity(subtitleOpacity)
                    }
                    .offset(y: textOffset)
                    .opacity(textOpacity)
                    .zIndex(1)

                    // Logo on top layer
                    Image("droid-bg")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 140, height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: .blue.opacity(0.5), radius: 25, x: 0, y: 10)
                        .scaleEffect(logoScale)
                        .opacity(logoOpacity)
                        .zIndex(2)
                }
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                logoScale = 1.0
                logoOpacity = 1.0
            }
            
            withAnimation(.spring(response: 0.85, dampingFraction: 0.72).delay(0.3)) {
                textOffset = 115
                textOpacity = 1.0
            }
            
            withAnimation(.easeIn(duration: 0.5).delay(0.7)) {
                subtitleOpacity = 1.0
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                withAnimation(.easeInOut(duration: 0.6)) {
                    isPresented = false
                }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var adbService = ADBService()
    @StateObject private var companionSync = CompanionSync.shared
    @ObservedObject var transferManager = TransferManager.shared
    
    @State private var selectedSection: NavigationSection = .device
    @State private var layoutMode: MainExplorerView.LayoutMode = .icon
    @State private var searchText: String = ""
    @State private var previewURL: URL?
    @State private var isUploading = false
    @State private var uploadStatusText = ""
    @State private var selectedDevice: ADBDevice?
    @State private var selectedFile: RemoteFile?
    @State private var selectedContact: Contact?
    
    @State private var showSplash = true
    @State private var showWirelessSheet = false
    @State private var wirelessIP = ""
    @State private var detectedIP: String?
    @State private var showInspector = true
    @State private var showTimestampTransfer = false
    @State private var showOnboarding = false
    @State private var wirelessError: String?
    @State private var isConnecting = false

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false
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
        ZStack {
            explorerContent

            if showOnboarding && !showSplash {
                Color.clear
                    .ignoresSafeArea()
                    .overlay {
                        OnboardingView(adbService: adbService, isPresented: $showOnboarding)
                    }
                    .zIndex(999)
            }

            if showSplash {
                MacOSSplashScreenView(isPresented: $showSplash)
                    .transition(.opacity)
                    .zIndex(1000)
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .onAppear {
            if !hasCompletedOnboarding {
                showOnboarding = true
            }
            Task {
                await adbService.detectDevices()
                if selectedDevice == nil { selectedDevice = adbService.selectedDevice }
                if let firstDevice = adbService.connectedDevices.first {
                    await companionSync.setupPortForwarding(serial: firstDevice.id, adbPath: adbService.adbPath)
                }
            }
        }
        .onChange(of: showOnboarding) { _, newValue in
            if !newValue { hasCompletedOnboarding = true }
        }
        // ADBService auto-selects a device, but the sidebar gates AeroCast and
        // the Quick Access rows on this local binding. Without mirroring, those
        // stayed greyed out until the user happened to click the device card.
        .onChange(of: adbService.selectedDevice) { _, device in
            if selectedDevice?.id != device?.id { selectedDevice = device }
        }
        .onChange(of: adbService.connectedDevices) { _, newValue in
            if !newValue.isEmpty && showOnboarding {
                withAnimation(.spring(response: 0.3)) {
                    showOnboarding = false
                }
            }
            if let firstDevice = newValue.first {
                Task {
                    await companionSync.setupPortForwarding(serial: firstDevice.id, adbPath: adbService.adbPath)
                }
            }
        }
        .sheet(isPresented: $showWirelessSheet) {
            wirelessConnectionSheet
        }
        .sheet(isPresented: $showTimestampTransfer) {
            TimestampTransferView(adbService: adbService)
        }
        .tint(colorFromName(appThemeColor))
    }

    /// AeroCast, Roster and Transfers render edge-to-edge, so the inspector is
    /// suppressed for them regardless of the user's toggle — which is restored
    /// intact the moment they navigate back to a pane that uses it.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { showInspector && selectedSection.usesInspector },
            set: { showInspector = $0 }
        )
    }

    private var explorerContent: some View {
        NavigationSplitView {
            SidebarView(
                adbService: adbService,
                selectedDevice: $selectedDevice,
                selectedSection: $selectedSection
            )
        } detail: {
            Group {
                switch selectedSection {
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
                case .messages:
                    MessagesView(selectedContact: selectedContact)
                case .aeroCast:
                    AeroCastView(adbService: adbService)
                case .studioInput:
                    StudioCamView(adbService: adbService)
                case .macRemote:
                    MacRemoteAccessView()
                case .roster:
                    RosterView(adbService: adbService)
                case .clipboard:
                    ClipboardSyncView()
                case .screenshots:
                    ScreenshotGalleryView(adbService: adbService)
                case .transfers:
                    TransfersView()
                }
            }
        }
        .inspector(isPresented: inspectorPresented) {
            Group {
                switch selectedSection {
                case .messages:
                    ContactsSidebarView(selectedContact: $selectedContact)
                case .aeroCast, .studioInput, .roster, .transfers, .macRemote:
                    // These panes own their full canvas; the inspector would
                    // only steal width from them.
                    EmptyView()
                default:
                    FilePreviewPanel(file: selectedFile, adbService: adbService)
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("Section", selection: $selectedSection) {
                    ForEach(NavigationSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.systemImage).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .fixedSize()
            }

            ToolbarItem(placement: .navigation) {
                if selectedSection == .device {
                    Picker("View", selection: $layoutMode) {
                        ForEach(MainExplorerView.LayoutMode.allCases) { mode in
                            Image(systemName: mode.systemImage)
                                .help(mode.label)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }

            ToolbarItem(placement: .principal) {
                TransferStatusPill()
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTimestampTransfer = true
                } label: {
                    Label("Back Up", systemImage: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
                        .labelStyle(.titleAndIcon)
                }
                .help("Lossless timestamp-preserving backup & restore")
                .disabled(adbService.selectedDevice == nil)
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            ToolbarItemGroup(placement: .automatic) {
                Button {
                    Task {
                        await adbService.detectDevices()
                        if let device = adbService.selectedDevice {
                            await adbService.fetchStorageInfo(device: device)
                            await companionSync.setupPortForwarding(serial: device.id, adbPath: adbService.adbPath)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")

                Button {
                    prepareWirelessConnection()
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                .help("Wireless Connect")

                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Inspector")

                Button {
                    showOnboarding = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("Setup Guide")
            }
        }
        .toolbarTitleDisplayMode(.inline)
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
                    .disabled(isConnecting)

                if let detected = detectedIP {
                    Button("Use detected: \(detected)") {
                        wirelessIP = detected
                    }
                    .font(.caption)
                    .disabled(isConnecting)
                }

                if let error = wirelessError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(width: 220, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    showWirelessSheet = false
                    wirelessError = nil
                }
                .disabled(isConnecting)

                Button(isConnecting ? "Connecting…" : "Connect") {
                    Task {
                        isConnecting = true
                        wirelessError = nil
                        do {
                            try await adbService.connectWireless(ip: wirelessIP)
                            showWirelessSheet = false
                        } catch {
                            wirelessError = error.localizedDescription
                        }
                        isConnecting = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(wirelessIP.isEmpty || isConnecting)
            }
        }
        .padding(24)
        .frame(width: 280)
    }

    private func prepareWirelessConnection() {
        showWirelessSheet = true
        wirelessError = nil
        Task {
            detectedIP = await adbService.getDeviceIP()
            if let detected = detectedIP, wirelessIP.isEmpty {
                wirelessIP = detected
            }
        }
    }
}
