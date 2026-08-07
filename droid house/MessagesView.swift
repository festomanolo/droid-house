import SwiftUI

struct MessagesView: View {
    @ObservedObject var companionSync = CompanionSync.shared
    @ObservedObject var smartReply = SmartReplyEngine.shared
    let selectedContact: Contact?

    @State private var messageText: String = ""
    @State private var replyingTo: SMSMessage?
    @State private var hasPositionedThread = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let contact = selectedContact {
                chatHeader(for: contact)
                Divider().opacity(0.5)
                thread
                Divider().opacity(0.5)
                composer(for: contact)
            } else {
                emptySelection
            }
        }
        .background {
            ZStack {
                Color.dhSubstrate
                LinearGradient(
                    colors: [Color.dhAccentBlue.opacity(0.07), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
            }
            .ignoresSafeArea()
        }
        .task(id: selectedContact?.id) {
            guard let contact = selectedContact else { return }
            messageText = ""
            replyingTo = nil
            // Reset so the new thread jumps to its newest message rather than
            // inheriting the previous thread's scroll position.
            hasPositionedThread = false
            try? await companionSync.fetchMessages(for: contact.id)
            smartReply.refresh(thread: companionSync.activeMessages, contact: contact)
        }
        .onChange(of: companionSync.activeMessages) { _, messages in
            smartReply.refresh(thread: messages, contact: selectedContact)
        }
    }

    // MARK: - Header

    private func chatHeader(for contact: Contact) -> some View {
        HStack(spacing: 11) {
            ContactAvatar(name: contact.name, size: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(contact.phoneNumber)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            connectionBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(companionSync.isConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .shadow(color: (companionSync.isConnected ? Color.green : Color.orange).opacity(0.7),
                        radius: 4)

            Text(badgeText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .glassSurface(.floating)
        .help(companionSync.statusMessage)
    }

    private var badgeText: String {
        if !companionSync.isConnected { return "Demo data" }
        if !companionSync.hasSMSAccess { return "SMS not granted" }
        return "Live SMS"
    }

    // MARK: - Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(companionSync.activeMessages) { message in
                        ChatBubble(
                            message: message,
                            isFreshArrival: message.id == companionSync.latestArrivalID,
                            quotedMessage: ReplyTag.resolveQuotedMessage(
                                for: message,
                                in: companionSync.activeMessages
                            ),
                            onReply: { target in
                                withAnimation(Spatial.Motion.bouncy) { replyingTo = target }
                                isInputFocused = true
                            },
                            onJumpToQuoted: { target in
                                withAnimation(Spatial.Motion.fluid) {
                                    proxy.scrollTo(target.id, anchor: .center)
                                }
                            },
                            deliveryState: companionSync.deliveryStates[message.id],
                            onRetry: { companionSync.retrySend(messageID: $0.id) },
                            onDiscard: { companionSync.discardFailed(messageID: $0.id) }
                        )
                        .id(message.id)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: message.isOutgoing ? .trailing : .leading)
                                    .combined(with: .opacity)
                                    .combined(with: .scale(scale: 0.9)),
                                removal: .opacity
                            )
                        )
                    }

                    // Anchor for "scroll to the very bottom" with generous padding
                    // so the last bubble, timestamp, and delivery ticks are 100% visible.
                    Color.clear
                        .frame(height: 36)
                        .id(Self.bottomAnchor)
                }
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
            .animation(Spatial.Motion.bouncy, value: companionSync.activeMessages)
            .onChange(of: companionSync.activeMessages) { _, messages in
                guard !messages.isEmpty else { return }
                scrollToBottom(proxy: proxy, animated: hasPositionedThread)
                hasPositionedThread = true
            }
            .onChange(of: replyingTo) { _, _ in
                scrollToBottom(proxy: proxy, animated: true)
            }
            .onChange(of: isInputFocused) { _, _ in
                scrollToBottom(proxy: proxy, animated: true)
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = false) {
        let performScroll = {
            if animated {
                withAnimation(Spatial.Motion.fluid) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }

        performScroll()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            performScroll()
            try? await Task.sleep(for: .milliseconds(150))
            performScroll()
        }
    }

    private static let bottomAnchor = "thread-bottom-anchor"

    // MARK: - Composer

    private func composer(for contact: Contact) -> some View {
        VStack(spacing: 8) {
            if let error = companionSync.lastSyncError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if !smartReply.suggestions.isEmpty && messageText.isEmpty {
                smartReplyStrip(for: contact)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let replyingTo {
                replyBanner(replyingTo)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 10) {
                TextField(replyingTo == nil ? "Message" : "Reply", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($isInputFocused)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .overlay {
                                RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    .strokeBorder(
                                        isInputFocused
                                            ? Color.accentColor.opacity(0.55)
                                            : Color.primary.opacity(0.12),
                                        lineWidth: 1
                                    )
                            }
                    }
                    .animation(Spatial.Motion.crisp, value: isInputFocused)
                    .cursor(.text)
                    .onSubmit { send(to: contact) }

                sendButton(for: contact)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial)
        .animation(Spatial.Motion.fluid, value: companionSync.lastSyncError)
        .animation(Spatial.Motion.fluid, value: replyingTo)
        .animation(Spatial.Motion.fluid, value: smartReply.suggestions)
    }

    /// Ranked one-tap replies. Clicking inserts the text so it can be edited
    /// before sending, rather than firing it off immediately.
    private func smartReplyStrip(for contact: Contact) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .help("Suggestions from on-device context — no cloud, no model")

                ForEach(smartReply.suggestions) { suggestion in
                    Button {
                        withAnimation(Spatial.Motion.bouncy) {
                            messageText = suggestion.text
                        }
                        isInputFocused = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: suggestion.kind.systemImage)
                                .font(.system(size: 8.5, weight: .semibold))
                            Text(suggestion.text)
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .glassSurface(.floating, tint: suggestion.kind == .learned ? .dhAccentViolet : nil)
                    }
                    .buttonStyle(.plain)
                    .cursor(.interactive)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
        }
        .frame(height: 30)
    }

    /// Shows what the pending message will quote, with the exact excerpt that
    /// is going on the wire.
    private func replyBanner(_ target: SMSMessage) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.accentColor)
                .frame(width: 2.5, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 7.5))
                    Text("Replying to \(target.isOutgoing ? "yourself" : target.sender)")
                        .font(.system(size: 9.5, weight: .bold))
                }
                .foregroundStyle(Color.accentColor)

                Text(ReplyTag.makeExcerpt(from: target.body))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(Spatial.Motion.crisp) { replyingTo = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .cursor(.interactive)
            .help("Cancel reply")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .glassSurface(.surface)
    }

    private func sendButton(for contact: Contact) -> some View {
        let canSend = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return Button {
            send(to: contact)
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(canSend ? Color.dhAccentBlue : Color.secondary.opacity(0.35))
                .scaleEffect(canSend ? 1.0 : 0.9)
                .animation(Spatial.Motion.bouncy, value: canSend)
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .cursor(canSend ? .interactive : .disallowed)
        .keyboardShortcut(.return, modifiers: [])
    }

    // MARK: - Empty

    private var emptySelection: some View {
        VStack(spacing: 12) {
            Image(systemName: "message.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
                .symbolEffect(.pulse)
            Text("Select a conversation")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Choose a thread from the inspector to start messaging.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Send

    private func send(to contact: Contact) {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Fold the pending reply target into the wire body.
        let body: String
        if let replyingTo {
            body = ReplyTag.encode(reply: trimmed, quoting: replyingTo.body)
        } else {
            body = trimmed
        }

        messageText = ""
        withAnimation(Spatial.Motion.fluid) { replyingTo = nil }

        // Learn the user's phrasing so future suggestions sound like them.
        smartReply.learn(from: trimmed, contactID: contact.id)

        // Synchronous: the bubble is in the thread before this call returns, so
        // it renders in the same frame the user pressed Return. Transmission
        // happens in the background and only updates the bubble's state.
        withAnimation(Spatial.Motion.bouncy) {
            companionSync.sendMessage(
                to: contact.phoneNumber,
                body: body,
                threadID: contact.id
            )
        }
    }
}

// MARK: - Avatar

/// Deterministic gradient avatar — the same contact always gets the same hue,
/// which makes threads recognisable at a glance without any stored asset.
struct ContactAvatar: View {
    let name: String
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
            Text(initials)
                .font(.system(size: size * 0.40, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let parts = name
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
        let letters = parts.compactMap { $0.first }.prefix(2)
        let result = String(letters).uppercased()
        return result.isEmpty ? "?" : result
    }

    private var gradientColors: [Color] {
        // Stable hash → hue. `hashValue` is seeded per-process in Swift, so it
        // would give a different colour every launch; this doesn't.
        var hash: UInt64 = 5381
        for byte in name.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let hue = Double(hash % 360) / 360.0
        return [
            Color(hue: hue, saturation: 0.68, brightness: 0.92),
            Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1.0),
                  saturation: 0.78, brightness: 0.72)
        ]
    }
}
