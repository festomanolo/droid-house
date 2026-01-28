import SwiftUI

struct SettingsView: View {
    @AppStorage("appThemeColor") private var appThemeColor: String = "blue"
    @AppStorage("folderIconColor") private var folderIconColor: String = "blue"
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedTab: SettingsTab = .appearance
    @State private var isLaunched = false
    @State private var shakeOffset: CGFloat = 0
    @State private var glowOpacity: Double = 0.5
    
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
        }
        .formStyle(.grouped)
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
                Text("festomanolo")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [themeColor, themeColor.opacity(0.7), .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Text("Lead Developer & Visionary")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Text("Building the future of Android management on macOS. Passionate about clean code, high performance, and premium user experiences.")
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .padding(.horizontal, 40)
                .lineSpacing(4)
            
            Spacer()
            
            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/festomanolo")!) {
                    Label("GitHub", systemImage: "link")
                }
                .buttonStyle(.bordered)
                
                Link(destination: URL(string: "https://twitter.com/festomanolo")!) {
                    Label("Twitter", systemImage: "link")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
            
            Text("Version 1.2.0 • Made with ❤️ in 2026")
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
                    .fill(.green.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.green)
            }
            
            VStack(spacing: 10) {
                Text("You're all set!")
                    .font(.title2.weight(.bold))
                
                Text("Droid House is currently up to date.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Button {
                // Action for manual check
            } label: {
                Text("Check for Updates")
                    .padding(.horizontal, 20)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            Spacer()
        }
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
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            withAnimation(.interactiveSpring(response: 0.1, dampingFraction: 0.1)) {
                shakeOffset = CGFloat.random(in: -2...2)
            }
        }
    }
}

#Preview {
    SettingsView()
}
