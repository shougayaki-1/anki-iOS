import Foundation
#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

// No card content, deck names, or elapsed-time data crosses the extension boundary.
struct StudyActivityState: Codable, Hashable {
    let mode: String
    let answered: Int
    let total: Int?
    let fixedCards: Bool
    var paused: Bool

    var unit: String { fixedCards ? "枚" : "回答" }
    var compactProgress: String { total.map { "\(answered)/\($0)" } ?? "\(answered)回答" }
    var progress: String { total.map { "\(answered) / \($0)\(unit)" } ?? "\(answered)回答" }
    var status: String { paused ? "一時停止中" : "学習中" }
}

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
struct StudyActivityAttributes: ActivityAttributes {
    typealias ContentState = StudyActivityState
    let sessionID: String
}
#endif

enum StudyActivityLink {
    static func url(sessionID: String) -> URL {
        var parts = URLComponents(string: "ankistudy://session/resume")!
        parts.queryItems = [URLQueryItem(name: "id", value: sessionID)]
        return parts.url!
    }
    static func sessionID(_ url: URL) -> String? {
        guard url.scheme == "ankistudy", url.host == "session", url.path == "/resume" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }
}
