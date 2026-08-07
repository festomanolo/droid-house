import SwiftUI

// MARK: - Chat Bubble
//
// Arrival is a multi-step, *discrete* sequence — settle → overshoot → rest —
// which is exactly what `PhaseAnimator` models: named states with a distinct
// animation per transition, rather than one interpolation from A to B.
//
// The reaction pop layered on top is continuous and needs precise control at
// specific instants, so that one uses `KeyframeAnimator`.

struct ChatBubble: View {
    let message: SMSMessage

    /// True only for a message that genuinely just arrived, so a thread switch
    /// doesn't replay the entrance for the whole backlog.
    var isFreshArrival: Bool = false

    /// The message this one is answering, resolved from its `RE:` tag.
    var quotedMessage: SMSMessage? = nil

    /// Invoked when the user starts a reply to this message.
    var onReply: ((SMSMessage) -> Void)? = nil

    /// Scrolls to the quoted original when its preview is clicked.
    var onJumpToQuoted: ((SMSMessage) -> Void)? = nil

    /// Delivery state for locally-composed messages; `nil` means delivered.
    var deliveryState: MessageDeliveryState? = nil

    var onRetry: ((SMSMessage) -> Void)? = nil
    var onDiscard: ((SMSMessage) -> Void)? = nil

    @State private var isHovering = false
    @State private var showsActions = false
    @State private var showsTimestamp = false
    @State private var reactionTrigger = 0
    @State private var hideActionsTask: Task<Void, Never>?

    /// How long the reply affordance lingers after the pointer leaves.
    ///
    /// Without this the button vanishes the moment the cursor crosses the gap
    /// toward it, which makes it effectively unclickable.
    private static let actionLingerSeconds: Double = 3.0

    /// The tag parsed out of the body, if this is a threaded reply.
    private var replyTag: ReplyTag.Parsed? {
        ReplyTag.parse(message.body)
    }

    // MARK: Entry phases

    private enum ArrivalPhase: CaseIterable {
        case offstage   // just below, small, transparent
        case landing    // overshoots slightly past its resting size
        case settled    // at rest

        var scale: CGFloat {
            switch self {
            case .offstage: return 0.82
            case .landing:  return 1.045
            case .settled:  return 1.0
            }
        }

        var offsetY: CGFloat {
            switch self {
            case .offstage: return 16
            case .landing:  return -3
            case .settled:  return 0
            }
        }

        var opacity: Double {
            switch self {
            case .offstage: return 0
            case .landing:  return 1
            case .settled:  return 1
            }
        }

        var blur: CGFloat {
            switch self {
            case .offstage: return 6
            case .landing:  return 0
            case .settled:  return 0
            }
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if message.isOutgoing {
                Spacer(minLength: 40)
                replyAffordance
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                bubble
                if let deliveryState, deliveryState != .sent {
                    deliveryFooter(deliveryState)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if showsTimestamp || showsActions {
                    timestamp
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            if !message.isOutgoing {
                replyAffordance
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        // Hover is tracked on the whole row — including the reply button — so
        // moving the pointer from bubble to button never counts as leaving.
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                hideActionsTask?.cancel()
                hideActionsTask = nil
                withAnimation(Spatial.Motion.crisp) { showsActions = true }
            } else {
                scheduleActionsHide()
            }
        }
        .onDisappear {
            hideActionsTask?.cancel()
            hideActionsTask = nil
        }
        .animation(Spatial.Motion.fluid, value: deliveryState)
    }

    /// Keeps the actions up for a beat after the pointer leaves, then fades
    /// them — cancelled if the pointer comes back in the meantime.
    private func scheduleActionsHide() {
        hideActionsTask?.cancel()
        hideActionsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.actionLingerSeconds))
            guard !Task.isCancelled, !isHovering else { return }
            withAnimation(Spatial.Motion.fluid) { showsActions = false }
        }
    }

    // MARK: Delivery state

    @ViewBuilder
    private func deliveryFooter(_ state: MessageDeliveryState) -> some View {
        switch state {
        case .sending:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                Text("Sending…")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 5)

        case .sent:
            EmptyView()

        case .failed(let reason):
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8.5))
                    Text("Not delivered")
                        .font(.system(size: 9.5, weight: .semibold))
                }
                .foregroundStyle(.orange)

                Text(reason)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: message.isOutgoing ? .trailing : .leading)
                    .multilineTextAlignment(message.isOutgoing ? .trailing : .leading)

                HStack(spacing: 6) {
                    if let onRetry {
                        Button("Retry") { onRetry(message) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .cursor(.interactive)
                    }
                    if let onDiscard {
                        Button("Discard") { onDiscard(message) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .cursor(.interactive)
                    }
                }
            }
            .padding(.horizontal, 5)
        }
    }

    /// Reply button that fades in on hover, mirrored to the side of the bubble
    /// the message sits on.
    @ViewBuilder
    private var replyAffordance: some View {
        if let onReply {
            Button {
                onReply(message)
            } label: {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7))
            }
            .buttonStyle(.plain)
            .cursor(.interactive)
            .opacity(showsActions ? 1 : 0)
            .scaleEffect(showsActions ? 1 : 0.6)
            .animation(Spatial.Motion.bouncy, value: showsActions)
            // Zero-size when hidden so it can't eat clicks meant for the bubble.
            .allowsHitTesting(showsActions)
            .help("Reply to this message")
            .accessibilityLabel("Reply")
        }
    }

    // MARK: Bubble body

    private var bubble: some View {
        PhaseAnimator(
            ArrivalPhase.allCases,
            trigger: isFreshArrival
        ) { phase in
            bubbleContent
                .scaleEffect(
                    isFreshArrival ? phase.scale : 1.0,
                    anchor: message.isOutgoing ? .bottomTrailing : .bottomLeading
                )
                .offset(y: isFreshArrival ? phase.offsetY : 0)
                .opacity(isFreshArrival ? phase.opacity : 1)
                .blur(radius: isFreshArrival ? phase.blur : 0)
        } animation: { phase in
            // A distinct spring per leg: a quick, snappy rise into the
            // overshoot, then a soft, heavily-damped settle out of it.
            switch phase {
            case .offstage: return .spring(response: 0.01, dampingFraction: 1)
            case .landing:  return .spring(response: 0.34, dampingFraction: 0.62)
            case .settled:  return .spring(response: 0.42, dampingFraction: 0.86)
            }
        }
    }

    private var bubbleContent: some View {
        let bubbleShape = UnevenRoundedRectangle(
            cornerRadii: message.isOutgoing
                ? RectangleCornerRadii(topLeading: 18, bottomLeading: 18, bottomTrailing: 4, topTrailing: 18)
                : RectangleCornerRadii(topLeading: 18, bottomLeading: 4, bottomTrailing: 18, topTrailing: 18),
            style: .continuous
        )

        return VStack(alignment: .leading, spacing: 6) {
            if let tag = replyTag {
                quotePreview(tag)
            }

            Text(ReplyTag.displayBody(message.body))
                .font(.system(size: 13))
                .foregroundStyle(message.isOutgoing ? Color.white : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .frame(maxWidth: 460, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(bubbleBackground)
            .overlay(alignment: message.isOutgoing ? .bottomTrailing : .bottomLeading) {
                reactionPop
            }
            .scaleEffect(showsActions ? 1.014 : 1.0)
            .animation(Spatial.Motion.crisp, value: showsActions)
            .contentShape(bubbleShape)
            .onTapGesture {
                withAnimation(Spatial.Motion.bouncy) { showsTimestamp.toggle() }
                reactionTrigger += 1
            }
            .cursor(.interactive)
            .contextMenu {
                if let onReply {
                    Button("Reply") { onReply(message) }
                }
                Button("Copy Message") {
                    NSPasteboard.general.clearContents()
                    // Copy what's shown, not the wire form with its RE: tag.
                    NSPasteboard.general.setString(ReplyTag.displayBody(message.body), forType: .string)
                }
                if replyTag != nil {
                    Button("Copy Raw (with tag)") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.body, forType: .string)
                    }
                }
            }
    }

    /// The quoted line, rendered as an accent-barred excerpt above the reply.
    /// Clicking it jumps to the original when we managed to resolve it.
    private func quotePreview(_ tag: ReplyTag.Parsed) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(message.isOutgoing ? Color.white.opacity(0.75) : Color.accentColor)
                .frame(width: 2.5)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(quoteAuthor)
                        .font(.system(size: 9.5, weight: .bold))
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 7))
                }
                .foregroundStyle(message.isOutgoing ? Color.white.opacity(0.85) : Color.accentColor)

                // Always exactly one line — the excerpt was truncated on the
                // wire precisely so it can never wrap here.
                Text(tag.quote + (tag.quoteWasTruncated ? ReplyTag.ellipsis : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(message.isOutgoing ? Color.white.opacity(0.7) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(message.isOutgoing ? Color.white.opacity(0.16) : Color.primary.opacity(0.07))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            guard let quotedMessage, let onJumpToQuoted else { return }
            onJumpToQuoted(quotedMessage)
        }
        .cursor(quotedMessage != nil ? .interactive : .standard)
        .help(quotedMessage != nil ? "Jump to the quoted message" : tag.quote)
    }

    private var quoteAuthor: String {
        guard let quotedMessage else { return "Reply" }
        return quotedMessage.isOutgoing ? "You" : quotedMessage.sender
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        let shape = UnevenRoundedRectangle(
            cornerRadii: message.isOutgoing
                ? RectangleCornerRadii(topLeading: 18, bottomLeading: 18, bottomTrailing: 4, topTrailing: 18)
                : RectangleCornerRadii(topLeading: 18, bottomLeading: 4, bottomTrailing: 18, topTrailing: 18),
            style: .continuous
        )

        if message.isOutgoing {
            shape
                .fill(
                    LinearGradient(
                        colors: [Color.dhAccentGreen, Color.dhAccentGreen.opacity(0.88)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    // Specular top edge — the same "lit from above" cue the
                    // rest of the app's glass uses.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
                }
                .shadow(
                    color: Color.dhAccentGreen.opacity(showsActions ? 0.42 : 0.22),
                    radius: showsActions ? 9 : 4,
                    y: 2
                )
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay { shape.fill(Color.dhGlassTint) }
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(showsActions ? 0.16 : 0.08), radius: showsActions ? 7 : 3, y: 2)
        }
    }

    // MARK: Reaction pop (KeyframeAnimator)

    /// A ring that blooms outward and fades when the bubble is tapped.
    /// Keyframes let the scale, opacity and rotation each run their own curve
    /// on their own schedule — which is the whole point of the API.
    private var reactionPop: some View {
        KeyframeAnimator(
            initialValue: PopState(),
            trigger: reactionTrigger
        ) { state in
            Circle()
                .strokeBorder(
                    (message.isOutgoing ? Color.white : Color.dhAccentGreen)
                        .opacity(state.opacity),
                    lineWidth: 2
                )
                .frame(width: 26, height: 26)
                .scaleEffect(state.scale)
                .rotationEffect(.degrees(state.rotation))
                .offset(x: message.isOutgoing ? 8 : -8, y: 8)
                .allowsHitTesting(false)
        } keyframes: { _ in
            KeyframeTrack(\PopState.scale) {
                SpringKeyframe(1.5, duration: 0.28, spring: .bouncy)
                CubicKeyframe(2.4, duration: 0.36)
            }
            KeyframeTrack(\PopState.opacity) {
                LinearKeyframe(0.0, duration: 0.02)
                CubicKeyframe(0.85, duration: 0.16)
                CubicKeyframe(0.0, duration: 0.46)
            }
            KeyframeTrack(\PopState.rotation) {
                LinearKeyframe(0, duration: 0.02)
                CubicKeyframe(90, duration: 0.62)
            }
        }
    }

    private struct PopState {
        var scale: CGFloat = 0.2
        var opacity: Double = 0
        var rotation: Double = 0
    }

    // MARK: Double Tick Delivery Report

    @ViewBuilder
    private var doubleTick: some View {
        HStack(spacing: -3.5) {
            Image(systemName: "checkmark")
                .font(.system(size: 7.5, weight: .bold))
            Image(systemName: "checkmark")
                .font(.system(size: 7.5, weight: .bold))
        }
        .foregroundStyle(Color.dhAccentGreen.opacity(0.95))
    }

    // MARK: Timestamp

    private var timestamp: some View {
        HStack(spacing: 4) {
            if message.isOutgoing {
                doubleTick
            }
            Text(message.timestamp, format: .dateTime.hour().minute())
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 5)
    }
}

// MARK: - Typing indicator

/// Three dots stepping through discrete phases — again a natural fit for
/// `PhaseAnimator`, since "which dot is up" is a discrete state, not a value
/// to interpolate.
struct TypingIndicator: View {
    var body: some View {
        PhaseAnimator([0, 1, 2, 3]) { active in
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary.opacity(index == active ? 0.85 : 0.35))
                        .frame(width: 6, height: 6)
                        .scaleEffect(index == active ? 1.35 : 1.0)
                        .offset(y: index == active ? -2 : 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .glassSurface(.surface)
        } animation: { _ in
            .spring(response: 0.26, dampingFraction: 0.6)
        }
    }
}

#Preview {
    VStack(spacing: 6) {
        ChatBubble(message: SMSMessage(
            id: "1", conversationId: "t", sender: "Alex",
            body: "The AeroCast bridge is live — screen and audio both.",
            timestamp: Date(), isOutgoing: false
        ))
        ChatBubble(message: SMSMessage(
            id: "2", conversationId: "t", sender: "Me",
            body: "Beautiful. Ship it.",
            timestamp: Date(), isOutgoing: true
        ), isFreshArrival: true)
        HStack { TypingIndicator(); Spacer() }.padding(.horizontal, 14)
    }
    .padding(.vertical, 20)
    .frame(width: 460)
    .background(Color.dhSubstrate)
}
