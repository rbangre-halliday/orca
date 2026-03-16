import Cocoa

/// Manages TerminalView lifecycles, backed by WorkspaceStore for persistence.
class TerminalManager {
    private let ghosttyApp: GhosttyApp
    private weak var window: NSWindow?
    private weak var terminalContainer: NSView?
    let store: WorkspaceStore

    /// Maps terminal UUID -> live TerminalView.
    private var liveTerminals: [UUID: TerminalView] = [:]
    private var activeID: UUID?

    /// Called after any change (for title updates, sidebar reload, etc.).
    var onChange: (() -> Void)?

    var activeTerminal: TerminalView? {
        guard let id = activeID else { return nil }
        return liveTerminals[id]
    }

    var activeLabel: String? {
        guard let id = activeID else { return nil }
        return store.tree.find(id: id)?.label
    }

    var terminalCount: Int { liveTerminals.count }

    init(ghosttyApp: GhosttyApp, window: NSWindow, terminalContainer: NSView, store: WorkspaceStore) {
        self.ghosttyApp = ghosttyApp
        self.window = window
        self.terminalContainer = terminalContainer
        self.store = store
    }

    // MARK: - Restore from persistence

    func restoreFromStore() {
        let terminalIDs = store.tree.allTerminalIDsInOrder
        if terminalIDs.isEmpty {
            // First launch — create a folder named after initial directory
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
        let view = TerminalView(ghosttyApp: ghosttyApp, frame: frame)
        view.autoresizingMask = [.width, .height]

        view.onClose = { [weak self] in
            self?.closeTerminal(id: id)
        }

        view.onTitleChange = { [weak self] title in
            guard let self else { return }
            // Clean up the title — use last path component or process name
            let label = Self.cleanTitle(title)
            if !label.isEmpty {
                self.store.rename(id: id, to: label)
                self.onChange?()
            }
        }

        liveTerminals[id] = view
    }

    // MARK: - Close / Delete

    func closeCurrent() {
        guard let id = activeID else { return }
        closeTerminal(id: id)
    }

    func closeTerminal(id: UUID) {
        let allIDs = store.tree.allTerminalIDsInOrder
        let isActive = id == activeID

        var nextID: UUID?
        if isActive, allIDs.count > 1, let idx = allIDs.firstIndex(of: id) {
            nextID = idx + 1 < allIDs.count ? allIDs[idx + 1] : allIDs[idx - 1]
        } else if !isActive {
            nextID = activeID
        }

        if let view = liveTerminals.removeValue(forKey: id) {
            view.removeFromSuperview()
        }
        store.removeNode(id: id)

        if liveTerminals.isEmpty {
            activeID = nil
            onChange?()
            NSApp.terminate(nil)
            return
        }

        if let next = nextID {
            switchTo(id: next)
        } else {
            onChange?()
        }
    }

    /// Delete a node — if folder, close all contained terminals.
    func deleteNode(id: UUID) {
        guard let node = store.tree.find(id: id) else { return }

        if case .folder = node {
            let terminalIDs = store.tree.allTerminalIDsInOrder
            // Collect terminal IDs inside this folder
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
                if let view = liveTerminals.removeValue(forKey: tid) {
                    view.removeFromSuperview()
                }
            }
            store.removeNode(id: id)

            if liveTerminals.isEmpty {
                activeID = nil
                onChange?()
                NSApp.terminate(nil)
                return
            }

            if needsSwitch {
                activeID = nil
                if let first = store.tree.allTerminalIDsInOrder.first {
                    switchTo(id: first)
                    return
                }
            }
            onChange?()
        } else {
            closeTerminal(id: id)
        }
    }

    // MARK: - Switch

    /// Switch the displayed terminal. Does NOT steal focus — call `focusTerminal()` separately.
    func switchTo(id: UUID) {
        guard id != activeID else { return }
        guard let view = liveTerminals[id] else { return }
        guard let terminalContainer else { return }

        if let old = activeTerminal {
            old.removeFromSuperview()
        }

        activeID = id
        store.setActive(terminalID: id)

        view.frame = terminalContainer.bounds
        view.autoresizingMask = [.width, .height]
        terminalContainer.addSubview(view)

        onChange?()
    }

    /// Give keyboard focus to the active terminal.
    func focusTerminal() {
        if let view = activeTerminal {
            window?.makeFirstResponder(view)
        }
    }

    func switchToNext() {
        guard let activeID else { return }
        let ids = store.tree.allTerminalIDsInOrder
        guard ids.count > 1, let idx = ids.firstIndex(of: activeID) else { return }
        switchTo(id: ids[(idx + 1) % ids.count])
    }

    func switchToPrevious() {
        guard let activeID else { return }
        let ids = store.tree.allTerminalIDsInOrder
        guard ids.count > 1, let idx = ids.firstIndex(of: activeID) else { return }
        switchTo(id: ids[(idx - 1 + ids.count) % ids.count])
    }

    // MARK: - Move (drag-drop)

    func moveNode(id: UUID, toParent: UUID?, atIndex: Int) {
        store.moveNode(id: id, toParent: toParent, atIndex: atIndex)
        onChange?()
    }

    // MARK: - Initial Directory

    /// Determine the initial working directory: CLI arg > PWD env > cwd > home.
    static func initialDirectory() -> String {
        // 1. Command line argument: `orca /path/to/dir`
        let args = ProcessInfo.processInfo.arguments
        if args.count > 1 {
            let candidate = args[1]
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }

        // 2. PWD environment variable (set by the shell)
        if let pwd = ProcessInfo.processInfo.environment["PWD"],
           pwd != "/",
           FileManager.default.fileExists(atPath: pwd) {
            return pwd
        }

        // 3. Actual cwd if it's not root
        let cwd = FileManager.default.currentDirectoryPath
        if cwd != "/" {
            return cwd
        }

        // 4. Fall back to home
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    // MARK: - Title Cleaning

    /// Clean a shell title into a concise label.
    private static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return "terminal" }

        // Shell names → "terminal"
        let shells: Set = ["zsh", "bash", "fish", "sh", "dash", "-zsh", "-bash", "-fish"]
        if shells.contains(title.lowercased()) { return "terminal" }

        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Strip user@host prefix in any format (with ": ", ":", or " ")
        if title.contains("@") {
            // Try "user@host: rest"
            if let range = title.range(of: ": ") {
                title = String(title[range.upperBound...])
            }
            // Try "user@host:rest"
            else if let range = title.range(of: ":") {
                let afterColon = String(title[range.upperBound...])
                if afterColon.hasPrefix("/") || afterColon.hasPrefix("~") {
                    title = afterColon
                }
            }
            // Try "user@host rest"
            else if let range = title.range(of: " ") {
                title = String(title[range.upperBound...])
            }
        }

        // Replace home path with ~
        title = title.replacingOccurrences(of: home, with: "~")

        // If it contains a path separator, extract last meaningful component
        if title.contains("/") {
            // Remove trailing slash
            while title.hasSuffix("/") && title.count > 1 { title.removeLast() }
            let last = (title as NSString).lastPathComponent
            if !last.isEmpty && last != "/" && last != "~" {
                return last
            }
            if title == "~" || title == "/" { return "~" }
        }

        // Check if what remains is still a shell name
        if shells.contains(title.lowercased()) { return "terminal" }

        return title
    }
}
