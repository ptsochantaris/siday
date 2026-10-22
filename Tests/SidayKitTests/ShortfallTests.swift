// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayFoundation
@testable import SidayTrackers
import Testing

// What a file asks for that is not played as it asks (`TuneInfo.shortfalls`): the wording that the
// loaders share. What each kind of file says is checked beside that kind's other tests.

@Test func shortfallCountsAreWrittenAsTheyAreSaid() {
    #expect(Shortfall.number(1) == "one" && Shortfall.number(12) == "twelve" && Shortfall.number(19) == "nineteen")
    #expect(Shortfall.number(20) == "twenty" && Shortfall.number(37) == "thirty-seven" && Shortfall.number(99) == "ninety-nine")
    // Past where words are easier to read than figures, figures.
    #expect(Shortfall.number(100) == "100" && Shortfall.number(312) == "312")
    #expect(Shortfall.some(1, one: "samples is silent.", many: "samples are silent.") == "One of its samples is silent.")
    #expect(Shortfall.some(3, one: "samples is silent.", many: "samples are silent.") == "Three of its samples are silent.")
    #expect(Shortfall.some(140, one: "samples is silent.", many: "samples are silent.") == "140 of its samples are silent.")
    #expect(Shortfall.list([]) == "" && Shortfall.list(["a"]) == "a" && Shortfall.list(["a", "b"]) == "a and b" && Shortfall.list(["a", "b", "c"]) == "a, b and c")
}

@Test func shortfallNamesTheCommandsThatAreLeftOutOnceEach() {
    var kinds = Shortfall.Kinds()
    #expect(kinds.isEmpty && Shortfall.commandsLeftOut(kinds.named(["one thing", "another", "a third"])) == nil)
    kinds.note(2)
    kinds.note(0)
    kinds.note(2)
    #expect(kinds.named(["one thing", "another", "a third"]) == ["one thing", "a third"])
    #expect(Shortfall.commandsLeftOut(["sliding by semitones", "the retuning of a sample"]) == "Two of its commands are left out: sliding by semitones and the retuning of a sample.")
    #expect(Shortfall.commandsLeftOut(["a loop within a pattern"], why: "which MultiTracker did not have")
        == "One of its commands is left out, which MultiTracker did not have: a loop within a pattern.")
}

@Test func shortfallOfAFileCutShortCountsOnlyWhatCouldBeHeard() {
    // A sample that has lost a few bytes of its end has lost nothing anyone can hear.
    var few = Shortfall.CutShort()
    few.add(length: 20000, there: 19990)
    few.add(length: 2, there: 0)
    few.add(length: 40000, there: 39000)
    #expect(few.sentence == nil)
    // One that has lost a sixteenth of itself has, and so has one that has lost two thousand bytes.
    var last = Shortfall.CutShort()
    last.add(length: 8000, there: 9000)
    last.add(length: 8000, there: 7000)
    #expect(last.sentence == "The file is cut short: its last sample ends in silence.")
    last.add(length: 60000, there: 57000)
    #expect(last.sentence == "The file is cut short: two of its samples end in silence.")
    // And one the file ends before the beginning of is missing altogether.
    var gone = Shortfall.CutShort()
    gone.add(length: 64, there: 0)
    #expect(gone.sentence == "The file is cut short: one of its samples is missing, and is silent.")
    gone.add(length: 64, there: -500)
    #expect(gone.sentence == "The file is cut short: two of its samples are missing, and are silent.")
    gone.add(length: 6400, there: 100)
    #expect(gone.sentence == "The file is cut short: two of its samples are missing, and another ends in silence.")
    gone.add(length: 6400, there: 100)
    #expect(gone.sentence == "The file is cut short: two of its samples are missing, and two more end in silence.")
}

@Test func shortfallOfPlugInsSaysWhatIsLostWithEach() {
    #expect(Shortfall.plugIns(unheard: 0, bare: 0, channels: 0).isEmpty)
    #expect(Shortfall.plugIns(unheard: 3, bare: 1, channels: 2) == [
        "Three of its instruments play through plug-ins, and are not heard.",
        "One of its instruments is sent through a plug-in, and is heard without it.",
        "Two of its channels are sent through plug-ins, and are heard without them.",
    ])
}

@Test func plugInsOfModPlugTrackerAreFoundWhereItWritesThem() {
    func piece(_ name: String, _ body: [UInt8]) -> [UInt8] {
        Array(name.utf8) + [UInt8(body.count & 0xFF), UInt8(body.count >> 8), 0, 0] + body
    }
    // The song's text, which is passed over; a plug-in in the second place, and a place with none
    // in it; the plug-in each of three channels is sent through; and what is said of two instruments.
    var file: [UInt8] = [9, 9, 9] + piece("text", Array("hello".utf8))
    file += piece("FX01", [1, 2, 3, 4] + [UInt8](repeating: 0, count: 124)) + piece("FX02", [UInt8](repeating: 0, count: 128))
    file += piece("CHFX", [0, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0])
    let pieces = file.count
    file += Array("XTPM".utf8) + Array("...V".utf8) + [2, 0, 7, 7, 8, 8] + Array(".PiM".utf8) + [1, 0, 2, 3] + Array("STPM".utf8)
    var extras = ModPlugExtras()
    #expect(extras.readPieces(ByteReader(file), at: 3, before: file.count) == pieces)
    extras.readInstrumentExtras(ByteReader(file), from: 0, instruments: 2)
    #expect(extras.hasPlugIn[2] && !extras.hasPlugIn[1] && !extras.hasPlugIn[3])
    #expect(extras.channelPlugIns == [0, 2, 3] && extras.channelsThroughPlugIns == 1)
    #expect(extras.instrumentPlugIns == [2, 3])
    #expect(extras.playsThroughPlugIn(instrument: 0) && !extras.playsThroughPlugIn(instrument: 1) && !extras.playsThroughPlugIn(instrument: 9))
    // A file with none of it says nothing, and one that ends in the middle of it does not trap.
    var none = ModPlugExtras()
    #expect(none.readPieces(ByteReader([1, 2, 3]), at: 0, before: 3) == 0)
    for length in 0 ..< file.count {
        var cut = ModPlugExtras()
        let part = Array(file[..<length])
        cut.readInstrumentExtras(ByteReader(part), from: cut.readPieces(ByteReader(part), at: 3, before: part.count), instruments: 2)
    }
}
