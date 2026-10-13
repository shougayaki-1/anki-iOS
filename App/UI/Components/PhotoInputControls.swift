import SwiftUI
import PhotosUI
import AVFoundation
import UIKit
import UniformTypeIdentifiers

struct PhotoInputControls: View {
    let picked: (Data) -> Void
    @State private var acceptingFiles = true
    @State private var imageFile = false
    @State private var dropTarget = false
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
            #if targetEnvironment(macCatalyst)
            Button("画像ファイル", systemImage: "doc") { imageFile = true }
                .accessibilityIdentifier("selectImageFile")
            #else
            Button("撮影", systemImage: "camera") {
                Task {
                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { failure = MediaError.noCamera.localizedDescription; return }
                    let allowed = await AVCaptureDevice.requestAccess(for: .video)
                    if allowed { camera = true } else { failure = MediaError.cameraDenied.localizedDescription }
                }
            }
            #endif
            if loading { ProgressView() }
        }
        .buttonStyle(.borderless)
        .fileImporter(isPresented: $imageFile, allowedContentTypes: [.png, .jpeg]) { result in
            do { picked(try LocalFileInput.read(result.get(), extensions: ["png", "jpg", "jpeg"], maximumBytes: ImageEncodingPolicy.maximumBytes)) }
            catch { failure = error.localizedDescription }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
            guard providers.count == 1 else { failure = "画像ファイルは1件ずつ選択してください。"; return false }
            LocalFileInput.load(providers[0], extensions: ["png", "jpg", "jpeg"], maximumBytes: ImageEncodingPolicy.maximumBytes) { result in
                guard acceptingFiles else { return }
                switch result { case let .success((_, data)): picked(data); case let .failure(error): failure = error.localizedDescription }
            }
            return true
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }

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
        .onAppear { acceptingFiles = true }
        .onDisappear { acceptingFiles = false; loadingTask?.cancel(); loading = false }
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

// File panel and Finder drops share the same bounded reader. Neither path
// grants persistent access or stores a bookmark to the source file.
enum LocalFileInput {
    enum ImportContents: Sendable {
        case text(String)
        case images(ImageImportPackage)
        case deck(ValidatedDeckPackage)
        case anki(AnkiImportPreview)
    }
    static func readImport(_ url: URL) async throws -> ImportContents {
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let ext = url.pathExtension.lowercased()
            if ext == "studybackup" { throw ImportRoutingError.backup }
            let archives: Set<String> = ["zip", "studydeck", "apkg"]
            let data = try read(url, extensions: archives.union(["csv", "tsv", "txt"]),
                                maximumBytes: archives.contains(ext) ? 200_000_000 : 10_000_000)
            return try decodeImport(data, extension: ext)
        }
        let contents = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return contents
    }
    // Classification never falls back to another parser after a validation failure.
    static func decodeImport(_ data: Data, extension ext: String) throws -> ImportContents {
        try Task.checkCancellation()
        let ext = ext.lowercased()
        if ext == "studybackup" { throw ImportRoutingError.backup }
        guard data.count <= (["zip", "studydeck", "apkg"].contains(ext) ? 200_000_000 : 10_000_000) else { throw LibraryError.fileTooLarge }
        if ["zip", "studydeck", "apkg"].contains(ext) {
            switch try archiveKind(data, extension: ext) {
            case .deck: return .deck(try DeckExchange.decode(data))
            case .anki: return .anki(try AnkiImport.decode(data))
            case .images: return .images(try ImageImportPackage.read(data))
            }
        }
        guard ["csv", "tsv", "txt"].contains(ext) else { throw ImportRoutingError.unsupported }
        guard !data.starts(with: [0x50, 0x4b, 0x03, 0x04]), !data.contains(0),
              let text = String(data: data, encoding: .utf8) else { throw ImportRoutingError.mismatch }
        return .text(text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text)
    }
    private enum ArchiveKind { case deck, anki, images }
    private static func archiveKind(_ data: Data, extension ext: String) throws -> ArchiveKind {
        let files = try AnkiPackageZIP.read(data, budget: AnkiReadBudget())
        let format: String?
        if let manifest = files["manifest.json"] {
            guard manifest.count <= 1_000_000 else { throw BackupError.tooLarge }
            format = (try JSONSerialization.jsonObject(with: manifest) as? [String: Any])?["format"] as? String
        } else { format = nil }
        if format == "studybackup" || (files["data.json"] != nil && files["manifest.json"] != nil) { throw ImportRoutingError.backup }
        let deck = files["deck.json"] != nil || format == "studydeck"
        let anki = ["collection.anki2", "collection.anki21", "collection.anki21b"].contains { files[$0] != nil }
        let images = files["cards.csv"] != nil || files["cards.tsv"] != nil
        guard [deck, anki, images].filter({ $0 }).count == 1 else { throw ImportRoutingError.ambiguous }
        guard ext == "zip" || (ext == "studydeck" && deck) || (ext == "apkg" && anki) else {
            throw ImportRoutingError.mismatch
        }
        return deck ? .deck : anki ? .anki : .images
    }
    static func read(_ url: URL, extensions: Set<String>, maximumBytes: Int) throws -> Data {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else { throw StudyError.unsupportedContent }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw StudyError.unsupportedContent }
        guard let size = values.fileSize, size <= maximumBytes else { throw LibraryError.fileTooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw LibraryError.fileTooLarge }
        return data
    }
    static func load(_ provider: NSItemProvider, extensions: Set<String>, maximumBytes: Int,
                     completion: @escaping @MainActor (Result<(URL, Data), Error>) -> Void) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            let result: Result<(URL, Data), Error> = Result {
                if let error { throw error }
                let url: URL?
                if let value = item as? URL { url = value }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = nil }
                guard let url else { throw StudyError.unsupportedContent }
                return (url, try read(url, extensions: extensions, maximumBytes: maximumBytes))
            }
            Task { @MainActor in completion(result) }
        }
    }
}


enum ImportRoutingError: LocalizedError {
    case backup, ambiguous, mismatch, unsupported
    var errorDescription: String? {
        switch self {
        case .backup: return "完全バックアップは通常のインポートでは取り込めません。設定 → バックアップ・復元から復元してください。"
        case .ambiguous: return "ZIPの内容を一意に判定できません。デッキ・Anki・画像ZIPの構造を確認し、元の形式で書き出し直してください。"
        case .mismatch: return "拡張子とファイルの内容が一致しません。元のアプリから正しい形式で書き出し直してください。テキストはUTF-8を使用してください。"
        case .unsupported: return "CSV / TSV / TXT / 画像ZIP / .studydeck / .apkgを選択してください。"
        }
    }
}
