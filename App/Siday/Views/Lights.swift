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
