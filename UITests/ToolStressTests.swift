import XCTest

/// Does what crashed the app on a tester's iPhone Duo: changing tool many times and using the
/// lasso on a page with ink. A crash ends the test, and the workflow keeps the crash report.
final class ToolStressTests: XCTestCase {
    private let tools = ["Penna", "Matita", "Evidenziatore", "Gomma", "Forme", "Lazo", "Sposta testi e foto", "Puntatore laser"]

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", screen, "-AppleLanguages", "(it)", "-AppleLocale", "it_IT"]
        app.launch()
        XCTAssertTrue(app.buttons["Lazo"].waitForExistence(timeout: 40), "the editor did not open")
        return app
    }

    private func point(_ app: XCUIApplication, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func drag(_ app: XCUIApplication, from a: (CGFloat, CGFloat), to b: (CGFloat, CGFloat), hold: TimeInterval = 0.05) {
        point(app, a.0, a.1).press(forDuration: hold, thenDragTo: point(app, b.0, b.1))
    }

    private func tapTool(_ app: XCUIApplication, _ name: String) {
        let b = app.buttons[name]
        if b.exists, b.isHittable { b.tap() }
    }

    private func alive(_ app: XCUIApplication, _ step: String) {
        XCTAssertEqual(app.state, .runningForeground, "the app is gone after: \(step)")
    }

    func testChangingToolsManyTimes() {
        let app = launch("editor")
        for round in 1...8 {
            for t in tools {
                tapTool(app, t)
                alive(app, "round \(round), tool \(t)")
            }
            for t in tools.reversed() {
                tapTool(app, t)
            }
            alive(app, "round \(round), back")
        }
    }

    func testLassoOnInk() {
        let app = launch("editor")
        for round in 1...5 {
            tapTool(app, "Penna")
            drag(app, from: (0.25, 0.55), to: (0.7, 0.6))
            alive(app, "round \(round): pen stroke")

            tapTool(app, "Lazo")
            // a lasso across the handwriting, then move what it caught
            drag(app, from: (0.15, 0.3), to: (0.85, 0.45))
            alive(app, "round \(round): lasso")
            drag(app, from: (0.5, 0.38), to: (0.5, 0.5), hold: 0.4)
            alive(app, "round \(round): moving the selection")
            point(app, 0.5, 0.45).tap()
            alive(app, "round \(round): tap on the selection")

            // change tool while something is selected
            for t in ["Forme", "Lazo", "Gomma", "Lazo", "Evidenziatore", "Sposta testi e foto", "Lazo"] {
                tapTool(app, t)
                alive(app, "round \(round): \(t) with a selection")
            }
            drag(app, from: (0.2, 0.5), to: (0.8, 0.7))
            tapTool(app, "Forme")
            drag(app, from: (0.3, 0.6), to: (0.6, 0.7))
            alive(app, "round \(round): shape")
            tapTool(app, "Lazo")
            drag(app, from: (0.25, 0.55), to: (0.7, 0.75))
            alive(app, "round \(round): lasso on the shape")
        }
    }

    func testLassoOnShapesPage() {
        let app = launch("shapes")
        for round in 1...4 {
            tapTool(app, "Lazo")
            drag(app, from: (0.1, 0.25), to: (0.9, 0.6))
            drag(app, from: (0.45, 0.4), to: (0.4, 0.55), hold: 0.4)
            alive(app, "round \(round): lasso and move")
            for t in tools {
                tapTool(app, t)
            }
            alive(app, "round \(round): all tools after the lasso")
        }
    }

    /// The Text button switches to moving boxes without going through the tool buttons: it
    /// crashed 0.3.2 on a tester's phone (the same happened adding a photo).
    func testTextButtonAfterEveryTool() {
        let app = launch("editor")
        for t in tools {
            tapTool(app, t)
            tapTool(app, "Testo")
            alive(app, "Testo after \(t)")
            point(app, 0.5, 0.9).tap()
        }
    }

    /// The laser, the audio bar and listening do not end the app.
    func testLaserAndAudioBar() {
        let app = launch("editor")
        tapTool(app, "Puntatore laser")
        drag(app, from: (0.2, 0.4), to: (0.8, 0.6))
        alive(app, "laser")
        // the audio button is at the end of the tool strip, often scrolled away: use the ⋯ menu
        app.buttons["Altro"].tap()
        let item = app.buttons["Registrazione audio"].firstMatch
        if item.waitForExistence(timeout: 5) { item.tap() }
        alive(app, "audio bar")
        XCTAssertTrue(app.buttons["Registra"].waitForExistence(timeout: 5), "the audio bar did not open")
        tapTool(app, "Penna")
        drag(app, from: (0.3, 0.5), to: (0.6, 0.55))
        alive(app, "pen after the laser")
    }
}
