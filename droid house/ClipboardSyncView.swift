import SwiftUI

struct ClipboardSyncView: View {
    @ObservedObject var syncManager = ClipboardSyncManager.shared
    @ObservedObject var companionSync = CompanionSync.shared
    @State private var manualText: String = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Dashboard Header
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Clipboard Sync")
                            .font(.system(size: 16, weight: .bold))
                        Toggle("", isOn: $syncManager.isAutoSyncEnabled)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help("Auto-sync clipboard between Mac and Android")
                    }
                    Text(syncManager.isAutoSyncEnabled ? "Real-time bidirectional clipboard polling active" : "Auto-sync disabled. Use manual controls below.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 10) {
                    Button {
                        Task { await syncManager.pullFromAndroid() }
                    } label: {
                        Label("Pull from Android", systemImage: "arrow.down.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(PillButtonStyle())
                    
                    Button {
                        Task { await syncManager.pushToAndroid(NSPasteboard.general.string(forType: .string) ?? "") }
                    } label: {
                        Label("Push to Android", systemImage: "arrow.up.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
            
            Divider()
            
            // Manual input bar & current clipboard status
            VStack(alignment: .leading, spacing: 12) {
                Text("CURRENT PASTEBOARD CONTENT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                
                HStack(spacing: 12) {
                    TextField("Enter text to broadcast to Android pasteboard...", text: $manualText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    
                    Button("Broadcast") {
                        let text = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        Task {
                            await syncManager.pushToAndroid(text)
                            manualText = ""
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(manualText.isEmpty)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .padding(16)
            
            Divider()
            
            // History Log
            VStack(alignment: .leading, spacing: 10) {
                Text("PASTEBOARD HISTORY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                
                if syncManager.clipboardHistory.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 32))
                            .foregroundStyle(.tertiary)
                        Text("No Clipboard Items Yet")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Copied items will automatically appear here.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(syncManager.clipboardHistory) { item in
                            ClipboardRow(item: item) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.text, forType: .string)
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
        }
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow))
    }
}

private struct ClipboardRow: View {
    let item: ClipboardItem
    let onCopy: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Source Badge
            Text(item.source.rawValue)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(item.source == .mac ? .blue : .green)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(item.source == .mac ? Color.blue.opacity(0.15) : Color.green.opacity(0.15))
                )
            
            Text(item.text)
                .font(.system(size: 12))
                .lineLimit(2)
            
            Spacer()
            
            Text(item.timestamp, style: .time)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            
            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Copy to local pasteboard")
        }
        .padding(.vertical, 4)
    }
}
