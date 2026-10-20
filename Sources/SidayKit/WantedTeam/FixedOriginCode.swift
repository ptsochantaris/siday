// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the relocation of code saved at a fixed address that Wanted Team's EaglePlayers for Wally
// Beben's and Mike Davies' music do in their `InitPlayer` (WT/WallyBeben/src/Wally Beben_v1.asm, lines
// 624-760; the Mike Davies player's file, $462-$4F4 of its hunk), each with its own table of opcodes.

/// Code that was saved from where it ran, at an address of its own (its origin), with the absolute
/// addresses of its own variables and tables in its instructions: put anywhere else, each of them must
/// be moved by the distance between the two. The players find them as they find nothing else, by the
/// instructions' first words: going through the code a word at a time, any word in their table is taken
/// for an instruction of that form, and the address in it moved (unless its upper word is $00DF, an
/// address of the custom chips', which stays). The code's data are gone through the same way, and any
/// of their words that is the same as one of the table's is taken for an instruction too, as the
/// players take it.
struct FixedOriginCode {
    /// Where an instruction of the table has its address, or addresses.
    enum Form {
        /// An address straight after the opcode (as `MOVE.B $Address,D0`).
        case address
        /// An address after a word (an immediate or a displacement, as `MOVE.B #$x,$Address`).
        case afterWord
        /// Two addresses after the opcode (`MOVE.B $Address,$Address`), each kept if it is the custom chips'.
        case twoAddresses
    }

    /// Each opcode the player looks for, and its form.
    let forms: [(opcode: UInt16, form: Form)]

    private func form(of word: UInt16) -> Form? {
        for entry in forms where entry.opcode == word { return entry.form }
        return nil
    }

    /// The players' relocation of the code from `from` up to `end`: each address in it of an instruction
    /// of the table moved from `origin` to `module` (its value less the origin and plus the module's
    /// address). False for code the players would go through for ever: their search ends only when it
    /// comes to `end` exactly after a word that is not in the table, so not if it starts at or past
    /// it, nor if it steps over it past an instruction's address. (Nor, here, for code that would end
    /// past the machine's memory.)
    func relocate(_ host: inout DeliTrackerHost, from: UInt32, to end: UInt32, origin: UInt32, module: UInt32) -> Bool {
        guard from < end, (end - from) % 2 == 0, Int(end) <= host.memorySize else { return false }
        func move(_ at: UInt32) {
            host.machine.poke32(at, host.machine.peek32(at) &- origin &+ module)
        }
        func custom(_ at: UInt32) -> Bool { host.machine.peek16(at) == 0x00DF }
        var at = from
        while true {
            guard let form = form(of: host.machine.peek16(at)) else {
                at += 2
                if at == end { return true }
                continue
            }
            at += form == .afterWord ? 4 : 2
            if form == .twoAddresses {
                // (The first address, if it is the custom chips', is passed over; the second, as any
                // other, stays where it is to be gone through as the next word.)
                if !custom(at) { move(at) }
                at += 4
            }
            if !custom(at) {
                move(at)
                at += 4
            }
            if at >= end { return false }
        }
    }
}
