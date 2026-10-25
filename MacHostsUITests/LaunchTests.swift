import XCTest

final class LaunchTests: XCTestCase {
  override func setUp() {
    super.setUp()
    // No editing may follow a failed assertion of the private-workspace marker.
    continueAfterFailure = false
  }

  @MainActor
  private func launchPrivateWorkspace() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = [
      "--ui-testing-local-workspace", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
      "-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
    ]
    app.launch()
    app.activate()
    XCTAssertTrue(app.staticTexts["privateTestWorkspace"].waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  func testLaunchShowsUnavailableSystemIntegration() {
    let app = launchPrivateWorkspace()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["systemApplyUnavailable"].exists)
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

}
