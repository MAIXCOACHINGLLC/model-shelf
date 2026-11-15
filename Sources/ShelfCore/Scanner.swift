import Foundation

// The scan. Read only: it lists model files, reads job and skill code for model names, and asks a local Ollama what
// it holds. It never writes, moves or deletes anything, and it skips data folders and private folders.

/// What the scan needs from the machine. `live` is the real Mac; tests pass a fake home and fake answers.
public struct ScanEnvironment {
    public var home: String
    public var loadedJobs: () -> Set<String>                 // launchd labels that are loaded now
    public var fetchJSON: (String) -> [String: Any]?         // GET a local URL and parse JSON

    public init(home: String, loadedJobs: @escaping () -> Set<String>, fetchJSON: @escaping (String) -> [String: Any]?) {
        self.home = home
        self.loadedJobs = loadedJobs
        self.fetchJSON = fetchJSON
    }

    public static var live: ScanEnvironment {
        ScanEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            loadedJobs: {
                Set(run("/bin/launchctl", ["list"]).split(separator: "\n").compactMap { $0.split(separator: "\t").last.map(String.init) })
            },
            fetchJSON: getJSON
        )
    }
}

public func runScan(config: ShelfConfig, env: ScanEnvironment = .live) -> Scan {
    Scanner(cfg: config, env: env).scan()
}

private struct Item {
    let key: String                  // path from home, or "ollama/<tag>"
    let store: String
    let ids: [String]                // strings that name this model in code
    let gb: Double
    let defaultKind: String
}

private struct Agent {
    let name: String
    let root: String
    let tag: String
    let skillName: String?
    var isSkill: Bool { skillName != nil }
}

private struct SourceFile {
    let agent: Int
    let rel: String
    let path: String
}

private let fm = FileManager.default
private let codeExts: Set<String> = ["py", "sh", "zsh", "bash", "js", "mjs", "cjs", "ts", "json", "toml", "yaml", "yml", "plist", "swift"]
private let scriptExts: Set<String> = ["py", "sh", "zsh", "bash", "js", "mjs", "cjs", "ts", ""]
private let skipDirs: Set<String> = [".git", "node_modules", ".venv", "venv", "__pycache__", "runs", "next-runs", "state", "logs",
                                     "out", "projects", "site-packages", "data", "cache", "tmp", "build", "dist", ".wrangler"]
private let privateFolders = ["Library", "Desktop", "Documents", "Downloads", "Applications", "Pictures", "Movies", "Music"]
private let folderKinds = ["diffusion_models": "Picture or video model", "checkpoints": "Picture or video model", "unet": "Picture or video model",
                           "text_encoders": "Text reader", "clip": "Text reader", "loras": "Add-on", "vae": "Image decoder",
                           "audio_encoders": "Sound reader"]

// A real git, never the /usr/bin/git stub that asks to install developer tools.
private let gitPath: String? = ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
                                "/opt/homebrew/bin/git", "/usr/local/bin/git"].first { fm.isExecutableFile(atPath: $0) }

private func run(_ exe: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

private func getJSON(_ url: String) -> [String: Any]? {
    guard let u = URL(string: url), u.host == "127.0.0.1" || u.host == "localhost" else { return nil }  // local only
    var req = URLRequest(url: u)
    req.timeoutInterval = 3
    let done = DispatchSemaphore(value: 0)
    var result: [String: Any]?
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let data { result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
        done.signal()
    }.resume()
    _ = done.wait(timeout: .now() + 4)
    return result
}

private func size(_ path: String) -> Int64 {
    (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
}

private struct Scanner {
    let cfg: ShelfConfig
    let env: ScanEnvironment

    func expand(_ p: String) -> String { p.hasPrefix("~/") ? env.home + p.dropFirst(1) : p }

    // The path after home, whether it came in as written or with links resolved (/var is /private/var on a Mac).
    func afterHome(_ p: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let real = realpath(env.home, &buf) != nil ? String(cString: buf) : env.home  // keeps /private, unlike URL's resolve
        for h in [env.home, real] where p.hasPrefix(h + "/") { return String(p.dropFirst(h.count + 1)) }
        return nil
    }
    func tilde(_ p: String) -> String { afterHome(p).map { "~/" + $0 } ?? p }
    func key(_ p: String) -> String { afterHome(p) ?? p }

    // MARK: Model files on disk

    func hfItems(_ store: String) -> [Item] {
        let root = expand(store)
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var items: [Item] = []
        var seen = Set<String>()  // across models: two models can share one file, which is counted once
        for n in names.sorted(by: >) where n.hasPrefix("models--") {
            let snaps = root + "/" + n + "/snapshots"
            var bytes: Int64 = 0
            for rel in (fm.enumerator(atPath: snaps)?.allObjects as? [String]) ?? [] {
                let real = URL(fileURLWithPath: snaps + "/" + rel).resolvingSymlinksInPath().path
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: real, isDirectory: &isDir), !isDir.boolValue, seen.insert(real).inserted else { continue }
                bytes += size(real)
            }
            guard bytes > 1_000_000 else { continue }  // empty or unfinished downloads
            let parts = n.dropFirst("models--".count).components(separatedBy: "--")
            items.append(Item(key: key(root + "/" + n), store: tilde(root), ids: [parts.joined(separator: "/"), parts.last ?? n],
                              gb: Double(bytes) / 1e9, defaultKind: "Model"))
        }
        return items
    }

    func fileItems(_ store: String) -> [Item] {
        let root = URL(fileURLWithPath: expand(store))
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var items: [Item] = []
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { e.skipDescendants(); continue }      // links point into a store listed on its own
            if url.lastPathComponent.hasPrefix(".") { e.skipDescendants(); continue }
            // A Hugging Face cache inside a model folder (it carries CACHEDIR.TAG) belongs in hfStores, not here.
            if v?.isDirectory == true, fm.fileExists(atPath: url.appendingPathComponent("CACHEDIR.TAG").path) { e.skipDescendants(); continue }
            guard v?.isRegularFile == true, let s = v?.fileSize, s >= 5_000_000 else { continue }
            let folder = url.deletingLastPathComponent()
            items.append(Item(key: key(url.path), store: tilde(folder.path), ids: [url.lastPathComponent], gb: Double(s) / 1e9,
                              defaultKind: folderKinds[folder.lastPathComponent] ?? "Model"))
        }
        return items
    }

    func ollamaItems() -> (items: [Item], loaded: Set<String>, up: Bool) {
        guard let base = cfg.ollama else { return ([], [], true) }
        guard let models = env.fetchJSON(base + "/api/tags")?["models"] as? [[String: Any]] else { return ([], [], false) }
        let items = models.compactMap { m -> Item? in
            guard let name = m["name"] as? String else { return nil }
            let short = name.split(separator: ":").first.map(String.init) ?? name
            return Item(key: "ollama/" + name, store: "Ollama", ids: [name, short],
                        gb: ((m["size"] as? NSNumber)?.doubleValue ?? 0) / 1e9, defaultKind: "Writing")
        }
        let ps = (env.fetchJSON(base + "/api/ps")?["models"] as? [[String: Any]]) ?? []
        return (items, Set(ps.compactMap { $0["name"] as? String }), true)
    }

    // MARK: Agents: every launchd job's folder, plus every skill

    func gitRoot(_ dir: String) -> String? {
        var d = dir
        while d.hasPrefix(env.home + "/") {
            if fm.fileExists(atPath: d + "/.git") { return d }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }

    func isPrivate(_ path: String) -> Bool {
        privateFolders.contains { path.hasPrefix(env.home + "/" + $0 + "/") }
    }

    func jobRoot(_ plist: [String: Any]) -> String? {
        var candidates: [String] = []
        if let wd = plist["WorkingDirectory"] as? String { candidates.append(wd) }
        candidates += (plist["ProgramArguments"] as? [String]) ?? []
        if let p = plist["Program"] as? String { candidates.append(p) }
        for raw in candidates {
            let path = expand(raw)
            guard path.hasPrefix(env.home + "/"), !isPrivate(path) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            var dir = isDir.boolValue ? path : (path as NSString).deletingLastPathComponent
            if let g = gitRoot(dir) { return g }
            for tail in ["/.venv/bin", "/bin"] where dir.hasSuffix(tail) { dir = String(dir.dropLast(tail.count)) }
            return dir
        }
        return nil
    }

    func agents() -> [Agent] {
        let loaded = env.loadedJobs()
        let dir = env.home + "/Library/LaunchAgents"
        let skip = Set(cfg.skipAgents.map(expand))
        var byRoot: [String: Bool] = [:]
        for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
            guard let data = fm.contents(atPath: dir + "/" + f),
                  let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let root = jobRoot(p), !skip.contains(root) else { continue }
            byRoot[root] = (byRoot[root] ?? false) || loaded.contains((p["Label"] as? String) ?? "")
        }
        var list = byRoot.sorted { $0.key < $1.key }.map { root, live in
            Agent(name: cfg.agents[tilde(root)] ?? (root as NSString).lastPathComponent, root: root,
                  tag: live ? "job" : "job (not loaded)", skillName: nil)
        }
        for skills in cfg.skills.map(expand) {
            for s in ((try? fm.contentsOfDirectory(atPath: skills)) ?? []).sorted() where !s.hasPrefix(".") {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: skills + "/" + s, isDirectory: &isDir), isDir.boolValue else { continue }
                list.append(Agent(name: cfg.skillNames[s] ?? (s + " skill"), root: skills + "/" + s, tag: "skill", skillName: s))
            }
        }
        return list
    }

    func sourceFiles(_ agent: Agent, index: Int) -> [SourceFile] {
        var rels: [String] = []
        let git = gitPath == nil ? nil : gitRoot(URL(fileURLWithPath: agent.root).resolvingSymlinksInPath().path)
        let root = git == nil ? agent.root : URL(fileURLWithPath: agent.root).resolvingSymlinksInPath().path
        if let git, let gitPath {
            let prefix = root == git ? "" : String(root.dropFirst(git.count + 1)) + "/"
            rels = run(gitPath, ["-C", git, "ls-files", "-z", "--", prefix.isEmpty ? "." : prefix]).split(separator: "\0")
                .map { String($0.dropFirst(prefix.count)) }
                .filter { r in !r.split(separator: "/").dropLast().contains { skipDirs.contains(String($0)) } }
        } else if let e = fm.enumerator(atPath: root) {
            while let r = e.nextObject() as? String {
                if skipDirs.contains((r as NSString).lastPathComponent) { e.skipDescendants(); continue }
                rels.append(r)
            }
        }
        var out: [SourceFile] = []
        for rel in rels where !cfg.ignoreFiles.contains(where: { fnmatch($0, rel, 0) == 0 }) {
            let ext = (rel as NSString).pathExtension.lowercased()
            let path = root + "/" + rel
            guard codeExts.contains(ext) || ext.isEmpty else { continue }
            if ext == "json" {  // JSON is often content or data; only settings files count
                let name = (rel as NSString).lastPathComponent.lowercased()
                guard git != nil, ["config", "settings", "engine"].contains(where: name.contains) else { continue }
            }
            let s = size(path)
            guard s > 0, s < 512_000 else { continue }
            if ext.isEmpty {  // a file with no extension counts only if it is a script
                let head = FileHandle(forReadingAtPath: path).map { h in defer { try? h.close() }; return h.readData(ofLength: 2) }
                guard head == Data("#!".utf8) else { continue }
            }
            out.append(SourceFile(agent: index, rel: rel, path: path))
        }
        return out
    }

    // The fixed strings each file names. grep -o reports the longest match at each spot, so
    // "whisper-large-v3-turbo" inside "faster-whisper-large-v3-turbo" is not counted twice.
    func grep(_ patterns: [String], in files: [SourceFile]) -> [Int: Set<String>] {
        guard !patterns.isEmpty, !files.isEmpty else { return [:] }
        let patFile = NSTemporaryDirectory() + "model-shelf-\(UUID().uuidString).txt"
        guard (try? patterns.joined(separator: "\n").write(toFile: patFile, atomically: true, encoding: .utf8)) != nil else { return [:] }
        defer { try? fm.removeItem(atPath: patFile) }
        var index: [String: Int] = [:]
        for (i, f) in files.enumerated() { index[f.path] = i }
        var found: [Int: Set<String>] = [:]
        for start in stride(from: 0, to: files.count, by: 400) {
            let batch = files[start..<min(start + 400, files.count)].map(\.path)
            for line in run("/usr/bin/grep", ["-oHIF", "--null", "-f", patFile, "--"] + batch).split(separator: "\n") {
                let parts = line.split(separator: "\0", maxSplits: 1)
                guard parts.count == 2, let i = index[String(parts[0])] else { continue }
                found[i, default: []].insert(String(parts[1]))
            }
        }
        return found
    }

    // MARK: The scan

    func scan() -> Scan {
        var warnings: [String] = []
        var items = cfg.hfStores.flatMap(hfItems)
        items += cfg.fileStores.flatMap(fileItems)
        let ol = ollamaItems()
        if !ol.up { warnings.append("Ollama is not answering, so its models are not listed.") }
        items += ol.items

        let ags = agents()
        let files = ags.enumerated().flatMap { sourceFiles($0.element, index: $0.offset) }

        // Which code files name each model.
        var byId: [String: [Int]] = [:]
        for (i, it) in items.enumerated() { for id in Set(it.ids) where id.count >= 6 { byId[id, default: []].append(i) } }
        var users = Array(repeating: [User](), count: items.count)
        var direct: [(item: Int, file: Int)] = []
        for (fi, names) in grep(Array(byId.keys), in: files) { for n in names { for i in byId[n] ?? [] { direct.append((i, fi)) } } }
        var viaSkill: [(item: Int, skill: String)] = []
        var hopKeys: [String: [(item: Int, file: Int)]] = [:]
        for (i, fi) in direct {
            let f = files[fi], a = ags[f.agent]
            users[i].append(User(agent: a.name, how: (a.isSkill ? "skill script " : "names it in ") + f.rel, tag: a.tag))
            if let s = a.skillName { viaSkill.append((i, s)) }
            let parts = f.rel.split(separator: "/")
            if parts.count >= 2, scriptExts.contains((f.rel as NSString).pathExtension.lowercased()) {
                hopKeys[parts.suffix(2).joined(separator: "/"), default: []].append((i, fi))
            }
        }
        // One more hop: a job or skill that runs a script which names the model.
        for (gi, keys) in grep(Array(hopKeys.keys), in: files) {
            let a = ags[files[gi].agent]
            for key in keys {
                for (i, fi) in hopKeys[key] ?? [] where files[fi].agent != files[gi].agent {
                    users[i].append(User(agent: a.name, how: "runs \(ags[files[fi].agent].name)'s \(key)", tag: a.tag))
                    if let s = a.skillName { viaSkill.append((i, s)) }
                }
            }
        }
        // A job that runs a skill which uses the model.
        let jobFiles = files.filter { !ags[$0.agent].isSkill }
        for (gi, keys) in grep(Array(Set(viaSkill.map { "skills/" + $0.skill })), in: jobFiles) {
            let a = ags[jobFiles[gi].agent]
            for key in keys {
                let s = String(key.dropFirst("skills/".count))
                for (i, sk) in viaSkill where sk == s {
                    users[i].append(User(agent: a.name, how: "runs the \(cfg.skillNames[s] ?? s + " skill")", tag: a.tag))
                }
            }
        }

        // Group items into the models the settings describe; anything else is new.
        var claimed = Set<Int>()
        var entries: [Entry] = []
        func make(_ m: ShelfConfig.Model?, _ idx: [Int]) -> Entry {
            let its = idx.map { items[$0] }
            var seen = Set<String>()
            var us = idx.flatMap { users[$0] }.filter { seen.insert($0.agent).inserted }
            us.removeAll { (m?.notUsedBy ?? []).contains($0.agent) }
            let loaded = its.contains { $0.key.hasPrefix("ollama/") && ol.loaded.contains(String($0.key.dropFirst(7))) }
            var section = us.isEmpty ? (loaded ? "idle" : "unused") : "used"
            if let st = m?.status { section = st; if st == "unused" { us = [] } }
            let first = its[0]
            let fallbackName = first.key.hasPrefix("ollama/") ? String(first.key.dropFirst(7))
                : ((first.key as NSString).lastPathComponent.replacingOccurrences(of: "models--", with: "")
                    .replacingOccurrences(of: "--", with: "/") as NSString).deletingPathExtension
            let icons = ["Text reader": "text.alignleft", "Add-on": "puzzlepiece", "Image decoder": "photo",
                         "Sound reader": "waveform", "Writing": "text.bubble", "Picture or video model": "photo.on.rectangle"]
            return Entry(id: m?.id ?? first.key, name: m?.name ?? fallbackName, kind: m?.kind ?? first.defaultKind,
                         icon: m?.icon ?? icons[first.defaultKind] ?? "shippingbox", color: m?.color ?? "gray",
                         what: m?.what ?? "Found on disk. No description yet.", gb: its.reduce(0) { $0 + $1.gb },
                         store: first.store, users: us, section: section, loaded: loaded, isNew: m == nil, note: m?.note,
                         files: its.map(\.key))
        }
        for m in cfg.models {
            let idx = items.indices.filter { i in !claimed.contains(i) && m.match.contains { fnmatch($0, items[i].key, 0) == 0 } }
            guard !idx.isEmpty else { continue }  // not on disk any more: it drops off the shelf on its own
            claimed.formUnion(idx)
            entries.append(make(m, idx))
        }
        for i in items.indices where !claimed.contains(i) { entries.append(make(nil, [i])) }
        let order = ["used": 0, "idle": 1, "unused": 2]
        entries.sort { (order[$0.section] ?? 3, -$0.gb) < (order[$1.section] ?? 3, -$1.gb) }
        return Scan(entries: entries, at: Date(), warnings: warnings)
    }
}
