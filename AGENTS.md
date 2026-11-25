# Rules for anyone changing Model Shelf

This is the one rulebook for people and every coding assistant (Claude Code, Codex, Cursor, Gemini and others).
`CLAUDE.md` only points here. Do not add a second rules file.

## What it is

Model Shelf shows every local AI model on a computer: its size, what it does, and which scheduled jobs and Claude
Code skills use it. On a Mac it is a menu bar app that keeps itself current. On Linux and Windows the same scan prints a
list in the terminal. It only reads. Public repository, MIT license. How it works: [ARCHITECTURE.md](ARCHITECTURE.md).
The panel's look: [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md). Safety and privacy rules: [SECURITY.md](SECURITY.md).

## Setup, build, test, lint

Needs Git and Swift 5.9 or newer. On a Mac: macOS 14 or newer and Xcode or the Command Line Tools. No other
dependencies, no keys, no network.

```bash
swift build                 # debug build
swift test                  # scanner tests against a fake home folder
./scripts/build-app.sh      # Mac only: builds "build/Model Shelf.app", signed ad hoc
swift build -c release      # Linux and Windows: then run .build/release/ModelShelf
```

Run the program (on a Mac it is `"build/Model Shelf.app/Contents/MacOS/ModelShelf"`):

```bash
ModelShelf --list                                    # the list as text
ModelShelf --scan                                    # one scan as JSON
ModelShelf --snapshot out.png [model-id] [scan.json] # Mac: the panel as a picture
ModelShelf --help                                    # prints the settings file path
```

`./scripts/install.sh` copies the app to `~/Applications` and adds a login item; `./scripts/uninstall.sh` removes both.
They change the machine, so run them only when asked.

Lint: no linter or formatter is set up (no SwiftLint or swift-format config). TBD – confirm whether one is wanted.
Until then, a clean `swift build` with no new warnings is the bar.

## Code style

- Swift, 4-space indent. Match the file you are in: long lines are fine, short local names, `// MARK:` sections.
- `///` comments on public types and functions; plain-word comments that say why, not what.
- `Sources/ShelfCore` has no UI. The panel (SwiftUI and AppKit) lives in `Sources/ModelShelf` behind `#if os(macOS)`.
- Paths are joined and compared with "/" through the helpers in `Jobs.swift` (`norm`, `pathOf`) and `Scanner.swift`
  (`parent`, `lastPart`).
- Words people see (panel, list, README) are plain: "Leftovers", "Check again", "Reading the disk".

## Project rules

- The app only reads. Never add code that moves, writes or deletes files outside its own settings, or that starts or
  stops jobs. Never add network calls other than the local Ollama address, and no telemetry.
- Keep private folders and data folders out of the scan (`privateFolders`, `skipDirs` in `Sources/ShelfCore/Scanner.swift`).
- `Sources/ShelfCore` holds the scan and has no UI; test every change there in `Tests/ShelfCoreTests` against a fake
  home folder. Run `swift build`, `swift test` and, on a Mac, `./scripts/build-app.sh` before saying it works.
- It runs on macOS, Linux and Windows. Keep system-specific code behind `#if os(...)` (the job readers live in
  `Sources/ShelfCore/Jobs.swift`), join paths with "/", and call only tools the system ships (git is optional). CI on all
  three systems is the proof for the ones you cannot run.
- Screenshots and examples use made-up data only (`docs/demo-scan.json`), never a real machine's models or paths.
- Plain words in the README. One commit per change; the message says why.

## Dev workflow

1. Branch from an up-to-date `main`.
2. Make the change. A change to the scan comes with a test in `Tests/ShelfCoreTests/ScannerTests.swift`, built on the
   fake home helpers there (`model`, `write`, `job`, `hfRepo`).
3. Run `swift build` and `swift test`; on a Mac also `./scripts/build-app.sh`.
4. A change to the panel: redraw the screenshot from the demo data and look at it, for example
   `"build/Model Shelf.app/Contents/MacOS/ModelShelf" --snapshot docs/screenshot.png whisper docs/demo-scan.json`.
5. Update the README when what a user sees or sets changes, and the living docs below.
6. Push and open a pull request. CI ("Build and test", `.github/workflows/ci.yml`) builds, tests and runs a real find
   on macOS, Linux and Windows. It runs only while the repository is public.

## Git conventions

- One commit per change. The title says what changed in plain words; the body says why.
- Add files by path, never `git add -A`.
- Branch names are short and say what the change is (for example `docs/agent-standards`). The first commits went
  straight to `main`; TBD – confirm whether `main` takes changes only through pull requests.
- Never rewrite published history.

## Do and don't

| Do | Don't |
|---|---|
| Keep the scan read only and local only | Add writes, deletes, job control, network calls or telemetry |
| Test scan changes against a fake home folder | Test against, or commit, a real machine's models, paths or jobs |
| Keep system-specific code behind `#if os(...)` | Call a tool the system does not ship, or assume a Mac |
| Use made-up data in docs and screenshots | Paste real scan output into an issue, commit or doc |
| Keep the README's promise of no other dependencies | Add a package without a README update and a Decision Log row |
| Run build, tests and (on a Mac) build-app before saying it works | Take a green CI run as proof that a screen looks right |

## Living docs

Any change to architecture, dependencies, security, or UI must update ARCHITECTURE.md, SECURITY.md, or DESIGN_SYSTEM.md in the same commit.
