import SwiftUI

struct ReviewView: View {
    @Bindable var store: StudyStore
    @FocusState private var typingFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let review = store.review, let item = review.card {
                        Text(item.deckName).font(.caption).foregroundStyle(.secondary)
                        Text(item.content.question).font(.title2).textSelection(.enabled)
                            .accessibilityIdentifier("reviewQuestion")
                        if let id = item.sourceContent.imageID {
                            if let url = try? store.repository.assetURL(id: id), let image = UIImage(contentsOfFile: url.path) {
                                StudyImageView(image: image, masks: item.kind == .imageOcclusion ? (item.sourceContent.masks ?? []) : [],
                                               targetID: UUID(uuidString: String(item.variantKey.dropFirst("image:".count))),
                                               hideAll: item.sourceContent.hideAllMasks ?? true, revealed: review.answerRevealed)
                            } else { Label("画像を読み込めません。ライブラリで画像を確認してください。", systemImage: "exclamationmark.triangle") }
                        }
                        Picker("回答方法", selection: Binding(get: { review.responseMode }, set: { store.draft(mode: $0) })) {
                            ForEach(ResponseMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                        if review.responseMode == .typing {
                            TextField("自分の回答", text: Binding(get: { store.review?.typedDraft ?? "" }, set: { store.draft(text: $0) }), axis: .vertical)
                                .lineLimit(3...12).textFieldStyle(.roundedBorder).focused($typingFocused)
                                .accessibilityIdentifier("typedAnswer")
                                .disabled(review.answerRevealed)
                        }
                        if review.answerRevealed {
                            Divider()
                            if review.responseMode == .typing {
                                Text("自分の回答").font(.headline)
                                Text(review.typedDraft.isEmpty ? "（未入力）" : review.typedDraft)
                            }
                            Text("模範解答").font(.headline)
                            Text(item.content.answer).textSelection(.enabled).accessibilityIdentifier("modelAnswer")
                            if !item.content.explanation.isEmpty { Text(item.content.explanation).foregroundStyle(.secondary) }
                            Text("誤答にはAgain。Hardは思い出せたが難しかったときに使います。")
                                .font(.footnote).foregroundStyle(.secondary)
                            ForEach(ReviewGrade.allCases, id: \.self) { grade in
                                Button {
                                    typingFocused = false
                                    store.grade(grade)
                                } label: { Text(gradeTitle(grade)).frame(maxWidth: .infinity) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("grade-\(grade.rawValue)")
                                .disabled(!imageAvailable(item))
                            }
                        } else {
                            Button("答えを表示") { typingFocused = false; store.draft(revealed: true) }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("revealAnswer")
                                .disabled(!imageAvailable(item))
                        }
                    } else {
                        ContentUnavailableView("今出題できるカードはありません", systemImage: "checkmark.circle",
                                               description: Text("短期学習の期限が来たら、このセッションで続けられます。"))
                        if let next = store.review?.nextShortDue {
                            Text("次の短期復習: \(next.formatted())")
                        }
                        Button("出題を再確認", action: store.refreshQueue)
                    }
                }.padding()
            }
            .navigationTitle(store.review?.mode.title ?? "学習")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("中断", action: store.pause).accessibilityIdentifier("pauseStudy") }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Undo", action: store.undo).disabled(store.review?.canUndo != true).accessibilityIdentifier("undoReview")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { typingFocused = false } }
            }
            .alert("保存できませんでした", isPresented: Binding(get: { store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
                Button("閉じる", role: .cancel) { store.failure = nil }
            } message: { Text((store.failure ?? "") + "\n評価は確定されていません。再度操作してください。") }
            .task {
                while !Task.isCancelled {
                    if store.review?.card == nil { store.refreshQueue() }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }.interactiveDismissDisabled()
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
