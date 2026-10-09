import Foundation
import Vision

struct OCRResult: Sendable {
    let text: String
    let languages: [String]
}

struct OCRService {
    static func recognize(_ data: Data) async throws -> OCRResult {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let supported = try request.supportedRecognitionLanguages()
            let preferred = ["ja-JP", "en-US"].filter { supported.contains($0) }
            request.recognitionLanguages = preferred.isEmpty ? Array(supported.prefix(1)) : preferred
            try VNImageRequestHandler(data: data, options: [:]).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            return OCRResult(text: text, languages: request.recognitionLanguages)
        }.value
    }
}
