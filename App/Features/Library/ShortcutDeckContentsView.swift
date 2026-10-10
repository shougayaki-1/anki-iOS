import SwiftUI

// An independent destination; DeckManagerView (#40) remains untouched.
struct ShortcutDeckDestination: Identifiable, Equatable {
    let id: UUID
}

struct ShortcutDeckContentsView: View {
    @Bindable var store: StudyStore
    let deckID: UUID

    private var deck: DeckItem? { store.decks.first { $0.id == deckID } }
    private var cards: [NoteItem] {
        let descendants = (try? store.repository.descendants(of: deckID)) ?? Set([deckID])
        return store.notes.filter { descendants.contains($0.deckID) }
    }

    var body: some View {
        Group {
            if let deck {
                List {
                    Section {
                        Text(deck.name).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("shortcutDeckPath")
                    }
                    if cards.isEmpty {
                        ContentUnavailableView("カードがありません", systemImage: "rectangle.on.rectangle",
                                               description: Text("このデッキと下位デッキにはカードがありません。"))
                    } else {
                        Section("カード（下位デッキを含む）") {
                            ForEach(cards) { card in
                                NavigationLink {
                                    NoteDetailView(store: store, cardID: card.cardID)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(card.content.question).lineLimit(2)
                                        Text(card.deckName).font(.caption).foregroundStyle(.secondary)
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
    }
}
