// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// How time is kept, and when each row is played, follow the MIDI sequencer of libADLMIDI
// (BW_MidiSequencer, src/midiseq/impl/process_impl.hpp and io_impl.hpp), Copyright (c) 2015-2026
// Vitaly Novichkov, which is free software under the MIT licence (see THIRD-PARTY.md): so that a song
// reaches a synthesiser at the very moments libADLMIDI's reaches its own, which is what siday's FM
// player is checked against.

/// Plays a song: tells a synthesiser each event of it as its moment comes.
///
/// Time is kept in seconds. A tempo is kept as an exact fraction, seconds to a tick, and the time to
/// the next row is worked out from it each time, as libADLMIDI does; the player asks for the events
/// of so much time at a time (`tick`).
///
/// A song ends when the last thing it sends a synthesiser has been sent, and a second after that the
/// sequencer says so (`atEnd`): whatever the file has after its last message (an End of Track a day
/// later, as a few have) is not waited for.
///
/// A song loops where it says to as the software that wrote it into the file meant: by the loop
/// controllers of Miles Design's Audio Interface Library (XMIDI's FOR and NEXT, controllers 116 and
/// 117), which the games' music converted from XMIDI to MIDI files keeps, and which Apogee's EMIDI
/// gives the same meaning. A FOR's value is how many times the part after it is played, nought for
/// ever; a NEXT of 64 or more goes back to the FOR, and one of less leaves the loop. The whole song goes
/// back, every track, as the single track of an XMIDI sequence did. But a loop for ever is gone round
/// only where no note of the song is started after its NEXT: a game's music often loops a part for
/// as long as the player is in a place, and goes on to the next part, with more loops, when the game
/// tells it to; heard by itself, such a song is played through once, and only its last loop, that
/// of the song itself, goes round.
///
/// A song loops too by markers, as libADLMIDI loops it and as the files converted from HMI's music
/// for games (Daggerfall's) mark it: from a marker "loopStart" to one "loopEnd", or to its end, for
/// ever.
public final class MIDISequencer {
    /// A time as a fraction of a second, kept exact as libADLMIDI keeps it.
    struct Fraction {
        var nom: UInt64
        var denom: UInt64

        /// In its lowest terms.
        mutating func reduce() {
            guard nom != 0 else {
                denom = 1
                return
            }
            var n1 = min(nom, denom), n2 = max(nom, denom)
            var remainder = n2 % n1
            while remainder != 0 {
                n2 = n1
                n1 = remainder
                remainder = n2 % n1
            }
            nom /= n1
            denom /= n1
        }

        func times(_ value: UInt64) -> Fraction {
            var product = Fraction(nom: nom &* value, denom: denom)
            product.reduce()
            return product
        }

        var seconds: Double { Double(nom) / Double(denom) }
    }

    struct TrackPosition {
        /// The next row to be played; past the last once there are none.
        var row = 0
        /// Ticks until it is played.
        var delay: UInt64 = 0
        /// Below nought once the track has ended.
        var status = 0
    }

    struct Position {
        var tracks: [TrackPosition]
        /// Seconds until the next row is due.
        var wait = 0.0
        /// Seconds played.
        var time = 0.0
        /// Ticks played.
        var tick: UInt64 = 0
    }

    /// A loop that has been gone into: where it goes back to, and how many more times it is played,
    /// nought for ever.
    struct Loop {
        var position: Position
        var tempo: Fraction
        var left: Int
    }

    public let song: MIDISong
    /// Seconds a tick at a tempo of a quarter note a second, the fraction tempos are multiplied by;
    /// nil for a song timed in SMPTE frames, whose ticks are always the same length.
    private let perMicrosecond: Fraction?
    private let startingTempo: Fraction
    private var tempo: Fraction
    private var position: Position
    private var loops: [Loop] = []
    /// Where a loop by markers goes back to, once its "loopStart" has been played.
    private var markerLoop: Loop?
    /// True for the moments played again after going back to a loop, at which its FOR is not gone into
    /// again.
    private var replaying = false

    /// True once the song is over, and its last second has been waited.
    public private(set) var atEnd = false
    /// How many times the song has gone back to a loop that goes round for ever.
    public private(set) var loopCount = 0
    /// Where, in seconds, the first loop that goes round for ever begins and ends, once it has gone
    /// round once.
    public private(set) var foreverLoop: (start: Double, end: Double)?
    /// How long the sequencer waits after the song's last message before it says it is over.
    public static let lastWait = 1.0

    /// System exclusive messages sent before the song, from a file beside it that sets the synthesiser
    /// up (see `MIDIFile.messages(ofCompanion:)`), and the seconds at which each is sent.
    private let prelude: [MIDIEvent]
    private let preludeTimes: [Double]
    private var preludeSent = 0
    /// How long the messages before the song take, after which it starts.
    public let preludeLength: Double

    /// - Parameter file: the file the song is from, for its timing.
    /// - Parameter prelude: system exclusive messages to send before it, whole (F0 to F7).
    public init(_ song: MIDISong, of file: MIDIFile, prelude messages: [[UInt8]] = []) {
        self.song = song
        // Each message is sent as fast as a MIDI cable carries it, ten bits a byte at 31,250 a second,
        // and then the synthesiser is given time to take it in before the next: siday's choice, 40 ms,
        // and 120 ms after an MT-32's reset of all its parameters (address 7F), about what Origin's own
        // Wing Commander file of its MT-32 set-up leaves after it. (The rips of the time do anything
        // from sending them all at once, leaving it to the cable, to 120 ms apart.) The song starts when
        // the last has been taken in.
        var times: [Double] = []
        var time = 0.0
        for message in messages {
            times.append(time)
            let reset = message.count >= 6 && message[1] == 0x41 && message[3] == 0x16 && message[5] == 0x7F
            time += Double(message.count) * 10 / 31250 + (reset ? 0.12 : 0.04)
        }
        prelude = messages.map { message in
            var event = MIDIEvent(kind: .systemExclusive)
            event.bytes = message
            return event
        }
        preludeTimes = times
        preludeLength = time
        if let smpte = file.smpte {
            // A tick is a fixed part of a frame.
            let ticks = UInt64(smpte.ticksPerFrame)
            startingTempo = smpte.framesPerSecond == 30000.0 / 1001.0 ? Fraction(nom: 1001, denom: 30000 * ticks) : Fraction(nom: 1, denom: UInt64(smpte.framesPerSecond) * ticks)
            perMicrosecond = nil
        } else {
            // Until the song says otherwise, 120 beats a minute.
            startingTempo = Fraction(nom: 1, denom: UInt64(file.division) * 2)
            perMicrosecond = Fraction(nom: 1, denom: 1_000_000 * UInt64(file.division))
        }
        tempo = startingTempo
        position = Position(tracks: Array(repeating: TrackPosition(), count: song.tracks.count))
        position.wait = preludeLength
    }

    /// Back to the start of the song.
    public func rewind() {
        tempo = startingTempo
        position = Position(tracks: Array(repeating: TrackPosition(), count: song.tracks.count))
        position.wait = preludeLength
        preludeSent = 0
        loops = []
        markerLoop = nil
        replaying = false
        atEnd = false
        loopCount = 0
        foreverLoop = nil
    }

    /// Seconds played.
    public var time: Double { position.time }

    /// Lets `seconds` pass, and plays what falls due in them, to within half of `granularity`.
    /// - Returns: the seconds until the next row is due.
    public func tick<Receiver: MIDIReceiver>(_ seconds: Double, granularity: Double, to receiver: Receiver) -> Double {
        position.wait -= seconds
        position.time += seconds
        while preludeSent < prelude.count, preludeTimes[preludeSent] <= position.time + granularity * 0.5 {
            receiver.receive(prelude[preludeSent])
            preludeSent += 1
        }
        // (As libADLMIDI, no more than ten thousand rows that take no time at once.)
        var antiFreeze = 10000
        while position.wait <= granularity * 0.5, antiFreeze > 0 {
            if !playRow(to: receiver) { break }
            if position.wait <= 0 { antiFreeze -= 1 }
        }
        if antiFreeze <= 0 { position.wait += 1 }
        if preludeSent < prelude.count { return max(0, min(position.wait, preludeTimes[preludeSent] - position.time)) }
        return max(0, position.wait)
    }

    /// Plays every track's row that is due, and works out how long it is to the next.
    /// - Returns: false once the song is over.
    private func playRow<Receiver: MIDIReceiver>(to receiver: Receiver) -> Bool {
        if position.tracks.isEmpty { atEnd = true }
        if atEnd { return false }
        let begun = position
        var goBack: Loop?
        tracks: for index in position.tracks.indices {
            var track = position.tracks[index]
            guard track.status >= 0, track.delay == 0 else { continue }
            let rows = song.tracks[index].rows
            guard track.row < rows.count else {
                // (As libADLMIDI: a track that has run out without an End of Track stops the others'
                // rows at this moment.)
                position.tracks[index].status = -1
                break
            }
            let row = rows[track.row]
            for event in song.tracks[index].events[row.events] {
                switch event.kind {
                case .endOfTrack:
                    track.status = -1
                case .tempo:
                    if let perMicrosecond {
                        var tempo = perMicrosecond.times(UInt64(event.tempo))
                        tempo.reduce()
                        self.tempo = tempo
                    }
                case .songBegins:
                    receiver.songBegins()
                case .systemExclusive:
                    receiver.receive(event)
                case .meta:
                    if event.loopMark == 1, song.loopsByMarkers, !replaying {
                        markerLoop = Loop(position: begun, tempo: tempo, left: 0)
                    } else if event.loopMark == 2, let loop = markerLoop {
                        goBack = loop
                        loopCount += 1
                        if foreverLoop == nil { foreverLoop = (loop.position.time, position.time) }
                    }
                case .system:
                    break
                default:
                    track.status = Int(event.kind.rawValue)
                    receiver.receive(event)
                    if event.kind == .controller, event.data1 == 116, !replaying {
                        loops.append(Loop(position: begun, tempo: tempo, left: Int(event.data2)))
                    } else if event.kind == .controller, event.data1 == 117, var loop = loops.last {
                        if event.data2 < 64 || (loop.left == 0 && row.tick < song.lastNoteTick) {
                            // Left; or a loop for ever with more of the song after it, which is passed
                            // through (see the type's notes).
                            loops.removeLast()
                        } else if loop.left == 0 {
                            goBack = loop
                            loopCount += 1
                            if foreverLoop == nil { foreverLoop = (loop.position.time, position.time) }
                        } else {
                            loop.left -= 1
                            loops[loops.count - 1] = loop
                            if loop.left > 0 { goBack = loop } else { loops.removeLast() }
                        }
                    }
                }
                if goBack != nil { break }
            }
            if track.status >= 0 {
                track.delay += row.delay
                track.row += 1
            }
            position.tracks[index] = track
            if goBack != nil { break tracks }
        }
        replaying = false

        if let loop = goBack {
            // Back to the moment of the FOR, every track, with the tempo there was then; the time
            // goes on.
            let (wait, time) = (position.wait, position.time)
            position = loop.position
            position.wait = wait
            position.time = time
            tempo = loop.tempo
            replaying = true
            return true
        }

        // The song is over once its last message has been sent.
        var over = position.tick >= song.lastMessageTick

        // How long until the next row of any track.
        var shortest: UInt64?
        for track in position.tracks where track.status >= 0 {
            if shortest == nil || track.delay < shortest! { shortest = track.delay }
        }
        if shortest == nil { over = true }
        if over, let loop = markerLoop {
            // A loop by markers with no "loopEnd" goes round at the song's end.
            loopCount += 1
            if foreverLoop == nil { foreverLoop = (loop.position.time, position.time) }
            let (wait, time) = (position.wait, position.time)
            position = loop.position
            position.wait = wait
            position.time = time
            tempo = loop.tempo
            replaying = true
            return true
        }
        if !over, let shortest {
            for index in position.tracks.indices { position.tracks[index].delay &-= shortest }
            position.wait += tempo.times(shortest).seconds
            position.tick += shortest
        }
        if over {
            atEnd = true
            position.wait += Self.lastWait
        }
        return true
    }

    /// True if a song has a loop that goes round for ever: a FOR of nought, and a NEXT after it with no
    /// note started after that.
    public static func loopsForEver(_ song: MIDISong) -> Bool {
        var forTick: UInt64?
        var nextTick: UInt64 = 0
        for track in song.tracks {
            for row in track.rows {
                for event in track.events[row.events] where event.kind == .controller {
                    if event.data1 == 116, event.data2 == 0 { forTick = min(forTick ?? row.tick, row.tick) }
                    if event.data1 == 117, event.data2 >= 64, row.tick >= song.lastNoteTick { nextTick = max(nextTick, row.tick) }
                }
            }
        }
        if song.loopsByMarkers { return true }
        guard let forTick, nextTick > 0 else { return false }
        return nextTick >= forTick
    }
}
