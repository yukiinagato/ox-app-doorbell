import UIKit
import XCTest

@testable import Doorbell

final class ReplyFitTests: XCTestCase {

    /// A deterministic stand-in for the platform's text layout: CJK is one em wide and wraps per
    /// character, Latin is 0.55 em per character and wraps per word, newlines break lines.
    private func measure(_ text: String, _ size: CGFloat, _ maxWidth: CGFloat) -> CGSize {
        func isWide(_ c: Character) -> Bool { return c.unicodeScalars.first!.value >= 0x2E80 }
        func advance(_ c: Character) -> CGFloat { return (isWide(c) ? 1.0 : 0.55) * size }
        var lines = 0
        var widest: CGFloat = 0
        for paragraph in text.components(separatedBy: "\n") {
            var line: CGFloat = 0
            var rows = 1
            var tokens: [String] = []
            var word = ""
            for c in paragraph {
                if isWide(c) || c == " " {
                    if !word.isEmpty { tokens.append(word); word = "" }
                    tokens.append(String(c))
                } else { word.append(c) }
            }
            if !word.isEmpty { tokens.append(word) }
            for token in tokens {
                let w = token.reduce(CGFloat(0)) { $0 + advance($1) }
                if line + w > maxWidth && line > 0 { rows += 1; widest = max(widest, line); line = 0 }
                line += w
            }
            widest = max(widest, line)
            lines += rows
        }
        return CGSize(width: widest, height: CGFloat(lines) * size * ReplyFit.lineHeightMultiple)
    }

    private func fit(_ text: String, _ w: CGFloat, _ h: CGFloat) -> ReplyFit.Fit {
        return ReplyFit.fit(text: text, width: w, height: h, measure: measure)
    }

    private func assertFitsAndMaximal(_ text: String, _ w: CGFloat, _ h: CGFloat,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let result = fit(text, w, h)
        XCTAssertTrue(result.fits, file: file, line: line)
        let used = measure(text, result.size, w)
        XCTAssertLessThanOrEqual(used.width, w + 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(used.height, h, file: file, line: line)
        if result.size < h {
            let bigger = measure(text, result.size + 1, w)
            XCTAssertTrue(bigger.width > w + 0.5 || bigger.height > h, "not maximal",
                          file: file, line: line)
        }
    }

    func testShortTextGrowsToTheBoxLimit() {
        let result = fit("OK", 700, 300)
        XCTAssertTrue(result.fits)
        XCTAssertGreaterThan(result.size, 150)
        assertFitsAndMaximal("OK", 700, 300)
    }

    func testTypicalSentencesInEachLanguage() {
        assertFitsAndMaximal("すぐに行きますので、少々お待ちください。", 700, 800)
        assertFitsAndMaximal("I will be right there, please wait a moment.", 700, 800)
        assertFitsAndMaximal("我马上就来，请稍等一下。", 700, 800)
        XCTAssertGreaterThan(fit("すぐに行きますので、少々お待ちください。", 700, 800).size,
                             ReplyFit.floorSize)
    }

    func testVeryLongTextKeepsTheFloorAndDoesNotFit() {
        let text = String(repeating: "お待ちください。", count: 400)
        let result = fit(text, 400, 300)
        XCTAssertEqual(result.size, ReplyFit.floorSize)
        XCTAssertFalse(result.fits)
    }

    func testLandscapeAndPortraitBoxesChooseDifferentSizes() {
        let text = "Please leave the parcel at the side door, thank you."
        assertFitsAndMaximal(text, 720, 900)
        assertFitsAndMaximal(text, 1000, 420)
        XCTAssertNotEqual(fit(text, 720, 900).size, fit(text, 1000, 420).size)
    }

    func testExplicitNewlinesCountAsLines() {
        let one = fit("Back in five minutes", 800, 400)
        let three = fit("Back\nin five\nminutes", 800, 400)
        XCTAssertLessThanOrEqual(three.size, one.size)
        assertFitsAndMaximal("Back\nin five\nminutes", 800, 400)
    }

    func testDegenerateBoxKeepsTheFloor() {
        XCTAssertEqual(fit("OK", 0, 0), ReplyFit.Fit(size: ReplyFit.floorSize, fits: false))
    }

    func testPlatformMeasureHonoursNewlinesAndWidth() {
        let single = ReplyFit.measure("Hello", size: 40, maxWidth: 600)
        let double = ReplyFit.measure("Hello\nWorld", size: 40, maxWidth: 600)
        XCTAssertGreaterThan(double.height, single.height * 1.8)
        let narrow = ReplyFit.measure("すぐに行きますので少々お待ちください", size: 40, maxWidth: 200)
        XCTAssertLessThanOrEqual(narrow.width, 200)
        XCTAssertGreaterThan(narrow.height, single.height * 2)
    }

    func testOverlayFitsItsFrameAndScrollsOnlyAtTheFloor() {
        let view = ReplyOverlayView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        view.show(text: "すぐに行きます", ttl: 30)
        view.layoutIfNeeded()
        XCTAssertFalse(view.scrolls)
        XCTAssertGreaterThan(view.fittedSize, ReplyFit.floorSize)
        view.show(text: String(repeating: "お待ちください。", count: 300), ttl: 30)
        view.layoutIfNeeded()
        XCTAssertTrue(view.scrolls)
        XCTAssertEqual(view.fittedSize, ReplyFit.floorSize)
    }

    func testTapsAreIgnoredAndHintHiddenDuringTheFirstThreeSeconds() {
        var guardState = ReplyDismissGuard()
        XCTAssertEqual(guardState.hint(at: 0), .none)
        XCTAssertEqual(guardState.tap(at: 1), .ignore)
        XCTAssertEqual(guardState.tap(at: 2.99), .ignore)
        XCTAssertEqual(guardState.hint(at: 2.99), .none)
        XCTAssertEqual(guardState.hint(at: 3), .first)
    }

    func testSecondSeparateTapWithinTheWindowCloses() {
        var guardState = ReplyDismissGuard()
        XCTAssertEqual(guardState.tap(at: 4), .arm)
        XCTAssertEqual(guardState.hint(at: 4.1), .confirm)
        XCTAssertEqual(guardState.tap(at: 5), .close)
    }

    func testBounceWithinThreeHundredMillisecondsDoesNotClose() {
        var guardState = ReplyDismissGuard()
        XCTAssertEqual(guardState.tap(at: 4), .arm)
        XCTAssertEqual(guardState.tap(at: 4.2), .ignore)
        XCTAssertEqual(guardState.hint(at: 4.2), .confirm)
        XCTAssertEqual(guardState.tap(at: 4.35), .close)
    }

    func testHintReturnsAndTapRearmsWhenTheWindowExpires() {
        var guardState = ReplyDismissGuard()
        XCTAssertEqual(guardState.tap(at: 4), .arm)
        XCTAssertEqual(guardState.hint(at: 7.5), .first)
        XCTAssertEqual(guardState.tap(at: 8), .arm)
        XCTAssertEqual(guardState.tap(at: 9), .close)
    }

    func testOverlayClosesOnlyOnGuardedSecondTap() {
        let view = ReplyOverlayView(frame: CGRect(x: 0, y: 0, width: 700, height: 500))
        var closed = 0
        view.onDismiss = { closed += 1 }
        view.hintFirst = "first"
        view.hintConfirm = "again"
        view.show(text: "OK", ttl: 30)
        let start = CACurrentMediaTime()
        view.handleTap(now: start + 1)
        view.handleTap(now: start + 4)
        XCTAssertEqual(closed, 0)
        view.handleTap(now: start + 5)
        XCTAssertEqual(closed, 1)
    }

    func testReplyInkContrastIsAtLeastSevenToOne() {
        func luminance(_ color: UIColor) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            func lin(_ c: CGFloat) -> CGFloat {
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let a = luminance(ReplyOverlayView.ink), b = luminance(ReplyOverlayView.surface)
        XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 7)
    }
}
