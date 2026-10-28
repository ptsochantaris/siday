// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// How a track is read into rows, and how the events of a row are put in order, follow the MIDI
// sequencer of libADLMIDI (BW_MidiSequencer, src/midiseq), Copyright (c) 2015-2026 Vitaly Novichkov,
// which is free software under the MIT licence (see THIRD-PARTY.md): so that a song is played to a
// synthesiser in the same order as libADLMIDI plays it, which is what siday's FM player is checked
// against.

import SidayFoundation

/// One track of a MIDI file, read into rows: a row is the events of one moment, in the order they are
/// played, and how long it is until the track's next.
public struct MIDITrack: Sendable {
    public struct Row: Sendable {
        /// When it is, in the file's ticks from the start of the track.
        public var tick: UInt64
        /// How many ticks it is to the next row.
        public var delay: UInt64
        /// Where its events are in `events`.
        public var events: Range<Int>
    }

    public var events: [MIDIEvent] = []
    public var rows: [Row] = []
    /// The track's name, from its first Sequence/Track Name event; empty if it has none.
    public var name = ""
    /// True if it sends anything to a synthesiser: a channel message or a system exclusive message.
    public var hasMessages = false
    /// The tick of the last thing it sends a synthesiser, if it sends anything.
    public var lastMessageTick: UInt64 = 0
    /// The tick of the last note it starts.
    public var lastNoteTick: UInt64 = 0
}

/// One song of a MIDI file: the tracks that are played together. A file of format 0 or 1 is one
/// song; one of format 2 has a song for each of its tracks.
public struct MIDISong: Sendable {
    public var tracks: [MIDITrack]
    /// The song's name, where the file gives it one.
    public var title = ""
    /// The tick of the last thing the song sends a synthesiser: the song is over when it has been
    /// played, whatever comes after it (an End of Track at a later time is not waited for).
    public var lastMessageTick: UInt64 = 0
    /// The tick of the last note the song starts.
    public var lastNoteTick: UInt64 = 0
    /// True if it has a loop that goes round for ever (see `MIDISequencer`).
    public var loopsForEver = false
    /// True if the song loops by its markers, from "loopStart" to "loopEnd" or its end (see
    /// `MIDISequencer`).
    public var loopsByMarkers = false
}

/// A Standard MIDI File, read: its songs and what it says of itself.
public struct MIDIFile: Sendable {
    /// 0, one track; 1, tracks played together; 2, tracks each a song of its own.
    public let format: Int
    /// The ticks to a quarter note; for a file timed in frames of SMPTE time code, nought (see
    /// `framesPerSecond`).
    public let division: Int
    /// For a file timed in SMPTE time code: its frames a second (29.97 for its "29"), and its ticks to
    /// a frame. Nil for one timed in quarter notes.
    public let smpte: (framesPerSecond: Double, ticksPerFrame: Int)?
    public var tracks: [MIDITrack] = []
    public var songs: [MIDISong] = []
    /// What the file is called in its own text, where it plainly names itself; else empty.
    public var title = ""
    /// The file's first copyright notice, as it gives it; else empty.
    public var copyright = ""
    /// What the file asks for that cannot be played, a sentence for each (see `TuneInfo.shortfalls`).
    public var shortfalls: [String] = []

    /// The order the events of a moment of a track are played in.
    public enum Order: Sendable {
        /// libADLMIDI's (see `sort`), which siday plays them in.
        case libADLMIDI
        /// The file's own: to find where a song's music begins (see `MIDISequencer.firstNotes`).
        case asWritten
    }

    /// Reads a Standard MIDI File, or one wrapped in RIFF as an RMID file, with the events of each moment
    /// in `order`.
    public init(_ data: [UInt8], order: Order = .libADLMIDI) throws {
        let file = ByteReader(data)
        var start = 0
        if file.ascii(at: 0, length: 4) == "RIFF", file.ascii(at: 8, length: 4) == "RMID" {
            // The MIDI file is the RIFF file's "data" chunk.
            var at = 12
            start = -1
            while at + 8 <= data.count {
                let length = file.u32le(at + 4)
                if file.ascii(at: at, length: 4) == "data" {
                    start = at + 8
                    break
                }
                at += 8 + length + (length & 1)
            }
            guard start >= 0 else { throw TuneError.malformed("an RMID file with no MIDI data") }
        }
        guard file.ascii(at: start, length: 4) == "MThd" else { throw TuneError.malformed("not a MIDI file") }
        let headerLength = file.u32be(start + 4)
        guard headerLength >= 6, start + 14 <= data.count else { throw TuneError.malformed("a MIDI file cut short in its header") }
        let format = file.u16be(start + 8), count = file.u16be(start + 10), division = file.u16be(start + 12)
        self.format = format > 2 ? 1 : format
        if division & 0x8000 != 0 {
            // Frames a second as a negative number, and ticks to a frame.
            let frames = -Int(Int8(truncatingIfNeeded: division >> 8))
            smpte = (frames == 29 ? 30000.0 / 1001.0 : Double(frames), max(1, division & 0xFF))
            self.division = 0
        } else {
            smpte = nil
            self.division = division
        }
        guard self.division > 0 || smpte != nil else { throw TuneError.malformed("a MIDI file of no ticks to a beat") }

        var at = start + 8 + headerLength
        var cutShort = 0, missing = 0
        var markers = LoopMarkers()
        for index in 0 ..< count {
            guard at + 8 <= data.count else {
                missing = count - index
                break
            }
            guard file.ascii(at: at, length: 4) == "MTrk" else {
                // Not a track where one should be: the rest are taken to be lost.
                missing = count - index
                break
            }
            let length = file.u32be(at + 4)
            let end = at + 8 + length
            if end > data.count { cutShort += 1 }
            var track = MIDITrack()
            Self.read(file, from: at + 8, to: min(end, data.count), into: &track, markers: &markers, order: order)
            tracks.append(track)
            at = end
        }
        guard !tracks.isEmpty else { throw TuneError.malformed("a MIDI file with no tracks") }
        if missing > 0 || cutShort > 0 {
            // (The file is played as far as it goes.)
            let lost = missing == 0 ? "" : missing == 1 ? "Its last track is missing" : "Its last \(Shortfall.number(missing)) tracks are missing"
            let short = cutShort == 0 ? "" : cutShort == 1 ? "a track of it ends early" : "\(Shortfall.number(cutShort)) of its tracks end early"
            let said = lost.isEmpty ? Shortfall.capitalNumber(cutShort) + (cutShort == 1 ? " of its tracks ends early" : " of its tracks end early")
                : short.isEmpty ? lost : lost + ", and " + short
            shortfalls.append(Shortfall.cutShort(said + "."))
        }

        // The songs.
        var songTracks: [[Int]] = []
        if self.format == 2 {
            // A track that sends nothing to a synthesiser, but has the tempo, is played with every
            // song: XMI2MID, which made many files of games' music, puts each song's tempo in a track
            // of its own before it.
            let conductors = tracks.indices.filter { !tracks[$0].hasMessages }
            for index in tracks.indices where tracks[index].hasMessages {
                songTracks.append(conductors.filter { $0 < index } + [index])
            }
        }
        if songTracks.isEmpty { songTracks = [Array(tracks.indices)] }
        for indices in songTracks {
            var song = MIDISong(tracks: indices.map { tracks[$0] })
            song.tracks[0].beginWithSong()
            song.lastMessageTick = song.tracks.reduce(0) { max($0, $1.hasMessages ? $1.lastMessageTick : 0) }
            song.lastNoteTick = song.tracks.reduce(0) { max($0, $1.lastNoteTick) }
            song.title = self.format == 2 ? tracks[indices.last!].name : ""
            song.loopsByMarkers = markers.valid
            song.loopsForEver = MIDISequencer.loopsForEver(song)
            songs.append(song)
        }
        if self.format == 2, songs.count == 1 { songs[0].title = "" }

        title = Self.title(of: tracks, format: self.format)
        for track in tracks {
            if let notice = track.events.first(where: { $0.kind == .meta && $0.meta == 0x02 }) {
                copyright = Self.text(notice.bytes)
                break
            }
        }
    }

    /// The markers of a loop, "loopStart" and "loopEnd", as libADLMIDI takes them, across all the
    /// tracks: a loop is not to be had if either is found twice, or both at the same moment, or the end
    /// before the start.
    struct LoopMarkers {
        var start: UInt64?, end: UInt64?
        var invalid = false
        /// Each row that has one in it ends with it, and what comes after it at the same moment is a row
        /// of its own.
        var inThisRow = false

        mutating func note(_ mark: UInt8, at tick: UInt64) {
            guard !invalid else { return }
            if mark == 1 {
                if start != nil || inThisRow { invalid = true } else { start = tick }
            } else {
                if end != nil || inThisRow { invalid = true } else { end = tick }
            }
            inThisRow = true
        }

        var valid: Bool {
            guard !invalid, let start else { return false }
            if let end, start != 0, end != 0, start >= end { return false }
            return true
        }
    }

    /// Reads one track's events into rows, as libADLMIDI's sequencer does.
    private static func read(_ file: ByteReader, from start: Int, to end: Int, into track: inout MIDITrack, markers: inout LoopMarkers, order: Order) {
        var at = start
        /// A number of the variable length MIDI keeps times in: seven bits to a byte, the highest
        /// set on all but the last. Nil if the track ends before it does.
        func variable() -> UInt64? {
            var value: UInt64 = 0
            for _ in 0 ..< 4 {
                guard at < end else { return nil }
                let byte = file[at]
                at += 1
                value = value << 7 | UInt64(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            return value
        }

        var row: [MIDIEvent] = []
        var tick: UInt64 = 0
        /// Whether each note of each channel is on, from the rows before: see `sort`.
        var notes = [Bool](repeating: false, count: 2048)
        func flush(delay: UInt64) {
            if order == .libADLMIDI { sort(&row, notes: &notes) }
            let first = track.events.count
            track.events += row
            track.rows.append(MIDITrack.Row(tick: tick, delay: delay, events: first ..< track.events.count))
            tick += delay
            row.removeAll(keepingCapacity: true)
            markers.inThisRow = false
        }

        // The track begins with a row of its own, whose delay is to its first event.
        guard let first = variable() else {
            track.events = [MIDIEvent(kind: .endOfTrack)]
            track.rows = [MIDITrack.Row(tick: 0, delay: 0, events: 0 ..< 1)]
            return
        }
        flush(delay: first)

        var status: UInt8 = 0
        while true {
            var event: MIDIEvent
            if at + 1 > end {
                // The track's data has run out: its end is taken as read.
                event = MIDIEvent(kind: .endOfTrack)
            } else {
                var byte = file[at]
                at += 1
                if byte == 0xF0 || byte == 0xF7 {
                    guard let length = variable(), at + Int(length) <= end else {
                        event = MIDIEvent(kind: .endOfTrack)
                        row.append(event)
                        flush(delay: 0)
                        return
                    }
                    event = MIDIEvent(kind: .systemExclusive)
                    event.bytes = [byte] + file.data[at ..< at + Int(length)]
                    at += Int(length)
                } else if byte == 0xFF {
                    let type = file[at]
                    at += 1
                    guard let length = variable(), at + Int(length) <= end else {
                        event = MIDIEvent(kind: .endOfTrack)
                        row.append(event)
                        flush(delay: 0)
                        return
                    }
                    let bytes = Array(file.data[at ..< at + Int(length)])
                    at += Int(length)
                    switch type {
                    case 0x2F:
                        event = MIDIEvent(kind: .endOfTrack)
                    case 0x51 where length <= 5:
                        event = MIDIEvent(kind: .tempo)
                        event.tempo = bytes.reduce(0) { $0 << 8 | UInt32($1) }
                    default:
                        event = MIDIEvent(kind: .meta)
                        event.meta = type
                        event.bytes = bytes
                        if type == 0x03, track.name.isEmpty { track.name = text(bytes) }
                        if type == 0x06 {
                            let name = text(bytes).lowercased()
                            if name.hasPrefix("loopstart") { event.loopMark = 1 } else if name.hasPrefix("loopend") { event.loopMark = 2 }
                            if event.loopMark != 0 { markers.note(event.loopMark, at: tick) }
                        }
                    }
                } else {
                    if byte < 0x80 {
                        // Running status: the event is of the same kind as the one before. (With
                        // none before it, it is read as libADLMIDI reads it, as a note ended.)
                        byte = status | 0x80
                        at -= 1
                    }
                    status = byte
                    if byte >= 0xF0 {
                        // A system common or real-time message, which a file should not have: its
                        // data, if any, is passed over.
                        let size = byte == 0xF2 ? 2 : byte == 0xF3 || byte == 0xF1 ? 1 : 0
                        guard at + size <= end else {
                            row.append(MIDIEvent(kind: .endOfTrack))
                            flush(delay: 0)
                            return
                        }
                        at += size
                        event = MIDIEvent(kind: .system)
                    } else {
                        let kind = MIDIEvent.Kind(rawValue: byte >> 4)!
                        let size = kind == .program || kind == .channelTouch ? 1 : 2
                        guard at + size <= end else {
                            row.append(MIDIEvent(kind: .endOfTrack))
                            flush(delay: 0)
                            return
                        }
                        event = MIDIEvent(kind: kind, channel: byte & 0x0F, data1: file[at], data2: size == 2 ? file[at + 1] : 0)
                        at += size
                        // A note started at no velocity is a note ended.
                        if kind == .noteOn, event.data2 == 0 { event.kind = .noteOff }
                    }
                }
            }
            row.append(event)
            if event.isChannelMessage || event.kind == .systemExclusive {
                track.hasMessages = true
                track.lastMessageTick = tick
                if event.kind == .noteOn { track.lastNoteTick = tick }
            }
            // (As libADLMIDI is built: an End of Track at a moment of its own comes as soon as the row
            // before it, so that a track's silence after its last event is not waited for.)
            if event.kind == .endOfTrack {
                if row.count == 1, !track.rows.isEmpty { track.rows[track.rows.count - 1].delay = 0 }
                flush(delay: 0)
                return
            }
            guard let delay = variable() else {
                // The track has run out where the time to its next event should be: it ends here,
                // with no End of Track, as libADLMIDI reads it.
                if row.count == 1, !track.rows.isEmpty { track.rows[track.rows.count - 1].delay = 0 }
                flush(delay: 0)
                return
            }
            if delay > 0 || markers.inThisRow { flush(delay: delay) }
        }
    }

    /// Puts the events of a row in the order they are played, as libADLMIDI's sequencer does: by
    /// `MIDIEvent.priority`, keeping the file's order among those of the same; and then a note's end
    /// that would come before its own start, where the note was not on, or was ended already in the
    /// row, is moved to the end of the row, so that a note started and ended at the same moment is
    /// not left sounding.
    static func sort(_ row: inout [MIDIEvent], notes: inout [Bool]) {
        let count = row.count
        if count > 1 {
            for mi in 1 ..< count {
                let event = row[mi], priority = event.priority
                var mj = mi
                while mj > 0, priority < row[mj - 1].priority {
                    row[mj] = row[mj - 1]
                    mj -= 1
                }
                row[mj] = event
            }
        }
        guard count > 0 else { return }
        if count > 1 {
            var maxSize = count
            var i = count - 1
            while true {
                let event = row[i]
                if event.kind == .noteOff { break }
                if event.kind != .noteOn {
                    if i == 0 { break }
                    i -= 1
                    continue
                }
                let note = Int(event.channel) << 7 | Int(event.data1 & 0x7F)
                let wasOn = notes[note]
                var endsOfSameNote = 0
                var j = 0
                while j < maxSize {
                    let other = row[j]
                    if other.kind == .noteOn { break }
                    if other.kind != .noteOff {
                        j += 1
                        continue
                    }
                    if Int(other.channel) << 7 | Int(other.data1 & 0x7F) == note {
                        if !wasOn || endsOfSameNote != 0 {
                            if j < count - 1 {
                                row.remove(at: j)
                                row.append(other)
                                maxSize -= 1
                                if j < i { i -= 1 }
                            } else {
                                j += 1
                            }
                            continue
                        }
                        endsOfSameNote += 1
                    }
                    j += 1
                }
                if i == 0 { break }
                i -= 1
            }
        }
        for event in row {
            if event.kind == .noteOn {
                notes[Int(event.channel) << 7 | Int(event.data1 & 0x7F)] = true
            } else if event.kind == .noteOff {
                notes[Int(event.channel) << 7 | Int(event.data1 & 0x7F)] = false
            }
        }
    }

    /// A text of the file's, in the encoding of the PCs most were written on.
    static func text(_ bytes: [UInt8]) -> String {
        var end = bytes.count
        while end > 0, bytes[end - 1] == 0 { end -= 1 }
        return (TextEncoding.windows1252.decode(bytes[0 ..< end]) ?? "").trimmed(newlines: true)
    }

    /// What the file is called, if it plainly says: the name of its first track where that track is
    /// the file's whole tune (format 0) or holds only its tempo and the like (format 1, as the
    /// sequencers of the time wrote the song's name), and is not a name a sequencer gave every file
    /// it made.
    static func title(of tracks: [MIDITrack], format: Int) -> String {
        guard let first = tracks.first, format == 0 || (format == 1 && !first.hasMessages) else { return "" }
        let name = first.name
        let lower = name.lowercased()
        let made = ["untitled", "seq-1", "sequence", "winjammer demo", "track 1", "track1", "track 0", "tk10", "melody", "drums", "piano", "tempo"]
        guard !made.contains(lower), name.utf8.contains(where: { ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A }) else { return "" }
        return name
    }
}

public extension MIDIFile {
    /// Every system exclusive message of the file, track by track.
    var systemExclusiveMessages: [[UInt8]] {
        var messages: [[UInt8]] = []
        for track in tracks {
            for event in track.events where event.kind == .systemExclusive { messages.append(event.bytes) }
        }
        return messages
    }

    /// True if the file sends a synthesiser any system exclusive message of its own.
    var sendsSystemExclusive: Bool {
        tracks.contains { track in track.events.contains { $0.kind == .systemExclusive } }
    }

    /// The system exclusive messages of a file kept beside a MIDI file to set the synthesiser up before
    /// it is played, in the order they are to be sent: a file of them back to back (`.syx`), as most
    /// were kept; or a MIDI file of them alone, as some were (see `Companions`). Each begins with its
    /// F0 and ends with its F7; what is between messages is passed over.
    static func messages(ofCompanion bytes: [UInt8]) -> [[UInt8]] {
        if bytes.starts(with: [0x4D, 0x54, 0x68, 0x64]) || bytes.starts(with: [0x52, 0x49, 0x46, 0x46]) {
            guard let file = try? MIDIFile(bytes) else { return [] }
            // In the order they are played: by their times, the tracks' rows merged.
            var timed: [(tick: UInt64, track: Int, index: Int, bytes: [UInt8])] = []
            for (number, track) in file.tracks.enumerated() {
                for row in track.rows {
                    for index in row.events where track.events[index].kind == .systemExclusive && track.events[index].bytes.first == 0xF0 {
                        timed.append((row.tick, number, index, track.events[index].bytes))
                    }
                }
            }
            timed.sort { ($0.tick, $0.track, $0.index) < ($1.tick, $1.track, $1.index) }
            return timed.map { $0.bytes }
        }
        var messages: [[UInt8]] = []
        var at = 0
        while at < bytes.count {
            guard bytes[at] == 0xF0, let end = bytes[at...].firstIndex(of: 0xF7) else {
                at += 1
                continue
            }
            messages.append(Array(bytes[at ... end]))
            at = end + 1
        }
        return messages
    }
}

extension MIDITrack {
    /// Puts the start of the song first in the track's first row.
    mutating func beginWithSong() {
        guard !rows.isEmpty, !events[rows[0].events].contains(where: { $0.kind == .songBegins }) else { return }
        events.insert(MIDIEvent(kind: .songBegins), at: rows[0].events.lowerBound)
        rows[0].events = rows[0].events.lowerBound ..< rows[0].events.upperBound + 1
        for index in 1 ..< rows.count {
            rows[index].events = rows[index].events.lowerBound + 1 ..< rows[index].events.upperBound + 1
        }
    }
}
