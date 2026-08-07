import SwiftUI
import AVKit
import QuickLookThumbnailing

struct FilePreviewPanel: View {
    let file: RemoteFile?
    let adbService: ADBService
    @State private var thumbnailImage: NSImage?
    @State private var isLoadingThumbnail = false
    @State private var localPreviewURL: URL?
    @State private var isDownloadingPreview = false
    
    var body: some View {
        VStack(spacing: 0) {
            if let file = file {
                ScrollView {
                    VStack(spacing: 20) {
                        // Thumbnail / Preview
                        thumbnailSection(for: file)
                        
                        Divider()
                        
                        // File Info
                        infoSection(for: file)
                        
                        // Media Player (if applicable)
                        if let url = localPreviewURL {
                            mediaSection(for: file, url: url)
                        }
                        
                        Spacer()
                    }
                    .padding(16)
                }
            } else {
                emptyState
            }
        }
        .frame(minWidth: 260, idealWidth: 280, maxWidth: 320)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        .onChange(of: file) { _, newFile in
            thumbnailImage = nil
            localPreviewURL = nil
            if let f = newFile {
                loadPreview(for: f)
            }
        }
    }
    
    // MARK: - Thumbnail Section
    
    private func thumbnailSection(for file: RemoteFile) -> some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.3))
                    .frame(height: 160)
                
                if isLoadingThumbnail || isDownloadingPreview {
                    ProgressView()
                } else if let image = thumbnailImage ?? ThumbnailManager.shared.getThumbnail(for: file, adbService: adbService) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: file.iconName)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }
            }
            
            Text(file.name)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }
    
    // MARK: - Info Section
    
    private func infoSection(for file: RemoteFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Information")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            
            InfoRow(label: "Type", value: file.isDirectory ? "Folder" : fileType(for: file))
            InfoRow(label: "Size", value: file.formattedSize)
            InfoRow(label: "Modified", value: file.modifiedDate)
            InfoRow(label: "Permissions", value: file.permissions)
            InfoRow(label: "Path", value: file.fullPath)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Media Section
    
    @ViewBuilder
    private func mediaSection(for file: RemoteFile, url: URL) -> some View {
        let ext = (file.name as NSString).pathExtension.lowercased()
        
        if ["mp4", "mov", "mkv", "avi", "webm", "m4v"].contains(ext) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Video Preview")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                
                // AppKit AVPlayerView instead of SwiftUI's VideoPlayer, which
                // aborts on generic-metadata instantiation on some Intel/macOS
                // configurations (_AVKit_SwiftUI crash).
                AVPlayerViewRepresentable(url: url)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } else if ["mp3", "m4a", "wav", "flac", "ogg", "aac"].contains(ext) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Audio Preview")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                
                AudioPlayerView(url: url)
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No Selection")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Select a file to see its details")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Helpers
    
    private func fileType(for file: RemoteFile) -> String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "Image"
        case "mp4", "mov", "mkv", "avi", "webm", "m4v": return "Video"
        case "mp3", "m4a", "wav", "flac", "ogg", "aac": return "Audio"
        case "pdf": return "PDF Document"
        case "txt", "log": return "Text File"
        case "zip", "tar", "gz", "7z", "rar": return "Archive"
        case "apk": return "Android App"
        default: return ext.isEmpty ? "File" : "\(ext.uppercased()) File"
        }
    }
    
    private func loadPreview(for file: RemoteFile) {
        guard !file.isDirectory else { return }
        
        let ext = (file.name as NSString).pathExtension.lowercased()
        let previewableExtensions = ["jpg", "jpeg", "png", "gif", "heic", "webp", "mp4", "mov", "mkv", "mp3", "m4a", "wav"]
        
        guard previewableExtensions.contains(ext) else { return }
        
        isDownloadingPreview = true
        
        Task {
            let tempDir = FileManager.default.temporaryDirectory
            let localPath = tempDir.appendingPathComponent(file.name)
            
            do {
                try await adbService.pullFile(remotePath: file.fullPath, localPath: localPath.path)
                
                await MainActor.run {
                    localPreviewURL = localPath
                    isDownloadingPreview = false
                    
                    // Generate thumbnail for images
                    if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) {
                        if let image = NSImage(contentsOf: localPath) {
                            thumbnailImage = image
                        }
                    } else if ["mp4", "mov", "mkv", "m4v"].contains(ext) {
                        generateVideoThumbnail(url: localPath)
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloadingPreview = false
                }
            }
        }
    }
    
    private func generateVideoThumbnail(url: URL) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 300, height: 200),
            scale: 2.0,
            representationTypes: .thumbnail
        )
        
        QLThumbnailGenerator.shared.generateRepresentations(for: request) { thumbnail, _, error in
            if let thumbnail = thumbnail {
                DispatchQueue.main.async {
                    self.thumbnailImage = thumbnail.nsImage
                }
            }
        }
    }
}

// MARK: - AppKit Video Player

/// Wraps AppKit's `AVPlayerView`. We deliberately avoid SwiftUI's `VideoPlayer`
/// because instantiating its generic metadata (`_AVKit_SwiftUI`) aborts at
/// runtime on some Intel / macOS 26 configurations.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            nsView.player?.pause()
            nsView.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(3)
        }
    }
}

// MARK: - Audio Player

struct AudioPlayerView: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    
    var body: some View {
        VStack(spacing: 12) {
            // Decorative waveform header for the functional audio transport below.
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(height: 40)
                .overlay {
                    Image(systemName: "waveform")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.secondary)
                }
            
            // Progress bar
            Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                if !editing {
                    player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
                }
            }
            .tint(.primary)
            
            // Time labels
            HStack {
                Text(formatTime(currentTime))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            // Controls
            HStack(spacing: 24) {
                Button {
                    player?.seek(to: CMTime(seconds: max(0, currentTime - 10), preferredTimescale: 600))
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                
                Button {
                    if isPlaying {
                        player?.pause()
                    } else {
                        player?.play()
                    }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
                
                Button {
                    player?.seek(to: CMTime(seconds: min(duration, currentTime + 10), preferredTimescale: 600))
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.3)))
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
    
    private func setupPlayer() {
        player = AVPlayer(url: url)
        
        // Get duration
        if let item = player?.currentItem {
            Task {
                let dur = try? await item.asset.load(.duration)
                if let dur = dur {
                    await MainActor.run {
                        duration = dur.seconds
                    }
                }
            }
        }
        
        // Observe time
        player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { time in
            currentTime = time.seconds
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

#Preview {
    FilePreviewPanel(file: nil, adbService: ADBService())
}
