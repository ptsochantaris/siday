// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's sequencer and patterns of TFMX (src/Chris/Sequencer.cpp and
// Pattern.cpp), Copyright (C) Michael Schwendt, used under the GPL-2.0-or-later, as it is at its
// commit dcec102 of 2026-09-26.

// The track table is a step of sixteen bytes for each line of the song: for each of eight tracks a
// pattern (PT) and a transposition or voice (TR), or, after $EFFE, a command to the song: Stop, Loop,
// Speed, 7VOICE or Fade. How long the table is cannot be told for certain (some files have what looks
// like patterns before their first), so a song's steps are not checked against it.
//
// A pattern is a list of four bytes, aa bb cd ee: a note aa (below $F0) for macro bb, with volume c,
// voice d and detune ee, or a command to the pattern ($F0 to $FF).

extension TFMXDecoder {
    /// Whether a track is heard: the header's word for each track is nought for one that is. (Few files
    /// mute any, and in two that do, a voice goes missing.)
    func getTrackMute(_ t: Int) -> Bool {
        if variant.noTrackMute { return true }
        return word(offsets.header &+ 0x1C0 &+ UInt32(t << 1)) == 0
    }

    mutating func resetSequencer() {
        sequencer.current = sequencer.first
        sequencer.next = false
        sequencer.loops = -1
        sequencer.stepSeenBefore = InlineArray(repeating: false)
    }

    /// On to the next step, or back to the first after the last, which is the song's end. (The last is
    /// checked for exactly, as the Loop command can jump past it.)
    mutating func nextTrackStep() {
        if sequencer.current == sequencer.last {
            sequencer.current = sequencer.first
            songEnd = true
        } else {
            sequencer.current += 1
        }
        processTrackStep()
        sequencer.next = true
    }

    mutating func processTrackStep() {
        var evalMaxLoops = Self.recurseLimit
        repeat {
            sequencer.evalNext = false
            if sequencer.current > 511 { sequencer.current = sequencer.first }
            // (A first step beyond the table's 512 would be marked outside it in the library, which is
            // undefined, and is not marked here.)
            if sequencer.current < 512 { sequencer.stepSeenBefore[sequencer.current] = true }

            var stepOffset = offsets.trackTable &+ UInt32(truncatingIfNeeded: sequencer.current << 4)
            // TFMX 1.x, $e5e: $FA00, $FA01 and $FA02 are Stop, Loop and Speed too, their arguments
            // straight after.
            let older = variant.original == .tfmx && word(stepOffset) >= 0xFA00 && word(stepOffset) <= 0xFA02
            if word(stepOffset) == 0xEFFE || older { // a command
                var command = word(stepOffset) & 3
                stepOffset &+= 2
                if !older {
                    command = word(stepOffset)
                    stepOffset &+= 2
                }
                if command > 4 { command = 0 } // taken to be Stop
                trackCmdUsed[Int(command)] = true
                switch command {
                case 0: trackCmdStop()
                case 1: trackCmdLoop(stepOffset)
                case 2: trackCmdSpeed(stepOffset)
                case 3:
                    switch variant.original {
                    // TFMX Pro's table, $1516, has Fade for it; TFMX 1.x, $102e, sets a flag that only
                    // a speed from $10 to $1F has a use for (see `restart`).
                    case .pro: trackCmdFade(stepOffset)
                    case .tfmx:
                        sequencer.current += 1
                        sequencer.evalNext = true
                    default: trackCmd7V(stepOffset)
                    }
                default: trackCmdFade(stepOffset)
                }
            } else {
                // The pattern and transposition of each track.
                for t in 0 ..< 8 {
                    tracks[t].PT = byte(stepOffset)
                    stepOffset &+= 1
                    tracks[t].TR = Int8(bitPattern: byte(stepOffset))
                    stepOffset &+= 1
                    if tracks[t].PT < 0x80 {
                        tracks[t].offset = getPattOffset(tracks[t].PT)
                        tracks[t].step = 0
                        tracks[t].wait = 0
                        tracks[t].loops = -1
                        tracks[t].infiniteLoop = false
                    }
                }
            }
            if !sequencer.evalNext { break }
            evalMaxLoops -= 1
        } while evalMaxLoops > 0
    }

    mutating func trackCmdStop() {
        songEnd = true
        triggerRestart = true
    }

    mutating func trackCmdLoop(_ stepOffset: UInt32) {
        if variant.original == .tfmx {
            // TFMX 1.x, $fd4: on to the step it gives, always (and the song's end is told, as it is
            // for every loop, to whoever plays it).
            sequencer.current = Int(word(stepOffset))
            if sequencer.current < 512, sequencer.stepSeenBefore[sequencer.current] { songEnd = true }
            sequencer.evalNext = true
            return
        }
        if sequencer.loops == 0 { // the loop's end
            sequencer.loops = -1
            sequencer.current += 1
        } else if sequencer.loops < 0 { // a loop may begin
            sequencer.current = Int(word(stepOffset))
            sequencer.loops = Int16(bitPattern: word(stepOffset &+ 2)) &- 1
            if sequencer.current > 511 || sequencer.current > sequencer.last { // a bad loop
                songEnd = true
                triggerRestart = true
            } else if sequencer.stepSeenBefore[sequencer.current], sequencer.loops < 0 {
                // A loop with a count below nought would never end.
                songEnd = true
            }
            // Only Ramses's title sets $F00 loops, and Cyberzerk's songs in the game $2E00.
            if sequencer.loops == 0xEFF || sequencer.loops > 0x100 { sequencer.loops = 0 }
        } else {
            sequencer.loops &-= 1
            sequencer.current = Int(word(stepOffset))
        }
        sequencer.evalNext = true
    }

    mutating func trackCmdSpeed(_ stepOffset: UInt32) {
        admin.count = Int16(bitPattern: word(stepOffset))
        admin.speed = admin.count
        ciaTimer = TFMXTiming.timer(afterSpeed: word(stepOffset &+ 2), was: ciaTimer, old: format == .tfmx)
        // Beats a minute, if any: values like $FF00 that would be below nought are left alone.
        var arg2 = 0x81FF & word(stepOffset &+ 2)
        if arg2 != 0, arg2 < 0x200 {
            if arg2 < 32 { arg2 = 125 }
            setRate(UInt32(arg2))
        }
        sequencer.current += 1
        sequencer.evalNext = true
    }

    mutating func trackCmdFade(_ stepOffset: UInt32) {
        fadeInit(byte(stepOffset &+ 3), byte(stepOffset &+ 1))
        sequencer.current += 1
        sequencer.evalNext = true
    }

    /// 7VOICE: as the library has it, it sets the song's beats a minute from its last byte, and marks
    /// the module one of seven voices (`adjustTraitsPost`).
    mutating func trackCmd7V(_ stepOffset: UInt32) {
        let arg2 = Int16(bitPattern: word(stepOffset &+ 2))
        if arg2 >= 0 {
            var x = Int8(bitPattern: byte(stepOffset &+ 3))
            if x < -0x20 { x = -0x20 }
            sevenVoiceTempo = Int(x)
            setBPM(UInt16((125 * 100) / (100 + Int(x))))
        }
        sequencer.current += 1
        sequencer.evalNext = true
    }

    // MARK: Patterns

    func getPattOffset(_ pt: UInt8) -> UInt32 {
        offsets.header &+ long(offsets.patterns &+ (UInt32(pt) << 2))
    }

    mutating func processPattern(_ t: Int) {
        var evalMaxLoops = Self.recurseLimit
        repeat {
            tracks[t].evalNext = false
            let p = tracks[t].offset &+ (UInt32(tracks[t].step) << 2)
            cmd.aa = byte(p)
            cmd.bb = byte(p &+ 1)
            cmd.cd = byte(p &+ 2)
            cmd.ee = byte(p &+ 3)
            let aaBefore = cmd.aa
            if cmd.aa < 0xF0, variant.original == .tfmx {
                // TFMX 1.x, $c04 to $c46: the note with the track's transposition is not kept below
                // $40, and it is by that whether the track goes on or waits.
                if cmd.aa < 0xC0, cmd.aa >= 0x7F {
                    tracks[t].wait = cmd.ee
                    cmd.ee = 0
                }
                cmd.aa &+= UInt8(bitPattern: tracks[t].TR)
                if tracks[t].on { noteCmd() }
                tracks[t].step &+= 1
                if cmd.aa >= 0xC0 || cmd.aa < 0x7F { tracks[t].evalNext = true }
            } else if cmd.aa < 0xF0 { // a note
                if cmd.aa < 0xC0, cmd.aa >= 0x7F { // a note and a wait, in place of the detune
                    tracks[t].wait = cmd.ee
                    cmd.ee = 0
                }
                cmd.aa &+= UInt8(bitPattern: tracks[t].TR)
                if aaBefore < 0xC0 { cmd.aa &= 0x3F }
                if tracks[t].on { noteCmd() }
                tracks[t].step &+= 1
                if aaBefore >= 0xC0 || aaBefore < 0x7F { tracks[t].evalNext = true }
            } else { // a command
                switch cmd.aa & 0xF {
                case 0: pattCmdEnd(t)
                case 1: pattCmdLoop(t)
                case 2: pattCmdGoto(t)
                case 3: pattCmdWait(t)
                case 4, 14: pattCmdStop(t)
                case 5, 6, 7: pattCmdNote(t)
                case 8: pattCmdSaveAndGoto(t)
                case 9: pattCmdReturnFromGoto(t)
                case 10: pattCmdFade(t)
                case 11 where variant.original != .none: pattCmdPlayPattern(t)
                case 12 where variant.original == .tfmx, 13 where variant.original == .tfmx:
                    // TFMX 1.x, $c46: the track's row ends there.
                    tracks[t].step &+= 1
                case 12 where variant.original != .none: pattCmdNote(t) // TFMX Pro's Lock, $133a
                default: pattCmdNOP(t) // 11, 12 (FXPR, not done), 13 and 15
                }
            }
            if !tracks[t].evalNext { break }
            evalMaxLoops -= 1
        } while evalMaxLoops > 0
    }

    mutating func pattCmdNOP(_ t: Int) {
        tracks[t].step &+= 1
        tracks[t].evalNext = true
    }

    /// The pattern's end: on to the next step of the song.
    mutating func pattCmdEnd(_ t: Int) {
        // (TFMX 1.x, $c72: but on a track whose step gave it $81, only the track stops.)
        if variant.original == .tfmx, tracks[t].PT == 0x81 {
            tracks[t].PT = 0xFF
            return
        }
        tracks[t].PT = 0xFF
        nextTrackStep()
    }

    mutating func pattCmdLoop(_ t: Int) {
        if tracks[t].loops == 0 { // the loop's end
            tracks[t].loops = -1
            tracks[t].step &+= 1
            tracks[t].evalNext = true
            return
        } else if tracks[t].loops == -1 { // a loop may begin
            tracks[t].loops = Int8(truncatingIfNeeded: Int(cmd.bb) - 1)
            // A loop that never ends, which may keep the song from ending: what that does to the song's
            // end is seen to in `runMain`.
            if tracks[t].loops == -1 { tracks[t].infiniteLoop = true }
        } else {
            tracks[t].loops &-= 1
        }
        tracks[t].step = Self.makeWord(cmd.cd, cmd.ee)
        tracks[t].evalNext = true
    }

    mutating func pattCmdGoto(_ t: Int) {
        tracks[t].PT = cmd.bb
        tracks[t].offset = getPattOffset(tracks[t].PT)
        tracks[t].step = Self.makeWord(cmd.cd, cmd.ee)
        tracks[t].evalNext = true
    }

    mutating func pattCmdWait(_ t: Int) {
        tracks[t].wait = cmd.bb
        tracks[t].step &+= 1
    }

    mutating func pattCmdStop(_ t: Int) {
        tracks[t].PT = 0xFF
    }

    mutating func pattCmdNote(_ t: Int) {
        // (Chris Hülsbeck's players give it only from a track that is heard: TFMX 1.x, $d18; TFMX
        // Pro, $13e2.)
        if tracks[t].on || variant.original == .none { noteCmd() }
        tracks[t].step &+= 1
        tracks[t].evalNext = true
    }

    /// $FB, in Chris Hülsbeck's players (TFMX 1.x, $dc2; TFMX Pro, $149c): track d is given pattern
    /// bb from its beginning, with transposition ee.
    mutating func pattCmdPlayPattern(_ t: Int) {
        let other = Int(cmd.cd & 7)
        tracks[other].PT = cmd.bb
        tracks[other].TR = Int8(bitPattern: cmd.ee)
        tracks[other].offset = getPattOffset(cmd.bb & 0x7F)
        tracks[other].step = 0
        tracks[other].wait = 0
        tracks[other].loops = -1
        tracks[other].infiniteLoop = false
        tracks[t].step &+= 1
        tracks[t].evalNext = true
    }

    mutating func pattCmdSaveAndGoto(_ t: Int) {
        tracks[t].offsetSaved = tracks[t].offset
        tracks[t].stepSaved = tracks[t].step
        pattCmdGoto(t)
    }

    mutating func pattCmdReturnFromGoto(_ t: Int) {
        tracks[t].offset = tracks[t].offsetSaved
        tracks[t].step = tracks[t].stepSaved &+ 1
        tracks[t].evalNext = true
    }

    mutating func pattCmdFade(_ t: Int) {
        fadeInit(cmd.ee, cmd.bb)
        tracks[t].step &+= 1
        tracks[t].evalNext = true
    }
}
