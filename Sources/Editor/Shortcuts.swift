import SwiftUI

/// Keyboard shortcuts of an open notebook, for an iPad with a keyboard (hold ⌘ to see the list).
/// The buttons are invisible: only their shortcuts count. While a text box is being written in
/// the editing shortcuts are off, so ⌘Z and the arrows work on the text.
struct EditorShortcuts: View {
    let model: EditorModel
    var onSearch: () -> Void
    var onPages: () -> Void
    var onClose: () -> Void

    var body: some View {
        let editing = model.drawMode && !model.presenting && !model.replaying
        let turning = !model.notebook.isBoard && (model.drawMode || model.presenting)
        ZStack {
            Button("Annulla l'ultima modifica") { model.canvas.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!editing || !model.canUndo)
            Button("Ripeti") { model.canvas.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!editing || !model.canRedo)
            ForEach(Array(Tool.allCases.enumerated()), id: \.offset) { i, t in
                Button(t.label) { model.select(t) }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                    .disabled(!editing)
            }
            Button("Pagina successiva") { model.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!turning)
            Button("Pagina precedente") { model.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!turning || model.pageIndex == 0)
            Button("Nuova pagina") { model.addPage(after: model.pageIndex, template: nil) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!editing || model.notebook.isBoard)
            Button("Segnalibro") { model.toggleBookmark(model.pageIndex) }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!editing || model.notebook.isBoard)
            Button("Righello") { model.toggleRuler() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!editing)
            Button("Cerca nel quaderno") { onSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.presenting)
            Button("Tutte le pagine") { onPages() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.presenting || model.notebook.isBoard)
            Button("Fine presentazione") { model.setPresenting(false) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!model.presenting)
            Button("Chiudi il quaderno") { onClose() }
                .keyboardShortcut("w", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// Keyboard shortcuts of the shelf; off while a notebook or a sheet is open over it.
struct LibraryShortcuts: View {
    let router: Router

    var body: some View {
        let free = router.open == nil && !router.showSearch && !router.showSettings && !router.showNew && !router.showIntro
            && !router.showTrash && !router.showStats && router.study == nil
        ZStack {
            Button("Nuovo quaderno") { router.showNew = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("Cerca") { router.showSearch = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("Impostazioni") { router.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        .disabled(!free)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
