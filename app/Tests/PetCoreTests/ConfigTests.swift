import XCTest
@testable import PetCore

final class ConfigTests: XCTestCase {
    func testDefaultsAreDesignDefaults() {
        let p = NaviParams()
        XCTAssertEqual(p.size, 7); XCTAssertEqual(p.glowRadius, 4); XCTAssertEqual(p.glowIntensity, 0.55)
        XCTAssertEqual(p.coreColor, "#fff8ad"); XCTAssertEqual(p.wingCount, 4); XCTAssertEqual(p.wingSpeed, 18.5)
        XCTAssertEqual(p.wingOpacity, 0.42); XCTAssertEqual(p.wingSize, 1)
        XCTAssertFalse(p.halo); XCTAssertFalse(p.ring); XCTAssertTrue(p.pixel); XCTAssertEqual(p.pixelSize, 3)
        XCTAssertEqual(p.bobAmp, 40); XCTAssertEqual(p.bobFreq, 0.25); XCTAssertEqual(p.followLag, 1)
        XCTAssertEqual(p.speed, 2.65); XCTAssertEqual(p.trailLength, 0.35); XCTAssertEqual(p.trailDensity, 11)
        XCTAssertEqual(p.trailSpread, 22); XCTAssertTrue(p.sound); XCTAssertEqual(p.sleepMin, 10)
    }

    /// A config JSON copied from the design playground (round-1 shape with `status`, no workflows).
    func testPlaygroundJSONLoadsStatusIgnored() throws {
        let pasted = ##"{"preset":"classic","mode":"follow","status":"pr","params":{"size":7,"glowRadius":4,"glowIntensity":0.55,"coreColor":"#fff8ad","wingCount":4,"wingSpeed":18.5,"wingOpacity":0.42,"wingSize":1,"halo":false,"ring":false,"pixel":true,"pixelSize":3,"geometric":false,"bobAmp":40,"bobFreq":0.25,"followLag":1,"orbitRadius":320,"speed":2.65,"trailLength":0.35,"trailDensity":11,"trailSpread":22,"sound":true}}"##
        let c = try NaviConfig.decode(Data(pasted.utf8))
        XCTAssertEqual(c.preset, "classic")
        XCTAssertEqual(c.mode, "follow")
        XCTAssertEqual(c.params.coreColor, "#fff8ad")
        XCTAssertEqual(c.params.sleepMin, 10, "missing key keeps default")
        XCTAssertEqual(c.menuSort, .recent)
    }

    func testFullShareBoxJSONWithWorkflowsAndSort() throws {
        let json = ##"{"preset":"navi","mode":"hover","menuSort":"status","params":{"size":12,"coreColor":"#00ff00","sleepMin":3},"workflows":[{"name":"x","state":"idle","changedAt":1}]}"##
        let c = try NaviConfig.decode(Data(json.utf8))
        XCTAssertEqual(c.params.size, 12)
        XCTAssertEqual(c.params.coreColor, "#00ff00")
        XCTAssertEqual(c.params.sleepMin, 3)
        XCTAssertEqual(c.menuSort, .status)
        XCTAssertEqual(c.mode, "hover")
    }

    func testLegacyNavaPresetMigrates() throws {
        let c = try NaviConfig.decode(Data(##"{"preset":"nava","params":{}}"##.utf8))
        XCTAssertEqual(c.preset, "navi")
    }

    func testBareParamsAccepted() throws {
        let c = try NaviConfig.decode(Data(##"{"size":9,"pixel":false}"##.utf8))
        XCTAssertEqual(c.params.size, 9)
        XCTAssertFalse(c.params.pixel)
    }

    func testRoundTrip() throws {
        var c = NaviConfig()
        c.params.trailDensity = 40; c.menuSort = .status
        let data = try c.encode()
        let back = try NaviConfig.decode(data)
        XCTAssertEqual(back, c)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(obj["params"]); XCTAssertEqual(obj["preset"] as? String, "navi")
    }

    func testGarbageThrows() {
        XCTAssertThrowsError(try NaviConfig.decode(Data("nope".utf8)))
    }
}
