// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after Wanted Team's EaglePlayers for the music of the Amiga's composers whose own 68000 code is in
// each module (their sources in UADE's amigasrc/players/wanted_team/, each named where it is followed),
// run by UADE's host `score` (amigasrc/score/score.s) as `DeliTrackerHost` runs it.

/// What one of Wanted Team's EaglePlayers does for its format, around the composer's own code that is
/// in each module: most follow one recipe, which `WantedTeamPlayer` plays. The player checks the file
/// (`isOne`); in its `DTP_InitPlayer` loads the module (by LoadSeg, as a rule: `WantedTeamHeader.load`),
/// finds the module's routines (in a header of pointers, a table of branches at its start, or by
/// searching its code), counts its songs, and patches its code (`WantedTeamPatches`, through
/// EaglePlayer's `ModuleChange`); in its `DTP_InitSound` starts the song in `dtg_SndNum`; and then its
/// `DTP_Interrupt` is called fifty times a second by the host's timer, and calls the module's routine
/// for a tick. A song ends when a patch of the player's calls `dtg_SongEnd` (`AmigaAssembly.callSongEnd`).
///
/// A recipe is a small value: the routines' places it found in the module and in its own code. Its
/// own code (`assemble`) is the player's routines and patches, hand-assembled, without what they do
/// for EaglePlayer's scopes and analysers (`UPS_`), which is not heard. It is put at
/// `DeliTrackerHost.clientCode` before each song's start, and `initPlayer` may change it there.
protocol WantedTeamRecipe {
    /// The format's name, as `TuneInfo` gives it.
    static var format: String { get }
    /// Where UADE puts the module: past the EaglePlayer's hunks (see `WantedTeamPlayer.moduleAt`).
    static var moduleAt: UInt32 { get }
    /// What the module's music is turned up or down by (see `PaulaTickPlayer.gain`).
    static var gain: Float { get }
    /// The player's check (its `EP_Check3` or `DTP_Check2`).
    static func isOne(_ data: [UInt8]) -> Bool

    /// A recipe that has found nothing yet.
    init()
    /// The player's own code, assembled at `DeliTrackerHost.clientCode` (6 KB at most): its routines,
    /// its patches and their table, and its variables. The recipe keeps where each is.
    mutating func assemble(_ a: inout AmigaAssembly)
    /// `DTP_InitPlayer`: the module loaded, its routines found, its code patched; and its songs, as
    /// `DTP_SubSongRange` gives them (the first's number, and how many). Throws for a module the
    /// player would not play (as UADE's would fail, or would run off into memory).
    mutating func initPlayer(_ host: inout DeliTrackerHost) throws(TuneError) -> WantedTeamSongs
    /// `DTP_Volume`, called after the song is set and before it starts (by default, nothing).
    mutating func volume(_ host: inout DeliTrackerHost) throws(TuneError)
    /// `DTP_InitSound`: the song in `dtg_SndNum` started (as a rule by `DeliTrackerHost.initSound` of a
    /// routine of the recipe's code).
    mutating func initSound(_ host: inout DeliTrackerHost) throws(TuneError)
    /// The player's `DTP_Interrupt`, which the host calls from its timer (fifty times a second, unless
    /// the recipe has set `dtg_Timer` to another speed by `initSound`); nil for a recipe that has set its
    /// own interrupts going in `initSound` (as `DTP_StartInt` does).
    var interrupt: UInt32? { get }
    /// What the module says of itself: its name, its author's, and anything for `TuneInfo.detail`.
    var title: String { get }
    var author: String { get }
    var detail: String { get }
}

extension WantedTeamRecipe {
    /// UADE puts the module of every one of these players at $F000: each player's file is less than
    /// 4 KB, so its hunks are relocated to $D000, and less than 4 KB, so the module goes 8 KB past
    /// the page they end in (`uadecore_reset`).
    static var moduleAt: UInt32 { 0xF000 }
    static var gain: Float { 0.46 }
    mutating func volume(_: inout DeliTrackerHost) throws(TuneError) {}
    var detail: String { "" }
}

/// A module's songs as its player gives them: the first's number, as the player numbers them, and how
/// many there are.
struct WantedTeamSongs {
    var first = 0
    var count = 1
}

/// The header Wanted Team give the modules they adapted with a player of their own (their
/// "standard header"): an AmigaDOS program of one hunk, to be loaded into chip memory, whose code
/// begins `MOVEQ #-1,D0; RTS` and an ID of eight bytes, followed by the addresses of the module's
/// routines, its counts and its names, as longs, in an order each player has (WT/CoreDesign/
/// Standard_header, WT/JankoMrsic-Flogel/Standard.header, WT/BennDaglishSID/example_header).
enum WantedTeamHeader {
    /// The players' check (`Check3`, the same in each but the ID and how many longs it looks at): the
    /// file's first long HUNK_HEADER, its first hunk's size marked for chip memory (its top byte set),
    /// the hunk's code `MOVEQ #-1,D0; RTS` and `id`, and the longs after the ID numbered by `required`
    /// (from nought) not nought.
    static func isOne(_ data: [UInt8], id: [UInt8], required: [Int]) -> Bool {
        guard id.count == 8, data.count >= 44 + 4 * ((required.max() ?? 0) + 1),
              long(data, 0) == 0x3F3, data[20] != 0, long(data, 32) == 0x70FF_4E75
        else { return false }
        for i in 0 ..< 8 where data[36 + i] != id[i] { return false }
        return required.allSatisfy { long(data, 44 + $0 * 4) != 0 }
    }

    /// A long of the file, nought past its end.
    static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= data.count else { return 0 }
        return UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
    }

    /// The players' `InitPlayer` loading the module: LoadSeg of the module's own file (the name at
    /// `dtg_PathArrayPtr`), which gives the address of its first hunk. Throws if it does not load.
    static func load(_ host: inout DeliTrackerHost) throws(TuneError) -> UInt32 {
        guard let module = host.loadSegment(host.moduleFileName) else {
            throw .malformed("a module that does not load")
        }
        return module
    }

    /// The `count` longs after the ID of the module whose first hunk is at `module`.
    static func longs(_ host: borrowing DeliTrackerHost, module: UInt32, count: Int) -> [UInt32] {
        (0 ..< count).map { host.machine.peek32(module &+ 12 &+ UInt32($0 * 4)) }
    }

    /// A string the module points at, as the player gives it to EaglePlayer (none for nought).
    static func string(_ host: borrowing DeliTrackerHost, at address: UInt32) -> String {
        address == 0 ? "" : host.string(at: address, most: 64)
    }
}
