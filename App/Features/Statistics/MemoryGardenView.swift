import SwiftUI

struct MemoryGrowthSection: View {
    let store: StudyStore
    let groups: [MemoryGrowthGroup]
    @State private var selected: GardenStage?
    @State private var growth: GardenGrowth?
    @State private var growthProgress = 1.0
    @State private var visible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var total: Int { groups.reduce(0) { $0 + $1.cards.count } }
    private var chosen: MemoryGrowthGroup? { groups.first { $0.stage == selected } }

    var body: some View {
        DashboardCard(title: "記憶の庭", subtitle: "学んだ記憶を、少しずつ育てる") {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text((groups.last?.cards.count ?? 0).formatted())
                    .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
                Text("枚が長期定着（推定）").font(.subheadline)
            }
            MemoryGardenScene(counts: groups.map { $0.cards.count }, selected: selected, growingFrom: growth?.from, growingTo: growth?.to, progress: growthProgress)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .onGeometryChange(for: Bool.self) { geometry in
                    let frame = geometry.frame(in: .global)
                    return frame.minY >= 60 && frame.maxY <= UIScreen.main.bounds.height - 100
                } action: { visible = $0 }
                .accessibilityLabel("記憶の庭、対象\(total)枚。植物は構成比を表す象徴です。")
                .accessibilityIdentifier("memoryGarden")
            if let growth {
                Text("学習で、\(growth.from.title)から\(growth.to.title)へ")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.accentColor).accessibilityIdentifier("gardenGrowthStatus")
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(groups) { group in
                    Button { selected = selected == group.stage ? nil : group.stage } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Circle().fill(group.stage.gardenColor).frame(width: 7, height: 7)
                                Text(group.id).font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                                if selected == group.stage { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(group.cards.count)枚").font(.headline).monospacedDigit()
                                Text(total == 0 ? "—" : (Double(group.cards.count) / Double(total)).formatted(.percent.precision(.fractionLength(1))))
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }.fixedSize(horizontal: true, vertical: false)
                        }
                        .foregroundStyle(.primary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected == group.stage ? Color.accentColor.opacity(0.08) : Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected == group.stage ? Color.accentColor : .clear, lineWidth: 1.5))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selected == group.stage ? [.isSelected] : [])
                        .accessibilityIdentifier("garden-" + group.id)
                }
            }
            if let chosen {
                VStack(alignment: .leading, spacing: 8) {
                    Text(chosen.explanation).font(.caption).foregroundStyle(.secondary)
                    NavigationLink {
                        MemoryEvidenceCardsView(store: store, ids: chosen.cards.map(\.id), cards: chosen.cards)
                    } label: {
                        HStack {
                            Text("\(chosen.id)のカード \(chosen.cards.count)枚")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }.font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("gardenCards")
                }
            }
            Text(total == 0 ? "まだ静かな庭です。対象カードを追加するか、絞り込みを変更してください。" : "停止・休止を除く\(total)枚。植物の本数は象徴です。分類を選ぶと対象カードを確認できます。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            NavigationLink { MemoryAnalysisView(store: store) } label: {
                HStack {
                    Text("正確な記憶統計を見る")
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption)
                }.font(.subheadline).frame(minHeight: 44)
            }.accessibilityIdentifier("gardenStatistics")
            Text("花はReview状態・Stability 21日以上のFSRS推定。永久記憶の保証ではありません。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: visible && store.selectedTab == 2 && scenePhase == .active) {
            guard visible, store.selectedTab == 2, scenePhase == .active else { growth = nil; growthProgress = 1; return }
            let claimed = store.claimGardenGrowth(groups: groups)
            #if DEBUG
            let forcedReduction = ProcessInfo.processInfo.arguments.contains("-study-test-reduce-motion")
            #else
            let forcedReduction = false
            #endif
            guard !reduceMotion, !forcedReduction, !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
            growth = claimed
            guard claimed != nil else { return }
            growthProgress = 0
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            guard !Task.isCancelled, visible, scenePhase == .active else { return }
            withAnimation(.easeInOut(duration: 0.6)) { growthProgress = 1 }
        }
        .onDisappear { growth = nil; growthProgress = 1 }
        .onChange(of: scenePhase) { _, phase in if phase != .active { growth = nil; growthProgress = 1 } }
        .onChange(of: reduceMotion) { _, _ in growth = nil; growthProgress = 1 }
        // A scope change is a new landscape, never a growth event.
        .onChange(of: store.statisticsScope) { _, _ in selected = nil }
    }
}

extension GardenStage {
    var gardenColor: Color {
        switch self {
        case .seed: return Color(red: 0.61, green: 0.45, blue: 0.30)
        case .sprout: return Color(red: 0.33, green: 0.62, blue: 0.47)
        case .plant: return Color(red: 0.18, green: 0.48, blue: 0.38)
        case .flower: return Color.accentColor
        }
    }
}

// Bounded immediate-mode drawing: at most 40 plants, no timer or per-card views.
// Stable interleaving makes all stages share the same ground instead of four icons.
struct MemoryGardenScene: View, Animatable {
    let counts: [Int]
    var selected: GardenStage?
    var growingFrom: GardenStage?
    var growingTo: GardenStage?
    var progress = 1.0
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    @Environment(\.colorScheme) private var colorScheme

    static func specimens(counts: [Int]) -> [GardenStage] {
        let total = counts.reduce(0, +)
        guard total > 0 else { return [] }
        let capacity = min(40, total)
        let quotas = counts.map { Double($0) / Double(total) * Double(capacity) }
        var slots = quotas.map { Int($0) }
        for index in quotas.indices.sorted(by: { quotas[$0] - Double(slots[$0]) > quotas[$1] - Double(slots[$1]) }).prefix(capacity - slots.reduce(0, +)) { slots[index] += 1 }
        var result: [GardenStage] = []
        while slots.contains(where: { $0 > 0 }) {
            for index in slots.indices where slots[index] > 0 {
                result.append(GardenStage.allCases[index]); slots[index] -= 1
            }
        }
        return result
    }

    var body: some View {
        let specimens = Self.specimens(counts: counts)
        Canvas { context, size in
            let dark = colorScheme == .dark
            let bounds = CGRect(origin: .zero, size: size)
            context.fill(Path(bounds), with: .linearGradient(Gradient(colors: [Color.accentColor.opacity(dark ? 0.13 : 0.05), Color.green.opacity(dark ? 0.08 : 0.04)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // Three soft contours give the small plot depth without scenery noise.
            for row in 0..<3 {
                let y = size.height * (0.53 + Double(row) * 0.17)
                var hill = Path()
                hill.move(to: CGPoint(x: 0, y: y))
                hill.addCurve(to: CGPoint(x: size.width, y: y + 7), control1: CGPoint(x: size.width * 0.35, y: y - 18), control2: CGPoint(x: size.width * 0.68, y: y + 20))
                hill.addLine(to: CGPoint(x: size.width, y: size.height)); hill.addLine(to: CGPoint(x: 0, y: size.height)); hill.closeSubpath()
                context.fill(hill, with: .color(Color.green.opacity(dark ? 0.055 : 0.045)))
            }
            for index in specimens.indices.sorted(by: { ($0 * 17) % 40 < ($1 * 17) % 40 }) {
                let stage = specimens[index]
                // A coprime permutation distributes stages across the entire plot.
                let position = (index * 17) % 40
                let row = position / 10, column = position % 10
                let x = (Double(column) + 0.65 + (row % 2 == 0 ? 0 : 0.25)) * size.width / 10.7
                let y = size.height * (0.56 + Double(row) * 0.12)
                var plant = context
                plant.opacity = selected == nil || selected == stage ? 1 : 0.18
                plant.translateBy(x: x, y: y)
                let scale = 0.75 + Double(row) * 0.10
                plant.scaleBy(x: scale, y: scale)
                if stage == growingTo, specimens.firstIndex(of: stage) == index, let from = growingFrom {
                    var old = plant
                    old.opacity *= 1 - progress
                    draw(from, in: &old, variation: index % 3)
                    plant.opacity *= progress
                    plant.scaleBy(x: 0.75 + 0.25 * progress, y: 0.6 + 0.4 * progress)
                }
                draw(stage, in: &plant, variation: index % 3)
            }
            if specimens.isEmpty {
                context.draw(Text("これから育つ、記憶の庭").font(.subheadline).foregroundStyle(.secondary), at: CGPoint(x: size.width / 2, y: size.height * 0.36))
            }
        }
        .accessibilityElement(children: .ignore)
    }

    private func draw(_ stage: GardenStage, in context: inout GraphicsContext, variation: Int) {
        let green = GardenStage.plant.gardenColor
        context.fill(Path(ellipseIn: CGRect(x: -9, y: 1, width: 18, height: 3)), with: .color(green.opacity(0.10)))
        if stage == .seed {
            var seed = Path()
            seed.move(to: CGPoint(x: -4, y: 0)); seed.addQuadCurve(to: CGPoint(x: 4, y: -5), control: CGPoint(x: -5, y: -9)); seed.addQuadCurve(to: CGPoint(x: -4, y: 0), control: CGPoint(x: 8, y: 2))
            context.fill(seed, with: .color(stage.gardenColor))
            context.stroke(Path { $0.move(to: CGPoint(x: -2, y: -2)); $0.addLine(to: CGPoint(x: 2, y: -4)) }, with: .color(.white.opacity(0.45)), lineWidth: 0.8)
            return
        }
        let height: CGFloat = stage == .sprout ? 17 : stage == .plant ? 34 : 47 + CGFloat(variation * 3)
        var stem = Path()
        stem.move(to: .zero)
        stem.addQuadCurve(to: CGPoint(x: 1, y: -height), control: CGPoint(x: -4, y: -height * 0.5))
        context.stroke(stem, with: .color(green), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
        let leafCount = stage == .sprout ? 2 : 4
        for leaf in 0..<leafCount {
            let side: CGFloat = leaf % 2 == 0 ? -1 : 1
            let y = -height * (0.33 + CGFloat(leaf / 2) * 0.31)
            let reach: CGFloat = stage == .sprout ? 10 : 13
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addQuadCurve(to: CGPoint(x: side * reach, y: y - 10), control: CGPoint(x: side * reach, y: y + 1))
            path.addQuadCurve(to: CGPoint(x: 0, y: y), control: CGPoint(x: side * 2, y: y - 12))
            context.fill(path, with: .color(leaf % 2 == 0 ? green : GardenStage.sprout.gardenColor))
        }
        if stage == .flower {
            var bloom = context
            bloom.translateBy(x: 1, y: -height)
            for _ in 0..<5 {
                bloom.fill(Path(ellipseIn: CGRect(x: -3.8, y: -11, width: 7.6, height: 12)), with: .color(Color.accentColor.opacity(colorScheme == .dark ? 0.95 : 0.78)))
                bloom.rotate(by: .degrees(72))
            }
            bloom.fill(Path(ellipseIn: CGRect(x: -3, y: -3, width: 6, height: 6)), with: .color(Color(red: 0.93, green: 0.77, blue: 0.40)))
        }
    }
}
