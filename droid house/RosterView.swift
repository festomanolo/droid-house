import SwiftUI
import UniformTypeIdentifiers

// MARK: - Raw Data Roster
//
// A spreadsheet, deliberately. Every row the device reported is one row here,
// in source order, with its original column names. Nothing is grouped, joined
// or de-duplicated on the way in — if a person owns four phone numbers they
// occupy four rows, exactly as the raw provider returned them.

struct RosterView: View {
    @ObservedObject var adbService: ADBService
    @StateObject private var store = RosterStore()

    @State private var filter = ""
    @State private var columnWidths: [CGFloat] = []
    @State private var sortColumn: Int?
    @State private var sortAscending = true
    @State private var selectedRow: Int?
    @State private var isExporting = false

    private let rowHeight: CGFloat = 26
    private let gutterWidth: CGFloat = 52

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider().opacity(0.5)

            if store.isLoading {
                loadingState
            } else if store.table.isEmpty {
                emptyState
            } else {
                spreadsheet
            }

            if let error = store.lastError, !store.isLoading {
                errorBar(error)
            }

            statusBar
        }
        .substrateBackground()
        .task(id: adbService.selectedDevice?.id) {
            guard adbService.selectedDevice != nil else { return }
            await store.load(kind: store.kind, device: adbService.selectedDevice)
            resetLayout()
        }
        .fileExporter(
            isPresented: $isExporting,
            document: CSVDocument(text: store.table.csv()),
            contentType: .commaSeparatedText,
            defaultFilename: exportFilename
        ) { _ in }
    }

    // MARK: Control bar

    private var controlBar: some View {
        HStack(spacing: 10) {
            ForEach(RosterStore.SourceKind.allCases) { kind in
                let isActive = store.kind == kind
                Button {
                    Task {
                        await store.load(kind: kind, device: adbService.selectedDevice)
                        resetLayout()
                    }
                } label: {
                    Label(kind.rawValue, systemImage: kind.systemImage)
                        .font(.system(size: 11.5, weight: isActive ? .semibold : .medium))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(
                    SpatialButtonStyle(
                        depth: .surface,
                        tint: isActive ? .dhAccentMint : nil,
                        padding: EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
                    )
                )
                .disabled(kind == .file)
                .help(kind == .file ? "Open a CSV or TSV to load it here" : "Read \(kind.contentURI ?? "")")
            }

            Divider().frame(height: 16)

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Filter rows…", text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .frame(width: 170)
                    .cursor(.text)
                if !filter.isEmpty {
                    Button {
                        withAnimation(Spatial.Motion.crisp) { filter = "" }
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
            .glassSurface(.surface)

            Spacer()

            Button {
                isExporting = true
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(SpatialButtonStyle(depth: .surface,
                                            padding: EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)))
            .disabled(store.table.isEmpty)

            Button {
                Task {
                    await store.load(kind: store.kind, device: adbService.selectedDevice)
                    resetLayout()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(SpatialButtonStyle(depth: .surface,
                                            padding: EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)))
            .help("Re-read from the device")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Spreadsheet

    private var spreadsheet: some View {
        let rows = visibleRows
        let widths = effectiveWidths
        // Total width is fixed by the columns, so the lazy stack can size
        // itself without measuring every row.
        let contentWidth = gutterWidth + widths.reduce(0, +)

        return ScrollView([.horizontal, .vertical]) {
            // LazyVStack, emphatically not VStack.
            //
            // A contacts dump is ~5,000 rows × ~96 columns. Building that
            // eagerly is roughly half a million views, which overruns
            // SwiftUI's AttributeGraph node table and aborts the process
            // (`AG::data::table::grow_region` precondition failure). Lazily,
            // only the ~30 rows on screen are ever realised.
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { displayIndex, row in
                        dataRow(row, displayIndex: displayIndex, widths: widths)
                    }
                } header: {
                    headerRow(widths: widths)
                }
            }
            .frame(width: contentWidth, alignment: .leading)
        }
        .background(Color.dhCanvas)
    }

    private func headerRow(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            // Corner cell above the row numbers.
            Text("#")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: gutterWidth, height: rowHeight)
                .background(Color.primary.opacity(0.05))
                .overlay(alignment: .trailing) { gridLine(vertical: true) }

            ForEach(Array(store.table.columns.enumerated()), id: \.offset) { index, column in
                headerCell(column, index: index, width: widths[safe: index] ?? 120)
            }
        }
        .overlay(alignment: .bottom) { gridLine(vertical: false).opacity(0.9) }
        // Keeps the header visible while the body scrolls beneath it.
        .background(.regularMaterial)
        .zIndex(1)
    }

    private func headerCell(_ column: String, index: Int, width: CGFloat) -> some View {
        let isSorted = sortColumn == index

        return HStack(spacing: 3) {
            Text(column)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(isSorted ? Color.accentColor : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            if isSorted {
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .frame(width: width, height: rowHeight, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Spatial.Motion.crisp) {
                if sortColumn == index {
                    sortAscending.toggle()
                } else {
                    sortColumn = index
                    sortAscending = true
                }
            }
        }
        .cursor(.interactive)
        .overlay(alignment: .trailing) {
            // Drag handle — the cursor morphs to a column resizer here, which
            // is the whole reason the grid is hand-built rather than a Table.
            gridLine(vertical: true)
                .frame(width: 7)
                .contentShape(Rectangle())
                .cursor(.resizeColumn)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            resizeColumn(index, by: value.translation.width)
                        }
                )
        }
        .help(column)
    }

    private func dataRow(_ row: RosterRow, displayIndex: Int, widths: [CGFloat]) -> some View {
        let isSelected = selectedRow == row.id

        return HStack(spacing: 0) {
            // Source ordinal — deliberately the *original* index, so a sorted
            // or filtered view still tells you where the row really sits.
            Text("\(row.id + 1)")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: gutterWidth, height: rowHeight, alignment: .trailing)
                .padding(.trailing, 7)
                .background(Color.primary.opacity(0.035))
                .overlay(alignment: .trailing) { gridLine(vertical: true) }

            ForEach(Array(store.table.columns.enumerated()), id: \.offset) { index, _ in
                let text = row.value(at: index)
                Text(text.isEmpty ? "—" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(text.isEmpty ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 7)
                    .frame(width: widths[safe: index] ?? 120, height: rowHeight, alignment: .leading)
                    .overlay(alignment: .trailing) { gridLine(vertical: true) }
                    .textSelection(.enabled)
            }
        }
        .background(rowBackground(displayIndex: displayIndex, isSelected: isSelected))
        .overlay(alignment: .bottom) { gridLine(vertical: false) }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Spatial.Motion.crisp) {
                selectedRow = (selectedRow == row.id) ? nil : row.id
            }
        }
        .contextMenu {
            Button("Copy Row as TSV") { copyRow(row) }
            Button("Copy Row as JSON") { copyRowJSON(row) }
        }
    }

    private func rowBackground(displayIndex: Int, isSelected: Bool) -> some View {
        Group {
            if isSelected {
                Color.accentColor.opacity(0.20)
            } else if displayIndex.isMultiple(of: 2) {
                Color.clear
            } else {
                // Zebra striping, the one concession to readability that
                // doesn't alter the data.
                Color.primary.opacity(0.028)
            }
        }
    }

    private func gridLine(vertical: Bool) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.small)
            Text("Reading \(store.kind.rawValue.lowercased()) from the device…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Rows", systemImage: store.kind.systemImage)
        } description: {
            Text(adbService.selectedDevice == nil
                 ? "Connect a device to read its raw tables."
                 : "Nothing came back from \(store.kind.contentURI ?? "this source").")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(statusText)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            Spacer()

            if !store.transport.isEmpty {
                Text(store.transport)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
            }

            if !store.table.sourceDescription.isEmpty {
                Text(store.table.sourceDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.regularMaterial)
        .overlay(alignment: .top) { gridLine(vertical: false) }
    }

    private var statusText: String {
        let total = store.table.rows.count
        let shown = visibleRows.count
        let columns = store.table.columns.count
        if shown == total {
            return "\(total) rows · \(columns) columns · unmerged"
        }
        return "\(shown) of \(total) rows · \(columns) columns · unmerged"
    }

    // MARK: Derived data

    private var visibleRows: [RosterRow] {
        var rows = store.table.rows

        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            rows = rows.filter { row in
                row.values.contains { $0.lowercased().contains(query) }
            }
        }

        if let sortColumn {
            rows.sort { lhs, rhs in
                let a = lhs.value(at: sortColumn)
                let b = rhs.value(at: sortColumn)
                // Numeric columns (ids, timestamps) must not sort as strings.
                if let na = Double(a), let nb = Double(b) {
                    return sortAscending ? na < nb : na > nb
                }
                let result = a.localizedCaseInsensitiveCompare(b)
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
        }

        return rows
    }

    private var effectiveWidths: [CGFloat] {
        guard columnWidths.count == store.table.columns.count else {
            return store.table.naturalWidths()
        }
        return columnWidths
    }

    private var exportFilename: String {
        let base = store.table.name.replacingOccurrences(of: " ", with: "-").lowercased()
        return "droidhouse-\(base.isEmpty ? "roster" : base)"
    }

    // MARK: Actions

    private func resetLayout() {
        columnWidths = store.table.naturalWidths()
        sortColumn = nil
        sortAscending = true
        selectedRow = nil
    }

    private func resizeColumn(_ index: Int, by delta: CGFloat) {
        if columnWidths.count != store.table.columns.count {
            columnWidths = store.table.naturalWidths()
        }
        guard index < columnWidths.count else { return }
        columnWidths[index] = max(48, min(760, columnWidths[index] + delta))
    }

    private func copyRow(_ row: RosterRow) {
        let line = (0..<store.table.columns.count)
            .map { row.value(at: $0) }
            .joined(separator: "\t")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    private func copyRowJSON(_ row: RosterRow) {
        var object: [String: String] = [:]
        for (index, column) in store.table.columns.enumerated() {
            object[column] = row.value(at: index)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }
}

// MARK: - CSV export document

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Safe indexing

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
