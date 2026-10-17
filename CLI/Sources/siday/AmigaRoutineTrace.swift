// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayKit

/// What a SoundFX or an Oktalyzer module's player tells the sound chip, a line a tick, for setting
/// beside what the tracker's own routine tells it: nil for a tune of another kind, or if it has not
/// been asked for.
///
/// It is asked for by `SIDAY_SFX_TRACE` or `SIDAY_OKT_TRACE`, with `--raw`. A line is the tick's
/// number, how long the tick before it lasted in the chip's clocks, where the tune was (place in the
/// order, line and tick of the line), and then everything written to the chip in the order it was
/// written: the voice, a letter for what was written (P a period, V a volume, C where to play from,
/// N how many words), and the number. Where to play from is a place in the file, or `x` for one that
/// is not in it. The song that is written is the one from the top of the file, which is what the
/// routine plays, unless another is asked for by number.
///
/// For SoundFX the variable may name the places in the order of playing to play, as `first,end`, in
/// place of the song that is asked for. For Oktalyzer, `SIDAY_OKT_WORDS` names a file of how many
/// words the routine was seen to mix on each tick, a line a tick and a number for each split voice,
/// to be gone by; and what is mixed on each tick is written to the file `SIDAY_OKT_MIXED` names: for
/// each tick and each split voice, how many bytes, in two bytes, and then the bytes.
func amigaRoutineTrace(of renderer: any Renderer, subsong: Int?, seconds: Double) throws -> String? {
    let environment = ProcessInfo.processInfo.environment
    func letter(_ index: Int) -> String { ["P", "V", "C", "N"][index] }
    func line(_ number: Int, _ before: Int, _ position: Int, _ row: Int, _ tick: Int, _ writes: [String]) -> String {
        "\(number) \(before) \(position):\(row).\(tick) | " + writes.joined(separator: " ") + "\n"
    }

    if let asked = environment["SIDAY_SFX_TRACE"], let soundFX = renderer as? SoundFXRenderer {
        soundFX.select(subsong: (subsong ?? 1) - 1)
        let numbers = asked.split(separator: ",").compactMap { Int($0) }
        let places: (first: Int, end: Int?)? = asked.contains(",") && !numbers.isEmpty ? (numbers[0], numbers.count > 1 ? numbers[1] : nil) : nil
        var text = ""
        var before = 0
        for (number, tick) in soundFX.registerTicks(seconds: seconds, places: places).enumerated() {
            let writes = tick.writes.map { write in
                let kind: Int = switch write.register {
                case .period: 0
                case .volume: 1
                case .location: 2
                case .length: 3
                }
                return "\(write.voice)\(letter(kind))" + (kind == 2 && write.value < 0 ? "x" : "\(write.value)")
            }
            text += line(number, before, tick.position, tick.line, tick.tickOfLine, writes)
            before = tick.clocks
        }
        return text
    }

    if environment["SIDAY_OKT_TRACE"] != nil, let oktalyzer = renderer as? OktalyzerRenderer {
        oktalyzer.select(subsong: (subsong ?? 1) - 1)
        var wordsSeen: [[Int]]?
        if let path = environment["SIDAY_OKT_WORDS"] {
            wordsSeen = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(separator: " ").compactMap { Int($0) } }
        }
        var text = ""
        var before = 0
        var mixed = Data()
        for (number, tick) in oktalyzer.registerTicks(seconds: seconds, wordsSeen: wordsSeen).enumerated() {
            let writes = tick.writes.map { write in
                let kind: Int = switch write.register {
                case .period: 0
                case .volume: 1
                case .location: 2
                case .length: 3
                }
                return "\(write.voice)\(letter(kind))" + (kind == 2 && write.value < 0 ? "x" : "\(write.value)")
            }
            text += line(number, before, tick.position, tick.line, tick.tickOfLine, writes)
            before = tick.clocks
            for voice in tick.mixed where !voice.isEmpty {
                mixed.append(contentsOf: [UInt8(voice.count & 0xFF), UInt8(voice.count >> 8)])
                mixed.append(contentsOf: voice.map { UInt8(bitPattern: $0) })
            }
        }
        if let path = environment["SIDAY_OKT_MIXED"] { try mixed.write(to: URL(fileURLWithPath: path)) }
        return text
    }
    return nil
}
