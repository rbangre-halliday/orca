import Cocoa

// MARK: - Design Constants

private enum SidebarStyle {
    static let bgColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
    static let rowHeight: CGFloat = 32
    static let accentColor = NSColor(red: 0.55, green: 0.47, blue: 1.0, alpha: 1.0)
    static let selectedColor = NSColor(white: 1.0, alpha: 0.10)
    static let focusedSelectedColor = NSColor(red: 0.55, green: 0.47, blue: 1.0, alpha: 0.18)
    static let textColor = NSColor(white: 0.75, alpha: 1.0)
    static let textDim = NSColor(white: 0.42, alpha: 1.0)
    static let textActive = NSColor(white: 0.97, alpha: 1.0)
    static let folderTextColor = NSColor(white: 0.62, alpha: 1.0)
    static let indentGuideColor = NSColor(white: 1.0, alpha: 0.06)
    static let fontSize: CGFloat = 14
    static let terminalFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
    static let folderFont = NSFont.systemFont(ofSize: fontSize, weight: .medium)
    static let accentBarWidth: CGFloat = 2.5
    static let indentPerLevel: CGFloat = 18
    static let iconSize: CGFloat = 16
}

// MARK: - Pasteboard type

extension NSPasteboard.PasteboardType {
    static let workspaceNode = NSPasteboard.PasteboardType("dev.orca.workspace-node")
}

// MARK: - Node wrapper

class NodeItem: NSObject {
    let id: UUID
    var node: WorkspaceNode
    var childItems: [NodeItem]
    var depth: Int = 0

    init(_ node: WorkspaceNode, depth: Int = 0) {
        self.id = node.id
        self.node = node
        self.depth = depth
        if case .folder(let d) = node {
            self.childItems = d.children.map { NodeItem($0, depth: depth + 1) }
        } else {
            self.childItems = []
        }
    }

    override var hash: Int { id.hashValue }
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NodeItem else { return false }
        return id == other.id
    }
}

// MARK: - Callbacks

struct SidebarCallbacks {
    var onSelect: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onAddTerminal: ((UUID?) -> Void)?
    var onAddFolder: ((UUID?) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onMove: ((UUID, UUID?, Int) -> Void)?
    var onReturnFocus: (() -> Void)?
}

// MARK: - Custom Row View

class SidebarRowView: NSTableRowView {
    var isActiveTerminal = false
    var nodeDepth: Int = 0

    override func drawSelection(in dirtyRect: NSRect) {
        let selRect = bounds.insetBy(dx: 5, dy: 1)
        let path = NSBezierPath(roundedRect: selRect, xRadius: 5, yRadius: 5)

        // Brighter selection when the outline view is first responder (focused)
        let isFocused = (window?.firstResponder as? NSView)?.isDescendant(of: superview ?? self) ?? false
        let color = isFocused ? SidebarStyle.focusedSelectedColor : SidebarStyle.selectedColor
        color.setFill()
        path.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Active terminal: accent bar on left
        if isActiveTerminal {
            let barRect = NSRect(x: 3, y: bounds.midY - 7, width: SidebarStyle.accentBarWidth, height: 14)
            let barPath = NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25)
            SidebarStyle.accentColor.setFill()
            barPath.fill()
        }

        // Indent guides: draw vertical lines for each depth level
        if nodeDepth > 0 {
            SidebarStyle.indentGuideColor.setStroke()
            for level in 1...nodeDepth {
                let x = CGFloat(level) * SidebarStyle.indentPerLevel + 8
                let line = NSBezierPath()
                line.move(to: NSPoint(x: x, y: 0))
                line.line(to: NSPoint(x: x, y: bounds.height))
                line.lineWidth = 1
                line.stroke()
            }
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .dark }
}

// MARK: - Custom NSOutlineView

class SidebarOutlineView: NSOutlineView {
    var callbacks = SidebarCallbacks()

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 0x24, 0x4C: // Return / numpad Enter
            let row = selectedRow
            guard row >= 0, let item = self.item(atRow: row) as? NodeItem else { return }
            if item.node.isFolder {
                if isItemExpanded(item) { collapseItem(item) }
                else { expandItem(item) }
            } else {
                // Activate terminal and return focus to it
                callbacks.onSelect?(item.id)
                callbacks.onReturnFocus?()
            }

        case 0x26: // j — move down (vim)
            let next = min(selectedRow + 1, numberOfRows - 1)
            if next >= 0 { selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false); scrollRowToVisible(next) }

        case 0x28: // k — move up (vim)
            let prev = max(selectedRow - 1, 0)
            selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false); scrollRowToVisible(prev)

        case 0x25: // l — expand folder (vim right)
            let row = selectedRow
            if row >= 0, let item = self.item(atRow: row) as? NodeItem, item.node.isFolder {
                expandItem(item)
            }

        case 0x22: // h — collapse folder or go to parent (vim left)
            let row = selectedRow
            if row >= 0, let item = self.item(atRow: row) as? NodeItem {
                if item.node.isFolder && isItemExpanded(item) {
                    collapseItem(item)
                } else if let parent = self.parent(forItem: item) {
                    let parentRow = self.row(forItem: parent)
                    if parentRow >= 0 { selectRowIndexes(IndexSet(integer: parentRow), byExtendingSelection: false); scrollRowToVisible(parentRow) }
                }
            }

        case 0x0F: // r — rename selected item
            let row = selectedRow
            guard row >= 0 else { return }
            editColumn(0, row: row, with: nil, select: true)

        case 0x33, 0x75: // Backspace or Forward Delete — delete selected item
            let row = selectedRow
            guard row >= 0, let item = self.item(atRow: row) as? NodeItem else { return }
            callbacks.onDelete?(item.id)

        case 0x35: // Escape — return focus to terminal
            callbacks.onReturnFocus?()

        case 0x30: // Tab — return focus to terminal
            callbacks.onReturnFocus?()

        default:
            super.keyDown(with: event)
        }
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        SidebarStyle.bgColor.setFill()
        clipRect.fill()
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        frame.origin.x += 2
        return frame
    }
}

// MARK: - Sidebar Controller

class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let store: WorkspaceStore
    var callbacks = SidebarCallbacks()
    let scrollView: NSScrollView
    let outlineView: SidebarOutlineView

    private var rootItems: [NodeItem] = []
    private var itemCache: [UUID: NodeItem] = [:]

    init(store: WorkspaceStore) {
        self.store = store

        outlineView = SidebarOutlineView()
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = SidebarStyle.rowHeight
        outlineView.indentationPerLevel = SidebarStyle.indentPerLevel
        outlineView.autoresizesOutlineColumn = true
        outlineView.allowsMultipleSelection = false
        outlineView.backgroundColor = SidebarStyle.bgColor
        outlineView.selectionHighlightStyle = .sourceList
        outlineView.intercellSpacing = NSSize(width: 0, height: 1)

        outlineView.registerForDraggedTypes([.workspaceNode])
        outlineView.draggingDestinationFeedbackStyle = .sourceList
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.isEditable = true
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = SidebarStyle.bgColor
        scrollView.scrollerStyle = .overlay
        scrollView.contentView.drawsBackground = true
        (scrollView.contentView as? NSClipView)?.backgroundColor = SidebarStyle.bgColor

        super.init()

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClickRow(_:))

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
    }

    /// Focus the sidebar so keyboard nav works.
    func focus() {
        outlineView.window?.makeFirstResponder(outlineView)
        // If nothing selected, select first row
        if outlineView.selectedRow < 0 && outlineView.numberOfRows > 0 {
            outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Reload

    private var reloadScheduled = false

    func reload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            let selectedID = self.selectedNodeID()
            self.rebuildCache()
            self.outlineView.reloadData()
            self.restoreExpandedState(self.rootItems)
            if let id = selectedID {
                self.selectNode(id: id)
            }
        }
    }

    private func rebuildCache() {
        var newCache: [UUID: NodeItem] = [:]
        func build(_ nodes: [WorkspaceNode], depth: Int) -> [NodeItem] {
            return nodes.map { node in
                let item: NodeItem
                if let existing = itemCache[node.id] {
                    existing.node = node
                    existing.depth = depth
                    existing.childItems = node.isFolder ? build(node.children, depth: depth + 1) : []
                    item = existing
                } else {
                    item = NodeItem(node, depth: depth)
                    if node.isFolder { item.childItems = build(node.children, depth: depth + 1) }
                }
                newCache[item.id] = item
                return item
            }
        }
        rootItems = build(store.tree.roots, depth: 0)
        itemCache = newCache
    }

    func selectNode(id: UUID) {
        let row = findRow(for: id)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    private func selectedNodeID() -> UUID? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return (outlineView.item(atRow: row) as? NodeItem)?.id
    }

    func contextFolderID() -> UUID? {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? NodeItem else { return nil }
        if item.node.isFolder { return item.id }
        return store.tree.parentID(of: item.id)
    }

    private func findRow(for id: UUID) -> Int {
        for row in 0..<outlineView.numberOfRows {
            if let item = outlineView.item(atRow: row) as? NodeItem, item.id == id { return row }
        }
        return -1
    }

    private func restoreExpandedState(_ items: [NodeItem]) {
        for item in items {
            if item.node.isFolder && item.node.isExpanded {
                outlineView.expandItem(item)
                restoreExpandedState(item.childItems)
            }
        }
    }

    /// Ensure the parent folder of a node is expanded (e.g. after creating a child).
    func ensureVisible(id: UUID) {
        if let parentID = store.tree.parentID(of: id),
           let parentItem = itemCache[parentID] {
            outlineView.expandItem(parentItem)
            store.setExpanded(id: parentID, expanded: true)
        }
    }

    @objc private func doubleClickRow(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        outlineView.editColumn(0, row: row, with: nil, select: true)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return rootItems.count }
        return (item as? NodeItem)?.childItems.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootItems[index] }
        return (item as! NodeItem).childItems[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? NodeItem)?.node.isFolder ?? false
    }

    // MARK: - Drag

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let nodeItem = item as? NodeItem else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(nodeItem.id.uuidString, forType: .workspaceNode)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let pb = info.draggingPasteboard.pasteboardItems?.first,
              let idStr = pb.string(forType: .workspaceNode),
              let draggedID = UUID(uuidString: idStr) else { return [] }
        if let target = item as? NodeItem {
            if target.id == draggedID { return [] }
            if store.tree.isAncestor(draggedID, of: target.id) { return [] }
            if !target.node.isFolder { return [] }
        }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let pb = info.draggingPasteboard.pasteboardItems?.first,
              let idStr = pb.string(forType: .workspaceNode),
              let draggedID = UUID(uuidString: idStr) else { return false }
        callbacks.onMove?(draggedID, (item as? NodeItem)?.id, max(index, 0))
        return true
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        SidebarStyle.rowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let rowView = SidebarRowView()
        if let nodeItem = item as? NodeItem {
            rowView.isActiveTerminal = (!nodeItem.node.isFolder && nodeItem.id == store.tree.activeTerminalID)
            rowView.nodeDepth = nodeItem.depth
        }
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let nodeItem = item as? NodeItem else { return nil }
        let node = nodeItem.node
        let isActive = (!node.isFolder && node.id == store.tree.activeTerminalID)

        let cellID = NSUserInterfaceItemIdentifier(node.isFolder ? "FolderCell" : "TerminalCell")
        let cell: NSTableCellView

        if let existing = outlineView.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView {
            cell = existing
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            cell.addSubview(icon)
            cell.imageView = icon

            let text = EditableTextField()
            text.translatesAutoresizingMaskIntoConstraints = false
            text.isBordered = false
            text.drawsBackground = false
            text.isEditable = true
            text.focusRingType = .none
            text.lineBreakMode = .byTruncatingTail
            text.cell?.truncatesLastVisibleLine = true
            cell.addSubview(text)
            cell.textField = text

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: SidebarStyle.iconSize),
                icon.heightAnchor.constraint(equalToConstant: SidebarStyle.iconSize),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        let symConfig = NSImage.SymbolConfiguration(pointSize: SidebarStyle.fontSize, weight: .medium)

        if node.isFolder {
            cell.imageView?.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(symConfig)
            cell.imageView?.contentTintColor = SidebarStyle.folderTextColor
            cell.textField?.stringValue = node.label
            cell.textField?.font = SidebarStyle.folderFont
            cell.textField?.textColor = SidebarStyle.folderTextColor
        } else {
            let symbolName = isActive ? "terminal.fill" : "terminal"
            cell.imageView?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(symConfig)
            cell.imageView?.contentTintColor = isActive ? SidebarStyle.accentColor : SidebarStyle.textDim
            cell.textField?.stringValue = node.label
            cell.textField?.font = SidebarStyle.terminalFont
            cell.textField?.textColor = isActive ? SidebarStyle.textActive : SidebarStyle.textColor
        }

        if let tf = cell.textField as? EditableTextField {
            tf.nodeID = node.id
            tf.onCommit = { [weak self] id, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { self?.callbacks.onRename?(id, trimmed) }
            }
        }

        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? NodeItem else { return }
        if !item.node.isFolder {
            callbacks.onSelect?(item.id)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? NodeItem else { return }
        store.setExpanded(id: item.id, expanded: true)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? NodeItem else { return }
        store.setExpanded(id: item.id, expanded: false)
    }
}

// MARK: - Context Menu

extension SidebarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clickedRow = outlineView.clickedRow
        if clickedRow >= 0, let item = outlineView.item(atRow: clickedRow) as? NodeItem {
            if item.node.isFolder {
                menu.addItem(withTitle: "Add Terminal", action: #selector(contextAddTerminal(_:)), keyEquivalent: "")
                menu.addItem(withTitle: "Add Subfolder", action: #selector(contextAddSubfolder(_:)), keyEquivalent: "")
                menu.addItem(.separator())
            }
            menu.addItem(withTitle: "Rename", action: #selector(contextRename(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            let deleteItem = NSMenuItem(title: "Delete", action: #selector(contextDelete(_:)), keyEquivalent: "")
            deleteItem.attributedTitle = NSAttributedString(string: "Delete", attributes: [.foregroundColor: NSColor.systemRed])
            menu.addItem(deleteItem)
        } else {
            menu.addItem(withTitle: "New Terminal", action: #selector(contextNewTerminalRoot(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "New Folder", action: #selector(contextNewFolderRoot(_:)), keyEquivalent: "")
        }
        for item in menu.items { item.target = self }
    }

    @objc private func contextAddTerminal(_ sender: Any?) {
        guard outlineView.clickedRow >= 0, let item = outlineView.item(atRow: outlineView.clickedRow) as? NodeItem else { return }
        callbacks.onAddTerminal?(item.id)
    }
    @objc private func contextAddSubfolder(_ sender: Any?) {
        guard outlineView.clickedRow >= 0, let item = outlineView.item(atRow: outlineView.clickedRow) as? NodeItem else { return }
        callbacks.onAddFolder?(item.id)
    }
    @objc private func contextRename(_ sender: Any?) {
        guard outlineView.clickedRow >= 0 else { return }
        outlineView.editColumn(0, row: outlineView.clickedRow, with: nil, select: true)
    }
    @objc private func contextDelete(_ sender: Any?) {
        guard outlineView.clickedRow >= 0, let item = outlineView.item(atRow: outlineView.clickedRow) as? NodeItem else { return }
        callbacks.onDelete?(item.id)
    }
    @objc private func contextNewTerminalRoot(_ sender: Any?) { callbacks.onAddTerminal?(nil) }
    @objc private func contextNewFolderRoot(_ sender: Any?) { callbacks.onAddFolder?(nil) }
}

// MARK: - Editable Text Field

class EditableTextField: NSTextField {
    var nodeID: UUID?
    var onCommit: ((UUID, String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        self.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }
}

extension EditableTextField: NSTextFieldDelegate {
    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        if let id = nodeID { onCommit?(id, fieldEditor.string) }
        return true
    }
}
