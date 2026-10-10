import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct OrderingAnswerView: View {
    let problem: OrderingAnswer
    let draft: OrderingDraft
    var hapticsEnabled = false
    let action: (OrderingAction) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggedID: Int?
    @State private var insertionIndex: Int?
    @State private var tokenFrames: [Int: CGRect] = [:]
    @State private var selectionPulse = 0
    @State private var liftPulse = 0
    @State private var dropPulse = 0
    @State private var lastPositionFeedback = Date.distantPast

    // A private type prevents accepting unrelated text dragged from another app.
    private static let dragType = UTType(exportedAs: "dev.shoug.anki-ios.ordering-token")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("語句を順番に選んで英文を作成").font(.headline)
            Text("作成中の英文").font(.subheadline).foregroundStyle(.secondary)
            Text(draft.selected.isEmpty ? "（未選択）" : sentence(draft.selected))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("作成中の英文")
                .accessibilityValue(draft.selected.isEmpty ? "未選択" : sentence(draft.selected))
                .accessibilityIdentifier("orderingSentence")

            selectedChips
            Text("語句の候補").font(.subheadline).foregroundStyle(.secondary)
            ChipFlowLayout {
                ForEach(Array(draft.pool.enumerated()), id: \.element) { index, id in
                    if !draft.selected.contains(id) {
                        Button {
                            action(.select(id))
                            selectionPulse += 1
                        } label: { chip(problem.tokens[id].text) }
                            .accessibilityLabel("語句 \(spokenToken(problem.tokens[id].text)) を選ぶ")
                            .accessibilityValue("候補\(index + 1)")
                            .accessibilityAction(named: "選ぶ") {
                                action(.select(id))
                                selectionPulse += 1
                            }
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
        .sensoryFeedback(trigger: selectionPulse) { _, _ in hapticsEnabled ? .selection : nil }
        .sensoryFeedback(trigger: liftPulse) { _, _ in
            hapticsEnabled ? .impact(weight: .light, intensity: 0.45) : nil
        }
        .sensoryFeedback(trigger: dropPulse) { _, _ in
            hapticsEnabled ? .impact(weight: .light, intensity: 0.55) : nil
        }
        .onChange(of: draft.selected) { _, _ in
            // The persisted draft is authoritative after a tap or a committed drag.
            draggedID = nil
            insertionIndex = nil
        }
        .onChange(of: draft.cardID) { _, _ in
            draggedID = nil
            insertionIndex = nil
            tokenFrames = [:]
        }
        .onDisappear {
            draggedID = nil
            insertionIndex = nil
        }
    }

    private var selectedChips: some View {
        ChipFlowLayout {
            ForEach(Array(draft.selected.enumerated()), id: \.element) { index, id in
                Button {
                    action(.remove(id))
                    selectionPulse += 1
                } label: { chip(problem.tokens[id].text) }
                    .accessibilityLabel("\(index + 1)番目の語句 \(spokenToken(problem.tokens[id].text)) を取り消す")
                    .accessibilityValue("現在の位置 \(index + 1) / \(draft.selected.count)")
                    .accessibilityHint("タップで取り消します。長押ししてドラッグ、またはVoiceOverのアクションで移動できます。")
                    .accessibilityActions {
                        if index > 0 {
                            Button("前へ移動") { accessibleMove(id, to: index - 1) }
                            Button("先頭へ移動") { accessibleMove(id, to: 0) }
                        }
                        if index < draft.selected.count - 1 {
                            Button("後ろへ移動") { accessibleMove(id, to: index + 1) }
                            Button("末尾へ移動") { accessibleMove(id, to: draft.selected.count - 1) }
                        }
                    }
                    .accessibilityIdentifier("ordering-selected-\(id)")
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: OrderingChipFramesKey.self,
                                value: [id: proxy.frame(in: .named("ordering-selected-flow"))]
                            )
                        }
                    }
                    .onDrag {
                        draggedID = id
                        insertionIndex = nil
                        liftPulse += 1
                        // The payload is local to this view; the persistent identity is the token ID.
                        let payload = Data("\(draft.cardID.uuidString):\(id)".utf8)
                        return NSItemProvider(item: payload as NSData, typeIdentifier: Self.dragType.identifier)
                    } preview: {
                        chip(problem.tokens[id].text)
                            .padding(.horizontal, 8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .shadow(radius: 5, y: 3)
                    }
            }
        }
        .buttonStyle(.bordered).tint(Color("PrimaryAction"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: "ordering-selected-flow")
        .contentShape(Rectangle())
        .onPreferenceChange(OrderingChipFramesKey.self) { tokenFrames = $0 }
        .onDrop(of: [Self.dragType.identifier], delegate: OrderingSelectedDropDelegate(
            acceptedType: Self.dragType.identifier,
            canAccept: { draggedID.map { draft.selected.contains($0) } ?? false },
            hovering: { location in updateInsertion(at: location) },
            dropped: { commitDrag() },
            exited: { insertionIndex = nil }
        ))
        .overlay(alignment: .topLeading) {
            if let guide = insertionGuide {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: guide.height)
                    .position(x: guide.x, y: guide.y)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: draft.selected)
        .accessibilityIdentifier("orderingSelectedFlow")
    }

    // Return an insertion slot between tokens, including row beginnings/ends.
    private func updateInsertion(at point: CGPoint) {
        guard draggedID != nil,
              let proposed = OrderingInsertionLocation.resolve(point, ids: draft.selected, frames: tokenFrames),
              proposed != insertionIndex else { return }
        let wasTargeted = insertionIndex != nil
        insertionIndex = proposed
        if wasTargeted && Date().timeIntervalSince(lastPositionFeedback) >= 0.10 {
            selectionPulse += 1
            lastPositionFeedback = Date()
        }
    }

    private func commitDrag() -> Bool {
        defer {
            insertionIndex = nil
            draggedID = nil
        }
        guard let id = draggedID, let source = draft.selected.firstIndex(of: id),
              let slot = insertionIndex else { return false }
        // Slot is indexed before removal; the model takes the final index after removal.
        let destination = slot > source ? slot - 1 : slot
        guard destination != source else { return true }
        action(.move(id, to: destination))
        dropPulse += 1
        return true
    }

    private var insertionGuide: (x: CGFloat, y: CGFloat, height: CGFloat)? {
        guard let index = insertionIndex, !draft.selected.isEmpty else { return nil }
        if index < draft.selected.count, let frame = tokenFrames[draft.selected[index]] {
            return (max(1.5, frame.minX - 4), frame.midY, max(44, frame.height))
        }
        if let frame = tokenFrames[draft.selected[draft.selected.count - 1]] {
            return (frame.maxX + 4, frame.midY, max(44, frame.height))
        }
        return nil
    }

    private func accessibleMove(_ id: Int, to destination: Int) {
        guard let source = draft.selected.firstIndex(of: id),
              draft.selected.indices.contains(destination), source != destination else { return }
        var updated = draft.selected
        updated.remove(at: source)
        updated.insert(id, at: destination)
        action(.move(id, to: destination))
        selectionPulse += 1
        UIAccessibility.post(notification: .announcement,
                             argument: "\(destination + 1)番目へ移動。現在の英文: \(sentence(updated))")
    }

    private func sentence(_ ids: [Int]) -> String {
        ids.map { problem.tokens[$0].text }.joined(separator: " ")
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

private struct OrderingChipFramesKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] { [:] }
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// The selected chips remain in their original flow layout while dragging.
// Distances are computed in flow-local coordinates, so a drop in inter-chip
// whitespace or a different wrapped row resolves to the nearest row and slot.
enum OrderingInsertionLocation {
    private struct Entry {
        let index: Int
        let frame: CGRect
    }
    private struct Row {
        var entries: [Entry]
        var minY: CGFloat { entries.map(\.frame.minY).min() ?? 0 }
        var maxY: CGFloat { entries.map(\.frame.maxY).max() ?? 0 }
        func distance(to y: CGFloat) -> CGFloat {
            max(minY - y, y - maxY, 0)
        }
    }

    static func resolve(_ point: CGPoint, ids: [Int], frames: [Int: CGRect]) -> Int? {
        let entries = ids.enumerated().compactMap { index, id -> Entry? in
            guard let frame = frames[id], frame.width > 0, frame.height > 0 else { return nil }
            return Entry(index: index, frame: frame)
        }
        guard !entries.isEmpty else { return nil }
        var rows: [Row] = []
        for entry in entries {
            if let last = rows.indices.last,
               let first = rows[last].entries.first,
               abs(entry.frame.midY - first.frame.midY) < min(entry.frame.height, first.frame.height) / 2 {
                rows[last].entries.append(entry)
            } else {
                rows.append(Row(entries: [entry]))
            }
        }
        guard let row = rows.min(by: { $0.distance(to: point.y) < $1.distance(to: point.y) }) else {
            return nil
        }
        for entry in row.entries where point.x < entry.frame.midX {
            return entry.index
        }
        return (row.entries.last?.index ?? 0) + 1
    }
}

private struct OrderingSelectedDropDelegate: DropDelegate {
    let acceptedType: String
    let canAccept: () -> Bool
    let hovering: (CGPoint) -> Void
    let dropped: () -> Bool
    let exited: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        canAccept() && info.hasItemsConforming(to: [acceptedType])
    }
    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { hovering(info.location) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return DropProposal(operation: .cancel) }
        hovering(info.location)
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        hovering(info.location)
        return dropped()
    }
    func dropExited(info: DropInfo) { exited() }
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
