import Foundation

struct ADBDevice: Identifiable, Hashable {
    let id: String  // Serial number
    var name: String
    var model: String
    let connectionType: ConnectionType
    var isConnected: Bool
    
    enum ConnectionType: String {
        case usb = "USB"
        case wireless = "Wireless"
    }
    
    var displayName: String {
        name.isEmpty ? model : name
    }
}

struct RemoteFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let size: Int64
    let permissions: String
    let modifiedDate: String
    let fullPath: String
    
    var formattedSize: String {
        if isDirectory { return "—" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return "\(size / 1024) KB" }
        if size < 1024 * 1024 * 1024 { return "\(size / (1024 * 1024)) MB" }
        return "\(size / (1024 * 1024 * 1024)) GB"
    }
    
    var iconName: String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp":
            return "photo"
        case "mp4", "mov", "mkv", "avi", "webm":
            return "video"
        case "mp3", "m4a", "wav", "flac", "ogg":
            return "music.note"
        case "pdf":
            return "doc.richtext"
        case "txt", "log":
            return "doc.text"
        case "zip", "tar", "gz", "7z", "rar":
            return "doc.zipper"
        case "apk":
            return "app.badge"
        default:
            return "doc"
        }
    }
}
