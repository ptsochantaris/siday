// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after UADE's host for DeliTracker's and EaglePlayer's players, its sound core `score`
// (amigasrc/score/score.s, by Heikki Orsila, LGPL), and the definitions of DeliTracker's interface to its
// players (misc/DeliPlayer.i, Delirium Softdesign) and EaglePlayer's (misc/EaglePlayer.i). What each
// part does, and in what order, is score's; the labels named are its.

/// The tags of a DeliTracker or EaglePlayer player that its host reads, as DeliPlayer.i and
/// EaglePlayer.i number them: each the tag's base and its place in their list.
enum DeliTag {
    /// DTP_TagBase, TAG_USER + "DT".
    static let base: UInt32 = 0x8000_4454
    static let customPlayer = base + 1, playerName = base + 5, check2 = base + 8, extLoad = base + 9
    static let interrupt = base + 10, config = base + 12, subSongRange = base + 14, initPlayer = base + 15
    static let endPlayer = base + 16, initSound = base + 17, endSound = base + 18, startInt = base + 19
    static let stopInt = base + 20, volume = base + 21, nextSong = base + 27, prevSong = base + 28
    static let newSubSongRange = base + 30, deliBase = base + 31, moduleName = base + 47, formatName = base + 48
    /// EP_TagBase, TAG_USER + "EP".
    static let eagleBase: UInt32 = 0x8000_4550
    static let check3 = eagleBase + 20, check5 = eagleBase + 28, initAmplifier = eagleBase + 35
    static let eagleBasePointer = eagleBase + 42
}

/// A player of DeliTracker's or EaglePlayer's, run on siday's Amiga (`AmigaMachine`) as UADE's host
/// runs it: an AmigaDOS program whose first hunk begins `MOVEQ #-1,D0; RTS`, "DELIRIUM" and a pointer to
/// its tags (DTP_InitPlayer, DTP_Interrupt and the rest), and which calls its host through the globals
/// passed it in A5 (DeliTracker's `dtg_`, EaglePlayer's `EPG_` and, below them, `ENPP_`) and the system's
/// libraries. A DeliTracker custom module is one such player that is its own music; an EaglePlayer
/// player is given a module as well.
///
/// The host does what score does, in its order: the player relocated where UADE puts it, its globals
/// set up, its check called, `DTP_InitPlayer`, its range of songs asked for, the song set, `DTP_Volume`,
/// `DTP_InitSound`, and then either its own `DTP_StartInt` called, which sets its interrupts going itself,
/// or its `DTP_Interrupt` called from the interrupt of CIA-A's timer B, set to `dtg_Timer`
/// ($376B, fifty times a second, unless the player sets another). The machine then runs as the Amiga
/// does (`AmigaMachine.run(until:)`), every interrupt taken as it comes due: the CIAs' timers, the frame's,
/// and Paula's, each by score's handler of it, which calls what the player has set for it.
///
/// The host's own routines are as score has them, as far as the players in UnExoticA's collection call
/// them. Most are a TRAP to the host (`Call`), which does in Swift what score does in 68000 code; the
/// interrupts' handlers and a few routines short enough are score's code, hand-assembled. A routine of
/// the system's libraries that score does not give is refused as it is in UADE, where it stops the
/// player: the call is noted (`failure`) and the player stops.
struct DeliTrackerHost: ~Copyable {
    // MARK: Where things are, as UADE has them (src/uade.c)

    /// The user's stack and the supervisor's: UADE's.
    static let userStack: UInt32 = 0x8500
    static let superStack: UInt32 = 0x8F00
    /// Where the player's file is put as it is, before it is relocated.
    static let playerFile: UInt32 = 0x9000
    /// The host's own code.
    /// (A KB past the start of the host's space, which a player written in Swift may have for its own
    /// code at a place it has fixed, as `WhittakerPlayer` has its patches.)
    private static let codeAt = AmigaMachine.hostSpace + 0x400
    /// The host's tables and data.
    private static let frameCount: UInt32 = 0x3000
    private static let vblankServers: UInt32 = 0x3004
    private static let irqLines: UInt32 = 0x3084
    private static let isData: UInt32 = 0x30BC
    private static let oldStructs: UInt32 = 0x30F4
    private static let ciaaInts: UInt32 = 0x3150, ciaaDatas: UInt32 = 0x3158
    private static let ciabInts: UInt32 = 0x3160, ciabDatas: UInt32 = 0x3168
    private static let dirArray: UInt32 = 0x3200, fileArray: UInt32 = 0x3300, pathArray: UInt32 = 0x3400
    private static let ciaaResource: UInt32 = 0x3600, ciabResource: UInt32 = 0x3640
    private static let dosBase: UInt32 = 0x4000
    private static let intuitionBase: UInt32 = 0x4800
    private static let iconBase: UInt32 = 0x4B00
    /// The globals passed the player in A5 (score's `eaglebase`), with EaglePlayer's jumps below.
    static let globals: UInt32 = 0x5000

    // The globals' fields (DeliPlayer.i, EaglePlayer.i).
    static let dtgDOSBase: UInt32 = 4, dtgIntuitionBase: UInt32 = 8
    static let dtgDirArrayPtr: UInt32 = 24, dtgFileArrayPtr: UInt32 = 28, dtgPathArrayPtr: UInt32 = 32
    static let dtgChkData: UInt32 = 36, dtgChkSize: UInt32 = 40, dtgSndNum: UInt32 = 44, dtgSndVol: UInt32 = 46
    static let dtgSndLBal: UInt32 = 48, dtgSndRBal: UInt32 = 50, dtgLED: UInt32 = 52, dtgTimer: UInt32 = 54
    static let dtgGetListData: UInt32 = 56, dtgLoadFile: UInt32 = 60, dtgCopyDir: UInt32 = 64, dtgCopyFile: UInt32 = 68
    static let dtgCopyString: UInt32 = 72, dtgAudioAlloc: UInt32 = 76, dtgAudioFree: UInt32 = 80, dtgStartInt: UInt32 = 84
    static let dtgStopInt: UInt32 = 88, dtgSongEnd: UInt32 = 92, dtgCutSuffix: UInt32 = 96, dtgSetTimer: UInt32 = 100
    static let dtgWaitAudioDMA: UInt32 = 104, dtgNotePlayer: UInt32 = 116
    static let epgNewLoadFile: UInt32 = 144, epgFindAuthor: UInt32 = 164, epgModuleChange: UInt32 = 176
    static let epgArgN: UInt32 = 290, epgArg1: UInt32 = 294, epgArg2: UInt32 = 298, epgArg3: UInt32 = 302
    static let epgArg4: UInt32 = 306, epgArg5: UInt32 = 310
    static let epgVoices: UInt32 = 326, epgVoice1Vol: UInt32 = 328
    // EaglePlayer's jumps, below the globals.
    static let enppGetListData: Int32 = -66, enppLoadFile: Int32 = -72, enppAllocAudio: Int32 = -96
    static let enppSongEnd: Int32 = -120, enppSetTimer: Int32 = -132, enppNewLoadFile: Int32 = -168
    static let enppFindAuthor: Int32 = -198

    /// CIA-A's timer B, set to `dtg_Timer`, fifty times a second unless the player sets another: the timer
    /// of a player that calls for no interrupts of its own (score's `cia_chip_sel`, `cia_timer_sel`).
    static let defaultTimer: UInt16 = 0x376B

    // MARK: The host's routines, each a TRAP #15 and an RTS at its place in a table

    enum Call: Int, CaseIterable {
        case unimplementedExec, unimplementedDOS, unimplementedEagle, unimplementedIntuition, unimplementedIcon
        case unimplementedCIA
        case allocMem, openLibrary, openResource, openDevice, doIO, sendIO, typeOfMem, allocSignal, setIntVector
        case addIntServer
        case loadSeg, open, seek, read, close, lock
        case getListData, loadFile, copyDir, copyFile, copyString, songEnd, setTimer, moduleChange
        case addCIABInterrupt, remCIAAInterrupt, remCIABInterrupt
        case defaultStartInt, defaultStopInt, frame
    }

    private static let stubs = codeAt
    private static func stub(_ call: Call) -> UInt32 { stubs + UInt32(call.rawValue * 4) }

    /// Where the parts of the host's code begin, once it is assembled.
    private struct Entries {
        var okay: UInt32 = 0, rts: UInt32 = 0, rtsNonZero: UInt32 = 0, testD0: UInt32 = 0, findTask: UInt32 = 0
        var supervisor: UInt32 = 0, superState: UInt32 = 0, userState: UInt32 = 0, cause: UInt32 = 0
        var waitAudioDMA: UInt32 = 0
        var level1: UInt32 = 0, level2: UInt32 = 0, level3: UInt32 = 0, level4: UInt32 = 0, level5: UInt32 = 0
        var level6: UInt32 = 0, ciaaInterrupt: UInt32 = 0, ciabInterrupt: UInt32 = 0
        var idle: UInt32 = 0, waitFrame: UInt32 = 0
    }

    // MARK: State

    private(set) var machine: AmigaMachine
    private let code: [UInt8]
    private var entries = Entries()
    /// The player's file, and the module given it (empty for a custom module, which is its own).
    private let playerBytes: [UInt8]
    private let module: [UInt8]
    /// Files the player may load by name (through LoadSeg, Open or `dtg_LoadFile`), the module's own name
    /// among them.
    private var files: [(name: [UInt8], bytes: [UInt8])]
    private let moduleName: [UInt8]

    /// The player's tags, as found.
    private(set) var tags: [(tag: UInt32, value: UInt32)] = []
    private(set) var segments: [AmigaHunks.Segment] = []
    private var relocateAt: UInt32 = 0
    private(set) var moduleAt: UInt32 = 0
    /// Where score's AllocMem gives memory from next (its `chippoint`), which it never takes back.
    private var memoryPoint: UInt32 = 0
    /// What score's `dtg_GetListData` gives: the module, and each file loaded since, by number.
    private var loaded: [(at: UInt32, size: UInt32)] = []
    private var openFiles: [(file: Int, position: Int)?] = []
    private var signals: UInt32 = 0x0000_FFFF
    /// The request for timer.device's unit of frames, its count of frames to wait, and its routine.
    private var timerRequest: UInt32?
    private var timerWaiting = false
    private var timerCount: UInt32 = 0
    private var timerRoutine: UInt32 = 0

    /// The player's range of songs, as it gives it.
    private(set) var firstSong = 0
    private(set) var lastSong = 0
    /// The song the player says to begin with, if it says one (`DTP_NewSubSongRange`).
    private(set) var defaultSong: Int?
    /// How many times the player has called `dtg_SongEnd` since the song was started.
    private(set) var songEnds = 0
    /// Why the player stopped, if it has: a call into the system that is not given, or code gone wrong.
    private(set) var failure: String?
    /// Where the player's code went wrong, if it did (for finding out why).
    private(set) var faultAt: UInt32?
    private(set) var faultStatus: UInt32 = 0
    /// Whether the host's timer calls the player's `DTP_Interrupt` (rather than its own interrupts).
    private(set) var hostTimer = false
    /// The processor's cycles spent, not waiting, since the song was started.
    private(set) var busyCycles: Int64 = 0

    /// - Parameters:
    ///   - player: the player's AmigaDOS program.
    ///   - module: the module it is to play (none for a custom module).
    ///   - name: the file name the player is told its module has.
    ///   - files: other files the player may load, by their names.
    init(player: [UInt8], module: [UInt8] = [], name: String = "module", files: [(name: String, bytes: [UInt8])] = [],
         chipRAM: Int = 0x20_0000) throws(TuneError)
    {
        playerBytes = player
        self.module = module
        moduleName = Array(name.utf8.prefix(120))
        self.files = [(Array(name.utf8.prefix(120)), module.isEmpty ? player : module)]
        for file in files { self.files.append((Array(file.name.utf8), file.bytes)) }
        machine = AmigaMachine(chipRAM: chipRAM)
        var entries = Entries()
        code = Self.assemble(&entries)
        self.entries = entries
        var refusal: TuneError?
        do {
            try place()
        } catch {
            refusal = error
        }
        if let refusal { throw refusal }
    }

    /// A host for a player that is written for it in Swift (as Wanted Team's are, for players of their
    /// format whose code is in each module): no program of its own, but the module where UADE puts it for
    /// the player whose place it takes (`moduleAt`, past that player's hunks), and the host's routines
    /// and its interrupts as for any. The player's own 68000 code, if any, goes at `clientCode`.
    init(moduleAt: UInt32, module: [UInt8], name: String = "module", files: [(name: String, bytes: [UInt8])] = [],
         chipRAM: Int = 0x20_0000) throws(TuneError)
    {
        playerBytes = []
        self.module = module
        moduleName = Array(name.utf8.prefix(120))
        self.files = [(Array(name.utf8.prefix(120)), module)]
        for file in files { self.files.append((Array(file.name.utf8), file.bytes)) }
        machine = AmigaMachine(chipRAM: chipRAM)
        var entries = Entries()
        code = Self.assemble(&entries)
        self.entries = entries
        self.moduleAt = moduleAt
        guard Int(moduleAt) + module.count + 0x10000 + Self.room <= machine.memorySize else {
            throw .unsupported("a module larger than the Amiga's chip RAM")
        }
    }

    /// Where a player written in Swift puts its own 68000 code: 6 KB of the host's.
    static let clientCode: UInt32 = 0x6000
    static let clientCodeSize = 0x1800

    /// Where the player and its module go, and its tags: as UADE has them. The player's file is put at
    /// $9000; its hunks are relocated from 16 KB past the 4 KB page its file ends in; and the module, if
    /// any, goes 8 KB past the page the hunks end in (`uadecore_reset`).
    private mutating func place() throws(TuneError) {
        guard AmigaHunks.isOne(playerBytes) else { throw .malformed("not an AmigaDOS program") }
        let sizes = try AmigaHunks.sizes(playerBytes)
        relocateAt = ((Self.playerFile + UInt32(playerBytes.count)) & 0x7FFF_F000) + 0x4000
        // (UADE's `calc_reloc_size` adds up the hunks' sizes of 24 bits.)
        let length = UInt32(sizes.reduce(0) { $0 + ($1 & 0x3FF_FFFF) })
        moduleAt = ((relocateAt + length) & 0x7FFF_F000) + 0x2000
        guard Int(moduleAt) + module.count + 0x10000 <= machine.memorySize else {
            throw .unsupported("a player and module larger than the Amiga's chip RAM")
        }
        try load()
        // The tags: the first hunk begins MOVEQ #-1,D0; RTS; "DELIRIUM", then their address.
        let first = segments[0].address
        guard segments[0].size >= 16, machine.peek32(first + 4) == 0x4445_4C49, machine.peek32(first + 8) == 0x5249_554D else {
            throw .malformed("not a DeliTracker player")
        }
        var at = machine.peek32(first + 12)
        while tags.count < 256 {
            guard Int(at) + 8 <= machine.memorySize else { throw .malformed("a DeliTracker player whose tags run off the memory") }
            let tag = machine.peek32(at)
            if tag == 0 { break }
            tags.append((tag, machine.peek32(at + 4)))
            at += 8
        }
    }

    /// The player loaded into a machine switched on afresh, as UADE does it for each song.
    private mutating func load() throws(TuneError) {
        machine.powerOn()
        if !playerBytes.isEmpty {
            machine.load(playerBytes, at: Self.playerFile)
            segments = try AmigaHunks.load(playerBytes, at: relocateAt, into: machine.memory, capacity: machine.memorySize,
                                           placement: .uade)
        }
        if !module.isEmpty { machine.load(module, at: moduleAt) }
    }

    /// The value of a tag the player has, if it has it.
    func tag(_ tag: UInt32) -> UInt32? { tags.first { $0.tag == tag }?.value }

    /// A string in the machine's memory, at most `most` bytes of it.
    func string(at address: UInt32, most: Int = 256) -> String {
        var bytes: [UInt8] = []
        var at = address
        while bytes.count < most, Int(at) < machine.memorySize {
            let byte = machine.peek8(at)
            if byte == 0 { break }
            bytes.append(byte)
            at += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The player's name for itself (`DTP_PlayerName`), and the names it gives its module and its format
    /// once it has been started (`DTP_ModuleName`, `DTP_FormatName`: each a pointer to a pointer).
    var playerName: String { tag(DeliTag.playerName).map { string(at: $0, most: 25) } ?? "" }
    var namedModule: String { named(DeliTag.moduleName) }
    var namedFormat: String { named(DeliTag.formatName) }

    private func named(_ tag: UInt32) -> String {
        guard let pointer = self.tag(tag), pointer != 0 else { return "" }
        let at = machine.peek32(pointer)
        return at == 0 ? "" : string(at: at, most: 250)
    }

    // MARK: Starting

    /// The processor's time a call into the player is given before it is taken to have gone wrong: ten
    /// seconds of the machine's.
    private static let callClocks: UInt64 = 10 * 3_546_895

    /// Starts the player afresh with the song `song` (as the player numbers them: from `firstSong`), as
    /// score does: everything up to its interrupts going. Throws if the player does not get that far.
    /// With no song, the one score starts with: the one the player has set in `dtg_SndNum` by then, if
    /// any, or else its first.
    mutating func start(song: Int?) throws(TuneError) {
        try prepare()
        // score's `call_config`, `call_check_module` and `call_extload`.
        if let config = tag(DeliTag.config) {
            guard try call(config) == 0 else { throw .unsupported("the player would not be configured") }
        }
        if let check = tag(DeliTag.check2) ?? tag(DeliTag.check5) ?? tag(DeliTag.check3) {
            guard try call(check) == 0 else { throw .malformed("the player does not take the module") }
        }
        if let extLoad = tag(DeliTag.extLoad) {
            guard try call(extLoad) == 0 else { throw .missingCompanion("the player could not load a file it needs") }
        }
        startInterrupts()
        if let initPlayer = tag(DeliTag.initPlayer) {
            // (A player whose DTP_InitPlayer fails is played all the same, as score plays it.)
            _ = try call(initPlayer)
        }
        // `call_check_subsongs`: DTP_SubSongRange gives the first and last in D0 and D1;
        // DTP_NewSubSongRange points at three words, the song to begin with, the first and the last.
        firstSong = 0
        lastSong = 0
        defaultSong = nil
        if let range = tag(DeliTag.subSongRange) {
            _ = try call(range)
            firstSong = Int(Int16(truncatingIfNeeded: machine.cpu.registers[0]))
            lastSong = Int(Int16(truncatingIfNeeded: machine.cpu.registers[1]))
        }
        if let range = tag(DeliTag.newSubSongRange) {
            let first = Int(Int16(bitPattern: machine.peek16(range)))
            defaultSong = first
            machine.poke16(Self.globals + Self.dtgSndNum, UInt16(truncatingIfNeeded: first))
            firstSong = Int(Int16(bitPattern: machine.peek16(range + 2)))
            lastSong = Int(Int16(bitPattern: machine.peek16(range + 4)))
        }
        let set = Int(Int16(bitPattern: machine.peek16(Self.globals + Self.dtgSndNum)))
        setSong(song ?? (set != 0 ? set : firstSong))
        if let volume = tag(DeliTag.volume) { _ = try call(volume) }
        if let routine = tag(DeliTag.initSound) { try initSound(routine) }
        // `set_player_interrupt`.
        if let startInt = tag(DeliTag.startInt) {
            _ = try call(startInt)
        } else if let interrupt = tag(DeliTag.interrupt) {
            playByTimer(interrupt)
        } else {
            throw .unsupported("a DeliTracker player with no interrupt")
        }
        idle()
    }

    /// `SetSubSong` (a song below nought made nought), and the filter turned off, as score does then.
    mutating func setSong(_ song: Int) {
        machine.poke16(Self.globals + Self.dtgSndNum, UInt16(truncatingIfNeeded: max(0, song)))
        let pra = machine.chips.read8(0xBFE001, at: machine.cpu.cycles)
        machine.chips.write8(0xBFE001, pra | 2, at: machine.cpu.cycles)
    }

    /// `call_init_sound`, with INTENAR in D1: a player that turns the interrupts off in it has them
    /// turned back on.
    mutating func initSound(_ routine: UInt32, with registers: [(Int, UInt32)] = []) throws(TuneError) {
        let before = machine.chips.read16(AmigaChips.custom + 0x1C, at: machine.cpu.cycles)
        machine.cpu.registers[1] = UInt32(before)
        _ = try call(routine, with: registers)
        let after = machine.chips.read16(AmigaChips.custom + 0x1C, at: machine.cpu.cycles)
        if before & 0x4000 != 0, after & 0x4000 == 0 {
            machine.chips.write16(AmigaChips.custom + 0x9A, 0xC000, at: machine.cpu.cycles)
        }
    }

    /// `set_player_interrupt` for a player with no interrupts of its own: `routine` called from CIA-A's
    /// timer B, set going from `dtg_Timer`.
    mutating func playByTimer(_ routine: UInt32) {
        // (UADE's host takes this long over what it does between the player's DTP_InitSound and setting
        // the timer going, as measured against a timer the player sets going itself at the end of its
        // DTP_InitSound: which of the two's interrupts comes first, when they come close, is as in UADE.)
        pause(clocks: Self.scoreBeforeTimer)
        addCIAAInterrupt(timer: 1, code: routine, data: 0)
        hostTimer = true
    }

    /// How long score's code between `call_init_sound` and `add_ciaa_interrupt` takes, in Paula's clocks.
    static let scoreBeforeTimer: UInt64 = 265

    /// Lets time pass, as score's code does that is not here: the machine waits in score's main loop,
    /// taking any interrupt that comes due.
    mutating func pause(clocks: UInt64) {
        guard clocks > 0 else { return }
        idle()
        _ = run(until: machine.now + clocks)
    }

    /// The rest, score's `playloop`: waiting for each frame, with the globals in A5.
    mutating func idle() {
        machine.cpu.registers[13] = Self.globals
        machine.cpu.setStatus(0)
        machine.cpu.registers[15] = Self.userStack - 16
        machine.jump(to: entries.idle)
    }

    /// `init_interrupts`: score's handlers of the frame's interrupt and the CIAs', the frame's let
    /// through; and the song nought and `dtg_Timer` fifty times a second, as score has them before
    /// DTP_InitPlayer.
    mutating func startInterrupts() {
        machine.poke32(0x68, entries.level2)
        machine.poke32(0x6C, entries.level3)
        machine.poke32(0x78, entries.level6)
        machine.chips.write16(AmigaChips.custom + 0x9A, 0xC020, at: machine.cpu.cycles)
        machine.poke16(Self.globals + Self.dtgSndNum, 0)
        machine.poke16(Self.globals + Self.dtgTimer, Self.defaultTimer)
    }

    /// The machine switched on afresh with the player and its module in it, and everything score does
    /// before it calls the player: its system, its globals, and the module's name.
    mutating func prepare() throws(TuneError) {
        try load()
        songEnds = 0
        failure = nil
        faultAt = nil
        hostTimer = false
        busyCycles = 0
        loaded = [(0, 0)]
        openFiles = []
        signals = 0x0000_FFFF
        timerRequest = nil
        timerWaiting = false
        machine.load(code, at: Self.codeAt)
        setUpSystem()
        // score's `contplayer`: where AllocMem begins, past the module (for a custom, none).
        memoryPoint = (moduleAt + UInt32(module.count) + 1024) & ~0xFF
        let custom = tag(DeliTag.customPlayer) != nil
        loaded[0] = custom ? (0, 0) : (moduleAt, UInt32(module.count))
        setUpGlobals(custom: custom)
        setUpNames()
    }

    /// Calls a routine of the player's from score's main program: in user mode, the interrupts let
    /// through, the globals in A5 and the routine's address in A0 and D0, and time passing as it runs.
    /// Returns D0. A player written in Swift may set other registers as its own code would have them
    /// (`registers`, by their place in `M68000.registers`).
    mutating func call(_ routine: UInt32, with registers: [(Int, UInt32)] = []) throws(TuneError) -> UInt32 {
        machine.cpu.setStatus(0)
        machine.cpu.registers[15] = Self.userStack - 16
        machine.poke32(Self.userStack - 20, AmigaMachine.returnAddress)
        machine.cpu.registers[15] = Self.userStack - 20
        machine.cpu.registers[13] = Self.globals
        machine.cpu.registers[8] = routine
        machine.cpu.registers[0] = routine
        for (r, value) in registers where r >= 0 && r < 15 { machine.cpu.registers[r] = value }
        machine.jump(to: routine)
        let deadline = machine.now + Self.callClocks
        guard run(until: deadline) == .returned else {
            throw .unsupported(failure ?? "the player did not come back from a call as it should")
        }
        return machine.cpu.registers[0]
    }

    // MARK: Running

    /// Runs the machine until `end` (in Paula's clocks since it was switched on), answering the host's
    /// traps on the way. `.reached` once it is there; `.returned` for a call that has come back; `.failed`
    /// for a player that has gone wrong, which is stopped (`failure` says why).
    mutating func run(until end: UInt64) -> AmigaRun {
        while true {
            let before = machine.cpu.cycles, waitedBefore = machine.waitedCycles
            let outcome = machine.run(until: end)
            busyCycles += Int64(machine.cpu.cycles - before) - Int64(machine.waitedCycles - waitedBefore)
            switch outcome {
            case .reached, .returned:
                return outcome
            case .failed:
                if failure == nil {
                    failure = "the player's code went wrong"
                    // Where: the instruction that is not one, or, for an exception (whose vector is the
                    // machine's ILLEGAL), the place it was taken at, from the stack.
                    let pc = machine.cpu.pc &- 2
                    faultAt = pc == AmigaMachine.faultAddress ? machine.peek32(machine.cpu.registers[15] &+ 2) : pc
                    faultStatus = machine.cpu.statusRegister
                }
                return .failed
            case let .trap(number):
                let pc = machine.cpu.pc
                if number == 15, pc >= Self.stubs + 2, pc < Self.stubs + UInt32(Call.allCases.count * 4) + 2,
                   (pc - Self.stubs - 2) % 4 == 0, let call = Call(rawValue: Int(pc - Self.stubs - 2) / 4)
                {
                    if !perform(call) {
                        return .failed
                    }
                } else {
                    // The player's own trap, through its vector.
                    machine.cpu.takeTrap(number)
                }
            }
        }
    }

    /// The machine's memory, and its size.
    var memory: UnsafeMutablePointer<UInt8> { machine.memory }
    var memorySize: Int { machine.memorySize }
    /// The time the machine has reached, in Paula's clocks since it was switched on.
    var now: UInt64 { machine.now }

    /// Starts a stretch of time, from which the writes to Paula made in it are timed (see
    /// `AmigaMachine.beginStretch`); and the time it starts at.
    mutating func beginStretch() -> UInt64 {
        machine.beginStretch()
        return machine.chips.clock
    }

    /// The writes to Paula and the DMA made since this was last asked, their cycles counted from the
    /// stretch's start.
    mutating func takeWrites(into list: inout [AmigaWrite]) {
        machine.takeWrites(into: &list)
    }

    /// The room at the top of the memory that the player is not given (by AllocMem), kept for silence.
    static let room = 0x20000 + 2048

    /// When the player's next tick comes: the next time CIA-A's timer B runs out, if the host's timer
    /// calls it, otherwise the next frame.
    func nextTick(after time: UInt64) -> UInt64 {
        if hostTimer, let next = machine.chips.timerRunsOut(cia: 0, timer: 1) { return max(next, time + 1) }
        let frame = machine.chips.frameClocks
        return (time / frame + 1) * frame
    }

    // MARK: The system, as score sets it up

    private mutating func setUpSystem() {
        // `start`: the stacks' guards, the interrupts, the DMA and the requests all off, the filter off,
        // the CIAs' interrupts held back, no modulation, and every voice pointed at a word of silence.
        machine.poke32(Self.superStack, 0x5741_4C4C)
        machine.poke32(Self.userStack, 0x5741_4C4C)
        machine.cpu.setStatus(0x2700)
        machine.cpu.timesMultiplies = true
        machine.cpu.registers[15] = Self.superStack
        machine.cpu.userStack = Self.userStack
        machine.chips.interrupts = true
        machine.chips.write16(AmigaChips.custom + 0x9A, 0x7FFF)
        machine.chips.write16(AmigaChips.custom + 0x9C, 0x7FFF)
        machine.chips.write16(AmigaChips.custom + 0x96, 0x7FFF)
        machine.chips.write8(0xBFE201, 3)
        machine.chips.write8(0xBFE001, 2)
        machine.chips.write8(0xBFDD00, 0x1F)
        machine.chips.write16(AmigaChips.custom + 0x9E, 0x00FF)
        // (The vectors of exceptions are the machine's own, each the ILLEGAL that stops it: score's
        // `default_exception` stops the player too.)
        for v in 0 ..< 4 {
            let at = AmigaChips.custom + 0xA0 + UInt32(v * 16)
            machine.chips.write16(at + 8, 0)
            machine.chips.write16(at, UInt16(AmigaMachine.silence >> 16))
            machine.chips.write16(at + 2, UInt16(AmigaMachine.silence & 0xFFFF))
            machine.chips.write16(at + 4, 1)
            machine.chips.write16(at + 6, 150)
        }
        machine.chips.write16(AmigaChips.custom + 0x96, 0x8280)
        machine.chips.write16(AmigaChips.custom + 0x9A, 0xC000)
        // exec.library: every routine one that stops the player, but those score gives.
        for offset in stride(from: 6, through: AmigaMachine.libraryRoutines * 6, by: 6) {
            machine.setLibraryRoutine(offset, to: Self.stub(.unimplementedExec))
        }
        let exec: [(Int, UInt32)] = [
            (162, Self.stub(.setIntVector)), (168, Self.stub(.addIntServer)), (198, Self.stub(.allocMem)),
            (684, Self.stub(.allocMem)), (210, entries.rts), (690, entries.rts), (498, Self.stub(.openResource)),
            (444, Self.stub(.openDevice)), (456, Self.stub(.doIO)), (462, Self.stub(.sendIO)), (474, entries.okay),
            (480, entries.okay), (372, entries.okay), (180, entries.cause), (408, Self.stub(.openLibrary)),
            (552, Self.stub(.openLibrary)), (534, Self.stub(.typeOfMem)), (330, Self.stub(.allocSignal)),
            (324, entries.rts), (30, entries.supervisor), (150, entries.superState), (156, entries.userState),
            (294, entries.findTask),
            // The harmless: CacheClearU, Forbid, Permit, Enable, Disable, CloseLibrary.
            (636, entries.rts), (132, entries.rts), (138, entries.rts), (126, entries.rts), (120, entries.rts),
            (414, entries.rts),
        ]
        for (offset, address) in exec { machine.setLibraryRoutine(offset, to: address) }
        // "fuck med player", and a processor of 68020 or better (AttnFlags); fifty frames a second.
        machine.poke8(AmigaMachine.execBase + 0x126, 0xFF)
        machine.poke16(AmigaMachine.execBase + 0x128, 0x0003)
        machine.poke8(AmigaMachine.execBase + 0x212, 50)
        // dos.library.
        Self.library(machine, at: Self.dosBase, routines: 200, to: Self.stub(.unimplementedDOS))
        let dos: [(Int, UInt32)] = [
            (150, Self.stub(.loadSeg)), (30, Self.stub(.open)), (66, Self.stub(.seek)), (42, Self.stub(.read)),
            (36, Self.stub(.close)), (126, entries.okay), (84, Self.stub(.lock)), (90, entries.rtsNonZero),
            (156, entries.rtsNonZero),
        ]
        for (offset, address) in dos { Self.jump(machine, Self.dosBase &- UInt32(offset), address) }
        // intuition.library, icon.library and the CIAs' resources, whose every routine is refused but
        // intuition's AllocRemember (which is AllocMem's), ciab.resource's AddICRVector and the two's
        // RemICRVector; and ciaa.resource's AddICRVector, which fails.
        Self.library(machine, at: Self.intuitionBase, routines: 0x400 / 6, to: Self.stub(.unimplementedIntuition))
        Self.jump(machine, Self.intuitionBase &- 0x18C, Self.stub(.allocMem))
        Self.library(machine, at: Self.iconBase, routines: 108 / 6, to: Self.stub(.unimplementedIcon))
        Self.library(machine, at: Self.ciaaResource, routines: 10, to: Self.stub(.unimplementedCIA))
        Self.library(machine, at: Self.ciabResource, routines: 10, to: Self.stub(.unimplementedCIA))
        Self.jump(machine, Self.ciaaResource &- 6, entries.rtsNonZero)
        Self.jump(machine, Self.ciaaResource &- 12, Self.stub(.remCIAAInterrupt))
        Self.jump(machine, Self.ciabResource &- 6, Self.stub(.addCIABInterrupt))
        Self.jump(machine, Self.ciabResource &- 12, Self.stub(.remCIABInterrupt))
        Self.jump(machine, Self.ciabResource &- 18, entries.okay)
        Self.jump(machine, Self.ciabResource &- 24, entries.okay)
    }

    private static func library(_ machine: borrowing AmigaMachine, at base: UInt32, routines: Int, to address: UInt32) {
        for r in 1 ... routines { jump(machine, base &- UInt32(r * 6), address) }
    }

    private static func jump(_ machine: borrowing AmigaMachine, _ at: UInt32, _ to: UInt32) {
        machine.poke16(at, 0x4EF9)
        machine.poke32(at &+ 2, to)
    }

    /// score's `init_base`.
    private mutating func setUpGlobals(custom: Bool) {
        let g = Self.globals
        // EaglePlayer's jumps below, every one refused but those score gives (with a JSR, as it has them).
        for r in 1 ... 0x200 / 6 {
            machine.poke16(g &- UInt32(r * 6), 0x4EB9)
            machine.poke32(g &- UInt32(r * 6) + 2, Self.stub(.unimplementedEagle))
        }
        machine.poke32(g + Self.dtgChkData, loaded[0].at)
        machine.poke32(g + Self.dtgChkSize, loaded[0].size)
        machine.poke16(g + Self.dtgSndNum, 0)
        for field in [Self.dtgSndVol, Self.dtgSndLBal, Self.dtgSndRBal] { machine.poke16(g + field, 64) }
        machine.poke16(g + Self.epgVoices, 15)
        for v in 0 ..< 4 { machine.poke16(g + Self.epgVoice1Vol + UInt32(v * 2), 64) }
        machine.poke32(g + Self.dtgAudioAlloc, entries.okay)
        machine.poke32(g + Self.dtgAudioFree, entries.okay)
        Self.jump(machine, g &+ UInt32(bitPattern: Self.enppAllocAudio), entries.testD0)
        machine.poke32(g + Self.dtgGetListData, Self.stub(.getListData))
        Self.jump(machine, g &+ UInt32(bitPattern: Self.enppGetListData), Self.stub(.getListData))
        machine.poke32(g + Self.dtgSongEnd, Self.stub(.songEnd))
        Self.jump(machine, g &+ UInt32(bitPattern: Self.enppSongEnd), Self.stub(.songEnd))
        machine.poke32(g + Self.dtgStartInt, tag(DeliTag.startInt) ?? Self.stub(.defaultStartInt))
        machine.poke32(g + Self.dtgStopInt, tag(DeliTag.stopInt) ?? Self.stub(.defaultStopInt))
        machine.poke32(g + Self.dtgSetTimer, Self.stub(.setTimer))
        machine.poke16(g + Self.dtgTimer, 0)
        Self.jump(machine, g &+ UInt32(bitPattern: Self.enppSetTimer), Self.stub(.setTimer))
        // (The note player is not given: none of these players uses it.)
        machine.poke32(g + Self.dtgNotePlayer, entries.rts)
        machine.poke32(g + Self.epgFindAuthor, entries.rts)
        machine.poke32(g + Self.epgModuleChange, Self.stub(.moduleChange))
        machine.poke32(g + Self.dtgWaitAudioDMA, entries.waitAudioDMA)
        machine.poke32(g + Self.dtgPathArrayPtr, Self.pathArray)
        machine.poke32(g + Self.dtgFileArrayPtr, Self.fileArray)
        machine.poke32(g + Self.dtgDirArrayPtr, Self.dirArray)
        machine.poke32(g + Self.dtgLoadFile, Self.stub(.loadFile))
        Self.jump(machine, g &+ UInt32(bitPattern: Self.enppLoadFile), Self.stub(.loadFile))
        Self.jump(machine, g &+ UInt32(bitPattern: Self.enppNewLoadFile), Self.stub(.loadFile))
        machine.poke32(g + Self.epgNewLoadFile, Self.stub(.loadFile))
        machine.poke32(g + Self.dtgCopyDir, Self.stub(.copyDir))
        machine.poke32(g + Self.dtgCopyFile, Self.stub(.copyFile))
        machine.poke32(g + Self.dtgCutSuffix, entries.rts)
        machine.poke32(g + Self.dtgCopyString, Self.stub(.copyString))
        machine.poke32(g + Self.dtgDOSBase, Self.dosBase)
        machine.poke32(g + Self.dtgIntuitionBase, Self.intuitionBase)
        Self.jump(machine, g &+ UInt32(bitPattern: Self.enppFindAuthor), entries.rts)
        // DTP_DeliBase and EP_EagleBase each point at where the player keeps the globals' address.
        for t in [DeliTag.deliBase, DeliTag.eagleBasePointer] {
            if let at = tag(t), Int(at) + 4 <= machine.memorySize { machine.poke32(at, g) }
        }
        _ = custom
    }

    /// score's `split_module_name` and `copy_module_name`: the module's directory (none here), its file
    /// name, and the two together as its path.
    private mutating func setUpNames() {
        machine.poke8(Self.dirArray, 0)
        for (i, byte) in moduleName.enumerated() { machine.poke8(Self.fileArray + UInt32(i), byte) }
        machine.poke8(Self.fileArray + UInt32(moduleName.count), 0)
        for (i, byte) in moduleName.enumerated() { machine.poke8(Self.pathArray + UInt32(i), byte) }
        machine.poke8(Self.pathArray + UInt32(moduleName.count), 0)
    }

    // MARK: The host's routines

    /// Does what score's routine does, the registers as the player called it with; then the player goes
    /// on from the RTS after the TRAP. False for a call that stops the player.
    private mutating func perform(_ call: Call) -> Bool {
        let d0 = machine.cpu.registers[0], d1 = machine.cpu.registers[1], a1 = machine.cpu.registers[9]
        let cycles = machine.cpu.cycles
        switch call {
        case .unimplementedExec, .unimplementedDOS, .unimplementedEagle, .unimplementedIntuition, .unimplementedIcon,
             .unimplementedCIA:
            // The routine's offset: below EaglePlayer's globals, from where its JSR came back to (as score's
            // `eaglebase_unimplemented_call` finds it); in a library, from the JSR d16(A6) that called it
            // (as its `library_unimplemented_call` does).
            let back = machine.peek32(machine.cpu.registers[15])
            let offset = call == .unimplementedEagle ? UInt16(truncatingIfNeeded: back &- 6 &- Self.globals)
                : machine.peek16(back &- 2)
            let library = switch call {
            case .unimplementedExec: "exec.library"
            case .unimplementedDOS: "dos.library"
            case .unimplementedEagle: "EaglePlayer"
            case .unimplementedIntuition: "intuition.library"
            case .unimplementedIcon: "icon.library"
            default: "a CIA's resource"
            }
            let name = call == .unimplementedExec ? Self.execName(Int(Int16(bitPattern: offset))) : nil
            failure = "a player that calls \(library)'s " + (name ?? "routine at \(Int(Int16(bitPattern: offset)))")
                + ", which UADE's host does not give"
            return false
        case .allocMem:
            // score's `exec_alloc_mem`: from `chippoint`, sixteen bytes past the boundary below its end,
            // cleared if asked (MEMF_CLEAR); never refused.
            let at = memoryPoint
            let end = UInt64(at) + UInt64(d0)
            guard end + 16 <= UInt64(machine.memorySize - Self.room) else {
                machine.cpu.registers[0] = 0
                return true
            }
            memoryPoint = (UInt32(end) & ~0xF) + 16
            if d1 & 0x1_0000 != 0, d0 > 0 { machine.memory.advanced(by: Int(at)).initialize(repeating: 0, count: Int(d0)) }
            machine.cpu.registers[0] = at
        case .openLibrary:
            let name = string(at: a1, most: 64)
            machine.cpu.registers[0] = name == "dos.library" ? Self.dosBase : name == "icon.library" ? Self.iconBase : 0
        case .openResource:
            let name = string(at: a1, most: 4)
            machine.cpu.registers[0] = name == "ciab" ? Self.ciabResource : name == "ciaa" ? Self.ciaaResource : 0
        case .openDevice:
            // score's `exec_open_device`: audio.device, its allocation given the first of the channels
            // asked for; and timer.device, only its unit that counts frames (UNIT_VBLANK).
            let name = string(at: machine.cpu.registers[8], most: 32)
            if name == "audio.device" {
                if machine.peek16(a1 + 28) == 32, machine.peek32(a1 + 36) != 0 {
                    machine.poke32(a1 + 24, UInt32(machine.peek8(machine.peek32(a1 + 40))))
                    if machine.peek32(a1 + 32) == 0 { machine.poke32(a1 + 32, 0x756E_6971) }
                }
            } else if name == "timer.device", d0 == 1 {
                machine.poke32(a1 + 24, d0)
                timerRequest = a1
                timerWaiting = false
            } else {
                failure = name == "timer.device" ? "a player that times itself by a unit of timer.device other than the frames'"
                    : "a player that opens \(name)"
                return false
            }
            machine.poke8(a1 + 31, 0)
            machine.cpu.registers[0] = 0
        case .doIO:
            machine.poke8(a1 + 31, 0)
            machine.cpu.registers[0] = 0
        case .sendIO:
            // score's `exec_sendio`, for the frames' timer only, asked to wait (TR_ADDREQUEST): so many
            // frames as its seconds and microseconds make, and then the code at $12 of what its reply
            // port's task points at is called, from the main loop (`HandleTimerDevice`).
            guard a1 == timerRequest, machine.peek16(a1 + 28) == 9 else {
                failure = "a player that asks timer.device for more than to wait"
                return false
            }
            let seconds = machine.peek32(a1 + 32) & 0xFFFF, micros = machine.peek32(a1 + 36)
            let frames = seconds * 50 &+ UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: min(micros / 20000, 0xFFFF))))
            timerCount = frames
            timerWaiting = true
            timerRoutine = machine.peek32(machine.peek32(machine.peek32(a1 + 14) &+ 16) &+ 0x12)
            machine.poke8(a1 + 31, 0)
        case .frame:
            // score's `HandleTimerDevice`, each frame in its main loop for a player that sets its own
            // interrupts going: the timer's wait counted down, and once it is over its routine given to
            // be called, with the request in A1.
            machine.cpu.registers[8] = 0
            if tag(DeliTag.startInt) != nil, !hostTimer, timerWaiting {
                if timerCount != 0 {
                    timerCount -= 1
                } else {
                    timerWaiting = false
                    guard timerRoutine != 0 else {
                        failure = "a player whose timer.device routine is nowhere"
                        return false
                    }
                    machine.cpu.registers[8] = timerRoutine
                    machine.cpu.registers[9] = timerRequest ?? 0
                    machine.cpu.registers[0] = timerRoutine
                }
            }
        case .typeOfMem:
            // MEMF_PUBLIC | MEMF_CHIP below 2 MB.
            machine.cpu.registers[0] = a1 < 0x20_0000 ? 3 : 0
        case .allocSignal:
            // score's `exec_allocsignal`: the first free from 31 down, or the one asked for.
            var result: UInt32 = 0xFFFF_FFFF
            if d0 == 0xFFFF_FFFF {
                for s in stride(from: 31, through: 0, by: -1) where signals & (1 << UInt32(s)) == 0 {
                    result = UInt32(s)
                    break
                }
            } else if signals & (1 << (d0 & 31)) == 0 {
                signals |= 1 << (d0 & 31)
                result = d0
            }
            machine.cpu.registers[0] = result
        case .setIntVector:
            // score's `exec_set_int_vector`, only for Paula's four (7 to 10): its handler of level 4 put
            // in the vector, and the player's code and data put in its tables for the number.
            let number = Int(d0 & 0xFFFF)
            guard number >= 7, number <= 10 else {
                failure = "a player that sets the vector of interrupt \(number)"
                return false
            }
            machine.poke32(0x70, entries.level4)
            let slot = UInt32(number * 4)
            let old = Self.oldStructs + slot
            machine.poke32(old + 0x12, machine.peek32(Self.irqLines + slot))
            machine.poke32(old + 0x0E, machine.peek32(Self.isData + slot))
            machine.poke32(Self.isData + slot, machine.peek32(a1 + 0x0E))
            machine.poke32(Self.irqLines + slot, machine.peek32(a1 + 0x12))
            machine.cpu.registers[0] = old
            machine.chips.write16(AmigaChips.custom + 0x9A, 0x8000 | 1 << UInt16(number), at: cycles)
        case .addIntServer:
            // Only for the frame's (5): the code and data put at the end of score's list of servers.
            guard d0 & 0xFF == 5 else {
                failure = "a player that adds a server to interrupt \(d0 & 0xFF)"
                return false
            }
            var at = Self.vblankServers
            while machine.peek32(at) != 0, at < Self.irqLines - 16 { at += 8 }
            machine.poke32(at, machine.peek32(a1 + 0x12))
            machine.poke32(at + 4, machine.peek32(a1 + 0x0E))
            machine.poke32(at + 8, 0)
            machine.cpu.registers[0] = 0
        case .addCIABInterrupt:
            addCIABInterrupt(timer: Int(d0 & 1), code: machine.peek32(a1 + 0x12), data: machine.peek32(a1 + 0x0E))
            machine.cpu.registers[0] = 0
        case .remCIAAInterrupt, .remCIABInterrupt:
            let b = call == .remCIABInterrupt
            let timer = UInt32(d0 & 1)
            machine.chips.write8(b ? 0xBFDD00 : 0xBFED01, UInt8(1 << timer), at: cycles)
            machine.poke32((b ? Self.ciabDatas : Self.ciaaDatas) + timer * 4, 0)
            machine.poke32((b ? Self.ciabInts : Self.ciaaInts) + timer * 4, 0)
            machine.cpu.registers[0] = 0
        case .loadSeg:
            let name = Array(string(at: d1, most: 256).utf8)
            guard name.isEmpty || file(named: name) != nil else {
                failure = "a player that loads a file it is not given"
                return false
            }
            machine.cpu.registers[0] = loadSegment(name).map { ($0 - 4) >> 2 } ?? 0
        case .open:
            let name = Array(string(at: d1, most: 256).utf8)
            guard let file = file(named: name) else {
                machine.cpu.registers[0] = 0
                return true
            }
            openFiles.append((file, 0))
            machine.cpu.registers[0] = UInt32(openFiles.count)
        case .read:
            guard d1 >= 1, Int(d1) <= openFiles.count, let open = openFiles[Int(d1) - 1] else {
                machine.cpu.registers[0] = 0xFFFF_FFFF
                return true
            }
            let bytes = files[open.file].bytes
            let count = max(0, min(Int(machine.cpu.registers[3]), bytes.count - open.position))
            let to = machine.cpu.registers[2]
            for i in 0 ..< count { machine.poke8(to &+ UInt32(i), bytes[open.position + i]) }
            openFiles[Int(d1) - 1]!.position += count
            machine.cpu.registers[0] = UInt32(count)
        case .seek:
            guard d1 >= 1, Int(d1) <= openFiles.count, let open = openFiles[Int(d1) - 1] else {
                machine.cpu.registers[0] = 0xFFFF_FFFF
                return true
            }
            let size = files[open.file].bytes.count
            let offset = Int(Int32(bitPattern: machine.cpu.registers[2]))
            let mode = Int32(bitPattern: machine.cpu.registers[3])
            let to = mode == -1 ? offset : mode == 1 ? size + offset : open.position + offset
            machine.cpu.registers[0] = UInt32(open.position)
            openFiles[Int(d1) - 1]!.position = max(0, min(size, to))
        case .close:
            if d1 >= 1, Int(d1) <= openFiles.count { openFiles[Int(d1) - 1] = nil }
            machine.cpu.registers[0] = 0xFFFF_FFFF
        case .lock:
            machine.cpu.registers[0] = file(named: Array(string(at: d1, most: 256).utf8)) == nil ? 0 : 0xF000_0000
        case .getListData:
            // The module (number nought) or a file loaded since: its address in A0 and size in D0.
            let index = Int(d0)
            if index < loaded.count {
                machine.cpu.registers[8] = loaded[index].at
                machine.cpu.registers[0] = loaded[index].size
            }
        case .loadFile:
            // The file at `dtg_PathArrayPtr` loaded at `chippoint` and listed; D0 nought if it was.
            let name = Array(string(at: machine.peek32(Self.globals + Self.dtgPathArrayPtr), most: 256).utf8)
            if let file = file(named: name), machine.load(files[file].bytes, at: memoryPoint) {
                loaded.append((memoryPoint, UInt32(files[file].bytes.count)))
                memoryPoint = ((memoryPoint + UInt32(files[file].bytes.count)) & ~0xF) + 16
                machine.cpu.registers[0] = 0
            } else {
                machine.cpu.registers[0] = 0xFF
            }
        case .copyDir, .copyFile:
            let path = machine.peek32(Self.globals + Self.dtgPathArrayPtr)
            var end = path
            while machine.peek8(end) != 0, end < path + 255 { end += 1 }
            let from = call == .copyDir ? Self.dirArray : Self.fileArray
            copyString(from: from, to: end, most: call == .copyDir ? 255 : 128)
        case .copyString:
            let path = machine.peek32(Self.globals + Self.dtgPathArrayPtr)
            var end = path
            while machine.peek8(end) != 0, end < path + 255 { end += 1 }
            copyString(from: machine.cpu.registers[8], to: end, most: 128)
        case .songEnd:
            songEnds += 1
        case .setTimer:
            // score's `enpp_set_timer`: `dtg_Timer` to the latch of the timer the host plays the player by.
            let value = machine.peek16(Self.globals + Self.dtgTimer)
            machine.chips.write8(0xBFE601, UInt8(value & 0xFF), at: cycles)
            machine.chips.write8(0xBFE701, UInt8(value >> 8), at: cycles)
        case .moduleChange:
            moduleChange()
        case .defaultStartInt, .defaultStopInt:
            break
        }
        return true
    }

    /// score's `dos_loadseg`: the file named loaded at `chippoint` (or, named by nothing, the module as it
    /// is), relocated past it as score's relocator does, and the address of its first hunk; nil if it
    /// cannot be.
    mutating func loadSegment(_ name: [UInt8]) -> UInt32? {
        let bytes: [UInt8]
        if name.isEmpty {
            bytes = module
        } else {
            guard let file = file(named: name) else { return nil }
            bytes = files[file].bytes
            let at = memoryPoint
            guard Int(at) + bytes.count + Self.room <= machine.memorySize, machine.load(bytes, at: at) else { return nil }
            memoryPoint = ((at + UInt32(bytes.count)) & ~0xF) + 16
        }
        do {
            let hunks = try AmigaHunks.load(bytes, at: memoryPoint, into: machine.memory,
                                            capacity: machine.memorySize - Self.room, placement: .uade)
            memoryPoint = hunks.last.map { $0.address + UInt32($0.size) } ?? memoryPoint
            return hunks.first?.address
        } catch {
            return nil
        }
    }

    /// The module's own name, as the player is told it.
    var moduleFileName: [UInt8] { moduleName }

    private func file(named name: [UInt8]) -> Int? {
        func last(_ path: [UInt8]) -> ArraySlice<UInt8> {
            path.lastIndex(where: { $0 == 0x2F || $0 == 0x3A }).map { path[($0 + 1)...] } ?? path[...]
        }
        let wanted = last(name).map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        return files.indices.first { i in last(files[i].name).map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 } == wanted }
    }

    /// score's `strlcpy`.
    private func copyString(from: UInt32, to: UInt32, most: Int) {
        for i in 0 ..< most {
            let byte = machine.peek8(from + UInt32(i))
            machine.poke8(to + UInt32(i), byte)
            if byte == 0 { break }
        }
    }

    /// score's `add_ciaa_interrupt`: the code and data put in its table for the timer, its handler in the
    /// vector of level 2, and the timer set going from `dtg_Timer`, continuously, its interrupt let through.
    private mutating func addCIAAInterrupt(timer: Int, code: UInt32, data: UInt32) {
        addCIAInterrupt(b: false, timer: timer, code: code, data: data)
    }

    /// score's `add_ciab_interrupt`, the same for CIA-B, its handler in the vector of level 6.
    private mutating func addCIABInterrupt(timer: Int, code: UInt32, data: UInt32) {
        addCIAInterrupt(b: true, timer: timer, code: code, data: data)
    }

    private mutating func addCIAInterrupt(b: Bool, timer: Int, code: UInt32, data: UInt32) {
        let cycles = machine.cpu.cycles
        let slot = UInt32(timer & 1) * 4
        machine.poke32((b ? Self.ciabDatas : Self.ciaaDatas) + slot, data)
        machine.poke32((b ? Self.ciabInts : Self.ciaaInts) + slot, code)
        machine.poke32(b ? 0x78 : 0x68, b ? entries.ciabInterrupt : entries.ciaaInterrupt)
        let value = machine.peek16(Self.globals + Self.dtgTimer)
        let base: UInt32 = b ? 0xBFD000 : 0xBFE001
        let latch = base + (timer & 1 == 0 ? 0x400 : 0x600)
        machine.chips.write8(latch, UInt8(value & 0xFF), at: cycles)
        machine.chips.write8(latch + 0x100, UInt8(value >> 8), at: cycles)
        machine.chips.write8(base + 0xD00, timer & 1 == 0 ? 0x81 : 0x82, at: cycles)
        machine.chips.write8(base + (timer & 1 == 0 ? 0xE00 : 0xF00), 0x11, at: cycles)
        machine.chips.write16(AmigaChips.custom + 0x9A, b ? 0xA000 : 0x8008, at: cycles)
    }

    /// score's `epg_modulechange`, EaglePlayer's patching of a player's code: for each entry of the table
    /// at EPG_ARG3 (a pattern's offset in the table, its length in words less one, and its patch's offset),
    /// each place from EPG_ARG1 for EPG_ARG2 bytes that holds the pattern made NOPs, its first a JSR to
    /// the patch. Only as score does it: in its search mode 1 (EPG_ARG4), EPG_ARG5 -2 and five arguments.
    mutating func moduleChange() {
        let g = Self.globals
        guard machine.peek32(g + Self.epgArg4) == 1, machine.peek32(g + Self.epgArg5) == 0xFFFF_FFFE, machine.peek32(g + Self.epgArgN) == 5 else {
            return
        }
        let table = machine.peek32(g + Self.epgArg3)
        var entry = table
        var entries = 0
        while entries < 256 {
            let patternOffset = machine.peek16(entry)
            if patternOffset == 0 { break }
            let words = Int(machine.peek16(entry + 2))
            let patchOffset = machine.peek16(entry + 4)
            entry += 6
            entries += 1
            var at = machine.peek32(g + Self.epgArg1)
            var left = Int64(Int32(bitPattern: machine.peek32(g + Self.epgArg2)))
            // (Each offset is added to the table's address as score adds it, ADDA.W, which takes it as
            // signed.)
            let pattern = table &+ UInt32(bitPattern: Int32(Int16(bitPattern: patternOffset)))
            while left > 0, Int(at) + 2 * (words + 1) <= machine.memorySize {
                var same = true
                for i in 0 ... words where machine.peek16(pattern + UInt32(i * 2)) != machine.peek16(at + UInt32(i * 2)) {
                    same = false
                    break
                }
                if same {
                    for i in 0 ... words { machine.poke16(at + UInt32(i * 2), 0x4E71) }
                    machine.poke16(at, 0x4EB9)
                    machine.poke32(at + 2, table &+ UInt32(bitPattern: Int32(Int16(bitPattern: patchOffset))))
                    left -= Int64(words * 2)
                    at += UInt32(words * 2)
                }
                at += 2
                left -= 2
            }
        }
    }

    /// The names of the routines of exec.library a player might call that score does not give.
    private static func execName(_ offset: Int) -> String? {
        switch -offset {
        case 282: "AddTask"
        case 288: "RemTask"
        case 318: "Wait"
        case 306: "SetSignal"
        case 366: "PutMsg"
        case 378: "ReplyMsg"
        case 384: "WaitPort"
        case 354: "AddPort"
        case 174: "RemIntServer"
        case 450: "CloseDevice"
        case 468: "CheckIO"
        case 624: "CopyMem"
        case 666: "CreateMsgPort"
        case 654: "CreateIORequest"
        default: nil
        }
    }

    // MARK: The host's own code

    /// score's code that is kept as 68000 code: its interrupts' handlers, its main loop's wait for the
    /// next frame, and a few short routines. Each with the instruction it is.
    private static func assemble(_ e: inout Entries) -> [UInt8] {
        var a = AmigaAssembly(at: codeAt)
        // The traps to the host, in the order of `Call`.
        for _ in Call.allCases { a.w(0x4E4F, 0x4E75) } // TRAP #15; RTS
        e.okay = a.here
        a.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        e.rts = a.here
        a.w(0x4E75) // RTS
        e.rtsNonZero = a.here
        a.w(0x70FF, 0x4E75) // MOVEQ #-1,D0; RTS
        e.testD0 = a.here
        a.w(0x4A80, 0x4E75) // TST.L D0; RTS (ENPP_AllocAudio)
        e.findTask = a.here
        a.w(0x203C, 0xDEAD, 0xFACE, 0x4E75) // MOVE.L #$DEADFACE,D0; RTS
        // exec's Supervisor: the routine in A5 run by TRAP #0, which it ends with RTE.
        e.supervisor = a.here
        a.w(0x21CD, 0x0080) // MOVE.L A5,$80.W
        a.w(0x4E40, 0x4E75) // TRAP #0; RTS
        // SuperState: TRAP #0 to `superstate_kick`, which comes back in supervisor mode on the user's stack,
        // the supervisor's in D0.
        e.superState = a.here
        let kick = a.label()
        a.w(0x21FC)
        a.address(of: kick)
        a.w(0x0080) // MOVE.L #kick,$80.W
        a.w(0x4E40, 0x4AFC) // TRAP #0; ILLEGAL
        a.place(kick)
        a.w(0x200F, 0x4E6F, 0x4E75) // MOVE.L A7,D0; MOVE.L USP,A7; RTS
        // UserState.
        e.userState = a.here
        a.w(0x4E67, 0x2E40, 0x46FC, 0x0000, 0x4E75) // MOVE.L A7,USP; MOVEA.L D0,A7; MOVE.W #0,SR; RTS
        // Cause: a software interrupt's code called at once, through TRAP #3, as score's `exec_cause` does.
        e.cause = a.here
        let causeDone = a.label(), trapCall = a.label()
        a.w(0x48E7, 0xFFFE) // MOVEM.L D0-D7/A0-A6,-(A7)
        a.w(0x0C29, 0x000B, 0x0008) // CMPI.B #NT_SOFTINT,LN_TYPE(A1)
        a.branch(0x6700, to: causeDone) // BEQ.S done
        a.w(0x137C, 0x000B, 0x0008) // MOVE.B #NT_SOFTINT,LN_TYPE(A1)
        a.w(0x2029, 0x0012) // MOVE.L IS_CODE(A1),D0
        a.branch(0x6700, to: causeDone) // BEQ.S done
        a.w(0x2669, 0x000E) // MOVEA.L IS_DATA(A1),A3
        a.w(0x2A40) // MOVEA.L D0,A5
        a.w(0x303C, 0x2100) // MOVE.W #$2100,D0
        a.w(0x49F9)
        a.address(of: trapCall) // LEA trapcall,A4
        a.w(0x21CC, 0x008C) // MOVE.L A4,$8C.W
        a.w(0x4E43) // TRAP #3
        a.place(causeDone)
        a.w(0x4CDF, 0x7FFF, 0x4E75) // MOVEM.L (A7)+,D0-D7/A0-A6; RTS
        a.place(trapCall)
        a.w(0x46C0) // MOVE.W D0,SR
        a.w(0x137C, 0x0002, 0x0008) // MOVE.B #NT_INTERRUPT,LN_TYPE(A1)
        a.w(0x224B) // MOVEA.L A3,A1
        a.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        a.w(0x41F9, 0x00DF, 0xF000) // LEA $DFF000,A0
        a.w(0x4E95) // JSR (A5)
        a.w(0x46FC, 0x2000, 0x4E73) // MOVE.W #$2000,SR; RTE
        // `wait_audio_dma`: ten lines of the beam.
        e.waitAudioDMA = a.here
        let line = a.label(), same = a.label(), noWait = a.label()
        a.w(0x48E7, 0xC000) // MOVEM.L D0-D1,-(A7)
        a.w(0x700A) // MOVEQ #10,D0
        a.w(0x5340) // SUBQ.W #1,D0
        a.branch(0x6B00, to: noWait) // BMI.S nowait
        a.place(line)
        a.w(0x1239, 0x00DF, 0xF006) // MOVE.B $DFF006,D1
        a.place(same)
        a.w(0xB239, 0x00DF, 0xF006) // CMP.B $DFF006,D1
        a.branch(0x6700, to: same) // BEQ.S same
        a.w(0x51C8)
        a.displacement(to: line) // DBF D0,line
        a.place(noWait)
        a.w(0x4CDF, 0x0003, 0x4E75) // MOVEM.L (A7)+,D0-D1; RTS
        // `mylevel1`, `mylevel5`: the request cleared.
        e.level1 = a.here
        a.w(0x33FC, 0x0007, 0x00DF, 0xF09C, 0x4E73) // MOVE.W #7,$DFF09C; RTE
        e.level5 = a.here
        a.w(0x33FC, 0x1800, 0x00DF, 0xF09C, 0x4E73) // MOVE.W #$1800,$DFF09C; RTE
        // `mylevel2`, `mylevel6`: the request cleared and the CIA's read.
        e.level2 = a.here
        a.w(0x33FC, 0x0008, 0x00DF, 0xF09C) // MOVE.W #8,$DFF09C
        a.w(0x2F00, 0x1039, 0x00BF, 0xED01, 0x201F, 0x4E73) // MOVE.L D0,-(A7); MOVE.B $BFED01,D0; MOVE.L (A7)+,D0; RTE
        e.level6 = a.here
        a.w(0x33FC, 0x2000, 0x00DF, 0xF09C) // MOVE.W #$2000,$DFF09C
        a.w(0x2F00, 0x1039, 0x00BF, 0xDD00, 0x201F, 0x4E73) // MOVE.L D0,-(A7); MOVE.B $BFDD00,D0; MOVE.L (A7)+,D0; RTE
        // `mylevel3`: the frame counted and each server in score's list called, A1 its data, A5 its code.
        e.level3 = a.here
        let notFrame = a.label(), servers = a.label(), serversDone = a.label()
        a.w(0x0839, 0x0005, 0x00DF, 0xF01F) // BTST #5,$DFF01F
        a.branch(0x6700, to: notFrame) // BEQ.S notvbi
        a.w(0x48E7, 0x8084) // MOVEM.L D0/A0/A5,-(A7)
        a.w(0x41F9)
        a.long(frameCount) // LEA framecount,A0
        a.w(0x5290) // ADDQ.L #1,(A0)
        a.w(0x41F9)
        a.long(vblankServers) // LEA lev3serverlist,A0
        a.place(servers)
        a.w(0x2010) // MOVE.L (A0),D0
        a.branch(0x6700, to: serversDone) // BEQ.S end
        a.w(0x48E7, 0xFFFE) // MOVEM.L D0-D7/A0-A6,-(A7)
        a.w(0x2268, 0x0004) // MOVEA.L 4(A0),A1
        a.w(0x2A40) // MOVEA.L D0,A5
        a.w(0x4E95) // JSR (A5)
        a.w(0x4CDF, 0x7FFF) // MOVEM.L (A7)+,D0-D7/A0-A6
        a.w(0x5088) // ADDQ.L #8,A0
        a.branch(0x6000, to: servers) // BRA.S loop
        a.place(serversDone)
        a.w(0x4CDF, 0x2101) // MOVEM.L (A7)+,D0/A0/A5
        a.place(notFrame)
        a.w(0x33FC, 0x0070, 0x00DF, 0xF09C, 0x4E73) // MOVE.W #$70,$DFF09C; RTE
        // `mylevel4`: Paula's interrupts, each asked for and let through called in the order 1, 3, 0, 2,
        // one at a time: A5 its code, A1 its data, A0 $DFF000, D1 the requests let through, A6 exec.
        e.level4 = a.here
        let enabled = a.label(), begin = a.label(), loop = a.label(), endLoop = a.label()
        let noHandler = a.label(), order = a.label()
        a.w(0x48E7, 0xFFFE) // MOVEM.L D0-D7/A0-A6,-(A7)
        a.w(0x45F9, 0x00DF, 0xF000) // LEA $DFF000,A2
        a.w(0x342A, 0x001C) // MOVE.W INTENAR(A2),D2
        a.w(0x0802, 0x000E) // BTST #14,D2
        a.branch(0x6600, to: enabled) // BNE.S enabled
        a.w(0x4CDF, 0x7FFF, 0x4E73) // MOVEM.L (A7)+,D0-D7/A0-A6; RTE
        a.place(enabled)
        a.w(0x47F9)
        a.long(irqLines) // LEA irqlines,A3
        a.w(0x49F9)
        a.long(isData) // LEA isdatapointers,A4
        a.place(begin)
        a.w(0x7400) // MOVEQ #0,D2
        a.w(0x342A, 0x001C) // MOVE.W INTENAR(A2),D2
        a.w(0xC46A, 0x001E) // AND.W INTREQR(A2),D2
        a.w(0x7E00) // MOVEQ #0,D7
        a.place(loop)
        let orderAt = a.words.count
        a.w(0x3C3B, 0x7000) // MOVE.W order(PC,D7.W),D6 (its displacement filled in below)
        a.branch(0x6B00, to: endLoop) // BMI.S endloop
        a.w(0x5447) // ADDQ.W #2,D7
        a.w(0x0D02) // BTST D6,D2
        a.branch(0x6700, to: loop) // BEQ.S loop
        a.w(0x2206) // MOVE.L D6,D1
        a.w(0xE549) // LSL.W #2,D1
        a.w(0x2033, 0x1000) // MOVE.L 0(A3,D1.W),D0
        a.branch(0x6700, to: noHandler) // BEQ.S nohandler
        a.w(0x2A40) // MOVEA.L D0,A5
        a.w(0x2274, 0x1000) // MOVEA.L 0(A4,D1.W),A1
        a.w(0x204A) // MOVEA.L A2,A0
        a.w(0x2202) // MOVE.L D2,D1
        a.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        a.w(0x4E95) // JSR (A5)
        a.place(endLoop)
        a.w(0x302A, 0x001C) // MOVE.W INTENAR(A2),D0
        a.w(0xC06A, 0x001E) // AND.W INTREQR(A2),D0
        a.w(0x0240, 0x0780) // ANDI.W #$780,D0
        a.branch(0x6600, to: begin) // BNE.S begin
        a.w(0x4CDF, 0x7FFF, 0x4E73) // MOVEM.L (A7)+,D0-D7/A0-A6; RTE
        a.place(noHandler)
        a.w(0x7000, 0x0DC0) // MOVEQ #0,D0; BSET D6,D0
        a.w(0x3540, 0x009C) // MOVE.W D0,INTREQ(A2)
        a.branch(0x6000, to: endLoop) // BRA.S endloop
        a.place(order)
        a.w(0x0008, 0x000A, 0x0007, 0x0009, 0xFFFF)
        // (MOVE.W d8(PC,D7.W): the displacement is from the extension word.)
        let orderDisplacement = Int(a.addressOf(order)) - Int(codeAt) - (orderAt * 2 + 2)
        var words = a.words
        words[orderAt + 1] = 0x7000 | UInt16(UInt8(truncatingIfNeeded: orderDisplacement))
        // `ciaa_interrupt`, `ciab_interrupt`: the request cleared, the CIA's read, and the code set for
        // each of its timers that ran out called, A1 its data, A6 exec, D0 what was read.
        func cia(_ a: inout AmigaAssembly, request: UInt16, icr: UInt32, ints: UInt32, datas: UInt32) {
            let notA = a.label(), notB = a.label()
            a.w(0x48E7, 0xFFFE) // MOVEM.L D0-D7/A0-A6,-(A7)
            a.w(0x33FC, request, 0x00DF, 0xF09C) // MOVE.W #request,$DFF09C
            a.w(0x1039)
            a.long(icr) // MOVE.B icr,D0
            a.w(0x0240, 0x0003) // ANDI.W #3,D0
            for (bit, label) in [(UInt16(0), notA), (1, notB)] {
                a.w(0x0800, bit) // BTST #bit,D0
                a.branch(0x6700, to: label) // BEQ.S not
                a.w(0x2079)
                a.long(ints + UInt32(bit) * 4) // MOVEA.L ints,A0
                a.w(0x2279)
                a.long(datas + UInt32(bit) * 4) // MOVEA.L datas,A1
                a.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
                a.w(0x2F00, 0x4E90, 0x201F) // MOVE.L D0,-(A7); JSR (A0); MOVE.L (A7)+,D0
                a.place(label)
            }
            a.w(0x4CDF, 0x7FFF, 0x4E73) // MOVEM.L (A7)+,D0-D7/A0-A6; RTE
        }
        e.ciaaInterrupt = a.here
        cia(&a, request: 0x0008, icr: 0xBFED01, ints: ciaaInts, datas: ciaaDatas)
        e.ciabInterrupt = a.here
        cia(&a, request: 0x2000, icr: 0xBFDD00, ints: ciabInts, datas: ciabDatas)
        // score's `playloop`, as far as it is heard: TRAP #4 to `waittrapvector`, which waits in STOP for
        // the frame counted to change; and round again.
        e.waitFrame = a.here
        let stop = a.label()
        a.w(0x41F9)
        a.long(frameCount) // LEA framecount,A0
        a.w(0x2010) // MOVE.L (A0),D0
        a.place(stop)
        a.w(0x4E72, 0x2000) // STOP #$2000
        a.w(0x2210, 0xB280) // MOVE.L (A0),D1; CMP.L D0,D1
        a.branch(0x6700, to: stop) // BEQ.S newstop
        a.w(0x4E73) // RTE
        // Then, each frame, `HandleTimerDevice`: the host gives the routine to call in A0, if any.
        e.idle = a.here
        let idle = a.placed(), none = a.label()
        a.w(0x21FC)
        a.long(e.waitFrame)
        a.w(0x0090) // MOVE.L #waittrapvector,$90.W
        a.w(0x4E44) // TRAP #4
        a.w(0x48E7, 0xFFFE) // MOVEM.L D0-D7/A0-A6,-(A7)
        a.w(0x4EB9)
        a.long(stub(.frame)) // JSR frame
        a.w(0x2008) // MOVE.L A0,D0
        a.branch(0x6700, to: none) // BEQ.S none
        a.w(0x4E90) // JSR (A0)
        a.place(none)
        a.w(0x4CDF, 0x7FFF) // MOVEM.L (A7)+,D0-D7/A0-A6
        a.branch(0x6000, to: idle) // BRA.S idle
        // (The order's displacement, put back.)
        var bytes = a.assembled()
        bytes[(orderAt + 1) * 2] = UInt8(words[orderAt + 1] >> 8)
        bytes[(orderAt + 1) * 2 + 1] = UInt8(words[orderAt + 1] & 0xFF)
        return bytes
    }
}
