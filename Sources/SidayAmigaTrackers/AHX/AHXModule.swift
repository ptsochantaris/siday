// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ahx2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

import SidayChips
import SidayFoundation

/// An AHX file, read into the shape the tracker keeps one in.
///
/// AHX is a tracker for the Amiga that has no samples: its instruments are a few numbers each, and a
/// short list of things to do as a note goes on, from which the player makes the sound as it plays.
/// A file is a list of positions, each of which says which track each of the four voices plays and
/// how far up or down it is moved; the tracks, of up to 64 rows; and the instruments.
final class AHXModule {
    /// The most rows a track has, and the room each track is given.
    static let rows = 64
    static let mostInstruments = 63
    /// Where the things an instrument is made of are, counted from its first byte, as in the file.
    enum Field {
        static let volume = 0, filterSpeedAndWavelength = 1
        static let attackFrames = 2, attackVolume = 3, decayFrames = 4, decayVolume = 5
        static let sustainFrames = 6, releaseFrames = 7, releaseVolume = 8
        static let filterLowerLimit = 12, vibratoDelay = 13, vibratoDepth = 14, vibratoSpeed = 15
        static let squareLowerLimit = 16, squareUpperLimit = 17, squareSpeed = 18, filterUpperLimit = 19
        static let listSpeed = 20, listLength = 21
        /// The list of things to do as a note goes on, four bytes to an entry.
        static let list = 22
    }

    /// The room each instrument is given: what the file has of it, and nothing after. A list can be
    /// told to go on from an entry past its end, and the player then reads on through as many as 512
    /// entries before it stops; they are here to be read, and they are empty.
    static let instrumentSpace = Field.list + 4 * 512 + 2
    private static let trackSpace = 256 * rows * 3
    /// How long the Amiga's timer is set to count between one tick and the next, by what the file
    /// says of its speed: fifty ticks a second, or two, three or four times that.
    private static let timerPeriods: [UInt16] = [14209, 7104, 4736, 3552]

    let title: String
    /// 0 for a file from the first AHX, which had no filters, and 1 for one from the second.
    let revision: UInt8
    let positionCount: UInt16
    /// The position the song goes on from when it runs off the end of the list.
    let restart: UInt16
    let trackLength: UInt16
    let highestTrack: UInt8
    let instrumentCount: Int
    /// Where each of the file's other songs starts in the list of positions.
    let subsongStarts: [UInt16]
    let timerPeriod: UInt16

    private let positions: UnsafeMutablePointer<UInt8>
    /// Every track there can be, 64 rows of three bytes each: those the file does not have are empty.
    private let tracks: UnsafeMutablePointer<UInt8>
    /// The instruments by number, `instrumentSpace` to each. The one numbered nought is the one the
    /// player gives a note that asks for an instrument the file does not have.
    let instruments: UnsafeMutablePointer<UInt8>
    /// What gives those three back, also for a file that turns out not to be a module.
    private let held: [Memory<UInt8>]

    /// How many times a second the player is run.
    var ticksPerSecond: Double { (Paula.clockHz / 5.0) / Double(Int(timerPeriod) + 1) }

    /// A byte of a position: the track and then the transposition of each voice in turn, and nothing
    /// for a position the list does not have.
    @inline(__always) func position(_ position: Int, _ offset: Int) -> UInt8 {
        position < Int(positionCount) ? positions[(position << 3) + offset] : 0
    }

    /// A byte of the tracks, counted from the first of them.
    @inline(__always) func track(_ offset: Int) -> UInt8 {
        offset >= 0 && offset < Self.trackSpace ? tracks[offset] : 0
    }

    /// Where an instrument is among `instruments`.
    @inline(__always) func instrument(_ number: Int) -> Int {
        number >= 1 && number <= instrumentCount ? number * Self.instrumentSpace : 0
    }

    init(_ data: [UInt8]) throws {
        let file = ByteReader(data)
        if file[0] == 0x48, file[1] == 0x56, file[2] == 0x4C { // "HVL"
            throw TuneError.unsupported("a HivelyTracker module, which is not an AHX one")
        }
        guard data.count >= 14, file[0] == 0x54, file[1] == 0x48, file[2] == 0x58 else { // "THX"
            throw TuneError.malformed("not an AHX module")
        }
        revision = file[3]
        guard revision <= 1 else { throw TuneError.unsupported("an AHX module of a later kind (\(revision))") }

        let flags = file.u16be(6)
        let firstTrackIsEmpty = flags & 0x8000 != 0
        positionCount = UInt16(flags & 0x3FF)
        let restart = UInt16(file.u16be(8))
        self.restart = restart >= positionCount ? 0 : restart
        trackLength = UInt16(file[10])
        highestTrack = file[11]
        instrumentCount = Int(file[12])
        let subsongs = Int(file[13])
        timerPeriod = Self.timerPeriods[(flags >> 13) & 3]

        // The player this is ported from takes these as they come, and reads and writes past the
        // ends of what it has set aside for them. No file that was found does any of it.
        guard positionCount > 0 else { throw TuneError.malformed("an AHX module with no positions") }
        guard trackLength > 0, trackLength <= Self.rows else { throw TuneError.malformed("an AHX module with tracks of \(trackLength) rows") }
        guard instrumentCount <= Self.mostInstruments else { throw TuneError.malformed("an AHX module with \(instrumentCount) instruments") }

        var at = 14
        subsongStarts = (0 ..< subsongs).map { UInt16(file.u16be(at + $0 * 2)) }
        at += subsongs * 2

        held = [Memory(capacity: Int(positionCount) * 8), Memory(capacity: Self.trackSpace),
                Memory(capacity: (Self.mostInstruments + 1) * Self.instrumentSpace)]
        let positions = held[0].pointer, tracks = held[1].pointer, instruments = held[2].pointer
        tracks.initialize(repeating: 0, count: Self.trackSpace)
        instruments.initialize(repeating: 0, count: (Self.mostInstruments + 1) * Self.instrumentSpace)
        self.positions = positions
        self.tracks = tracks
        self.instruments = instruments

        for i in 0 ..< Int(positionCount) * 8 { positions[i] = file[at + i] }
        at += Int(positionCount) * 8

        // A file may leave out its first track, to say that it is empty.
        let trackBytes = Int(trackLength) * 3
        for track in (firstTrackIsEmpty ? 1 : 0) ..< Int(highestTrack) + 1 {
            for i in 0 ..< trackBytes { tracks[track * Self.rows * 3 + i] = file[at + i] }
            at += trackBytes
        }

        for number in 1 ..< instrumentCount + 1 {
            let bytes = Field.list + (Int(file[at + Field.listLength]) << 2)
            guard at + bytes <= data.count else { throw TuneError.malformed("an AHX module that is cut short") }
            for i in 0 ..< bytes { instruments[number * Self.instrumentSpace + i] = file[at + i] }
            at += bytes
        }
        guard at <= data.count else { throw TuneError.malformed("an AHX module that is cut short") }

        // The song's name comes after the music, and the instruments' names after it.
        var name: [UInt8] = []
        while name.count < 255, file[at + name.count] != 0 {
            // (What is not a letter of the Amiga's is a space.)
            let byte = file[at + name.count]
            name.append(byte < 0x20 || (byte >= 0x7F && byte < 0xA0) ? 0x20 : byte)
        }
        title = (TextEncoding.latin1.decode(name) ?? "").trimmed()

        // The first AHX had no filters, and what a file of its time has where the filter's commands
        // came to be is taken out: of the tracks, where a track of fewer than 64 rows is counted
        // from the end of the one before it and not from where it is kept, so that in such a file
        // it is other rows that are looked at; and of the instruments' lists.
        if revision == 0 {
            for row in 0 ..< (Int(highestTrack) + 1) * Int(trackLength) where tracks[row * 3 + 1] & 0x0F == 4 {
                tracks[row * 3 + 1] &= 0xF0
                tracks[row * 3 + 2] = 0
            }
            for number in 1 ..< instrumentCount + 1 {
                let instrument = number * Self.instrumentSpace
                for entry in 0 ..< Int(instruments[instrument + Field.listLength]) {
                    let at = instrument + Field.list + entry * 4
                    let first = (instruments[at] >> 2) & 7, second = (instruments[at] >> 5) & 7
                    if first == 0 || first == 4 { instruments[at + 2] = 0 }
                    if second == 0 || second == 4 { instruments[at + 3] = 0 }
                }
            }
        }

        // The instrument a note is given when it asks for one the file does not have.
        instruments[Field.attackFrames] = 1
        instruments[Field.decayFrames] = 1
        instruments[Field.sustainFrames] = 1
        instruments[Field.releaseFrames] = 1
        instruments[Field.listSpeed] = 1
        instruments[Field.squareLowerLimit] = 0x20
        instruments[Field.squareUpperLimit] = 0x3F
        instruments[Field.squareSpeed] = 1
        instruments[Field.filterLowerLimit] = 1
        instruments[Field.filterUpperLimit] = 0x1F
        instruments[Field.filterSpeedAndWavelength] = 4 << 3
    }
}
