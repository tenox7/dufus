import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tenox.dufus"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            running.first { $0 != NSRunningApplication.current }?.activate()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

@main
struct DufusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("Dufus", id: "main") {
            ContentView(appState: appState)
                .onOpenURL { url in
                    appState.imageURL = url
                }
                .onAppear {
                    appState.imageURL = nil
                    handleCommandLineArgs()
                }
        }
        .defaultSize(width: 350, height: 500)
        .windowResizability(.contentSize)
    }

    private func handleCommandLineArgs() {
        let args = CommandLine.arguments.dropFirst()
        guard let path = args.first else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        appState.imageURL = url
    }
}

class AppState: ObservableObject {
    @Published var imageURL: URL?
    @Published var progress: Double = 0
    @Published var status: String = "Ready"
    @Published var writing: Bool = false
    var cancelled: Bool = false
}
