import SwiftUI

struct OrderingAnswerView: View {
    let problem: OrderingAnswer
    let draft: OrderingDraft
    let action: (OrderingAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("語句を順番に選んで英文を作成").font(.headline)
            Text("作成中の英文").font(.subheadline).foregroundStyle(.secondary)
            Text(draft.selected.isEmpty ? "（未選択）" : draft.selected.map { problem.tokens[$0].text }.joined(separator: " "))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("作成中の英文")
                .accessibilityValue(draft.selected.isEmpty ? "未選択" : draft.selected.map { problem.tokens[$0].text }.joined(separator: " "))
                .accessibilityIdentifier("orderingSentence")
            ChipFlowLayout {
                ForEach(Array(draft.selected.enumerated()), id: \.element) { index, id in
                    Button { action(.remove(id)) } label: { chip(problem.tokens[id].text) }
                        .accessibilityLabel("\(index + 1)番目の語句 \(spokenToken(problem.tokens[id].text)) を取り消す")
                        .accessibilityAction(named: "取り消す") { action(.remove(id)) }
                        .accessibilityIdentifier("ordering-selected-\(id)")
                }
            }
            .buttonStyle(.bordered).tint(Color("PrimaryAction"))
            Text("語句の候補").font(.subheadline).foregroundStyle(.secondary)
            ChipFlowLayout {
                ForEach(Array(draft.pool.enumerated()), id: \.element) { index, id in
                    if !draft.selected.contains(id) {
                        Button { action(.select(id)) } label: { chip(problem.tokens[id].text) }
                            .accessibilityLabel("語句 \(spokenToken(problem.tokens[id].text)) を選ぶ")
                            .accessibilityValue("候補\(index + 1)")
                            .accessibilityAction(named: "選ぶ") { action(.select(id)) }
                            .accessibilityIdentifier("ordering-token-\(id)")
                    }
                }
            }
            .buttonStyle(.bordered)
            Text("選択 \(draft.selected.count) / \(problem.tokens.count)語句")
                .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("orderingProgress")
            if let result = draft.result {
                Label(result == .correct ? "正解" : "不正解 — 語句を取り消すか、最初からやり直せます。",
                      systemImage: result == .correct ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(result == .correct ? Color("GradeGood") : Color("GradeAgain"))
                    .accessibilityIdentifier("orderingResult")
                Text(draft.evaluationGuidance).font(.footnote).foregroundStyle(.secondary)
            }
            Button("最初から") { action(.reset) }
                .buttonStyle(.bordered).disabled(draft.selected.isEmpty).accessibilityIdentifier("orderingReset")
            Button { action(.check) } label: {
                Text("正誤判定").font(.headline).frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent).tint(Color("PrimaryAction")).foregroundStyle(.white)
            .disabled(draft.selected.count != problem.tokens.count)
            .accessibilityIdentifier("checkOrdering")
            Text("登録された模範英文の語順と比較します。意味が近い別の英文を自動判定する機能ではありません。正誤判定だけでは学習履歴に記録しません。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
    // Read the word without terminal punctuation; the visible token retains the original.
    private func spokenToken(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"“”‘’'()[]{}"))
    }
    private func chip(_ text: String) -> some View {
        Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 32, minHeight: 36).padding(.vertical, 4)
    }
}

// Each chip keeps its intrinsic width; long words wrap at the available width.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 8
    private func positions(width: CGFloat, subviews: Subviews) -> ([CGPoint], [CGSize], CGFloat) {
        var positions: [CGPoint] = [], sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing; x = 0; rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y)); sizes.append(size)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (positions, sizes, y + rowHeight)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let width = max(1, proposal.width?.isFinite == true ? proposal.width! : ideal)
        return CGSize(width: width, height: positions(width: width, subviews: subviews).2)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (points, sizes, _) = positions(width: max(1, bounds.width), subviews: subviews)
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + points[index].x, y: bounds.minY + points[index].y),
                                 anchor: .topLeading, proposal: ProposedViewSize(sizes[index]))
        }
    }
}
