// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of the Beathoven Synthesizer and Sound Master, played by Wanted Team's recipe
// (`WantedTeamPlayer`), on tiny modules assembled here by hand: each laid out as its player looks for it,
// its code changed as the player changes it, and its songs ending as the player has them end. The
// thorough check is made outside the package: what every one of UnExoticA's modules writes to Paula, tick
// by tick and song by song, against what it writes in UADE.

private struct Silent: TFMXOutput {
    mutating func on(_: Int) {}
    mutating func off(_: Int) {}
    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
}

/// The values a tick's writes put in a register.
private func written(_ writes: [AmigaWrite], _ register: UInt16) -> [UInt16] {
    writes.filter { $0.register == register }.map(\.value)
}

/// A module of the Beathoven Synthesizer, of 1.09 or 1.00: two songs; a start that writes the song's number
/// to AUD1PER and leaves A0 at its fourth voice (whose list, and the others', the player looks at); and a
/// tick that writes a voice's volume of $C5 (which the player's patch writes as seven bits, through its
/// balance, here none),
/// waits for the DMA with a busy loop (which the player makes a wait of the beam), and on its third (or
/// second, for 1.00) takes every voice's list back to its start (which the player counts, and once all four
/// have, says the song has ended). The modules of 1.09 have their own speed: CIA-A's timer at $2000.
private func beathovenModule(old: Bool = false) -> [UInt8] {
    var p = HunkProgram()
    p.w(0x70FF, 0x4E75, 0x4245, 0x4154, 0x484F, 0x5645, 0x4E31, 0x3030 | (old ? 0 : 9)) // "BEATHOVEN109"
    p.address("play")
    p.address("init")
    p.long(2)
    for _ in 3 ..< 14 { p.long(0) }
    p.long(old ? 0 : 0x2000)
    p.label("init")
    p.w(0x33C0, 0x00DF, 0xF0B6, 0x41F9) // MOVE.W D0,$DFF0B6; LEA voice3,A0
    p.address("voice3")
    p.w(0x4E75)
    p.label("play")
    p.w(0x5279)
    p.address("count") // ADDQ.W #1,count
    if old {
        p.w(0x4DF9, 0x00DF, 0xF0A0, 0x43F9) // LEA $DFF0A0,A6; LEA volume-44,A1
        p.address("volume44")
        p.w(0x3D69, 0x002C, 0x0008) // MOVE.W 44(A1),8(A6)
        p.w(0x0C79, 0x0002)
        p.address("count") // CMPI.W #2,count
        p.w(0x6630) // BNE.S out
        for v in 0 ..< 4 {
            p.w(0x41F9)
            p.address("voice\(v)") // LEA voice,A0
            p.w(0x2168, 0x000E, 0x000A) // MOVE.L 14(A0),10(A0)
        }
    } else {
        p.w(0x45F9)
        p.address("volume") // LEA volume,A2
        p.w(0x47F9, 0x00DF, 0xF0A0, 0x376A, 0x0000, 0x0008) // LEA $DFF0A0,A3; MOVE.W 0(A2),8(A3)
        p.w(0x700A, 0x4E71, 0x51C8, 0xFFFC) // MOVEQ #10,D0; NOP; DBF D0,*-2
        p.w(0x0C79, 0x0003)
        p.address("count") // CMPI.W #3,count
        p.w(0x6638) // BNE.S out
        for v in 0 ..< 4 {
            p.w(0x41F9)
            p.address("voice\(v)") // LEA voice,A0
            p.w(0x2268, 0x0008, 0x2149, 0x0004) // MOVEA.L 8(A0),A1; MOVE.L A1,4(A0)
        }
    }
    p.w(0x4E75)
    p.label("count")
    p.w(0)
    p.label("volume44")
    for _ in 0 ..< 22 { p.w(0) }
    p.label("volume")
    p.w(0xC5)
    // The voices: for 1.09, the voice's registers' address and its list's pointer and start; for 1.00,
    // sixty bytes each, the list's pointer at 10, its start at 14, and the voice's bit at 32.
    for v in 0 ..< 4 {
        p.label("voice\(v)")
        if old {
            p.w(0, 0, 0, 0, 0)
            p.address("list")
            p.address("list")
            for _ in 0 ..< 7 { p.w(0) }
            p.long(1 << v)
            for _ in 0 ..< 12 { p.w(0) }
        } else {
            p.long(0x00DF_F0A0 + UInt32(v * 16))
            p.address("list")
            p.address("list")
        }
    }
    p.label("list")
    p.long(1)
    p.long(0)
    p.long(0)
    p.long(0)
    return p.file()
}

@Test func beathovenSynthesizerModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = beathovenModule()
    #expect(BeathovenSynthesizer.isOne(file) && !SoundMaster.isOne(file) && !CoreDesign.isOne(file))
    var p = try BeathovenSynthesizerPlayer(file, song: 1)
    #expect(p.songCount == 2 && p.tuneInfo.format == "Beathoven Synthesizer")
    #expect(p.tuneInfo.detail == "Beathoven Synthesizer 1.09")
    // The song's number, from nought; and every voice pointed at the player's silence, as it starts.
    #expect(written(p.startWrites, 0xB6).last == 1)
    #expect(written(p.startWrites, 0xA2).last == 0xD9B8 && written(p.startWrites, 0xD4).last == 1)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // Its own speed; and the volume through the player's patch.
    #expect(abs(p.tickClocks - (0x2000 + 1) * 5) < 5)
    #expect(written(p.writes, 0xA8) == [0x45])
    _ = p.run(&out)
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 1)

    var old = try BeathovenSynthesizerPlayer(beathovenModule(old: true))
    #expect(old.songCount == 2 && old.tuneInfo.detail == "Beathoven Synthesizer 1.00")
    _ = old.run(&out)
    _ = old.run(&out)
    #expect(abs(old.tickClocks - (0x376B + 1) * 5) < 5)
    #expect(written(old.writes, 0xA8) == [0x45])
    #expect(old.endings == 0)
    _ = old.run(&out)
    #expect(old.endings == 1)
    let length = Int(old.lengthClocks ?? 0)
    #expect(abs(length - 2 * (0x376B + 1) * 5) < 5)
}

/// A module of Sound Master's: three branches, to its start, its tick and its start again; a start that
/// writes the song's number to AUD1PER, and ends as the later versions' do (an instruction on $BFE001,
/// and a MOVE.B #0,d16(A3)); and a tick that writes a voice's volume of $A8 through a routine of its own
/// (which the player makes a jump to its patch, which writes it as seven bits, through its balance, here
/// none), and moves on through its list of
/// three positions, going back to its start after the third (which the player takes for the song's end).
private func soundMasterModule() -> [UInt8] {
    var p = HunkProgram()
    p.w(0x6000)
    p.to("init")
    p.w(0x6000)
    p.to("play")
    p.w(0x6000)
    p.to("init")
    p.label("init")
    p.w(0x47FA)
    p.to("data") // LEA data(PC),A3
    p.w(0x33C0, 0x00DF, 0xF0B6) // MOVE.W D0,$DFF0B6
    p.w(0x08F9, 0x0001, 0x00BF, 0xE001) // BSET #1,$BFE001
    p.w(0x177C, 0x0000, 0x0003, 0x4E75) // MOVE.B #0,3(A3); RTS
    p.label("setVolume")
    p.w(0x3D40, 0x00A8, 0x4E75) // MOVE.W D0,$A8(A6); RTS
    p.label("play")
    p.w(0x47FA)
    p.to("data") // LEA data(PC),A3
    p.w(0x4DF9, 0x00DF, 0xF000, 0x303C, 0x00A8, 0x6100) // LEA $DFF000,A6; MOVE.W #$A8,D0; BSR.W setVolume
    p.to("setVolume")
    p.w(0x162B, 0x0000, 0x5203, 0xB62B, 0x0001, 0x660A) // MOVE.B 0(A3),D3; ADDQ.B #1,D3; CMP.B 1(A3),D3; BNE.S
    p.w(0x162B, 0x0002, 0x177C, 0x0000, 0x0003) // MOVE.B 2(A3),D3; MOVE.B #0,3(A3)
    p.w(0x1743, 0x0000, 0x4E75) // MOVE.B D3,0(A3); RTS
    p.label("data")
    p.w(0x0003, 0x0000)
    return Array(p.file()[32...].prefix(p.here))
}

@Test func soundMasterModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let module = soundMasterModule()
    #expect(SoundMaster.isOne(module) && !BeathovenSynthesizer.isOne(module))
    var p = try SoundMasterPlayer(module)
    #expect(p.songCount == 1 && p.tuneInfo.format == "Sound Master")
    #expect(written(p.startWrites, 0xB6).last == 0)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(written(p.writes, 0xA8) == [0x28])
    _ = p.run(&out)
    #expect(p.endings == 0)
    _ = p.run(&out)
    #expect(p.endings == 1)
    let length = Int(p.lengthClocks ?? 0)
    #expect(abs(length - 3 * (0x376B + 1) * 5) < 5)
    // Not one of its modules: a check with no instruction on $BFE001 before its RTS.
    var other = module
    other[other.firstIndex(of: 0xBF)!] = 0xBE
    #expect(!SoundMaster.isOne(other))
}

/// Cut and changed copies of a module, which its player must refuse or play without trapping or hanging.
private func damage<R: WantedTeamRecipe>(_: R.Type, _ file: [UInt8]) {
    for cut in stride(from: 0, to: file.count, by: 13) {
        _ = try? WantedTeamPlayer<R>(Array(file.prefix(cut)))
    }
    var seed: UInt32 = 2026
    for _ in 0 ..< 12 {
        var damaged = file
        for _ in 0 ..< 4 {
            seed = seed &* 1_103_515_245 &+ 12345
            damaged[Int(seed >> 8) % damaged.count] = UInt8(truncatingIfNeeded: seed >> 20)
        }
        var out = Silent()
        if var p = try? WantedTeamPlayer<R>(damaged) { for _ in 0 ..< 10 { _ = p.run(&out) } }
    }
}

@Test func beathovenAndSoundMasterModulesThatAreDamagedNeverTrapOrHang() {
    damage(BeathovenSynthesizer.self, beathovenModule())
    damage(BeathovenSynthesizer.self, beathovenModule(old: true))
    damage(SoundMaster.self, soundMasterModule())
}
