import SwiftUI

private struct NumericSettingFocusKey: FocusedValueKey { typealias Value = Bool }
extension FocusedValues {
    var numericSettingEditing: Bool? {
        get { self[NumericSettingFocusKey.self] }
        set { self[NumericSettingFocusKey.self] = newValue }
    }
}

enum NumericSettingError {
    case invalid(String)
    case saveFailed
    var message: String {
        switch self {
        case .invalid(let message): return message
        case .saveFailed: return "保存できませんでした。保存値に戻しました。再入力してください。"
        }
    }
}

/// Keeps edits local until Done. Losing focus or leaving the screen cancels them.
struct NumericSettingRow: View {
    let title: String
    let value: String
    let unit: String
    let identifier: String
    var allowsDecimal = false
    let save: (String) -> NumericSettingError?
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { Text(title); input }
            } else {
                HStack { Text(title).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 12); input }
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier(identifier + "Error")
            }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, _ in
            // Saved values (including sliders/dragging) are always authoritative.
            draft = value; error = nil
        }
        .onChange(of: focused) { _, active in
            if !active { draft = value; error = nil }
        }
        .onDisappear { focused = false; draft = value; error = nil }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focused {
                    Button("キャンセル") { focused = false }
                        .accessibilityIdentifier(identifier + "Cancel")
                    Spacer()
                    Button("完了", action: commit)
                        .accessibilityIdentifier(identifier + "Done")
                }
            }
        }
    }

    private var input: some View {
        HStack(spacing: 6) {
            TextField(title, text: $draft)
                .keyboardType(allowsDecimal ? .decimalPad : .numberPad)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: typeSize.isAccessibilitySize ? nil : 96)
                .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
                .focused($focused)
                .focusedValue(\.numericSettingEditing, true)
                .onSubmit(commit)
                .accessibilityLabel(title)
                .accessibilityValue(draft + unit)
                .accessibilityHint("編集可能。完了で保存、キャンセルや欄の移動で取り消します")
                .accessibilityIdentifier(identifier)
            if focused {
                Button {
                    draft = ""; focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(title + "の入力を消去")
                .accessibilityIdentifier(identifier + "Clear")
            }
            Text(unit).fixedSize().accessibilityHidden(true)
        }
    }

    private func commit() {
        if let failure = save(draft) {
            if case .saveFailed = failure { draft = value }
            error = failure.message
        } else {
            focused = false
            draft = value
        }
    }
}
