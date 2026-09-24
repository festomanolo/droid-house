import SwiftUI

struct SettingsView: View {
    @AppStorage("appThemeColor") private var appThemeColor: String = "blue"
    @AppStorage("folderIconColor") private var folderIconColor: String = "blue"
    @AppStorage(ADBLocator.overrideKey) private var adbOverride: String = ""
    @State private var adbResolvedPath: String = "adb"
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: SettingsTab = .appearance
    @State private var isLaunched = false
    @State private var shakeOffset: CGFloat = 0
    @State private var glowOpacity: Double = 0.5
    @State private var shakeTimer: Timer?
    @State private var updateState: UpdateState = .idle

    enum UpdateState: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
    }

    private let currentVersion = "1.2.0"
    private let releasesURL = URL(string: "https://github.com/festomanolo/droidhouse/releases")!
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case about = "About"
        case updates = "Updates"
        
        var id: String { self.rawValue }
        var icon: String {
            switch self {
            case .appearance: return "paintpalette"
            case .about: return "person.circle"
            case .updates: return "arrow.triangle.2.circlepath"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header / Custom Tab Bar (Safari Style)
            HStack(spacing: 0) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(8)
                        .background(Circle().fill(.quaternary.opacity(0.5)))
                }
                .buttonStyle(.plain)
                .help("Back")
                
                Spacer()
                
                // Safari-style Tab Picker
                HStack(spacing: 4) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedTab = tab
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 12))
                                Text(tab.rawValue)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background {
                                if selectedTab == tab {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.1))
                                        .matchedGeometryEffect(id: "tab", in: tabNamespace)
                                }
                            }
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Capsule().fill(.ultraThinMaterial))
                
                Spacer()
                
                Button("Apply") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            
            Divider()
            
            // Content Area
            ZStack {
                switch selectedTab {
                case .appearance:
                    appearanceSettings
                        .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .move(edge: .trailing).combined(with: .opacity)))
                case .about:
                    aboutSettings
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                case .updates:
                    updatesSettings
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 550, height: 450)
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        .scaleEffect(isLaunched ? 1 : 0.95)
        .opacity(isLaunched ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                isLaunched = true
            }
        }
        .onDisappear {
            shakeTimer?.invalidate()
            shakeTimer = nil
        }
    }
    
    @Namespace private var tabNamespace
    
    // MARK: - Appearance
    
    private var appearanceSettings: some View {
        Form {
            Section("Color Scheme") {
                Picker("Accent Color", selection: $appThemeColor) {
                    ForEach(["blue", "purple", "pink", "red", "orange", "green", "gray"], id: \.self) { color in
                        Text(color.capitalized).tag(color)
                    }
                }
                .pickerStyle(.inline)
            }

            Section("Icon Customization") {
                Picker("Folder Color", selection: $folderIconColor) {
                    ForEach(["blue", "purple", "yellow", "gray", "green", "red"], id: \.self) { color in
                        Text(color.capitalized).tag(color)
                    }
                }
                .pickerStyle(.inline)
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: adbResolvedPath.hasPrefix("/") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(adbResolvedPath.hasPrefix("/") ? .green : .orange)
                    Text(adbResolvedPath.hasPrefix("/") ? adbResolvedPath : "adb not found on PATH")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }

                TextField("Custom adb path (optional)", text: $adbOverride)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { adbResolvedPath = ADBLocator.refresh() }

                HStack {
                    Button("Re-detect") {
                        adbResolvedPath = ADBLocator.refresh()
                    }
                    .controlSize(.small)
                    Spacer()
                    Text("Applies on next launch or re-detect")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("Command-Line Tools")
            } footer: {
                Text("DroidHouse auto-detects adb, including custom install locations. Set a path here only if detection fails.")
                    .font(.caption2)
            }
        }
        .formStyle(.grouped)
        .onAppear { adbResolvedPath = ADBLocator.resolve() }
    }
    
    // MARK: - About
    
    private var aboutSettings: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // Profile with Effects
            ZStack {
                // Lighting Effect (Glow)
                Circle()
                    .fill(themeColor.opacity(0.3))
                    .frame(width: 140, height: 140)
                    .blur(radius: 20)
                    .opacity(glowOpacity)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                            glowOpacity = 0.8
                        }
                    }
                
                // Profile Image
                Image("festomanolo")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(themeColor.opacity(0.5), lineWidth: 4))
                    .shadow(color: themeColor.opacity(0.5), radius: 10)
                    // Earthquake Effect
                    .offset(x: shakeOffset)
                    .onAppear {
                        startEarthquakeEffect()
                    }
            }
            
            VStack(spacing: 8) {
                Text("Tech-X")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [themeColor, themeColor.opacity(0.7), .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Text("Made by festomanolo from Tech-X")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            
            Text("Building the future of Android management and remote spatial control on macOS. High-performance device bridging, native CoreAudio routing, and ultra-low latency desktop streaming.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal, 40)
                .lineSpacing(4)
            
            Spacer()
            
            HStack(spacing: 16) {
                Link(destination: URL(string: "mailto:festomanolofm@gmail.com")!) {
                    Label("festomanolofm@gmail.com", systemImage: "envelope.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
            
            Text("Version 2.0 • Made by festomanolo from Tech-X • 2026")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
    }
    
    // MARK: - Updates
    
    private var updatesSettings: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(updateAccent.opacity(0.1))
                    .frame(width: 100, height: 100)

                if updateState == .checking {
                    ProgressView().controlSize(.large)
                } else {
                    Image(systemName: updateSymbol)
                        .font(.system(size: 50))
                        .foregroundStyle(updateAccent)
                        .contentTransition(.symbolEffect(.replace))
                }
            }

            VStack(spacing: 10) {
                Text(updateTitle)
                    .font(.title2.weight(.bold))
                    .contentTransition(.numericText())

                Text(updateSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            if case .available = updateState {
                Button {
                    NSWorkspace.shared.open(releasesURL)
                } label: {
                    Text("Download Update").padding(.horizontal, 20)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    checkForUpdates()
                } label: {
                    Text("Check for Updates").padding(.horizontal, 20)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(updateState == .checking)
            }

            Spacer()
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: updateState)
    }

    private var updateAccent: Color {
        switch updateState {
        case .available: return .orange
        case .checking:  return .secondary
        default:         return .green
        }
    }

    private var updateSymbol: String {
        switch updateState {
        case .available: return "arrow.down.circle.fill"
        case .checking:  return "arrow.triangle.2.circlepath"
        default:         return "checkmark.seal.fill"
        }
    }

    private var updateTitle: String {
        switch updateState {
        case .idle:               return "Version \(currentVersion)"
        case .checking:           return "Checking…"
        case .upToDate:           return "You're all set!"
        case .available:          return "Update available"
        }
    }

    private var updateSubtitle: String {
        switch updateState {
        case .idle:              return "Droid House is installed and ready."
        case .checking:          return "Contacting the update server…"
        case .upToDate:          return "Droid House \(currentVersion) is the latest version."
        case .available(let v):  return "Version \(v) is ready to download."
        }
    }

    /// Queries the GitHub Releases API for the latest published tag and
    /// compares it to the running version.
    private func checkForUpdates() {
        updateState = .checking
        Task {
            let latest = await fetchLatestVersion()
            await MainActor.run {
                guard let latest else {
                    updateState = .upToDate // network failure -> assume current
                    return
                }
                if isNewer(latest, than: currentVersion) {
                    updateState = .available(latest)
                } else {
                    updateState = .upToDate
                }
            }
        }
    }

    private func fetchLatestVersion() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/festomanolo/droidhouse/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            return nil
        }
        return tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
    }

    /// Semantic-ish version comparison ("1.3.0" > "1.2.0").
    private func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let lhs = i < a.count ? a[i] : 0
            let rhs = i < b.count ? b[i] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
    
    // MARK: - Helper Functions
    
    private var themeColor: Color {
        switch appThemeColor {
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "green": return .green
        case "gray": return .gray
        default: return .blue
        }
    }
    
    private func startEarthquakeEffect() {
        shakeTimer?.invalidate()
        shakeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            withAnimation(.interactiveSpring(response: 0.1, dampingFraction: 0.1)) {
                shakeOffset = CGFloat.random(in: -2...2)
            }
        }
    }
}

#Preview {
    SettingsView()
}
