// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from HivelyTracker, Copyright (c) Pete Gordon, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

import SidayFoundation

/// A HivelyTracker file, read into the shape the tracker keeps one in.
///
/// HivelyTracker is AHX carried on: the same instruments made of a few numbers and a list of things
/// to do as a note goes on, the same tracks and list of positions, but with as many as sixteen
/// voices in place of the Amiga's four, each with a place of its own between the speakers; with two
/// commands on a row where AHX has one; and with more for an instrument's list to do. A file says
/// how loud it is to be mixed and how far apart its voices start.
final class HVLModule {
    /// The most rows a track has, and the room each track is given.
    static let rows = 64
    static let mostChannels = 16
    /// What the tracker will not load more of.
    static let mostPositions = 1000, mostInstruments = 64

    /// A row of a track: a note from 1 to 60, an instrument, and two commands each with its number.
    struct Step {
        var note: UInt8 = 0, instrument: UInt8 = 0
        var command: UInt8 = 0, parameter: UInt8 = 0
        var secondCommand: UInt8 = 0, secondParameter: UInt8 = 0
    }

    struct Instrument {
        var volume: UInt8 = 0
        /// Which of the six lengths of wave: 4 bytes, doubling to 128.
        var waveLength: UInt8 = 0
        var filterLowerLimit: UInt8 = 0, filterUpperLimit: UInt8 = 0, filterSpeed: UInt8 = 0
        var squareLowerLimit: UInt8 = 0, squareUpperLimit: UInt8 = 0, squareSpeed: UInt8 = 0
        var vibratoDelay: UInt8 = 0, vibratoSpeed: UInt8 = 0, vibratoDepth: UInt8 = 0
        var hardCutRelease = false
        var hardCutReleaseFrames: UInt8 = 0
        // The envelope: how many ticks each of its parts lasts, and the level it comes to.
        var attackFrames: Int16 = 0, attackVolume: Int16 = 0
        var decayFrames: Int16 = 0, decayVolume: Int16 = 0
        var sustainFrames: Int16 = 0
        var releaseFrames: Int16 = 0, releaseVolume: Int16 = 0
        /// The list of things to do as a note goes on: how many ticks each entry lasts, how many
        /// entries there are, and where the first of them is among the module's.
        var listSpeed: Int16 = 0, listLength: Int16 = 0
        var list = 0
    }

    /// An entry of an instrument's list: a wave to change to (1 to 4, and 0 for none), a note of
    /// the instrument's own, which is added to the track's or stands in place of it, and two
    /// commands each with its number.
    struct ListEntry {
        var note: UInt8 = 0, wave: UInt8 = 0
        var fixed = false
        var command: UInt8 = 0, parameter: UInt8 = 0
        var secondCommand: UInt8 = 0, secondParameter: UInt8 = 0
    }

    /// The loudness an AHX file is mixed at, which has none of its own, by how far apart its voices
    /// are set: the closer together, the more of them fall on each side.
    private static let ahxGains: [Int32] = [71, 72, 76, 85, 100]

    let title: String
    /// 0 for a file from before HivelyTracker 1.5, and 1 for one that may use what came with it.
    let version: UInt8
    /// True if this is an AHX file, taken as HivelyTracker takes one.
    let isAHX: Bool
    let channels: Int
    let positionCount: UInt16
    /// The position the song goes on from when it runs off the end of the list.
    let restart: UInt16
    let trackLength: UInt8
    let highestTrack: UInt8
    /// How many instruments there are: as many as the file says, or, in one that is cut short,
    /// those before the first it has not all of.
    let instrumentCount: Int
    /// What the file asks for that is not played as it asks: for a file cut short, what it has lost
    /// (see `TuneInfo.shortfalls`).
    let shortfalls: [String]
    /// Where each of the file's other songs starts in the list of positions.
    let subsongStarts: [UInt16]
    /// How many times in a fiftieth of a second the player is run: from one to four.
    let speedMultiplier: Int
    /// How loud the file is to be mixed, in 256ths.
    let mixGain: Int32
    /// How far apart the voices start, from 0, all in the middle, to 4, hard to either side.
    let stereo: Int

    /// For each position, the track of each of sixteen voices and then how far each is moved.
    private let positions: UnsafeMutablePointer<UInt8>
    /// Every track there can be, 64 rows each, and one row more: those the file does not have are empty.
    private let tracks: UnsafeMutablePointer<Step>
    /// The instruments by number. The one numbered nought is never played.
    let instruments: [Instrument]
    let entries: [ListEntry]

    /// What gives `positions` and `tracks` back, also for a file that turns out not to be a module.
    private let positionMemory: Memory<UInt8>, trackMemory: Memory<Step>

    /// How many samples a tick lasts. The tracker counts time in samples and not by the Amiga's
    /// timer, so a tick is a whole number of them and there are fifty to the second exactly.
    var tickFrames: Int { outputSampleRate / 50 / speedMultiplier }

    /// The track a voice plays at a position.
    @inline(__always) func track(_ position: Int, _ voice: Int) -> UInt8 {
        positions[(position << 5) + voice]
    }

    /// How far up or down a voice's track is moved at a position.
    @inline(__always) func transpose(_ position: Int, _ voice: Int) -> Int8 {
        Int8(bitPattern: positions[(position << 5) + Self.mostChannels + voice])
    }

    /// A row of a track. A break to a row can name the one after a track's last, which the tracker
    /// then plays: in a track of 64 rows that is the first row of the next track, and it is here too.
    @inline(__always) func step(_ track: Int, _ row: Int) -> Step {
        tracks[(track << 6) + min(row, Self.rows)]
    }

    /// - Parameter ahxStereo: for comparing with the tracker's replayer only, which plays AHX files
    ///   too: takes an AHX file as that replayer does, with its voices this far apart, from 0 to 4.
    init(_ data: [UInt8], ahxStereo: Int? = nil) throws {
        let file = ByteReader(data)
        let ahx = file[0] == 0x54 && file[1] == 0x48 && file[2] == 0x58 // "THX"
        if ahx {
            guard ahxStereo != nil, file[3] < 3 else { throw TuneError.malformed("not a HivelyTracker module") }
        } else {
            guard data.count >= 16, file[0] == 0x48, file[1] == 0x56, file[2] == 0x4C else { // "HVL"
                throw TuneError.malformed("not a HivelyTracker module")
            }
            guard file[3] <= 1 else { throw TuneError.unsupported("a HivelyTracker module of a later kind (\(file[3]))") }
        }
        isAHX = ahx
        // (The tracker's replayer leaves an AHX file's version as it finds its memory. Nought is
        // what it is here, and in the reference this is compared with.)
        version = ahx ? 0 : file[3]

        let positionCount = UInt16(file.u16be(6) & 0xFFF)
        self.positionCount = positionCount
        let firstTrackIsEmpty = file[6] & 0x80 != 0
        speedMultiplier = Int((file[6] >> 5) & 3) + 1
        channels = ahx ? 4 : Int(file[8] >> 2) + 4
        let restart = ahx ? UInt16(file.u16be(8)) : UInt16(file.u16be(8) & 0x3FF)
        trackLength = file[10]
        highestTrack = file[11]
        let instrumentsSaid = Int(file[12])
        let subsongs = Int(file[13])
        // (The widths are five, and a file is one byte that could say more. The tracker would
        // look past the end of its table; here anything wider is the widest.)
        stereo = min(4, ahx ? max(0, ahxStereo ?? 0) : Int(file[15]))
        mixGain = ahx ? Self.ahxGains[stereo] * 256 / 100 : (Int32(file[14]) << 8) / 100

        // The tracker turns these away.
        guard positionCount <= Self.mostPositions, trackLength <= Self.rows, instrumentsSaid <= Self.mostInstruments else {
            throw TuneError.malformed("a HivelyTracker module with \(positionCount) positions, tracks of \(trackLength) rows and \(instrumentsSaid) instruments")
        }
        // And these it takes as they come, and reads and writes past the ends of what it has set
        // aside for them. No file that was found does any of it.
        guard positionCount > 0 else { throw TuneError.malformed("a HivelyTracker module with no positions") }
        guard trackLength > 0 else { throw TuneError.malformed("a HivelyTracker module with tracks of no rows") }
        guard channels <= Self.mostChannels else { throw TuneError.malformed("a HivelyTracker module with \(channels) channels") }
        self.restart = restart >= positionCount ? positionCount - 1 : restart

        var at = ahx ? 14 : 16
        subsongStarts = (0 ..< subsongs).map {
            let start = UInt16(file.u16be(at + $0 * 2))
            // (Only for an AHX file does the tracker look at where a song is said to start.)
            return ahx && start >= positionCount ? 0 : start
        }
        at += subsongs * 2

        positionMemory = Memory(capacity: Int(positionCount) << 5)
        let positions = positionMemory.pointer
        positions.initialize(repeating: 0, count: Int(positionCount) << 5)
        let trackSpace = 256 * Self.rows + 1
        trackMemory = Memory(capacity: trackSpace)
        let tracks = trackMemory.pointer
        tracks.initialize(repeating: Step(), count: trackSpace)
        self.positions = positions
        self.tracks = tracks

        for position in 0 ..< Int(positionCount) {
            for voice in 0 ..< channels {
                positions[(position << 5) + voice] = file[at]
                positions[(position << 5) + Self.mostChannels + voice] = file[at + 1]
                at += 2
            }
        }

        // A file may leave out its first track, to say that it is empty.
        for track in (firstTrackIsEmpty ? 1 : 0) ..< Int(highestTrack) + 1 {
            for row in 0 ..< Int(trackLength) {
                if ahx {
                    tracks[(track << 6) + row] = Step(note: (file[at] >> 2) & 0x3F, instrument: ((file[at] & 3) << 4) | (file[at + 1] >> 4),
                                                      command: file[at + 1] & 0xF, parameter: file[at + 2])
                    at += 3
                } else if file[at] == 0x3F {
                    // An empty row is kept as one byte.
                    at += 1
                } else {
                    tracks[(track << 6) + row] = Step(note: file[at], instrument: file[at + 1], command: file[at + 2] >> 4, parameter: file[at + 3],
                                                      secondCommand: file[at + 2] & 0xF, secondParameter: file[at + 4])
                    at += 5
                }
            }
        }

        // A file cut short plays as far as it goes: what it has lost of its tracks is empty, and the
        // instruments it has lost, from the first that is not all there, are none, which is silent.
        // One that has lost all its instruments has nothing to be heard by.
        let tracksLost = at > data.count
        var instruments = [Instrument()]
        var entries: [ListEntry] = []
        for _ in 0 ..< instrumentsSaid {
            guard at + 22 + Int(file[at + 21]) * (ahx ? 4 : 5) <= data.count else { break }
            var instrument = Instrument()
            instrument.volume = file[at]
            instrument.filterSpeed = ((file[at + 1] >> 3) & 0x1F) | ((file[at + 12] >> 2) & 0x20)
            // (A length past the six there are is the longest. The tracker shifts by less than
            // nothing and reads past the end of a table.)
            instrument.waveLength = min(5, file[at + 1] & 7)
            instrument.attackFrames = Int16(file[at + 2])
            instrument.attackVolume = Int16(file[at + 3])
            instrument.decayFrames = Int16(file[at + 4])
            instrument.decayVolume = Int16(file[at + 5])
            instrument.sustainFrames = Int16(file[at + 6])
            instrument.releaseFrames = Int16(file[at + 7])
            instrument.releaseVolume = Int16(file[at + 8])
            instrument.filterLowerLimit = file[at + 12] & 0x7F
            instrument.vibratoDelay = file[at + 13]
            // One byte says how deep the vibrato is, whether the note is let go before the next
            // one, and how many ticks before.
            instrument.hardCutReleaseFrames = (file[at + 14] >> 4) & 7
            instrument.hardCutRelease = file[at + 14] & 0x80 != 0
            instrument.vibratoDepth = file[at + 14] & 0x0F
            instrument.vibratoSpeed = file[at + 15]
            instrument.squareLowerLimit = file[at + 16]
            instrument.squareUpperLimit = file[at + 17]
            instrument.squareSpeed = file[at + 18]
            instrument.filterUpperLimit = file[at + 19] & 0x3F
            instrument.listSpeed = Int16(file[at + 20])
            instrument.listLength = Int16(file[at + 21])
            instrument.list = entries.count
            at += 22
            for _ in 0 ..< Int(instrument.listLength) {
                var entry = ListEntry()
                if ahx {
                    // AHX packs an entry into four bytes, and numbers its commands from 0 to 7:
                    // its last two are HivelyTracker's twelfth and fifteenth.
                    entry.command = (file[at] >> 2) & 7
                    entry.secondCommand = (file[at] >> 5) & 7
                    entry.wave = ((file[at] << 1) & 6) | (file[at + 1] >> 7)
                    entry.fixed = (file[at + 1] >> 6) & 1 != 0
                    entry.note = file[at + 1] & 0x3F
                    entry.parameter = file[at + 2]
                    entry.secondParameter = file[at + 3]
                    // The first AHX had no filters, and what a file of its time says of them where
                    // the sweeps are started is taken out.
                    if file[3] == 0, entry.command == 4 { entry.parameter &= 0x0F }
                    if file[3] == 0, entry.secondCommand == 4 { entry.secondParameter &= 0x0F }
                    if entry.command == 6 { entry.command = 12 } else if entry.command == 7 { entry.command = 15 }
                    if entry.secondCommand == 6 { entry.secondCommand = 12 } else if entry.secondCommand == 7 { entry.secondCommand = 15 }
                    at += 4
                } else {
                    entry.command = file[at] & 0xF
                    entry.secondCommand = (file[at + 1] >> 3) & 0xF
                    entry.wave = file[at + 1] & 7
                    entry.fixed = (file[at + 2] >> 6) & 1 != 0
                    entry.note = file[at + 2] & 0x3F
                    entry.parameter = file[at + 3]
                    entry.secondParameter = file[at + 4]
                    at += 5
                }
                entries.append(entry)
            }
            instruments.append(instrument)
        }
        let kept = instruments.count - 1
        guard kept > 0 || instrumentsSaid == 0 else { throw TuneError.malformed("a HivelyTracker module cut short before its instruments") }
        var said: [String] = []
        if kept < instrumentsSaid {
            var used = Set<Int>()
            for step in 0 ..< (Int(highestTrack) + 1) << 6 { used.insert(Int(tracks[step].instrument)) }
            if let sentence = Shortfall.instrumentsLost(used.count { $0 > kept && $0 <= instrumentsSaid }, damaged: false, samplesToo: false) {
                said.append(sentence)
            }
        }
        if said.isEmpty, tracksLost { said.append(Shortfall.cutShort("Some of what it has is not there.")) }
        shortfalls = said
        instrumentCount = kept
        self.instruments = instruments
        self.entries = entries

        // The file says where its name is: after the music, with the instruments' names after it.
        let nameAt = file.u16be(4)
        var name: [UInt8] = []
        while name.count < 127, file[nameAt + name.count] != 0 {
            // (What is not a letter of the Amiga's is a space.)
            let byte = file[nameAt + name.count]
            name.append(byte < 0x20 || (byte >= 0x7F && byte < 0xA0) ? 0x20 : byte)
        }
        title = (TextEncoding.latin1.decode(name) ?? "").trimmed()
    }
}
