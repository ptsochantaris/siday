// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from pt2-clone, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): his C port of the replayer of ProTracker 2.3D.

/// The periods of three octaves of notes, sixteen times over: once for each fine tuning from none,
/// up to +7, and from -8 back up to -1. Each list ends in a zero. An arpeggio on a sample tuned to -1
/// reads past the end of them all, into what ProTracker happened to keep after its table, and what it
/// found there is what such a tune sounds like: so that is here too.
private let proTrackerPeriods: [Int16] = [
    856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453, 428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
    214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113, 0,
    850, 802, 757, 715, 674, 637, 601, 567, 535, 505, 477, 450, 425, 401, 379, 357, 337, 318, 300, 284, 268, 253, 239, 225,
    213, 201, 189, 179, 169, 159, 150, 142, 134, 126, 119, 113, 0,
    844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474, 447, 422, 398, 376, 355, 335, 316, 298, 282, 266, 251, 237, 224,
    211, 199, 188, 177, 167, 158, 149, 141, 133, 125, 118, 112, 0,
    838, 791, 746, 704, 665, 628, 592, 559, 528, 498, 470, 444, 419, 395, 373, 352, 332, 314, 296, 280, 264, 249, 235, 222,
    209, 198, 187, 176, 166, 157, 148, 140, 132, 125, 118, 111, 0,
    832, 785, 741, 699, 660, 623, 588, 555, 524, 495, 467, 441, 416, 392, 370, 350, 330, 312, 294, 278, 262, 247, 233, 220,
    208, 196, 185, 175, 165, 156, 147, 139, 131, 124, 117, 110, 0,
    826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463, 437, 413, 390, 368, 347, 328, 309, 292, 276, 260, 245, 232, 219,
    206, 195, 184, 174, 164, 155, 146, 138, 130, 123, 116, 109, 0,
    820, 774, 730, 689, 651, 614, 580, 547, 516, 487, 460, 434, 410, 387, 365, 345, 325, 307, 290, 274, 258, 244, 230, 217,
    205, 193, 183, 172, 163, 154, 145, 137, 129, 122, 115, 109, 0,
    814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457, 431, 407, 384, 363, 342, 323, 305, 288, 272, 256, 242, 228, 216,
    204, 192, 181, 171, 161, 152, 144, 136, 128, 121, 114, 108, 0,
    907, 856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453, 428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240,
    226, 214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 0,
    900, 850, 802, 757, 715, 675, 636, 601, 567, 535, 505, 477, 450, 425, 401, 379, 357, 337, 318, 300, 284, 268, 253, 238,
    225, 212, 200, 189, 179, 169, 159, 150, 142, 134, 126, 119, 0,
    894, 844, 796, 752, 709, 670, 632, 597, 563, 532, 502, 474, 447, 422, 398, 376, 355, 335, 316, 298, 282, 266, 251, 237,
    223, 211, 199, 188, 177, 167, 158, 149, 141, 133, 125, 118, 0,
    887, 838, 791, 746, 704, 665, 628, 592, 559, 528, 498, 470, 444, 419, 395, 373, 352, 332, 314, 296, 280, 264, 249, 235,
    222, 209, 198, 187, 176, 166, 157, 148, 140, 132, 125, 118, 0,
    881, 832, 785, 741, 699, 660, 623, 588, 555, 524, 494, 467, 441, 416, 392, 370, 350, 330, 312, 294, 278, 262, 247, 233,
    220, 208, 196, 185, 175, 165, 156, 147, 139, 131, 123, 117, 0,
    875, 826, 779, 736, 694, 655, 619, 584, 551, 520, 491, 463, 437, 413, 390, 368, 347, 328, 309, 292, 276, 260, 245, 232,
    219, 206, 195, 184, 174, 164, 155, 146, 138, 130, 123, 116, 0,
    868, 820, 774, 730, 689, 651, 614, 580, 547, 516, 487, 460, 434, 410, 387, 365, 345, 325, 307, 290, 274, 258, 244, 230,
    217, 205, 193, 183, 172, 163, 154, 145, 137, 129, 122, 115, 0,
    862, 814, 768, 725, 684, 646, 610, 575, 543, 513, 484, 457, 431, 407, 384, 363, 342, 323, 305, 288, 272, 256, 242, 228,
    216, 203, 192, 181, 171, 161, 152, 144, 136, 128, 121, 114, 0,
    774, 1800, 2314, 3087, 4113, 4627, 5400, 6426, 6940, 7713, 8739, 9253, 24625, 12851, 13365,
]

/// Half a sine wave, for vibrato and tremolo.
private let proTrackerSine: [UInt8] = [
    0x00, 0x18, 0x31, 0x4A, 0x61, 0x78, 0x8D, 0xA1, 0xB4, 0xC5, 0xD4, 0xE0, 0xEB, 0xF4, 0xFA, 0xFD,
    0xFF, 0xFD, 0xFA, 0xF4, 0xEB, 0xE0, 0xD4, 0xC5, 0xB4, 0xA1, 0x8D, 0x78, 0x61, 0x4A, 0x31, 0x18,
]

/// How fast the "invert loop" effect eats its way through a sample, by its setting.
private let proTrackerFunk: [UInt8] = [0x00, 0x05, 0x06, 0x07, 0x08, 0x0A, 0x0B, 0x0D, 0x10, 0x13, 0x16, 0x1A, 0x20, 0x2B, 0x40, 0x80]

/// ProTracker's replayer: what the tracker did, fifty times a second or so, to turn a module's
/// patterns into what it told Paula. It is ProTracker's, mistakes and all, because the mistakes are in
/// the music: tunes were written by ear against them.
struct ProTrackerReplayer: ~Copyable {
    static let slowestTempo = 32, fastestTempo = 255

    /// One of the four channels. The names are the tracker's own, spelled out.
    private struct Channel {
        // Places in the module's memory; -1 for nowhere.
        var start = -1, waveStart = -1, loopStart = -1
        var volume: Int8 = 0
        var portamentoDirection: Int8 = 0
        var loopRow: Int8 = 0, loopCount: Int8 = 0
        var waveControl: UInt8 = 0, glissFunk: UInt8 = 0
        var sampleOffset: UInt8 = 0, portamentoSpeed: UInt8 = 0
        var vibrato: UInt8 = 0, tremolo: UInt8 = 0
        var fineTune: UInt8 = 0, funkOffset: UInt8 = 0
        var vibratoPosition: UInt8 = 0, tremoloPosition: UInt8 = 0
        var period: Int16 = 0, note: Int16 = 0, wantedPeriod: Int16 = 0
        var command: UInt16 = 0
        /// In words, as Paula is told them.
        var length: UInt16 = 0, repeatLength: UInt16 = 0
    }

    let module: ProTrackerModule
    var paula: Paula
    private let periods: UnsafeMutablePointer<Int16>
    private let visited: UnsafeMutablePointer<Bool>
    private var channels = InlineArray<4, Channel>(repeating: Channel())

    private var tick: Int32 = 0, speed: Int32 = 6
    private var row: Int8 = 0
    private var position: Int16 = 0
    private var pattern: Int8 = 0
    private var jumping = false, breaking = false
    private var breakRow: Int8 = 0
    private var patternDelay: UInt8 = 0, patternDelayLeft: UInt8 = 0
    private var slideMask: UInt8 = 0xFF
    private var starting: UInt16 = 0
    /// A tempo takes hold a tick after it is set, as the timer that keeps it only looks when it fires.
    private var pendingTempo: Int32 = -1
    private(set) var tempo = 125
    private var stopping = false
    private var wrapped = false
    /// True once the tune has told the tracker to stop (a speed of nothing).
    private(set) var stopped = false
    /// Which places in the list of patterns have been played, and whether a note has been.
    private(set) var ordersPlayed = [Bool](repeating: false, count: 128)
    private(set) var playedNote = false
    /// Which of the file's songs first played each row, shared between them and not this replayer's
    /// to free, and which song this is. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>?
    private let songNumber: UInt8
    private var metEarlierSong = false
    /// True if this song went on into a row that a song before it played, other than by running off
    /// the end of the list of patterns.
    private(set) var ledIntoEarlierSong = false
    /// How many rows the table of who played a row first has.
    static let rowsInAll = 128 * ProTrackerModule.rows

    /// - Parameters:
    ///   - position: where in the list of patterns to start.
    ///   - firstPlayedBy: for a file of several songs, which of them first played each row.
    ///   - songNumber: which of them this is.
    init(_ module: ProTrackerModule, model: AmigaModel, position start: Int = 0, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil,
         songNumber: UInt8 = 0) {
        self.firstPlayedBy = firstPlayedBy
        self.songNumber = songNumber
        self.module = module
        paula = Paula(rate: Double(outputSampleRate * 2), model: model, memory: UnsafePointer(module.memory),
                      size: ProTrackerModule.memorySize, silence: ProTrackerModule.silence)
        periods = .allocate(capacity: proTrackerPeriods.count)
        for i in 0 ..< proTrackerPeriods.count { periods[i] = proTrackerPeriods[i] }
        visited = .allocate(capacity: 128 * ProTrackerModule.rows)
        visited.initialize(repeating: false, count: 128 * ProTrackerModule.rows)
        setTempo(125)
        setTempo(module.initialTempo)
        position = Int16(max(0, min(module.songLength - 1, start)))
        pattern = Int8(truncatingIfNeeded: module.orders[Int(position)])
        if pattern > Int8(ProTrackerModule.mostPatterns - 1) { pattern = Int8(ProTrackerModule.mostPatterns - 1) }
        tick = speed - 1
    }

    deinit {
        periods.deallocate()
        visited.deallocate()
    }

    /// How many times a second the tracker's timer fires at a tempo. (The timer counts a whole number
    /// of its clock's ticks, and ProTracker rounds that number down.)
    static func ticksPerSecond(tempo: Int) -> Double {
        (Paula.clockHz / 5.0) / Double(1_773_447 / tempo + 1)
    }

    private mutating func setTempo(_ value: Int) {
        guard value >= Self.slowestTempo, value <= Self.fastestTempo else { return }
        tempo = value
    }

    // MARK: Effects

    private mutating func updateFunk(_ c: Int) {
        let rate = channels[c].glissFunk >> 4
        guard rate != 0 else { return }
        channels[c].funkOffset &+= proTrackerFunk[Int(rate)]
        guard channels[c].funkOffset >= 128 else { return }
        channels[c].funkOffset = 0
        guard channels[c].loopStart != -1, channels[c].waveStart != -1 else { return }
        channels[c].waveStart += 1
        if channels[c].waveStart >= channels[c].loopStart + Int(channels[c].repeatLength) << 1 {
            channels[c].waveStart = channels[c].loopStart
        }
        let at = channels[c].waveStart
        if at >= 0, at < ProTrackerModule.memorySize { module.memory[at] = -1 &- module.memory[at] }
    }

    private mutating func jumpLoop(_ c: Int) {
        guard tick == 0 else { return }
        let count = Int8(channels[c].command & 0xF)
        if count == 0 {
            channels[c].loopRow = row
            return
        }
        if channels[c].loopCount == 0 {
            channels[c].loopCount = count
        } else {
            channels[c].loopCount &-= 1
            if channels[c].loopCount == 0 { return }
        }
        breakRow = channels[c].loopRow
        breaking = true
        // The rows about to be played again have not been played for the last time.
        var again = Int(breakRow)
        while again <= Int(row) {
            if again >= 0, position >= 0 { visited[Int(position) * ProTrackerModule.rows + again] = false }
            again += 1
        }
    }

    private mutating func retrigger(_ c: Int) {
        paula.stop(voices: 1 << c)
        paula.setLocation(c, channels[c].start)
        paula.setLength(c, channels[c].length)
        paula.setPeriod(c, UInt16(bitPattern: channels[c].period))
        paula.start(voices: 1 << c)
        paula.setLocation(c, channels[c].loopStart)
        paula.setLength(c, channels[c].repeatLength)
    }

    private mutating func volumeSlide(_ c: Int) {
        let parameter = UInt8(truncatingIfNeeded: channels[c].command)
        if parameter & 0xF0 == 0 {
            channels[c].volume &-= Int8(parameter & 0x0F)
            if channels[c].volume < 0 { channels[c].volume = 0 }
        } else {
            channels[c].volume &+= Int8(parameter >> 4)
            if channels[c].volume > 64 { channels[c].volume = 64 }
        }
    }

    private mutating func arpeggio(_ c: Int) {
        let step = tick % 3
        let add: Int
        if step == 1 {
            add = Int(channels[c].command >> 4) & 0xF
        } else if step == 2 {
            add = Int(channels[c].command & 0xF)
        } else {
            paula.setPeriod(c, UInt16(bitPattern: channels[c].period))
            return
        }
        let table = Int(channels[c].fineTune) * 37
        for note in 0 ..< 37 where channels[c].period >= periods[table + note] {
            paula.setPeriod(c, UInt16(bitPattern: periods[table + note + add]))
            break
        }
    }

    private mutating func slideUp(_ c: Int) {
        channels[c].period &-= Int16(UInt8(truncatingIfNeeded: channels[c].command) & slideMask)
        slideMask = 0xFF
        // ProTracker forgets that a period can go below nothing here, and does not stop it.
        if channels[c].period & 0xFFF < 113 { channels[c].period = (channels[c].period & Int16(bitPattern: 0xF000)) | 113 }
        paula.setPeriod(c, UInt16(bitPattern: channels[c].period) & 0xFFF)
    }

    private mutating func slideDown(_ c: Int) {
        channels[c].period &+= Int16(UInt8(truncatingIfNeeded: channels[c].command) & slideMask)
        slideMask = 0xFF
        if channels[c].period & 0xFFF > 856 { channels[c].period = (channels[c].period & Int16(bitPattern: 0xF000)) | 856 }
        paula.setPeriod(c, UInt16(bitPattern: channels[c].period) & 0xFFF)
    }

    /// The place in a channel's list of periods of the first one a period is not below.
    private func place(of period: Int, _ c: Int) -> Int {
        let table = Int(channels[c].fineTune) * 37
        var i = 0
        while true {
            if period >= Int(periods[table + i]) { break }
            i += 1
            if i >= 37 {
                i = 35
                break
            }
        }
        return i
    }

    private mutating func setTonePortamento(_ c: Int) {
        let table = Int(channels[c].fineTune) * 37
        var i = place(of: Int(UInt16(bitPattern: channels[c].note) & 0xFFF), c)
        if channels[c].fineTune & 8 != 0, i > 0 { i -= 1 }
        channels[c].wantedPeriod = periods[table + i]
        channels[c].portamentoDirection = 0
        if channels[c].period == channels[c].wantedPeriod {
            channels[c].wantedPeriod = 0
        } else if channels[c].period > channels[c].wantedPeriod {
            channels[c].portamentoDirection = 1
        }
    }

    private mutating func tonePortamentoStep(_ c: Int) {
        guard channels[c].wantedPeriod > 0 else { return }
        if channels[c].portamentoDirection > 0 {
            channels[c].period &-= Int16(channels[c].portamentoSpeed)
            if channels[c].period <= channels[c].wantedPeriod {
                channels[c].period = channels[c].wantedPeriod
                channels[c].wantedPeriod = 0
            }
        } else {
            channels[c].period &+= Int16(channels[c].portamentoSpeed)
            if channels[c].period >= channels[c].wantedPeriod {
                channels[c].period = channels[c].wantedPeriod
                channels[c].wantedPeriod = 0
            }
        }
        if channels[c].glissFunk & 0xF == 0 {
            paula.setPeriod(c, UInt16(bitPattern: channels[c].period))
        } else {
            // Glissando: only whole notes are heard on the way.
            let table = Int(channels[c].fineTune) * 37
            paula.setPeriod(c, UInt16(bitPattern: periods[table + place(of: Int(channels[c].period), c)]))
        }
    }

    private mutating func tonePortamento(_ c: Int) {
        if channels[c].command & 0xFF != 0 {
            channels[c].portamentoSpeed = UInt8(truncatingIfNeeded: channels[c].command)
            channels[c].command &= 0xFF00
        }
        tonePortamentoStep(c)
    }

    private mutating func vibratoStep(_ c: Int) {
        let at = (channels[c].vibratoPosition >> 2) & 0x1F
        var data: UInt16
        switch channels[c].waveControl & 3 {
        case 0: data = UInt16(proTrackerSine[Int(at)])
        case 1: data = channels[c].vibratoPosition < 128 ? UInt16(at) << 3 : 255 &- UInt16(at) << 3
        default: data = 255
        }
        data = UInt16(truncatingIfNeeded: (Int(data) * Int(channels[c].vibrato & 0xF)) >> 7)
        let period = Int(channels[c].period)
        data = UInt16(truncatingIfNeeded: channels[c].vibratoPosition < 128 ? period + Int(data) : period - Int(data))
        paula.setPeriod(c, data)
        channels[c].vibratoPosition &+= (channels[c].vibrato >> 2) & 0x3C
    }

    private mutating func vibrato(_ c: Int) {
        let command = UInt8(truncatingIfNeeded: channels[c].command)
        if command & 0x0F != 0 { channels[c].vibrato = (channels[c].vibrato & 0xF0) | (command & 0x0F) }
        if command & 0xF0 != 0 { channels[c].vibrato = (command & 0xF0) | (channels[c].vibrato & 0x0F) }
        vibratoStep(c)
    }

    private mutating func tremolo(_ c: Int) {
        let command = UInt8(truncatingIfNeeded: channels[c].command)
        if command & 0x0F != 0 { channels[c].tremolo = (channels[c].tremolo & 0xF0) | (command & 0x0F) }
        if command & 0xF0 != 0 { channels[c].tremolo = (command & 0xF0) | (channels[c].tremolo & 0x0F) }

        let at = (channels[c].tremoloPosition >> 2) & 0x1F
        var data: Int
        switch (channels[c].waveControl >> 4) & 3 {
        case 0: data = Int(proTrackerSine[Int(at)])
        // ProTracker looks at the vibrato's place here where it means the tremolo's.
        case 1: data = channels[c].vibratoPosition < 128 ? Int(at) << 3 : 255 - Int(at) << 3
        default: data = 255
        }
        data = (data * Int(channels[c].tremolo & 0xF)) >> 6
        if channels[c].tremoloPosition < 128 {
            data = min(64, Int(channels[c].volume) + data)
        } else {
            data = max(0, Int(channels[c].volume) - data)
        }
        paula.setVolume(c, UInt16(truncatingIfNeeded: data))
        channels[c].tremoloPosition &+= (channels[c].tremolo >> 2) & 0x3C
    }

    private mutating func sampleOffset(_ c: Int) {
        if channels[c].command & 0xFF != 0 { channels[c].sampleOffset = UInt8(truncatingIfNeeded: channels[c].command) }
        let offset = UInt16(channels[c].sampleOffset) << 7
        if offset < channels[c].length {
            channels[c].length -= offset
            if channels[c].start != -1 { channels[c].start += Int(offset) << 1 }
        } else {
            channels[c].length = 1
        }
    }

    private mutating func setSpeed(_ c: Int) {
        let value = Int32(channels[c].command & 0xFF)
        if value == 0 {
            stopping = true
        } else if value < 32 {
            speed = value
            tick = 0
        } else {
            pendingTempo = value
        }
    }

    private mutating func extended(_ c: Int) {
        let command = channels[c].command
        let value = UInt8(command & 0xF)
        switch (command & 0x00F0) >> 4 {
        case 0x0:
            // The switch is the wrong way up: nothing turns the filter on.
            if tick == 0 { paula.setLightFilter(command & 1 == 0) }
        case 0x1:
            if tick == 0 {
                slideMask = 0xF
                slideUp(c)
            }
        case 0x2:
            if tick == 0 {
                slideMask = 0xF
                slideDown(c)
            }
        case 0x3: channels[c].glissFunk = (channels[c].glissFunk & 0xF0) | value
        case 0x4: channels[c].waveControl = (channels[c].waveControl & 0xF0) | value
        case 0x5: channels[c].fineTune = value
        case 0x6: jumpLoop(c)
        case 0x7: channels[c].waveControl = (value << 4) | (channels[c].waveControl & 0xF)
        case 0x8:
            // A filter run over the sample itself as it plays. Almost every module that has this
            // effect in it means something else by it (a signal to the demo it was written for), and
            // it wrecks their samples: so, as in the tracker this is ported from, it is left out.
            break
        case 0x9:
            if value > 0 {
                if tick == 0, channels[c].note & 0xFFF > 0 { return }
                if tick % Int32(value) == 0 { retrigger(c) }
            }
        case 0xA:
            if tick == 0 { channels[c].volume = min(64, channels[c].volume &+ Int8(value)) }
        case 0xB:
            if tick == 0 { channels[c].volume = max(0, channels[c].volume &- Int8(value)) }
        case 0xC:
            if tick == Int32(value) { channels[c].volume = 0 }
        case 0xD:
            if tick == Int32(value), channels[c].note & 0xFFF > 0 { retrigger(c) }
        case 0xE:
            if tick == 0, patternDelayLeft == 0 { patternDelay = value &+ 1 }
        default:
            if tick == 0 {
                channels[c].glissFunk = (value << 4) | (channels[c].glissFunk & 0xF)
                if channels[c].glissFunk & 0xF0 != 0 { updateFunk(c) }
            }
        }
    }

    /// The effects that act as a row is read.
    private mutating func rowEffects(_ c: Int) {
        let command = channels[c].command
        switch (command & 0x0F00) >> 8 {
        case 0x9: sampleOffset(c)
        case 0xB:
            // To an order that is one before the one meant, which the move to the next order then makes good.
            position = Int16(command & 0xFF) - 1
            breakRow = 0
            jumping = true
        case 0xC:
            channels[c].volume = Int8(truncatingIfNeeded: command)
            if UInt8(bitPattern: channels[c].volume) > 64 { channels[c].volume = 64 }
        case 0xD:
            // The row is written in decimal.
            breakRow = Int8(truncatingIfNeeded: Int((command & 0xF0) >> 4) * 10 + Int(command & 0x0F))
            if UInt8(bitPattern: breakRow) > 63 { breakRow = 0 }
            jumping = true
        case 0xE: extended(c)
        case 0xF: setSpeed(c)
        default: paula.setPeriod(c, UInt16(bitPattern: channels[c].period))
        }
    }

    /// The effects that act on every tick between one row and the next.
    private mutating func tickEffects(_ c: Int) {
        updateFunk(c)
        let command = channels[c].command
        let effect = (command & 0x0F00) >> 8
        if command & 0xFFF != 0 {
            switch effect {
            case 0x0: arpeggio(c)
            case 0x1: slideUp(c)
            case 0x2: slideDown(c)
            case 0x3: tonePortamento(c)
            case 0x4: vibrato(c)
            case 0x5:
                tonePortamentoStep(c)
                volumeSlide(c)
            case 0x6:
                vibratoStep(c)
                volumeSlide(c)
            case 0xE: extended(c)
            default:
                paula.setPeriod(c, UInt16(bitPattern: channels[c].period))
                if effect == 0x7 {
                    tremolo(c)
                } else if effect == 0xA {
                    volumeSlide(c)
                }
            }
        }
        // Tremolo sets the volume it wants itself.
        if effect != 0x7 { paula.setVolume(c, UInt16(truncatingIfNeeded: Int(channels[c].volume))) }
    }

    // MARK: Notes

    private mutating func setPeriod(_ c: Int) {
        let wanted = Int(UInt16(bitPattern: channels[c].note) & 0xFFF)
        var i = 0
        while i < 37, wanted < Int(periods[i]) { i += 1 }
        channels[c].period = periods[Int(channels[c].fineTune) * 37 + i]

        // A note that is to be delayed is not started here.
        if channels[c].command & 0xFF0 != 0xED0 {
            paula.stop(voices: 1 << c)
            if channels[c].waveControl & 0x04 == 0 { channels[c].vibratoPosition = 0 }
            if channels[c].waveControl & 0x40 == 0 { channels[c].tremoloPosition = 0 }
            paula.setLength(c, channels[c].length)
            paula.setLocation(c, channels[c].start)
            if channels[c].start == -1 {
                channels[c].loopStart = -1
                paula.setLength(c, 1)
                channels[c].repeatLength = 1
            }
            paula.setPeriod(c, UInt16(bitPattern: channels[c].period))
            starting |= 1 << c
        }
        rowEffects(c)
    }

    private mutating func playVoice(_ c: Int) {
        if channels[c].note == 0, channels[c].command == 0 { paula.setPeriod(c, UInt16(bitPattern: channels[c].period)) }

        let note = module.note(pattern: Int(pattern), row: Int(row), channel: c)
        if note.period != 0 { playedNote = true }
        channels[c].note = Int16(bitPattern: note.period)
        channels[c].command = UInt16(note.command) << 8 | UInt16(note.parameter)

        if note.sample >= 1, note.sample <= 31 {
            let sample = module.samples[Int(note.sample) - 1]
            channels[c].start = sample.offset
            channels[c].fineTune = sample.fineTune & 0xF
            channels[c].volume = sample.volume
            channels[c].length = UInt16(truncatingIfNeeded: sample.length >> 1)
            channels[c].repeatLength = UInt16(truncatingIfNeeded: sample.loopLength >> 1)
            let repeatStart = UInt16(truncatingIfNeeded: sample.loopStart >> 1)
            if repeatStart > 0 {
                channels[c].loopStart = channels[c].start + Int(repeatStart) << 1
                channels[c].waveStart = channels[c].loopStart
                channels[c].length = repeatStart &+ channels[c].repeatLength
            } else {
                channels[c].loopStart = channels[c].start
                channels[c].waveStart = channels[c].start
            }
            // A voice that has never been given anything to play is given silence.
            if channels[c].length == 0 {
                channels[c].loopStart = ProTrackerModule.silence
                channels[c].waveStart = ProTrackerModule.silence
            }
        }

        let command = channels[c].command
        guard channels[c].note & 0xFFF > 0 else {
            rowEffects(c)
            return
        }
        if command & 0xFF0 == 0xE50 {
            channels[c].fineTune = UInt8(command & 0xF)
            setPeriod(c)
            return
        }
        switch (command & 0x0F00) >> 8 {
        case 3, 5:
            setTonePortamento(c)
            rowEffects(c)
        case 9:
            rowEffects(c)
            setPeriod(c)
        default:
            setPeriod(c)
        }
    }

    private mutating func nextPosition() {
        row = breakRow
        breakRow = 0
        jumping = false
        position = (position &+ 1) & 127
        if Int(position) >= module.songLength {
            position = 0
            wrapped = true
        }
        pattern = Int8(truncatingIfNeeded: module.orders[Int(position)])
        if pattern > Int8(ProTrackerModule.mostPatterns - 1) { pattern = Int8(ProTrackerModule.mostPatterns - 1) }
    }

    /// One tick of the tracker's timer. False when the tick is the last of a pass through the tune:
    /// the next would play a row that has been played before, or the tune has run off its end.
    mutating func runTick() -> Bool {
        if pendingTempo != -1 {
            setTempo(Int(pendingTempo))
            pendingTempo = -1
        }

        tick += 1
        var newRow = false
        if UInt32(bitPattern: tick) >= UInt32(bitPattern: speed) {
            tick = 0
            newRow = true
        }

        if newRow {
            if patternDelayLeft == 0 {
                starting = 0
                if position >= 0, row >= 0 {
                    let at = Int(position) * ProTrackerModule.rows + Int(row)
                    visited[at] = true
                    if let firstPlayedBy, firstPlayedBy[at] == ModuleSongs.unplayed { firstPlayedBy[at] = songNumber }
                    ordersPlayed[Int(position)] = true
                }
                for c in 0 ..< 4 {
                    playVoice(c)
                    paula.setVolume(c, UInt16(truncatingIfNeeded: Int(channels[c].volume)))
                }
                // The voices that have a new note start together, and are then told where to go on
                // from when they reach the end of what they have just been given.
                paula.start(voices: starting)
                for c in 0 ..< 4 {
                    paula.setLocation(c, channels[c].loopStart)
                    paula.setLength(c, channels[c].repeatLength)
                }
            } else {
                for c in 0 ..< 4 { tickEffects(c) }
            }

            row &+= 1
            if patternDelay > 0 {
                patternDelayLeft = patternDelay
                patternDelay = 0
            }
            if patternDelayLeft > 0 {
                patternDelayLeft -= 1
                if patternDelayLeft > 0 { row &-= 1 }
            }
            if breaking {
                row = breakRow
                breakRow = 0
                breaking = false
            }
            if row >= Int8(ProTrackerModule.rows) || jumping { nextPosition() }
        } else {
            for c in 0 ..< 4 { tickEffects(c) }
            if jumping { nextPosition() }
        }

        if stopping {
            stopping = false
            stopped = true
        }

        // The last tick of a row: is the row that comes next one that has been played?
        if patternDelayLeft == 0, tick == speed - 1 {
            let seen = position >= 0 && row >= 0 && visited[Int(position) * ProTrackerModule.rows + Int(row)]
            if !seen, !wrapped, !metEarlierSong, position >= 0, row >= 0, let firstPlayedBy,
               firstPlayedBy[Int(position) * ProTrackerModule.rows + Int(row)] < songNumber {
                // On into what a song before this one played, which from here is part of this one.
                metEarlierSong = true
                ledIntoEarlierSong = true
            }
            if seen || wrapped {
                wrapped = false
                visited.update(repeating: false, count: 128 * ProTrackerModule.rows)
                return false
            }
        }
        return true
    }
}
