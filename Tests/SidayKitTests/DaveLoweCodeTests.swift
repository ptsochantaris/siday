// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the player of Dave Lowe's modules of code, on a tiny module assembled here by hand:
// laid out as Wanted Team's are, its code changed as their player changes it, and its songs ending as
// their player has them end. The thorough check is made outside the package: what every one of
// UnExoticA's modules writes to Paula, tick by tick and song by song, against what it writes in UADE.

/// A module of Dave Lowe's, as small as one can be: its header of routines and lists; a start that
/// writes the song's number to AUD1PER; and a tick that writes a volume of $1C5 to voice 0 (as his
/// drivers write volumes, which the player's patch makes seven bits), then, for each voice, takes a
/// note's length from a word of -1 (as his drivers take them, which the player's patch counts as the
/// end of the voice's list). Two songs.
private func module() -> [UInt8] {
    var p = HunkProgram()
    p.w(0x70FF, 0x4E75, 0x554E, 0x434C, 0x4541, 0x5254) // MOVEQ #-1,D0; RTS; "UNCLEART"
    for field in ["init", "play", nil, "songWord", nil, nil, nil, nil, "firstSongs", "name", "author"] as [String?] {
        if let field { p.address(field) } else { p.long(0) }
    }
    for _ in 0 ..< 6 { p.long(0) }
    p.label("init")
    p.w(0x33F9)
    p.address("songWord")
    p.w(0x00DF, 0xF0B6, 0x4E75) // MOVE.W songWord,$DFF0B6; RTS
    p.label("play")
    p.w(0x6000)
    p.to("body") // BRA.W body
    for _ in 0 ..< 190 { p.w(0x4E71) }
    p.label("body")
    p.w(0x41F9)
    p.address("data") // LEA data,A0
    p.w(0x45F9, 0x00DF, 0xF0A0) // LEA $DFF0A0,A2
    p.w(0x303C, 0x01C5) // MOVE.W #$1C5,D0
    p.w(0x3540, 0x0008, 0x2149, 0x0012) // MOVE.W D0,8(A2); MOVE.L A1,$12(A0)
    p.w(0x7C03) // MOVEQ #3,D6
    p.label("voice")
    p.w(0x43F9)
    p.address("minus") // LEA minus,A1
    p.w(0x3159, 0x0002, 0x5368, 0x0002) // MOVE.W (A1)+,2(A0); SUBQ.W #1,2(A0)
    p.w(0xD4FC, 0x0010) // ADDA.W #16,A2
    p.w(0x51CE)
    p.to("voice") // DBF D6,voice
    p.w(0x4E75)
    p.label("data")
    for _ in 0 ..< 32 { p.w(0) }
    p.label("minus")
    p.w(0xFFFF)
    p.label("songWord")
    p.w(0)
    p.label("firstSongs")
    for _ in 0 ..< 8 { p.address("list") }
    p.long(0)
    p.label("list")
    p.long(1)
    p.long(0)
    p.label("name")
    p.w(0x536F, 0x6E67, 0x0000) // "Song"
    p.label("author")
    p.w(0x4D65, 0x0000) // "Me"
    return p.file()
}

private struct Writes: TFMXOutput {
    var periods: [(Int, UInt16)] = []
    var volumes: [(Int, UInt16)] = []
    mutating func on(_: Int) {}
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
    mutating func writePeriod(_ voice: Int, _ period: UInt16) { periods.append((voice, period)) }
    mutating func writeVolume(_ voice: Int, _ volume: UInt16) { volumes.append((voice, volume)) }
}

@Test func daveLoweModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = module()
    #expect(DaveLoweCodePlayer.isOne(file))
    var p = try DaveLoweCodePlayer(file, song: 1)
    #expect(p.songCount == 2)
    #expect(p.tuneInfo.format == "Dave Lowe")
    #expect(p.tuneInfo.title == "Song" && p.tuneInfo.author == "Me")
    var out = Writes()
    for _ in 0 ..< 3 { _ = p.run(&out) }
    // The song's number, as the player numbers them (from one).
    #expect(out.periods.contains { $0.0 == 1 && $0.1 == 2 })
    // The volume written through the player's patch, seven bits of it.
    #expect(out.volumes.filter { $0.0 == 0 && $0.1 != 0 }.map(\.1) == [0x45, 0x45])
    // Every voice at the end of its list in each tick: the first time each voice's count goes from
    // two to go to one, the second it comes to nought and the song ends, and then with every tick.
    let length = Int(p.lengthClocks ?? 0)
    #expect(abs(length - 2 * (0x376B + 1) * 5) < 5)
    #expect(p.endings == 1)
}

@Test func daveLoweModulesThatAreDamagedNeverTrapOrHang() {
    let file = module()
    #expect(!DaveLoweCodePlayer.isOne(Array(file.prefix(50))))
    for cut in stride(from: 0, to: file.count, by: 5) {
        _ = try? DaveLoweCodePlayer(Array(file.prefix(cut)))
    }
    var seed: UInt32 = 54321
    for _ in 0 ..< 60 {
        var damaged = file
        for _ in 0 ..< 4 {
            seed = seed &* 1_103_515_245 &+ 12345
            damaged[32 + Int(seed >> 8) % (damaged.count - 32)] = UInt8(truncatingIfNeeded: seed >> 20)
        }
        if var p = try? DaveLoweCodePlayer(damaged) {
            var out = Writes()
            for _ in 0 ..< 10 { _ = p.run(&out) }
        }
    }
}
