//
//  AppStoreScreenshots.swift
//  StarlightUITests
//
//  Drives the app through the screens shown on the App Store, in every
//  language, using the sample data of the app's screenshot mode. Saves
//  full-resolution screenshots to SHOT_DIR/<iPhone|iPad>/<language> on the
//  host Mac. Run through scripts/screenshots.sh.
//

#if os(iOS)
import XCTest

final class AppStoreScreenshots: XCTestCase {
    /// Languages and the matching regions.
    private static let locales = [
        "en": "en_US",
        "zh-Hans": "zh_CN",
        "zh-Hant": "zh_TW",
        "zh-HK": "zh_HK",
    ]

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var directory: URL { URL(fileURLWithPath: env["SHOT_DIR"] ?? "/tmp/starlight-shots") }
    private var deviceName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testScreenshots() throws {
        // SHOT_LANG limits the run to one language
        let languages = env["SHOT_LANG"].flatMap { $0.isEmpty ? nil : [$0] }
            ?? ["en", "zh-Hans", "zh-Hant", "zh-HK"]
        for language in languages {
            try capture(language: language)
        }
    }

    @MainActor
    private func capture(language: String) throws {
        let folder = directory.appending(path: deviceName).appending(path: language)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func save(_ name: String) throws {
            try Self.upright(XCUIScreen.main.screenshot().image).pngData()?
                .write(to: folder.appending(path: "\(name).png"))
        }

        XCUIDevice.shared.orientation = .portrait
        var app = launch(language: language)

        let gaming = app.buttons["screenshot.gaming"]
        XCTAssertTrue(gaming.waitForExistence(timeout: 10))
        // Box art renders into the cards' photo walls
        sleep(2)
        try save("01-devices")

        app.buttons["screenshot.workstation"].tap()
        let pin = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '4 8 3 1'")).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        sleep(1)
        try save("02-pairing")

        // Starts over rather than cancelling through a localized button
        app.terminate()
        app = launch(language: language)
        let relaunchedGaming = app.buttons["screenshot.gaming"]
        XCTAssertTrue(relaunchedGaming.waitForExistence(timeout: 10))
        relaunchedGaming.tap()
        let resume = app.buttons["resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        sleep(2)
        try save("03-apps")

        // iPad doesn't force the stream into landscape, and the iPhone's
        // screenshot follows the device rather than the interface
        XCUIDevice.shared.orientation = .landscapeLeft
        resume.tap()
        let handle = app.descendants(matching: .any)["streamOptionsHandle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        sleep(2)
        try save("04-stream")

        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 400, dy: 0)))
        sleep(2)
        try save("05-drawer")

        app.terminate()
    }

    /// Screenshots keep the screen's portrait orientation, so landscape ones
    /// are turned to read upright.
    private static func upright(_ image: UIImage) -> UIImage {
        let orientation = XCUIDevice.shared.orientation
        guard orientation.isLandscape, let pixels = image.cgImage else { return image }
        // Tells drawing which way to turn the raw portrait pixels
        let turned = UIImage(cgImage: pixels, scale: 1, orientation: orientation == .landscapeLeft ? .left : .right)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: turned.size, format: format).image { _ in
            turned.draw(at: .zero)
        }
    }

    private func launch(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ScreenshotMode",
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", Self.locales[language] ?? "en_US",
            "-stream.showsStatistics", "YES",
        ]
        app.launch()
        return app
    }
}
#endif
