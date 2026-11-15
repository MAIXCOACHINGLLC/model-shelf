import Foundation
import XCTest
@testable import ShelfCore

/// Each test builds a fake home folder: model files (sparse, so they cost no disk), launchd jobs pointing at small
/// scripts, and skills. The scan then runs against that home with no Ollama unless a test fakes one.
final class ScannerTests: XCTestCase {
    private var home = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: home + "/Library/LaunchAgents", withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: home)
    }

    // MARK: Helpers

    private func write(_ rel: String, _ text: String) throws {
        let path = home + "/" + rel
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func model(_ rel: String, mb: Int = 6) throws {
        let path = home + "/" + rel
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertTrue(fm.createFile(atPath: path, contents: nil))
        let h = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        try h.truncate(atOffset: UInt64(mb) * 1_000_000)
        try h.close()
    }

    private func job(_ label: String, runs script: String) throws {
        let plist: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/zsh", home + "/" + script]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: home + "/Library/LaunchAgents/\(label).plist"))
    }

    private func hfRepo(_ repo: String, blob: String, mb: Int = 6) throws {
        let dir = "cache/hub/models--" + repo.replacingOccurrences(of: "/", with: "--")
        if !fm.fileExists(atPath: home + "/cache/hub/blobs/" + blob) { try model("cache/hub/blobs/" + blob, mb: mb) }
        try fm.createDirectory(atPath: home + "/" + dir + "/snapshots/rev1", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/" + dir + "/snapshots/rev1/model.bin", withDestinationPath: "../../../blobs/" + blob)
    }

    private func scan(_ json: String = "{}", loaded: Set<String> = [], ollama: [String: [String: Any]] = [:]) throws -> Scan {
        let base = #"{"hfStores": ["~/cache/hub"], "fileStores": ["~/models"], "skills": ["~/skills"], "ollama": "#
            + (ollama.isEmpty ? "null" : #""http://127.0.0.1:11434""#) + "}"
        var cfg = try JSONDecoder().decode(ShelfConfig.self, from: Data(base.utf8))
        let extra = try JSONDecoder().decode(ShelfConfig.self, from: Data(json.utf8))
        if json.contains("\"models\"") { cfg.models = extra.models }
        if json.contains("\"agents\"") { cfg.agents = extra.agents }
        if json.contains("\"ignoreFiles\"") { cfg.ignoreFiles = extra.ignoreFiles }
        let env = ScanEnvironment(home: home, loadedJobs: { loaded }, fetchJSON: { url in
            ollama.first { url.hasSuffix($0.key) }?.value
        })
        return runScan(config: cfg, env: env)
    }

    private func entry(_ s: Scan, _ name: String) throws -> Entry {
        try XCTUnwrap(s.entries.first { $0.name == name }, "no entry named \(name) in \(s.entries.map(\.name))")
    }

    // MARK: Tests

    func testFindsModelFilesAndTheJobThatNamesThem() throws {
        try model("models/diffusion_models/pic-model-q4.gguf")
        try model("models/loras/tiny.safetensors", mb: 1)  // under 5 MB: not a model
        try write("agents/render/run.py", "UNET = 'pic-model-q4.gguf'\n")
        try job("com.test.render", runs: "agents/render/run.py")

        let s = try scan(loaded: ["com.test.render"])
        XCTAssertEqual(s.entries.count, 1)
        let e = try entry(s, "pic-model-q4")
        XCTAssertEqual(e.section, "used")
        XCTAssertEqual(e.kind, "Picture or video model")
        XCTAssertEqual(e.users, [User(agent: "render", how: "names it in run.py", tag: "job")])
        XCTAssertTrue(e.isNew)
        XCTAssertEqual(e.gb, 0.006, accuracy: 0.0001)
    }

    func testJobNotLoadedIsMarked() throws {
        try model("models/m/voice-model.bin")
        try write("agents/voice/run.sh", "#!/bin/sh\nload voice-model.bin\n")
        try job("com.test.voice", runs: "agents/voice/run.sh")
        XCTAssertEqual(try entry(try scan(), "voice-model").users.first?.tag, "job (not loaded)")
    }

    func testDataFilesAndDocsDoNotCount() throws {
        try model("models/m/pic-model-q4.gguf")
        try write("agents/render/run.py", "print('hello')\n")
        try write("agents/render/calendar.json", #"{"topic": "pic-model-q4.gguf"}"#)  // content, not settings
        try write("agents/render/docs/notes.py", "# we tried pic-model-q4.gguf once\n")
        try write("agents/render/state/run.py", "pic-model-q4.gguf\n")                 // a data folder
        try write("agents/render/README", "pic-model-q4.gguf\n")                        // no extension, not a script
        try job("com.test.render", runs: "agents/render/run.py")
        let e = try entry(try scan(), "pic-model-q4")
        XCTAssertEqual(e.users, [])
        XCTAssertEqual(e.section, "unused")
    }

    func testOneHopThroughAScript() throws {
        try model("models/m/voice-model.bin")
        try write("renderer/tools/tts.py", "MODEL = 'voice-model.bin'\n")
        try write("renderer/worker.py", "print('worker')\n")
        try job("com.test.renderer", runs: "renderer/worker.py")
        try write("clips/make.sh", "#!/bin/sh\npython ~/renderer/tools/tts.py\n")
        try job("com.test.clips", runs: "clips/make.sh")

        let names = try entry(try scan(), "voice-model").users.map { "\($0.agent): \($0.how)" }
        XCTAssertEqual(Set(names), ["renderer: names it in tools/tts.py", "clips: runs renderer's tools/tts.py"])
    }

    func testJobThatRunsASkillWhichUsesTheModel() throws {
        try model("models/m/voice-model.bin")
        try write("skills/clipper/scripts/voice.py", "M = 'voice-model.bin'\n")
        try write("clips/run.sh", "#!/bin/sh\nclaude -p 'use ~/.claude/skills/clipper/SKILL.md'\n")
        try job("com.test.clips", runs: "clips/run.sh")

        let users = try entry(try scan(#"{"agents": {"~/clips": "Daily clips"}}"#), "voice-model").users
        XCTAssertEqual(users.map(\.agent), ["clipper skill", "Daily clips"])
        XCTAssertEqual(users.last?.how, "runs the clipper skill")
    }

    func testLongestNameWins() throws {
        try hfRepo("org/whisper-large-v3-turbo", blob: "aaa")
        try hfRepo("org2/faster-whisper-large-v3-turbo", blob: "bbb")
        try write("agents/hear/run.py", "WhisperModel('org2/faster-whisper-large-v3-turbo')\n")
        try job("com.test.hear", runs: "agents/hear/run.py")

        let s = try scan()
        XCTAssertEqual(try entry(s, "org2/faster-whisper-large-v3-turbo").users.map(\.agent), ["hear"])
        XCTAssertEqual(try entry(s, "org/whisper-large-v3-turbo").users, [])
    }

    func testSharedHuggingFaceFileIsCountedOnce() throws {
        try hfRepo("org/voice-a", blob: "shared", mb: 8)
        try hfRepo("org/voice-b", blob: "shared", mb: 8)
        let s = try scan()
        XCTAssertEqual(s.entries.reduce(0) { $0 + $1.gb }, 0.008, accuracy: 0.0001)
    }

    func testSettingsGroupDescribeAndCorrect() throws {
        try model("models/diffusion_models/pic-model-q4.gguf")
        try model("models/vae/pic-vae.safetensors")
        try model("models/diffusion_models/old-talker.gguf")
        try model("models/diffusion_models/stray.gguf")
        try write("renderer/graphs.py", "A = 'pic-model-q4.gguf'\nB = 'old-talker.gguf'  # defined, never called\n")
        try job("com.test.renderer", runs: "renderer/graphs.py")
        let cfg = """
        {"models": [
          {"id": "pic", "name": "Picture model", "kind": "Pictures", "match": ["models/diffusion_models/pic-*", "models/vae/pic-*"],
           "what": "Makes pictures."},
          {"id": "talk", "name": "Old talker", "kind": "Talking video", "match": ["models/diffusion_models/old-talker*"],
           "what": "Never called.", "status": "unused", "note": "Named in code only."}
        ]}
        """
        let s = try scan(cfg)
        let pic = try entry(s, "Picture model")
        XCTAssertEqual(pic.gb, 0.012, accuracy: 0.0001)
        XCTAssertEqual(pic.files.count, 2)
        XCTAssertFalse(pic.isNew)
        XCTAssertEqual(pic.section, "used")
        let talk = try entry(s, "Old talker")
        XCTAssertEqual(talk.section, "unused")
        XCTAssertEqual(talk.users, [])
        XCTAssertTrue(try entry(s, "stray").isNew)
    }

    func testNotUsedByRemovesAWrongLink() throws {
        try model("models/m/clone-voice.bin")
        try write("renderer/tools/tts.py", "CLONE = 'clone-voice.bin'\n")
        try write("renderer/worker.py", "print('worker')\n")
        try job("com.test.renderer", runs: "renderer/worker.py")
        try write("clips/make.sh", "#!/bin/sh\npython tools/tts.py --design\n")
        try job("com.test.clips", runs: "clips/make.sh")
        let cfg = #"{"models": [{"id": "c", "name": "Clone", "kind": "Voice", "match": ["models/m/clone-*"], "what": "x", "notUsedBy": ["clips"]}]}"#
        XCTAssertEqual(try entry(try scan(cfg), "Clone").users.map(\.agent), ["renderer"])
    }

    func testOllamaModelInMemoryWithNoUserIsIdle() throws {
        let s = try scan(ollama: [
            "/api/tags": ["models": [["name": "chat-model:8b", "size": 5_000_000_000], ["name": "embedder:small", "size": 600_000_000]]],
            "/api/ps": ["models": [["name": "chat-model:8b"]]],
        ])
        let chat = try entry(s, "chat-model:8b")
        XCTAssertTrue(chat.loaded)
        XCTAssertEqual(chat.section, "idle")
        XCTAssertEqual(chat.gb, 5, accuracy: 0.001)
        XCTAssertEqual(try entry(s, "embedder:small").section, "unused")
    }

    func testOllamaDownIsAWarning() throws {
        let cfg = try JSONDecoder().decode(ShelfConfig.self, from: Data(#"{"hfStores": [], "fileStores": [], "skills": []}"#.utf8))
        let s = runScan(config: cfg, env: ScanEnvironment(home: home, loadedJobs: { [] }, fetchJSON: { _ in nil }))
        XCTAssertEqual(s.warnings, ["Ollama is not answering, so its models are not listed."])
    }

    func testEmptySettingsFileUsesDefaults() throws {
        let cfg = try JSONDecoder().decode(ShelfConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(cfg.hfStores, ["~/.cache/huggingface/hub"])
        XCTAssertEqual(cfg.ollama, "http://127.0.0.1:11434")
        XCTAssertTrue(cfg.models.isEmpty)
    }

    func testExampleSettingsFileIsValid() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../docs/shelf.example.json")
        let cfg = try JSONDecoder().decode(ShelfConfig.self, from: Data(contentsOf: url))
        XCTAssertEqual(cfg.models.count, 3)
    }

    func testHuggingFaceCacheInsideAModelFolderIsNotCountedTwice() throws {
        try model("models/diffusion_models/pic-model-q4.gguf")
        try model("models/hub/blobs/abc")            // a cache living inside the model folder
        try write("models/hub/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55\n")
        XCTAssertEqual(try scan().entries.map(\.name), ["pic-model-q4"])
    }
}
