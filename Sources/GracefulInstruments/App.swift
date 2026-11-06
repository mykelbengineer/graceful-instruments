import SwiftUI
import AppKit

@main
struct Main {
    static func main() {
        // Command-line modes for testing and setting up over SSH (see DevTools.swift).
        if let code = DevTools.run(CommandLine.arguments) { exit(code) }
        GracefulApp.main()
    }
}

struct GracefulApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var downloader = Downloader()
    @StateObject private var stemMaker = StemMaker()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(downloader)
                .environmentObject(stemMaker)
                .frame(minWidth: 1080, minHeight: 640)
                .onAppear {
                    downloader.model = model
                    stemMaker.model = model
                    KeyMonitor.shared.install(model: model)
                    // For remote checks: --open "part of a title" [--autoplay]
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--open"), i + 1 < args.count,
                       let item = model.items.first(where: { $0.title.localizedCaseInsensitiveContains(args[i + 1]) }) {
                        model.open(item.id, autoplay: args.contains("--autoplay"))
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Playback") {
                Button("Play / Pause   (Space)") { model.togglePlay() }
                Button("Stop   (S)") { model.stop() }
                Button("Fade Out   (F)") { model.fadeOut() }
                Button("Loop On/Off   (L)") { model.toggleLoop() }
                Button("Click On/Off   (K)") { model.clickOn.toggle() }
                Divider()
                Button("Back One Bar   ([)") { model.jumpBars(-1) }
                Button("Forward One Bar   (])") { model.jumpBars(1) }
                Button("Next in Setlist   (N)") { model.playNext() }
                Button("Previous in Setlist   (B)") { model.playPrevious() }
                Divider()
                Button("Tap Tempo   (T)") { model.tapTempo() }
                Divider()
                Button("Set Loop In   (I)") { model.setIn() }
                Button("Set Loop Out   (O)") { model.setOut() }
                Divider()
                Button("Pad On/Off   (P)") { model.pads.toggle() }
            }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Closing the window by mistake mustn't stop the music: the app keeps running and the Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for w in sender.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil); return false } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let m = KeyMonitor.shared.model, m.engine.isPlaying || m.pads.on else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Music is still playing"
        a.informativeText = "Quit Graceful Instruments and stop the sound?"
        a.addButton(withTitle: "Keep Playing")
        a.addButton(withTitle: "Quit")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeyMonitor.shared.model?.saveNow()
        StemMaker.shared?.cancelAll()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // Open large on small laptop screens so all three columns have room.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                  let screen = w.screen?.visibleFrame, w.frame.width < 1240 else { return }
            let size = NSSize(width: min(1340, screen.width - 40), height: min(860, screen.height - 20))
            w.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                              width: size.width, height: size.height), display: true, animate: false)
        }
    }
}

/// Single-key shortcuts for live use. Keys go to text fields as normal while someone is typing.
final class KeyMonitor {
    static let shared = KeyMonitor()
    private var token: Any?
    weak var model: AppModel?

    static let digitCues: [Character: String] = [
        "1": "verse", "2": "prechorus", "3": "chorus", "4": "bridge", "5": "build",
        "6": "down", "7": "again", "8": "lasttime", "9": "ending", "0": "instrumental"]

    func install(model: AppModel) {
        self.model = model
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, let m = self.model else { return e }
            if let r = e.window?.firstResponder, r is NSText || r is NSTextView { return e }
            let mods = e.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty else { return e }
            guard let ch = e.charactersIgnoringModifiers?.lowercased().first else { return e }
            switch ch {
            case " ": m.togglePlay()
            case "s": m.stop()
            case "f": m.fadeOut()
            case "l": m.toggleLoop()
            case "k": m.clickOn.toggle()
            case "[": m.jumpBars(-1)
            case "]": m.jumpBars(1)
            case "n": m.playNext()
            case "b": m.playPrevious()
            case "t": m.tapTempo()
            case "i": m.setIn()
            case "o": m.setOut()
            case "p": m.pads.toggle()
            case "=", "+": m.nudgeTempo(1)
            case "-": m.nudgeTempo(-1)
            default:
                if let cue = KeyMonitor.digitCues[ch] { m.cue(cue) } else { return e }
            }
            return nil
        }
    }
}
