import SwiftUI

struct SidebarView: View {
    @ObservedObject var adbService: ADBService
    @Binding var selectedDevice: ADBDevice?
    @State private var showSettings = false
    
    
    private let quickAccessLocations: [QuickAccessItem] = [
        QuickAccessItem(title: "Internal Storage", path: "/sdcard", systemImage: "internaldrive"),
        QuickAccessItem(title: "Downloads", path: "/sdcard/Download", systemImage: "arrow.down.circle"),
        QuickAccessItem(title: "DCIM", path: "/sdcard/DCIM", systemImage: "camera"),
        QuickAccessItem(title: "Pictures", path: "/sdcard/Pictures", systemImage: "photo.stack"),
        QuickAccessItem(title: "Music", path: "/sdcard/Music", systemImage: "music.note.list"),
        QuickAccessItem(title: "Movies", path: "/sdcard/Movies", systemImage: "film"),
        QuickAccessItem(title: "Documents", path: "/sdcard/Documents", systemImage: "doc.text")
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            List {
                // Devices Section
                Section("Devices") {
                    if adbService.connectedDevices.isEmpty {
                        HStack(spacing: 8) {
                            if adbService.isLoading {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }
                            Text(adbService.isLoading ? "Scanning..." : "No devices found")
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                        }
                    } else {
                        ForEach(adbService.connectedDevices) { device in
                            Button {
                                selectedDevice = device
                                adbService.selectedDevice = device
                                Task {
                                    await adbService.listFiles(path: "/sdcard")
                                }
                            } label: {
                                HStack {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.displayName)
                                                .font(.system(size: 13, weight: .medium))
                                            Text(device.connectionType.rawValue)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    } icon: {
                                        Image(systemName: device.connectionType == .wireless ? "wifi" : "cable.connector")
                                            .symbolRenderingMode(.monochrome)
                                            .foregroundStyle(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    if selectedDevice?.id == device.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .buttonStyle(SidebarRowStyle())
                        }
                    }
                }
                
                // Quick Access Section
                Section("Quick Access") {
                    ForEach(quickAccessLocations) { item in
                        Button {
                            Task {
                                await adbService.listFiles(path: item.path)
                            }
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(SidebarRowStyle())
                        .disabled(selectedDevice == nil)
                        .dropDestination(for: String.self) { paths, _ in
                            handleDropOnFolder(paths: paths, destinationPath: item.path)
                            return true
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            
            Divider()
            
            Button {
                showSettings = true
            } label: {
                HStack {
                    Label("Settings", systemImage: "gearshape.fill")
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
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await adbService.detectDevices()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolRenderingMode(.hierarchical)
                }
                .help("Refresh devices")
            }
        }
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
}

struct QuickAccessItem: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    let systemImage: String
}

#Preview {
    SidebarView(adbService: ADBService(), selectedDevice: .constant(nil))
}
