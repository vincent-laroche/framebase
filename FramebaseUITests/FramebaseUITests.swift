import ImageIO
import SQLite3
import UniformTypeIdentifiers
import XCTest

final class FramebaseUITests: XCTestCase {
    @MainActor
    func testMainWindowLaunches() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-\(UUID().uuidString).framebase", isDirectory: true)
        let app = XCUIApplication()
        // A launch smoke test must not inherit the developer's persisted
        // library or cloud enrollment: that would make the test reach for
        // Keychain and block on a human authorization dialog.
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

        // Selecting a folder must name it. The navigation target is only an
        // identifier, so an unresolved title reads as the literal word "Folder".
        sidebarItem(named: "Projects", in: app).click()
        let titledWindow = app.windows["Projects"]
        XCTAssertTrue(
            titledWindow.waitForExistence(timeout: 5),
            "Window titles: \(app.windows.allElementsBoundByIndex.map(\.title))"
        )

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
    func testNewAlbumAndTagAppearInTheNativeSidebar() throws {
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

        app.menuBars.menuBarItems["File"].click()
        let newAlbum = app.menuItems["New Album"]
        XCTAssertTrue(newAlbum.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(newAlbum, timeout: 5), "New Album was visible but had no clickable frame.")
        newAlbum.click()
        XCTAssertTrue(sidebarItem(named: "New Album", in: app).waitForExistence(timeout: 5))
        sidebarItem(named: "New Album", in: app).click()
        app.typeKey(.return, modifierFlags: [])
        app.typeText("Campaign")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sidebarItem(named: "Campaign", in: app).waitForExistence(timeout: 5))

        app.menuBars.menuBarItems["File"].click()
        let newTag = app.menuItems["New Tag"]
        XCTAssertTrue(newTag.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForHittable(newTag, timeout: 5), "New Tag was visible but had no clickable frame.")
        newTag.click()
        XCTAssertTrue(sidebarItem(named: "New Tag", in: app).waitForExistence(timeout: 5))
        sidebarItem(named: "New Tag", in: app).click()
        XCTAssertTrue(app.windows["New Tag"].waitForExistence(timeout: 5))
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertFalse(sidebarItem(named: "New Tag", in: app).waitForExistence(timeout: 5))

        app.menuBars.menuBarItems["Edit"].click()
        let undoItem = app.menuItems["Undo"]
        XCTAssertTrue(undoItem.waitForExistence(timeout: 5), app.menuItems.debugDescription)
        undoItem.click()
        XCTAssertTrue(
            sidebarItem(named: "New Tag", in: app).waitForExistence(timeout: 5),
            "Undo must restore a deleted tag to the native sidebar."
        )
    }

    /// The rest of the suite runs against an empty library, so no collection
    /// view cell is ever dequeued and no thumbnail is ever decoded. Importing
    /// real images and asserting a cell renders is what covers that path.
    ///
    /// Scope note: this covers dequeue, configure, and display. It does not
    /// catch the cell-lifecycle feedback loop that pinned the browser at 100%
    /// CPU, because that only starves decodes once they are slower than the
    /// reload cycle, which needs a real photo library rather than fixtures.
    @MainActor
    func testImportedAssetRendersAThumbnailCell() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-\(UUID().uuidString).framebase", isDirectory: true)
        let sourceDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-Sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        // More cells than fit at once, so reuse and prefetch run too.
        let sourceURLs = try (0..<12).map { index in
            try writeJPEG(named: "sample-\(index).jpg", in: sourceDirectoryURL)
        }

        let app = XCUIApplication()
        app.launchEnvironment["FRAMEBASE_UI_TEST_LIBRARY_ROOT"] = rootURL.path
        app.launchEnvironment["FRAMEBASE_UI_TEST_IMPORT_SOURCES"] = sourceURLs
            .map(\.path)
            .joined(separator: "\n")
        app.launch()
        defer {
            app.terminate()
            if rootURL.lastPathComponent.hasPrefix("FramebaseUITests-"),
               rootURL.pathExtension == "framebase" {
                try? FileManager.default.removeItem(at: rootURL)
            }
            if sourceDirectoryURL.lastPathComponent.hasPrefix("FramebaseUITests-Sources-") {
                try? FileManager.default.removeItem(at: sourceDirectoryURL)
            }
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let allAssets = sidebarItem(named: "All Assets", in: app)
        XCTAssertTrue(allAssets.waitForExistence(timeout: 5))
        allAssets.click()

        app.typeKey("i", modifierFlags: [.command, .shift])

        let grid = app.descendants(matching: .any)["assetBrowser.grid"]
        XCTAssertTrue(
            grid.waitForExistence(timeout: 30),
            "The asset grid never replaced the empty-state view."
        )

        let cells = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "asset.")
        )
        let firstCell = cells.element(boundBy: 0)
        XCTAssertTrue(
            firstCell.waitForExistence(timeout: 30),
            "No asset cell was rendered. Grid: \(grid.debugDescription)"
        )
        // Only the on-screen cells are realized, so this is a floor, not a count.
        XCTAssertGreaterThan(cells.count, 0)

        // Each cell captions itself with the asset's display name.
        //
        // Scope note: this proves the caption is built, not that it is visible.
        // A thumbnail that overflows its cell pushes the caption off-screen
        // while leaving it in the accessibility tree with an unchanged frame,
        // so neither existence nor geometry catches that regression here —
        // reproducing it needs real photographs rather than fixtures.
        let filenameLabel = app.staticTexts.matching(
            NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "sample-", "sample-")
        ).element(boundBy: 0)
        XCTAssertTrue(
            filenameLabel.waitForExistence(timeout: 15),
            "No cell rendered its filename. Cells: \(cells.debugDescription)"
        )

        // A dequeued cell that raises during layout takes the process with it,
        // and a browser that keeps cancelling and re-requesting its thumbnails
        // pins the main thread, which stalls these queries until they time out.
        // Interacting after the grid settles is what covers both.
        firstCell.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(
            app.staticTexts["File"].waitForExistence(timeout: 10),
            "The inspector did not show single-asset detail after a click."
        )

        // The inspector swaps its "File" detail for a "Selection" summary once
        // more than one asset is selected, so this catches ⌘A regressing to a
        // no-op while the grid holds focus. It does not distinguish selecting
        // the realized cells from selecting every asset in a paged scope.
        app.typeKey("a", modifierFlags: [.command])
        XCTAssertTrue(
            app.staticTexts["Selection"].waitForExistence(timeout: 10),
            "Command-A did not select every asset while the grid had focus."
        )

        let moveToTrash = app.descendants(matching: .any)["toolbar.moveToTrash"]
        XCTAssertTrue(moveToTrash.waitForExistence(timeout: 5), "Move to Trash is missing from the browser toolbar.")
        moveToTrash.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["assetBrowser.empty.All Assets"].waitForExistence(timeout: 10),
            "Moving the selected fixture assets to Trash did not clear the current destination."
        )
        let trash = sidebarItem(named: "Trash", in: app)
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.click()
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "Trash did not show the selected fixture assets.")
        app.typeKey("a", modifierFlags: [.command])
        let restore = app.descendants(matching: .any)["toolbar.restoreFromTrash"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5), "Restore is missing from the Trash toolbar.")
        restore.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["assetBrowser.empty.Trash"].waitForExistence(timeout: 10),
            "Restoring selected assets did not clear Trash."
        )
        allAssets.click()
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "Restore did not return the fixture assets to All Assets.")

        // This stays fixture-only. It will run in CI or a dedicated session;
        // local headless verification compiles the target but never drives the
        // active macOS desktop through XCUITest.
        let viewMenu = app.descendants(matching: .any)["toolbar.browserView"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 5), "The browser view menu is missing.")
        viewMenu.click()
        let listAction = app.menuItems["List"]
        XCTAssertTrue(listAction.waitForExistence(timeout: 5), "The List view action is missing.")
        listAction.click()
        let list = app.descendants(matching: .any)["assetBrowser.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "List presentation did not replace the grid.")
        app.typeKey("a", modifierFlags: [.command])
        XCTAssertTrue(
            app.staticTexts["Selection"].waitForExistence(timeout: 10),
            "Command-A did not select the paged list records."
        )
        viewMenu.click()
        let gridAction = app.menuItems["Grid"]
        XCTAssertTrue(gridAction.waitForExistence(timeout: 5), "The Grid view action is missing.")
        gridAction.click()
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "Grid presentation did not restore after list verification.")

        let searchField = app.descendants(matching: .any)["assetBrowser.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "The native structured search field is missing.")
        searchField.click()
        searchField.typeText("sample-0")
        let filteredCells = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "asset.")
        )
        func waitForFilteredCells(matching format: String) -> XCTWaiter.Result {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: format),
                object: filteredCells
            )
            return XCTWaiter.wait(for: [expectation], timeout: 10)
        }
        XCTAssertEqual(waitForFilteredCells(matching: "count == 1"), .completed)
        XCTAssertEqual(filteredCells.count, 1, "Search did not reduce the browser to its one matching asset.")

        let savedSearches = app.descendants(matching: .any)["toolbar.savedSearches"]
        XCTAssertTrue(savedSearches.waitForExistence(timeout: 5), "Saved Searches is missing from the browser toolbar.")
        savedSearches.click()
        let saveCurrentSearch = app.menuItems["Save Current Search"]
        XCTAssertTrue(saveCurrentSearch.waitForExistence(timeout: 5), app.menuItems.debugDescription)
        saveCurrentSearch.click()

        let smartCollections = app.descendants(matching: .any)["toolbar.smartCollections"]
        XCTAssertTrue(smartCollections.waitForExistence(timeout: 5), "Smart Collections is missing from the browser toolbar.")
        smartCollections.click()
        let createSmartCollection = app.menuItems["Create From Current Rules"]
        XCTAssertTrue(createSmartCollection.waitForExistence(timeout: 5), app.menuItems.debugDescription)
        createSmartCollection.click()
        let smartCollection = app.textFields["sidebar.item.Smart Collection"]
        XCTAssertTrue(smartCollection.waitForExistence(timeout: 5), "The rule-backed smart collection was not added to the sidebar.")

        let savedSearch = app.textFields["sidebar.item.Saved Search"]
        XCTAssertTrue(savedSearch.waitForExistence(timeout: 5), "The saved rule was not added to the sidebar.")
        savedSearch.click()
        app.typeKey(.return, modifierFlags: [])
        app.typeKey("a", modifierFlags: [.command])
        app.typeText("Sample Search")
        app.typeKey(.return, modifierFlags: [])
        let renamedSavedSearch = app.textFields["sidebar.item.Sample Search"]
        XCTAssertTrue(renamedSavedSearch.waitForExistence(timeout: 5), "The saved rule could not be renamed inline.")

        searchField.click()
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey(.delete, modifierFlags: [])
        allAssets.click()
        XCTAssertEqual(waitForFilteredCells(matching: "count > 1"), .completed)

        renamedSavedSearch.click()
        XCTAssertEqual(waitForFilteredCells(matching: "count == 1"), .completed)

        allAssets.click()
        XCTAssertEqual(waitForFilteredCells(matching: "count > 1"), .completed)
        smartCollection.click()
        XCTAssertEqual(waitForFilteredCells(matching: "count == 1"), .completed)

        attachScreenshot(named: "ImportedCellRendered", in: app)
    }

    /// Scaled fixture test (300+ assets) that verifies:
    /// 1) Grid thumbnail rendering under scale with synthetic images only.
    /// 2) Command-A selects all assets and updates inspector to "Selection".
    /// 3) Single click collapses a multi-selection back to 1 asset ("File" inspector).
    /// 4) Captures XCTAttachment screenshots at key milestones for visual verification.
    @MainActor
    func testScaledLibrarySelectionAndScreenshotHarness() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-\(UUID().uuidString).framebase", isDirectory: true)
        let sourceDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-Sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)

        let sourceURLs = try (0..<300).map { index in
            try writeJPEG(
                named: "scaled-sample-\(index).jpg",
                in: sourceDirectoryURL,
                width: 320,
                height: 240
            )
        }

        let app = XCUIApplication()
        app.launchEnvironment["FRAMEBASE_UI_TEST_LIBRARY_ROOT"] = rootURL.path
        app.launchEnvironment["FRAMEBASE_UI_TEST_IMPORT_SOURCES"] = sourceURLs
            .map(\.path)
            .joined(separator: "\n")
        app.launch()
        defer {
            app.terminate()
            if rootURL.lastPathComponent.hasPrefix("FramebaseUITests-"),
               rootURL.pathExtension == "framebase" {
                try? FileManager.default.removeItem(at: rootURL)
            }
            if sourceDirectoryURL.lastPathComponent.hasPrefix("FramebaseUITests-Sources-") {
                try? FileManager.default.removeItem(at: sourceDirectoryURL)
            }
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(sidebarItem(named: "All Assets", in: app).waitForExistence(timeout: 5))

        app.typeKey("i", modifierFlags: [.command, .shift])

        let grid = app.descendants(matching: .any)["assetBrowser.grid"]
        XCTAssertTrue(
            grid.waitForExistence(timeout: 60),
            "The asset grid never replaced the empty-state view."
        )

        let cells = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "asset.")
        )
        let firstCell = cells.element(boundBy: 0)
        XCTAssertTrue(
            firstCell.waitForExistence(timeout: 60),
            "No asset cell was rendered in scaled test."
        )

        attachScreenshot(named: "01-ScaledGridImported", in: app)

        app.typeKey("a", modifierFlags: [.command])
        XCTAssertTrue(
            app.staticTexts["Selection"].waitForExistence(timeout: 10),
            "Command-A did not trigger multi-selection on 300+ asset library."
        )

        attachScreenshot(named: "02-MultiSelectionAll", in: app)

        firstCell.click()
        XCTAssertTrue(
            app.staticTexts["File"].waitForExistence(timeout: 10),
            "Single click on a cell did not collapse multi-selection back to single item inspector."
        )

        attachScreenshot(named: "03-SingleCellCollapsed", in: app)
    }

    @MainActor
    private func attachScreenshot(named name: String, in app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func writeJPEG(
        named name: String,
        in directoryURL: URL,
        width: Int = 1_200,
        height: Int = 900
    ) throws -> URL {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8(x * 4 % 256)
                pixels[offset + 1] = UInt8(y * 5 % 256)
                pixels[offset + 2] = UInt8((x + y) % 256)
                pixels[offset + 3] = 255
            }
        }

        let url = directoryURL.appendingPathComponent(name, isDirectory: false)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ),
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    @MainActor
    private func sidebarItem(named name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["sidebar.item.\(name)"]
    }

    private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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
