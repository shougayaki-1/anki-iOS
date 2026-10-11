import SwiftUI

// Build hierarchy from parent IDs; DeckItem.name remains the full path for context.
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

    static func selectionAncestors(of id: UUID?, in decks: [DeckItem]) -> Set<UUID> {
        let parents = Dictionary(uniqueKeysWithValues: decks.map { ($0.id, $0.parentID) })
        var result = Set<UUID>(), current = id
        while let value = current, let parent = parents[value] ?? nil {
            guard result.insert(parent).inserted else { break }
            current = parent
        }
        return result
    }

    static func selectionRows(from decks: [DeckItem], expanded: Set<UUID>, search: String) -> [DeckTreeRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let roots = roots(from: decks)
        guard !query.isEmpty else { return visibleRows(roots: roots, expanded: expanded) }
        return visibleRows(roots: roots, expanded: Set(decks.map(\.id)))
            .filter { $0.path.localizedStandardContains(query) }
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
    @State private var learning: DeckLearningOverride?
    @State private var effectiveRetention = 90
    @State private var effectiveLimit = ""
    @State private var parentID: UUID?
    @State private var destination: UUID?
    @State private var deleting = false
    @State private var excluded: Set<UUID> = []
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                TextField("デッキ名", text: $name).accessibilityIdentifier("deckNameInput")
                DeckSelectionField("親デッキ", decks: store.decks, selection: $parentID, nilTitle: "なし（最上位）", excluded: excluded).accessibilityIdentifier("deckParentPicker")
            }
            if let deckID {
                Section("学習設定") {
                    Toggle("新規上限を指定", isOn: Binding(get: { learning?.newLimit != nil }, set: { learning?.newLimit = $0 ? 20 : nil }))
                    if let value = learning?.newLimit {
                        Stepper("新規上限：\(value)枚／日", value: Binding(get: { learning?.newLimit ?? 20 }, set: { learning?.newLimit = $0 }), in: 0...500)
                    }
                    Toggle("目標保持率を指定", isOn: Binding(get: { learning?.retention != nil }, set: { learning?.retention = $0 ? 0.9 : nil }))
                    if let value = learning?.retention {
                        Stepper("目標保持率：\(Int((value * 100).rounded()))%", value: Binding(get: { Int(((learning?.retention ?? 0.9) * 100).rounded()) }, set: { learning?.retention = Double($0) / 100 }), in: 80...97)
                    }
                    Text("保存済みの実効保持率：\(effectiveRetention)%\n新規上限：\(effectiveLimit)")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("未指定は親から継承します。新規学習は全体・親・このデッキの上限をすべて守ります。保持率は次の回答から適用し、既存の復習予定を変更しません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
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
                    DeckSelectionField("ノート移動先", decks: store.decks, selection: $destination, excluded: excluded)
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
                    learning = try store.repository.options().deckLearning?.first { $0.deckID == id } ?? DeckLearningOverride(deckID: id)
                    effectiveRetention = Int((try store.repository.deckRetention(id) * 100).rounded())
                    let limits = try store.repository.deckLimits(id).values
                    effectiveLimit = "全体\(store.settings.dailyNewLimit)枚" + (limits.min().map { "、デッキ\($0)枚（子孫共通）" } ?? "、全体設定を継承")
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
            if let id = deckID {
                try store.repository.moveDeck(id: id, name: name, parentID: parentID, learning: learning, now: store.clock())
            }
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
                        DeckSelectionField("移動先デッキ", decks: store.decks, selection: $destination, excluded: Set(store.decks.map(\.id)).subtracting(availableDestinations.map(\.id)))
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

// Shared single-deck selection. Callers own persistence and nil semantics.
struct DeckSelectionField: View {
    let title: String
    let decks: [DeckItem]
    @Binding var selection: UUID?
    var nilTitle: String? = nil
    var excluded: Set<UUID> = []
    var includesDescendants = false
    @State private var showing = false

    init(_ title: String, decks: [DeckItem], selection: Binding<UUID?>,
         nilTitle: String? = nil, excluded: Set<UUID> = [], includesDescendants: Bool = false) {
        self.title = title; self.decks = decks; self._selection = selection
        self.nilTitle = nilTitle; self.excluded = excluded; self.includesDescendants = includesDescendants
    }
    init(_ title: String, decks: [DeckItem], selection: Binding<UUID>) {
        self.init(title, decks: decks, selection: Binding<UUID?>(
            get: { selection.wrappedValue },
            set: { if let id = $0 { selection.wrappedValue = id } }))
    }
    private var selected: DeckItem? { decks.first { $0.id == selection } }
    var body: some View {
        Button { showing = true } label: {
            HStack {
                Text(title)
                Spacer()
                Text(selected?.shortName ?? (selection == nil ? nilTitle ?? "選択してください" : "選択先が見つかりません"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right").font(.caption)
            }
            .foregroundStyle(.primary)
        }
        .accessibilityLabel(title + "、" + (selected?.name ?? (selection == nil ? nilTitle ?? "選択してください" : "選択先が見つかりません")))
        .accessibilityHint(includesDescendants ? "選択したデッキとすべての子孫を対象にします" : "所属先のデッキを選びます")
        .sheet(isPresented: $showing) {
            DeckSelectionSheet(title: title, decks: decks, selection: $selection,
                               nilTitle: nilTitle, excluded: excluded, includesDescendants: includesDescendants)
        }
    }
}

struct DeckSelectionSheet: View {
    let title: String
    let decks: [DeckItem]
    @Binding var selection: UUID?
    let nilTitle: String?
    let excluded: Set<UUID>
    let includesDescendants: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = Set<UUID>()
    @State private var search = ""
    @State private var initialized = false

    private var rows: [DeckTreeRow] {
        DeckTreeBuilder.selectionRows(from: decks, expanded: expanded, search: search)
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let nilTitle, search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button { selection = nil; dismiss() } label: {
                            HStack {
                                Text(nilTitle); Spacer()
                                if selection == nil { Image(systemName: "checkmark") }
                            }
                        }.accessibilityAddTraits(selection == nil ? .isSelected : [])
                            .accessibilityIdentifier("selectAllDecks")
                    }
                    if rows.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "デッキがありません" : "該当するデッキがありません",
                                               systemImage: "folder", description: Text("検索条件やデッキ管理を確認してください。"))
                    }
                    ForEach(rows) { row in
                        HStack(spacing: 4) {
                            if row.hasChildren && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Button {
                                    if !expanded.insert(row.id).inserted { expanded.remove(row.id) }
                                } label: {
                                    Image(systemName: expanded.contains(row.id) ? "chevron.down" : "chevron.right")
                                        .frame(width: 44, height: 44).contentShape(Rectangle())
                                }.accessibilityLabel(row.path + (expanded.contains(row.id) ? "を折りたたむ" : "を展開する"))
                                    .accessibilityIdentifier("selectDeckDisclosure-" + row.id.uuidString)
                            } else if search.isEmpty {
                                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                            }
                            Button { selection = row.id; dismiss() } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(row.name).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                                        if !search.isEmpty || row.depth >= 6 {
                                            Text(row.path).font(.caption).foregroundStyle(Color("SecondaryText"))
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer()
                                    if selection == row.id { Image(systemName: "checkmark") }
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .contentShape(Rectangle())
                            }.disabled(excluded.contains(row.id))
                                .accessibilityLabel(row.path)
                                .accessibilityValue(excluded.contains(row.id) ? "選択不可" : (selection == row.id ? "選択中" : "未選択"))
                                .accessibilityHint(row.hasChildren ? "子デッキがあります" : "子デッキはありません")
                                .accessibilityAddTraits(selection == row.id ? .isSelected : [])
                                .accessibilityIdentifier("selectDeck-" + row.id.uuidString)
                        }.padding(.leading, search.isEmpty ? CGFloat(min(row.depth, 6)) * 12 : 0)
                            .id(row.id)
                    }
                    if includesDescendants {
                        Text("選んだデッキとすべての子孫が対象です。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.borderless)
                    .scrollDismissesKeyboard(.interactively)
                    .task {
                        guard !initialized else { return }
                        expanded = DeckTreeBuilder.selectionAncestors(of: selection, in: decks)
                        initialized = true
                        await Task.yield()
                        if let selection { proxy.scrollTo(selection, anchor: .center) }
                    }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "デッキ名を検索")
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }.accessibilityIdentifier("cancelDeckSelection")
                }
            }
        }
    }
}
