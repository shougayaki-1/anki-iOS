import SwiftUI
import PencilKit

struct ReviewView: View {
    @State private var loadedReviewImage: UIImage?
    @State private var loadedReviewImageKey: String?
    @State private var reviewImageFailed = false
    @State private var imageWidth: CGFloat = 400
    @Environment(\.displayScale) private var imageScale
    private var reviewImagePixels: Int {
        guard let item = store.review?.card else { return 256 }
        if !store.settings.reviewAppearance.showsImage(for: item.kind) { return 256 }
        let height: CGFloat = item.kind != .imageOcclusion && store.settings.reviewAppearance.imageDisplay == .compact ? 180 : 560
        return Int(ceil(max(imageWidth, height) * imageScale / 256)) * 256
    }
    private var reviewImageKey: String {
        "\(store.mediaDisplayNamespace)|\(store.dataRevision)|\(store.review?.card?.cardID.uuidString ?? "")|\(store.review?.card?.sourceContent.imageID?.uuidString ?? "")|\(reviewImagePixels)"
    }
    @Bindable var store: StudyStore
    @State private var whiteboardPresented = false
    @State private var whiteboardDrawing = PKDrawing()
    @FocusState private var typingFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speechPlayer = StudySpeechPlayer()
    @StateObject private var pronunciation = PronunciationPractice()
    @State private var lastSpeechEvent: SpeechPresentationKey?
    @State private var editingCard: NoteItem?
    @State private var confirmingEdit = false
    @State private var autoSpeechPaused = false
    @State private var swipeGate = ReviewSwipeGate()
    @State private var swipeProgress = ReviewSwipeProgress.idle
    @State private var swipeTranslation = CGSize.zero
    @State private var swiping = false
    @State private var contentScrollable = false
    @State private var excludedSwipeFrames: [CGRect] = []
    @State private var handleIntent = ReviewSwipeIntent()
    @GestureState private var handleDragging = false
    @State private var settlingSwipe = false
    @State private var captureSwipeCard: (() -> UIView?)?
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
            reviewContent
            .sheet(isPresented: $whiteboardPresented) { whiteboardContent }
            .sheet(item: $editingCard, onDismiss: { pronunciation.discard(); lastSpeechEvent = nil }) { item in
                NoteEditorView(store: store, item: item, duringReview: true)
            }
            .confirmationDialog("編集画面では解答も表示されます", isPresented: $confirmingEdit, titleVisibility: .visible) {
                Button("解答を確認して編集") { openEditor() }
            } message: { Text("編集を開くと回答表示済みとして扱います。保存後は同じカードを再提示します。") }
            .navigationTitle(store.review?.mode.title ?? "学習")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { reviewToolbar }
            .alert("処理を完了できませんでした", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
                if store.typedDraftSaveFailed {
                    Button("入力の保存を再試行") { store.flushTypedDraft() }
                }
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
            .background { GeometryReader { geometry in
                Color.clear.onAppear { imageWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in imageWidth = width }
            } }
            .task(id: reviewImageKey) {
                let request = reviewImageKey
                loadedReviewImage = nil; loadedReviewImageKey = nil; reviewImageFailed = false
                guard let id = store.review?.card?.sourceContent.imageID else { return }
                do {
                    let url = try store.repository.assetURL(id: id)
                    let result = try await DisplayImageLoader.shared.load(file: url, namespace: store.mediaDisplayNamespace, pixels: reviewImagePixels)
                    guard !Task.isCancelled, request == reviewImageKey else { return }
                    loadedReviewImage = UIImage(cgImage: result); loadedReviewImageKey = request
                } catch is CancellationError { } catch {
                    guard !Task.isCancelled, request == reviewImageKey else { return }
                    reviewImageFailed = true
                }
            }
            .onDisappear { loadedReviewImage = nil; loadedReviewImageKey = nil }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                Task { await DisplayImageLoader.shared.clearCache() }
            }
            .onDisappear { store.flushTypedDraft() }
    }

    @ViewBuilder private var whiteboardContent: some View {
        if let review = store.review, let item = review.card {
            ReviewWhiteboard(drawing: $whiteboardDrawing, answerRevealed: review.answerRevealed,
                             canReveal: imageAvailable(item), onReveal: {
                speechPlayer.stop()
                store.draft(revealed: true)
            }) {
                questionContent(item)
                reviewImage(review, item: item)
                if review.answerRevealed { Divider(); answerContent(review, item: item) }
            }
        }
    }

    private var reviewContent: some View {
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
                            speechControls(review, item: item).reviewSwipeExcluded()
                            pronunciationControls.reviewSwipeExcluded()
                            reviewImage(review, item: item).reviewSwipeExcluded()
                            if !review.answerRevealed {
                                StudyHintView(hint: item.content.hint).id(item.cardID)
                            }
                            if let reason = review.orderingUnavailable {
                                Text("並び替えを利用できないため、頭の中で回答に切り替えました。\n" + reason)
                                    .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("orderingUnavailable")
                            }
                            if typeSize.isAccessibilitySize { accessibleModePicker(review).reviewSwipeExcluded() }
                            else { modePicker(review).pickerStyle(.segmented).controlSize(.large).reviewSwipeExcluded() }
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
                        } else {
                            if store.sessionStudyPaused { Text(StudyError.deckStudyPaused.localizedDescription).padding() }
                            else { ReviewEmptyStateView(state: store.reviewRefreshFailed ? nil : store.review?.emptyState, nextShortDue: store.review?.nextShortDue,
                                                 canFinish: store.review != nil, store: store) }
                        }
                    }.padding()
                        .frame(maxWidth: UIDevice.current.userInterfaceIdiom != .phone ? 760 : .infinity)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: store.review?.card == nil ? geometry.size.height : 0)
                        .background(Color(uiColor: .systemBackground))
                        .offset(motionReduced ? .zero : swipeTranslation)
                        .background {
                            ReviewCardPan(enabled: swipeEnabled, excludedFrames: excludedSwipeFrames,
                                          onLayout: { scrollable in if !swiping { contentScrollable = scrollable } },
                                          onAttach: { captureSwipeCard = $0 },
                                          onChange: updateCardSwipe, onEnd: finishCardSwipe,
                                          onCancel: cancelSwipe)
                        }

                }
                .background { swipeBackdrop }
                .overlay(alignment: .top) {
                    if motionReduced, let action = swipeProgress.candidate {
                        Label(swipeProgress.ready ? "離すと\(action.title)" : action.title,
                              systemImage: swipeProgress.ready ? "checkmark.circle.fill" : action.symbol)
                            .font(.headline).padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(8).allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(ReviewSwipeExclusionKey.self) { excludedSwipeFrames = $0 }
                .accessibilityIdentifier("reviewCardSurface")
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let review = store.review, let progress = review.sessionProgress {
                    let total = review.visibleAnswerTotal ?? progress.limit
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(progress.limit == 0 ? "今回回答済み \(progress.answered)問" :
                                 progress.isComplete ? "今回の\(progress.limit)問を完了" :
                                 review.card == nil ? "回答済み \(progress.answered)問" :
                                 "残り\(max(0, total - progress.answered))問")
                                .font(.headline)
                                .accessibilityIdentifier("remainingQuestions")
                            Spacer(minLength: 8)
                            if progress.limit > 0 {
                                Text("今回 \(progress.answered) / \(total)問")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("sessionProgress")
                            }
                        }
                        if progress.limit > 0 {
                            ProgressView(value: Double(min(progress.answered, total)), total: Double(total))
                                .accessibilityIdentifier("sessionProgressBar")
                                .accessibilityLabel("今回の学習進捗")
                                .accessibilityValue("\(progress.answered)問回答済み、現時点の出題分は残り\(max(0, total - progress.answered))問")
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
                    BottomActionArea {
                        if store.settings.reviewAppearance.gesturesEnabled && !voiceOver && review.answerRevealed && contentScrollable {
                            swipeHandle.allowsHitTesting(swipeEnabled)
                        }
                        ReviewActionBar(
                            answerRevealed: review.answerRevealed,
                            isEnabled: imageAvailable(item) && !settlingSwipe,
                            onReveal: {
                                speechPlayer.stop()
                                typingFocused = false
                                store.draft(revealed: true)
                            },
                            onGrade: { grade in
                                invalidateSwipe()
                                pronunciation.discard()
                                speechPlayer.stop()
                                typingFocused = false
                                store.grade(grade)
                            }
                        )
                    }
                    .frame(maxWidth: UIDevice.current.userInterfaceIdiom != .phone ? 760 : .infinity)
                    .frame(maxWidth: .infinity)
                    .background { ReviewFixedAreaGestureShield() }
                } else if let review = store.review, review.card == nil {
                    Button { invalidateSwipe(); if store.sessionStudyPaused { store.pause() } else { store.completeSession() } } label: {
                        Text(store.sessionStudyPaused ? "下書きを保持してホームへ戻る" : review.emptyState?.reason == .waiting || review.sessionProgress.map { $0.limit > 0 && !$0.isComplete } == true ? "今回はここまで・ホームへ戻る" : "完了してホームへ")
                            .font(.headline).multilineTextAlignment(.center)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PrimaryActionStyle(capsule: true))
                    .accessibilityIdentifier("finishReview")
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .background(Color(uiColor: .systemBackground))
                    .background { ReviewFixedAreaGestureShield() }
                }
            }
            .safeAreaInset(edge: .top) {
                if let notice = store.achievementNotice {
                    NoteSaveNoticeView(notice: notice) {
                        if store.achievementNotice?.id == notice.id { store.achievementNotice = nil }
                    }.allowsHitTesting(false)
                }
            }
            .onChange(of: handleDragging) { _, active in
                if !active {
                    Task { @MainActor in
                        await Task.yield()
                        if !handleDragging { cancelSwipe(); handleIntent = ReviewSwipeIntent() }
                    }
                }
            }
            .onChange(of: whiteboardPresented) { _, _ in invalidateSwipe() }
            .onChange(of: editingCard?.id) { _, _ in invalidateSwipe() }
            .onChange(of: confirmingEdit) { _, _ in invalidateSwipe() }
            .onChange(of: typingFocused) { _, focused in
                if focused { invalidateSwipe() }
            }
            .animation(motionReduced ? nil : .easeInOut(duration: 0.18), value: store.review?.answerRevealed)
            .animation(motionReduced ? nil : .easeInOut(duration: 0.18), value: store.review?.card?.cardID)
            .onAppear { speechEventChanged(speechEvent) }
            .onChange(of: speechEvent) { _, event in speechEventChanged(event) }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    invalidateSwipe()
                    speechPlayer.stop()
                    if phase == .background { pronunciation.discard() }
                    else { pronunciation.stopRecording(); pronunciation.stopPlayback() }
                }
                else { speechEventChanged(speechEvent) }
            }
            .onChange(of: store.showingReview) { _, showing in
                if !showing { invalidateSwipe(); clearWhiteboard(); pronunciation.discard() }
            }
            .onChange(of: voiceOver) { _, enabled in if enabled { invalidateSwipe(); speechPlayer.stop() } }
            .onChange(of: store.settings.reviewAppearance.gesturesEnabled) { _, _ in invalidateSwipe() }
            .onChange(of: store.review?.responseMode) { _, _ in invalidateSwipe() }
            .onChange(of: store.failure) { _, failure in if failure != nil { invalidateSwipe() } }
            .onChange(of: store.review?.answerRevealed) { _, revealed in
                invalidateSwipe()
                if revealed == true { typingFocused = false; readingFocus = .answer }
            }
            .onChange(of: store.review?.card?.cardID) { _, _ in
                clearWhiteboard()
                invalidateSwipe(); readingFocus = .question
            }
            .onDisappear {
                cancelSwipe()
                speechPlayer.stop()
                pronunciation.discard()
                lastSpeechEvent = nil
                autoSpeechPaused = false
            }
            .onChange(of: store.review?.sessionProgress?.answered) { old, new in
                if old != new { clearWhiteboard(); pronunciation.discard() }
                if old != new, let progress = store.review?.sessionProgress, progress.isComplete {
                    UIAccessibility.post(notification: .announcement, argument: "今回の\(progress.limit)問を完了しました。")
                }
            }
    }

    private var speechEvent: SpeechPresentationKey? {
        guard let item = store.review?.card else { return nil }
        return SpeechPresentationKey(cardID: item.cardID, revealed: store.review?.answerRevealed == true)
    }

    @ToolbarContentBuilder private var reviewToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                guard editingCard == nil, !confirmingEdit else { return }
                typingFocused = false
                speechPlayer.stop()
                cancelSwipe()
                if pronunciation.phase == .requestingPermission { pronunciation.discard() }
                else { pronunciation.stopRecording(); pronunciation.stopPlayback() }
                whiteboardPresented = true
            } label: { Image(systemName: "pencil.tip.crop.circle") }
            .disabled(store.review?.card == nil || editingCard != nil || confirmingEdit)
            .accessibilityLabel("手書きを開く")
            .accessibilityIdentifier("openWhiteboard")
        }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let card = store.review?.card {
                            Menu("フラグ", systemImage: "flag") {
                                ForEach(CardFlag.allCases) { flag in
                                    Button(flag.title) { store.perform { try store.repository.setFlags(cardIDs: [card.cardID], flag: flag) } }
                                }
                                Button("フラグを解除") { store.perform { try store.repository.setFlags(cardIDs: [card.cardID], flag: nil) } }
                                    .disabled(card.flag == nil)
                            }
                            Button("今日は表示しない", systemImage: "clock") {
                                speechPlayer.stop(); pronunciation.discard(); invalidateSwipe(); typingFocused = false
                                store.perform { try store.repository.hideToday(cardID: card.cardID, now: store.clock()) }
                            }
                            Button("無期限で停止", systemImage: "pause.circle") {
                                speechPlayer.stop(); pronunciation.discard(); invalidateSwipe(); typingFocused = false
                                store.perform { try store.repository.setSuspended(cardID: card.cardID, value: true, now: store.clock()) }
                            }
                            if let flag = card.flag { Label("フラグ: " + flag.title, systemImage: "flag.fill") }
                        }
                        Button("カードを編集", systemImage: "pencil") {
                            speechPlayer.stop(); pronunciation.discard(); invalidateSwipe(); typingFocused = false
                            if store.review?.answerRevealed == true { openEditor() }
                            else { confirmingEdit = true }
                        }.disabled(store.review?.card == nil || whiteboardPresented || editingCard != nil)
                    } label: {
                        if let flag = store.review?.card?.flag { CardFlagLabel(flag: flag) }
                        else { Image(systemName: "ellipsis.circle") }
                    }
                    .accessibilityLabel("カードの操作")
                    .accessibilityIdentifier("reviewCardActions")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(store.review?.card == nil ? "閉じる" : "中断") {
                        speechPlayer.stop()
                        pronunciation.discard()
                        clearWhiteboard()
                        invalidateSwipe(); store.pause()
                    }
                        .keyboardShortcut(.escape, modifiers: [])
                        .accessibilityIdentifier("pauseStudy")
                        .accessibilityHint("学習を中断し、セッションを保存してホームへ戻ります")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Undo") { invalidateSwipe(); speechPlayer.stop(); pronunciation.discard(); clearWhiteboard(); store.undo() }
                        .keyboardShortcut("z", modifiers: .command)
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

    private var pronunciationControls: some View {
        DisclosureGroup("発音を練習") {
            VStack(alignment: .leading, spacing: 10) {
                Text("録音は一時的です。カード移動・中断で削除します（最大2分）。")
                    .font(.caption).foregroundStyle(.secondary)
                if pronunciation.phase == .recording, let date = pronunciation.startedAt {
                    HStack {
                        Label("録音中", systemImage: "mic.fill").foregroundStyle(.red)
                        Text(date, style: .timer).monospacedDigit()
                        Button("録音を停止") { pronunciation.stopRecording() }
                    }
                } else {
                    Button(pronunciation.phase == .requestingPermission ? "マイクを確認中…" : "録音を開始") {
                        speechPlayer.stop()
                        Task {
                            guard editingCard == nil, !confirmingEdit, !whiteboardPresented, scenePhase == .active else { return }
                            await pronunciation.start()
                        }
                    }.disabled(pronunciation.phase == .requestingPermission)
                    if pronunciation.phase == .ready || pronunciation.phase == .playing {
                        Button(pronunciation.phase == .playing ? "自分の音声を停止" : "自分の音声を再生") {
                            speechPlayer.stop()
                            if pronunciation.phase == .playing { pronunciation.stopPlayback() }
                            else { pronunciation.play() }
                        }
                        Button("録音を削除") { pronunciation.discard() }
                    }
                }
                if let notice = pronunciation.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                if pronunciation.permissionDenied {
                    Button("設定を開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }.buttonStyle(.borderless)
        }.accessibilityIdentifier("pronunciationPractice")
    }

    private func clearWhiteboard() {
        whiteboardPresented = false
        whiteboardDrawing = PKDrawing()
    }

    private func openEditor() {
        guard editingCard == nil, !whiteboardPresented, let item = store.review?.card else { return }
        clearWhiteboard()
        pronunciation.discard()
        // The editor exposes the answer even if the user later cancels.
        editingCard = item
        store.draft(revealed: true)
        guard store.failure == nil else { editingCard = nil; return }
        speechPlayer.stop()
    }

    private func speechEventChanged(_ event: SpeechPresentationKey?) {
        guard editingCard == nil, !confirmingEdit else { speechPlayer.stop(); return }
        guard event != lastSpeechEvent else { return }
        speechPlayer.stop()
        if event?.cardID != lastSpeechEvent?.cardID { pronunciation.discard() }
        else { pronunciation.stopRecording(); pronunciation.stopPlayback() }
        guard let event else { lastSpeechEvent = nil; return }
        guard !whiteboardPresented else { return }
        guard scenePhase == .active else { SpeechDiagnostics.record("autoplaySkipped reason=inactive"); return }
        lastSpeechEvent = event
        guard let item = store.review?.card, item.cardID == event.cardID else { return }
        guard !autoSpeechPaused, !voiceOver else {
            SpeechDiagnostics.record(autoSpeechPaused ? "autoplaySkipped reason=paused" : "autoplaySkipped reason=voiceOver")
            return
        }
        let autoplay = store.settings.speech.autoplay(deckID: item.deckID,
            noteOverride: item.sourceContent.speechOverrides?[item.variantKey])
        guard autoplay.includes(event.side) else {
            SpeechDiagnostics.record("autoplaySkipped setting=\(autoplay.rawValue) side=\(event.side.rawValue)")
            return
        }
        playPreferredAudio(event.side, item: item)
    }

    private func playPreferredAudio(_ side: SpeechSide, item: NoteItem) {
        guard editingCard == nil, !confirmingEdit, !whiteboardPresented else { return }
        guard pronunciation.phase != .recording, pronunciation.phase != .requestingPermission else { return }
        pronunciation.stopPlayback()
        guard side == .question || store.review?.answerRevealed == true else { return }
        if let id = item.content.audioID(for: side) {
            if let url = try? store.repository.assetURL(id: id) { speechPlayer.playAttached(url: url) }
            else { speechPlayer.missingAttachment() }
        } else { playSpeech(side, item: item) }
    }

    private func playSpeech(_ side: SpeechSide, item: NoteItem) {
        guard editingCard == nil, !confirmingEdit, !whiteboardPresented else { return }
        guard pronunciation.phase != .recording, pronunciation.phase != .requestingPermission else { return }
        pronunciation.stopPlayback()
        // An answer can be read manually only after it has been revealed.
        guard side == .question || store.review?.answerRevealed == true else {
            SpeechDiagnostics.record("requestRejected reason=unrevealedAnswer"); return
        }
        let result = SpeechReadout.assessment(kind: item.kind, displayed: item.content, side: side)
        guard let text = result.text else {
            if let failure = result.failure { speechPlayer.unavailableReadout(failure) }
            return
        }
        speechPlayer.play(text: text, settings: store.settings.speech)
    }

    @ViewBuilder private func speechControls(_ review: ReviewPresentation, item: NoteItem) -> some View {
        let hasQuestion = item.content.questionAudioID != nil || SpeechReadout.text(kind: item.kind, displayed: item.content, side: .question) != nil
        let hasAnswer = review.answerRevealed &&
            (item.content.answerAudioID != nil || SpeechReadout.text(kind: item.kind, displayed: item.content, side: .answer) != nil)
        if hasQuestion || hasAnswer || speechPlayer.notice != nil {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { speechButtons(hasQuestion: hasQuestion, hasAnswer: hasAnswer, item: item) }
                    VStack(alignment: .leading, spacing: 8) {
                        speechButtons(hasQuestion: hasQuestion, hasAnswer: hasAnswer, item: item)
                    }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
                if speechPlayer.phase == .requested {
                    Text("読み上げを開始しています…").font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("speechRequested")
                }
                if let notice = speechPlayer.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("speechNotice")
                }
                DisclosureGroup("音が聞こえないとき") {
                    Text("消音モードでは音を鳴らしません。消音を解除し、音量とBluetoothなどの出力先を確認してください。開始しない場合はiPhoneのアクセシビリティ設定で英語音声を確認できます。自動再生がオフでも再生ボタンは使えます。")
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("speechOutputHelp")
            }
        }
    }

    @ViewBuilder private func speechButtons(hasQuestion: Bool, hasAnswer: Bool, item: NoteItem) -> some View {
        if hasQuestion {
            Button { playPreferredAudio(.question, item: item) } label: {
                Label("問題を再生", systemImage: "speaker.wave.2")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(SecondaryActionStyle())
            .accessibilityIdentifier("speakQuestion")
            .disabled(pronunciation.phase == .recording || pronunciation.phase == .requestingPermission)
        }
        if hasAnswer {
            Button { playPreferredAudio(.answer, item: item) } label: {
                Label("解答を再生", systemImage: "speaker.wave.2")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(SecondaryActionStyle())
            .accessibilityIdentifier("speakAnswer")
            .disabled(pronunciation.phase == .recording || pronunciation.phase == .requestingPermission)
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
            }.frame(minHeight: 44).accessibilityIdentifier("chooseTTS")
            .disabled(pronunciation.phase == .recording || pronunciation.phase == .requestingPermission)
        }
        if speechPlayer.playing {
            Button { speechPlayer.stop() } label: {
                Label("停止", systemImage: "stop.fill")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(SecondaryActionStyle())
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
        if item.sourceContent.imageID != nil,
           store.settings.reviewAppearance.showsImage(for: item.kind) {
            if let image = loadedReviewImage, loadedReviewImageKey == reviewImageKey {
                StudyImageView(image: image, masks: item.kind == .imageOcclusion ? (item.sourceContent.masks ?? []) : [],
                               targetID: UUID(uuidString: String(item.variantKey.dropFirst("image:".count))),
                               hideAll: item.sourceContent.hideAllMasks ?? true, revealed: review.answerRevealed)
                    .frame(maxHeight: item.kind != .imageOcclusion && store.settings.reviewAppearance.imageDisplay == .compact ? 180 : 560)
                    .accessibilityIdentifier("reviewImage")
            } else if reviewImageFailed {
                Label("画像を読み込めません。ライブラリで画像を確認してください。", systemImage: "exclamationmark.triangle")
            } else { ProgressView().frame(height: 180) }
        }
    }
    private var swipeHandle: some View {
        Label("四方向にスワイプ", systemImage: "hand.draw")
            .font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore).accessibilityLabel("四方向にスワイプ")
            .accessibilityIdentifier("reviewSwipeHandle")
            .gesture(DragGesture(minimumDistance: 12, coordinateSpace: .global)
                .updating($handleDragging) { _, active, _ in active = true }
                .onChanged { value in
                    guard handleIntent.update(x: value.translation.width, y: value.translation.height, scrollable: false),
                          handleIntent.accepts(x: value.translation.width, y: value.translation.height) else {
                        invalidateSwipe(); return
                    }
                    updateCardSwipe(value.translation)
                }
                .onEnded { value in
                    if handleIntent.accepts(x: value.translation.width, y: value.translation.height) {
                        finishCardSwipe(value.translation)
                    } else { cancelSwipe() }
                    handleIntent = ReviewSwipeIntent()
                })
    }

    private var swipeBackdrop: some View {
        ZStack {
            if let action = swipeProgress.candidate {
                swipeColor(action).opacity(swipeProgress.ready ? 0.3 : 0.12)
                VStack(spacing: 6) {
                    Image(systemName: swipeProgress.ready ? "checkmark.circle.fill" : action.symbol)
                        .font(.title3)
                    Text(action.title).font(.headline)
                    if swipeProgress.ready { Text("離して評価").font(.caption2) }
                }
                // The whole label fits in the 96pt strip exposed at the gate.
                .frame(width: 80).padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: swipeAlignment(action))
            }
        }.allowsHitTesting(false)
    }

    private func swipeColor(_ action: ReviewSwipeAction) -> Color {
        switch action {
        case .grade(.again): return .red
        case .grade(.hard): return .orange
        case .grade(.good): return .green
        case .grade(.easy): return .blue
        case .reveal: return .accentColor
        }
    }
    private func swipeAlignment(_ action: ReviewSwipeAction) -> Alignment {
        switch action {
        case .grade(.again): return .trailing
        case .grade(.hard): return .top
        case .grade(.easy): return .bottom
        default: return .leading
        }
    }

    private func updateCardSwipe(_ translation: CGSize) {
        guard swipeEnabled, let review = store.review, let item = review.card else { return }
        if !swiping {
            swiping = true
            swipeGate.begin(id: item.cardID, revealed: true)
            store.haptics.prepareSwipe(mode: store.settings.hapticsMode)
        }
        swipeTranslation = translation
        swipeProgress = swipeGate.update(id: item.cardID, revealed: review.answerRevealed,
            x: translation.width, y: translation.height, now: Date())
        if swipeProgress.feedback { store.haptics.play(.swipeReady, mode: store.settings.hapticsMode) }
    }

    private func finishCardSwipe(_ translation: CGSize) {
        defer { cancelSwipe() }
        guard swipeEnabled, let review = store.review, let card = review.card else { return }
        let prepared = swipeGate.gavePreparationFeedback
        guard case .grade(let grade) = swipeGate.finish(id: card.cardID, revealed: review.answerRevealed,
            x: translation.width, y: translation.height, now: Date()) else { return }
        speechPlayer.stop(); pronunciation.discard(); typingFocused = false
        let snapshot = motionReduced ? nil : captureSwipeCard?()
        store.grade(grade, swipePrepared: prepared)
        guard store.failure == nil, let snapshot, let window = snapshot.window else {
            snapshot?.removeFromSuperview(); return
        }
        settlingSwipe = true
        let target: CGAffineTransform
        switch grade {
        case .again: target = CGAffineTransform(translationX: -window.bounds.width, y: 0)
        case .good: target = CGAffineTransform(translationX: window.bounds.width, y: 0)
        case .easy: target = CGAffineTransform(translationX: 0, y: -window.bounds.height)
        case .hard: target = CGAffineTransform(translationX: 0, y: window.bounds.height)
        }
        UIView.animate(withDuration: 0.22, animations: {
            snapshot.transform = target; snapshot.alpha = 0
        }, completion: { _ in snapshot.removeFromSuperview(); settlingSwipe = false })
    }

    private var swipeEnabled: Bool {
        guard let review = store.review, review.answerRevealed,
              let item = review.card, imageAvailable(item) else { return false }
        return store.settings.reviewAppearance.gesturesEnabled && !voiceOver && scenePhase == .active &&
            !typingFocused && !settlingSwipe && store.showingReview && store.failure == nil &&
            !whiteboardPresented && editingCard == nil && !confirmingEdit
    }
    private func invalidateSwipe() {
        swipeGate.invalidate(); swipeProgress = .idle; swipeTranslation = .zero
    }
    private func cancelSwipe() {
        swipeGate.cancel(); swipeProgress = .idle
        withAnimation(motionReduced ? nil : .easeOut(duration: 0.18)) { swipeTranslation = .zero }
        swiping = false
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
        guard item.sourceContent.imageID != nil else { return true }
        return loadedReviewImage != nil && loadedReviewImageKey == reviewImageKey
    }
}



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
                .buttonStyle(PrimaryActionStyle())
                .keyboardShortcut(.return, modifiers: .command)
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
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryActionStyle(color: gradeColor(grade)))
        .foregroundStyle(.white)
        .frame(minWidth: compact ? 72 : 0)
        .accessibilityLabel(gradeTitle(grade))
        .accessibilityHint(gradeHint(grade))
        .keyboardShortcut(KeyEquivalent(Character(String(grade.rawValue))), modifiers: .command)
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
                Button(limit > 0 ? "同じ設定でもう最大\(limit)問学習する" : "同じ設定で上限なしの学習を始める",
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


/// Session-only ink; never passed to StudyStore or persistence.
private struct ReviewWhiteboard<Content: View>: View {
    @Binding var drawing: PKDrawing
    let answerRevealed: Bool
    let canReveal: Bool
    let onReveal: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var erasing = false
    @State private var confirmingClear = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12, content: content)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .frame(maxHeight: 240)
                HStack {
                    Picker("描画ツール", selection: $erasing) {
                        Text("ペン").tag(false)
                        Text("消しゴム").tag(true)
                    }.pickerStyle(.segmented)
                    Button("全消去", role: .destructive) { confirmingClear = true }
                        .disabled(drawing.strokes.isEmpty)
                }.padding(.horizontal)
                ReviewInkCanvas(drawing: $drawing, erasing: erasing)
                    .accessibilityLabel("指で描く手書きキャンバス")
                    .accessibilityIdentifier("whiteboardCanvas")
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
                    .padding(.horizontal)
                Text("筆跡はこのカードのみ。評価・Undo・中断で消去されます。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                if !answerRevealed {
                    Button("答えを見る", action: onReveal)
                        .buttonStyle(.borderedProminent).disabled(!canReveal)
                        .accessibilityIdentifier("whiteboardRevealAnswer")
                }
            }.padding(.bottom)
            .navigationTitle("手書き").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("閉じる") { dismiss() } }
            }
            .confirmationDialog("筆跡をすべて消去しますか？", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("全消去", role: .destructive) { drawing = PKDrawing() }
                Button("キャンセル", role: .cancel) { }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct ReviewInkCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    let erasing: Bool

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.backgroundColor = .secondarySystemBackground
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.drawing = $drawing
        canvas.tool = erasing ? PKEraserTool(.vector) : PKInkingTool(.pen, color: .label, width: 3)
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        canvas.delegate = nil
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var drawing: Binding<PKDrawing>
        init(drawing: Binding<PKDrawing>) { self.drawing = drawing }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if drawing.wrappedValue != canvasView.drawing {
                drawing.wrappedValue = canvasView.drawing
            }
        }
    }
}

// UIKit failure ordering lets the ScrollView own vertical gestures rather than
// running grading and scrolling simultaneously. No overlay intercepts text taps.
import UIKit.UIGestureRecognizerSubclass
import WebKit

private struct ReviewSwipeExclusionKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}
private extension View {
    func reviewSwipeExcluded() -> some View {
        background { GeometryReader { geometry in
            Color.clear.preference(key: ReviewSwipeExclusionKey.self, value: [geometry.frame(in: .global)])
        } }
    }
}

private struct ReviewCardPan: UIViewRepresentable {
    let enabled: Bool
    let excludedFrames: [CGRect]
    let onLayout: (Bool) -> Void
    let onAttach: (@escaping () -> UIView?) -> Void
    let onChange: (CGSize) -> Void
    let onEnd: (CGSize) -> Void
    let onCancel: () -> Void

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        view.configuration = self
        view.attach()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.recognizer?.isEnabled = false
        if let recognizer = view.recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
        view.observations = []
    }
    final class Probe: UIView {
        var configuration: ReviewCardPan?
        var recognizer: CardRecognizer?
        var observations: [NSKeyValueObservation] = []
        override func didMoveToSuperview() { super.didMoveToSuperview(); attach() }
        override func layoutSubviews() { super.layoutSubviews(); attach() }
        func attach() {
            guard let configuration else { return }
            if let recognizer {
                recognizer.configuration = configuration
                if recognizer.isEnabled != configuration.enabled { recognizer.isEnabled = configuration.enabled }
                return
            }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    let gesture = CardRecognizer(target: nil, action: nil)
                    gesture.configuration = configuration
                    gesture.scroll = scroll
                    gesture.isEnabled = configuration.enabled
                    gesture.cancelsTouchesInView = true
                    scroll.addGestureRecognizer(gesture)
                    scroll.panGestureRecognizer.require(toFail: gesture)
                    recognizer = gesture
                    DispatchQueue.main.async { [weak self, weak scroll] in
                        self?.configuration?.onAttach { [weak scroll] in
                            guard let scroll, let window = scroll.window,
                                  let snapshot = scroll.snapshotView(afterScreenUpdates: false) else { return nil }
                            snapshot.frame = scroll.convert(scroll.bounds, to: window)
                            snapshot.isUserInteractionEnabled = false
                            window.addSubview(snapshot)
                            return snapshot
                        }
                    }
                    observations = [scroll.observe(\.contentSize, options: [.initial, .new]) { [weak self] _, _ in self?.measure() },
                                    scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in self?.measure() }]
                    return
                }
                ancestor = view.superview
            }
        }
        func measure() {
            guard let scroll = recognizer?.scroll else { return }
            let overflow = scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom - scroll.bounds.height
            let previous = recognizer?.scrollable ?? false
            let next = overflow > (previous ? 2 : 8)
            recognizer?.scrollable = next
            DispatchQueue.main.async { [weak self] in self?.configuration?.onLayout(next) }
        }
    }
    final class CardRecognizer: UIGestureRecognizer {
        var configuration: ReviewCardPan?
        weak var scroll: UIScrollView?
        var scrollable = false
        private var start = CGPoint.zero
        private var intent = ReviewSwipeIntent()
        private var startedAt = Date()
        private var startedScrollable = false
        private var translation = CGSize.zero
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard event.allTouches?.count == 1, let touch = touches.first, let configuration, configuration.enabled else {
                let active = state == .began || state == .changed
                state = active ? .cancelled : .failed
                if active { self.configuration?.onCancel() }
                return
            }
            let global = touch.location(in: nil)
            guard !configuration.excludedFrames.contains(where: { $0.contains(global) }) else { state = .failed; return }
            var hit: UIView? = touch.view
            while let view = hit, view !== scroll {
                if view is UIControl || view is WKWebView || view is UITextField || view is UITextView {
                    state = .failed; return
                }
                hit = view.superview
            }
            start = global; startedAt = Date(); startedScrollable = scrollable
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            guard let touch = touches.first, state == .possible || state == .began || state == .changed else { return }
            let point = touch.location(in: nil)
            translation = CGSize(width: point.x - start.x, height: point.y - start.y)
            if state == .possible {
                // Long press belongs to text selection; never promote it to grading.
                guard Date().timeIntervalSince(startedAt) < 0.35 else { state = .failed; return }
                let accepted = intent.update(x: translation.width, y: translation.height, scrollable: startedScrollable)
                guard intent.axis != nil else { return }
                guard accepted else { state = .failed; return }
                state = .began
            } else { state = .changed }
            guard intent.accepts(x: translation.width, y: translation.height) else {
                state = .cancelled; configuration?.onCancel(); return
            }
            configuration?.onChange(translation)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            guard state == .began || state == .changed else { state = .failed; return }
            if let touch = touches.first {
                let point = touch.location(in: nil)
                translation = CGSize(width: point.x - start.x, height: point.y - start.y)
            }
            state = .ended
            if intent.accepts(x: translation.width, y: translation.height) { configuration?.onEnd(translation) }
            else { configuration?.onCancel() }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .cancelled; configuration?.onCancel()
        }
        override func reset() {
            super.reset()
            configuration?.onCancel()
            intent = ReviewSwipeIntent(); translation = .zero
        }
    }
}
