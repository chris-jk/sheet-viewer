// Sheet Viewer: a fast window for spreadsheets. One tab per page, click a column
// to sort, type to filter, click a link to open it, and light editing (cells,
// rows, pages) with export to CSV or Excel. It shows a file's colors, bold and
// italic; it does not do formulas, charts or layout.
// CSV is read and written here; Excel and Numbers files go through read.py and write.py.
import AppKit
import UniformTypeIdentifiers

let appName = "Sheet Viewer"
let pythonURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/\(appName)/venv/bin/python")
let delimitedExtensions: Set<String> = ["csv", "tsv", "tab", "txt"]
let openableExtensions = ["csv", "tsv", "xlsx", "xlsm", "xltx", "xltm", "xls", "xlsb", "ods", "numbers"]

struct ViewerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Cell text

/// "$1,299.90", "26%", "(12)" and "-5" are numbers; "610-5330" and "1.2.3" are not.
func parseNumber(_ raw: String) -> Double? {
    var text = Substring(raw.trimmingCharacters(in: .whitespaces))
    guard !text.isEmpty, text.utf8.count <= 32 else { return nil }
    var negative = false
    if text.hasPrefix("("), text.hasSuffix(")") {
        negative = true
        text = text.dropFirst().dropLast()
    }
    for _ in 0..<2 {  // "-$5" and "$-5"
        if text.hasPrefix("-") || text.hasPrefix("\u{2212}") {
            negative = true
            text = text.dropFirst()
        } else if let first = text.first, "$€£¥+".contains(first) {
            text = text.dropFirst()
        }
    }
    if text.hasSuffix("%") { text = text.dropLast() }
    let digits = text.replacingOccurrences(of: ",", with: "")
    guard digits.contains(where: { $0.isASCII && $0.isNumber }),
          digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
          let value = Double(digits) else { return nil }
    return negative ? -value : value
}

/// "10/5/2026" or "10/05/26", with or without a time after it, as a number that sorts by day.
func parseSlashDate(_ text: String) -> Double? {
    let parts = (text.split(separator: " ", maxSplits: 1).first ?? "").split(separator: "/")
    guard parts.count == 3, let month = Int(parts[0]), let day = Int(parts[1]), var year = Int(parts[2]),
          (1...12).contains(month), (1...31).contains(day) else { return nil }
    if year < 100 { year += year < 70 ? 2000 : 1900 }
    return Double(year * 10000 + month * 100 + day)
}

/// Web pages and email addresses open on a click. Any other kind of link gets a question first.
func opensWithoutAsking(_ link: URL) -> Bool { ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") }

func columnLetters(_ index: Int) -> String {
    var n = index, letters = ""
    repeat {
        letters = String(UnicodeScalar(UInt8(65 + n % 26))) + letters
        n = n / 26 - 1
    } while n >= 0
    return letters
}

// MARK: - Reading and writing

func decodeText(_ data: Data) -> [UInt8] {
    if data.starts(with: [0xEF, 0xBB, 0xBF]) { return [UInt8](data.dropFirst(3)) }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
       let text = String(data: data, encoding: .utf16) { return [UInt8](text.utf8) }
    if String(data: data, encoding: .utf8) != nil { return [UInt8](data) }
    // Not UTF-8: an old Windows export.
    return [UInt8]((String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)).utf8)
}

/// The separator a delimited file uses: of , tab ; | the one that turns up the same number of times on the
/// most lines, outside quotes. A raw count is not enough: a comma file whose values hold "a;b;c" has more
/// semicolons than commas, but only the commas are steady from line to line.
func sniffDelimiter(_ bytes: [UInt8]) -> UInt8 {
    let candidates: [UInt8] = [44, 9, 59, 124]  // in order of preference on a tie
    var lines: [[UInt8: Int]] = [], counts: [UInt8: Int] = [:]
    var quoted = false
    for byte in bytes.prefix(65536) {
        if byte == 34 {
            quoted.toggle()
        } else if !quoted, byte == 10 {
            if !counts.isEmpty { lines.append(counts) }
            counts = [:]
            if lines.count == 30 { break }
        } else if !quoted, candidates.contains(byte) {
            counts[byte, default: 0] += 1
        }
    }
    if !counts.isEmpty, lines.count < 30 { lines.append(counts) }
    var best: UInt8 = 44, bestLines = 0
    for candidate in candidates {
        var tally: [Int: Int] = [:]  // times per line, to how many lines have that many
        for line in lines { if let times = line[candidate] { tally[times, default: 0] += 1 } }
        let steady = tally.values.max() ?? 0
        if steady > bestLines { (best, bestLines) = (candidate, steady) }
    }
    return best
}

func parseDelimited(_ bytes: [UInt8], delimiter: UInt8) -> [[String]] {
    var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
    var quoted = false, i = 0
    func take() -> String {
        defer { field.removeAll(keepingCapacity: true) }
        return String(decoding: field, as: UTF8.self)
    }
    while i < bytes.count {
        let byte = bytes[i]
        if quoted {
            if byte != 34 {
                field.append(byte)
            } else if i + 1 < bytes.count, bytes[i + 1] == 34 {
                field.append(34)
                i += 1
            } else {
                quoted = false
            }
        } else if byte == 34, field.isEmpty {
            quoted = true
        } else if byte == delimiter {
            row.append(take())
        } else if byte == 10 || byte == 13 {
            if byte == 13, i + 1 < bytes.count, bytes[i + 1] == 10 { i += 1 }
            row.append(take())
            rows.append(row)
            row = []
        } else {
            field.append(byte)
        }
        i += 1
    }
    if !field.isEmpty || !row.isEmpty {
        row.append(take())
        rows.append(row)
    }
    return rows
}

/// Rows as CSV text: a field is quoted only when it holds a comma, a quote or a line break.
func delimitedText(_ rows: [[String]]) -> String {
    rows.map { row in
        row.map { field in
            field.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
                ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
        }.joined(separator: ",")
    }.joined(separator: "\n") + "\n"
}

/// Drops the blank rows and columns a table ends with and makes every row the same width.
func squared(_ rows: [[String]]) -> [[String]] {
    var rows = rows
    while let last = rows.last, last.allSatisfy(\.isEmpty) { rows.removeLast() }
    let width = rows.map { ($0.lastIndex { !$0.isEmpty } ?? -1) + 1 }.max() ?? 0
    return rows.map { $0.count >= width ? Array($0[..<width]) : $0 + Array(repeating: "", count: width - $0.count) }
}

/// How a cell is dressed in the file: colors as "RRGGBB", nil where the file leaves it to the app.
struct CellStyle: Decodable, Equatable {
    var fill: String?
    var color: String?
    var bold = false
    var italic = false

    enum CodingKeys: String, CodingKey { case fill = "f", color = "c", bold = "b", italic = "i" }
}

/// The fills on offer for coloring rows and cells: pale enough that black text reads on them in light and dark mode.
let swatches: [(name: String, hex: String)] = [
    ("Yellow", "FFF59D"), ("Green", "C8E6C9"), ("Blue", "BBDEFB"), ("Red", "FFCDD2"),
    ("Orange", "FFE0B2"), ("Purple", "E1BEE7"), ("Gray", "E0E0E0"),
]

func rgb(_ hex: String) -> NSColor? {
    guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat(value >> 16 & 255) / 255, green: CGFloat(value >> 8 & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}

/// A menu of the swatches plus "No Color". Each item carries what `payload` makes of its color ("" for none).
func colorMenu(_ action: Selector, target: AnyObject?, payload: (String) -> Any) -> NSMenu {
    let menu = NSMenu()
    for (name, hex) in swatches {
        let item = menu.addItem(withTitle: name, action: action, keyEquivalent: "")
        let fill = rgb(hex) ?? .clear
        item.image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
        item.target = target
        item.representedObject = payload(hex)
    }
    menu.addItem(.separator())
    let none = menu.addItem(withTitle: "No Color", action: action, keyEquivalent: "")
    none.target = target
    none.representedObject = payload("")
    return menu
}

struct RawBook: Decodable {
    struct Link: Decodable { let r: Int, c: Int, u: String }
    struct Sheet: Decodable { let name: String, rows: [[String]], links: [Link], styles: [CellStyle], styled: [Int] }
    let sheets: [Sheet]
}

/// Runs one of the bundled Python scripts and returns what it printed.
func runPython(_ name: String, _ arguments: [String] = [], input: Data? = nil) throws -> Data {
    guard let script = Bundle.main.url(forResource: name, withExtension: "py"),
          FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
        throw ViewerError(message: "The Excel reader isn't installed. Run build.sh in the sheet-viewer folder.")
    }
    let process = Process(), output = Pipe(), errors = Pipe(), feed = Pipe()
    process.executableURL = pythonURL
    process.arguments = ["-I", script.path] + arguments
    process.standardInput = input == nil ? FileHandle.nullDevice : feed
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    // Feed and drain while it runs: a full pipe would stall the script.
    if let input {
        DispatchQueue.global().async {
            try? feed.fileHandleForWriting.write(contentsOf: input)
            try? feed.fileHandleForWriting.close()
        }
    }
    var complaint = Data()
    let draining = DispatchGroup()
    draining.enter()
    DispatchQueue.global().async {
        complaint = errors.fileHandleForReading.readDataToEndOfFile()
        draining.leave()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    draining.wait()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let lines = String(decoding: complaint, as: UTF8.self).split(separator: "\n")
        throw ViewerError(message: String(lines.last ?? "The file could not be handled."))
    }
    return data
}

func readBook(_ url: URL) throws -> [Sheet] {
    let ext = url.pathExtension.lowercased()
    if delimitedExtensions.contains(ext) || !openableExtensions.contains(ext) {
        let bytes = decodeText(try Data(contentsOf: url))
        let delimiter: UInt8 = ext == "tsv" || ext == "tab" ? 9 : sniffDelimiter(bytes)
        let cells = squared(parseDelimited(bytes, delimiter: delimiter))
        return cells.isEmpty ? [] : [Sheet(name: url.deletingPathExtension().lastPathComponent, cells: cells)]
    }
    return try JSONDecoder().decode(RawBook.self, from: runPython("read", [url.path])).sheets.map { raw in
        var links: [Int: [Int: String]] = [:]
        for link in raw.links { links[link.r, default: [:]][link.c] = link.u }
        return Sheet(name: raw.name, cells: squared(raw.rows), links: links, styles: raw.styles, styled: raw.styled)
    }
}

// MARK: - Sheet

final class Sheet {
    enum Kind { case text, number, date }

    struct Row {
        var cells: [String]
        var links: [Int: String] = [:]  // column to address
        var styles: [Int: Int] = [:]  // column to a place in the sheet's styles
    }

    /// Rows taken out, with what was showing at the time, so putting them back restores the view.
    struct Removed {
        var items: [(index: Int, row: Row)]
        var showing: [Int]
        var view: Int
    }

    var name: String
    let width: Int
    private(set) var styles: [CellStyle]
    private(set) var grid: [Row]
    var hasHeader: Bool { didSet { analyse() } }
    var sortColumn: Int?  // nil: the file's own order
    var ascending = true
    private(set) var titles: [String] = []
    private(set) var kinds: [Kind] = []
    private(set) var rows: [Int] = []  // what is showing, as indexes into grid
    private var haystack: [String]?  // each row's text for search; built on the first search, dropped on an edit
    private var view = 0  // counts sorts and searches: a row list saved under one is stale under the next

    init(name: String, cells: [[String]], links: [Int: [Int: String]] = [:], styles: [CellStyle] = [], styled: [Int] = []) {
        self.name = name
        self.styles = styles
        width = cells.first?.count ?? 0
        var grid = cells.enumerated().map { Row(cells: $1, links: links[$0] ?? [:]) }
        for at in stride(from: 0, to: styled.count - 2, by: 3)
        where grid.indices.contains(styled[at]) && (0..<width).contains(styled[at + 1]) && styles.indices.contains(styled[at + 2]) {
            grid[styled[at]].styles[styled[at + 1]] = styled[at + 2]
        }
        self.grid = grid
        // A header row is mostly filled and mostly words; a title line or a row of figures is not.
        let filled = (cells.first ?? []).filter { !$0.isEmpty }
        hasHeader = cells.count > 1 && filled.count * 5 >= width * 4
            && filled.filter { parseNumber($0) != nil }.count * 5 <= filled.count
        analyse()
        refresh(terms: [])
    }

    var count: Int { grid.count }
    var bodyStart: Int { hasHeader && !grid.isEmpty ? 1 : 0 }  // a page emptied of rows has no header row either
    var bodyCount: Int { grid.count - bodyStart }

    func text(_ row: Int, _ column: Int) -> String { grid[row].cells[column] }

    func style(_ row: Int, _ column: Int) -> CellStyle? { grid[row].styles[column].map { styles[$0] } }

    /// Where a cell leads: its link, or the web address it holds.
    func address(_ row: Int, _ column: Int) -> String? {
        if let link = grid[row].links[column] { return link }
        let text = grid[row].cells[column]
        return (text.hasPrefix("https://") || text.hasPrefix("http://")) && !text.contains(" ") ? text : nil
    }

    /// What copying or exporting a cell as plain text gives: a one-word label on a link ("open") is a button, so the address is the data.
    func copyText(_ row: Int, _ column: Int) -> String {
        let text = grid[row].cells[column]
        if let link = grid[row].links[column], !text.contains(" ") { return link }
        return text
    }

    private func analyse() {
        titles = (0..<width).map { bodyStart == 1 && !grid[0].cells[$0].isEmpty ? grid[0].cells[$0] : columnLetters($0) }
        kinds = (0..<width).map { column in
            var seen = 0, numbers = 0, dates = 0
            for row in bodyStart..<grid.count where !grid[row].cells[column].isEmpty {
                seen += 1
                if parseNumber(grid[row].cells[column]) != nil {
                    numbers += 1
                } else if parseSlashDate(grid[row].cells[column]) != nil {
                    dates += 1
                }
                if seen == 1000 { break }
            }
            if seen > 0, numbers * 10 >= seen * 9 { return .number }
            if seen > 0, dates * 10 >= seen * 9 { return .date }
            return .text
        }
    }

    // MARK: Showing

    private func matching(_ terms: [String]) -> [Int] {
        let body = Array(bodyStart..<grid.count)
        guard !terms.isEmpty else { return body }
        let hay = haystack ?? grid.map { ($0.cells + Array($0.links.values)).joined(separator: "\t").lowercased() }
        haystack = hay
        return body.filter { row in terms.allSatisfy { hay[row].range(of: $0, options: .literal) != nil } }
    }

    func matchCount(_ terms: [String]) -> Int { matching(terms).count }

    /// Rows put in the order the current sort asks for.
    private func ordered(_ keep: [Int]) -> [Int] {
        guard let column = sortColumn else { return ascending ? keep : keep.reversed() }
        let kind = kinds[column]
        let texts = keep.map { grid[$0].cells[column] }
        let values: [Double?] = kind == .text ? [] : texts.map(kind == .date ? parseSlashDate : parseNumber)
        let order = keep.indices.sorted { a, b in
            if texts[a].isEmpty != texts[b].isEmpty { return texts[b].isEmpty }  // blanks last either way
            var result = ComparisonResult.orderedSame
            if kind == .text {
                result = texts[a].localizedStandardCompare(texts[b])
            } else {
                switch (values[a], values[b]) {
                case let (x?, y?): result = x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
                case (_?, nil): return true  // figures ahead of stray words either way
                case (nil, _?): return false
                case (nil, nil): result = texts[a].localizedStandardCompare(texts[b])
                }
            }
            return result == .orderedSame ? a < b : (result == .orderedAscending) == ascending
        }
        return order.map { keep[$0] }
    }

    func refresh(terms: [String]) {
        view += 1
        rows = ordered(matching(terms))
    }

    /// The rows an export writes, header first: everything in the order on screen, or only what the search left showing.
    func exportRows(onlyShowing: Bool) -> [Int] {
        // With nothing hidden the screen already holds every row, with added and edited rows where they were put.
        // Sorting afresh would move them. Only when a search hides rows is there no screen order for the rest.
        let body = onlyShowing || rows.count == bodyCount ? rows : ordered(Array(bodyStart..<grid.count))
        return (bodyStart == 1 ? [0] : []) + body
    }

    // MARK: Editing

    private func changed() {
        haystack = nil
        analyse()
    }

    func blankRow() -> Row { Row(cells: Array(repeating: "", count: width)) }

    /// Fills cells with a color, or clears their fill with nil. Bold, italic and text color stay as they were.
    func fill(_ hex: String?, rows: [Int], columns: [Int]) {
        for row in rows {
            for column in columns {
                var look = style(row, column) ?? CellStyle()
                look.fill = hex
                if look == CellStyle() {
                    grid[row].styles[column] = nil
                } else if let known = styles.firstIndex(of: look) {
                    grid[row].styles[column] = known
                } else {
                    styles.append(look)
                    grid[row].styles[column] = styles.count - 1
                }
            }
        }
    }

    /// Rows' styles as they stand, to put back on undo.
    func styleMaps(_ rows: [Int]) -> [(row: Int, styles: [Int: Int])] { rows.map { (row: $0, styles: grid[$0].styles) } }

    func setStyleMaps(_ saved: [(row: Int, styles: [Int: Int])]) {
        for item in saved { grid[item.row].styles = item.styles }
    }

    /// Changes a cell and returns what it held. The row stays where it is on screen even if the sort would now move it.
    func set(_ text: String, row: Int, column: Int) -> String {
        let old = grid[row].cells[column]
        grid[row].cells[column] = text
        changed()
        return old
    }

    /// Adds a row to the file at `index` and to the screen at `place`: the caller knows where the eye is.
    func insert(_ row: Row, at index: Int, showingAt place: Int) {
        grid.insert(row, at: index)
        rows = rows.map { $0 >= index ? $0 + 1 : $0 }
        rows.insert(index, at: min(max(place, 0), rows.count))
        changed()
    }

    func remove(_ indexes: IndexSet) -> Removed {
        let removed = Removed(items: indexes.map { (index: $0, row: grid[$0]) }, showing: rows, view: view)
        var below = [Int](repeating: 0, count: grid.count), gone = 0  // how many removed rows sit above each row
        for index in grid.indices {
            below[index] = gone
            if indexes.contains(index) { gone += 1 }
        }
        rows = rows.compactMap { indexes.contains($0) ? nil : $0 - below[$0] }
        grid = grid.enumerated().compactMap { indexes.contains($0.offset) ? nil : $0.element }
        changed()
        return removed
    }

    /// Puts removed rows back where they were. The screen goes back too, unless the sort or search changed since.
    func restore(_ removed: Removed, terms: [String]) {
        var merged: [Row] = [], next = 0, kept = 0
        merged.reserveCapacity(grid.count + removed.items.count)
        for index in 0..<(grid.count + removed.items.count) {
            if next < removed.items.count, removed.items[next].index == index {
                merged.append(removed.items[next].row)
                next += 1
            } else {
                merged.append(grid[kept])
                kept += 1
            }
        }
        grid = merged
        changed()
        if removed.view == view {
            rows = removed.showing
        } else {
            refresh(terms: terms)
        }
    }
}

// MARK: - Views

final class GridView: NSTableView {
    var onCopy: (() -> Void)?
    var onType: ((String) -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?() }

    // Typing over the table starts a search.
    override func keyDown(with event: NSEvent) {
        let held = event.modifierFlags.intersection([.command, .control, .option])
        if held.isEmpty, let typed = event.characters, typed.count == 1,
           let scalar = typed.unicodeScalars.first, CharacterSet.alphanumerics.contains(scalar) {
            onType?(typed)
        } else {
            super.keyDown(with: event)
        }
    }
}

final class CellView: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("cell")
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = CellView.id
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.allowsExpansionToolTips = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var fill: NSColor?

    // A fill covers the row's own highlight, so a selected filled cell takes on some of the selection color.
    override var backgroundStyle: NSView.BackgroundStyle { didSet { paint() } }

    private func paint() {
        let selected = backgroundStyle == .emphasized
        layer?.backgroundColor = (selected ? fill?.blended(withFraction: 0.4, of: .selectedContentBackgroundColor) : fill)?.cgColor
    }

    /// Where the words are drawn, which is narrower than the cell when they are short.
    var textFrame: NSRect {
        let width = min(label.frame.width, label.attributedStringValue.size().width + 2)
        return NSRect(x: label.alignment == .right ? label.frame.maxX - width : label.frame.minX, y: label.frame.minY,
                      width: width, height: label.frame.height)
    }

    func show(_ text: String, font: NSFont, color: NSColor, alignment: NSTextAlignment, fill: NSColor? = nil, underlined: Bool = false) {
        self.fill = fill
        paint()
        label.isEditable = false
        label.font = font
        label.alignment = alignment
        if underlined {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.alignment = alignment
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style, .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        } else {
            label.stringValue = text
            label.textColor = color
        }
    }
}

// MARK: - Window

final class ViewerController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate,
    NSMenuDelegate, NSMenuItemValidation
{
    let url: URL
    let window: NSWindow
    var onClose: (() -> Void)?
    private(set) var edited = false { didSet { window.isDocumentEdited = edited } }

    private let table = GridView()
    private let scroll = NSScrollView()
    private let tabs = NSSegmentedControl()
    private let picker = NSPopUpButton()
    private let search = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let notice = NSTextField(labelWithString: "Opening…")
    private let undo = UndoManager()
    private let fonts: [NSFont] = {  // plain, bold, italic, bold italic
        let plain = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        func slanted(_ font: NSFont) -> NSFont {
            NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic)), size: 13) ?? font
        }
        return [plain, bold, slanted(plain), slanted(bold)]
    }()
    private let numbers: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
    private var colors: [String: NSColor] = [:]
    private var sheets: [Sheet] = []
    private var current = 0
    private var restoringSort = false
    private var exportFormat: NSPopUpButton?
    private var exportShowing: NSButton?
    private weak var exportPanel: NSSavePanel?

    private var sheet: Sheet? { sheets.indices.contains(current) ? sheets[current] : nil }
    private var terms: [String] { search.stringValue.lowercased().split(separator: " ").map(String.init) }
    private var baseName: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL) {
        self.url = url
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: min(1280, screen.width * 0.86), height: min(820, screen.height * 0.86))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = url.lastPathComponent
        window.representedURL = url
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 620, height: 280)
        window.delegate = self
        window.center()
        buildContent()
    }

    private func buildContent() {
        tabs.trackingMode = .selectOne
        tabs.target = self
        tabs.action = #selector(tabChosen)
        tabs.isHidden = true
        picker.target = self
        picker.action = #selector(tabChosen)
        picker.isHidden = true
        // Right-click the tabs to add or delete a page. Not the picker: a pop-up button's menu is its list of pages.
        tabs.menu = NSMenu()
        tabs.menu?.delegate = self

        search.placeholderString = "Search"
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchChanged)
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
            let button = NSButton(image: image, target: self, action: action)
            button.toolTip = tip
            return button
        }
        // A pull-down wears its first item as its face.
        let paint = NSPopUpButton(frame: .zero, pullsDown: true)
        paint.menu = colorMenu(#selector(colorRows), target: self) { $0 }
        let face = NSMenuItem()
        face.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Color")
        paint.menu?.insertItem(face, at: 0)
        paint.imagePosition = .imageOnly
        paint.toolTip = "Color the selected rows"
        let export = NSButton(title: "Export…", target: self, action: #selector(exportDocument))
        export.toolTip = "Save as CSV or Excel (⌘S)"
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [
            tabs, picker, gap, count,
            button("plus", "Add a row under the selected one (⌘↩)", #selector(addRow)),
            button("minus", "Delete the selected rows (⌘⌫)", #selector(deleteRows)),
            paint, export, search,
        ])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let rule = NSBox()
        rule.boxType = .separator

        table.dataSource = self
        table.delegate = self
        table.style = .plain
        table.rowHeight = 24
        table.intercellSpacing = .zero  // so a colored row is one unbroken band
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.target = self
        table.action = #selector(cellClicked)
        table.doubleAction = #selector(cellDoubleClicked)
        table.onCopy = { [weak self] in self?.copySelection() }
        table.onType = { [weak self] typed in self?.search(adding: typed) }
        table.menu = NSMenu()
        table.menu?.delegate = self

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        notice.textColor = .secondaryLabelColor
        notice.font = .systemFont(ofSize: 15)

        let content = NSView()
        for view in [bar, rule, scroll, notice] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            search.widthAnchor.constraint(equalToConstant: 220),
            rule.topAnchor.constraint(equalTo: bar.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            notice.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            notice.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        window.contentView = content
        window.initialFirstResponder = table
    }

    // MARK: Loading

    func load() {
        notice.stringValue = sheets.isEmpty ? "Opening…" : ""
        let url = url
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try readBook(url) }
            DispatchQueue.main.async {
                switch result {
                case .success(let sheets): self.show(sheets)
                case .failure(let error): self.notice.stringValue = error.localizedDescription
                }
            }
        }
    }

    func show(_ book: [Sheet]) {
        endEditing()  // into the pages being replaced, not the new ones
        // A reload keeps each page's sort and header choice.
        for sheet in book {
            guard let old = sheets.first(where: { $0.name == sheet.name }), old.width == sheet.width else { continue }
            sheet.hasHeader = old.hasHeader
            sheet.sortColumn = old.sortColumn
            sheet.ascending = old.ascending
        }
        sheets = book
        undo.removeAllActions()
        edited = false
        notice.stringValue = sheets.isEmpty ? "Nothing in this file" : ""
        buildTabs()
        select(min(current, max(0, sheets.count - 1)))
    }

    private func buildTabs() {
        let names = sheets.map(\.name)
        let crowded = names.count > 8 || names.joined().count > 90
        tabs.isHidden = crowded || names.count < 2
        picker.isHidden = !crowded
        tabs.segmentCount = names.count
        picker.removeAllItems()
        for name in names { picker.menu?.addItem(NSMenuItem(title: name, action: nil, keyEquivalent: "")) }
    }

    func select(_ index: Int) {
        endEditing()
        current = index
        tabs.selectedSegment = index
        picker.selectItem(at: index)
        for column in table.tableColumns { table.removeTableColumn(column) }
        guard let sheet else {
            table.reloadData()
            count.stringValue = ""
            return
        }

        let rowNumbers = NSTableColumn(identifier: .init("#"))
        rowNumbers.title = "#"
        rowNumbers.headerToolTip = "Row in the file. Click for the file's own order."
        rowNumbers.width = CGFloat(String(sheet.count).count) * 9 + 20
        rowNumbers.minWidth = 28
        rowNumbers.headerCell.alignment = .right
        rowNumbers.sortDescriptorPrototype = NSSortDescriptor(key: "#", ascending: true)
        table.addTableColumn(rowNumbers)
        for index in 0..<sheet.width {
            let column = NSTableColumn(identifier: .init("c\(index)"))
            column.title = sheet.titles[index]
            column.headerToolTip = sheet.titles[index]
            column.width = fittedWidth(sheet, index)
            column.minWidth = 36
            column.sortDescriptorPrototype = NSSortDescriptor(key: "c\(index)", ascending: true)
            if sheet.kinds[index] != .text { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        restoringSort = true
        table.sortDescriptors = [NSSortDescriptor(key: sheet.sortColumn.map { "c\($0)" } ?? "#", ascending: sheet.ascending)]
        restoringSort = false
        refresh()
    }

    private func fittedWidth(_ sheet: Sheet, _ column: Int) -> CGFloat {
        let heading = [NSAttributedString.Key.font: NSTableHeaderCell(textCell: "").font ?? NSFont.systemFont(ofSize: 13)]
        var widest = (sheet.titles[column] as NSString).size(withAttributes: heading).width + 34  // room for the sort arrow
        // Measure rows spread over the whole sheet: the top of a long list is not the widest part.
        for row in stride(from: sheet.bodyStart, to: sheet.count, by: max(1, sheet.bodyCount / 300)) where widest < 460 {
            let text = sheet.text(row, column)
            if !text.isEmpty { widest = max(widest, (text as NSString).size(withAttributes: [.font: fonts[1]]).width + 18) }
        }
        return min(max(widest.rounded(.up), 44), 460)
    }

    /// Filters and sorts afresh, then redraws.
    private func refresh() {
        guard let sheet else { return }
        sheet.refresh(terms: terms)
        redraw()
        if sheet.rows.count > 0 { table.scrollRowToVisible(0) }
    }

    /// Redraws what the sheet says is showing, without re-sorting it.
    private func redraw() {
        guard let sheet else { return }
        let terms = terms
        table.deselectAll(nil)
        table.reloadData()
        let total = numbers.string(from: sheet.bodyCount as NSNumber) ?? "\(sheet.bodyCount)"
        let showing = numbers.string(from: sheet.rows.count as NSNumber) ?? "\(sheet.rows.count)"
        count.stringValue = terms.isEmpty ? "\(total) rows" : "\(showing) of \(total) rows"
        // While searching, each tab says how many rows it has that match.
        for (index, other) in sheets.enumerated() {
            let matches = numbers.string(from: other.matchCount(terms) as NSNumber) ?? ""
            let label = terms.isEmpty ? other.name : "\(other.name)  \(matches)"
            tabs.setLabel(label, forSegment: index)
            tabs.setWidth(0, forSegment: index)
            picker.item(at: index)?.title = label
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { sheet?.rows.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let sheet, let tableColumn, row < sheet.rows.count else { return nil }
        let cell = tableView.makeView(withIdentifier: CellView.id, owner: nil) as? CellView ?? CellView()
        cell.label.delegate = self
        let source = sheet.rows[row]
        guard let column = dataColumn(tableColumn) else {
            cell.show(String(source + 1), font: fonts[0], color: .tertiaryLabelColor, alignment: .right)
            cell.toolTip = nil
            return cell
        }
        let style = sheet.style(source, column), linked = sheet.address(source, column) != nil
        cell.show(sheet.text(source, column),
                  font: fonts[(style?.bold == true ? 1 : 0) + (style?.italic == true ? 2 : 0)],
                  color: textColor(style, linked: linked),
                  alignment: sheet.kinds[column] == .text ? .left : .right,
                  fill: style?.fill.flatMap(color), underlined: linked)
        cell.toolTip = sheet.grid[source].links[column]  // where a labelled link ("open") leads
        return cell
    }

    private func color(_ hex: String) -> NSColor? {
        if let known = colors[hex] { return known }
        let made = rgb(hex)
        colors[hex] = made
        return made
    }

    /// A file's colors were picked for black on white paper. On a filled cell they hold; on the window's own
    /// background a dark one would vanish in dark mode, so it becomes the system's ordinary or quiet text color.
    private func textColor(_ style: CellStyle?, linked: Bool) -> NSColor {
        let filled = style?.fill != nil
        guard let hex = style?.color, let chosen = color(hex) else {
            if linked { return filled ? NSColor(srgbRed: 0.02, green: 0.39, blue: 0.76, alpha: 1) : .linkColor }
            return filled ? .black : .labelColor
        }
        if filled { return chosen }
        if linked { return .linkColor }
        let light = 0.2126 * chosen.redComponent + 0.7152 * chosen.greenComponent + 0.0722 * chosen.blueComponent
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark, light < 0.45 { return light < 0.12 ? .labelColor : .secondaryLabelColor }
        if !dark, light > 0.8 { return .labelColor }
        return chosen
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !restoringSort, let sheet, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else { return }
        endEditing()
        sheet.sortColumn = Int(key.dropFirst())  // "#" has no number: back to the file's order
        sheet.ascending = descriptor.ascending
        refresh()
    }

    private func dataColumn(_ column: NSTableColumn) -> Int? { Int(column.identifier.rawValue.dropFirst()) }

    func link(row: Int, column: Int) -> URL? {
        guard let sheet, sheet.rows.indices.contains(row), table.tableColumns.indices.contains(column),
              let index = dataColumn(table.tableColumns[column]),
              let address = sheet.address(sheet.rows[row], index) else { return nil }
        return URL(string: address) ?? address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap { URL(string: $0) }
    }

    @objc private func cellClicked() {
        let row = table.clickedRow, column = table.clickedColumn
        // Only the words are the link. The rest of the cell, a click with a key held and a double-click
        // are for selecting and editing, and must not send the browser off.
        guard let event = NSApp.currentEvent, event.clickCount == 1,
              event.modifierFlags.intersection([.shift, .command, .control, .option]).isEmpty,
              let target = link(row: row, column: column),
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? CellView,
              cell.textFrame.insetBy(dx: -3, dy: -3).contains(cell.convert(event.locationInWindow, from: nil)) else { return }
        follow(target)
    }

    /// Opens a link. A file someone sent can link a harmless-looking word to an app, a shortcut or a network
    /// share, so anything that is not a web page or an email address is shown in full and asked about first.
    private func follow(_ target: URL) {
        guard !opensWithoutAsking(target) else {
            NSWorkspace.shared.open(target)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Open this link?"
        alert.informativeText = "It is not a web page:\n\n" + String(target.absoluteString.prefix(400))
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        alert.beginSheetModal(for: window) { if $0 == .alertSecondButtonReturn { NSWorkspace.shared.open(target) } }
    }

    @objc private func cellDoubleClicked() { beginEditing(row: table.clickedRow, column: table.clickedColumn) }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copySelection() {
        guard let sheet, !table.selectedRowIndexes.isEmpty else { return NSSound.beep() }
        let columns = table.tableColumns.compactMap(dataColumn)
        put(table.selectedRowIndexes.map { row in
            columns.map { sheet.copyText(sheet.rows[row], $0) }.joined(separator: "\t")
        }.joined(separator: "\n"))
    }

    // MARK: Editing cells

    /// Opens a cell for typing. Rows and columns here are the table's: what is on screen.
    func beginEditing(row: Int, column: Int) {
        guard let sheet, sheet.rows.indices.contains(row), table.tableColumns.indices.contains(column),
              let index = dataColumn(table.tableColumns[column]) else { return }
        table.scrollRowToVisible(row)
        table.scrollColumnToVisible(column)
        guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? CellView else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        cell.label.stringValue = sheet.text(sheet.rows[row], index)  // the bare text, without a link's underline
        cell.label.isEditable = true
        window.makeFirstResponder(cell.label)
    }

    func endEditing() {
        if window.firstResponder is NSText { window.makeFirstResponder(table) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let cell = field.superview as? CellView, field.isEditable else { return }
        field.isEditable = false
        let row = table.row(for: cell), column = table.column(for: cell)
        guard let sheet, sheet.rows.indices.contains(row), table.tableColumns.indices.contains(column),
              let index = dataColumn(table.tableColumns[column]) else { return }
        let source = sheet.rows[row]
        if field.stringValue != sheet.text(source, index) { setCell(sheet, row: source, column: index, to: field.stringValue) }
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        DispatchQueue.main.async {
            // Tab carries on into the next cell; anything else hands the keyboard back to the table.
            if movement == NSTextMovement.tab.rawValue, column + 1 < self.table.numberOfColumns {
                self.beginEditing(row: row, column: column + 1)
            } else if movement == NSTextMovement.backtab.rawValue, column > 1 {
                self.beginEditing(row: row, column: column - 1)
            } else {
                self.table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<self.table.numberOfColumns))
                if self.window.firstResponder === self.window || self.window.firstResponder is NSText {
                    self.window.makeFirstResponder(self.table)
                }
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)), let field = control as? NSTextField else { return false }
        field.abortEditing()
        field.isEditable = false
        window.makeFirstResponder(table)
        table.reloadData(forRowIndexes: table.selectedRowIndexes, columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        return true
    }

    // MARK: Changes, each one undoable

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    private func changed(_ sheet: Sheet, _ what: String, keepingSelection: Bool = false) {
        if !undo.isUndoing, !undo.isRedoing { undo.setActionName(what) }
        edited = true
        // An undo can reach back to another page: go there so the change is seen.
        if let index = sheets.firstIndex(where: { $0 === sheet }), index != current {
            select(index)
        } else {
            let selection = table.selectedRowIndexes
            redraw()
            if keepingSelection { table.selectRowIndexes(selection, byExtendingSelection: false) }
        }
    }

    private func setCell(_ sheet: Sheet, row: Int, column: Int, to text: String) {
        let old = sheet.set(text, row: row, column: column)
        undo.registerUndo(withTarget: self) { $0.setCell(sheet, row: row, column: column, to: old) }
        changed(sheet, "Edit Cell", keepingSelection: true)
    }

    private func fill(_ sheet: Sheet, _ hex: String?, rows: [Int], columns: [Int]) {
        let before = sheet.styleMaps(rows)
        sheet.fill(hex, rows: rows, columns: columns)
        undo.registerUndo(withTarget: self) { $0.restoreStyles(sheet, before) }
        changed(sheet, hex == nil ? "Clear Color" : "Color", keepingSelection: true)
    }

    private func restoreStyles(_ sheet: Sheet, _ saved: [(row: Int, styles: [Int: Int])]) {
        let before = sheet.styleMaps(saved.map(\.row))
        sheet.setStyleMaps(saved)
        undo.registerUndo(withTarget: self) { $0.restoreStyles(sheet, before) }
        changed(sheet, "Color", keepingSelection: true)
    }

    private func removeRows(_ sheet: Sheet, _ indexes: IndexSet) {
        let removed = sheet.remove(indexes)
        undo.registerUndo(withTarget: self) { $0.restoreRows(sheet, removed) }
        changed(sheet, indexes.count == 1 ? "Delete Row" : "Delete Rows")
    }

    private func restoreRows(_ sheet: Sheet, _ removed: Sheet.Removed) {
        sheet.restore(removed, terms: sheet === self.sheet ? terms : [])
        undo.registerUndo(withTarget: self) { $0.removeRows(sheet, IndexSet(removed.items.map(\.index))) }
        changed(sheet, "Add Row")
    }

    private func insertPage(_ sheet: Sheet, at index: Int) {
        sheets.insert(sheet, at: index)
        undo.registerUndo(withTarget: self) { $0.removePage(at: index) }
        if !undo.isUndoing, !undo.isRedoing { undo.setActionName("Add Page") }
        edited = true
        buildTabs()
        select(index)
    }

    private func removePage(at index: Int) {
        let sheet = sheets.remove(at: index)
        undo.registerUndo(withTarget: self) { $0.insertPage(sheet, at: index) }
        if !undo.isUndoing, !undo.isRedoing { undo.setActionName("Delete Page") }
        edited = true
        buildTabs()
        select(min(index, sheets.count - 1))
    }

    @objc func addRow(_ sender: Any?) {
        guard let sheet else { return }
        endEditing()
        // Under the selected row, in the file and on screen; with nothing selected, at the end of both.
        let selected = table.selectedRowIndexes.last
        let index = selected.map { sheet.rows[$0] + 1 } ?? sheet.count
        sheet.insert(sheet.blankRow(), at: index, showingAt: selected.map { $0 + 1 } ?? sheet.rows.count)
        undo.registerUndo(withTarget: self) { $0.removeRows(sheet, [index]) }
        changed(sheet, "Add Row")
        if let showing = sheet.rows.firstIndex(of: index) { beginEditing(row: showing, column: 1) }
    }

    @objc func deleteRows(_ sender: Any?) {
        guard let sheet, !table.selectedRowIndexes.isEmpty else { return NSSound.beep() }
        endEditing()
        removeRows(sheet, IndexSet(table.selectedRowIndexes.map { sheet.rows[$0] }))
    }

    /// Colors the selected rows. The menu item carries the color; "" clears it.
    @objc func colorRows(_ sender: NSMenuItem) {
        guard let sheet, !table.selectedRowIndexes.isEmpty, let hex = sender.representedObject as? String else { return NSSound.beep() }
        endEditing()
        fill(sheet, hex.isEmpty ? nil : hex, rows: table.selectedRowIndexes.map { sheet.rows[$0] }, columns: Array(0..<sheet.width))
    }

    /// Colors one cell. The menu item carries the cell's row and column in the file, then the color.
    @objc private func colorCell(_ sender: NSMenuItem) {
        guard let sheet, let spot = sender.representedObject as? [Any], spot.count == 3,
              let row = spot[0] as? Int, let column = spot[1] as? Int, let hex = spot[2] as? String else { return }
        endEditing()
        fill(sheet, hex.isEmpty ? nil : hex, rows: [row], columns: [column])
    }

    @objc func addPage(_ sender: Any?) {
        let name = NSTextField(string: "Page \(sheets.count + 1)")
        name.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        let alert = NSAlert()
        alert.messageText = "Add a page"
        alert.informativeText = "It starts empty, with the same columns as this page."
        alert.accessoryView = name
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { self.addPage(named: name.stringValue) }
        }
    }

    func addPage(named name: String) {
        endEditing()
        let width = max(sheet?.width ?? 0, 1)
        let blank = Array(repeating: "", count: width)
        let header = sheet.flatMap { like in like.hasHeader ? (0..<like.width).map { like.text(0, $0) } : nil }
        let page = Sheet(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Page \(sheets.count + 1)" : name,
                         cells: (header.map { [$0] } ?? []) + [blank])
        page.hasHeader = header != nil
        insertPage(page, at: sheets.isEmpty ? 0 : current + 1)
    }

    @objc func deletePage(_ sender: Any?) {
        guard sheets.count > 1 else { return NSSound.beep() }
        endEditing()
        removePage(at: current)
    }

    // MARK: Export

    @objc func exportDocument(_ sender: Any?) {
        guard let sheet else { return }
        endEditing()
        let panel = NSSavePanel()
        let format = NSPopUpButton()
        format.addItems(withTitles: [sheets.count > 1 ? "CSV (this page)" : "CSV", sheets.count > 1 ? "Excel (all pages)" : "Excel"])
        format.selectItem(at: delimitedExtensions.contains(url.pathExtension.lowercased()) ? 0 : 1)
        format.target = self
        format.action = #selector(exportFormatChanged)
        let showing = NSButton(checkboxWithTitle: "Only the \(numbers.string(from: sheet.rows.count as NSNumber) ?? "") rows showing",
                               target: nil, action: nil)
        showing.isHidden = terms.isEmpty
        let line = NSStackView(views: [NSTextField(labelWithString: "Format:"), format, showing])
        line.spacing = 10
        line.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        panel.accessoryView = line
        panel.directoryURL = url.deletingLastPathComponent()
        exportPanel = panel
        exportFormat = format
        exportShowing = showing
        exportFormatChanged()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let target = panel.url else { return }
            do {
                try self.export(to: target, excel: format.indexOfSelectedItem == 1, onlyShowing: !showing.isHidden && showing.state == .on)
            } catch {
                let alert = NSAlert(error: error)
                alert.beginSheetModal(for: self.window)
            }
        }
    }

    @objc private func exportFormatChanged() {
        guard let panel = exportPanel, let format = exportFormat, let sheet else { return }
        let excel = format.indexOfSelectedItem == 1
        panel.allowedContentTypes = [UTType(filenameExtension: excel ? "xlsx" : "csv")].compactMap { $0 }
        panel.nameFieldStringValue = exportName(sheet, excel: excel)
    }

    /// The file name an export is offered under.
    func exportName(_ sheet: Sheet, excel: Bool) -> String {
        // An Excel export holds values, not the original's formulas: steer it away from landing on the original.
        let source = url.pathExtension.lowercased()
        let name = excel ? (source == "xlsx" || source == "xlsm" ? baseName + " edited" : baseName)
            : (sheets.count > 1 ? "\(baseName) - \(sheet.name)" : baseName)
        return name.replacingOccurrences(of: "/", with: "-") + (excel ? ".xlsx" : ".csv")
    }

    /// Writes this page as CSV, or every page as an Excel workbook, in the order on screen.
    func export(to target: URL, excel: Bool, onlyShowing: Bool) throws {
        guard let sheet else { return }
        if !excel {
            let text = delimitedText(sheet.exportRows(onlyShowing: onlyShowing).map { row in
                (0..<sheet.width).map { sheet.copyText(row, $0) }
            })
            try Data(text.utf8).write(to: target, options: .atomic)
            if sheets.count == 1, !onlyShowing { edited = false }
            return
        }
        let pages: [[String: Any]] = sheets.map { page in
            let order = page.exportRows(onlyShowing: onlyShowing && page === sheet)
            var links: [[String: Any]] = [], styled: [Int] = []
            for (row, source) in order.enumerated() {
                for (column, address) in page.grid[source].links { links.append(["r": row, "c": column, "u": address]) }
                for (column, style) in page.grid[source].styles { styled += [row, column, style] }
            }
            return [
                "name": page.name, "header": page.hasHeader, "rows": order.map { page.grid[$0].cells }, "links": links,
                "styles": page.styles.map { ["f": $0.fill as Any, "c": $0.color as Any, "b": $0.bold, "i": $0.italic] },
                "styled": styled,
            ]
        }
        let payload = try JSONSerialization.data(withJSONObject: ["path": target.path, "sheets": pages])
        _ = try runPython("write", input: payload)
        if !onlyShowing { edited = false }
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, _ payload: Any? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = payload
        }
        guard menu === table.menu else {
            add("Add Page…", #selector(addPage(_:)))
            if let sheet, sheets.count > 1 { add("Delete “\(sheet.name)”", #selector(deletePage)) }
            return
        }
        let row = table.clickedRow, column = table.clickedColumn
        guard let sheet, sheet.rows.indices.contains(row) else { return }
        // Acting on a row from its menu acts on that row, as in Finder.
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes([row], byExtendingSelection: false) }
        let columns = table.tableColumns.compactMap(dataColumn)
        if table.tableColumns.indices.contains(column), let index = dataColumn(table.tableColumns[column]) {
            add("Edit Cell", #selector(editPayload), [row, column])
            add("Copy Cell", #selector(copyPayload), sheet.text(sheet.rows[row], index))
        }
        add("Copy Row", #selector(copyPayload), columns.map { sheet.copyText(sheet.rows[row], $0) }.joined(separator: "\t"))
        if let target = link(row: row, column: column) {
            menu.addItem(.separator())
            add("Open Link", #selector(openPayload), target)
            add("Copy Link", #selector(copyPayload), target.absoluteString)
        }
        menu.addItem(.separator())
        add("Add Row Below", #selector(addRow))
        add(table.selectedRowIndexes.count > 1 ? "Delete \(table.selectedRowIndexes.count) Rows" : "Delete Row", #selector(deleteRows))
        menu.addItem(.separator())
        menu.addItem(withTitle: table.selectedRowIndexes.count > 1 ? "Color Rows" : "Color Row", action: nil, keyEquivalent: "")
            .submenu = colorMenu(#selector(colorRows), target: self) { $0 }
        if table.tableColumns.indices.contains(column), let index = dataColumn(table.tableColumns[column]) {
            let source = sheet.rows[row]
            menu.addItem(withTitle: "Color Cell", action: nil, keyEquivalent: "")
                .submenu = colorMenu(#selector(colorCell), target: self) { [source, index, $0] as [Any] }
        }
    }

    @objc private func editPayload(_ sender: NSMenuItem) {
        if let spot = sender.representedObject as? [Int], spot.count == 2 { beginEditing(row: spot[0], column: spot[1]) }
    }

    @objc private func copyPayload(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { put(text) }
    }

    @objc private func openPayload(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? URL { follow(target) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleHeader):
            item.state = sheet?.hasHeader == true ? .on : .off
            return sheet != nil
        // While typing, ⌘⌫ belongs to the text: it clears the line, it must not delete the row.
        case #selector(deleteRows), #selector(colorRows): return !(window.firstResponder is NSText) && !table.selectedRowIndexes.isEmpty
        case #selector(deletePage): return !(window.firstResponder is NSText) && sheets.count > 1
        case #selector(addRow), #selector(exportDocument): return sheet != nil
        default: return true
        }
    }

    @objc func toggleHeader(_ sender: Any?) {
        guard let sheet, sheet.count > 0 else { return NSSound.beep() }
        sheet.sortColumn = nil
        sheet.ascending = true
        sheet.hasHeader.toggle()
        select(current)
    }

    @objc func reload(_ sender: Any?) {
        endEditing()
        guard edited else { return load() }
        let alert = NSAlert()
        alert.messageText = "Reload and lose your changes?"
        alert.informativeText = "The file is read again from disk. Changes you have not exported are dropped."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { self.load() } }
    }

    @objc func showInFinder(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    @objc func focusSearch(_ sender: Any?) { window.makeFirstResponder(search) }

    @objc private func tabChosen(_ sender: NSControl) {
        select(sender === picker ? picker.indexOfSelectedItem : tabs.selectedSegment)
    }

    @objc private func searchChanged() { refresh() }

    private func search(adding typed: String) {
        window.makeFirstResponder(search)
        search.stringValue += typed
        search.currentEditor()?.selectedRange = NSRange(location: (search.stringValue as NSString).length, length: 0)
        refresh()
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        endEditing()
        guard edited else { return true }
        let alert = NSAlert()
        alert.messageText = "Export your changes to “\(url.lastPathComponent)”?"
        alert.informativeText = "Changes made here are lost unless you export them."
        alert.addButton(withTitle: "Export…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Changes")
        alert.beginSheetModal(for: window) { response in
            if response == .alertThirdButtonReturn {
                self.edited = false
                self.window.close()
            } else if response == .alertFirstButtonReturn {
                DispatchQueue.main.async { self.exportDocument(nil) }
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: Checks

    /// Runs the actions the menus and mouse do, for checks that never show the window. Commands are joined by ";":
    /// sheet:2, search:goggle clear, sort:9, sortdesc:9, header, select:0,1, edit:row,column,text, add, delete,
    /// undo, redo, addpage:Name, deletepage, color:FFF59D, color:none, colorcell:row,column,C8E6C9, csv:path,
    /// csvshowing:path, xlsx:path, names, link:row,column.
    func run(script: String) -> Bool {
        undo.groupsByEvent = false  // no events here: each command is its own undo step
        for command in script.split(separator: ";") {
            let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
            let name = parts[0], argument = parts.count > 1 ? parts[1] : ""
            let given = argument.split(separator: ",").compactMap { Int($0) }
            let changes = ["edit", "add", "delete", "addpage", "deletepage", "color", "colorcell"].contains(name)
            if changes { undo.beginUndoGrouping() }
            defer { if changes { undo.endUndoGrouping() } }
            switch name {
            case "sheet" where sheets.indices.contains(given.first ?? -1): select(given[0])
            case "search":
                search.stringValue = argument
                refresh()
            case "sort" where given.count == 1, "sortdesc" where given.count == 1:
                table.sortDescriptors = [NSSortDescriptor(key: "c\(given[0])", ascending: name == "sort")]
            case "header": toggleHeader(nil)
            case "select": table.selectRowIndexes(IndexSet(given), byExtendingSelection: false)
            case "edit":
                let fields = argument.split(separator: ",", maxSplits: 2).map(String.init)
                guard fields.count == 3, let row = Int(fields[0]), let column = Int(fields[1]) else { return false }
                // Through the real path: open the cell, type, leave it.
                beginEditing(row: row, column: column)
                guard let editor = window.firstResponder as? NSTextView else {
                    print("could not open row \(row), column \(column) for typing")
                    return false
                }
                editor.insertText(fields[2], replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                endEditing()
            case "add":
                addRow(nil)
                endEditing()
            case "delete": deleteRows(nil)
            case "undo": undo.undo()
            case "redo": undo.redo()
            case "addpage": addPage(named: argument)
            case "deletepage": deletePage(nil)
            case "csv", "csvshowing", "xlsx":
                do {
                    try export(to: URL(fileURLWithPath: argument), excel: name == "xlsx", onlyShowing: name == "csvshowing")
                } catch {
                    print("export failed: \(error.localizedDescription)")
                    return false
                }
            case "color":  // the selected rows; "none" clears
                guard let sheet else { return false }
                fill(sheet, argument == "none" ? nil : argument, rows: table.selectedRowIndexes.map { sheet.rows[$0] }, columns: Array(0..<sheet.width))
            case "colorcell":  // row,column on screen, then the color
                let fields = argument.split(separator: ",").map(String.init)
                guard let sheet, fields.count == 3, let row = Int(fields[0]), let column = Int(fields[1]),
                      sheet.rows.indices.contains(row), table.tableColumns.indices.contains(column),
                      let index = dataColumn(table.tableColumns[column]) else { return false }
                fill(sheet, fields[2] == "none" ? nil : fields[2], rows: [sheet.rows[row]], columns: [index])
            case "names":
                if let sheet { print("offered as:", exportName(sheet, excel: false), "|", exportName(sheet, excel: true)) }
            case "link" where given.count == 2:
                print("link at row \(given[0]), column \(given[1]):", link(row: given[0], column: given[1])?.absoluteString ?? "none")
            default:
                print("unknown or malformed command: \(command)")
                return false
            }
        }
        print("pages: \(sheets.map { "\($0.name) \($0.bodyCount)" }.joined(separator: " | ")); edited: \(edited)")
        return true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var viewers: [ViewerController] = []
    private var cascade = NSPoint.zero

    func applicationWillFinishLaunching(_ notification: Notification) { NSApp.mainMenu = mainMenu() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A double-clicked file arrives a moment after launch; with none, ask for one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if self.viewers.isEmpty { self.openDocument(nil) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach(open) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if viewers.isEmpty { openDocument(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        viewers.forEach { $0.endEditing() }  // text still in an open cell counts as a change
        let unsaved = viewers.filter(\.edited)
        guard !unsaved.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1 ? "Quit without exporting “\(unsaved[0].url.lastPathComponent)”?"
            : "Quit without exporting \(unsaved.count) files?"
        alert.informativeText = "Changes made here are lost unless you export them."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        if let viewer = viewers.first(where: { $0.url == url }) {
            viewer.window.makeKeyAndOrderFront(nil)
            viewer.reload(nil)
            return
        }
        let viewer = ViewerController(url: url)
        // A viewer has nothing to do with no file open.
        viewer.onClose = { [weak self, weak viewer] in
            self?.viewers.removeAll { $0 === viewer }
            if self?.viewers.isEmpty == true { NSApp.terminate(nil) }
        }
        viewers.append(viewer)
        cascade = viewer.window.cascadeTopLeft(from: cascade)
        viewer.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        viewer.load()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = openableExtensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            panel.urls.forEach(open)
        } else if viewers.isEmpty {
            NSApp.terminate(nil)
        }
    }

    // The Open With submenu: every other app that takes this kind of file.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let url = viewers.first(where: { $0.window.isKeyWindow })?.url else { return }
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) where app != Bundle.main.bundleURL {
            let item = menu.addItem(withTitle: FileManager.default.displayName(atPath: app.path),
                                    action: #selector(openWith), keyEquivalent: "")
            item.target = self
            item.representedObject = [url, app]
        }
    }

    @objc private func openWith(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        NSWorkspace.shared.open([pair[0]], withApplicationAt: pair[1], configuration: NSWorkspace.OpenConfiguration())
    }

    private func mainMenu() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ held: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = held
            return item
        }
        func add(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
            return menu
        }
        let colorRows = item("Color Rows", nil)
        colorRows.submenu = colorMenu(#selector(ViewerController.colorRows), target: nil) { $0 }
        let openWith = item("Open With", nil)
        openWith.submenu = NSMenu(title: "Open With")
        openWith.submenu?.delegate = self

        _ = add(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        _ = add("File", [
            item("Open…", #selector(openDocument), "o"),
            .separator(),
            item("Export…", #selector(ViewerController.exportDocument), "s"),
            item("Reload", #selector(ViewerController.reload), "r"),
            openWith,
            item("Show in Finder", #selector(ViewerController.showInFinder), "r", [.command, .shift]),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        _ = add("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSResponder.selectAll(_:)), "a"),
            .separator(),
            item("Add Row", #selector(ViewerController.addRow), "\r"),
            item("Delete Rows", #selector(ViewerController.deleteRows), "\u{8}"),
            item("Add Page…", #selector(ViewerController.addPage(_:))),
            item("Delete Page", #selector(ViewerController.deletePage)),
            colorRows,
            .separator(),
            item("Find", #selector(ViewerController.focusSearch), "f"),
        ])
        _ = add("View", [
            item("First Row Is Header", #selector(ViewerController.toggleHeader), "h", [.command, .shift]),
        ])
        NSApp.windowsMenu = add("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        return main
    }
}

// MARK: - Checks

/// The reading, sorting, search and editing rules, run by `SheetViewer --selftest`.
func selfTest() -> Bool {
    var failures = 0
    func check(_ passed: Bool, _ what: String) {
        if !passed {
            failures += 1
            print("FAIL: \(what)")
        }
    }
    func body(_ sheet: Sheet, _ column: Int = 0) -> [String] { (sheet.bodyStart..<sheet.count).map { sheet.text($0, column) } }
    func showing(_ sheet: Sheet, _ column: Int = 0) -> [String] { sheet.rows.map { sheet.text($0, column) } }

    check(parseNumber("$1,299.90") == 1299.90, "money")
    check(parseNumber("-$5.00") == -5 && parseNumber("$-5.00") == -5 && parseNumber("(12)") == -12, "negatives")
    check(parseNumber("26%") == 26 && parseNumber(" 1,573 ") == 1573 && parseNumber(".5") == 0.5, "percent, thousands, bare decimal")
    check(["610-5330", "", "abc", "1.2.3", "$", "-", "12 oz"].allSatisfy { parseNumber($0) == nil }, "not numbers")
    check(parseSlashDate("10/5/2026") == 20261005 && parseSlashDate("1/2/26 4:05 PM") == 20260102, "slash dates")
    check(parseSlashDate("2026-10-05") == nil && parseSlashDate("13/1/2026") == nil, "not slash dates")
    check((0...27).map(columnLetters).suffix(3) == ["Z", "AA", "AB"] && columnLetters(0) == "A", "column letters")

    let quoted = "a,b\r\n\"x, y\",\"he said \"\"hi\"\"\"\n\"two\nlines\",\nlast,"
    let parsed = parseDelimited(Array(quoted.utf8), delimiter: 44)
    check(parsed == [["a", "b"], ["x, y", "he said \"hi\""], ["two\nlines", ""], ["last", ""]], "quoted CSV")
    check(parseDelimited(Array(delimitedText(parsed + [["cr\r\nlf", "plain"]]).utf8), delimiter: 44)
        == parsed + [["cr\r\nlf", "plain"]], "CSV written and read back")
    check(delimitedText([["a", "b c"], ["1", ""]]) == "a,b c\n1,\n", "plain CSV is left unquoted")
    check(sniffDelimiter(Array("a;b;c\n1;2;3\n".utf8)) == 59, "semicolons")
    check(sniffDelimiter(Array("a\tb, c\n1\t2\n".utf8)) == 9, "tabs")
    check(sniffDelimiter(Array("\"a;b;c\",d\n".utf8)) == 44, "separators inside quotes don't count")
    check(sniffDelimiter(Array("id,tags\n1,a;b;c\n2,d;e;f\n".utf8)) == 44, "semicolons inside a comma file's values")
    check(sniffDelimiter(Array("name,cats\nfoo,a|b|c".utf8)) == 44, "pipes inside a comma file's values")
    check(sniffDelimiter(Array("a;b\n1,5;2,5\n3,5;4,5\n".utf8)) == 59, "decimal commas inside a semicolon file")
    check(sniffDelimiter(Array("just one column\nno separators\n".utf8)) == 44, "nothing to go on means commas")
    check(opensWithoutAsking(URL(string: "HTTPS://example.com/a")!) && opensWithoutAsking(URL(string: "mailto:a@example.com")!), "web and mail links open")
    check(["file:///System/Applications/Calculator.app", "shortcuts://run-shortcut?name=x", "smb://host/share", "typecmd:ls"]
        .allSatisfy { !opensWithoutAsking(URL(string: $0)!) }, "anything else is asked about")
    check(squared([["a"], ["b", "c", ""], [""], []]) == [["a", ""], ["b", "c"]], "squared")
    check(decodeText(Data([0xEF, 0xBB, 0xBF, 0x61])) == [0x61], "UTF-8 mark dropped")
    check(String(decoding: decodeText(Data([0x63, 0x61, 0x66, 0xE9])), as: UTF8.self) == "café", "Windows text")

    let yellow = CellStyle(fill: "FFFF00", color: nil, bold: true, italic: false)
    let sheet = Sheet(name: "t", cells: [["Item", "Price"], ["b", "$10.00"], ["a", "$9.50"], ["c", ""], ["d", "$1,000.00"]],
                      links: [1: [0: "https://example.com/widget"]], styles: [yellow], styled: [2, 1, 0, 9, 9, 0, 1, 1, 7])
    check(sheet.hasHeader && sheet.titles == ["Item", "Price"] && sheet.kinds == [.text, .number], "header and kinds")
    check(sheet.style(2, 1) == yellow && sheet.style(1, 1) == nil && sheet.style(2, 0) == nil, "styles land on their cells; strays are dropped")
    check(sheet.rows == [1, 2, 3, 4], "file order")
    sheet.sortColumn = 1
    sheet.refresh(terms: [])
    check(sheet.rows == [2, 1, 4, 3], "figures ascending, blanks last")
    check(sheet.exportRows(onlyShowing: false) == [0, 2, 1, 4, 3], "export follows the sort, header first")
    sheet.ascending = false
    sheet.refresh(terms: [])
    check(sheet.rows == [4, 1, 2, 3], "figures descending, blanks still last")
    sheet.sortColumn = 0
    sheet.ascending = true
    sheet.refresh(terms: ["$"])
    check(sheet.rows == [2, 1, 4], "search then sort")
    check(sheet.exportRows(onlyShowing: true) == [0, 2, 1, 4] && sheet.exportRows(onlyShowing: false) == [0, 2, 1, 3, 4], "export all or only showing")
    check(sheet.matchCount(["widget"]) == 1 && sheet.matchCount(["a", "9.5"]) == 1 && sheet.matchCount(["zzz"]) == 0, "search terms")
    check(sheet.copyText(1, 0) == "https://example.com/widget" && sheet.copyText(2, 0) == "a", "copy text")
    check(sheet.address(1, 0) == "https://example.com/widget" && sheet.address(2, 0) == nil, "linked cell")
    let sites = Sheet(name: "u", cells: [["Site"], ["https://example.com/a?b=1"], ["see https://example.com"]])
    check(sites.address(1, 0) != nil && sites.address(2, 0) == nil, "a bare address is a link; one inside a sentence is not")

    // Editing. Showing now: a, b, d (rows 2, 1, 4), searched for "$" and sorted by item.
    check(sheet.set("zebra", row: 2, column: 0) == "a" && showing(sheet) == ["zebra", "b", "d"], "an edited row stays put")
    check(sheet.matchCount(["zebra"]) == 1, "search sees the edit")
    sheet.insert(sheet.blankRow(), at: 3, showingAt: 1)  // under "zebra", which is file row 2 and first on screen
    check(showing(sheet) == ["zebra", "", "b", "d"] && body(sheet) == ["b", "zebra", "", "c", "d"], "a new row lands where it was put, in the file and on screen")
    check(sheet.style(2, 1) == yellow && sheet.address(1, 0) != nil, "styles and links stay with their rows")
    let removed = sheet.remove([1, 3])  // "b" and the blank row
    check(body(sheet) == ["zebra", "c", "d"] && showing(sheet) == ["zebra", "d"], "rows removed from the file and the screen")
    check(sheet.style(1, 1) == yellow, "a style moves up with its row")
    sheet.restore(removed, terms: ["$"])
    check(body(sheet) == ["b", "zebra", "", "c", "d"] && showing(sheet) == ["zebra", "", "b", "d"], "undo puts rows and the screen back")
    let again = sheet.remove([1])
    sheet.refresh(terms: [])  // the view changed in between
    sheet.restore(again, terms: [])
    check(showing(sheet) == ["b", "c", "d", "zebra", ""], "after a new sort, undo re-sorts instead of trusting the old screen")
    let saved = sheet.styleMaps([1, 2])
    sheet.fill("C8E6C9", rows: [1, 2], columns: [0, 1])
    check(sheet.style(1, 0)?.fill == "C8E6C9" && sheet.style(1, 0)?.bold == false, "a plain cell takes a fill")
    check(sheet.style(2, 1) == CellStyle(fill: "C8E6C9", color: nil, bold: true, italic: false), "a styled cell keeps its bold under a new fill")
    sheet.fill(nil, rows: [1, 2], columns: [0, 1])
    check(sheet.style(1, 0) == nil && sheet.style(2, 1) == CellStyle(fill: nil, color: nil, bold: true, italic: false), "clearing a fill leaves the rest")
    sheet.setStyleMaps(saved)
    check(sheet.style(2, 1) == yellow && sheet.style(1, 0) == nil, "undo puts styles back")
    sheet.hasHeader = false
    check(sheet.titles == ["A", "B"] && sheet.bodyCount == 6, "header off")

    check(!Sheet(name: "s", cells: [["Stock for the spring sale", "", ""], ["x", "1", "2"]]).hasHeader, "a title line is not a header")
    check(!Sheet(name: "n", cells: [["1", "2"], ["3", "4"]]).hasHeader, "a row of figures is not a header")
    let words = Sheet(name: "w", cells: [["Name"], ["item 10"], ["Item 9"], ["apple"]])
    words.sortColumn = 0
    words.refresh(terms: [])
    check(words.rows == [3, 2, 1], "words sort like Finder")
    words.insert(words.blankRow(), at: words.count, showingAt: words.rows.count)
    check(words.rows == [3, 2, 1, 4], "a row added at the end shows at the end")
    words.insert(words.blankRow(), at: 4, showingAt: 1)
    check(words.exportRows(onlyShowing: false) == [0, 3, 4, 2, 1, 5], "a full export keeps added rows where they sit on screen")

    let bare = Sheet(name: "e", cells: [["1", "2"], ["3", "4"]])
    _ = bare.remove([0, 1])
    bare.hasHeader = true
    check(bare.bodyStart == 0 && bare.bodyCount == 0 && bare.titles == ["A", "B"] && bare.exportRows(onlyShowing: false).isEmpty,
          "a page with no rows left has no header row")

    print(failures == 0 ? "selftest ok" : "\(failures) failed")
    return failures == 0
}

/// Opens a file without showing it, runs commands, and draws the window to a PNG: `SheetViewer --snapshot file out.png [--do "commands"] [--light]`.
func snapshot(_ arguments: [String]) -> Bool {
    guard let index = arguments.firstIndex(of: "--snapshot"), index + 2 < arguments.count else { return false }
    NSApp.setActivationPolicy(.accessory)
    if arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
    let viewer = ViewerController(url: URL(fileURLWithPath: arguments[index + 1]))
    do {
        viewer.show(try readBook(viewer.url))
    } catch {
        print("could not read: \(error.localizedDescription)")
        return false
    }
    if let at = arguments.firstIndex(of: "--do"), at + 1 < arguments.count, !viewer.run(script: arguments[at + 1]) { return false }
    viewer.window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let view = viewer.window.contentView?.superview ?? viewer.window.contentView,
          let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
    view.cacheDisplay(in: view.bounds, to: image)
    guard let png = image.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: arguments[index + 2]))) != nil
}

signal(SIGPIPE, SIG_IGN)  // a script that quits early must not take the app with it
let app = NSApplication.shared
if CommandLine.arguments.contains("--selftest") { exit(selfTest() ? 0 : 1) }
if CommandLine.arguments.contains("--snapshot") { exit(snapshot(CommandLine.arguments) ? 0 : 1) }
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
