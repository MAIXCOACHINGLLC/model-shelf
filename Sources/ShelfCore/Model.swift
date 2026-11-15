import Foundation

/// The settings file (`shelf.json`): where models live, how to name jobs, and the descriptions and
/// corrections for known models. Every field has a default, so `{}` is a valid file.
public struct ShelfConfig: Decodable {
    public struct Model: Decodable {
        public let id: String
        public let name: String
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
    public var fileStores: [String] = ["~/ComfyUI/models", "~/.lmstudio/models"]
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
    public let kind: String
    public let icon: String
    public let color: String
    public let what: String
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
