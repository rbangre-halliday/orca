import Cocoa
import GhosttyKit

/// Manages TerminalView lifecycles with split pane support, backed by WorkspaceStore.
class TerminalManager {
    private let ghosttyApp: GhosttyApp
    private weak var window: NSWindow?
    private weak var terminalContainer: NSView?
    let store: WorkspaceStore

    /// Maps sidebar entry UUID -> SplitContainer (which may contain multiple split terminals).
    private var splitContainers: [UUID: SplitContainer] = [:]
    private var activeID: UUID?

    /// Terminals waiting for user input (Claude finished working).
    private(set) var waitingForInput: Set<UUID> = []
    /// Track which terminals were busy (title started with *) to detect transitions.
    private var wasBusy: Set<UUID> = []

    var onChange: (() -> Void)?

    /// The focused TerminalView within the active split container.
    var activeTerminal: TerminalView? {
        guard let id = activeID else { return nil }
        return splitContainers[id]?.focusedTerminal
    }

    var activeLabel: String? {
        guard let id = activeID else { return nil }
        return store.tree.find(id: id)?.label
    }

    var terminalCount: Int { splitContainers.count }

    init(ghosttyApp: GhosttyApp, window: NSWindow, terminalContainer: NSView, store: WorkspaceStore) {
        self.ghosttyApp = ghosttyApp
        self.window = window
        self.terminalContainer = terminalContainer
        self.store = store
    }

    // MARK: - Restore

    func restoreFromStore() {
        let terminalIDs = store.tree.allTerminalIDsInOrder
        if terminalIDs.isEmpty {
            let cwd = Self.initialDirectory()
            FileManager.default.changeCurrentDirectoryPath(cwd)
            let folderName = (cwd as NSString).lastPathComponent
            let folderID = store.addFolder(label: folderName)
            createTerminal(inFolder: folderID)
            return
        }

        for tid in terminalIDs {
            createLiveTerminal(for: tid)
        }

        let targetID = store.tree.activeTerminalID ?? terminalIDs.first!
        switchTo(id: targetID)
    }

    // MARK: - Create

    @discardableResult
    func createTerminal(inFolder folderID: UUID? = nil, label: String? = nil) -> UUID {
        let name = label ?? store.nextTerminalLabel()
        let id = store.addTerminal(label: name, inFolder: folderID)
        createLiveTerminal(for: id)
        switchTo(id: id)
        return id
    }

    private func createLiveTerminal(for id: UUID) {
        guard let terminalContainer else { return }
        let frame = terminalContainer.bounds
        let view = makeTerminalView(frame: frame)

        view.onClose = { [weak self] in
            self?.handleTerminalClose(sidebarID: id, terminal: view)
        }

        let container = SplitContainer(terminal: view)
        splitContainers[id] = container
    }

    /// Create a TerminalView with standard callbacks. Inherits cwd from active terminal.
    private func makeTerminalView(frame: NSRect) -> TerminalView {
        let cwd = activeTerminal?.detectWorkingDirectory()
        let view = TerminalView(ghosttyApp: ghosttyApp, frame: frame, workingDirectory: cwd)
        view.autoresizingMask = [.width, .height]

        view.onTitleChange = { [weak self, weak view] title in
            guard let self, let view else { return }
            // Extract working directory from the raw title
            view.currentWorkingDirectory = Self.extractDirectory(from: title)
            // Find which sidebar entry this terminal belongs to
            guard let entryID = self.sidebarID(for: view) else { return }

            // Detect busy → idle transitions via the * prefix.
            // Any process that sets "* title" when working and drops the *
            // when done (e.g. Claude Code) triggers the waiting indicator.
            let isBusy = title.hasPrefix("* ")

            if isBusy {
                self.wasBusy.insert(entryID)
                self.waitingForInput.remove(entryID)
            } else if self.wasBusy.contains(entryID) {
                // Transitioned from busy → idle: waiting for input
                self.wasBusy.remove(entryID)
                if entryID != self.activeID {
                    self.waitingForInput.insert(entryID)
                }
            }

            guard !self.store.tree.isManuallyRenamed(id: entryID) else {
                self.onChange?()
                return
            }
            let label = Self.cleanTitle(title)
            if !label.isEmpty {
                self.store.rename(id: entryID, to: label)
            }
            self.onChange?()
        }

        view.onFocus = { [weak self, weak view] in
            guard let self, let view else { return }
            if let entryID = self.sidebarID(for: view),
               let container = self.splitContainers[entryID] {
                // Unfocus all other terminals in this container
                for other in container.allTerminals() where other !== view {
                    if let surface = other.surface {
                        ghostty_surface_set_focus(surface, false)
                    }
                }
                container.focusedTerminal = view
            }
        }

        return view
    }

    /// Find which sidebar entry UUID a TerminalView belongs to.
    private func sidebarID(for terminal: TerminalView) -> UUID? {
        for (id, container) in splitContainers {
            if container.allTerminals().contains(where: { $0 === terminal }) {
                return id
            }
        }
        return nil
    }

    // MARK: - Split

    func splitTerminal(_ terminal: TerminalView, direction: ghostty_action_split_direction_e) {
        guard let entryID = sidebarID(for: terminal),
              let container = splitContainers[entryID] else { return }

        let dir: SplitContainer.Direction = (direction == GHOSTTY_SPLIT_DIRECTION_RIGHT || direction == GHOSTTY_SPLIT_DIRECTION_LEFT) ? .horizontal : .vertical

        guard let newView = container.split(terminal: terminal, direction: dir, ghosttyApp: ghosttyApp) else { return }

        // Wire callbacks for the new terminal
        newView.onClose = { [weak self, weak newView] in
            guard let self, let newView else { return }
            self.handleSplitClose(sidebarID: entryID, terminal: newView)
        }

        newView.onTitleChange = { [weak self] title in
            guard let self else { return }
            guard !self.store.tree.isManuallyRenamed(id: entryID) else { return }
            let label = Self.cleanTitle(title)
            if !label.isEmpty {
                self.store.rename(id: entryID, to: label)
                self.onChange?()
            }
        }

        newView.onFocus = { [weak self, weak newView] in
            guard let self, let newView else { return }
            // Unfocus all other terminals in this container
            for other in container.allTerminals() where other !== newView {
                if let surface = other.surface {
                    ghostty_surface_set_focus(surface, false)
                }
            }
            container.focusedTerminal = newView
        }

        // Explicitly unfocus all other panes now
        for other in container.allTerminals() where other !== newView {
            if let surface = other.surface {
                ghostty_surface_set_focus(surface, false)
            }
        }

        window?.makeFirstResponder(newView)
    }

    func gotoSplit(from terminal: TerminalView, direction: ghostty_action_goto_split_e) {
        guard let entryID = sidebarID(for: terminal),
              let container = splitContainers[entryID] else { return }

        if let target = container.navigate(from: terminal, direction: direction) {
            // Unfocus all, then focus the target
            for other in container.allTerminals() where other !== target {
                if let surface = other.surface {
                    ghostty_surface_set_focus(surface, false)
                }
            }
            container.focusedTerminal = target
            window?.makeFirstResponder(target)
        }
    }

    // MARK: - Close

    /// Handle close of a terminal that's the sole terminal in a sidebar entry.
    private func handleTerminalClose(sidebarID: UUID, terminal: TerminalView) {
        // If this entry has splits, close just this pane
        if let container = splitContainers[sidebarID], container.allTerminals().count > 1 {
            handleSplitClose(sidebarID: sidebarID, terminal: terminal)
            return
        }
        closeTerminal(id: sidebarID)
    }

    /// Handle close of one pane within a split.
    private func handleSplitClose(sidebarID: UUID, terminal: TerminalView) {
        guard let container = splitContainers[sidebarID] else { return }

        let wasFocused = container.focusedTerminal === terminal
        let isEmpty = container.remove(terminal: terminal)

        if isEmpty {
            closeTerminal(id: sidebarID)
            return
        }

        if wasFocused {
            // Focus the first remaining terminal
            if let first = container.allTerminals().first {
                container.focusedTerminal = first
                window?.makeFirstResponder(first)
            }
        }
    }

    func closeCurrent() {
        guard let id = activeID else { return }
        if let container = splitContainers[id],
           let focused = container.focusedTerminal,
           container.allTerminals().count > 1 {
            // Close just the focused split pane
            handleSplitClose(sidebarID: id, terminal: focused)
        } else {
            closeTerminal(id: id)
        }
    }

    func closeTerminal(id: UUID) {
        let liveIDs = Array(splitContainers.keys.filter { store.tree.find(id: $0) != nil })
        let orderedIDs = store.tree.allTerminalIDsInOrder.filter { liveIDs.contains($0) }
        let isActive = id == activeID

        var nextID: UUID?
        if isActive, orderedIDs.count > 1, let idx = orderedIDs.firstIndex(of: id) {
            nextID = idx + 1 < orderedIDs.count ? orderedIDs[idx + 1] : orderedIDs[idx - 1]
        } else if !isActive {
            nextID = activeID
        }

        if let container = splitContainers.removeValue(forKey: id) {
            container.rootView.removeFromSuperview()
        }
        store.removeNode(id: id)

        if splitContainers.isEmpty {
            activeID = nil
            onChange?()
            return
        }

        if let next = nextID {
            switchTo(id: next)
        } else {
            onChange?()
        }
    }

    func deleteNode(id: UUID) {
        guard let node = store.tree.find(id: id) else { return }

        if case .folder = node {
            var toRemove: [UUID] = []
            func collect(_ n: WorkspaceNode) {
                switch n {
                case .terminal(let d): toRemove.append(d.id)
                case .folder(let d): d.children.forEach { collect($0) }
                }
            }
            collect(node)

            let needsSwitch = toRemove.contains(where: { $0 == activeID })

            for tid in toRemove {
                if let container = splitContainers.removeValue(forKey: tid) {
                    container.rootView.removeFromSuperview()
                }
            }
            store.removeNode(id: id)

            if splitContainers.isEmpty {
                activeID = nil
                onChange?()
                return
            }

            if needsSwitch {
                activeID = nil
                if let first = store.tree.allTerminalIDsInOrder.first(where: { splitContainers[$0] != nil }) {
                    switchTo(id: first)
                    return
                }
            }
            onChange?()
        } else {
            closeTerminal(id: id)
        }
    }

    func clearWorkspace() {
        for (_, container) in splitContainers {
            container.rootView.removeFromSuperview()
        }
        splitContainers.removeAll()
        activeID = nil
        store.clearWorkspace()

        let cwd = store.workspaceDir
        let folderName = (cwd as NSString).lastPathComponent
        let folderID = store.addFolder(label: folderName)
        createTerminal(inFolder: folderID)
    }

    // MARK: - Switch

    func switchTo(id: UUID) {
        guard id != activeID else { return }
        guard let container = splitContainers[id] else { return }
        guard let terminalContainer else { return }

        // Remove old
        if let oldID = activeID, let oldContainer = splitContainers[oldID] {
            oldContainer.rootView.removeFromSuperview()
        }

        activeID = id
        store.setActive(terminalID: id)
        waitingForInput.remove(id)

        let view = container.rootView
        view.frame = terminalContainer.bounds
        view.autoresizingMask = [.width, .height]
        terminalContainer.addSubview(view)

        onChange?()
    }

    func focusTerminal() {
        if let view = activeTerminal {
            window?.makeFirstResponder(view)
        }
    }

    func switchToNext() {
        guard let activeID else { return }
        let ids = store.tree.allTerminalIDsInOrder.filter { splitContainers[$0] != nil }
        guard ids.count > 1, let idx = ids.firstIndex(of: activeID) else { return }
        switchTo(id: ids[(idx + 1) % ids.count])
    }

    func switchToPrevious() {
        guard let activeID else { return }
        let ids = store.tree.allTerminalIDsInOrder.filter { splitContainers[$0] != nil }
        guard ids.count > 1, let idx = ids.firstIndex(of: activeID) else { return }
        switchTo(id: ids[(idx - 1 + ids.count) % ids.count])
    }

    // MARK: - Move

    func moveNode(id: UUID, toParent: UUID?, atIndex: Int) {
        store.moveNode(id: id, toParent: toParent, atIndex: atIndex)
        onChange?()
    }

    // MARK: - Initial Directory

    static func initialDirectory() -> String {
        let args = ProcessInfo.processInfo.arguments
        if args.count > 1 {
            let candidate = args[1]
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        if let pwd = ProcessInfo.processInfo.environment["PWD"],
           pwd != "/", FileManager.default.fileExists(atPath: pwd) {
            return pwd
        }
        let cwd = FileManager.default.currentDirectoryPath
        if cwd != "/" { return cwd }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: - Directory Extraction

    /// Extract a full directory path from a shell title like "user@host: ~/path" or "user@host path"
    private static func extractDirectory(from raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return nil }

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Strip user@host prefix
        if title.contains("@") {
            if let range = title.range(of: ": ") {
                title = String(title[range.upperBound...])
            } else if let range = title.range(of: ":") {
                let after = String(title[range.upperBound...])
                if after.hasPrefix("/") || after.hasPrefix("~") { title = after }
            } else if let range = title.range(of: " ") {
                let after = String(title[range.upperBound...])
                if after.hasPrefix("/") || after.hasPrefix("~") || after.contains("/") {
                    title = after
                }
            }
        }

        // Expand ~ to home
        if title.hasPrefix("~") {
            title = home + title.dropFirst(1)
        }

        // Only return if it looks like a valid path
        if title.hasPrefix("/") && FileManager.default.fileExists(atPath: title) {
            return title
        }

        return nil
    }

    // MARK: - Title Cleaning

    private static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return "terminal" }
        let shells: Set = ["zsh", "bash", "fish", "sh", "dash", "-zsh", "-bash", "-fish"]
        if shells.contains(title.lowercased()) { return "terminal" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if title.contains("@") {
            if let range = title.range(of: ": ") { title = String(title[range.upperBound...]) }
            else if let range = title.range(of: ":") {
                let after = String(title[range.upperBound...])
                if after.hasPrefix("/") || after.hasPrefix("~") { title = after }
            } else if let range = title.range(of: " ") { title = String(title[range.upperBound...]) }
        }
        title = title.replacingOccurrences(of: home, with: "~")
        if title.contains("/") {
            while title.hasSuffix("/") && title.count > 1 { title.removeLast() }
            let last = (title as NSString).lastPathComponent
            if !last.isEmpty && last != "/" && last != "~" { return last }
            if title == "~" || title == "/" { return "~" }
        }
        if shells.contains(title.lowercased()) { return "terminal" }
        return title
    }
}
