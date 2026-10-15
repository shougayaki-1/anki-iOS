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
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    let entry: DailyCardEntry
    var body: some View {
        Group {
            // Background removal also occurs outside StandBy; this layout fits those contexts too.
            if family == .systemSmall && !showsBackground {
                DailyCardGlanceView(entry: entry)
            } else {
                homeContent
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(entry.card?.url() ?? URL(string: "ankistudy://widget/home")!)
    }
    private var homeContent: some View {
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
    }
}

// A question-only presentation. The provider, selection and navigation remain shared.
struct DailyCardGlanceView: View {
    let entry: DailyCardEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今日の1枚").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let card = entry.card {
                ViewThatFits(in: .vertical) {
                    if !card.requiresApp {
                        question(card.question, size: 28)
                        question(card.question, size: 24)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: card.requiresApp ? "photo" : "text.alignleft")
                            .font(.title2)
                        Text("アプリで問題を見る")
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .privacySensitive()
                Text("タップして確認").font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 0)
                Label(entry.available ? "今の学習はひと区切り" : "アプリを開いて更新",
                      systemImage: entry.available ? "checkmark.circle" : "arrow.clockwise")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.primary)
    }
    private func question(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)
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
    var body: some Widget { StudyProgressWidget(); DailyCardWidget(); StudyStreakWidget(); ReviewForecastWidget(); StudySessionActivity() }
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


struct StreakEntry: TimelineEntry {
    let date: Date
    let day: WidgetStreakDay?
    let goal: Int?
}
struct StreakProvider: TimelineProvider {
    func placeholder(in context: Context) -> StreakEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (StreakEntry) -> Void) {
        completion(context.isPreview ? .sample : entry(Date(), WidgetSnapshotFile.shared().read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StreakEntry>) -> Void) {
        let now = Date(), snapshot = WidgetSnapshotFile.shared().read()
        guard let snapshot, snapshot.streak(at: now) != nil else {
            completion(Timeline(entries: [entry(now, nil)], policy: .after(now.addingTimeInterval(3600))))
            return
        }
        let dates = [now] + (snapshot.streakDays ?? []).map(\.date).filter { $0 > now && $0 < snapshot.expiresAt } + [snapshot.expiresAt]
        completion(Timeline(entries: dates.map { entry($0, snapshot) }, policy: .after(snapshot.expiresAt)))
    }
    private func entry(_ date: Date, _ snapshot: WidgetSnapshot?) -> StreakEntry {
        StreakEntry(date: date, day: snapshot?.streak(at: date), goal: snapshot?.dailyGoal)
    }
}
extension StreakEntry {
    static var sample: Self {
        Self(date: Date(), day: WidgetStreakDay(date: Calendar.current.startOfDay(for: Date()), streak: 7, cards: 12,
            recent: [true, true, true, true, true, true, true]), goal: 20)
    }
}
struct StreakWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: StreakEntry
    private var primary: Color { widgetPrimaryColor(colorScheme) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let day = entry.day {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: day.studied ? "flame.fill" : "flame")
                                .foregroundStyle(day.studied ? primary : .secondary)
                            Text("連続学習").foregroundStyle(.secondary)
                        }.font(.caption.weight(.semibold))
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(day.streak)").font(.system(size: family == .systemSmall ? 44 : 36, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                            Text("日").font(.subheadline.weight(.semibold))
                        }.lineLimit(1)
                        if family == .systemMedium {
                            Text(day.studied ? "今日も学習済み" : (day.streak > 0 ? "昨日まで継続中" : "今日の1枚から"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: family == .systemMedium ? 98 : nil, alignment: .leading)
                    if family == .systemMedium {
                        Spacer(minLength: 0)
                        week(day)
                    }
                }
                Spacer(minLength: 0)
                if family == .systemSmall {
                    Label(day.studied ? "今日は学習済み" : "今日の1枚から", systemImage: day.studied ? "checkmark.circle.fill" : "plus.circle")
                        .font(.caption.weight(.semibold)).foregroundStyle(day.studied ? primary : .primary)
                    Text(day.studied ? "記録を見る ›" : (day.streak > 0 ? "昨日まで継続中" : "アプリで学習 ›")).font(.caption).foregroundStyle(.secondary)
                } else if let goal = entry.goal {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(day.cards >= goal ? "今日の目標を達成" : "今日の目標", systemImage: day.cards >= goal ? "checkmark.seal.fill" : "circle.dotted")
                            Spacer(minLength: 4)
                            Text("\(day.cards) / \(goal)枚").monospacedDigit()
                        }.font(.caption.weight(.semibold))
                        ProgressView(value: Double(min(day.cards, goal)), total: Double(goal)).tint(primary)
                    }
                } else {
                    HStack {
                        Label(day.studied ? "今日は学習済み" : "今日の1枚から", systemImage: day.studied ? "checkmark.circle.fill" : "plus.circle")
                        Spacer()
                        Text("今日 \(day.cards)枚")
                    }.font(.caption.weight(.semibold))
                }
            } else {
                Label("毎日の積み重ね", systemImage: "flame").font(.headline).foregroundStyle(primary)
                Spacer(minLength: 0)
                Text("アプリを開いて更新").font(.subheadline.weight(.semibold))
                Text("最新の学習記録を確認しよう").font(.caption).foregroundStyle(.secondary)
            }
        }
        .privacySensitive()
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(URL(string: entry.day?.studied == true ? "ankistudy://widget/progress" : "ankistudy://widget/home"))
    }
    private func week(_ day: WidgetStreakDay) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { index in
                let date = Calendar.current.date(byAdding: .day, value: index - 6, to: day.date) ?? day.date
                VStack(spacing: 5) {
                    Text(index == 6 ? "今日" : date.formatted(.dateTime.weekday(.narrow))).font(.system(size: 11, weight: index == 6 ? .bold : .regular))
                    Image(systemName: day.recent[index] ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16)).foregroundStyle(day.recent[index] ? primary : Color.secondary.opacity(0.4))
                    Text("\(Calendar.current.component(.day, from: date))").font(.system(size: 11)).monospacedDigit()
                }
                .frame(width: 22)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(date.formatted(.dateTime.month().day()))、\(day.recent[index] ? "学習済み" : "未学習")")
            }
        }
    }
}
struct StudyStreakWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StudyStreakWidget", provider: StreakProvider()) { StreakWidgetView(entry: $0) }
            .configurationDisplayName("毎日の積み重ね")
            .description("連続学習と直近7日、今日の目標をひと目で。保存済みの学習記録を表示します。更新時刻はOSが調整します。")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
#Preview("Streak・Small", as: .systemSmall) { StudyStreakWidget() } timeline: {
    StreakEntry.sample
    StreakEntry(date: Date(), day: WidgetStreakDay(date: Date(), streak: 6, cards: 0, recent: [true, true, true, true, true, true, false]), goal: 20)
    StreakEntry(date: Date(), day: nil, goal: nil)
}
#Preview("Streak・Medium", as: .systemMedium) { StudyStreakWidget() } timeline: {
    StreakEntry.sample
    StreakEntry(date: Date(), day: WidgetStreakDay(date: Date(), streak: 7, cards: 20, recent: [true, true, true, true, true, true, true]), goal: 20)
    StreakEntry(date: Date(), day: WidgetStreakDay(date: Date(), streak: 0, cards: 0, recent: [true, false, true, true, false, false, false]), goal: nil)
}

struct ForecastEntry: TimelineEntry {
    let date: Date
    let forecast: WidgetReviewForecast?
}
struct ForecastProvider: TimelineProvider {
    func placeholder(in context: Context) -> ForecastEntry { .sample }
    func getSnapshot(in context: Context, completion: @escaping (ForecastEntry) -> Void) {
        let now = Date()
        completion(context.isPreview ? .sample : ForecastEntry(date: now, forecast: WidgetSnapshotFile.shared().read()?.forecast(at: now)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ForecastEntry>) -> Void) {
        let now = Date(), snapshot = WidgetSnapshotFile.shared().read()
        let expiry = max(snapshot?.dailyCardExpiresAt ?? now, now.addingTimeInterval(1))
        completion(Timeline(entries: [ForecastEntry(date: now, forecast: snapshot?.forecast(at: now)),
            ForecastEntry(date: expiry, forecast: nil)], policy: .after(max(expiry, now.addingTimeInterval(3600)))))
    }
}
extension ForecastEntry {
    static var sample: Self {
        let now = Date(), start = Calendar.current.startOfDay(for: now)
        return Self(date: now, forecast: WidgetReviewForecast(days: [2, 8, 24, 5, 0, 12, 3].enumerated().map {
            WidgetForecastDay(date: Calendar.current.date(byAdding: .day, value: $0.offset, to: start)!, count: $0.element)
        }, overdue: 6, card: DailyWidgetCard(id: UUID(), deck: "英語", question: "What does recall mean?", requiresApp: false)))
    }
}
struct ForecastWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: ForecastEntry
    private let home = URL(string: "ankistudy://widget/home")!
    private let progress = URL(string: "ankistudy://widget/progress")!
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("これからの復習").font(.subheadline.bold())
                Spacer(minLength: 4)
                if let forecast = entry.forecast, forecast.overdue > 0 {
                    Text("期限超過 \(forecast.overdue)枚").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let forecast = entry.forecast {
                Link(destination: progress) {
                    VStack(alignment: .leading, spacing: 3) {
                        chart(forecast)
                        if let peak = forecast.days.max(by: { $0.count < $1.count }), peak.count > 0 {
                            Text("\(peak.date.formatted(.dateTime.month().day().weekday(.wide)))に最多 \(peak.count)枚")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text("7日間の復習予定はありません").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Link(destination: forecast.card?.url() ?? home) {
                    HStack(spacing: 5) {
                        Image(systemName: forecast.card == nil ? "checkmark.circle" : "rectangle.on.rectangle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(forecast.card == nil ? "今の復習はひと区切り" : "そろそろ復習したい1枚 ›").font(.caption.bold())
                            if let card = forecast.card {
                                Text(card.requiresApp ? "画像の問題はアプリで確認" : card.question)
                                    .font(.caption2).lineLimit(1).privacySensitive()
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text("保存済み期限・学習で予定は変わります").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Spacer(minLength: 0)
                Text("アプリを開いて更新").font(.headline)
                Text("最新の復習予定を確認しよう").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(home)
    }
    private func chart(_ forecast: WidgetReviewForecast) -> some View {
        let peak = forecast.days.map(\.count).max() ?? 0
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(forecast.days, id: \.date) { day in
                VStack(spacing: 2) {
                    Text("\(day.count)").font(.system(size: 9, weight: day.count == peak ? .semibold : .regular)).monospacedDigit()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(day.count == 0 ? Color.secondary.opacity(0.18) : widgetPrimaryColor(colorScheme).opacity(day.count == peak ? 1 : 0.65))
                        // Square-root scale keeps small days visible beside a large peak.
                        .frame(height: day.count == 0 ? 2 : 3 + 15 * sqrt(Double(day.count) / Double(max(peak, 1))))
                        .frame(height: 18, alignment: .bottom)
                    Text(day.date.formatted(.dateTime.day().weekday(.narrow)))
                        .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.date.formatted(.dateTime.month().day().weekday())), \(day.count)枚予定")
            }
        }
    }
}
struct ReviewForecastWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ReviewForecastWidget", provider: ForecastProvider()) { ForecastWidgetView(entry: $0) }
            .configurationDisplayName("これからの復習")
            .description("今の学習範囲の7日間の保存済み期限と、そろそろ復習したい1枚。FSRSの推定を利用します。更新時刻はOSが調整します。")
            .supportedFamilies([.systemMedium])
    }
}
#Preview("これからの復習", as: .systemMedium) { ReviewForecastWidget() } timeline: {
    ForecastEntry.sample
    ForecastEntry(date: Date(), forecast: nil)
}

private func widgetPrimaryColor(_ colorScheme: ColorScheme) -> Color {
    guard colorScheme == .dark else { return Color("PrimaryAction") }
    // The shared action color is designed as a filled button background.
    // Lift the same hue for small foreground symbols on dark widget surfaces.
    let color = (UIColor(named: "PrimaryAction") ?? .systemBlue)
        .resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return Color(red: Double(red * 0.65 + 0.35), green: Double(green * 0.65 + 0.35), blue: Double(blue * 0.65 + 0.35))
}
