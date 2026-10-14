import SwiftUI

/// Screen-level actions only. Navigation bars, menus and List rows use system controls.
struct PrimaryActionStyle: ButtonStyle {
    var color: Color = Color("PrimaryAction")
    var foreground: Color = .white
    var capsule = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(foreground)
            .background {
                RoundedRectangle(cornerRadius: capsule ? 28 : 14)
                    .fill(color)
                    .overlay {
                        RoundedRectangle(cornerRadius: capsule ? 28 : 14)
                            .fill(.black.opacity(configuration.isPressed ? 0.15 : 0))
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: capsule ? 28 : 14))
            .opacity(isEnabled ? 1 : 0.35)
    }
}

/// Text actions keep a lighter appearance while the entire 44pt label is tappable.
struct SecondaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 44)
            .foregroundStyle(.tint)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

/// Used inside safeAreaInset so the scrollable content and keyboard retain their space.
struct BottomActionArea<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 8) { content }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
    }
}

/// Grade assets are the source of truth for buttons, swipe feedback and result labels.
extension ReviewGrade {
    var color: Color {
        switch self {
        case .again: return Color("GradeAgain")
        case .hard: return Color("GradeHard")
        case .good: return Color("GradeGood")
        case .easy: return Color("GradeEasy")
        }
    }
}
