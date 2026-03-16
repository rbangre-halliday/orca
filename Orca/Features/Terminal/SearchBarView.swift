import Cocoa

/// Floating search bar overlaying the terminal. Dark, minimal, top-right positioned.
class SearchBarView: NSView {
    let searchField: NSTextField
    private let countLabel: NSTextField
    private let closeButton: NSButton

    var onSearch: ((String) -> Void)?
    var onClose: (() -> Void)?

    private var debounceTimer: Timer?

    override init(frame: NSRect) {
        searchField = NSTextField()
        countLabel = NSTextField(labelWithString: "")
        closeButton = NSButton()
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 0.95).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.08).cgColor

        // Shadow
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 8
        layer?.shadowOpacity = 1

        // Search field
        searchField.placeholderString = "Search..."
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        searchField.textColor = NSColor(white: 0.9, alpha: 1.0)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        // Count label (e.g. "3 of 12")
        countLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        // Close button
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = NSColor(white: 0.5, alpha: 1.0)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -6),

            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),

            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func setText(_ text: String) {
        searchField.stringValue = text
    }

    func updateCounts(total: Int?, selected: Int?) {
        if let total, let selected, total > 0 {
            countLabel.stringValue = "\(selected) of \(total)"
        } else if let total, total == 0 {
            countLabel.stringValue = "no matches"
            countLabel.textColor = NSColor(red: 0.9, green: 0.4, blue: 0.4, alpha: 1.0)
        } else {
            countLabel.stringValue = ""
        }
        if total ?? 0 > 0 {
            countLabel.textColor = NSColor(white: 0.5, alpha: 1.0)
        }
    }

    @objc private func closeTapped() {
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}

extension SearchBarView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue
        // Debounce: short queries wait, longer ones fire immediately
        debounceTimer?.invalidate()
        let delay = query.count < 3 ? 0.3 : 0.05
        debounceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.onSearch?(query)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(cancelOperation(_:)) {
            onClose?()
            return true
        }
        if commandSelector == #selector(insertNewline(_:)) {
            // Enter — could navigate to next match, for now just search
            onSearch?(searchField.stringValue)
            return true
        }
        return false
    }
}
