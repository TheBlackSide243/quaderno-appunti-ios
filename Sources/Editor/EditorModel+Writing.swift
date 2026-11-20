import PencilKit
import SwiftUI
import UIKit

/// The lasso, the zoom window, boxes and recordings.
extension EditorModel {
    // MARK: Lasso selection

    func recolorSelection(_ hex: String) { canvas.recolorSelection(UIColor(hex: hex)) }
    func duplicateSelection() { canvas.duplicateSelection() }
    func deleteSelection() { canvas.deleteSelection() }
    func clearSelection() { canvas.clearSelection() }

    func copySelection() {
        canvas.copySelection()
        notice = String(localized: "Copiato: incollalo da … → Aggiungi → Incolla, anche in un altro quaderno.")
    }

    /// Reads the handwriting that was chosen with the lasso.
    func readSelection() {
        guard let r = canvas.selectionRect else { return }
        readInk(in: r.insetBy(dx: -4, dy: -4))
    }

    // MARK: Zoom window

    func setUpZoomPad() {
        zoomPad.page = canvas
        zoomPad.zoom = zoomLevel
        zoomPad.onSize = { [weak self] size in self?.zoomResized(size) }
        zoomPad.onCommit = { [weak self] right in self?.zoomCommitted(right) }
    }

    func toggleZoom() {
        zoomOn.toggle()
        if zoomOn {
            if picking != nil { endPicking() }
            if !tool.inks || tool == .tape { select(.pen) }
            // starts at the left margin, near the top of what is in view
            let c = canvas.visibleCenter
            zoomBox.origin = CGPoint(x: zoomMargin, y: max(20, c.y - 120))
            clampZoomBox()
            canvas.onZoomTap = { [weak self] p in self?.moveZoom(to: p) }
            zoomPad.syncTool()
            showZoomBox()
        } else {
            canvas.onZoomTap = nil
            canvas.showZoomBox(nil)
        }
    }

    /// The left edge where a new line starts: after the margin of lined paper.
    private var zoomMargin: CGFloat { page.template == .lined || page.template == .checklist ? 70 : 24 }

    private func zoomResized(_ size: CGSize) {
        zoomBox.size = size
        clampZoomBox()
        showZoomBox()
    }

    func setZoomLevel(_ z: CGFloat) {
        zoomLevel = z
        UserDefaults.standard.set(Double(z), forKey: "zoomLevel")
        zoomPad.zoom = z
        zoomPad.syncTool()
    }

    func zoomStep(_ dir: CGFloat) {
        zoomBox.origin.x += dir * zoomBox.width * 0.7
        if dir > 0, zoomBox.maxX > page.size.width - 4 { zoomNewLine(); return }
        clampZoomBox()
        showZoomBox()
    }

    func zoomNewLine() {
        zoomBox.origin.x = zoomMargin
        zoomBox.origin.y += zoomBox.height * 0.75
        clampZoomBox()
        showZoomBox()
    }

    func moveZoom(to p: CGPoint) {
        zoomBox.origin = CGPoint(x: p.x - zoomBox.width * 0.1, y: p.y - zoomBox.height * 0.72)
        clampZoomBox()
        showZoomBox()
    }

    /// The writing reached the right end of the strip: the box moves on.
    private func zoomCommitted(_ right: CGFloat) {
        if right > 0.8 { zoomStep(1) }
    }

    private func clampZoomBox() {
        let s = page.size
        zoomBox.origin.x = min(max(0, zoomBox.origin.x), max(0, s.width - zoomBox.width))
        zoomBox.origin.y = min(max(0, zoomBox.origin.y), max(0, s.height - zoomBox.height))
    }

    private func showZoomBox() {
        guard zoomOn else { return }
        canvas.showZoomBox(zoomBox)
        zoomPad.box = zoomBox
        zoomPad.refresh()
    }

    // MARK: Boxes

    func addText() {
        tools.tool = .hand
        drawMode = false
        canvas.addText()
    }

    func addImage(_ img: UIImage, sticker: Bool = false) {
        tools.tool = .hand
        drawMode = false
        canvas.addImage(img, sticker: sticker)
    }

    /// Puts what is on the clipboard on the page: a picture, or text in a new box. False if there is nothing.
    func paste() -> Bool {
        if canvas.pasteInk() { return true }
        let board = UIPasteboard.general
        if board.hasImages, let img = board.image {
            addImage(img)
            return true
        }
        if board.hasStrings, let s = board.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            tools.tool = .hand
            drawMode = false
            canvas.addText(s)
            return true
        }
        return false
    }

    func update(_ change: (inout PageItem) -> Void) { canvas.updateSelected(change) }
    func deleteSelected() { canvas.deleteSelected() }

    // MARK: Audio

    var recordings: [Recording] { notebook.recordings ?? [] }

    func recordingSaved(_ rec: Recording) {
        var list = recordings
        list.append(rec)
        notebook.recordings = list
        library.save(notebook)
    }

    func setTranscript(_ rec: Recording, _ text: String) {
        guard let i = recordings.firstIndex(where: { $0.id == rec.id }) else { return }
        notebook.recordings?[i].transcript = text
        library.save(notebook)
    }

    /// Puts text on the page in a new box.
    func insertText(_ text: String) {
        tools.tool = .hand
        drawMode = false
        canvas.addText(text)
    }

    func deleteRecording(_ rec: Recording) {
        audio.forget(rec)
        try? FileManager.default.removeItem(at: Store.audio(notebook.id, rec.id))
        notebook.recordings = recordings.filter { $0.id != rec.id }
        if notebook.recordings?.isEmpty == true { notebook.recordings = nil }
        library.save(notebook)
    }

    /// A tap on the writing while listening: plays what was recorded when that stroke was written.
    func playFrom(_ date: Date?) {
        guard let date else {
            notice = String(localized: "Tocca un tratto scritto a mano.")
            return
        }
        guard let rec = recordings.last(where: { $0.start.addingTimeInterval(-1) <= date && date <= $0.end.addingTimeInterval(1) }) else {
            notice = String(localized: "Mentre scrivevi questo non stavi registrando.")
            return
        }
        audio.play(rec, at: max(0, date.timeIntervalSince(rec.start) - 2))
    }
}
