//
//  AgencyUITests.swift
//  AgencyUITests
//
//  Created by Brianna Zamora on 11/21/25.
//

import XCTest

final class AgencyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAddPhaseWithAgentCreatesPlanCard() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        for name in ["backlog", "in-progress", "done"] {
            let dir = project.appendingPathComponent("phase-0-seed/\(name)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: dir.appendingPathComponent(".gitkeep").path, contents: Data())
        }

        let app = XCUIApplication()
        app.launchEnvironment["UITEST_PROJECT_PATH"] = root.path
        app.launch()

        let addButton = app.buttons["Add phase with agent"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let labelField = app.textFields["Phase label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 2))
        labelField.tap()
        labelField.typeText("UI Flow")

        let startButton = app.buttons["Start plan flow"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 1))
        startButton.tap()

        let phaseRow = app.staticTexts["Phase 1: ui-flow"]
        XCTAssertTrue(phaseRow.waitForExistence(timeout: 10), "Phase row did not appear")

        let planCard = app.staticTexts.containing(NSPredicate(format: "label CONTAINS '1.0'")).firstMatch
        XCTAssertTrue(planCard.waitForExistence(timeout: 5))
    }
}
