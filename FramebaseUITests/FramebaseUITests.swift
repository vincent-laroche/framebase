import SQLite3
import XCTest

final class FramebaseUITests: XCTestCase {
    @MainActor
    func testMainWindowLaunches() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testManagedLibraryCreatesAndOpensAtLaunch() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-\(UUID().uuidString).framebase", isDirectory: true)
        let app = XCUIApplication()
        app.launchEnvironment["FRAMEBASE_UI_TEST_LIBRARY_ROOT"] = rootURL.path
        app.launch()
        defer {
            app.terminate()
            if rootURL.lastPathComponent.hasPrefix("FramebaseUITests-"),
               rootURL.pathExtension == "framebase" {
                try? FileManager.default.removeItem(at: rootURL)
            }
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let catalogURL = rootURL
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("catalog.sqlite", isDirectory: false)
        let catalogCreated = NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: catalogURL.path)
        }
        let expectation = XCTNSPredicateExpectation(predicate: catalogCreated, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Originals").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Staging").path))
    }

    @MainActor
    func testFolderCreateRenameDeleteAndUndo() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-\(UUID().uuidString).framebase", isDirectory: true)
        let app = XCUIApplication()
        app.launchEnvironment["FRAMEBASE_UI_TEST_LIBRARY_ROOT"] = rootURL.path
        app.launch()
        defer {
            app.terminate()
            if rootURL.lastPathComponent.hasPrefix("FramebaseUITests-"),
               rootURL.pathExtension == "framebase" {
                try? FileManager.default.removeItem(at: rootURL)
            }
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebarItem(named: "All Assets", in: app).waitForExistence(timeout: 5))

        app.typeKey("n", modifierFlags: [.command, .shift])
        let newFolder = sidebarItem(named: "New Folder", in: app)
        XCTAssertTrue(newFolder.waitForExistence(timeout: 5))
        newFolder.click()
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Projects")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sidebarItem(named: "Projects", in: app).waitForExistence(timeout: 5))

        app.typeKey("n", modifierFlags: [.command, .option, .shift])
        let childFolder = sidebarItem(named: "New Folder", in: app)
        XCTAssertTrue(childFolder.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForFolderNames(["New Folder", "Projects"], at: rootURL, timeout: 5))
        app.typeKey(.delete, modifierFlags: [])
        let deleteButton = app.sheets.firstMatch.buttons["Delete Folder"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()
        XCTAssertTrue(
            waitForFolderNames(["Projects"], at: rootURL, timeout: 15),
            "Observed folders: \(userFolderNames(at: rootURL) ?? [])"
        )

        app.menuBars.menuBarItems["Edit"].click()
        let undoItem = app.menuItems["Undo"]
        XCTAssertTrue(undoItem.waitForExistence(timeout: 5), app.menuItems.debugDescription)
        undoItem.click()
        XCTAssertTrue(
            waitForFolderNames(["New Folder", "Projects"], at: rootURL, timeout: 15),
            "Observed folders after undo: \(userFolderNames(at: rootURL) ?? [])"
        )

        app.menuBars.menuBarItems["Edit"].click()
        let redoItem = app.menuItems["Redo"]
        XCTAssertTrue(redoItem.waitForExistence(timeout: 5), app.menuItems.debugDescription)
        redoItem.click()
        XCTAssertTrue(
            waitForFolderNames(["Projects"], at: rootURL, timeout: 15),
            "Observed folders after redo: \(userFolderNames(at: rootURL) ?? [])"
        )
    }

    @MainActor
    private func sidebarItem(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["sidebar.item.\(name)"]
    }

    @MainActor
    private func waitForFolderNames(_ expectedNames: [String], at rootURL: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if userFolderNames(at: rootURL) == expectedNames {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        } while Date() < deadline
        return userFolderNames(at: rootURL) == expectedNames
    }

    private func userFolderNames(at rootURL: URL) -> [String]? {
        let catalogURL = rootURL
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("catalog.sqlite", isDirectory: false)
        var database: OpaquePointer?
        guard sqlite3_open_v2(catalogURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            return nil
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT name FROM folders WHERE system_kind IS NULL ORDER BY name COLLATE NOCASE",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            names.append(String(cString: text))
        }
        return names
    }

}
