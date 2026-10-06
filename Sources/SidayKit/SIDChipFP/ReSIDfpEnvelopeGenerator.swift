// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// This file is part of a Swift port of reSIDfp, a SID emulator engine.
// Copyright 2011-2022 Leandro Nini <drfiemost@users.sourceforge.net>
// Copyright 2018 VICE Project
// Copyright 2007-2010 Antti Lankila
// Copyright 2004,2010 Dag Lem <resid@nimrod.no>
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// EnvelopeGenerator.h / EnvelopeGenerator.cpp.
//
// clock() is arranged as one test for "anything pending" followed by the rate counter step, with
// reSIDfp's chain of pipeline tests out of line (clockPipelines); the order of the tests is unchanged.
// quietCycles() / clockQuiet() do a run of cycles in which nothing is pending in one step: the rate
// counter is a 15-bit LFSR whose position in its sequence is looked up, so the cycle on which it will
// next equal the rate is known in advance. steadyCycles() / clockSteady() extend that to the two states
// in which the envelope cannot move at all (ReSIDfpChip.clockCycles uses these).

extension ReSIDfpChip {
    /// A 15 bit [LFSR] is used to implement the envelope rates, in effect dividing
    /// the clock to the envelope counter by the currently selected rate period.
    ///
    /// In addition, another 5 bit counter is used to implement the exponential envelope decay,
    /// in effect further dividing the clock to the envelope counter.
    /// The period of this counter is set to 1, 2, 4, 8, 16, 30 at the envelope counter
    /// values 255, 93, 54, 26, 14, 6, respectively.
    ///
    /// [LFSR]: https://en.wikipedia.org/wiki/Linear_feedback_shift_register
    struct EnvelopeGenerator {
        /// The envelope state machine's distinct states. In addition to this,
        /// envelope has a hold mode, which freezes envelope counter to zero.
        enum State: UInt8 {
            case ATTACK, DECAY_SUSTAIN, RELEASE
        }

        /// XOR shift register for ADSR prescaling.
        var lfsr: UInt32 = 0x7FFF

        /// Comparison value (period) of the rate counter before next event.
        var rate: UInt32 = 0

        /// During release mode, the SID approximates envelope decay via piecewise
        /// linear decay rate.
        var exponential_counter: UInt32 = 0

        /// Comparison value (period) of the exponential decay counter before next
        /// decrement.
        var exponential_counter_period: UInt32 = 1
        var new_exponential_counter_period: UInt32 = 0

        var state_pipeline: UInt32 = 0

        ///
        var envelope_pipeline: UInt32 = 0

        var exponential_pipeline: UInt32 = 0

        /// Current envelope state
        var state = State.RELEASE
        var next_state = State.RELEASE

        /// Whether counter is enabled. Only switching to ATTACK can release envelope.
        var counter_enabled = true

        /// Gate bit
        var gate = false

        ///
        var resetLfsr = false

        /// The current digital value of envelope output.
        var envelope_counter: UInt8 = 0xAA

        /// Attack register
        var attack: UInt8 = 0

        /// Decay register
        var decay: UInt8 = 0

        /// Sustain register
        var sustain: UInt8 = 0

        /// Release register
        var release: UInt8 = 0

        /// The ENV3 value, sampled at the first phase of the clock
        var env3: UInt8 = 0

        /// Lookup table to convert from attack, decay, or release value to rate
        /// counter period.
        ///
        /// The rate counter is a 15 bit register which is left shifted each cycle.
        /// When the counter reaches a specific comparison value,
        /// the envelope counter is incremented (attack) or decremented
        /// (decay/release) and the rate counter is resetted.
        ///
        /// see [kevtris.org](http://blog.kevtris.org/?p=13)
        @inline(__always)
        static func adsrtable(_ i: UInt8) -> UInt32 {
            // A switch rather than an array: no allocation, no bounds check.
            switch i & 0x0F {
            case 0: 0x007F
            case 1: 0x3000
            case 2: 0x1E00
            case 3: 0x0660
            case 4: 0x0182
            case 5: 0x5573
            case 6: 0x000E
            case 7: 0x3805
            case 8: 0x2424
            case 9: 0x2220
            case 10: 0x090C
            case 11: 0x0ECD
            case 12: 0x010E
            case 13: 0x23F7
            case 14: 0x5237
            default: 0x64A8
            }
        }

        /// Get the Envelope Generator digital output.
        @inline(__always)
        func output() -> UInt32 { UInt32(envelope_counter) }

        /// Return the envelope current value.
        ///
        /// - Returns: envelope counter value
        func readENV() -> UInt8 { env3 }

        /// SID reset.
        mutating func reset() {
            // counter is not changed on reset
            envelope_pipeline = 0

            state_pipeline = 0

            attack = 0
            decay = 0
            sustain = 0
            release = 0

            gate = false

            resetLfsr = true

            exponential_counter = 0
            exponential_counter_period = 1
            new_exponential_counter_period = 0

            state = .RELEASE
            counter_enabled = true
            rate = EnvelopeGenerator.adsrtable(release)
        }

        /// Write control register.
        ///
        /// - Parameter control: control register value
        mutating func writeCONTROL_REG(_ control: UInt8) {
            let gate_next = (control & 0x01) != 0

            if gate_next != gate {
                gate = gate_next

                // The rate counter is never reset, thus there will be a delay before the
                // envelope counter starts counting up (attack) or down (release).

                if gate_next {
                    // Gate bit on:  Start attack, decay, sustain.
                    next_state = .ATTACK
                    state_pipeline = 2

                    if resetLfsr || exponential_pipeline == 2 {
                        envelope_pipeline = (exponential_counter_period == 1) || (exponential_pipeline == 2) ? 2 : 4
                    } else if exponential_pipeline == 1 {
                        state_pipeline = 3
                    }
                } else {
                    // Gate bit off: Start release.
                    next_state = .RELEASE
                    state_pipeline = envelope_pipeline > 0 ? 3 : 2
                }
            }
        }

        /// Write Attack/Decay register.
        ///
        /// - Parameter attack_decay: attack/decay value
        mutating func writeATTACK_DECAY(_ attack_decay: UInt8) {
            attack = (attack_decay >> 4) & 0x0F
            decay = attack_decay & 0x0F

            if state == .ATTACK {
                rate = EnvelopeGenerator.adsrtable(attack)
            } else if state == .DECAY_SUSTAIN {
                rate = EnvelopeGenerator.adsrtable(decay)
            }
        }

        /// Write Sustain/Release register.
        ///
        /// - Parameter sustain_release: sustain/release value
        mutating func writeSUSTAIN_RELEASE(_ sustain_release: UInt8) {
            // From the sustain levels it follows that both the low and high 4 bits
            // of the envelope counter are compared to the 4-bit sustain value.
            // This has been verified by sampling ENV3.
            //
            // For a detailed description see:
            // http://ploguechipsounds.blogspot.it/2010/11/new-research-on-sid-adsr.html
            sustain = (sustain_release & 0xF0) | ((sustain_release >> 4) & 0x0F)

            release = sustain_release & 0x0F

            if state == .RELEASE {
                rate = EnvelopeGenerator.adsrtable(release)
            }
        }

        /// SID clocking.
        @inline(__always)
        mutating func clock() {
            env3 = envelope_counter

            if _slowPath((new_exponential_counter_period | state_pipeline | envelope_pipeline | exponential_pipeline) != 0 || resetLfsr) {
                clockPipelines()
            }

            // ADSR delay bug.
            // If the rate counter comparison value is set below the current value of the
            // rate counter, the counter will continue counting up until it wraps around
            // to zero at 2^15 = 0x8000, and then count rate_period - 1 before the
            // envelope can constly be stepped.
            // This has been verified by sampling ENV3.

            // check to see if LFSR matches table value
            if _fastPath(lfsr != rate) {
                // it wasn't a match, clock the LFSR once
                // by performing XOR on last 2 bits
                let feedback = ((lfsr << 14) ^ (lfsr << 13)) & 0x4000
                lfsr = (lfsr >> 1) | feedback
            } else {
                resetLfsr = true
            }
        }

        // MARK: Runs of cycles in which nothing happens

        /// The rate counter's sequence, for stepping it many cycles at once. `position[lfsr]` is the number of
        /// steps from 0x7fff to `lfsr`; `sequence[k]` is the value after k steps. The counter visits all 32767
        /// nonzero values (0 is never reached and is given position 0 only to fill the table).
        enum RateCounter {
            static var period: Int32 { 32767 }

            nonisolated(unsafe) static let tables: (position: UnsafePointer<UInt16>, sequence: UnsafePointer<UInt16>) = {
                let position = UnsafeMutablePointer<UInt16>.allocate(capacity: 32768)
                position.initialize(repeating: 0, count: 32768)
                let sequence = UnsafeMutablePointer<UInt16>.allocate(capacity: 32767)
                var lfsr: UInt32 = 0x7FFF
                for k in 0 ..< 32767 {
                    position[Int(lfsr)] = UInt16(k)
                    sequence[k] = UInt16(lfsr)
                    let feedback = ((lfsr << 14) ^ (lfsr << 13)) & 0x4000
                    lfsr = (lfsr >> 1) | feedback
                }
                precondition(lfsr == 0x7FFF)
                return (UnsafePointer(position), UnsafePointer(sequence))
            }()
        }

        /// The number of coming cycles in which clock() would only latch ENV3 and step the rate counter, the
        /// last of them possibly being the one that finds the counter equal to `rate`. 0 when something is
        /// pending. clockQuiet() does that many cycles, or fewer, in one go.
        @inline(__always)
        func quietCycles(_ position: UnsafePointer<UInt16>) -> Int32 {
            if (new_exponential_counter_period | state_pipeline | envelope_pipeline | exponential_pipeline) != 0 || resetLfsr || lfsr == 0 {
                return 0
            }
            var distance = Int32(position[Int(rate & 0x7FFF)]) &- Int32(position[Int(lfsr & 0x7FFF)])
            if distance < 0 { distance &+= RateCounter.period }
            return distance &+ 1
        }

        /// clock() `n` times, for 1 <= n <= quietCycles().
        @inline(__always)
        mutating func clockQuiet(_ n: Int32, _ position: UnsafePointer<UInt16>, _ sequence: UnsafePointer<UInt16>) {
            env3 = envelope_counter

            let from = Int32(position[Int(lfsr & 0x7FFF)])
            var distance = Int32(position[Int(rate & 0x7FFF)]) &- from
            if distance < 0 { distance &+= RateCounter.period }
            if n <= distance {
                var to = from &+ n
                if to >= RateCounter.period { to &-= RateCounter.period }
                lfsr = UInt32(sequence[Int(to)])
            } else {
                // The last of the n cycles found the counter equal to the rate.
                lfsr = rate
                resetLfsr = true
            }
        }

        /// The number of coming cycles in which the envelope counter (the output) is certain not to change.
        /// While the counter is frozen at zero, or held at the sustain level, that is every cycle until the
        /// next register write: the rate counter and the exponential counter go on cycling, but nothing they
        /// do can step the envelope. Otherwise it is quietCycles().
        @inline(__always)
        func steadyCycles(_ position: UnsafePointer<UInt16>) -> Int32 {
            if (new_exponential_counter_period | state_pipeline | envelope_pipeline | exponential_pipeline) != 0 {
                return 0
            }
            if state != .ATTACK, !counter_enabled || (state == .DECAY_SUSTAIN && envelope_counter == sustain) {
                return Int32.max
            }
            return quietCycles(position)
        }

        /// clock() `n` times, for n <= steadyCycles(): quiet runs in one step each, the cycles between them one by one.
        @inline(never)
        mutating func clockSteady(_ n: Int32, _ position: UnsafePointer<UInt16>, _ sequence: UnsafePointer<UInt16>) {
            var left = n
            while left > 0 {
                let quiet = quietCycles(position)
                if quiet > 0 {
                    let run = quiet < left ? quiet : left
                    clockQuiet(run, position, sequence)
                    left &-= run
                } else {
                    clock()
                    left &-= 1
                }
            }
        }

        /// The part of clock() between the ENV3 latch and the rate counter step.
        @inline(never)
        mutating func clockPipelines() {
            if _slowPath(new_exponential_counter_period > 0) {
                exponential_counter_period = new_exponential_counter_period
                new_exponential_counter_period = 0
            }

            if _slowPath(state_pipeline != 0) {
                state_change()
            }

            // if (envelope_pipeline != 0 && --envelope_pipeline == 0) ... else if (exponential_pipeline != 0
            // && --exponential_pipeline == 0) ... else if (resetLfsr) ...
            var envelope_step = false
            if envelope_pipeline != 0 {
                envelope_pipeline &-= 1
                envelope_step = envelope_pipeline == 0
            }
            if envelope_step {
                if _fastPath(counter_enabled) {
                    if state == .ATTACK {
                        envelope_counter &+= 1
                        if envelope_counter == 0xFF {
                            next_state = .DECAY_SUSTAIN
                            state_pipeline = 3
                        }
                    } else if state == .DECAY_SUSTAIN || state == .RELEASE {
                        envelope_counter &-= 1
                        if envelope_counter == 0x00 {
                            counter_enabled = false
                        }
                    }

                    set_exponential_counter()
                }
                return
            }

            var exponential_step = false
            if exponential_pipeline != 0 {
                exponential_pipeline &-= 1
                exponential_step = exponential_pipeline == 0
            }
            if exponential_step {
                exponential_counter = 0

                if (state == .DECAY_SUSTAIN && envelope_counter != sustain)
                    || state == .RELEASE
                {
                    // The envelope counter can flip from 0x00 to 0xff by changing state to
                    // attack, then to release. The envelope counter will then continue
                    // counting down in the release state.
                    // This has been verified by sampling ENV3.

                    envelope_pipeline = 1
                }
                return
            }

            if resetLfsr {
                lfsr = 0x7FFF
                resetLfsr = false

                if state == .ATTACK {
                    // The first envelope step in the attack state also resets the exponential
                    // counter. This has been verified by sampling ENV3.
                    exponential_counter = 0 // NOTE this is actually delayed one cycle, not modeled

                    // The envelope counter can flip from 0xff to 0x00 by changing state to
                    // release, then to attack. The envelope counter is then frozen at
                    // zero; to unlock this situation the state must be changed to release,
                    // then to attack. This has been verified by sampling ENV3.

                    envelope_pipeline = 2
                } else {
                    if counter_enabled {
                        exponential_counter &+= 1
                        if exponential_counter == exponential_counter_period {
                            exponential_pipeline = exponential_counter_period != 1 ? 2 : 1
                        }
                    }
                }
            }
        }

        /**
         * This is what happens on chip during state switching,
         * based on die reverse engineering and transistor level
         * emulation.
         *
         * Attack
         *
         *  0 - Gate on
         *  1 - Counting direction changes
         *      During this cycle the decay rate is "accidentally" activated
         *  2 - Counter is being inverted
         *      Now the attack rate is correctly activated
         *      Counter is enabled
         *  3 - Counter will be counting upward from now on
         *
         * Decay
         *
         *  0 - Counter == $ff
         *  1 - Counting direction changes
         *      The attack state is still active
         *  2 - Counter is being inverted
         *      During this cycle the decay state is activated
         *  3 - Counter will be counting downward from now on
         *
         * Release
         *
         *  0 - Gate off
         *  1 - During this cycle the release state is activated if coming from sustain/decay
         * *2 - Counter is being inverted, the release state is activated
         * *3 - Counter will be counting downward from now on
         *
         *  (* only if coming directly from Attack state)
         *
         * Freeze
         *
         *  0 - Counter == $00
         *  1 - Nothing
         *  2 - Counter is disabled
         */
        mutating func state_change() {
            state_pipeline &-= 1

            switch next_state {
            case .ATTACK:
                if state_pipeline == 1 {
                    // The decay rate is "accidentally" enabled during first cycle of attack phase
                    rate = EnvelopeGenerator.adsrtable(decay)
                } else if state_pipeline == 0 {
                    state = .ATTACK
                    // The attack rate is correctly enabled during second cycle of attack phase
                    rate = EnvelopeGenerator.adsrtable(attack)
                    counter_enabled = true
                }
            case .DECAY_SUSTAIN:
                if state_pipeline == 0 {
                    state = .DECAY_SUSTAIN
                    rate = EnvelopeGenerator.adsrtable(decay)
                }
            case .RELEASE:
                if (state == .ATTACK && state_pipeline == 0)
                    || (state == .DECAY_SUSTAIN && state_pipeline == 1)
                {
                    state = .RELEASE
                    rate = EnvelopeGenerator.adsrtable(release)
                }
            }
        }

        mutating func set_exponential_counter() {
            // Check for change of exponential counter period.
            //
            // For a detailed description see:
            // http://ploguechipsounds.blogspot.it/2010/03/sid-6581r3-adsr-tables-up-close.html
            switch envelope_counter {
            case 0xFF, 0x00:
                new_exponential_counter_period = 1
            case 0x5D:
                new_exponential_counter_period = 2
            case 0x36:
                new_exponential_counter_period = 4
            case 0x1A:
                new_exponential_counter_period = 8
            case 0x0E:
                new_exponential_counter_period = 16
            case 0x06:
                new_exponential_counter_period = 30
            default:
                break
            }
        }
    }
}
