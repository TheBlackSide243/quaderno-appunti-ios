import Foundation
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Questions, summaries and quizzes on the notes, with the language model of Apple Intelligence that
/// runs on the device: free, without internet, nothing leaves the phone. It needs iOS 26 and a
/// device with Apple Intelligence turned on; elsewhere the app says why it is not there.
enum NoteAI {
    enum Status: Equatable {
        case ready
        case unavailable(String)
    }

    static var status: Status {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .ready
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return .unavailable(String(localized: "Questo dispositivo non ha Apple Intelligence: serve un iPhone 15 Pro o più recente, oppure un iPad con chip M."))
                case .appleIntelligenceNotEnabled:
                    return .unavailable(String(localized: "Attiva Apple Intelligence in Impostazioni → Apple Intelligence e Siri, poi torna qui."))
                case .modelNotReady:
                    return .unavailable(String(localized: "Il modello di Apple Intelligence si sta ancora scaricando. Riprova tra un po'."))
                @unknown default:
                    return .unavailable(String(localized: "Apple Intelligence non è disponibile in questo momento."))
                }
            }
        }
        return .unavailable(String(localized: "Serve iOS 26 o successivo, su un dispositivo con Apple Intelligence."))
        #else
        return .unavailable(String(localized: "Serve iOS 26 o successivo, su un dispositivo con Apple Intelligence."))
        #endif
    }

    static var italian: Bool { (Locale.current.language.languageCode?.identifier ?? "it") == "it" }

    /// About 1700 tokens of notes: with the instructions and the answer it stays inside the
    /// model's 4096-token window.
    static let budget = 6000

    // MARK: Choosing the notes

    struct Source {
        let page: Int
        let text: String
    }

    /// The text of the pages, numbered from 1, without the empty ones.
    static func sources(_ nb: Notebook, _ texts: [String: PageText]) -> [Source] {
        nb.pages.enumerated().compactMap { i, pg in
            let t = (texts[pg.id.uuidString]?.all ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : Source(page: i + 1, text: t)
        }
    }

    /// The notes to give the model, within the budget: for a question, the pages that share the most
    /// words with it come first.
    static func context(_ sources: [Source], question: String? = nil, budget: Int = budget) -> String {
        var list = sources
        if let q = question {
            let words = Set(Indexer.fold(q).split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 })
            if !words.isEmpty {
                func score(_ s: Source) -> Int {
                    let f = Indexer.fold(s.text)
                    var n = 0
                    for w in words { n += f.components(separatedBy: w).count - 1 }
                    return n
                }
                let scored: [(source: Source, score: Int)] = list.map { (source: $0, score: score($0)) }
                let ordered = scored.sorted { a, b in
                    if a.score != b.score { return a.score > b.score }
                    return a.source.page < b.source.page
                }
                list = ordered.map { $0.source }
            }
        }
        var out = ""
        for s in list {
            let block = (italian ? "[Pagina \(s.page)]\n" : "[Page \(s.page)]\n") + s.text + "\n\n"
            if out.count + block.count > budget {
                let room = budget - out.count
                if room > 300 { out += String(block.prefix(room)) }
                break
            }
            out += block
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a long text into pieces that fit the budget, at paragraph ends where possible.
    static func chunks(_ text: String, size: Int = budget) -> [String] {
        var out: [String] = []
        var cur = ""
        for para in text.components(separatedBy: "\n") {
            if cur.count + para.count + 1 > size, !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
            if para.count > size {
                var rest = Substring(para)
                while rest.count > size {
                    out.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
                cur = String(rest)
            } else {
                cur += (cur.isEmpty ? "" : "\n") + para
            }
        }
        if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }
        return out
    }

    // MARK: Asking the model

    struct QA: Identifiable, Hashable {
        let id = UUID()
        var question: String
        var answer: String
    }

    enum Failure: LocalizedError {
        case unavailable(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .unavailable(let s): s
            case .empty: String(localized: "Non ho trovato testo da leggere: scrivi qualcosa o aspetta che la scrittura venga letta.")
            }
        }
    }

    private static var instructions: String {
        italian
            ? "Sei l'assistente di studio di un'app per prendere appunti. Usi solo gli appunti che ti vengono dati, che possono contenere errori di lettura della scrittura a mano. Rispondi in italiano, in modo chiaro e breve. Quando usi una pagina, citala così: (pagina 3). Se negli appunti la risposta non c'è, dillo."
            : "You are the study assistant of a note-taking app. Use only the notes you are given, which may contain handwriting reading mistakes. Answer in English, clearly and briefly. When you use a page, cite it like this: (page 3). If the answer is not in the notes, say so."
    }

    /// A conversation about some notes; each question can follow the previous ones.
    final class Chat {
        #if canImport(FoundationModels)
        private var session: AnyObject?
        #endif

        func ask(_ question: String, notes: String) async throws -> String {
            guard case .ready = NoteAI.status else {
                if case .unavailable(let why) = NoteAI.status { throw Failure.unavailable(why) }
                throw Failure.empty
            }
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                let s: LanguageModelSession
                if let old = session as? LanguageModelSession {
                    s = old
                } else {
                    s = LanguageModelSession(instructions: NoteAI.instructions)
                    session = s
                }
                let prompt = (NoteAI.italian ? "Appunti:\n" : "Notes:\n") + notes + "\n\n" + (NoteAI.italian ? "Domanda: " : "Question: ") + question
                do {
                    return try await s.respond(to: prompt).content
                } catch {
                    // the conversation outgrew the model's memory: start again with this question only
                    let fresh = LanguageModelSession(instructions: NoteAI.instructions)
                    session = fresh
                    return try await fresh.respond(to: prompt).content
                }
            }
            #endif
            throw Failure.unavailable(String(localized: "Serve iOS 26 o successivo, su un dispositivo con Apple Intelligence."))
        }
    }

    static func summary(of text: String) async throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw Failure.empty }
        if case .unavailable(let why) = status { throw Failure.unavailable(why) }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let ask = italian
                ? "Riassumi questi appunti in pochi punti elenco, con i concetti più importanti:\n\n"
                : "Summarise these notes in a few bullet points, with the most important ideas:\n\n"
            var parts: [String] = []
            for c in chunks(t) {
                let s = LanguageModelSession(instructions: instructions)
                parts.append(try await s.respond(to: ask + c).content)
            }
            if parts.count == 1 { return parts[0] }
            // a summary of the summaries
            let s = LanguageModelSession(instructions: instructions)
            let all = parts.joined(separator: "\n\n")
            return try await s.respond(to: ask + String(all.prefix(budget))).content
        }
        #endif
        throw Failure.unavailable(String(localized: "Serve iOS 26 o successivo, su un dispositivo con Apple Intelligence."))
    }

    static func quiz(from text: String, count: Int = 6) async throws -> [QA] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw Failure.empty }
        if case .unavailable(let why) = status { throw Failure.unavailable(why) }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let s = LanguageModelSession(instructions: instructions)
            let ask = italian
                ? "Scrivi \(count) domande di ripasso su questi appunti, ognuna con la sua risposta breve, in italiano:\n\n"
                : "Write \(count) review questions on these notes, each with its short answer, in English:\n\n"
            let r = try await s.respond(to: ask + String(t.prefix(budget)), generating: GeneratedQuiz.self)
            return r.content.questions.prefix(count).map { QA(question: $0.question, answer: $0.answer) }
                .filter { !$0.question.isEmpty && !$0.answer.isEmpty }
        }
        #endif
        throw Failure.unavailable(String(localized: "Serve iOS 26 o successivo, su un dispositivo con Apple Intelligence."))
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedQuiz {
    @Guide(description: "Review questions, each with its answer")
    var questions: [GeneratedQuestion]
}

@available(iOS 26.0, *)
@Generable
struct GeneratedQuestion {
    @Guide(description: "A short question about the notes")
    var question: String
    @Guide(description: "The answer, one or two sentences")
    var answer: String
}
#endif

// MARK: Spelling

/// Words of the handwriting that the dictionary does not know, with the dictionary's suggestions.
@MainActor
enum SpellCheck {
    struct Miss: Identifiable, Hashable {
        let id = UUID()
        let word: String
        /// Where the word is on the page.
        let rect: CGRect
        let guesses: [String]
    }

    static var languages: [String] {
        let have = Set(UITextChecker.availableLanguages)
        let wanted = NoteAI.italian ? ["it_IT", "it", "en_US", "en"] : ["en_US", "en", "it_IT", "it"]
        var out: [String] = []
        for w in wanted where have.contains(w) && !out.contains(where: { $0.prefix(2) == w.prefix(2) }) { out.append(w) }
        return out
    }

    /// A word counts as wrong only if no language knows it.
    static func misses(_ words: [(String, CGRect)]) -> [Miss] {
        let checker = UITextChecker()
        let langs = languages
        guard !langs.isEmpty else { return [] }
        var out: [Miss] = []
        for (w, r) in words where w.count >= 3 && w.allSatisfy(\.isLetter) {
            let range = NSRange(location: 0, length: (w as NSString).length)
            var guesses: [String] = []
            var known = false
            for l in langs {
                let bad = checker.rangeOfMisspelledWord(in: w, range: range, startingAt: 0, wrap: false, language: l)
                if bad.location == NSNotFound {
                    known = true
                    break
                }
                guesses += checker.guesses(forWordRange: bad, in: w, language: l) ?? []
            }
            if !known {
                var seen = Set<String>()
                let unique = guesses.filter { seen.insert($0.lowercased()).inserted }
                out.append(Miss(word: w, rect: r, guesses: Array(unique.prefix(4))))
            }
        }
        return out
    }
}
