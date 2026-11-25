import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVKit

struct PhotoPickerSheet: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onPicked: ([MediaUploadItem]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = 10
        config.filter = .any(of: [.images, .videos])
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPickerSheet

        init(_ parent: PhotoPickerSheet) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }

            let group = DispatchGroup()
            var items: [MediaUploadItem] = []
            let lock = NSLock()

            for (idx, result) in results.enumerated() {
                let provider = result.itemProvider
                let typeId = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: typeId) { data, _ in
                    defer { group.leave() }
                    guard let data = data else { return }
                    let ut = UTType(typeId)
                    let ext = ut?.preferredFilenameExtension ?? "bin"
                    let mime = ut?.preferredMIMEType ?? "application/octet-stream"
                    let suggested = provider.suggestedName ?? "media-\(idx + 1)"
                    let filename = suggested.contains(".") ? suggested : "\(suggested).\(ext)"
                    lock.lock()
                    items.append(MediaUploadItem(filename: filename, mimeType: mime, data: data))
                    lock.unlock()
                }
            }

            group.notify(queue: .main) {
                self.parent.onPicked(items)
            }
        }
    }
}

struct DocumentPickerSheet: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onPicked: ([MediaUploadItem]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerSheet

        init(_ parent: DocumentPickerSheet) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.dismiss()
            var items: [MediaUploadItem] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                let ext = url.pathExtension
                let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                items.append(MediaUploadItem(filename: url.lastPathComponent, mimeType: mime, data: data))
            }
            if !items.isEmpty {
                parent.onPicked(items)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

struct ImageViewerSheet: View {
    let url: URL
    let filename: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        VStack(spacing: 10) {
                            Image(systemName: "photo.badge.exclamationmark")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("Không thể tải ảnh")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    default:
                        ProgressView()
                            .tint(.white)
                    }
                }
            }
            .navigationTitle(filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

struct VideoPlayerSheet: View {
    let url: URL
    let filename: String
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player = player {
                    VideoPlayer(player: player)
                }
            }
            .onAppear {
                let av = AVPlayer(url: url)
                player = av
                av.play()
            }
            .onDisappear {
                player?.pause()
                player = nil
            }
            .navigationTitle(filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
