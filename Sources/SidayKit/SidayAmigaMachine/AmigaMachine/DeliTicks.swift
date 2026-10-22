// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

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
