// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Fast checks of Paul Shields' player, on tiny files made here as the games' are, in each of the three layouts. The
// thorough check is made outside the package: what it tells Paula, tick by tick, against what Wanted Team's player
// tells her in UADE, for UnExoticA's 14 files.

/// What Paula is told, as a list (the moments in the tick, and the periods and volumes, left out).
private struct Recorder: TFMXOutput {
    var events: [String] = []
    mutating func on(_ voice: Int) { events.append("on \(voice)") }
    mutating func off(_ voice: Int) { events.append("off \(voice)") }
    mutating func takeNextBuffer(_ voice: Int, start: Int, length: UInt16) { events.append("buffer \(voice) \(start) \(length)") }
    func loopCount(_: Int) -> UInt16 { 0 }
}

private func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

/// A file of the layout's: instrument 1 a sample of eight words at volume 40 (none in the second layout), its loop
/// of four from its third, three octaves up. The fourth voice plays note 12 and note 24, two ticks each, of
/// instrument 1, and goes round; the second (Amnios': the first) rests for four ticks and goes round; the others
/// stop at once. If `stopping`, the two stop instead of going round.
private func file(_ layout: PaulShieldsPlayer.Layout, stopping: Bool = false) -> (bytes: [UInt8], samples: Int) {
    let amnios = layout == .amnios
    let size = layout == .second ? 10 : 32
    var bytes = [UInt8](repeating: 0, count: 16 * size)
    let entry = size + (layout == .second ? 2 : 22)
    bytes[entry ..< entry + 2] = word(8)[...]
    if layout == .second {
        bytes[entry + 2 ..< entry + 8] = (word(4) + word(4) + word(288))[...]
    } else {
        bytes[entry + 2 ..< entry + 10] = (word(40) + word(4) + word(4) + word(288))[...]
    }
    let header = bytes.count
    let headerSize = amnios ? 18 : 20
    let stop = amnios ? 0xFFE8 : 0xFFF4
    let loop = amnios ? 0xFFEC : 0xFFF0
    // (After the header, two envelopes that hold, the tables, the patterns and the lists.)
    let envelopes = header + headerSize
    var after = [UInt8]()
    after += [1, 0x80, 1, 0x80]
    let tables = envelopes + after.count
    if amnios {
        after += word(16) + word(envelopes) + word(envelopes + 2)
    } else {
        after += word(envelopes) + word(envelopes + 2) + word(envelopes)
    }
    let notes = envelopes + after.count
    after += amnios ? [0x8C, 0, 12, 2, 24, 2, 0x90] : [4, 1, 0, 12, 2, 0, 24, 2, 12]
    let rest = envelopes + after.count
    after += amnios ? [0x80, 4, 0x90] : [16, 4, 12]
    if after.count & 1 != 0 { after.append(0) }
    // (Amnios' check wants its first voice's list after a list's end; and the samples begin after the list that is
    // furthest in, at the next word like the one before it.)
    let lists = envelopes + after.count
    var places = [Int](repeating: 0, count: 4)
    places[0] = lists
    places[2] = lists + 2
    after += word(stop) + word(stop)
    places[3] = envelopes + after.count
    after += word(notes) + word(stopping ? stop : loop)
    places[amnios ? 0 : 1] = envelopes + after.count
    after += word(rest) + word(stopping ? stop : loop)
    if amnios { places[1] = lists }
    var head: [UInt8] = amnios ? word(tables) : word(tables) + word(tables + 4)
    // (The header's first voice is the fourth.)
    for v in [3, 2, 1, 0] { head += word(0x40) + word(places[v]) }
    bytes += head + after
    let samples = bytes.count
    bytes += (0 ..< 16).map { UInt8($0 * 9 + 2) }
    return (bytes, samples)
}

@Test func paulShieldsDetection() throws {
    for layout in [PaulShieldsPlayer.Layout.first, .second, .amnios] {
        let (made, samples) = file(layout)
        #expect(PaulShieldsPlayer.layout(of: made) == layout)
        #expect(PaulShieldsPlayer.isOne(made))
        let player = try PaulShieldsPlayer(made)
        #expect(player.samplesAt == samples && player.sampleCount == 1 && player.songCount == 1)
        // (A file without all its samples is refused.)
        let cut = Array(made.dropLast(2))
        #expect(!PaulShieldsPlayer.isOne(cut))
        #expect(throws: TuneError.self) { try PaulShieldsPlayer(cut) }
    }
    var other = file(.first).bytes
    other[0] = 1
    #expect(!PaulShieldsPlayer.isOne(other))
    // (PostScript, whose files end .ps too.)
    let postScript = Array("%!PS-Adobe-3.0\n%%Creator: test\n".utf8) + [UInt8](repeating: 0x20, count: 600)
    #expect(!PaulShieldsPlayer.isOne(postScript))
    #expect(throws: TuneError.self) { try PaulShieldsPlayer(postScript) }
}

/// A note is begun on its tick: its voice turned off and told its sample; turned on in the next tick and, after the
/// wait, told its loop. Its period is from the table, three octaves and the note up; its volume the instrument's.
@Test func paulShieldsNotesReachPaula() throws {
    for layout in [PaulShieldsPlayer.Layout.first, .second, .amnios] {
        let (made, samples) = file(layout)
        var player = try PaulShieldsPlayer(made)
        var events: [[String]] = []
        var periods: [UInt16] = []
        var volumes: [UInt16] = []
        for _ in 0 ..< 4 {
            var recorder = Recorder()
            _ = player.run(&recorder)
            events.append(recorder.events)
            periods.append(player.periodWritten(3))
            volumes.append(player.volumeWritten(3))
        }
        let note = ["off 3", "buffer 3 \(samples) 8"]
        let on = ["on 3", "buffer 3 \(samples + 4) 4"]
        #expect(events == [note, on, note, on])
        // (Note 12 is four octaves of eighths of a semitone up from the table's first, note 24 five.)
        #expect(periods == [0x6AE, 0x6AE, 0x357, 0x357])
        // (The second layout's instruments have no volume: its voice's is the header's, less 64.)
        #expect(volumes == (layout == .second ? [0, 0, 0, 0] : [40, 40, 40, 40]))
        #expect(player.lightFilter == (layout == .amnios))
    }
}

/// The song comes to its end as its second voice's list (Amnios', its first's) goes round, after four ticks here;
/// one whose voices all stop, stops.
@Test func paulShieldsSongEnds() throws {
    for layout in [PaulShieldsPlayer.Layout.first, .second, .amnios] {
        var player = try PaulShieldsPlayer(file(layout).bytes)
        #expect(player.lengthClocks == UInt64(4 * TFMXTiming.fiftyTimes))
        var none = TFMXSilentOutput()
        for _ in 0 ..< 4 { _ = player.run(&none) }
        #expect(player.endings == 0)
        _ = player.run(&none)
        #expect(player.endings == 1 && player.stops == 0)

        var stopping = try PaulShieldsPlayer(file(layout, stopping: true).bytes)
        #expect(stopping.lengthClocks == UInt64(4 * TFMXTiming.fiftyTimes))
        for _ in 0 ..< 4 { _ = stopping.run(&none) }
        #expect(stopping.stops == 0)
        _ = stopping.run(&none)
        #expect(stopping.stops == 1 && stopping.endings == 1)
        // (And it says nothing more.)
        var recorder = Recorder()
        _ = stopping.run(&recorder)
        #expect(recorder.events.isEmpty)
    }
}
