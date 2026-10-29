import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--smoke") {
            Smoke.run()
        } else if CommandLine.arguments.contains("--records-test") {
            Smoke.runRecords()
        } else if CommandLine.arguments.contains("--hotplug-test") {
            MainActor.assumeIsolated { HotplugTest.run() }
        } else if CommandLine.arguments.contains("--clap-test") {
            MainActor.assumeIsolated { ClapTest.run() }
        } else {
            // Session windows are restored from AppState's own list, not by AppKit's window restoration.
            UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])
            PlainchainApp.main()
        }
    }
}

struct PlainchainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Owned by the delegate, which needs it before any window exists (files opened at launch).
    private var app: AppState { delegate.app }

    var body: some Scene {
        // One window per session; each has its own model and engine.
        WindowGroup("Plainchain", for: SessionRef.self) { $ref in
            SessionWindow(app: app, ref: $ref)
        }
        .windowResizability(.contentMinSize)
        // File opens go through AppDelegate, which picks the window; SwiftUI must not spawn one of its own.
        .handlesExternalEvents(matching: [])
        .commands {
            CommandGroup(replacing: .newItem) { FileCommands(app: app) }
            CommandGroup(replacing: .saveItem) { SaveCommands(app: app) }
            CommandMenu("Plugins") {
                Button("Rescan Plugins") { app.refreshPlugins() }.keyboardShortcut("r")
            }
        }
    }
}

/// A session window: its own model, built once from the window's session.
/// At launch SwiftUI opens the first window without one; it takes the first
/// saved session and opens the rest.
struct SessionWindow: View {
    let app: AppState
    @Binding var ref: SessionRef?
    @StateObject private var model: Model
    @Environment(\.openWindow) private var openWindow

    init(app: AppState, ref: Binding<SessionRef?>) {
        self.app = app
        _ref = ref
        let given = ref.wrappedValue
        _model = StateObject(wrappedValue: Model(app: app, ref: given ?? app.initialRef()))
    }

    var body: some View {
        ContentView()
            .environmentObject(model)
            .environmentObject(model.levels)
            .environmentObject(app)
            .frame(minWidth: 480, minHeight: 520)
            .navigationTitle(model.title)
            .focusedSceneObject(model)
            .background(WindowReader { model.attach($0) })
            .onAppear {
                if ref == nil { ref = SessionRef(id: model.id, path: model.ref.path) }
                app.windowAppeared(openWindow)
            }
    }
}

/// Hands over the NSWindow hosting it, once it is in one.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { Probe(found) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let found: (NSWindow) -> Void
        init(_ found: @escaping (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}

private struct FileCommands: View {
    let app: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Session") { openWindow(value: SessionRef()) }.keyboardShortcut("n")
        Button("Open Session…") { app.openSessionPanel() }.keyboardShortcut("o")
    }
}

/// Save acts on the focused session window, or with a plugin editor in
/// front (a plain AppKit window, no scene) on the session last in front.
private struct SaveCommands: View {
    @ObservedObject var app: AppState
    @FocusedObject private var focused: Model?
    private var model: Model? { focused ?? app.lastFocused }

    var body: some View {
        Button("Save") { model?.saveSession() }.keyboardShortcut("s").disabled(model == nil)
        Button("Save As…") { model?.saveSessionAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(model == nil)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One per process, made with the delegate so a file opened at launch has somewhere to go.
    let app = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets the binary show a window and menu bar even when run outside a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Before the first window is up, AppState holds the files until it can open them.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { app.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // From here on, windows that close stay in the restore list.
        app.terminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.shutdown()
    }
}
