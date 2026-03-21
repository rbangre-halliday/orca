import Cocoa
import GhosttyKit

/// Manages a recursive binary split tree of TerminalViews for a single sidebar entry.
class SplitContainer: NSObject, NSSplitViewDelegate {
    indirect enum Node {
        case leaf(TerminalView)
        case split(direction: Direction, splitView: NSSplitView, first: Node, second: Node)
    }

    enum Direction {
        case horizontal // side by side
        case vertical   // top/bottom
    }

    var root: Node
    weak var focusedTerminal: TerminalView?

    init(terminal: TerminalView) {
        self.root = .leaf(terminal)
        self.focusedTerminal = terminal
    }

    /// The top-level NSView to add to the terminal container.
    var rootView: NSView {
        switch root {
        case .leaf(let tv): return tv
        case .split(_, let sv, _, _): return sv
        }
    }

    /// All TerminalViews in this container (depth-first).
    func allTerminals() -> [TerminalView] {
        var result: [TerminalView] = []
        func walk(_ node: Node) {
            switch node {
            case .leaf(let tv): result.append(tv)
            case .split(_, _, let a, let b): walk(a); walk(b)
            }
        }
        walk(root)
        return result
    }

    // MARK: - Split

    /// Split the pane containing `terminal`, creating a new TerminalView next to it.
    /// Returns the new TerminalView.
    func split(terminal: TerminalView, direction: Direction, ghosttyApp: GhosttyApp) -> TerminalView? {
        guard let app = ghosttyApp.app else { return nil }

        let newView = TerminalView(ghosttyApp: ghosttyApp, frame: terminal.bounds)
        newView.autoresizingMask = [.width, .height]

        let sv = NSSplitView()
        sv.isVertical = (direction == .horizontal)
        sv.dividerStyle = .thin
        sv.delegate = self
        sv.autoresizingMask = [.width, .height]

        // Replace the terminal in the view hierarchy
        let parent = terminal.superview
        let frame = terminal.frame
        terminal.removeFromSuperview()

        sv.frame = frame
        sv.addArrangedSubview(terminal)
        sv.addArrangedSubview(newView)

        if let parent = parent as? NSSplitView {
            // Find which index the terminal was at
            // It was already removed, so just add the split view
            parent.addArrangedSubview(sv)
        } else {
            parent?.addSubview(sv)
        }

        // Update the tree
        root = replaceLeaf(in: root, target: terminal, with: .split(
            direction: direction, splitView: sv,
            first: .leaf(terminal), second: .leaf(newView)
        ))

        // Set equal sizes
        let dividerPos = direction == .horizontal
            ? frame.width / 2
            : frame.height / 2
        sv.setPosition(dividerPos, ofDividerAt: 0)

        focusedTerminal = newView
        return newView
    }

    private func replaceLeaf(in node: Node, target: TerminalView, with replacement: Node) -> Node {
        switch node {
        case .leaf(let tv):
            return tv === target ? replacement : node
        case .split(let dir, let sv, let a, let b):
            return .split(direction: dir, splitView: sv,
                          first: replaceLeaf(in: a, target: target, with: replacement),
                          second: replaceLeaf(in: b, target: target, with: replacement))
        }
    }

    // MARK: - Remove

    /// Remove a terminal from the split tree. Returns true if the container is now empty.
    @discardableResult
    func remove(terminal: TerminalView) -> Bool {
        terminal.removeFromSuperview()
        if case .leaf(let tv) = root, tv === terminal {
            return true // container is empty
        }

        root = removedLeaf(in: root, target: terminal) ?? root
        return false
    }

    private func removedLeaf(in node: Node, target: TerminalView) -> Node? {
        switch node {
        case .leaf(let tv):
            return tv === target ? nil : node
        case .split(let dir, let sv, let a, let b):
            let newA = removedLeaf(in: a, target: target)
            let newB = removedLeaf(in: b, target: target)

            if newA == nil && newB == nil { return nil }
            if newA == nil {
                // Replace split with just B
                let bView = viewFor(newB ?? b)
                bView.frame = sv.frame
                bView.autoresizingMask = [.width, .height]
                if let parent = sv.superview as? NSSplitView {
                    let idx = parent.arrangedSubviews.firstIndex(of: sv) ?? 0
                    sv.removeFromSuperview()
                    parent.insertArrangedSubview(bView, at: idx)
                } else if let parent = sv.superview {
                    sv.removeFromSuperview()
                    parent.addSubview(bView)
                }
                return newB ?? b
            }
            if newB == nil {
                let aView = viewFor(newA ?? a)
                aView.frame = sv.frame
                aView.autoresizingMask = [.width, .height]
                if let parent = sv.superview as? NSSplitView {
                    let idx = parent.arrangedSubviews.firstIndex(of: sv) ?? 0
                    sv.removeFromSuperview()
                    parent.insertArrangedSubview(aView, at: idx)
                } else if let parent = sv.superview {
                    sv.removeFromSuperview()
                    parent.addSubview(aView)
                }
                return newA ?? a
            }
            return .split(direction: dir, splitView: sv, first: newA!, second: newB!)
        }
    }

    private func viewFor(_ node: Node) -> NSView {
        switch node {
        case .leaf(let tv): return tv
        case .split(_, let sv, _, _): return sv
        }
    }

    // MARK: - Navigate

    /// Find the adjacent terminal in the given direction.
    func navigate(from terminal: TerminalView, direction: ghostty_action_goto_split_e) -> TerminalView? {
        let all = allTerminals()
        guard all.count > 1 else { return nil }

        if direction == GHOSTTY_GOTO_SPLIT_NEXT {
            guard let idx = all.firstIndex(where: { $0 === terminal }) else { return nil }
            return all[(idx + 1) % all.count]
        }
        if direction == GHOSTTY_GOTO_SPLIT_PREVIOUS {
            guard let idx = all.firstIndex(where: { $0 === terminal }) else { return nil }
            return all[(idx - 1 + all.count) % all.count]
        }

        // Spatial navigation: find the nearest terminal in the requested direction
        let rootV = rootView
        let currentRect = terminal.convert(terminal.bounds, to: rootV)
        let currentCenter = CGPoint(x: currentRect.midX, y: currentRect.midY)

        var best: TerminalView?
        var bestDist = CGFloat.infinity

        for candidate in all where candidate !== terminal {
            let candidateRect = candidate.convert(candidate.bounds, to: rootV)
            let candidateCenter = CGPoint(x: candidateRect.midX, y: candidateRect.midY)

            let dx = candidateCenter.x - currentCenter.x
            let dy = candidateCenter.y - currentCenter.y

            let isValid: Bool
            switch direction {
            case GHOSTTY_GOTO_SPLIT_LEFT:  isValid = dx < -10
            case GHOSTTY_GOTO_SPLIT_RIGHT: isValid = dx > 10
            case GHOSTTY_GOTO_SPLIT_UP:    isValid = dy > 10   // NSView y is flipped
            case GHOSTTY_GOTO_SPLIT_DOWN:  isValid = dy < -10
            default: isValid = false
            }

            if isValid {
                let dist = abs(dx) + abs(dy)
                if dist < bestDist {
                    bestDist = dist
                    best = candidate
                }
            }
        }

        return best
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        80
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let total = splitView.isVertical ? splitView.frame.width : splitView.frame.height
        return total - 80
    }
}
