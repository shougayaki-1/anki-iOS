import AVFoundation
import Combine
import Foundation
import OSLog

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

enum SpeechSide: String { case question, answer }

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
        assessment(kind: kind, displayed: displayed, side: side).text
    }
    static func assessment(kind: NoteKind, displayed: TextContent, side: SpeechSide) -> SpeechReadoutAssessment {
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
        if normalized.isEmpty { return .init(text: nil, failure: .emptyText) }
        if normalized.contains("{{c") || (kind == .cloze && side == .question && (normalized.contains("[") || normalized.contains("]"))) {
            return .init(text: nil, failure: .hiddenContent)
        }
        if normalized.unicodeScalars.contains(where: { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7A3: return true
            default: return false
            }
        }) { return .init(text: nil, failure: .mixedLanguage) }
        guard normalized.range(of: #"[A-Za-z]{2,}"#, options: .regularExpression) != nil else { return .init(text: nil, failure: .noEnglish) }
        return .init(text: normalized, failure: nil)
    }
}

enum SpeechReadoutFailure: String {
    case emptyText, hiddenContent, mixedLanguage, noEnglish
    var notice: String {
        switch self {
        case .emptyText: return "この面には読み上げる本文がありません。"
        case .hiddenContent: return "伏せた解答を守るため、この本文は読み上げません。"
        case .mixedLanguage: return "日英が混在する本文は読み上げません。カード編集で読み上げ用の英文を指定できます。"
        case .noEnglish: return "この面に読み上げ対象の英文がありません。"
        }
    }
}
struct SpeechReadoutAssessment {
    let text: String?
    let failure: SpeechReadoutFailure?
}
enum SpeechPlaybackPhase: String { case idle, requested, speaking, attached }
enum SpeechVoiceSelection {
    static func index(languages: [String], accent: SpeechAccent) -> Int? {
        languages.firstIndex { $0.caseInsensitiveCompare(accent.rawValue) == .orderedSame }
            ?? languages.firstIndex { $0.caseInsensitiveCompare("en-US") == .orderedSame }
            ?? languages.firstIndex { $0.lowercased().hasPrefix("en-") || $0.lowercased() == "en" }
    }
}
enum SpeechDiagnostics {
    private static let logger = Logger(subsystem: "dev.shoug.AnkiIOS", category: "StudyAudio")
    // Callers supply enum values/counts/system route types, never card text or file names.
    static func record(_ event: String) {
        logger.info("\(event, privacy: .public)")
        #if DEBUG
        print("StudyAudio: " + event)
        #endif
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
    @Published private(set) var phase: SpeechPlaybackPhase = .idle
    var playing: Bool { phase != .idle }
    @Published private(set) var notice: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var attachedPlayer: AVAudioPlayer?
    private var startWatchdog: Task<Void, Never>?
    private var audioObservers = Set<AnyCancellable>()

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        // Clear the queue on calls and output disconnection. Never resume an old
        // card's speech when the interruption ends or headphones reconnect.
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                SpeechDiagnostics.record("interruption type=\(type ?? 0)")
                if type == AVAudioSession.InterruptionType.began.rawValue { self?.stop() }
            }
            .store(in: &audioObservers)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   [.oldDeviceUnavailable, .newDeviceAvailable, .override, .routeConfigurationChange].contains(AVAudioSession.RouteChangeReason(rawValue: reason)) {
                    SpeechDiagnostics.record("routeChanged reason=\(reason)")
                    self?.stop()
                }
            }
            .store(in: &audioObservers)
    }

    func play(text: String, settings: SpeechPreferences) {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { unavailableReadout(.emptyText); return }
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard let index = SpeechVoiceSelection.index(languages: voices.map(\.language), accent: settings.accent) else {
            SpeechDiagnostics.record("unavailable reason=noEnglishVoice count=\(voices.count)")
            notice = "利用できる英語音声がありません。iPhoneのアクセシビリティ設定で英語音声を確認・ダウンロードしてください。"
            return
        }
        let voice = voices[index]
        notice = voice.language == settings.accent.rawValue ? nil : "指定した英語音声がないため、利用可能な英語音声（\(voice.language)）で再生します。"
        // Keep the existing silent-switch policy; explicit help explains how to hear audio.
        do { try prepareAudioSession() }
        catch {
            SpeechDiagnostics.record("failed source=tts reason=audioSession code=\((error as NSError).code)")
            notice = "音声出力を準備できませんでした。ほかの音声を停止して再生し直してください。"
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = settings.pace.rate
        activeUtterance = utterance; phase = .requested
        SpeechDiagnostics.record("requested source=tts accent=\(settings.accent.rawValue) voiceLanguage=\(voice.language)")
        startWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, self.activeUtterance === utterance, self.phase == .requested else { return }
            self.stop()
            self.notice = "読み上げが開始しませんでした。英語音声のダウンロードと音声出力先を確認して、再生し直してください。"
            SpeechDiagnostics.record("failed source=tts reason=startTimeout")
        }
        synthesizer.speak(utterance)
    }

    private func prepareAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.ambient, mode: .default)
        try session.setActive(true)
        let routes = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        SpeechDiagnostics.record("output category=ambient routeTypes=\(routes) volumeZero=\(session.outputVolume == 0)")
        if session.outputVolume == 0 { notice = "音量が0です。音量と出力先を確認してください。" }
    }
    func unavailableReadout(_ reason: SpeechReadoutFailure) {
        stop(); notice = reason.notice
        SpeechDiagnostics.record("unavailable reason=\(reason.rawValue)")
    }

    func stop() {
        if phase != .idle { SpeechDiagnostics.record("stopped phase=\(phase.rawValue)") }
        startWatchdog?.cancel(); startWatchdog = nil
        attachedPlayer?.stop(); attachedPlayer = nil
        activeUtterance = nil
        phase = .idle
        notice = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    func playAttached(url: URL) {
        stop()
        do {
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw AttachedAudioError.missing }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= AudioEncodingPolicy.maximumBytes else { throw AttachedAudioError.tooLarge }
            try prepareAudioSession()
            let player = try AVAudioPlayer(contentsOf: url)
            guard player.duration.isFinite, player.duration > 0, player.duration <= AudioEncodingPolicy.maximumDuration,
                  player.prepareToPlay() else { throw AttachedAudioError.invalid }
            player.delegate = self
            attachedPlayer = player
            SpeechDiagnostics.record("requested source=attachment")
            guard player.play() else { throw AttachedAudioError.invalid }
            phase = .attached
            SpeechDiagnostics.record("started source=attachment")
        } catch {
            attachedPlayer = nil; phase = .idle
            SpeechDiagnostics.record("failed source=attachment reason=invalidOrMissing")
            notice = error is AttachedAudioError ? error.localizedDescription : AttachedAudioError.invalid.localizedDescription
        }
    }
    func missingAttachment() {
        stop(); notice = AttachedAudioError.missing.localizedDescription
        SpeechDiagnostics.record("failed source=attachment reason=missing")
    }
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
            self.attachedPlayer = nil; self.phase = .idle
            SpeechDiagnostics.record(failed ? "failed source=attachment" : "finished source=attachment")
            if failed { self.notice = AttachedAudioError.invalid.localizedDescription }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let identity = SpeechUtteranceIdentity(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, identity.matches(self.activeUtterance) else { return }
            self.startWatchdog?.cancel(); self.startWatchdog = nil
            self.phase = .speaking
            SpeechDiagnostics.record("started source=tts")
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishOnMainQueue(utterance, cancelled: false)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishOnMainQueue(utterance, cancelled: true)
    }
    nonisolated private func finishOnMainQueue(_ utterance: AVSpeechUtterance, cancelled: Bool) {
        // Delegate delivery isn't actor-isolated. Retain the utterance until
        // this identity-only comparison so an older callback can't clear new speech.
        let identity = SpeechUtteranceIdentity(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self, identity.matches(self.activeUtterance) else { return }
            self.startWatchdog?.cancel(); self.startWatchdog = nil
            let neverStarted = self.phase == .requested
            self.activeUtterance = nil; self.phase = .idle
            if neverStarted && !cancelled {
                self.notice = "読み上げの開始を確認できませんでした。英語音声と出力先を確認して、再生し直してください。"
                SpeechDiagnostics.record("failed source=tts reason=finishedWithoutStart")
            }
            if cancelled { self.notice = "読み上げが中断されました。必要なら再生し直してください。" }
            SpeechDiagnostics.record(cancelled ? "cancelled source=tts" : "finished source=tts")
        }
    }
}

private struct AttachedPlayerIdentity: @unchecked Sendable {
    private let player: AVAudioPlayer
    init(_ player: AVAudioPlayer) { self.player = player }
    @MainActor func matches(_ current: AVAudioPlayer?) -> Bool { player === current }
}
