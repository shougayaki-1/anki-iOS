import Foundation
import AVFoundation
import CryptoKit

// Original local bytes are retained. This policy is shared by selection, restore and future deck/Anki import.
enum AudioEncodingPolicy {
    static let maximumBytes = 20_000_000
    static let maximumDuration = 600.0
    static let extensions = ["audio/wav": "wav", "audio/mp4": "m4a", "audio/mpeg": "mp3", "audio/aac": "aac", "audio/x-caf": "caf"]
    struct Prepared: Sendable {
        let data: Data
        let mediaType: String
        let duration: Double
        var fileExtension: String { AudioEncodingPolicy.extensions[mediaType]! }
    }
    static func prepare(_ data: Data) throws -> Prepared {
        guard !data.isEmpty, data.count <= maximumBytes else { throw AttachedAudioError.tooLarge }
        let prefix = Array(data.prefix(12)), type: String
        if prefix.count >= 12, String(bytes: prefix.prefix(4), encoding: .ascii) == "RIFF",
           String(bytes: prefix[8..<12], encoding: .ascii) == "WAVE" {
            let declared = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(prefix[4 + $1]) << ($1 * 8)) }
            guard Int(declared) == data.count - 8 else { throw AttachedAudioError.invalid }
            var offset = 12, hasFormat = false, hasSamples = false
            while offset < data.count {
                guard data.count - offset >= 8 else { throw AttachedAudioError.invalid }
                let size = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[offset + 4 + $1]) << ($1 * 8)) }
                let end = offset + 8 + Int(size)
                guard end <= data.count else { throw AttachedAudioError.invalid }
                let name = String(data: data.subdata(in: offset..<(offset + 4)), encoding: .ascii)
                if name == "fmt " { hasFormat = size >= 16 }
                if name == "data" { hasSamples = size > 0 }
                offset = end + Int(size % 2)
            }
            guard offset == data.count, hasFormat, hasSamples else { throw AttachedAudioError.invalid }
            type = "audio/wav"
        } else if prefix.count >= 12, String(bytes: prefix[4..<8], encoding: .ascii) == "ftyp",
                  ["M4A ", "M4B "].contains(String(bytes: prefix[8..<12], encoding: .ascii) ?? "") { type = "audio/mp4" }
        else if String(bytes: prefix.prefix(4), encoding: .ascii) == "caff" { type = "audio/x-caf" }
        else if String(bytes: prefix.prefix(3), encoding: .ascii) == "ID3" { type = "audio/mpeg" }
        else if prefix.count >= 2, prefix[0] == 0xff, prefix[1] & 0xf6 == 0xf0 { type = "audio/aac" }
        else if prefix.count >= 2, prefix[0] == 0xff, prefix[1] & 0xe0 == 0xe0, prefix[1] & 0x06 != 0 { type = "audio/mpeg" }
        else { throw AttachedAudioError.invalid }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(extensions[type]!)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: .atomic)
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let duration = Double(file.length) / format.sampleRate
            guard format.sampleRate.isFinite, (8000...96000).contains(format.sampleRate),
                  (1...2).contains(format.channelCount), duration.isFinite, duration > 0, duration <= maximumDuration,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw AttachedAudioError.invalid }
            var decoded: AVAudioFramePosition = 0
            while decoded < file.length {
                try Task.checkCancellation()
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { throw AttachedAudioError.invalid }
                decoded += AVAudioFramePosition(buffer.frameLength)
            }
            guard decoded == file.length else { throw AttachedAudioError.invalid }
            return Prepared(data: data, mediaType: type, duration: duration)
        } catch is CancellationError { throw CancellationError() }
        catch { throw AttachedAudioError.invalid }
    }
    static func read(_ url: URL) async throws -> Prepared {
        let task = Task.detached(priority: .utility) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maximumBytes else { throw AttachedAudioError.tooLarge }
            return try prepare(Data(contentsOf: url, options: .mappedIfSafe))
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

enum AttachedAudioError: LocalizedError {
    case invalid, tooLarge, missing, save
    var errorDescription: String? {
        switch self {
        case .invalid: return "音声を読み込めません。完全なWAV・M4A・MP3・AAC・CAF（10分以内、8〜96kHz、モノラル／ステレオ）を選んでください。"
        case .tooLarge: return "音声は1ファイル20MBまでです。"
        case .missing: return "添付音声が見つかりません。編集で再選択できます。学習と評価は続けられます。"
        case .save: return "音声を保存できません。空き容量と保存先を確認してください。"
        }
    }
}

extension TextContent {
    var audioIDs: [UUID] { [questionAudioID, answerAudioID].compactMap { $0 } }
    func audioID(for side: SpeechSide) -> UUID? { side == .question ? questionAudioID : answerAudioID }
}
extension NoteInput {
    var audioIDs: [UUID] { [questionAudioID, answerAudioID].compactMap { $0 } }
}

extension MediaStore {
    func storeAudio(_ prepared: AudioEncodingPolicy.Prepared) throws -> StoredImage {
        let id = UUID(), path = "audio/\(UUID().uuidString).\(prepared.fileExtension)"
        let file = try url(for: path)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try prepared.data.write(to: file, options: .atomic)
        } catch { throw AttachedAudioError.save }
        return StoredImage(id: id, relativePath: path, mediaType: prepared.mediaType, width: 0, height: 0,
                           sha256: SHA256.hash(data: prepared.data).map { String(format: "%02x", $0) }.joined())
    }
}
