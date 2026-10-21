import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

/// Loads, downsamples and caches thumbnails for files on the device.
///
/// Views ask for a thumbnail with `await thumbnail(for:)` from their own
/// `.task(id:)`, so a cell that scrolls away cancels its fetch and a finished
/// fetch only re-renders the cell that asked for it. The old design published
/// a change on the shared manager for every image, which re-rendered every
/// visible cell each time one thumbnail landed.
final class ThumbnailManager {
    static let shared = ThumbnailManager()

    private let cacheDir: URL
    private let memoryCache = NSCache<NSString, NSImage>()

    /// adb runs one sync connection per fetch; past a handful in parallel the
    /// USB link is saturated and every image just arrives later.
    private let limiter = AsyncLimiter(limit: 4)

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif", "gif"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "mkv", "avi", "webm", "3gp", "m4v"]

    /// Images above this are not worth pulling in full just for a grid tile.
    private static let maxImageBytes: Int64 = 60 * 1024 * 1024
    /// Enough of a video to reach its first keyframe in most containers.
    private static let videoPrefixBytes = 4_000_000

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = caches.appendingPathComponent("DroidHouse/Thumbnails")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memoryCache.countLimit = 800
        memoryCache.totalCostLimit = 120 * 1024 * 1024
    }

    // MARK: - Explorer files

    static func supportsThumbnail(_ file: RemoteFile) -> Bool {
        guard !file.isDirectory else { return false }
        let ext = (file.name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext) || videoExtensions.contains(ext)
    }

    /// Memory-cache hit only; safe to call from `body`.
    func cachedThumbnail(for file: RemoteFile) -> NSImage? {
        memoryCache.object(forKey: Self.cacheKey(for: file) as NSString)
    }

    func thumbnail(for file: RemoteFile, adbService: ADBService) async -> NSImage? {
        guard Self.supportsThumbnail(file) else { return nil }
        let key = Self.cacheKey(for: file)
        let ext = (file.name as NSString).pathExtension.lowercased()
        let isVideo = Self.videoExtensions.contains(ext)
        if !isVideo && file.size > Self.maxImageBytes { return nil }

        return await load(key: key, maxPixel: 240) {
            try await adbService.fetchFileDataFast(
                path: file.fullPath,
                maxSize: isVideo ? Self.videoPrefixBytes : nil
            )
        } decode: { data in
            isVideo ? await Self.videoFrame(from: data, name: file.name, maxPixel: 240)
                    : Self.downsample(data, maxPixel: 240)
        }
    }

    // MARK: - Screenshots
    //
    // Screenshots arrive as bare remote paths from the companion, not as
    // `RemoteFile`s from a directory listing, so they need an entry point that
    // doesn't require the explorer's model.

    func cachedThumbnail(forRemotePath path: String) -> NSImage? {
        memoryCache.object(forKey: Self.cacheKey(forRemotePath: path) as NSString)
    }

    func thumbnail(forRemotePath path: String, adbService: ADBService) async -> NSImage? {
        await load(key: Self.cacheKey(forRemotePath: path), maxPixel: 480) {
            guard let data = await self.imageData(forRemotePath: path, adbService: adbService) else {
                throw CancellationError()
            }
            return data
        } decode: { data in
            Self.downsample(data, maxPixel: 480)
        }
    }

    /// Full-resolution image bytes for a remote path, used when copying a
    /// screenshot to the clipboard or opening it — a downscaled thumbnail
    /// would be the wrong thing to hand over.
    func fullImage(forRemotePath path: String, adbService: ADBService) async -> NSImage? {
        guard let data = await imageData(forRemotePath: path, adbService: adbService) else {
            return nil
        }
        return NSImage(data: data)
    }

    /// Fetches a screenshot's bytes, preferring the companion bridge and
    /// falling back to adb when it isn't reachable.
    func imageData(forRemotePath path: String, adbService: ADBService) async -> Data? {
        if let data = await CompanionSync.shared.screenshotData(remotePath: path) {
            return data
        }
        return try? await adbService.fetchFileDataFast(path: path, maxSize: nil)
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Pipeline

    /// Memory → disk → device, with only the device step rate-limited.
    private func load(
        key: String,
        maxPixel: Int,
        fetch: @escaping () async throws -> Data,
        decode: @escaping (Data) async -> CGImage?
    ) async -> NSImage? {
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }

        let diskURL = cacheDir.appendingPathComponent(key).appendingPathExtension("png")

        if let cgImage = await Task.detached(priority: .utility, operation: {
            Self.readDiskThumbnail(at: diskURL)
        }).value {
            return remember(cgImage, key: key)
        }

        do {
            try await limiter.acquire()
        } catch {
            return nil // Cell scrolled away while queued.
        }
        defer { Task { await limiter.release() } }

        guard !Task.isCancelled, let data = try? await fetch(), !data.isEmpty else { return nil }

        // Decode on a background thread: ImageIO downsampling of a 12 MP
        // photo is tens of milliseconds, which used to land on the main thread.
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let image = await decode(data) else { return nil }
            Self.writeDiskThumbnail(image, to: diskURL)
            return image
        }.value

        guard let cgImage else { return nil }
        return remember(cgImage, key: key)
    }

    private func remember(_ cgImage: CGImage, key: String) -> NSImage {
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        memoryCache.setObject(image, forKey: key as NSString, cost: cgImage.width * cgImage.height * 4)
        return image
    }

    // MARK: - Keys
    //
    // Keys must be stable across listings *and* launches. `String.hashValue`
    // is randomly seeded per process, so the old keys never matched the disk
    // cache after a relaunch and the folder was re-downloaded every time.

    private static func cacheKey(for file: RemoteFile) -> String {
        "f_\(stableHash("\(file.fullPath)|\(file.size)|\(file.modifiedDate)"))"
    }

    private static func cacheKey(forRemotePath path: String) -> String {
        let name = (path as NSString).lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "shot_\(stableHash(path))_\(name.prefix(40))"
    }

    /// 64-bit FNV-1a: deterministic, fast, and plenty for a cache key.
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }

    // MARK: - Image work (background)

    private nonisolated static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func videoFrame(from data: Data, name: String, maxPixel: Int) async -> CGImage? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + name)
        guard (try? data.write(to: tempURL)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: tempURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? await generator.image(at: .zero).image
    }

    private nonisolated static func readDiskThumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private nonisolated static func writeDiskThumbnail(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

// MARK: - Async limiter

/// A counting semaphore for async code whose waiters can be cancelled.
///
/// `DispatchSemaphore.wait()` blocks a thread, and the old thumbnail code
/// released its slot before the fetch had even started, so it limited nothing.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            running = max(0, running - 1)
        } else {
            // Hand the slot straight to the next waiter.
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
