# Architecture

## Overview

One Swift package with two targets and a test target. `ShelfCore` is the scan: it finds model files, reads the code of
scheduled jobs and skills for model names, and returns a `Scan`. `ModelShelf` is the program: on a Mac a menu bar app
with a drop-down panel, on Linux and Windows a list printed in the terminal. Both run the same scan. Nothing is
stored: each scan is built fresh from the disk and, if it answers, a local Ollama.

```
settings file (optional) ──┐
model folders, Ollama ─────┼──> ShelfCore scan ──> Scan ──> menu bar panel (Mac)
scheduled jobs, skills ────┘                          ├──> --list text (default on Linux and Windows)
                                                       ├──> --scan JSON
                                                       └──> --snapshot PNG (Mac)
```

## Components

| Path | What it does |
|---|---|
| `Sources/ShelfCore/Scanner.swift` | The scan: model items, job and skill folders, code search, grouping into entries. Holds `privateFolders`, `skipDirs` and the local-only Ollama fetch. |
| `Sources/ShelfCore/Jobs.swift` | One scheduled-job reader per system, plus shared helpers: home folder, settings path, path normalizing, running a program. |
| `Sources/ShelfCore/Model.swift` | Data types: `ShelfConfig` (the settings file), `Entry`, `User`, `Scan`; size text (`gbText`) and the terminal list (`listText`). |
| `Sources/ModelShelf/App.swift` | Entry point and flags (`--help`, `--scan`, `--list`, `--snapshot`), settings loading, the menu bar item and popover, the refresh timer. |
| `Sources/ModelShelf/ShelfView.swift` | The SwiftUI panel (Mac only). See DESIGN_SYSTEM.md. |
| `Tests/ShelfCoreTests/ScannerTests.swift` | Scan tests against a fake home folder (sparse model files, launchd plists, skills), plus the Linux and Windows readers, word splitting and wildcard matching. |
| `Support/Info.plist` | App bundle settings: id `io.github.maxketamine-spec.ModelShelf`, version 1.0.0, macOS 14 or newer, no Dock icon (`LSUIElement`). |
| `scripts/` | `build-app.sh` (build and ad hoc sign the Mac app), `install.sh` (copy to `~/Applications`, add a launchd login item), `uninstall.sh`. |
| `docs/` | Demo scan (`demo-scan.json`), example settings (`shelf.example.json`, checked by a test), the README screenshot. |
| `.github/workflows/ci.yml` | Build, test and a real end-to-end find on macOS, Linux and Windows. |

## Data flow

1. **Settings.** `loadConfig` reads `shelf.json` from the system's settings folder. A missing or invalid file means
   built-in defaults (Hugging Face cache, ComfyUI and LM Studio folders, Ollama at `127.0.0.1:11434`, `~/.claude/skills`).
2. **Model items.** Hugging Face caches: each `models--*` folder, sized from its snapshot files with links resolved, so
   a file two models share counts once; under 1 MB is skipped as an unfinished download. Model folders: every regular
   file of 5 MB or more, typed by its folder (`loras`, `vae` and so on), except logs, text, Markdown, lock, CSV
   and HTML files (`notModelExts`); a folder holding a Hugging Face cache (`CACHEDIR.TAG`) is skipped. Each item keeps
   the creation date of its folder or file when the system has one. Ollama: `/api/tags` for what it holds and
   `/api/ps` for what is loaded now.
3. **Agents.** Each scheduled job becomes the folder it runs from: the first of its paths inside home and outside
   private folders, raised to its git root when there is one, never home itself. Each skill folder is an agent too.
4. **Code files.** In a git repository, `git ls-files` (when git is installed); otherwise a folder walk. Data
   folders, ignored files (`ignoreFiles`), non-code files, files of 512 KB or more and binary files are left out. One
   exception to non-code: a skill's own `SKILL.md` at its top level is read; its other Markdown is not.
5. **Name search.** An in-app fixed-string search, like `grep -o -F`: the longest name wins at each spot, and names
   shorter than 6 characters are not searched.
6. **Links.** A file that names a model makes its job or skill a user. One more step: a job that runs that script
   (matched as `/folder/file`) or runs that skill (matched as `skills/<name>/`) is a user too.
7. **Entries.** Items are grouped by the `match` patterns in the settings; anything unmatched is its own entry marked
   "New". An entry carries the settings' `tech` and `does` and the earliest creation date of its items (`added`).
   Each entry lands in `used` (shown as In use), `idle` (Resting: loaded in Ollama with no user, or set `idle`) or
   `unused` (Leftovers), sorted by size.
8. **Output and refresh.** The terminal prints one scan and stops. The Mac app scans at launch, every 15 minutes,
   and when the panel opens if the last scan is more than 5 minutes old. The scan runs in the background, one at a
   time.

## Integrations

All local. Nothing is sent off the machine.

| What | How | Where |
|---|---|---|
| Ollama | HTTP GET `/api/tags` and `/api/ps`, local host only | `Scanner.swift` |
| launchd (Mac) | Reads `~/Library/LaunchAgents/*.plist`; `launchctl list` for what is loaded | `Jobs.swift` |
| systemd and cron (Linux) | Reads `~/.config/systemd/user/*.service`; `systemctl --user list-units`; `crontab -l` | `Jobs.swift` |
| Task Scheduler (Windows) | A fixed PowerShell script (`Get-ScheduledTask`) that prints JSON, skipping Windows' own tasks | `Jobs.swift` |
| git (optional) | `git ls-files` to read only tracked files; on a Mac never the `/usr/bin/git` stub | `Scanner.swift` |
| launchd login item (Mac) | `install.sh` writes the plist with `plutil`: starts at login, restarts after a crash | `scripts/install.sh` |

Environment it reads: `HOME` (`USERPROFILE` on Windows), `APPDATA` (Windows settings), `XDG_CONFIG_HOME` (Linux
settings), `PATH` (finding git on Linux and Windows), `SystemRoot` (finding PowerShell).

## Tech stack

| Part | Choice |
|---|---|
| Language | Swift (tools version 5.9; CI on Linux and Windows uses Swift 6.4.2) |
| Build | Swift Package Manager (`Package.swift`) |
| UI | SwiftUI in an AppKit `NSStatusItem` and `NSPopover` (Mac only) |
| Core libraries | Foundation (FoundationNetworking on Linux and Windows), Dispatch |
| Tests | XCTest |
| Platforms | macOS 14+, Linux, Windows |
| CI | GitHub Actions: `macos-15`, `ubuntu-24.04` in `swift:6.4.2-noble`, `windows-latest` with `compnerd/gha-setup-swift` |
| Mac packaging | zsh scripts, `codesign` (ad hoc), `plutil`, `launchctl` |
| Third-party packages | None |

## Decision Log

| Date | Decision | Why | Alternatives considered |
|---|---|---|---|
| 2026-11-15 | Read only and local only: no writes, no job control, no network except a local Ollama, no telemetry (commit `2f8fad4`, README "Safety and privacy") | Safety and privacy: it looks through a machine's model folders and job code (README) | TBD – confirm |
| 2026-11-15 | A Mac menu bar app (status item and popover, no Dock icon), installed in `~/Applications` with a launchd login item that restarts it after a crash (commit `2f8fad4`, `scripts/install.sh`) | Always current at a glance; no admin rights needed (README) | TBD – confirm |
| 2026-11-15 | No third-party dependencies (`Package.swift` has none since commit `2f8fad4`; README "Install" since `8fc8937`) | TBD – confirm | TBD – confirm |
| 2026-11-15 | Links between jobs need whole names: a one-step link needs the whole folder name, a skill link the whole skill name; same-named job folders both show; repeated settings ids do not merge; the login item is written with `plutil` (commit `9062cb8`) | Found in review: partial names linked the wrong jobs, and unusual characters could break the login item | Matching on part of a name, which was replaced |
| 2026-11-15 | Run on Linux and Windows: one job reader per system, the name search and wildcard matching inside the app, paths joined with "/"; the panel stays Mac only and the other systems print a list (commit `8fc8937`) | The scan used Mac-only pieces | `/usr/bin/grep`, `fnmatch`, `realpath` and `NSString` paths, which were replaced |
| 2026-11-15 | A job's folder is never home itself or a hidden tool folder, and the scan writes no temporary file (commit `8fc8937`) | A job starting `~/.local/bin/uv`, or a script right in home, could make the scan read far too much. Why no temporary file: TBD – confirm | TBD – confirm |
| 2026-11-15 | CI builds, tests and runs a real end-to-end find on macOS, Linux and Windows, only while the repository is public (public-only Mac CI since commit `2f8fad4`; all three systems since `8fc8937`; `ci.yml`) | CI is the proof for systems nobody runs by hand; minutes on a private repository are billed | TBD – confirm |
| 2026-11-15 | One small folder walk instead of FileManager's enumerator (commit `3e3e517`) | CI on Linux and Windows caught a crash and a skipped-models bug in the enumerator path | FileManager's enumerator, which was replaced |
| 2026-11-16 | One root AGENTS.md; CLAUDE.md is the single line `@AGENTS.md`; SECURITY.md, ARCHITECTURE.md and DESIGN_SYSTEM.md added | One rulebook for every coding tool, and docs that move with the code | A full CLAUDE.md beside AGENTS.md (two rulebooks drift) |
| 2026-11-25 | Plain words: sections shown as In use, Resting, Leftovers (ids unchanged); optional `tech` and `does` in the settings; a new download shows the date it arrived | The owner could not tell what each model was for, or why a model sat unused | Keeping Used, Idle, Not used and technical names only |
| 2026-11-25 | A skill's own `SKILL.md` counts as code; its other Markdown does not | A skill told Claude to load a model only in its instructions, so the shelf showed that model as unused | Reading every Markdown file in a skill (its notes name models it dropped) |
| 2026-11-25 | Logs, text, Markdown, lock, CSV and HTML files in model folders are never models | A 6 MB download log showed up as a model | A size limit only; JSON is left in, since tokenizers can be large .json files |
