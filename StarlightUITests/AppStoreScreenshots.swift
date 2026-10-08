//
//  AppStoreScreenshots.swift
//  StarlightUITests
//
//  Drives the app through the screens shown on the App Store and saves
//  full-resolution screenshots to SHOT_DIR on the host Mac.
//

#if os(iOS)
import XCTest

final class AppStoreScreenshots: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var language: String { env["SHOT_LANG"] ?? "zh-Hans" }
    private var directory: URL { URL(fileURLWithPath: env["SHOT_DIR"] ?? "/tmp/shots") }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        let locale = language == "en" ? "en_US" : language.replacingOccurrences(of: "-", with: "_")
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launch()
        return app
    }

    private func save(_ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func firstCard(in app: XCUIApplication) -> XCUIElement {
        app.scrollViews.firstMatch.buttons.firstMatch
    }

    /// Starts pairing and waits for the PIN to be entered on the host.
    @MainActor
    func testPair() throws {
        let app = launch()
        let card = firstCard(in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        card.tap()

        let pin = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH 'Pairing code' OR label BEGINSWITH '配对码' OR label BEGINSWITH '配對碼'"
        )).firstMatch
        let found = pin.waitForExistence(timeout: 15)
        try save("pairing")
        guard found else {
            print(app.debugDescription)
            return
        }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: pin)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 900), .completed)
    }

    @MainActor
    func testScreens() throws {
        let app = launch()
        let card = firstCard(in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 20))
        // Let box art load into the card's photo wall
        sleep(6)
        try save("01-devices")

        card.tap()
        quitRunningApp(in: app)
        sleep(6)
        try save("02-apps")

        tab("Settings", "设置", in: app).tap()
        sleep(2)
        try save("03-settings")

        tab("Devices", "设备", in: app).tap()
        let desktop = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Desktop'")).firstMatch
        XCTAssertTrue(desktop.waitForExistence(timeout: 10))
        // iPad doesn't force the stream into landscape, so turn the device
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        desktop.tap()
        // Connecting and the first frames
        sleep(15)
        try save("04-stream")

        let handle = app.buttons.matching(NSPredicate(
            format: "label == 'Stream Options' OR label == '串流选项'"
        )).firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 400, dy: 0)))
        sleep(2)
        try save("05-drawer")

        // Leaves the host idle for the next run
        let quit = app.buttons.matching(NSPredicate(
            format: "label == 'Quit App' OR label == '退出应用'"
        )).firstMatch
        XCTAssertTrue(quit.waitForExistence(timeout: 5))
        quit.tap()
        sleep(5)
        XCUIDevice.shared.orientation = .portrait
    }

    /// Tab bar items sit at the bottom on iPhone and at the top on iPad.
    private func tab(_ english: String, _ chinese: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", english, chinese)).firstMatch
    }

    /// Quits an app left running on the host so the grid shows every app.
    private func quitRunningApp(in app: XCUIApplication) {
        let resume = app.buttons.matching(NSPredicate(format: "label == 'Resume' OR label == '继续'")).firstMatch
        guard resume.waitForExistence(timeout: 5) else { return }
        let quit = NSPredicate(format: "label == 'Quit' OR label == '退出'")
        app.buttons.matching(quit).firstMatch.tap()
        let confirm = app.alerts.buttons.matching(quit).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(resume.waitForNonExistence(timeout: 20))
    }
}
#endif
