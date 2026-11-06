import SwiftUI
import AppKit

// Shared building blocks: one button look, one size scale, so every screen feels the same
// and everything is easy to hit during a service.

enum Size {
    static let big: CGFloat = 44      // transport and main actions
    static let medium: CGFloat = 34   // most buttons
    static let small: CGFloat = 28    // compact rows (lists, steppers)
    static let radius: CGFloat = 9
}

enum ButtonKind { case normal, primary, danger, success, warning }

extension ButtonKind {
    var fill: Color {
        switch self {
        case .normal: return Color(NSColor.controlColor)
        case .primary: return .accentColor
        case .danger: return Color(red: 0.86, green: 0.24, blue: 0.22)
        case .success: return Color(red: 0.18, green: 0.66, blue: 0.38)
        case .warning: return .orange
        }
    }
    var text: Color { self == .normal ? .primary : .white }
}

/// The one button look used across the app: rounded, filled, a clear pressed and disabled state.
struct BigButtonStyle: ButtonStyle {
    var kind: ButtonKind = .normal
    var height: CGFloat = Size.medium
    var fullWidth = false
    var fontSize: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth, fontSize: fontSize)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let kind: ButtonKind
        let height: CGFloat
        let fullWidth: Bool
        let fontSize: CGFloat
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: fontSize, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height, maxHeight: height)
                .foregroundColor(kind.text)
                .background(RoundedRectangle(cornerRadius: Size.radius).fill(kind.fill))
                .overlay(RoundedRectangle(cornerRadius: Size.radius)
                    .stroke(Color(NSColor.separatorColor), lineWidth: kind == .normal ? 1 : 0))
                .overlay(RoundedRectangle(cornerRadius: Size.radius).fill(Color.black.opacity(configuration.isPressed ? 0.18 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: Size.radius))
                .opacity(enabled ? 1 : 0.4)
        }
    }
}

extension View {
    /// Shorthand for the shared button look.
    func big(_ kind: ButtonKind = .normal, height: CGFloat = Size.medium, fullWidth: Bool = false, fontSize: CGFloat = 13) -> some View {
        buttonStyle(BigButtonStyle(kind: kind, height: height, fullWidth: fullWidth, fontSize: fontSize))
    }
}

/// Icon (and optional title) laid out for BigButtonStyle.
struct IconLabel: View {
    let systemName: String
    var title: String? = nil
    var iconSize: CGFloat = 14
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemName).font(.system(size: iconSize, weight: .semibold))
            if let t = title { Text(t).lineLimit(1) }
        }
    }
}

/// A big square-ish icon button (steppers, transport).
struct SquareButton: View {
    let systemName: String
    var size: CGFloat = Size.medium
    var kind: ButtonKind = .normal
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: size * 0.38, weight: .bold))
                .frame(width: size - 24)
        }
        .big(kind, height: size)
        .help(help)
    }
}

/// Large on/off button: filled in colour when on, so its state reads from across the room.
struct ToggleTile: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    var onKind: ButtonKind = .primary
    var height: CGFloat = Size.medium
    var help = ""
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
                Text(title).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .big(isOn ? onKind : .normal, height: height, fullWidth: true)
        .help(help)
    }
}

/// A segmented choice with big, equal-width buttons (the system one is small on Big Sur).
struct Segments<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 30
    var fontSize: CGFloat = 12

    init(_ options: [(T, String)], selection: Binding<T>, height: CGFloat = 30, fontSize: CGFloat = 12) {
        self.options = options
        _selection = selection
        self.height = height
        self.fontSize = fontSize
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                let on = value == selection
                Button(action: { selection = value }) {
                    Text(label)
                        .font(.system(size: fontSize, weight: on ? .semibold : .regular))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: height - 4, maxHeight: height - 4)
                        .foregroundColor(on ? .white : .primary)
                        .background(RoundedRectangle(cornerRadius: Size.radius - 2).fill(on ? Color.accentColor : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Size.radius).fill(Color(NSColor.controlColor)))
        .overlay(RoundedRectangle(cornerRadius: Size.radius).stroke(Color(NSColor.separatorColor), lineWidth: 1))
    }
}

/// Section heading used inside cards: an icon and a name.
struct CardTitle: View {
    let title: String
    var systemImage: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let s = systemImage { Image(systemName: s).foregroundColor(.accentColor) }
            Text(title).font(.system(size: 13, weight: .bold))
        }
        .lineLimit(1)
    }
}

/// A small coloured capsule ("TODAY", "Pad Ab").
struct Badge: View {
    let text: String
    var color: Color = .accentColor
    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundColor(.white).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}

/// Centred placeholder for empty screens.
struct EmptyState: View {
    let systemImage: String
    let title: String
    var message: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 38)).foregroundColor(.secondary)
            Text(title).font(.system(size: 16, weight: .semibold)).multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message).foregroundColor(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
