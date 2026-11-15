import Foundation
import ShelfCore
#if os(macOS)
import AppKit
import SwiftUI
#endif

// Model Shelf: every local AI model on this computer, what it does, and which jobs and skills use it.
//   ModelShelf                                              Mac: the menu bar app. Linux and Windows: the list below
//   ModelShelf --list                                       print the list as text and quit
//   ModelShelf --scan                                       print one scan as JSON and quit
//   ModelShelf --snapshot out.png [model-id] [scan.json]    Mac: draw the panel to a picture

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") {
            print("Usage: ModelShelf [--list | --scan]\nSettings: \(settingsPath())")
            exit(0)
        }
        if args.contains("--scan") {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try! enc.encode(runScan(config: loadConfig())))
            exit(0)
        }
        #if os(macOS)
        if !args.contains("--list") {
            if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
                let open = i + 2 < args.count ? args[i + 2] : nil
                var scan = Scan(entries: [], at: Date(), warnings: [])
                if i + 3 < args.count {
                    let dec = JSONDecoder()
                    dec.dateDecodingStrategy = .iso8601
                    guard let data = FileManager.default.contents(atPath: args[i + 3]), let s = try? dec.decode(Scan.self, from: data) else {
                        FileHandle.standardError.write(Data("cannot read \(args[i + 3])\n".utf8))
                        exit(1)
                    }
                    scan = s
                } else {
                    scan = runScan(config: loadConfig())
                }
                MainActor.assumeIsolated { snapshot(scan, open: open, to: args[i + 1]) }
                exit(0)
            }
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                let delegate = MenuBar()
                app.delegate = delegate
                app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
                app.run()
            }
            return
        }
        #endif
        print(listText(runScan(config: loadConfig())))
    }
}

/// The settings file (see `settingsPath`) if present and valid, else built-in defaults.
func loadConfig() -> ShelfConfig {
    let path = settingsPath()
    guard let data = FileManager.default.contents(atPath: path) else { return ShelfConfig() }
    do {
        return try JSONDecoder().decode(ShelfConfig.self, from: data)
    } catch {
        FileHandle.standardError.write(Data("Model Shelf: \(path) is not valid (\(error)); using defaults\n".utf8))
        return ShelfConfig()
    }
}

#if os(macOS)

/// The icon in the menu bar and the panel that drops down under it (a status item with a popover).
@MainActor
final class MenuBar: NSObject, NSApplicationDelegate {
    private let shelf = Shelf()
    private let popover = NSPopover()
    private var item: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Model Shelf")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
        let host = NSHostingController(rootView: ShelfView().environmentObject(shelf))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient  // closes when you click anywhere else
    }

    @objc private func toggle() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        shelf.refreshIfOld()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }
}

@MainActor
final class Shelf: ObservableObject {
    @Published var scan: Scan?
    @Published var busy = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    init(preloaded: Scan) { scan = preloaded }

    func refreshIfOld() {
        if let at = scan?.at, Date().timeIntervalSince(at) < 5 * 60 { return }
        refresh()
    }

    func refresh() {
        guard !busy else { return }
        busy = true
        let cfg = loadConfig()
        Task.detached(priority: .utility) {
            let result = runScan(config: cfg)
            await MainActor.run { self.scan = result; self.busy = false }
        }
    }
}

@MainActor
private func snapshot(_ scan: Scan, open: String?, to path: String) {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: ShelfView(open: open).environmentObject(Shelf(preloaded: scan))
        .background(Color(nsColor: .windowBackgroundColor)))
    host.frame.size = host.fittingSize
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))  // let SwiftUI draw once
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try? png.write(to: URL(fileURLWithPath: path))
}
#endif
