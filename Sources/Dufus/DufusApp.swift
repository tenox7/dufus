import SwiftUI

@main
struct DufusApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
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
