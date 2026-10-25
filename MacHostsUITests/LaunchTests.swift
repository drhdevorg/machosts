import XCTest

final class LaunchTests: XCTestCase {
  @MainActor
  func testLaunchShowsUnavailableSystemIntegration() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.staticTexts["systemApplyUnavailable"].waitForExistence(timeout: 10))
    app.terminate()
  }
}
