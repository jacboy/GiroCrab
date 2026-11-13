import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Animierte Vektor-Krabbe auf Basis von `girocrab-icon.svg` (1024x1024 Koordinatenraum).
/// Unterstützt:
/// - Initialen Münzwurf (3D-Flip) & diagonalen Glanz-Schimmer auf der Kreditkarte
/// - Sanftes Atmen/Schweben mit synchronisiertem Bodenschatten & Blinzeln im Ruhemodus
/// - Freudensprung („Unlock Hop“) beim Entsperren des Tresors
/// - Klick / Tap auf die Krabbe wiederholt den Münzwurf & Karten-Schimmer jederzeit
public struct AnimatedCrabLogoView: View {
    public enum Phase: Equatable, Sendable {
        case idle
        case unlocking
        case unlocked
        case failed
    }

    public var size: CGFloat
    public var phase: Phase
    public var showBackgroundSquircle: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Animations-Zustände (normiert auf den 1024x1024 Canvas)
    @State private var hoverOffsetY: CGFloat = 0
    @State private var hopOffsetY: CGFloat = 0
    @State private var coinOffsetY: CGFloat = 0
    @State private var coinFlipDegrees: Double = 0
    @State private var cardTiltDegrees: Double = 0
    @State private var rightClawDegrees: Double = 0
    @State private var shimmerProgress: CGFloat = -1.2
    @State private var eyebrowOffsetY: CGFloat = 0
    @State private var pupilOffset: CGSize = .zero
    @State private var eyeScaleY: CGFloat = 1.0
    @State private var isReplaying: Bool = false
    @State private var idleTask: Task<Void, Never>?

    public init(
        size: CGFloat = 160,
        phase: Phase = .idle,
        showBackgroundSquircle: Bool = true
    ) {
        self.size = size
        self.phase = phase
        self.showBackgroundSquircle = showBackgroundSquircle
    }

    public var body: some View {
        let scale = size / 1024.0

        ZStack {
            if showBackgroundSquircle {
                RoundedRectangle(cornerRadius: 220 * scale, style: .continuous)
                    .fill(Color(hex: 0x263040))
            }

            // 1. Bodenschatten (skaliert gegenläufig zur Schwebehöhe)
            CrabGroundShadowLayer()
                .scaleEffect(
                    x: shadowScale,
                    y: shadowScale,
                    anchor: UnitPoint(x: 512.0 / 1024.0, y: 782.0 / 1024.0)
                )
                .opacity(shadowOpacity)

            // Hauptgruppe der Krabbe (bewegt sich beim Schweben & Hop)
            ZStack {
                // 2. Linker Arm + Kreditkarte + Schimmer + linke Schere
                ZStack {
                    CrabLeftArmAndCardLayer(shimmerProgress: shimmerProgress)
                }
                .rotationEffect(
                    .degrees(cardTiltDegrees),
                    anchor: UnitPoint(x: 275.0 / 1024.0, y: 470.0 / 1024.0)
                )

                // 3. Rechter Arm + Goldmünze (mit 3D-Flip) + rechte Schere
                ZStack {
                    CrabRightClawBackLayer()

                    CrabGoldCoinLayer()
                        .rotation3DEffect(
                            .degrees(coinFlipDegrees),
                            axis: (x: 0, y: 1, z: 0.1),
                            anchor: UnitPoint(x: 726.0 / 1024.0, y: 310.0 / 1024.0)
                        )
                        .offset(y: coinOffsetY * scale)

                    CrabRightClawFrontLayer()
                }
                .rotationEffect(
                    .degrees(rightClawDegrees),
                    anchor: UnitPoint(x: 715.0 / 1024.0, y: 485.0 / 1024.0)
                )

                // 4. Beine & Körperpanzer + Mund
                CrabLegsAndBodyLayer()

                // 5. Augen & Augenbrauen
                CrabEyesAndBrowsLayer(
                    eyebrowOffsetY: eyebrowOffsetY * scale,
                    pupilOffset: CGSize(
                        width: pupilOffset.width * scale,
                        height: pupilOffset.height * scale
                    ),
                    eyeScaleY: eyeScaleY
                )
            }
            .offset(y: (hoverOffsetY + hopOffsetY) * scale)
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture {
            triggerCoinTossAndShimmer()
        }
        .onAppear {
            startAnimations()
        }
        .onDisappear {
            idleTask?.cancel()
            idleTask = nil
        }
        .onChange(of: phase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("GiroCrab"))
        .accessibilityAddTraits(.isButton)
    }

    private var totalLift: CGFloat {
        -(hoverOffsetY + hopOffsetY)
    }

    private var shadowScale: CGFloat {
        let clamped = max(-40, min(60, totalLift))
        return max(0.78, 1.0 - (clamped / 260.0))
    }

    private var shadowOpacity: Double {
        let clamped = max(-40, min(60, totalLift))
        return Double(max(0.18, 0.35 - (clamped / 320.0)))
    }

    // MARK: - Animations-Abläufe

    private func startAnimations() {
        guard !reduceMotion else { return }

        // Sanftes Atmen/Schweben
        withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
            hoverOffsetY = -14
        }

        // Initialer Münzwurf + Karten-Schimmer beim Erscheinen
        triggerCoinTossAndShimmer()

        // Periodisches Blinzeln im Ruhemodus
        idleTask?.cancel()
        idleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(3400))
                guard !Task.isCancelled, !reduceMotion else { break }
                await performBlink()
            }
        }
    }

    @MainActor
    private func performBlink() async {
        withAnimation(.easeIn(duration: 0.07)) {
            eyeScaleY = 0.08
        }
        try? await Task.sleep(for: .milliseconds(85))
        withAnimation(.easeOut(duration: 0.09)) {
            eyeScaleY = 1.0
        }
    }

    public func triggerCoinTossAndShimmer() {
        guard !reduceMotion, !isReplaying else { return }
        isReplaying = true

        shimmerProgress = -1.2

        Task { @MainActor in
            // 1. Ausholen & Münze hochwerfen + Karte neigen + Blick zur Münze
            withAnimation(.easeOut(duration: 0.22)) {
                coinOffsetY = -95
                rightClawDegrees = -8
                cardTiltDegrees = -7
                eyebrowOffsetY = -16
                pupilOffset = CGSize(width: 8, height: -9)
            }
            withAnimation(.easeInOut(duration: 0.48)) {
                coinFlipDegrees += 360
                shimmerProgress = 1.4
            }

            try? await Task.sleep(for: .milliseconds(220))

            // 2. Münze landet federnd in der Schere zurück
            withAnimation(.spring(response: 0.38, dampingFraction: 0.58)) {
                coinOffsetY = 0
                rightClawDegrees = 0
                cardTiltDegrees = 3
            }

            try? await Task.sleep(for: .milliseconds(180))

            withAnimation(.spring(response: 0.32, dampingFraction: 0.7)) {
                cardTiltDegrees = 0
                eyebrowOffsetY = 0
                pupilOffset = .zero
            }

            try? await Task.sleep(for: .milliseconds(220))
            isReplaying = false
        }
    }

    private func handlePhaseChange(_ newPhase: Phase) {
        guard !reduceMotion else { return }
        switch newPhase {
        case .idle:
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                pupilOffset = .zero
                eyebrowOffsetY = 0
            }
        case .unlocking:
            // Blick nach oben Richtung Face ID / Kamera
            withAnimation(.easeInOut(duration: 0.25)) {
                pupilOffset = CGSize(width: 0, height: -10)
                eyebrowOffsetY = -8
            }
        case .unlocked:
            // Freudensprung ("Unlock Hop")
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            Task { @MainActor in
                withAnimation(.spring(response: 0.26, dampingFraction: 0.52)) {
                    hopOffsetY = -52
                    cardTiltDegrees = -10
                    rightClawDegrees = 10
                    eyebrowOffsetY = -18
                    pupilOffset = .zero
                }
                try? await Task.sleep(for: .milliseconds(210))
                withAnimation(.spring(response: 0.36, dampingFraction: 0.62)) {
                    hopOffsetY = 0
                    cardTiltDegrees = 0
                    rightClawDegrees = 0
                    eyebrowOffsetY = 0
                }
            }
        case .failed:
            // Fragender Blick
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                eyebrowOffsetY = 8
                pupilOffset = CGSize(width: -6, height: 4)
            }
        }
    }
}

// MARK: - Vektor-Ebenen (1024x1024 Referenzsystem)

private struct CrabGroundShadowLayer: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 1024.0
            Ellipse()
                .fill(Color(hex: 0x161D26))
                .frame(width: 484 * s, height: 48 * s)
                .position(x: 512 * s, y: 782 * s)
        }
    }
}

private struct CrabLeftArmAndCardLayer: View {
    let shimmerProgress: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 1024.0
            ctx.scaleBy(x: s, y: s)

            // Linker Arm-Verbindungsteil
            var arm = Path()
            arm.move(to: CGPoint(x: 259, y: 428))
            arm.addLine(to: CGPoint(x: 315, y: 459))
            arm.addLine(to: CGPoint(x: 325, y: 508))
            arm.addLine(to: CGPoint(x: 273, y: 500))
            arm.closeSubpath()
            ctx.fill(arm, with: .color(Color(hex: 0xC63609)))

            // Kreditkarte (rotiert um -30 Grad wie im SVG)
            ctx.drawLayer { cardCtx in
                cardCtx.translateBy(x: 256, y: 310)
                cardCtx.rotate(by: .degrees(-30))

                let cardRect = CGRect(x: -145, y: -92, width: 290, height: 184)
                let cardPath = Path(roundedRect: cardRect, cornerRadius: 22)
                cardCtx.fill(cardPath, with: .color(Color(hex: 0xD5DCE6)))

                // Magnetstreifen
                let stripe = Path(CGRect(x: -145, y: -56, width: 290, height: 34))
                cardCtx.fill(stripe, with: .color(Color(hex: 0x263040)))

                // Textzeilen auf der Karte
                let line1 = Path(roundedRect: CGRect(x: -115, y: 18, width: 92, height: 12), cornerRadius: 6)
                let line2 = Path(roundedRect: CGRect(x: -115, y: 40, width: 122, height: 12), cornerRadius: 6)
                cardCtx.fill(line1, with: .color(Color(hex: 0x8F9BA8)))
                cardCtx.fill(line2, with: .color(Color(hex: 0x8F9BA8)))

                // Zwei überlappende Karten-Kreise (Mastercard-Stil)
                let c1 = Path(ellipseIn: CGRect(x: 42, y: 2, width: 46, height: 46))
                let c2 = Path(ellipseIn: CGRect(x: 68, y: 2, width: 46, height: 46))
                cardCtx.fill(c1, with: .color(Color(hex: 0x7E8B9B)))
                cardCtx.fill(c2, with: .color(Color(hex: 0x99A5B4)))

                // Diagonaler Glanz-Schimmer über der Karte
                cardCtx.clip(to: cardPath)
                let shimmerX = shimmerProgress * 220
                let shimmerRect = CGRect(x: shimmerX - 35, y: -130, width: 70, height: 260)
                cardCtx.rotate(by: .degrees(20))
                cardCtx.fill(
                    Path(shimmerRect),
                    with: .linearGradient(
                        Gradient(colors: [
                            .white.opacity(0.0),
                            .white.opacity(0.55),
                            .white.opacity(0.0),
                        ]),
                        startPoint: CGPoint(x: shimmerRect.minX, y: 0),
                        endPoint: CGPoint(x: shimmerRect.maxX, y: 0)
                    )
                )
            }

            // Linke Schere (vor der Karte)
            var claw = Path()
            claw.move(to: CGPoint(x: 191, y: 392))
            claw.addQuadCurve(to: CGPoint(x: 262, y: 398), control: CGPoint(x: 230, y: 408))
            claw.addLine(to: CGPoint(x: 304, y: 344))
            claw.addQuadCurve(to: CGPoint(x: 312, y: 462), control: CGPoint(x: 340, y: 418))
            claw.addQuadCurve(to: CGPoint(x: 191, y: 392), control: CGPoint(x: 215, y: 486))
            claw.closeSubpath()
            ctx.fill(claw, with: .color(Color(hex: 0xE64815)))
        }
        .allowsHitTesting(false)
    }
}

private struct CrabRightClawBackLayer: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 1024.0
            ctx.scaleBy(x: s, y: s)

            // Rechter Arm + hinterer Scherenfinger
            var back = Path()
            back.move(to: CGPoint(x: 695, y: 495))
            back.addLine(to: CGPoint(x: 748, y: 446))
            back.addQuadCurve(to: CGPoint(x: 698, y: 365), control: CGPoint(x: 685, y: 408))
            back.addLine(to: CGPoint(x: 752, y: 375))
            back.addLine(to: CGPoint(x: 765, y: 488))
            back.addLine(to: CGPoint(x: 710, y: 525))
            back.closeSubpath()
            ctx.fill(back, with: .color(Color(hex: 0xC63609)))
        }
        .allowsHitTesting(false)
    }
}

private struct CrabGoldCoinLayer: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 1024.0
            ctx.scaleBy(x: s, y: s)

            let center = CGPoint(x: 726, y: 310)
            let outer = Path(ellipseIn: CGRect(x: center.x - 84, y: center.y - 84, width: 168, height: 168))
            let inner = Path(ellipseIn: CGRect(x: center.x - 66, y: center.y - 66, width: 132, height: 132))

            ctx.fill(outer, with: .color(Color(hex: 0xF3C23A)))
            ctx.fill(inner, with: .color(Color(hex: 0xE5AE27)))

            // Münz-Prägestreifen (leicht geneigt)
            ctx.drawLayer { barCtx in
                barCtx.translateBy(x: center.x, y: center.y)
                barCtx.rotate(by: .degrees(-18))
                let bar = Path(roundedRect: CGRect(x: -16, y: -58, width: 32, height: 116), cornerRadius: 8)
                barCtx.fill(bar, with: .color(Color(hex: 0xF3C23A)))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CrabRightClawFrontLayer: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 1024.0
            ctx.scaleBy(x: s, y: s)

            var front = Path()
            front.move(to: CGPoint(x: 777, y: 278))
            front.addQuadCurve(to: CGPoint(x: 822, y: 446), control: CGPoint(x: 862, y: 368))
            front.addQuadCurve(to: CGPoint(x: 702, y: 442), control: CGPoint(x: 756, y: 492))
            front.addQuadCurve(to: CGPoint(x: 758, y: 382), control: CGPoint(x: 734, y: 416))
            front.closeSubpath()
            ctx.fill(front, with: .color(Color(hex: 0xE64815)))

            // Glanzpunkte auf der rechten Schere
            let dot1 = Path(ellipseIn: CGRect(x: 798, y: 382, width: 12, height: 22))
            let dot2 = Path(ellipseIn: CGRect(x: 793, y: 412, width: 9, height: 9))
            ctx.fill(dot1, with: .color(Color(hex: 0xF38654)))
            ctx.fill(dot2, with: .color(Color(hex: 0xF38654)))
        }
        .allowsHitTesting(false)
    }
}

private struct CrabLegsAndBodyLayer: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 1024.0
            ctx.scaleBy(x: s, y: s)

            // Linke 3 Beine
            let leftLegs: [([CGPoint], UInt32)] = [
                ([CGPoint(x: 254, y: 528), CGPoint(x: 316, y: 560), CGPoint(x: 245, y: 658), CGPoint(x: 162, y: 716), CGPoint(x: 205, y: 608)], 0xD93E0E),
                ([CGPoint(x: 295, y: 552), CGPoint(x: 356, y: 576), CGPoint(x: 294, y: 676), CGPoint(x: 228, y: 736), CGPoint(x: 258, y: 634)], 0xC63609),
                ([CGPoint(x: 342, y: 575), CGPoint(x: 394, y: 595), CGPoint(x: 340, y: 688), CGPoint(x: 277, y: 735), CGPoint(x: 306, y: 650)], 0xB22E06),
            ]
            for (pts, hex) in leftLegs {
                var p = Path()
                p.addLines(pts)
                p.closeSubpath()
                ctx.fill(p, with: .color(Color(hex: hex)))
            }

            // Rechte 3 Beine (gespiegelt um x = 512)
            for (pts, hex) in leftLegs {
                var p = Path()
                p.addLines(pts.map { CGPoint(x: 1024 - $0.x, y: $0.y) })
                p.closeSubpath()
                ctx.fill(p, with: .color(Color(hex: hex)))
            }

            // Körperpanzer (obere Kuppel + Facetten)
            var shellLeft = Path()
            shellLeft.move(to: CGPoint(x: 512, y: 422))
            shellLeft.addQuadCurve(to: CGPoint(x: 296, y: 536), control: CGPoint(x: 350, y: 422))
            shellLeft.addLine(to: CGPoint(x: 382, y: 668))
            shellLeft.addLine(to: CGPoint(x: 512, y: 668))
            shellLeft.closeSubpath()
            ctx.fill(shellLeft, with: .color(Color(hex: 0xF0551E)))

            var shellRight = Path()
            shellRight.move(to: CGPoint(x: 512, y: 422))
            shellRight.addQuadCurve(to: CGPoint(x: 728, y: 536), control: CGPoint(x: 674, y: 422))
            shellRight.addLine(to: CGPoint(x: 642, y: 668))
            shellRight.addLine(to: CGPoint(x: 512, y: 668))
            shellRight.closeSubpath()
            ctx.fill(shellRight, with: .color(Color(hex: 0xDC4312)))

            // Untere Bauch-Facette
            var lowerShell = Path()
            lowerShell.move(to: CGPoint(x: 296, y: 536))
            lowerShell.addLine(to: CGPoint(x: 512, y: 492))
            lowerShell.addLine(to: CGPoint(x: 728, y: 536))
            lowerShell.addLine(to: CGPoint(x: 642, y: 668))
            lowerShell.addLine(to: CGPoint(x: 382, y: 668))
            lowerShell.closeSubpath()
            ctx.fill(lowerShell, with: .color(Color(hex: 0xD33B0D)))

            // Glanzpunkte auf der linken Panzerseite
            ctx.drawLayer { glCtx in
                glCtx.translateBy(x: 386, y: 484)
                glCtx.rotate(by: .degrees(-28))
                glCtx.fill(Path(ellipseIn: CGRect(x: -18, y: -8, width: 36, height: 16)), with: .color(Color(hex: 0xF68352)))
                glCtx.fill(Path(ellipseIn: CGRect(x: 24, y: -14, width: 14, height: 10)), with: .color(Color(hex: 0xF68352)))
            }

            // Lachender Mund + Zunge
            var mouth = Path()
            mouth.move(to: CGPoint(x: 432, y: 545))
            mouth.addQuadCurve(to: CGPoint(x: 592, y: 545), control: CGPoint(x: 512, y: 562))
            mouth.addQuadCurve(to: CGPoint(x: 512, y: 634), control: CGPoint(x: 576, y: 634))
            mouth.addQuadCurve(to: CGPoint(x: 432, y: 545), control: CGPoint(x: 448, y: 634))
            mouth.closeSubpath()
            ctx.fill(mouth, with: .color(Color(hex: 0x5B1707)))

            // Zunge (geclippt auf den Mund)
            ctx.drawLayer { mCtx in
                mCtx.clip(to: mouth)
                let tongue = Path(ellipseIn: CGRect(x: 462, y: 590, width: 100, height: 56))
                mCtx.fill(tongue, with: .color(Color(hex: 0xEE5C35)))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CrabEyesAndBrowsLayer: View {
    let eyebrowOffsetY: CGFloat
    let pupilOffset: CGSize
    let eyeScaleY: CGFloat

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 1024.0

            ZStack {
                // Augenbrauen
                Canvas { ctx, size in
                    ctx.scaleBy(x: s, y: s)

                    var leftBrow = Path()
                    leftBrow.move(to: CGPoint(x: 398, y: 356))
                    leftBrow.addQuadCurve(to: CGPoint(x: 465, y: 352), control: CGPoint(x: 430, y: 328))
                    ctx.stroke(leftBrow, with: .color(Color(hex: 0xEA4E1B)), style: StrokeStyle(lineWidth: 14, lineCap: .round))

                    var rightBrow = Path()
                    rightBrow.move(to: CGPoint(x: 559, y: 352))
                    rightBrow.addQuadCurve(to: CGPoint(x: 626, y: 356), control: CGPoint(x: 594, y: 328))
                    ctx.stroke(rightBrow, with: .color(Color(hex: 0xEA4E1B)), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                }
                .offset(y: eyebrowOffsetY)

                // Linkes & rechtes Auge (skaliert vertikal beim Blinzeln)
                 CrabSingleEyeView(centerX: 448, centerY: 404, scale: s, pupilOffset: pupilOffset)
                    .scaleEffect(x: 1.0, y: eyeScaleY, anchor: UnitPoint(x: 448.0 / 1024.0, y: 404.0 / 1024.0))

                CrabSingleEyeView(centerX: 576, centerY: 404, scale: s, pupilOffset: pupilOffset)
                    .scaleEffect(x: 1.0, y: eyeScaleY, anchor: UnitPoint(x: 576.0 / 1024.0, y: 404.0 / 1024.0))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct CrabSingleEyeView: View {
    let centerX: CGFloat
    let centerY: CGFloat
    let scale: CGFloat
    let pupilOffset: CGSize

    var body: some View {
        ZStack {
            // Oranger Augenring
            Circle()
                .fill(Color(hex: 0xEA4E1B))
                .frame(width: 92 * scale, height: 92 * scale)

            // Sklera (Weiß)
            Circle()
                .fill(Color.white)
                .frame(width: 68 * scale, height: 68 * scale)

            // Pupille + Lichtreflex
            ZStack {
                Circle()
                    .fill(Color(hex: 0x1E2836))
                    .frame(width: 38 * scale, height: 38 * scale)

                Circle()
                    .fill(Color.white)
                    .frame(width: 13 * scale, height: 13 * scale)
                    .offset(x: -7 * scale, y: -7 * scale)
            }
            .offset(pupilOffset)
        }
        .position(x: centerX * scale, y: centerY * scale)
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}