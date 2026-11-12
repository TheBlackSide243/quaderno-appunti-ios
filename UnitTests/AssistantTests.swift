import UIKit
import XCTest
@testable import Appunti

/// What the assistant gives the model, text flashcards, and the spelling check.
final class AssistantTests: XCTestCase {
    private func notebook(_ n: Int) -> Notebook {
        Notebook(title: "Test", pages: (0..<n).map { _ in PageInfo(template: .lined, size: CGSize(width: 595, height: 842)) })
    }

    func testSourcesSkipEmptyPages() {
        let nb = notebook(3)
        var texts: [String: PageText] = [:]
        texts[nb.pages[0].id.uuidString] = PageText(ink: "Newton e la forza")
        texts[nb.pages[2].id.uuidString] = PageText(typed: "Entropia")
        let s = NoteAI.sources(nb, texts)
        XCTAssertEqual(s.map(\.page), [1, 3])
    }

    func testQuestionPutsTheRightPageFirst() {
        let src = [NoteAI.Source(page: 1, text: "La cellula e il nucleo"), NoteAI.Source(page: 2, text: "Il teorema di Pitagora sui triangoli rettangoli"),
                   NoteAI.Source(page: 3, text: "Le reazioni chimiche")]
        let ctx = NoteAI.context(src, question: "Cosa dice il teorema di Pitagora?")
        let p2 = ctx.range(of: "Pitagora")!.lowerBound
        let p1 = ctx.range(of: "cellula")!.lowerBound
        XCTAssertLessThan(p2, p1)
    }

    func testContextStaysInsideTheBudget() {
        let src = (1...40).map { NoteAI.Source(page: $0, text: String(repeating: "parola ", count: 200)) }
        XCTAssertLessThanOrEqual(NoteAI.context(src).count, NoteAI.budget)
        let parts = NoteAI.chunks(String(repeating: "riga di testo\n", count: 2000), size: 1000)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 1000 })
        XCTAssertGreaterThan(parts.count, 20)
    }

    func testStatusWithoutAppleIntelligenceSaysWhy() {
        // the simulators of the build machines have no Apple Intelligence
        if case .unavailable(let why) = NoteAI.status { XCTAssertFalse(why.isEmpty) }
    }

    func testTextCards() throws {
        var c = Flashcard(page: UUID(), front: .zero, back: .zero)
        XCTAssertFalse(c.isText)
        c.question = "Quanto vale g?"
        c.answer = "9,81 m/s²"
        XCTAssertTrue(c.isText)
        let back = try JSONDecoder().decode(Flashcard.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.answer, "9,81 m/s²")
    }

    @MainActor
    func testSpelling() throws {
        let langs = SpellCheck.languages
        try XCTSkipIf(langs.isEmpty, "no dictionaries on this simulator")
        let r = CGRect(x: 0, y: 0, width: 50, height: 20)
        let misses = SpellCheck.misses([("hello", r), ("ciao", r), ("helo", r), ("ok", r), ("2024", r)])
        let words = misses.map(\.word)
        XCTAssertFalse(words.contains("hello"))
        XCTAssertFalse(words.contains("ok"), "short words are not checked")
        XCTAssertFalse(words.contains("2024"))
        XCTAssertTrue(words.contains("helo"))
        XCTAssertFalse(misses.first { $0.word == "helo" }?.guesses.isEmpty ?? true)
    }
}
