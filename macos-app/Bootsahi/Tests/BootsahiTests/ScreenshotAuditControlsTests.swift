import XCTest
import AppKit
@testable import Bootsahi

/// Retained pixel fixtures for the region audit in `ScreenshotCaptureTests`.
/// These need no window server: they build bitmaps directly, so the audit's
/// ability to FAIL is checked on every `swift test`, not only when capture runs.
@MainActor
final class ScreenshotAuditControlsTests: XCTestCase {

    private let w = 860, h = 640
    private let bg: (UInt8, UInt8, UInt8) = (236, 236, 236)

    private func image(
        _ paint: (_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8)?
    ) -> CGImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let c = paint(x, y) ?? bg
            let i = (y * w + x) * 4
            px[i] = c.0; px[i + 1] = c.1; px[i + 2] = c.2
        } }
        let ctx = px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        }
        return ctx.makeImage()!
    }

    private func violations(_ img: CGImage) -> [String] {
        ScreenshotCaptureTests.violations(
            ScreenshotCaptureTests.audit(img, name: "fixture"))
    }

    /// Dark body ink in the top part plus a button-like block in the bottom bar.
    private func good(buttonColor: (UInt8, UInt8, UInt8)) -> CGImage {
        image { x, y in
            if y > 100 && y < 400 && x > 80 && x < 700 && (y / 6) % 2 == 0 { return (40, 40, 40) }
            if y > 590 && y < 625 && x > 600 && x < 820 { return buttonColor }
            return nil
        }
    }

    func testPositiveControlPassesWithAccentButton() {
        XCTAssertEqual(violations(good(buttonColor: (10, 90, 220))), [])
    }

    func testPaleInactiveButtonIsStillAccepted() {
        // macOS draws .borderedProminent pale in a non-active app; the regional
        // contrast logic must keep accepting it.
        XCTAssertEqual(violations(good(buttonColor: (250, 250, 250))), [])
    }

    func testBlankFrameFails() {
        XCTAssertTrue(violations(image { _, _ in nil }).contains("blank"))
    }

    func testPlaceholderRenderingFails() {
        let img = image { x, y in
            (y > 60 && y < 560 && x > 40 && x < 820) ? (255, 200, 30) : nil
        }
        XCTAssertTrue(violations(img).contains("placeholder"))
    }

    func testMissingPrimaryActionFails() {
        let img = image { x, y in
            (y > 100 && y < 400 && x > 80 && x < 700 && (y / 6) % 2 == 0) ? (40, 40, 40) : nil
        }
        XCTAssertTrue(violations(img).contains("action-bar"))
    }
}
