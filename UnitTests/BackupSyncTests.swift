import PencilKit
import UIKit
import XCTest
@testable import Appunti

/// The zip files, the copy of the whole library, the sync with a folder of iCloud Drive and the
/// trash: the parts that, if they broke, would lose notes.
@MainActor
final class BackupSyncTests: XCTestCase {
    private var temp: URL!
    private var savedTombs: Data?
    private var savedFolders: Data?
    private var made: [UUID] = []

    override func setUp() {
        super.setUp()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("prove-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        // the sync and the trash use the app's real files: put them back as they were afterwards
        savedTombs = try? Data(contentsOf: Tombstones.file)
        savedFolders = try? Data(contentsOf: Store.foldersFile)
    }

    override func tearDown() {
        let fm = FileManager.default
        try? fm.removeItem(at: temp)
        for id in made {
            try? fm.removeItem(at: Store.dir(id))
            try? fm.removeItem(at: Store.trash.appendingPathComponent(id.uuidString))
            PageHistory.removeAll(id)
        }
        if let savedTombs { try? savedTombs.write(to: Tombstones.file) } else { try? fm.removeItem(at: Tombstones.file) }
        if let savedFolders { try? savedFolders.write(to: Store.foldersFile) } else { try? fm.removeItem(at: Store.foldersFile) }
        super.tearDown()
    }

    private func stroke(_ x: CGFloat) -> PKStroke {
        let pts = [CGPoint(x: x, y: 10), CGPoint(x: x + 40, y: 30)].enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: 1)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    private func setDate(_ url: URL, _ d: Date) {
        try? FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: url.path)
    }

    // MARK: Zip

    func testZipRoundTrip() throws {
        let url = temp.appendingPathComponent("a.zip")
        let text = Data(String(repeating: "quaderno appunti ", count: 400).utf8)
        let picture = Data((0..<5000).map { _ in UInt8.random(in: 0...255) })
        let w = try ZipWriter(url: url)
        try w.add("Quaderni/note.json", data: text)
        try w.add("Quaderni/images/foto.jpg", data: picture)
        try w.add("vuoto.json", data: Data())
        try w.add("àccénti/è ok.txt", data: Data("ciao".utf8))
        try w.finish()

        let r = try ZipReader(url: url)
        XCTAssertEqual(r.entries.map(\.name), ["Quaderni/note.json", "Quaderni/images/foto.jpg", "vuoto.json", "àccénti/è ok.txt"])
        let json = try XCTUnwrap(r.entries.first { $0.name == "Quaderni/note.json" })
        XCTAssertEqual(json.method, 8, "text is deflated")
        XCTAssertLessThan(json.packed, json.size)
        XCTAssertEqual(try r.data(json), text)
        let jpg = try XCTUnwrap(r.entries.first { $0.name.hasSuffix("foto.jpg") })
        XCTAssertEqual(jpg.method, 0, "pictures are stored")
        XCTAssertEqual(try r.data(jpg), picture)
        XCTAssertEqual(try r.data(r.entries[2]), Data())
        XCTAssertEqual(try r.data(r.entries[3]), Data("ciao".utf8))
    }

    func testZipReaderReadsOtherArchives() throws {
        // made by Python's zipfile, deflated
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "goodnotes"))
        let r = try ZipReader(url: url)
        let old = try Zip(data: Data(contentsOf: url))
        var same = 0
        for e in r.entries where !e.name.hasSuffix("/") {
            if let bytes = old.file(e.name) {
                XCTAssertEqual(Array(try r.data(e)), bytes, e.name)
                same += 1
            }
        }
        XCTAssertGreaterThan(same, 2)
    }

    func testZipChecksDamage() throws {
        let url = temp.appendingPathComponent("rotto.zip")
        let w = try ZipWriter(url: url)
        try w.add("a.jpg", data: Data(repeating: 7, count: 300))
        try w.finish()
        var bytes = try Data(contentsOf: url)
        bytes[40] ^= 0xFF  // inside the stored file
        try bytes.write(to: url)
        let r = try ZipReader(url: url)
        XCTAssertThrowsError(try r.data(r.entries[0]))
        try Data("non è uno zip".utf8).write(to: url)
        XCTAssertThrowsError(try ZipReader(url: url))
    }

    func testZip64ForManyFiles() throws {
        let url = temp.appendingPathComponent("tanti.zip")
        let w = try ZipWriter(url: url)
        let n = 66_000
        for i in 0..<n { try w.add("f/\(i).bin", data: Data([UInt8(i & 0xFF)])) }
        try w.finish()
        let r = try ZipReader(url: url)
        XCTAssertEqual(r.entries.count, n)
        XCTAssertEqual(try r.data(r.entries[n - 1]), Data([UInt8((n - 1) & 0xFF)]))
    }

    // MARK: Copy of the library

    /// A library folder with one notebook, a folder, a sticker, a paper and a study day.
    private func makeLibrary(_ docs: URL, notebook id: UUID, modified: Date = Date()) throws -> Notebook {
        let fm = FileManager.default
        let page = PageInfo(template: .lined, size: CGSize(width: 595, height: 842))
        var nb = Notebook(title: "Fisica", paper: .white, pages: [page])
        nb.id = id
        nb.modified = modified
        let folder = Folder(name: "Scuola")
        nb.folderID = folder.id
        let dir = docs.appendingPathComponent("Quaderni/\(id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Store.encoder.encode(nb).write(to: dir.appendingPathComponent("notebook.json"))
        try PKDrawing(strokes: [stroke(10), stroke(80)]).dataRepresentation()
            .write(to: dir.appendingPathComponent("pages/\(page.id.uuidString).drawing"))
        try Data(repeating: 1, count: 2000).write(to: dir.appendingPathComponent("images/foto.jpg"))
        try Data("ignorami".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        try Store.encoder.encode([folder]).write(to: docs.appendingPathComponent("cartelle.json"))

        let stickers = docs.appendingPathComponent("Adesivi", isDirectory: true)
        try fm.createDirectory(at: stickers, withIntermediateDirectories: true)
        let sticker = StickerStore.Sticker(file: "s1.png")
        try Data([9, 9, 9]).write(to: stickers.appendingPathComponent("s1.png"))
        try Store.encoder.encode([sticker]).write(to: stickers.appendingPathComponent("adesivi.json"))

        let papers = docs.appendingPathComponent("Carte", isDirectory: true)
        try fm.createDirectory(at: papers, withIntermediateDirectories: true)
        try Data([5, 5]).write(to: papers.appendingPathComponent("c1.jpg"))
        try Store.encoder.encode([PaperStore.Item(file: "c1.jpg")]).write(to: papers.appendingPathComponent("carte.json"))

        try JSONEncoder().encode(["2026-11-19": StudyLog.Day(reviews: 4, right: 3, focus: 25)])
            .write(to: docs.appendingPathComponent("studio.json"))
        return nb
    }

    func testCopyAndRestoreTheLibrary() throws {
        let fm = FileManager.default
        let from = temp.appendingPathComponent("da", isDirectory: true)
        let to = temp.appendingPathComponent("a", isDirectory: true)
        let out = temp.appendingPathComponent("uscita", isDirectory: true)
        for d in [from, to, out] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let id = UUID()
        let nb = try makeLibrary(from, notebook: id)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let zip = try LibraryBackup.export(from: from, to: out, now: now)
        XCTAssertTrue(zip.lastPathComponent.hasPrefix("Quaderno Appunti "))
        let names = try ZipReader(url: zip).entries.map(\.name)
        XCTAssertTrue(names.contains("copia.json"))
        XCTAssertTrue(names.contains("Quaderni/\(id.uuidString)/notebook.json"))
        XCTAssertFalse(names.contains { $0.hasSuffix(".DS_Store") }, "hidden files stay out")
        let manifest = try XCTUnwrap(LibraryBackup.manifest(zip))
        XCTAssertEqual(manifest.notebooks, 1)
        XCTAssertEqual(manifest.created, now)

        let trash = to.appendingPathComponent("Cestino", isDirectory: true)
        let s = try LibraryBackup.restore(zip, into: to, trash: trash)
        XCTAssertEqual(s.restored, [id])
        XCTAssertEqual(s.skipped, 0)
        XCTAssertEqual(s.folders, 1)
        XCTAssertEqual(s.stickers, 1)
        XCTAssertEqual(s.papers, 1)
        let dir = to.appendingPathComponent("Quaderni/\(id.uuidString)")
        let back = try Store.decoder.decode(Notebook.self, from: Data(contentsOf: dir.appendingPathComponent("notebook.json")))
        XCTAssertEqual(back.title, "Fisica")
        XCTAssertEqual(back.modified.timeIntervalSince1970, nb.modified.timeIntervalSince1970, accuracy: 1, "not touched without a deletion")
        let ink = try PKDrawing(data: Data(contentsOf: dir.appendingPathComponent("pages/\(nb.pages[0].id.uuidString).drawing")))
        XCTAssertEqual(ink.strokes.count, 2)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("images/foto.jpg")).count, 2000)
        XCTAssertEqual(try Data(contentsOf: to.appendingPathComponent("Adesivi/s1.png")), Data([9, 9, 9]))
        XCTAssertTrue(fm.fileExists(atPath: to.appendingPathComponent("Carte/c1.jpg").path))
        let days = try JSONDecoder().decode([String: StudyLog.Day].self, from: Data(contentsOf: to.appendingPathComponent("studio.json")))
        XCTAssertEqual(days["2026-11-19"], StudyLog.Day(reviews: 4, right: 3, focus: 25))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: to.appendingPathComponent("Quaderni").path).contains { $0.hasPrefix(".") },
                       "nothing half written is left")

        // a second time nothing changes and nothing is counted twice
        let again = try LibraryBackup.restore(zip, into: to, trash: trash)
        XCTAssertEqual(again, LibraryBackup.Summary(restored: [], skipped: 1, folders: 0, stickers: 0, papers: 0))
        let days2 = try JSONDecoder().decode([String: StudyLog.Day].self, from: Data(contentsOf: to.appendingPathComponent("studio.json")))
        XCTAssertEqual(days2, days)
        let list = try Store.decoder.decode([StickerStore.Sticker].self, from: Data(contentsOf: to.appendingPathComponent("Adesivi/adesivi.json")))
        XCTAssertEqual(list.count, 1)
    }

    func testRestoreLeavesNotebooksInTheTrash() throws {
        let fm = FileManager.default
        let from = temp.appendingPathComponent("da2", isDirectory: true)
        let to = temp.appendingPathComponent("a2", isDirectory: true)
        let id = UUID()
        _ = try makeLibrary(from, notebook: id)
        let zip = try LibraryBackup.export(from: from, to: temp)
        let trash = to.appendingPathComponent("Cestino", isDirectory: true)
        try fm.createDirectory(at: trash.appendingPathComponent(id.uuidString), withIntermediateDirectories: true)
        let s = try LibraryBackup.restore(zip, into: to, trash: trash)
        XCTAssertEqual(s.restored, [])
        XCTAssertEqual(s.skipped, 1)
    }

    func testRestoredNotebookOutlivesItsDeletion() throws {
        let from = temp.appendingPathComponent("da3", isDirectory: true)
        let to = temp.appendingPathComponent("a3", isDirectory: true)
        let id = UUID()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try makeLibrary(from, notebook: id, modified: old)
        let zip = try LibraryBackup.export(from: from, to: temp)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try LibraryBackup.restore(zip, into: to, trash: to.appendingPathComponent("Cestino"),
                                      tombstones: [id.uuidString: old.addingTimeInterval(3600)], now: now)
        let back = try Store.decoder.decode(Notebook.self, from: Data(contentsOf: to.appendingPathComponent("Quaderni/\(id.uuidString)/notebook.json")))
        XCTAssertEqual(back.modified, now, "newer than its deletion, so syncing keeps it")
    }

    func testRestoreRefusesOtherFilesAndPathsOutside() throws {
        let other = temp.appendingPathComponent("altro.zip")
        let w = try ZipWriter(url: other)
        try w.add("foto/vacanze.jpg", data: Data([1, 2, 3]))
        try w.finish()
        XCTAssertThrowsError(try LibraryBackup.restore(other, into: temp.appendingPathComponent("x"), trash: temp.appendingPathComponent("y"))) { e in
            XCTAssertEqual((e as? LibraryBackup.Failure).map { "\($0)" }, "notABackup")
        }
        XCTAssertNil(LibraryBackup.manifest(other))

        let id = UUID()
        var nb = Notebook(title: "Trappola", paper: .white, pages: [PageInfo(template: .blank, size: CGSize(width: 100, height: 100))])
        nb.id = id
        let evil = temp.appendingPathComponent("trappola.zip")
        let w2 = try ZipWriter(url: evil)
        try w2.add("Quaderni/\(id.uuidString)/notebook.json", data: try Store.encoder.encode(nb))
        try w2.add("Quaderni/\(id.uuidString)/../../fuori.txt", data: Data("no".utf8))
        try w2.finish()
        let to = temp.appendingPathComponent("dentro/docs", isDirectory: true)
        let s = try LibraryBackup.restore(evil, into: to, trash: to.appendingPathComponent("Cestino"))
        XCTAssertEqual(s.restored, [id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("dentro/fuori.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: to.appendingPathComponent("fuori.txt").path))
    }

    func testOldCopiesDoNotPileUp() throws {
        let fm = FileManager.default
        let from = temp.appendingPathComponent("da4", isDirectory: true)
        let out = temp.appendingPathComponent("uscita4", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        _ = try makeLibrary(from, notebook: UUID())
        let other = out.appendingPathComponent("altro.zip")
        try Data([1]).write(to: other)

        let first = try LibraryBackup.export(from: from, to: out, now: Date(timeIntervalSince1970: 1_800_000_000))
        let second = try LibraryBackup.export(from: from, to: out, now: Date(timeIntervalSince1970: 1_800_000_600))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(fm.fileExists(atPath: first.path), "the copy made before is gone")
        XCTAssertTrue(fm.fileExists(atPath: second.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path), "other files stay")

        // what the app does when it starts
        XCTAssertEqual(LibraryBackup.removeCopies(in: out), 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), ["altro.zip"])
    }

    func testCopyAndRestoreTellHowFarTheyGot() throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var list: [Double] = []
            func add(_ v: Double) { lock.lock(); list.append(v); lock.unlock() }
            var values: [Double] { lock.lock(); defer { lock.unlock() }; return list }
        }
        let from = temp.appendingPathComponent("da5", isDirectory: true)
        let to = temp.appendingPathComponent("a5", isDirectory: true)
        let id = UUID()
        _ = try makeLibrary(from, notebook: id)
        // a few more files, so there is something to count
        let pics = from.appendingPathComponent("Quaderni/\(id.uuidString)/images", isDirectory: true)
        for i in 0..<30 { try Data(repeating: UInt8(i), count: 5000).write(to: pics.appendingPathComponent("f\(i).jpg")) }

        let made = Seen()
        let zip = try LibraryBackup.export(from: from, to: temp, progress: { made.add($0) })
        let seen = made.values
        XCTAssertFalse(seen.isEmpty)
        XCTAssertEqual(seen, seen.sorted(), "only forward")
        XCTAssertEqual(seen.last, 1)
        XCTAssertLessThanOrEqual(seen.count, 101, "not one call per file")

        let back = Seen()
        let s = try LibraryBackup.restore(zip, into: to, trash: to.appendingPathComponent("Cestino"), progress: { back.add($0) })
        XCTAssertEqual(s.restored, [id])
        XCTAssertEqual(back.values, back.values.sorted())
        XCTAssertGreaterThan(back.values.count, 2)
        XCTAssertEqual(back.values.last, 1)

        // nothing to put back is done at once
        let none = Seen()
        _ = try LibraryBackup.restore(zip, into: to, trash: to.appendingPathComponent("Cestino"), progress: { none.add($0) })
        XCTAssertEqual(none.values, [1])
    }

    func testNoCopyOfAnEmptyLibrary() throws {
        XCTAssertThrowsError(try LibraryBackup.export(from: temp.appendingPathComponent("vuota"), to: temp))
    }

    // MARK: Sync with a folder of iCloud Drive

    /// A notebook with one page and some ink, in the app's own library.
    private func localNotebook(modified: Date = Date()) -> Notebook {
        var nb = Notebook(title: "Sync", paper: .white, pages: [PageInfo(template: .lined, size: CGSize(width: 595, height: 842))])
        nb.modified = modified
        made.append(nb.id)
        Store.ensureDirs(nb.id)
        try? Store.encoder.encode(nb).write(to: Store.meta(nb.id))
        Store.saveDrawing(PKDrawing(strokes: [stroke(10)]), nb.id, nb.pages[0].id)
        return nb
    }

    private func cloudDir(_ id: UUID) -> URL { temp.appendingPathComponent("Quaderni/\(id.uuidString)", isDirectory: true) }

    private func sync(_ local: [Notebook], open: UUID? = nil) throws -> CloudBackup.SyncReport {
        try CloudBackup.sync(root: temp, local: local, open: open).get()
    }

    func testSyncSendsNewNotebooks() throws {
        let nb = localNotebook()
        let r = try sync([nb])
        XCTAssertGreaterThanOrEqual(r.sent, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDir(nb.id).appendingPathComponent("notebook.json").path))
        let ink = try PKDrawing(data: Data(contentsOf: cloudDir(nb.id).appendingPathComponent("pages/\(nb.pages[0].id.uuidString).drawing")))
        XCTAssertEqual(ink.strokes.count, 1)
        // a second sync has nothing to do
        let r2 = try sync([nb])
        XCTAssertEqual(r2.sent, 0)
        XCTAssertEqual(r2.received, 0)
    }

    func testSyncBringsNotebooksFromOtherDevices() throws {
        var nb = Notebook(title: "Dall'iPad", paper: .white, pages: [PageInfo(template: .grid, size: CGSize(width: 595, height: 842))])
        made.append(nb.id)
        nb.modified = Date()
        let there = cloudDir(nb.id)
        try FileManager.default.createDirectory(at: there.appendingPathComponent("pages"), withIntermediateDirectories: true)
        try Store.encoder.encode(nb).write(to: there.appendingPathComponent("notebook.json"))
        try PKDrawing(strokes: [stroke(1), stroke(2), stroke(3)]).dataRepresentation()
            .write(to: there.appendingPathComponent("pages/\(nb.pages[0].id.uuidString).drawing"))

        let r = try sync([])
        XCTAssertTrue(r.changed.contains(nb.id))
        XCTAssertGreaterThanOrEqual(r.received, 2)
        XCTAssertEqual(Store.loadDrawing(nb.id, nb.pages[0].id).strokes.count, 3)
    }

    func testNewerPageWinsButNotInTheOpenNotebook() throws {
        let t0 = Date().addingTimeInterval(-600)
        let nb = localNotebook(modified: t0)
        _ = try sync([nb])
        let here = Store.drawing(nb.id, nb.pages[0].id)
        let there = cloudDir(nb.id).appendingPathComponent("pages/\(nb.pages[0].id.uuidString).drawing")
        // another device wrote more on the page a minute later
        try PKDrawing(strokes: [stroke(10), stroke(60)]).dataRepresentation().write(to: there)
        setDate(here, t0)
        setDate(there, t0.addingTimeInterval(60))

        // while the notebook is open here it is only sent, never replaced
        _ = try sync([nb], open: nb.id)
        XCTAssertEqual(Store.loadDrawing(nb.id, nb.pages[0].id).strokes.count, 1)

        let r = try sync([nb])
        XCTAssertTrue(r.changed.contains(nb.id))
        XCTAssertEqual(Store.loadDrawing(nb.id, nb.pages[0].id).strokes.count, 2)

        // and the other way round: written here later, it goes there
        Store.saveDrawing(PKDrawing(strokes: [stroke(1), stroke(2), stroke(3)]), nb.id, nb.pages[0].id)
        setDate(here, t0.addingTimeInterval(300))
        _ = try sync([nb])
        XCTAssertEqual(try PKDrawing(data: Data(contentsOf: there)).strokes.count, 3)
    }

    func testDeletedOnAnotherDevice() throws {
        let t0 = Date().addingTimeInterval(-600)
        let nb = localNotebook(modified: t0)
        _ = try sync([nb])
        // the other device deleted it after its last change
        try Store.encoder.encode([nb.id.uuidString: t0.addingTimeInterval(60)]).write(to: temp.appendingPathComponent("eliminati.json"))
        let r = try sync([nb])
        XCTAssertEqual(r.removed, [nb.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudDir(nb.id).path))
        XCTAssertNotNil(Tombstones.load()[nb.id.uuidString], "the deletion is known here too")
    }

    func testChangedAfterTheDeletionIsKept() throws {
        let t0 = Date().addingTimeInterval(-600)
        let nb = localNotebook(modified: t0)
        try Store.encoder.encode([nb.id.uuidString: t0.addingTimeInterval(-60)]).write(to: temp.appendingPathComponent("eliminati.json"))
        let r = try sync([nb])
        XCTAssertEqual(r.removed, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloudDir(nb.id).appendingPathComponent("notebook.json").path))
    }

    func testFoldersAreMergedBothWays() throws {
        let mine = Folder(name: "Qui"), theirs = Folder(name: "Là")
        let before = (try? Data(contentsOf: Store.foldersFile)).flatMap { try? Store.decoder.decode([Folder].self, from: $0) } ?? []
        try Store.encoder.encode(before + [mine]).write(to: Store.foldersFile)
        try Store.encoder.encode([theirs]).write(to: temp.appendingPathComponent("cartelle.json"))
        _ = try sync([])
        let here = try Store.decoder.decode([Folder].self, from: Data(contentsOf: Store.foldersFile))
        let there = try Store.decoder.decode([Folder].self, from: Data(contentsOf: temp.appendingPathComponent("cartelle.json")))
        for list in [here, there] {
            XCTAssertTrue(list.contains(mine))
            XCTAssertTrue(list.contains(theirs))
        }
    }

    func testPagesNoLongerInTheNotebookAreCleanedUp() throws {
        var nb = localNotebook()
        let gone = PageInfo(template: .blank, size: CGSize(width: 100, height: 100))
        Store.saveDrawing(PKDrawing(strokes: [stroke(5)]), nb.id, gone.id)
        nb.pages.append(gone)
        try Store.encoder.encode(nb).write(to: Store.meta(nb.id))
        _ = try sync([nb])
        let there = cloudDir(nb.id).appendingPathComponent("pages/\(gone.id.uuidString).drawing")
        XCTAssertTrue(FileManager.default.fileExists(atPath: there.path))
        // the page is deleted here
        nb.pages.removeLast()
        nb.modified = Date().addingTimeInterval(5)
        try Store.encoder.encode(nb).write(to: Store.meta(nb.id))
        _ = try sync([nb])
        XCTAssertFalse(FileManager.default.fileExists(atPath: there.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: Store.drawing(nb.id, gone.id).path))
    }

    // MARK: Trash

    func testTrashAndRestore() throws {
        let library = Library()
        let nb = library.create(title: "Da buttare", cover: 0, style: .plain, template: .lined, paper: .white, format: .a4Portrait, folder: nil)
        made.append(nb.id)
        library.delete(nb.id)
        XCTAssertNil(library.notebook(nb.id))
        XCTAssertEqual(library.trashed.first?.id, nb.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Store.dir(nb.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Store.trash.appendingPathComponent(nb.id.uuidString).path))
        let when = try XCTUnwrap(Tombstones.load()[nb.id.uuidString])
        XCTAssertEqual(library.daysLeft(library.trashed[0]), Store.trashDays)

        library.restore(nb.id)
        let back = try XCTUnwrap(library.notebook(nb.id))
        XCTAssertNil(back.deletedAt)
        XCTAssertGreaterThanOrEqual(back.modified, when, "newer than its deletion, so syncing does not delete it again")
        XCTAssertNil(Tombstones.load()[nb.id.uuidString])
        XCTAssertFalse(library.trashed.contains { $0.id == nb.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: Store.meta(nb.id).path))

        library.delete(nb.id)
        library.deleteForever(nb.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Store.trash.appendingPathComponent(nb.id.uuidString).path))
        XCTAssertFalse(library.trashed.contains { $0.id == nb.id })
    }

    func testTrashEmptiesItselfAfterThirtyDays() throws {
        func trashed(daysAgo: Double) throws -> UUID {
            var nb = Notebook(title: "Vecchio", paper: .white, pages: [PageInfo(template: .blank, size: CGSize(width: 100, height: 100))])
            nb.deletedAt = Date().addingTimeInterval(-daysAgo * 86_400)
            made.append(nb.id)
            let dir = Store.trash.appendingPathComponent(nb.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Store.encoder.encode(nb).write(to: dir.appendingPathComponent("notebook.json"))
            return nb.id
        }
        let old = try trashed(daysAgo: 31)
        let recent = try trashed(daysAgo: 29)
        let library = Library()
        XCTAssertFalse(FileManager.default.fileExists(atPath: Store.trash.appendingPathComponent(old.uuidString).path))
        XCTAssertFalse(library.trashed.contains { $0.id == old })
        let kept = try XCTUnwrap(library.trashed.first { $0.id == recent })
        XCTAssertEqual(library.daysLeft(kept), 1)
    }
}
