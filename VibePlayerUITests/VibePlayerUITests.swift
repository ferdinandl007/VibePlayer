import XCTest

final class VibePlayerUITests: XCTestCase {
    var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
    }
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testRadioPlayerAndSoundEditors() throws {
        XCTAssertTrue(app.staticTexts["Radio"].waitForExistence(timeout: 20))
        capture("Radio")
        app.buttons["station-Joyful Pop"].tap()
        XCTAssertTrue(app.buttons["Add"].waitForExistence(timeout: 10))
        capture("Player")
        app.buttons["Add"].tap()
        XCTAssertTrue(app.navigationBars["Shape your sound"].waitForExistence(timeout: 5))
        capture("Sound picker")
        app.buttons["Instruments"].tap()
        XCTAssertTrue(app.buttons["Piano"].waitForExistence(timeout: 5))
        app.buttons["Voice"].tap()
        XCTAssertTrue(app.buttons["Instrumental"].waitForExistence(timeout: 5))
        app.buttons["Moods"].tap()
        XCTAssertTrue(app.buttons["Dreamy"].waitForExistence(timeout: 5))
        app.buttons["Dreamy"].tap()
        app.buttons["Done"].tap()
        let dreamy = app.descendants(matching: .any).matching(identifier: "sound-control-cloud.moon.fill-Dreamy").firstMatch
        XCTAssertTrue(dreamy.waitForExistence(timeout: 5))
        capture("Direct sound sliders")
        let start = dreamy.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        let finish = dreamy.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: finish)
        let intensityValue = String(describing: dreamy.value ?? "")
        let intensityNumber = Int(intensityValue.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? -1
        XCTAssertTrue((20...40).contains(intensityNumber), "Unexpected intensity after drag: \(intensityValue)")
        let tempo = app.descendants(matching: .any).matching(identifier: "tempo-control").firstMatch
        XCTAssertTrue(tempo.waitForExistence(timeout: 5))
        let tempoStart = tempo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let tempoEnd = tempo.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        tempoStart.press(forDuration: 0.1, thenDragTo: tempoEnd)
        let tempoValue = String(describing: tempo.value ?? "")
        let tempoNumber = Int(tempoValue.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? -1
        XCTAssertTrue((145...165).contains(tempoNumber), "Unexpected tempo after drag: \(tempoValue)")
        XCTAssertFalse(app.buttons["Like and save song"].isEnabled)
        app.buttons["Sleep timer"].tap()
        XCTAssertTrue(app.buttons["15 minutes"].waitForExistence(timeout: 5))
        app.buttons["15 minutes"].tap()
        app.buttons["player-playback"].tap()
        XCTAssertEqual(app.buttons["player-playback"].label, "Pause")
        app.buttons["player-playback"].tap()
        app.buttons["Close player"].tap()
        XCTAssertTrue(app.staticTexts["Radio"].waitForExistence(timeout: 5))
    }
    func testCustomSoundsAndPickerCancellation() throws {
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        app.buttons["Add"].tap()
        let sections = app.scrollViews["sound-sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 10))
        sections.swipeLeft()
        let textures = app.buttons["Textures"]
        if !textures.isHittable { sections.swipeLeft() }
        textures.tap()
        XCTAssertTrue(app.buttons["Airy"].waitForExistence(timeout: 5))
        let lyrics = app.buttons["Lyrics"]
        for _ in 0..<4 where !lyrics.isHittable { sections.swipeLeft() }
        XCTAssertTrue(lyrics.isHittable)
        lyrics.tap()
        XCTAssertTrue(app.buttons["Poetic"].waitForExistence(timeout: 5))
        app.buttons["Poetic"].tap(); app.buttons["Poetic"].tap()
        for _ in 0..<4 where !textures.isHittable { sections.swipeRight() }
        XCTAssertTrue(textures.isHittable)
        textures.tap()
        let term = "Glow " + String(UUID().uuidString.prefix(5))
        let field = app.textFields["sound-search"]
        field.tap(); field.typeText(term)
        XCTAssertTrue(app.buttons["add-custom-sound"].waitForExistence(timeout: 5))
        app.buttons["add-custom-sound"].tap()
        app.navigationBars["Shape your sound"].buttons["Done"].tap()
        let slider = app.descendants(matching: .any).matching(identifier: "sound-control-waveform.path-" + term).firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        let from = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        let to = slider.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to)
        let displayed = String(describing: slider.value ?? "")
        let number = Int(displayed.split(whereSeparator: { !$0.isNumber }).first ?? "") ?? -1
        XCTAssertTrue((25...45).contains(number), "Unexpected custom intensity: \(displayed)")
        app.buttons["Add"].tap()
        let sectionsAgain = app.scrollViews["sound-sections"]
        sectionsAgain.swipeLeft()
        if !app.buttons["Textures"].isHittable { sectionsAgain.swipeLeft() }
        app.buttons["Textures"].tap()
        let searchAgain = app.textFields["sound-search"]
        searchAgain.tap(); searchAgain.typeText(term)
        XCTAssertTrue(app.buttons[term].waitForExistence(timeout: 5))
        app.buttons[term].tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(slider.exists, "Cancel should keep the previously saved slider")
    }
    func testCreateAndLibrary() throws {
        app.tabBars.buttons["Create"].tap()
        XCTAssertTrue(app.textViews["song-prompt"].waitForExistence(timeout: 10))
        capture("Create")
        let prompt = app.textViews["song-prompt"]
        prompt.tap(); prompt.typeText("Moonlight drive")
        app.buttons["edit-styles"].tap()
        XCTAssertTrue(app.textViews["styles-editor"].waitForExistence(timeout: 5))
        capture("Styles editor")
        app.buttons["mellow"].tap()
        app.buttons["Done"].tap()
        app.buttons["edit-lyrics"].tap()
        let lyrics = app.textViews["lyrics-editor"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap(); lyrics.typeText("Under the moonlight")
        capture("Lyrics editor")
        app.buttons["Done"].tap()
        app.buttons["Create options"].tap()
        app.buttons["Save idea"].tap()
        XCTAssertTrue(app.staticTexts["idea-saved"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Moonlight drive"].waitForExistence(timeout: 5))
        capture("Library")
        app.staticTexts["Moonlight drive"].tap()
        XCTAssertTrue(app.staticTexts["Moonlight drive"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["mellow"].exists)
        XCTAssertTrue(app.staticTexts["Under the moonlight"].exists)
        capture("Song idea")
    }
    func testSongwritingSettings() throws {
        app.tabBars.buttons["Create"].tap()
        let options = app.buttons["Create options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        app.buttons["Songwriting settings"].tap()
        XCTAssertTrue(app.secureTextFields["gemini-api-key"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Songwriting"].exists)
        app.buttons["Done"].tap()
    }
    func testAudioImportPicker() throws {
        app.tabBars.buttons["Library"].tap()
        let importButton = app.buttons["Import audio"]
        if !importButton.isHittable { app.swipeUp() }
        XCTAssertTrue(importButton.waitForExistence(timeout: 10))
        importButton.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 35))
        capture("Audio file picker")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Your vibes"].waitForExistence(timeout: 5))
    }
    func testRadioSongCanBeSavedAndSurvivesRelaunch() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        app.buttons["player-playback"].tap()
        let like = app.buttons["Like and save song"]
        let enabled = NSPredicate(format: "enabled == true")
        expectation(for: enabled, evaluatedWith: like)
        waitForExpectations(timeout: 20)
        like.tap()
        XCTAssertTrue(app.buttons["Saved to library"].waitForExistence(timeout: 5))
        let ready = app.staticTexts["radio-ready-count"]
        let twoReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "2 ready"), object: ready)
        XCTAssertEqual(XCTWaiter.wait(for: [twoReady], timeout: 10), .completed)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "radio-queued-track").count, 2)
        capture("Radio playback and ready queue")
        app.buttons["Forward 15 seconds"].tap()
        XCTAssertTrue(app.buttons["Like and save song"].waitForExistence(timeout: 15), "Radio should advance to the prepared next song")
        app.buttons["Close player"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Lofi Beats"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--fixture-renderer"]
        app.launch()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Lofi Beats"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Song options"].exists)
    }
    func testSwipeDownClosesRadioPlayer() throws {
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        let handle = app.buttons["player-dismiss-handle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 10))
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = start.withOffset(CGVector(dx: 0, dy: 250))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.staticTexts["Radio"].waitForExistence(timeout: 5))
    }
    func testAdaptiveRadioPlayer() throws {
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        XCTAssertTrue(app.buttons["player-dismiss-handle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Add"].exists)
        XCTAssertTrue(app.buttons["player-playback"].exists)
        capture("Adaptive radio player")
        app.buttons["player-dismiss-handle"].tap()
        XCTAssertTrue(app.staticTexts["Radio"].waitForExistence(timeout: 5))
    }
    func testIPadSystemNavigation() throws {
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        capture("iPad system navigation")
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        create.tap()
        XCTAssertTrue(app.textViews["song-prompt"].waitForExistence(timeout: 5))
        app.buttons["Library"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5))
        app.buttons["Radio"].firstMatch.tap()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 5))
    }
    func testSavedSongUsesTrackPlayer() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        app.buttons["player-playback"].tap()
        let like = app.buttons["Like and save song"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: like)
        waitForExpectations(timeout: 20)
        like.tap()
        app.buttons["Close player"].tap()
        app.tabBars.buttons["Library"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Lofi Beats")).firstMatch.tap()
        XCTAssertTrue(app.otherElements["single-track-player"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.sliders["Playback position"].exists)
        XCTAssertTrue(app.otherElements["track-artwork"].exists)
        XCTAssertFalse(app.buttons["Add"].exists)
        capture("Single track player")
        let handle = app.buttons["player-dismiss-handle"]
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 250)))
        XCTAssertTrue(app.staticTexts["Library"].waitForExistence(timeout: 5))
    }
    func testPromptedSongIsSaved() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer", "--fixture-full-context-audio"]
        app.launch()
        app.tabBars.buttons["Create"].tap()
        let prompt = app.textViews["song-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 15))
        prompt.tap(); prompt.typeText("A bright new day")
        app.buttons["edit-lyrics"].tap()
        let lyrics = app.textViews["lyrics-editor"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap(); lyrics.typeText("Here comes the morning")
        app.buttons["Done"].tap()
        app.buttons["create-song"].tap()
        app.buttons["open-generation-progress"].tap()
        XCTAssertTrue(app.staticTexts["Whole-song synthesis · step 1 of 8"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Playing while rendering"].waitForExistence(timeout: 8))
        app.buttons["Close generation progress"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Song options"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["A bright new day"].exists)
    }
    func testCreatePlaysBeforeSavingAndThenFinishes() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer", "--fixture-early-audio"]
        app.launch()
        app.tabBars.buttons["Create"].tap()
        app.buttons["Create options"].tap()
        let earlyPlayback = app.buttons["Early playback"].firstMatch
        if !earlyPlayback.exists { app.buttons["Rendering"].tap() }
        XCTAssertTrue(earlyPlayback.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["High quality"].exists)
        earlyPlayback.tap()
        app.buttons["A hazy late-night drive"].tap()
        app.buttons["edit-lyrics"].tap()
        let lyrics = app.textViews["lyrics-editor"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap(); lyrics.typeText("Here comes the morning")
        app.buttons["Done"].tap()
        app.buttons["create-song"].tap()
        let progress = app.buttons["open-generation-progress"]
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["A little atmosphere"].exists)
        capture("Create playback and rendering in one dock")
        progress.tap()
        XCTAssertTrue(app.staticTexts["Generation queue"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Playing while rendering"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["cancel-creation"].isHittable)
        capture("Expanded generation progress")
        app.buttons["Add another prompt"].tap()
        app.buttons["Warm piano on a rainy day"].tap()
        app.buttons["edit-lyrics"].tap()
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap(); lyrics.typeText("Rain on the window")
        app.buttons["Done"].tap()
        let enqueue = app.buttons["queue-create-song"]
        XCTAssertTrue(enqueue.isHittable)
        enqueue.tap()
        progress.tap()
        XCTAssertTrue(app.staticTexts["Up next"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Warm piano on a rainy day"].exists)
        capture("Expanded progress with a queued prompt")
        app.buttons["Close generation progress"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["A hazy late-night drive"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Warm piano on a rainy day"].waitForExistence(timeout: 15))
    }
    func testCreateDockStaysReachableWithKeyboard() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        let createTab = app.tabBars.buttons["Create"]
        (createTab.exists ? createTab : app.buttons["Create"].firstMatch).tap()
        let prompt = app.textViews["song-prompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 8))
        prompt.tap()
        prompt.typeText("Soft drums and a low piano")
        XCTAssertTrue(app.buttons["create-song"].isHittable)
        XCTAssertFalse(app.staticTexts["A little atmosphere"].exists)
        capture("Create with keyboard and one dock")
    }
    func testRadioWaitsBetweenTracksAndResumesAutomatically() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer", "--fixture-radio-gap"]
        app.launch()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        let loading = app.descendants(matching: .any)["radio-loading"].firstMatch
        app.buttons["player-playback"].tap()
        for state in ["Waiting for audio", "Preparing in the background", "Waiting for audio", "Preparing in the background"] {
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", state), object: loading)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
        }
    }
    func testTempoChangeReplacesThePlayingRadioSong() throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--fixture-renderer"]
        app.launch()
        XCTAssertTrue(app.buttons["open-current-station"].waitForExistence(timeout: 20))
        app.buttons["open-current-station"].tap()
        app.buttons["player-playback"].tap()
        let like = app.buttons["Like and save song"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: like)
        waitForExpectations(timeout: 20)
        like.tap()
        XCTAssertTrue(app.buttons["Saved to library"].waitForExistence(timeout: 5))

        let tempo = app.descendants(matching: .any).matching(identifier: "tempo-control").firstMatch
        XCTAssertTrue(tempo.exists)
        let start = tempo.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let end = tempo.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)

        XCTAssertTrue(like.waitForExistence(timeout: 8), "The changed tempo should produce a replacement song during playback")
        XCTAssertEqual(app.buttons["player-playback"].label, "Pause")
    }
    func testCreateCustomStation() throws {
        XCTAssertTrue(app.buttons["New station"].waitForExistence(timeout: 15))
        app.buttons["New station"].tap()
        let name = app.alerts["New station"].textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Night Drive")
        app.alerts["New station"].buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Night Drive"].waitForExistence(timeout: 5))
    }
    func testLandscapeNavigation() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.staticTexts["Radio"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Create"].tap()
        XCTAssertTrue(app.textViews["song-prompt"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Your vibes"].waitForExistence(timeout: 5))
    }
}
