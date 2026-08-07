//
//  TimestampTransferView.swift
//  droid house
//
//  Glassmorphic control surface for the lossless timestamp-preserving
//  transfer engine. Presents a backup/restore workflow with a live status
//  dashboard, animated status pills and a collapsible ADB log drawer.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TimestampTransferView: View {
    @ObservedObject var adbService: ADBService
    @StateObject private var engine = ArchiveTransferEngine()
    @Environment(\.dismiss) private var dismiss

    @State private var direction: ArchiveTransferEngine.Direction = .backup
    @State private var remoteRoot: String = "/sdcard"
    @State private var relativePaths: [String] = ["DCIM/Screenshots", "Download", "Documents"]
    @State private var newPathText: String = ""
    @State private var restoreArchive: URL?
    @State private var showLog = false
    @State private var appeared = false
    @State private var showFolderPicker = false

    private let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            ScrollView {
                VStack(spacing: 20) {
                    directionPicker
                    configurationCard
                    statusDashboard
                    logDrawer
                }
                .padding(20)
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 560, height: 640)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow).ignoresSafeArea())
        .onAppear {
            direction = engine.direction
            withAnimation(spring) { appeared = true }
        }
        .onChange(of: engine.phase) { _, newValue in
            if newValue == .streaming || newValue.isTerminal {
                withAnimation(spring) { showLog = !engine.log.isEmpty }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 44, height: 44)
                Image(systemName: "clock.arrow.trianglehead.2.counterclockwise.rotate.90")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Lossless Timestamp Transfer")
                    .font(.system(size: 15, weight: .semibold))
                Text("Streams a tar archive with zero device storage overhead")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Direction Picker

    private var directionPicker: some View {
        HStack(spacing: 10) {
            ForEach(ArchiveTransferEngine.Direction.allCases) { option in
                Button {
                    withAnimation(spring) { direction = option }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: option.symbol)
                            .font(.system(size: 14, weight: .semibold))
                        Text(option.title)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(direction == option ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(direction == option ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 1)
                    }
                    .foregroundStyle(direction == option ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(engine.isRunning)
            }
        }
    }

    // MARK: - Configuration Card

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Configuration", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }

            // Device row
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen2")
                    .foregroundStyle(.secondary)
                if let device = adbService.selectedDevice {
                    Text(device.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text(device.connectionType.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary.opacity(0.5)))
                } else {
                    Text("No device connected")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
                Spacer()
            }

            Divider().opacity(0.4)

            if direction == .backup {
                backupConfiguration
            } else {
                restoreConfiguration
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }

    private var backupConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Root")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                TextField("/sdcard", text: $remoteRoot)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(engine.isRunning)
            }

            HStack {
                Text("Folders to archive")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    showFolderPicker = true
                } label: {
                    Label("Browse Phone…", systemImage: "folder.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .disabled(engine.isRunning || adbService.selectedDevice == nil)
            }

            if relativePaths.isEmpty {
                Text("No folders selected. Tap “Browse Phone…” to choose.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(relativePaths, id: \.self) { path in
                        pathChip(path)
                    }
                }
            }

            // Manual entry kept as a power-user fallback.
            HStack(spacing: 8) {
                TextField("or type a path e.g. Pictures", text: $newPathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(addPath)
                Button {
                    addPath()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .disabled(newPathText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .disabled(engine.isRunning)
        }
        .sheet(isPresented: $showFolderPicker) {
            RemoteFolderPickerView(
                adbService: adbService,
                root: remoteRoot.isEmpty ? "/sdcard" : remoteRoot,
                preselected: Set(relativePaths)
            ) { chosen in
                withAnimation(spring) {
                    // Merge, de-duplicate, keep order stable.
                    var merged = relativePaths
                    for path in chosen where !merged.contains(path) {
                        merged.append(path)
                    }
                    relativePaths = merged
                }
            }
        }
    }

    private var restoreConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Root")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                TextField("/sdcard", text: $remoteRoot)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .disabled(engine.isRunning)
            }

            Text("Archive to restore")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Button {
                chooseArchive()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: restoreArchive == nil ? "doc.badge.plus" : "doc.zipper")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(restoreArchive?.lastPathComponent ?? "Choose a .tar archive…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(restoreArchive == nil ? .secondary : .primary)
                        if let url = restoreArchive {
                            Text(url.deletingLastPathComponent().path)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(Color.primary.opacity(0.15))
                        }
                }
            }
            .buttonStyle(.plain)
            .disabled(engine.isRunning)
        }
    }

    private func pathChip(_ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
            Text(path)
                .font(.system(size: 11, design: .monospaced))
            if !engine.isRunning {
                Button {
                    withAnimation(spring) { relativePaths.removeAll { $0 == path } }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.accentColor.opacity(0.1)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1))
    }

    // MARK: - Status Dashboard

    private var statusDashboard: some View {
        VStack(spacing: 16) {
            statusPill

            HStack(spacing: 12) {
                metricTile(title: "Transferred", value: ByteFormat.string(engine.bytesTransferred), symbol: "shippingbox.fill")
                metricTile(title: "Rate", value: ByteFormat.rate(engine.bytesPerSecond), symbol: "speedometer")
                metricTile(title: "Elapsed", value: String(format: "%.1fs", engine.elapsed), symbol: "timer")
            }

            if engine.isRunning {
                indeterminateBar
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(phaseTint.opacity(0.25), lineWidth: 1)
                }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(phaseTint.opacity(0.18)).frame(width: 30, height: 30)
                if engine.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: phaseSymbol)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(phaseTint)
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                }
            }

            Text(engine.phase.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(phaseTint)
                .contentTransition(.numericText())

            Spacer()

            Text(direction == .backup ? "DEVICE → MAC" : "MAC → DEVICE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.quaternary.opacity(0.5)))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background {
            Capsule(style: .continuous)
                .fill(phaseTint.opacity(0.08))
                .overlay(Capsule().strokeBorder(phaseTint.opacity(0.2), lineWidth: 1))
        }
        .animation(spring, value: engine.phase)
    }

    private func metricTile(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .textCase(.uppercase)

            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        }
    }

    private var indeterminateBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(LinearGradient(colors: [phaseTint.opacity(0.3), phaseTint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: appeared ? geo.size.width * 0.65 : -geo.size.width * 0.35)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: appeared)
            }
        }
        .frame(height: 6)
    }

    // MARK: - Log Drawer

    private var logDrawer: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(spring) { showLog.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("ADB Output")
                        .font(.system(size: 12, weight: .medium))
                    if !engine.log.isEmpty {
                        Text("\(engine.log.count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary.opacity(0.5)))
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showLog ? 0 : -90))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(engine.log) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(line.timestamp, format: .dateTime.hour().minute().second())
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Text(line.text)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(line.isError ? .red : .primary.opacity(0.85))
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                                .id(line.id)
                            }
                            if engine.log.isEmpty {
                                Text("No output yet.")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .frame(height: 140)
                    .onChange(of: engine.log.count) { _, _ in
                        if let last = engine.log.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                .background(Color.black.opacity(0.15))
                .transition(.asymmetric(insertion: .push(from: .top), removal: .opacity))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.03))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if case .completed = engine.phase, direction == .backup, let url = engine.lastArchiveURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal Archive", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if engine.isRunning {
                Button(role: .cancel) {
                    engine.cancel()
                } label: {
                    Label("Cancel", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    start()
                } label: {
                    Label(direction == .backup ? "Start Backup" : "Start Restore",
                          systemImage: direction.symbol)
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Actions

    private var canStart: Bool {
        guard adbService.selectedDevice != nil else { return false }
        switch direction {
        case .backup:  return !relativePaths.isEmpty && !remoteRoot.trimmingCharacters(in: .whitespaces).isEmpty
        case .restore: return restoreArchive != nil
        }
    }

    private func addPath() {
        let trimmed = newPathText.trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        guard !trimmed.isEmpty, !relativePaths.contains(trimmed) else { return }
        withAnimation(spring) {
            relativePaths.append(trimmed)
            newPathText = ""
        }
    }

    private func start() {
        guard let serial = adbService.selectedDevice?.id else { return }
        withAnimation(spring) { showLog = true }
        switch direction {
        case .backup:
            let panel = NSSavePanel()
            panel.title = "Save Timestamp-Preserving Archive"
            panel.nameFieldStringValue = defaultArchiveName()
            panel.allowedContentTypes = [.init(filenameExtension: "tar") ?? .data]
            panel.canCreateDirectories = true
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                engine.startBackup(serial: serial,
                                   remoteRoot: remoteRoot,
                                   relativePaths: relativePaths,
                                   destination: url)
            }
        case .restore:
            guard let archive = restoreArchive else { return }
            engine.startRestore(serial: serial, remoteRoot: remoteRoot, archive: archive)
        }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = "Choose a .tar Archive to Restore"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "tar") ?? .data]
        panel.begin { response in
            if response == .OK, let url = panel.url {
                restoreArchive = url
            }
        }
    }

    private func defaultArchiveName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let device = adbService.selectedDevice?.displayName.replacingOccurrences(of: " ", with: "-") ?? "device"
        return "DroidHouse-\(device)-\(formatter.string(from: Date())).tar"
    }

    // MARK: - Phase styling

    private var phaseTint: Color {
        switch engine.phase {
        case .idle:       return .secondary
        case .preparing, .streaming, .finalizing: return .accentColor
        case .completed:  return .green
        case .cancelled:  return .orange
        case .failed:     return .red
        }
    }

    private var phaseSymbol: String {
        switch engine.phase {
        case .idle:       return "clock"
        case .preparing:  return "gearshape"
        case .streaming:  return "dot.radiowaves.left.and.right"
        case .finalizing: return "lock.fill"
        case .completed:  return "checkmark.seal.fill"
        case .cancelled:  return "xmark.circle.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Remote Folder Picker

struct RemoteFolderPickerView: View {
    @ObservedObject var adbService: ADBService
    let root: String
    let preselected: Set<String>
    let onDone: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var currentPath: String
    @State private var folders: [RemoteFile] = []
    @State private var isLoading = false
    @State private var selected: Set<String> = []   // absolute paths

    private let spring = Animation.spring(response: 0.32, dampingFraction: 0.85)

    init(adbService: ADBService, root: String, preselected: Set<String>, onDone: @escaping ([String]) -> Void) {
        self.adbService = adbService
        self.root = root
        self.preselected = preselected
        self.onDone = onDone
        _currentPath = State(initialValue: root)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            pathBar
            Divider().opacity(0.4)
            folderList
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 480, height: 540)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .behindWindow).ignoresSafeArea())
        .onAppear {
            selected = Set(preselected.map(absolute))
            Task { await load(currentPath) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill.badge.person.crop")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Choose Folders to Back Up")
                    .font(.system(size: 14, weight: .semibold))
                Text("Tap a folder to open it · use the circle to select")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Path bar

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await goUp() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.quaternary.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .disabled(currentPath == root)

            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(displayPath)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            if isLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: List

    private var folderList: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                if folders.isEmpty && !isLoading {
                    ContentUnavailableView {
                        Label("No Subfolders", systemImage: "folder")
                    } description: {
                        Text("This folder has no subfolders to select.")
                    }
                    .padding(.top, 40)
                } else {
                    ForEach(folders) { folder in
                        folderRow(folder)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func folderRow(_ folder: RemoteFile) -> some View {
        let isSelected = selected.contains(folder.fullPath)
        return HStack(spacing: 10) {
            Button {
                withAnimation(spring) {
                    if isSelected { selected.remove(folder.fullPath) }
                    else { selected.insert(folder.fullPath) }
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            Button {
                Task { await load(folder.fullPath) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                    Text(folder.name)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if !selected.isEmpty {
                Button("Clear") { withAnimation(spring) { selected.removeAll() } }
                    .buttonStyle(.borderless)
            }
            Text(selected.isEmpty ? "No folders selected"
                                  : "\(selected.count) folder\(selected.count == 1 ? "" : "s") selected")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button {
                let relatives = selected.map(relative).filter { !$0.isEmpty }.sorted()
                onDone(relatives)
                dismiss()
            } label: {
                Text(selected.isEmpty ? "Add" : "Add \(selected.count)")
                    .frame(minWidth: 60)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: Data

    private func load(_ path: String) async {
        isLoading = true
        currentPath = path
        folders = await adbService.listDirectories(at: path)
        isLoading = false
    }

    private func goUp() async {
        guard currentPath != root else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        await load(parent.isEmpty ? root : parent)
    }

    // MARK: Path helpers

    private var displayPath: String {
        currentPath == root ? "\(root)  (root)" : currentPath
    }

    private func relative(_ abs: String) -> String {
        if abs == root { return "" }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return abs.hasPrefix(prefix) ? String(abs.dropFirst(prefix.count)) : abs
    }

    private func absolute(_ rel: String) -> String {
        root.hasSuffix("/") ? root + rel : root + "/" + rel
    }
}

// MARK: - Flow Layout (wrapping chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var x: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                totalHeight += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            rows[rows.count - 1].append(subview)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview {
    TimestampTransferView(adbService: ADBService())
}
