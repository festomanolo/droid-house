import SwiftUI
import QuickLookThumbnailing
import AVFoundation
import Combine

class ThumbnailManager: ObservableObject {
    static let shared = ThumbnailManager()
    
    private let cacheDir: URL
    private let diskCache: FileManager
    private var memoryCache = NSCache<NSString, NSImage>()
    
    // Concurrency control — high parallelism for snappy thumbnail loading.
    private let maxConcurrentFetches = 12
    private let semaphore: DispatchSemaphore
    private let fetchQueue = DispatchQueue(label: "com.droidhouse.thumbnail-fetch", attributes: .concurrent)
    
    // In-flight tracking (Thread-safe)
    private let activeFetchesLock = NSLock()
    private var activeFetchKeys = Set<String>()
    
    // Disk cache index for faster lookups
    private var diskCacheIndex = Set<String>()
    private let indexLock = NSLock()
    
    init() {
        self.diskCache = FileManager.default
        let caches = diskCache.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDir = caches.appendingPathComponent("DroidHouse/Thumbnails")
        self.semaphore = DispatchSemaphore(value: maxConcurrentFetches)
        
        try? diskCache.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memoryCache.countLimit = 600
        memoryCache.totalCostLimit = 120 * 1024 * 1024 // 120MB memory limit
        
        // Build disk cache index in background
        DispatchQueue.global(qos: .utility).async {
            self.buildDiskCacheIndex()
        }
    }
    
    private func buildDiskCacheIndex() {
        guard let files = try? diskCache.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) else { return }
        indexLock.lock()
        diskCacheIndex = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        indexLock.unlock()
    }
    
    @MainActor
    func getThumbnail(for file: RemoteFile, adbService: ADBService) -> NSImage? {
        let cacheKey = "\(file.id.uuidString)_\(file.modifiedDate.hashValue)"
        
        // 1. Check memory (Fastest)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        
        // 2. Check disk cache index first (faster than file system check)
        indexLock.lock()
        let existsInCache = diskCacheIndex.contains(cacheKey)
        indexLock.unlock()
        
        let diskPath = cacheDir.appendingPathComponent("\(cacheKey).png")
        
        if existsInCache {
            // Load from disk in background
            fetchQueue.async {
                if let image = NSImage(contentsOf: diskPath) {
                    // Calculate cost based on image size
                    let cost = Int(image.size.width * image.size.height * 4) // Rough estimate
                    DispatchQueue.main.async {
                        self.memoryCache.setObject(image, forKey: cacheKey as NSString, cost: cost)
                        self.objectWillChange.send()
                    }
                }
            }
        } else {
            // 3. Fetch from device
            fetchThumbnail(for: file, adbService: adbService, destination: diskPath, key: cacheKey)
        }
        
        return nil
    }
    
    // MARK: - Path-based access
    //
    // Screenshots arrive as bare remote paths from the companion, not as
    // `RemoteFile`s from a directory listing, so they need an entry point that
    // doesn't require the explorer's model.

    /// Cached thumbnail for a remote path, kicking off a fetch on a miss.
    /// Returns `nil` on the first call and publishes a change when ready.
    @MainActor
    func thumbnail(forRemotePath path: String, adbService: ADBService) -> NSImage? {
        let key = Self.cacheKey(forRemotePath: path)

        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        let diskPath = cacheDir.appendingPathComponent("\(key).png")

        indexLock.lock()
        let onDisk = diskCacheIndex.contains(key)
        indexLock.unlock()

        if onDisk {
            fetchQueue.async {
                guard let image = NSImage(contentsOf: diskPath) else { return }
                let cost = Int(image.size.width * image.size.height * 4)
                DispatchQueue.main.async {
                    self.memoryCache.setObject(image, forKey: key as NSString, cost: cost)
                    self.objectWillChange.send()
                }
            }
            return nil
        }

        fetchRemotePathThumbnail(path: path, adbService: adbService, destination: diskPath, key: key)
        return nil
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

    private static func cacheKey(forRemotePath path: String) -> String {
        // Stable, filesystem-safe, and collision-resistant enough for a cache.
        var hash: UInt64 = 5381
        for byte in path.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        let name = (path as NSString).lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return "shot_\(hash)_\(name.prefix(40))"
    }

    private func fetchRemotePathThumbnail(
        path: String,
        adbService: ADBService,
        destination: URL,
        key: String
    ) {
        activeFetchesLock.lock()
        if activeFetchKeys.contains(key) {
            activeFetchesLock.unlock()
            return
        }
        activeFetchKeys.insert(key)
        activeFetchesLock.unlock()

        fetchQueue.async {
            self.semaphore.wait()

            Task {
                defer {
                    self.semaphore.signal()
                    self.activeFetchesLock.lock()
                    self.activeFetchKeys.remove(key)
                    self.activeFetchesLock.unlock()
                }

                guard let data = await self.imageData(forRemotePath: path, adbService: adbService),
                      let image = NSImage(data: data) else { return }

                let thumbnail = self.resize(image: image, to: CGSize(width: 420, height: 420))

                if let tiff = thumbnail.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: destination)
                    self.indexLock.lock()
                    self.diskCacheIndex.insert(key)
                    self.indexLock.unlock()
                }

                let cost = Int(thumbnail.size.width * thumbnail.size.height * 4)
                await MainActor.run {
                    self.memoryCache.setObject(thumbnail, forKey: key as NSString, cost: cost)
                    self.objectWillChange.send()
                }
            }
        }
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        try? diskCache.removeItem(at: cacheDir)
        try? diskCache.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        indexLock.lock()
        diskCacheIndex.removeAll()
        indexLock.unlock()
    }
    
    private func fetchThumbnail(for file: RemoteFile, adbService: ADBService, destination: URL, key: String) {
        let ext = (file.name as NSString).pathExtension.lowercased()
        let isImage = ["jpg", "jpeg", "png", "webp", "heic"].contains(ext)
        let isVideo = ["mp4", "mov", "mkv", "avi", "webm"].contains(ext)
        
        guard isImage || isVideo else { return }
        
        // Check if already fetching
        activeFetchesLock.lock()
        if activeFetchKeys.contains(key) {
            activeFetchesLock.unlock()
            return
        }
        activeFetchKeys.insert(key)
        activeFetchesLock.unlock()
        
        fetchQueue.async {
            // Wait for a slot in the concurrency limit
            self.semaphore.wait()
            
            defer {
                self.semaphore.signal()
                self.activeFetchesLock.lock()
                self.activeFetchKeys.remove(key)
                self.activeFetchesLock.unlock()
            }
            
            Task {
                do {
                    // Images: fetch the whole file so decoding never fails on a
                    // truncated stream (a partial JPEG/HEIC yields a blank thumb).
                    // Videos: 4 MB is plenty to grab an early frame.
                    let data = try await adbService.fetchFileDataFast(path: file.fullPath, maxSize: isImage ? nil : 4_000_000)
                    
                    // Process thumbnail in background
                    if let image = await self.processThumbnail(data: data, isVideo: isVideo, name: file.name) {
                        // Save to disk
                        if let pngData = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: pngData) {
                            let finalData = bitmap.representation(using: .png, properties: [:])
                            try? finalData?.write(to: destination)
                            
                            // Update disk cache index
                            self.indexLock.lock()
                            self.diskCacheIndex.insert(key)
                            self.indexLock.unlock()
                        }
                        
                        // Calculate cost for memory cache
                        let cost = Int(image.size.width * image.size.height * 4)
                        
                        // Update UI on Main Actor
                        await MainActor.run {
                            self.memoryCache.setObject(image, forKey: key as NSString, cost: cost)
                            self.objectWillChange.send()
                        }
                    }
                } catch {
                    print("Failed to fetch thumbnail for \(file.name): \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func processThumbnail(data: Data, isVideo: Bool, name: String) async -> NSImage? {
        if !isVideo {
            guard let image = NSImage(data: data) else { return nil }
            return resize(image: image, to: CGSize(width: 200, height: 200)) // Reduced from 250
        } else {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + name)
            try? data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            
            return await generateVideoFrame(at: tempURL)
        }
    }
    
    private func generateVideoFrame(at url: URL) async -> NSImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200) // Reduced from 300
        
        do {
            let cgImage = try await generator.image(at: .zero).image
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            return nil
        }
    }
    
    private func resize(image: NSImage, to size: CGSize) -> NSImage {
        let aspectRatio = image.size.width / image.size.height
        var destSize = size
        
        if aspectRatio > 1 {
            destSize.height = size.width / aspectRatio
        } else {
            destSize.width = size.height * aspectRatio
        }
        
        let newImage = NSImage(size: destSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: destSize), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
    
    // Prefetch thumbnails for visible files
    func prefetchThumbnails(for files: [RemoteFile], adbService: ADBService) {
        let imageFiles = files.filter { file in
            let ext = (file.name as NSString).pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "webp", "heic", "mp4", "mov", "mkv", "avi", "webm"].contains(ext)
        }
        
        // Prefetch a generous window so the grid fills in ahead of scrolling.
        for file in imageFiles.prefix(48) {
            let cacheKey = "\(file.id.uuidString)_\(file.modifiedDate.hashValue)"
            
            // Skip if already in memory or being fetched
            if memoryCache.object(forKey: cacheKey as NSString) != nil { continue }
            
            activeFetchesLock.lock()
            let alreadyFetching = activeFetchKeys.contains(cacheKey)
            activeFetchesLock.unlock()
            
            if alreadyFetching { continue }
            
            // Check disk cache
            indexLock.lock()
            let existsInCache = diskCacheIndex.contains(cacheKey)
            indexLock.unlock()
            
            if !existsInCache {
                let diskPath = cacheDir.appendingPathComponent("\(cacheKey).png")
                fetchThumbnail(for: file, adbService: adbService, destination: diskPath, key: cacheKey)
            }
        }
    }
}
