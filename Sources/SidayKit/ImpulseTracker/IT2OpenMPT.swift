// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its ways of keeping time (`soundlib/Sndfile.cpp`), and what its own commands and envelopes do
// (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`).

/// What an MPTM file says of its song that an IT file has no way to say, and that Impulse Tracker's
/// replayer has been given the means to play. See `MPTMFile`.
///
/// Impulse Tracker has one way of keeping time: a tempo is so many ticks in two and a half seconds,
/// and a row is so many ticks. OpenMPT has that ("classic"), and two more. In its "alternative" way
/// the tempo is ticks in a second. In its "modern" way the tempo is beats in a minute and a beat is
/// so many rows, so that the speed (ticks to a row) changes how finely a row is cut and not how
/// long it lasts; and the rows of a beat need not be equal ("swing"). A tempo can be a fraction, and
/// can be higher than Impulse Tracker's 255.
struct OpenMPTSong {
    enum TempoMode {
        case classic, alternative, modern
    }

    /// One of the file's lists of patterns ("sequences"), which are its songs. They lie end to end
    /// in the module's one list, with an end of the list between each and the next.
    struct Sequence {
        /// Where in the module's list it starts, and how many places it has.
        var first = 0, count = 0
        /// Where in the module's list it goes on from when it has come to its end.
        var restart = 0
        var speed: UInt8 = 6
        /// Its tempo in ten-thousandths, as OpenMPT keeps one.
        var tempo = 125 * OpenMPTSong.tempoUnit
    }

    /// OpenMPT counts a tempo in ten-thousandths.
    static let tempoUnit = 10000
    /// A swing of this much leaves a row as long as it would have been.
    static let swingUnity: UInt32 = 1 << 24
    /// The slowest and the fastest tempo there can be; a file that says so holds a tempo it is told
    /// to change to, or slid to, to Impulse Tracker's 255.
    static let leastTempo = 32, mostTempo = 1000

    var tempoMode = TempoMode.classic
    /// How many rows make a beat: the song's, and each pattern's own (nought for a pattern that has none).
    var rowsPerBeat = 4
    var patternRowsPerBeat: [UInt16] = []
    /// How long each row of a beat is, against `swingUnity`: the song's, and each pattern's own.
    /// Empty for rows that are all alike.
    var swing: [UInt32] = []
    var patternSwing: [[UInt32]] = []
    /// The highest tempo a command can set or slide to.
    var tempoCeiling = 255
    var sequences: [Sequence] = []
    /// The values that are too long for a command's one byte and go on into the rows below it
    /// (OpenMPT's #xx), each under where its command is (see `place`): the value in the low 24
    /// bits, and above them how many rows it went on into.
    var longValues: [Int: Int] = [:]
    /// True if a key let go moves a volume envelope's level by as much as it has moved since its
    /// "release node", as OpenMPT once had it, and not in proportion.
    var legacyReleaseNode = false
    /// True if a note that is to start beyond the end of its sample starts where it would have
    /// without being told, as Impulse Tracker has it, and not where its loop starts.
    var offsetAsImpulseTracker = false
    /// True unless the file asks for Impulse Tracker's way with a jump on the row of a loop that
    /// goes back, which is that the jump ends the loop: OpenMPT's own is that the loop goes back.
    var loopsOutlastJumps = true
    /// True unless the file asks for Impulse Tracker's way with a note that its instrument has no
    /// sample for, which is to do nothing with the row: OpenMPT's own, until its version 1.32, was
    /// to leave the note out and do what else the row says.
    var unmappedNotesKeepCommands = true
    /// True if vibratos are Impulse Tracker's, finer and by its tables; false for OpenMPT's own,
    /// of ProTracker's sixty-four steps, which is so far followed only for an instrument with a
    /// tuning of its own (see `openMPTTunedVibrato`).
    var itVibrato = true
    /// True if a voice to one side of the middle is no louder on its nearer side than one in the
    /// middle is on both, and only quieter on its further one: OpenMPT's way since its version 1.17
    /// ("soft panning"). Impulse Tracker's, which OpenMPT also has, makes the nearer side louder.
    var softPanning = false
    /// How much louder or quieter than an IT file with the same settings it is to be played.
    var gain: Float = 1
    /// The rows that change a plug-in's setting ("parameter control notes"), each under its
    /// pattern and row as `pattern << 16 | row`. Such a note names a plug-in by its place from 1 (in
    /// eight bits from the twentieth), one of its settings (in ten bits from the tenth) and what
    /// it is to be, of 999 (in the low ten); and the top bit says the setting is to be slid there
    /// over the row and not set at its start.
    var parameterNotes: [Int: [UInt32]] = [:]

    /// A row of a channel of a pattern as one number, for `longValues`.
    static func place(pattern: Int, row: Int, channel: Int) -> Int {
        (pattern << 16) | (row << 6) | channel
    }

    /// The sequence that a place in the module's list is in; the first if it is in none.
    func sequence(at order: Int) -> Sequence {
        sequences.first { order >= $0.first && order < $0.first + max(1, $0.count) } ?? sequences.first ?? Sequence()
    }

    /// The longest a tick can last, in frames: at the slowest tempo, and in the modern way with one
    /// tick to a row, one row to a beat and that row swung as long as a row can be.
    var longestTick: Int {
        switch tempoMode {
        case .classic: outputSampleRate * 5 / (2 * Self.leastTempo) + 1
        case .alternative: outputSampleRate / Self.leastTempo + 1
        case .modern: outputSampleRate * 60 / Self.leastTempo * 4 + 2
        }
    }
}

extension IT2Player {
    // MARK: Keeping time

    /// How many frames the tick just begun lasts in an MPTM file, which is told to the mixer in
    /// place of what Impulse Tracker's tempo would give. To be asked once for every tick: in the
    /// modern way a tick is a whole number of frames, and what is cut off each is kept and made up
    /// in a later one.
    func openMPTTickFrames(_ song: OpenMPTSong) -> Int32 {
        let rate = UInt64(outputSampleRate)
        let tempo = max(1, UInt64(Tempo) * UInt64(OpenMPTSong.tempoUnit) + UInt64(TempoFraction))
        var frames: UInt64
        switch song.tempoMode {
        case .classic:
            frames = rate * 5 * UInt64(OpenMPTSong.tempoUnit) / (tempo << 1)
        case .alternative:
            frames = rate * UInt64(OpenMPTSong.tempoUnit) / tempo
        case .modern:
            let pattern = Int(CurrentPattern)
            var rowsPerBeat = song.rowsPerBeat
            if pattern < song.patternRowsPerBeat.count, song.patternRowsPerBeat[pattern] != 0 { rowsPerBeat = Int(song.patternRowsPerBeat[pattern]) }
            let ticksPerBeat = UInt64(max(1, CurrentSpeed)) * UInt64(max(1, rowsPerBeat))
            var exact = Double(rate) * (60.0 / ((Double(tempo) / Double(OpenMPTSong.tempoUnit)) * Double(ticksPerBeat)))
            var swing = song.swing
            if pattern < song.patternSwing.count, !song.patternSwing[pattern].isEmpty { swing = song.patternSwing[pattern] }
            if !swing.isEmpty {
                exact = exact * Double(swing[Int(CurrentRow) % swing.count]) / Double(OpenMPTSong.swingUnity)
            }
            let whole = exact < 1_000_000 ? Int(exact) : 1_000_000
            frames = UInt64(whole)
            TickRemainder += exact - Double(whole)
            if TickRemainder >= 1 {
                frames += 1
                TickRemainder -= 1
            }
        }
        return Int32(max(1, min(frames, UInt64(song.longestTick))))
    }

    /// A command's value, which in an MPTM file may go on into the rows below (see `OpenMPTSong`),
    /// and how many rows it goes on into: none in any other file, where it is the byte it always was.
    func openMPTLongValue(_ hc: IT2HostPointer) -> Int {
        openMPTLongValueAndRows(hc).value
    }

    private func openMPTLongValueAndRows(_ hc: IT2HostPointer) -> (value: Int, rows: Int) {
        guard let song = module.openMPT, !song.longValues.isEmpty else { return (Int(hc.pointee.CmdVal), 0) }
        let place = OpenMPTSong.place(pattern: Int(CurrentPattern), row: Int(CurrentRow), channel: Int(hc.pointee.HostChnNum))
        guard let long = song.longValues[place] else { return (Int(hc.pointee.CmdVal), 0) }
        return (long & 0xFF_FFFF, long >> 24)
    }

    // MARK: Commands that are OpenMPT's own

    /// :xy, the note started after x ticks and cut y ticks after that. It is S's delay and then S's
    /// cut, and they are left to do it.
    func InitCommandDelayCut(_ hc: IT2HostPointer) {
        let delay = hc.pointee.CmdVal >> 4, length = hc.pointee.CmdVal & 0x0F
        hc.pointee.MiscEfxData[2] = length
        if delay == 0 {
            InitNoCommand(hc)
            beginCut(hc)
        } else {
            hc.pointee.MiscEfxData[0] = 0xD0
            hc.pointee.MiscEfxData[1] = delay
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
        }
    }

    /// OpenMPT's finetune: the channel's notes are bent, by as much as their instrument allows at
    /// the most, to where the command's value (a byte, and another if the row below goes on with
    /// it) is from the middle. A smooth one goes a share of the way there each tick of its row.
    func InitCommandBend(_ hc: IT2HostPointer, smooth: Bool) {
        InitNoCommand(hc)
        if smooth {
            hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
            CommandBend(hc)
        } else {
            hc.pointee.Bend = bendTarget(hc)
        }
    }

    func CommandBend(_ hc: IT2HostPointer) {
        let target = Int(bendTarget(hc)), now = Int(hc.pointee.Bend)
        // (As many ticks as are left of the row, this among them, and of its repeats.)
        let left = Int(CurrentTick) + (RowDelayOn ? (Int(RowDelay) - 1) * Int(CurrentSpeed) : 0)
        hc.pointee.Bend = Int16(clamping: left > 1 ? now + (target - now) / left : target)
    }

    private func bendTarget(_ hc: IT2HostPointer) -> Int16 {
        let (value, rows) = openMPTLongValueAndRows(hc)
        return Int16(clamping: (rows > 0 ? value : value << 8) - 0x8000)
    }

    /// A voice's pitch, bent by its channel's finetune at the end of a tick, after everything else
    /// has moved it: by as many semitones at the most as its instrument says, either way.
    func openMPTBend(_ sc: IT2SlavePointer) {
        if sc.pointee.HostChnNum & CHN_DISOWNED == 0, let hc = sc.pointee.HostChnPtr { sc.pointee.Bend = hc.pointee.Bend }
        guard sc.pointee.Bend != 0, sc.pointee.Ins != 0xFF, let ins = sc.pointee.InsPtr, ins.PitchWheelDepth != 0 else { return }
        let bend = Int(sc.pointee.Bend) * Int(ins.PitchWheelDepth)
        let rate = (Double(sc.pointee.Frequency) * pow(2.0, Double(bend) / (12 * 256 * 128))).rounded()
        sc.pointee.Frequency = rate >= 0 && rate < Double(Int32.max) ? Int32(rate) : Int32.max
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// A row's note and instrument, for a channel of an MPTM file, as OpenMPT sees to them: an
    /// instrument named takes the bend away, unless the note slides from the last on the same
    /// instrument; and a note that is struck starts its channel's vibrato from the top of its wave,
    /// which in Impulse Tracker only a vibrato on the note's own row does.
    func openMPTRow(_ hc: IT2HostPointer) {
        let mask = hc.pointee.NotePackMask
        guard mask & 0x33 != 0 else { return }
        let slides = mask & 0x88 != 0 && (hc.pointee.Cmd == 7 || hc.pointee.Cmd == 12) || mask & 0x44 != 0 && hc.pointee.RawVolColumn >= 193 && hc.pointee.RawVolColumn <= 202
        let sliding = slides && hc.pointee.Flags & HF_CHAN_ON != 0
        if mask & 0x22 != 0, hc.pointee.Bend != 0, !sliding || hc.pointee.SlaveChnPtr?.pointee.Ins != hc.pointee.Ins { hc.pointee.Bend = 0 }
        if mask & 0x11 != 0, hc.pointee.RawNote < 120, !sliding, module.openMPT?.itVibrato == true { hc.pointee.VibratoPos = 0 }
    }

    private func beginCut(_ hc: IT2HostPointer) {
        hc.pointee.MiscEfxData[0] = 0xC0
        hc.pointee.MiscEfxData[1] = hc.pointee.MiscEfxData[2]
        if hc.pointee.MiscEfxData[2] == 0 {
            // Cut on the tick it starts: it is not heard.
            if hc.pointee.Flags & HF_CHAN_ON != 0 {
                hc.pointee.Flags &= ~HF_CHAN_ON
                hc.pointee.SlaveChnPtr?.pointee.Flags |= SF_NOTE_STOP
            }
        } else {
            hc.pointee.Flags |= HF_UPDATE_EFX_IF_CHAN_ON
        }
    }

    func CommandDelayCut(_ hc: IT2HostPointer) {
        let delayed = hc.pointee.MiscEfxData[0] == 0xD0
        CommandS(hc)
        // The delay is over when S's delay has taken its flags away, having started the note.
        if delayed, hc.pointee.Flags & HF_ALWAYS_UPDATE_EFX == 0 { beginCut(hc) }
    }

    /// The command after Z, in a file of ModPlug Tracker's or OpenMPT's: Z's macro, sent on every
    /// tick of the row, and what it sets the filter, or a plug-in, to come to a little at a time,
    /// so that it is where the macro puts it only on the row's last tick.
    func InitCommandSmoothMacro(_ hc: IT2HostPointer) {
        InitCommandZ(hc, comingTo: true)
        hc.pointee.Flags |= HF_ALWAYS_UPDATE_EFX
    }

    func CommandSmoothMacro(_ hc: IT2HostPointer) {
        sendMacro(hc, comingTo: true)
    }

    /// Sends the macro a channel's Z or its like asks for.
    /// - Parameter comingTo: true to bring the filter only as far towards what the macro sets it
    ///   to as the ticks left of the row allow: a part of the way that is one over their number.
    func sendMacro(_ hc: IT2HostPointer, comingTo: Bool) {
        // (The voice is whichever the channel last had, playing or not.)
        let sc = hc.pointee.SlaveChnPtr
        let channel = Int(hc.pointee.HostChnNum) & 63
        let cutoff = FilterParameters[channel], resonance = FilterParameters[64 + channel]
        let left = Int(CurrentTick) + (RowDelayOn ? (Int(RowDelay) - 1) * Int(CurrentSpeed) : 0)
        // (A plug-in's setting is brought nearer as it is sent: see `modPlugMacro`.)
        macroTicksLeft = comingTo ? left : 0
        defer { macroTicksLeft = 0 }
        if hc.pointee.CmdVal >= 0x80 {
            MIDITranslate(hc, sc, 0x320 + (UInt16(hc.pointee.CmdVal & 0x7F) << 5))
        } else {
            MIDITranslate(hc, sc, 0x120 + (UInt16(hc.pointee.EfxMem_SFx & 0xF) << 5))
        }
        guard comingTo, left > 1 else { return }
        func nearer(_ from: UInt8, _ to: UInt8) -> UInt8 {
            UInt8(max(0, min(127, Int((Float(from) + Float(Int(to) - Int(from)) / Float(left)).rounded()))))
        }
        FilterParameters[channel] = nearer(cutoff, FilterParameters[channel])
        FilterParameters[64 + channel] = nearer(resonance, FilterParameters[64 + channel])
    }

    /// What S9x does in an MPTM file beyond surround: S9E and S9F play the channel's sample
    /// forwards and backwards. (S98 and S99, its reverb, are seen to with S91; the rest are to do with
    /// four speakers and with how a note's filter starts, and are not here.)
    func OpenMPTCommandS9(_ hc: IT2HostPointer, _ value: UInt8) {
        switch value {
        case 0xE:
            guard hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr else { return }
            sc.pointee.LoopDirection = DIR_FORWARDS
            if sc.pointee.Backwards != 0 {
                sc.pointee.Backwards = 0
                GetLoopInformation(sc)
            }
        case 0xF:
            guard hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr, let s = sc.pointee.SmpPtr, s.Length > 0 else { return }
            GetLoopInformation(sc)
            let loops = sc.pointee.LoopMode != 0
            let rowHasNote = hc.pointee.NotePackMask & 0x11 != 0 && hc.pointee.RawNote < 120
            // A note just started is started from its end, or from the end of its loop.
            if sc.pointee.SamplingPosition == 0, sc.pointee.Frac64 == 0, rowHasNote || !loops {
                sc.pointee.SamplingPosition = sc.pointee.LoopEnd &- 1
                sc.pointee.Frac64 = 0xFFFF_FFFF
            }
            // The mixer goes backwards only within a loop that goes back and forth, so that is what
            // it is given: the whole sample, for one that does not loop, which it is to end at the
            // start of; and a loop that goes round is played as if it went back and forth.
            if !loops {
                sc.pointee.LoopBegin = 0
                sc.pointee.LoopEnd = Int32(truncatingIfNeeded: min(s.Length, UInt32(Int32.max)))
                sc.pointee.Backwards = BACKWARDS_ONCE
            } else if sc.pointee.LoopMode != LOOP_PINGPONG {
                sc.pointee.Backwards = BACKWARDS_LOOP
            }
            sc.pointee.LoopMode = LOOP_PINGPONG
            sc.pointee.LoopDirection = DIR_BACKWARDS
            sc.pointee.Flags |= SF_LOOP_CHANGED
        default:
            break
        }
    }

    /// Which of the volume column's ten ways of starting a note from further into its sample a row
    /// of an MPTM file has: 1 to 9 for the nine places that the sample itself names ("cue points"),
    /// nought for where the channel's last note started, and nil for none of them.
    private func volumeColumnOffset(_ hc: IT2HostPointer) -> Int? {
        guard hc.pointee.NotePackMask & 0x44 != 0, hc.pointee.RawVolColumn >= 223, hc.pointee.RawVolColumn <= 232 else { return nil }
        return Int(hc.pointee.RawVolColumn) - 223
    }

    /// Starts a voice's note from a place in its sample. Past the end of the sample, or of its loop,
    /// the note starts where the loop does; or with "old effects" at the very end, as Impulse
    /// Tracker has it; or, in a file that asks for Impulse Tracker's way, where it would have anyway.
    private func startNote(_ hc: IT2HostPointer, _ sc: IT2SlavePointer, at offset: UInt32) {
        var offset = offset
        if offset >= UInt32(bitPattern: max(0, sc.pointee.LoopEnd)) {
            if module.Flags & ITF_OLD_EFFECTS != 0 {
                offset = UInt32(bitPattern: max(0, sc.pointee.LoopEnd &- 1))
            } else if module.openMPT?.offsetAsImpulseTracker == true {
                return
            } else {
                offset = UInt32(bitPattern: max(0, sc.pointee.LoopBegin))
            }
        }
        sc.pointee.SamplingPosition = Int32(bitPattern: offset)
        sc.pointee.Frac32 = 0
        sc.pointee.Frac64 = 0
    }

    /// A note of an MPTM file started by the volume column's offset alone. (With Oxx beside it the
    /// two are reckoned together: see `OpenMPTCommandO`.)
    func OpenMPTVolumeColumnOffset(_ hc: IT2HostPointer, _ sc: IT2SlavePointer) {
        guard let which = volumeColumnOffset(hc), hc.pointee.Cmd & 31 != 15 else { return }
        var offset = hc.pointee.OffsetMemory
        if which > 0 {
            guard let s = sc.pointee.SmpPtr, which <= s.cues.count else { return }
            offset = s.cues[which - 1]
            hc.pointee.OffsetMemory = offset
        }
        startNote(hc, sc, at: offset)
    }

    /// Oxx in an MPTM file, whose row's note has just been started. The offset may go on into the
    /// rows below (#xx), and is then counted in samples and not in 256s of them. With the volume
    /// column's offset beside it, it is counted from the cue point that names; and with the volume
    /// column's "where the last note started", it is a part of the whole sample, of 256.
    func OpenMPTCommandO(_ hc: IT2HostPointer, _ sc: IT2SlavePointer) {
        let (long, rows) = openMPTLongValueAndRows(hc)
        let which = volumeColumnOffset(hc)
        var offset = UInt32(truncatingIfNeeded: long), high: UInt32 = 0
        if rows == 0 {
            offset = UInt32(hc.pointee.CmdVal) << 8
            if offset != 0 {
                hc.pointee.OffsetMemory = offset
            } else if which == nil {
                offset = hc.pointee.OffsetMemory
            }
            if which != 0 { high = UInt32(hc.pointee.HighSmpOffs) << 16 }
        }
        if let which {
            if which == 0 {
                let length = UInt64(UInt32(bitPattern: max(0, sc.pointee.LoopEnd)))
                let whole: UInt64 = rows > 1 ? 1 << 24 : 1 << 16
                offset = UInt32(truncatingIfNeeded: (length * UInt64(offset) + whole / 2) / whole)
            } else if let s = sc.pointee.SmpPtr, which <= s.cues.count {
                offset &+= s.cues[which - 1]
            }
            hc.pointee.OffsetMemory = offset
        }
        startNote(hc, sc, at: offset &+ high)
    }

    // MARK: Plug-ins' settings

    /// A plug-in's setting on its way to where a row said it was to be by the row's end.
    struct ParameterSlide {
        var place: Int, index: Int
        var target: Float, step: Float
        var ticksLeft: Int
    }

    /// What an MPTM file's rows say of its plug-ins' settings, done for the tick just begun: a
    /// setting is set on a row's first tick, or slid over its ticks and set exactly on the last.
    func openMPTParameterNotes(_ song: OpenMPTSong) {
        if RowJustRead {
            parameterSlides.removeAll(keepingCapacity: true)
            for note in song.parameterNotes[Int(CurrentPattern) << 16 | Int(CurrentRow)] ?? [] {
                let place = Int(note >> 20 & 0xFF) - 1, index = Int(note >> 10 & 0x3FF)
                let value = Float(note & 0x3FF) / 999
                if note >> 31 == 0 {
                    mixer.setPlugInParameter(place: place, index, value)
                } else {
                    let ticks = max(1, Int(CurrentSpeed))
                    let step = (value - mixer.plugInParameter(place: place, index)) / Float(ticks)
                    parameterSlides.append(ParameterSlide(place: place, index: index, target: value, step: step, ticksLeft: ticks))
                }
            }
        }
        for slide in parameterSlides.indices where parameterSlides[slide].ticksLeft > 0 {
            parameterSlides[slide].ticksLeft -= 1
            let now = parameterSlides[slide]
            if now.ticksLeft == 0 {
                mixer.setPlugInParameter(place: now.place, now.index, now.target)
            } else {
                mixer.setPlugInParameter(place: now.place, now.index, now.step, slide: true)
            }
        }
    }

    /// A MIDI macro has addressed a plug-in, which is how ModPlug Tracker and OpenMPT let a Zxx
    /// command reach one: `code` 3 for how much of what the plug-in is given is heard beside what
    /// it makes, and 128 and upwards for its settings, each to `value` of 127. The plug-in is the
    /// channel's, or failing that the one its instrument plays through.
    func modPlugMacro(_ hc: IT2HostPointer, code: UInt8, value: UInt8) {
        guard let sound else { return }
        let channel = Int(hc.pointee.HostChnNum)
        var plugIn = channel < sound.channelPlugIns.count ? sound.channelPlugIns[channel] : 0
        if plugIn == 0, module.Flags & ITF_INSTR_MODE != 0, hc.pointee.Ins >= 1, Int(hc.pointee.Ins) <= module.InsNum {
            plugIn = Int(module.instrument(Int(hc.pointee.Ins) - 1).MixPlug)
        }
        guard plugIn > 0 else { return }
        // Sent a little at a time over a row, a value is brought as far towards where it is to be as
        // the ticks left of the row allow, and set exactly on the last (see `sendMacro`).
        func nearer(_ now: Float, _ wanted: Float) -> Float {
            macroTicksLeft > 1 ? now + (wanted - now) / Float(macroTicksLeft) : wanted
        }
        if code == 3 {
            mixer.setPlugInDryRatio(place: plugIn - 1, nearer(mixer.plugInDryRatio(place: plugIn - 1), Float(127 - Int(value)) / 127))
        } else if code >= 0x80 {
            let index = Int(code & 0x7F)
            mixer.setPlugInParameter(place: plugIn - 1, index, nearer(mixer.plugInParameter(place: plugIn - 1, index), Float(value) / 127))
        }
    }

    // MARK: Tunings

    // An instrument with a tuning of its own (see `OpenMPTTuning`) is played as OpenMPT plays one,
    // which is not as it plays any other: a note's pitch is not a rate that slides and vibratos
    // move, but is worked out afresh from the note, the number of the tuning's fine steps the slides
    // have taken it from there, and the tick's vibrato, whenever one of those has changed. A slide
    // up or down moves it by so many fine steps a tick, a slide to a note by so many a row, an
    // arpeggio by whole notes of the tuning, and a vibrato by a ratio of up to a twentieth either way.
    // What OpenMPT keeps for this is kept on the channel (`IT2TunedChannel`), and in a copy on its
    // voice, which is the voice's own once its channel goes on to another note.

    /// The rate of a note of an instrument that has a tuning of its own, before anything has moved
    /// it: the sample's rate at middle C by what the tuning makes of the note.
    func openMPTTunedFrequency(_ s: IT2Sample?, _ ratio: Float) -> Int32 {
        let rate = (Float(s?.C5Speed ?? 0) * ratio).rounded()
        return rate >= 0 && rate < 2_147_483_520 ? Int32(rate) : 0
    }

    /// The tuning of the instrument a channel has, if it has one of its own.
    @inline(__always) func tuning(of hc: IT2HostPointer) -> OpenMPTTuning? {
        guard tunings, hc.pointee.Ins >= 1, hc.pointee.Ins != 0xFF, Int(hc.pointee.Ins) <= module.InsNum else { return nil }
        return module.instrument(Int(hc.pointee.Ins) - 1).Tuning
    }

    /// A row's note and instrument, for a channel whose instrument has a tuning of its own: an
    /// instrument named puts the slides' fine steps back to none, and a note with a slide to it
    /// leaves the pitch where it was and has the slide go from there.
    func openMPTTunedRow(_ hc: IT2HostPointer) {
        let mask = hc.pointee.NotePackMask
        guard mask & 0x33 != 0, let tuning = tuning(of: hc) else { return }
        let note = hc.pointee.RawNote
        let slides = mask & 0x88 != 0 && (hc.pointee.Cmd == 7 || hc.pointee.Cmd == 12) || mask & 0x44 != 0 && hc.pointee.RawVolColumn >= 193 && hc.pointee.RawVolColumn <= 202
        // (A slide to a note with nothing sounding is a note.)
        let sliding = slides && hc.pointee.Flags & HF_CHAN_ON != 0
        if mask & 0x22 != 0 {
            hc.pointee.Tuned.fine = 0
            hc.pointee.Tuned.slideLeft = 0
            hc.pointee.Tuned.steps = 0
            hc.pointee.Tuned.again = true
        }
        guard mask & 0x11 != 0, note < 120 else { return }
        if sliding {
            hc.pointee.Tuned.slideLeft = (Int32(hc.pointee.TranslatedNote) - Int32(hc.pointee.Tuned.note)) * Int32(tuning.fineSteps + 1) - hc.pointee.Tuned.steps
            hc.pointee.Tuned.steps = -hc.pointee.Tuned.slideLeft
        } else {
            hc.pointee.Tuned.slideLeft = 0
        }
        hc.pointee.Tuned.note = note
        hc.pointee.Tuned.played = hc.pointee.TranslatedNote
        hc.pointee.Tuned.again = true
        // (And a vibrato starts again from the top of its wave; in OpenMPT's own way, a quarter
        // of the way along, but for a file with "old effects".)
        if !sliding {
            if module.openMPT?.itVibrato != false {
                hc.pointee.VibratoPos = 0
            } else {
                hc.pointee.Tuned.vibratoPos = module.Flags & ITF_OLD_EFFECTS != 0 ? 0 : 0x10
            }
        }
    }

    /// Exx and Fxx (and the volume column's), for a channel whose instrument has a tuning of its
    /// own: so many fine steps every tick, the first among them; EFx and FFx so many over the row,
    /// a share each tick; and EEx and FEx so many now. Down is less than nought.
    func openMPTTunedSlide(_ hc: IT2HostPointer, _ param: Int32, alwaysWhole: Bool = false) {
        let size = abs(param), way: Int32 = param < 0 ? -1 : 1
        if !alwaysWhole, size >= 0xF0 {
            let param = way * (size - 0xF0)
            if tickOfRow == 0 { hc.pointee.Tuned.fineSlideDone = 0 }
            let share = Int32(Double(tickOfRow + 1) * Double(param) / Double(CurrentSpeed))
            let done = Int32(hc.pointee.Tuned.fineSlideDone)
            hc.pointee.Tuned.steps &+= param >= 0 ? share - done : share + done
            hc.pointee.Tuned.fineSlideDone = Int8(truncatingIfNeeded: tickOfRow + 1 == Int(CurrentSpeed) ? abs(param) : abs(share))
        } else if !alwaysWhole, size >= 0xE0 {
            if tickOfRow == 0 { hc.pointee.Tuned.steps &+= way * (size - 0xE0) }
        } else {
            hc.pointee.Tuned.steps &+= param
        }
        hc.pointee.Tuned.again = true
    }

    /// A tick of Gxx, for a channel whose instrument has a tuning of its own: so many fine steps a
    /// row (or whole notes, after S11), a share of them each tick, until the note is reached.
    func openMPTTunedSlideToNote(_ hc: IT2HostPointer, _ param: UInt8) {
        guard param != 0, let tuning = tuning(of: hc) else { return }
        let before = tickOfRow != 0 ? hc.pointee.Tuned.slideRow : 0
        let speed = Int32(param) * (hc.pointee.Tuned.slideLeft < 0 ? -1 : 1)
        hc.pointee.Tuned.slideRow = Int32(Double(tickOfRow + 1) * Double(speed) / Double(CurrentSpeed))
        if hc.pointee.Tuned.glissando { hc.pointee.Tuned.slideRow &*= Int32(tuning.fineSteps + 1) }
        let slide = hc.pointee.Tuned.slideRow &- before
        if abs(hc.pointee.Tuned.slideLeft) <= abs(slide) {
            if hc.pointee.Tuned.slideLeft != 0 {
                hc.pointee.Tuned.steps &+= hc.pointee.Tuned.slideLeft
                hc.pointee.Tuned.slideLeft = 0
                hc.pointee.Tuned.again = true
            }
        } else {
            hc.pointee.Tuned.steps &+= slide
            hc.pointee.Tuned.slideLeft &-= slide
            hc.pointee.Tuned.again = true
        }
    }

    /// A tick of vibrato, for a channel whose instrument has a tuning of its own: the wave's point,
    /// of 64, at the depth OpenMPT has for it (or in OpenMPT's own way of vibrato, a point of its own). The pitch is worked out again at the next row's first
    /// tick too, when the vibrato may be over.
    func openMPTTunedVibrato(_ hc: IT2HostPointer, _ wave: Int8) {
        let old = module.Flags & ITF_OLD_EFFECTS != 0
        let depth = Int(hc.pointee.VibratoDepth) >> (old ? 1 : 0)
        var wave = Int(wave)
        if module.openMPT?.itVibrato == false {
            // OpenMPT's own way: a wave of 64 steps and of 127 a side, moved on after it is read,
            // and not on a row's first tick with "old effects".
            let position = Int(hc.pointee.Tuned.vibratoPos) & 0x3F
            switch hc.pointee.VibratoWaveform & 3 {
            case 1: wave = (position < 32 ? 0 : 255) - position * 4
            case 2: wave = position < 32 ? 127 : -127
            case 3: wave = Int(openMPTRandomWave[position])
            default: wave = Int(openMPTSineWave[position])
            }
            if tickOfRow != 0 || !old { hc.pointee.Tuned.vibratoPos &+= hc.pointee.VibratoSpeed >> 2 }
        }
        hc.pointee.Tuned.vibrato += 0.05 * Float(wave * depth) / (128 * 60)
        hc.pointee.Tuned.again = true
        hc.pointee.Tuned.againAtRow = tickOfRow + 1 == Int(CurrentSpeed)
    }

    /// A tick of Jxy, for a channel whose instrument has a tuning of its own: the note, then x
    /// notes of the tuning higher, then y.
    func openMPTTunedArpeggio(_ hc: IT2HostPointer) {
        switch tickOfRow % 3 {
        case 1: hc.pointee.Tuned.arpeggio = Int32(hc.pointee.EfxMem_J >> 4)
        case 2: hc.pointee.Tuned.arpeggio = Int32(hc.pointee.EfxMem_J & 0x0F)
        default: hc.pointee.Tuned.arpeggio = 0
        }
        hc.pointee.Tuned.again = true
        hc.pointee.Tuned.againAtRow = true
    }

    /// A tick of a sample's own vibrato in an MPTM file that asks for Impulse Tracker's ways with
    /// vibrato, as OpenMPT has those: the wave is read where it was before it moves on (Impulse
    /// Tracker's replayer moves it first), its depth is divided towards nought, and the pitch is
    /// moved by the slide tables' coarse step and fine step together.
    func openMPTAutoVibrato(_ sc: IT2SlavePointer, _ smp: IT2Sample) {
        guard smp.AutoVibratoSpeed != 0 else { return }
        let position = Int(sc.pointee.AutoVibratoPos)
        let depth = min(Int(sc.pointee.AutoVibratoDepth) + Int(smp.AutoVibratoRate), Int(smp.AutoVibratoDepth) * 256)
        sc.pointee.AutoVibratoDepth = UInt16(depth)
        sc.pointee.AutoVibratoPos &+= smp.AutoVibratoSpeed
        var wave: Int
        switch smp.AutoVibratoWaveform {
        case 1: wave = 64 - (position + 1) / 2 // a ramp down
        case 2: wave = position < 128 ? 64 : 0 // a square
        case 3: wave = Int(Random() & 127) - 64
        case 4: wave = (position + 1) / 2 - 64 // a ramp up
        default: wave = Int(it2FineSineData[position])
        }
        wave = wave * (depth / 256) / 64
        guard wave != 0 else { return }
        // (In 256ths of the rate, as OpenMPT reckons it.)
        let steps = abs(wave), rate = Int64(sc.pointee.Frequency) * 256
        func step(_ factor: UInt32) -> Int64 { rate * Int64(factor) / 65536 - rate }
        var moved: Int64
        if wave < 0 {
            moved = step(UInt32(it2LinearSlideDownTable[min(256, steps / 4)]))
            if steps & 3 != 0 { moved += step(UInt32(it2FineLinearSlideDownTable[steps & 3])) }
        } else {
            moved = step(it2LinearSlideUpTable[min(256, steps / 4)])
            if steps & 3 != 0 { moved += step(it2FineLinearSlideUpTable[steps & 3]) }
        }
        sc.pointee.Frequency = Int32(truncatingIfNeeded: min(Int64(Int32.max), (rate + moved) / 256))
        sc.pointee.Flags |= SF_FREQ_CHANGE
    }

    /// A tick of an instrument's pitch envelope, for one with a tuning of its own: so many of the
    /// tuning's fine steps, eight to each of the envelope's half-semitones. (The envelope's place,
    /// which OpenMPT reads to 512 a side, is here to 65,536 times the half-semitones.)
    func openMPTTunedPitchEnvelope(_ sc: IT2SlavePointer) {
        let fine = (sc.pointee.PitchEnvState.Value &+ 4096) >> 13
        if sc.pointee.HostChnNum & CHN_DISOWNED == 0, let hc = sc.pointee.HostChnPtr {
            if hc.pointee.Tuned.fine != fine {
                hc.pointee.Tuned.fine = fine
                hc.pointee.Tuned.again = true
            }
        } else if sc.pointee.Tuned.fine != fine {
            sc.pointee.Tuned.fine = fine
            sc.pointee.Tuned.again = true
        }
    }

    /// A tick of a sample's own vibrato, for a voice of an instrument that has a tuning of its own,
    /// which OpenMPT plays at the sample's depth from the start and in a way of its own.
    func openMPTTunedAutoVibrato(_ sc: IT2SlavePointer, _ smp: IT2Sample) {
        sc.pointee.AutoVibratoPos &+= smp.AutoVibratoSpeed
        let position = Int(sc.pointee.AutoVibratoPos)
        let wave: Int
        switch smp.AutoVibratoWaveform {
        case 1: wave = ((0x40 - position / 2) & 0x7F) - 0x40 // a ramp down
        case 2: wave = position & 128 != 0 ? 64 : -64 // a square
        case 3: // at random, from a table
            wave = Int(openMPTRandomWave[position & 0x3F])
            sc.pointee.AutoVibratoPos &+= 1
        case 4: wave = ((0x40 + position / 2) & 0x7F) - 0x40 // a ramp up
        default: wave = -Int(it2FineSineData[position])
        }
        sc.pointee.TunedAutoVibrato = 0.05 * Float(Int(smp.AutoVibratoDepth) * wave) / 4096
    }

    /// A voice's pitch at the end of a tick, for an instrument with a tuning of its own: worked
    /// out again if anything has moved it, from what its channel keeps (or, for a voice its
    /// channel has let go of, what the voice kept).
    func openMPTTunedPitch(_ sc: IT2SlavePointer) {
        guard sc.pointee.Ins != 0xFF, let tuning = sc.pointee.InsPtr?.Tuning else { return }
        let hc = sc.pointee.HostChnNum & CHN_DISOWNED == 0 ? sc.pointee.HostChnPtr : nil
        if let hc { sc.pointee.Tuned = hc.pointee.Tuned }
        var t = sc.pointee.Tuned
        let auto = sc.pointee.TunedAutoVibrato
        if t.again || auto != nil || (t.againAtRow && tickOfRow == 0) {
            var vibrato = t.vibrato
            if let auto { vibrato += auto }
            let ratio = tuning.ratio(Int(t.played) - 60 + Int(t.arpeggio), fine: Int(t.fine &+ t.steps))
            // (OpenMPT's rate has four bits of fraction, which a note for the FM chip keeps.)
            let sixteenths = (Float(sc.pointee.SmpPtr?.C5Speed ?? 0) * vibrato * ratio * 16).rounded()
            let rate = sixteenths >= 0 && sixteenths < 4_294_967_040 ? UInt32(sixteenths) : UInt32.max
            let fine = fineFMPitch && sc.pointee.SmpPtr?.AdLib != nil
            let frequency = Int32(truncatingIfNeeded: fine ? min(rate, UInt32(Int32.max)) : (rate &+ 8) >> 4)
            if t.again || auto != nil { t.again = false } else { t.againAtRow = false }
            sc.pointee.Frequency = frequency
            sc.pointee.FrequencySet = frequency
            sc.pointee.Flags |= SF_FREQ_CHANGE
        }
        t.vibrato = 1
        t.arpeggio = 0
        sc.pointee.Tuned = t
        sc.pointee.TunedAutoVibrato = nil
        if let hc { hc.pointee.Tuned = t }
    }

    // MARK: Envelopes

    /// A key has been let go on a voice whose volume envelope names a point to go to then (its
    /// "release node"): the envelope goes on from that point, and from then on its level is taken
    /// against what it was when the key was let go. Returns that.
    func openMPTRelease(_ sc: IT2SlavePointer, _ env: borrowing IT2Envelope) {
        let node = Int(env.ReleaseNode)
        guard node < Int(env.Num), node < env.Tick.count else { return }
        sc.pointee.ReleaseLevel = Int16(truncatingIfNeeded: max(0, min(64 << 2, (sc.pointee.VolEnvState.Value >> 14))))
        sc.pointee.VolEnvState.CurNode = (sc.pointee.VolEnvState.CurNode & Int16(bitPattern: 0xFF00)) | Int16(UInt8(truncatingIfNeeded: node))
        sc.pointee.VolEnvState.Tick = Int16(bitPattern: env.Tick[node])
        sc.pointee.VolEnvState.NextTick = sc.pointee.VolEnvState.Tick
    }

    /// The level of a volume envelope that has gone on from its release node, of 64 with eight bits
    /// of fraction as the replayer takes one: what the envelope says, moved to where the level was
    /// when the key was let go.
    func openMPTReleasedLevel(_ sc: IT2SlavePointer, _ env: borrowing IT2Envelope, _ level: Int) -> Int {
        let node = Int(env.ReleaseNode)
        guard node < env.Magnitude.count else { return level }
        // (OpenMPT's levels are of 256.)
        let now = level >> 6, atJump = Int(sc.pointee.ReleaseLevel), atNode = Int(env.Magnitude[node]) * 4
        var moved: Int
        if module.openMPT?.legacyReleaseNode == true {
            moved = atJump + (now - atNode) * 2
        } else {
            moved = atNode > 0 ? atJump * now / atNode : 0
        }
        moved = max(0, min(512, moved))
        return moved << 6
    }
}
