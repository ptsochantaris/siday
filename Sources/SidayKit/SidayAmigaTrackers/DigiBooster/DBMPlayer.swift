// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Ported from libdigibooster3 1.2, the replayer of DigiBooster 3 that its makers published
// (copyright (c) 2014 Grzegorz Kraszewski, under the two-clause BSD licence: see THIRD-PARTY.md):
// its player.c, with the same whole numbers, and with its slips kept where a file can be heard to
// depend on them. What is done otherwise, and why, is said where it is done.

/// Plays a DBM file a tick at a time, as DigiBooster 3's replayer does.
///
/// DigiBooster keeps everything that slides in units of the speed, so that a slide can move by less
/// than a step a tick and still come to whole steps by the end of its row: a volume is so many
/// sixty-fourths times the ticks to a row, a pitch so many eighths of a semitone times the same,
/// and a fine slide adds its one step a row a little at a time, where other trackers add it at once.
/// A pitch goes by a table of the eighths of a semitone and a table for each speed of the parts of
/// one. The slides move on every tick of a row, the first among them, and on into the next row's
/// first. Notes and commands are as ProTracker has them, more or less, with DigiBooster's own:
/// global volume and its slide, a panning slide, playing a sample backwards, two sustains to an
/// envelope, and an echo for each track.
final class DBMPlayer {
    final class Track {
        /// The instrument it plays, from 1; nought for none.
        var instrument = 0
        var isOn = false
        var muted = false
        /// Whether it has a sample to play: the replayer's "instrument chain".
        var hasChain = false
        var gainLeft: Int16 = 0, gainRight: Int16 = 0
        // These three are in units of the speed (see the player).
        var volume: Int32 = 0, panning: Int32 = 0, pitch: Int32 = 0
        var volumeDelta: Int16 = 0, panningDelta: Int16 = 0, pitchDelta: Int16 = 0, slideToNoteDelta: Int16 = 0
        var arpeggio1: Int16 = 0, arpeggio2: Int16 = 0
        /// Not in units of the speed.
        var slideTarget: Int16 = 576
        var vibratoSpeed: Int16 = 0, vibratoDepth: Int16 = 0, vibratoCounter: Int16 = 0
        var volumeEnvelope = EnvelopeState(), panningEnvelope = EnvelopeState()
        var volumeEnvelopeNow: Int16 = 0, panningEnvelopeNow: Int16 = 0
        var triggerCounter: Int32 = 0x7FFF_FFFF, cutCounter: Int32 = 0x7FFF_FFFF, retrigger: Int32 = 0, triggerOffset: Int32 = 0
        /// Ticks until the key is let go, by DigiBooster Pro's command for it.
        var keyOffCounter: Int32 = 0x7FFF_FFFF
        var playBackwards = false
        // The last of each command's values, for a nought to mean the same again.
        var oldVolumeSlide: UInt8 = 0, oldPanningSlide: UInt8 = 0, oldSlideUp: UInt8 = 0, oldSlideDown: UInt8 = 0
        var oldSlideSpeed: UInt8 = 0, oldVolumeSlide5: UInt8 = 0, oldVibrato: UInt8 = 0, oldVibrato6: UInt8 = 0
        var echoDelay: Int32 = 0, echoFeedback: Int32 = 0, echoMix: Int32 = 0, echoCross: Int32 = 0
        var voice: DBMVoice?
        var echo: DBMEcho?
        /// The echo's kind, whether or not its sound is being made: see `DBMEcho.type`.
        var echoType = 0
        /// The pitch heard on the last tick, in eighths of a semitone: 384 for the C of the fourth
        /// octave, which is played at the instrument's own rate.
        var heardPitch: Int32 = 0
        var struck = false
        /// Where it is between the speakers, from -1 to 1.
        var side: Float = 0
    }

    struct EnvelopeState {
        var index: UInt16 = 0
        var tickCounter: UInt16 = 0
        var section: UInt16 = 0
        var xDelta: Int16 = 0, yDelta: Int16 = 0, yStart: Int16 = 0, previous: Int16 = 0
        var sustainA: UInt16 = 0, sustainB: UInt16 = 0, loopEnd: UInt16 = 0
    }

    /// What is done when a song runs off the end of its list of patterns.
    enum ListEnd {
        /// It goes on from the top, as DigiBooster does.
        case goesRound
        /// It stops, as the replayer does when it is asked to play a song once: after the first row
        /// of the list, which it has begun on by then.
        case stopsAsReplayer
        /// It stops there, for a song that starts part of the way down a list and would go on into
        /// another (see `ModuleSongs`).
        case stops
    }

    let module: DBMModule
    let tracks: [Track]
    private let rate: Int32
    private let forSound: Bool
    private let listEnd: ListEnd
    /// True for two things the replayer does not do: an echo that starts as the file sets it (see
    /// `echoOn`), and DigiBooster Pro's command to let the key go (see `effect`). False to play
    /// exactly as the replayer does.
    private let asTheFileAsks: Bool

    private let song: DBMModule.Song
    private(set) var order: Int
    private(set) var pattern: Int
    private(set) var row = 0
    private(set) var tick = 0
    private(set) var speed: Int32 = 6
    private(set) var tempo: Int32 = 125
    /// How many samples the tick just begun lasts.
    private(set) var tickSamples = 0
    private var tickRemainder = 0
    private var patternDelay: Int32 = 0
    private var moduleEnd = false
    private var breakTo: Int32 = -1, jumpTo: Int32 = -1, looping: Int32 = -1
    private var loopCounter = 0, loopOrder = 0, loopRow = 0
    private var globalVolume: Int16 = 64, globalVolumeSlide: Int16 = 0
    private var oldGlobalVolumeSlide: UInt8 = 0
    private var minVolume: Int16 = 0, maxVolume: Int16 = 384, minPanning: Int16 = -768, maxPanning: Int16 = 768
    private var minPitch: Int16 = 576, maxPitch: Int16 = 4608
    private var arpeggioCounter = 0
    /// The settings of the echo the whole module shares, as the file and its commands have left them.
    private var sharedEcho: (delay: Int32, feedback: Int32, mix: Int32, cross: Int32)
    /// True once the song has stopped: no more rows are read.
    private(set) var stopped = false
    /// True if the tick just played is the first of a row's ticks, after the song has stopped: where
    /// the replayer stops making sound.
    private(set) var stopTick = false
    private var stopNow = false

    /// How far each side is put off for each panning (see `DBMVoice.phaseTable`), which the voices
    /// point into.
    private let phases: Memory<Int16>
    private let silence = Memory<Int16>(capacity: 1)
    /// The most frames that are mixed at once: more than the longest tick, at the slowest tempo.
    static let mostFrames = 4096
    private let premix = Memory<Int16>(capacity: mostFrames * 2)
    /// Where each track's sound is kept for its scope, if it is wanted: its instrument's, after its
    /// echo and its volume and before it is added to the others. A track at its loudest swings one
    /// either side of nothing.
    var waves: ChannelWaves?

    /// For telling the file's songs apart: see `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>?
    private let rowBase: [Int]
    private let songNumber: UInt8
    private(set) var ordersPlayed: [Bool]
    private(set) var playedNote = false
    private(set) var ledIntoEarlierSong = false
    /// The rows this song has played since it last came round, by `rowBase`.
    private let visited: Memory<Bool>?
    /// The row read last, by its place in the list and its number.
    private(set) var lastOrder = 0, lastRow = 0
    /// False once the song has come round to a row it has played.
    private var more = true

    /// Where each place in a song's list begins among the rows of them all, and (last) how many rows
    /// that is: for telling which song played each row first. Nil for a list too long to tell.
    static func rowBase(_ module: DBMModule, song: Int) -> [Int]? {
        var base: [Int] = []
        var total = 0
        for pattern in module.songs[song].orders {
            base.append(total)
            total += module.patterns[module.pattern(pattern)].rows
            if total > 1 << 23 { return nil }
        }
        base.append(total)
        return base
    }

    /// - Parameters:
    ///   - song: which of the file's songs, and `order` where in its list to start.
    ///   - forSound: false for a pass in silence, which makes no sound and so takes no memory for it.
    ///   - rowBase: the song's rows (see `rowBase(_:song:)`), for knowing when it comes round; none
    ///     for not knowing.
    ///   - firstPlayedBy: for a file of several songs, which of them first played each row.
    init(_ module: DBMModule, song: Int, order: Int = 0, rate: Int = outputSampleRate, forSound: Bool = true, listEnd: ListEnd = .goesRound,
         asTheFileAsks: Bool = true, rowBase: [Int]? = nil, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil, songNumber: UInt8 = 0) {
        self.module = module
        self.rate = Int32(rate)
        self.forSound = forSound
        self.listEnd = listEnd
        self.asTheFileAsks = asTheFileAsks
        self.song = module.songs[song]
        self.order = min(order, self.song.orders.count - 1)
        pattern = module.pattern(self.song.orders[self.order])
        self.firstPlayedBy = rowBase == nil ? nil : firstPlayedBy
        self.rowBase = rowBase ?? []
        if let rows = rowBase?.last {
            let visited = Memory<Bool>(capacity: max(1, rows))
            visited.pointer.initialize(repeating: false, count: max(1, rows))
            self.visited = visited
        } else {
            visited = nil
        }
        self.songNumber = songNumber
        ordersPlayed = [Bool](repeating: false, count: self.song.orders.count)
        let table = DBMVoice.phaseTable(rate: rate)
        phases = Memory<Int16>(capacity: table.count)
        for (i, value) in table.enumerated() { phases.pointer[i] = value }
        sharedEcho = (module.echoDelay, module.echoFeedback, module.echoMix, module.echoCross)
        silence.pointer[0] = 0
        tracks = (0 ..< module.tracks).map { _ in Track() }
        for (index, track) in tracks.enumerated() {
            track.echoDelay = module.echoDelay
            track.echoFeedback = module.echoFeedback
            track.echoMix = module.echoMix
            track.echoCross = module.echoCross
            if module.echoOn[index] { echoOn(track, type: 1) }
        }
    }

    // MARK: The DSP of a track

    private func makeVoice(_ track: Track) -> DBMVoice {
        if let voice = track.voice { return voice }
        let voice = DBMVoice(phases: phases.pointer, silence: silence.pointer)
        track.voice = voice
        return voice
    }

    private func echoOn(_ track: Track, type: Int) {
        guard track.echoType == 0 else { return }
        track.echoType = type
        guard forSound else { return }
        let echo = DBMEcho(rate: Int(rate), type: type)
        // The replayer starts every echo as DigiBooster 3 does by default, whatever the file says,
        // and goes by the file's settings only once a command has changed them: it reads them, and
        // gives them to the tracks, and does not give them to the echo. Here an echo starts as the
        // file has it, unless what is wanted is what the replayer does.
        if asTheFileAsks {
            if type == 1 {
                echo.set(delay: sharedEcho.delay, feedback: sharedEcho.feedback, mix: sharedEcho.mix, cross: sharedEcho.cross)
            } else {
                echo.set(delay: track.echoDelay, feedback: track.echoFeedback, mix: track.echoMix, cross: track.echoCross)
            }
        }
        track.echo = echo
    }

    private func echoOff(_ track: Track, type: Int) {
        guard track.echoType == type, type != 0 else { return }
        track.echoType = 0
        track.echo = nil
    }

    private func changeEcho(_ track: Track) {
        if track.echoType == 2 {
            track.echo?.set(delay: track.echoDelay, feedback: track.echoFeedback, mix: track.echoMix, cross: track.echoCross)
        } else {
            sharedEcho = (track.echoDelay, track.echoFeedback, track.echoMix, track.echoCross)
            for other in tracks where other.echoType == 1 {
                other.echoFeedback = track.echoFeedback
                other.echoMix = track.echoMix
                other.echoCross = track.echoCross
                other.echoDelay = track.echoDelay
                other.echo?.set(delay: track.echoDelay, feedback: track.echoFeedback, mix: track.echoMix, cross: track.echoCross)
            }
        }
    }

    // MARK: Instruments and notes

    private func trigger(_ track: Track) {
        track.volumeEnvelopeNow = 16384
        track.panningEnvelopeNow = 0
        track.volumeEnvelope.section = 0
        track.volumeEnvelope.tickCounter = 0
        if Int(track.volumeEnvelope.index) < module.volumeEnvelopes.count {
            let envelope = module.volumeEnvelopes[Int(track.volumeEnvelope.index)]
            track.volumeEnvelope.sustainA = envelope.sustainA
            track.volumeEnvelope.sustainB = envelope.sustainB
            track.volumeEnvelope.loopEnd = envelope.loopLast
        }
        track.panningEnvelope.section = 0
        track.panningEnvelope.tickCounter = 0
        if Int(track.panningEnvelope.index) < module.panningEnvelopes.count {
            let envelope = module.panningEnvelopes[Int(track.panningEnvelope.index)]
            track.panningEnvelope.sustainA = envelope.sustainA
            track.panningEnvelope.sustainB = envelope.sustainB
            track.panningEnvelope.loopEnd = envelope.loopLast
        }
        if forSound, track.hasChain { track.voice?.trigger(backwards: track.playBackwards, offset: track.triggerOffset) }
        track.vibratoCounter = 0
        track.triggerOffset = 0
        track.isOn = true
        track.struck = true
        playedNote = true
    }

    /// Gives a track an instrument, as a note beside one does, which starts its sample afresh.
    private func setInstrument(_ track: Track, _ number: Int) {
        track.hasChain = false
        track.instrument = 0
        track.isOn = false
        // (A note of an instrument the file has not got is passed over.)
        guard number <= module.instruments.count else { return }
        let instrument = module.instruments[number - 1]
        track.volumeEnvelope.index = instrument.volumeEnvelope
        track.panningEnvelope.index = instrument.panningEnvelope
        let sample = instrument.sample
        guard sample < module.sampleLengths.count, module.sampleLengths[sample] > 0 else { return }
        if forSound {
            makeVoice(track).start(module.sampleData.pointer + module.sampleStarts[sample], frames: module.sampleLengths[sample],
                                   loopStart: instrument.loopStart, loopLength: instrument.loopLength, loopType: instrument.loopType)
        }
        track.hasChain = true
        track.instrument = number
    }

    /// The rate the track's instrument is to be played at for a pitch, in units of the speed.
    private func setPitch(_ track: Track, _ value: Int32) {
        guard track.instrument != 0 else { return }
        track.heardPitch = value / speed
        guard forSound, let voice = track.voice else { return }
        let instrument = module.instruments[track.instrument - 1]
        // (As the replayer works it out, oddities and all: the pitch is cut to sixteen bits, and a
        // pitch below the lowest, which a vibrato can take it to, comes out as many octaves up as
        // the last six bits of the count say, as the machines this is compared on have it.)
        let pitch = Int32(UInt16(truncatingIfNeeded: value))
        let fine = Int(pitch % speed)
        var tune = UInt16(truncatingIfNeeded: pitch / speed) &- 96
        var octave = 0
        while tune >= 96 {
            tune -= 96
            octave += 1
        }
        let alpha = UInt64(DBMTables.smoothSlides[Int(speed)][fine])
        let beta = UInt64(DBMTables.scale[Int(tune)])
        var step = UInt64(instrument.c3Frequency) &* beta &* alpha
        step >>= UInt64((19 - octave) & 63)
        voice.step = UInt32(truncatingIfNeeded: step / UInt64(rate))
    }

    private func defaultVolume(_ track: Track) {
        guard track.instrument != 0 else { return }
        let instrument = module.instruments[track.instrument - 1]
        track.volume = Int32(truncatingIfNeeded: instrument.volume) &* speed
        track.panning = instrument.panning &* speed
        track.volumeEnvelope.section = 0
        track.volumeEnvelope.tickCounter = 0
        track.panningEnvelope.section = 0
        track.panningEnvelope.tickCounter = 0
    }

    // MARK: Where the song goes

    private func resetDelayed() {
        breakTo = -1
        jumpTo = -1
        looping = -1
        moduleEnd = false
    }

    private func applyDelayed() {
        let orders = song.orders
        if jumpTo != -1 {
            order = Int(jumpTo) < orders.count ? Int(jumpTo) : 0
            pattern = patternAt(order)
            row = 0
        }
        if breakTo != -1 {
            if jumpTo == -1, row > 0 {
                order += 1
                if order >= orders.count { order = 0 }
            }
            pattern = patternAt(order)
            let rows = module.patterns[pattern].rows
            row = Int(breakTo) < rows ? Int(breakTo) : rows - 1
        }
        if looping != -1 {
            // (The rows a loop plays again have not been played for the last time.)
            if let visited, loopOrder <= lastOrder, lastOrder + 1 < rowBase.count {
                let from = rowBase[loopOrder] + loopRow, to = rowBase[lastOrder] + lastRow
                if from <= to { (visited.pointer + from).update(repeating: false, count: to - from + 1) }
            }
            order = loopOrder
            pattern = patternAt(order)
            row = loopRow
        }
        if moduleEnd { patternDelay = 0x7FFF_FFFF }
        resetDelayed()
    }

    private func patternAt(_ order: Int) -> Int {
        module.pattern(song.orders[order])
    }

    private func nextPattern() {
        order += 1
        if order >= song.orders.count {
            order = 0
            switch listEnd {
            case .goesRound: break
            case .stopsAsReplayer: moduleEnd = true
            case .stops: stopNow = true
            }
        }
        pattern = patternAt(order)
        row = 0
    }

    private func scanForSpeed() {
        for track in 0 ..< module.tracks {
            let cell = module.cell(pattern: pattern, row: row, track: track)
            if cell.command1 == 0x0F { setSpeed(cell.parameter1) }
            if cell.command2 == 0x0F { setSpeed(cell.parameter2) }
        }
    }

    /// Fxx: under 32 the speed, from 32 the tempo, and nought the end of the song.
    private func setSpeed(_ value: UInt8) {
        if value == 0 {
            patternDelay = 0x7FFF_FFFF
        } else if value < 0x20 {
            speed = Int32(value)
        } else {
            tempo = Int32(value)
        }
    }

    private func nextRow() {
        // A row this song has played already is where it comes round; one that a song before it
        // played first is where it goes on into that one.
        if order < ordersPlayed.count { ordersPlayed[order] = true }
        if let visited, order + 1 < rowBase.count, row < rowBase[order + 1] - rowBase[order] {
            let at = rowBase[order] + row
            if visited.pointer[at] {
                more = false
                visited.pointer.update(repeating: false, count: max(1, rowBase[rowBase.count - 1]))
            } else if let firstPlayedBy, firstPlayedBy[at] < songNumber {
                ledIntoEarlierSong = true
            }
            visited.pointer[at] = true
            if let firstPlayedBy, firstPlayedBy[at] == ModuleSongs.unplayed { firstPlayedBy[at] = songNumber }
        }
        lastOrder = order
        lastRow = row

        for (index, track) in tracks.enumerated() {
            let cell = module.cell(pattern: pattern, row: row, track: index)
            track.triggerCounter = 0x7FFF_FFFF
            track.cutCounter = 0x7FFF_FFFF
            track.retrigger = 0
            track.playBackwards = false
            track.triggerOffset = 0
            track.keyOffCounter = 0x7FFF_FFFF

            // A note beside an instrument starts it afresh; a note alone strikes the one there is;
            // an instrument alone sets its volume and panning. (Not with a slide to the note, which
            // only sets where it slides to.)
            let slides = cell.command1 == 3 || cell.command1 == 5 || cell.command2 == 3 || cell.command2 == 5
            if cell.instrument != 0, cell.octave != 0, !slides { setInstrument(track, Int(cell.instrument)) }
            if cell.octave != 0 {
                if cell.note < 12 {
                    let note = Int16((Int(cell.octave) * 12 + Int(cell.note)) << 3)
                    if !slides {
                        track.pitch = Int32(note) &* speed
                        track.triggerCounter = 0
                    } else {
                        track.slideTarget = note
                    }
                } else {
                    keyOff(track)
                }
            }
            if cell.instrument != 0 { defaultVolume(track) }
            if cell.command1 != 0 || cell.parameter1 != 0 { effect(track, cell.command1, cell.parameter1) }
            if cell.command2 != 0 || cell.parameter2 != 0 { effect(track, cell.command2, cell.parameter2) }
        }

        row += 1
        if row >= module.patterns[pattern].rows { nextPattern() }
    }

    /// The key let go: the envelopes go on past their sustains, and loop no more, in that order of
    /// the three. An instrument with no volume envelope is cut off. (The replayer takes its panning
    /// envelope away from it too, by a slip.)
    private func keyOff(_ track: Track) {
        if track.volumeEnvelope.index == DBMModule.noEnvelope {
            track.panningEnvelope.index = DBMModule.noEnvelope
            track.isOn = false
        }
        if track.volumeEnvelope.index != DBMModule.noEnvelope { Self.letGo(&track.volumeEnvelope) }
        if track.panningEnvelope.index != DBMModule.noEnvelope { Self.letGo(&track.panningEnvelope) }
    }

    private static func letGo(_ envelope: inout EnvelopeState) {
        if envelope.loopEnd <= envelope.sustainA, envelope.loopEnd <= envelope.sustainB {
            envelope.loopEnd = DBMModule.noEnvelope
        } else if envelope.sustainA <= envelope.sustainB {
            envelope.sustainA = DBMModule.noEnvelope
        } else {
            envelope.sustainB = DBMModule.noEnvelope
        }
    }

    // MARK: The commands

    private static func bcd(_ x: UInt8) -> Int32 {
        guard x >> 4 < 10, x & 15 < 10 else { return 0 }
        return Int32(x >> 4) * 10 + Int32(x & 15)
    }

    /// A volume slide's value: a step a tick up or down, or (with F beside it) a step a row.
    private func slide(_ delta: inout Int16, _ value: UInt8) {
        let up = Int32(value >> 4), down = Int32(value & 15)
        if up == 0 || down == 0 {
            if up != 0 { delta = Int16(truncatingIfNeeded: Int32(delta) &+ up &* speed) }
            if down != 0 { delta = Int16(truncatingIfNeeded: Int32(delta) &- down &* speed) }
        } else if down == 0xF {
            delta = Int16(truncatingIfNeeded: Int32(delta) &+ up)
        } else if up == 0xF {
            delta = Int16(truncatingIfNeeded: Int32(delta) &- down)
        }
    }

    private func effect(_ track: Track, _ command: UInt8, _ value: UInt8) {
        var value = value
        switch command {
        case 0x0:
            track.arpeggio1 = Int16(truncatingIfNeeded: Int32((value >> 4) << 3) &* speed)
            track.arpeggio2 = Int16(truncatingIfNeeded: Int32((value & 15) << 3) &* speed)
        case 0x1:
            if value == 0 { value = track.oldSlideUp } else { track.oldSlideUp = value }
            let by = value < 0xF0 ? Int32(value) &* speed : Int32(value & 15)
            track.pitchDelta = Int16(truncatingIfNeeded: Int32(track.pitchDelta) &+ by)
        case 0x2:
            if value == 0 { value = track.oldSlideDown } else { track.oldSlideDown = value }
            let by = value < 0xF0 ? Int32(value) &* speed : Int32(value & 15)
            track.pitchDelta = Int16(truncatingIfNeeded: Int32(track.pitchDelta) &- by)
        case 0x3:
            if value == 0 { value = track.oldSlideSpeed } else { track.oldSlideSpeed = value }
            slideToNote(track, Int32(value))
        case 0x4:
            if value == 0 { value = track.oldVibrato } else { track.oldVibrato = value }
            track.vibratoSpeed = Int16(value >> 4)
            track.vibratoDepth = Int16(truncatingIfNeeded: Int32(value & 15) &* speed)
        case 0x5:
            if value == 0 { value = track.oldVolumeSlide5 } else { track.oldVolumeSlide5 = value }
            slideToNote(track, Int32(track.oldSlideSpeed))
            slide(&track.volumeDelta, value)
        case 0x6:
            if value == 0 { value = track.oldVibrato6 } else { track.oldVibrato6 = value }
            track.vibratoSpeed = Int16(track.oldVibrato >> 4)
            track.vibratoDepth = Int16(truncatingIfNeeded: Int32(track.oldVibrato & 15) &* speed)
            slide(&track.volumeDelta, value)
        case 0x8:
            track.panning = (Int32(value) - 128) &* speed
        case 0x9:
            track.triggerOffset = track.triggerOffset &+ Int32(value) << 8
        case 0xA:
            if value == 0 { value = track.oldVolumeSlide } else { track.oldVolumeSlide = value }
            slide(&track.volumeDelta, value)
        case 0xB:
            jumpTo = Int32(value)
        case 0xC:
            if value <= 0x40 { track.volume = Int32(value) &* speed }
        case 0xD:
            breakTo = Self.bcd(value)
        case 0xE:
            extended(track, value)
        case 0x10:
            if value <= 0x40 { globalVolume = Int16(value) }
        case 0x11:
            if value == 0 { value = oldGlobalVolumeSlide } else { oldGlobalVolumeSlide = value }
            let up = Int16(value >> 4), down = Int16(value & 15)
            if up == 0 || down == 0 {
                if up != 0 { globalVolumeSlide &+= up }
                if down != 0 { globalVolumeSlide &-= down }
            }
        case 0x14:
            // DigiBooster Pro's Kxx lets the key go so many ticks into the row, as a note to let it
            // go does at once. DigiBooster 3's replayer passes it over.
            if asTheFileAsks { track.keyOffCounter = Int32(value) }
        case 0x19:
            if value == 0 { value = track.oldPanningSlide } else { track.oldPanningSlide = value }
            let right = Int32(value >> 4), left = Int32(value & 15)
            // (A fine slide of panning is not in the replayer.)
            if right == 0 || left == 0 {
                if right != 0 { track.panningDelta = Int16(truncatingIfNeeded: Int32(track.panningDelta) &+ right &* speed) }
                if left != 0 { track.panningDelta = Int16(truncatingIfNeeded: Int32(track.panningDelta) &- left &* speed) }
            }
        case 0x1F:
            let what = value >> 4, onOff = value & 15
            if onOff == 0 {
                switch what {
                case 0: echoOn(track, type: 1)
                case 1: for other in tracks { echoOn(other, type: 1) }
                case 2: echoOn(track, type: 2)
                default: break
                }
            } else if onOff == 1 {
                switch what {
                case 0: echoOff(track, type: 1)
                case 1: for other in tracks { echoOff(other, type: 1) }
                case 2: echoOff(track, type: 2)
                default: break
                }
            }
        case 0x20:
            track.echoDelay = Int32(value)
            changeEcho(track)
        case 0x21:
            track.echoFeedback = Int32(value)
            changeEcho(track)
        case 0x22:
            track.echoMix = Int32(value)
            changeEcho(track)
        case 0x23:
            track.echoCross = Int32(value)
            changeEcho(track)
        default:
            break
        }
    }

    private func slideToNote(_ track: Track, _ by: Int32) {
        let target = Int16(truncatingIfNeeded: Int32(track.slideTarget) &* speed)
        if Int32(target) >= track.pitch {
            track.slideToNoteDelta = Int16(truncatingIfNeeded: Int32(track.slideToNoteDelta) &+ by &* speed)
        } else {
            track.slideToNoteDelta = Int16(truncatingIfNeeded: Int32(track.slideToNoteDelta) &- by &* speed)
        }
    }

    private func extended(_ track: Track, _ value: UInt8) {
        let x = Int32(value & 15)
        switch value >> 4 {
        case 0x1:
            track.pitch = track.pitch &+ x &* speed
            if track.pitch > Int32(maxPitch) { track.pitch = Int32(maxPitch) }
        case 0x2:
            track.pitch = track.pitch &- x &* speed
            if track.pitch < Int32(minPitch) { track.pitch = Int32(minPitch) }
        case 0x3:
            // (The replayer means "if there is a note on this row", and asks so of a number the
            // counter never has: so it is for every row.)
            track.playBackwards = true
        case 0x4:
            if value == 0x40 { track.isOn = false }
        case 0x6:
            if x != 0 {
                if loopCounter == 0 {
                    loopCounter = Int(x)
                    looping = 0
                } else {
                    loopCounter -= 1
                    if loopCounter > 0 {
                        looping = 0
                    } else {
                        loopCounter = 0
                        loopOrder = 0
                        loopRow = 0
                    }
                }
            } else if loopCounter == 0 {
                loopOrder = order
                loopRow = row
            }
        case 0x7:
            track.triggerOffset = track.triggerOffset &+ x << 16
        case 0x8:
            track.panning = ((x << 4) - 128) &* speed
        case 0x9:
            track.retrigger = x
        case 0xA:
            track.volume = track.volume &+ x &* speed
            if track.volume > Int32(maxVolume) { track.volume = Int32(maxVolume) }
        case 0xB:
            track.volume = track.volume &- x &* speed
            if track.volume < Int32(minVolume) { track.volume = Int32(minVolume) }
        case 0xC:
            track.cutCounter = x
        case 0xD:
            track.triggerCounter = x
        case 0xE:
            patternDelay = x
        default:
            break
        }
    }

    // MARK: Every tick

    private func postTick() {
        for track in tracks {
            track.volume = track.volume &+ Int32(track.volumeDelta)
            if track.volume > Int32(maxVolume) { track.volume = Int32(maxVolume) }
            if track.volume < Int32(minVolume) { track.volume = Int32(minVolume) }
            track.panning = track.panning &+ Int32(track.panningDelta)
            if track.panning > Int32(maxPanning) { track.panning = Int32(maxPanning) }
            if track.panning < Int32(minPanning) { track.panning = Int32(minPanning) }
            if track.slideToNoteDelta != 0 {
                let target = Int32(track.slideTarget) &* speed
                track.pitch = track.pitch &+ Int32(track.slideToNoteDelta)
                if track.slideToNoteDelta > 0 {
                    if track.pitch > target { track.pitch = target }
                } else if track.pitch < target {
                    track.pitch = target
                }
            }
            track.pitch = track.pitch &+ Int32(track.pitchDelta)
            if track.pitch > Int32(maxPitch) { track.pitch = Int32(maxPitch) }
            if track.pitch < Int32(minPitch) { track.pitch = Int32(minPitch) }
        }
        globalVolume &+= globalVolumeSlide
        if globalVolume > 64 {
            globalVolume = 64
        } else if globalVolume < 0 {
            globalVolume = 0
        }
    }

    private func doTriggers() {
        if asTheFileAsks {
            for track in tracks where track.keyOffCounter != 0x7FFF_FFFF {
                if track.keyOffCounter == 0 { keyOff(track) }
                track.keyOffCounter &-= 1
            }
        }
        for track in tracks where track.instrument != 0 {
            if track.triggerCounter == 0 {
                trigger(track)
                track.triggerCounter = track.retrigger
            }
            track.triggerCounter &-= 1
            // (A note cut leaves the note playing, at no volume.)
            if track.cutCounter <= 0 { track.volume = 0 }
            track.cutCounter &-= 1
        }
    }

    private func clearSlides() {
        for track in tracks {
            track.volumeDelta = 0
            track.panningDelta = 0
            track.pitchDelta = 0
            track.slideToNoteDelta = 0
            track.volume /= speed
            track.panning /= speed
            track.pitch /= speed
            track.arpeggio1 = 0
            track.arpeggio2 = 0
            track.vibratoSpeed = 0
            track.vibratoDepth = 0
        }
        globalVolumeSlide = 0
        arpeggioCounter = 0
    }

    private func setUpSlides() {
        for track in tracks {
            track.volume = track.volume &* speed
            track.panning = track.panning &* speed
            track.pitch = track.pitch &* speed
        }
        minVolume = 0
        minPanning = Int16(truncatingIfNeeded: -(speed << 7))
        minPitch = Int16(truncatingIfNeeded: speed &* 96)
        maxVolume = Int16(truncatingIfNeeded: speed << 6)
        maxPanning = Int16(truncatingIfNeeded: speed << 7)
        maxPitch = Int16(truncatingIfNeeded: speed &* 864)
    }

    private func gainsAndPitches() {
        for track in tracks {
            var pitch = track.pitch
            pitch = pitch &+ Int32(arpeggioCounter == 1 ? track.arpeggio1 : arpeggioCounter == 2 ? track.arpeggio2 : 0)
            pitch = pitch &+ ((Int32(DBMTables.vibrato[Int(track.vibratoCounter)]) &* Int32(track.vibratoDepth)) >> 8)
            track.vibratoCounter = (track.vibratoCounter &+ track.vibratoSpeed) & 0x3F
            setPitch(track, pitch)

            // The volume as fourteen bits, by the envelope and the global volume; and the panning,
            // which the panning envelope moves about it, less the nearer to a side it is.
            var volume = (track.volume << 8) / speed
            let panning0 = (track.panning << 7) / speed
            volume = (volume &* Int32(track.volumeEnvelopeNow)) >> 14
            volume = (volume &* Int32(globalVolume)) >> 6
            var away = Int16(truncatingIfNeeded: panning0 > 0 ? panning0 : -panning0)
            away = Int16(truncatingIfNeeded: 16384 - Int32(away))
            let moved = (Int32(away) &* Int32(track.panningEnvelopeNow)) >> 14
            let panning = panning0 &+ moved
            var left = volume, right = volume
            if panning > 0 { left = (left &* (16384 - panning)) >> 14 }
            if panning < 0 { right = (right &* (16384 + panning)) >> 14 }
            track.gainLeft = Int16(truncatingIfNeeded: left)
            track.gainRight = Int16(truncatingIfNeeded: right)
            track.side = max(-1, min(1, Float(panning) / 16384))
            if forSound, track.hasChain { track.voice?.setPanning(track.panning / speed) }
        }
    }

    private func interpolate(_ state: inout EnvelopeState, _ envelope: DBMModule.Envelope, shift: Int32) -> Int16 {
        if state.tickCounter == 0 {
            if state.section == state.loopEnd { state.section = envelope.loopFirst }
            let section = Int(min(31, state.section))
            state.yStart = Int16(truncatingIfNeeded: Int32(envelope.values[section]) << shift)
            if state.section == state.sustainA || state.section == state.sustainB || state.section >= envelope.sections { return state.yStart }
            state.xDelta = Int16(truncatingIfNeeded: Int32(envelope.positions[section + 1]) - Int32(envelope.positions[section]))
            state.tickCounter = UInt16(bitPattern: state.xDelta)
            state.yDelta = Int16(truncatingIfNeeded: (Int32(envelope.values[section + 1]) << shift) - Int32(state.yStart))
            state.section += 1
        }
        let through = Int32(state.xDelta) - Int32(state.tickCounter)
        state.tickCounter &-= 1
        // (Two points at one place divide by nothing, which is nothing on the machines this is
        // compared on.)
        let part = state.xDelta == 0 ? 0 : (Int32(state.yDelta) &* through) / Int32(state.xDelta)
        state.previous = Int16(truncatingIfNeeded: Int32(state.yStart) &+ part)
        return state.previous
    }

    private func doEnvelopes() {
        for track in tracks where track.isOn {
            if Int(track.volumeEnvelope.index) < module.volumeEnvelopes.count {
                track.volumeEnvelopeNow = interpolate(&track.volumeEnvelope, module.volumeEnvelopes[Int(track.volumeEnvelope.index)], shift: 8)
            }
            if Int(track.panningEnvelope.index) < module.panningEnvelopes.count {
                track.panningEnvelopeNow = interpolate(&track.panningEnvelope, module.panningEnvelopes[Int(track.panningEnvelope.index)], shift: 7)
            }
        }
    }

    /// Plays one tick: what each track is to play until the next, and how long that is.
    /// - Returns: false if the song came round on this tick, to a row it had already played.
    func runTick() -> Bool {
        more = true
        // (The slides move first, on the very first tick too, which brings a pitch of nought up
        // to the lowest there is.)
        postTick()
        if tick == 0, !stopped {
            if stopNow {
                stopped = true
            } else if patternDelay > 0 {
                // A delay of more than fifteen rows is the end of the song.
                if patternDelay > 15 { stopped = true }
                patternDelay &-= 1
            } else {
                applyDelayed()
                clearSlides()
                scanForSpeed()
                setUpSlides()
                nextRow()
            }
        }
        stopTick = tick == 0 && stopped
        doTriggers()
        doEnvelopes()
        gainsAndPitches()
        arpeggioCounter += 1
        if arpeggioCounter > 2 { arpeggioCounter = 0 }

        // How long the tick is: five seconds of samples over twice the tempo, with what is over
        // carried on to the next. (The replayer adds the sample that is over one late.)
        let bpm2 = Int(tempo) << 1
        let samples = 5 * Int(rate)
        tickSamples = samples / bpm2
        tickRemainder += samples % bpm2
        if tickRemainder > bpm2 {
            tickRemainder -= bpm2
            tickSamples += 1
        }
        tick += 1
        if tick == Int(speed) { tick = 0 }
        return more
    }

    // MARK: The sound

    /// Mixes so many frames of every track into the two sums, as the replayer does: each track's
    /// sound as its two gains have it, and a fourteenth bit off. (Whether a track is still playing
    /// is known once for all the frames that are asked for at once, as in the replayer, and so
    /// they are asked for as it asks for them: a tick at a time, or the part of one that is in the
    /// block its caller is making.)
    /// - Parameter levels: where the loudest each track has been is kept, from 0 to 1.
    func mix(into sums: UnsafeMutablePointer<Int32>, frames: Int, levels: inout [Float]) {
        let premix = premix.pointer
        var done = 0
        while done < frames {
            let count = min(Self.mostFrames, frames - done)
            for (index, track) in tracks.enumerated() {
                guard track.isOn else {
                    waves?.silence(index, count: count)
                    continue
                }
                if let echo = track.echo {
                    echo.pull(premix, count, from: track.hasChain ? track.voice : nil)
                    track.isOn = true
                } else if track.hasChain, let voice = track.voice {
                    track.isOn = voice.pull(premix, count)
                } else {
                    track.isOn = false
                    waves?.silence(index, count: count)
                    continue
                }
                let gainLeft = Int32(track.gainLeft), gainRight = Int32(track.gainRight)
                // For the light: how far each side swings, either side of its middle. (A track
                // held at one level is not heard, and is dark.)
                var lowLeft: Int32 = 32767, highLeft: Int32 = -32768, lowRight: Int32 = 32767, highRight: Int32 = -32768
                let out = sums + done * 2
                if track.muted {
                    for i in 0 ..< count {
                        let l = Int32(premix[i * 2]), r = Int32(premix[i * 2 + 1])
                        lowLeft = min(lowLeft, l)
                        highLeft = max(highLeft, l)
                        lowRight = min(lowRight, r)
                        highRight = max(highRight, r)
                    }
                } else {
                    for i in 0 ..< count {
                        let l = Int32(premix[i * 2]), r = Int32(premix[i * 2 + 1])
                        out[i * 2] &+= (l &* gainLeft) >> 14
                        out[i * 2 + 1] &+= (r &* gainRight) >> 14
                        lowLeft = min(lowLeft, l)
                        highLeft = max(highLeft, l)
                        lowRight = min(lowRight, r)
                        highRight = max(highRight, r)
                    }
                }
                let swingLeft = Float(max(0, highLeft - lowLeft)) * 0.5, swingRight = Float(max(0, highRight - lowRight)) * 0.5
                let level = max(swingLeft * abs(Float(gainLeft)), swingRight * abs(Float(gainRight))) / (32768 * 16384)
                if level > levels[index] { levels[index] = min(1, level) }
                if let waves {
                    // The side it is nearer, which has its whole volume and is not put off: the
                    // other has much the same, quieter and a little later.
                    let side = abs(gainLeft) >= abs(gainRight) ? 0 : 1
                    let gain = Float(max(abs(gainLeft), abs(gainRight))) / (32768 * 16384)
                    for i in 0 ..< count { waves.store(index, at: i, Float(premix[i * 2 + side]) * gain) }
                }
            }
            waves?.advance(by: count)
            done += count
        }
    }
}
