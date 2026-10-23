// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
@testable import SidayFoundation
import Testing

// Fast checks of the recipes for Kris Hatlelid's and Sean Conran's music, on tiny modules assembled here
// by hand: each laid out as its player looks for it, its code changed as the player changes it, and its
// songs ending as the player has them end. The thorough check is made outside the package: what every one
// of UnExoticA's modules writes to Paula, tick by tick and song by song, against what it writes in UADE.

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

private func long(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
}

/// Code assembled from nought (so that its labels' addresses are its offsets), its bytes made whole longs.
private func longs(_ a: AmigaAssembly) -> [UInt8] {
    var bytes = a.assembled()
    while bytes.count % 4 != 0 { bytes.append(0) }
    return bytes
}

/// An AmigaDOS program of the hunks given, each its bytes and the places in it that point into each
/// hunk (by number), and its size in the header (`chip` for chip memory); with as many hunks of BSS
/// after them, of a long each, as `bss`.
private func program(_ hunks: [(bytes: [UInt8], relocations: [Int: [Int]], chip: Bool)], bss: Int = 0) -> [UInt8] {
    let total = hunks.count + bss
    var file = long(0x3F3) + long(0) + long(UInt32(total)) + long(0) + long(UInt32(total - 1))
    for hunk in hunks { file += long(UInt32(hunk.bytes.count / 4) | (hunk.chip ? 0x4000_0000 : 0)) }
    for _ in 0 ..< bss { file += long(1) }
    for (i, hunk) in hunks.enumerated() {
        file += long(i == 0 ? 0x3E9 : 0x3EA) + long(UInt32(hunk.bytes.count / 4)) + hunk.bytes
        if !hunk.relocations.isEmpty {
            file += long(0x3EC)
            for (target, places) in hunk.relocations.sorted(by: { $0.key < $1.key }) {
                file += long(UInt32(places.count)) + long(UInt32(target))
                for place in places { file += long(UInt32(place)) }
            }
            file += long(0)
        }
        file += long(0x3F2)
    }
    for _ in 0 ..< bss { file += long(0x3EB) + long(1) + long(0x3F2) }
    return file
}

/// Kris Hatlelid's code, in hunk `hunk` (its addresses relocated to it): its table of routines from
/// `table` (`CMP.W #n,D0; BEQ.W`: 0, its start; 1, to read its instruments; 2, to play a song); its start,
/// whose `LEA abs.L,A1` the player makes an RTS, and the `LEA d16(PC),A1`s of its routine for a tick and
/// its audio interrupt after it; the code the player finds the speed's routine and the flag of its
/// volumes by; its audio interrupt, whose RTE the player makes an RTS and whose `LEA abs.L,A0` points at
/// its four tracks' places; and its tick, which writes $1AC to AUD0PER and 20 to AUD0VOL as his code does
/// (through a voice's place, at A3, of its registers' addresses), and on its third clears the first word
/// of each track's place, its music over. For a song of its own (`twoFiles` false), its routine 1 points
/// A0 at its voices, of which the place 16 bytes before points at a pointer to its speed, a $DD and $1B
/// and a $DE and $B5 (CIA-A's timer $1BB5). For the music of another file, its routine 2 takes the
/// song's place from the table of songs in D2 (by D1), the music's start, which it moves past by an
/// `ADDA.L #$10,A0` that the player makes its own.
private func hatlelidCode(_ a: inout AmigaAssembly, table: Int, twoFiles: Bool) -> [Int] {
    var relocations: [Int] = []
    func address(_ a: inout AmigaAssembly, _ label: Int) {
        relocations.append(Int(a.here))
        a.address(of: label)
    }
    let start = a.label(), read = a.label(), playSong = a.label(), play = a.label(), audio = a.label()
    let speed = a.label(), flag = a.label(), tracks = a.label(), voice = a.label(), count = a.label()
    let voices = a.label(), toSpeed = a.label(), music = a.label(), done = a.label()
    a.place(table)
    for (n, routine) in [start, read, playSong].enumerated() {
        a.w(0xB07C, UInt16(n), 0x6700) // CMP.W #n,D0; BEQ.W
        a.displacement(to: routine)
    }
    a.w(0x4E75)
    a.place(start)
    a.w(0x4E71, 0x7E00, 0x43F9, 0x0000, 0x0000, 0x43FA) // NOP; MOVEQ #0,D7; LEA 0,A1; LEA play(PC),A1
    a.displacement(to: play)
    a.w(0x43FA)
    a.displacement(to: audio) // LEA audio(PC),A1
    a.w(0x4E75)
    a.place(read)
    if !twoFiles {
        a.w(0x41F9)
        address(&a, voices) // LEA voices,A0
    }
    a.w(0x4E75)
    a.place(playSong)
    if twoFiles {
        // MOVEA.L D2,A0; LSL.W #2,D1; MOVEA.L 0(A0,D1.W),A0; ADDA.L #$10,A0; RTS
        a.w(0x2042, 0xE549, 0x2070, 0x1000, 0xD1FC, 0x0000, 0x0010)
    }
    a.w(0x4E75)
    a.w(0x0C00, 0x00DE, 0x6700) // CMPI.B #$DE,D0; BEQ.W speed
    a.displacement(to: speed)
    a.w(0x302B, 0x001E, 0x4A79) // MOVE.W $1E(A3),D0; TST.W flag; BNE.S *+6; MOVE.W D0,(A6)
    address(&a, flag)
    a.w(0x6604, 0x3C80)
    a.place(audio)
    a.w(0x41F9)
    address(&a, tracks) // LEA tracks,A0
    a.w(0x33FC, 0x0780, 0x00DF, 0xF09C, 0x4E73) // MOVE.W #$780,$DFF09C; RTE
    a.place(speed)
    a.w(0x4E75)
    a.place(play)
    a.w(0x47FA)
    a.displacement(to: voice) // LEA voice(PC),A3
    a.w(0x343C, 0x01AC, 0x2C6B, 0x002C, 0x3C82) // MOVE.W #$1AC,D2; MOVEA.L $2C(A3),A6; MOVE.W D2,(A6)
    a.w(0x343C, 0x0014, 0x2C6B, 0x0028, 0x3C82) // MOVE.W #20,D2; MOVEA.L $28(A3),A6; MOVE.W D2,(A6)
    a.w(0x41FA)
    a.displacement(to: count) // LEA count(PC),A0
    a.w(0x5250, 0x0C50, 0x0003) // ADDQ.W #1,(A0); CMPI.W #3,(A0)
    a.branch(0x6600, to: done) // BNE.S done
    a.w(0x41F9)
    address(&a, tracks) // LEA tracks,A0
    a.w(0x4250, 0x4268, 0x004A, 0x4268, 0x0094, 0x4268, 0x00DE) // CLR.W (A0); CLR.W 74(A0); CLR.W 148(A0); CLR.W 222(A0)
    a.place(done)
    a.w(0x4E75)
    a.place(flag)
    a.w(0)
    a.place(count)
    a.w(0)
    a.place(voice)
    for _ in 0 ..< 20 { a.w(0) }
    a.long(0xDFF0A8) // (at $28: the voice's volume's register; at $2C, its period's)
    a.long(0xDFF0A6)
    a.place(tracks)
    for _ in 0 ..< 4 * 37 { a.w(0) }
    // Before the voices, the pointer to the pointer to the speed (and a long for the song's length).
    address(&a, toSpeed)
    a.long(6)
    a.long(0)
    a.long(0)
    a.place(voices)
    for _ in 0 ..< 4 { a.long(0) }
    a.place(toSpeed)
    address(&a, music)
    a.place(music)
    a.w(0xDD1B, 0xDEB5)
    return relocations
}

/// A module of Kris Hatlelid's with its code (as Grand Prix Circuit's and Test Drive II's are): his
/// `BRA.W` past a long $ABCD and his code, in a hunk of code; a hunk for chip memory and one of BSS.
private func hatlelidModule() -> [UInt8] {
    var a = AmigaAssembly(at: 0)
    let table = a.label()
    a.w(0x6000)
    a.displacement(to: table)
    a.long(0xABCD)
    for _ in 0 ..< 8 { a.w(0) }
    let relocations = hatlelidCode(&a, table: table, twoFiles: false)
    return program([(longs(a), [0: relocations], false), ([UInt8](repeating: 0, count: 16), [:], true)], bss: 1)
}

/// The music alone, as the rest are: `LEA songs,A0; RTS` in a hunk of code, and in a hunk for chip
/// memory the table of its two songs and, for each, its first voice: a pointer to a pointer to its speed
/// (the first's $DD $37 $DE $00, CIA-A's timer $3700, and the second's $DD $1B $DE $B5), and 16 bytes
/// on the music's start. And its replayer, `songplay`: his code in a hunk of its own.
private func hatlelidMusic() -> (data: [UInt8], replayer: [UInt8]) {
    var a = AmigaAssembly(at: 0)
    let table = a.label()
    let relocations = hatlelidCode(&a, table: table, twoFiles: true)
    let replayer = program([(longs(a), [0: relocations], false)])
    // The songs (offsets into the chip hunk): the table at 0, the songs at 12 and 48.
    var songs: [UInt8] = long(12) + long(48) + long(0)
    var places = [0, 4]
    for (at, speed) in [(12, [0xDD, 0x37, 0xDE, 0x00]), (48, [0xDD, 0x1B, 0xDE, 0xB5])] {
        // The song: its pointer to the pointer to the speed, a long for its length, and the music's start
        // 16 bytes on; then the pointer, and the speed.
        songs += long(UInt32(at + 28)) + long(6) + long(0) + long(0) + long(0) + long(0) + long(0)
        songs += long(UInt32(at + 32)) + speed.map(UInt8.init)
        places += [at, at + 28]
    }
    let code = [0x41, 0xF9, 0, 0, 0, 0, 0x4E, 0x75] as [UInt8]
    let data = program([(code, [1: [2]], false), (songs, [1: places], true)], bss: 1)
    return (data, replayer)
}

@Test func krisHatlelidModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = hatlelidModule()
    #expect(KrisHatlelid.isOne(file) && KrisHatlelid.twoFiles(file) == false)
    #expect(!SeanConran.isOne(file) && !CoreDesign.isOne(file))
    #expect(!KrisHatlelid.isOne(Array(file.prefix(40))))
    var p = try KrisHatlelidPlayer(file)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 1)
    #expect(p.tuneInfo.format == "Kris Hatlelid")
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    // The speed from the song's first voice ($1BB5); the period as the module writes it, and its volume
    // doubled, through the player's patches.
    #expect(p.tickClocks == (0x1BB5 + 1) * 5)
    #expect(written(p.writes, 0xA6) == [0x1AC])
    #expect(written(p.writes, 0xA8) == [40])
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(p.endings == 0)
    // Every track's music over (on the third tick): the song's end, said as the next begins.
    _ = p.run(&out)
    #expect(p.endings == 1)
    #expect(p.lengthClocks != nil)
}

@Test func krisHatlelidMusicIsPlayedByTheReplayerBesideIt() throws {
    let (data, replayer) = hatlelidMusic()
    #expect(KrisHatlelid.isOne(data) && KrisHatlelid.twoFiles(data) == true)
    #expect(!KrisHatlelid.isOne(replayer))
    // Without its replayer, it is refused as missing it.
    do {
        _ = try KrisHatlelidPlayer(data)
        Issue.record("played without its replayer")
    } catch let TuneError.missingCompanion(why) {
        #expect(why.contains(KrisHatlelid.replayerName))
    }
    var p = try KrisHatlelidPlayer(data, song: 1, name: "songs.kh", files: [(name: KrisHatlelid.replayerName, bytes: replayer)])
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2)
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(p.tickClocks == (0x1BB5 + 1) * 5)
    #expect(written(p.writes, 0xA6) == [0x1AC] && written(p.writes, 0xA8) == [40])
    for _ in 0 ..< 3 { _ = p.run(&out) }
    #expect(p.endings == 1)
    try p.select(song: 0)
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(p.tickClocks == (0x3700 + 1) * 5)
}

/// A module of Sean Conran's of 1990 or 1991: his table of periods ($1000 $0FE2 and on); from 292 bytes
/// in, his start (its `MOVEQ #0,D1` and `LEA songs(PC),A1`; its song's place, from that table by the song's
/// number in D0's low byte, kept; and the number written at its end, `MOVE.B D0,(A0)`); after it his tick, which reads a byte of
/// the song's positions (`MOVE.B (A0)+,D0; BMI.S`, which the player makes its own), going back to the
/// song's start at a command, writes $1AC to the four voices' periods (through A3, $DFF096, as his code
/// does, each followed by a move of where it has come to, through A2) and 40 to the first voice's volume
/// (from D6, D1 negative); "Sean Conran"; and the table of songs, two, as offsets into the module eight
/// bytes apart, the first's positions 1, 2, 3 and a command, the second's 1 and a command.
private func conranModule() -> [UInt8] {
    var a = AmigaAssembly(at: SeanConran.moduleAt)
    let base = a.placed()
    a.w(0x1000, 0x0FE2, 0x0FC4, 0x0FA7, 0x0F8B, 0x0F6E)
    while a.here < SeanConran.moduleAt + 292 { a.w(0) }
    let vars = a.label(), position = a.label(), start = a.label(), number = a.label(), songs = a.label()
    let over = a.label(), command = a.label()
    a.w(0x45FA)
    a.displacement(to: vars) // LEA vars(PC),A2
    a.branch(0x6000, to: over) // BRA.S over
    a.w(0x7200)
    a.place(over)
    a.w(0x43FA)
    a.displacement(to: songs) // LEA songs(PC),A1
    // ANDI.W #$FF,D0; LSL.W #3,D0; MOVE.W 0(A1,D0.W),D0; LEA base(PC),A0
    a.w(0x0240, 0x00FF, 0xE748, 0x3031, 0x0000, 0x41FA)
    a.displacement(to: base)
    a.w(0xD0C0, 0x43FA) // ADDA.W D0,A0; LEA position(PC),A1
    a.displacement(to: position)
    a.w(0x2288, 0x43FA) // MOVE.L A0,(A1); LEA start(PC),A1
    a.displacement(to: start)
    a.w(0x2288, 0x41FA) // MOVE.L A0,(A1); LEA number(PC),A0
    a.displacement(to: number)
    a.w(0x1080, 0x4E75) // MOVE.B D0,(A0); RTS
    // The tick.
    a.w(0x43FA)
    a.displacement(to: position) // LEA position(PC),A1
    a.w(0x2051, 0x1018) // MOVEA.L (A1),A0; MOVE.B (A0)+,D0
    a.branch(0x6B00, to: command) // BMI.S command
    a.w(0x2288, 0x323C, 0x01AC, 0x47F9, 0x00DF, 0xF096, 0x45FA) // MOVE.L A0,(A1); MOVE.W #$1AC,D1; LEA $DFF096,A3; LEA vars(PC),A2
    a.displacement(to: vars)
    for v: UInt16 in 1 ... 4 { a.w(0x3741, v * 0x10, 0x2548, 0x0008) } // MOVE.W D1,$v0(A3); MOVE.L A0,8(A2)
    a.w(0x3C3C, 0x0028, 0x72FF) // MOVE.W #40,D6; MOVEQ #-1,D1
    a.w(0x6A06, 0x3746, 0x0012, 0x6008, 0xD241, 0x3770, 0x1000, 0x0012) // BPL.S; MOVE.W D6,$12(A3); BRA.S; ...
    a.w(0x4E75)
    a.place(command)
    a.w(0x22BA)
    a.displacement(to: start) // MOVE.L start(PC),(A1)
    a.w(0x4E75)
    a.place(vars)
    for _ in 0 ..< 8 { a.w(0) }
    a.place(position)
    a.long(0)
    a.place(start)
    a.long(0)
    a.place(number)
    a.w(0)
    a.w(0, 0x5365, 0x616E, 0x2043, 0x6F6E, 0x7261, 0x6E00) // "Sean Conran"
    while a.here < SeanConran.moduleAt + 600 { a.w(0) }
    a.place(songs)
    a.w(UInt16(a.here - SeanConran.moduleAt + 16), 0, 0, 0)
    a.w(UInt16(a.here - SeanConran.moduleAt + 14), 0, 0, 0)
    a.w(0x0102, 0x0380, 0x00FF) // the first song's positions
    a.w(0x0180, 0x00FF) // the second's
    var bytes = a.assembled()
    bytes += [UInt8](repeating: 0, count: 1200 - bytes.count)
    return bytes
}

@Test func seanConranModulesArePlayedAsWantedTeamsPlayerPlaysThem() throws {
    let file = conranModule()
    #expect(SeanConran.isOne(file))
    #expect(!KrisHatlelid.isOne(file) && !SeanConnolly.isOne(file) && !Desire.isOne(file))
    var p = try SeanConranPlayer(file)
    try p.select(song: p.song)  // (Played through first, as its renderer has it played.)
    #expect(p.songCount == 2)
    #expect(p.tuneInfo.format == "Sean Conran" && p.tuneInfo.author == "Sean Conran")
    var out = Silent()
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(p.tickClocks == (0x376B + 1) * 5)
    // The periods and the volume through the player's patches.
    for register: UInt16 in [0xA6, 0xB6, 0xC6, 0xD6] { #expect(written(p.writes, register) == [0x1AC]) }
    #expect(written(p.writes, 0xA8) == [40])
    _ = p.run(&out)
    _ = p.run(&out)
    #expect(p.endings == 0)
    // The command after the third position: the song's end.
    _ = p.run(&out)
    #expect(p.endings == 1)
    let first = p.lengthClocks
    #expect(first != nil)
    // The second song's command comes after its first position.
    try p.select(song: 1)
    let second = p.lengthClocks
    #expect(second != nil && second! < first!)
    // A bank of sounds, whose words after the code are $7F7F, is not music.
    var bank = file
    for i in 300 ..< 304 { bank[i] = 0x7F }
    #expect(!SeanConran.isOne(bank))
    #expect(!SeanConran.isOne(Array(file.prefix(10))))
}
