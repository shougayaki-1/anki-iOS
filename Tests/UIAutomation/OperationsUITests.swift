import XCTest
import UIKit

final class OperationsUITests: XCTestCase {
    func tab(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        if app.tabBars.buttons[title].exists { return app.tabBars.buttons[title] }
        let index = ["ホーム", "ライブラリ", "記録", "設定"].firstIndex(of: title)!
        return app.buttons["sidebarTab-\(index)"]
    }
    func launch() -> XCUIApplication {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }

        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString]
        app.launch()
        XCTAssertTrue(tab(app, "ライブラリ").waitForExistence(timeout: 15))
        return app
    }
    func create(_ app: XCUIApplication) {
        tab(app, "ライブラリ").tap(); app.buttons["addNote"].tap()
        let question = app.descendants(matching: .any)["questionInput"]
        scrollTo(question, in: app)
        XCTAssertTrue(question.waitForExistence(timeout: 5)); question.tap(); question.typeText("Backup question")
        let answer = app.descendants(matching: .any)["answerInput"]
        scrollTo(answer, in: app)
        answer.tap(); answer.typeText("Backup answer"); app.buttons["saveNote"].tap()
        XCTAssertTrue(app.staticTexts["Backup question"].waitForExistence(timeout: 5))
    }
    func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        func visible() -> Bool {
            guard element.exists && element.isHittable else { return false }
            let top = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? app.frame.minY
            return element.frame.minY >= top && element.frame.maxY <= app.frame.maxY - 16
        }
        if visible() { return }
        if UIDevice.current.userInterfaceIdiom == .pad {
            let lists = (app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex)
                .filter { $0.isHittable && $0.frame.width > 200 && $0.frame.contains(CGPoint(x: app.frame.midX, y: app.frame.midY)) }
            if let list = lists.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                for _ in 0..<6 { list.swipeDown(); if visible() { return } }
                for _ in 0..<20 { list.swipeUp(); if visible() { return } }
                XCTAssertTrue(visible(), "iPad modal control must be visible"); return
            }
        }
        for _ in 0..<6 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.3))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.75)))
            if visible() { return }
        }
        for _ in 0..<25 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.7))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.45)))
            if visible() { return }
        }
        XCTAssertTrue(visible(), "Control must be visible outside the navigation bar")
    }
    func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    func testLibraryTreeInlineExpansionSearchAndRestart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-library-tree"]
        app.launch()
        XCTAssertTrue(tab(app, "ライブラリ").waitForExistence(timeout: 15))
        tab(app, "ライブラリ").tap()
        func folder(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'libraryDeck-' AND label CONTAINS %@", name)).firstMatch
        }
        let root = folder("Tree English"), child = folder("Tree Draft"), leaf = folder("Tree Lesson")
        XCTAssertTrue(root.waitForExistence(timeout: 10)); XCTAssertFalse(child.exists)
        root.tap(); XCTAssertTrue(child.waitForExistence(timeout: 5))
        child.tap(); XCTAssertTrue(leaf.waitForExistence(timeout: 5))
        leaf.tap(); XCTAssertTrue(app.staticTexts["Tree leaf question"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tree parent question"].exists)
        root.tap(); XCTAssertFalse(leaf.exists)
        root.tap(); XCTAssertTrue(app.staticTexts["Tree leaf question"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.terminate(); app.launch(); XCTAssertTrue(tab(app, "ライブラリ").waitForExistence(timeout: 15))
        tab(app, "ライブラリ").tap()
        XCTAssertEqual(root.value as? String, "展開中")
        for _ in 0..<4 where !app.staticTexts["Tree leaf question"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Tree leaf question"].waitForExistence(timeout: 10))
        for _ in 0..<4 where !root.isHittable { app.swipeDown() }
        root.tap()
        let field = app.searchFields.firstMatch
        for _ in 0..<4 where !field.exists { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Tree leaf\n")
        for _ in 0..<4 where !app.staticTexts["Tree leaf question"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Tree leaf question"].waitForExistence(timeout: 10))
        app.swipeUp()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Issue112-inline-tree-search"; screenshot.lifetime = .keepAlways
        add(screenshot)
        app.swipeDown()
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Tree leaf".count))
        XCTAssertTrue(root.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: child)
        waitForExpectations(timeout: 10)
    }

    func testNotificationPermissionActualReservationsAndCancellation() {
        addUIInterruptionMonitor(withDescription: "Local notification permission") { alert in
            if alert.buttons["許可"].exists { alert.buttons["許可"].tap(); return true }
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        let app = launch(); create(app)
        tab(app, "設定").tap()
        let toggle = app.switches["notificationToggle"]
        scrollTo(toggle, in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 10)
        let count = app.staticTexts["notificationCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10)); XCTAssertTrue(count.label.contains("0件"))
        tab(app, "ホーム").tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap(); app.buttons["grade-1"].tap(); app.buttons["pauseStudy"].tap()
        tab(app, "設定").tap(); scrollTo(toggle, in: app)
        let planned = NSPredicate(format: "label CONTAINS %@", "30件")
        expectation(for: planned, evaluatedWith: count)
        waitForExpectations(timeout: 15)
        attach(app, name: "Phase4-notification-reservations")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "0件"), evaluatedWith: count)
        waitForExpectations(timeout: 10)
        app.terminate(); app.launch()
        XCTAssertTrue(tab(app, "設定").waitForExistence(timeout: 15)); tab(app, "設定").tap()
        scrollTo(toggle, in: app); XCTAssertEqual(toggle.value as? String, "0")
    }
    func testActualDueNotificationDeliveryAndTapReturnsHome() throws {
        #if targetEnvironment(macCatalyst)
        throw XCTSkip("iOS notification delivery acceptance")
        #else
        addUIInterruptionMonitor(withDescription: "Local notification permission") { alert in
            for label in ["許可", "Allow"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        let app = XCUIApplication()
        let id = UUID().uuidString
        app.launchArguments = ["-study-test-store", id, "-study-test-notification-due"]
        app.launch()
        XCTAssertTrue(tab(app, "設定").waitForExistence(timeout: 15))
        tab(app, "設定").tap()
        let toggle = app.switches["notificationToggle"]
        scrollTo(toggle, in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        let count = app.staticTexts["notificationCount"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "30件"), evaluatedWith: count)
        waitForExpectations(timeout: 15)
        tab(app, "ライブラリ").tap()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if app.state == .runningForeground { XCUIDevice.shared.press(.home) }
        expectation(for: NSPredicate { _, _ in app.state != .runningForeground }, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        XCTAssertNotEqual(app.state, .runningForeground, "通知配信はバックグラウンドで確認します。")
        let notification = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "復習テスト \(id.prefix(8))")).firstMatch
        if !notification.waitForExistence(timeout: 190) {
            // Focus or disabled banners can hide the transient presentation.
            // Open Notification Center and select the actual delivered item.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.0))
                .press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.85)))
        }
        guard notification.waitForExistence(timeout: 10) else {
            attach(springboard, name: "notification-delivery-unconfirmed")
            // Cancel only this isolated store's pending notifications on failure.
            app.activate(); tab(app, "設定").tap(); scrollTo(toggle, in: app)
            if toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
            XCTFail("期限到来の実通知を特定できませんでした。予約のみで配信成功にはしません。")
            return
        }
        notification.tap()
        XCTAssertTrue(app.buttons["start-review"].waitForExistence(timeout: 15))
        XCTAssertTrue(tab(app, "ホーム").isSelected)
        app.buttons["start-review"].tap()
        if app.buttons["復習するへ切り替える"].exists { app.buttons["復習するへ切り替える"].tap() }
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 10))
        app.buttons["revealAnswer"].tap(); app.buttons["grade-4"].tap(); app.buttons["pauseStudy"].tap()
        tab(app, "設定").tap(); scrollTo(toggle, in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "label CONTAINS %@", "0件"), evaluatedWith: count)
        waitForExpectations(timeout: 15)
        app.terminate(); app.launch()
        XCTAssertTrue(tab(app, "設定").waitForExistence(timeout: 15))
        tab(app, "設定").tap(); scrollTo(toggle, in: app)
        XCTAssertEqual(toggle.value as? String, "0")
        #endif
    }
    func testNativeBackupExportAndImportPicker() {
        let app = launch(); create(app)
        let filename = "Study-UITest-\(UUID().uuidString.prefix(12))"
        tab(app, "ホーム").tap(); app.buttons["start-new"].tap()
        XCTAssertTrue(app.buttons["revealAnswer"].waitForExistence(timeout: 5))
        app.buttons["revealAnswer"].tap(); app.buttons["grade-4"].tap(); app.buttons["pauseStudy"].tap()
        tab(app, "設定").tap()
        let open = app.buttons["openBackup"]; scrollTo(open, in: app); open.tap()
        app.buttons["exportBackup"].tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10))
        let cancel = app.buttons["キャンセル"].exists ? app.buttons["キャンセル"] : app.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
        else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.085)).press(forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
        XCTAssertTrue(app.staticTexts["backupResult"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["backupResult"].label.contains("取り消しました"))
        XCTAssertFalse(app.buttons["backupReturnHome"].exists)
        app.buttons["exportBackup"].tap()
        let filenameField = app.textFields.firstMatch
        XCTAssertTrue(filenameField.waitForExistence(timeout: 10))
        filenameField.tap()
        let existing = filenameField.value as? String ?? ""
        filenameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + filename)
        if app.buttons["完了"].exists { app.buttons["完了"].tap() }
        else if app.keyboards.buttons["Done"].exists { app.keyboards.buttons["Done"].tap() }
        if app.buttons["On My iPad"].exists { app.buttons["On My iPad"].tap() }
        else if app.buttons["このiPad内"].exists { app.buttons["このiPad内"].tap() }
        let onPhone = app.buttons["On My iPhone"]
        if onPhone.waitForExistence(timeout: 10) { onPhone.tap() }
        else if app.buttons["このiPhone内"].exists { app.buttons["このiPhone内"].tap() }
        let local = app.cells.matching(NSPredicate(format: "label IN %@", ["このiPhone内", "On My iPhone", "このiPad内", "On My iPad"])).firstMatch
        if local.exists && local.isHittable { local.tap() }
        let folder = app.cells.matching(NSPredicate(format: "identifier == %@", "暗記ノート, Container")).firstMatch
        if folder.waitForExistence(timeout: 3) && folder.isHittable { folder.tap() }
        let save = app.buttons["Save"]
        if save.exists { save.tap() } else if app.buttons["保存"].exists { app.buttons["保存"].tap() }
        let result = app.staticTexts["backupResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(result.label.contains("書き出しました"))
        app.buttons["importBackup"].tap()
        let backupFile = app.cells.matching(NSPredicate(format: "label CONTAINS %@", filename)).firstMatch
        if !backupFile.waitForExistence(timeout: 3) {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(filename)
        }
        XCTAssertTrue(backupFile.waitForExistence(timeout: 15))
        backupFile.tap()
        let restore = app.buttons["restoreBackup"]; scrollTo(restore, in: app); XCTAssertTrue(restore.exists); restore.tap()
        app.buttons["confirmRestoreBackup"].firstMatch.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 10)); XCTAssertTrue(result.label.contains("復元が完了しました"))
        XCTAssertTrue(app.staticTexts["restoredBackupCounts"].label.contains("1カード"))
        XCTAssertFalse(app.buttons["restoreBackup"].exists)
        attach(app, name: "Backup-restored-completion")
        app.buttons["backupReturnHome"].tap()
        XCTAssertTrue(tab(app, "ホーム").waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["exportBackup"].exists)
        XCTAssertTrue(tab(app, "ホーム").isSelected)
        app.terminate(); app.launch()
        XCTAssertTrue(tab(app, "記録").waitForExistence(timeout: 15)); tab(app, "記録").tap()
        XCTAssertTrue(app.staticTexts["todayAnswerCount"].label.contains("1回"))
        tab(app, "ライブラリ").tap(); XCTAssertTrue(app.staticTexts["Backup question"].exists)
    }
}

extension OperationsUITests {
    func testCustomPracticePresetInterruptionAndCompletion() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-library-tree"]
        app.launch()
        XCTAssertTrue(tab(app, "ライブラリ").waitForExistence(timeout: 15))
        tab(app, "ライブラリ").tap()
        app.buttons["カスタム学習"].tap()
        let name = app.textFields["customStudyName"]
        scrollTo(name, in: app); name.tap(); name.typeText("Tree practice")
        app.buttons["完了"].tap()
        let save = app.buttons["saveCustomStudy"]
        scrollTo(save, in: app); save.tap()
        attach(app, name: "Issue124-preset")
        app.swipeDown(); app.swipeDown()
        let start = app.buttons["startCustomStudy"]
        scrollTo(start, in: app); XCTAssertTrue(start.isEnabled); start.tap()
        let reveal = app.buttons["revealCustomPractice"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5)); reveal.tap()
        XCTAssertTrue(app.buttons["nextCustomPractice"].exists)
        attach(app, name: "Issue124-practice")
        app.buttons["中断"].tap()
        app.swipeDown(); app.swipeDown()
        let resume = app.buttons["resumeCustomPractice"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5)); resume.tap()
        XCTAssertTrue(app.buttons["nextCustomPractice"].waitForExistence(timeout: 5))
        app.buttons["nextCustomPractice"].tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 5)); reveal.tap()
        app.buttons["nextCustomPractice"].tap()
        XCTAssertTrue(app.staticTexts["カスタム練習が完了しました"].waitForExistence(timeout: 5))
        app.buttons["finishCustomPractice"].tap()
        app.swipeDown(); app.swipeDown()
        XCTAssertFalse(app.buttons["resumeCustomPractice"].exists)
    }
}

extension OperationsUITests {
    func testCustomPracticeVerticalTextAttachedAudioAndHiddenAnswer() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-custom-media"]
        app.launch()
        XCTAssertTrue(tab(app, "ライブラリ").waitForExistence(timeout: 15)); tab(app, "ライブラリ").tap()
        app.buttons["カスタム学習"].tap()
        let start = app.buttons["startCustomStudy"]; scrollTo(start, in: app); start.tap()
        let question = app.buttons["customPracticeSpeakQuestion"]
        XCTAssertTrue(question.waitForExistence(timeout: 10)); question.tap()
        XCTAssertTrue(app.buttons["customPracticeStopAudio"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["customPracticeSpeakAnswer"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["customPracticeAnswer"].exists)
        app.buttons["customPracticeStopAudio"].tap()
        attach(app, name: "Issue124-vertical-question-audio")
        let reveal = app.buttons["revealCustomPractice"]; scrollTo(reveal, in: app); reveal.tap()
        app.swipeDown()
        let answerAudio = app.buttons["customPracticeSpeakAnswer"]; scrollTo(answerAudio, in: app); answerAudio.tap()
        XCTAssertTrue(app.buttons["customPracticeStopAudio"].waitForExistence(timeout: 5))
        let answer = app.descendants(matching: .any)["customPracticeAnswer"]; scrollTo(answer, in: app)
        attach(app, name: "Issue124-vertical-answer-audio")
        let next = app.buttons["nextCustomPractice"]; scrollTo(next, in: app); next.tap()
        XCTAssertTrue(app.staticTexts["カスタム練習が完了しました"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["customPracticeStopAudio"].exists)
    }

    func testCustomPracticeScaleResponseAudit() {
        let app = XCUIApplication()
        app.launchArguments = ["-study-test-store", UUID().uuidString, "-study-test-custom-scale", "-study-performance"]
        app.launch()
        XCTAssertTrue(tab(app, "ライブラリ").waitForExistence(timeout: 60))
        // Leave fixture generation outside an optional Instruments attachment.
        print("CUSTOM_AUDIT_READY cards=3000 todayLogs=10000")
        Thread.sleep(forTimeInterval: 20)
        tab(app, "ライブラリ").tap(); app.buttons["カスタム学習"].tap()
        let rebuild = app.buttons["対象を再構築"]; scrollTo(rebuild, in: app)
        for _ in 0..<3 { rebuild.tap() }
        attach(app, name: "Issue124-scale-preview")
        app.buttons["startCustomStudy"].tap()
        for _ in 0..<3 {
            let reveal = app.buttons["revealCustomPractice"]; scrollTo(reveal, in: app); reveal.tap()
            let next = app.buttons["nextCustomPractice"]; scrollTo(next, in: app); next.tap()
        }
        app.buttons["中断"].tap(); app.swipeDown(); app.swipeDown()
        let resume = app.buttons["resumeCustomPractice"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10)); resume.tap()
        XCTAssertTrue(app.buttons["revealCustomPractice"].waitForExistence(timeout: 10))
        app.buttons["中断"].tap(); app.swipeDown(); app.swipeDown()
        app.buttons["練習を終了"].tap()
        XCTAssertFalse(app.buttons["resumeCustomPractice"].exists)
        print("CUSTOM_AUDIT_FINISHED")
    }
}
