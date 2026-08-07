import SwiftUI

struct OnboardingView: View {
    @ObservedObject var adbService: ADBService
    @Binding var isPresented: Bool
    @State private var currentStep = 0
    @State private var animationPhase: CGFloat = 0
    @State private var pulseAnimation = false
    @State private var autoAdvanceTimer: Timer?
    @State private var dragOffset: CGFloat = 0
    
    let steps: [OnboardingStep] = [
        OnboardingStep(
            title: "Connect Your Android Device",
            description: "Enable USB Debugging to get started",
            icon: "cable.connector",
            type: .setup,
            instructions: [
                "Go to Settings → About Phone",
                "Tap \"Build Number\" 7 times",
                "Go to Settings → Developer Options",
                "Enable \"USB Debugging\"",
                "Connect via USB cable"
            ]
        ),
        OnboardingStep(
            title: "Wireless Connection",
            description: "Connect wirelessly for cable-free management",
            icon: "wifi",
            type: .setup,
            instructions: [
                "Connect device via USB first",
                "Enable \"Wireless Debugging\" in Developer Options",
                "Click the wireless icon in Droid House",
                "Your device connects automatically"
            ]
        ),
        OnboardingStep(
            title: "Powerful Features",
            description: "Everything you need to manage your Android files",
            icon: "star.fill",
            type: .features,
            features: [
                FeatureItem(icon: "arrow.up.arrow.down.circle.fill", title: "Drag & Drop", description: "Seamlessly transfer files"),
                FeatureItem(icon: "eye.fill", title: "Quick Look", description: "Preview with Space bar"),
                FeatureItem(icon: "star.fill", title: "Bookmarks", description: "Save favorite folders"),
                FeatureItem(icon: "folder.fill.badge.plus", title: "Folder Upload", description: "Upload entire directories"),
                FeatureItem(icon: "doc.on.doc.fill", title: "Copy Files", description: "Use Cmd+C to copy"),
                FeatureItem(icon: "photo.on.rectangle.angled", title: "Thumbnails", description: "Fast image previews")
            ]
        )
    ]
    
    var body: some View {
        ZStack {
            // Blurred background
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            Color.black.opacity(0.6)
                .ignoresSafeArea()
            
            // Content card
            VStack(spacing: 0) {
                // Close button
                HStack {
                    Spacer()
                    Button {
                        stopAutoAdvance()
                        withAnimation(.spring(response: 0.3)) {
                            isPresented = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding()
                }
                
                // Sliding content
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        ForEach(0..<steps.count, id: \.self) { index in
                            if steps[index].type == .features {
                                FeaturesStepView(
                                    step: steps[index],
                                    isActive: index == currentStep,
                                    animationPhase: $animationPhase
                                )
                                .frame(width: geometry.size.width)
                            } else {
                                OnboardingStepView(
                                    step: steps[index],
                                    isActive: index == currentStep,
                                    animationPhase: $animationPhase,
                                    pulseAnimation: $pulseAnimation
                                )
                                .frame(width: geometry.size.width)
                            }
                        }
                    }
                    .offset(x: -CGFloat(currentStep) * geometry.size.width + dragOffset)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8), value: currentStep)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                stopAutoAdvance()
                                dragOffset = value.translation.width
                            }
                            .onEnded { value in
                                let threshold: CGFloat = 50
                                if value.translation.width < -threshold && currentStep < steps.count - 1 {
                                    currentStep += 1
                                } else if value.translation.width > threshold && currentStep > 0 {
                                    currentStep -= 1
                                }
                                dragOffset = 0
                            }
                    )
                }
                
                // Page indicators
                HStack(spacing: 8) {
                    ForEach(0..<steps.count, id: \.self) { index in
                        Circle()
                            .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                            .scaleEffect(index == currentStep ? 1.2 : 1.0)
                            .animation(.spring(response: 0.3), value: currentStep)
                    }
                }
                .padding(.vertical, 20)
                
                // Navigation
                HStack(spacing: 20) {
                    if currentStep > 0 {
                        Button("Back") {
                            stopAutoAdvance()
                            withAnimation(.spring(response: 0.3)) {
                                currentStep -= 1
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    
                    Spacer()
                    
                    Button(currentStep < steps.count - 1 ? "Skip" : "Get Started") {
                        stopAutoAdvance()
                        withAnimation(.spring(response: 0.3)) {
                            if currentStep < steps.count - 1 {
                                currentStep = steps.count - 1
                            } else {
                                isPresented = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(24)
            }
            .frame(width: 700, height: 600)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 10)
            )
        }
        .onAppear {
            startAnimations()
            startAutoAdvance()
        }
        .onDisappear {
            stopAutoAdvance()
        }
    }
    
    private func startAnimations() {
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
            animationPhase = 1
        }
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            pulseAnimation = true
        }
    }
    
    private func startAutoAdvance() {
        autoAdvanceTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                if currentStep < steps.count - 1 {
                    currentStep += 1
                } else {
                    stopAutoAdvance()
                }
            }
        }
    }
    
    private func stopAutoAdvance() {
        autoAdvanceTimer?.invalidate()
        autoAdvanceTimer = nil
    }
}

enum StepType {
    case setup
    case features
}

struct OnboardingStep {
    let title: String
    let description: String
    let icon: String
    let type: StepType
    var instructions: [String] = []
    var features: [FeatureItem] = []
}

struct FeatureItem {
    let icon: String
    let title: String
    let description: String
}

struct FeaturesStepView: View {
    let step: OnboardingStep
    let isActive: Bool
    @Binding var animationPhase: CGFloat
    @State private var featureAnimations: [Bool] = Array(repeating: false, count: 6)
    
    var body: some View {
        VStack(spacing: 16) {
            // Animated Icon with particles
            ZStack {
                // Particle effects
                ForEach(0..<12) { index in
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.6), Color.accentColor.opacity(0)],
                                startPoint: .center,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 6, height: 6)
                        .offset(
                            x: cos(Double(index) * .pi / 6) * (isActive ? 60 : 0),
                            y: sin(Double(index) * .pi / 6) * (isActive ? 60 : 0)
                        )
                        .opacity(isActive ? 0 : 1)
                        .animation(
                            .easeOut(duration: 1.5)
                            .delay(Double(index) * 0.05)
                            .repeatForever(autoreverses: false),
                            value: isActive
                        )
                }
                
                // Main icon with glow
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.accentColor.opacity(0.3),
                                    Color.accentColor.opacity(0.1),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 30,
                                endRadius: 60
                            )
                        )
                        .frame(width: 120, height: 120)
                        .scaleEffect(isActive ? 1.2 : 1.0)
                        .opacity(isActive ? 0.8 : 0.4)
                        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: isActive)
                    
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 90, height: 90)
                    
                    Image(systemName: step.icon)
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .symbolEffect(.bounce, value: isActive)
                        .rotationEffect(.degrees(isActive ? 360 : 0))
                        .animation(.easeInOut(duration: 20).repeatForever(autoreverses: false), value: isActive)
                }
            }
            .frame(height: 110)
            
            // Title and description
            VStack(spacing: 8) {
                Text(step.title)
                    .font(.system(size: 26, weight: .bold))
                
                Text(step.description)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 4)
            
            // Features grid with staggered animations
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 20),
                GridItem(.flexible(), spacing: 20)
            ], spacing: 14) {
                ForEach(Array(step.features.enumerated()), id: \.offset) { index, feature in
                    FeatureCard(
                        feature: feature,
                        isAnimating: featureAnimations[index]
                    )
                }
            }
            .padding(.horizontal, 50)
            
            Spacer(minLength: 0)
        }
        .padding(.top, 5)
        .onAppear {
            if isActive {
                startFeatureAnimations()
            }
        }
        .onChange(of: isActive) { _, newValue in
            if newValue {
                startFeatureAnimations()
            }
        }
    }
    
    private func startFeatureAnimations() {
        for index in 0..<featureAnimations.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.1) {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                    featureAnimations[index] = true
                }
            }
        }
    }
}

struct FeatureCard: View {
    let feature: FeatureItem
    let isAnimating: Bool
    @State private var isHovering = false
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(isHovering ? 0.3 : 0.15),
                                Color.accentColor.opacity(isHovering ? 0.2 : 0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)
                    .scaleEffect(isHovering ? 1.1 : 1.0)
                
                Image(systemName: feature.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.bounce, value: isHovering)
            }
            
            Text(feature.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            
            Text(feature.description)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(isHovering ? 0.4 : 0.2),
                                    Color.accentColor.opacity(isHovering ? 0.2 : 0.1)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )
        )
        .scaleEffect(isAnimating ? 1.0 : 0.8)
        .opacity(isAnimating ? 1.0 : 0.0)
        .offset(y: isAnimating ? 0 : 20)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovering = hovering
            }
        }
    }
}

struct OnboardingStepView: View {
    let step: OnboardingStep
    let isActive: Bool
    @Binding var animationPhase: CGFloat
    @Binding var pulseAnimation: Bool
    
    var body: some View {
        VStack(spacing: 32) {
            // Animated Icon
            ZStack {
                // Pulse rings
                if step.icon == "cable.connector" || step.icon == "wifi" {
                    ForEach(0..<3) { index in
                        Circle()
                            .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                            .frame(width: 120 + CGFloat(index) * 40, height: 120 + CGFloat(index) * 40)
                            .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                            .opacity(pulseAnimation ? 0 : 0.5)
                            .animation(
                                .easeOut(duration: 2)
                                .repeatForever(autoreverses: false)
                                .delay(Double(index) * 0.3),
                                value: pulseAnimation
                            )
                    }
                }
                
                // Main icon
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: step.icon)
                        .font(.system(size: 50))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, value: isActive)
                }
                
                // Connection animation for cable/wifi
                if step.icon == "cable.connector" {
                    HStack(spacing: 20) {
                        Image(systemName: "iphone.gen2")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                            .offset(x: animationPhase * -10)
                        
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: 30))
                            .foregroundStyle(.secondary)
                            .offset(x: animationPhase * 10)
                    }
                    .offset(y: 100)
                } else if step.icon == "wifi" {
                    HStack(spacing: 40) {
                        VStack {
                            Image(systemName: "iphone.gen2")
                                .font(.system(size: 30))
                            Image(systemName: "wifi.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.green)
                                .opacity(animationPhase)
                        }
                        
                        VStack {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 30))
                            Image(systemName: "wifi.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(.green)
                                .opacity(animationPhase)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .offset(y: 100)
                }
            }
            .frame(height: 200)
            
            // Title and description
            VStack(spacing: 12) {
                Text(step.title)
                    .font(.system(size: 24, weight: .bold))
                
                Text(step.description)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Instructions
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(step.instructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.15))
                                .frame(width: 24, height: 24)
                            
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        
                        Text(instruction)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .padding(.top, 20)
    }
}

#Preview {
    OnboardingView(adbService: ADBService(), isPresented: .constant(true))
}
