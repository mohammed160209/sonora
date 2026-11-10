import XCTest

/// Exercises real touch gestures against the same native queue used by the app.
final class MusicInteractionTests: XCTestCase {
    func testPlayerModesMenusAndReturnToMiniPlayer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-url", "sonora://review?id=jfKfPfyJRdk&title=Sonora%20Player%20Interaction&artist=Sonora%20Artist&mode=artwork"]
        app.launch()
        XCTAssertTrue(app.buttons["player-queue"].waitForExistence(timeout: 30))
        app.buttons["player-queue"].tap()
        XCTAssertTrue(app.buttons["queue-add-songs"].waitForExistence(timeout: 8))
        app.buttons["player-lyrics"].tap()
        let lyricsOptions = app.buttons["lyrics-source-options"]
        XCTAssertTrue(lyricsOptions.waitForExistence(timeout: 8))
        XCTAssertTrue(lyricsOptions.isHittable)
        lyricsOptions.tap()
        XCTAssertTrue(app.buttons["Lyrics Sources"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["Lyrics Sources"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Lyrics Sources"].waitForExistence(timeout: 8))
        app.navigationBars["Lyrics Sources"].buttons["Done"].tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: lyricsOptions)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["player-return-artwork"].waitForExistence(timeout: 8))
        app.buttons["player-return-artwork"].tap()
        XCTAssertTrue(app.buttons["player-more"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(identifier: "player-more").count, 1)
        app.buttons["player-more"].tap()
        XCTAssertTrue(app.buttons["Add to Queue"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["Add to Queue"].firstMatch.tap()
        app.buttons["player-dismiss"].tap()
        XCTAssertTrue(app.buttons["mini-player-open"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["mini-player-open"].label.contains("Sonora Artist"))
        app.buttons["mini-player-open"].tap()
        XCTAssertTrue(app.buttons["player-queue"].waitForExistence(timeout: 8))
    }

    func testFullscreenPullDownCancelAndDismissFromArtworkAndBlankSpace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-fullscreen", "--sonora-review-url", "sonora://seekreview"]
        app.launch()
        XCTAssertTrue(app.buttons["player-queue"].waitForExistence(timeout: 30))
        let surface = app.otherElements["player-fullscreen"].firstMatch
        XCTAssertTrue(surface.exists)
        XCTAssertLessThanOrEqual(surface.frame.minY, 1)
        XCTAssertGreaterThanOrEqual(surface.frame.maxY, app.frame.maxY - 1)
        let offlineBadge = app.staticTexts["player-offline-badge"]
        XCTAssertTrue(offlineBadge.waitForExistence(timeout: 8))
        XCTAssertEqual(offlineBadge.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertLessThan(offlineBadge.frame.maxY, app.buttons["player-play-pause"].frame.minY)
        // Pull a short way down and reverse: the player must survive cancellation.
        let artwork = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        artwork.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.36)),
            withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertTrue(app.buttons["player-queue"].waitForExistence(timeout: 8))
        // A downward artwork pull closes without needing the top grabber.
        artwork.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)))
        let mini = app.buttons["mini-player-open"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mini)
        waitForExpectations(timeout: 8)
        mini.tap()
        XCTAssertTrue(app.buttons["player-queue"].waitForExistence(timeout: 8), app.debugDescription)
        // Empty space beside the cover has the same dismiss gesture.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.35))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.84)))
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: mini)
        waitForExpectations(timeout: 8)
    }

    func testQueueAndHistoryLongPressMenusEditRealEntries() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-history", "--sonora-review-url",
            "sonora://queuereview?id=jfKfPfyJRdk&title=Sonora%20Menu%20Interaction&artist=Sonora"]
        app.launch()
        XCTAssertTrue(app.buttons["queue-add-songs"].waitForExistence(timeout: 30))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue-row-"))
        XCTAssertEqual(rows.count, 2)
        let second = rows.element(boundBy: 1).identifier
        app.buttons[second].coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1)
        let next = app.buttons["Play Next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 8), app.debugDescription)
        next.tap()
        expectation(for: NSPredicate { _, _ in rows.element(boundBy: 0).identifier == second }, evaluatedWith: app)
        waitForExpectations(timeout: 15)
        app.buttons[second].coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1)
        let remove = app.buttons["Remove from Queue"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 8))
        remove.tap(); waitForQueueCount(1, rows: rows)
        let list = app.collectionViews["player-queue-list"]
        list.swipeDown(); list.swipeDown()
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history-row-"))
        guard let past = history.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("No visible history entry: " + app.debugDescription); return
        }
        let pastID = past.identifier
        past.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1)
        let clear = app.buttons["Remove from History"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 8), app.debugDescription)
        clear.tap()
        expectation(for: NSPredicate { _, _ in !app.buttons[pastID].exists }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        list.swipeDown(); list.swipeDown()
        guard let replay = history.allElementsBoundByIndex.first(where: { $0.isHittable && !$0.identifier.hasSuffix("-8") }) else {
            XCTFail("No visible earlier history entry"); return
        }
        replay.tap()
    }

    func testLocalPlaylistRenameThroughItsMenu() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-url", "sonora://localplaylistreview"]
        app.launch()
        XCTAssertTrue(app.buttons["playlist-more"].waitForExistence(timeout: 30))
        app.buttons["playlist-more"].tap()
        XCTAssertTrue(app.buttons["Rename Playlist"].waitForExistence(timeout: 5))
        app.buttons["Rename Playlist"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let value = field.value as? String {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText("Sonora Touch Playlist")
        app.alerts.buttons["Save"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sonora Touch Playlist"].firstMatch.waitForExistence(timeout: 10))
    }

    func testCollectionCoversOpenAndReturnWithNativeToolbarActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-url", "sonora://collectionreview"]
        app.launch()
        let recentAlbum = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-recent-album-")).firstMatch
        XCTAssertTrue(recentAlbum.waitForExistence(timeout: 30), app.debugDescription)
        let library = app.collectionViews["library-main-list"]
        if !recentAlbum.isHittable { library.swipeUp() }
        recentAlbum.tap()
        XCTAssertTrue(app.collectionViews["album-track-list"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Sonora Review Tone"].firstMatch.exists)
        navigateBack(in: app)
        let recentPlaylist = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "library-recent-playlist-")).firstMatch
        XCTAssertTrue(recentPlaylist.waitForExistence(timeout: 10))
        if !recentPlaylist.isHittable { library.swipeUp() }
        recentPlaylist.tap()
        XCTAssertTrue(app.collectionViews["playlist-track-list"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["playlist-more"].isHittable)
        app.buttons["playlist-more"].tap()
        XCTAssertTrue(app.buttons["Rename Playlist"].waitForExistence(timeout: 8))
        // Close the menu by touching outside its surface, then use the native back control.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.55)).tap()
        navigateBack(in: app)
        XCTAssertTrue(app.buttons["library-edit"].waitForExistence(timeout: 8))
        app.buttons["library-edit"].tap()
        XCTAssertTrue(app.buttons["library-edit-done"].waitForExistence(timeout: 8))
        app.buttons["library-edit-done"].tap()
    }

    func testDownloadedTimedLyricsSurviveCacheClearAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-seek", "--sonora-review-url", "sonora://downloadlyricsreview"]
        app.launch()
        XCTAssertTrue(app.buttons["player-lyrics"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ready offline")).firstMatch.waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--sonora-review-seek", "--sonora-review-offline", "--sonora-review-url", "sonora://downloadlyricsrestore"]
        app.launch()
        XCTAssertTrue(app.buttons["player-lyrics"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ready offline")).firstMatch.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ready offline")).firstMatch.tap()
        let clock = app.staticTexts["player-native-clock"]
        expectation(for: NSPredicate { _, _ in
            let elapsed = Double(clock.label) ?? 0
            return elapsed > 3.5 && elapsed < 8
        }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
    }

    func testDownloadedCategoriesUseSavedMusic() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-url", "sonora://downloadsreview"]
        app.launch()
        XCTAssertTrue(app.buttons["download-songs"].waitForExistence(timeout: 30))
        app.buttons["download-songs"].tap()
        let list = app.collectionViews["downloaded-songs-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertTrue(list.staticTexts["Sonora Review Tone"].firstMatch.waitForExistence(timeout: 10))
        list.swipeDown()
        expectation(for: NSPredicate { _, _ in app.searchFields.allElementsBoundByIndex.contains { $0.isHittable } }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        guard let search = app.searchFields.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("The pull-down search field is not visible"); return
        }
        search.tap()
        let missing = "zzNoMatchzz"
        search.typeText(missing)
        expectation(for: NSPredicate { _, _ in (search.value as? String) == missing }, evaluatedWith: app)
        waitForExpectations(timeout: 12)
        let emptyResult = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", missing)).firstMatch
        // Query separately: a combined predicate can spend its entire deadline taking several AX snapshots.
        XCTAssertTrue(emptyResult.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(emptyResult.isHittable)
        let previousResults = list.staticTexts.matching(identifier: "Sonora Review Tone").allElementsBoundByIndex
        XCTAssertFalse(previousResults.contains { $0.isHittable })
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: missing.count) + "Review")
        expectation(for: NSPredicate { _, _ in list.staticTexts["Sonora Review Tone"].firstMatch.isHittable }, evaluatedWith: app)
        waitForExpectations(timeout: 12)
        let cancel = app.buttons.matching(identifier: "Cancel").allElementsBoundByIndex.first { $0.isHittable }
        cancel?.tap()
        navigateBack(in: app)
        XCTAssertTrue(app.buttons["download-albums"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["download-albums"].tap()
        XCTAssertTrue(app.staticTexts["Sonora Review Album"].firstMatch.waitForExistence(timeout: 10))
        navigateBack(in: app)
        XCTAssertTrue(app.buttons["download-playlists"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["download-playlists"].tap()
        XCTAssertTrue(app.staticTexts["Sonora Saved Playlist"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Sonora Saved Playlist"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sonora Review Tone"].firstMatch.waitForExistence(timeout: 10))
    }

    /// The native leading navigation control remains visible while collection search is active.
    private func navigateBack(in app: XCUIApplication) {
        let candidates = app.navigationBars.buttons.allElementsBoundByIndex.filter { $0.isHittable }
        guard let back = candidates.min(by: { $0.frame.minX < $1.frame.minX }) else {
            XCTFail("No visible navigation control: " + app.debugDescription); return
        }
        back.tap()
    }

    func testArtworkSwipeSelectsAdjacentQueueOccurrences() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-url", "sonora://trackswipereview?id=jfKfPfyJRdk&title=Sonora%20Swipe%20First&artist=First%20Review%20Artist"]
        app.launch()
        let metadata = app.descendants(matching: .any).matching(identifier: "player-track-metadata").firstMatch
        XCTAssertTrue(metadata.waitForExistence(timeout: 30))
        XCTAssertTrue(metadata.label.contains("Sonora Swipe First"))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.32))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.32)))
        expectation(for: NSPredicate { _, _ in metadata.label.contains("Sonora Swipe Second") }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.56))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.86, dy: 0.56)))
        expectation(for: NSPredicate { _, _ in metadata.label.contains("Sonora Swipe First") }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["player-queue"].isHittable)
    }

    func testSeekSurfaceTapsAndDragsMoveNativeAudioClock() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-seek", "--sonora-review-url", "sonora://seekreview"]
        app.launch()
        let seek = app.descendants(matching: .any).matching(identifier: "player-seek").firstMatch
        XCTAssertTrue(seek.waitForExistence(timeout: 30))
        let clock = app.staticTexts["player-native-clock"]
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        expectation(for: NSPredicate { _, _ in (Double(clock.label) ?? 0) > 10 }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        seek.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: seek.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)))
        expectation(for: NSPredicate { _, _ in
            let value = Double(clock.label) ?? 0
            return value > 2 && value < 7
        }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
    }

    func testLibraryEditingStaysInlineAndPersistsSelection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-url", "sonora://libraryreview"]
        app.launch()
        let edit = app.buttons["library-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        let library = app.collectionViews["library-main-list"]
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        let destination = library.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "library-destination-pinned", "Pinned")).firstMatch
        let wasSelected = destination.exists
        edit.tap()
        let pinned = app.cells.containing(.any, identifier: "library-category-pinned").firstMatch
        XCTAssertTrue(pinned.waitForExistence(timeout: 8))
        pinned.tap()
        app.buttons["library-edit-done"].tap()
        expectation(for: NSPredicate { _, _ in destination.exists != wasSelected }, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        app.terminate(); app.launch()
        XCTAssertTrue(edit.waitForExistence(timeout: 30))
        XCTAssertEqual(destination.exists, !wasSelected, "Category visibility must persist across relaunch")
        edit.tap(); pinned.tap(); app.buttons["library-edit-done"].tap()
        library.swipeDown()
        XCTAssertFalse(app.searchFields.allElementsBoundByIndex.contains { $0.isHittable })
    }

    func testQueueHistoryKeepsPlaybackControlsAvailable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-history", "--sonora-review-url",
            "sonora://queuereview?id=jfKfPfyJRdk&title=Sonora%20History%20Interaction&artist=Sonora"]
        app.launch()
        XCTAssertTrue(app.buttons["queue-add-songs"].waitForExistence(timeout: 30))
        let queue = app.collectionViews["player-queue-list"]
        XCTAssertTrue(queue.exists)
        queue.swipeDown()
        let clear = app.buttons["queue-clear-history"]
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: clear)
        waitForExpectations(timeout: 8)
        queue.swipeDown()
        queue.swipeDown()
        XCTAssertTrue(clear.isHittable)
        XCTAssertTrue(app.buttons["player-previous"].isHittable)
        expectation(for: NSPredicate(format: "hittable == false"), evaluatedWith: app.buttons["player-return-artwork"])
        waitForExpectations(timeout: 8)
        clear.tap()
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: app.buttons["player-return-artwork"])
        waitForExpectations(timeout: 8)
    }

    func testQueueReorderSwipeAddAndClear() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--sonora-review-url", "sonora://queuereview?id=jfKfPfyJRdk&title=Sonora%20Queue%20Interaction&artist=Sonora"]
        app.launch()
        XCTAssertTrue(app.buttons["queue-add-songs"].waitForExistence(timeout: 30))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue-row-"))
        XCTAssertEqual(rows.count, 2)
        let firstID = rows.element(boundBy: 0).identifier
        let secondID = rows.element(boundBy: 1).identifier
        let firstCell = app.cells.containing(.button, identifier: firstID).firstMatch
        let secondCell = app.cells.containing(.button, identifier: secondID).firstMatch
        XCTAssertTrue(firstCell.exists && secondCell.exists)
        firstCell.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5))
            .press(forDuration: 0.8, thenDragTo: secondCell.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)))
        let moved = NSPredicate { _, _ in
            app.buttons[secondID].exists && app.buttons[firstID].exists &&
            app.buttons[secondID].frame.minY < app.buttons[firstID].frame.minY
        }
        expectation(for: moved, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        app.buttons[firstID].swipeLeft()
        let remove = app.buttons["Remove from Queue"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        waitForQueueCount(1, rows: rows)
        app.buttons["queue-add-songs"].tap()
        XCTAssertTrue(app.buttons["queue-picker-confirm"].waitForExistence(timeout: 5))
        let choices = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "queue-picker-song-"))
        let visibleChoice = NSPredicate { _, _ in choices.allElementsBoundByIndex.contains { $0.isHittable } }
        expectation(for: visibleChoice, evaluatedWith: app)
        waitForExpectations(timeout: 8)
        guard let choice = choices.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            XCTFail("The Add Songs sheet has no hittable song row")
            return
        }
        choice.tap()
        XCTAssertTrue(app.buttons["queue-picker-confirm"].isEnabled)
        app.buttons["queue-picker-confirm"].tap()
        XCTAssertTrue(app.buttons["queue-clear"].waitForExistence(timeout: 5))
        waitForQueueCount(2, rows: rows)
        app.buttons["queue-clear"].tap()
        waitForQueueCount(0, rows: rows)
    }

    /// Native list removal/insertion completes asynchronously; assert the resulting row count.
    private func waitForQueueCount(_ count: Int, rows: XCUIElementQuery) {
        expectation(for: NSPredicate { _, _ in rows.count == count }, evaluatedWith: rows)
        waitForExpectations(timeout: 8)
    }
}
