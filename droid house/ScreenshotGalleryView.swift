import SwiftUI
import QuickLook

struct ScreenshotGalleryView: View {
    @ObservedObject var companionSync = CompanionSync.shared
    @ObservedObject var thumbnails = ThumbnailManager.shared
    @ObservedObject var adbService: ADBService

    @State private var isRefreshing = false
    @State private var quickLookURL: URL?
    @State private var copiedID: String?
    @State private var statusMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 168, maximum: 240), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if companionSync.screenshots.isEmpty {
                emptyGallery
            } else {
                grid
            }

            if let statusMessage {
                statusBar(statusMessage)
            }
        }
        .substrateBackground()
        .task {
            await refresh()
        }
        .quickLookPreview($quickLookURL)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Screenshot Sync")
                    .font(.system(size: 15, weight: .bold))
                Text(subtitleText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(SpatialButtonStyle(depth: .surface,
                                            padding: EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)))
            .disabled(isRefreshing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var subtitleText: String {
        if !companionSync.isConnected {
            return "Companion offline — start it on the phone to index screenshots"
        }
        let count = companionSync.screenshots.count
        return "\(count) screenshot\(count == 1 ? "" : "s") · click to preview, ⌘C or the button to copy"
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(companionSync.screenshots) { item in
                    ScreenshotCard(
                        item: item,
                        adbService: adbService,
                        justCopied: copiedID == item.id,
                        onOpen: { open(item) },
                        onCopy: { copy(item) },
                        onSave: { save(item) }
                    )
                }
            }
            .padding(18)
        }
    }

    private var emptyGallery: some View {
        VStack(spacing: 13) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("No Screenshots Yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(companionSync.isConnected
                 ? "Take a screenshot on your phone — it appears here automatically."
                 : "Open the DroidHouse companion on your phone to index screenshots.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            Button("Check Now") { Task { await refresh() } }
                .buttonStyle(SpatialButtonStyle(depth: .surface))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusBar(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Actions

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        try? await companionSync.fetchScreenshots()
    }

    /// Copies the full-resolution screenshot onto the macOS pasteboard, so it
    /// can be pasted straight into Slack, Mail, Figma, anywhere.
    private func copy(_ item: ScreenshotItem) {
        Task {
            guard let image = await thumbnails.fullImage(
                forRemotePath: item.remotePath,
                adbService: adbService
            ) else {
                await flash("Could not read \((item.remotePath as NSString).lastPathComponent) from the device.")
                return
            }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            // Write both the image and a file promise-ish TIFF so that apps
            // which only accept one representation still get something usable.
            pasteboard.writeObjects([image])

            withAnimation(Spatial.Motion.bouncy) { copiedID = item.id }
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Spatial.Motion.fluid) {
                if copiedID == item.id { copiedID = nil }
            }
        }
    }

    /// Pulls the screenshot to a temp file and hands it to Quick Look.
    private func open(_ item: ScreenshotItem) {
        Task {
            let name = (item.remotePath as NSString).lastPathComponent
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("DroidHouseScreenshots", isDirectory: true)
                .appendingPathComponent(name)

            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            guard let data = await thumbnails.imageData(forRemotePath: item.remotePath, adbService: adbService),
                  (try? data.write(to: destination)) != nil else {
                await flash("Could not open \(name).")
                return
            }

            quickLookURL = destination
        }
    }

    private func save(_ item: ScreenshotItem) {
        let name = (item.remotePath as NSString).lastPathComponent

        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            guard let data = await thumbnails.imageData(forRemotePath: item.remotePath, adbService: adbService) else {
                await flash("Could not download \(name).")
                return
            }
            do {
                try data.write(to: url)
                await flash("Saved \(name).")
            } catch {
                await flash("Could not save \(name): \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func flash(_ message: String) async {
        withAnimation(Spatial.Motion.fluid) { statusMessage = message }
        try? await Task.sleep(for: .seconds(3))
        withAnimation(Spatial.Motion.fluid) {
            if statusMessage == message { statusMessage = nil }
        }
    }
}

// MARK: - Card

private struct ScreenshotCard: View {
    let item: ScreenshotItem
    @ObservedObject var adbService: ADBService
    let justCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onSave: () -> Void

    @ObservedObject private var thumbnails = ThumbnailManager.shared
    @State private var isHovering = false

    private var fileName: String {
        (item.remotePath as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            preview
            caption
        }
        .padding(7)
        .glassSurface(.surface, highlighted: isHovering)
        .onHover { hovering in
            withAnimation(Spatial.Motion.crisp) { isHovering = hovering }
        }
        .contextMenu {
            Button("Open in Quick Look") { onOpen() }
            Button("Copy Image") { onCopy() }
            Button("Save As…") { onSave() }
            Divider()
            Button("Copy Device Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.remotePath, forType: .string)
            }
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .aspectRatio(9.0 / 16.0, contentMode: .fit)

            // Asking the manager on every render is intentional: it returns the
            // cached image immediately once ready and publishes a change when a
            // fetch completes.
            if let image = thumbnails.thumbnail(forRemotePath: item.remotePath, adbService: adbService) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .transition(.opacity)
            } else {
                VStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Loading…")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }

            if isHovering || justCopied {
                overlayActions
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.22 : 0.08), lineWidth: 1)
        }
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(Spatial.Motion.crisp, value: isHovering)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .cursor(.zoomIn)
    }

    private var overlayActions: some View {
        ZStack {
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack {
                Spacer()
                if justCopied {
                    Label("Copied", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                        .padding(.bottom, 10)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    HStack(spacing: 7) {
                        actionButton("doc.on.doc.fill", help: "Copy image", action: onCopy)
                        actionButton("arrow.down.circle.fill", help: "Save as…", action: onSave)
                        actionButton("eye.fill", help: "Quick Look", action: onOpen)
                    }
                    .padding(.bottom, 9)
                }
            }
        }
    }

    private func actionButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(.ultraThinMaterial))
        }
        .buttonStyle(.plain)
        .cursor(.interactive)
        .help(help)
    }

    private var caption: some View {
        HStack(spacing: 6) {
            Text(fileName)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(item.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 3)
    }
}
