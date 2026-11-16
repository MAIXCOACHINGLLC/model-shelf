# Security

Model Shelf looks through a computer's model folders and the code of its scheduled jobs and skills. That is private
ground, so the rules below are the product as much as the code is. The short version: it only reads, it stays on the
machine, and it keeps nothing but file paths.

## Secrets

- The app has no keys, tokens, passwords or accounts, and needs none to build, test or run.
- Never commit a secret, a real settings file or real scan output. A gitleaks scan of the full git history on
  2026-11-16 found nothing.
- The settings file (`shelf.json`, path from `ModelShelf --help`) holds folder paths, names and descriptions only. It
  lives outside the repository.

## Auth and permissions

- No login and no accounts. It runs as the user who starts it and never asks for admin rights.
- The Mac install (`scripts/install.sh`) writes only inside the home folder: the app in `~/Applications` and a launchd
  login item in `~/Library/LaunchAgents`. `scripts/uninstall.sh` removes both and leaves the settings file.
- `scripts/build-app.sh` signs the app ad hoc for the Mac that built it. It is not signed with a developer ID or
  notarized.

## Input validation

- **Settings file.** Every field is optional. A file that is not valid JSON is ignored with a note on standard error,
  and the defaults are used.
- **Ollama.** The only network call. `getJSON` in `Sources/ShelfCore/Scanner.swift` refuses any host other than
  `127.0.0.1` or `localhost`, and gives up after a few seconds.
- **Files it reads.** Only code files (scripts and settings, by extension), under 512 KB; a file with a zero byte is
  treated as binary and skipped; a file with no extension counts only if it starts with `#!`. JSON counts only for
  settings-like names inside a git repository. Folder walks skip links and hidden names.
- **Job definitions.** Only paths inside the home folder and outside private folders are used. A job's folder is never
  home itself or a hidden tool folder such as `~/.local`.
- **Programs it runs.** Fixed programs with argument lists, never a shell line built from file content:
  `launchctl list` (Mac), `systemctl --user list-units` and `crontab -l` (Linux), a fixed PowerShell script that lists
  scheduled tasks (Windows), and `git ls-files` when git is installed. Nothing it finds is ever run.
- **`--snapshot` with a scan file.** A file that cannot be read as a scan stops the program with an error.

## Data handling and privacy

- **Read only.** It never moves, changes or deletes a file and never starts or stops a job. The scan writes no
  temporary files. Results stay in memory; `--scan` and `--list` print to the terminal.
- **Local only.** Nothing leaves the machine. No telemetry, no accounts, no update checks.
- **Private folders are skipped.** No code is read in `Desktop`, `Documents`, `Downloads`, `Pictures`, `Movies`,
  `Music`, `Videos`, `Library`, `AppData`, `Applications`, `Public` or `snap`, in hidden folders, or in data folders
  such as `data`, `state`, `logs`, `runs`, `out`, `cache` (`privateFolders` and `skipDirs` in `Scanner.swift`). In a
  git repository only tracked files are read. Model folders named in the settings are listed, not read.
- **It keeps paths, not contents.** The scan looks only for model names and keeps only the paths of matching files.
- **Personal data.** A real scan holds a machine's folder paths and job names, which can include a user name. Never put
  one in an issue, a commit, a test or a screenshot; use `docs/demo-scan.json` and fake home folders. Model Shelf has
  no reason to see health or other sensitive personal data, and the folder rules above keep it out of the scan.

## Dependencies

- No third-party Swift packages: only the system libraries (Foundation, AppKit, SwiftUI, XCTest). Adding one is a recorded decision
  (ARCHITECTURE.md Decision Log) and must keep the read-only, local-only promise.
- CI pins its outside pieces: `actions/checkout@v4`, `compnerd/gha-setup-swift@v0.5.1`, the `swift:6.4.2-noble`
  container and Swift 6.4.2 on Windows. A pin moves like any other change: one commit, and the message says why.

## Reporting a problem

Please do not post security details in a public issue. GitHub private vulnerability reporting is off for this
repository. TBD – confirm a private channel. Until then, open an issue that says only that you have a security problem
to report, and wait for the maintainer (maxketamine-spec) to reply.
