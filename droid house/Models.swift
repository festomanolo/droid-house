import Foundation
import SwiftUI

enum NavigationSection: String, CaseIterable, Identifiable {
    case device = "Internal Storage"
    case messages = "Messages"
    case aeroCast = "AeroCast"
    case studioInput = "Studio Cam & Mic"
    case roster = "Smart Sync"
    case clipboard = "Clipboard Sync"
    case screenshots = "Screenshots"
    case transfers = "Transfers"
    case macRemote = "Mac Remote Control"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .device: return "internaldrive.fill"
        case .messages: return "message.fill"
        case .aeroCast: return "airplayvideo"
        case .studioInput: return "video.badge.waveform.fill"
        case .roster: return "tablecells.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .screenshots: return "photo.on.rectangle.angled"
        case .transfers: return "arrow.up.arrow.down.circle"
        case .macRemote: return "laptopcomputer.and.iphone"
        }
    }

    var tintColor: Color {
        switch self {
        case .device: return .blue
        case .messages: return .green
        case .aeroCast: return .dhAccentViolet
        case .studioInput: return .dhAccentMint
        case .roster: return .dhAccentMint
        case .clipboard: return .orange
        case .screenshots: return .purple
        case .transfers: return .cyan
        case .macRemote: return .dhAccentBlue
        }
    }

    /// One-line description used in the sidebar and the section switcher.
    var summary: String {
        switch self {
        case .device: return "Browse the device filesystem"
        case .messages: return "Read and reply to SMS threads"
        case .aeroCast: return "Mirror the screen and audio"
        case .studioInput: return "Camera & studio mic input for Mac"
        case .roster: return "Raw, unmerged tabular data"
        case .clipboard: return "Two-way clipboard bridge"
        case .screenshots: return "Live screenshot gallery"
        case .transfers: return "Active and past file transfers"
        case .macRemote: return "Control Mac from Android APK over WAN/LAN"
        }
    }

    /// Sections that render their own full-bleed canvas and shouldn't be
    /// paired with the file inspector.
    var usesInspector: Bool {
        switch self {
        case .aeroCast, .studioInput, .roster, .transfers, .macRemote: return false
        default: return true
        }
    }
}

struct Contact: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let phoneNumber: String
    let avatarUrl: String?
    var lastMessageSnippet: String
    var lastMessageTimestamp: Date
    var unreadCount: Int
}

struct SMSMessage: Identifiable, Hashable, Codable {
    let id: String
    let conversationId: String
    let sender: String
    let body: String
    let timestamp: Date
    let isOutgoing: Bool
}

struct ClipboardItem: Identifiable, Hashable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    let source: Source
    
    enum Source: String, Codable {
        case mac = "macOS"
        case android = "Android"
    }
}

struct ScreenshotItem: Identifiable, Hashable {
    let id: String
    let remotePath: String
    let localCacheURL: URL?
    let timestamp: Date
}

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
