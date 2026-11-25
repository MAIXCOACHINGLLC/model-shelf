import Foundation

/// The settings file (`shelf.json`): where models live, how to name jobs, and the descriptions and
/// corrections for known models. Every field has a default, so `{}` is a valid file.
public struct ShelfConfig: Decodable {
    public struct Model: Decodable {
        public let id: String
        public let name: String          // a plain name people know it by, e.g. "Picture maker"
        public let tech: String?         // the technical name, shown small in the detail
        public let does: String?         // a few words on what it does, shown on the row
        public let kind: String
        public let icon: String?         // SF Symbol name
        public let color: String?        // pink, orange, blue, teal, purple, indigo, red, mint, cyan, yellow, green, gray
        public let match: [String]       // globs on an item key: a path from home, or "ollama/<tag>"
        public let what: String
        public let status: String?       // "idle" or "unused" overrides what the scan finds
        public let notUsedBy: [String]?  // job or skill names the code search links by mistake
        public let note: String?
    }

    public var hfStores: [String] = ["~/.cache/huggingface/hub"]
    public var fileStores: [String] = ["~/ComfyUI/models", "~/Documents/ComfyUI/models", "~/.lmstudio/models"]  // ComfyUI by hand, the ComfyUI app, LM Studio
    public var ollama: String? = "http://127.0.0.1:11434"
    public var skills: [String] = ["~/.claude/skills"]
    public var skipAgents: [String] = []
    public var ignoreFiles: [String] = ["tests/*", "*/tests/*", "test/*", "*/test/*", "docs/*", "*/docs/*"]
    public var agents: [String: String] = [:]
    public var skillNames: [String: String] = [:]
    public var models: [Model] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = ShelfConfig()
        hfStores = try c.decodeIfPresent([String].self, forKey: .hfStores) ?? d.hfStores
        fileStores = try c.decodeIfPresent([String].self, forKey: .fileStores) ?? d.fileStores
        ollama = c.contains(.ollama) ? try c.decodeIfPresent(String.self, forKey: .ollama) : d.ollama
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? d.skills
        skipAgents = try c.decodeIfPresent([String].self, forKey: .skipAgents) ?? d.skipAgents
        ignoreFiles = try c.decodeIfPresent([String].self, forKey: .ignoreFiles) ?? d.ignoreFiles
        agents = try c.decodeIfPresent([String: String].self, forKey: .agents) ?? d.agents
        skillNames = try c.decodeIfPresent([String: String].self, forKey: .skillNames) ?? d.skillNames
        models = try c.decodeIfPresent([Model].self, forKey: .models) ?? d.models
    }

    private enum Keys: String, CodingKey {
        case hfStores, fileStores, ollama, skills, skipAgents, ignoreFiles, agents, skillNames, models
    }
}

/// A job or skill that uses a model, and how the scan knows.
public struct User: Codable, Hashable {
    public let agent: String
    public let how: String
    public let tag: String               // "job", "job (not loaded)" or "skill"
}

/// One model on the shelf: its files, size, description and users.
public struct Entry: Codable, Identifiable {
    public let id: String
    public let name: String
    public let tech: String?             // from the settings
    public let does: String?             // from the settings
    public let kind: String
    public let icon: String
    public let color: String
    public let what: String
    public let added: Date?              // when its oldest file or folder appeared on disk, if the system says
    public let gb: Double
    public let store: String
    public let users: [User]
    public let section: String           // "used", "idle" or "unused"
    public let loaded: Bool              // in Ollama's memory right now
    public let isNew: Bool               // found on disk, not described in the settings
    public let note: String?
    public let files: [String]
}

public struct Scan: Codable {
    public let entries: [Entry]
    public let at: Date
    public let warnings: [String]

    public init(entries: [Entry], at: Date, warnings: [String]) {
        self.entries = entries
        self.at = at
        self.warnings = warnings
    }
}

/// Sizes the way the panel shows them: "480 MB", "1.6 GB", "30 GB".
public func gbText(_ gb: Double) -> String {
    if gb < 0.1 { return "\(Int((gb * 1000).rounded())) MB" }
    return gb < 10 ? String(format: "%.1f GB", gb) : "\(Int(gb.rounded())) GB"
}

/// The scan as plain text for a terminal: the same sections as the panel, one line per model.
public func listText(_ scan: Scan) -> String {
    let total = scan.entries.reduce(0) { $0 + $1.gb }
    var out = scan.warnings.map { "Note: " + $0 }
    guard !scan.entries.isEmpty else {
        return (out + ["No models found. The README shows how to point Model Shelf at your model folders."]).joined(separator: "\n")
    }
    out.append("Models: \(gbText(total)) in \(scan.entries.count) model\(scan.entries.count == 1 ? "" : "s")")
    let width = min(40, scan.entries.map(\.name.count).max() ?? 0)
    func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
        let fill = String(repeating: " ", count: max(0, n - s.count))
        return left ? fill + s : s + fill
    }
    for (id, title) in [("used", "In use"), ("idle", "Resting"), ("unused", "Leftovers")] {
        let list = scan.entries.filter { $0.section == id }
        guard !list.isEmpty else { continue }
        out += ["", "\(title) (\(gbText(list.reduce(0) { $0 + $1.gb })))"]
        for e in list {
            let names = e.users.map(\.agent)
            let who = !names.isEmpty ? names.joined(separator: ", ") : (e.loaded ? "in memory now, nothing names it" : "nothing uses it")
            out.append("  " + pad(e.name, width) + "  " + pad(gbText(e.gb), 7, left: true) + "  " + who)
        }
    }
    return out.joined(separator: "\n")
}
