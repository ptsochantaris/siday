// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday. What Oktalyzer's own replay routine does was learned by running it, in an emulated
// Amiga, beside this one and comparing what each told the sound chip, tick by tick, and what each
// mixed for it, byte by byte, and by reading how it goes about it. None of its code is here. Its
// table of periods is ProTracker's, which is from pt2-clone, Copyright (c) Olav Sørensen, used under
// the BSD 3-Clause licence (see THIRD-PARTY.md).

/// What the player told the sound chip in one tick: for setting beside what Oktalyzer's own routine
/// tells it, which is how this one is checked.
public struct OktalyzerTick: Sendable {
    public enum Register: Sendable {
        case period, volume
        /// Where to play from: a place in the file, or less than nought for a place that is not in
        /// it (silence, or what has been mixed).
        case location
        /// How far, in words.
        case length
    }

    public struct Write: Sendable {
        public var voice: Int
        public var register: Register
        public var value: Int
    }

    /// Everything written, in the order it was written.
    public var writes: [Write] = []
    /// What was mixed on this tick for each voice that has two tracks, a byte for each sample the
    /// chip is to play (empty for a voice with one track).
    public var mixed = [[Int8]](repeating: [], count: 4)
    /// How long the tick lasted, in the colour clocks the sound chip counts.
    public var clocks = 0
    /// Where the tune was: the place in the order of playing and the line last read, and which tick
    /// of the line it was.
    public var position = 0
    public var line = 0
    public var tickOfLine = 0
}

/// The player for Oktalyzer modules: what Oktalyzer did, fifty times a second, to turn a module's
/// patterns into what it told Paula.
///
/// A voice that is whole is played as any tracker plays one: a note points the chip at a sample and
/// gives it a period, and the chip does the rest. (But a tick late. The voice is stopped and told
/// its note on one tick and set going on the next.)
///
/// A voice that is split has two tracks, and Oktalyzer mixed them, a tick's worth at a time, into a
/// stretch of memory that the voice then played. It had a quick way of doing it. Mixing two notes
/// at two pitches means stepping through both samples at rates of their own, which the Amiga had
/// not the time for; so Oktalyzer steps through only one. The voice is played at the period of the
/// higher note, whose sample can then be taken a byte for a byte, and the lower note is stretched
/// to fit, each of its bytes being used as many times as it takes. When the notes change, so does
/// the voice's period, and with it how many bytes make a tick: a tick of the highest note is seven
/// times as many as one of the lowest. The two are added four bytes at a time, as one number, so
/// that a byte which overflows carries into its neighbour; samples for a split voice are made at
/// half strength so that they do not. All of that is done here as it was done there, since it is
/// what the tunes sound like. A split voice has one volume between its two tracks, its samples
/// play once and never repeat, and its notes go no higher than the A of the top octave.
///
/// The chip plays one stretch after another without being stopped, and the player and the chip keep
/// their own time: the player a timer's, the chip its periods'. A tick's worth of bytes at a
/// period is never quite a tick long, so the chip runs ahead a little on every tick; and each time
/// the player finds that the chip has already reached the last word of a stretch when a tick
/// begins, it makes the next one a word longer.
///
/// It does as Oktalyzer's routine does where that is odd, too, since tunes were written by ear
/// against it.
struct OktalyzerPlayer: ~Copyable {
    static let chipClock = Int(Paula.clockHz)
    /// How long a tick is, in the sound chip's clocks: the routine sets a timer to go off as
    /// often as a PAL Amiga draws its screen, or as near as the timer comes to it. (The timer
    /// counts cycles of a clock a fifth as fast as the chip's, and takes one count more than it is
    /// given to come round.)
    static let tickClocks = (14211 + 1) * 5
    /// The length of the screen that a tick stands for, in the same clocks: 313 lines of 227.
    /// A tick's worth of bytes at a period is as many words as go into this, rounded down.
    private static let frameClocks = 313 * 227
    /// A split voice goes no higher than this note, counting from nought.
    private static let highestMixed = 33
    private static let highest = 35
    /// What all four voices are set to play before the tune begins: so many words of silence, at
    /// the period of the lowest note.
    private static let openingWords = 41

    /// A track of a split voice: what Oktalyzer keeps for it in place of a voice of the chip.
    private struct Lane {
        /// Where in memory the track's sample has got to; nil when it is playing nothing.
        var place: Int?
        /// How much of the sample is left, in bytes.
        var left: UInt32 = 0
        /// The note it is playing, counting from nought, and the note it was given, which an
        /// arpeggio counts from.
        var note: Int16 = 0
        var base: Int16 = 0
        /// For the lights: how far it swung in what was last mixed, and whether a note has begun.
        var swing: Float = 0
        var struck = false
    }

    private struct Voice {
        var split = false
        /// The first of the tracks it plays: it has one, or two.
        var track = 0
        // A whole voice.
        /// Where it is to go on from when it reaches the end of its note, and how far.
        var loop = -1
        var loopWords: UInt16 = 1
        var note: Int16 = 0
        var period: Int16 = 0
        // A split voice: its two tracks, and what was last mixed for it.
        var lanes = (Lane(), Lane())
        var mixedPeriod: UInt16 = 0
        var mixedWords = 0
        var hasMixed = false
        /// How the chip stands with what it has been given to play: when its next byte begins, in
        /// clocks from the start of the tick, how many bytes it has still to begin before it comes
        /// to the last word of the stretch it is playing, and the period it is counting.
        var nextByte = 0
        var bytesToLastWord = 0
        var chipPeriod = 0
    }

    private typealias Cell = (note: UInt8, instrument: UInt8, command: UInt8, data: UInt8)

    let module: OktalyzerModule
    var paula: Paula
    private var voices = InlineArray<4, Voice>(repeating: Voice())
    /// What each track has on the line last read.
    private var cells = InlineArray<8, Cell>(repeating: (0, 0, 0, 0))
    /// The volumes of the four voices, and what they were when the chip was last told them.
    private var volumes: InlineArray<4, UInt8> = [64, 64, 64, 64]
    private var told: InlineArray<4, UInt8> = [64, 64, 64, 64]
    private var speed: Int16
    /// Which tick of the line it is.
    private var count: Int16 = 0
    private var position: Int
    private var line = -1
    /// The place a command has said to go to after this line; -1 for none.
    private var jump = -1
    /// The voices that were given a note on the tick before, and are to be set going.
    private var pending: UInt16 = 0
    private var begun = false
    /// Which of a split voice's stretches of memory was last mixed into.
    private var mixBuffer = 0
    private let periods: UnsafeMutablePointer<UInt16>
    private let visited: UnsafeMutablePointer<Bool>

    /// Set when the tune is to stop, which only a tune with nothing in it to play does.
    private(set) var stopped = false
    private var wrapped = false
    /// Which places in the order of playing have been played, and whether any note has been.
    private(set) var ordersPlayed: [Bool]
    private(set) var playedNote = false
    /// Which song first played each line, shared with the other songs of the file. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>?
    private let songNumber: UInt8
    private var metEarlierSong = false
    private(set) var ledIntoEarlierSong = false

    /// For the comparison with Oktalyzer's own routine: when this is not nil, each tick is written down.
    var record: OktalyzerTick?
    /// And for the same: how many words Oktalyzer's own routine mixed for each split voice on each
    /// tick, as it was seen to, in place of working out when the chip would have run ahead. (That
    /// depends on where the Amiga's screen had got to when the tune began, to a fraction of a line.)
    var wordsSeen: [[Int]]?
    private var ticksRun = 0

    /// - Parameters:
    ///   - position: where in the order of playing to start.
    ///   - firstPlayedBy: which of the songs found in this order first played each line.
    ///   - songNumber: which of them this is.
    init(_ module: OktalyzerModule, model: AmigaModel, position start: Int = 0, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil,
         songNumber: UInt8 = 0) {
        self.module = module
        self.firstPlayedBy = firstPlayedBy
        self.songNumber = songNumber
        paula = Paula(rate: Double(outputSampleRate * 2), model: model, memory: UnsafePointer(module.memory), size: module.memorySize,
                      silence: module.silence)
        speed = Int16(truncatingIfNeeded: module.speed)
        position = max(0, min(module.positions.count - 1, start))
        ordersPlayed = [Bool](repeating: false, count: module.positions.count)
        visited = .allocate(capacity: max(1, module.rowsInAll))
        visited.initialize(repeating: false, count: max(1, module.rowsInAll))
        periods = .allocate(capacity: 36)
        for i in 0 ..< 36 { periods[i] = UInt16(proTrackerPeriods[i]) }
        var track = 0
        for v in 0 ..< 4 {
            voices[v].split = module.split[v]
            voices[v].track = track
            track += module.split[v] ? 2 : 1
            // Every voice is set to play a stretch of silence, over and over, until it is given
            // something else.
            voices[v].chipPeriod = Int(periods[0])
            paula.setLocation(v, module.silence)
            paula.setLength(v, UInt16(Self.openingWords))
            paula.setPeriod(v, periods[0])
        }
    }

    deinit {
        periods.deallocate()
        visited.deallocate()
    }

    // MARK: The sound chip

    private mutating func write(_ voice: Int, _ register: OktalyzerTick.Register, _ value: Int) {
        switch register {
        case .period: paula.setPeriod(voice, UInt16(truncatingIfNeeded: value))
        case .volume: paula.setVolume(voice, UInt16(truncatingIfNeeded: value))
        case .location: paula.setLocation(voice, value)
        case .length: paula.setLength(voice, UInt16(truncatingIfNeeded: value))
        }
        let inFile = register != .location || (value >= 0 && value < module.silence)
        record?.writes.append(OktalyzerTick.Write(voice: voice, register: register, value: inFile ? value : -1))
    }

    /// How many words of a note make a tick, less the one that is added when the chip has run ahead.
    private func words(ofNote note: Int) -> Int {
        Self.frameClocks / (2 * Int(periods[note]))
    }

    // MARK: Whole voices

    /// Gives a whole voice the note its track has on the line last read: stops it, and tells it
    /// where to play from and at what period. It is set going on the next tick.
    private mutating func strike(_ v: Int) {
        let cell = cells[voices[v].track]
        guard cell.note != 0, cell.note <= 36, cell.instrument < OktalyzerModule.instrumentCount else { return }
        let instrument = module.instruments[Int(cell.instrument)]
        guard let place = instrument.place, instrument.use != .split else { return }
        let length = UInt16(truncatingIfNeeded: instrument.length >> 1)
        guard length != 0 else { return }
        paula.stop(voices: 1 << v)
        pending |= 1 << v
        write(v, .location, place)
        voices[v].note = Int16(cell.note) - 1
        voices[v].period = Int16(bitPattern: periods[Int(cell.note) - 1])
        write(v, .period, Int(periods[Int(cell.note) - 1]))
        volumes[v] = instrument.volume
        if instrument.repeatWords == 0 {
            write(v, .length, Int(length))
            voices[v].loop = module.silence
            voices[v].loopWords = 1
        } else {
            // A sample that repeats is played as far as the end of the part that repeats, and no
            // further: what the file has after that is never heard.
            write(v, .length, Int(instrument.repeatStart &+ instrument.repeatWords))
            voices[v].loop = place + Int(instrument.repeatStart) * 2
            voices[v].loopWords = instrument.repeatWords
        }
        playedNote = true
    }

    /// Tells a whole voice the period of a note, which is kept within the three octaves there are.
    private mutating func setNote(_ v: Int, _ note: Int16) {
        let period = periods[Int(max(0, min(Int16(Self.highest), note)))]
        write(v, .period, Int(period))
        voices[v].period = Int16(bitPattern: period)
    }

    /// Which of an arpeggio's three notes a tick plays: the one below, the note itself, or the one
    /// above. There are three kinds, each with its own order.
    private func arpeggio(_ kind: UInt8, _ data: UInt8) -> Int16? {
        let below = -Int16(data >> 4), above = Int16(data & 15)
        switch kind {
        case 10:
            let turn = Int(count) % 3
            return turn == 0 ? below : (turn == 1 ? 0 : above)
        case 11:
            let turn = Int(count) & 3
            return turn == 1 ? above : (turn == 3 ? below : 0)
        default:
            // (The third kind goes up by both digits, and does nothing on a line's first tick.)
            guard count != 0 else { return nil }
            let turn = (Int(count) - 1) % 3
            return turn == 0 ? Int16(data >> 4) : (turn == 1 ? above : 0)
        }
    }

    /// Carries out a whole voice's command, which is done on every tick of its line.
    private mutating func command(_ v: Int) {
        let cell = cells[voices[v].track]
        let data = Int16(cell.data)
        switch cell.command {
        case 1:
            voices[v].period = max(113, voices[v].period &- data)
            write(v, .period, Int(voices[v].period))
        case 2:
            voices[v].period = min(856, voices[v].period &+ data)
            write(v, .period, Int(voices[v].period))
        case 10, 11, 12:
            if let by = arpeggio(cell.command, cell.data) { setNote(v, voices[v].note &+ by) }
        case 13, 21:
            // The note itself is moved down, on every tick or on the line's first.
            guard cell.command == 13 || count == 0 else { return }
            voices[v].note &-= data
            setNote(v, voices[v].note)
        case 17, 30:
            guard cell.command == 30 || count == 0 else { return }
            voices[v].note &+= data
            setNote(v, voices[v].note)
        case 15:
            if count == 0 { paula.setLightFilter(cell.data != 0) }
        case 24:
            // A change of volume for a note that is not to begin at its instrument's: the volume
            // is put back to what it was before the note, and then changed.
            volumes[v] = told[v]
            if cell.data > 0x40 { fade(v, cell.data) }
        case 25, 28, 31:
            shared(cell.command, cell.data, voice: v)
        default:
            break
        }
    }

    // MARK: Commands of every voice

    /// A change of volume by one of the four ways of a volume command's number above 64: down or
    /// up on every tick, or down or up on the first tick of the line. The sums are done in a byte,
    /// as the routine does them.
    private mutating func fade(_ v: Int, _ data: UInt8) {
        var amount = Int8(bitPattern: data &- 0x40)
        var falls = true, everyTick = true
        if amount >= 0x10 {
            amount &-= 0x10
            falls = false
            if amount >= 0x10 {
                amount &-= 0x10
                falls = true
                everyTick = false
                if amount >= 0x10 {
                    amount &-= 0x10
                    falls = false
                    if amount >= 0x10 { return }
                }
            }
        }
        guard everyTick || count == 0 else { return }
        if falls {
            volumes[v] &-= UInt8(bitPattern: amount)
            if volumes[v] >= 0x80 { volumes[v] = 0 }
        } else {
            volumes[v] &+= UInt8(bitPattern: amount)
            if volumes[v] > 0x40 { volumes[v] = 0x40 }
        }
    }

    /// The commands that a track of either kind of voice has.
    private mutating func shared(_ command: UInt8, _ data: UInt8, voice v: Int) {
        switch command {
        case 25:
            // On to another place in the order of playing after this line: the number is written
            // as two decimal digits.
            guard count == 0 else { return }
            let to = Int(data & 15) + Int(data >> 4) * 10
            if to < module.positions.count { jump = to }
        case 28:
            if count == 0, data & 15 != 0 { speed = Int16(data & 15) }
        case 31:
            if data <= 0x40 { volumes[v] = data } else { fade(v, data) }
        default:
            break
        }
    }

    // MARK: Split voices

    /// Gives a track of a split voice the note it has on the line last read. Nothing is said to
    /// the chip: the mixing takes the note up.
    private mutating func strikeMixed(_ lane: inout Lane, _ track: Int) {
        let cell = cells[track]
        guard cell.note != 0, cell.note <= 36, cell.instrument < OktalyzerModule.instrumentCount else { return }
        let instrument = module.instruments[Int(cell.instrument)]
        guard let place = instrument.place, instrument.use != .whole else { return }
        lane.place = place
        lane.left = instrument.length
        lane.note = Int16(cell.note) - 1
        lane.base = lane.note
        lane.struck = true
        playedNote = true
    }

    /// Carries out the command of a track of a split voice.
    private mutating func commandMixed(_ lane: inout Lane, _ track: Int, voice v: Int) {
        let cell = cells[track]
        let data = Int16(cell.data)
        switch cell.command {
        case 10, 11, 12:
            if let by = arpeggio(cell.command, cell.data) { lane.note = lane.base &+ by }
        case 13, 21:
            guard cell.command == 13 || count == 0 else { return }
            lane.base &-= data
            lane.note &-= data
        case 17, 30:
            guard cell.command == 30 || count == 0 else { return }
            lane.base &+= data
            lane.note &+= data
        case 15:
            if count == 0 { paula.setLightFilter(cell.data != 0) }
        case 25, 28, 31:
            shared(cell.command, cell.data, voice: v)
        default:
            break
        }
    }

    /// How much of a track's sample is left, in words: as much of that number as the routine looks at.
    private static func wordsLeft(_ lane: Lane) -> UInt16 {
        UInt16(truncatingIfNeeded: lane.left >> 1)
    }

    /// Takes so many words from what a track has left: or ends its note, if it has not got them.
    private static func take(_ words: UInt16, from lane: inout Lane, to place: Int) {
        let had = wordsLeft(lane)
        if had < words {
            lane.place = nil
            lane.left = 0
            lane.note = 0
            lane.base = 0
        } else {
            lane.place = place
            lane.left = ((lane.left >> 1) & 0xFFFF_0000 | UInt32(had - words)) << 1
        }
    }

    @inline(__always) private func sample(_ at: Int) -> Int8 {
        at >= 0 && at < module.silence ? module.memory[at] : 0
    }

    /// Copies so many words of a track's sample into what is being mixed, or as many as it has
    /// left, with silence after them. Returns where in the sample it got to.
    private func copy(_ lane: Lane, from: Int, into out: UnsafeMutablePointer<Int8>, words: Int) -> Int {
        let have = min(Int(Self.wordsLeft(lane)), words)
        for i in 0 ..< have * 2 { out[i] = sample(from + i) }
        for i in have * 2 ..< words * 2 { out[i] = 0 }
        return from + have * 2
    }

    /// How far a stretch of bytes swings, for the lights.
    private static func swing(_ bytes: UnsafeMutablePointer<Int8>, _ count: Int) -> Float {
        var low: Int8 = 127, high: Int8 = -128
        for i in 0 ..< count {
            low = min(low, bytes[i])
            high = max(high, bytes[i])
        }
        return high > low ? Float(Int(high) - Int(low)) : 0
    }

    private static func kept(_ note: Int16) -> Int16 {
        max(0, min(Int16(highestMixed), note))
    }

    /// The note whose period a split voice will be played at when its tracks are next mixed: the
    /// one track's that is playing, or the higher of the two.
    private func leadingNote(_ v: Int) -> Int {
        let first = voices[v].lanes.0, second = voices[v].lanes.1
        if first.place == nil { return second.place == nil ? 0 : Int(Self.kept(second.note)) }
        if second.place == nil { return Int(Self.kept(first.note)) }
        return Int(max(Self.kept(first.note), Self.kept(second.note)))
    }

    /// Mixes a tick's worth of a split voice's two tracks into the stretch of memory the voice is
    /// to play after the one it has been given.
    /// - Parameter extra: a word, if the chip has run ahead, and otherwise nothing.
    private mutating func mix(_ v: Int, extra: Int) {
        let out = module.memory + module.mixPlace(v, mixBuffer)
        var first = voices[v].lanes.0, second = voices[v].lanes.1
        let loudness = Float(min(64, volumes[v] & 127)) / (64 * 256)
        first.swing = 0
        second.swing = 0
        if first.place == nil || second.place == nil {
            // One track, or neither: the voice plays that track's note as it is.
            if first.place == nil {
                mixAlone(v, &second, into: out, extra: extra, loudness)
            } else {
                mixAlone(v, &first, into: out, extra: extra, loudness)
            }
        } else {
            // Both: the voice plays at the period of the higher note, and the lower is stretched to it.
            // (Which is the higher is asked of the notes as they are, before they are brought
            // within what a split voice can play.)
            let firstLeads = first.note >= second.note
            first.note = Self.kept(first.note)
            second.note = Self.kept(second.note)
            if firstLeads {
                mixPair(v, leader: &first, other: &second, into: out, extra: extra, loudness)
            } else {
                mixPair(v, leader: &second, other: &first, into: out, extra: extra, loudness)
            }
        }
        voices[v].lanes = (first, second)
        voices[v].hasMixed = true
        if record != nil {
            var bytes: [Int8] = []
            for i in 0 ..< voices[v].mixedWords * 2 { bytes.append(out[i]) }
            record!.mixed[v] = bytes
        }
    }

    private mutating func mixAlone(_ v: Int, _ lane: inout Lane, into out: UnsafeMutablePointer<Int8>, extra: Int, _ loudness: Float) {
        lane.note = Self.kept(lane.note)
        guard let place = lane.place else {
            // Silence is mixed as the lowest note is.
            voices[v].mixedPeriod = periods[0]
            voices[v].mixedWords = words(ofNote: 0) + extra
            for i in 0 ..< voices[v].mixedWords * 2 { out[i] = 0 }
            return
        }
        let want = words(ofNote: Int(lane.note)) + extra
        voices[v].mixedPeriod = periods[Int(lane.note)]
        voices[v].mixedWords = want
        let to = copy(lane, from: place, into: out, words: want)
        lane.swing = Self.swing(out, want * 2) * loudness
        Self.take(UInt16(want), from: &lane, to: to)
    }

    private mutating func mixPair(_ v: Int, leader: inout Lane, other: inout Lane, into out: UnsafeMutablePointer<Int8>, extra: Int,
                                  _ loudness: Float) {
        let period = periods[Int(leader.note)], slower = periods[Int(other.note)]
        let want = words(ofNote: Int(leader.note)) + extra
        voices[v].mixedPeriod = period
        voices[v].mixedWords = want

        if let place = other.place {
            if period == slower {
                // Two notes the same: the other's sample is taken as it is, too.
                let to = copy(other, from: place, into: out, words: want)
                Self.take(UInt16(want), from: &other, to: to)
            } else {
                // How many of its bytes go to a byte of the leader's, in 65,536ths; and so how many
                // words of it this tick needs. A track that has not that many left plays none of
                // them: it is silent from here, though its note is not over until the leader's is.
                let step = UInt16(truncatingIfNeeded: (UInt32(period) << 16) / UInt32(slower))
                let needed = UInt16(truncatingIfNeeded: (UInt32(step) &* UInt32(want)) >> 16)
                if needed > Self.wordsLeft(other) {
                    for i in 0 ..< want * 2 { out[i] = 0 }
                    other.left = ((other.left >> 1) & 0xFFFF_0000) << 1
                } else {
                    var from = place
                    var fraction: UInt16 = 0
                    var byte: Int8 = 0
                    for i in 0 ..< want * 2 {
                        let (after, borrowed) = fraction.subtractingReportingOverflow(step)
                        fraction = after
                        if borrowed {
                            byte = sample(from)
                            from += 1
                        }
                        out[i] = byte
                    }
                    // (It always goes on from an even place.)
                    let used = (from - place + 1) >> 1
                    Self.take(UInt16(truncatingIfNeeded: used), from: &other, to: place + used * 2)
                }
            }
            other.swing = Self.swing(out, want * 2) * loudness
        }

        // The leader's sample is added: four bytes at a time as one number, for as much of it as
        // is a multiple of eight words, and then two at a time.
        guard let place = leader.place else { return }
        let have = min(Int(Self.wordsLeft(leader)), want)
        var low: Int8 = 127, high: Int8 = -128
        for i in 0 ..< have * 2 {
            let byte = sample(place + i)
            low = min(low, byte)
            high = max(high, byte)
        }
        leader.swing = high > low ? Float(Int(high) - Int(low)) * loudness : 0
        let longs = (have - have % 8) / 2
        for i in 0 ..< longs {
            var sum: UInt32 = 0, add: UInt32 = 0
            for k in 0 ..< 4 {
                sum = sum << 8 | UInt32(UInt8(bitPattern: out[i * 4 + k]))
                add = add << 8 | UInt32(UInt8(bitPattern: sample(place + i * 4 + k)))
            }
            sum &+= add
            for k in 0 ..< 4 { out[i * 4 + k] = Int8(bitPattern: UInt8(truncatingIfNeeded: sum >> UInt32((3 - k) * 8))) }
        }
        for i in longs * 2 ..< have {
            let sum = (UInt16(UInt8(bitPattern: out[i * 2])) << 8 | UInt16(UInt8(bitPattern: out[i * 2 + 1])))
                &+ (UInt16(UInt8(bitPattern: sample(place + i * 2))) << 8 | UInt16(UInt8(bitPattern: sample(place + i * 2 + 1))))
            out[i * 2] = Int8(bitPattern: UInt8(sum >> 8))
            out[i * 2 + 1] = Int8(bitPattern: UInt8(truncatingIfNeeded: sum))
        }
        Self.take(UInt16(want), from: &leader, to: place + have * 2)
    }

    /// When in a tick a split voice is told its period, and when the routine then looks to see
    /// whether the chip has reached its last word, in clocks from the start of the tick.
    private static let periodWritten = 0, interruptsRead = 15
    /// And when, on the first tick, the chip begins the silence it starts on.
    private static let chipBegins = 454

    /// Whether the chip has come to the last word of the stretch a split voice is playing, as a
    /// tick begins and the voice is told its next period: if it has, it is running ahead, and the
    /// stretch that is mixed on this tick is made a word longer.
    ///
    /// The chip is not asked. Its time is kept here in whole clocks, as the Amiga's was: each byte
    /// lasts as many clocks as the period the chip had when the byte began.
    /// - Parameter newPeriod: what the voice is told on this tick; nil if it is told nothing.
    private mutating func chipIsAhead(_ v: Int, newPeriod: Int?) -> Bool {
        var next = voices[v].nextByte, bytes = voices[v].bytesToLastWord
        let old = max(1, voices[v].chipPeriod), new = max(1, newPeriod ?? voices[v].chipPeriod)
        // The bytes that begin before the new period is written are of the old one.
        if next < Self.periodWritten, bytes > 0 {
            let before = min(bytes, (Self.periodWritten - next + old - 1) / old)
            next += before * old
            bytes -= before
        }
        guard newPeriod != nil else {
            // (Before anything has been mixed there is nothing to come to the end of.)
            voices[v].nextByte = next - Self.tickClocks
            voices[v].bytesToLastWord = bytes
            return false
        }
        // From where its last word begins the chip has that word to play, and then all but the
        // last word of the stretch it was given on the tick before.
        let lastWord: Int
        if bytes == 0 {
            lastWord = next
            bytes = voices[v].mixedWords * 2
            if next < Self.periodWritten {
                let before = min(bytes, (Self.periodWritten - next + old - 1) / old)
                next += before * old
                bytes -= before
            }
        } else {
            lastWord = next + bytes * new
            next = lastWord
            bytes = voices[v].mixedWords * 2
        }
        voices[v].nextByte = next - Self.tickClocks
        voices[v].bytesToLastWord = bytes
        voices[v].chipPeriod = new
        return lastWord < Self.interruptsRead
    }

    /// Half way through a tick's sound: the split voices are told where to go on from when they
    /// finish what they are playing, which is what was mixed at the start of the tick. (Oktalyzer
    /// waited until the chip had begun the last word of what it was playing, and told it then. But
    /// the chip here keeps time by itself, and may be a sample early or late in getting there: so
    /// it is told in the middle, where it cannot be mistaken about which stretch is meant.)
    mutating func halfTick() {
        for v in 0 ..< 4 where voices[v].split && voices[v].hasMixed {
            paula.setLocation(v, module.mixPlace(v, mixBuffer))
            paula.setLength(v, UInt16(voices[v].mixedWords))
        }
    }

    // MARK: Lines

    /// Where a line of a place is in the tables that have an entry for every line; nil if it has none.
    private func rowIndex(_ position: Int, _ line: Int) -> Int? {
        guard position >= 0, position < module.positions.count, line >= 0, line < module.lines(at: position) else { return nil }
        return module.firstRowOfPosition[position] + line
    }

    /// Moves the tune on a line and reads it. Returns false if the line has been played before, or
    /// the tune has run off its end: the pass through the tune is then over.
    private mutating func nextLine() -> Bool {
        count = 0
        line += 1
        var tries = 0
        while jump >= 0 || line >= module.lines(at: position) {
            line = 0
            if jump >= 0 {
                position = jump
                jump = -1
            } else {
                position += 1
            }
            if position >= module.positions.count {
                position = 0
                speed = Int16(truncatingIfNeeded: module.speed)
                wrapped = true
            }
            // An order with nothing in it to play would be gone round for ever.
            tries += 1
            if tries > module.positions.count + 1 {
                stopped = true
                return false
            }
        }
        for track in 0 ..< module.trackCount { cells[track] = module.cell(position: position, line: line, track: track) }

        var more = true
        if let row = rowIndex(position, line) {
            let seen = visited[row]
            if !seen, !wrapped, !metEarlierSong, let firstPlayedBy, firstPlayedBy[row] < songNumber {
                // On into what a song before this one played, which from here is part of this one.
                metEarlierSong = true
                ledIntoEarlierSong = true
            }
            if seen || wrapped {
                wrapped = false
                visited.update(repeating: false, count: max(1, module.rowsInAll))
                more = false
            }
            visited[row] = true
            if let firstPlayedBy, firstPlayedBy[row] == ModuleSongs.unplayed { firstPlayedBy[row] = songNumber }
            ordersPlayed[position] = true
        }
        return more
    }

    // MARK: Ticks

    /// One tick of the player's timer. False when the tick is the last of a pass through the tune:
    /// the line it read has been played before, or the tune has run off its end.
    mutating func runTick() -> Bool {
        if record != nil { record = OktalyzerTick() }
        guard !stopped else { return true }
        let more = tick()
        ticksRun += 1
        if record != nil {
            record!.clocks = Self.tickClocks
            record!.position = position
            record!.line = line
            record!.tickOfLine = Int(count)
        }
        return more
    }

    private mutating func tick() -> Bool {
        if !begun {
            begun = true
            paula.start(voices: 15)
            for v in 0 ..< 4 {
                voices[v].nextByte = Self.chipBegins
                voices[v].bytesToLastWord = (Self.openingWords - 1) * 2
            }
        }

        // Each split voice is told the period of what was mixed for it on the tick before, which
        // it is about to begin; and it is seen whether it has run ahead.
        var ahead: InlineArray<4, Bool> = [false, false, false, false]
        for v in 0 ..< 4 where voices[v].split {
            if voices[v].hasMixed { write(v, .period, Int(voices[v].mixedPeriod)) }
            ahead[v] = chipIsAhead(v, newPeriod: voices[v].hasMixed ? Int(voices[v].mixedPeriod) : nil)
        }

        // The whole voices that were given a note on the tick before are set going, and told
        // where to go on from when they reach its end.
        if pending != 0 {
            paula.start(voices: pending)
            for v in 0 ..< 4 where pending & (1 << v) != 0 {
                write(v, .location, voices[v].loop)
                write(v, .length, Int(voices[v].loopWords))
            }
            pending = 0
        }
        if count == 0 {
            for v in 0 ..< 4 where !voices[v].split { strike(v) }
        }
        for v in 0 ..< 4 where !voices[v].split { command(v) }
        told = volumes
        for v in 0 ..< 4 { write(v, .volume, Int(told[v])) }

        // The next line is read on the last tick of this one, and the split voices take it up at
        // once: what is mixed now is not heard until the whole voices have begun their notes.
        var more = true
        count &+= 1
        if speed <= count {
            more = nextLine()
            if stopped { return true }
            for v in 0 ..< 4 where voices[v].split {
                var lanes = voices[v].lanes
                strikeMixed(&lanes.0, voices[v].track)
                strikeMixed(&lanes.1, voices[v].track + 1)
                voices[v].lanes = lanes
            }
        }
        for v in 0 ..< 4 where voices[v].split {
            var lanes = voices[v].lanes
            commandMixed(&lanes.0, voices[v].track, voice: v)
            commandMixed(&lanes.1, voices[v].track + 1, voice: v)
            voices[v].lanes = lanes
        }

        mixBuffer = (mixBuffer + 1) % OktalyzerModule.mixBuffers
        var seen = 0
        for v in 0 ..< 4 where voices[v].split {
            var extra = ahead[v] ? 1 : 0
            if let wordsSeen, ticksRun < wordsSeen.count, seen < wordsSeen[ticksRun].count {
                // (What the routine was seen to mix is a word more than the note's own, or it is not.)
                extra = wordsSeen[ticksRun][seen] == words(ofNote: leadingNote(v)) + 1 ? 1 : 0
                seen += 1
            }
            mix(v, extra: extra)
            if record != nil {
                record!.writes.append(OktalyzerTick.Write(voice: v, register: .location, value: -1))
                record!.writes.append(OktalyzerTick.Write(voice: v, register: .length, value: voices[v].mixedWords))
            }
        }
        return more
    }

    // MARK: The lights

    /// The side each track is on, -1 for the left and 1 for the right: that of the voice it is
    /// played on, which two tracks may share.
    func sides(into sides: UnsafeMutablePointer<Float>) {
        for v in 0 ..< 4 {
            sides[voices[v].track] = Paula.side(ofVoice: v)
            if voices[v].split { sides[voices[v].track + 1] = Paula.side(ofVoice: v) }
        }
    }

    /// How far each track has swung since this was last asked, where 1 is as far as a voice at
    /// full volume can.
    mutating func takeLevels(into levels: inout [Float]) {
        var alone = [Float](repeating: 0, count: 4)
        paula.takeLevels(into: &alone)
        for v in 0 ..< 4 {
            if voices[v].split {
                levels[voices[v].track] = voices[v].lanes.0.swing
                levels[voices[v].track + 1] = voices[v].lanes.1.swing
            } else {
                levels[voices[v].track] = alone[v]
            }
        }
    }

    /// The pitch of a track of a split voice.
    private func pitch(_ lane: Lane) -> Float {
        guard lane.place != nil else { return 0 }
        return ChannelPitch.note(ofRate: Paula.clockHz / Double(periods[Int(Self.kept(lane.note))]))
    }

    /// The pitch of each track's note, and whether one has begun since this was last asked.
    mutating func takeNotes(into notes: inout TickNotes, chip: inout TickNotes) {
        paula.takeNotes(into: &chip)
        for v in 0 ..< 4 {
            let track = voices[v].track
            if voices[v].split {
                notes.pitches[track] = pitch(voices[v].lanes.0)
                notes.pitches[track + 1] = pitch(voices[v].lanes.1)
                if voices[v].lanes.0.struck { notes.struck[track] = true }
                if voices[v].lanes.1.struck { notes.struck[track + 1] = true }
                voices[v].lanes.0.struck = false
                voices[v].lanes.1.struck = false
            } else {
                // (A whole voice plays silence, over and over, until it is given a note.)
                notes.pitches[track] = voices[v].period > 0 ? chip.pitches[v] : 0
                if chip.struck[v], ticksRun > 1 { notes.struck[track] = true }
            }
            chip.struck[v] = false
        }
    }
}
