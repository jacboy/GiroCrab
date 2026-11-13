import SwiftUI
import XCTest
@testable import GiroCrabUI

@MainActor
final class AnimatedCrabLogoViewTests: XCTestCase {
    func testPhasesRenderNonEmptyImages() {
        for phase: AnimatedCrabLogoView.Phase in [.idle, .unlocking, .unlocked, .failed] {
            let r = ImageRenderer(content: AnimatedCrabLogoView(size: 120, phase: phase))
            XCTAssertNotNil(r.cgImage, "\(phase)")
        }
    }

    func testRendersWithoutBackground() {
        let r = ImageRenderer(content: AnimatedCrabLogoView(size: 64, phase: .idle, showBackgroundSquircle: false))
        XCTAssertEqual(r.cgImage?.width, 64 * Int(r.scale))
    }

    func testPhaseTransitionsAreDistinctAndEquatable() {
        var view = AnimatedCrabLogoView(size: 120)
        XCTAssertEqual(view.phase, .idle)
        view.phase = .unlocking
        XCTAssertNotEqual(view.phase, .idle)
        view.phase = .unlocked
        XCTAssertEqual(view.phase, .unlocked)
    }
}
