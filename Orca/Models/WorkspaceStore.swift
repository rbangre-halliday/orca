import Foundation
import Combine

/// Owns the workspace tree, handles mutations, and persists to JSON.
class WorkspaceStore: ObservableObject {
    @Published var tree: WorkspaceTree

    private let configURL: URL

    init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/orca")
        configURL = configDir.appendingPathComponent("workspace.json")
        tree = WorkspaceTree()
    }

    // MARK: - Mutations (all auto-save)

    func addTerminal(label: String, inFolder folderID: UUID? = nil) -> UUID {
        let data = TerminalNodeData(label: label)
        tree.addTerminal(data, inFolder: folderID)
        tree.activeTerminalID = data.id
        save()
        return data.id
    }

    func addFolder(label: String, inFolder folderID: UUID? = nil) -> UUID {
        let data = FolderNodeData(label: label)
        tree.addFolder(data, inFolder: folderID)
        save()
        return data.id
    }

    @discardableResult
    func removeNode(id: UUID) -> [UUID] {
        let removed = tree.removeNode(id: id)
        save()
        return removed
    }

    func rename(id: UUID, to label: String) {
        tree.rename(id: id, to: label)
        save()
    }

    func moveNode(id: UUID, toParent: UUID?, atIndex: Int) {
        tree.moveNode(id: id, toParent: toParent, atIndex: atIndex)
        save()
    }

    func setActive(terminalID: UUID) {
        tree.activeTerminalID = terminalID
        save()
    }

    func setExpanded(id: UUID, expanded: Bool) {
        tree.setExpanded(id: id, expanded: expanded)
        save()
    }

    func nextTerminalLabel() -> String {
        "terminal"
    }

    func nextFolderLabel() -> String {
        "New Folder"
    }

    // MARK: - Persistence

    func save() {
        let dir = configURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(tree) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    private static func load(from url: URL) -> WorkspaceTree? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WorkspaceTree.self, from: data)
    }
}
