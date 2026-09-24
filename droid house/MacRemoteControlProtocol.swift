import Foundation
import CoreGraphics

// MARK: - Mac Remote Control Protocol
//
// Defines the wire format and message schemas for remotely controlling macOS
// from the DroidHouse Android companion app over WAN (Tailscale, public IP, port forward)
// or local Wi-Fi.

public enum MacRemoteProtocol {
    public static let defaultPort: UInt16 = 8089
    public static let protocolVersion: Int = 1
    public static let screenHeaderMagic: UInt32 = 0x44485343 // 'DHSC' (DroidHouse Screen)

    // MARK: - Incoming Messages (Android -> Mac)

    public struct InboundEnvelope: Codable {
        public let type: String
        public let pin: String?
        public let deviceName: String?
        public let dx: Double?
        public let dy: Double?
        public let xRatio: Double?
        public let yRatio: Double?
        public let button: String?
        public let text: String?
        public let keyCode: UInt16?
        public let keyDown: Bool?
        public let combo: String?
        public let action: String?
        public let fps: Int?
        public let quality: Double?
        public let scale: Double?
        public let enabled: Bool?
        public let timestamp: Double?
    }

    // MARK: - Outgoing Messages (Mac -> Android)

    public struct OutboundEnvelope: Codable {
        public let type: String
        public let success: Bool?
        public let message: String?
        public let macName: String?
        public let screenWidth: Double?
        public let screenHeight: Double?
        public let version: Int?
        public let timestamp: Double?
        public let accessibilityGranted: Bool?
        public let screenCaptureGranted: Bool?
        public let pingId: Double?

        public init(
            type: String,
            success: Bool? = nil,
            message: String? = nil,
            macName: String? = nil,
            screenWidth: Double? = nil,
            screenHeight: Double? = nil,
            version: Int? = nil,
            timestamp: Double? = nil,
            accessibilityGranted: Bool? = nil,
            screenCaptureGranted: Bool? = nil,
            pingId: Double? = nil
        ) {
            self.type = type
            self.success = success
            self.message = message
            self.macName = macName
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
            self.version = version
            self.timestamp = timestamp
            self.accessibilityGranted = accessibilityGranted
            self.screenCaptureGranted = screenCaptureGranted
            self.pingId = pingId
        }
    }

    // MARK: - Mouse Button Types

    public enum MouseButton: String {
        case left
        case right
        case middle
    }

    // MARK: - System Action Identifiers

    public enum SystemAction: String {
        case volumeUp = "volume_up"
        case volumeDown = "volume_down"
        case volumeMute = "volume_mute"
        case playPause = "play_pause"
        case nextTrack = "next_track"
        case prevTrack = "prev_track"
        case brightnessUp = "brightness_up"
        case brightnessDown = "brightness_down"
        case lockScreen = "lock_screen"
        case sleepDisplay = "sleep_display"
        case sleepMac = "sleep_mac"
        case missionControl = "mission_control"
        case showDesktop = "show_desktop"
    }

    // MARK: - Key Combo Identifiers

    public enum KeyCombo: String {
        case spotlight = "spotlight"       // Cmd + Space
        case appSwitcher = "app_switcher" // Cmd + Tab
        case copy = "copy"                 // Cmd + C
        case paste = "paste"               // Cmd + V
        case undo = "undo"                 // Cmd + Z
        case selectAll = "select_all"     // Cmd + A
        case save = "save"                 // Cmd + S
        case enter = "enter"               // Return
        case backspace = "backspace"       // Backspace / Delete
        case escape = "escape"             // Esc
        case tab = "tab"                   // Tab
        case space = "space"               // Space
        case arrowUp = "arrow_up"
        case arrowDown = "arrow_down"
        case arrowLeft = "arrow_left"
        case arrowRight = "arrow_right"
    }
}
