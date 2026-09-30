//
//  StarlightUITests.swift
//  StarlightUITests
//
//  Created by Zayrick on 2026/7/11.
//

#if os(iOS)
import XCTest

final class StarlightUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchActivation() throws {
        let app = XCUIApplication()
        app.launch()

        let searchButtons = app.buttons.matching(
            NSPredicate(format: "label == %@", "Search")
        )
        XCTAssertTrue(searchButtons.firstMatch.waitForExistence(timeout: 5))
        let searchButton = searchButtons.element(
            boundBy: searchButtons.count - 1
        )
        searchButton.tap()

        let searchFields = app.searchFields
        XCTAssertTrue(searchFields.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testDeviceActionsUseContextMenu() throws {
        let app = XCUIApplication()
        app.launch()

        let card = app.descendants(matching: .any)["device-card-studio"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["更多"].exists)

        card.press(forDuration: 1)
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 5))
    }
}
#endif
