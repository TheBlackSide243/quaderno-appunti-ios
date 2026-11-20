import Charts
import SwiftUI
import UserNotifications

/// What was studied each day: flashcards reviewed (and how many right) and minutes of focus with
/// the study timer. Kept in Documents/studio.json.
@MainActor
@Observable
final class StudyLog {
    static let shared = StudyLog()

    struct Day: Codable, Equatable {
        var reviews = 0
        var right = 0
        var focus = 0
    }

    private(set) var days: [String: Day] = [:]
    private static let file = Store.documents.appendingPathComponent("studio.json")

    private init() {
        if let d = try? Data(contentsOf: Self.file), let v = try? JSONDecoder().decode([String: Day].self, from: d) { days = v }
    }

    /// Reads the file again (after a copy of the library was put back).
    func reload() {
        if let d = try? Data(contentsOf: Self.file), let v = try? JSONDecoder().decode([String: Day].self, from: d) { days = v }
    }

    nonisolated static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func logReview(right: Bool, now: Date = Date()) {
        var d = days[Self.key(now)] ?? Day()
        d.reviews += 1
        if right { d.right += 1 }
        days[Self.key(now)] = d
        persist()
    }

    func logFocus(minutes: Int, now: Date = Date()) {
        guard minutes > 0 else { return }
        var d = days[Self.key(now)] ?? Day()
        d.focus += minutes
        days[Self.key(now)] = d
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(days) { try? d.write(to: Self.file, options: .atomic) }
    }

    var streak: Int { Self.streak(days, today: Date()) }

    /// Days in a row with some study, up to today (a day not started yet does not break it).
    nonisolated static func streak(_ days: [String: Day], today: Date) -> Int {
        let cal = Calendar.current
        func studied(_ d: Date) -> Bool { let v = days[key(d)]; return (v?.reviews ?? 0) > 0 || (v?.focus ?? 0) > 0 }
        var day = cal.startOfDay(for: today)
        if !studied(day) { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        var n = 0
        while studied(day) {
            n += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return n
    }

    /// The last `n` days, oldest first.
    func last(_ n: Int, today: Date = Date()) -> [(date: Date, day: Day)] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: today)
        return (0..<n).reversed().compactMap { i in
            guard let d = cal.date(byAdding: .day, value: -i, to: start) else { return nil }
            return (d, days[Self.key(d)] ?? Day())
        }
    }
}

/// The study timer: 25 minutes of focus, then 5 of pause. A notification says when time is up,
/// also with the app closed.
@MainActor
@Observable
final class FocusTimer {
    static let shared = FocusTimer()

    enum Phase { case focus, pause }

    private(set) var phase: Phase = .focus
    /// When the running phase ends (nil = stopped or paused).
    private(set) var end: Date?
    /// Seconds left while paused.
    private(set) var pausedLeft: TimeInterval?
    var focusMinutes = 25
    var pauseMinutes = 5

    var active: Bool { end != nil || pausedLeft != nil }

    func left(_ now: Date = Date()) -> TimeInterval {
        if let pausedLeft { return pausedLeft }
        guard let end else { return 0 }
        return max(0, end.timeIntervalSince(now))
    }

    func start(_ p: Phase = .focus) {
        phase = p
        pausedLeft = nil
        let secs = TimeInterval((p == .focus ? focusMinutes : pauseMinutes) * 60)
        end = Date().addingTimeInterval(secs)
        schedule(after: secs)
    }

    func pause() {
        guard let end else { return }
        pausedLeft = max(0, end.timeIntervalSinceNow)
        self.end = nil
        cancelNotification()
    }

    func resume() {
        guard let p = pausedLeft else { return }
        pausedLeft = nil
        end = Date().addingTimeInterval(p)
        schedule(after: p)
    }

    func stop() {
        if phase == .focus, let end {
            // the minutes already done still count
            let done = Double(focusMinutes * 60) - max(0, end.timeIntervalSinceNow)
            StudyLog.shared.logFocus(minutes: Int(done / 60))
        }
        end = nil
        pausedLeft = nil
        phase = .focus
        cancelNotification()
    }

    /// Called every second by the badge: when a phase is over the next one starts.
    func tick(_ now: Date = Date()) {
        guard let end, now >= end else { return }
        if phase == .focus {
            StudyLog.shared.logFocus(minutes: focusMinutes)
            start(.pause)
        } else {
            self.end = nil
            phase = .focus
        }
    }

    private static let notificationID = "appunti.timer"

    private func schedule(after secs: TimeInterval) {
        let phase = self.phase
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = phase == .focus ? String(localized: "Tempo di una pausa") : String(localized: "Pausa finita")
            c.body = phase == .focus ? String(localized: "Hai studiato per bene: riposati qualche minuto.") : String(localized: "Si ricomincia quando vuoi: apri il quaderno e avvia il timer.")
            c.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, secs), repeats: false)
            center.add(UNNotificationRequest(identifier: Self.notificationID, content: c, trigger: trigger))
        }
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }
}

/// The timer while it runs, in a corner of the page.
struct FocusBadge: View {
    @State private var timer = FocusTimer.shared

    var body: some View {
        if timer.active {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = timer.left(ctx.date)
                Menu {
                    if timer.pausedLeft != nil {
                        Button { timer.resume() } label: { Label("Riprendi", systemImage: "play.fill") }
                    } else {
                        Button { timer.pause() } label: { Label("Metti in pausa", systemImage: "pause.fill") }
                    }
                    if timer.phase == .pause {
                        Button { timer.start(.focus) } label: { Label("Ricomincia a studiare", systemImage: "book") }
                    }
                    Button(role: .destructive) { timer.stop() } label: { Label("Ferma il timer", systemImage: "stop.fill") }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: timer.phase == .focus ? "timer" : "cup.and.saucer.fill")
                        Text(AudioNotes.clock(left)).monospacedDigit()
                        if timer.pausedLeft != nil { Image(systemName: "pause.fill").font(.caption2) }
                    }
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(timer.phase == .focus ? Theme.bg : Theme.text)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(timer.phase == .focus ? Theme.accent : Theme.panel, in: Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: timer.phase == .focus ? 0 : 1))
                }
                .onChange(of: ctx.date) { _, d in timer.tick(d) }
                .accessibilityLabel(timer.phase == .focus ? String(localized: "Timer di studio") : String(localized: "Pausa"))
            }
        }
    }
}

/// How studying is going: days in a row, flashcards of the last two weeks, minutes of focus.
struct StudyStatsView: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var log = StudyLog.shared

    private var due: Int { library.notebooks.reduce(0) { $0 + ($1.cards ?? []).filter { $0.isDue() }.count } }
    private var cards: Int { library.notebooks.reduce(0) { $0 + ($1.cards ?? []).count } }

    var body: some View {
        let days = log.last(14)
        let month = log.last(30).map(\.day)
        let reviews = month.reduce(0) { $0 + $1.reviews }
        let right = month.reduce(0) { $0 + $1.right }
        let focusWeek = log.last(7).reduce(0) { $0 + $1.day.focus }
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        tile(String(localized: "Giorni di fila"), "\(log.streak)", "flame.fill")
                        tile(String(localized: "Da ripassare oggi"), "\(due)", "rectangle.on.rectangle.angled")
                        tile(String(localized: "Risposte giuste (30 giorni)"), reviews == 0 ? "–" : "\(Int((Double(right) / Double(reviews) * 100).rounded()))%", "checkmark.circle.fill")
                        tile(String(localized: "Minuti di studio (7 giorni)"), "\(focusWeek)", "timer")
                    }
                    Panel("Flashcard ripassate") {
                        Chart(days, id: \.date) { d in
                            BarMark(x: .value("Giorno", d.date, unit: .day), y: .value("Carte", d.day.reviews))
                                .foregroundStyle(Theme.accent)
                                .cornerRadius(3)
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 2)) { _ in
                                AxisValueLabel(format: .dateTime.day().month(.narrow), centered: true)
                                    .foregroundStyle(Theme.sub)
                            }
                        }
                        .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(Theme.line); AxisValueLabel().foregroundStyle(Theme.sub) } }
                        .frame(height: 180)
                        Text(cards == 0 ? String(localized: "Non hai ancora flashcard: creale in un quaderno da … → Studio → Crea flashcard.")
                             : String(localized: "\(cards) flashcard in tutto. Ogni giorno in cui ripassi o usi il timer allunga la serie."))
                            .font(.caption).foregroundStyle(Theme.sub)
                    }
                    Panel("Timer di studio") {
                        Text("In un quaderno scegli … → Studio → Timer di studio: 25 minuti di studio, poi 5 di pausa. Ti avvisa anche con l'app chiusa.")
                            .font(.caption).foregroundStyle(Theme.sub)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Statistiche di studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
            .screen()
        }
        .preferredColorScheme(.dark)
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            Text(value).font(.title.weight(.bold).monospacedDigit()).foregroundStyle(Theme.text)
            Text(title).font(.caption).foregroundStyle(Theme.sub).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}
