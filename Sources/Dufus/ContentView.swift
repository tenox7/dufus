import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var appState: AppState
    @StateObject private var diskManager = DiskManager()
    @State private var selectedDisk: DiskInfo?
    @State private var showFilePicker = false
    @State private var dropHighlight = false
    @State private var wipeBeforeWrite = true
    private var writer: DiskWriter { DiskWriter(appState: appState) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            dropZone
            HStack {
                Picker("Target Disk:", selection: $selectedDisk) {
                    Text("Select a disk…").tag(nil as DiskInfo?)
                    ForEach(diskManager.disks) { disk in
                        Text(disk.displayName).tag(disk as DiskInfo?)
                    }
                }
                Button("⟳") {
                    diskManager.refresh()
                }
            }
            Toggle("Wipe filesystem signatures before write", isOn: $wipeBeforeWrite)
            Spacer()
            progressSection
            HStack {
                Button("Write") {
                    guard let image = appState.imageURL, let disk = selectedDisk else { return }
                    writer.write(image: image, to: disk, wipe: wipeBeforeWrite)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.imageURL == nil || selectedDisk == nil || appState.writing)
                Button("Stop") {
                    appState.cancelled = true
                }
                .disabled(!appState.writing)
                Button("Eject") {
                    guard let disk = selectedDisk else { return }
                    writer.eject(disk: disk)
                }
                .disabled(selectedDisk == nil || appState.writing)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(20)
        .frame(width: 350, height: 300)
        .onAppear {
            diskManager.refresh()
        }
        .onChange(of: diskManager.disks) { newDisks in
            if newDisks.count == 1 { selectedDisk = newDisks.first }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: Self.imageTypes,
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                appState.imageURL = url
            }
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: appState.progress)
                .scaleEffect(y: 4, anchor: .center)
            Text(appState.status)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .foregroundColor(dropHighlight ? .accentColor : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(dropHighlight ? Color.accentColor.opacity(0.1) : Color.clear)
                )

            if let url = appState.imageURL {
                VStack(spacing: 4) {
                    Image(systemName: "doc.fill")
                        .font(.title)
                    Text(url.lastPathComponent)
                        .font(.headline)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc")
                        .font(.title)
                    Text("Drop disk image here or click to select")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(height: 100)
        .contentShape(Rectangle())
        .onTapGesture { showFilePicker = true }
        .onDrop(of: [.fileURL], isTargeted: $dropHighlight) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    appState.imageURL = url
                }
            }
            return true
        }
    }

    static let imageTypes: [UTType] = [
        .diskImage, .data, .archive,
        UTType("org.gnu.gnu-zip-archive") ?? .data,
        UTType("org.tukaani.xz-archive") ?? .data,
        UTType("public.zip-archive") ?? .data,
        UTType("com.apple.disk-image") ?? .data,
    ]
}

