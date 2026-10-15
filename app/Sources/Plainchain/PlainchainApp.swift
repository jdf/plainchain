import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--smoke") { Smoke.run() } else { PlainchainApp.main() }
    }
}

struct PlainchainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        WindowGroup("Plainchain") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.levels)
                .frame(minWidth: 480, minHeight: 520)
                .navigationTitle(model.title)
                .onAppear { delegate.model = model }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model.newSession() }.keyboardShortcut("n")
                Button("Open Session…") { model.openSession() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.saveSession() }.keyboardShortcut("s")
                Button("Save As…") { model.saveSessionAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Plugins") {
                Button("Rescan Plugins") { model.refreshPlugins() }.keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: Model?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets the binary show a window and menu bar even when run outside a .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, let model else { return }
        Task { @MainActor in await model.open(url, quietly: false) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}
