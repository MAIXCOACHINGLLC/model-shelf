import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux and Windows
#endif

// The scan. Read only: it lists model files, reads job and skill code for model names, and asks a local Ollama what
// it holds. It never writes, moves or deletes anything, and it skips data folders and private folders.

/// What the scan needs from the machine. `live` is this computer; tests pass a fake home and fake answers.
public struct ScanEnvironment {
    public var home: String
    public var jobs: () -> [Job]                             // scheduled jobs (Jobs.swift)
    public var fetchJSON: (String) -> [String: Any]?         // GET a local URL and parse JSON

    public init(home: String, jobs: @escaping () -> [Job], fetchJSON: @escaping (String) -> [String: Any]?) {
        self.home = home
        self.jobs = jobs
        self.fetchJSON = fetchJSON
    }

    public static var live: ScanEnvironment {
        let home = homeFolder()
        return ScanEnvironment(home: home, jobs: { Jobs.live(home: home) }, fetchJSON: getJSON)
    }
}

public func runScan(config: ShelfConfig, env: ScanEnvironment = .live) -> Scan {
    Scanner(cfg: config, env: env, realHome: realPath(env.home)).scan()
}

/// The path with links resolved, keeping /private on a Mac (URL's resolve drops it).
private func realPath(_ p: String) -> String {
    #if os(Windows)
    return pathOf(URL(fileURLWithPath: p).resolvingSymlinksInPath())
    #else
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    return realpath(p, &buf) != nil ? String(cString: buf) : p
    #endif
}

private func resolved(_ p: String) -> String { pathOf(URL(fileURLWithPath: p).resolvingSymlinksInPath()) }

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

private let codeExts: Set<String> = ["py", "sh", "zsh", "bash", "js", "mjs", "cjs", "ts", "json", "toml", "yaml", "yml", "plist", "swift"]
private let scriptExts: Set<String> = ["py", "sh", "zsh", "bash", "js", "mjs", "cjs", "ts", ""]
private let skipDirs: Set<String> = [".git", "node_modules", ".venv", "venv", "__pycache__", "runs", "next-runs", "state", "logs",
                                     "out", "projects", "site-packages", "data", "cache", "tmp", "build", "dist", ".wrangler"]
// Folders in home whose code is never read, compared in lower case (Mac and Windows names ignore case). Hidden
// folders (".config", ".local") are skipped too.
private let privateFolders: Set<String> = ["library", "desktop", "documents", "downloads", "applications", "pictures", "movies", "music",
                                           "videos", "public", "appdata", "snap"]
private let folderKinds = ["diffusion_models": "Picture or video model", "checkpoints": "Picture or video model", "unet": "Picture or video model",
                           "text_encoders": "Text reader", "clip": "Text reader", "loras": "Add-on", "vae": "Image decoder",
                           "audio_encoders": "Sound reader"]

// A real git. On a Mac never /usr/bin/git, a stub that asks to install developer tools; elsewhere the one on PATH.
private let gitPath: String? = {
    #if os(macOS)
    let candidates = ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
                      "/opt/homebrew/bin/git", "/usr/local/bin/git"]
    #else
    #if os(Windows)
    let (sep, exe): (Character, String) = (";", "git.exe")
    #else
    let (sep, exe): (Character, String) = (":", "git")
    #endif
    let path = ProcessInfo.processInfo.environment.first { $0.key.uppercased() == "PATH" }?.value ?? ""
    let candidates = path.split(separator: sep).map { norm(String($0)) + "/" + exe }
    #endif
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}()

// Path pieces with "/" only, the same on every system (paths are normalized first).
private func parent(_ p: String) -> String { p.lastIndex(of: "/").map { String(p[..<$0]) } ?? "" }
private func lastPart(_ p: String) -> String { p.split(separator: "/").last.map(String.init) ?? p }
private func ext(_ p: String) -> String {
    let n = lastPart(p)
    guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return "" }
    return n[n.index(after: dot)...].lowercased()
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

// A regular file's size; 0 for a folder, a link or anything else.
private func size(_ path: String) -> Int64 {
    guard let a = try? fm.attributesOfItem(atPath: path), a[.type] as? FileAttributeType == .typeRegular else { return 0 }
    return (a[.size] as? NSNumber)?.int64Value ?? 0
}

// Every regular file under dir, as a path from dir with its size. Skips hidden names and links; goes into a folder
// only if `enter` says so. Written out instead of FileManager's enumerator, whose skipping differs on Windows.
private func walk(_ dir: String, _ rel: String = "", enter: (String) -> Bool, into out: inout [(rel: String, size: Int64)]) {
    for name in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !name.hasPrefix(".") {
        let path = dir + "/" + name, r = rel.isEmpty ? name : rel + "/" + name
        guard let a = try? fm.attributesOfItem(atPath: path), let type = a[.type] as? FileAttributeType else { continue }
        if type == .typeDirectory, enter(path) { walk(path, r, enter: enter, into: &out) }
        if type == .typeRegular { out.append((r, (a[.size] as? NSNumber)?.int64Value ?? 0)) }
    }
}

private struct Scanner {
    let cfg: ShelfConfig
    let env: ScanEnvironment
    let realHome: String                 // home with links resolved (/var is /private/var on a Mac)

    func expand(_ p: String) -> String { norm(p.hasPrefix("~/") ? env.home + p.dropFirst(1) : p) }

    // The path after home, whether it came in as written or with links resolved. Windows paths ignore case.
    func afterHome(_ p: String) -> String? {
        for h in [env.home, realHome] {
            #if os(Windows)
            let hit = p.lowercased().hasPrefix(h.lowercased() + "/")
            #else
            let hit = p.hasPrefix(h + "/")
            #endif
            if hit { return String(p.dropFirst(h.count + 1)) }
        }
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
                let real = resolved(snaps + "/" + norm(rel))
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
        let root = expand(store)
        // Links point into a store listed on its own. A Hugging Face cache inside a model folder (it carries
        // CACHEDIR.TAG) belongs in hfStores, not here.
        var found: [(rel: String, size: Int64)] = []
        walk(root, enter: { !fm.fileExists(atPath: $0 + "/CACHEDIR.TAG") }, into: &found)
        return found.filter { $0.size >= 5_000_000 }.map { f in
            let path = root + "/" + f.rel, folder = parent(path)
            return Item(key: key(path), store: tilde(folder), ids: [lastPart(path)], gb: Double(f.size) / 1e9,
                        defaultKind: folderKinds[lastPart(folder)] ?? "Model")
        }
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

    // MARK: Agents: every scheduled job's folder, plus every skill

    func gitRoot(_ dir: String) -> String? {
        var d = dir
        while afterHome(d) != nil {  // stops before home itself
            if fm.fileExists(atPath: d + "/.git") { return d }
            d = parent(d)
        }
        return nil
    }

    // Inside a private folder or a hidden one, such as ~/.local, where tools keep their programs.
    func isPrivate(_ path: String) -> Bool {
        guard let top = afterHome(path)?.split(separator: "/").first.map(String.init) else { return false }
        return top.hasPrefix(".") || privateFolders.contains(top.lowercased())
    }

    // The folder a job runs from: the first of its paths that is inside home and not private.
    func jobRoot(_ job: Job) -> String? {
        for raw in job.paths {
            let path = expand(raw)
            guard afterHome(path) != nil, !isPrivate(path) else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            var dir = isDir.boolValue ? path : parent(path)
            if let g = gitRoot(dir) { return g }
            for tail in ["/.venv/bin", "/.venv/Scripts", "/bin"] where dir.hasSuffix(tail) { dir = String(dir.dropLast(tail.count)) }
            guard afterHome(dir) != nil else { continue }  // never all of home, as for ~/run.sh or ~/bin/run.sh
            return dir
        }
        return nil
    }

    func agents() -> [Agent] {
        let skip = Set(cfg.skipAgents.map(expand))
        var byRoot: [String: Bool] = [:]
        for job in env.jobs() {
            guard let root = jobRoot(job), !skip.contains(root) else { continue }
            byRoot[root] = (byRoot[root] ?? false) || job.loaded
        }
        var list = byRoot.sorted { $0.key < $1.key }.map { root, live in
            Agent(name: cfg.agents[tilde(root)] ?? lastPart(root), root: root,
                  tag: live ? "job" : "job (not loaded)", skillName: nil)
        }
        // Two job folders with the same name: show where each one is, so neither hides the other.
        let counts = Dictionary(grouping: list, by: \.name).mapValues(\.count)
        list = list.map { counts[$0.name, default: 0] > 1 ? Agent(name: "\($0.name) (\(tilde($0.root)))", root: $0.root, tag: $0.tag, skillName: nil) : $0 }
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
        let git = gitPath == nil ? nil : gitRoot(resolved(agent.root))
        let root = git == nil ? agent.root : resolved(agent.root)
        if let git, let gitPath {
            let prefix = root == git ? "" : String(root.dropFirst(git.count + 1)) + "/"
            rels = run(gitPath, ["-C", git, "ls-files", "-z", "--", prefix.isEmpty ? "." : prefix]).split(separator: "\0")
                .map { String($0.dropFirst(prefix.count)) }
                .filter { r in !r.split(separator: "/").dropLast().contains { skipDirs.contains(String($0)) } }
        } else {
            var found: [(rel: String, size: Int64)] = []
            walk(root, enter: { !skipDirs.contains(lastPart($0)) }, into: &found)
            rels = found.map(\.rel)
        }
        var out: [SourceFile] = []
        for rel in rels where !cfg.ignoreFiles.contains(where: { glob($0, rel) }) {
            let fileExt = ext(rel)
            let path = root + "/" + rel
            guard codeExts.contains(fileExt) || fileExt.isEmpty else { continue }
            if fileExt == "json" {  // JSON is often content or data; only settings files count
                let name = lastPart(rel).lowercased()
                guard git != nil, ["config", "settings", "engine"].contains(where: name.contains) else { continue }
            }
            let s = size(path)
            guard s > 0, s < 512_000 else { continue }
            if fileExt.isEmpty {  // a file with no extension counts only if it is a script
                let head = FileHandle(forReadingAtPath: path).map { h in defer { try? h.close() }; return h.readData(ofLength: 2) }
                guard head == Data("#!".utf8) else { continue }
            }
            out.append(SourceFile(agent: index, rel: rel, path: path))
        }
        return out
    }

    // The fixed strings each file names, found the way `grep -o -F` finds them: at each spot the longest one wins and
    // the search goes on after it, so "whisper-large-v3-turbo" inside "faster-whisper-large-v3-turbo" is not counted.
    // A file with a zero byte is binary and skipped.
    func grep(_ patterns: [String], in files: [SourceFile]) -> [Int: Set<String>] {
        let names = patterns.filter { $0.utf8.count >= 2 }
        guard !names.isEmpty, !files.isEmpty else { return [:] }
        let pats = names.map { Array($0.utf8) }
        var byStart = [[Int]](repeating: [], count: 65536)  // patterns by their first two bytes, longest first
        for i in pats.indices.sorted(by: { pats[$0].count > pats[$1].count }) { byStart[Int(pats[i][0]) << 8 | Int(pats[i][1])].append(i) }
        let starts = byStart.map { !$0.isEmpty }
        var found: [Int: Set<String>] = [:]
        for (fi, f) in files.enumerated() {
            guard let data = fm.contents(atPath: f.path) else { continue }
            let hits: Set<Int> = data.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: UInt8.self)
                guard !b.contains(0) else { return [] }
                var hits = Set<Int>(), i = 0
                while i + 1 < b.count {
                    let k = Int(b[i]) << 8 | Int(b[i + 1])
                    var step = 1
                    if starts[k] {
                        for pi in byStart[k] where i + pats[pi].count <= b.count {
                            let p = pats[pi]
                            var j = 2
                            while j < p.count, b[i + j] == p[j] { j += 1 }
                            if j == p.count { hits.insert(pi); step = p.count; break }
                        }
                    }
                    i += step
                }
                return hits
            }
            if !hits.isEmpty { found[fi] = Set(hits.map { names[$0] }) }
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
            if parts.count >= 2, scriptExts.contains(ext(f.rel)) {
                hopKeys["/" + parts.suffix(2).joined(separator: "/"), default: []].append((i, fi))  // "/tools/tts.py", not "mytools/tts.py"
            }
        }
        // One more hop: a job or skill that runs a script which names the model.
        for (gi, keys) in grep(Array(hopKeys.keys), in: files) {
            let a = ags[files[gi].agent]
            for key in keys {
                for (i, fi) in hopKeys[key] ?? [] where files[fi].agent != files[gi].agent {
                    users[i].append(User(agent: a.name, how: "runs \(ags[files[fi].agent].name)'s \(key.dropFirst())", tag: a.tag))
                    if let s = a.skillName { viaSkill.append((i, s)) }
                }
            }
        }
        // A job that runs a skill which uses the model.
        let jobFiles = files.filter { !ags[$0.agent].isSkill }
        for (gi, keys) in grep(Array(Set(viaSkill.map { "skills/" + $0.skill + "/" })), in: jobFiles) {  // "video/" is not "video-skills/"
            let a = ags[jobFiles[gi].agent]
            for key in keys {
                let s = String(key.dropFirst("skills/".count).dropLast())
                for (i, sk) in viaSkill where sk == s {
                    users[i].append(User(agent: a.name, how: "runs the \(cfg.skillNames[s] ?? s + " skill")", tag: a.tag))
                }
            }
        }

        // Group items into the models the settings describe; anything else is new.
        var claimed = Set<Int>()
        var entries: [Entry] = []
        var usedIds = Set<String>()
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
                : withoutExt(lastPart(first.key).replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "--", with: "/"))
            let icons = ["Text reader": "text.alignleft", "Add-on": "puzzlepiece", "Image decoder": "photo",
                         "Sound reader": "waveform", "Writing": "text.bubble", "Picture or video model": "photo.on.rectangle"]
            var id = m?.id ?? first.key
            while !usedIds.insert(id).inserted { id += "+" }  // a repeated id in the settings must not merge two rows
            return Entry(id: id, name: m?.name ?? fallbackName, kind: m?.kind ?? first.defaultKind,
                         icon: m?.icon ?? icons[first.defaultKind] ?? "shippingbox", color: m?.color ?? "gray",
                         what: m?.what ?? "Found on disk. No description yet.", gb: its.reduce(0) { $0 + $1.gb },
                         store: first.store, users: us, section: section, loaded: loaded, isNew: m == nil, note: m?.note,
                         files: its.map(\.key))
        }
        for m in cfg.models {
            let idx = items.indices.filter { i in !claimed.contains(i) && m.match.contains { glob($0, items[i].key) } }
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

// "pic-model-q4.gguf" without ".gguf". A name that is only an extension stays as it is.
private func withoutExt(_ name: String) -> String {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
    return String(name[..<dot])
}

/// Shell-style wildcards, like fnmatch(3) with no flags: `*` matches any run of characters (slashes too), `?` any one,
/// `[abc]` or `[a-z]` one of a set, `[!abc]` one not in it, and a backslash makes the next character plain.
func glob(_ pattern: String, _ text: String) -> Bool {
    let p = Array(pattern.unicodeScalars), t = Array(text.unicodeScalars)
    var pi = 0, ti = 0, star = -1, starT = 0
    while ti < t.count {
        if pi < p.count, p[pi] == "*" { star = pi; starT = ti; pi += 1; continue }
        if pi < p.count, let next = matchOne(p, pi, t[ti]) { pi = next; ti += 1; continue }
        guard star >= 0 else { return false }
        pi = star + 1; starT += 1; ti = starT  // let the last * take one more character
    }
    while pi < p.count, p[pi] == "*" { pi += 1 }
    return pi == p.count
}

// If the pattern piece at i matches c, the index after that piece.
private func matchOne(_ p: [Unicode.Scalar], _ i: Int, _ c: Unicode.Scalar) -> Int? {
    switch p[i] {
    case "?":
        return i + 1
    case "\\" where i + 1 < p.count:
        return p[i + 1] == c ? i + 2 : nil
    case "[":
        var j = i + 1, hit = false
        let negate = j < p.count && (p[j] == "!" || p[j] == "^")
        if negate { j += 1 }
        let first = j
        while j < p.count, p[j] != "]" || j == first {  // a ] right after [ is a plain ]
            if j + 2 < p.count, p[j + 1] == "-", p[j + 2] != "]" {
                if p[j] <= c && c <= p[j + 2] { hit = true }
                j += 3
            } else {
                if p[j] == c { hit = true }
                j += 1
            }
        }
        guard j < p.count else { return p[i] == c ? i + 1 : nil }  // no closing ]: a plain [
        return hit != negate ? j + 1 : nil
    default:
        return p[i] == c ? i + 1 : nil
    }
}
