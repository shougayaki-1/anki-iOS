import AVFoundation
import Combine
import Foundation

/// Owns only disposable audio; never writes to the media store or study repository.
@MainActor
final class PronunciationPractice: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    enum Phase: Equatable { case idle, requestingPermission, recording, ready, playing }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var notice: String?
    @Published private(set) var permissionDenied = false
    @Published private(set) var startedAt: Date?
    private var ownsSession = false
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var file: URL?
    private var generation = UUID()
    private let requestPermission: (@escaping (Bool) -> Void) -> Void
    private var observers: [AnyCancellable] = []
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("PronunciationPractice", isDirectory: true) }

    static func cleanAbandonedRecordings() { try? FileManager.default.removeItem(at: directory) }

    init(requestPermission: @escaping (@escaping (Bool) -> Void) -> Void = { AVAudioApplication.requestRecordPermission(completionHandler: $0) }) {
        self.requestPermission = requestPermission
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] notification in
                Task { @MainActor in
                    if name == AVAudioSession.interruptionNotification,
                       notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt != AVAudioSession.InterruptionType.began.rawValue { return }
                    if name == AVAudioSession.routeChangeNotification,
                       notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.categoryChange.rawValue { return }
                    guard let self, self.phase == .recording || self.phase == .playing else { return }
                    self.discard()
                    self.notice = "音声が中断されました。もう一度録音できます。"
                }
            }.store(in: &observers)
        }
    }

    func start() async {
        guard phase != .requestingPermission else { return }
        discard()
        let token = generation
        phase = .requestingPermission
        let granted = await withCheckedContinuation { continuation in
            requestPermission { continuation.resume(returning: $0) }
        }
        guard token == generation else { return }
        permissionDenied = !granted
        guard granted else {
            phase = .idle
            notice = "マイクを使うには、設定でマイクへのアクセスを許可してください。"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            ownsSession = true
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let url = Self.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            file = url
            let recorder = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            self.recorder = recorder
            recorder.delegate = self
            guard recorder.record(forDuration: 120) else { throw PracticeError.unavailable }
            startedAt = Date()
            phase = .recording
        } catch { fail("録音を開始できません。マイクと音声出力先を確認してください。") }
    }

    func stopRecording() {
        guard phase == .recording else { return }
        recorder?.stop()
        startedAt = nil
        phase = .ready
        deactivate()
    }

    func play() {
        guard let file, phase == .ready else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            ownsSession = true
            let player = try AVAudioPlayer(contentsOf: file)
            self.player = player
            player.delegate = self
            guard player.play() else { throw PracticeError.unavailable }
            phase = .playing
        } catch { fail("録音を再生できません。もう一度録音してください。") }
    }

    func stopPlayback() {
        guard phase == .playing else { return }
        player?.stop()
        player = nil
        phase = .ready
        deactivate()
    }

    func discard() {
        generation = UUID() // Invalidates a permission response after card changes/backgrounding.
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        phase = .idle
        startedAt = nil
        notice = nil
        permissionDenied = false
        deactivate()
    }

    private func deactivate() {
        guard ownsSession else { return }; ownsSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    private func fail(_ message: String) { discard(); notice = message }
    private enum PracticeError: Error { case unavailable }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            if flag { self.startedAt = nil; self.phase = .ready; self.deactivate() }
            else { self.fail("録音が中断されました。もう一度録音してください。") }
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in guard self.recorder === recorder else { return }; self.fail("録音を保存できません。もう一度録音してください。") }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in guard self.player === player else { return }; self.stopPlayback() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in guard self.player === player else { return }; self.fail("録音を再生できません。もう一度録音してください。") }
    }
}
