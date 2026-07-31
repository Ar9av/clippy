import XCTest
import CoreGraphics
@testable import ClippyMac

/// The screenshot handed to the model is shrunk before encoding. Every
/// model-supplied coordinate is interpreted through the ratio between that
/// image and the window's point size, so the scaling has to be exact and
/// uniform on both axes — a stretched or letterboxed image would silently
/// bend every click that follows.
final class ScreenshotDownscaleTests: XCTestCase {
    private func image(_ width: Int, _ height: Int) -> CGImage {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )!.makeImage()!
    }

    private var limit: Int { ScreenAwarenessService.maxScreenshotDimension }

    func testLeavesAnImageWithinTheLimitUntouched() {
        let source = image(1200, 800)
        let result = ScreenAwarenessService.downscaledForModel(source)
        XCTAssertEqual(result.width, 1200)
        XCTAssertEqual(result.height, 800)
    }

    func testAnImageExactlyAtTheLimitIsUntouched() {
        let result = ScreenAwarenessService.downscaledForModel(image(limit, 900))
        XCTAssertEqual(result.width, limit)
        XCTAssertEqual(result.height, 900)
    }

    func testShrinksTheLongEdgeToTheLimit() {
        // A full-screen window on a Retina display — the case that cost ~900ms.
        let result = ScreenAwarenessService.downscaledForModel(image(3024, 1964))
        XCTAssertEqual(result.width, limit)
    }

    func testPreservesAspectRatio() {
        let source = image(3024, 1964)
        let result = ScreenAwarenessService.downscaledForModel(source)
        let sourceRatio = Double(source.width) / Double(source.height)
        let resultRatio = Double(result.width) / Double(result.height)
        XCTAssertEqual(sourceRatio, resultRatio, accuracy: 0.005)
    }

    func testScalesByTheLongEdgeWhateverTheOrientation() {
        let portrait = ScreenAwarenessService.downscaledForModel(image(1200, 3000))
        XCTAssertEqual(portrait.height, limit)
        XCTAssertLessThan(portrait.width, limit)

        let landscape = ScreenAwarenessService.downscaledForModel(image(3000, 1200))
        XCTAssertEqual(landscape.width, limit)
        XCTAssertLessThan(landscape.height, limit)
    }

    func testNeverProducesAZeroDimension() {
        // An extreme aspect ratio must not round the short edge away to zero.
        let result = ScreenAwarenessService.downscaledForModel(image(6000, 2))
        XCTAssertEqual(result.width, limit)
        XCTAssertGreaterThanOrEqual(result.height, 1)
    }

    /// The contract the coordinate math depends on: one multiplier maps window
    /// points onto image pixels on both axes.
    func testASinglePointToPixelRatioHoldsOnBothAxes() {
        let windowPoints = CGSize(width: 1512, height: 982)
        let captured = image(Int(windowPoints.width) * 2, Int(windowPoints.height) * 2)
        let result = ScreenAwarenessService.downscaledForModel(captured)

        let horizontal = Double(result.width) / Double(windowPoints.width)
        let vertical = Double(result.height) / Double(windowPoints.height)
        XCTAssertEqual(horizontal, vertical, accuracy: 0.005)
        // And that ratio is what the capture path reports as screenshotScale.
        XCTAssertEqual(horizontal, Double(limit) / Double(windowPoints.width), accuracy: 0.005)
    }
}
