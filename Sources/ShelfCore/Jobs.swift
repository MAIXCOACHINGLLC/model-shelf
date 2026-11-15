import Foundation

// Scheduled jobs, one reader per system. A job is the folder and files it runs; the scan then reads the code there.
//   macOS    launchd agents in ~/Library/LaunchAgents
//   Linux    systemd user services in ~/.config/systemd/user, and the user's crontab
//   Windows  Task Scheduler tasks outside the \Microsoft\ folder

public struct Job: Equatable {
    public var label: String
    public var paths: [String]   // the working folder first, then the program and its arguments
    public var loaded: Bool      // switched on now

    public init(label: String, paths: [String], loaded: Bool) {
        self.label = label
        self.paths = paths
        self.loaded = loaded
    }
}

public enum Jobs {
    /// The jobs on this machine.
    public static func live(home: String) -> [Job] {
        #if os(macOS)
        let loaded = Set(run("/bin/launchctl", ["list"]).split(separator: "\n").compactMap { $0.split(separator: "\t").last.map(String.init) })
        return launchd(home: home, loaded: loaded)
        #elseif os(Windows)
        let ps = (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
        let script = Data(tasksScript.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()  // UTF-16, as -EncodedCommand wants
        return scheduledTasks(run(ps, ["-NoProfile", "-NonInteractive", "-EncodedCommand", script]), home: home)
        #else
        let units = run("/usr/bin/env", ["systemctl", "--user", "list-units", "--type=service,timer", "--state=active", "--plain", "--no-legend", "--no-pager"])
        let active = Set(units.split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) })
        return systemd(home: home, active: active) + crontab(run("/usr/bin/env", ["crontab", "-l"]), home: home)
        #endif
    }

    /// macOS: every ~/Library/LaunchAgents/*.plist. `loaded` holds the labels `launchctl list` shows.
    public static func launchd(home: String, loaded: Set<String>) -> [Job] {
        let dir = home + "/Library/LaunchAgents"
        return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().compactMap { f in
            guard f.hasSuffix(".plist"), let data = fm.contents(atPath: dir + "/" + f),
                  let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            let label = (p["Label"] as? String) ?? ""
            let paths = [p["WorkingDirectory"] as? String].compactMap { $0 } + ((p["ProgramArguments"] as? [String]) ?? [])
                + [p["Program"] as? String].compactMap { $0 }
            return Job(label: label, paths: paths, loaded: loaded.contains(label))
        }
    }

    /// Linux: every ~/.config/systemd/user/*.service. A service counts as on when it, or its timer, is active.
    public static func systemd(home: String, active: Set<String>) -> [Job] {
        let dir = home + "/.config/systemd/user"
        return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().compactMap { f in
            guard f.hasSuffix(".service"), let text = try? String(contentsOfFile: dir + "/" + f, encoding: .utf8) else { return nil }
            let name = String(f.dropLast(".service".count))
            var dirs: [String] = [], exec: [String] = []
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("WorkingDirectory=") {
                    dirs.append(String(line.dropFirst("WorkingDirectory=".count).drop { $0 == "-" }))
                } else if line.hasPrefix("ExecStart=") {
                    exec += words(String(line.dropFirst("ExecStart=".count).drop { "@-:+!".contains($0) }))
                }
            }
            let paths = (dirs + exec).map { expandHome($0.replacingOccurrences(of: "%h", with: home), home: home) }
            return Job(label: name, paths: paths, loaded: active.contains(f) || active.contains(name + ".timer"))
        }
    }

    /// Linux: each schedule line of `crontab -l`. Comments and variable lines are skipped.
    public static func crontab(_ text: String, home: String) -> [Job] {
        text.split(whereSeparator: \.isNewline).enumerated().compactMap { n, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            var w = words(line)
            let special = w.first?.hasPrefix("@") == true           // @daily, @reboot and the like replace the five time fields
            if !special, w.first?.contains("=") == true { return nil }  // NAME=value sets a variable
            w.removeFirst(min(w.count, special ? 1 : 5))
            guard !w.isEmpty else { return nil }
            return Job(label: "crontab line \(n + 1)", paths: w.map { expandHome($0, home: home) }, loaded: true)
        }
    }

    /// Windows: the JSON `tasksScript` prints, one row per task action.
    public static func scheduledTasks(_ json: String, home: String) -> [Job] {
        guard let rows = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let exe = r["exe"] as? String else { return nil }
            let fix = { (s: String) in  // Task Scheduler writes Windows paths; make them forward-slash paths in home
                s.replacingOccurrences(of: "%USERPROFILE%", with: home, options: .caseInsensitive).replacingOccurrences(of: "\\", with: "/")
            }
            let paths = [r["dir"] as? String].compactMap { $0 }.map(fix) + words(fix(exe)) + words(fix((r["args"] as? String) ?? ""))
            return Job(label: (r["name"] as? String) ?? "", paths: paths, loaded: (r["state"] as? String) != "Disabled")
        }
    }

    /// Splits a command line into words, keeping quoted parts together: `python "my dir/run.py"` is two words.
    public static func words(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, inWord = false, escaped = false
        for c in line {
            if escaped { cur.append(c); escaped = false; continue }
            if c == "\\", quote != "'" { escaped = true; inWord = true; continue }
            if let q = quote { if c == q { quote = nil } else { cur.append(c) }; continue }
            if c == "\"" || c == "'" { quote = c; inWord = true; continue }
            if c == " " || c == "\t" {
                if inWord { out.append(cur); cur = ""; inWord = false }
                continue
            }
            cur.append(c)
            inWord = true
        }
        if inWord { out.append(cur) }
        return out
    }

    // Task actions as JSON, leaving out Windows' own tasks.
    static let tasksScript = """
        $rows = foreach ($t in Get-ScheduledTask) {
          if ($t.TaskPath -like '\\Microsoft\\*') { continue }
          foreach ($a in $t.Actions) {
            if ($a.Execute) {
              [pscustomobject]@{ name = $t.TaskName; state = [string]$t.State; exe = $a.Execute; args = $a.Arguments; dir = $a.WorkingDirectory }
            }
          }
        }
        ConvertTo-Json -Compress -InputObject @($rows)
        """
}

/// `~/x`, `$HOME/x` and `${HOME}/x` written out in full.
func expandHome(_ word: String, home: String) -> String {
    let w = word.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
    return w == "~" ? home : (w.hasPrefix("~/") ? home + w.dropFirst(1) : w)
}

let fm = FileManager.default

/// Forward slashes on Windows, so every path is compared and joined one way. Windows accepts them.
func norm(_ path: String) -> String {
    #if os(Windows)
    return path.replacingOccurrences(of: "\\", with: "/")
    #else
    return path
    #endif
}

/// A file URL as a plain path on this system.
func pathOf(_ url: URL) -> String {
    #if os(Windows)
    return norm(url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path)
    #else
    return url.path
    #endif
}

/// The home folder: $HOME (USERPROFILE on Windows), as shells and git see it.
public func homeFolder() -> String {
    #if os(Windows)
    let name = "USERPROFILE"
    #else
    let name = "HOME"
    #endif
    if let p = ProcessInfo.processInfo.environment[name], !p.isEmpty { return norm(p) }
    return pathOf(fm.homeDirectoryForCurrentUser)
}

/// Where the settings file lives on this system.
public func settingsPath(home: String = homeFolder()) -> String {
    #if os(macOS)
    return home + "/Library/Application Support/Model Shelf/shelf.json"
    #elseif os(Windows)
    return norm(ProcessInfo.processInfo.environment["APPDATA"] ?? home + "/AppData/Roaming") + "/Model Shelf/shelf.json"
    #else
    let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? ""
    return (xdg.isEmpty ? home + "/.config" : xdg) + "/model-shelf/shelf.json"
    #endif
}

/// Runs a program and returns what it prints, or "" if it cannot run.
func run(_ exe: String, _ args: [String]) -> String {
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
