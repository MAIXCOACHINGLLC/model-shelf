# Rules for anyone changing Model Shelf

- The app only reads. Never add code that moves, writes or deletes files outside its own settings, or that starts or
  stops jobs. Never add network calls other than the local Ollama address, and no telemetry.
- Keep private folders and data folders out of the scan (`privateFolders`, `skipDirs` in `Sources/ShelfCore/Scanner.swift`).
- `Sources/ShelfCore` holds the scan and has no UI; test every change there in `Tests/ShelfCoreTests` against a fake
  home folder. Run `swift build`, `swift test` and, on a Mac, `./scripts/build-app.sh` before saying it works.
- It runs on macOS, Linux and Windows. Keep system-specific code behind `#if os(...)` (the job readers live in
  `Sources/ShelfCore/Jobs.swift`), join paths with "/", and call only tools the system ships (git is optional). CI on all three
  systems is the proof for the ones you cannot run.
- Screenshots and examples use made-up data only (`docs/demo-scan.json`), never a real machine's models or paths.
- Plain words in the README. One commit per change; the message says why.
