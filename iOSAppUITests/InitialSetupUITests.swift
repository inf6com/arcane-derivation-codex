import XCTest

final class InitialSetupUITests: XCTestCase {
    func testStorageReselectionAndSetupCompletionOnConnectedIPad() throws {
        let app = XCUIApplication()
        app.launch()

        let setupHeader = app.staticTexts["初期設定"]
        guard setupHeader.waitForExistence(timeout: 3) else {
            XCTAssertTrue(app.buttons["数学的基礎"].waitForExistence(timeout: 10), "A previously completed setup did not restore the saved syllabus nodes.")
            return
        }

        let next = app.buttons["次へ"]
        XCTAssertTrue(next.waitForExistence(timeout: 20))
        next.tap()
        XCTAssertTrue(app.buttons["保存先を選択"].waitForExistence(timeout: 5))
        app.buttons["保存先を選択"].tap()
        let folderPickerOpen = app.buttons["開く"]
        XCTAssertTrue(folderPickerOpen.waitForExistence(timeout: 10), "The system folder picker did not expose its Open action.")
        folderPickerOpen.tap()

        let selectedRoot = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "名称未設定フォルダ 4")).firstMatch
        XCTAssertTrue(selectedRoot.waitForExistence(timeout: 10), "The selected storage root is not shown in setup.")
        app.buttons["次へ"].tap()
        XCTAssertTrue(app.staticTexts["プリセットドメイン：E資格"].waitForExistence(timeout: 10), "Setup did not advance after selecting the existing storage root.")

        app.terminate()
        app.launch()
        app.buttons["次へ"].tap()
        XCTAssertTrue(app.staticTexts["保存先"].waitForExistence(timeout: 10))
        app.buttons["次へ"].tap()
        XCTAssertTrue(app.staticTexts["プリセットドメイン：E資格"].waitForExistence(timeout: 10), "The selected root bookmark did not survive relaunch and validation.")

        app.buttons["次へ"].tap()
        XCTAssertTrue(app.staticTexts["AIプロバイダを選択"].waitForExistence(timeout: 10), "Setup did not advance from the syllabus page.")
        app.buttons["次へ"].tap()
        XCTAssertTrue(app.staticTexts["論文探索"].waitForExistence(timeout: 10), "Setup did not advance from the AI page.")
        app.buttons["利用を開始"].tap()
        let setupDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: setupHeader)
        XCTAssertEqual(XCTWaiter.wait(for: [setupDismissed], timeout: 15), .completed, "The app remained in setup after completion.")
        XCTAssertTrue(app.buttons["数学的基礎"].waitForExistence(timeout: 10), "The main E-Qualification syllabus nodes did not appear after setup.")
    }

    func testUnavailableStoredRootIsRejectedOnConnectedIPad() throws {
        let app = XCUIApplication()
        app.launch()

        let next = app.buttons["次へ"]
        XCTAssertTrue(next.waitForExistence(timeout: 20), "Initial setup did not open on the connected iPad.")
        next.tap() // Language → storage

        XCTAssertTrue(app.staticTexts["保存先"].waitForExistence(timeout: 5), "The wizard did not advance to storage.")
        XCTAssertFalse(app.staticTexts["未設定"].exists, "The persisted root path is empty; do not continue with an unselected root.")
        next.tap() // Storage validates the persisted bookmark and write access before advancing.

        XCTAssertTrue(
            app.staticTexts["保存済みの保存先にアクセスできません。フォルダを選び直してください。"]
                .waitForExistence(timeout: 5),
            "An inaccessible persisted root must be rejected with a re-selection instruction."
        )
    }
}
