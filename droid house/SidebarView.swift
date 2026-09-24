import SwiftUI

struct SidebarView: View {
    @ObservedObject var adbService: ADBService
    @Binding var selectedDevice: ADBDevice?
    @Binding var selectedSection: NavigationSection
    @State private var showSettings = false

    private let quickAccessLocations: [QuickAccessItem] = [
        QuickAccessItem(title: "Internal Storage", path: "/sdcard", systemImage: "internaldrive.fill", tint: .blue),
        QuickAccessItem(title: "Downloads", path: "/sdcard/Download", systemImage: "arrow.down.circle.fill", tint: .green),
        QuickAccessItem(title: "Camera", path: "/sdcard/DCIM", systemImage: "camera.fill", tint: .pink),
        QuickAccessItem(title: "Pictures", path: "/sdcard/Pictures", systemImage: "photo.fill", tint: .orange),
        QuickAccessItem(title: "Music", path: "/sdcard/Music", systemImage: "music.note", tint: .red),
        QuickAccessItem(title: "Movies", path: "/sdcard/Movies", systemImage: "film.fill", tint: .purple),
        QuickAccessItem(title: "Documents", path: "/sdcard/Documents", systemImage: "doc.fill", tint: .cyan)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    deviceSection
                    quickAccessSection
                    companionFeaturesSection
                    bookmarksSection
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
            }

            settingsFooter
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await adbService.detectDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolRenderingMode(.hierarchical)
                }
                .help("Refresh devices")
            }
        }
    }

    // MARK: - Device Section

    @ViewBuilder
    private var deviceSection: some View {
        sectionHeader("Device")

        if adbService.connectedDevices.isEmpty {
            noDeviceCard
        } else {
            VStack(spacing: 8) {
                ForEach(adbService.connectedDevices) { device in
                    DeviceCard(
                        device: device,
                        isSelected: selectedDevice?.id == device.id,
                        storage: adbService.storageInfo.first(where: { $0.isInternal }) ?? adbService.storageInfo.first
                    ) {
                        selectedDevice = device
                        adbService.selectedDevice = device
                        Task { await adbService.listFiles(path: "/sdcard") }
                    }
                }
            }
        }
    }

    private var noDeviceCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                    .frame(width: 40, height: 40)
                if adbService.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "iphone.slash")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(adbService.isLoading ? "Scanning…" : "No device")
                    .font(.system(size: 13, weight: .semibold))
                Text(adbService.isLoading ? "Looking for devices" : "Connect over USB or Wi-Fi")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        )
    }

    // MARK: - Quick Access

    @ViewBuilder
    private var quickAccessSection: some View {
        sectionHeader("Quick Access")

        VStack(spacing: 2) {
            SidebarLocationRow(
                title: "Device Storage",
                systemImage: NavigationSection.device.systemImage,
                tint: NavigationSection.device.tintColor,
                isActive: selectedSection == .device,
                isDisabled: selectedDevice == nil,
                action: {
                    selectedSection = .device
                    Task { await adbService.listFiles(path: "/sdcard") }
                }
            )
            
            ForEach(quickAccessLocations) { item in
                SidebarLocationRow(
                    title: item.title,
                    systemImage: item.systemImage,
                    tint: item.tint,
                    isActive: selectedSection == .device && adbService.currentPath == item.path,
                    isDisabled: selectedDevice == nil,
                    action: {
                        selectedSection = .device
                        Task { await adbService.listFiles(path: item.path) }
                    },
                    onDropPaths: { handleDropOnFolder(paths: $0, destinationPath: item.path) },
                    onDropURLs: { startUploadURLs($0, into: item.path) }
                )
            }
        }
    }
    
    // MARK: - Companion Features Section
    
    @ViewBuilder
    private var companionFeaturesSection: some View {
        sectionHeader("Companion Services")

        VStack(spacing: 2) {
            ForEach(Self.companionSections) { section in
                SidebarLocationRow(
                    title: section.rawValue,
                    systemImage: section.systemImage,
                    tint: section.tintColor,
                    isActive: selectedSection == section,
                    isDisabled: (section == .aeroCast || section == .studioInput) && selectedDevice == nil,
                    action: {
                        withAnimation(Spatial.Motion.fluid) { selectedSection = section }
                    }
                )
                .help(section.summary)
            }
        }
    }

    /// The companion-backed panes, in the order the product presents them.
    private static let companionSections: [NavigationSection] = [
        .messages, .aeroCast, .studioInput, .macRemote, .roster, .clipboard, .screenshots, .transfers
    ]

    // MARK: - Bookmarks

    @ViewBuilder
    private var bookmarksSection: some View {
        HStack {
            sectionHeader("Bookmarks")
            Spacer()
            let isBookmarked = adbService.bookmarks.contains(adbService.currentPath)
            Button {
                if isBookmarked {
                    adbService.removeBookmark(adbService.currentPath)
                } else {
                    adbService.addBookmark(adbService.currentPath)
                }
            } label: {
                Image(systemName: isBookmarked ? "star.slash" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(selectedDevice == nil)
            .help(isBookmarked ? "Remove bookmark for current folder" : "Bookmark current folder")
            .padding(.trailing, 6)
        }

        if adbService.bookmarks.isEmpty {
            Text("Star a folder to pin it here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        } else {
            VStack(spacing: 2) {
                ForEach(adbService.bookmarks, id: \.self) { bookmark in
                    SidebarLocationRow(
                        title: bookmarkTitle(bookmark),
                        systemImage: "star.fill",
                        tint: .yellow,
                        isActive: selectedSection == .device && adbService.currentPath == bookmark,
                        isDisabled: selectedDevice == nil,
                        action: {
                            selectedSection = .device
                            Task { await adbService.listFiles(path: bookmark) }
                        },
                        onDropPaths: { handleDropOnFolder(paths: $0, destinationPath: bookmark) },
                        onDropURLs: { startUploadURLs($0, into: bookmark) }
                    )
                    .contextMenu {
                        Button("Remove Bookmark", role: .destructive) {
                            adbService.removeBookmark(bookmark)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Settings Footer

    private var settingsFooter: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("Settings")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.leading, 8)
    }

    private func handleDropOnFolder(paths: [String], destinationPath: String) {
        Task {
            for path in paths {
                if let file = adbService.currentFiles.first(where: { $0.fullPath == path }) {
                    try? await adbService.moveFiles([file], to: destinationPath)
                }
            }
        }
    }

    private func startUploadURLs(_ urls: [URL], into destination: String) {
        Task {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                if isDir.boolValue {
                    let name = url.lastPathComponent
                    let dest = destination.hasSuffix("/") ? "\(destination)\(name)" : "\(destination)/\(name)"
                    try? await adbService.makeDirectory(path: dest)
                    if let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        for item in contents {
                            try? await adbService.pushFile(localPath: item.path, remotePath: dest)
                        }
                    }
                } else {
                    try? await adbService.pushFile(localPath: url.path, remotePath: destination)
                }
            }
        }
    }

    private func bookmarkTitle(_ path: String) -> String {
        let components = path.split(separator: "/")
        return components.last.map(String.init) ?? path
    }
}

// MARK: - Device Card

struct DeviceCard: View {
    let device: ADBDevice
    let isSelected: Bool
    let storage: ADBService.StorageInfo?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: isSelected
                                        ? [Color.accentColor, Color.accentColor.opacity(0.7)]
                                        : [Color.secondary.opacity(0.35), Color.secondary.opacity(0.2)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Image(systemName: device.connectionType == .wireless ? "wifi" : "cable.connector")
                                .font(.system(size: 9))
                            Text(device.connectionType.rawValue)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(device.connectionType == .wireless ? Color.green : Color.secondary)
                    }

                    Spacer()

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                if let storage {
                    VStack(alignment: .leading, spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.08))
                                Capsule()
                                    .fill(storage.percent > 0.9 ? Color.red : Color.accentColor)
                                    .frame(width: geo.size.width * storage.percent)
                            }
                        }
                        .frame(height: 5)
                        Text("\(storage.available) free of \(storage.total)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(isHovering ? 0.12 : 0.06), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(isSelected ? 0.1 : 0.04), radius: isSelected ? 6 : 3, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
    }
}

// MARK: - Sidebar Location Row

struct SidebarLocationRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isActive: Bool
    let isDisabled: Bool
    let action: () -> Void
    var onDropPaths: ([String]) -> Void = { _ in }
    var onDropURLs: ([URL]) -> Void = { _ in }

    @State private var isHovering = false
    @State private var isTargeted = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(isActive ? 1 : 0.9).gradient)
                        .frame(width: 26, height: 26)
                        .opacity(isDisabled ? 0.4 : 1)
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isDisabled ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isTargeted ? tint : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .dropDestination(for: String.self) { paths, _ in
            onDropPaths(paths); return true
        } isTargeted: { isTargeted = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            onDropURLs(urls); return true
        } isTargeted: { isTargeted = $0 }
    }

    private var rowFill: Color {
        if isActive { return Color.accentColor.opacity(0.14) }
        if isHovering && !isDisabled { return Color.primary.opacity(0.06) }
        return .clear
    }
}

struct QuickAccessItem: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    let systemImage: String
    var tint: Color = .blue
}
