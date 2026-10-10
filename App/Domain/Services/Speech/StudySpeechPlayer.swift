import AVFoundation
import Combine
import Foundation

/// A deck's default is off. A note can inherit it or override it.
enum SpeechAutoplay: String, Codable, CaseIterable, Identifiable {
    case off, question, answer, both
    var id: Self { self }
    var title: String {
        switch self {
        case .off: return "オフ"
        case .question: return "問題面のみ"
        case .answer: return "解答面のみ"
        case .both: return "両面"
        }
    }
    func includes(_ side: SpeechSide) -> Bool {
        self == .both || (self == .question && side == .question) || (self == .answer && side == .answer)
    }
}

enum SpeechSide { case question, answer }

enum SpeechAccent: String, Codable, CaseIterable, Identifiable {
    case american = "en-US", british = "en-GB"
    var id: Self { self }
    var title: String { self == .american ? "アメリカ英語" : "イギリス英語" }
}

enum SpeechPace: String, Codable, CaseIterable, Identifiable {
    case slow, standard, fast
    var id: Self { self }
    var title: String {
        switch self { case .slow: return "ゆっくり"; case .standard: return "標準"; case .fast: return "速い" }
    }
    /// These are AVSpeechUtterance rate values, not speech-speed multipliers.
    var rate: Float {
        switch self { case .slow: return 0.42; case .standard: return AVSpeechUtteranceDefaultSpeechRate; case .fast: return 0.58 }
    }
}

struct SpeechPreferences: Codable, Equatable {
    var accent: SpeechAccent = .american
    var pace: SpeechPace = .standard
    var deckAutoplay: [String: SpeechAutoplay] = [:]

    func autoplay(deckID: UUID, noteOverride: SpeechAutoplay?) -> SpeechAutoplay {
        noteOverride ?? deckAutoplay[deckID.uuidString] ?? .off
    }
}

/// Never read undisclosed answers. Use only the already rendered card face.
enum SpeechReadout {
    static func text(kind: NoteKind, displayed: TextContent, side: SpeechSide) -> String? {
        let source: String
        if kind != .cloze,
           let explicit = side == .question ? displayed.speechQuestion : displayed.speechAnswer,
           !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = explicit
        } else {
            source = side == .question ? displayed.question : displayed.answer
        }
        // Cloze question face includes [hint] (sometimes the hidden word). Never speak it.
        let cleaned = kind == .cloze && side == .question
            ? source.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
            : source
        let normalized = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 3000, !normalized.contains("{{c"),
              !(kind == .cloze && side == .question && (normalized.contains("[") || normalized.contains("]"))),
              normalized.range(of: #"[A-Za-z]{2,}"#, options: .regularExpression) != nil,
              !normalized.unicodeScalars.contains(where: { scalar in
                  switch scalar.value {
                  case 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7A3: return true
                  default: return false
                  }
              }) else { return nil }
        return normalized
    }
}

struct SpeechPresentationKey: Equatable {
    let cardID: UUID
    let revealed: Bool
    var side: SpeechSide { revealed ? .answer : .question }
}

/// Owns the speech queue for a single visible study screen, not a global audio player.
@MainActor
final class StudySpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var notice: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(text: String, settings: SpeechPreferences) {
        stop()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let selected = voices.first { $0.language == settings.accent.rawValue }
            ?? AVSpeechSynthesisVoice(language: settings.accent.rawValue)
        let fallback = selected ?? voices.first { $0.language.hasPrefix("en-") }
        guard let voice = fallback else {
            notice = "利用できる英語音声がありません。iOSの音声設定を確認してください。"
            return
        }
        // Ambient respects the silent switch and mixes with other audio. Do not force playback.
        do { try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default) }
        catch {
            notice = "音声出力を準備できませんでした。"
            return
        }
        notice = voice.language == settings.accent.rawValue ? nil : "指定した英語音声がないため、利用可能な英語音声で再生しています。"
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = settings.pace.rate
        activeUtterance = utterance
        playing = true
        synthesizer.speak(utterance)
    }

    func stop() {
        activeUtterance = nil
        playing = false
        notice = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if utterance === activeUtterance { activeUtterance = nil; playing = false }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if utterance === activeUtterance { activeUtterance = nil; playing = false }
    }
}