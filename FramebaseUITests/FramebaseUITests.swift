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

        // A dequeued cell that raises during layout takes the process with it,
        // and a browser that keeps cancelling and re-requesting its thumbnails
        // pins the main thread, which stalls these queries until they time out.
        // Interacting after the grid settles is what covers both.
        firstCell.click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.state, .runningForeground)
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
