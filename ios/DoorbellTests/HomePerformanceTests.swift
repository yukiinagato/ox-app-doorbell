import ImageIO
import UIKit
import XCTest

@testable import Doorbell

/// The two pieces of per-poll main-thread work the indoor home page used to do, measured against
/// what replaced them. The owner saw a hitch every few seconds on an iPad mini 3; these are the
/// costs that were paid on the main thread on that cadence.
///
/// The numbers below are simulator numbers on a development Mac, so they understate an A7 by a
/// long way. What they establish is the ratio and the fact that the work is gone, not the panel's
/// absolute frame budget.
final class HomePerformanceTests: XCTestCase {

    // MARK: - The call list

    private func sampleRows(_ count: Int) -> [CallLogRow] {
        return (0..<count).map { index in
            CallLogRow(id: "row-\(index)", callId: "call-\(index)",
                       tsMs: 1_760_000_000_000 + Int64(index) * 60_000, door: "front",
                       purpose: "delivery", outcome: index % 4 == 0 ? "missed" : "answered",
                       answeredBy: "pad", durationMs: 42_000, hlc: "hlc-\(index)", seen: true)
        }
    }

    /// What the history table pays per row: a stock subtitle cell configured from one call.
    func testConfiguringTwentyStockHistoryCells() {
        let texts = Texts()
        let core = CoreBridge()
        let rows = sampleRows(20)
        let cells = rows.map { _ in UITableViewCell(style: .subtitle, reuseIdentifier: "call") }
        measure {
            for (index, row) in rows.enumerated() {
                CallHistory.configure(cells[index], core: core, texts: texts, config: nil,
                                      row: row, lang: "ja")
            }
        }
        XCTAssertEqual(cells[0].accessibilityIdentifier, "history_row_row-0")
        XCTAssertNotNil(cells[0].imageView?.image, "the outcome icon is a vendored asset")
    }

    // MARK: - The door tile still

    private func snapshotJpeg() -> Data {
        // A door-station snapshot is a camera frame, not a thumbnail; this is the shape of the
        // decode the tile was doing on the main thread every five seconds, per door.
        let size = CGSize(width: 1280, height: 720)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        defer { UIGraphicsEndImageContext() }
        for band in 0..<24 {
            UIColor(hue: CGFloat(band) / 24, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
            UIRectFill(CGRect(x: 0, y: CGFloat(band) * 30, width: size.width, height: 30))
        }
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        return image.jpegData(compressionQuality: 0.8) ?? Data()
    }

    /// `UIImage(data:)` records the bytes and leaves the decode to the CoreAnimation commit, which
    /// happens on the main thread. Rendering it here is what that commit does.
    func testDecodingASnapshotTheOldWay() {
        let data = snapshotJpeg()
        XCTAssertFalse(data.isEmpty)
        measure {
            guard let image = UIImage(data: data) else { return XCTFail("no image") }
            UIGraphicsBeginImageContextWithOptions(CGSize(width: 132, height: 84), true, 2)
            image.draw(in: CGRect(x: 0, y: 0, width: 132, height: 84))
            UIGraphicsEndImageContext()
        }
    }

    /// ImageIO decodes straight to the size the tile draws at, off the main thread.
    func testDecodingASnapshotToTileSize() {
        let data = snapshotJpeg()
        measure {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return XCTFail("no source")
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 264,
            ]
            XCTAssertNotNil(CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                                options as CFDictionary))
        }
    }
}
