import SwiftUI
import AppKit

// MARK: - Mac Remote Access View
//
// Control center in macOS DroidHouse to manage remote control of the Mac from
// the Android companion APK over WAN (Tailscale, Dynamic DNS, Router Port Forwarding)
// or local Wi-Fi.

struct MacRemoteAccessView: View {
    @ObservedObject var host: MacRemoteControlHost = MacRemoteControlHost.shared
    @State private var copiedItem: String?
    @State private var customPinInput = ""
    @State private var pinErrorMessage: String? = nil
    @State private var showSavedSuccess = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerBanner
                permissionsCard
                serverToggleCard
                connectionAddressesCard
                liveClientCard
                streamSettingsCard
                recentActivityCard
            }
            .padding(24)
        }
        .background(Color.black.opacity(0.4))
        .onAppear {
            customPinInput = host.pairingPin
            host.refreshNetworkAddresses()
            host.checkPermissions()
            if !host.isRunning {
                host.startServer()
            }
        }
    }

    // MARK: - Header Banner

    private var headerBanner: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.8), Color.purple.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .shadow(color: .blue.opacity(0.4), radius: 10, x: 0, y: 4)

                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text("Mac Remote Control")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    statusPill
                }

                Text("Control this Mac's mouse, keyboard, media, and screen from DroidHouse APK anywhere in the world.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(host.isRunning ? (host.isClientAuthenticated ? Color.green : Color.yellow) : Color.gray)
                .frame(width: 8, height: 8)
                .shadow(color: host.isRunning ? Color.green.opacity(0.8) : Color.clear, radius: 4)

            Text(host.isRunning ? (host.isClientAuthenticated ? "Connected" : "Listening") : "Offline")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(host.isRunning ? (host.isClientAuthenticated ? Color.green : Color.yellow) : Color.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.5))
                .overlay(
                    Capsule()
                        .stroke(host.isRunning ? (host.isClientAuthenticated ? Color.green.opacity(0.4) : Color.yellow.opacity(0.4)) : Color.gray.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Server Toggle Card

    private var serverToggleCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote Control Server")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                Text(host.isRunning ? "Accepting incoming connections on port \(host.port)" : "Server stopped. Turn on to allow Android control.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { host.isRunning },
                set: { enabled in
                    if enabled {
                        host.startServer()
                    } else {
                        host.stopServer()
                    }
                }
            ))
            .toggleStyle(.switch)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    // MARK: - Connection Addresses Card

    private var connectionAddressesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("How to Connect from Android")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    host.refreshNetworkAddresses()
                } label: {
                    Label("Refresh IPs", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Enter one of the addresses below into the DroidHouse Android app along with your 6-digit Security PIN.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                // Tailscale / Zero-Config WAN
                if let tailscaleIP = host.tailscaleIPAddress {
                    addressRow(
                        title: "Permanent Tailscale IP (Recommended for WAN)",
                        subtitle: "Static address — never changes across reboots, cellular, or Wi-Fi networks",
                        value: "\(tailscaleIP):\(host.port)",
                        badge: "Permanent WAN",
                        badgeColor: .blue
                    )
                } else {
                    // Tailscale Guide Callout
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "network")
                                .foregroundStyle(Color.blue)
                            Text("Permanent Remote Tunnel (Access from anywhere in the world)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Link("Get Tailscale (Free)", destination: URL(string: "https://tailscale.com/download")!)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.blue)
                        }

                        Text("To control your Mac from outside your house (on 4G/5G or foreign Wi-Fi), install Tailscale on this Mac and on your Android phone using the same login. Your Mac will get a permanent static IP (100.x.y.z) that never changes!")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.1)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.25), lineWidth: 1)))
                }

                // Local Network
                addressRow(
                    title: "Local Wi-Fi Network",
                    subtitle: "Use when phone and Mac are connected to the same router",
                    value: "\(host.localIPAddress):\(host.port)",
                    badge: "LAN",
                    badgeColor: .mint
                )

                // Public Internet / Port Forwarding
                if let wanIP = host.publicWANIPAddress {
                    addressRow(
                        title: "Public Internet IP",
                        subtitle: "Requires port \(host.port) forwarded on your home router",
                        value: "\(wanIP):\(host.port)",
                        badge: "Internet",
                        badgeColor: .purple
                    )
                }
            }

            Divider().padding(.vertical, 4)

            // Security PIN & Password Section (Directly Editable Permanent Access)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Security PIN / Password")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Permanent")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.green.opacity(0.2)))
                                .foregroundStyle(Color.green)
                        }

                        Text("Set your own custom password or PIN (4–32 characters). Persisted permanently in macOS settings.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                // Interactive Editable PIN / Password Field
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.dhAccentMint)

                        TextField("Enter PIN or Password", text: $customPinInput)
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                savePin()
                            }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.65))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(customPinInput != host.pairingPin ? Color.blue.opacity(0.8) : Color.white.opacity(0.15), lineWidth: 1.5)
                            )
                    )

                    Button {
                        savePin()
                    } label: {
                        HStack(spacing: 4) {
                            if showSavedSuccess {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.green)
                                Text("Saved")
                                    .foregroundStyle(.green)
                            } else {
                                Text("Save PIN")
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(customPinInput.trimmingCharacters(in: .whitespacesAndNewlines).count < 4)

                    Button {
                        copyToClipboard(host.pairingPin, label: "PIN")
                    } label: {
                        Image(systemName: copiedItem == "PIN" ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .help("Copy current PIN to clipboard")

                    Button {
                        host.regeneratePin()
                        customPinInput = host.pairingPin
                        showSavedSuccess = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                            showSavedSuccess = false
                        }
                    } label: {
                        Label("Randomize", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .help("Generate new random 6-digit PIN")
                }

                if let err = pinErrorMessage {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red)
                } else if showSavedSuccess {
                    Text("✓ Saved permanently in macOS settings. Use this exact PIN/password in your Android app.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.green)
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    private func addressRow(title: String, subtitle: String, value: String, badge: String, badgeColor: Color) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)

                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(badgeColor.opacity(0.18)))
                }

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))

            Button {
                copyToClipboard(value, label: value)
            } label: {
                Image(systemName: copiedItem == value ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.04), lineWidth: 1))
        )
    }

    // MARK: - Permissions Card

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS System Permissions")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 14) {
                permissionTile(
                    title: "Accessibility",
                    description: "Required to move mouse pointer and type keyboard keys",
                    isGranted: host.isAccessibilityGranted,
                    action: { host.requestAccessibility() }
                )

                permissionTile(
                    title: "Screen Recording",
                    description: "Required for streaming live Mac screen to Android",
                    isGranted: host.isScreenCaptureGranted,
                    action: { host.requestScreenCapture() }
                )
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    private func permissionTile(title: String, description: String, isGranted: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isGranted ? Color.green : Color.orange)
            }

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !isGranted {
                Button("Grant Access", action: action)
                    .font(.system(size: 11, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.small)
            } else {
                Text("Granted")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isGranted ? Color.green.opacity(0.2) : Color.orange.opacity(0.3), lineWidth: 1))
        )
    }

    // MARK: - Live Client Card

    private var liveClientCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Companion Session")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            if let client = host.connectedClientName, host.isClientAuthenticated {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.2))
                            .frame(width: 44, height: 44)
                        Image(systemName: "iphone.gen3")
                            .font(.system(size: 20))
                            .foregroundStyle(.green)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(client)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)

                        Text("IP: \(host.connectedClientIP ?? "Unknown")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if host.roundTripLatencyMs > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(host.roundTripLatencyMs)) ms")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(host.roundTripLatencyMs < 60 ? Color.green : Color.yellow)

                            Text("Round-trip RTT")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Disconnect") {
                        host.stopServer()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            host.startServer()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.green.opacity(0.08))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.green.opacity(0.2), lineWidth: 1))
                )
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)

                    Text("No companion connected. Launch DroidHouse APK on Android and tap Mac Remote to connect.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    // MARK: - Stream Settings Card

    private var streamSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Screen Streaming Preferences")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target Frame Rate: \(host.streamFps) FPS")
                        .font(.system(size: 12, weight: .medium))
                    Slider(
                        value: Binding(
                            get: { Double(host.streamFps) },
                            set: { host.streamFps = Int($0) }
                        ),
                        in: 10...30,
                        step: 5
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("JPEG Quality: \(Int(host.streamQuality * 100))%")
                        .font(.system(size: 12, weight: .medium))
                    Slider(
                        value: $host.streamQuality,
                        in: 0.3...0.8,
                        step: 0.05
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Resolution Scale: \(Int(host.streamScale * 100))%")
                        .font(.system(size: 12, weight: .medium))
                    Slider(
                        value: $host.streamScale,
                        in: 0.4...1.0,
                        step: 0.1
                    )
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    // MARK: - Recent Activity Card

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Activity Log")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(host.recentEvents.count) events")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                if host.recentEvents.isEmpty {
                    Text("No remote events received yet.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(host.recentEvents.prefix(8), id: \.self) { event in
                        Text(event)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.4))
            )
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
        )
    }

    private func copyToClipboard(_ value: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.spring(response: 0.3)) {
            copiedItem = label
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if copiedItem == label {
                withAnimation { copiedItem = nil }
            }
        }
    }

    private func savePin() {
        let trimmed = customPinInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.setCustomPin(trimmed) {
            pinErrorMessage = nil
            showSavedSuccess = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                showSavedSuccess = false
            }
        } else {
            pinErrorMessage = "PIN or Password must be between 4 and 32 characters."
        }
    }
}
