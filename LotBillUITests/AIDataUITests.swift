import XCTest

@MainActor final class AIDataUITests: XCTestCase {
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launchArguments = ["--ledger-test-store", UUID().uuidString] + arguments
        app.launch(); XCTAssertTrue(app.buttons["entry.add"].waitForExistence(timeout: 10)); return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, maximum: Int = 10) {
        for _ in 0..<maximum { if element.isHittable && element.frame.maxY < app.frame.maxY - 100 { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testAIDraftRequiresReviewAndReportUsesSavedTotals() {
        let app = launch(["--ai-ui-fixture"])
        app.buttons["ai.open"].tap()
        let input = app.textFields["ai.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("Lunch 35")
        reveal(app.buttons["ai.generate"], in: app); app.buttons["ai.generate"].tap()
        XCTAssertTrue(app.buttons["同意本次发送"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["同意本次发送"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["ai.candidate"].waitForExistence(timeout: 5))
        reveal(app.buttons["ai.review"], in: app); app.buttons["ai.review"].tap()
        XCTAssertTrue(app.buttons["entry.save"].waitForExistence(timeout: 5)); app.buttons["entry.save"].tap()
        let toggle = app.switches["ai.draft.confirm"]
        reveal(toggle, in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        capture(app, name: "AI草稿核实")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.buttons["entry.save"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["AI 辅助"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥35.00")
        app.buttons["ai.open"].tap(); app.segmentedControls.buttons["月报说明"].tap()
        let generate = app.buttons["ai.report.generate"]; reveal(generate, in: app); generate.tap()
        app.buttons["同意本次发送"].firstMatch.tap()
        let explanation = app.staticTexts["ai.report.explanation"]
        XCTAssertTrue(explanation.waitForExistence(timeout: 5)); reveal(explanation, in: app)
        capture(app, name: "AI月报及本机依据")
    }
    func testManualFallbackPreservesInputWithoutService() {
        let app = launch(); app.buttons["ai.open"].tap()
        let input = app.textFields["ai.input"]; input.tap(); input.typeText("Keep original text")
        app.buttons["ai.generate"].tap()
        XCTAssertTrue(app.staticTexts["ai.message"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ai.message"].label.contains("请先"))
        app.buttons["ai.manual"].tap()
        let note = app.descendants(matching: .any).matching(identifier: "entry.note").firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5)); XCTAssertTrue((note.value as? String ?? "").contains("Keep original text"))
        app.buttons["取消"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥0.00")
    }
    func testConfigurationPersistsWithoutDisplayingStoredKey() {
        let app = launch(); app.buttons["ai.open"].tap(); app.buttons["配置 AI 服务"].tap()
        let name = app.textFields["ai.config.name"], url = app.textFields["ai.config.url"], model = app.textFields["ai.config.model"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Test Service")
        url.tap(); url.typeText("https://example.invalid/v1")
        model.tap(); model.typeText("test-model")
        let key = app.secureTextFields["ai.config.key"]; key.tap(); key.typeText("synthetic-key")
        let save = app.buttons["ai.config.save"]; reveal(save, in: app); save.tap()
        reveal(app.staticTexts["ai.config.message"], in: app)
        XCTAssertTrue(app.staticTexts["ai.config.message"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["ai.open"].waitForExistence(timeout: 10)); app.buttons["ai.open"].tap(); app.buttons["配置 AI 服务"].tap()
        XCTAssertEqual(name.value as? String, "Test Service"); XCTAssertEqual(model.value as? String, "test-model")
        XCTAssertFalse((key.value as? String ?? "").contains("synthetic-key"))
        capture(app, name: "AI服务配置")
    }
    func testCSVExporterCancellationAndConfirmedRestore() {
        let app = launch(["--backup-ui-fixture"])
        app.buttons["entry.add"].tap()
        let amount = app.textFields["entry.amount"]; amount.tap(); amount.typeText("35.50"); app.buttons["entry.save"].tap()
        app.tabBars.buttons["设置"].tap()
        reveal(app.buttons["CSV 导出"], in: app); app.buttons["CSV 导出"].tap()
        let preview = app.buttons["export.preview"]; reveal(preview, in: app); preview.tap()
        let save = app.buttons["export.save"]; reveal(save, in: app); capture(app, name: "CSV导出预览"); save.tap()
        let picker = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        XCTAssertTrue(picker.waitForExistence(timeout: 8))
        capture(app, name: "系统CSV导出器")
        let cancel = app.buttons["取消"].firstMatch
        // The system remembers the last destination, so cancellation can require
        // multiple back steps on a real phone with existing document folders.
        for _ in 0..<8 {
            if cancel.waitForExistence(timeout: 2) && cancel.isHittable { break }
            let back = picker.buttons["BackButton"]
            guard back.waitForExistence(timeout: 2), back.isHittable else { break }
            back.tap()
        }
        XCTAssertTrue(cancel.waitForExistence(timeout: 5)); cancel.tap()
        XCTAssertTrue(app.navigationBars["CSV 导出"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(app.buttons["备份与恢复"], in: app); app.buttons["备份与恢复"].tap()
        let restore = app.buttons["backup.restore"]; reveal(restore, in: app)
        XCTAssertTrue(app.staticTexts["backup.preview.summary"].exists)
        capture(app, name: "备份恢复预览")
        restore.tap(); app.buttons["建立恢复点并替换账本"].tap()
        XCTAssertTrue(app.staticTexts["restore.notice"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥35.50")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["summary.expense"].waitForExistence(timeout: 10)); XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥35.50")
    }
}

@MainActor final class M7AcceptanceUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString] + extra
        if extra.contains("--m7-accessibility") { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.navigationBars["Lot Bill"].waitForExistence(timeout: 30))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<16 {
            if element.isHittable && element.frame.maxY < app.frame.maxY - 90 { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func addExpense(_ amount: String, in app: XCUIApplication) {
        app.buttons["entry.add"].tap()
        let input = app.textFields["entry.amount"]; XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText(amount); app.buttons["entry.save"].tap()
        XCTAssertTrue(app.buttons["entry.save"].waitForNonExistence(timeout: 5))
    }
    private func openBackup(_ app: XCUIApplication) {
        app.tabBars.buttons["设置"].tap()
        for _ in 0..<5 {
            if app.navigationBars["设置"].exists { break }
            app.navigationBars.buttons["BackButton"].tap()
        }
        reveal(app.buttons["备份与恢复"], in: app); app.buttons["备份与恢复"].tap()
        XCTAssertTrue(app.buttons["backup.export"].waitForExistence(timeout: 5))
    }
    func testAbruptExitBeforeAndAfterRestoreCommit() {
        for phase in ["before-save", "after-save"] {
            let app = launch(["--backup-ui-fixture"])
            addExpense("35.50", in: app)
            // The incoming preview captures 35.50, then the live ledger gains a second record.
            // Capture incoming on each launch from a file in the isolated test directory.
            app.launchArguments += ["--m7-restore-fixture", "--m7-exit-" + phase]
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["entry.add"].waitForExistence(timeout: 10))
            addExpense("10", in: app)
            openBackup(app)
            reveal(app.buttons["backup.restore"], in: app)
            app.buttons["backup.restore"].tap(); app.buttons["建立恢复点并替换账本"].tap()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
            app.launchArguments.removeAll { $0.hasPrefix("--m7-exit-") || $0 == "--backup-ui-fixture" || $0 == "--m7-restore-fixture" }
            app.launch()
            XCTAssertTrue(app.staticTexts["summary.expense"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.staticTexts["summary.expense"].label, phase == "before-save" ? "¥45.50" : "¥35.50")
            openBackup(app)
            let recovery = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "BeforeRestore-")).firstMatch
            reveal(recovery, in: app); recovery.tap()
            XCTAssertTrue(app.staticTexts["backup.preview.summary"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["backup.preview.summary"].label.contains("流水 2；"))
            capture(app, "M7-中断恢复点-" + phase)
            app.buttons["backup.restore"].tap(); app.buttons["建立恢复点并替换账本"].tap()
            XCTAssertTrue(app.staticTexts["summary.expense"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥45.50")
            app.terminate()
        }
    }
    func testTenThousandEntryListSearchAndStatistics() {
        let app = launch(["--m7-large"])
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥10100.00")
        app.tabBars.buttons["流水"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        for _ in 0..<3 { app.swipeUp() }
        capture(app, "M7-万条流水滚动")
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Synthetic scale 9999")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Synthetic scale 9999")).firstMatch.waitForExistence(timeout: 10))
        capture(app, "M7-万条流水搜索")
        app.buttons["关闭"].tap(); app.tabBars.buttons["统计"].tap()
        XCTAssertTrue(app.staticTexts["summary.expense"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥10100.00")
    }
    func testSystemFileHistoryExportAndRestore() {
        let app = launch(["--m7-files"])
        app.tabBars.buttons["设置"].tap(); app.buttons["历史文件导入"].tap()
        app.buttons["选择 XLSX / CSV 文件"].tap()
        capture(app, "M7-系统文件选择器")
        // Preserve the initial picker hierarchy in the test result when adapting OS navigation.
        let attachment = XCTAttachment(string: app.debugDescription); attachment.name = "M7-file-picker"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(app.buttons["浏览"].waitForExistence(timeout: 5))
        app.buttons["浏览"].tap()
        let local = app.staticTexts["我的iPhone"]
        if local.waitForExistence(timeout: 5) && !app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Lot Bill")).firstMatch.exists { local.tap() }
        let folder = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Lot Bill")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.tap()
        let synthetic = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "M7-" + app.launchArguments[1])).firstMatch
        XCTAssertTrue(synthetic.waitForExistence(timeout: 5)); synthetic.tap()
        app.cells.matching(NSPredicate(format: "label CONTAINS %@", "M7-History")).firstMatch.tap()
        let preview = app.buttons["import.preview"]; reveal(preview, in: app); preview.tap()
        let commit = app.buttons["import.commit"]; reveal(commit, in: app); commit.tap(); app.buttons["确认提交"].tap()
        XCTAssertTrue(app.staticTexts["导入成功，可在批次记录中查看来源和撤销影响。"].waitForExistence(timeout: 5))
        app.tabBars.buttons["首页"].tap(); addExpense("1200", in: app)
        app.tabBars.buttons["统计"].tap(); app.buttons["月度对账"].tap()
        app.buttons["reconciliation.manual"].tap()
        let external = app.textFields["statement.amount.expense.daily.2"]
        reveal(external, in: app); external.tap(); external.typeText("1350")
        app.buttons["statement.save"].tap(); app.buttons["确认保存依据"].tap()
        let current = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "版本 1")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5)); current.tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "餐饮", "1350.00")).firstMatch.tap()
        let reason = app.textFields["adjustment.reason"]
        reveal(reason, in: app); reason.tap(); reason.typeText("Synthetic missing receipt")
        app.buttons["adjustment.prepare"].tap(); app.buttons["确认修订"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        app.buttons["statement.review"].tap(); app.buttons["确认核对"].tap()
        XCTAssertTrue(app.staticTexts["已核对，核对范围和保留差异见下方记录"].waitForExistence(timeout: 5))
        app.tabBars.buttons["首页"].tap()
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥1350.00")
        openBackup(app)
        app.buttons["backup.export"].tap()
        capture(app, "M7-系统备份导出器")
        let exportAttachment = XCTAttachment(string: app.debugDescription); exportAttachment.name = "M7-backup-export-picker"; exportAttachment.lifetime = .keepAlways; add(exportAttachment)
        let filename = "M7-Roundtrip-" + app.launchArguments[1]
        let filenameField = app.textFields["DOCPicker.filenameTextField"]
        XCTAssertTrue(filenameField.waitForExistence(timeout: 5)); filenameField.tap()
        filenameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100) + filename)
        app.buttons["DOCPicker.actionButton"].tap()
        XCTAssertTrue(app.staticTexts["备份已导出。"].waitForExistence(timeout: 10))
        app.tabBars.buttons["首页"].tap(); addExpense("10", in: app)
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥1360.00")
        openBackup(app); reveal(app.buttons["backup.import"], in: app); app.buttons["backup.import"].tap()
        let saved = app.cells.matching(NSPredicate(format: "label CONTAINS %@", filename)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.tap()
        XCTAssertTrue(app.staticTexts["backup.preview.summary"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["backup.preview.summary"].label.contains("流水 1；历史 1；"))
        XCTAssertTrue(app.staticTexts["backup.preview.summary"].label.contains("调整修订 1；"))
        reveal(app.buttons["backup.restore"], in: app); capture(app, "M7-真实文件恢复预览")
        app.buttons["backup.restore"].tap(); app.buttons["建立恢复点并替换账本"].tap()
        XCTAssertTrue(app.staticTexts["restore.notice"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥1350.00")
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["summary.expense"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥1350.00")
        app.tabBars.buttons["设置"].tap(); reveal(app.buttons["CSV 导出"], in: app); app.buttons["CSV 导出"].tap()
        reveal(app.buttons["export.preview"], in: app); app.buttons["export.preview"].tap()
        reveal(app.buttons["export.save"], in: app); app.buttons["export.save"].tap()
        XCTAssertTrue(app.buttons["DOCPicker.actionButton"].waitForExistence(timeout: 10))
        app.buttons["DOCPicker.actionButton"].tap()
        XCTAssertTrue(app.staticTexts["文件已导出。"].waitForExistence(timeout: 10))
        capture(app, "M7-CSV实际导出完成")
    }
}

extension M7AcceptanceUITests {
    func testLargestTextDarkAppearanceKeyboardAndDatePicker() {
        let app = launch(["--m7-accessibility"])
        capture(app, "M7-深色最大字号-首页")
        reveal(app.buttons["entry.add"], in: app); app.buttons["entry.add"].tap()
        let amount = app.textFields["entry.amount"]; XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("12.34")
        capture(app, "M7-深色最大字号-金额键盘")
        let done = app.buttons["完成金额输入"]; reveal(done, in: app); done.tap()
        let date = app.datePickers["entry.date"]; reveal(date, in: app); date.tap()
        capture(app, "M7-深色最大字号-日期选择")
        // Close the compact calendar by tapping its date field again or its dismissal control.
        if app.buttons["关闭"].exists { app.buttons["关闭"].tap() }
        else { app.navigationBars["记一笔"].tap() }
        let note = app.descendants(matching: .any).matching(identifier: "entry.note").firstMatch
        reveal(note, in: app); note.tap(); note.typeText("Large text keyboard check")
        capture(app, "M7-深色最大字号-备注键盘")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.buttons["entry.save"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥12.34")
        app.tabBars.buttons["流水"].tap()
        app.swipeUp(); app.swipeUp()
        capture(app, "M7-深色最大字号-流水")
        app.tabBars.buttons["统计"].tap()
        reveal(app.staticTexts["summary.expense"], in: app)
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥12.34")
        capture(app, "M7-深色最大字号-统计")
    }
}

@MainActor final class ImprovementsUITests: XCTestCase {
    private func launch(history: Bool = false, backup: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ledger-test-store", UUID().uuidString] + (backup ? ["--backup-ui-fixture"] : [])
        if history { app.launchEnvironment["LOT_BILL_TEST_IMPORT_CSV"] = "第一分类,年度金额\n日常支出,1000\n总计,1000" }
        app.launch(); XCTAssertTrue(app.buttons["entry.add"].waitForExistence(timeout: 10)); return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 { if element.isHittable && element.frame.maxY < app.frame.maxY - 80 { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testSaveContinueTemplateAndBackupRehearsal() {
        let app = launch(backup: true)
        app.buttons["entry.add"].tap()
        app.textFields["entry.amount"].tap(); app.textFields["entry.amount"].typeText("20")
        app.buttons["完成金额输入"].tap()
        let template = app.buttons["将当前内容存为模板"]; reveal(template, in: app); template.tap()
        let next = app.buttons["entry.save.continue"]; reveal(next, in: app); next.tap()
        XCTAssertTrue(app.staticTexts["entry.success"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["entry.success"].label, "已保存，可继续记下一笔。")
        app.buttons["取消"].tap()
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥20.00")
        app.buttons["entry.add"].tap()
        let savedTemplate = app.buttons["餐饮 · ¥20"]; reveal(savedTemplate, in: app); savedTemplate.tap()
        app.buttons["entry.save"].tap()
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥40.00")
        app.tabBars.buttons["设置"].tap()
        let backup = app.buttons["备份与恢复"]; reveal(backup, in: app); backup.tap()
        XCTAssertTrue(app.staticTexts["backup.never"].waitForExistence(timeout: 5))
        let rehearse = app.buttons["backup.rehearse"]; reveal(rehearse, in: app); rehearse.tap()
        let result = app.staticTexts["backup.rehearsal.result"]; reveal(result, in: app)
        XCTAssertTrue(result.label.contains("演练通过")); capture(app, "P1-恢复演练")
        app.tabBars.buttons["首页"].tap()
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥40.00")
    }
    func testAnnualImportRefundAndCoverage() {
        let app = launch(history: true)
        app.tabBars.buttons["设置"].tap(); app.buttons["历史文件导入"].tap()
        let year = app.textFields["import.year"]; reveal(year, in: app)
        year.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let old = year.value as? String ?? "2025"
        year.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "2026")
        XCTAssertEqual(year.value as? String, "2026")
        app.swipeUp()
        let preview = app.buttons["import.preview"]; reveal(preview, in: app); preview.tap()
        let commit = app.buttons["import.commit"]; reveal(commit, in: app)
        XCTAssertTrue(commit.isEnabled); capture(app, "P1-两列年度导入")
        commit.tap(); app.buttons["确认提交"].tap()
        XCTAssertTrue(app.staticTexts["导入成功，可在批次记录中查看来源和撤销影响。"].waitForExistence(timeout: 5))
        app.tabBars.buttons["首页"].tap(); app.buttons["entry.add"].tap()
        app.segmentedControls.buttons["退款"].tap()
        app.textFields["entry.amount"].tap(); app.textFields["entry.amount"].typeText("50")
        app.buttons["完成金额输入"].tap()
        app.segmentedControls.buttons["历史消费"].tap()
        app.buttons["refund.history"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "2026-08-31")).firstMatch.tap()
        let reference = app.textFields["refund.reference"]; reveal(reference, in: app); reference.tap(); reference.typeText("receipt-ui")
        let reason = app.descendants(matching: .any).matching(identifier: "refund.reason").firstMatch; reveal(reason, in: app); reason.tap(); reason.typeText("Return item")
        app.buttons["entry.save"].tap()
        XCTAssertTrue(app.buttons["entry.add"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥-50.00")
        app.tabBars.buttons["统计"].tap(); app.segmentedControls.buttons["年度"].tap()
        XCTAssertEqual(app.staticTexts["summary.expense"].label, "¥950.00")
        let group = app.buttons["report.group.expense.daily"]; reveal(group, in: app); group.tap(); capture(app, "P1-年度大类展开")
        app.tabBars.buttons["设置"].tap(); app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["月度对账"].tap(); app.buttons["coverage.open"].tap()
        let august = app.buttons["coverage.month.2026-08"]; reveal(august, in: app); august.tap()
        let status = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "日常支出", "历史未按月拆分")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5)); reveal(status, in: app); capture(app, "P2-月份分类覆盖")
    }
}
