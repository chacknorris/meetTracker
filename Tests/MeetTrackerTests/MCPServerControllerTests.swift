import XCTest
@testable import MeetTracker

@MainActor
final class MCPServerControllerTests: XCTestCase {
    func testPersistsAValidPortWhileDisabled() {
        let defaults = isolatedDefaults()
        let controller = MCPServerController(
            defaults: defaults,
            automaticallyStart: false
        )

        XCTAssertTrue(controller.setPort(4_321))
        XCTAssertEqual(controller.port, 4_321)

        let reloaded = MCPServerController(
            defaults: defaults,
            automaticallyStart: false
        )
        XCTAssertEqual(reloaded.port, 4_321)
    }

    func testRejectsAPortOutsideTheUserRange() {
        let controller = MCPServerController(
            defaults: isolatedDefaults(),
            automaticallyStart: false
        )

        XCTAssertFalse(controller.setPort(80))
        XCTAssertEqual(controller.port, 3_210)
        guard case let .failed(message) = controller.state else {
            return XCTFail("Se esperaba un estado de error")
        }
        XCTAssertTrue(message.contains("1024"))
    }

    func testLoadsEnabledPreferenceWithoutStartingDuringTests() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "mcpServerEnabled")

        let controller = MCPServerController(
            defaults: defaults,
            automaticallyStart: false
        )

        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.state, .stopped)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "MCPServerControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
