import UIKit
import XCTest

@testable import Doorbell

final class AirQualityTests: XCTestCase {

    private func texts(_ lang: String = "en") -> Texts {
        let texts = Texts()
        texts.setLang(lang)
        return texts
    }

    func testMissingOrHiddenDocumentDrawsNothing() {
        XCTAssertEqual(AirQualityReading.from(nil), .hidden)
        XCTAssertEqual(AirQualityReading.from(["show": false, "state": "ok", "pm25": 12]), .hidden)
        XCTAssertEqual(AirQualityReading.from(["show": true, "state": "hidden"]), .hidden)
        XCTAssertEqual(AirQualityReading.from(["show": true, "state": "bogus"]), .hidden)
        XCTAssertFalse(AirQualityReading.hidden.isVisible)
    }

    func testFreshReading() {
        let reading = AirQualityReading.from([
            "show": true, "sensor": "s1", "state": "ok", "name": "Hall", "pm25": 30,
            "level": "moderate", "at_ms": 1, "age_s": 4, "battery_pct": 80, "charging": true,
        ])
        XCTAssertEqual(reading.state, .ok)
        XCTAssertEqual(reading.valueText, "30")
        XCTAssertFalse(reading.isDimmed)
        let en = texts()
        XCTAssertEqual(reading.displayText(en), "PM2.5  30 µg/m³  Moderate")
        XCTAssertEqual(reading.accessibilityText(en),
                       "PM2.5 30 micrograms per cubic metre, Moderate")
    }

    func testStaleReadingIsDimmedAndKeepsItsValue() {
        let reading = AirQualityReading.from(["show": true, "state": "stale", "pm25": 41.6,
                                              "level": "sensitive"])
        XCTAssertTrue(reading.isVisible)
        XCTAssertTrue(reading.isDimmed)
        XCTAssertEqual(reading.valueText, "42")
        XCTAssertEqual(reading.displayText(texts()), "PM2.5  42 µg/m³  Not updated")
    }

    func testPlaceholders() {
        let en = texts()
        let waiting = AirQualityReading.from(["show": true, "state": "waiting", "name": "Hall"])
        XCTAssertEqual(waiting.displayText(en), "PM2.5  Waiting")
        XCTAssertEqual(waiting.accessibilityText(en), "PM2.5, Waiting")
        let unconfigured = AirQualityReading.from(["show": true, "state": "unconfigured"])
        XCTAssertEqual(unconfigured.displayText(en), "PM2.5  No sensor")
        XCTAssertNil(unconfigured.valueText)
        let claimed = AirQualityReading.from(["show": true, "state": "ok"])
        XCTAssertEqual(claimed.state, .waiting)
    }

    func testEveryLevelHasWordingAndColour() {
        let en = texts()
        for level in AirQualityReading.levels {
            let key = AirQualityReading.levelKey(level)
            XCTAssertNotNil(key)
            XCTAssertNotEqual(en.t(key!), key!, level)
            XCTAssertNotNil(AirQualityReading.levelColor(level), level)
        }
        XCTAssertNil(AirQualityReading.levelKey("unknown"))
        XCTAssertNil(AirQualityReading.levelColor(nil))
        let unknownLevel = AirQualityReading.from(["show": true, "state": "ok", "pm25": 5,
                                                   "level": "unknown"])
        XCTAssertNil(unknownLevel.level)
        XCTAssertEqual(unknownLevel.displayText(en), "PM2.5  5 µg/m³")
    }

    func testJapaneseWording() {
        let reading = AirQualityReading.from(["show": true, "state": "ok", "pm25": 8,
                                              "level": "good"])
        XCTAssertEqual(reading.displayText(texts("ja")), "PM2.5  8 µg/m³  良好")
    }

    func testViewHidesAndShows() {
        let view = AirQualityView(texts: texts(), centred: true)
        XCTAssertTrue(view.isHidden)
        XCTAssertTrue(view.update(AirQualityReading.from(["show": true, "state": "ok",
                                                           "pm25": 12, "level": "good"])))
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.accessibilityLabel, "PM2.5 12 micrograms per cubic metre, Good")
        XCTAssertFalse(view.update(view.reading))
        XCTAssertTrue(view.update(.hidden))
        XCTAssertTrue(view.isHidden)
    }

    func testSensorPlanParsing() {
        let plan = AirSensorHost.Plan.from([
            "host": true, "scan": true,
            "sensors": [["id": "s1", "address": "8E3C0B5A-0000-4000-8000-000000000001",
                         "kind": "mops_vida_pm25"], ["address": "no-id"]],
            "mops_vida_pm25": ["advertised_service": "7676", "advertised_name": "MOPS",
                               "service": "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
                               "rx": "6E400002-B5A3-F393-E0A9-E50E24DCCA9E",
                               "tx": "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"],
        ])
        XCTAssertTrue(plan.host)
        XCTAssertTrue(plan.scan)
        XCTAssertEqual(plan.sensors.map { $0.id }, ["s1"])
        XCTAssertEqual(plan.advertisedService, "7676")
        XCTAssertFalse(AirSensorHost.Plan.from(nil).host)
    }

    func testConnectCommandHexDecoding() {
        XCTAssertEqual(CoreBridge.bytes(fromHex: "00ff7A"), Data([0x00, 0xff, 0x7a]))
        XCTAssertNil(CoreBridge.bytes(fromHex: "abc"))
        XCTAssertNil(CoreBridge.bytes(fromHex: "zz"))
        XCTAssertNil(CoreBridge.bytes(fromHex: ""))
    }
}
