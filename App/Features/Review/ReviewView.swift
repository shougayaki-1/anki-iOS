import SwiftUI

struct ReviewView: View {
    @Bindable var store: StudyStore
    @FocusState private var typingFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speechPlayer = StudySpeechPlayer()
    @State private var lastSpeechEvent: SpeechPresentationKey?
    @State private var autoSpeechPaused = false
    @State private var swipeGate = ReviewSwipeGate()
    @State private var swipePadFrame = CGRect.zero
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
                            Text(item.deckName).font(.caption).foregroundStyle(.secondary)
                            if review.answerRevealed && store.settings.reviewAppearance.answerFirst {
                                answerContent(review, item: item)
                                Divider()
                            }
                            questionContent(item)
                            speechControls(review, item: item)
                            reviewImage(review, item: item)
                            if !review.answerRevealed {
                                StudyHintView(hint: item.content.hint).id(item.cardID)
                            }
                            if let reason = review.orderingUnavailable {
                                Text("並び替えを利用できないため、頭の中で回答に切り替えました。\n" + reason)
                                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("orderingUnavailable")
                            }
                            if typeSize.isAccessibilitySize { accessibleModePicker(review) }
                            else { modePicker(review).pickerStyle(.segmented).controlSize(.large) }
                            if review.responseMode == .typing && !review.answerRevealed {
                                TextField("自分の回答", text: Binding(get: { store.review?.typedDraft ?? "" }, set: { store.draft(text: $0) }), axis: .vertical)
                                    .lineLimit(3...12).textFieldStyle(.roundedBorder).focused($typingFocused)
                                    .accessibilityIdentifier("typedAnswer")
                                    .disabled(review.answerRevealed)
                            }
                            if review.responseMode == .ordering && !review.answerRevealed,
                               let draft = review.ordering, let problem = try? OrderingAnswer(kind: item.kind, answer: item.content.answer) {
                                OrderingAnswerView(problem: problem, draft: draft,
                                                   hapticsEnabled: store.settings.hapticsMode != .off,
                                                   action: store.ordering)
                            }
                            if review.answerRevealed {
                                Divider()
                                if !store.settings.reviewAppearance.answerFirst { answerContent(review, item: item) }
                                Text("誤答にはAgain。Hardは思い出せたが難しかったときに使います。")
                                    .font(.footnote).foregroundStyle(.secondary)
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
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let review = store.review, let progress = review.sessionProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(progress.limit == 0 ? "今回回答済み \(progress.answered)問" :
                                 progress.isComplete ? "今回の\(progress.limit)問を完了" :
                                 review.card == nil ? "回答済み \(progress.answered)問" :
                                 "残り\(progress.remaining ?? 0)問")
                                .font(.headline)
                                .accessibilityIdentifier("remainingQuestions")
                            Spacer(minLength: 8)
                            if progress.limit > 0 {
                                Text("今回 \(progress.answered) / \(progress.limit)問")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("sessionProgress")
                            }
                        }
                        if progress.limit > 0 {
                            ProgressView(value: Double(min(progress.answered, progress.limit)), total: Double(progress.limit))
                                .accessibilityIdentifier("sessionProgressBar")
                                .accessibilityLabel("今回の学習進捗")
                                .accessibilityValue("\(progress.answered)問回答済み、残り\(progress.remaining ?? 0)問")
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color(uiColor: .systemBackground))
                    .background { ReviewFixedAreaGestureShield() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let review = store.review, let item = review.card {
                    ReviewActionBar(
                        answerRevealed: review.answerRevealed,
                        isEnabled: imageAvailable(item),
                        onReveal: {
                            speechPlayer.stop()
                            typingFocused = false
                            store.draft(revealed: true)
                        },
                        onGrade: { grade in
                            speechPlayer.stop()
                            typingFocused = false
                            store.grade(grade)
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, typingFocused ? 6 : 10)
                    .background(Color(uiColor: .systemBackground))
                    .background { ReviewFixedAreaGestureShield() }
                    .overlay(alignment: .top) { Divider() }
                } else if let review = store.review, review.card == nil {
                    Button { store.completeSession() } label: {
                        Text(review.emptyState?.reason == .waiting || review.sessionProgress.map { $0.limit > 0 && !$0.isComplete } == true ? "今回はここまで・ホームへ戻る" : "完了してホームへ")
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
                    .background { ReviewFixedAreaGestureShield() }
                }
            }
            .scrollDisabled(swiping)
            .animation(motionReduced ? nil : .easeInOut(duration: 0.18), value: store.review?.answerRevealed)
            .animation(motionReduced ? nil : .easeInOut(duration: 0.18), value: store.review?.card?.cardID)
            .onAppear { speechEventChanged(speechEvent) }
            .onChange(of: speechEvent) { _, event in speechEventChanged(event) }
            .onChange(of: scenePhase) { _, phase in if phase != .active { speechPlayer.stop() } }
            .onChange(of: voiceOver) { _, enabled in if enabled { speechPlayer.stop() } }
            .onChange(of: store.review?.answerRevealed) { _, revealed in
                swipeGate.invalidate()
                if revealed == true { typingFocused = false; readingFocus = .answer }
            }
            .onChange(of: store.review?.card?.cardID) { _, _ in swipeGate.invalidate(); readingFocus = .question }
            .onDisappear {
                swipeGate.cancel()
                speechPlayer.stop()
                lastSpeechEvent = nil
                autoSpeechPaused = false
            }
            .onChange(of: store.review?.sessionProgress?.answered) { old, new in
                if old != new, let progress = store.review?.sessionProgress, progress.isComplete {
                    UIAccessibility.post(notification: .announcement, argument: "今回の\(progress.limit)問を完了しました。")
                }
            }
            .navigationTitle(store.review?.mode.title ?? "学習")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(store.review?.card == nil ? "閉じる" : "中断") {
                        speechPlayer.stop()
                        store.pause()
                    }
                        .accessibilityIdentifier("pauseStudy")
                        .accessibilityHint("学習を中断し、セッションを保存してホームへ戻ります")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Undo") { speechPlayer.stop(); store.undo() }
                        .disabled(store.review?.canUndo != true).accessibilityIdentifier("undoReview")
                        .accessibilityLabel("直前の評価を取り消す")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        autoSpeechPaused.toggle()
                        if autoSpeechPaused { speechPlayer.stop() }
                    } label: {
                        Image(systemName: autoSpeechPaused ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .accessibilityLabel(autoSpeechPaused ? "自動読み上げを再開" : "このセッションの自動読み上げを停止")
                    .accessibilityIdentifier("toggleAutoSpeech")
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

    private var speechEvent: SpeechPresentationKey? {
        guard let item = store.review?.card else { return nil }
        return SpeechPresentationKey(cardID: item.cardID, revealed: store.review?.answerRevealed == true)
    }

    /// Invoked only for a visible card-side transition, never for ordinary SwiftUI redraws.
    private func speechEventChanged(_ event: SpeechPresentationKey?) {
        speechPlayer.stop()
        guard event != lastSpeechEvent else { return }
        lastSpeechEvent = event
        guard let event, scenePhase == .active, !autoSpeechPaused, !voiceOver,
              let item = store.review?.card, item.cardID == event.cardID,
              store.settings.speech.autoplay(deckID: item.deckID,
                                             noteOverride: item.sourceContent.speechOverrides?[item.variantKey]).includes(event.side) else { return }
        playPreferredAudio(event.side, item: item)
    }

    private func playPreferredAudio(_ side: SpeechSide, item: NoteItem) {
        guard side == .question || store.review?.answerRevealed == true else { return }
        if let id = item.content.audioID(for: side) {
            if let url = try? store.repository.assetURL(id: id) { speechPlayer.playAttached(url: url) }
            else { speechPlayer.missingAttachment() }
        } else { playSpeech(side, item: item) }
    }

    private func playSpeech(_ side: SpeechSide, item: NoteItem) {
        // An answer can be read manually only after it has been revealed.
        guard side == .question || store.review?.answerRevealed == true,
              let text = SpeechReadout.text(kind: item.kind, displayed: item.content, side: side) else { return }
        speechPlayer.play(text: text, settings: store.settings.speech)
    }

    @ViewBuilder private func speechControls(_ review: ReviewPresentation, item: NoteItem) -> some View {
        let hasQuestion = item.content.questionAudioID != nil || SpeechReadout.text(kind: item.kind, displayed: item.content, side: .question) != nil
        let hasAnswer = review.answerRevealed &&
            (item.content.answerAudioID != nil || SpeechReadout.text(kind: item.kind, displayed: item.content, side: .answer) != nil)
        if hasQuestion || hasAnswer {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { speechButtons(hasQuestion: hasQuestion, hasAnswer: hasAnswer, item: item) }
                    VStack(alignment: .leading, spacing: 8) {
                        speechButtons(hasQuestion: hasQuestion, hasAnswer: hasAnswer, item: item)
                    }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                if let notice = speechPlayer.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("speechNotice")
                }
            }
        }
    }

    @ViewBuilder private func speechButtons(hasQuestion: Bool, hasAnswer: Bool, item: NoteItem) -> some View {
        if hasQuestion {
            Button { playPreferredAudio(.question, item: item) } label: {
                Label("問題を再生", systemImage: "speaker.wave.2")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityIdentifier("speakQuestion")
        }
        if hasAnswer {
            Button { playPreferredAudio(.answer, item: item) } label: {
                Label("解答を再生", systemImage: "speaker.wave.2")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityIdentifier("speakAnswer")
        }
        if (item.content.questionAudioID != nil || (store.review?.answerRevealed == true && item.content.answerAudioID != nil)) &&
           (SpeechReadout.text(kind: item.kind, displayed: item.content, side: .question) != nil ||
            (store.review?.answerRevealed == true && SpeechReadout.text(kind: item.kind, displayed: item.content, side: .answer) != nil)) {
            Menu("TTSで読む", systemImage: "text.bubble") {
                if SpeechReadout.text(kind: item.kind, displayed: item.content, side: .question) != nil {
                    Button("問題の英文を読む") { playSpeech(.question, item: item) }.accessibilityIdentifier("ttsQuestion")
                }
                if store.review?.answerRevealed == true,
                   SpeechReadout.text(kind: item.kind, displayed: item.content, side: .answer) != nil {
                    Button("解答の英文を読む") { playSpeech(.answer, item: item) }.accessibilityIdentifier("ttsAnswer")
                }
            }.accessibilityIdentifier("chooseTTS")
        }
        if speechPlayer.playing {
            Button { speechPlayer.stop() } label: {
                Label("停止", systemImage: "stop.fill")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .accessibilityIdentifier("stopSpeech")
        }
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
        StudyTextView(text: item.content.question, layout: item.content.questionLayout, font: contentFont, fontSize: store.settings.reviewAppearance.textSize == .standard ? 24 : 32)
            .accessibilityIdentifier("reviewQuestion")
            .accessibilityFocused($readingFocus, equals: .question)
    }
    @ViewBuilder private func answerContent(_ review: ReviewPresentation, item: NoteItem) -> some View {
        if review.responseMode == .typing {
            Text("自分の回答").font(.headline)
            Text(review.typedDraft.isEmpty ? "（未入力）" : review.typedDraft)
        }
        if review.responseMode == .ordering, let draft = review.ordering {
            if let result = draft.result {
                Label(result == .correct ? "正解" : "不正解", systemImage: result == .correct ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(result == .correct ? Color("GradeGood") : Color("GradeAgain"))
                    .accessibilityIdentifier("orderingResult")
            } else { Label("模範解答を確認しました", systemImage: "eye") }
            Text(draft.evaluationGuidance).font(.footnote).foregroundStyle(.secondary)
        }
        Text("模範解答").font(.headline)
        StudyTextView(text: item.content.answer, layout: item.content.answerLayout, font: answerFont, fontSize: store.settings.reviewAppearance.textSize == .standard ? 20 : 28).accessibilityIdentifier("modelAnswer")
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
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: ReviewSwipePadFrameKey.self, value: proxy.frame(in: .global))
            }
        }
        .onPreferenceChange(ReviewSwipePadFrameKey.self) { swipePadFrame = $0 }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore).accessibilityLabel("スワイプ操作領域")
        .accessibilityIdentifier("reviewSwipePad")
        .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($swiping) { value, active, _ in
                active = swipePadFrame.contains(value.startLocation)
            }
            .onChanged { value in
                guard swipePadFrame.contains(value.startLocation), !voiceOver, imageAvailable(item) else { return }
                swipeGate.begin(id: item.cardID, revealed: review.answerRevealed)
            }
            .onEnded { value in
                guard swipePadFrame.contains(value.startLocation), !voiceOver, imageAvailable(item),
                      let current = store.review, let card = current.card else {
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

    private func canUse(_ mode: ResponseMode, review: ReviewPresentation) -> Bool {
        guard mode == .ordering else { return true }
        guard let item = review.card else { return false }
        return OrderingAnswer.reason(kind: item.kind, answer: item.content.answer) == nil
    }

    private func modePicker(_ review: ReviewPresentation) -> some View {
        Picker("回答方法", selection: Binding(get: { review.responseMode }, set: { store.draft(mode: $0) })) {
            ForEach(ResponseMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode).disabled(!canUse(mode, review: review))
            }
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
                .disabled(!canUse(mode, review: review))
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

    private func imageAvailable(_ item: NoteItem) -> Bool {
        guard let id = item.sourceContent.imageID else { return true }
        guard let url = try? store.repository.assetURL(id: id) else { return false }
        return UIImage(contentsOfFile: url.path) != nil
    }
}



private struct ReviewSwipePadFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// Gaps and padding in fixed controls must not forward a drag to content
// underneath them. The background receives those gestures; buttons stay above it.
private struct ReviewFixedAreaGestureShield: View {
    var body: some View {
        Color.clear.contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
            .accessibilityHidden(true)
    }
}

private struct ReviewActionBar: View {
    let answerRevealed: Bool
    let isEnabled: Bool
    let onReveal: () -> Void
    let onGrade: (ReviewGrade) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if answerRevealed {
                if typeSize.isAccessibilitySize {
                    twoColumnGrades
                } else {
                    // ViewThatFits uses the buttons' intrinsic text and touch widths.
                    // Compact labels are never truncated or scaled down to force four columns.
                    ViewThatFits(in: .horizontal) {
                        fourColumnGrades
                        twoColumnGrades
                    }
                }
            } else {
                Button(action: onReveal) {
                    Text("答えを表示").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("PrimaryAction"))
                .foregroundStyle(.white)
                .accessibilityIdentifier("revealAnswer")
                .disabled(!isEnabled)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var fourColumnGrades: some View {
        HStack(spacing: 8) {
            ForEach(ReviewGrade.allCases, id: \.self) { grade in
                gradeButton(grade, compact: true)
            }
        }
    }

    private var twoColumnGrades: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                gradeButton(.again, compact: false)
                gradeButton(.hard, compact: false)
            }
            HStack(spacing: 8) {
                gradeButton(.good, compact: false)
                gradeButton(.easy, compact: false)
            }
        }
    }

    private func gradeButton(_ grade: ReviewGrade, compact: Bool) -> some View {
        Button { onGrade(grade) } label: {
            Text(shortTitle(grade))
                .font(compact ? .subheadline.weight(.semibold) : .headline)
                .lineLimit(compact ? 1 : 2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: compact, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(ReviewGradeButtonStyle(color: gradeColor(grade)))
        .foregroundStyle(.white)
        .frame(minWidth: compact ? 72 : 0)
        .accessibilityLabel(gradeTitle(grade))
        .accessibilityHint(gradeHint(grade))
        .accessibilityIdentifier("grade-\(grade.rawValue)")
        .disabled(!isEnabled)
    }

    private func shortTitle(_ grade: ReviewGrade) -> String {
        switch grade {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }

    private func gradeTitle(_ grade: ReviewGrade) -> String {
        switch grade {
        case .again: return "Again・もう一度"
        case .hard: return "Hard・難しかった"
        case .good: return "Good・思い出せた"
        case .easy: return "Easy・簡単だった"
        }
    }

    private func gradeHint(_ grade: ReviewGrade) -> String {
        switch grade {
        case .again: return "思い出せなかったときに選択"
        case .hard: return "思い出せたが難しかったときに選択"
        case .good: return "思い出せたときに選択"
        case .easy: return "簡単に思い出せたときに選択"
        }
    }

    private func gradeColor(_ grade: ReviewGrade) -> Color {
        switch grade {
        case .again: return Color("GradeAgain")
        case .hard: return Color("GradeHard")
        case .good: return Color("GradeGood")
        case .easy: return Color("GradeEasy")
        }
    }
}

// System prominent-button padding scales aggressively at accessibility sizes.
// Explicit insets preserve full grade names and leave more space for the question.
private struct ReviewGradeButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6).padding(.vertical, 8)
            .background(color.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45),
                        in: RoundedRectangle(cornerRadius: 14))
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
            if canFinish, state?.reason == .complete {
                let limit = store.review?.sessionProgress?.limit ?? 0
                Button(limit > 0 ? "同じ設定でもう\(limit)問学習する" : "同じ設定で学習を続ける",
                       action: store.startAnotherSession)
                    .accessibilityIdentifier("startAnotherSession")
                Text("出題候補がない場合は、このセッションと最後のUndoを保持します。")
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
