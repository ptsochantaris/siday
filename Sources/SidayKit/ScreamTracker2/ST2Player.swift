// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from st2play, Copyright 2017 Sergei "x0r" Kolzun, used under the Apache License, Version
// 2.0 (see THIRD-PARTY.md): this is the `st2play.c` of its branch for Scream Tracker 2.3.

/// Scream Tracker 2.3's replayer, and its mixing: a port of st2play, which its author made from the
/// program itself.
///
/// It is the whole of how Scream Tracker 2 made sound. There was no sound card to do any of it:
/// the program added its four channels together into eight bits, one sample at a time, with
/// nothing between one sample of a sound and the next, and gave each to a Sound Blaster or to a
/// resistor ladder on the printer port. A tick is so many of those samples, a whole number of
/// them, which is why its tempo depends a little on the rate it mixes at. What is odd in it is
/// Scream Tracker's, and is kept: a command whose value is in tens of the units other trackers
/// count in, an arpeggio that goes wrong on a B, a tempo with a second half that divides the tick,
/// and a volume over 64 that silences a channel.
///
/// The names are st2play's, a little unbent. Where the C leaves a thing to chance, as when a tune
/// names a pattern or a sample there is none of, what is read here is nothing.
final class ST2Player {
    /// How many samples a second Scream Tracker mixed, at the highest of its settings: the PC's
    /// timer divided by 50.
    static let mixRate = 23863

    /// Where each channel's sound is kept for its scope, as loud as it is, at the rate it is mixed
    /// at, if it is wanted. A channel at its loudest swings 32 either side of nothing.
    var waves: ChannelWaves?

    private enum FX {
        static let speed: UInt16 = 0x01, positionJump: UInt16 = 0x02, patternBreak: UInt16 = 0x03, volumeSlide: UInt16 = 0x04
        static let portamentoDown: UInt16 = 0x05, portamentoUp: UInt16 = 0x06, tonePortamento: UInt16 = 0x07, vibrato: UInt16 = 0x08
        static let tremor: UInt16 = 0x09, arpeggio: UInt16 = 0x0A, vibratoAndSlide: UInt16 = 0x0B, toneAndSlide: UInt16 = 0x0F
    }

    private static let fxMult = 10
    private static let baseFrequency: UInt32 = 35_468_950
    private static let tempoTable: [Int] = [140, 50, 25, 15, 10, 7, 6, 4, 3, 3, 2, 2, 2, 2, 1, 1, 1, 1]
    private static let lfoTable: [Int] = [
        0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
        255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24,
        0, -24, -49, -74, -97, -120, -141, -161, -180, -197, -212, -224, -235, -244, -250, -253,
        -255, -253, -250, -244, -235, -224, -212, -197, -180, -161, -141, -120, -97, -74, -49, -24, 0,
    ]
    /// A period for each note: sixteen places to the octave, of which twelve are notes, each octave
    /// half the one before. (And one number from past the table's end, which a tune can reach.)
    private static let periodTable: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 256)
        let lowest: [UInt16] = [17120, 16160, 15240, 14400, 13560, 12800, 12080, 11400, 10760, 10160, 9600, 9070]
        for i in 0 ..< 12 { table[i] = lowest[i] }
        for i in 0 ..< 64 { table[i + 16] = table[i] >> 1 }
        table[255] = 0xE6D1
        return table
    }()

    private struct Channel {
        var row: UInt16 = 0
        var patternDataOffs = 0
        var eventNote: UInt16 = 0, eventVolume: UInt8 = 0, eventSmp: UInt16 = 0, eventCmd: UInt16 = 0, eventInfobyte: UInt16 = 0
        var lastNote: UInt16 = 0, lastInfobyte1: UInt16 = 0, lastInfobyte2: UInt16 = 0
        var periodCurrent: UInt16 = 0, periodTarget: UInt16 = 0
        var vibratoCurrent: UInt16 = 0, tremorCounter: UInt16 = 0, tremorState: UInt16 = 0
        /// Where the sample's sound is, and how much of it there is; -1 for none.
        var smpBase = -1, smpCount = 0
        var smpLoopEnd: UInt16 = 0, smpLoopStart: UInt16 = 0xFFFF, smpC2spd: UInt16 = 0
        var smpPosition: UInt32 = 0, smpStep: UInt32 = 0
        var volumeInitial: UInt16 = 0, volumeCurrent: UInt16 = 0, volumeMix: UInt16 = 0
        /// For the lights: the least and the most it has put into the mix of late, nothing when it
        /// is not sounding.
        var low = Int.max, high = Int.min
        var struck = false
        /// True for a channel that is left out of the sound: it plays on, and is not added in.
        var muted = false
    }

    private let module: ST2Module
    private let sampleRate: Int
    private var channels = [Channel](repeating: Channel(), count: ST2Module.channels)
    /// What each channel put out for the last `lightsLag` samples, for the lights, which are of each
    /// sample once it is heard: the player's samples reach the output through a filter, whose middle
    /// is that many of them behind the newest (see `STMRenderer`).
    private var lately = [Int](repeating: 0, count: ST2Module.channels * ST2Player.lightsLag)
    private var latelyAt = 0
    static let lightsLag = 8
    private var changePatternNext = false
    private var currentTick: UInt16 = 0, ticksPerRow: UInt16 = 0
    private var currentFrame: UInt16 = 0
    private(set) var framesPerTick: UInt16 = 1
    private var orderFirst = 0, orderNext = 0
    private(set) var orderCurrent = 0
    private var globalVolume: UInt8

    // What the player around it wants to know.
    /// How many ticks have been played.
    private(set) var ticks = 0
    /// How many times the tune has come round: to the end of its list, or, where it is asked to
    /// watch for it, to a row it has played before.
    private(set) var loopCount = 0
    /// As the tune is played, the rows it has played since it last came round (see `processTick`).
    private var rowsHeard: [Bool]
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>?
    private let songNumber: UInt8
    private(set) var ordersPlayed: [Bool]
    private(set) var playedNote = false
    private(set) var ledIntoEarlierSong = false

    /// - Parameters:
    ///   - order: where in the list to start, and to go round from.
    ///   - firstPlayedBy: for finding a tune's songs and their lengths: a table, a place for every
    ///     row of every place in the list, of which song first played it. A row found to have been
    ///     played is taken as the tune having come round.
    init(_ module: ST2Module, order: Int = 0, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil, songNumber: UInt8 = 0) {
        self.module = module
        sampleRate = Self.mixRate
        globalVolume = module.globalVolume
        self.firstPlayedBy = firstPlayedBy
        self.songNumber = songNumber
        ordersPlayed = [Bool](repeating: false, count: module.orders.count)
        rowsHeard = [Bool](repeating: false, count: firstPlayedBy == nil ? module.orders.count * ST2Module.rows : 0)
        setTempo(module.tempo)
        currentFrame = framesPerTick
        orderFirst = order
        orderNext = order
        changePattern()
        // (That was not the tune coming round: it had not begun.)
        loopCount = 0
    }

    private func setTempo(_ tempo: UInt8) {
        ticksPerRow = UInt16(tempo >> 4)
        let divisor = 50 - ((Self.tempoTable[Int(ticksPerRow)] * Int(tempo & 0x0F)) >> 4)
        // (A factor too great for the speed takes the divisor below nought, and the tick comes out
        // very long: sixteen bits of a number that is less than nothing.)
        framesPerTick = divisor == 0 ? 0xFFFF : UInt16(truncatingIfNeeded: sampleRate / divisor)
        if framesPerTick == 0 { framesPerTick = 1 }
    }

    private func updateFrequency(_ chn: Int) {
        var step: UInt32 = 0
        let period = UInt32(channels[chn].periodCurrent)
        if period >= 551 {
            let temp = Self.baseFrequency / period
            let rate = UInt32(sampleRate)
            step = ((temp / rate) & 0xFFFF) << 16
            step |= (((temp % rate) << 16) / rate) & 0xFFFF
        }
        channels[chn].smpStep = step
    }

    /// The period of a note for a sample: the table's, for how fast the sample is to be played.
    private func period(_ note: Int, _ c2spd: UInt16) -> UInt16 {
        UInt16(truncatingIfNeeded: Int(Self.periodTable[note & 0xFF]) * 8192 / Int(c2spd != 0 ? c2spd : 8192))
    }

    private func cmdRow(_ chn: Int) {
        switch channels[chn].eventCmd {
        case FX.speed:
            if channels[chn].eventInfobyte != 0 { setTempo(UInt8(truncatingIfNeeded: channels[chn].eventInfobyte)) }
        case FX.positionJump:
            orderNext = Int(channels[chn].eventInfobyte)
        case FX.patternBreak:
            changePatternNext = true
        default:
            break
        }
    }

    private func tonePortamento(_ chn: Int) {
        let by = UInt16(truncatingIfNeeded: Self.fxMult * Int(channels[chn].eventInfobyte))
        channels[chn].lastInfobyte1 = channels[chn].eventInfobyte
        if channels[chn].periodCurrent != channels[chn].periodTarget {
            // (The two are set against each other as numbers with a sign, as the program has it.)
            let target = Int16(bitPattern: channels[chn].periodTarget)
            if Int16(bitPattern: channels[chn].periodCurrent) > target {
                channels[chn].periodCurrent &-= by
                if Int16(bitPattern: channels[chn].periodCurrent) < target { channels[chn].periodCurrent = channels[chn].periodTarget }
            } else {
                channels[chn].periodCurrent &+= by
                if Int16(bitPattern: channels[chn].periodCurrent) > target { channels[chn].periodCurrent = channels[chn].periodTarget }
            }
            updateFrequency(chn)
        }
    }

    private func vibrato(_ chn: Int) {
        channels[chn].lastInfobyte2 = channels[chn].eventInfobyte
        let info = Int(channels[chn].eventInfobyte)
        let swing = Self.fxMult * ((Self.lfoTable[Int(channels[chn].vibratoCurrent >> 1)] * (info & 0x0F)) >> 7)
        channels[chn].periodCurrent = UInt16(truncatingIfNeeded: swing + Int(channels[chn].periodTarget))
        updateFrequency(chn)
        channels[chn].vibratoCurrent = UInt16(truncatingIfNeeded: (Int(channels[chn].vibratoCurrent) + ((info >> 4) << 1)) & 0x7E)
    }

    private func volumeSlide(_ chn: Int) {
        let info = channels[chn].eventInfobyte
        if info & 0x0F != 0 {
            channels[chn].volumeCurrent &-= info & 0x0F
            if Int16(bitPattern: channels[chn].volumeCurrent) <= -1 { channels[chn].volumeCurrent = 0 }
        } else {
            channels[chn].volumeCurrent &+= info >> 4
            if channels[chn].volumeCurrent >= 65 { channels[chn].volumeCurrent = 64 }
        }
    }

    private func cmdTick(_ chn: Int) {
        let cmd = channels[chn].eventCmd
        switch cmd {
        case FX.arpeggio:
            let info = UInt8(truncatingIfNeeded: channels[chn].eventInfobyte)
            let noteAdd: UInt8 = currentTick % 3 == 1 ? 0 : currentTick % 3 == 2 ? info >> 4 : info & 0x0F
            var octa = UInt8(truncatingIfNeeded: channels[chn].lastNote & 0xF0)
            var note = UInt8(truncatingIfNeeded: channels[chn].lastNote & 0x0F) &+ noteAdd
            // (Eleven is a B, and a note: taking it for one too many is the program's own mistake,
            // and sends a B off the end of the table.)
            if note >= 11 {
                note &-= 12
                octa &+= 16
            }
            channels[chn].periodCurrent = period(Int(octa | note), channels[chn].smpC2spd)
            channels[chn].periodTarget = channels[chn].periodCurrent
            updateFrequency(chn)
        case FX.tremor:
            if channels[chn].tremorCounter == 0 {
                if channels[chn].tremorState == 1 {
                    channels[chn].tremorState = 0
                    channels[chn].volumeCurrent = 0
                    channels[chn].tremorCounter = channels[chn].eventInfobyte & 0x0F
                } else {
                    channels[chn].tremorState = 1
                    channels[chn].volumeCurrent = channels[chn].volumeInitial
                    channels[chn].tremorCounter = channels[chn].eventInfobyte >> 4
                }
            } else {
                channels[chn].tremorCounter &-= 1
            }
        default:
            channels[chn].tremorCounter = 0
            channels[chn].tremorState = 1
            switch cmd {
            case FX.tonePortamento:
                if channels[chn].eventInfobyte == 0 { channels[chn].eventInfobyte = channels[chn].lastInfobyte1 }
                tonePortamento(chn)
            case FX.vibrato:
                if channels[chn].eventInfobyte == 0 { channels[chn].eventInfobyte = channels[chn].lastInfobyte2 }
                vibrato(chn)
            default:
                channels[chn].vibratoCurrent = 0
                switch cmd {
                case FX.portamentoDown:
                    channels[chn].periodCurrent &+= UInt16(truncatingIfNeeded: Self.fxMult * Int(channels[chn].eventInfobyte))
                    updateFrequency(chn)
                case FX.portamentoUp:
                    channels[chn].periodCurrent &-= UInt16(truncatingIfNeeded: Self.fxMult * Int(channels[chn].eventInfobyte))
                    updateFrequency(chn)
                case FX.vibratoAndSlide:
                    // (The slide is by the command's value, and the vibrato by the last vibrato's:
                    // which is then the value for the rest of the row, the slide's too.)
                    volumeSlide(chn)
                    channels[chn].eventInfobyte = channels[chn].lastInfobyte2
                    vibrato(chn)
                case FX.toneAndSlide:
                    volumeSlide(chn)
                    channels[chn].eventInfobyte = channels[chn].lastInfobyte1
                    tonePortamento(chn)
                default:
                    if channels[chn].periodCurrent != channels[chn].periodTarget {
                        channels[chn].periodCurrent = channels[chn].periodTarget
                        updateFrequency(chn)
                    }
                    if cmd == FX.volumeSlide { volumeSlide(chn) }
                }
            }
        }
    }

    private func triggerNote(_ chn: Int) {
        if channels[chn].eventVolume != 65 {
            channels[chn].volumeCurrent = UInt16(channels[chn].eventVolume)
            channels[chn].volumeInitial = channels[chn].volumeCurrent
        }

        if channels[chn].eventCmd == FX.tonePortamento {
            if channels[chn].eventNote != 255 { channels[chn].periodTarget = period(Int(channels[chn].eventNote), channels[chn].smpC2spd) }
            return
        }

        let smp = Int(channels[chn].eventSmp)
        if smp != 0 {
            let sample = module.samples[smp]
            if channels[chn].eventVolume == 65 {
                channels[chn].volumeCurrent = UInt16(sample.volume)
                channels[chn].volumeInitial = channels[chn].volumeCurrent
            }
            channels[chn].smpC2spd = sample.c2spd
            if sample.base < 0 { channels[chn].eventNote = 254 }
            channels[chn].smpBase = sample.base
            channels[chn].smpCount = sample.count
            if sample.loopEnd != 0xFFFF {
                channels[chn].smpLoopEnd = sample.loopEnd
                channels[chn].smpLoopStart = sample.loopStart
            } else {
                channels[chn].smpLoopEnd = sample.length
                channels[chn].smpLoopStart = 0xFFFF
            }
        }

        if channels[chn].eventNote == 254 {
            channels[chn].smpPosition = 0
            channels[chn].smpLoopEnd = 0
            channels[chn].smpLoopStart = 0xFFFF
        } else if channels[chn].eventNote != 255 {
            channels[chn].lastNote = channels[chn].eventNote
            channels[chn].periodCurrent = period(Int(channels[chn].eventNote), channels[chn].smpC2spd)
            channels[chn].periodTarget = channels[chn].periodCurrent
            updateFrequency(chn)
            channels[chn].smpPosition = 0
            channels[chn].struck = true
            if channels[chn].smpBase >= 0 { playedNote = true }
        }

        cmdRow(chn)
    }

    private func processRow(_ chn: Int) {
        channels[chn].row &+= 1
        if channels[chn].row >= 64 { changePatternNext = true }

        let (note, insVol, volCmd, info) = module.cell(at: channels[chn].patternDataOffs)
        channels[chn].eventNote = UInt16(note)
        channels[chn].eventSmp = UInt16(insVol >> 3)
        channels[chn].eventVolume = (insVol & 7) | ((volCmd >> 1) & 0x78)
        channels[chn].eventCmd = UInt16(volCmd & 0x0F)
        channels[chn].eventInfobyte = UInt16(info)
        channels[chn].patternDataOffs += 0x10

        triggerNote(chn)

        if channels[chn].eventCmd == FX.tremor { cmdTick(chn) }
    }

    private func changePattern() {
        if module.order(orderNext) == ST2Module.end || module.order(orderNext) == ST2Module.endToTop {
            orderNext = module.order(orderNext) == ST2Module.end ? orderFirst : 0
            loopCount += 1
            for i in rowsHeard.indices { rowsHeard[i] = false }
        }
        let pattern = Int(module.order(orderNext))
        orderCurrent = orderNext
        orderNext += 1
        for i in 0 ..< ST2Module.channels {
            channels[i].patternDataOffs = 0x400 * pattern + i * 4
            channels[i].row = 0
        }
    }

    private func processTick() {
        ticks += 1
        if currentTick != 0 {
            currentTick -= 1
            for i in 0 ..< ST2Module.channels { cmdTick(i) }
        } else {
            if changePatternNext {
                changePatternNext = false
                changePattern()
            }
            // Whose row this is: a row some song has played already is the end of this one.
            if orderCurrent < ordersPlayed.count { ordersPlayed[orderCurrent] = true }
            if let firstPlayedBy, orderCurrent < module.orders.count {
                let at = orderCurrent * ST2Module.rows + Int(channels[0].row & 63)
                if firstPlayedBy[at] == ModuleSongs.unplayed {
                    firstPlayedBy[at] = songNumber
                } else {
                    if firstPlayedBy[at] != songNumber { ledIntoEarlierSong = true }
                    loopCount += 1
                }
            } else if orderCurrent < module.orders.count {
                // (As the tune is played, a row it has played before is it coming round too: by a
                // jump, as often as by the end of its list. Each time round is counted once.)
                let at = orderCurrent * ST2Module.rows + Int(channels[0].row & 63)
                if rowsHeard[at] {
                    loopCount += 1
                    for i in rowsHeard.indices { rowsHeard[i] = false }
                }
                rowsHeard[at] = true
            }
            for i in 0 ..< ST2Module.channels { processRow(i) }
            currentTick = ticksPerRow != 0 ? ticksPerRow - 1 : 0
        }

        for i in 0 ..< ST2Module.channels {
            channels[i].volumeMix = UInt16(truncatingIfNeeded: (Int(channels[i].volumeCurrent) * Int(globalVolume)) >> 6)
        }
    }

    /// One sample of the four channels together, as Scream Tracker gave it to the card: eight
    /// bits, with silence at 128.
    func renderSample() -> UInt8 {
        var mix = 0
        let waves = waves
        // (The channels and the lights' last levels are taken out of the player while the sample is made,
        // and put back: looked at where they are, as a class's, each look had a check of its own.)
        var channels = self.channels, lately = self.lately
        self.channels = []
        self.lately = []
        let sound = module.sound, slot = latelyAt
        var i = 0
        while i < ST2Module.channels {
            var level = 0
            channels[i].smpPosition &+= channels[i].smpStep
            var at = Int(channels[i].smpPosition >> 16)
            var sounding = at < Int(channels[i].smpLoopEnd)
            if !sounding {
                // Round, for a sample that goes round: with no look at where that leaves it.
                channels[i].smpPosition = UInt32(channels[i].smpLoopStart) << 16 | (channels[i].smpPosition & 0xFFFF)
                sounding = channels[i].smpLoopStart != 0xFFFF
                at = Int(channels[i].smpLoopStart)
            }
            if sounding {
                if channels[i].smpBase >= 0, channels[i].volumeMix < 65 {
                    let byte = at < channels[i].smpCount ? Int(Int8(bitPattern: sound[channels[i].smpBase + at])) : 0
                    // (The high half of the product, which for a sample below the middle rounds away from it.)
                    level = (Int(channels[i].volumeMix) * byte) >> 8
                    if !channels[i].muted { mix += level }
                }
            } else {
                channels[i].smpPosition = UInt32(channels[i].smpLoopEnd) << 16 | (channels[i].smpPosition & 0xFFFF)
            }
            let heard = lately[i * Self.lightsLag + slot]
            lately[i * Self.lightsLag + slot] = level
            if heard < channels[i].low { channels[i].low = heard }
            if heard > channels[i].high { channels[i].high = heard }
            waves?.store(i, at: 0, Float(level))
            i += 1
        }
        self.channels = channels
        self.lately = lately

        waves?.advance(by: 1)
        latelyAt = latelyAt == Self.lightsLag - 1 ? 0 : latelyAt + 1

        if currentFrame == 1 {
            currentFrame = framesPerTick
            processTick()
        } else {
            currentFrame &-= 1
        }

        return UInt8(truncatingIfNeeded: mix) &+ 128
    }

    /// Leaves channels out of the sound, or brings them back: see `Renderer.setMuted`. A mark for
    /// each channel, true for one not to be heard; a channel with no mark is heard.
    func setMuted(_ muted: [Bool]) {
        for i in 0 ..< ST2Module.channels { channels[i].muted = i < muted.count && muted[i] }
    }

    /// Plays one tick in silence, and says how many samples it would have lasted.
    func runTickInSilence() -> Int {
        let frames = Int(framesPerTick)
        processTick()
        return frames
    }

    // MARK: For the lights and the pictures

    /// How far each channel has swung since this was last asked, of the most it can: from 0 to 1.
    /// A channel held at one level has not swung, and is silent to the ear.
    func takeLevels(into levels: UnsafeMutablePointer<Float>) {
        for i in 0 ..< ST2Module.channels {
            levels[i] = channels[i].low < channels[i].high ? min(1, Float(channels[i].high - channels[i].low) / 63) : 0
            channels[i].low = Int.max
            channels[i].high = Int.min
        }
    }

    /// The pitch each channel has now, and whether a note was started on it since this was last asked.
    func takeNotes(into notes: inout TickNotes) {
        for i in 0 ..< ST2Module.channels {
            let heard = channels[i].smpBase >= 0 && channels[i].volumeMix > 0 && channels[i].volumeMix < 65 && channels[i].smpStep != 0
                && (Int(channels[i].smpPosition >> 16) < Int(channels[i].smpLoopEnd) || channels[i].smpLoopStart != 0xFFFF)
            notes.pitches[i] = heard ? ChannelPitch.note(ofRate: Double(channels[i].smpStep) / 65536 * Double(sampleRate)) : 0
            if channels[i].struck { notes.struck[i] = true }
            channels[i].struck = false
        }
    }
}
