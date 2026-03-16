import Cocoa
import GhosttyKit

/// Wraps the ghostty_app_t lifecycle: config, runtime callbacks, and tick loop.
class GhosttyApp {
    private(set) var app: ghostty_app_t?

    init() {
        // Build config
        guard let config = ghostty_config_new() else { return }
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        // Build runtime config with callbacks.
        // Note: the userdata for surface-level callbacks (read/write clipboard, close)
        // is the surface's userdata (set in ghostty_surface_config_s), NOT the app's.
        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { ud in
                guard let ud else { return }
                let me = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
                DispatchQueue.main.async { me.tick() }
            },
            action_cb: { app, target, action in
                return GhosttyApp.handleAction(app, target: target, action: action)
            },
            read_clipboard_cb: { surfaceUD, loc, state in
                // surfaceUD is the TerminalView (surface's userdata)
                guard let surfaceUD else { return false }
                let view = Unmanaged<TerminalView>.fromOpaque(surfaceUD).takeUnretainedValue()
                guard let surface = view.surface else { return false }
                guard let str = NSPasteboard.general.string(forType: .string) else { return false }
                str.withCString { ptr in
                    ghostty_surface_complete_clipboard_request(surface, ptr, state, true)
                }
                return true
            },
            confirm_read_clipboard_cb: { surfaceUD, str, state, req in
                // Auto-confirm: just complete the request
                guard let surfaceUD else { return }
                let view = Unmanaged<TerminalView>.fromOpaque(surfaceUD).takeUnretainedValue()
                guard let surface = view.surface else { return }
                ghostty_surface_complete_clipboard_request(surface, str, state, true)
            },
            write_clipboard_cb: { surfaceUD, loc, content, len, confirm in
                guard let content, len > 0 else { return }
                if let data = content.pointee.data {
                    let str = String(cString: data)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(str, forType: .string)
                }
            },
            close_surface_cb: { surfaceUD, processAlive in
                guard let surfaceUD else { return }
                let view = Unmanaged<TerminalView>.fromOpaque(surfaceUD).takeUnretainedValue()
                DispatchQueue.main.async {
                    view.onClose?()
                }
            }
        )

        self.app = ghostty_app_new(&runtime, config)
        ghostty_config_free(config)
    }

    deinit {
        if let app { ghostty_app_free(app) }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private static func handleAction(
        _ app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_NEW_WINDOW,
             GHOSTTY_ACTION_NEW_TAB,
             GHOSTTY_ACTION_NEW_SPLIT:
            // Ignore for now — single terminal
            return true

        case GHOSTTY_ACTION_RENDER:
            // Tell the surface view to redraw
            if target.tag == GHOSTTY_TARGET_SURFACE,
               let surfaceUD = ghostty_surface_userdata(target.target.surface) {
                let view = Unmanaged<TerminalView>.fromOpaque(surfaceUD).takeUnretainedValue()
                view.needsDisplay = true
            }
            return true

        case GHOSTTY_ACTION_SET_TITLE:
            if target.tag == GHOSTTY_TARGET_SURFACE,
               let surfaceUD = ghostty_surface_userdata(target.target.surface),
               let title = action.action.set_title.title {
                let view = Unmanaged<TerminalView>.fromOpaque(surfaceUD).takeUnretainedValue()
                let str = String(cString: title)
                DispatchQueue.main.async {
                    view.onTitleChange?(str)
                }
            }
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return true

        default:
            return false
        }
    }
}
