//
//  StarlightUITests.swift
//  StarlightUITests
//
//  Created by Zayrick on 2026/7/11.
//

import XCTest
#if os(iOS)
import UIKit
#endif

final class StarlightUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

#if os(iOS)
    @MainActor
    func testPlatformSearchPlacement() throws {
        let app = XCUIApplication()
        app.launch()

        let devicesTab = app.buttons["设备"].firstMatch
        XCTAssertTrue(devicesTab.waitForExistence(timeout: 5))
        devicesTab.tap()

        let searchField = app.searchFields.firstMatch

        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertFalse(searchField.exists)

            let searchButton = app.buttons["Search"]
            XCTAssertTrue(searchButton.waitForExistence(timeout: 5))
            searchButton.tap()

            XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        } else {
            XCTAssertFalse(searchField.exists)

            let searchTab = app.tabBars.firstMatch.buttons.element(boundBy: 2)
            XCTAssertTrue(searchTab.waitForExistence(timeout: 5))
            searchTab.tap()

            XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        }

        searchField.tap()
        searchField.typeText("卧室")
        XCTAssertTrue(app.staticTexts["卧室 Mac mini"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["工作室 Mac"].exists)
    }
#endif

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
