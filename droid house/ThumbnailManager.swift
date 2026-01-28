import SwiftUI
import QuickLookThumbnailing
import AVFoundation
import Combine

class ThumbnailManager: ObservableObject {
    static let shared = ThumbnailManager()
    
    private let cacheDir: URL
    private let diskCache: FileManager
    private var memoryCache = NSCache<NSString, NSImage>()
    
    // Concurrency control
    private let maxConcurrentFetches = 4
    private let semaphore = DispatchSemaphore(value: 4)
    private let fetchQueue = DispatchQueue(label: "com.droidhouse.thumbnail-fetch", attributes: .concurrent)
    
    // In-flight tracking (Thread-safe)
    private let activeFetchesLock = NSLock()
    private var activeFetchKeys = Set<String>()
    
    init() {
        self.diskCache = FileManager.default
        let caches = diskCache.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDir = caches.appendingPathComponent("DroidHouse/Thumbnails")
        
        try? diskCache.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memoryCache.countLimit = 150 // Slightly increased
    }
    
    @MainActor
    func getThumbnail(for file: RemoteFile, adbService: ADBService) -> NSImage? {
        let cacheKey = "\(file.id.uuidString)_\(file.modifiedDate.hashValue)"
        
        // 1. Check memory (Fastest)
        if let cached = memoryCache.object(forKey: cacheKey as NSString) {
            return cached
        }
        
        // 2. Check disk (Async to avoid blocking UI)
        let diskPath = cacheDir.appendingPathComponent("\(cacheKey).png")
        
        // Quick check for existence is fine on main thread
        if diskCache.fileExists(atPath: diskPath.path) {
            // Load disk data in background to avoid stutter
            fetchQueue.async {
                if let image = NSImage(contentsOf: diskPath) {
                    DispatchQueue.main.async {
                        self.memoryCache.setObject(image, forKey: cacheKey as NSString)
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
                    // Fetch data (this is already backgrounded in ADBService now)
                    let data = try await adbService.fetchFileDataFast(path: file.fullPath, maxSize: isImage ? 500_000 : 2_000_000)
                    
                    // Process thumbnail in background
                    if let image = await self.processThumbnail(data: data, isVideo: isVideo, name: file.name) {
                        // Save to disk
                        if let pngData = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: pngData) {
                            let finalData = bitmap.representation(using: .png, properties: [:])
                            try? finalData?.write(to: destination)
                        }
                        
                        // Update UI on Main Actor
                        await MainActor.run {
                            self.memoryCache.setObject(image, forKey: key as NSString)
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
            return resize(image: image, to: CGSize(width: 250, height: 250))
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
        generator.maximumSize = CGSize(width: 300, height: 300)
        
        do {
            let cgImage = try await generator.image(at: .zero).image
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            return nil
        }
    }
    
    private func resize(image: NSImage, to size: CGSize) -> NSImage {
        let destSize = NSSize(width: size.width, height: size.height)
        let newImage = NSImage(size: destSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: destSize), from: NSRect(origin: .zero, size: image.size), operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}
