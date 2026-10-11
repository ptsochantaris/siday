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
    /// True if a voice to one side of the middle is no louder on its nearer side than one in the
    /// middle is on both, and only quieter on its further one: OpenMPT's way since its version 1.17
    /// ("soft panning"). Impulse Tracker's, which OpenMPT also has, makes the nearer side louder.
    var softPanning = false
    /// How much louder or quieter than an IT file with the same settings it is to be played.
    var gain: Float = 1

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

    /// What S9x does in an MPTM file beyond surround: S9E and S9F play the channel's sample
    /// forwards and backwards. (The rest are to do with OpenMPT's reverb and its ways of putting
    /// sound between four speakers, which are not here.)
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
