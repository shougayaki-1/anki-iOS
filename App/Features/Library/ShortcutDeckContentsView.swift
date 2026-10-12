import SwiftUI

// An independent destination; DeckManagerView (#40) remains untouched.
struct ShortcutDeckDestination: Identifiable, Hashable {
    let id: UUID
}

struct ShortcutDeckContentsView: View {
    @Bindable var store: StudyStore
    let deckID: UUID

    private var deck: DeckItem? { store.decks.first { $0.id == deckID } }
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss
    @State private var index: LibraryIndex?
    @State private var results = LibraryResults()
    @State private var cards: [LibraryCard] = []
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        Group {
            if let deck {
                List {
                    Section {
                        Text(deck.name).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("shortcutDeckPath")
                    }
                    if loading { ProgressView("カードを読み込み中") }
                    if let failure { Label(failure, systemImage: "exclamationmark.triangle") }
                    if results.cardCount == 0 && !loading && failure == nil {
                        ContentUnavailableView {
                            Label("このデッキにはカードがありません", systemImage: "rectangle.on.rectangle")
                        } description: {
                            Text("このデッキと下位デッキにはカードがありません。")
                        } actions: {
                            Button("このデッキにカードを追加") { adding = true }
                                .buttonStyle(.borderedProminent).tint(Color("PrimaryAction"))
                                .accessibilityIdentifier("emptyDeckAdd")
                            Button("ライブラリに戻る") { dismiss() }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        Section("カード（下位デッキを含む）") {
                            ForEach(cards) { card in
                                NavigationLink {
                                    NoteDetailView(store: store, cardID: card.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        LibraryCardRow(card: card, index: index).equatable()
                                        Text(index?.notes[card.noteID]?.deckName ?? "").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle(deck.name.components(separatedBy: " / ").last ?? deck.name)
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("shortcutDeckContents")
            } else {
                ContentUnavailableView("デッキが見つかりません", systemImage: "books.vertical",
                                       description: Text("デッキが削除または復元された可能性があります。"))
            }
        }
        .sheet(isPresented: $adding) { NoteEditorView(store: store, item: nil, initialDeckID: deckID) }
        .task(id: store.dataRevision) {
            loading = true
            defer { if !Task.isCancelled { loading = false } }
            do {
                let revision = store.dataRevision
                let allowed = try store.repository.descendants(of: deckID)
                let found = try await store.libraryReader.search("", revision: revision, deckIDs: allowed)
                let loaded = try await store.libraryReader.contents(revision: revision, deckIDs: allowed)
                try Task.checkCancellation()
                guard revision == store.dataRevision else { return }
                cards = found.cardsByDeck.values.flatMap { $0 }.sorted { $0.createdAt > $1.createdAt }
                index = loaded; results = found; failure = nil
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}
