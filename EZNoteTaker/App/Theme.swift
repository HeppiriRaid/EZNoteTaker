import SwiftUI

/// A warm "architecture sketchbook" look: paper backgrounds, brick accent, serif headlines.
enum Theme {
    static let brick = Color("AccentColor")
    static let ink = Color.primary
    static let paper = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let recordRed = Color(red: 0.86, green: 0.2, blue: 0.18)
    static let gold = Color(red: 0.85, green: 0.62, blue: 0.16)
    static let sage = Color(red: 0.36, green: 0.55, blue: 0.43)

    static func importanceColor(_ importance: ExamImportance) -> Color {
        switch importance {
        case .high: recordRed
        case .medium: gold
        case .low: .secondary
        }
    }
}

extension Font {
    static func serifTitle(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: .serif) }
    static func serifHeadline(_ size: CGFloat = 19) -> Font { .system(size: size, weight: .semibold, design: .serif) }
}

struct CardBackground: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Renders **bold** and *italic* inline markdown in model-written strings.
struct RichText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

struct Pill: View {
    let text: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct BulletList: View {
    let items: [String]
    var symbol = "circle.fill"
    var color: Color = Theme.brick

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: symbol == "circle.fill" ? 6 : 13))
                        .foregroundStyle(color)
                    RichText(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct SectionLabel: View {
    let title: String
    var systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

/// Thumbnail loaded from the photo store.
struct PhotoThumb: View {
    let fileName: String
    var maxPixel: CGFloat = 600

    var body: some View {
        if let image = ImageCache.shared.thumbnail(for: fileName, maxPixel: maxPixel) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(.quaternary).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }
}

/// Small banner shown at the bottom when something finished in the background.
struct ToastView: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.brick)
            Text(text).font(.subheadline.weight(.medium)).lineLimit(3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal)
    }
}
