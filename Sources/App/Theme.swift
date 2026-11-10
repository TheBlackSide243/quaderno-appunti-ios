import SwiftUI

/// The dark palette shared by all of the user's apps; only the accent changes (here: highlighter yellow).
enum Theme {
    static let bg = Color(red: 15 / 255, green: 15 / 255, blue: 17 / 255)
    static let panel = Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255)
    static let line = Color(red: 52 / 255, green: 52 / 255, blue: 60 / 255)
    static let input = Color(red: 38 / 255, green: 38 / 255, blue: 44 / 255)
    static let text = Color(red: 242 / 255, green: 242 / 255, blue: 246 / 255)
    static let sub = Color(red: 150 / 255, green: 150 / 255, blue: 162 / 255)
    static let good = Color(red: 74 / 255, green: 214 / 255, blue: 124 / 255)
    static let bad = Color(red: 240 / 255, green: 96 / 255, blue: 80 / 255)
    static let warn = Color(red: 255 / 255, green: 176 / 255, blue: 32 / 255)
    static let accent = Color(red: 250 / 255, green: 204 / 255, blue: 21 / 255)
    /// Grey behind the paper in the editor.
    static let desk = Color(red: 22 / 255, green: 22 / 255, blue: 26 / 255)
}

/// A rounded panel with a small uppercase title above it.
struct Panel<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title.uppercased()).font(.caption.bold()).foregroundStyle(Theme.sub).tracking(0.6)
                    }
                    Spacer()
                    if let trailing { trailing }
                }
                .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
        }
    }
}

/// A key/value row.
struct InfoRow: View {
    let label: String
    let value: String
    var color: Color = Theme.text

    init(_ label: String, _ value: String, color: Color = Theme.text) {
        self.label = label
        self.value = value
        self.color = color
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.sub)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(Theme.bg)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(Theme.input.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(color.opacity(0.7), lineWidth: 1))
            .foregroundStyle(color)
    }
}

/// A text field in the dark input style.
struct Field: View {
    let title: String
    @Binding var text: String
    var prompt: String = ""
    var secure = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.sub)
            Group {
                if secure { SecureField(prompt, text: $text) } else { TextField(prompt, text: $text) }
            }
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(11)
            .background(Theme.input, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.line, lineWidth: 1))
        }
    }
}

/// A red banner for the last error, dismissable.
struct ErrorBanner: View {
    @Binding var error: String?

    var body: some View {
        if let error {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                Text(error).font(.footnote).foregroundStyle(Theme.text).textSelection(.enabled)
                Spacer()
                Button { self.error = nil } label: { Image(systemName: "xmark").foregroundStyle(Theme.sub) }
            }
            .padding(12)
            .background(Theme.bad.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.bad.opacity(0.5), lineWidth: 1))
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 9, height: 9) }
}

/// A progress bar in the accent color.
struct Bar: View {
    let value: Double
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.input)
                Capsule().fill(color).frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: 7)
    }
}

extension View {
    /// Dark scroll background used by every screen.
    func screen() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}

/// Runs `action` now and then every `seconds` while the view is on screen.
struct Polling: ViewModifier {
    let seconds: Double
    let action: () async -> Void

    func body(content: Content) -> some View {
        content.task {
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }
}

extension View {
    func polling(every seconds: Double, _ action: @escaping () async -> Void) -> some View {
        modifier(Polling(seconds: seconds, action: action))
    }
}
