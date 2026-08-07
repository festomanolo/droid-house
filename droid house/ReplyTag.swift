import Foundation

// MARK: - Reply Tagging over plain SMS
//
// SMS has no threading primitive: there is no field that says "this message
// answers that one". So DroidHouse encodes the relationship *in the body*, in a
// form that stays readable on any dumb SMS client while being unambiguous
// enough to parse back into a rich quote here.
//
// Wire format — the quote is always exactly one line:
//
//     ↵ RE: Are we still on for the 3pm…
//     Yes, see you then
//
//   • `↵` opens the line, marking it as a threading tag at a glance.
//   • `RE: ` names what follows as the quoted message.
//   • the excerpt is the quoted message, whitespace-collapsed to a single line
//     and truncated with a real ellipsis so it can never wrap.
//   • everything after the first newline is the reply itself.
//
// A recipient without DroidHouse simply reads a sensible quoted reply. A
// recipient with it sees a threaded bubble.

enum ReplyTag {

    static let marker = "RE:"
    static let returnSymbol = "\u{21B5}"   // ↵
    static let ellipsis = "\u{2026}"       // …

    /// Longest excerpt kept before truncating. Chosen so the tag line stays
    /// within a single SMS segment's worth of overhead.
    static let excerptLimit = 40

    // MARK: Encoding

    /// Builds the wire body for `reply` quoting `original`.
    static func encode(reply: String, quoting original: String) -> String {
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = makeExcerpt(from: original)
        guard !excerpt.isEmpty else { return trimmedReply }
        return "\(returnSymbol) \(marker) \(excerpt)\n\(trimmedReply)"
    }

    /// Collapses a message to one truncated line suitable for the tag.
    static func makeExcerpt(from original: String) -> String {
        // If the quoted message is itself a tagged reply, quote its *reply*
        // half — otherwise quotes nest and each generation loses more meaning.
        let source = parse(original)?.reply ?? original

        let collapsed = source
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !collapsed.isEmpty else { return "" }
        guard collapsed.count > excerptLimit else { return collapsed }

        // Prefer cutting on a word boundary so the excerpt doesn't end
        // mid-word before the ellipsis.
        let hardCut = String(collapsed.prefix(excerptLimit))
        if let lastSpace = hardCut.lastIndex(of: " "), hardCut.distance(from: hardCut.startIndex, to: lastSpace) > excerptLimit / 2 {
            return String(hardCut[..<lastSpace]) + ellipsis
        }
        return hardCut + ellipsis
    }

    // MARK: Decoding

    struct Parsed: Equatable {
        /// The quoted excerpt, without the marker, ellipsis or return symbol.
        let quote: String
        /// The actual reply text.
        let reply: String
        /// True when the excerpt was truncated on the sending side.
        let quoteWasTruncated: Bool
    }

    /// Splits a tagged body back into its quote and reply.
    /// Returns `nil` for an ordinary, untagged message.
    static func parse(_ body: String) -> Parsed? {
        guard let newline = body.firstIndex(of: "\n") else { return nil }

        var head = String(body[body.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
        let tail = String(body[body.index(after: newline)...])

        // The return symbol leads the tag. Strip it first — but accept a tag
        // without it, so a hand-typed "Re:" from another client still threads.
        if head.hasPrefix(returnSymbol) {
            head = String(head.dropFirst(returnSymbol.count)).trimmingCharacters(in: .whitespaces)
        }

        // Case-insensitive marker check.
        guard head.lowercased().hasPrefix(marker.lowercased()) else { return nil }

        head = String(head.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)

        // Tolerate the older trailing-symbol layout.
        if head.hasSuffix(returnSymbol) {
            head = String(head.dropLast(returnSymbol.count)).trimmingCharacters(in: .whitespaces)
        }

        var truncated = false
        if head.hasSuffix(ellipsis) {
            truncated = true
            head = String(head.dropLast(ellipsis.count)).trimmingCharacters(in: .whitespaces)
        } else if head.hasSuffix("...") {
            truncated = true
            head = String(head.dropLast(3)).trimmingCharacters(in: .whitespaces)
        }

        let reply = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !head.isEmpty, !reply.isEmpty else { return nil }

        return Parsed(quote: head, reply: reply, quoteWasTruncated: truncated)
    }

    /// The text to render inside a bubble — the reply half for tagged
    /// messages, the whole body otherwise.
    static func displayBody(_ body: String) -> String {
        parse(body)?.reply ?? body
    }

    /// Finds the message a tagged body is answering, by matching its excerpt
    /// against earlier messages in the thread.
    ///
    /// Matching is prefix-based because the excerpt is truncated; the search
    /// runs newest-first so a repeated phrase resolves to the most recent
    /// occurrence, which is nearly always the intended one.
    static func resolveQuotedMessage(
        for message: SMSMessage,
        in thread: [SMSMessage]
    ) -> SMSMessage? {
        guard let parsed = parse(message.body) else { return nil }

        let needle = normalise(parsed.quote)
        guard !needle.isEmpty else { return nil }

        let candidates = thread.prefix(while: { $0.id != message.id })

        return candidates.reversed().first { candidate in
            let hay = normalise(displayBody(candidate.body))
            return parsed.quoteWasTruncated ? hay.hasPrefix(needle) : hay == needle
        }
    }

    private static func normalise(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}
