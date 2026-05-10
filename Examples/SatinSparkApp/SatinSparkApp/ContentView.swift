import SatinSpark
import SwiftUI
import UniformTypeIdentifiers

private struct ImportedPackedSplats: Sendable {
    var packedArray: [UInt32]
    var numSplats: Int
    var maxSplats: Int
    var splatEncoding: SplatEncoding

    func makePackedSplats() -> PackedSplats {
        PackedSplats(
            packedArray: packedArray,
            numSplats: numSplats,
            maxSplats: maxSplats,
            splatEncoding: splatEncoding
        )
    }
}

struct ContentView: View {
    @State private var renderer = SplatDemoRenderer()
    @State private var isImporterPresented = false
    @State private var selectedFileName = "Deterministic fixture"
    @State private var statusText = "Ready"
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?

    private let initialURL: URL?
    private let splatTypes = [
        "ply",
        "splat",
        "spz",
        "ksplat",
        "sog",
        "pcsogs",
        "pcsogszip",
        "rad",
    ].compactMap { UTType(filenameExtension: $0) }

    init(initialURL: URL? = nil) {
        self.initialURL = initialURL
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            SplatDemoView(renderer: renderer)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("Open Splat", systemImage: "folder")
                    }

                    Text(selectedFileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.headline)
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let importError {
                    Text(importError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .padding(16)
            .frame(maxWidth: 420, alignment: .leading)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: splatTypes.isEmpty ? [.data] : splatTypes,
            allowsMultipleSelection: false
        ) { result in
            importSplats(result)
        }
        .task {
            guard let initialURL else { return }
            importSplats(initialURL)
        }
    }

    private func importSplats(_ result: Result<[URL], any Error>) {
        do {
            guard let url = try result.get().first else { return }
            importSplats(url)
        } catch {
            importError = error.localizedDescription
            statusText = "Import failed"
        }
    }

    private func importSplats(_ url: URL) {
        importTask?.cancel()
        selectedFileName = url.lastPathComponent
        statusText = "Loading..."
        importError = nil

        importTask = Task {
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    let isScoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if isScoped {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let packedSplats = try SplatLoader.load(url: url)
                    return ImportedPackedSplats(
                        packedArray: packedSplats.packedArray,
                        numSplats: packedSplats.numSplats,
                        maxSplats: packedSplats.maxSplats,
                        splatEncoding: packedSplats.splatEncoding
                    )
                }.value

                guard !Task.isCancelled else { return }
                let packedSplats = imported.makePackedSplats()
                renderer.replacePackedSplats(packedSplats)
                statusText = "\(packedSplats.numSplats) splats"
                importError = nil
            } catch {
                guard !Task.isCancelled else { return }
                importError = error.localizedDescription
                statusText = "Import failed"
            }
        }
    }
}

#Preview {
    ContentView()
}
