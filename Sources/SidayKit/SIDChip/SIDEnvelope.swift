// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  ---------------------------------------------------------------------------
//  This file is part of a Swift port of reSID, a MOS6581 SID emulator engine.
//  Copyright (C) 2010  Dag Lem <resid@nimrod.no>
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 2 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//  ---------------------------------------------------------------------------
//
// Port of reSID's envelope.h / envelope.cc.

extension SIDChip {
    // ----------------------------------------------------------------------------
    // A 15 bit counter is used to implement the envelope rates, in effect
    // dividing the clock to the envelope counter by the currently selected rate
    // period.
    // In addition, another counter is used to implement the exponential envelope
    // decay, in effect further dividing the clock to the envelope counter.
    // The period of this counter is set to 1, 2, 4, 8, 16, 30 at the envelope
    // counter values 255, 93, 54, 26, 14, 6, respectively.
    // ----------------------------------------------------------------------------
    struct EnvelopeGenerator {
        enum State: UInt8 { case ATTACK, DECAY_SUSTAIN, RELEASE, FREEZED }

        var rate_counter: UInt32 = 0
        var rate_period: UInt32 = 0
        var exponential_counter: UInt32 = 0
        var exponential_counter_period: UInt32 = 0
        var new_exponential_counter_period: UInt32 = 0
        var envelope_counter: UInt32
        // reSID leaves env3 uninitialised until the first clock(); it starts at zero here.
        var env3: UInt32 = 0
        // Emulation of pipeline delay for envelope decrement.
        //
        // reSID has envelope_pipeline, exponential_pipeline and state_pipeline as three ints and
        // reset_rate_counter as a bool. The pipelines are small down-counters (never above 4) and
        // all four are zero on most cycles, so here they share one word, `pipelines`, one byte
        // each, and clock() finds out with one load whether there is anything to do. The members
        // of the same names read and write their own byte.
        var pipelines: UInt32 = 0

        var envelope_pipeline: Int32 {
            @inline(__always) get { Int32(truncatingIfNeeded: pipelines & 0xFF) }
            @inline(__always) set { pipelines = (pipelines & ~0xFF) | (UInt32(truncatingIfNeeded: newValue) & 0xFF) }
        }

        var exponential_pipeline: Int32 {
            @inline(__always) get { Int32(truncatingIfNeeded: (pipelines >> 8) & 0xFF) }
            @inline(__always) set { pipelines = (pipelines & ~0xFF00) | ((UInt32(truncatingIfNeeded: newValue) & 0xFF) << 8) }
        }

        var state_pipeline: Int32 {
            @inline(__always) get { Int32(truncatingIfNeeded: (pipelines >> 16) & 0xFF) }
            @inline(__always) set { pipelines = (pipelines & ~0xFF_0000) | ((UInt32(truncatingIfNeeded: newValue) & 0xFF) << 16) }
        }

        var reset_rate_counter: Bool {
            @inline(__always) get { (pipelines & 0x0100_0000) != 0 }
            @inline(__always) set { pipelines = newValue ? pipelines | 0x0100_0000 : pipelines & ~0x0100_0000 }
        }

        var hold_zero = false

        var attack: UInt32 = 0
        var decay: UInt32 = 0
        var sustain: UInt32 = 0
        var release: UInt32 = 0

        var gate: UInt32 = 0

        var state = State.RELEASE
        var next_state = State.RELEASE

        let sid_model: SIDModel

        // DAC lookup tables.
        let model_dac: UnsafePointer<UInt16>

        // Rate counter periods are calculated from the Envelope Rates table in
        // the Programmer's Reference Guide. The rate counter period is the number of
        // cycles between each increment of the envelope counter.
        // The rates have been verified by sampling ENV3.
        //
        // The rate counter is a 16 bit register which is incremented each cycle.
        // When the counter reaches a specific comparison value, the envelope counter
        // is incremented (attack) or decremented (decay/release) and the
        // counter is zeroed.
        //
        // NB! Sampling ENV3 shows that the calculated values are not exact.
        // It may seem like most calculated values have been rounded (.5 is rounded
        // down) and 1 has beed added to the result. A possible explanation for this
        // is that the SID designers have used the calculated values directly
        // as rate counter comparison values, not considering a one cycle delay to
        // zero the counter. This would yield an actual period of comparison value + 1.
        //
        // See envelope.cc in reSID for how the periods were measured.
        @inline(__always)
        static func rate_counter_period(_ rate: UInt32) -> UInt32 {
            switch rate & 0xF {
            case 0: 8 //         2ms*1.0MHz/256 =     7.81
            case 1: 31 //        8ms*1.0MHz/256 =    31.25
            case 2: 62 //       16ms*1.0MHz/256 =    62.50
            case 3: 94 //       24ms*1.0MHz/256 =    93.75
            case 4: 148 //      38ms*1.0MHz/256 =   148.44
            case 5: 219 //      56ms*1.0MHz/256 =   218.75
            case 6: 266 //      68ms*1.0MHz/256 =   265.63
            case 7: 312 //      80ms*1.0MHz/256 =   312.50
            case 8: 391 //     100ms*1.0MHz/256 =   390.63
            case 9: 976 //     250ms*1.0MHz/256 =   976.56
            case 10: 1953 //   500ms*1.0MHz/256 =  1953.13
            case 11: 3125 //   800ms*1.0MHz/256 =  3125.00
            case 12: 3906 //     1 s*1.0MHz/256 =  3906.25
            case 13: 11719 //    3 s*1.0MHz/256 = 11718.75
            case 14: 19531 //    5 s*1.0MHz/256 = 19531.25
            default: 31250 //    8 s*1.0MHz/256 = 31250.00
            }
        }

        // From the sustain levels it follows that both the low and high 4 bits of the
        // envelope counter are compared to the 4-bit sustain value.
        // This has been verified by sampling ENV3.
        //
        // The table is 0x00, 0x11, 0x22, ... 0xff.
        @inline(__always)
        static func sustain_level(_ sustain: UInt32) -> UInt32 {
            (sustain & 0xF) &* 0x11
        }

        // ----------------------------------------------------------------------------
        // Constructor.
        // ----------------------------------------------------------------------------
        init(model: SIDModel, tables: SIDModelTables) {
            sid_model = model
            model_dac = UnsafePointer(tables.env_dac)

            // Counter's odd bits are high on powerup
            envelope_counter = 0xAA

            // just to avoid uninitialized access with delta clocking
            next_state = .RELEASE

            reset()
        }

        // ----------------------------------------------------------------------------
        // SID reset.
        // ----------------------------------------------------------------------------
        mutating func reset() {
            // counter is not changed on reset
            envelope_pipeline = 0
            exponential_pipeline = 0

            state_pipeline = 0

            attack = 0
            decay = 0
            sustain = 0
            release = 0

            gate = 0

            rate_counter = 0
            exponential_counter = 0
            exponential_counter_period = 1
            new_exponential_counter_period = 0
            reset_rate_counter = false

            state = .RELEASE
            rate_period = Self.rate_counter_period(release)
            hold_zero = false
        }

        // ----------------------------------------------------------------------------
        // Register functions.
        // ----------------------------------------------------------------------------
        mutating func writeCONTROL_REG(_ control: UInt32) {
            let gate_next = control & 0x01

            // The rate counter is never reset, thus there will be a delay before the
            // envelope counter starts counting up (attack) or down (release).

            if gate != gate_next {
                // Gate bit on: Start attack, decay, sustain.
                // Gate bit off: Start release.
                next_state = gate_next != 0 ? .ATTACK : .RELEASE
                if next_state == .ATTACK {
                    // The decay register is "accidentally" activated during first cycle of attack phase
                    state = .DECAY_SUSTAIN
                    rate_period = Self.rate_counter_period(decay)
                    state_pipeline = 2
                    if reset_rate_counter || exponential_pipeline == 2 {
                        envelope_pipeline = exponential_counter_period == 1 || exponential_pipeline == 2 ? 2 : 4
                    } else if exponential_pipeline == 1 { state_pipeline = 3 }
                } else { state_pipeline = envelope_pipeline > 0 ? 3 : 2 }
                gate = gate_next
            }
        }

        mutating func writeATTACK_DECAY(_ attack_decay: UInt32) {
            attack = (attack_decay >> 4) & 0x0F
            decay = attack_decay & 0x0F
            if state == .ATTACK {
                rate_period = Self.rate_counter_period(attack)
            } else if state == .DECAY_SUSTAIN {
                rate_period = Self.rate_counter_period(decay)
            }
        }

        mutating func writeSUSTAIN_RELEASE(_ sustain_release: UInt32) {
            sustain = (sustain_release >> 4) & 0x0F
            release = sustain_release & 0x0F
            if state == .RELEASE {
                rate_period = Self.rate_counter_period(release)
            }
        }

        func readENV() -> UInt32 {
            env3
        }

        // ----------------------------------------------------------------------------
        // SID clocking - 1 cycle.
        // ----------------------------------------------------------------------------
        @inline(__always)
        mutating func clock() {
            // The ENV3 value is sampled at the first phase of the clock
            env3 = envelope_counter

            // The state, envelope and exponential pipelines and the rate counter reset are idle on
            // most cycles; reSID tests each in turn, here one test guards all four and the work
            // itself is kept out of line (clock_pipelines) so the per-cycle code stays small.
            if _slowPath(pipelines != 0) {
                clock_pipelines()
            }

            // Check for ADSR delay bug.
            // If the rate counter comparison value is set below the current value of the
            // rate counter, the counter will continue counting up until it wraps around
            // to zero at 2^15 = 0x8000, and then count rate_period - 1 before the
            // envelope can finally be stepped.
            // This has been verified by sampling ENV3.
            //
            if _fastPath(rate_counter != rate_period) {
                rate_counter &+= 1
                if _slowPath((rate_counter & 0x8000) != 0) {
                    rate_counter = (rate_counter &+ 1) & 0x7FFF
                }
            } else {
                reset_rate_counter = true
            }
        }

        /// The first three steps of reSID's EnvelopeGenerator::clock(), which do nothing unless a
        /// pipeline is running or the rate counter has just matched its period.
        @inline(never)
        mutating func clock_pipelines() {
            if _slowPath(state_pipeline != 0) {
                state_change()
            }

            // If the exponential counter period != 1, the envelope decrement is delayed
            // 1 cycle. This is only modeled for single cycle clocking.
            if _slowPath(envelope_pipeline != 0) {
                envelope_pipeline &-= 1
                if envelope_pipeline == 0 {
                    if _fastPath(!hold_zero) {
                        if state == .ATTACK {
                            envelope_counter = (envelope_counter &+ 1) & 0xFF
                            if _slowPath(envelope_counter == 0xFF) {
                                state = .DECAY_SUSTAIN
                                rate_period = Self.rate_counter_period(decay)
                            }
                        } else if state == .DECAY_SUSTAIN || state == .RELEASE {
                            envelope_counter = (envelope_counter &- 1) & 0xFF
                        }

                        set_exponential_counter()
                    }
                }
            }

            // C++: if (exponential_pipeline != 0 && --exponential_pipeline == 0) {...} else if (reset_rate_counter) {...}
            var exponential_fired = false
            if _slowPath(exponential_pipeline != 0) {
                exponential_pipeline &-= 1
                exponential_fired = exponential_pipeline == 0
            }
            if exponential_fired {
                exponential_counter = 0

                if (state == .DECAY_SUSTAIN && envelope_counter != Self.sustain_level(sustain))
                    || state == .RELEASE
                {
                    // The envelope counter can flip from 0x00 to 0xff by changing state to
                    // attack, then to release. The envelope counter will then continue
                    // counting down in the release state.
                    // This has been verified by sampling ENV3.

                    envelope_pipeline = 1
                }
            } else if _slowPath(reset_rate_counter) {
                rate_counter = 0
                reset_rate_counter = false

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
                    if !hold_zero {
                        exponential_counter &+= 1
                        if exponential_counter == exponential_counter_period {
                            exponential_pipeline = exponential_counter_period != 1 ? 2 : 1
                        }
                    }
                }
            }
        }

        // ----------------------------------------------------------------------------
        // SID clocking - delta_t cycles.
        // ----------------------------------------------------------------------------
        mutating func clock(_ delta_t: Int32) {
            var delta_t = delta_t
            // NB! Any pipelined envelope counter decrement from single cycle clocking
            // will be lost. It is not worth the trouble to flush the pipeline here.

            if _slowPath(state_pipeline != 0) {
                if next_state == .ATTACK {
                    state = .ATTACK
                    hold_zero = false
                    rate_period = Self.rate_counter_period(attack)
                } else if next_state == .RELEASE {
                    state = .RELEASE
                    rate_period = Self.rate_counter_period(release)
                } else if next_state == .FREEZED {
                    hold_zero = true
                }
                state_pipeline = 0
            }

            // Check for ADSR delay bug.
            // If the rate counter comparison value is set below the current value of the
            // rate counter, the counter will continue counting up until it wraps around
            // to zero at 2^15 = 0x8000, and then count rate_period - 1 before the
            // envelope can finally be stepped.
            // This has been verified by sampling ENV3.
            //

            // NB! This requires two's complement integer.
            var rate_step = Int32(bitPattern: rate_period &- rate_counter)
            if _slowPath(rate_step <= 0) {
                rate_step &+= 0x7FFF
            }

            while delta_t != 0 {
                if delta_t < rate_step {
                    // likely (~65%)
                    rate_counter &+= UInt32(bitPattern: delta_t)
                    if _slowPath((rate_counter & 0x8000) != 0) {
                        rate_counter = (rate_counter &+ 1) & 0x7FFF
                    }
                    return
                }

                rate_counter = 0
                delta_t &-= rate_step

                // The first envelope step in the attack state also resets the exponential
                // counter. This has been verified by sampling ENV3.
                //
                var step = state == .ATTACK
                if !step {
                    exponential_counter &+= 1
                    step = exponential_counter == exponential_counter_period
                }
                if step {
                    // likely (~50%)
                    exponential_counter = 0

                    // Check whether the envelope counter is frozen at zero.
                    if _slowPath(hold_zero) {
                        rate_step = Int32(bitPattern: rate_period)
                        continue
                    }

                    switch state {
                    case .ATTACK:
                        // The envelope counter can flip from 0xff to 0x00 by changing state to
                        // release, then to attack. The envelope counter is then frozen at
                        // zero; to unlock this situation the state must be changed to release,
                        // then to attack. This has been verified by sampling ENV3.
                        //
                        envelope_counter = (envelope_counter &+ 1) & 0xFF
                        if _slowPath(envelope_counter == 0xFF) {
                            state = .DECAY_SUSTAIN
                            rate_period = Self.rate_counter_period(decay)
                        }
                    case .DECAY_SUSTAIN:
                        if _fastPath(envelope_counter != Self.sustain_level(sustain)) {
                            envelope_counter &-= 1
                        }
                    case .RELEASE:
                        // The envelope counter can flip from 0x00 to 0xff by changing state to
                        // attack, then to release. The envelope counter will then continue
                        // counting down in the release state.
                        // This has been verified by sampling ENV3.
                        // NB! The operation below requires two's complement integer.
                        //
                        envelope_counter = (envelope_counter &- 1) & 0xFF
                    case .FREEZED:
                        // we should never get here
                        break
                    }

                    // Check for change of exponential counter period.
                    set_exponential_counter()
                    if _slowPath(new_exponential_counter_period > 0) {
                        exponential_counter_period = new_exponential_counter_period
                        new_exponential_counter_period = 0
                        if next_state == .FREEZED {
                            hold_zero = true
                        }
                    }
                }

                rate_step = Int32(bitPattern: rate_period)
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
        @inline(__always)
        mutating func state_change() {
            state_pipeline &-= 1

            switch next_state {
            case .ATTACK:
                if state_pipeline == 0 {
                    state = .ATTACK
                    // The attack register is correctly activated during second cycle of attack phase
                    rate_period = Self.rate_counter_period(attack)
                    hold_zero = false
                }
            case .DECAY_SUSTAIN:
                break
            case .RELEASE:
                if (state == .ATTACK && state_pipeline == 0)
                    || (state == .DECAY_SUSTAIN && state_pipeline == 1)
                {
                    state = .RELEASE
                    rate_period = Self.rate_counter_period(release)
                }
            case .FREEZED:
                break
            }
        }

        // ----------------------------------------------------------------------------
        // Read the envelope generator output.
        // ----------------------------------------------------------------------------
        @inline(__always)
        func output() -> Int32 {
            // DAC imperfections are emulated by using envelope_counter as an index
            // into a DAC lookup table. readENV() uses envelope_counter directly.
            Int32(model_dac[Int(envelope_counter & 0xFF)])
        }

        @inline(__always)
        mutating func set_exponential_counter() {
            // Check for change of exponential counter period.
            switch envelope_counter {
            case 0xFF:
                exponential_counter_period = 1
            case 0x5D:
                exponential_counter_period = 2
            case 0x36:
                exponential_counter_period = 4
            case 0x1A:
                exponential_counter_period = 8
            case 0x0E:
                exponential_counter_period = 16
            case 0x06:
                exponential_counter_period = 30
            case 0x00:
                // TODO write a test to verify that 0x00 really changes the period
                // e.g. set R = 0xf, gate on to 0x06, gate off to 0x00, gate on to 0x04,
                // gate off, sample.
                exponential_counter_period = 1

                // When the envelope counter is changed to zero, it is frozen at zero.
                // This has been verified by sampling ENV3.
                hold_zero = true
            default:
                break
            }
        }
    }
}
