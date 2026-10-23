// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayChips

/// A player on `DeliTrackerHost` heard a tick at a time, as `PaulaTickRenderer` hears a player: the
/// machine run as the Amiga runs from one of the player's ticks to the next (each the time its timer
/// next runs out, or a frame), and what it wrote to Paula told at the moment it wrote it. The ticks are
/// the player's own, so a player that sets its timer to another speed is heard by ticks of that length.
struct DeliTicks {
    private(set) var feed: AmigaPaulaFeed
    /// What the tick just run wrote, its cycles counted from `lead` clocks into the tick.
    private(set) var writes: [AmigaWrite] = []
    /// What the song's start wrote to Paula, heard as its first tick begins.
    private(set) var startWrites: [AmigaWrite] = []
    /// The tick being run: when it began and when it ends, in Paula's clocks since the machine was
    /// switched on; and the length of the last that ran.
    private var tickStart: UInt64 = 0
    private var tickEnd: UInt64 = 0
    private(set) var tickClocks = TFMXTiming.fiftyTimes
    /// How far into the tick its stretch of running began (the processor's last instruction before may
    /// have run past the tick's start).
    private(set) var lead = 0
    private var songEndsSeen = 0

    init(memorySize: Int) {
        feed = AmigaPaulaFeed(memorySize: memorySize)
    }

    /// As the player has just been started: what it wrote in starting is heard as the first tick
    /// begins, and the first tick lasts until its timer first runs out.
    mutating func begin(_ host: inout DeliTrackerHost) {
        feed.reset()
        songEndsSeen = 0
        _ = host.beginStretch()
        host.takeWrites(into: &startWrites)
        for i in startWrites.indices { startWrites[i].cycles = 0 }
        tickStart = host.now
        tickEnd = host.nextTick(after: tickStart)
    }

    /// Runs a tick, and tells `output` what was written in it. Returns whether the player went wrong
    /// (and has stopped), and how many times it said its song ended.
    mutating func run<Output: TFMXOutput>(_ host: inout DeliTrackerHost, _ output: inout Output) -> (failed: Bool, ends: Int) {
        feed.beginTick()
        if !startWrites.isEmpty {
            feed.tell(startWrites, &output)
            startWrites.removeAll(keepingCapacity: true)
        }
        let from = host.beginStretch()
        lead = Int(from &- tickStart)
        let outcome = host.run(until: tickEnd)
        host.takeWrites(into: &writes)
        feed.tell(writes, lead: lead, &output)
        let ends = host.songEnds - songEndsSeen
        songEndsSeen = host.songEnds
        tickClocks = Int(tickEnd - tickStart)
        tickStart = tickEnd
        tickEnd = host.nextTick(after: max(tickStart, host.now))
        return (outcome != .reached, ends)
    }

    /// A tick of a player that has stopped: nothing is run, and nothing more is heard.
    mutating func idle() {
        feed.beginTick()
        writes.removeAll(keepingCapacity: true)
    }
}

/// What a song played through in silence, to find its end, would let be heard: whether a voice is ever
/// playing at a volume above nought (see `DryRunSilences`).
struct DryRunEar: TFMXOutput {
    private var playing = [false, false, false, false]
    private var volumes = [UInt16](repeating: 0, count: 4)
    private(set) var heard = false

    mutating func on(_ voice: Int) {
        guard playing.indices.contains(voice) else { return }
        playing[voice] = true
        if volumes[voice] > 0 { heard = true }
    }

    mutating func off(_ voice: Int) {
        if playing.indices.contains(voice) { playing[voice] = false }
    }

    mutating func writeVolume(_ voice: Int, _ volume: UInt16) {
        guard volumes.indices.contains(voice) else { return }
        volumes[voice] = volume & 0x7F
        if playing[voice], volumes[voice] > 0 { heard = true }
    }

    mutating func takeNextBuffer(_: Int, start _: Int, length _: UInt16) {}
    func loopCount(_: Int) -> UInt16 { 0 }
}

/// The songs of a module that were played through to their ends and never heard (`DryRunEar`). One of
/// them has nothing to it (`SongInfo.empty`), and is of no length, if another song of the module is
/// heard: as the songs past the end of a module's own list of them have, and the effects in a list of a
/// game's that make no sound. A module of which no song is heard is left as it is found: what is
/// silent there is more likely the playing of it than the module.
struct DryRunSilences {
    private var silent: [Int] = []
    private var heardAny = false

    /// Notes what was found of a song played through, and puts in `lengths` the songs that are empty.
    mutating func found(_ song: Int, heard: Bool, in lengths: inout [UInt64??]) {
        if heard {
            heardAny = true
        } else {
            silent.append(song)
        }
        guard heardAny else { return }
        for song in silent where lengths.indices.contains(song) { lengths[song] = .some(0) }
        silent.removeAll()
    }
}
