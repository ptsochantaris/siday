// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
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
        let columns = scopes
            ? [GridItem(.adaptive(minimum: 64, maximum: 96), spacing: 6)]
            : [GridItem(.adaptive(minimum: min(lampSize, 24), maximum: lampSize), spacing: 0)]
        LazyVGrid(columns: columns, alignment: .center, spacing: 6) {
            ForEach(0 ..< count, id: \.self) { voice in
                Light(voice: voice, level: frame.lights[voice],
                      kind: voice < frame.kinds.count ? frame.kinds[voice] : .chip,
                      muted: voice < frame.muted.count && frame.muted[voice],
                      wave: scopes ? Array(frame.scopes.dropFirst(voice * ChannelWaves.points).prefix(ChannelWaves.points)) : nil,
                      lamp: lamps, lampSize: lampSize, scopeHeight: scopeHeight)
            }
        }
        .frame(maxWidth: scopes ? CGFloat(min(8, max(1, count))) * 102 : CGFloat(count) * lampSize)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voices")
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
    let lampSize: CGFloat
    let scopeHeight: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            if lamp {
                let size = wave == nil ? lampSize : 24
                Lamp(level: level, kind: kind)
                    .frame(width: size, height: size)
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
/// web player's lamps have. In the dark the glass is dark, as the web player's; in the light it is a
/// paler glass of the same colour.
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

    /// The trace of a voice's scope: its lamp's colour, a little deeper on a light ground so that it
    /// stands out from it.
    static func trace(_ kind: VoiceKind, _ scheme: ColorScheme) -> Color {
        guard scheme == .light else { return colour(kind) }
        switch kind {
        case .chip: return Color(red: 0.83, green: 0.16, blue: 0.08)
        case .sample: return Color(red: 0.10, green: 0.37, blue: 0.84)
        case .speaker: return Color(red: 0.80, green: 0.18, blue: 0.65)
        }
    }

    /// The glass, lit from above on the left: its light side and its shaded side.
    private static func glass(_ kind: VoiceKind, _ scheme: ColorScheme) -> [Color] {
        if scheme == .light {
            switch kind {
            case .chip: return [Color(red: 0.97, green: 0.87, blue: 0.85), Color(red: 0.88, green: 0.72, blue: 0.70)]
            case .sample: return [Color(red: 0.86, green: 0.90, blue: 0.97), Color(red: 0.71, green: 0.77, blue: 0.89)]
            case .speaker: return [Color(red: 0.96, green: 0.86, blue: 0.93), Color(red: 0.87, green: 0.71, blue: 0.83)]
            }
        }
        switch kind {
        case .chip: return [Color(red: 0.42, green: 0.11, blue: 0.09), Color(red: 0.13, green: 0.03, blue: 0.03)]
        case .sample: return [Color(red: 0.09, green: 0.19, blue: 0.43), Color(red: 0.03, green: 0.06, blue: 0.15)]
        case .speaker: return [Color(red: 0.42, green: 0.11, blue: 0.33), Color(red: 0.15, green: 0.03, blue: 0.12)]
        }
    }

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let level = CGFloat(max(0, min(1, level)))
            // The lamp is half the place; its glow is as wide as the place when bright, and fainter than
            // its level, so a loud voice stands out from a quiet one and a note is seen to die away.
            let glass = CGRect(x: centre.x - side / 4, y: centre.y - side / 4, width: side / 2, height: side / 2)
            let colours = Self.glass(kind, scheme)
            context.fill(Path(ellipseIn: glass), with: .radialGradient(Gradient(colors: colours), center: CGPoint(x: glass.minX + glass.width * 0.38, y: glass.minY + glass.height * 0.32), startRadius: 0, endRadius: side / 4))
            // The ring: on the web player's dark panel nearly black; on a light ground a soft grey.
            let ring = scheme == .light ? Color(white: 0.45, opacity: 0.55) : Color(red: 0.047, green: 0.051, blue: 0.063)
            context.stroke(Path(ellipseIn: glass.insetBy(dx: -0.5, dy: -0.5)), with: .color(ring), lineWidth: 1)
            let glow = level * level.squareRoot()
            guard glow > 0.01 else { return }
            let radius = side / 2 * (0.5 + 0.5 * level)
            let colour = Self.colour(kind)
            context.opacity = glow
            context.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                         with: .radialGradient(Gradient(stops: [
                             .init(color: colour, location: 0), .init(color: colour, location: 0.46),
                             .init(color: colour.opacity(0.5), location: 0.55), .init(color: colour.opacity(0.18), location: 0.7),
                             .init(color: colour.opacity(0), location: 1),
                         ]), center: centre, startRadius: 0, endRadius: radius))
        }
    }
}

/// A voice's wave, in the colour of its lamp, on a ground of its own: dark in the dark, as the web
/// player's, and pale in the light, with a line round it.
struct Scope: View {
    let wave: [Float]
    let kind: VoiceKind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let ground = Path(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6)
            if scheme == .light {
                context.fill(ground, with: .color(Color(white: 0.955)))
                context.stroke(ground, with: .color(Color(white: 0.78)), lineWidth: 1)
            } else {
                // (The web player's paper and line.)
                context.fill(ground, with: .color(Color(red: 0.078, green: 0.086, blue: 0.102)))
                context.stroke(ground, with: .color(Color(red: 0.18, green: 0.2, blue: 0.235)), lineWidth: 1)
            }
            guard wave.count > 1 else { return }
            var path = Path()
            for (place, value) in wave.enumerated() {
                let point = CGPoint(x: CGFloat(place) / CGFloat(wave.count - 1) * size.width,
                                    y: size.height / 2 - CGFloat(value) * (size.height / 2 - 2))
                if place == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Lamp.trace(kind, scheme)), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
    }
}
