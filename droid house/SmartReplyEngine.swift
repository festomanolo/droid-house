import Foundation
import Combine
import NaturalLanguage

// MARK: - Smart Replies without a model
//
// No LLM, no network, no multi-gigabyte weights. This is a deterministic
// classifier plus an entity extractor plus a personalisation model learned from
// the user's own outgoing messages. It runs in well under a millisecond.
//
// The pipeline:
//   1. classify the last incoming message's intent (question type, greeting,
//      thanks, scheduling, money, location, urgency, …)
//   2. extract entities that a good reply would echo — times, dates, amounts,
//      places, people
//   3. read the conversation context — who spoke last, how long ago, time of
//      day, how formal this thread usually is
//   4. score candidate replies from the matching intent templates, boosting
//      phrases this user actually sends
//   5. return the top few, de-duplicated

@MainActor
final class SmartReplyEngine: ObservableObject {

    static let shared = SmartReplyEngine()

    @Published private(set) var suggestions: [Suggestion] = []

    private let personalisation = PersonalisationStore()

    private init() {}

    // MARK: Types

    struct Suggestion: Identifiable, Hashable {
        let id = UUID()
        let text: String
        let kind: Kind
        /// Higher scores rank first.
        let score: Double

        enum Kind: Hashable {
            case affirmative
            case negative
            case deferral
            case acknowledgement
            case question
            case scheduling
            case courtesy
            case learned

            var systemImage: String {
                switch self {
                case .affirmative:     return "checkmark.circle"
                case .negative:        return "xmark.circle"
                case .deferral:        return "clock"
                case .acknowledgement: return "hand.thumbsup"
                case .question:        return "questionmark.circle"
                case .scheduling:      return "calendar"
                case .courtesy:        return "heart"
                case .learned:         return "sparkles"
                }
            }
        }
    }

    /// What the incoming message is *doing*, which is what determines the
    /// shape of a good reply.
    enum Intent: String {
        case yesNoQuestion
        case openQuestion
        case schedulingRequest
        case greeting
        case thanks
        case apology
        case farewell
        case confirmationRequest
        case moneyRequest
        case locationRequest
        case urgent
        case statement
    }

    struct Context {
        var lastIncoming: SMSMessage?
        var intent: Intent = .statement
        var times: [String] = []
        var dates: [String] = []
        var amounts: [String] = []
        var places: [String] = []
        var people: [String] = []
        var waitingMinutes: Double = 0
        var userSpokeLast: Bool = false
        var threadIsFormal: Bool = false
    }

    // MARK: - Entry point

    /// Recomputes suggestions for a thread. Cheap enough to call on every
    /// message change.
    func refresh(thread: [SMSMessage], contact: Contact?) {
        guard let context = buildContext(thread: thread) else {
            suggestions = []
            return
        }

        // Nothing useful to suggest when the user already had the last word —
        // except a nudge if it's been a while.
        if context.userSpokeLast {
            suggestions = followUpSuggestions(context: context)
            return
        }

        var candidates = templates(for: context)
        candidates.append(contentsOf: contextualExtras(for: context))
        candidates.append(contentsOf: learnedSuggestions(for: context, contact: contact))

        suggestions = rank(candidates, context: context)
    }

    func clear() {
        suggestions = []
    }

    /// Records an outgoing message so future suggestions sound like the user.
    func learn(from body: String, contactID: String?) {
        personalisation.record(body: body, contactID: contactID)
    }

    // MARK: - Context building

    private func buildContext(thread: [SMSMessage]) -> Context? {
        guard let last = thread.last else { return nil }

        var context = Context()
        context.userSpokeLast = last.isOutgoing
        context.waitingMinutes = Date().timeIntervalSince(last.timestamp) / 60.0

        guard let lastIncoming = thread.last(where: { !$0.isOutgoing }) else {
            return context.userSpokeLast ? context : nil
        }

        context.lastIncoming = lastIncoming

        // Classify against the reply half only — the quoted excerpt is context,
        // not the thing being asked.
        let body = ReplyTag.displayBody(lastIncoming.body)
        context.intent = classify(body)

        let entities = extractEntities(from: body)
        context.times = entities.times
        context.dates = entities.dates
        context.amounts = entities.amounts
        context.places = entities.places
        context.people = entities.people

        // A thread reads as formal when the other party writes in full,
        // capitalised sentences and avoids contractions/slang.
        context.threadIsFormal = looksFormal(thread: thread)

        return context
    }

    // MARK: - Intent classification

    private func classify(_ raw: String) -> Intent {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .statement }

        func containsAny(_ needles: [String]) -> Bool {
            needles.contains { text.contains($0) }
        }

        func startsWithAny(_ needles: [String]) -> Bool {
            needles.contains { text.hasPrefix($0) }
        }

        // Order matters: the most specific intents are tested first, because a
        // message can legitimately match several patterns.
        if containsAny(["urgent", "asap", "emergency", "right now", "immediately", "haraka"]) {
            return .urgent
        }

        if containsAny(["send money", "payment", "pay me", "invoice", "owe", "transfer",
                        "deposit", "refund", "lipa", "malipo"]) || !extractEntities(from: raw).amounts.isEmpty {
            return .moneyRequest
        }

        if containsAny(["where are you", "your location", "what's your address",
                        "whats your address", "send location", "which place", "uko wapi"]) {
            return .locationRequest
        }

        if containsAny(["what time", "when are", "when will", "when can", "are you free",
                        "you free", "available", "meeting", "schedule", "reschedule",
                        "let's meet", "lets meet", "see you at", "still on for"]) {
            return .schedulingRequest
        }

        if containsAny(["are we still on", "confirm", "confirmed", "is that ok",
                        "is it ok", "does that work", "sound good", "you sure"]) {
            return .confirmationRequest
        }

        if startsWithAny(["hi", "hey", "hello", "good morning", "good afternoon",
                          "good evening", "habari", "mambo", "sasa"]) {
            return .greeting
        }

        if containsAny(["thank you", "thanks", "thx", "asante", "appreciate it"]) {
            return .thanks
        }

        if containsAny(["sorry", "apolog", "my bad", "samahani"]) {
            return .apology
        }

        if containsAny(["goodnight", "good night", "bye", "talk later", "talk soon",
                        "see you later", "take care", "usiku mwema"]) {
            return .farewell
        }

        if text.hasSuffix("?") || containsAny(["?"]) {
            // A yes/no question opens with an auxiliary or modal verb.
            let yesNoOpeners = ["is ", "are ", "was ", "were ", "do ", "does ", "did ",
                                "can ", "could ", "will ", "would ", "should ", "have ",
                                "has ", "had ", "am ", "may ", "might "]
            if startsWithAny(yesNoOpeners) { return .yesNoQuestion }

            let whOpeners = ["what", "when", "where", "who", "why", "how", "which"]
            if startsWithAny(whOpeners) { return .openQuestion }

            return .yesNoQuestion
        }

        return .statement
    }

    // MARK: - Entity extraction

    private struct Entities {
        var times: [String] = []
        var dates: [String] = []
        var amounts: [String] = []
        var places: [String] = []
        var people: [String] = []
    }

    private func extractEntities(from text: String) -> Entities {
        var entities = Entities()

        // Dates and times via the system data detector — far more robust than
        // hand-rolled regex, and it understands "tomorrow at 3".
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            detector.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let matchRange = Range(match.range, in: text) else { return }
                let raw = String(text[matchRange])
                // Treat anything containing a clock-ish token as a time.
                if raw.range(of: #"\d\s?(am|pm|:\d\d)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    entities.times.append(raw)
                } else {
                    entities.dates.append(raw)
                }
            }
        }

        // Currency amounts: symbol-prefixed, or a code/keyword with digits.
        let amountPattern = #"(?:[$£€]\s?\d[\d,]*(?:\.\d{1,2})?)|(?:\b(?:tsh|ksh|usd|eur|gbp|ngn|zar)\s?\d[\d,]*(?:\.\d{1,2})?\b)"#
        if let regex = try? NSRegularExpression(pattern: amountPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range, in: text) {
                    entities.amounts.append(String(text[r]))
                }
            }
        }

        // Names and places via NLTagger's named-entity recognition.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, tokenRange in
            guard let tag else { return true }
            let value = String(text[tokenRange])
            switch tag {
            case .placeName:    entities.places.append(value)
            case .personalName: entities.people.append(value)
            default: break
            }
            return true
        }

        return entities
    }

    // MARK: - Templates

    private func templates(for context: Context) -> [Suggestion] {
        switch context.intent {
        case .yesNoQuestion:
            return [
                Suggestion(text: "Yes", kind: .affirmative, score: 1.0),
                Suggestion(text: "No", kind: .negative, score: 0.9),
                Suggestion(text: "Let me check and get back to you", kind: .deferral, score: 0.85)
            ]

        case .openQuestion:
            return [
                Suggestion(text: "Let me check and get back to you", kind: .deferral, score: 1.0),
                Suggestion(text: "Give me a few minutes", kind: .deferral, score: 0.88),
                Suggestion(text: "Can I call you about this?", kind: .question, score: 0.8)
            ]

        case .schedulingRequest:
            var out = [
                Suggestion(text: "That works for me", kind: .scheduling, score: 1.0),
                Suggestion(text: "Can we do a bit later?", kind: .scheduling, score: 0.85),
                Suggestion(text: "I'll confirm shortly", kind: .deferral, score: 0.8)
            ]
            // Echoing the proposed time back is the single most useful reply
            // here, so it outranks the generic acceptances.
            if let time = context.times.first {
                out.insert(Suggestion(text: "See you at \(time)", kind: .scheduling, score: 1.2), at: 0)
            } else if let date = context.dates.first {
                out.insert(Suggestion(text: "\(date.capitalizedFirst) works", kind: .scheduling, score: 1.15), at: 0)
            }
            return out

        case .greeting:
            return [
                Suggestion(text: "\(timeOfDayGreeting())!", kind: .courtesy, score: 1.0),
                Suggestion(text: "Hey — what's up?", kind: .courtesy, score: 0.9),
                Suggestion(text: "Hi! How are you?", kind: .courtesy, score: 0.85)
            ]

        case .thanks:
            return [
                Suggestion(text: "Anytime", kind: .courtesy, score: 1.0),
                Suggestion(text: "You're welcome", kind: .courtesy, score: 0.92),
                Suggestion(text: "No problem at all", kind: .courtesy, score: 0.85)
            ]

        case .apology:
            return [
                Suggestion(text: "No worries", kind: .courtesy, score: 1.0),
                Suggestion(text: "It's completely fine", kind: .courtesy, score: 0.9),
                Suggestion(text: "Don't worry about it", kind: .courtesy, score: 0.85)
            ]

        case .farewell:
            return [
                Suggestion(text: "Talk soon!", kind: .courtesy, score: 1.0),
                Suggestion(text: "\(timeOfDayFarewell())!", kind: .courtesy, score: 0.95),
                Suggestion(text: "You too", kind: .courtesy, score: 0.85)
            ]

        case .confirmationRequest:
            return [
                Suggestion(text: "Confirmed", kind: .affirmative, score: 1.0),
                Suggestion(text: "Yes, still on", kind: .affirmative, score: 0.95),
                Suggestion(text: "Actually, I need to reschedule", kind: .negative, score: 0.7)
            ]

        case .moneyRequest:
            var out = [
                Suggestion(text: "Sending it now", kind: .affirmative, score: 1.0),
                Suggestion(text: "Received, thank you", kind: .acknowledgement, score: 0.9),
                Suggestion(text: "Can we sort this out tomorrow?", kind: .deferral, score: 0.78)
            ]
            if let amount = context.amounts.first {
                out.insert(Suggestion(text: "Confirming \(amount)", kind: .affirmative, score: 1.1), at: 0)
            }
            return out

        case .locationRequest:
            var out = [
                Suggestion(text: "On my way", kind: .affirmative, score: 1.0),
                Suggestion(text: "I'm here already", kind: .affirmative, score: 0.9),
                Suggestion(text: "Running about 10 minutes late", kind: .deferral, score: 0.82)
            ]
            if let place = context.places.first {
                out.insert(Suggestion(text: "Meet me at \(place)", kind: .scheduling, score: 1.05), at: 0)
            }
            return out

        case .urgent:
            return [
                Suggestion(text: "On it right now", kind: .affirmative, score: 1.2),
                Suggestion(text: "Calling you in a moment", kind: .affirmative, score: 1.1),
                Suggestion(text: "Give me five minutes", kind: .deferral, score: 0.9)
            ]

        case .statement:
            return [
                Suggestion(text: "Got it", kind: .acknowledgement, score: 1.0),
                Suggestion(text: "Thanks for letting me know", kind: .acknowledgement, score: 0.92),
                Suggestion(text: "Okay", kind: .acknowledgement, score: 0.8)
            ]
        }
    }

    /// Suggestions that come from the conversation's situation rather than the
    /// text of the last message.
    private func contextualExtras(for context: Context) -> [Suggestion] {
        var out: [Suggestion] = []

        // Context-aware expressions
        out.append(Suggestion(
            text: "Hongera sana Aiseeee!!",
            kind: .courtesy,
            score: 0.98
        ))
        out.append(Suggestion(
            text: "Una maisha aiseee aaaah!",
            kind: .courtesy,
            score: 0.97
        ))

        // Apologise for a genuinely late reply — but only once the delay is
        // long enough that it would actually read as late.
        if context.waitingMinutes > 180 {
            out.append(Suggestion(
                text: "Sorry for the late reply",
                kind: .courtesy,
                score: 0.95
            ))
        }

        // Formal threads get a more measured acknowledgement.
        if context.threadIsFormal {
            out.append(Suggestion(
                text: "Noted, thank you",
                kind: .acknowledgement,
                score: 0.88
            ))
        }

        if let person = context.people.first, context.intent == .openQuestion {
            out.append(Suggestion(
                text: "I'll check with \(person)",
                kind: .deferral,
                score: 0.86
            ))
        }

        return out
    }

    private func followUpSuggestions(context: Context) -> [Suggestion] {
        // Don't nag: only offer a follow-up once the silence is meaningful.
        guard context.waitingMinutes > 60 else { return [] }

        return [
            Suggestion(text: "Any update on this?", kind: .question, score: 1.0),
            Suggestion(text: "Just following up", kind: .question, score: 0.9),
            Suggestion(text: "Let me know when you get a chance", kind: .question, score: 0.85)
        ]
    }

    // MARK: - Personalisation

    private func learnedSuggestions(for context: Context, contact: Contact?) -> [Suggestion] {
        personalisation
            .topPhrases(for: context.intent, contactID: contact?.id, limit: 2)
            .map { phrase in
                // Learned phrases sit just below the best template so they
                // surface prominently without crowding out sensible defaults.
                Suggestion(text: phrase.text, kind: .learned, score: 0.95 + phrase.weight * 0.3)
            }
    }

    // MARK: - Ranking

    private func rank(_ candidates: [Suggestion], context: Context) -> [Suggestion] {
        var seen = Set<String>()
        var unique: [Suggestion] = []

        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let key = candidate.text.lowercased().trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(candidate)
        }

        return Array(unique.prefix(4))
    }

    // MARK: - Helpers

    private func looksFormal(thread: [SMSMessage]) -> Bool {
        let incoming = thread.filter { !$0.isOutgoing }.suffix(6)
        guard incoming.count >= 2 else { return false }

        let informalMarkers = ["lol", "haha", "yeah", "yep", "nah", "u ", " ur ", "gonna", "wanna", "😂", "🙏", "👍"]
        var formalScore = 0

        for message in incoming {
            let body = ReplyTag.displayBody(message.body)
            let lower = body.lowercased()

            if informalMarkers.contains(where: { lower.contains($0) }) {
                formalScore -= 1
                continue
            }
            // Long, properly capitalised, punctuated sentences read as formal.
            if body.count > 60, let first = body.first, first.isUppercase,
               body.contains(".") {
                formalScore += 1
            }
        }

        return formalScore >= 2
    }

    private func timeOfDayGreeting() -> String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 0..<12:  return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    private func timeOfDayFarewell() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        return (hour >= 21 || hour < 5) ? "Goodnight" : "Take care"
    }
}

// MARK: - Personalisation store

/// Learns which short phrases the user actually sends, globally and per
/// contact, so suggestions drift toward their real voice over time.
///
/// This is a frequency model, not a language model: it only ever proposes
/// phrases the user has typed themselves.
private final class PersonalisationStore {

    struct Phrase {
        let text: String
        /// Normalised 0...1 frequency within its bucket.
        let weight: Double
    }

    private let defaultsKey = "droidhouse.smartreply.phrases"
    private let maxPhraseLength = 60
    private let maxPerBucket = 24

    /// bucket key ("intent" or "intent|contactID") -> phrase -> count
    private var counts: [String: [String: Int]]

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: [String: Int]].self, from: data) {
            counts = decoded
        } else {
            counts = [:]
        }
    }

    func record(body: String, contactID: String?) {
        // Only the reply half is the user's own voice.
        let text = ReplyTag.displayBody(body).trimmingCharacters(in: .whitespacesAndNewlines)

        // Long, bespoke messages are never reusable as a canned reply.
        guard !text.isEmpty, text.count <= maxPhraseLength else { return }

        let intent = SmartReplyEngine.Intent.statement  // bucket by reply shape
        let bucketKeys = [
            replyBucket(for: text, intent: intent),
            contactID.map { "\(replyBucket(for: text, intent: intent))|\($0)" }
        ].compactMap { $0 }

        for key in bucketKeys {
            var bucket = counts[key] ?? [:]
            bucket[text, default: 0] += 1

            // Keep buckets bounded by evicting the least-used phrase.
            if bucket.count > maxPerBucket,
               let weakest = bucket.min(by: { $0.value < $1.value })?.key {
                bucket.removeValue(forKey: weakest)
            }
            counts[key] = bucket
        }

        persist()
    }

    func topPhrases(for intent: SmartReplyEngine.Intent, contactID: String?, limit: Int) -> [Phrase] {
        // Prefer phrases used with *this* contact, then fall back to global.
        let keys = [
            contactID.map { "\(intent.rawValue)|\($0)" },
            intent.rawValue,
            contactID.map { "\(SmartReplyEngine.Intent.statement.rawValue)|\($0)" },
            SmartReplyEngine.Intent.statement.rawValue
        ].compactMap { $0 }

        for key in keys {
            guard let bucket = counts[key], !bucket.isEmpty else { continue }
            let maxCount = Double(bucket.values.max() ?? 1)
            // A phrase used once is noise, not a habit.
            let ranked = bucket
                .filter { $0.value >= 2 }
                .sorted { $0.value > $1.value }
                .prefix(limit)
                .map { Phrase(text: $0.key, weight: Double($0.value) / maxCount) }
            if !ranked.isEmpty { return Array(ranked) }
        }

        return []
    }

    /// Buckets a phrase by the kind of reply it is, so "Yes" is offered for
    /// questions rather than for greetings.
    private func replyBucket(for text: String, intent: SmartReplyEngine.Intent) -> String {
        let lower = text.lowercased()

        if ["yes", "yeah", "yep", "sure", "ok", "okay", "confirmed", "sawa", "ndio"]
            .contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
            return SmartReplyEngine.Intent.yesNoQuestion.rawValue
        }
        if ["no", "nope", "nah", "hapana"].contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
            return SmartReplyEngine.Intent.yesNoQuestion.rawValue
        }
        if lower.contains("thank") || lower.contains("asante") || lower.contains("welcome") {
            return SmartReplyEngine.Intent.thanks.rawValue
        }
        if lower.contains("morning") || lower.contains("hey") || lower.hasPrefix("hi") {
            return SmartReplyEngine.Intent.greeting.rawValue
        }
        if lower.contains("time") || lower.contains("meet") || lower.contains("tomorrow") {
            return SmartReplyEngine.Intent.schedulingRequest.rawValue
        }
        return intent.rawValue
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(counts) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
