import Foundation
import Combine

// MARK: - Raw tabular model
//
// The governing rule for everything in this file: **rows are never merged.**
//
// Android's contacts database stores one row per *data item*, so a person with
// three phone numbers and two emails occupies five rows. Most bridge apps
// collapse those into a single "contact card", which silently discards which
// raw row a value came from. DroidHouse keeps every row exactly as the device
// reported it, in the device's own order, and shows it in a spreadsheet.
// Related entries stay separate; correlation is left to the reader.

/// One raw record. `values` is positional and aligned to the table's `columns`,
/// so a blank cell stays a blank cell rather than being dropped.
struct RosterRow: Identifiable, Hashable {
    let id: Int              // ordinal position in the source, 0-based
    var values: [String]

    func value(at index: Int) -> String {
        guard index >= 0, index < values.count else { return "" }
        return values[index]
    }
}

struct RosterTable {
    var name: String
    var columns: [String]
    var rows: [RosterRow]
    var sourceDescription: String

    static let empty = RosterTable(name: "—", columns: [], rows: [], sourceDescription: "")

    var isEmpty: Bool { rows.isEmpty }

    /// Widest content per column, used to seed sensible initial widths.
    func naturalWidths(min: CGFloat = 90, max: CGFloat = 320) -> [CGFloat] {
        columns.enumerated().map { index, header in
            var longest = header.count
            // Sampling the first 200 rows is enough to size a column and keeps
            // this cheap for tables with tens of thousands of rows.
            for row in rows.prefix(200) {
                longest = Swift.max(longest, row.value(at: index).count)
            }
            let estimated = CGFloat(longest) * 7.2 + 24
            return Swift.min(max, Swift.max(min, estimated))
        }
    }

    func csv() -> String {
        func escape(_ field: String) -> String {
            guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
                return field
            }
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var out = columns.map(escape).joined(separator: ",")
        for row in rows {
            let padded = (0..<columns.count).map { escape(row.value(at: $0)) }
            out += "\n" + padded.joined(separator: ",")
        }
        return out
    }
}

// MARK: - Store

@MainActor
final class RosterStore: ObservableObject {

    enum SourceKind: String, CaseIterable, Identifiable {
        case contacts = "Contacts"
        case callLog = "Call Log"
        case smsRaw = "SMS Table"
        case file = "File"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .contacts: return "person.text.rectangle"
            case .callLog:  return "phone.arrow.up.right"
            case .smsRaw:   return "tablecells"
            case .file:     return "doc.text"
            }
        }

        /// The `content://` provider each roster is pulled from.
        var contentURI: String? {
            switch self {
            case .contacts: return "content://com.android.contacts/data"
            case .callLog:  return "content://call_log/calls"
            case .smsRaw:   return "content://sms"
            case .file:     return nil
            }
        }

        /// The companion's `/api/roster/{table}` path segment.
        var bridgeTable: String? {
            switch self {
            case .contacts: return "contacts"
            case .callLog:  return "calllog"
            case .smsRaw:   return "sms"
            case .file:     return nil
            }
        }
    }

    @Published private(set) var table: RosterTable = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var isTruncated = false
    @Published private(set) var transport: String = ""
    @Published var lastError: String?
    @Published var kind: SourceKind = .contacts

    private let adbPath: String

    init(adbPath: String = ADBLocator.resolve()) {
        self.adbPath = adbPath
    }

    // MARK: Loading

    /// Loads a raw table, preferring the companion bridge.
    ///
    /// The bridge walks the cursor directly, so it returns every column with
    /// its real type. `adb shell content query` is the fallback: it works with
    /// no companion installed, but it flattens everything to text and can only
    /// expose what the shell user is allowed to read.
    func load(kind: SourceKind, device: ADBDevice?) async {
        self.kind = kind
        guard let device else {
            lastError = "No device selected."
            table = .empty
            return
        }
        guard let uri = kind.contentURI else {
            lastError = "Open a delimited file to populate this roster."
            return
        }

        isLoading = true
        lastError = nil
        isTruncated = false
        defer { isLoading = false }

        if let bridgeTable = kind.bridgeTable,
           let payload = try? await CompanionSync.shared.fetchRoster(table: bridgeTable),
           !payload.columns.isEmpty {

            table = RosterTable(
                name: kind.rawValue,
                columns: payload.columns,
                // One payload row in, one roster row out. Index is the row's
                // position in the cursor, which is what the gutter displays.
                rows: payload.rows.enumerated().map { RosterRow(id: $0.offset, values: $0.element) },
                sourceDescription: "\(uri) · \(device.displayName)"
            )
            isTruncated = payload.truncated
            transport = "Companion bridge"

            if payload.rows.isEmpty {
                lastError = "The provider returned no rows."
            } else if payload.truncated {
                lastError = "Showing the first \(payload.rows.count) rows; the table is larger."
            }
            return
        }

        // Fallback: straight adb.
        transport = "adb shell"
        do {
            let output = try await runADB(
                ["-s", device.id, "shell", "content", "query", "--uri", uri],
                timeout: 60
            )

            let parsed = Self.parseContentQuery(output, name: kind.rawValue)
            if parsed.rows.isEmpty {
                // An empty result here is nearly always a permissions problem
                // rather than an actually empty provider.
                lastError = "No rows returned. \(uri) may need the companion app running, or the shell user cannot read it."
            }
            table = RosterTable(
                name: kind.rawValue,
                columns: parsed.columns,
                rows: parsed.rows,
                sourceDescription: "\(uri) · \(device.displayName)"
            )
        } catch {
            lastError = error.localizedDescription
            table = .empty
        }
    }

    /// Loads a delimited file (CSV or TSV) straight off the device without
    /// pulling it to disk first.
    func loadFile(remotePath: String, device: ADBDevice?) async {
        guard let device else {
            lastError = "No device selected."
            return
        }

        kind = .file
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let output = try await runADB(
                // Single-quoted so spaces and shell metacharacters in the path
                // survive the device-side shell intact.
                ["-s", device.id, "exec-out",
                 "cat '" + remotePath.replacingOccurrences(of: "'", with: "'\\''") + "'"],
                timeout: 120
            )
            let name = (remotePath as NSString).lastPathComponent
            let parsed = Self.parseDelimited(output, name: name)
            table = RosterTable(
                name: name,
                columns: parsed.columns,
                rows: parsed.rows,
                sourceDescription: "\(remotePath) · \(device.displayName)"
            )
            if parsed.rows.isEmpty {
                lastError = "\(name) contained no data rows."
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadLocalFile(url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let parsed = Self.parseDelimited(text, name: url.lastPathComponent)
            kind = .file
            table = RosterTable(
                name: url.lastPathComponent,
                columns: parsed.columns,
                rows: parsed.rows,
                sourceDescription: url.path
            )
            lastError = parsed.rows.isEmpty ? "\(url.lastPathComponent) contained no data rows." : nil
        } catch {
            lastError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Parsing

    /// Parses `adb shell content query` output.
    ///
    /// Each line looks like:
    ///   `Row: 0 _id=1, mimetype=vnd.android.cursor.item/phone_v2, data1=+15551234`
    ///
    /// Every `Row:` becomes exactly one roster row — no grouping by contact id,
    /// no folding of a person's several numbers into one entry.
    nonisolated static func parseContentQuery(_ output: String, name: String) -> (columns: [String], rows: [RosterRow]) {
        var orderedColumns: [String] = []
        var seenColumns = Set<String>()
        var rawRows: [[String: String]] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Row:") else { continue }

            // Drop the "Row: <n> " prefix.
            var body = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if let space = body.firstIndex(of: " ") {
                body = String(body[body.index(after: space)...])
            } else {
                body = ""
            }

            var fields: [String: String] = [:]
            for pair in splitPairs(body) {
                guard let equals = pair.firstIndex(of: "=") else { continue }
                let key = String(pair[pair.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(pair[pair.index(after: equals)...])
                guard !key.isEmpty else { continue }
                fields[key] = value == "NULL" ? "" : value
                if !seenColumns.contains(key) {
                    seenColumns.insert(key)
                    orderedColumns.append(key)
                }
            }

            if !fields.isEmpty {
                rawRows.append(fields)
            }
        }

        let rows = rawRows.enumerated().map { index, fields in
            RosterRow(id: index, values: orderedColumns.map { fields[$0] ?? "" })
        }

        return (orderedColumns, rows)
    }

    /// Splits `a=1, b=2, c=3` on the commas that actually separate pairs.
    ///
    /// A naive `split(separator: ",")` mangles values that legitimately contain
    /// commas (addresses, display names). A comma only starts a new pair when
    /// what follows looks like `identifier=`.
    nonisolated private static func splitPairs(_ body: String) -> [String] {
        var pairs: [String] = []
        var current = ""
        let characters = Array(body)
        var i = 0

        while i < characters.count {
            let char = characters[i]
            if char == "," && startsNewPair(characters, from: i + 1) {
                pairs.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                i += 1
                while i < characters.count && characters[i] == " " { i += 1 }
                continue
            }
            current.append(char)
            i += 1
        }

        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            pairs.append(current.trimmingCharacters(in: .whitespaces))
        }
        return pairs
    }

    nonisolated private static func startsNewPair(_ characters: [Character], from index: Int) -> Bool {
        var i = index
        while i < characters.count && characters[i] == " " { i += 1 }
        var sawIdentifier = false
        while i < characters.count {
            let char = characters[i]
            if char.isLetter || char.isNumber || char == "_" {
                sawIdentifier = true
                i += 1
            } else if char == "=" {
                return sawIdentifier
            } else {
                return false
            }
        }
        return false
    }

    /// Parses CSV or TSV, auto-detecting the delimiter and honouring quoted
    /// fields. Ragged rows are padded rather than rejected — the point of a raw
    /// viewer is to show what is actually there.
    nonisolated static func parseDelimited(_ text: String, name: String) -> (columns: [String], rows: [RosterRow]) {
        let normalised = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalised.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard let headerLine = lines.first else { return ([], []) }

        let delimiter: Character = headerLine.contains("\t") ? "\t" : ","
        let columns = parseDelimitedLine(headerLine, delimiter: delimiter)
        guard !columns.isEmpty else { return ([], []) }

        var rows: [RosterRow] = []
        for (offset, line) in lines.dropFirst().enumerated() {
            var values = parseDelimitedLine(line, delimiter: delimiter)
            if values.count < columns.count {
                values.append(contentsOf: Array(repeating: "", count: columns.count - values.count))
            }
            rows.append(RosterRow(id: offset, values: values))
        }

        return (columns, rows)
    }

    nonisolated private static func parseDelimitedLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character?

        while let char = pending ?? iterator.next() {
            pending = nil

            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")   // escaped quote
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == delimiter {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }

        fields.append(current)
        return fields
    }

    // MARK: ADB

    private func runADB(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        let adb = adbPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [adb] + arguments

                let pipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errorPipe

                let lock = NSLock()
                var didResume = false
                func resumeOnce(_ block: () -> Void) {
                    lock.lock(); defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    block()
                }

                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    if process.isRunning { process.terminate() }
                    resumeOnce { continuation.resume(throwing: ADBError.timedOut(timeout)) }
                }
                timer.resume()

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timer.cancel()

                    if process.terminationStatus != 0 {
                        let message = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                        resumeOnce {
                            continuation.resume(
                                throwing: ADBError.commandFailed(
                                    message.trimmingCharacters(in: .whitespacesAndNewlines)
                                )
                            )
                        }
                    } else {
                        resumeOnce {
                            continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
                        }
                    }
                } catch {
                    timer.cancel()
                    resumeOnce { continuation.resume(throwing: ADBError.processError(error.localizedDescription)) }
                }
            }
        }
    }
}
