import ActivityKit
import SwiftUI
import WidgetKit

struct StudySessionActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StudyActivityAttributes.self) { context in
            StudySessionActivityView(state: context.state, stale: context.isStale)
                .padding(16)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(Color.primary)
                .widgetURL(StudyActivityLink.url(sessionID: context.attributes.sessionID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("暗記学習", systemImage: "rectangle.on.rectangle.fill").font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.mode).font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StudySessionActivityView(state: context.state, stale: context.isStale, island: true)
                }
            } compactLeading: {
                Image(systemName: context.state.paused || context.isStale ? "pause.circle.fill" : "rectangle.on.rectangle.fill")
                    .foregroundStyle(Color(red: 0.55, green: 0.70, blue: 1))
            } compactTrailing: {
                Text(context.state.compactProgress).font(.caption2).monospacedDigit()
            } minimal: {
                Image(systemName: context.state.paused || context.isStale ? "pause.circle.fill" : "rectangle.on.rectangle.fill")
                    .foregroundStyle(Color(red: 0.55, green: 0.70, blue: 1))
            }
            .widgetURL(StudyActivityLink.url(sessionID: context.attributes.sessionID))
            .keylineTint(Color(red: 0.55, green: 0.70, blue: 1))
        }
    }
}

struct StudySessionActivityView: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: StudyActivityState
    var stale = false
    var island = false
    private var tint: Color { (island || colorScheme == .dark) ? Color(red: 0.55, green: 0.70, blue: 1) : Color(red: 0.133333, green: 0.333333, blue: 0.8) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !island { Text("暗記学習").font(.headline); Text(state.mode).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                Label(stale ? "再開できます" : state.status,
                      systemImage: stale || state.paused ? "pause.circle" : "book")
                    .font(.caption)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(state.progress).font(.title3.bold()).monospacedDigit()
                Spacer()
                if state.fixedCards, let total = state.total {
                    Text("残り\(max(0, total - state.answered))枚").font(.caption).foregroundStyle(.secondary)
                } else if state.total != nil {
                    Text("回答回数の上限").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let total = state.total, total > 0 {
                ProgressView(value: Double(min(state.answered, total)), total: Double(total)).tint(tint)
            }
            HStack {
                Spacer()
                Label("アプリで学習を再開", systemImage: "arrow.up.forward.app").font(.caption).foregroundStyle(tint)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("一時停止・固定復習", as: .content, using: StudyActivityAttributes(sessionID: "preview")) {
    StudySessionActivity()
} contentStates: {
    StudyActivityState(mode: "復習", answered: 8, total: 15, fixedCards: true, paused: true)
    StudyActivityState(mode: "新規", answered: 12, total: nil, fixedCards: false, paused: false)
}
