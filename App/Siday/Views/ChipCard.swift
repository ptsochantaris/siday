// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// (Also compiled on its own, with the files that say what the chips are, to draw the web player's
// pictures of them: see Scripts/chip-pictures.swift.)
#if canImport(SidayPlayer)
import SidayPlayer
#endif
import SwiftUI

/// The picture of a tune: the chip it is heard as made by, as the app's icon has its own, worn and
/// grainy on a board of the colour of the machine or the card it sat in. Drawn once for each chip at
/// each size, and kept.
struct ChipCard: View {
    let chip: SoundChip
    /// Its side, in points.
    let size: CGFloat
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image = ChipArt.image(chip, side: size, scale: scale) {
                Image(decorative: image, scale: scale)
                    .resizable()
            } else {
                Rectangle().fill(chip.face.board)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.16))
        .accessibilityElement()
        .accessibilityLabel(chip.face.spoken)
    }
}

extension SoundChip {
    /// How a chip is drawn: its name as it is known, shortened for a small picture; its part
    /// number, as printed on it where that is known; the machines or cards it was in; the colour of
    /// their boards; and its package, a DIP's pins along two sides, a square one's along four, a side's
    /// worth given (as many as it has, unless that is too many to see).
    struct Face {
        let name: String
        let short: String
        let part: String
        let machine: String
        let board: Color
        let pinsASide: Int
        let square: Bool

        /// What the picture is, for those who cannot see it.
        var spoken: String { String(localized: "\(name) chip, \(part), \(machine.replacingOccurrences(of: " · ", with: ", "))") }
    }

    var face: Face {
        // (The ZX Spectrum's board, orange-brown; the Gravis Ultrasound's famously red, Creative's
        // green; the AdLib Gold's for the FM chips; and the SID blue, as it always is in the mind.)
        let spectrum = Color(red: 0.62, green: 0.36, blue: 0.15)
        let gold = Color(red: 0.68, green: 0.53, blue: 0.16)
        switch self {
        case .sid6581: return Face(name: "SID", short: "SID", part: "MOS 6581", machine: "Commodore 64", board: Color(red: 0.18, green: 0.24, blue: 0.58), pinsASide: 14, square: false)
        case .sid8580: return Face(name: "SID", short: "SID", part: "CSG 8580", machine: "Commodore 64C", board: Color(red: 0.18, green: 0.24, blue: 0.58), pinsASide: 14, square: false)
        case .ay8912: return Face(name: "AY", short: "AY", part: "AY-3-8912", machine: "ZX Spectrum · Amstrad CPC", board: spectrum, pinsASide: 14, square: false)
        case .ay8910: return Face(name: "AY", short: "AY", part: "AY-3-8910", machine: "General Instrument", board: spectrum, pinsASide: 20, square: false)
        case .ym2149: return Face(name: "YM", short: "YM", part: "YM2149F", machine: "Atari ST", board: Color(red: 0.30, green: 0.34, blue: 0.40), pinsASide: 20, square: false)
        case .ula: return Face(name: "ULA", short: "ULA", part: "Ferranti ULA", machine: "ZX Spectrum beeper", board: spectrum, pinsASide: 20, square: false)
        case .pokey: return Face(name: "POKEY", short: "POKEY", part: "C012294", machine: "Atari 400 · 800 · XL · XE", board: Color(red: 0.36, green: 0.24, blue: 0.15), pinsASide: 20, square: false)
        case .paula: return Face(name: "PAULA", short: "PAULA", part: "MOS 8364", machine: "Amiga", board: Color(red: 0.05, green: 0.38, blue: 0.34), pinsASide: 24, square: false)
        case .opl2: return Face(name: "OPL2", short: "OPL2", part: "YM3812", machine: "AdLib · Sound Blaster", board: gold, pinsASide: 12, square: false)
        case .opl3: return Face(name: "OPL3", short: "OPL3", part: "YMF262", machine: "Sound Blaster Pro 2 · 16", board: gold, pinsASide: 12, square: false)
        case .saa1099: return Face(name: "SAA", short: "SAA", part: "SAA1099", machine: "SAM Coupé · Game Blaster", board: Color(red: 0.40, green: 0.18, blue: 0.36), pinsASide: 14, square: false)
        case .sn76489: return Face(name: "SN", short: "SN", part: "SN76489", machine: "BBC Micro · PCjr · Sega", board: Color(red: 0.16, green: 0.36, blue: 0.48), pinsASide: 8, square: false)
        case .gf1: return Face(name: "GF1", short: "GF1", part: "ICS11614", machine: "Gravis Ultrasound", board: Color(red: 0.62, green: 0.11, blue: 0.11), pinsASide: 25, square: true)
        case .sbPro: return Face(name: "SB PRO", short: "SB", part: "CT1341", machine: "Sound Blaster Pro", board: Color(red: 0.10, green: 0.40, blue: 0.18), pinsASide: 20, square: false)
        case .dac: return Face(name: "DAC", short: "DAC", part: "PCM", machine: "recording", board: Color(white: 0.34), pinsASide: 8, square: false)
        case .la32: return Face(name: "LA32", short: "LA32", part: "Roland LA32", machine: "LAPC-I · CM-32L · MT-32", board: Color(red: 0.06, green: 0.28, blue: 0.24), pinsASide: 20, square: true)
        case .sc55: return Face(name: "SC-55", short: "SC-55", part: "Roland PCM", machine: "Sound Canvas SC-55", board: Color(red: 0.17, green: 0.18, blue: 0.21), pinsASide: 20, square: true)
        case .sc55mk2: return Face(name: "SC-55mkII", short: "SC-55", part: "Roland PCM", machine: "Sound Canvas SC-55mkII", board: Color(red: 0.17, green: 0.18, blue: 0.21), pinsASide: 20, square: true)
        }
    }
}

/// The chips' pictures, drawn as they are first wanted at each size, and kept.
@MainActor
enum ChipArt {
    private static var drawn: [String: CGImage] = [:]

    /// A chip's picture, `side` points square at `scale` pixels to the point.
    static func image(_ chip: SoundChip, side: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(chip.rawValue) \(Int(side)) \(Int(scale * 10))"
        if let image = drawn[key] { return image }
        let renderer = ImageRenderer(content: ChipDrawing(face: chip.face, seed: chip.rawValue).frame(width: side, height: side))
        renderer.scale = scale
        let image = renderer.cgImage
        drawn[key] = image
        return image
    }

    #if os(macOS)
    /// For the system's Now Playing: a picture large enough for anywhere it is shown.
    static func artwork(_ chip: SoundChip) -> NSImage? {
        image(chip, side: 600, scale: 2).map { NSImage(cgImage: $0, size: NSSize(width: 600, height: 600)) }
    }
    #else
    static func artwork(_ chip: SoundChip) -> UIImage? {
        image(chip, side: 600, scale: 2).map { UIImage(cgImage: $0, scale: 2, orientation: .up) }
    }
    #endif
}

/// The drawing itself: the board, its traces and pads, the pins, the package and its grain, and the
/// printing on it, worn. The same chip always comes out the same: its grain is from a seed of its own.
private struct ChipDrawing: View {
    let face: SoundChip.Face
    let seed: String

    /// A small repeatable source of chance.
    private struct Dice {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }

    private static let ink = Color(red: 0.86, green: 0.85, blue: 0.80)

    var body: some View {
        Canvas { context, size in
            let s = size.width
            // (Below this, only the chip's short name, large, and none of the finer detail.)
            let small = s < 100
            var dice = Dice(state: seed.unicodeScalars.reduce(UInt64(7)) { $0 &* 31 &+ UInt64($1.value) })
            func dot(_ x: Double, _ y: Double, _ r: Double) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }

            // The board: its colour, darker towards the edges, with traces running to pads.
            let all = Path(CGRect(origin: .zero, size: size))
            context.fill(all, with: .color(face.board))
            context.fill(all, with: .radialGradient(Gradient(colors: [.clear, .black.opacity(0.45)]), center: CGPoint(x: s / 2, y: s / 2), startRadius: s * 0.25, endRadius: s * 0.75))
            if !small {
                for _ in 0 ..< 22 {
                    let fromLeft = dice.next() < 0.5
                    let y = dice.next() * s
                    let x1 = fromLeft ? s * (0.05 + dice.next() * 0.1) : s * (0.85 + dice.next() * 0.1)
                    let bend = (dice.next() - 0.5) * s * 0.12
                    let end = CGPoint(x: x1 + (fromLeft ? 1 : -1) * abs(bend), y: y + bend)
                    var trace = Path()
                    trace.move(to: CGPoint(x: fromLeft ? 0 : s, y: y))
                    trace.addLine(to: CGPoint(x: x1, y: y))
                    trace.addLine(to: end)
                    context.stroke(trace, with: .color(.white.opacity(0.15)), lineWidth: s * 0.006)
                    context.fill(dot(end.x, end.y, s * 0.009), with: .color(Color(white: 0.75).opacity(0.5)))
                }
            }

            // The package, and its pins along two sides, or four.
            let bodyW = s * (face.square ? 0.66 : 0.8)
            let bodyH = face.square ? bodyW : s * (small ? 0.56 : 0.48)
            let body = CGRect(x: (s - bodyW) / 2, y: (s - bodyH) / 2, width: bodyW, height: bodyH)
            let pins = small ? min(face.pinsASide, 10) : face.pinsASide
            let reach = s * (face.square ? 0.06 : 0.075)
            let shine = Gradient(colors: [Color(white: 0.55), Color(white: 0.92), Color(white: 0.62)])
            func pinRow(along length: Double, place: (Double, Double) -> CGRect) {
                let pitch = length / Double(pins)
                for i in 0 ..< pins {
                    let rect = place(Double(i) * pitch + pitch * 0.24, pitch * 0.52)
                    let across = rect.width < rect.height
                    context.fill(Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.15),
                                 with: .linearGradient(shine, startPoint: rect.origin, endPoint: across ? CGPoint(x: rect.maxX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.maxY)))
                }
            }
            let inset = bodyW * 0.04
            pinRow(along: bodyW - inset * 2) { at, w in CGRect(x: body.minX + inset + at, y: body.minY - reach * 0.85, width: w, height: reach) }
            pinRow(along: bodyW - inset * 2) { at, w in CGRect(x: body.minX + inset + at, y: body.maxY - reach * 0.15, width: w, height: reach) }
            if face.square {
                pinRow(along: bodyH - inset * 2) { at, w in CGRect(x: body.minX - reach * 0.85, y: body.minY + inset + at, width: reach, height: w) }
                pinRow(along: bodyH - inset * 2) { at, w in CGRect(x: body.maxX - reach * 0.15, y: body.minY + inset + at, width: reach, height: w) }
            }

            let corner = s * 0.018
            let outline = Path(roundedRect: body, cornerRadius: corner)
            var shadow = context
            shadow.addFilter(.blur(radius: s * 0.025))
            shadow.fill(Path(roundedRect: body.offsetBy(dx: 0, dy: s * 0.015), cornerRadius: corner), with: .color(.black.opacity(0.6)))
            context.fill(outline, with: .linearGradient(Gradient(colors: [Color(white: 0.23), Color(white: 0.16)]), startPoint: body.origin, endPoint: CGPoint(x: body.maxX, y: body.maxY)))

            // The grain of the plastic: fine flecks, light and dark, and a few larger pits.
            var plastic = context
            plastic.clip(to: outline)
            let area = bodyW * bodyH / (s * s)
            for _ in 0 ..< Int((small ? 300 : 5200) * area) {
                let pit = dice.next() < 0.04
                let r = s * (pit ? 0.002 + dice.next() * 0.003 : 0.0007 + dice.next() * 0.0013)
                let light = !pit && dice.next() < 0.55
                plastic.fill(dot(body.minX + dice.next() * bodyW, body.minY + dice.next() * bodyH, r),
                             with: .color(light ? Color(white: 0.5).opacity(0.18 + dice.next() * 0.2) : .black.opacity(0.3 + dice.next() * 0.3)))
            }
            // The notch at a DIP's end, or the dimple by a square one's first pin.
            if face.square {
                plastic.fill(dot(body.minX + bodyW * 0.12, body.maxY - bodyW * 0.12, bodyW * 0.035), with: .color(.black.opacity(0.35)))
            } else {
                plastic.fill(dot(body.minX, body.midY, bodyH * 0.09), with: .color(Color(white: 0.08)))
            }

            // The printing, a little worn.
            var printing = plastic
            printing.addFilter(.shadow(color: Self.ink.opacity(0.25), radius: s * 0.004))
            func lettered(_ text: String, size: Double, weight: Font.Weight, mono: Bool = false, tracking: Double = 0, opacity: Double = 1) -> Text {
                Text(verbatim: text).font(.system(size: size, weight: weight, design: mono ? .monospaced : .default)).tracking(tracking).foregroundColor(Self.ink.opacity(opacity))
            }
            if small {
                let name = face.short
                let size = s * (name.count > 4 ? 0.15 : name.count > 3 ? 0.18 : 0.22)
                printing.draw(lettered(name, size: size, weight: .black, tracking: size * 0.06), at: CGPoint(x: body.midX, y: body.midY))
            } else {
                let size = s * (face.name.count > 6 ? 0.087 : face.name.count > 4 ? 0.13 : face.name.count > 3 ? 0.16 : 0.2)
                printing.draw(lettered(face.name, size: size, weight: .black, tracking: size * 0.08), at: CGPoint(x: body.midX, y: body.minY + bodyH * (face.square ? 0.38 : 0.4)))
                printing.draw(lettered(face.part.uppercased(), size: s * 0.05, weight: .semibold, mono: true, opacity: 0.9), at: CGPoint(x: body.midX, y: body.minY + bodyH * (face.square ? 0.62 : 0.7)))
                printing.draw(lettered(face.machine.uppercased(), size: s * 0.03, weight: .medium, mono: true, tracking: s * 0.002, opacity: 0.7), at: CGPoint(x: body.midX, y: body.minY + bodyH * (face.square ? 0.74 : 0.85)))
            }
            // Wear: specks of the plastic over the ink.
            for _ in 0 ..< Int((small ? 60 : 900) * area) {
                let r = s * (0.0008 + dice.next() * 0.002)
                plastic.fill(dot(body.minX + dice.next() * bodyW, body.minY + dice.next() * bodyH, r), with: .color(Color(white: 0.17).opacity(0.8)))
            }
            // A soft light from above.
            plastic.fill(outline, with: .linearGradient(Gradient(colors: [.white.opacity(0.07), .clear, .black.opacity(0.12)]), startPoint: CGPoint(x: body.midX, y: body.minY), endPoint: CGPoint(x: body.midX, y: body.maxY)))
        }
    }
}
