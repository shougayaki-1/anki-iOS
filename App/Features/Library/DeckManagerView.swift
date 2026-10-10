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
