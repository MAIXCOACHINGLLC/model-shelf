# Model Shelf

A small app that shows every AI model on your computer: how much space each one takes, what it does, and which of
your scheduled jobs and Claude Code skills actually use it. It only reads.

On a Mac it lives in the menu bar and keeps itself current. On Linux and Windows the same scan runs in a terminal and
prints the list.

<img src="docs/screenshot.png" alt="Model Shelf panel open under its menu bar icon, with Whisper expanded to show the jobs that use it" width="420">

*The screenshot uses made-up demo data (`docs/demo-scan.json`).*

## Why

Local models pile up. A few months of trying image, video, voice and text models leaves a hundred or more gigabytes
in caches, and nobody remembers which ones still matter. Model Shelf answers three questions at a glance:

- **What do I have?** Hugging Face caches, ComfyUI and LM Studio model folders, and Ollama, with real sizes (files
  shared between models are counted once).
- **What uses it?** It reads the code of every scheduled job and every skill in `~/.claude/skills`, and lists each job
  or skill that names a model. It follows one step further: a job that runs a script or a skill which names the model
  counts too. Scheduled jobs are launchd agents on a Mac, systemd user services and the crontab on Linux, and Task
  Scheduler tasks on Windows.
- **What can go?** Models nothing uses are grouped under "Not used". Ollama models in memory right now are marked
  "Loaded".

On a Mac it checks again every 15 minutes, and when you open it if the last check is more than 5 minutes old. A new
model shows up on its own, marked "New". A new job that uses a model shows up under it. A removed model drops off.

## Safety and privacy

- **Read only.** It never moves, changes or deletes a file, and it never stops or starts a job.
- **No network**, except asking a local Ollama (`127.0.0.1`) what it holds. No telemetry, no accounts, no updates.
- **Skips private and data folders.** It reads no code in your personal folders (`Desktop`, `Documents`, `Downloads`,
  `Pictures`, `Movies`, `Music`, `Videos`, `Library`, `AppData`) or in hidden folders such as `~/.local`, and none in
  folders named `data`, `state`, `logs`, `runs`, `out`, `cache` and the like. In a git repository it reads only
  tracked files. It reads only code files (scripts, settings), never JSON outside settings files, and only looks for
  model names; it keeps nothing but the matching file paths. Model folders you name in the settings are listed, not
  read.
- **No admin rights.** It runs as you, and the Mac install goes in your home folder.

## Install

All three need Git and Swift 5.9 or newer. Nothing else: the app has no other dependencies.

### Mac (menu bar app)

Needs macOS 14 or newer and Xcode or the Command Line Tools (`xcode-select --install`), which include Git and Swift.

```bash
git clone https://github.com/maxketamine-spec/model-shelf.git
cd model-shelf
./scripts/install.sh
```

The stack icon appears in the menu bar. It starts at login and comes back if it crashes; **Quit** keeps it closed until
the next login. To remove it: `./scripts/uninstall.sh`.

### Linux (terminal)

Install Swift from [swift.org/install](https://www.swift.org/install/linux/), then:

```bash
git clone https://github.com/maxketamine-spec/model-shelf.git
cd model-shelf
swift build -c release
.build/release/ModelShelf
```

### Windows (terminal)

Install Swift from [swift.org/install](https://www.swift.org/install/windows/) (that page also installs the Visual
Studio parts Swift needs) and [Git](https://git-scm.com/downloads/win). Then, in PowerShell:

```powershell
git clone https://github.com/maxketamine-spec/model-shelf.git
cd model-shelf
swift build -c release
.build\release\ModelShelf.exe
```

On Linux and Windows it prints the list and stops. Run it again whenever you want a fresh look.

## Settings

Optional. Without a settings file it looks in `~/.cache/huggingface/hub`, `~/ComfyUI/models`,
`~/Documents/ComfyUI/models` (the ComfyUI app), `~/.lmstudio/models`, Ollama at `127.0.0.1:11434`, and skills in
`~/.claude/skills`. `~` is your home folder on every system. To change that, or to describe your models, create the
settings file. Every field is optional; see [`docs/shelf.example.json`](docs/shelf.example.json).

| System | Settings file |
|---|---|
| Mac | `~/Library/Application Support/Model Shelf/shelf.json` |
| Linux | `~/.config/model-shelf/shelf.json` (or under `$XDG_CONFIG_HOME`) |
| Windows | `%APPDATA%\Model Shelf\shelf.json` |

`ModelShelf --help` prints the path on your computer.

| Field | What it does |
|---|---|
| `hfStores` | Hugging Face cache folders (the `hub` folder). |
| `fileStores` | Folders of loose model files, such as ComfyUI's `models`. Files of 5 MB or more count. |
| `ollama` | Ollama's address, or `null` to skip it. |
| `skills` | Folders of Claude Code skills. |
| `agents` | Friendly names for job folders, e.g. `{"~/agents/video": "Video maker"}`. |
| `skillNames` | Friendly names for skills. |
| `skipAgents` | Job folders to leave out. |
| `ignoreFiles` | Paths inside a job folder that do not count (tests and docs by default). |
| `models` | Descriptions. Each has `id`, `name`, `kind`, `what`, and `match`: wildcard patterns (`*`, `?`) on the file's path from your home folder, written with `/`, or `ollama/<tag>`. Optional `icon` (an SF Symbol), `color`, `note`, `status` (`idle` or `unused`, for a model the code names but never calls) and `notUsedBy` (names to drop when the code search links one by mistake). |

Grouping matters for models that load helper files: put a model's text encoder, VAE or add-ons in its `match` list,
and any model that another library loads for it (one video model loads a separate text model, for example).

## Limits

- It finds uses by name in code. A model loaded only by a third-party library, or chosen at run time from a setting
  it cannot read, will look unused until you group or describe it in the settings.
- Apart from Ollama's "Loaded", it does not watch what runs. "Used" means a job or skill names the model.
- Only scheduled jobs and skills count as users. Scripts you run by hand do not, and neither does a script that sits
  right in your home folder (reading all of home is off limits).
- The menu bar panel is Mac only. Linux and Windows get the same scan as a list in the terminal.

## Command line

On a Mac the program is `"Model Shelf.app/Contents/MacOS/ModelShelf"`; on Linux and Windows it is the one you built.

```bash
ModelShelf --list                                    # the list as text (the default on Linux and Windows)
ModelShelf --scan                                    # one scan as JSON
ModelShelf --snapshot out.png [model-id] [scan.json] # Mac: the panel as a picture
```

## Development

```bash
swift build
swift test            # scanner tests against a fake home folder
./scripts/build-app.sh  # Mac only: builds "build/Model Shelf.app"
```

`Sources/ShelfCore` is the scan (no UI) and `Jobs.swift` there holds the job reader for each system;
`Sources/ModelShelf` is the menu bar app and the terminal list. CI builds and tests on macOS, Linux and Windows.

## License

MIT. See [LICENSE](LICENSE).
