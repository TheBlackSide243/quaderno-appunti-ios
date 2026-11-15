import SwiftUI
import WidgetKit

/// Widgets for the Home Screen and the Lock Screen: a tap opens the app straight at a new
/// notebook, the last one, the flashcards to review or the search. They show no notes: the
/// notebooks stay inside the app.
@main
struct AppuntiWidgets: WidgetBundle {
    var body: some Widget {
        NewNotebookWidget()
        QuickActionsWidget()
        ReviewWidget()
    }
}

/// The links the app opens (`LibraryView` reads them).
enum WidgetLink {
    static let new = URL(string: "quadernoappunti://new")!
    static let last = URL(string: "quadernoappunti://last")!
    static let review = URL(string: "quadernoappunti://review")!
    static let search = URL(string: "quadernoappunti://search")!
}

/// The same colours as the app.
enum WidgetTheme {
    static let bg = Color(red: 15 / 255, green: 15 / 255, blue: 17 / 255)
    static let panel = Color(red: 28 / 255, green: 28 / 255, blue: 32 / 255)
    static let text = Color(red: 242 / 255, green: 242 / 255, blue: 246 / 255)
    static let sub = Color(red: 150 / 255, green: 150 / 255, blue: 162 / 255)
    static let accent = Color(red: 250 / 255, green: 204 / 255, blue: 21 / 255)
}

/// Nothing changes over time: one entry, for ever.
struct StaticProvider: TimelineProvider {
    struct Entry: TimelineEntry { let date: Date }
    func placeholder(in context: Context) -> Entry { Entry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: Date())], policy: .never))
    }
}

// MARK: New notebook

struct NewNotebookWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "appunti.new", provider: StaticProvider()) { _ in
            NewNotebookView().widgetURL(WidgetLink.new)
        }
        .configurationDisplayName("Nuovo quaderno")
        .description("Apre un quaderno nuovo, pronto per scrivere.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct NewNotebookView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil").font(.system(size: 22, weight: .semibold))
            }
            .accessibilityLabel(Text("Nuovo quaderno"))
            .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nuovo quaderno").font(.headline).widgetAccentable()
                    Text("Tocca per scrivere").font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .containerBackground(.clear, for: .widget)
        default:
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(WidgetTheme.bg)
                    .frame(width: 52, height: 52)
                    .background(WidgetTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer(minLength: 8)
                Text("Nuovo quaderno").font(.headline).foregroundStyle(WidgetTheme.text)
                Text("Tocca per scrivere").font(.caption).foregroundStyle(WidgetTheme.sub)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(WidgetTheme.bg, for: .widget)
        }
    }
}

// MARK: Quick actions

struct QuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "appunti.actions", provider: StaticProvider()) { _ in
            QuickActionsView()
        }
        .configurationDisplayName("Azioni rapide")
        .description("Quaderno nuovo, ultimo quaderno, flashcard e ricerca a un tocco.")
        .supportedFamilies([.systemMedium])
    }
}

struct QuickActionsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "book.closed.fill").foregroundStyle(WidgetTheme.accent)
                Text("Quaderno Appunti").font(.footnote.weight(.semibold)).foregroundStyle(WidgetTheme.sub)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    tile("square.and.pencil", "Nuovo quaderno", WidgetLink.new, strong: true)
                    tile("book", "Ultimo quaderno", WidgetLink.last)
                }
                GridRow {
                    tile("rectangle.on.rectangle.angled", "Ripassa", WidgetLink.review)
                    tile("magnifyingglass", "Cerca", WidgetLink.search)
                }
            }
        }
        .containerBackground(WidgetTheme.bg, for: .widget)
    }

    private func tile(_ icon: String, _ title: LocalizedStringKey, _ url: URL, strong: Bool = false) -> some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(strong ? WidgetTheme.bg : WidgetTheme.accent)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundStyle(strong ? WidgetTheme.bg : WidgetTheme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(strong ? WidgetTheme.accent : WidgetTheme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: Review

struct ReviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "appunti.review", provider: StaticProvider()) { _ in
            ReviewView().widgetURL(WidgetLink.review)
        }
        .configurationDisplayName("Ripassa le flashcard")
        .description("Apre il ripasso del quaderno con più flashcard da ripassare.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

struct ReviewView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryCircular {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: 20, weight: .semibold))
            }
            .accessibilityLabel(Text("Ripassa le flashcard"))
            .containerBackground(.clear, for: .widget)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(WidgetTheme.accent)
                    .frame(width: 52, height: 52)
                    .background(WidgetTheme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Spacer(minLength: 8)
                Text("Ripassa").font(.headline).foregroundStyle(WidgetTheme.text)
                Text("Le flashcard di oggi").font(.caption).foregroundStyle(WidgetTheme.sub)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .containerBackground(WidgetTheme.bg, for: .widget)
        }
    }
}
