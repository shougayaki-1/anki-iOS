import SwiftUI

struct ReviewView: View {
    @Bindable var store: StudyStore
    @FocusState private var typingFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var swipeGate = ReviewSwipeGate()
    @GestureState private var swiping = false
    @Environment(\.dynamicTypeSize) private var typeSize
    enum ReadingFocus: Hashable { case question, answer }
    @AccessibilityFocusState private var readingFocus: ReadingFocus?
    private var motionReduced: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-study-test-reduce-motion") { return true }
        #endif
        return reduceMotion || !store.settings.reviewAppearance.animationsEnabled
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let review = store.review, let item = review.card {
                            if let goal = store.settings.dailyGoal {
                                Text(store.counts.learnedToday >= goal ? "今日の目標を達成しました。学習を続けられます。" : "今日の学習 \(store.counts.learnedToday) / \(goal)枚")
                                    .font(.footnote).accessibilityIdentifier("reviewGoalProgress")
                            }
                            Text(item.deckName).font(.caption).foregroundStyle(.secondary)
                            if review.answerRevealed && store.settings.reviewAppearance.answerFirst {
                                answerContent(review, item: item)
                                Divider()
                            }
                            questionContent(item)
                            reviewImage(review, item: item)
                            if typeSize.isAccessibilitySize { accessibleModePicker(review) }
                            else { modePicker(review).pickerStyle(.segmented).controlSize(.large) }
                            if review.responseMode == .typing && !review.answerRevealed {
                                TextField("自分の回答", text: Binding(get: { store.review?.typedDraft ?? "" }, set: { store.draft(text: $0) }), axis: .vertical)
                                    .lineLimit(3...12).textFieldStyle(.roundedBorder).focused($typingFocused)
                                    .accessibilityIdentifier("typedAnswer")
                                    .disabled(review.answerRevealed)
                            }
                            if review.answerRevealed {
                                Divider()
                                if !store.settings.reviewAppearance.answerFirst { answerContent(review, item: item) }
                                Text("誤答にはAgain。Hardは思い出せたが難しかったときに使います。")
                                    .font(.footnote).foregroundStyle(.secondary)
                                VStack(spacing: 12) {
                                    ForEach(ReviewGrade.allCases, id: \.self) { grade in
                                        Button {
                                            typingFocused = false
                                            store.grade(grade)
                                        } label: {
                                            Text(gradeTitle(grade)).font(.headline)
                                                .frame(maxWidth: .infinity, minHeight: 56)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(gradeColor(grade))
                                        .foregroundStyle(Color.white)
                                        .accessibilityIdentifier("grade-\(grade.rawValue)")
                                        .disabled(!imageAvailable(item))
                                    }
                                }
                            } else {
                                Button { typingFocused = false; store.draft(revealed: true) } label: {
                                    Text("答えを表示").font(.headline)
                                        .frame(maxWidth: .infinity, minHeight: 56)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("revealAnswer")
                                .tint(Color("PrimaryAction")).foregroundStyle(Color.white)
                                .disabled(!imageAvailable(item))
                            }
                            if store.settings.reviewAppearance.gesturesEnabled && !voiceOver {
                                swipePad(review, item: item)
                            }
                        } else {
                            ReviewEmptyStateView(state: store.reviewRefreshFailed ? nil : store.review?.emptyState, nextShortDue: store.review?.nextShortDue,
                                                 canFinish: store.review != nil, store: store)
                        }
                    }.padding()
                        .frame(minHeight: store.review?.card == nil ? geometry.size.height : 0)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let review = store.review, review.card == nil {
                    Button { store.completeSession() } label: {
                        Text(review.emptyState?.reason == .waiting ? "今回はここまで・ホームへ戻る" : "完了してホームへ")
                            .font(.headline).multilineTextAlignment(.center)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .tint(Color("PrimaryAction")).foregroundStyle(Color.white)
                    .accessibilityIdentifier("finishReview")
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .background(Color(uiColor: .systemBackground))
                }
            }
            .scrollDisabled(swiping)
            .animation(motionReduced ? nil : .easeInOut(duration: 0.18), value: store.review?.answerRevealed)
            .animation(motionReduced ? nil : .easeInOut(duration: 0.18), value: store.review?.card?.cardID)
            .onChange(of: store.review?.answerRevealed) { _, revealed in
                swipeGate.invalidate()
                if revealed == true { readingFocus = .answer }
            }
            .onChange(of: store.review?.card?.cardID) { _, _ in swipeGate.invalidate(); readingFocus = .question }
            .onDisappear { swipeGate.cancel() }
            .onChange(of: store.counts.learnedToday) { old, new in
                if let goal = store.settings.dailyGoal, old < goal, new >= goal {
                    UIAccessibility.post(notification: .announcement, argument: "今日の学習目標を達成しました。学習を続けられます。")
                }
            }
            .navigationTitle(store.review?.mode.title ?? "学習")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(store.review?.card == nil ? "閉じる" : "中断", action: store.pause)
                        .accessibilityIdentifier("pauseStudy")
                        .accessibilityHint("学習を中断し、セッションを保存してホームへ戻ります")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Undo", action: store.undo).disabled(store.review?.canUndo != true).accessibilityIdentifier("undoReview")
                        .accessibilityLabel("直前の評価を取り消す")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { typingFocused = false } }
            }
            .alert("処理を完了できませんでした", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
                Button("閉じる", role: .cancel) { store.failure = nil }
            } message: { Text(store.failure ?? "") }
            .task(id: store.review?.card == nil ? store.review?.nextShortDue : nil) {
                guard store.review?.card == nil, let due = store.review?.nextShortDue else { return }
                let delay = max(0, due.timeIntervalSince(store.clock()))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                store.refreshQueue()
            }
        }.interactiveDismissDisabled()
    }

    private var contentFont: Font {
        switch store.settings.reviewAppearance.textSize {
        case .standard: return .title2
        case .larger: return .title
        case .extraLarge: return .largeTitle
        }
    }
    private var answerFont: Font {
        switch store.settings.reviewAppearance.textSize {
        case .standard: return .body
        case .larger: return .title2
        case .extraLarge: return .title
        }
    }
    private func questionContent(_ item: NoteItem) -> some View {
        Text(item.content.question).font(contentFont).textSelection(.enabled)
            .accessibilityIdentifier("reviewQuestion")
            .accessibilityFocused($readingFocus, equals: .question)
    }
    @ViewBuilder private func answerContent(_ review: ReviewPresentation, item: NoteItem) -> some View {
        if review.responseMode == .typing {
            Text("自分の回答").font(.headline)
            Text(review.typedDraft.isEmpty ? "（未入力）" : review.typedDraft)
        }
        Text("模範解答").font(.headline)
        Text(item.content.answer).font(answerFont).textSelection(.enabled).accessibilityIdentifier("modelAnswer")
            .accessibilityFocused($readingFocus, equals: .answer)
        if !item.content.explanation.isEmpty { Text(item.content.explanation).foregroundStyle(.secondary) }
    }
    @ViewBuilder private func reviewImage(_ review: ReviewPresentation, item: NoteItem) -> some View {
        if let id = item.sourceContent.imageID,
           store.settings.reviewAppearance.showsImage(for: item.kind) {
            if let url = try? store.repository.assetURL(id: id), let image = UIImage(contentsOfFile: url.path) {
                StudyImageView(image: image, masks: item.kind == .imageOcclusion ? (item.sourceContent.masks ?? []) : [],
                               targetID: UUID(uuidString: String(item.variantKey.dropFirst("image:".count))),
                               hideAll: item.sourceContent.hideAllMasks ?? true, revealed: review.answerRevealed)
                    .frame(maxHeight: item.kind != .imageOcclusion && store.settings.reviewAppearance.imageDisplay == .compact ? 180 : nil)
                    .accessibilityIdentifier("reviewImage")
            } else { Label("画像を読み込めません。ライブラリで画像を確認してください。", systemImage: "exclamationmark.triangle") }
        }
    }
    private func swipePad(_ review: ReviewPresentation, item: NoteItem) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.draw").accessibilityHidden(true)
            Text("スワイプ操作").font(.headline)
            Text(review.answerRevealed ? "← Again　↓ Hard\n→ Good　↑ Easy" : "右へスワイプして答えを表示")
                .font(.body).multilineTextAlignment(.center)
            Text("この領域で大きく動かして指を離します。戻すとキャンセルできます。")
                .font(.footnote).multilineTextAlignment(.center)
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 260)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore).accessibilityLabel("スワイプ操作領域")
        .accessibilityIdentifier("reviewSwipePad")
        .highPriorityGesture(DragGesture(minimumDistance: 0)
            .updating($swiping) { _, active, _ in active = true }
            .onChanged { _ in
                guard !voiceOver, imageAvailable(item) else { return }
                swipeGate.begin(id: item.cardID, revealed: review.answerRevealed)
            }
            .onEnded { value in
                guard !voiceOver, imageAvailable(item), let current = store.review, let card = current.card else {
                    swipeGate.cancel(); return
                }
                guard let action = swipeGate.finish(id: card.cardID, revealed: current.answerRevealed,
                                                    x: Double(value.translation.width), y: Double(value.translation.height), now: Date()) else { return }
                typingFocused = false
                switch action {
                case .reveal: store.draft(revealed: true)
                case .grade(let grade): store.grade(grade)
                }
            })
    }

    private func modePicker(_ review: ReviewPresentation) -> some View {
        Picker("回答方法", selection: Binding(get: { review.responseMode }, set: { store.draft(mode: $0) })) {
            ForEach(ResponseMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }.accessibilityIdentifier("reviewModePicker")
    }

    private func accessibleModePicker(_ review: ReviewPresentation) -> some View {
        Menu {
            ForEach(ResponseMode.allCases, id: \.self) { mode in
                Button {
                    store.draft(mode: mode)
                } label: {
                    if review.responseMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
                .accessibilityIdentifier("response-mode-\(mode.rawValue)")
            }
        } label: {
            HStack {
                Text("回答方法")
                Spacer(minLength: 12)
                Text(review.responseMode.title).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
            }
            .font(.body)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("回答方法")
        .accessibilityValue(review.responseMode.title)
        .accessibilityIdentifier("reviewModePicker")
    }

    private func gradeColor(_ grade: ReviewGrade) -> Color {
        switch grade {
        case .again: return Color("GradeAgain")
        case .hard: return Color("GradeHard")
        case .good: return Color("GradeGood")
        case .easy: return Color("GradeEasy")
        }
    }

    private func gradeTitle(_ grade: ReviewGrade) -> String {
        switch grade {
        case .again: return "Again · もう一度"
        case .hard: return "Hard · 難しかった"
        case .good: return "Good · 思い出せた"
        case .easy: return "Easy · 簡単だった"
        }
    }
    private func imageAvailable(_ item: NoteItem) -> Bool {
        guard let id = item.sourceContent.imageID else { return true }
        guard let url = try? store.repository.assetURL(id: id) else { return false }
        return UIImage(contentsOfFile: url.path) != nil
    }
}


private struct ReviewEmptyStateView: View {
    let state: ReviewEmptyState?
    let nextShortDue: Date?
    let canFinish: Bool
    var store: StudyStore

    var body: some View {
        VStack(spacing: 20) {
            Text(state?.title ?? "学習状態を確認できません").font(.title2.bold())
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("reviewEmptyTitle")
            Text(state?.message ?? "出題を再確認してください。")
            if let nextShortDue {
                Text("次の短期復習: \(nextShortDue.formatted(date: .omitted, time: .shortened))")
                    .accessibilityIdentifier("reviewNextShortDue")
            }
            if canFinish {
                Text("終了後は、このセッションのUndoは使えません。評価と復習予定は保存されています。中断して保存する場合は上部の「閉じる」を使います。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if state?.suggestsSettings == true {
                Button("終了して設定 > 学習へ") { store.completeSession(destination: 3) }
            }
            if state?.suggestsScopeChange == true {
                Text("ホームに戻ると学習対象を変更できます。停止の解除はライブラリで行えます。")
            }
            if state?.canRetry == true || state == nil {
                Button("出題を再確認", action: store.refreshQueue).accessibilityIdentifier("refreshReviewQueue")
            }
        }.frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }
}
