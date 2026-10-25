// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayAmigaMachine
@testable import SidayChips
import Testing

// Fast checks of the player of the older rips of Dave Lowe's music (Dave Lowe's Sound System), on a tiny
// module assembled here by hand. The thorough check is made outside the package: what UnExoticA's two
// files write to Paula, tick by tick and song by song, against what they write in UADE.

/// A module, as small as one can be with something of each kind: three songs whose voices play one
/// stretch over and over (an envelope of 40, 30 and then held, lifted by 5; an instrument with a loop;
/// a note of 300 for three ticks; a rest of two); voice 1 lifts its envelope first (command 52, then a
/// jump to the stretch). The second song fades in, every fourth write of a volume. The third's voice 0
/// starts the song again at once (command 60).
private func module() -> [UInt8] {
    var p = HunkProgram()
    p.w(0x70FF, 0x4E75, 0x4441, 0x5645, 0x4C4F, 0x5745, 0x0100, 3) // MOVEQ #-1,D0; RTS; "DAVELOWE"; 1.0; 3 songs
    for (lists, name, fade) in [(["list", "lifted", "list", "list"], "name1", 0), (["list", "lifted", "list", "list"], "name2", 3),
                                (["again", "list", "list", "list"], "name1", 0)] as [([String], String, UInt16)]
    {
        for list in lists { p.address(list) }
        p.address(name)
        p.w(fade)
    }
    p.label("list")
    p.address("stretch")
    p.long(0)
    p.label("lifted")
    p.address("lift")
    p.long(0)
    p.label("again")
    p.address("restart")
    p.long(0)
    p.label("lift")
    p.w(52, 56)
    p.address("stretch") // the envelope lifted; on to the stretch
    p.label("restart")
    p.w(60)
    p.label("stretch")
    p.w(12)
    p.address("envelope")
    p.w(4)
    p.address("instrument")
    p.w(300, 3, 32, 2, 8) // a note of 300 for three ticks; a rest of two; on to the next stretch
    p.label("envelope")
    p.long(5)
    p.w(40, 30, 0xFF)
    p.label("instrument")
    p.w(1)
    p.address("sample")
    p.w(4)
    p.address("loop")
    p.w(2)
    p.label("sample")
    p.w(0x1020, 0x3040)
    p.label("loop")
    p.w(0x5060, 0x7080)
    p.label("name1")
    p.w(0x536F, 0x6E67, 0x0000) // "Song"
    p.label("name2")
    p.w(0x4D65, 0x0000) // "Me"
    return p.file()
}

private struct Writes: TFMXOutput {
    var events: [String] = []
    mutating func on(_ v: Int) { events.append("on\(v)") }
    mutating func off(_ v: Int) { events.append("off\(v)") }
    mutating func takeNextBuffer(_ v: Int, start: Int, length: UInt16) {
        events.append("buffer\(v) \(start - DaveLoweSoundSystemPlayer.moduleAt) \(length)")
    }
    func loopCount(_: Int) -> UInt16 { 0 }
}

@Test func daveLoweSoundSystemModulesArePlayedAsTheirPlayerPlaysThem() throws {
    let file = module()
    #expect(DaveLoweSoundSystemPlayer.isOne(file))
    var p = try DaveLoweSoundSystemPlayer(file)
    #expect(p.songCount == 3)
    #expect(p.songNames == ["Song", "Me", "Song"])
    #expect(p.tuneInfo.format == "Dave Lowe" && p.tuneInfo.author == "Dave Lowe")
    // A note of three ticks and a rest of two, and then the list's end, which is every voice's: the
    // song's end, five ticks in.
    #expect(p.lengthClocks == UInt64(5 * DaveLoweSoundSystemPlayer.tickClocks))
    let sample = 162 // (the label's place in the hunk)
    var volumes: [[UInt16]] = [], periods: [UInt16] = [], events: [[String]] = []
    for _ in 0 ..< 6 {
        var out = Writes()
        _ = p.run(&out)
        volumes.append((0 ..< 4).map { p.volume($0) })
        periods.append(p.period(0))
        events.append(out.events.filter { $0.hasSuffix("0") || $0.hasPrefix("buffer0") })
    }
    // The envelope's words, its last held; voice 1's lifted, but not the one held; the rest quiet.
    #expect(volumes.map { $0[0] } == [40, 30, 30, 0, 0, 40])
    #expect(volumes.map { $0[1] } == [45, 35, 30, 0, 0, 45])
    #expect(periods == [300, 300, 300, 300, 300, 300])
    // The sample's start with the note, its loop at the next tick, stopped at the note's last tick, and
    // at the rest's last; the voice's DMA on with every other tick.
    #expect(events[0] == ["buffer0 \(sample) 4", "on0"])
    #expect(events[1] == ["buffer0 \(sample + 4) 2", "on0"])
    #expect(events[2] == ["off0"])
    #expect(events[3] == ["on0"])
    #expect(events[4] == ["off0"])
    #expect(events[5] == ["buffer0 \(sample) 4", "on0"])

    // The fade: one step of 64 for every four volumes written, from nought.
    try p.select(song: 1)
    var faded: [UInt16] = []
    for _ in 0 ..< 70 {
        var out = Writes()
        _ = p.run(&out)
        faded.append(p.volume(0))
    }
    #expect(faded[0] == 0)
    #expect(faded[5] == (40 * 5) >> 6)
    #expect(faded[65] == 40)

    // Command 60: the song's end and its start again, in the middle of the tick; the voices after it
    // play their first notes in it.
    try p.select(song: 2)
    #expect(p.lengthClocks == 0)
    var out = Writes()
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(out.events.prefix(5) == ["off0", "off1", "off2", "off3", "on0"])
    #expect(p.period(1) == 300 && p.volume(1) == 40)
}

@Test func daveLoweSoundSystemModulesThatAreDamagedNeverTrapOrHang() {
    let file = module()
    #expect(!DaveLoweSoundSystemPlayer.isOne(Array(file.prefix(45))))
    var later = file
    later[44] = 2
    #expect(!DaveLoweSoundSystemPlayer.isOne(later))
    var none = file
    none[47] = 0
    #expect((try? DaveLoweSoundSystemPlayer(none)) == nil)
    for cut in stride(from: 0, to: file.count, by: 3) {
        _ = try? DaveLoweSoundSystemPlayer(Array(file.prefix(cut)))
    }
    var seed: UInt32 = 54321
    for _ in 0 ..< 200 {
        var damaged = file
        for _ in 0 ..< 4 {
            seed = seed &* 1_103_515_245 &+ 12345
            damaged[46 + Int(seed >> 8) % (damaged.count - 46)] = UInt8(truncatingIfNeeded: seed >> 20)
        }
        if var p = try? DaveLoweSoundSystemPlayer(damaged) {
            var out = Writes()
            for _ in 0 ..< 20 { _ = p.run(&out) }
        }
    }
}
