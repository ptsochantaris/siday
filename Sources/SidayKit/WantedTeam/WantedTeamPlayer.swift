// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after UADE's playing of Wanted Team's EaglePlayers (amigasrc/players/wanted_team/), by its host
// `score` (amigasrc/score/score.s), as `DeliTrackerHost` runs it.

/// Music of one of the Amiga's composers whose own 68000 code is in each module, played as UADE plays it
/// with Wanted Team's EaglePlayer for it, whose work `Recipe` does (see `WantedTeamRecipe`): the machine
/// switched on, the recipe's code put in it, the module loaded, found and patched by the recipe's
/// `initPlayer`, the song set, the recipe's `volume` and `initSound`, and then its `interrupt` called
/// from CIA-A's timer B by the host, fifty times a second (unless the recipe sets another speed or its
/// own interrupts), and what the module writes to Paula heard at the moment it writes it (`DeliTicks`).
///
/// Its songs are the recipe's range of them, the first first. A song ends when the recipe's code calls
/// `dtg_SongEnd`, and its length is found by playing it through in silence, for as long as
/// `DeliCustomPlayer` gives a song.
struct WantedTeamPlayer<Recipe: WantedTeamRecipe>: ~Copyable {
    private var host: DeliTrackerHost
    private var ticks: DeliTicks
    private var recipe: Recipe
    private let code: [UInt8]
    private var first = 0
    private(set) var songCount = 1
    /// What the module says of itself.
    private(set) var title = ""
    private(set) var author = ""
    private(set) var detail = ""

    private(set) var song = 0
    private(set) var endings = 0
    private(set) var stops = 0
    private(set) var lengthClocks: UInt64?
    private var lengths: [UInt64??] = []
    private var dryRuns: Int64 = 0

    var memory: UnsafeMutablePointer<UInt8> { host.memory }
    var memoryCapacity: Int { host.memorySize }
    var silenceAt: Int { host.memorySize - DeliTrackerHost.room / 2 - 1024 }
    var mixingAt: Int { silenceAt }
    /// What the tick just run wrote (see `DeliTicks`), and the song's start.
    var writes: [AmigaWrite] { ticks.writes }
    var startWrites: [AmigaWrite] { ticks.startWrites }
    var tickClocks: Int { ticks.tickClocks }
    var lead: Int { ticks.lead }

    static func isOne(_ data: [UInt8]) -> Bool { Recipe.isOne(data) }

    /// - Parameter name: the module's file name, as the player is told it.
    init(_ data: [UInt8], song: Int = 0, name: String = "module") throws(TuneError) {
        var refusal: TuneError?
        let host: DeliTrackerHost
        do throws(TuneError) {
            guard Recipe.isOne(data) else { throw TuneError.malformed("not a module of \(Recipe.format)'s") }
            host = try DeliTrackerHost(moduleAt: Recipe.moduleAt, module: data, name: name)
        } catch {
            refusal = error
            host = try! DeliTrackerHost(moduleAt: Recipe.moduleAt, module: [])
        }
        self.host = host
        ticks = DeliTicks(memorySize: self.host.memorySize)
        var recipe = Recipe()
        var a = AmigaAssembly(at: DeliTrackerHost.clientCode)
        recipe.assemble(&a)
        code = a.assembled()
        self.recipe = recipe
        if refusal == nil, code.count > DeliTrackerHost.clientCodeSize {
            refusal = .unsupported("a player whose own code is larger than the host gives it")
        }
        if refusal == nil {
            do {
                let songs = try start(nil)
                first = songs.first
                songCount = max(1, min(256, songs.count))
                title = self.recipe.title
                author = self.recipe.author
                detail = self.recipe.detail
            } catch {
                refusal = error
            }
        }
        lengths = [UInt64??](repeating: nil, count: songCount)
        // (Refused only once it is all made.)
        if let refusal { throw refusal }
        try select(song: song >= 0 && song < songCount ? song : 0)
    }

    // MARK: Starting

    /// Starts a song afresh (from nought here; nil for the first the player gives), as UADE does: the
    /// machine switched on with the module in it, the player's code put in, and score's calls of the
    /// player in its order, up to its ticks set going.
    @discardableResult
    private mutating func start(_ song: Int?) throws(TuneError) -> WantedTeamSongs {
        try host.prepare()
        host.machine.load(code, at: DeliTrackerHost.clientCode)
        host.startInterrupts()
        let songs = try recipe.initPlayer(&host)
        host.setSong(songs.first + (song ?? 0))
        try recipe.volume(&host)
        try recipe.initSound(&host)
        if let interrupt = recipe.interrupt { host.playByTimer(interrupt) }
        host.idle()
        endings = 0
        stops = 0
        ticks.begin(&host)
        return songs
    }

    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        if lengths[song] == nil {
            // Played through in silence to its end: the tick it ends in is the first of it again, or the
            // first of the silence after it.
            try start(song)
            var none = Unheard()
            var used: Int64 = 0
            var clocks: UInt64 = 0
            while endings == 0, stops == 0, clocks < DeliCustomPlayer.mostClocks, used < DeliCustomPlayer.dryRunBudget,
                  dryRuns < DeliCustomPlayer.dryRunsBudget
            {
                let busy = host.busyCycles
                _ = run(&none)
                clocks += UInt64(ticks.tickClocks)
                used += host.busyCycles - busy
                dryRuns += host.busyCycles - busy
            }
            lengths[song] = .some(endings > 0 || stops > 0 ? clocks - UInt64(ticks.tickClocks) : nil)
        }
        lengthClocks = lengths[song] ?? nil
        try start(song)
    }

    /// Runs a tick: the machine run as the Amiga runs until the player's next tick is due, and what it
    /// wrote told `output` at the moments it wrote it. Returns the tick's length in milliseconds.
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        if stops > 0 {
            ticks.idle()
            return 20
        }
        let (failed, ends) = ticks.run(&host, &output)
        if failed { stops += 1 }
        endings += ends
        return ticks.tickClocks * 1000 / 3_546_895
    }

    /// Why the module stopped, if it has.
    var failure: String? { host.failure }

    private struct Unheard: TFMXOutput {
        mutating func on(_: Int) {}
        mutating func off(_: Int) {}
        mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
        func loopCount(_: Int) -> UInt16 { 0 }
    }
}

/// A module of a composer's own code, played on Paula by `PaulaTickRenderer`.
extension WantedTeamPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: Recipe.format)
        info.title = title
        info.author = author
        info.detail = detail
        return info
    }

    var gain: Float { Recipe.gain }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { ticks.tickClocks }

    /// What Paula's registers held as the tick began (see `AmigaPaulaFeed`).
    func period(_ voice: Int) -> UInt16 { ticks.feed.periods[voice] }
    func volume(_ voice: Int) -> UInt16 { ticks.feed.volumes[voice] }
    var lightFilter: Bool { ticks.feed.lightFilter }
}
