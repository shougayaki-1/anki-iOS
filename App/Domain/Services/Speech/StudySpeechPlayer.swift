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
        let normalized = RubyDocument.parse(cleaned).plain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("{{c"),
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

// AVSpeechUtterance is mutable and non-Sendable. This wrapper only retains its
// identity across delegate delivery; no utterance properties cross actors.
private struct SpeechUtteranceIdentity: @unchecked Sendable {
    private let utterance: AVSpeechUtterance
    init(_ utterance: AVSpeechUtterance) { self.utterance = utterance }
    @MainActor func matches(_ current: AVSpeechUtterance?) -> Bool { utterance === current }
}

/// Owns the speech queue for a single visible study screen, not a global audio player.
@MainActor
final class StudySpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var notice: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var attachedPlayer: AVAudioPlayer?
    private var audioObservers = Set<AnyCancellable>()

    override init() {
        super.init()
        synthesizer.delegate = self
        // Clear the queue on calls and output disconnection. Never resume an old
        // card's speech when the interruption ends or headphones reconnect.
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.stop() }
            .store(in: &audioObservers)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   [.oldDeviceUnavailable, .newDeviceAvailable, .override, .routeConfigurationChange].contains(AVAudioSession.RouteChangeReason(rawValue: reason)) {
                    self?.stop()
                }
            }
            .store(in: &audioObservers)
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
        attachedPlayer?.stop(); attachedPlayer = nil
        activeUtterance = nil
        playing = false
        notice = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func playAttached(url: URL) {
        stop()
        do {
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw AttachedAudioError.missing }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= AudioEncodingPolicy.maximumBytes else { throw AttachedAudioError.tooLarge }
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.duration.isFinite, player.duration > 0, player.duration <= AudioEncodingPolicy.maximumDuration,
                  player.prepareToPlay() else { throw AttachedAudioError.invalid }
            player.delegate = self
            attachedPlayer = player
            guard player.play() else { throw AttachedAudioError.invalid }
            playing = true
        } catch {
            attachedPlayer = nil; playing = false
            notice = error is AttachedAudioError ? error.localizedDescription : AttachedAudioError.invalid.localizedDescription
        }
    }
    func missingAttachment() { stop(); notice = AttachedAudioError.missing.localizedDescription }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishAttachment(player, failed: !flag)
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finishAttachment(player, failed: true)
    }
    nonisolated private func finishAttachment(_ player: AVAudioPlayer, failed: Bool) {
        let identity = AttachedPlayerIdentity(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, identity.matches(self.attachedPlayer) else { return }
            self.attachedPlayer = nil; self.playing = false
            if failed { self.notice = AttachedAudioError.invalid.localizedDescription }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishOnMainQueue(utterance)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishOnMainQueue(utterance)
    }
    nonisolated private func finishOnMainQueue(_ utterance: AVSpeechUtterance) {
        // Delegate delivery isn't actor-isolated. Retain the utterance until
        // this identity-only comparison so an older callback can't clear new speech.
        let identity = SpeechUtteranceIdentity(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, identity.matches(self.activeUtterance) else { return }
            self.activeUtterance = nil
            self.playing = false
        }
    }
}

private struct AttachedPlayerIdentity: @unchecked Sendable {
    private let player: AVAudioPlayer
    init(_ player: AVAudioPlayer) { self.player = player }
    @MainActor func matches(_ current: AVAudioPlayer?) -> Bool { player === current }
}
