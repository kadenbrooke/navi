import XCTest
@testable import PetCore

final class IdleNotificationAuthorizationTests: XCTestCase {
    private let alert = IdleAlert(id: "thread-1", name: "Navi collector")

    func testPostBeforePrepareQueuesAlertAndRequestsAuthorization() {
        var authorization = IdleNotificationAuthorization()

        let actions = authorization.post(alert)

        XCTAssertEqual(actions, [.requestAuthorization])
        XCTAssertEqual(authorization.state, .requesting)
        XCTAssertEqual(authorization.pendingAlert, alert)
    }

    func testDeniedAuthorizationDropsQueuedAlertWithoutRequeueOrDoublePost() {
        var authorization = IdleNotificationAuthorization()
        XCTAssertEqual(authorization.post(alert), [.requestAuthorization])

        XCTAssertEqual(authorization.resolve(authorized: false), [.drop(alert)])
        XCTAssertEqual(authorization.state, .denied)
        XCTAssertNil(authorization.pendingAlert)
        XCTAssertEqual(authorization.resolve(authorized: false), [])
        XCTAssertEqual(authorization.post(alert), [.drop(alert)])
        XCTAssertEqual(authorization.state, .denied)
        XCTAssertNil(authorization.pendingAlert)
    }

    func testAuthorizedQueuedAlertIsDeliveredExactlyOnce() {
        var authorization = IdleNotificationAuthorization()
        XCTAssertEqual(authorization.post(alert), [.requestAuthorization])

        XCTAssertEqual(authorization.resolve(authorized: true), [.deliver(alert)])
        XCTAssertEqual(authorization.state, .authorized)
        XCTAssertNil(authorization.pendingAlert)
        XCTAssertEqual(authorization.resolve(authorized: true), [])
    }
}
