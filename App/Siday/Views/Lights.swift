// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayPlayer
import SwiftUI

/// A light for each voice of the tune: a chip's channels, a module's tracks. Each is the lamp of an
/// early-1980s tape recorder's recording level: the louder its voice, the brighter it glows, and the
/// wider. Each is a button: pressed, it mutes its voice or brings it back; its menu has it heard alone.
/// With scopes, each voice has the scope of its wave under its lamp, as FastTracker 2 had a scope of
/// each channel.
struct Lights: View {
    @Environment(PlayerModel.self) private var model
    let frame: Frame
    let lamps: Bool
    let scopes: Bool

    @ScaledMetric(relativeTo: .body) private var lampSize = 36
    @ScaledMetric(relativeTo: .body) private var scopeHeight = 76

    var body: some View {
        let count = frame.lights.count
        Group {
            if scopes {
                // (No more than eight to a row, as the web player has them.)
                CentredRows(largest: 96, least: 64, spacing: 6, rowSpacing: 6, most: 8, square: false) {
                    lights(count)
                }
            } else {
                CentredRows(largest: lampSize, least: min(lampSize, 24), spacing: 0, rowSpacing: 0, most: nil, square: true) {
                    lights(count)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voices")
    }

    private func lights(_ count: Int) -> some View {
        ForEach(0 ..< count, id: \.self) { voice in
            Light(voice: voice, level: frame.lights[voice],
                  kind: voice < frame.kinds.count ? frame.kinds[voice] : .chip,
                  muted: voice < frame.muted.count && frame.muted[voice],
                  wave: scopes ? Array(frame.scopes.dropFirst(voice * ChannelWaves.points).prefix(ChannelWaves.points)) : nil,
                  lamp: lamps, scopeHeight: scopeHeight)
        }
    }
}

/// The voices' lamps, or their scopes, in rows: in one row in the middle, each as big as it may be
/// if there is room, and smaller if not; and only when they would be smaller than the least, in
/// more rows, as even as can be, each in the middle, the last too.
private struct CentredRows: Layout {
    let largest: CGFloat, least: CGFloat
    /// The room between one and the next in a row, and between rows.
    let spacing: CGFloat, rowSpacing: CGFloat
    /// The most to a row, if there is a most.
    let most: Int?
    /// Whether each is as tall as it is wide; if not, each is as tall as it asks to be.
    let square: Bool

    private func arrangement(_ count: Int, across width: CGFloat?) -> (perRow: Int, rows: Int, width: CGFloat) {
        guard count > 0 else { return (0, 0, 0) }
        let width = width ?? CGFloat(count) * (largest + spacing)
        let fit = min(most ?? .max, max(1, Int((width + spacing) / (least + spacing))))
        let rows = (count + fit - 1) / fit
        let perRow = (count + rows - 1) / rows
        return (perRow, rows, min(largest, (width - spacing * CGFloat(perRow - 1)) / CGFloat(perRow)))
    }

    private func height(of subviews: Subviews, _ width: CGFloat) -> CGFloat {
        square ? width : subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (perRow, rows, width) = arrangement(subviews.count, across: proposal.width)
        guard rows > 0 else { return .zero }
        let tall = height(of: subviews, width)
        return CGSize(width: CGFloat(perRow) * width + CGFloat(perRow - 1) * spacing,
                      height: CGFloat(rows) * tall + CGFloat(rows - 1) * rowSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (perRow, _, width) = arrangement(subviews.count, across: bounds.width)
        let tall = height(of: subviews, width)
        for (place, subview) in subviews.enumerated() {
            let row = place / perRow, column = place % perRow
            let inRow = min(perRow, subviews.count - row * perRow)
            let left = bounds.midX - (CGFloat(inRow) * width + CGFloat(inRow - 1) * spacing) / 2
            subview.place(at: CGPoint(x: left + CGFloat(column) * (width + spacing) + width / 2,
                                      y: bounds.minY + CGFloat(row) * (tall + rowSpacing) + tall / 2),
                          anchor: .center, proposal: ProposedViewSize(width: width, height: tall))
        }
    }
}

private struct Light: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColour
    let voice: Int
    let level: Float
    let kind: VoiceKind
    let muted: Bool
    /// Its scope, if one is shown.
    let wave: [Float]?
    let lamp: Bool
    let scopeHeight: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            if lamp {
                if wave == nil {
                    // (As big as the place it is given: see `CentredRows`.)
                    Lamp(level: level, kind: kind)
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    Lamp(level: level, kind: kind)
                        .frame(width: 24, height: 24)
                }
            }
            if let wave {
                Scope(wave: wave, kind: kind)
                    .frame(height: lamp ? scopeHeight - 28 : scopeHeight)
            }
        }
        .saturation(muted ? 0.22 : 1)
        .opacity(muted ? 0.45 : 1)
        .overlay(alignment: .bottomTrailing) {
            if muted, withoutColour || wave != nil {
                Image(systemName: "speaker.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.press(light: voice, solo: false) }
        .contextMenu {
            Button(muted ? "Bring Back" : "Mute", systemImage: muted ? "speaker.wave.2" : "speaker.slash") { model.press(light: voice, solo: false) }
            Button("Hear Alone", systemImage: "person.wave.2") { model.press(light: voice, solo: true) }
        }
        .help("Click to mute this voice or bring it back. Its menu has it heard alone.")
        .accessibilityElement()
        .accessibilityLabel(Text("Voice \(voice + 1)"))
        .accessibilityValue(Text(muted ? "Muted" : kind == .sample ? "Sample" : kind == .speaker ? "Beeper" : "Chip"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(muted ? "Brings the voice back." : "Mutes the voice.")
        .accessibilityAction { model.press(light: voice, solo: false) }
        .accessibilityAction(named: "Hear Alone") { model.press(light: voice, solo: true) }
    }
}

/// A lamp: glass when its voice is quiet, glowing when it plays, with a thin ring round the glass as the
/// web player's lamps have. The glass is dark, as the web player's, in the light as in the dark.
struct Lamp: View {
    let level: Float
    let kind: VoiceKind
    @Environment(\.colorScheme) private var scheme

    static func colour(_ kind: VoiceKind) -> Color {
        switch kind {
        case .chip: Color(red: 1, green: 0.16, blue: 0.08)
        case .sample: Color(red: 0.17, green: 0.51, blue: 1)
        case .speaker: Color(red: 1, green: 0.27, blue: 0.82)
        }
    }

    /// A lamp lit, as the web player's: its middle, the lamp, its edge, and the light it throws.
    private static func lit(_ kind: VoiceKind) -> (middle: Color, lamp: Color, edge: Color, thrown: Color) {
        func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color { Color(red: red / 255, green: green / 255, blue: blue / 255) }
        switch kind {
        case .chip: return (rgb(255, 82, 54), rgb(255, 36, 20), rgb(240, 16, 6), rgb(255, 34, 20))
        case .sample: return (rgb(88, 166, 255), rgb(43, 130, 255), rgb(18, 102, 242), rgb(34, 120, 255))
        case .speaker: return (rgb(255, 138, 230), rgb(255, 69, 210), rgb(240, 28, 188), rgb(255, 60, 210))
        }
    }

    /// The glass, lit from above on the left, as the web player's is, in the light as in the dark:
    /// its light side, its middle, and its shaded side.
    private static func glass(_ kind: VoiceKind) -> Gradient {
        func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color { Color(red: red / 255, green: green / 255, blue: blue / 255) }
        let (light, middle, shaded) = switch kind {
        case .chip: (rgb(106, 28, 22), rgb(58, 13, 10), rgb(34, 8, 7))
        case .sample: (rgb(22, 48, 110), rgb(11, 26, 64), rgb(7, 15, 38))
        case .speaker: (rgb(106, 28, 85), rgb(65, 15, 52), rgb(37, 8, 30))
        }
        return Gradient(stops: [.init(color: light, location: 0), .init(color: middle, location: 0.55), .init(color: shaded, location: 1)])
    }

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let level = CGFloat(max(0, min(1, level)))
            // The lamp is half the place; its glow is as wide as the place when bright, and fainter than
            // its level, so a loud voice stands out from a quiet one and a note is seen to die away.
            let glass = CGRect(x: centre.x - side / 4, y: centre.y - side / 4, width: side / 2, height: side / 2)
            // (The web's gradient reaches from its light place to the furthest corner of the glass's square.)
            context.fill(Path(ellipseIn: glass), with: .radialGradient(Self.glass(kind), center: CGPoint(x: glass.minX + glass.width * 0.38, y: glass.minY + glass.height * 0.32),
                                                                      startRadius: 0, endRadius: glass.width * 0.92))
            // The ring: on the web player's dark panel nearly black; on a light ground the dark grey
            // of the time bar's part that is ready, so that a lamp at rest looks as ready to use as
            // the controls round it, and as heavy: a line round a circle looks finer than one as wide
            // along the straight sides of a scope.
            let ring = scheme == .light ? Color.primary.opacity(0.65) : Color(red: 0.047, green: 0.051, blue: 0.063)
            let ringWidth: CGFloat = scheme == .light ? 1.5 : 1
            context.stroke(Path(ellipseIn: glass.insetBy(dx: -ringWidth / 2, dy: -ringWidth / 2)), with: .color(ring), lineWidth: ringWidth)
            do {
                // The lamp sits in a hollow: round the ring, the hollow's sloping side, shaded at the top
                // and catching the light at the bottom, as a hollow lit from above is; in the dark, a
                // dark one, so that the lamp has an edge on a black ground too.
                let slope = max(2, side / 14)
                let shading = scheme == .light ? [Color(white: 0.74), Color(white: 0.97)] : [Color(white: 0.02), Color(white: 0.24)]
                context.stroke(Path(ellipseIn: glass.insetBy(dx: -ringWidth - slope / 2, dy: -ringWidth - slope / 2)),
                               with: .linearGradient(Gradient(colors: shading),
                                                     startPoint: CGPoint(x: centre.x, y: glass.minY - ringWidth - slope),
                                                     endPoint: CGPoint(x: centre.x, y: glass.maxY + ringWidth + slope)),
                               lineWidth: slope)
            }
            let glow = level * level.squareRoot()
            guard glow > 0.01 else { return }
            let radius = side / 2 * (0.5 + 0.5 * level)
            let lit = Self.lit(kind)
            context.opacity = glow
            // The web player's glow, stop for stop (its gradient reaches to the corner of a square as
            // wide as the lamp's place, so its places are this one's times the square root of two):
            // the lamp, hotter in its middle, to a third of the way out, and then the light it throws
            // on what is round it, brightest at the lamp's edge, falling away quickly and then slowly.
            context.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                         with: .radialGradient(Gradient(stops: [
                             .init(color: lit.middle, location: 0), .init(color: lit.lamp, location: 0.283),
                             .init(color: lit.edge, location: 0.453), .init(color: lit.thrown.opacity(0.62), location: 0.523),
                             .init(color: lit.thrown.opacity(0.38), location: 0.594), .init(color: lit.thrown.opacity(0.22), location: 0.679),
                             .init(color: lit.thrown.opacity(0.12), location: 0.764), .init(color: lit.thrown.opacity(0.05), location: 0.863),
                             .init(color: lit.thrown.opacity(0), location: 0.99),
                         ]), center: centre, startRadius: 0, endRadius: radius))
        }
    }
}

/// A voice's wave, in the colour of its lamp, on a dark ground of its own, as the web player's, in
/// the light as in the dark; in the light, with a line round it as dark as a lamp's ring.
struct Scope: View {
    let wave: [Float]
    let kind: VoiceKind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let ground = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
            // (The web player's paper; and its line, or in the light the dark grey of the lamps' rings.)
            context.fill(ground, with: .color(Color(red: 0.078, green: 0.086, blue: 0.102)))
            context.stroke(ground, with: .color(scheme == .light ? Color.primary.opacity(0.65) : Color(red: 0.18, green: 0.2, blue: 0.235)), lineWidth: 1)
            guard wave.count > 1 else { return }
            var path = Path()
            for (place, value) in wave.enumerated() {
                let point = CGPoint(x: CGFloat(place) / CGFloat(wave.count - 1) * size.width,
                                    y: size.height / 2 - CGFloat(value) * (size.height / 2 - 2))
                if place == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Lamp.colour(kind)), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}
