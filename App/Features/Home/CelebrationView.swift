import SwiftUI

struct CelebrationDay: Identifiable {
    let date: Date
    let studied: Bool
    let label: String
    var id: Date { date }
}

// Presentation values only. Achievement rules and durable delivery stay in #202.
struct CelebrationSummary: Identifiable {
    let events: [AchievementEvent]
    let days: [CelebrationDay]
    var id: String { events.map(\.id).joined(separator: "|") }
    var primary: AchievementEvent { events[0] }
    var secondary: [AchievementEvent] {
        events.dropFirst().filter { event in
            if event.kind == .firstStudyToday {
                return !events.contains { $0.kind == .streakAdvanced && $0.record.value > 1 && $0.record.studyDay == event.record.studyDay }
            }
            if event.kind == .streakAdvanced && event.record.value == 1 {
                return !events.contains { $0.kind == .firstStudyToday && $0.record.studyDay == event.record.studyDay }
            }
            return true
        }
    }
    static func priority(_ event: AchievementEvent) -> Int {
        switch event.kind {
        case .streakAdvanced:
            return event.record.value > 1 && AchievementProgress.streakMilestones.contains(event.record.value) ? 5 : event.record.value > 1 ? 2 : 0
        case .matureMilestone: return 4
        case .dailyGoalReached: return 3
        case .firstStudyToday: return 1
        }
    }
    init?(events: [AchievementEvent], days: [CelebrationDay] = []) {
        var ids = Set<String>()
        let unique = events.filter { ids.insert($0.id).inserted }
        guard !unique.isEmpty else { return nil }
        self.events = unique.sorted {
            let a = Self.priority($0), b = Self.priority($1)
            if a != b { return a > b }
            if $0.record.occurredAt != $1.record.occurredAt { return $0.record.occurredAt > $1.record.occurredAt }
            return $0.id < $1.id
        }
        self.days = days
    }
    var isSpecial: Bool { Self.priority(primary) >= 4 }
    var number: Int {
        primary.kind == .firstStudyToday ? 1 : primary.kind == .matureMilestone ? primary.record.threshold : primary.record.value
    }
    var unit: String {
        switch primary.kind {
        case .firstStudyToday: return "今日の一歩"
        case .streakAdvanced: return "日連続"
        case .dailyGoalReached: return "/ \(primary.record.threshold) 枚"
        case .matureMilestone: return "枚・長期定着（推定）"
        }
    }
    var headline: String {
        switch primary.kind {
        case .firstStudyToday: return "今日も一歩、\n積み重ねました"
        case .streakAdvanced: return isSpecial ? "続けた日々が、力になる" : "昨日から、また一歩前進"
        case .dailyGoalReached: return "今日の目標を達成！"
        case .matureMilestone: return "記憶が、育っています"
        }
    }
    var detail: String {
        switch primary.kind {
        case .firstStudyToday: return "今日初めての学習を記録しました。\n小さな一歩が、明日につながります。"
        case .streakAdvanced: return "\(primary.record.value)日連続で学習しました。\n\(isSpecial ? "大切な節目を迎えました。" : "今日の積み重ねも記録に残ります。")"
        case .dailyGoalReached: return "今日学習したユニークカード\(primary.record.value)枚。\n同じカードへの再回答は重複して数えません。"
        case .matureMilestone: return "長期定着\(primary.record.threshold)枚を達成！\nReview状態・FSRS Stability 21日以上の推定です。永久に覚えられる保証ではありません。"
        }
    }
}

enum CelebrationAction { case continueStudy, home, records }

struct CelebrationView: View {
    let summary: CelebrationSummary
    let canContinue: Bool
    let haptics: HapticsService
    let hapticsMode: HapticsMode
    let action: (CelebrationAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var appeared = false
    @State private var numberAppeared = false
    @State private var accentAppeared = false
    @State private var played = false

    private var motionReduced: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-study-test-reduce-motion") { return true }
        #endif
        return reduceMotion
    }
    private var color: Color {
        switch summary.primary.kind {
        case .firstStudyToday: return .teal
        case .streakAdvanced: return summary.isSpecial ? .orange : .red
        case .dailyGoalReached: return .blue
        case .matureMilestone: return .green
        }
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: summary.secondary.isEmpty ? 18 : 12) {
                    HStack {
                        Text(summary.isSpecial ? "大切な節目" : "今日の達成")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { action(.home) } label: {
                            Image(systemName: "xmark").font(.body.weight(.semibold))
                                .frame(width: 44, height: 44).background(.quaternary, in: Circle())
                        }.tint(.primary).accessibilityLabel("お祝いを閉じてホームへ")
                            .accessibilityIdentifier("closeCelebration")
                    }
                    Spacer(minLength: 8)
                    visual.scaleEffect(summary.secondary.isEmpty ? 0.85 : 0.65)
                        .frame(height: summary.secondary.isEmpty ? 150 : 110).accessibilityHidden(true)
                        .opacity(appeared ? 1 : 0).scaleEffect(appeared || motionReduced ? 1 : 0.88)
                    VStack(spacing: 8) {
                        Text(summary.number, format: .number)
                            .font(.system(size: summary.secondary.isEmpty ? 64 : 56, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(color)
                        Text(summary.unit).font(.title3.weight(.semibold))
                    }.opacity(numberAppeared ? 1 : 0)
                        .offset(y: numberAppeared || motionReduced ? 0 : 8)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("celebrationNumber")
                    VStack(spacing: 12) {
                        Text(summary.headline).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        Text(summary.detail).font(.subheadline).foregroundStyle(.secondary)
                        Text("達成日 \(summary.primary.record.studyDay)").font(.caption).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center)
                    if summary.primary.kind == .streakAdvanced { week }
                    if !summary.secondary.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("一緒に達成しました").font(.subheadline.weight(.semibold))
                            ForEach(summary.secondary) { event in
                                Label(event.record.title, systemImage: symbol(event.kind)).font(.subheadline)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
                    }
                    Spacer(minLength: 8)

                }.padding(.horizontal, 28).padding(.vertical, 12)
                    .frame(maxWidth: 560).frame(minHeight: max(0, geometry.size.height))
                    .frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)
                .background {
                    Color(uiColor: .systemBackground).ignoresSafeArea()
                    LinearGradient(colors: [color.opacity(0.12), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea()
                }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    action(canContinue ? .continueStudy : .home)
                } label: {
                    Text(canContinue ? "学習を続ける" : "ホームへ").font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }.buttonStyle(PrimaryActionStyle(capsule: true))
                    .accessibilityIdentifier("celebrationPrimary")
                Button("記録を見る") { action(.records) }.font(.body.weight(.semibold))
                    .buttonStyle(SecondaryActionStyle()).accessibilityIdentifier("celebrationRecords")
            }.padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 8)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemBackground))
        }
            .task {
                guard !played else { return }; played = true
                if motionReduced {
                    appeared = true; numberAppeared = true; accentAppeared = true
                    haptics.play(.sessionCompleted, mode: hapticsMode)
                    return
                }
                withAnimation(.easeOut(duration: 0.35)) { appeared = true }
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    withAnimation(.easeOut(duration: 0.4)) { numberAppeared = true }
                    if scenePhase == .active { haptics.play(.sessionCompleted, mode: hapticsMode) }
                    try await Task.sleep(for: .milliseconds(summary.isSpecial ? 500 : 250))
                    withAnimation(.easeOut(duration: summary.isSpecial ? 0.55 : 0.3)) { accentAppeared = true }
                } catch { appeared = true; numberAppeared = true; accentAppeared = true }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { appeared = true; numberAppeared = true; accentAppeared = true }
            }
    }
    @ViewBuilder private var visual: some View {
        switch summary.primary.kind {
        case .firstStudyToday:
            ZStack {
                Circle().fill(color.opacity(0.08)).frame(width: 168)
                Circle().fill(color.opacity(0.12)).frame(width: 120).scaleEffect(accentAppeared ? 1.12 : 1)
                Image(systemName: "sunrise.fill").font(.system(size: 74)).foregroundStyle(color)
            }
        case .streakAdvanced:
            ZStack {
                if summary.isSpecial {
                    Image(systemName: "laurel.leading").font(.system(size: 118)).offset(x: -80)
                    Image(systemName: "laurel.trailing").font(.system(size: 118)).offset(x: 80)
                }
                Image(systemName: "flame.fill").font(.system(size: summary.isSpecial ? 118 : 100))
                    .foregroundStyle(LinearGradient(colors: [.yellow, color], startPoint: .top, endPoint: .bottom))
                Image(systemName: "sparkle").font(.title).offset(x: 65, y: -60).opacity(accentAppeared ? 1 : 0)
            }.foregroundStyle(color.opacity(0.7))
        case .dailyGoalReached:
            ZStack {
                Circle().stroke(color.opacity(0.12), lineWidth: 12)
                Circle().trim(from: 0, to: accentAppeared ? 1 : 0.75).stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                Image(systemName: "trophy.fill").font(.system(size: 70)).foregroundStyle(color)
            }.frame(width: 166, height: 166)
        case .matureMilestone:
            ZStack {
                Ellipse().fill(color.opacity(0.12)).frame(width: 160, height: 32).offset(y: 73)
                Image(systemName: "leaf.fill").font(.system(size: 88)).rotationEffect(.degrees(-30)).offset(x: -24, y: 16)
                Image(systemName: "camera.macro").font(.system(size: 92)).offset(x: 25, y: -24)
                    .scaleEffect(accentAppeared ? 1 : 0.85)
            }.foregroundStyle(color)
        }
    }
    private var week: some View {
        VStack(spacing: 12) {
            Text("達成日までの7日間").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(summary.days) { day in
                    VStack(spacing: 8) {
                        Text(day.label).font(.caption)
                        Image(systemName: day.studied ? "flame.fill" : "minus")
                            .foregroundStyle(day.studied ? color : .secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(day.studied ? color.opacity(0.1) : Color.clear, in: Capsule())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted))、\(day.studied ? "学習済み" : "学習記録なし")")
                }
            }
        }
    }
    private func symbol(_ kind: AchievementKind) -> String {
        switch kind {
        case .firstStudyToday: return "sunrise.fill"
        case .streakAdvanced: return "flame.fill"
        case .dailyGoalReached: return "trophy.fill"
        case .matureMilestone: return "leaf.fill"
        }
    }
}
