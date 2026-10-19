// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the host of DeliTracker's players and of its custom modules, on tiny modules assembled
// here by hand: what the host calls, in what order and how often, its timer and the player's own, the
// end of a song, a call it does not give, and damaged files. The thorough check is made outside the
// package: what each of UnExoticA's custom modules writes to Paula, tick by tick and song by song,
// against what it writes in UADE.

/// An AmigaDOS program of one code hunk, assembled a word at a time, with labels whose addresses are
/// relocated as LoadSeg would relocate them.
struct HunkProgram {
    private(set) var words: [UInt16] = []
    private var labels: [String: Int] = [:]
    private var absolute: [(at: Int, label: String)] = []
    private var relative: [(at: Int, label: String)] = []

    var here: Int { words.count * 2 }
    mutating func label(_ name: String) { labels[name] = here }
    mutating func w(_ values: UInt16...) { words += values }
    mutating func long(_ value: UInt32) { words += [UInt16(value >> 16), UInt16(value & 0xFFFF)] }
    /// The label's address, as a long, relocated.
    mutating func address(_ name: String) {
        absolute.append((words.count, name))
        words += [0, 0]
    }

    /// A displacement to `label` from this word's place (a BSR.W, DBcc or d16(PC)).
    mutating func to(_ name: String) {
        relative.append((words.count, name))
        words.append(0)
    }

    func offset(_ name: String) -> Int { labels[name]! }

    /// The program's file: its header, its hunk, and its relocations.
    func file() -> [UInt8] {
        var words = self.words
        if words.count % 2 == 1 { words.append(0) }
        for (at, name) in absolute {
            words[at] = UInt16(labels[name]! >> 16)
            words[at + 1] = UInt16(labels[name]! & 0xFFFF)
        }
        for (at, name) in relative { words[at] = UInt16(truncatingIfNeeded: labels[name]! - at * 2) }
        func long(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let longs = words.count / 2
        var bytes = long(0x3F3) + long(0) + long(1) + long(0) + long(0) + long(0x4000_0000 | longs) + long(0x3E9) + long(longs)
        for word in words { bytes += [UInt8(word >> 8), UInt8(word & 0xFF)] }
        bytes += long(0x3EC) + long(absolute.count) + long(0)
        for (at, _) in absolute { bytes += long(at * 2) }
        bytes += long(0) + long(0x3F2)
        return bytes
    }
}

/// A custom module: its tags, and routines that count how often they are called and say so on Paula.
/// Its DTP_Interrupt adds one to its count and writes it to AUD0PER; its DTP_InitSound writes the song's
/// number to AUD1PER; its range of songs is 0 to 2. `timer` set, DTP_InitSound sets `dtg_Timer` to it
/// and calls `dtg_SetTimer`; `endAt` set, DTP_Interrupt calls `dtg_SongEnd` when its count comes to it;
/// `initPlayer` is code put at the start of DTP_InitPlayer.
private func custom(timer: UInt16? = nil, endAt: UInt16? = nil, initPlayer: [UInt16] = [], tags extra: [UInt32] = []) -> [UInt8] {
    var p = HunkProgram()
    p.w(0x70FF, 0x4E75, 0x4445, 0x4C49, 0x5249, 0x554D) // MOVEQ #-1,D0; RTS; "DELIRIUM"
    p.address("tags")
    p.label("tags")
    for (tag, routine) in [(DeliTag.customPlayer, nil), (DeliTag.interrupt, "interrupt"), (DeliTag.initSound, "initSound"),
                           (DeliTag.initPlayer, "initPlayer"), (DeliTag.subSongRange, "range"), (DeliTag.playerName, "name")] as [(UInt32, String?)]
    {
        p.long(tag)
        if let routine { p.address(routine) } else { p.long(0) }
    }
    for tag in extra {
        p.long(tag)
        p.long(0)
    }
    p.long(0)
    p.long(0)
    p.label("interrupt")
    p.w(0x41F9)
    p.address("count") // LEA count,A0
    p.w(0x5250, 0x33D0, 0x00DF, 0xF0A6) // ADDQ.W #1,(A0); MOVE.W (A0),$DFF0A6
    if let endAt {
        p.w(0x0C50, endAt, 0x6606) // CMPI.W #endAt,(A0); BNE.S +6
        p.w(0x206D, 0x005C, 0x4E90) // MOVEA.L dtg_SongEnd(A5),A0; JSR (A0)
    }
    p.w(0x7000, 0x4E75)
    p.label("initPlayer")
    for word in initPlayer { p.w(word) }
    p.w(0x206D, 0x004C, 0x4ED0) // MOVEA.L dtg_AudioAlloc(A5),A0; JMP (A0)
    p.label("initSound")
    p.w(0x33ED, 0x002C, 0x00DF, 0xF0B6) // MOVE.W dtg_SndNum(A5),$DFF0B6
    if let timer {
        p.w(0x3B7C, timer, 0x0036) // MOVE.W #timer,dtg_Timer(A5)
        p.w(0x206D, 0x0064, 0x4E90) // MOVEA.L dtg_SetTimer(A5),A0; JSR (A0)
    }
    p.w(0x7000, 0x4E75)
    p.label("range")
    p.w(0x7000, 0x7202, 0x4E75) // MOVEQ #0,D0; MOVEQ #2,D1; RTS
    p.label("name")
    p.w(0x5465, 0x7374, 0x0000) // "Test"
    p.label("count")
    p.w(0)
    return p.file()
}

private struct Writes: TFMXOutput {
    var periods: [(Int, UInt16)] = []
    mutating func on(_: Int) {}
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { periods.append((voice, period)) }
}

@Test func deliCustomsAreCalledAsUADEsHostCallsThem() throws {
    let file = custom()
    #expect(DeliCustomPlayer.isOne(file))
    var p = try DeliCustomPlayer(file, song: 1)
    #expect(p.songCount == 3)
    #expect(p.tuneInfo.format == "DeliTracker custom")
    #expect(p.tuneInfo.detail == "Test")
    // A custom module that does not end plays on.
    #expect(p.lengthClocks == nil)
    var out = Writes()
    for _ in 0 ..< 5 { _ = p.run(&out) }
    // DTP_InitSound told the song (as the player numbers them), then DTP_Interrupt once a tick, fifty
    // times a second (CIA-A's timer B from $376B).
    #expect(out.periods.first { $0.0 == 1 && $0.1 != 150 }?.1 == 1)
    #expect(out.periods.filter { $0.0 == 0 && $0.1 != 150 }.map(\.1) == [1, 2, 3, 4])
    #expect(p.tickClocks == (0x376B + 1) * 5)
}

@Test func deliCustomsSetTheirOwnTimer() throws {
    // $1BB5: a hundred times a second.
    var p = try DeliCustomPlayer(custom(timer: 0x1BB5))
    var out = Writes()
    for _ in 0 ..< 4 { _ = p.run(&out) }
    #expect(p.tickClocks == (0x1BB5 + 1) * 5)
    #expect(out.periods.filter { $0.0 == 0 && $0.1 != 150 }.count == 3)
}

@Test func deliCustomsEndWhenTheySay() throws {
    let p = try DeliCustomPlayer(custom(endAt: 100))
    // It said so as its hundredth tick began, after the song's start and 99 ticks of it.
    // (Its first tick a few clocks short of the rest: the timer counts in fifths of Paula's clock from
    // when it was set going.)
    let length = Int(p.lengthClocks ?? 0)
    #expect(abs(length - 100 * (0x376B + 1) * 5) < 5)
}

@Test func deliCustomsThatCallWhatIsNotGivenAreRefused() {
    // exec.library's AddTask, which UADE's host does not give either.
    let file = custom(initPlayer: [0x2C78, 0x0004, 0x4EAE, 0xFEE6]) // MOVEA.L 4.W,A6; JSR -282(A6)
    #expect(throws: TuneError.self) { _ = try DeliCustomPlayer(file) }
    do {
        _ = try DeliCustomPlayer(file)
    } catch {
        #expect("\(error)".contains("AddTask"))
    }
    // Not a custom module: a player without DTP_CustomPlayer, or no player at all.
    var notCustom = custom()
    for i in stride(from: 0, to: notCustom.count - 4, by: 2) where notCustom[i ..< i + 4] == [0x80, 0x00, 0x44, 0x55] {
        notCustom[i + 3] = 0x56
    }
    #expect(!DeliCustomPlayer.isOne(notCustom))
    #expect(!DeliCustomPlayer.isOne([UInt8](repeating: 0, count: 64)))
}

@Test func deliCustomsThatAreDamagedNeverTrapOrHang() {
    let file = custom(endAt: 3)
    for cut in stride(from: 0, to: file.count, by: 3) {
        _ = try? DeliCustomPlayer(Array(file.prefix(cut)))
    }
    var seed: UInt32 = 12345
    for _ in 0 ..< 60 {
        var damaged = file
        for _ in 0 ..< 4 {
            seed = seed &* 1_103_515_245 &+ 12345
            damaged[Int(seed >> 8) % damaged.count] = UInt8(truncatingIfNeeded: seed >> 20)
        }
        if var p = try? DeliCustomPlayer(damaged) {
            var out = Writes()
            for _ in 0 ..< 10 { _ = p.run(&out) }
        }
    }
}
