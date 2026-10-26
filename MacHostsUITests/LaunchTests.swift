import XCTest

final class LaunchTests: XCTestCase {
  override func setUp() {
    super.setUp()
    // No editing may follow a failed assertion of the private-workspace marker.
    continueAfterFailure = false
  }

  @MainActor
  private func launchPrivateWorkspace(damaged: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing-local-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
    ]
    if damaged { app.launchArguments.append("--ui-testing-damaged-workspace") }
    app.launch()
    app.activate()
    let privateWorkspaceVisible = app.staticTexts["privateTestWorkspace"].waitForExistence(
      timeout: 10)
    if !privateWorkspaceVisible { app.terminate() }
    XCTAssertTrue(privateWorkspaceVisible)
    return app
  }

  @MainActor
  func testLaunchShowsUnavailableSystemIntegration() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["systemApplyUnavailable"].exists)
  }

  @MainActor
  func testTextExchangeOpensWithoutMutatingDraft() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 5)
    create.click()
    let source = app.textViews["profileSource"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.click()
    source.typeText("192.0.2.41 exchange.example\n")
    app.buttons["textExchange"].click()
    XCTAssertTrue(app.buttons["chooseHostsImport"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["exportHostsText"].isEnabled)
    app.buttons["Done"].click()
    XCTAssertEqual(source.value as? String, "192.0.2.41 exchange.example\n")
    XCTAssertEqual(app.checkBoxes["profileEnabled"].value as? Int, 0)
  }

  @MainActor
  func testFilteredEntryBulkActionsPreserveOtherSource() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 5)
    create.click()
    let source = app.textViews["profileSource"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    let original = "# ordinary comment\n192.0.2.1 staging.example alias\n192.0.2.2 other.example\n"
    source.click()
    source.typeText(original)
    app.disclosureTriangles["Entry switches"].click()
    let filter = app.textFields["entryFilter"]
    XCTAssertTrue(filter.waitForExistence(timeout: 5))
    filter.click()
    filter.typeText("ALIAS")
    app.buttons["disableMatchingEntries"].click()
    let disabled =
      "# ordinary comment\n# machosts-disabled: 192.0.2.1 staging.example alias\n192.0.2.2 other.example\n"
    XCTAssertEqual(source.value as? String, disabled)
    app.buttons["entrySourceLocation"].firstMatch.click()
    XCTAssertEqual(source.value as? String, disabled)
    app.buttons["enableMatchingEntries"].click()
    XCTAssertEqual(source.value as? String, original)
    XCTAssertEqual(app.checkBoxes["profileEnabled"].value as? Int, 0)
    XCTAssertTrue(app.staticTexts["Not applied to the system."].exists)
  }

  @MainActor
  func testProfileActionsDuplicateSelectAndTrashUsingMenus() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 5)
    create.click()
    let source = app.textViews["profileSource"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.click()
    source.typeText("192.0.2.41 actions.example\n")
    app.checkBoxes["profileEnabled"].click()
    app.menuBars.menuBarItems["Profiles"].click()
    app.menuItems["Duplicate as local profile"].click()
    XCTAssertEqual(app.checkBoxes["profileEnabled"].value as? Int, 0)
    XCTAssertEqual(source.value as? String, "192.0.2.41 actions.example\n")
    source.click()
    source.typeKey("a", modifierFlags: .command)
    source.typeText("192.0.2.42 copy.example\n")
    app.menuBars.menuBarItems["Profiles"].click()
    app.menuItems["Move to trash"].click()
    XCTAssertFalse(app.textViews["profileSource"].exists)
    app.menuBars.menuBarItems["Profiles"].click()
    XCTAssertFalse(app.menuItems["Duplicate as local profile"].isEnabled)
    app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    app.buttons["Trash"].click()
    XCTAssertTrue(app.staticTexts["Trash"].firstMatch.waitForExistence(timeout: 5))
  }

  @MainActor
  func testWorkspaceMenusRouteSearchAndPreview() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 5)
    app.typeKey("n", modifierFlags: .command)
    let source = app.textViews["profileSource"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.click()
    source.typeText("192.0.2.19 menu.example\n")
    // Find commands move focus from a different text field into the selected editor.
    app.textFields["profileName"].click()
    app.typeKey("f", modifierFlags: .command)
    XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(source.value as? String, "192.0.2.19 menu.example\n")
    app.typeKey("f", modifierFlags: [.command, .shift])
    app.textFields["profileSearch"].typeText("menu.example")
    XCTAssertTrue(app.buttons["profileSearchHit"].firstMatch.waitForExistence(timeout: 5))
    app.typeKey("p", modifierFlags: [.command, .shift])
    XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.sheets.firstMatch.staticTexts[
        "A readable system file and writable workspace are required. Check the system file status."
      ].waitForExistence(timeout: 5))
    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(app.sheets.firstMatch.exists)
    app.buttons["Done"].click()
    XCTAssertEqual(source.value as? String, "192.0.2.19 menu.example\n")
  }

  @MainActor
  func testWindowsKeepIndependentProfileSelections() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"].firstMatch
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 5)
    create.click()
    let source = app.textViews["profileSource"].firstMatch
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.click()
    source.typeText("192.0.2.31 first-window.example\n")
    app.typeKey("n", modifierFlags: [.command, .shift])
    expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: app.windows)
    waitForExpectations(timeout: 5)
    // A new window starts without taking the existing window's selection.
    XCTAssertEqual(app.textViews.matching(identifier: "profileSource").count, 1)
    app.typeKey("n", modifierFlags: .command)
    expectation(
      for: NSPredicate(format: "count == 2"),
      evaluatedWith: app.textViews.matching(identifier: "profileSource"))
    waitForExpectations(timeout: 5)
    let emptySource = app.textViews.matching(
      NSPredicate(format: "identifier == 'profileSource' AND value == ''")
    ).firstMatch
    XCTAssertTrue(emptySource.waitForExistence(timeout: 5))
    emptySource.click()
    emptySource.typeText("192.0.2.32 second-window.example\n")
    let firstSource = app.textViews.matching(
      NSPredicate(
        format: "identifier == 'profileSource' AND value == %@",
        "192.0.2.31 first-window.example\n")
    ).firstMatch
    XCTAssertTrue(firstSource.waitForExistence(timeout: 5))
    let secondSource = app.textViews.matching(
      NSPredicate(
        format: "identifier == 'profileSource' AND value == %@",
        "192.0.2.32 second-window.example\n")
    ).firstMatch
    XCTAssertTrue(secondSource.exists)
    firstSource.click()
    firstSource.typeKey("a", modifierFlags: .command)
    firstSource.typeText("192.0.2.33 changed-first.example\n")
    XCTAssertEqual(secondSource.value as? String, "192.0.2.32 second-window.example\n")
    app.typeKey("s", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["draftSaved"].firstMatch.waitForExistence(timeout: 5))
  }

  @MainActor
  func testLocalProfileEditingDiagnosticsAndTrashRestore() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"]
    XCTAssertTrue(create.waitForExistence(timeout: 5))
    let enabled = NSPredicate(format: "enabled == true")
    expectation(for: enabled, evaluatedWith: create)
    waitForExpectations(timeout: 5)
    create.click()
    let name = app.textFields["profileName"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.click()
    name.typeKey("a", modifierFlags: .command)
    name.typeText("UI fixture")
    app.buttons["Rename"].click()
    let source = app.textViews["profileSource"]
    source.click()
    source.typeText("invalid input")
    XCTAssertTrue(app.scrollViews["profileDiagnostics"].waitForExistence(timeout: 5))
    source.typeKey("a", modifierFlags: .command)
    source.typeText("192.0.2.5 ui.example\n")
    app.checkBoxes["profileEnabled"].click()
    app.typeKey("s", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["draftSaved"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Not applied to the system."].exists)
    app.staticTexts["UI fixture"].firstMatch.rightClick()
    app.menuItems["Move to trash"].click()
    XCTAssertFalse(app.textFields["profileName"].exists)
    app.buttons["Trash"].click()
    let restore = app.buttons["Restore inactive"]
    XCTAssertTrue(restore.waitForExistence(timeout: 5))
    restore.click()
    app.buttons["Done"].click()
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertEqual(source.value as? String, "192.0.2.5 ui.example\n")
    XCTAssertEqual(app.checkBoxes["profileEnabled"].value as? Int, 0)
    XCTAssertTrue(app.staticTexts["systemApplyUnavailable"].exists)
  }
  @MainActor
  func testFoldersMoveAndRemoveWithoutLosingProfile() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 5)
    create.click()
    let source = app.textViews["profileSource"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.click()
    source.typeText("192.0.2.7 folder.example\n")
    app.checkBoxes["profileEnabled"].click()
    app.buttons["manageFolders"].click()
    let folderName = app.textFields["newFolderName"]
    XCTAssertTrue(folderName.waitForExistence(timeout: 5))
    folderName.click()
    folderName.typeText("Fixture folder")
    app.buttons["createFolder"].click()
    XCTAssertTrue(app.textFields["folderName"].waitForExistence(timeout: 5))
    app.buttons["Done"].click()
    app.staticTexts["New profile"].firstMatch.rightClick()
    app.menuItems["Move to folder"].click()
    app.menuItems["Fixture folder"].click()
    XCTAssertEqual(source.value as? String, "192.0.2.7 folder.example\n")
    XCTAssertEqual(app.checkBoxes["profileEnabled"].value as? Int, 1)
    app.buttons["manageFolders"].click()
    app.sheets.firstMatch.staticTexts["Fixture folder"].firstMatch.click()
    app.buttons["Remove folder, keep profiles"].click()
    app.buttons["Done"].click()
    XCTAssertEqual(source.value as? String, "192.0.2.7 folder.example\n")
    XCTAssertEqual(app.checkBoxes["profileEnabled"].value as? Int, 1)
    app.typeKey("s", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["draftSaved"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testSearchSelectsNativeTextAndKeepsUndo() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 5)
    create.click()
    let source = app.textViews["profileSource"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.click()
    source.typeText("# comment\n192.0.2.8 ui.example\n")
    app.typeKey("f", modifierFlags: [.command, .shift])
    let search = app.textFields["profileSearch"]
    search.typeText("UI.EXAMPLE")
    let hit = app.buttons["profileSearchHit"].firstMatch
    XCTAssertTrue(hit.waitForExistence(timeout: 5))
    hit.click()
    source.typeText("edited.example")
    XCTAssertEqual(source.value as? String, "# comment\n192.0.2.8 edited.example\n")
    source.typeKey("z", modifierFlags: .command)
    XCTAssertEqual(source.value as? String, "# comment\n192.0.2.8 ui.example\n")
    // Search switches to another editor identity; its undo must never touch the first profile.
    create.click()
    source.click()
    source.typeText("# second profile")
    source.typeKey("z", modifierFlags: .command)
    search.click()
    search.typeKey("a", modifierFlags: .command)
    search.typeText("ui.example")
    XCTAssertTrue(hit.waitForExistence(timeout: 5))
    hit.click()
    XCTAssertEqual(source.value as? String, "# comment\n192.0.2.8 ui.example\n")
  }

  @MainActor
  func testEditorLineNumbersFollowTextAndUndo() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 5)
    create.click()
    let source = app.textViews["profileSource"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.click()
    source.typeText("# comment\n192.0.2.9 color.example\n")
    let ruler = app.descendants(matching: .any)["profileLineNumbers"].firstMatch
    XCTAssertTrue(ruler.waitForExistence(timeout: 5))
    expectation(for: NSPredicate(format: "value == %@", "3"), evaluatedWith: ruler)
    waitForExpectations(timeout: 5)
    source.typeKey("a", modifierFlags: .command)
    source.typeText("invalid")
    XCTAssertTrue(app.scrollViews["profileDiagnostics"].waitForExistence(timeout: 5))
    source.typeKey("z", modifierFlags: .command)
    XCTAssertEqual(source.value as? String, "# comment\n192.0.2.9 color.example\n")
    source.typeKey("z", modifierFlags: [.command, .shift])
    XCTAssertEqual(source.value as? String, "invalid")
    app.typeKey("s", modifierFlags: .command)
    XCTAssertTrue(app.staticTexts["draftSaved"].waitForExistence(timeout: 5))
  }

  @MainActor
  func testTrashReviewPreservesTextAndRestoresInactive() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 5)
    create.click()
    let source = app.textViews["profileSource"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.click()
    source.typeText("# review\n192.0.2.18 archived.example\n")
    app.checkBoxes["profileEnabled"].click()
    app.staticTexts["New profile"].firstMatch.rightClick()
    app.menuItems["Move to trash"].click()
    app.buttons["Trash"].click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.staticTexts["New profile"].waitForExistence(timeout: 5))
    sheet.staticTexts["New profile"].click()
    let archivedSource = sheet.textViews["profileSource"]
    XCTAssertTrue(archivedSource.waitForExistence(timeout: 5))
    XCTAssertEqual(archivedSource.value as? String, "# review\n192.0.2.18 archived.example\n")
    sheet.buttons["Done"].click()
    // Closing the review does not restore a profile.
    XCTAssertFalse(app.textViews["profileSource"].exists)
    app.buttons["Trash"].click()
    sheet.textFields["trashSearch"].click()
    sheet.textFields["trashSearch"].typeText("missing")
    XCTAssertTrue(sheet.staticTexts["No matching deleted profiles."].exists)
    XCTAssertFalse(sheet.buttons["restoreTrashedProfile"].exists)
    sheet.textFields["trashSearch"].typeKey("a", modifierFlags: .command)
    sheet.textFields["trashSearch"].typeText("New profile")
    sheet.staticTexts["New profile"].firstMatch.click()
    sheet.buttons["restoreTrashedProfile"].click()
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    XCTAssertEqual(source.value as? String, "# review\n192.0.2.18 archived.example\n")
    XCTAssertEqual(app.checkBoxes["profileEnabled"].value as? Int, 0)
  }

  @MainActor
  func testPreviewSavesDraftAndRequiresObservedSystemContents() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    let create = app.buttons["newProfile"]
    expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: create)
    waitForExpectations(timeout: 5)
    create.click()
    let source = app.textViews["profileSource"]
    XCTAssertTrue(source.waitForExistence(timeout: 5))
    source.click()
    source.typeText("192.0.2.10 preview.example\n")
    app.checkBoxes["profileEnabled"].click()
    app.buttons["previewChanges"].click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(
      sheet.staticTexts[
        "A readable system file and writable workspace are required. Check the system file status."
      ].waitForExistence(timeout: 5))
    XCTAssertFalse(sheet.buttons["Apply"].exists)
    sheet.buttons["Done"].click()
    XCTAssertTrue(app.staticTexts["draftSaved"].waitForExistence(timeout: 5))
    XCTAssertEqual(source.value as? String, "192.0.2.10 preview.example\n")
    XCTAssertEqual(app.checkBoxes["profileEnabled"].value as? Int, 1)
    XCTAssertTrue(app.staticTexts["Not applied to the system."].exists)
  }

}

extension LaunchTests {
  @MainActor
  func testReviewAndRestoreDamagedLocalWorkspace() {
    let app = launchPrivateWorkspace(damaged: true)
    defer { app.terminate() }
    let review = app.buttons["reviewWorkspaceRecovery"]
    XCTAssertTrue(review.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["draftSaved"].exists)
    XCTAssertFalse(app.buttons["newProfile"].isEnabled)
    review.click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.staticTexts["Recovered fixture"].waitForExistence(timeout: 5))
    sheet.staticTexts["Recovered fixture"].click()
    let savedText = sheet.textViews.firstMatch
    XCTAssertTrue(savedText.waitForExistence(timeout: 5))
    XCTAssertEqual(savedText.value as? String, "192.0.2.23 recovery.example\n")
    sheet.buttons["Cancel"].click()
    XCTAssertTrue(review.exists)
    XCTAssertFalse(app.buttons["newProfile"].isEnabled)
    review.click()
    sheet.buttons["restorePreviousWorkspace"].click()
    XCTAssertTrue(app.staticTexts["draftSaved"].waitForExistence(timeout: 5))
    XCTAssertFalse(review.exists)
    XCTAssertTrue(app.buttons["newProfile"].isEnabled)
    app.staticTexts["Recovered fixture"].firstMatch.click()
    XCTAssertEqual(
      app.textViews["profileSource"].value as? String,
      "192.0.2.23 recovery.example\n")
    XCTAssertTrue(app.staticTexts["Not applied to the system."].exists)
  }
}
