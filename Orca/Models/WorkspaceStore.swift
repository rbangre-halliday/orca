import Foundation
import Combine
import CommonCrypto

/// Owns the workspace tree, handles mutations, and persists to JSON per-directory.
class WorkspaceStore: ObservableObject {
    @Published var tree: WorkspaceTree

    private let configURL: URL
    let workspaceDir: String

    init(directory: String) {
        self.workspaceDir = directory
        let workspacesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/orca/workspaces")
        let hash = Self.directoryHash(directory)
        configURL = workspacesDir.appendingPathComponent("\(hash).json")
        tree = WorkspaceTree()

        // Restore from disk if available
        if let loaded = Self.load(from: configURL) {
            tree = loaded
        }
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

    func rename(id: UUID, to label: String, manual: Bool = false) {
        tree.rename(id: id, to: label, manual: manual)
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

    /// Reset workspace to empty (clear all).
    func clearWorkspace() {
        tree = WorkspaceTree()
        save()
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

    /// Stable hash of a directory path for the workspace filename.
    private static func directoryHash(_ path: String) -> String {
        let data = Data(path.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buf in
            _ = CC_SHA256(buf.baseAddress, CC_LONG(buf.count), &hash)
        }
        return hash.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
