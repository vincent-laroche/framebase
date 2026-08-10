import ImageIO
import SQLite3
import UniformTypeIdentifiers
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
        XCTAssertTrue(sidebarItem(named: "All Assets", in: app).waitForExistence(timeout: 5))

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

        attachScreenshot(named: "ImportedCellRendered", in: app)
    }

    @MainActor
    func testLocalAnalysisShowsProvenanceWithoutChangingOrganization() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-\(UUID().uuidString).framebase", isDirectory: true)
        let sourceDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-Sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        let sourceURL = try writeJPEG(named: "analysis-sample.jpg", in: sourceDirectoryURL)
        let app = XCUIApplication()
        app.launchEnvironment["FRAMEBASE_UI_TEST_LIBRARY_ROOT"] = rootURL.path
        app.launchEnvironment["FRAMEBASE_UI_TEST_IMPORT_SOURCES"] = sourceURL.path
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: sourceDirectoryURL)
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("i", modifierFlags: [.command, .shift])
        let cell = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "asset.")
        ).element(boundBy: 0)
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        cell.click()
        XCTAssertTrue(app.buttons["inspector.analyzeLocally"].waitForExistence(timeout: 10))
        let foldersBeforeAnalysis = userFolderNames(at: rootURL)
        let assetOrganizationBeforeAnalysis = assetOrganizationSnapshot(at: rootURL)

        app.buttons["inspector.analyzeLocally"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["analysis.provenance"].waitForExistence(timeout: 30),
            "The completed analysis did not show result provenance."
        )
        XCTAssertEqual(userFolderNames(at: rootURL), foldersBeforeAnalysis)
        XCTAssertEqual(assetOrganizationSnapshot(at: rootURL), assetOrganizationBeforeAnalysis)
    }

    @MainActor
    func testManualOrganizationAlbumAndTagControls() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-\(UUID().uuidString).framebase", isDirectory: true)
        let sourceDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-Sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        let sourceURL = try writeJPEG(named: "organization-sample.jpg", in: sourceDirectoryURL)
        let app = XCUIApplication()
        app.launchEnvironment["FRAMEBASE_UI_TEST_LIBRARY_ROOT"] = rootURL.path
        app.launchEnvironment["FRAMEBASE_UI_TEST_IMPORT_SOURCES"] = sourceURL.path
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: sourceDirectoryURL)
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("i", modifierFlags: [.command, .shift])
        let cell = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "asset.")
        ).element(boundBy: 0)
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        cell.click()
        XCTAssertTrue(app.staticTexts["File"].waitForExistence(timeout: 10))

        let albumsMenu = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "toolbar.albums")
        ).firstMatch
        XCTAssertTrue(albumsMenu.waitForExistence(timeout: 10))
        albumsMenu.click()
        let newAlbum = app.menuItems["New Album"]
        XCTAssertTrue(newAlbum.waitForExistence(timeout: 5))
        newAlbum.click()
        XCTAssertTrue(sidebarItem(named: "New Album", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(cell.waitForExistence(timeout: 10))
        cell.click()
        XCTAssertTrue(app.staticTexts["File"].waitForExistence(timeout: 10))

        let tagField = app.textFields["inspector.tagName"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 10))
        tagField.click()
        tagField.typeText("status:review")
        let addTagButton = app.buttons["inspector.addTag"]
        XCTAssertTrue(addTagButton.waitForExistence(timeout: 10))
        XCTAssertTrue(addTagButton.isEnabled)
        addTagButton.click()
        XCTAssertTrue(waitForEmptyValue(of: tagField, timeout: 10))
    }

    @MainActor
    func testWorkflowTagPreviewRequiresApprovalBeforeOrganizationChanges() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-\(UUID().uuidString).framebase", isDirectory: true)
        let sourceDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-Sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        let sourceURL = try writeJPEG(named: "workflow-sample.jpg", in: sourceDirectoryURL)
        let app = XCUIApplication()
        app.launchEnvironment["FRAMEBASE_UI_TEST_LIBRARY_ROOT"] = rootURL.path
        app.launchEnvironment["FRAMEBASE_UI_TEST_IMPORT_SOURCES"] = sourceURL.path
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: sourceDirectoryURL)
        }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("i", modifierFlags: [.command, .shift])
        let cell = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "asset.")
        ).element(boundBy: 0)
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        cell.click()
        XCTAssertTrue(app.staticTexts["File"].waitForExistence(timeout: 10))
        let beforePreview = assetOrganizationSnapshot(at: rootURL)

        let workflowButton = app.buttons["toolbar.workflowTag"]
        XCTAssertTrue(workflowButton.waitForExistence(timeout: 10))
        workflowButton.click()
        let tagField = app.textFields["workflow.tagName"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 10))
        app.buttons["workflow.preview"].click()
        XCTAssertTrue(app.buttons["workflow.approveAndApply"].waitForExistence(timeout: 10))
        XCTAssertEqual(assetOrganizationSnapshot(at: rootURL), beforePreview)

        app.buttons["workflow.approveAndApply"].click()
        XCTAssertTrue(
            waitForTagNames(["review:strong"], at: rootURL, timeout: 10),
            "The approved workflow did not write its reviewed tag."
        )
        XCTAssertEqual(assetTagNames(at: rootURL), ["review:strong"])
        XCTAssertEqual(
            workflowAuditKinds(at: rootURL),
            ["planCreated", "proposalCreated", "approvalGranted", "executionStarted", "executionSucceeded"]
        )
    }

    @MainActor
    func testVisualAssessmentReviewRecordsEvidenceWithoutOrganizingAsset() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-\(UUID().uuidString).framebase", isDirectory: true)
        let sourceDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FramebaseUITests-Sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        let sourceURL = try writeJPEG(named: "assessment-sample.jpg", in: sourceDirectoryURL)
        let app = XCUIApplication()
        app.launchEnvironment["FRAMEBASE_UI_TEST_LIBRARY_ROOT"] = rootURL.path
        app.launchEnvironment["FRAMEBASE_UI_TEST_IMPORT_SOURCES"] = sourceURL.path
        app.launchEnvironment["FRAMEBASE_UI_TEST_SEED_VISUAL_ASSESSMENT"] = "1"
        app.launch()
        defer {
            app.terminate()
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: sourceDirectoryURL)
        }

        app.typeKey("i", modifierFlags: [.command, .shift])
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "asset.")).element(boundBy: 0)
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        cell.click()
        let accept = app.buttons["assessment.accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 10))
        let beforeReview = assetOrganizationSnapshot(at: rootURL)
        accept.click()
        XCTAssertTrue(waitForVisualAssessmentReview(at: rootURL, timeout: 10))
        XCTAssertEqual(assetOrganizationSnapshot(at: rootURL), beforeReview)
    }

    /// Scaled fixture test (300+ assets) that verifies:
    /// 1) Grid thumbnail rendering under scale with real/synthetic images.
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

        var sourceURLs: [URL] = []
        let downloadsExportURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/01_library_2026-08-06_04_46", isDirectory: true)
        if let enumerator = FileManager.default.enumerator(at: downloadsExportURL, includingPropertiesForKeys: nil) {
            for case let fileURL as URL in enumerator {
                if ["jpg", "jpeg"].contains(fileURL.pathExtension.lowercased()) {
                    sourceURLs.append(fileURL)
                    if sourceURLs.count >= 300 { break }
                }
            }
        }
        let realCount = sourceURLs.count
        if sourceURLs.count < 300 {
            for index in realCount..<300 {
                let url = try writeJPEG(named: "scaled-sample-\(index).jpg", in: sourceDirectoryURL)
                sourceURLs.append(url)
            }
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
            grid.waitForExistence(timeout: 30),
            "The asset grid never replaced the empty-state view."
        )

        let cells = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "asset.")
        )
        let firstCell = cells.element(boundBy: 0)
        XCTAssertTrue(
            firstCell.waitForExistence(timeout: 30),
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

    private func writeJPEG(named name: String, in directoryURL: URL) throws -> URL {
        let width = 1_200
        let height = 900
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

    @MainActor
    private func waitForEmptyValue(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        wait(for: NSPredicate(format: "value == %@", ""), on: element, timeout: timeout)
    }

    @MainActor
    private func wait(for predicate: NSPredicate, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
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

    /// Reads the catalog directly so this test proves local analysis cannot
    /// alter the selected asset's folder, name, favorite/rating, tag set, or
    /// album membership. It intentionally excludes analysis tables.
    private func assetOrganizationSnapshot(at rootURL: URL) -> [String]? {
        let catalogURL = rootURL
            .appendingPathComponent("Catalog", isDirectory: true)
            .appendingPathComponent("catalog.sqlite", isDirectory: false)
        var database: OpaquePointer?
        guard sqlite3_open_v2(catalogURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            return nil
        }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT a.id || '|' || a.display_name || '|' || a.parent_folder_id || '|' ||
                   a.favorite || '|' || a.rating || '|' ||
                   COALESCE((SELECT group_concat(tag_id, ',') FROM (
                       SELECT tag_id FROM asset_tags WHERE asset_id = a.id ORDER BY tag_id
                   )), '') || '|' ||
                   COALESCE((SELECT group_concat(album_id, ',') FROM (
                       SELECT album_id FROM album_assets WHERE asset_id = a.id ORDER BY album_id
                   )), '')
            FROM assets a
            ORDER BY a.id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            rows.append(String(cString: text))
        }
        return rows
    }

    private func assetTagNames(at rootURL: URL) -> [String]? {
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
            "SELECT tags.name FROM asset_tags JOIN tags ON tags.id = asset_tags.tag_id ORDER BY tags.name",
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

    private func workflowAuditKinds(at rootURL: URL) -> [String]? {
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
            "SELECT kind FROM workflow_audit_events ORDER BY rowid",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var kinds: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            kinds.append(String(cString: text))
        }
        return kinds
    }

    @MainActor
    private func waitForVisualAssessmentReview(at rootURL: URL, timeout: TimeInterval) -> Bool {
        let catalogURL = rootURL.appendingPathComponent("Catalog", isDirectory: true).appendingPathComponent("catalog.sqlite", isDirectory: false)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var database: OpaquePointer?
            if sqlite3_open_v2(catalogURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database {
                defer { sqlite3_close(database) }
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM visual_assessment_reviews", -1, &statement, nil) == SQLITE_OK, let statement {
                    defer { sqlite3_finalize(statement) }
                    if sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_int64(statement, 0) == 1 { return true }
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForTagNames(_ expectedNames: [String], at rootURL: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if assetTagNames(at: rootURL) == expectedNames {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return assetTagNames(at: rootURL) == expectedNames
    }

}
