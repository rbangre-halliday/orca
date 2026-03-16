import Foundation

// MARK: - Node Types

struct TerminalNodeData: Identifiable, Codable {
    let id: UUID
    var label: String
    var isManuallyRenamed: Bool

    init(id: UUID = UUID(), label: String, isManuallyRenamed: Bool = false) {
        self.id = id
        self.label = label
        self.isManuallyRenamed = isManuallyRenamed
    }
}

struct FolderNodeData: Identifiable, Codable {
    let id: UUID
    var label: String
    var children: [WorkspaceNode]
    var isExpanded: Bool

    init(id: UUID = UUID(), label: String, children: [WorkspaceNode] = [], isExpanded: Bool = true) {
        self.id = id
        self.label = label
        self.children = children
        self.isExpanded = isExpanded
    }
}

// MARK: - Recursive Node

enum WorkspaceNode: Identifiable, Codable {
    case terminal(TerminalNodeData)
    case folder(FolderNodeData)

    var id: UUID {
        switch self {
        case .terminal(let d): return d.id
        case .folder(let d): return d.id
        }
    }

    var label: String {
        get {
            switch self {
            case .terminal(let d): return d.label
            case .folder(let d): return d.label
            }
        }
        set {
            switch self {
            case .terminal(var d): d.label = newValue; self = .terminal(d)
            case .folder(var d): d.label = newValue; self = .folder(d)
            }
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    var children: [WorkspaceNode] {
        get {
            if case .folder(let d) = self { return d.children }
            return []
        }
        set {
            if case .folder(var d) = self { d.children = newValue; self = .folder(d) }
        }
    }

    var isExpanded: Bool {
        get {
            if case .folder(let d) = self { return d.isExpanded }
            return false
        }
        set {
            if case .folder(var d) = self { d.isExpanded = newValue; self = .folder(d) }
        }
    }

    // Codable with discriminator
    enum CodingKeys: String, CodingKey {
        case type, terminal, folder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "terminal":
            self = .terminal(try container.decode(TerminalNodeData.self, forKey: .terminal))
        case "folder":
            self = .folder(try container.decode(FolderNodeData.self, forKey: .folder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let d):
            try container.encode("terminal", forKey: .type)
            try container.encode(d, forKey: .terminal)
        case .folder(let d):
            try container.encode("folder", forKey: .type)
            try container.encode(d, forKey: .folder)
        }
    }
}

// MARK: - Workspace Tree

struct WorkspaceTree: Codable {
    var roots: [WorkspaceNode]
    var activeTerminalID: UUID?

    init() {
        roots = []
        activeTerminalID = nil
    }

    // MARK: - Queries

    /// All terminal IDs in display order (depth-first walk).
    var allTerminalIDsInOrder: [UUID] {
        var result: [UUID] = []
        func walk(_ nodes: [WorkspaceNode]) {
            for node in nodes {
                switch node {
                case .terminal(let d): result.append(d.id)
                case .folder(let d): walk(d.children)
                }
            }
        }
        walk(roots)
        return result
    }

    /// Find a node by ID anywhere in the tree.
    func find(id: UUID) -> WorkspaceNode? {
        func search(_ nodes: [WorkspaceNode]) -> WorkspaceNode? {
            for node in nodes {
                if node.id == id { return node }
                if case .folder(let d) = node {
                    if let found = search(d.children) { return found }
                }
            }
            return nil
        }
        return search(roots)
    }

    /// Find the parent folder ID of a node (nil if root-level).
    func parentID(of id: UUID) -> UUID? {
        func search(_ nodes: [WorkspaceNode], parent: UUID?) -> UUID? {
            for node in nodes {
                if node.id == id { return parent }
                if case .folder(let d) = node {
                    if let found = search(d.children, parent: d.id) { return found }
                }
            }
            return nil
        }
        return search(roots, parent: nil)
    }

    /// Check if `ancestorID` is an ancestor of `nodeID`.
    func isAncestor(_ ancestorID: UUID, of nodeID: UUID) -> Bool {
        func search(_ nodes: [WorkspaceNode]) -> Bool {
            for node in nodes {
                if node.id == nodeID { return false }
                if case .folder(let d) = node {
                    if d.id == ancestorID {
                        return containsRecursive(d.children, id: nodeID)
                    }
                    if search(d.children) { return true }
                }
            }
            return false
        }
        return search(roots)
    }

    private func containsRecursive(_ nodes: [WorkspaceNode], id: UUID) -> Bool {
        for node in nodes {
            if node.id == id { return true }
            if case .folder(let d) = node, containsRecursive(d.children, id: id) { return true }
        }
        return false
    }

    // MARK: - Mutations

    mutating func addTerminal(_ data: TerminalNodeData, inFolder folderID: UUID? = nil) {
        let node = WorkspaceNode.terminal(data)
        if let fid = folderID {
            insertIntoFolder(fid, node: node)
        } else {
            roots.append(node)
        }
    }

    mutating func addFolder(_ data: FolderNodeData, inFolder folderID: UUID? = nil) {
        let node = WorkspaceNode.folder(data)
        if let fid = folderID {
            insertIntoFolder(fid, node: node)
        } else {
            roots.append(node)
        }
    }

    private mutating func insertIntoFolder(_ folderID: UUID, node: WorkspaceNode) {
        func insert(_ nodes: inout [WorkspaceNode]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == folderID, case .folder(var d) = nodes[i] {
                    d.children.append(node)
                    nodes[i] = .folder(d)
                    return true
                }
                if case .folder(var d) = nodes[i] {
                    if insert(&d.children) {
                        nodes[i] = .folder(d)
                        return true
                    }
                }
            }
            return false
        }
        _ = insert(&roots)
    }

    /// Remove a node by ID. Returns all terminal IDs that were removed (for cleanup).
    @discardableResult
    mutating func removeNode(id: UUID) -> [UUID] {
        var removedTerminalIDs: [UUID] = []

        func collectTerminals(_ node: WorkspaceNode) {
            switch node {
            case .terminal(let d): removedTerminalIDs.append(d.id)
            case .folder(let d): d.children.forEach { collectTerminals($0) }
            }
        }

        func remove(_ nodes: inout [WorkspaceNode]) -> Bool {
            if let idx = nodes.firstIndex(where: { $0.id == id }) {
                collectTerminals(nodes[idx])
                nodes.remove(at: idx)
                return true
            }
            for i in nodes.indices {
                if case .folder(var d) = nodes[i] {
                    if remove(&d.children) {
                        nodes[i] = .folder(d)
                        return true
                    }
                }
            }
            return false
        }

        _ = remove(&roots)

        if removedTerminalIDs.contains(where: { $0 == activeTerminalID }) {
            activeTerminalID = allTerminalIDsInOrder.first
        }

        return removedTerminalIDs
    }

    mutating func rename(id: UUID, to label: String, manual: Bool = false) {
        func update(_ nodes: inout [WorkspaceNode]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == id {
                    nodes[i].label = label
                    if manual, case .terminal(var d) = nodes[i] {
                        d.label = label
                        d.isManuallyRenamed = true
                        nodes[i] = .terminal(d)
                    }
                    return true
                }
                if case .folder(var d) = nodes[i] {
                    if update(&d.children) {
                        nodes[i] = .folder(d)
                        return true
                    }
                }
            }
            return false
        }
        _ = update(&roots)
    }

    func isManuallyRenamed(id: UUID) -> Bool {
        if case .terminal(let d) = find(id: id) { return d.isManuallyRenamed }
        return false
    }

    /// Move a node to a new parent at a specific index. `toParent` nil means root.
    mutating func moveNode(id: UUID, toParent: UUID?, atIndex: Int) {
        // First, extract the node
        var extracted: WorkspaceNode?

        func extract(_ nodes: inout [WorkspaceNode]) -> Bool {
            if let idx = nodes.firstIndex(where: { $0.id == id }) {
                extracted = nodes.remove(at: idx)
                return true
            }
            for i in nodes.indices {
                if case .folder(var d) = nodes[i] {
                    if extract(&d.children) {
                        nodes[i] = .folder(d)
                        return true
                    }
                }
            }
            return false
        }

        _ = extract(&roots)
        guard let node = extracted else { return }

        // Insert at new location
        if let parentID = toParent {
            func insert(_ nodes: inout [WorkspaceNode]) -> Bool {
                for i in nodes.indices {
                    if nodes[i].id == parentID, case .folder(var d) = nodes[i] {
                        let idx = min(atIndex, d.children.count)
                        d.children.insert(node, at: idx)
                        nodes[i] = .folder(d)
                        return true
                    }
                    if case .folder(var d) = nodes[i] {
                        if insert(&d.children) {
                            nodes[i] = .folder(d)
                            return true
                        }
                    }
                }
                return false
            }
            if !insert(&roots) {
                // Parent not found, fall back to root
                roots.append(node)
            }
        } else {
            let idx = min(atIndex, roots.count)
            roots.insert(node, at: idx)
        }
    }

    mutating func setExpanded(id: UUID, expanded: Bool) {
        func update(_ nodes: inout [WorkspaceNode]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == id {
                    nodes[i].isExpanded = expanded
                    return true
                }
                if case .folder(var d) = nodes[i] {
                    if update(&d.children) {
                        nodes[i] = .folder(d)
                        return true
                    }
                }
            }
            return false
        }
        _ = update(&roots)
    }
}
