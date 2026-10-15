import XCTest
import AppKit

@MainActor final class MacLedgerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testAIImportsLocalImageGeneratesDraftAndClearsItOnRemoval() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-bill-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString, "--ai-ui-fixture"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["AI 辅助"].firstMatch.click()
        let pick = app.buttons["ai.bill.pick"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        XCTAssertEqual(pick.label, "选择本地账单图片")
        pick.click()
        let cancel = app.buttons.matching(NSPredicate(format: "title == %@ OR title == %@", "取消", "Cancel")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertFalse(app.buttons["ai.generate.bill"].exists)

        pick.click()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let path = app.textFields.matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "PathTextField", "GoToWindowControllerGoToField")).firstMatch
        XCTAssertTrue(path.waitForExistence(timeout: 5))
        path.click(); path.typeKey("a", modifierFlags: .command)
        path.typeText(file.path)
        app.typeKey(.return, modifierFlags: [])
        let open = app.buttons.matching(NSPredicate(format: "title == %@ OR title == %@", "打开", "Open")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.click()
        let generate = app.buttons["ai.generate.bill"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.click()
        let consent = app.buttons["ai.consent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5)); consent.click()
        XCTAssertTrue(app.staticTexts["ai.candidate"].waitForExistence(timeout: 5))
        app.buttons["ai.bill.remove"].click()
        XCTAssertFalse(app.staticTexts["ai.candidate"].exists)
        XCTAssertFalse(generate.exists)
    }

    func testKeyboardEntrySearchAndPersistence() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let amount = app.textFields["entry.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.click(); amount.typeText("12.34")
        let note = app.textFields["entry.note"]
        XCTAssertTrue(note.exists)
        note.click(); note.typeText("987654321")
        app.buttons["entry.save"].click()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))

        app.typeKey("f", modifierFlags: .command)
        let search = app.textFields["mac.entries.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("987654321")
        XCTAssertTrue(app.staticTexts["987654321"].waitForExistence(timeout: 5))

        app.terminate(); app.launch()
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click(); search.typeText("987654321")
        XCTAssertTrue(app.staticTexts["987654321"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testCompactEditorContinuousSave() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let amount = app.textFields["entry.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        let note = app.textFields["entry.note"]
        let next = app.buttons["entry.save.continue"]
        XCTAssertTrue(note.isHittable)
        XCTAssertTrue(next.isHittable)
        XCTAssertFalse(app.buttons["完成金额输入"].exists)
        amount.click(); amount.typeText("12.34")
        note.click(); note.typeText("12345678901234567890")
        XCTAssertEqual(note.value as? String, "12345678901234567890")
        next.click()
        XCTAssertTrue(app.staticTexts["entry.success"].waitForExistence(timeout: 5))
        XCTAssertEqual(amount.value as? String, "")
        amount.click(); amount.typeText("56.78")
        app.buttons["entry.save"].click()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))
        app.terminate()
    }

    func testImportSecondLevelAndEditHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString]
        app.launchEnvironment["LOT_BILL_TEST_IMPORT_CSV"] = "第一分类,第二分类,金额\n日常支出,餐饮,1200\n总计,,1200"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["历史导入"].firstMatch.click()
        let preview = app.buttons["import.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); preview.click()
        let commit = app.buttons["import.commit"]
        for _ in 0..<12 where !commit.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(commit.isEnabled); commit.click()
        app.buttons["确认提交"].click()
        let historyList = app.buttons["history.list"]
        for _ in 0..<12 where !historyList.isHittable { app.scrollViews.firstMatch.swipeDown() }
        XCTAssertTrue(historyList.waitForExistence(timeout: 5)); historyList.click()
        let edit = app.buttons["history.edit.expense.daily.2"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.click()
        let amount = app.textFields["history.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.click(); amount.typeKey("a", modifierFlags: .command); amount.typeText("987.65")
        app.buttons["history.save"].click()
        XCTAssertTrue(amount.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "987.65")).firstMatch.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        app.staticTexts["历史导入"].firstMatch.click()
        XCTAssertTrue(historyList.waitForExistence(timeout: 5)); historyList.click()
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.click()
        XCTAssertEqual(amount.value as? String, "987.65")
        app.terminate()
    }

    func testCancelEntryAndOpenSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.textFields["entry.amount"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.textFields["entry.amount"].waitForNonExistence(timeout: 5))
        app.activate()
        app.windows["ledger"].click()
        // Use the native menu: typeKey(",") is remapped by some Chinese input sources.
        app.menuBars.menuBarItems["LotBillMac"].click()
        let settings = app.menuItems.matching(NSPredicate(format: "title == %@ OR title == %@", "设置…", "Settings…")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        XCTAssertTrue(app.windows["com_apple_SwiftUI_Settings_window"].waitForExistence(timeout: 5))
        app.terminate()
    }
}
