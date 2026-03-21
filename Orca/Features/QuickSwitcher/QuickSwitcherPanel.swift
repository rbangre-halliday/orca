import Cocoa

// MARK: - Design

private enum QSStyle {
    static let width: CGFloat = 480
    static let maxHeight: CGFloat = 340
    static let inputHeight: CGFloat = 44
    static let rowHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 10

    static let bgColor = NSColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.98)
    static let borderColor = NSColor(white: 1.0, alpha: 0.10)
    static let selectedRowColor = NSColor(red: 0.55, green: 0.47, blue: 1.0, alpha: 0.18)
    static let accentColor = NSColor(red: 0.55, green: 0.47, blue: 1.0, alpha: 1.0)
    static let textColor = NSColor(white: 0.90, alpha: 1.0)
    static let dimColor = NSColor(white: 0.40, alpha: 1.0)
    static let matchColor = NSColor(red: 0.70, green: 0.62, blue: 1.0, alpha: 1.0)
    static let inputFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
    static let resultFont = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    static let breadcrumbFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
}

// MARK: - Item + Fuzzy Match

struct QuickSwitcherItem {
    let id: UUID
    let label: String
    let breadcrumb: String
    let isFolder: Bool
}

private struct FuzzyMatch {
    let item: QuickSwitcherItem
    let score: Int
    let matchedIndices: [Int]
}

private func fuzzyMatch(query: String, target: String) -> (score: Int, indices: [Int])? {
    guard !query.isEmpty else { return (0, []) }
    let qChars = Array(query.lowercased())
    let tChars = Array(target.lowercased())
    var indices: [Int] = []
    var qi = 0
    for (ti, tc) in tChars.enumerated() {
        if qi < qChars.count && tc == qChars[qi] { indices.append(ti); qi += 1 }
    }
    guard qi == qChars.count else { return nil }
    var score = 100
    for i in 1..<indices.count { if indices[i] == indices[i-1] + 1 { score += 10 } }
    if indices.first == 0 { score += 20 }
    score -= target.count
    return (score, indices)
}

// MARK: - Quick Switcher (overlay view, not a window)

class QuickSwitcherOverlay: NSView {
    private let container = NSView()
    private let inputField = QSInputField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matches")

    private var allItems: [QuickSwitcherItem] = []
    private var results: [FuzzyMatch] = []
    private var eventMonitor: Any?

    var onSelect: ((UUID) -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor // dim background

        // Container — the actual switcher box
        container.wantsLayer = true
        container.layer?.backgroundColor = QSStyle.bgColor.cgColor
        container.layer?.cornerRadius = QSStyle.cornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = QSStyle.borderColor.cgColor
        container.layer?.shadowColor = NSColor.black.withAlphaComponent(0.5).cgColor
        container.layer?.shadowOffset = CGSize(width: 0, height: -4)
        container.layer?.shadowRadius = 20
        container.layer?.shadowOpacity = 1
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        // Input
        inputField.placeholderAttributedString = NSAttributedString(
            string: "Switch to...",
            attributes: [.foregroundColor: QSStyle.dimColor, .font: QSStyle.inputFont]
        )
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.font = QSStyle.inputFont
        inputField.textColor = QSStyle.textColor
        inputField.delegate = self
        inputField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inputField)

        // Separator
        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = QSStyle.borderColor.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sep)

        // Table
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = QSStyle.rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.gridStyleMask = []
        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("r")))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClick(_:))
        tableView.action = #selector(tableSingleClick(_:))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Empty label
        emptyLabel.font = .systemFont(ofSize: 13, weight: .regular)
        emptyLabel.textColor = QSStyle.dimColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.topAnchor.constraint(equalTo: topAnchor, constant: 80),
            container.widthAnchor.constraint(equalToConstant: QSStyle.width),
            container.heightAnchor.constraint(equalToConstant: QSStyle.maxHeight),

            inputField.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            inputField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            inputField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            inputField.heightAnchor.constraint(equalToConstant: QSStyle.inputHeight - 10),

            sep.topAnchor.constraint(equalTo: inputField.bottomAnchor, constant: 6),
            sep.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            sep.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            sep.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 24),
        ])
    }

    // MARK: - Show / Dismiss

    func show(items: [QuickSwitcherItem]) {
        allItems = items
        results = items.filter { !$0.isFolder }.map { FuzzyMatch(item: $0, score: 0, matchedIndices: []) }
        inputField.stringValue = ""
        isHidden = false
        tableView.reloadData()
        if !results.isEmpty { selectRow(0) }
        emptyLabel.isHidden = !results.isEmpty
        window?.makeFirstResponder(inputField)
        installEventMonitor()
    }

    func dismiss() {
        removeEventMonitor()
        isHidden = true
        onDismiss?()
    }

    private func installEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isHidden, self.superview != nil else { return event }
            switch event.keyCode {
            case 0x7E: self.moveSelection(-1); return nil       // Up
            case 0x7D: self.moveSelection(1); return nil        // Down
            case 0x24, 0x4C: self.confirmSelection(); return nil // Return
            case 0x35: self.dismiss(); return nil                // Escape
            default: return event
            }
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Click outside to dismiss, pass through clicks inside

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !container.frame.contains(point) {
            dismiss()
        } else {
            super.mouseDown(with: event)
        }
    }

    @objc private func tableSingleClick(_ sender: Any?) {
        // Single click selects and confirms immediately (like Telescope)
        confirmSelection()
    }

    @objc private func tableDoubleClick(_ sender: Any?) {
        confirmSelection()
    }

    // MARK: - Filtering

    fileprivate func filterResults(_ query: String) {
        if query.isEmpty {
            results = allItems.filter { !$0.isFolder }.map { FuzzyMatch(item: $0, score: 0, matchedIndices: []) }
        } else {
            results = allItems.compactMap { item -> FuzzyMatch? in
                guard !item.isFolder else { return nil }
                if let m = fuzzyMatch(query: query, target: item.label) {
                    return FuzzyMatch(item: item, score: m.score, matchedIndices: m.indices)
                }
                if fuzzyMatch(query: query, target: item.breadcrumb + " " + item.label) != nil {
                    return FuzzyMatch(item: item, score: -10, matchedIndices: [])
                }
                return nil
            }.sorted { $0.score > $1.score }
        }
        emptyLabel.isHidden = !results.isEmpty
        tableView.reloadData()
        if !results.isEmpty { selectRow(0) }
    }

    fileprivate func selectRow(_ row: Int) {
        guard row >= 0, row < results.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    fileprivate func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let cur = tableView.selectedRow
        let next = (cur + delta + results.count) % results.count
        selectRow(next)
    }

    fileprivate func confirmSelection() {
        var row = tableView.selectedRow
        // Fallback: if nothing selected but results exist, use first result
        if row < 0 && !results.isEmpty { row = 0 }
        guard row >= 0, row < results.count else { return }
        let id = results[row].item.id
        dismiss()
        onSelect?(id)
    }
}

// MARK: - NSTextFieldDelegate

extension QuickSwitcherOverlay: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        filterResults(field.stringValue)
    }
}

// MARK: - NSTableViewDataSource + Delegate

extension QuickSwitcherOverlay: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { QSStyle.rowHeight }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { QSRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let match = results[row]
        let item = match.item

        let cellID = NSUserInterfaceItemIdentifier("QSCell")
        let cell: NSView

        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) {
            cell = existing
        } else {
            let c = NSView()
            c.identifier = cellID

            let icon = NSImageView()
            icon.tag = 1
            icon.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(icon)

            let label = NSTextField(labelWithString: "")
            label.tag = 2
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            c.addSubview(label)

            let crumb = NSTextField(labelWithString: "")
            crumb.tag = 3
            crumb.translatesAutoresizingMaskIntoConstraints = false
            crumb.lineBreakMode = .byTruncatingTail
            c.addSubview(crumb)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 14),
                icon.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
                label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                crumb.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
                crumb.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -14),
                crumb.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])

            cell = c
        }

        // Icon
        let symCfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let icon = cell.viewWithTag(1) as? NSImageView {
            icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(symCfg)
            icon.contentTintColor = QSStyle.accentColor
        }

        // Label with highlights
        if let label = cell.viewWithTag(2) as? NSTextField {
            let attr = NSMutableAttributedString(
                string: item.label,
                attributes: [.font: QSStyle.resultFont, .foregroundColor: QSStyle.textColor]
            )
            for idx in match.matchedIndices where idx < attr.length {
                attr.addAttributes([.foregroundColor: QSStyle.matchColor, .font: NSFont.systemFont(ofSize: 13.5, weight: .bold)], range: NSRange(location: idx, length: 1))
            }
            label.attributedStringValue = attr
        }

        // Breadcrumb
        if let crumb = cell.viewWithTag(3) as? NSTextField {
            crumb.stringValue = item.breadcrumb
            crumb.font = QSStyle.breadcrumbFont
            crumb.textColor = QSStyle.dimColor
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Visual only — confirmation requires Enter
    }
}

// MARK: - Input Field

private class QSInputField: NSTextField {}

// MARK: - Row View

private class QSRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 6, dy: 1)
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill(using: QSStyle.selectedRowColor)
    }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .dark }
}

private extension NSBezierPath {
    func fill(using color: NSColor) {
        color.setFill()
        fill()
    }
}
