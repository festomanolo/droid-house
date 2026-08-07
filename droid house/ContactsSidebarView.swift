import SwiftUI

struct ContactsSidebarView: View {
    @ObservedObject var companionSync = CompanionSync.shared
    @Binding var selectedContact: Contact?

    @State private var searchText: String = ""
    @State private var isRefreshing = false

    private var filteredContacts: [Contact] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return companionSync.conversations }
        return companionSync.conversations.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.phoneNumber.localizedCaseInsensitiveContains(query) ||
            $0.lastMessageSnippet.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if filteredContacts.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(.ultraThinMaterial)
        .task {
            if companionSync.conversations.isEmpty {
                try? await companionSync.fetchConversations()
            }
            if selectedContact == nil {
                selectedContact = companionSync.conversations.first
            }
        }
        .onChange(of: companionSync.conversations) { _, updated in
            // A refresh must not silently deselect the open thread.
            if let current = selectedContact,
               let refreshed = updated.first(where: { $0.id == current.id }) {
                selectedContact = refreshed
            } else if selectedContact == nil {
                selectedContact = updated.first
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                SpatialSectionHeader("Conversations")
                    .padding(.horizontal, 0)

                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                        .animation(
                            isRefreshing
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: isRefreshing
                        )
                }
                .buttonStyle(.plain)
                .cursor(.interactive)
                .help("Re-read threads from the device")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                TextField("Filter threads", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .cursor(.text)
                if !searchText.isEmpty {
                    Button {
                        withAnimation(Spatial.Motion.crisp) { searchText = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .cursor(.interactive)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }

            if !companionSync.isConnected {
                Label("Showing demo threads", systemImage: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(filteredContacts) { contact in
                    ContactRow(
                        contact: contact,
                        isSelected: selectedContact?.id == contact.id
                    ) {
                        withAnimation(Spatial.Motion.fluid) {
                            selectedContact = contact
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .animation(Spatial.Motion.fluid, value: filteredContacts)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? "No conversations" : "No matches")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if searchText.isEmpty && companionSync.isConnected && !companionSync.hasSMSAccess {
                Text("Grant SMS access in the companion app.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            try? await companionSync.fetchConversations()
            // A refresh that returns instantly still shows one full rotation,
            // otherwise the spin reads as a glitch.
            try? await Task.sleep(for: .milliseconds(500))
            isRefreshing = false
        }
    }
}

// MARK: - Row

private struct ContactRow: View {
    let contact: Contact
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ContactAvatar(name: contact.name, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(contact.name)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text(contact.lastMessageTimestamp, format: .dateTime.hour().minute())
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 6) {
                        Text(ReplyTag.displayBody(contact.lastMessageSnippet))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if contact.unreadCount > 0 {
                            Text("\(contact.unreadCount)")
                                .font(.system(size: 9, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.accentColor))
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .glassSurface(
                .surface,
                highlighted: isSelected || isHovering,
                tint: isSelected ? Color.accentColor : nil
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cursor(.interactive)
        .scaleEffect(isSelected ? 1.0 : (isHovering ? 0.995 : 0.99))
        .animation(Spatial.Motion.crisp, value: isSelected)
        .animation(Spatial.Motion.crisp, value: isHovering)
        .onHover { isHovering = $0 }
    }
}
