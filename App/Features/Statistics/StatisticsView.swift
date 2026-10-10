import SwiftUI

struct StatisticsView: View {
    @Bindable var store: StudyStore
    var body: some View {
        NavigationStack {
            List {
                if let stats = store.statistics {
                    Section("今日の記録") {
                        LabeledContent("学習カード（ユニーク）", value: "\(store.counts.learnedToday)枚")
                        LabeledContent("回答回数", value: "\(store.counts.answerCount)回").accessibilityIdentifier("todayAnswerCount")
                        LabeledContent("継続日数", value: "\(stats.streak)日")
                        Text("全デッキの記録。学習日の切替は午前\(store.settings.dayStartHour)時です。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("自己評価（全履歴）") {
                        ForEach(ReviewGrade.allCases, id: \.self) { grade in
                            LabeledContent(String(describing: grade).capitalized, value: "\(stats.ratings[grade, default: 0])回")
                        }
                        LabeledContent("回答時間の合計", value: "\(stats.durationMs / 60000)分")
                    }
                    Section("予測保持率") {
                        if let retention = stats.meanRetrievability {
                            LabeledContent("現在の平均想起確率", value: retention.formatted(.percent.precision(.fractionLength(1))))
                        } else { Text("まだ学習済みカードがありません。") }
                        Text("停止中・未学習カードを除き、FSRSの安定性と現在日時から計算した予測です。実際の正答率ではありません。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("過去30日") {
                        ForEach(stats.days) { day in
                            LabeledContent(day.date.formatted(.dateTime.month().day()), value: "\(day.cards)枚 · \(day.answers)回")
                        }
                    }
                } else { ContentUnavailableView("記録を読み込めません", systemImage: "chart.bar") }
            }.navigationTitle("記録")
        }
    }
}
