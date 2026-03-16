import Cocoa
import GhosttyKit

/// NSView subclass that hosts a single ghostty_surface_t and forwards all input to it.
class TerminalView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var trackingArea: NSTrackingArea?
    private var searchBar: SearchBarView?

    /// Called when the shell process exits (from close_surface_cb).
    var onClose: (() -> Void)?

    /// Called when the shell sets its title (from action_cb SET_TITLE).
    var onTitleChange: ((String) -> Void)?

    init(ghosttyApp: GhosttyApp, frame: NSRect) {
        super.init(frame: frame)

        guard let app = ghosttyApp.app else { return }

        // Create surface config
        var surfaceCfg = ghostty_surface_config_new()
        surfaceCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceCfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        surfaceCfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        surfaceCfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        surfaceCfg.font_size = 0 // use config default

        self.surface = ghostty_surface_new(app, &surfaceCfg)

        wantsLayer = true
        layer?.isOpaque = true
        updateTrackingArea()

        // Accept file drops
        registerForDraggedTypes([.fileURL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    // MARK: - Search

    func showSearch(needle: String? = nil) {
        if searchBar == nil {
            let bar = SearchBarView()
            bar.onSearch = { [weak self] query in
                self?.performSearch(query)
            }
            bar.onClose = { [weak self] in
                self?.hideSearch()
            }
            addSubview(bar)
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                bar.widthAnchor.constraint(equalToConstant: 280),
                bar.heightAnchor.constraint(equalToConstant: 36),
            ])
            searchBar = bar
        }
        searchBar?.isHidden = false
        if let needle, !needle.isEmpty {
            searchBar?.setText(needle)
        }
        window?.makeFirstResponder(searchBar?.searchField)
    }

    func hideSearch() {
        searchBar?.isHidden = true
        // Clear the search in ghostty
        if let surface {
            let action = "search:"
            _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
        }
        window?.makeFirstResponder(self)
    }

    func updateSearchCounts(total: Int?, selected: Int?) {
        searchBar?.updateCounts(total: total, selected: selected)
    }

    private func performSearch(_ query: String) {
        guard let surface else { return }
        let action = "search:\(query)"
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    var isSearchVisible: Bool {
        searchBar?.isHidden == false
    }

    // MARK: - Copy / Paste

    @objc func copy(_ sender: Any?) {
        guard let surface else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        if let ptr = text.text, text.text_len > 0 {
            let str = String(cString: ptr)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    @objc func paste(_ sender: Any?) {
        guard let surface else { return }
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        str.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(str.utf8.count))
        }
    }

    @objc override func selectAll(_ sender: Any?) {
        // Let ghostty handle select all via its binding
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, "select_all", 10)
    }

    // MARK: - Drag and Drop (files into terminal)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        if sender.draggingPasteboard.canReadObject(forClasses: [NSString.self], options: nil) {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let surface else { return false }

        // Try file URLs first — insert escaped paths
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map { path -> String in
                // Escape spaces and special chars for shell
                path.path.replacingOccurrences(of: " ", with: "\\ ")
                    .replacingOccurrences(of: "(", with: "\\(")
                    .replacingOccurrences(of: ")", with: "\\)")
                    .replacingOccurrences(of: "'", with: "\\'")
            }
            let text = paths.joined(separator: " ")
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
            }
            return true
        }

        // Fall back to string content
        if let strings = sender.draggingPasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String], !strings.isEmpty {
            let text = strings.joined()
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
            }
            return true
        }

        return false
    }

    // MARK: - View Lifecycle

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Don't auto-grab focus — TerminalManager.focusTerminal() handles this explicitly.
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)
        let w = UInt32(newSize.width * scale)
        let h = UInt32(newSize.height * scale)
        if w > 0 && h > 0 {
            ghostty_surface_set_size(surface, w, h)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    // MARK: - Keyboard Input

    override func keyDown(with event: NSEvent) {
        guard surface != nil else {
            interpretKeyEvents([event])
            return
        }

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Let AppKit's input system handle the event (calls insertText, etc.)
        interpretKeyEvents([event])

        // Send the key event to ghostty
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let texts = keyTextAccumulator ?? []
        let text = texts.joined()

        if text.isEmpty {
            let keyEv = event.ghosttyKeyEvent(action)
            _ = ghostty_surface_key(surface!, keyEv)
        } else {
            text.withCString { ptr in
                var keyEv = event.ghosttyKeyEvent(action)  // var: we set .text below
                keyEv.text = ptr
                _ = ghostty_surface_key(surface!, keyEv)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        let keyEv = event.ghosttyKeyEvent(GHOSTTY_ACTION_RELEASE)
        _ = ghostty_surface_key(surface, keyEv)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }

        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }

        if hasMarkedText() { return }

        let mods = ghosttyMods(event.modifierFlags)
        let action: ghostty_input_action_e = (mods.rawValue & mod != 0) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE

        let keyEv = event.ghosttyKeyEvent(action)
        _ = ghostty_surface_key(surface, keyEv)
    }

    // MARK: - Mouse Input

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        let mods = ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let mods = ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { super.rightMouseDown(with: event); return }
        let mods = ghosttyMods(event.modifierFlags)
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { super.rightMouseUp(with: event); return }
        let mods = ghosttyMods(event.modifierFlags)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        let mods = ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, mods)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            x *= 2
            y *= 2
        }
        // Build scroll mods as a packed int
        var scrollMods: Int32 = 0
        if event.hasPreciseScrollingDeltas { scrollMods |= 1 }
        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let s as NSAttributedString: chars = s.string
        case let s as String: chars = s
        default: return
        }

        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        // Direct text input (e.g. from IME commit outside keyDown)
        guard let surface else { return }
        chars.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(chars.utf8.count))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let s as NSAttributedString: markedText = NSMutableAttributedString(attributedString: s)
        case let s as String: markedText = NSMutableAttributedString(string: s)
        default: return
        }
        syncPreedit()
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    override func doCommand(by selector: Selector) {
        // Swallow unhandled commands (arrows, backspace, etc.) to prevent system beep.
        // All key input is forwarded to ghostty directly via ghostty_surface_key.
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let point = convert(NSPoint(x: x, y: frame.height - y), to: nil)
        let screenPoint = window?.convertPoint(toScreen: point) ?? point
        return NSRect(x: screenPoint.x, y: screenPoint.y - h, width: w, height: h)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    // MARK: - Helpers

    private func syncPreedit() {
        guard let surface else { return }
        if markedText.length > 0 {
            markedText.string.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(markedText.string.utf8.count))
            }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }
}

// MARK: - NSEvent Extension for Ghostty Key Events

private extension NSEvent {
    func ghosttyKeyEvent(_ action: ghostty_input_action_e) -> ghostty_input_key_s {
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.keycode = UInt32(keyCode)
        ev.text = nil
        ev.composing = false
        ev.mods = ghostty_input_mods_e(modFlags(modifierFlags))
        ev.consumed_mods = ghostty_input_mods_e(
            modFlags(modifierFlags.subtracting([.control, .command]))
        )
        ev.unshifted_codepoint = 0
        if type == .keyDown || type == .keyUp {
            if let chars = characters(byApplyingModifiers: []),
               let cp = chars.unicodeScalars.first {
                ev.unshifted_codepoint = cp.value
            }
        }
        return ev
    }

    private func modFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return m
    }
}
