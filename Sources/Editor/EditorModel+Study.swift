import PencilKit
import SwiftUI
import UIKit

/// Choosing an area, spelling, flashcards, handwriting to text and presenting.
extension EditorModel {
    // MARK: Choosing an area

    func startPicking(_ p: Picking) {
        if !drawMode { setDrawMode(true) }
        picking = p
        canvas.mark(nil)
        syncPick()
    }

    func endPicking() {
        picking = nil
        canvas.mark(nil)
        syncPick()
    }

    func picked(_ r: CGRect) {
        switch picking {
        case .cardFront:
            picking = .cardBack(r)
            canvas.mark(r)
        case .cardBack(let front):
            endPicking()
            var list = notebook.cards ?? []
            list.append(Flashcard(page: page.id, front: front, back: r))
            notebook.cards = list
            canvas.saveNow()
            library.save(notebook)
            notice = String(localized: "Flashcard creata: \(list.count) in questo quaderno.")
        case .inkText:
            endPicking()
            readInk(in: r)
        case .sticker:
            endPicking()
            if let img = canvas.cutout(r) {
                StickerStore.shared.add(img)
                notice = String(localized: "Adesivo salvato: lo trovi tra gli adesivi.")
            } else {
                notice = String(localized: "In quel riquadro non c'è niente.")
            }
        case nil:
            break
        }
    }

    // MARK: Spelling

    func checkSpelling() async {
        guard !checkingSpelling else { return }
        canvas.saveNow()
        checkingSpelling = true
        let pageID = page.id
        let words = await Indexer.shared.words(canvas.canvas.drawing)
        checkingSpelling = false
        guard page.id == pageID else { return }
        misses = SpellCheck.misses(words)
        canvas.showMisspelled(misses.map(\.rect))
        if misses.isEmpty { notice = String(localized: "Nessun errore trovato nella scrittura di questa pagina.") }
    }

    /// Writes the correction as typed text in place of the handwritten word.
    func fix(_ m: SpellCheck.Miss, with word: String) {
        canvas.removeStrokes(in: m.rect.insetBy(dx: -2, dy: -2))
        canvas.addTextBox(word, in: m.rect.insetBy(dx: -4, dy: -6), fontSize: Double(min(40, max(12, m.rect.height * 0.8))).rounded())
        drop(m)
    }

    func drop(_ m: SpellCheck.Miss) {
        misses.removeAll { $0.id == m.id }
        canvas.showMisspelled(misses.map(\.rect))
    }

    func clearMisses() {
        misses = []
        canvas.showMisspelled([])
    }

    // MARK: Flashcards

    /// Questions and answers written by the assistant, as flashcards of this page.
    func addTextCards(_ list: [NoteAI.QA]) {
        guard !list.isEmpty else { return }
        var cards = notebook.cards ?? []
        for qa in list {
            var c = Flashcard(page: page.id, front: .zero, back: .zero)
            c.question = qa.question
            c.answer = qa.answer
            cards.append(c)
        }
        notebook.cards = cards
        library.save(notebook, touch: false)
    }

    var cards: [Flashcard] { notebook.cards ?? [] }
    var dueCards: Int { cards.filter { $0.isDue() }.count }

    func updateCard(_ c: Flashcard) {
        guard let i = notebook.cards?.firstIndex(where: { $0.id == c.id }) else { return }
        notebook.cards?[i] = c
        library.save(notebook, touch: false)
    }

    func deleteCard(_ c: Flashcard) {
        notebook.cards?.removeAll { $0.id == c.id }
        if notebook.cards?.isEmpty == true { notebook.cards = nil }
        library.save(notebook, touch: false)
    }

    // MARK: Handwriting to text

    func readInk(in r: CGRect) {
        let strokes = canvas.strokes(in: r)
        guard !strokes.isEmpty else {
            notice = String(localized: "In quel riquadro non c'è scrittura a mano.")
            return
        }
        inkText = InkText(area: r)
        let d = PKDrawing(strokes: strokes)
        Task {
            let (text, lines) = await Indexer.shared.read(d)
            guard inkText?.area == r else { return }
            inkText?.text = text
            inkText?.lines = max(1, lines)
        }
    }

    /// Puts the text read in a box over the handwriting; with `replace` the handwriting goes.
    func placeInkText(_ text: String, replace: Bool) {
        guard let it = inkText else { return }
        inkText = nil
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let size = min(40, max(12, (Double(it.area.height) / Double(max(1, it.lines))) * 0.62))
        if replace { canvas.removeStrokes(in: it.area) }
        canvas.addTextBox(t, in: replace ? it.area : it.area.offsetBy(dx: 0, dy: it.area.height + 8), fontSize: size.rounded())
    }

    // MARK: Presentation

    func setPresenting(_ on: Bool) {
        guard on != presenting else { return }
        if picking != nil { endPicking() }
        if on {
            toolBeforePresenting = tool
            presenting = true
            canvas.fitWhole = true
            select(.laser)
        } else {
            presenting = false
            canvas.fitWhole = false
            select(toolBeforePresenting == .hand ? .pen : toolBeforePresenting)
        }
    }

    func rename(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        notebook.title = t
        library.save(notebook, touch: false)
    }

    func setFingerDraws(_ on: Bool) {
        fingerDraws = on
        canvas.fingerDraws = on
        UserDefaults.standard.set(on, forKey: "fingerDraws")
    }

    func toggleRuler() {
        ruler.toggle()
        canvas.rulerActive = ruler
    }
}
