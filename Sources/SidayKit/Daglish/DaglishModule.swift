// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayer for Ben Daglish's modules ("Benn Daglish player module V1.2
// (6 Mar 2004)", by Mr.Larmer, carried by UADE as players/BenDaglish), whose source UADE carries
// (amigasrc/players/wanted_team/BennDaglish/Benn Daglishv3.asm). The addresses given are of the player's
// code hunk, as a disassembly of the one UADE installs has them.

/// What Wanted Team's player finds in one of Ben Daglish's modules, which is the 68000 driver he and
/// Colin Dooley wrote, with his music after it: how many songs it has, and what the player changes in
/// it before it is run.
///
/// A module begins with a table of branches into the driver: the first starts a song (with its number in
/// D0), the second plays a tick; then a byte that stays set while a song plays; then a branch to the
/// routine that stops the music. The player finds the table of songs by the instructions that index it
/// (two `ADD.W D0,D0`, a third, and the LEA of the table), and the end of the driver's code by the LEA of
/// its table of samples, which follows.
struct DaglishModule {
    /// Offsets into the module: the table of songs, and the first sample's entry in the table of samples,
    /// where the driver's code ends.
    var songTable: Int
    var samples: Int
    var songCount: Int
    /// What the player changes in the driver, and where (see `Change`).
    var changes: [(change: Change, at: Int)] = []

    /// The instructions the player's `DTP_InitPlayer` changes ($79C to $84A), as it finds them in the
    /// driver from the instruction after its first `LEA $DFF000,A6` to the table of samples, a word at a
    /// time, stepping past each it changes.
    enum Change: Equatable {
        /// `MOVE SR,-(A7)` and `ORI #n,SR`, which shut out interrupts while a note is set going, made
        /// NOPs; and the `RTE` that ends what they began made an RTS (as is the `RTE` of the driver's own
        /// routine for Paula's interrupts, which is not used). `MOVE (A7)+,SR`, the end of the same in
        /// some, is made a NOP.
        case masking
        case returnFromException
        case restoring
        /// `MOVE.L A0,$70`, by which the driver makes its own routine Paula's interrupts' (the player
        /// puts its own there, `Audio`, $9EA), made NOPs.
        case vector
        /// `MOVE.L A3,(A2); MOVE.W 8(A0),4(A2)`: a voice's sample given (Patch1, $A04).
        case sample
        /// `MOVE.W D0,8(A2); MOVE.L A3,26(A1)`: a voice's volume set, in the earliest of his drivers
        /// (Patch2, $A12). `louder` when it follows a `LSR.W #2,D0`, which the player makes a NOP ("more
        /// volume power", $7E8): its notes are four times as loud as the driver has them.
        case earlyVolume(louder: Bool)
        /// `MOVE.W D0,8(A1)` and the instruction after it (Patch3, $A24), and `MOVE.W D2,8(A2)` and the
        /// instruction after it (Patch4, $A38): a voice's volume set, at a note and on each tick.
        case volume(next: UInt32)
        case noteVolume(next: UInt32)
    }

    /// The words of the module, read as the player reads them; a read past the end refuses it.
    private struct Words {
        let data: [UInt8]

        func word(_ at: Int) throws(TuneError) -> Int {
            guard at >= 0, at + 1 < data.count else {
                throw .malformed("Ben Daglish's module is cut short, or its driver is not as his drivers are")
            }
            return Int(data[at]) << 8 | Int(data[at + 1])
        }

        func signedWord(_ at: Int) throws(TuneError) -> Int { Int(Int16(truncatingIfNeeded: try word(at))) }
        func long(_ at: Int) throws(TuneError) -> UInt32 { UInt32(try word(at)) << 16 | UInt32(try word(at + 2)) }
    }

    // MARK: The check

    /// The player's check (`DTP_Check2`, $448): three branches (`BRA` with a word of offset, forward
    /// and even) at 0, 4 and 10, and where the first goes, a `MOVE.W D0,-(A7)` and a BSR, a
    /// `MOVE.W #n,d(A6)` at 6 and a `LEA (PC),A0` at 12.
    static func isOne(_ data: [UInt8]) -> Bool {
        let m = Words(data: data)
        do {
            for at in [0, 4, 10] {
                guard try m.word(at) == 0x6000 else { return false }
                let offset = try m.word(at + 2)
                guard offset != 0, offset & 0x8001 == 0 else { return false }
            }
            let start = 2 + (try m.word(2))
            return try m.long(start) == 0x3F00_6100 && m.word(start + 6) == 0x3D7C && m.word(start + 12) == 0x41FA
        } catch {
            return false
        }
    }

    /// A module of nothing, where there is none.
    static let none = DaglishModule()

    private init() {
        songTable = 0
        samples = 0
        songCount = 1
    }

    // MARK: Finding the way in

    /// What the player's `DTP_InitPlayer` ($502) finds in a module that passed its check. Throws for one
    /// it refuses (`EPR_CorruptModule`, $858), or whose driver its search would run off.
    init(_ data: [UInt8]) throws(TuneError) {
        guard Self.isOne(data) else { throw .malformed("not a module of Ben Daglish's") }
        let m = Words(data: data)
        // $51C: from where the first branch goes, within 128 words, `ADD.W D0,D0` twice and once more,
        // then the LEA of the table of songs.
        var a0 = 2 + (try m.word(2))
        var left = 0x7F
        while true {
            if try m.long(a0) == 0xD040_D040 {
                a0 += 4
                if try m.word(a0) == 0xD040, try m.word(a0 + 2) == 0x41FA { break }
                continue
            }
            a0 += 2
            left -= 1
            guard left >= 0 else { throw .malformed("Ben Daglish's driver has no table of songs where his drivers have it") }
        }
        a0 += 4
        songTable = a0 + (try m.signedWord(a0))
        // $546: a song is four words, a pointer each to a voice's list, every one below $400; the count is
        // of those before the first that is not one (and one at least, $55E).
        var count = 0
        var a1 = songTable
        counting: while true {
            for _ in 0 ..< 4 {
                guard a1 >= 0, a1 + 1 < data.count, try m.word(a1) & 0xFC00 == 0 else { break counting }
                a1 += 2
            }
            count += 1
            // (No module has more than 13; one that says it has hundreds is not one.)
            guard count <= 255 else { throw .malformed("Ben Daglish's table of songs is not as his drivers keep it") }
        }
        songCount = max(1, count)
        // $56C: the next `LEA (PC),A0`, within 128 words, is of the table of samples.
        left = 0x7F
        while try m.word(a0) != 0x41FA {
            a0 += 2
            left -= 1
            guard left >= 0 else { throw .malformed("Ben Daglish's driver has no table of samples where his drivers have it") }
        }
        a0 += 2
        samples = a0 + (try m.signedWord(a0))
        // $786: the patches are looked for from the first `LEA $DFF000,A6` up to the samples' table, a word
        // at a time, and the search ends only as it comes to the table exactly.
        var from = 0
        while try m.word(from) != 0x4DF9 { from += 2 }
        from += 2
        guard samples >= from, samples & 1 == 0, samples <= data.count else {
            throw .malformed("Ben Daglish's driver is not as his drivers are")
        }
        a0 = from
        while a0 != samples {
            // (A search that steps past the table would never stop.)
            guard a0 < samples else { throw .malformed("Ben Daglish's driver is not as his drivers are") }
            let long = (try? m.long(a0)) ?? 0
            let next = (try? m.long(a0 + 4)) ?? 0
            if long == 0x40E7_007C {
                changes.append((.masking, a0))
                a0 += 6
            } else if long >> 16 == 0x4E73 {
                changes.append((.returnFromException, a0))
                a0 += 2
            } else if long == 0x248B_3568, next == 0x0008_0004 {
                changes.append((.sample, a0))
                a0 += 8
            } else if long == 0x3540_0008, next == 0x234B_001A {
                changes.append((.earlyVolume(louder: (try? m.word(a0 - 2)) == 0xE448), a0))
                a0 += 8
            } else if long == 0x3340_0008, next >> 16 == 0x302B {
                changes.append((.volume(next: next), a0))
                a0 += 8
            } else if long == 0x3542_0008 {
                changes.append((.noteVolume(next: next), a0))
                a0 += 8
            } else if long == 0x21C8_0070 {
                changes.append((.vector, a0))
                a0 += 4
            } else {
                if long >> 16 == 0x46DF { changes.append((.restoring, a0)) }
                a0 += 2
            }
        }
    }
}
