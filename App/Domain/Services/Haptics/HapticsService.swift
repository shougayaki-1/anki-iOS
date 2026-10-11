import UIKit
import CoreHaptics

enum HapticsMode: String, Codable, CaseIterable {
    case off, standard, rich
    var title: String {
        switch self { case .off: return "オフ"; case .standard: return "標準"; case .rich: return "豊か" }
    }
}

@MainActor
final class HapticsService {
    enum Event { case reveal, grade, undo, goal, orderingCorrect, orderingIncorrect, noteSaved }
    private var engine: CHHapticEngine?
    func play(_ event: Event, mode: HapticsMode) {
        guard mode != .off, UIApplication.shared.applicationState == .active else { return }
        if event == .goal, mode == .rich, CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            do {
                if engine == nil { engine = try CHHapticEngine(); engine?.isAutoShutdownEnabled = true }
                try engine?.start()
                let events = [0.0, 0.12, 0.27].map { time in
                    CHHapticEvent(eventType: .hapticTransient, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.65),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45)
                    ], relativeTime: time)
                }
                try engine?.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: 0)
                return
            } catch { engine = nil }
        }
        switch event {
        case .reveal: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .grade: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .undo: UISelectionFeedbackGenerator().selectionChanged()
        case .goal: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .noteSaved, .orderingCorrect: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .orderingIncorrect: UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
