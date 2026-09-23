import XCTest
@testable import PetCore

final class IdleNotificationAuthorizationTests: XCTestCase {
    private let alert = IdleAlert(id: "thread-1", name: "Navi collector")

    func testPostBeforePrepareQueuesAlertAndChecksCurrentSettings() {
        var authorization = IdleNotificationAuthorization()

        let actions = authorization.post(alert)

        XCTAssertEqual(actions, [.checkSettings])
        XCTAssertEqual(authorization.state, .checking)
        XCTAssertEqual(authorization.pendingAlert, alert)
    }

    func testDeniedAuthorizationDropsQueuedAlertWithoutRequeueOrDoublePost() {
        var authorization = IdleNotificationAuthorization()
        XCTAssertEqual(authorization.post(alert), [.checkSettings])

        XCTAssertEqual(authorization.resolveSettings(.denied), [.drop(alert)])
        XCTAssertEqual(authorization.state, .denied)
        XCTAssertNil(authorization.pendingAlert)
        XCTAssertEqual(authorization.resolve(authorized: false), [])
        XCTAssertEqual(authorization.post(alert), [.checkSettings])
        XCTAssertEqual(authorization.state, .checking)
        XCTAssertEqual(authorization.pendingAlert, alert)
    }

    func testAuthorizedQueuedAlertIsDeliveredExactlyOnce() {
        var authorization = IdleNotificationAuthorization()
        XCTAssertEqual(authorization.post(alert), [.checkSettings])
        XCTAssertEqual(authorization.resolveSettings(.notDetermined), [.requestAuthorization])

        XCTAssertEqual(authorization.resolve(authorized: true), [.deliver(alert)])
        XCTAssertEqual(authorization.state, .authorized)
        XCTAssertNil(authorization.pendingAlert)
        XCTAssertEqual(authorization.resolve(authorized: true), [])
    }

    func testDeniedStateCanBecomeAuthorizedAfterSystemSettingsChange() {
        var authorization = IdleNotificationAuthorization()
        XCTAssertEqual(authorization.prepare(), [.checkSettings])
        XCTAssertEqual(authorization.resolveSettings(.denied), [])
        XCTAssertEqual(authorization.state, .denied)

        XCTAssertEqual(authorization.prepare(), [.checkSettings])
        XCTAssertEqual(authorization.resolveSettings(.authorized), [])
        XCTAssertEqual(authorization.state, .authorized)
        XCTAssertEqual(authorization.post(alert), [.deliver(alert)])
    }
}
