import SwiftUI
import AVKit
import QuickLookThumbnailing
import ImageIO

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
        // .task(id:) cancels the previous preview (and the adb pull behind it)
        // as soon as the selection moves on. The old onChange + Task version
        // let every clicked file finish downloading, and whichever finished
        // last won, even if it was no longer the selected file.
        .task(id: file?.id) {
            thumbnailImage = nil
            localPreviewURL = nil
            isDownloadingPreview = false
            if let file {
                await loadPreview(for: file)
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
                } else if let image = thumbnailImage ?? ThumbnailManager.shared.cachedThumbnail(for: file) {
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
    
    /// Inline previews stream the whole file over adb, so anything bigger
    /// than this is left to Quick Look on demand rather than downloaded just
    /// because it was clicked.
    private static let maxInlinePreviewBytes: Int64 = 80 * 1024 * 1024

    private func loadPreview(for file: RemoteFile) async {
        guard !file.isDirectory else { return }

        let ext = (file.name as NSString).pathExtension.lowercased()
        let previewableExtensions = ["jpg", "jpeg", "png", "gif", "heic", "webp", "mp4", "mov", "mkv", "m4v", "mp3", "m4a", "wav"]

        guard previewableExtensions.contains(ext), file.size <= Self.maxInlinePreviewBytes else { return }

        isDownloadingPreview = true
        defer { isDownloadingPreview = false }

        // A folder per file path, so a file that's still open in the player
        // is never overwritten by a different file that shares its name.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidHouse-Preview", isDirectory: true)
            .appendingPathComponent(String(file.fullPath.hashValue, radix: 36), isDirectory: true)
        let localPath = dir.appendingPathComponent(file.name)

        do {
            // Untracked: browsing the inspector shouldn't flood the
            // transfer pill and history with downloads the user never asked for.
            try await adbService.pullFile(remotePath: file.fullPath, localPath: localPath.path, tracksProgress: false)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        localPreviewURL = localPath

        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) {
            // Decode a display-sized copy off the main thread; loading a
            // full 50 MP photo with NSImage(contentsOf:) stalled the UI.
            let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(localPath as CFURL, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 900
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            }.value
            guard !Task.isCancelled else { return }
            thumbnailImage = image
        } else if ["mp4", "mov", "mkv", "m4v"].contains(ext) {
            generateVideoThumbnail(url: localPath)
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
