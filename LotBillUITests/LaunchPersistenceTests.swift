import XCTest

final class LaunchPersistenceTests: XCTestCase {
    @MainActor
    func testDailyExpenseEditDeleteAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["entry.add"].waitForExistence(timeout: 10))
        app.buttons["entry.add"].tap()
        let amount = app.textFields["entry.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("35.50")
        let marker = "Lunch-\(UUID().uuidString.prefix(8))"
        let note = app.descendants(matching: .any).matching(identifier: "entry.note").firstMatch
        note.tap(); note.typeText(marker)
        app.buttons["entry.save"].tap()
        let summary = app.staticTexts["summary.expense"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "¥35.50")
        let overview = XCTAttachment(screenshot: app.screenshot())
        overview.name = "每日记账首页"
        overview.lifetime = .keepAlways
        add(overview)
        app.terminate(); app.launch()
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.label, "¥35.50")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
        app.buttons["entry.edit"].tap()
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap()
        amount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "40.25")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.buttons["entry.delete"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(summary.label, "¥40.25")
        row.tap(); app.buttons["entry.delete"].tap(); app.buttons["确认删除"].tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertEqual(summary.label, "¥0.00")
        app.terminate(); app.launch()
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertEqual(summary.label, "¥0.00")
    }

    @MainActor
    func testCreateAccountIncomeSearchAndReports() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["entry.add"].waitForExistence(timeout: 10))
        app.tabBars.buttons["设置"].tap()
        app.buttons["账户"].tap()
        app.buttons["account.add"].tap()
        let accountName = app.textFields["account.name"]
        XCTAssertTrue(accountName.waitForExistence(timeout: 5))
        accountName.tap(); accountName.typeText("Test Cash")
        app.buttons["account.save"].tap()
        XCTAssertTrue(app.buttons["account.add"].waitForExistence(timeout: 5))
        app.tabBars.buttons["首页"].tap()
        app.buttons["entry.add"].tap()
        app.segmentedControls["entry.kind"].buttons["收入"].tap()
        let amount = app.textFields["entry.amount"]
        amount.tap(); amount.typeText("4500.20")
        let note = app.descendants(matching: .any).matching(identifier: "entry.note").firstMatch
        note.tap(); note.typeText("Salary test")
        app.buttons["entry.account.source"].tap()
        app.buttons["Test Cash"].tap()
        app.buttons["entry.save"].tap()
        let income = app.staticTexts["summary.income"]
        XCTAssertTrue(income.waitForExistence(timeout: 5))
        XCTAssertEqual(income.label, "¥4500.20")
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥0.00")
        app.tabBars.buttons["流水"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Salary test")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Salary test")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["关闭"].tap()
        app.tabBars.buttons["统计"].tap()
        XCTAssertTrue(income.waitForExistence(timeout: 5))
        XCTAssertEqual(income.label, "¥4500.20")
        let reports = XCTAttachment(screenshot: app.screenshot())
        reports.name = "收入统计"
        reports.lifetime = .keepAlways
        add(reports)
    }

    @MainActor
    func testManualReconciliationAdjustmentAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(app.buttons["entry.add"].waitForExistence(timeout: 10))
        app.buttons["entry.add"].tap()
        let amount = app.textFields["entry.amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5)); amount.tap(); amount.typeText("1200")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.staticTexts["summary.expense"].waitForExistence(timeout: 5))
        app.tabBars.buttons["统计"].tap(); app.buttons["月度对账"].tap()
        app.buttons["reconciliation.manual"].tap()
        let external = app.textFields["statement.amount.expense.daily.2"]
        for _ in 0..<4 { if external.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(external.waitForExistence(timeout: 5)); external.tap(); external.typeText("1350")
        app.buttons["statement.save"].tap(); app.buttons["确认保存依据"].tap()
        let current = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "版本 1")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5)); current.tap()
        let dining = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "餐饮", "1350.00")).firstMatch
        XCTAssertTrue(dining.waitForExistence(timeout: 5)); dining.tap()
        let reason = app.textFields["adjustment.reason"]
        for _ in 0..<4 { if reason.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(reason.waitForExistence(timeout: 5)); reason.tap(); reason.typeText("Missing receipt")
        app.buttons["adjustment.prepare"].tap(); app.buttons["确认修订"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "月度调整修订"; attachment.lifetime = .keepAlways; add(attachment)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["statement.review"].tap(); app.buttons["确认核对"].tap()
        XCTAssertTrue(app.staticTexts["已核对，核对范围和保留差异见下方记录"].waitForExistence(timeout: 5))
        app.tabBars.buttons["首页"].tap()
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥1350.00")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["summary.expense"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥1350.00")
    }

    @MainActor
    func testHistoryPreviewCommitAndUndo() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString]
        app.launchEnvironment["LOT_BILL_TEST_IMPORT_CSV"] = "大类,分类,金额\n日常支出,餐饮,1200\n日常支出,超市,0\n总计,,1200"
        app.launch()
        XCTAssertTrue(app.buttons["entry.add"].waitForExistence(timeout: 10))
        app.tabBars.buttons["设置"].tap(); app.buttons["历史文件导入"].tap()
        let preview = app.buttons["import.preview"]
        for _ in 0..<8 { if preview.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(preview.waitForExistence(timeout: 5)); preview.tap()
        let commit = app.buttons["import.commit"]
        for _ in 0..<8 { if commit.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(commit.waitForExistence(timeout: 5)); XCTAssertTrue(commit.isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "历史导入预览"; attachment.lifetime = .keepAlways; add(attachment)
        commit.tap(); app.buttons["确认提交"].tap()
        XCTAssertTrue(app.staticTexts["导入成功，可在批次记录中查看来源和撤销影响。"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["导入批次与覆盖"].tap()
        app.buttons["预览撤销影响"].tap(); app.buttons["确认撤销"].tap()
        XCTAssertTrue(app.staticTexts["历史汇总 · 已撤销"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["entry.add"].waitForExistence(timeout: 10))
        app.tabBars.buttons["设置"].tap(); app.buttons["导入批次与覆盖"].tap()
        XCTAssertTrue(app.staticTexts["历史汇总 · 已撤销"].waitForExistence(timeout: 5))
    }


    @MainActor
    func testAccessibilityNavigationAndImportPreview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString]
        app.launchEnvironment["LOT_BILL_TEST_IMPORT_CSV"] = "大类,分类,金额\n日常支出,餐饮,1200"
        app.launch()
        XCTAssertTrue(app.navigationBars["Lot Bill"].waitForExistence(timeout: 10))
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        capture("外观字体-首页")
        app.tabBars.buttons["统计"].tap()
        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 5)); capture("外观字体-统计")
        app.tabBars.buttons["设置"].tap()
        let history = app.buttons["历史文件导入"]
        for _ in 0..<8 { if history.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(history.isHittable); history.tap()
        let preview = app.buttons["import.preview"]
        for _ in 0..<16 { if preview.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(preview.isHittable); preview.tap()
        let commit = app.buttons["import.commit"]
        for _ in 0..<10 { if commit.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(commit.isHittable); XCTAssertTrue(commit.isEnabled); capture("外观字体-导入确认")
    }

}
