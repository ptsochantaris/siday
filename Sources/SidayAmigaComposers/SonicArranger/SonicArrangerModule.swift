// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the two players UADE plays Sonic Arranger's files with: Wanted Team's EaglePlayer module
// ("Sonic Arranger 2.18 player module V1.0 (28 Feb 2009)", players/SonicArranger, whose source UADE
// carries as amigasrc/players/wanted_team/Sonic_Arranger/Sonic Arranger_v1.asm: the labels given are
// that source's), and its `SonicArranger-pc-all`, which runs the replayer a module carries in front of
// itself (the addresses given for that are of the module).

import SidayFoundation

/// Where a Sonic Arranger file keeps its parts, as the player that UADE plays it with finds them; and
/// which player that is.
///
/// A file comes in one of three forms. The editor's own module begins "SOAR" "V1.0" and is in parts,
/// each named and counted ("STBL" the songs, "OVTB" the positions, "NTBL" the rows, "INST" the
/// instruments, "SD8B" the samples, "SYWT" the waveforms, "SYAR" and "SYAF" the tables of the volume's
/// and the pitch's envelopes, "EDAT" the editor's own settings). A song, as the editor saves it for a
/// game to play, is the same parts without their names, found by eight offsets at its start (the first
/// always $28), its samples counted and measured after them, and after those "deadbeef", a long word
/// of nought and a text, each byte of it inverted. A song with its replayer in front of it begins with
/// that replayer's table of seven jumps, the song after its code.
///
/// UADE plays a song with a replayer in front of it of the build its magic knows (its jumps at
/// $2A, $6FC and $77C, the replayer of Sonic Arranger 2.18) with that replayer, through its
/// `SonicArranger-pc-all`; and every other file with Wanted Team's player, which plays the song it
/// finds after any replayer with its own copy of 2.18's code.
struct SonicArrangerLayout {
    enum Replayer: Equatable {
        /// Wanted Team's player.
        case wantedTeam
        /// The module's own replayer, of one of the two builds of 2.18 known here: one whose table of
        /// periods is at $1714 and its song at $197C, and one with a branch two bytes longer at $9A4
        /// and everything after it two bytes on.
        case own(periodsAt: Int)
    }

    var replayer: Replayer = .wantedTeam
    /// The songs: twelve bytes each, of six words (the speed, the rows of a position, the first
    /// position, the last, the position gone back to after it, and the ticks a second).
    var songsAt = 0
    var songCount = 0
    var positionsAt = 0
    var rowsAt = 0
    var instrumentsAt = 0
    /// How many instruments Wanted Team's player takes there to be (`Max`), which it keeps an
    /// instrument's number to.
    var instrumentCount = 0
    var wavesAt = 0
    var volumeTablesAt = 0
    var pitchTablesAt = 0
    /// Where each sample's data begins.
    var samples: [Int] = []
    /// Where the samples' data ends.
    var samplesEnd = 0
    /// The inverted text after a song's samples, which Wanted Team's player inverts back where it is
    /// ("Notuj"): its first byte and the one after its last.
    var text: (start: Int, end: Int)?

    /// The most samples either player has room for in its table of them (`lbL000418`).
    static let mostSamples = 128

    /// The two builds of the replayer of Sonic Arranger 2.18 known here: a fingerprint of their code
    /// (`fingerprint(_:end:)`), where their song begins and their table of periods.
    static let ownReplayers: [(fingerprint: UInt32, songAt: Int, periodsAt: Int)] = [
        (0x3EC3_FE5C, 0x197C, 0x1714),
        (0xDBFD_F3B2, 0x1980, 0x1716),
    ]

    // MARK: Reading

    private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        at >= 0 && at + 2 <= data.count ? UInt16(data[at]) << 8 | UInt16(data[at + 1]) : 0
    }

    private static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2))
    }

    private static func marker(_ data: [UInt8], _ at: Int, _ name: String) -> Bool {
        at >= 0 && at + 4 <= data.count && data[at ..< at + 4].elementsEqual(name.utf8)
    }

    /// An offset or a length read from the file, as a place in memory: one past any file is past the
    /// end of the memory the player has (where it reads noughts), and kept short of it, so that sums
    /// of a few such are in range on a machine of 32 bits.
    static func place(_ value: UInt32) -> Int { Int(min(value, UInt32(farthest))) }
    static let farthest = 0x1000_0000

    // MARK: Which player

    /// True for a file whose first twelve bytes UADE's `amifilemagic.c` takes for one with a replayer
    /// of 2.18 in front of it ("SA_old"), which it plays with `SonicArranger-pc-all`.
    static func hasOwnReplayerMagic(_ data: [UInt8]) -> Bool {
        let magic: [UInt8] = [0x4E, 0xFA, 0x00, 0x2A, 0x4E, 0xFA, 0x06, 0xFC, 0x4E, 0xFA, 0x07, 0x7C]
        return data.count >= 12 && data[0 ..< 12].elementsEqual(magic)
    }

    /// True for a file the player UADE plays it with takes for one of its own: `SonicArranger-pc-all`'s
    /// check (at $102 of its code) for one with the magic of a replayer of 2.18, Wanted Team's
    /// (`Check2`) for any other.
    static func isOne(_ data: [UInt8]) -> Bool {
        hasOwnReplayerMagic(data) ? ownReplayerCheck(data) : wantedTeamCheck(data)
    }

    /// `SonicArranger-pc-all`'s check: seven jumps; and the replayer's `movem` to save its registers at
    /// $2A or $1C, or at $2C with a `lea` of the song in the first 41 words of its first routine and,
    /// in the first quarter of the file, the `addq.w #1,(a0)` and `move.w (pc),d0` that it finds the
    /// replayer's master volume by.
    private static func ownReplayerCheck(_ data: [UInt8]) -> Bool {
        guard data.count >= 46 else { return false }
        for i in 0 ..< 7 where word(data, 4 * i) != 0x4EFA { return false }
        if word(data, 42) == 0x48E7 || word(data, 28) == 0x48E7 { return true }
        guard word(data, 44) == 0x48E7 else { return false }
        var at = Int(word(data, 2)) + 2
        var found = false
        for _ in 0 ... 40 {
            let opcode = word(data, at)
            at += 2
            if opcode == 0x41FA {
                found = true
                break
            }
        }
        guard found else { return false }
        let size = UInt32(truncatingIfNeeded: data.count)
        let count = Int((size >> 2 | size << 30) & 0xFFFF)
        for i in 0 ... count where word(data, 2 * i) == 0x5250 && word(data, 2 * i + 2) == 0x303A { return true }
        return false
    }

    /// Wanted Team's `Check2`: "SOAR", "V1.0" and "STBL"; or a song, after any replayer in front of it
    /// (a jump to an even place, and there a `lea` of an even place on), whose first offset is $28, and
    /// the next seven offsets more than nought and even, whose samples fit the file, and after them a
    /// "d". (It means to look for the whole of "deadbeef", but its loop, ended by `dbeq`, ends at the
    /// first byte that matches.)
    private static func wantedTeamCheck(_ data: [UInt8]) -> Bool {
        if marker(data, 0, "SOAR") { return marker(data, 4, "V1.0") && marker(data, 8, "STBL") }
        var left = Int64(data.count)
        var songAt = 0
        if word(data, 0) == 0x4EFA {
            let jump = Int16(bitPattern: word(data, 2))
            guard jump > 0, jump & 1 == 0 else { return false }
            let lea = 6 + Int(jump)
            guard word(data, lea) == 0x41FA else { return false }
            let offset = Int16(bitPattern: word(data, lea + 2))
            guard offset > 0, offset & 1 == 0 else { return false }
            songAt = lea + 2 + Int(offset)
            // (It counts what is left of the file from the `lea`'s offset alone, eight short of where the
            // song begins.)
            left -= 8 + Int64(offset)
            guard left >= 0 else { return false }
        }
        left -= 0x28
        guard left >= 0, long(data, songAt) == 0x28 else { return false }
        var last: UInt32 = 0
        for i in 1 ... 7 {
            last = long(data, songAt + 4 * i)
            guard last != 0, last & 0x8000_0001 == 0 else { return false }
        }
        left -= Int64(last)
        guard left >= 0 else { return false }
        var at = songAt + Int(last)
        let count = long(data, at)
        at += 4
        var lengthAt = at
        var remaining = count
        while remaining != 0 {
            let length = long(data, lengthAt)
            left -= Int64(length)
            guard left >= 0 else { return false }
            lengthAt += 4
            at += Int(length) + 4
            remaining &-= 1
            // (A count no file has room for runs out of the file first.)
            if lengthAt > data.count + 4 { return false }
        }
        left -= 12
        guard left >= 0 else { return false }
        return at < data.count && data[at] == 0x64 // "d"
    }

    // MARK: Layout

    /// Where the file's parts are, as the player UADE plays it with finds them; or why it is not played.
    static func read(_ data: [UInt8]) throws(TuneError) -> SonicArrangerLayout {
        guard isOne(data) else { throw .unsupported("not a Sonic Arranger module") }
        var layout: SonicArrangerLayout
        if hasOwnReplayerMagic(data) {
            layout = try ownReplayer(data)
        } else if marker(data, 0, "SOAR") {
            layout = try editorModule(data)
        } else {
            layout = try wantedTeamSong(data)
        }
        // Songs whose entries are not wholly in the file are not counted (no file of UnExoticA's has
        // one), nor more than 64 (none has more than eleven).
        layout.songCount = min(layout.songCount, max(0, (data.count - layout.songsAt) / 12), 64)
        guard layout.songCount > 0 else { throw .malformed("Sonic Arranger module with no songs") }
        return layout
    }

    /// A fingerprint of a replayer's code, from its start to `end`, leaving out what it keeps of its own
    /// as it plays (its levels and sync value at $1C and $28, its voices, tables and variables from $BC to
    /// $66C, and what it gives the operating system at $6CE and $8AC): FNV-1a, of 32 bits.
    static func fingerprint(_ data: [UInt8], end: Int) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        var i = 0
        while i < min(end, data.count) {
            switch i {
            case 0x1C: i = 0x24
            case 0x28: i = 0x2A
            case 0xBC: i = 0x66C
            case 0x6CE: i = 0x6EA
            case 0x8AC: i = 0x8C2
            default:
                hash = (hash ^ UInt32(data[i])) &* 0x0100_0193
                i += 1
            }
        }
        return hash
    }

    /// A song played by its own replayer: one of the builds known here, its parts found as the
    /// replayer's own setting up finds them ($2C), its songs as `SonicArranger-pc-all` counts them (from
    /// the second offset: one more than it, less $34, in twelves).
    private static func ownReplayer(_ data: [UInt8]) throws(TuneError) -> SonicArrangerLayout {
        guard let build = ownReplayers.first(where: { fingerprint(data, end: $0.songAt) == $0.fingerprint }),
              word(data, 0x30) == 0x41FA, 0x32 + Int(word(data, 0x32)) == build.songAt
        else {
            throw .unsupported("Sonic Arranger module whose replayer is not a build of 2.18 known here")
        }
        var layout = try song(data, at: build.songAt)
        layout.replayer = .own(periodsAt: build.periodsAt)
        let second = long(data, build.songAt + 4)
        let quotient = (second &- 0x34) / 12
        layout.songCount = Int((quotient > 0xFFFF ? second &- 0x34 : quotient) & 0xFFFF) + 1
        return layout
    }

    /// The parts of a song at `at` (the replayer's own setting up, $2C, and Wanted Team's `InitPlay`),
    /// counted as Wanted Team's player counts them.
    private static func song(_ data: [UInt8], at: Int) throws(TuneError) -> SonicArrangerLayout {
        var layout = SonicArrangerLayout()
        func part(_ i: Int) -> Int { at + place(long(data, at + 4 * i)) }
        layout.songsAt = part(0)
        layout.positionsAt = part(1)
        layout.rowsAt = part(2)
        layout.instrumentsAt = part(3)
        layout.wavesAt = part(4)
        layout.volumeTablesAt = part(5)
        layout.pitchTablesAt = part(6)
        let samplesAt = part(7)
        let count = long(data, samplesAt)
        guard count <= UInt32(mostSamples) else {
            throw .unsupported("Sonic Arranger module with more samples than its player has room for")
        }
        var sampleAt = samplesAt + 4 + 4 * Int(count)
        for i in 0 ..< Int(count) {
            layout.samples.append(sampleAt)
            sampleAt = min(sampleAt + place(long(data, samplesAt + 4 + 4 * i)), farthest)
        }
        layout.samplesEnd = sampleAt
        // (`divu`, whose quotient too big for a word leaves what was divided as it was.)
        let instruments = UInt32(truncatingIfNeeded: layout.wavesAt - layout.instrumentsAt)
        let quotient = instruments / 152
        layout.instrumentCount = Int((quotient > 0xFFFF ? instruments : quotient) & 0xFFFF)
        return layout
    }

    /// A song played by Wanted Team's player (`InitPlayer`, from `NoAR`): its songs counted in twelves
    /// (one, if the second's fifth word is below nought: a song stripped of its others); its
    /// instruments counted to where the waveforms begin, 152 bytes at a time, which never ends unless
    /// it comes to them exactly; and after its samples and the twelve bytes of "deadbeef", a byte $F5
    /// followed by nought ahead of the end of the file, which it measures the file by.
    private static func wantedTeamSong(_ data: [UInt8]) throws(TuneError) -> SonicArrangerLayout {
        var at = 0
        if word(data, 0) == 0x4EFA {
            at = Int(Int16(bitPattern: word(data, 2))) + 8
            at += Int(Int16(bitPattern: word(data, at)))
        }
        var layout = try song(data, at: at)
        let span = long(data, at + 4) &- long(data, at)
        let quotient = span / 12
        var songs = quotient > 0xFFFF ? span : quotient | (span % 12) << 16
        if songs != 1, word(data, at + 60) & 0x8000 != 0 { songs = 1 }
        // (A count with a remainder over is a count of more than 65,536: none is played but the first
        // 65,536, of which only those whose entries are in the file are anything.)
        layout.songCount = Int(min(songs, 0xFFFF))
        let instruments = layout.wavesAt - layout.instrumentsAt
        guard instruments > 0, instruments % 152 == 0 else {
            throw .malformed("Sonic Arranger module whose instruments do not fill their part")
        }
        var end = layout.samplesEnd + 12
        let start = end
        while true {
            // (It reads the byte at the end of the file before it finds it is past it: nought.)
            guard end <= data.count else { throw .malformed("Sonic Arranger song cut short") }
            let byte = end < data.count ? data[end] : 0
            end += 1
            if byte == 0xF5, end >= data.count || data[end] == 0 { break }
        }
        var textEnd = start + 1
        while textEnd < data.count, data[textEnd] != 0 { textEnd += 1 }
        layout.text = (start, textEnd)
        return layout
    }

    /// The editor's own module, read as Wanted Team's player reads it (`InitPlayer`, as far as `NoAR`):
    /// each part named and counted, the whole fitting the file, and "EDAT" after the last.
    private static func editorModule(_ data: [UInt8]) throws(TuneError) -> SonicArrangerLayout {
        var layout = SonicArrangerLayout()
        var left = Int64(data.count) - 16
        var at = 16
        let tooShort = TuneError.malformed("Sonic Arranger module cut short")
        let wrong = TuneError.malformed("Sonic Arranger module whose parts are not where they should be")
        func take(_ name: String, each: Int) throws(TuneError) -> (at: Int, count: UInt32) {
            left -= 8
            guard left >= 0 else { throw tooShort }
            guard marker(data, at, name) else { throw wrong }
            let count = long(data, at + 4)
            at += 8
            let bytes = Int64(count & 0xFFFF) * Int64(each)
            left -= bytes
            guard left >= 0 else { throw tooShort }
            defer { at += Int(bytes) }
            return (at, count)
        }
        layout.songsAt = 16
        let songs = long(data, 12)
        left -= Int64(songs & 0xFFFF) * 12
        guard left >= 0 else { throw tooShort }
        layout.songCount = Int(min(songs, 0xFFFF))
        at += Int(songs & 0xFFFF) * 12
        layout.positionsAt = try take("OVTB", each: 16).at
        // (The rows are counted in a long word, four bytes each.)
        left -= 8
        guard left >= 0 else { throw tooShort }
        guard marker(data, at, "NTBL") else { throw wrong }
        let rows = Int64(long(data, at + 4)) * 4
        left -= rows
        guard left >= 0 else { throw tooShort }
        layout.rowsAt = at + 8
        at += 8 + Int(rows)
        let instruments = try take("INST", each: 152)
        // (For none, the player's count of what kind each is goes round 4,294,967,296 times.)
        guard instruments.count != 0 else { throw .malformed("Sonic Arranger module with no instruments") }
        layout.instrumentsAt = instruments.at
        layout.instrumentCount = Int(instruments.count & 0xFFFF)
        left -= 8
        guard left >= 0 else { throw tooShort }
        guard marker(data, at, "SD8B") else { throw wrong }
        let count = long(data, at + 4)
        at += 8
        if count != 0 {
            guard count <= UInt32(mostSamples) else {
                throw .unsupported("Sonic Arranger module with more samples than its player has room for")
            }
            // Thirty-eight bytes of each sample's own, its length, and its data.
            left -= Int64(count) * 38
            guard left >= 0 else { throw tooShort }
            at += Int(count) * 38
            left -= Int64(count) * 4
            guard left >= 0 else { throw tooShort }
            var sampleAt = at + Int(count) * 4
            var total: Int64 = 0
            for i in 0 ..< Int(count) {
                layout.samples.append(sampleAt)
                let length = long(data, at + 4 * i)
                total += Int64(length)
                sampleAt = min(sampleAt + place(length), farthest)
            }
            left -= total
            guard left >= 0 else { throw tooShort }
            at += Int(count) * 4 + Int(total)
        }
        layout.wavesAt = try take("SYWT", each: 128).at
        layout.volumeTablesAt = try take("SYAR", each: 128).at
        layout.pitchTablesAt = try take("SYAF", each: 128).at
        left -= 24
        guard left >= 0 else { throw tooShort }
        guard marker(data, at, "EDAT") else { throw wrong }
        return layout
    }
}
