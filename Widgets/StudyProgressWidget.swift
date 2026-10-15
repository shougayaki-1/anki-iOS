import WidgetKit
import SwiftUI

struct StudyWidgetEntry: TimelineEntry {
    let date: Date
    let point: WidgetPoint?
    let goal: Int?
    let synced: Date?
}
struct StudyWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> StudyWidgetEntry { sample() }
    func getSnapshot(in context: Context, completion: @escaping (StudyWidgetEntry) -> Void) {
        if context.isPreview { completion(sample()) }
        else { completion(entry(at: Date(), snapshot: WidgetSnapshotFile.shared().read())) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StudyWidgetEntry>) -> Void) {
        let now = Date(), snapshot = WidgetSnapshotFile.shared().read()
        guard let snapshot, snapshot.point(at: now) != nil else {
            completion(Timeline(entries: [entry(at: now, snapshot: nil)], policy: .after(now.addingTimeInterval(3600))))
            return
        }
        let dates = [now] + snapshot.points.filter { $0.date > now }.map(\.date) + [snapshot.expiresAt]
        completion(Timeline(entries: dates.map { entry(at: $0, snapshot: snapshot) }, policy: .after(snapshot.expiresAt)))
    }
    private func entry(at date: Date, snapshot: WidgetSnapshot?) -> StudyWidgetEntry {
        let point = snapshot?.point(at: date)
        return StudyWidgetEntry(date: date, point: point, goal: point == nil ? nil : snapshot?.dailyGoal, synced: point == nil ? nil : snapshot?.generatedAt)
    }
    private func sample() -> StudyWidgetEntry {
        let date = Date()
        return StudyWidgetEntry(date: date, point: WidgetPoint(date: date, due: 12, newAvailable: 8, learnedToday: 7, answersToday: 10), goal: 20, synced: date)
    }
}
struct StudyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StudyWidgetEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("暗記ノート", systemImage: "rectangle.on.rectangle").font(.caption.bold())
            if let point = entry.point {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(point.due)").font(.system(family == .systemMedium ? .title2 : .largeTitle, design: .rounded).bold())
                        Text("復習待ち・全デッキ").font(.caption)
                    }.accessibilityElement(children: .combine)
                    if family == .systemMedium {
                        Spacer()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("新規 \(point.newAvailable)枚")
                            Text("回答 \(point.answersToday)回")
                        }.font(.subheadline)
                    }
                }.privacySensitive()
                if let goal = entry.goal {
                    ProgressView(value: Double(min(point.learnedToday, goal)), total: Double(goal)) {
                        Text("今日 \(point.learnedToday) / \(goal)枚").font(.caption)
                    }.privacySensitive()
                } else { Text("今日 \(point.learnedToday)枚を学習").font(.caption).privacySensitive() }
                if let synced = entry.synced {
                    Text("同期 \(synced.formatted(.dateTime.month().day().hour().minute()))").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("アプリを開いて更新").font(.headline)
                Text("情報が未取得・期限切れの場合は件数を表示しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if family == .systemMedium {
                HStack {
                    Link("復習を開く", destination: URL(string: "ankistudy://widget/review")!)
                    Spacer()
                    Link("進捗を見る", destination: URL(string: "ankistudy://widget/progress")!)
                }.font(.caption)
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(URL(string: "ankistudy://widget/home"))
        .accessibilityElement(children: .contain)
    }
}
struct StudyProgressWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.kind, provider: StudyWidgetProvider()) { StudyWidgetView(entry: $0) }
            .configurationDisplayName("復習と今日の進捗")
            .description("全デッキの保存済み復習予定と進捗を確認できます。問題文・答えは表示しません。更新はOSが制御します。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct DailyCardEntry: TimelineEntry {
    let date: Date
    let card: DailyWidgetCard?
    let available: Bool
}
struct DailyCardProvider: TimelineProvider {
    func placeholder(in context: Context) -> DailyCardEntry {
        DailyCardEntry(date: Date(), card: DailyWidgetCard(id: UUID(), deck: "英語", question: "思い出してみよう", requiresApp: false), available: true)
    }
    func getSnapshot(in context: Context, completion: @escaping (DailyCardEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyCardEntry>) -> Void) {
        let now = Date(), snapshot = WidgetSnapshotFile.shared().read()
        let expiry = snapshot?.dailyCardExpiresAt ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry(at: now), DailyCardEntry(date: max(expiry, now.addingTimeInterval(1)), card: nil, available: false)], policy: .after(max(expiry, now.addingTimeInterval(3600)))))
    }
    private func entry(at date: Date) -> DailyCardEntry {
        let snapshot = WidgetSnapshotFile.shared().read()
        let fresh = snapshot?.point(at: date) != nil && snapshot?.dailyCardExpiresAt.map { date < $0 } == true
        return DailyCardEntry(date: date, card: fresh ? snapshot?.dailyCard : nil, available: fresh)
    }
}
struct DailyCardView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DailyCardEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("今日の1枚").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if family == .systemMedium, let card = entry.card {
                    Spacer(minLength: 8)
                    Text(card.deck).font(.caption2).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                }
            }
            if let card = entry.card {
                if family != .systemMedium {
                    Text(card.deck).font(.caption2).foregroundStyle(.secondary).lineLimit(1).privacySensitive()
                }
                Text(card.question).font(.system(family == .systemSmall ? .title3 : .title2, design: .rounded).weight(.semibold))
                    .lineLimit(family == .systemSmall ? 3 : 2).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).privacySensitive()
                if family == .systemMedium {
                    HStack {
                        Text("このカード、わかる？").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Link(destination: card.url(answer: !card.requiresApp)) {
                            Text(card.requiresApp ? "アプリで問題を見る" : "アプリで答えを見る")
                                .font(.caption.bold()).frame(minHeight: 32)
                        }.buttonStyle(.borderedProminent).tint(Color("PrimaryAction"))
                    }
                } else {
                    Text("このカード、わかる？").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Spacer(minLength: 0)
                Label(entry.available ? "今の学習はひと区切り" : "アプリを開いて更新", systemImage: entry.available ? "checkmark.circle" : "rectangle.on.rectangle")
                    .font(.headline)
                Text(entry.available ? "次のカードはアプリで確認" : "今日のカードを用意しよう").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(entry.card?.url() ?? URL(string: "ankistudy://widget/home")!)
    }
}
struct DailyCardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DailyCardWidget", provider: DailyCardProvider()) { DailyCardView(entry: $0) }
            .configurationDisplayName("今日の1枚")
            .description("問題を見て、頭の中で回答。答えはアプリで確認できます。閲覧だけでは学習記録は変わりません。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
@main struct StudyWidgets: WidgetBundle {
    var body: some Widget { StudyProgressWidget(); DailyCardWidget() }
}

#Preview("今日の1枚・Small", as: .systemSmall) {
    DailyCardWidget()
} timeline: {
    DailyCardEntry(date: Date(), card: DailyWidgetCard(id: UUID(), deck: "英語 / 日常", question: "What does recall mean?", requiresApp: false), available: true)
}
#Preview("今日の1枚・Medium", as: .systemMedium) {
    DailyCardWidget()
} timeline: {
    DailyCardEntry(date: Date(), card: DailyWidgetCard(id: UUID(), deck: "日本史", question: "江戸幕府を開いた人物は？", requiresApp: false), available: true)
    DailyCardEntry(date: Date(), card: DailyWidgetCard(id: UUID(), deck: "長文のデッキ", question: String(repeating: "長い問題文の読みやすさを確認します。", count: 10), requiresApp: false), available: true)
    DailyCardEntry(date: Date(), card: nil, available: true)
    DailyCardEntry(date: Date(), card: nil, available: false)
}
