import SwiftUI

// Use actual parent IDs for the manager; DeckItem.name remains the full path for pickers.
struct DeckTreeNode: Identifiable {
    let id: UUID
    let name: String
    let children: [DeckTreeNode]
}

struct DeckTreeRow: Identifiable {
    let id: UUID
    let name: String
    let path: String
    let depth: Int
    let hasChildren: Bool
}

enum DeckTreeBuilder {
    static func roots(from decks: [DeckItem]) -> [DeckTreeNode] {
        let byID = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0) })
        let sorted = decks.sorted {
            let order = $0.shortName.localizedStandardCompare($1.shortName)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
        let byParent = Dictionary(grouping: sorted, by: \.parentID)
        var seen = Set<UUID>()

        func build(_ deck: DeckItem, ancestors: Set<UUID>) -> DeckTreeNode? {
            guard !seen.contains(deck.id), !ancestors.contains(deck.id) else { return nil }
            seen.insert(deck.id)
            let chain = ancestors.union([deck.id])
            return DeckTreeNode(id: deck.id, name: deck.shortName,
                                children: (byParent[deck.id] ?? []).compactMap { build($0, ancestors: chain) })
        }

        let topLevel = sorted.filter { $0.parentID == nil || $0.parentID.map { byID[$0] == nil } == true }
        var result = topLevel.compactMap { build($0, ancestors: []) }
        // Malformed legacy parent cycles must not make whole decks disappear.
        result.append(contentsOf: sorted.compactMap { build($0, ancestors: []) })
        return result
    }

    static func visibleRows(roots: [DeckTreeNode], expanded: Set<UUID>) -> [DeckTreeRow] {
        var result: [DeckTreeRow] = []
        func visit(_ node: DeckTreeNode, depth: Int, parentPath: String) {
            let path = parentPath.isEmpty ? node.name : "\(parentPath) / \(node.name)"
            result.append(DeckTreeRow(id: node.id, name: node.name, path: path,
                                      depth: depth, hasChildren: !node.children.isEmpty))
            if expanded.contains(node.id) {
                for child in node.children { visit(child, depth: depth + 1, parentPath: path) }
            }
        }
        for root in roots { visit(root, depth: 0, parentPath: "") }
        return result
    }
}

struct DeckManagerView: View {
    @Bindable var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var addingParentID: UUID?
    @State private var expanded = Set<UUID>()

    private var visibleRows: [DeckTreeRow] {
        DeckTreeBuilder.visibleRows(roots: DeckTreeBuilder.roots(from: store.decks), expanded: expanded)
    }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink("デッキファイルの共有・取込") { DeckExchangeView(store: store) }.accessibilityIdentifier("openDeckExchange")
                ForEach(visibleRows) { row in
                    HStack(spacing: 4) {
                        if row.hasChildren {
                            Button {
                                if expanded.contains(row.id) { expanded.remove(row.id) }
                                else { expanded.insert(row.id) }
                            } label: {
                                Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(row.path)を\(expanded.contains(row.id) ? "折りたたむ" : "展開する")")
                            .accessibilityIdentifier("deckDisclosure-\(row.id.uuidString)")
                        } else {
                            Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                        }
                        NavigationLink {
                            DeckEditorView(store: store, deckID: row.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(row.name, systemImage: "folder")
                                    .fixedSize(horizontal: false, vertical: true)
                                // Keep names readable on narrow screens without hiding
                                // levels once visual indentation reaches its width budget.
                                if row.depth >= 6 {
                                    Text("第\(row.depth + 1)階層")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityLabel("\(row.path)を編集")
                        .accessibilityValue("第\(row.depth + 1)階層")
                        .accessibilityIdentifier("deckEdit-\(row.id.uuidString)")
                    }
                    .padding(.leading, CGFloat(min(row.depth, 6)) * 14)
                    .contextMenu {
                        Button("子デッキを追加", systemImage: "folder.badge.plus") {
                            addingParentID = row.id
                            adding = true
                        }
                    }
                }
            }
            .navigationTitle("デッキ管理")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("デッキ追加", systemImage: "plus") {
                        addingParentID = nil
                        adding = true
                    }
                }
            }
            .sheet(isPresented: $adding, onDismiss: {
                if let parent = addingParentID { expanded.insert(parent) }
                addingParentID = nil
            }) {
                NavigationStack {
                    DeckEditorView(store: store, deckID: nil, initialParentID: addingParentID)
                }
            }
            .onChange(of: Set(store.decks.map(\.id))) { _, validIDs in
                expanded.formIntersection(validIDs)
            }
        }
    }
}

struct DeckEditorView: View {
    @Bindable var store: StudyStore
    let deckID: UUID?
    var initialParentID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parentID: UUID?
    @State private var destination: UUID?
    @State private var deleting = false
    @State private var excluded: Set<UUID> = []
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                TextField("デッキ名", text: $name).accessibilityIdentifier("deckNameInput")
                Picker("親デッキ", selection: $parentID) {
                    Text("なし（最上位）").tag(UUID?.none)
                    ForEach(store.decks.filter { !excluded.contains($0.id) }) { Text($0.name).tag(Optional($0.id)) }
                }.accessibilityIdentifier("deckParentPicker")
            }
            if let deckID {
                Section {
                    NavigationLink {
                        DeckContentsOperationView(store: store, sourceID: deckID, operation: .move)
                    } label: {
                        Label("このデッキのカードを移動", systemImage: "folder")
                    }
                    .accessibilityIdentifier("moveDeckContents")
                    NavigationLink {
                        DeckContentsOperationView(store: store, sourceID: deckID, operation: .delete)
                    } label: {
                        Label("このデッキのカードをすべて削除", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .accessibilityIdentifier("deleteDeckContents")
                } header: {
                    Text("カード・ノートの一括操作")
                } footer: {
                    Text("デッキ自体は削除しません。既定はこのデッキ直下のみです。確定前に件数を確認できます。")
                }
            }
            if deckID != nil {
                Section {
                    Picker("ノート移動先", selection: $destination) {
                        Text("選択してください").tag(UUID?.none)
                        ForEach(store.decks.filter { !excluded.contains($0.id) }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("デッキを削除", role: .destructive) { deleting = true }
                } header: { Text("削除時の移動先") } footer: { Text("子孫デッキも削除します。ノートを別のデッキへ移すか、カードと一緒に削除するか選べます。回答履歴は保持します。") }
            }
        }
        .navigationTitle(deckID == nil ? "デッキ追加" : "デッキ編集")
        .toolbar {
            if deckID == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }.accessibilityIdentifier("cancelDeckEditor")
                }
            }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .task {
            do {
                if let id = deckID, let deck = try store.repository.decks().first(where: { $0.id == id }) {
                    name = deck.name; parentID = deck.parentID; excluded = try store.repository.descendants(of: id)
                } else if deckID == nil, let initialParentID, store.decks.contains(where: { $0.id == initialParentID }) {
                    parentID = initialParentID
                }
            } catch { failure = error.localizedDescription }
        }
        .confirmationDialog("デッキと子孫を削除しますか？", isPresented: $deleting, titleVisibility: .visible) {
            Button("ノートを移動して削除") { remove(move: destination) }.disabled(destination == nil)
            Button("ノート・カードも削除", role: .destructive) { remove(move: nil) }
        }
        .alert("処理できませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("閉じる", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private func save() {
        do {
            if let id = deckID { try store.repository.moveDeck(id: id, name: name, parentID: parentID, now: store.clock()) }
            else { try store.repository.createDeck(name: name, parentID: parentID, now: store.clock()) }
            try store.reload(); dismiss()
        } catch { failure = error.localizedDescription }
    }
    private func remove(move: UUID?) {
        guard let id = deckID else { return }
        do { try store.repository.deleteDeck(id: id, moveNotesTo: move, now: store.clock()); try store.reload(); dismiss() }
        catch { failure = error.localizedDescription }
    }
}


private enum DeckContentsOperationKind: String {
    case move, delete
}

private struct DeckContentsOperationView: View {
    @Bindable var store: StudyStore
    let sourceID: UUID
    let operation: DeckContentsOperationKind

    @Environment(\.dismiss) private var dismiss
    @State private var includeChildren = false
    @State private var destination: UUID?
    @State private var preview: DeckContentsPreview?
    @State private var confirming = false
    @State private var completed: String?
    @State private var failure: String?

    private var sourceName: String {
        store.decks.first(where: { $0.id == sourceID })?.name ?? "削除されたデッキ"
    }
    private var hasChildren: Bool {
        store.decks.contains(where: { $0.parentID == sourceID })
    }
    private var scope: DeckContentsScope {
        includeChildren && hasChildren ? .includingDescendants : .direct
    }
    private var availableDestinations: [DeckItem] {
        let invalid: Set<UUID> = scope == .includingDescendants
            ? ((try? store.repository.descendants(of: sourceID)) ?? [sourceID])
            : [sourceID]
        return store.decks.filter { !invalid.contains($0.id) }
    }
    private var action: DeckContentsAction? {
        switch operation {
        case .move: return destination.map { .move(to: $0) }
        case .delete: return .delete
        }
    }

    var body: some View {
        Form {
            if let completed {
                Section("完了") {
                    Text(completed).accessibilityIdentifier("deckContentsResult")
                    Button("戻る") { dismiss() }
                }
            } else {
                Section("対象デッキ") {
                    Text(sourceName)
                    Text("デッキの名前や階層は変更しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("操作する範囲") {
                    Text(scope.title)
                    if hasChildren {
                        Toggle("子デッキの中身も含める", isOn: $includeChildren)
                            .accessibilityIdentifier("deckContentsIncludeDescendants")
                    }
                    Text(scope == .direct
                         ? "このデッキに直接所属するノートと兄弟カードだけが対象です。"
                         : "すべての子孫デッキに所属するノートと兄弟カードも対象です。子デッキは残ります。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if operation == .move {
                    Section("移動先") {
                        Picker("移動先デッキ", selection: $destination) {
                            Text("選択してください").tag(UUID?.none)
                            ForEach(availableDestinations) { deck in
                                Text(deck.name).tag(Optional(deck.id))
                            }
                        }
                        .accessibilityIdentifier("deckContentsDestination")
                        Text("移動元自身は選べません。子孫込みの場合、移動元配下のデッキも選べません。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        Text("削除後もデッキと子デッキは残ります。過去の回答履歴も保持します。")
                        Text("必要なデータは、実行前に設定のバックアップから書き出してください。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("対象と件数を確認") { prepare() }
                        .disabled(action == nil)
                        .accessibilityIdentifier("previewDeckContents")
                }
                if let preview {
                    Section("確定前のプレビュー") {
                        LabeledContent("対象", value: preview.sourcePath)
                        LabeledContent("範囲", value: preview.scope.title)
                        if let destinationPath = preview.destinationPath {
                            LabeledContent("移動先", value: destinationPath)
                        }
                        Text("対象：\(preview.noteCount)ノート・\(preview.cardCount)枚のカード")
                            .accessibilityIdentifier("deckContentsTargetCounts")
                        Text("実際の変更：\(preview.changedNoteCount)ノート・\(preview.changedCardCount)枚")
                            .accessibilityIdentifier("deckContentsChangedCounts")
                        if !preview.includedChildPaths.isEmpty {
                            DisclosureGroup("対象に含む子デッキ（\(preview.includedChildPaths.count)件）") {
                                ForEach(preview.includedChildPaths, id: \.self) { Text($0) }
                            }
                        }
                        if !preview.canCommit {
                            Text("変更対象がありません。カードが0枚か、すでに移動済みです。")
                                .foregroundStyle(.secondary)
                        } else {
                            Button(operation == .delete ? "削除内容を確定する" : "移動内容を確定する") {
                                confirming = true
                            }
                            .disabled(!preview.canCommit)
                            .accessibilityIdentifier("commitDeckContents")
                        }
                    }
                }
            }
        }
        .navigationTitle(operation == .move ? "デッキのカードを移動" : "デッキのカードだけ削除")
        .onChange(of: includeChildren) { _, _ in
            preview = nil
            if let destination, !availableDestinations.contains(where: { $0.id == destination }) {
                self.destination = nil
            }
        }
        .onChange(of: destination) { _, _ in preview = nil }
        .onChange(of: store.decks.map(\.id)) { _, _ in preview = nil }
        .confirmationDialog(
            operation == .delete ? "カードだけを削除しますか？" : "カードを移動しますか？",
            isPresented: $confirming, titleVisibility: .visible
        ) {
            if let preview, preview.canCommit {
                Button(
                    operation == .delete
                        ? "\(preview.changedNoteCount)ノート・\(preview.changedCardCount)枚を削除"
                        : "\(preview.changedNoteCount)ノート・\(preview.changedCardCount)枚を移動",
                    role: operation == .delete ? .destructive : nil
                ) {
                    commit()
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            if let preview {
                Text(operation == .delete
                     ? "\(preview.changedNoteCount)ノート・\(preview.changedCardCount)枚のカードを削除します。デッキと子デッキは残ります。この操作は元に戻せません。"
                     : "\(preview.changedNoteCount)ノート・\(preview.changedCardCount)枚のカードを「\(preview.destinationPath ?? "")」へ移動します。デッキと子デッキは残ります。")
            }
        }
        .alert("処理できませんでした", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("閉じる", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func prepare() {
        preview = nil
        do {
            guard let action else { throw LibraryError.invalidDestination }
            preview = try store.repository.previewDeckContents(deckID: sourceID, scope: scope, action: action)
        } catch { failure = error.localizedDescription }
    }

    private func commit() {
        guard let preview, preview.canCommit else { return }
        do {
            let result = try store.repository.applyDeckContents(preview, now: store.clock())
            self.preview = nil
            completed = operation == .delete
                ? "\(result.changedNotes)ノート・\(result.changedCards)枚を削除しました。デッキと子デッキは残っています。"
                : "\(result.changedNotes)ノート・\(result.changedCards)枚を移動しました。"
            // A completed transaction must not be reported as a failed deletion
            // if only post-commit UI/notification refresh fails.
            do { try store.reload() }
            catch { failure = "変更は保存済みですが、画面更新に失敗しました。再表示してください。\n" + error.localizedDescription }
            if operation == .delete {
                // Mirror NoteEditorView's post-save media cleanup. Media removal is
                // deliberately separate from the atomic Note/Card database deletion.
                do { try store.repository.cleanupUnusedMedia() }
                catch {
                    let warning = "カードは削除済みですが、不要な画像の整理に失敗しました。\n" + error.localizedDescription
                    failure = failure.map { $0 + "\n" + warning } ?? warning
                }
            }
        } catch {
            self.preview = nil
            failure = error.localizedDescription + "\n対象が変更されていた場合は、プレビューを作り直してください。"
        }
    }
}
