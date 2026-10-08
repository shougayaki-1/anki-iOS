import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

struct PhotoInputControls: View {
    let picked: (Data) -> Void
    @State private var selection: PhotosPickerItem?
    @State private var camera = false
    @State private var failure: String?
    @State private var loading = false
    @State private var loadingTask: Task<Void, Never>?

    var body: some View {
        HStack {
            PhotosPicker(selection: $selection, matching: .images) {
                Label("写真を選択", systemImage: "photo")
            }.accessibilityIdentifier("pickPhoto")
            Button("撮影", systemImage: "camera") {
                Task {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { failure = MediaError.noCamera.localizedDescription; return }
                    let allowed = await AVCaptureDevice.requestAccess(for: .video)
                    if allowed { camera = true } else { failure = MediaError.cameraDenied.localizedDescription }
                }
            }
            if loading { ProgressView() }
        }
        .buttonStyle(.borderless)
        .onChange(of: selection) { _, item in
            loadingTask?.cancel()
            loadingTask = Task {
                loading = true
                defer { if !Task.isCancelled { loading = false } }
                do {
                    guard let data = try await item?.loadTransferable(type: Data.self) else { throw MediaError.invalidImage }
                    guard !Task.isCancelled else { return }
                    picked(data)
                } catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }
        }
        .onDisappear { loadingTask?.cancel(); loading = false }
        .sheet(isPresented: $camera) {
            CameraCapture { data in camera = false; if let data { picked(data) } }
        }
        .alert("画像を取得できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("閉じる", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
}

struct CameraCapture: UIViewControllerRepresentable {
    let finished: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) { }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finished: (Data?) -> Void
        init(finished: @escaping (Data?) -> Void) { self.finished = finished }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finished(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else { finished(nil); return }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
            finished(normalized.jpegData(compressionQuality: 0.95))
        }
    }
}
