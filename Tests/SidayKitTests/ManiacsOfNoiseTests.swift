// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the players of the Maniacs of Noise's drivers, on tiny modules assembled here by hand:
// drivers laid out as theirs are, which the players' checks take and find their way about, and whose
// songs end and stop as the players have them end and stop. The thorough check is made outside the
// package: what every one of UnExoticA's modules writes to Paula, tick by tick and song by song, against
// what it writes in UADE.

// MARK: Charles Deenen's driver

/// A module for Charles Deenen's driver, as small as one can be: the three jumps, a line of text, the
/// routine that readies it (leaving A1 at its volume), the one that starts a song (one of three, each a
/// pattern of periods for the first voice, which it sets going on a sample) and the one that plays a
/// tick: the next period of the pattern, which at a nought starts again, at $FFFF stops the driver with
/// the voice still sounding, and at $FFFE fades it out (turns its DMA off and stops the driver).
private func deenen() -> [UInt8] {
    var c = AmigaCode(at: ManiacsOfNoisePlayer.moduleAddress)
    c.w(0x4EFA); c.to("init")
    c.w(0x4EFA); c.to("play")
    c.w(0x4EFA); c.to("song")
    c.bytes(Array("  Music by nobody  ".utf8) + [0])
    c.label("init")
    c.w(0x4BFA); c.to("vars") // LEA vars(PC),A5
    c.w(0x08AD, 0x0000, 0x019A) // BCLR #0,$19A(A5)
    c.w(0x43ED, 0x0044) // LEA 68(A5),A1
    c.w(0x4E75)
    c.label("song")
    c.w(0x4BFA); c.to("vars") // LEA vars(PC),A5
    c.w(0x0280, 0x0000, 0x00FF) // ANDI.L #$FF,D0
    c.w(0x6700); c.to("ret") // BEQ.W ret
    c.w(0x08AD, 0x0000, 0x019A) // BCLR #0,$19A(A5)
    c.w(0x5300) // SUBQ.B #1,D0
    c.w(0xB02D, 0x01AC) // CMP.B $1AC(A5),D0
    c.w(0x6C00); c.to("ret") // BGE.W ret
    c.w(0x4880, 0xD040) // EXT.W D0; ADD.W D0,D0
    c.w(0x41FA); c.to("patterns") // LEA patterns(PC),A0
    c.w(0xD0F0, 0x0000) // ADDA.W 0(A0,D0.W),A0
    c.w(0x2B48, 0x0050, 0x2B48, 0x0054) // MOVE.L A0,80(A5); MOVE.L A0,84(A5)
    c.w(0x41FA); c.to("sound") // LEA sound(PC),A0
    c.w(0x23C8, 0x00DF, 0xF0A0) // MOVE.L A0,$DFF0A0
    c.w(0x33FC, 0x0008, 0x00DF, 0xF0A4) // MOVE.W #8,$DFF0A4
    c.w(0x33FC, 0x0040, 0x00DF, 0xF0A8) // MOVE.W #64,$DFF0A8
    c.w(0x33FC, 0x8201, 0x00DF, 0xF096) // MOVE.W #$8201,$DFF096
    c.w(0x08ED, 0x0000, 0x019A) // BSET #0,$19A(A5)
    c.label("ret")
    c.w(0x4E75)
    c.label("play")
    c.w(0x4BFA); c.to("vars") // LEA vars(PC),A5
    c.w(0x082D, 0x0000, 0x019A) // BTST #0,$19A(A5)
    c.w(0x6700); c.to("done") // BEQ.W done
    c.w(0x206D, 0x0054, 0x3018) // MOVEA.L 84(A5),A0; MOVE.W (A0)+,D0
    c.w(0x6700); c.to("wrap") // BEQ.W wrap
    c.w(0xB07C, 0xFFFF, 0x6700); c.to("halt") // CMP.W #$FFFF,D0; BEQ.W halt
    c.w(0xB07C, 0xFFFE, 0x6700); c.to("fade") // CMP.W #$FFFE,D0; BEQ.W fade
    c.w(0x2B48, 0x0054) // MOVE.L A0,84(A5)
    c.w(0x33C0, 0x00DF, 0xF0A6) // MOVE.W D0,$DFF0A6
    c.w(0x4E75)
    c.label("wrap")
    c.w(0x2B6D, 0x0050, 0x0054, 0x4E75) // MOVE.L 80(A5),84(A5); RTS
    c.label("halt")
    c.w(0x08AD, 0x0000, 0x019A, 0x4E75) // BCLR #0,$19A(A5); RTS
    c.label("fade")
    c.w(0x33FC, 0x000F, 0x00DF, 0xF096) // MOVE.W #$F,$DFF096
    c.w(0x08AD, 0x0000, 0x019A) // BCLR #0,$19A(A5)
    c.label("done")
    c.w(0x4E75)
    c.label("patterns")
    c.w(0, 0, 0)
    c.label("a")
    c.w(0x100, 0x200, 0)
    c.label("b")
    c.w(0x100, 0xFFFF)
    c.label("c")
    c.w(0x100, 0xFFFE)
    c.label("sound")
    c.bytes([UInt8](repeating: 0x40, count: 8) + [UInt8](repeating: 0xC0, count: 8))
    c.label("vars")
    c.words += [UInt16](repeating: 0, count: 0x1B0 / 2)
    let patterns = c.offset("patterns")
    for (i, name) in ["a", "b", "c"].enumerated() { c.words[patterns / 2 + i] = UInt16(c.offset(name) - patterns) }
    // Three songs.
    c.words[(c.offset("vars") + 0x1AC) / 2] = 0x0300
    return c.assembled()
}

@Test func maniacsOfNoiseModulesAreFoundTheirWayAbout() throws {
    let data = deenen()
    #expect(ManiacsOfNoisePlayer.isOne(data))
    let layout = try ManiacsOfNoisePlayer.Layout(data)
    #expect(layout.initAt == 0x20 && layout.flags == 0x19A && layout.voicesAt == 72 && layout.voiceSize == 84)
    #expect(layout.songCount == 3)
    #expect(layout.text == "Music by nobody")
    // Not theirs: a file whose first jump is not one, or whose first routine does not begin as theirs do.
    #expect(!ManiacsOfNoisePlayer.isOne([0x4E, 0x71] + Array(data.dropFirst(2))))
    var other = data
    other[0x20] = 0x41
    #expect(!ManiacsOfNoisePlayer.isOne(other))
    #expect(!ManiacsOfNoisePlayer.isOne([UInt8](repeating: 0, count: 256)))
    #expect(throws: TuneError.self) { let _ = try ManiacsOfNoisePlayer([UInt8](repeating: 0x4E, count: 300)) }
}

/// What Paula is told, as a list.
private struct Told: TFMXOutput {
    var periods: [String] = []
    var volumes: [UInt16] = []
    var buffers: [Int] = []
    var starts = 0
    mutating func on(_: Int) { starts += 1 }
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start: Int, length _: UInt16) { buffers.append(start) }
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { periods.append("\(voice):\(period)") }
    mutating func writeVolume(_: Int, _ volume: UInt16) { volumes.append(volume) }
}

@Test func maniacsOfNoiseSongsEndAndStopAsThePlayerHasThem() throws {
    let tick = UInt64(ManiacsOfNoisePlayer.tickClocks)
    // The first song: its voice is where it was on the fourth tick, which is the first again.
    var player = try ManiacsOfNoisePlayer(deenen())
    #expect(player.songCount == 3)
    #expect(player.lengthClocks == 3 * tick)
    #expect(player.tuneInfo.format == "Maniacs of Noise")
    var ticks: [[String]] = []
    for _ in 0 ..< 7 {
        var told = Told()
        _ = player.run(&told)
        ticks.append(told.periods.filter { $0.hasPrefix("0:") && $0 != "0:150" })
    }
    #expect(ticks == [["0:256"], ["0:512"], [], ["0:256"], ["0:512"], [], ["0:256"]])
    // (Once each time round.)
    #expect(player.endings == 2)
    #expect(player.stops == 0)
    // The second: stopped by the driver with its voice sounding, which is its end; the third faded out,
    // which is its stopping.
    try player.select(song: 1)
    #expect(player.lengthClocks == tick)
    for _ in 0 ..< 4 {
        var told = Told()
        _ = player.run(&told)
    }
    #expect(player.endings == 1 && player.stops == 0)
    try player.select(song: 2)
    #expect(player.lengthClocks == tick)
    var told = Told()
    _ = player.run(&told)
    _ = player.run(&told)
    #expect(player.stops == 1)
}

@Test func maniacsOfNoiseModulesAreHeard() throws {
    var options = LoadOptions()
    options.stereo = .abc
    let renderer = try PaulaTickRenderer(ManiacsOfNoisePlayer(deenen()), options: options)
    #expect(renderer.subsongCount == 3)
    #expect(abs((renderer.songs[0].length ?? 0) - 3 * Double(ManiacsOfNoisePlayer.tickClocks) / Paula.clockHz) < 1e-9)
    let frames = outputSampleRate / 5
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: frames)
    var loudest: Float = 0
    for i in 0 ..< frames * 2 { loudest = max(loudest, abs(buffer[i])) }
    #expect(loudest > 0.05)
    #expect(renderer.loopCount >= 1)
}

// MARK: Jeroen Tel's driver

/// Where the little driver of Jeroen Tel's below was, in the game it is taken from.
private let telOrigin: UInt32 = 0x30000

/// A module of Jeroen Tel's driver, as small as one can be, laid out as the driver is: its first half
/// of a tick (whose first voice steps through its list, a note a tick: the note's period from the table
/// of periods, read in both of the ways the player keeps within the table, a volume louder than 64, and
/// the voice given its instrument's sample to go on to, which has no address), at the end of its list
/// sets it back to the start, and at $FE stops the music); the part of its start that the player finds
/// the table of songs by; its second half (the first voice's period and volume, and its DMA); the routine
/// that stops the music; its variables; the table of periods; two songs; and room, to the size the
/// player's check asks for.
private func tel() -> [UInt8] {
    var c = AmigaCode(at: telOrigin)
    var plusOne: [Int] = []
    func address(_ name: String, plus: Bool = false) {
        if plus { plusOne.append(c.words.count + 1) }
        c.address(name)
    }
    c.w(0x0239, 0x0001); address("P") // ANDI.B #1,P
    c.w(0x6602, 0x4E75) // BNE.S +2; RTS
    c.w(0x7800, 0x1839); address("BC", plus: true) // MOVEQ #0,D4; MOVE.B BD,D4
    c.w(0x5339); address("BA", plus: true) // SUBQ.B #1,BB
    c.w(0x0C39, 0x00FE); address("BA", plus: true) // CMPI.B #$FE,BB
    c.w(0x660A, 0x13F9); address("BC"); address("BA", plus: true) // BNE.S +10; MOVE.B BC,BB
    c.w(0x2A7C); address("T") // MOVEA.L #T,A5
    c.w(0x2A55, 0x266D, 0x001C) // MOVEA.L (A5),A5; MOVEA.L $1C(A5),A3
    c.w(0x7000, 0x102D, 0x0001) // MOVEQ #0,D0; MOVE.B 1(A5),D0
    c.w(0x7200, 0x1233, 0x0000) // MOVEQ #0,D1; MOVE.B 0(A3,D0.W),D1
    c.w(0xB23C, 0x00FF, 0x660C) // CMP.B #$FF,D1; BNE.S +12
    c.w(0x4239); address("v0", plus: true) // CLR.B v0+1
    c.w(0x1213, 0x6000); c.to("note") // MOVE.B (A3),D1; BRA.W note
    c.w(0xB23C, 0x00FE, 0x6606, 0x4EF9); address("stop") // CMP.B #$FE,D1; BNE.S +6; JMP stop
    c.label("note")
    c.w(0x522D, 0x0001) // ADDQ.B #1,1(A5)
    c.w(0x1001, 0x1400, 0xE302, 0x267C); address("periods") // MOVE.B D1,D0; MOVE.B D0,D2; ASL.B #1,D2; MOVEA.L #periods,A3
    c.w(0x3433, 0x2000, 0x3B42, 0x0010) // MOVE.W 0(A3,D2.W),D2; MOVE.W D2,16(A5)
    c.w(0x267C); address("periods") // MOVEA.L #periods,A3
    c.w(0xE301, 0x3B73, 0x1000, 0x000E) // ASL.B #1,D1; MOVE.W 0(A3,D1.W),14(A5)
    c.w(0x3B7C, 0x0090, 0x0012) // MOVE.W #$90,18(A5)
    c.w(0x266D, 0x0018, 0x49F9, 0x00DF, 0xF0A0) // MOVEA.L $18(A5),A3; LEA $DFF0A0,A4
    c.w(0x7600, 0x29AB, 0x0008, 0x3000) // MOVEQ #0,D3; MOVE.L 8(A3),0(A4,D3.W)
    c.w(0x39AB, 0x000C, 0x3004, 0x4E75) // MOVE.W 12(A3),4(A4,D3.W); RTS
    // (The driver's start, which the player does not call.)
    c.w(0x49F9); address("songs") // LEA songs,A4
    c.w(0x23F4, 0x0000); address("v0") // MOVE.L 0(A4,D0.W),v0
    c.w(0x4E75)
    c.label("second")
    c.w(0x0239, 0x0001); address("P") // ANDI.B #1,P
    c.w(0x6602, 0x4E75) // BNE.S +2; RTS
    c.w(0x7800, 0x1839); address("BC", plus: true) // MOVEQ #0,D4; MOVE.B BD,D4
    c.w(0x49F9, 0x00DF, 0xF0A6, 0x7600, 0x2A7C); address("T") // LEA $DFF0A6,A4; MOVEQ #0,D3; MOVEA.L #T,A5
    c.w(0x2A55, 0x162D, 0x0008) // MOVEA.L (A5),A5; MOVE.B 8(A5),D3
    c.w(0x39AD, 0x000E, 0x3000, 0x39AD, 0x0012, 0x3002) // MOVE.W 14(A5),0(A4,D3.W); MOVE.W 18(A5),2(A4,D3.W)
    c.w(0x33ED, 0x0016, 0x00DF, 0xF096, 0x4E75) // MOVE.W 22(A5),$DFF096; RTS
    c.label("stop")
    c.w(0x4239); address("P") // CLR.B P
    c.w(0x33FC, 0x000F, 0x00DF, 0xF096, 0x4E75) // MOVE.W #$F,$DFF096; RTS
    // The variables: a flag of the note, the ticks left of a step, the ticks of a step, the voices, and
    // the byte that says the driver plays (BA, BB, BC, BD, P); and a byte more.
    c.label("BA")
    c.w(0)
    c.label("BC")
    c.w(0)
    c.label("P")
    c.w(0)
    for v in 0 ..< 4 {
        c.label("v\(v)")
        c.words += [UInt16](repeating: 0, count: 20)
    }
    c.label("T")
    for v in 0 ..< 4 { address("v\(v)") }
    c.label("periods")
    let periods: [UInt16] = [856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
                             428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
                             214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113]
    c.words += periods
    c.words += [0, 0, 0, 0]
    c.label("songs")
    for list in ["one", "empty", "empty", "empty", "two", "empty", "empty", "empty"] {
        if list == "two" { c.w(0x0C01) }
        address(list)
    }
    c.w(0x0C01)
    for _ in 0 ..< 4 { address("empty") }
    c.w(0x0C01)
    c.label("one")
    c.bytes([5, 40, 0xFF, 0])
    c.label("two")
    c.bytes([5, 0xFE])
    c.label("empty")
    c.bytes([0xFF, 0])
    c.words += [UInt16](repeating: 0, count: max(0, (1800 - c.here) / 2))
    var bytes = c.assembled()
    // The labels that are a byte past a word (as the variables before the voices' are), and the
    // addresses a byte further on.
    for at in plusOne {
        let low = Int(bytes[2 * at]) << 8 | Int(bytes[2 * at + 1])
        bytes[2 * at] = UInt8((low + 1) >> 8 & 0xFF)
        bytes[2 * at + 1] = UInt8((low + 1) & 0xFF)
    }
    return bytes
}

@Test func jeroenTelModulesAreFoundTheirWayAbout() throws {
    let data = tel()
    #expect(JeroenTelPlayer.isOne(data))
    let layout = try JeroenTelModule(data)
    #expect(layout.origin == telOrigin)
    #expect(layout.playAt == 0 && layout.songCount == 2)
    #expect(layout.voices.count == 4 && layout.voices[1] == layout.voices[0] + 40)
    #expect(layout.voiceTable == layout.voices[0] + 160 && layout.playing == layout.voices[0] - 2)
    #expect(layout.wrapLength == 6 && layout.stopLength == 6)
    // Not his: a file too short for the player's check, or without the driver's start where it looks.
    #expect(!JeroenTelPlayer.isOne(Array(data.prefix(1700))))
    #expect(!JeroenTelPlayer.isOne([UInt8](repeating: 0, count: 40) + data))
    #expect(throws: TuneError.self) { let _ = try JeroenTelPlayer([UInt8](repeating: 0, count: 2000)) }
}

@Test func jeroenTelSongsEndAsThePlayerHasThemEnd() throws {
    let tick = UInt64(JeroenTelPlayer.tickClocks)
    var player = try JeroenTelPlayer(tel())
    #expect(player.tuneInfo.format == "Jeroen Tel")
    // The first song comes to the end of its list on its third tick, which is its first again.
    #expect(player.lengthClocks == 2 * tick)
    var told: [Told] = []
    for _ in 0 ..< 4 {
        var one = Told()
        _ = player.run(&one)
        told.append(one)
    }
    #expect(player.endings == 1 && player.stops == 0)
    // Each note's period, the second's read within the table (its 41st made its 36th); its volume no
    // more than 64; and the sample it goes on to the silence, for an instrument of no address.
    let periods = told.map { $0.periods.filter { $0.hasPrefix("0:") }.last }
    #expect(periods == ["0:640", "0:113", "0:640", "0:113"])
    #expect(told[1].volumes.last == 64)
    #expect(told[1].buffers.contains(Int(telOrigin) + tel().count + 64))
    // The second song stops on its second tick.
    try player.select(song: 1)
    #expect(player.lengthClocks == tick)
}

@Test func jeroenTelModulesAreHeard() throws {
    let renderer = try PaulaTickRenderer(JeroenTelPlayer(tel()), options: LoadOptions())
    #expect(renderer.subsongCount == 2)
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 4000)
    defer { buffer.deallocate() }
    renderer.render(into: buffer, frames: 2000)
    #expect(renderer.loopCount >= 1)
}

// MARK: Damaged files

@Test func maniacsOfNoiseModulesThatAreDamagedAreRefusedOrPlayed() {
    for data in [deenen(), tel()] {
        var refused = 0
        for cut in 0 ..< data.count {
            do {
                let renderer: any Renderer = ManiacsOfNoisePlayer.isOne(data)
                    ? try PaulaTickRenderer(ManiacsOfNoisePlayer(Array(data.prefix(cut))), options: LoadOptions())
                    : try PaulaTickRenderer(JeroenTelPlayer(Array(data.prefix(cut))), options: LoadOptions())
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2000)
                renderer.render(into: buffer, frames: 1000)
                buffer.deallocate()
            } catch {
                refused += 1
            }
        }
        #expect(refused > 0)
        var generator = SplitMix(seed: 7)
        // (Few, for each that plays may be a song that never ends, played through as it is loaded.)
        for i in 0 ..< 40 {
            var copy = data
            for _ in 0 ... i % 6 { copy[Int(generator.next() % UInt64(copy.count))] = UInt8(truncatingIfNeeded: generator.next()) }
            let renderer: (any Renderer)? = ManiacsOfNoisePlayer.isOne(data)
                ? try? PaulaTickRenderer(ManiacsOfNoisePlayer(copy), options: LoadOptions())
                : try? PaulaTickRenderer(JeroenTelPlayer(copy), options: LoadOptions())
            if let renderer {
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 2000)
                renderer.render(into: buffer, frames: 1000)
                buffer.deallocate()
            }
        }
    }
}

/// A small generator of numbers that are the same from run to run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
