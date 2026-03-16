import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var ghosttyApp: GhosttyApp!
    private var terminalManager: TerminalManager!
    private var store: WorkspaceStore!
    private var sidebarController: SidebarController!
    private var splitView: NSSplitView!
    private var sidebarView: NSView!
    private var sidebarWidth: CGFloat = 220
    private var sidebarVisible = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        ghosttyApp = GhosttyApp()
        guard ghosttyApp.app != nil else {
            NSLog("Failed to create GhosttyApp — exiting")
            NSApp.terminate(nil)
            return
        }

        // Window
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()

        // Split view
        splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = [.width, .height]
        splitView.delegate = self

        // Workspace store
        store = WorkspaceStore()

        // Sidebar (NSOutlineView)
        sidebarController = SidebarController(store: store)
        sidebarView = sidebarController.scrollView

        // Right pane: terminal container
        let terminalContainer = NSView()

        splitView.addArrangedSubview(sidebarView)
        splitView.addArrangedSubview(terminalContainer)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        window.contentView = splitView
        splitView.setPosition(220, ofDividerAt: 0)

        // Terminal manager
        terminalManager = TerminalManager(
            ghosttyApp: ghosttyApp,
            window: window,
            terminalContainer: terminalContainer,
            store: store
        )
        terminalManager.onChange = { [weak self] in
            self?.updateTitle()
            self?.sidebarController.reload()
        }

        // Wire sidebar callbacks
        sidebarController.callbacks = SidebarCallbacks(
            onSelect: { [weak self] id in
                self?.terminalManager.switchTo(id: id)
            },
            onRename: { [weak self] id, name in
                self?.store.rename(id: id, to: name)
                self?.terminalManager.onChange?()
            },
            onAddTerminal: { [weak self] folderID in
                self?.terminalManager.createTerminal(inFolder: folderID)
            },
            onAddFolder: { [weak self] parentID in
                guard let self else { return }
                _ = self.store.addFolder(label: self.store.nextFolderLabel(), inFolder: parentID)
                self.sidebarController.reload()
            },
            onDelete: { [weak self] id in
                self?.terminalManager.deleteNode(id: id)
            },
            onMove: { [weak self] id, parentID, index in
                self?.terminalManager.moveNode(id: id, toParent: parentID, atIndex: index)
            },
            onReturnFocus: { [weak self] in
                self?.terminalManager.focusTerminal()
            }
        )
        sidebarController.outlineView.callbacks = sidebarController.callbacks

        // Restore workspace or create first terminal
        terminalManager.restoreFromStore()
        sidebarController.reload()

        // Select the active terminal in sidebar
        if let activeID = store.tree.activeTerminalID {
            sidebarController.selectNode(id: activeID)
        }

        updateTitle()

        window.makeKeyAndOrderFront(nil)
        terminalManager.focusTerminal()
        NSApp.activate(ignoringOtherApps: true)

        setupMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.save()
    }

    // MARK: - Title

    private func updateTitle() {
        if let label = terminalManager.activeLabel {
            window.title = "Orca — \(label)"
        } else {
            window.title = "Orca"
        }
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Orca", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Orca", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Shell menu
        let shellMenuItem = NSMenuItem()
        let shellMenu = NSMenu(title: "Shell")
        shellMenu.addItem(withTitle: "New Terminal", action: #selector(newTerminal(_:)), keyEquivalent: "t")

        let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(newFolder(_:)), keyEquivalent: "n")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(newFolderItem)

        shellMenu.addItem(.separator())
        shellMenu.addItem(withTitle: "Close Terminal", action: #selector(closeTerminal(_:)), keyEquivalent: "w")
        shellMenu.addItem(.separator())
        shellMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebarPanel(_:)), keyEquivalent: "e")
        shellMenuItem.submenu = shellMenu
        mainMenu.addItem(shellMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Focus Sidebar", action: #selector(focusSidebar(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Focus Terminal", action: #selector(focusTerminal(_:)), keyEquivalent: "2")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")

        let nextItem = NSMenuItem(title: "Next Terminal", action: #selector(nextTerminal(_:)), keyEquivalent: "]")
        nextItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(nextItem)

        let prevItem = NSMenuItem(title: "Previous Terminal", action: #selector(previousTerminal(_:)), keyEquivalent: "[")
        prevItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(prevItem)

        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func newTerminal(_ sender: Any?) {
        let folderID = sidebarController.contextFolderID()
        let id = terminalManager.createTerminal(inFolder: folderID)
        sidebarController.ensureVisible(id: id)
        sidebarController.selectNode(id: id)
        sidebarController.focus()
    }

    @objc private func newFolder(_ sender: Any?) {
        let parentID = sidebarController.contextFolderID()
        let id = store.addFolder(label: store.nextFolderLabel(), inFolder: parentID)
        sidebarController.reload()
        sidebarController.ensureVisible(id: id)
        // Select and focus the new folder after async reload
        DispatchQueue.main.async { [weak self] in
            self?.sidebarController.selectNode(id: id)
            self?.sidebarController.focus()
        }
    }

    @objc private func closeTerminal(_ sender: Any?) {
        terminalManager.closeCurrent()
    }

    @objc private func nextTerminal(_ sender: Any?) {
        terminalManager.switchToNext()
        // Keep sidebar selection in sync
        if let activeID = store.tree.activeTerminalID {
            sidebarController.selectNode(id: activeID)
        }
    }

    @objc private func previousTerminal(_ sender: Any?) {
        terminalManager.switchToPrevious()
        if let activeID = store.tree.activeTerminalID {
            sidebarController.selectNode(id: activeID)
        }
    }

    @objc private func focusSidebar(_ sender: Any?) {
        sidebarController.focus()
    }

    @objc private func focusTerminal(_ sender: Any?) {
        terminalManager.focusTerminal()
    }

    @objc private func toggleSidebarPanel(_ sender: Any?) {
        if sidebarVisible {
            sidebarWidth = sidebarView.frame.width
            sidebarView.removeFromSuperview()
            splitView.adjustSubviews()
            sidebarVisible = false
        } else {
            splitView.insertArrangedSubview(sidebarView, at: 0)
            splitView.adjustSubviews()
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
            sidebarVisible = true
        }
        if let active = terminalManager.activeTerminal {
            window.makeFirstResponder(active)
        }
    }
}

// MARK: - NSSplitViewDelegate

extension AppDelegate: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        sidebarVisible ? 180 : 0
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        300
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === sidebarView
    }
}
