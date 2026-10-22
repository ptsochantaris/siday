// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// This file is part of a Swift port of reSIDfp, a SID emulator engine.
// Copyright 2011-2025 Leandro Nini <drfiemost@users.sourceforge.net>
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
// WaveformGenerator.h / WaveformGenerator.cpp.
//
// reSIDfp's generators hold pointers to their two neighbours (prevVoice, nextVoice). Here the chip
// passes what is read through them as arguments: output() takes the previous voice's accumulator,
// and synchronize() and readFollowingVoiceSync() are done by the chip (ReSIDfpChip.voiceSync).
//
// WaveformGenerator.Quiet is clock() and output() for a run of cycles in which none of their special
// cases can arise, with the generator's state in local variables (ReSIDfpChip.clockCycles uses it).

extension ReSIDfpChip {
    /// A 24 bit accumulator is the basis for waveform generation.
    /// FREQ is added to the lower 16 bits of the accumulator each cycle.
    /// The accumulator is set to zero when TEST is set, and starts counting
    /// when TEST is cleared.
    ///
    /// Waveforms are generated as follows:
    ///
    /// - No waveform:
    /// When no waveform is selected, the DAC input is floating.
    ///
    ///
    /// - Triangle:
    /// The upper 12 bits of the accumulator are used.
    /// The MSB is used to create the falling edge of the triangle by inverting
    /// the lower 11 bits. The MSB is thrown away and the lower 11 bits are
    /// left-shifted (half the resolution, full amplitude).
    /// Ring modulation substitutes the MSB with MSB EOR NOT sync_source MSB.
    ///
    ///
    /// - Sawtooth:
    /// The output is identical to the upper 12 bits of the accumulator.
    ///
    ///
    /// - Pulse:
    /// The upper 12 bits of the accumulator are used.
    /// These bits are compared to the pulse width register by a 12 bit digital
    /// comparator; output is either all one or all zero bits.
    /// The pulse setting is delayed one cycle after the compare.
    /// The test bit, when set to one, holds the pulse waveform output at 0xfff
    /// regardless of the pulse width setting.
    ///
    ///
    /// - Noise:
    /// The noise output is taken from intermediate bits of a 23-bit shift register
    /// which is clocked by bit 19 of the accumulator.
    /// The shift is delayed 2 cycles after bit 19 is set high.
    ///
    /// Operation: Calculate EOR result, shift register, set bit 0 = result.
    ///
    ///                    reset  +--------------------------------------------+
    ///                      |    |                                            |
    ///               test--OR-->EOR<--+                                       |
    ///                      |         |                                       |
    ///                      2 2 2 1 1 1 1 1 1 1 1 1 1                         |
    ///     Register bits:   2 1 0 9 8 7 6 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0 <---+
    ///                          |   |       |     |   |       |     |   |
    ///     Waveform bits:       1   1       9     8   7       6     5   4
    ///                          1   0
    ///
    /// The low 4 waveform bits are zero (grounded).
    struct WaveformGenerator {
        /**
         * Number of cycles after which the waveform output fades to 0 when setting
         * the waveform register to 0.
         * Values measured on warm chips (6581R3/R4 and 8580R5)
         * checking OSC3.
         * Times vary wildly with temperature and may differ
         * from chip to chip so the numbers here represent
         * only the big difference between the old and new models.
         *
         * See [VICE Bug #290](http://sourceforge.net/p/vice-emu/bugs/290/)
         * and [VICE Bug #1128](http://sourceforge.net/p/vice-emu/bugs/1128/)
         */
        // ~95ms
        static var FLOATING_OUTPUT_TTL_6581R3: UInt32 { 54000 }
        static var FLOATING_OUTPUT_FADE_6581R3: UInt32 { 1400 }
        // ~1s
        static var FLOATING_OUTPUT_TTL_6581R4: UInt32 { 1_000_000 }
        // ~1s
        static var FLOATING_OUTPUT_TTL_8580R5: UInt32 { 800_000 }
        static var FLOATING_OUTPUT_FADE_8580R5: UInt32 { 50000 }

        /**
         * Number of cycles after which the shift register is reset
         * when the test bit is set.
         * Values measured on warm chips (6581R3/R4 and 8580R5)
         * checking OSC3.
         * Times vary wildly with temperature and may differ
         * from chip to chip so the numbers here represent
         * only the big difference between the old and new models.
         */
        // ~210ms
        static var SHIFT_REGISTER_RESET_6581R3: UInt32 { 50000 }
        static var SHIFT_REGISTER_FADE_6581R3: UInt32 { 15000 }
        // ~2.15s
        static var SHIFT_REGISTER_RESET_6581R4: UInt32 { 2_150_000 }
        // ~2.8s
        static var SHIFT_REGISTER_RESET_8580R5: UInt32 { 986_000 }
        static var SHIFT_REGISTER_FADE_8580R5: UInt32 { 314_300 }

        static var shift_mask: UInt32 {
            ~(
                (1 << 2) | // Bit 20
                    (1 << 4) | // Bit 18
                    (1 << 8) | // Bit 14
                    (1 << 11) | // Bit 11
                    (1 << 13) | // Bit  9
                    (1 << 17) | // Bit  5
                    (1 << 20) | // Bit  2
                    (1 << 22) // Bit  0
            )
        }

        // matrix_t* model_wave / model_pulldown: rows of 4096.
        var model_wave: UnsafePointer<Int16>
        var model_pulldown: UnsafePointer<Int16>

        var wave: UnsafePointer<Int16>
        var pulldown: UnsafePointer<Int16>?

        // PWout = (PWn/40.95)%
        var pw: UInt32 = 0

        var shift_register: UInt32 = 0

        /// Shift register is latched when transitioning to shift phase 1.
        var shift_latch: UInt32 = 0

        /// Emulation of pipeline causing bit 19 to clock the shift register.
        var shift_pipeline: Int32 = 0

        var ring_msb_mask: UInt32 = 0
        var no_noise: UInt32 = 0
        var noise_output: UInt32 = 0
        var no_noise_or_noise_output: UInt32 = 0
        var no_pulse: UInt32 = 0
        var pulse_output: UInt32 = 0

        /// The control register right-shifted 4 bits; used for output function table lookup.
        var waveform: UInt32 = 0

        var waveform_output: UInt32 = 0

        /// Current accumulator value.
        var accumulator: UInt32 = 0x555555 // Accumulator's even bits are high on powerup

        // Fout = (Fn*Fclk/16777216)Hz
        var freq: UInt32 = 0

        /// 8580 tri/saw pipeline
        var tri_saw_pipeline: UInt32 = 0x555

        /// The OSC3 value
        var osc3: UInt32 = 0

        /// Remaining time to fully reset shift register.
        var shift_register_reset: UInt32 = 0

        // The wave signal TTL when no waveform is selected.
        var floating_output_ttl: UInt32 = 0

        /// The control register bits. Gate is handled by EnvelopeGenerator.
        var test = false
        var sync = false

        /// Test bit is latched at phi2 for the noise XOR.
        var test_or_reset = false

        /// Tell whether the accumulator MSB was set high on this cycle.
        var msb_rising = false

        var is6581: Bool

        /// setModel(), setWaveformModels() and setPulldownModels(), which the SID constructor calls before
        /// anything else.
        init(is6581: Bool, waveformModels: UnsafePointer<Int16>, pulldownModels: UnsafePointer<Int16>) {
            self.is6581 = is6581
            model_wave = waveformModels
            model_pulldown = pulldownModels
            wave = waveformModels
        }

        mutating func setPulldownModels(_ models: UnsafePointer<Int16>) {
            model_pulldown = models
        }

        /*
         * This is what happens when the lfsr is clocked:
         *
         * cycle 0: bit 19 of the accumulator goes from low to high, the noise register acts normally,
         *          the output may pulldown a bit;
         *
         * cycle 1: first phase of the shift, the bits are interconnected and the output of each bit
         *          is latched into the following. The output may overwrite the latched value.
         *
         * cycle 2: second phase of the shift, the latched value becomes active in the first
         *          half of the clock and from the second half the register returns to normal operation.
         *
         * When the test or reset lines are active the first phase is executed at every cyle
         * until the signal is released triggering the second phase.
         *
         *      |       |    bit n     |   bit n+1
         *      | bit19 | latch output | latch output
         * -----+-------+--------------+--------------
         * phi1 |   0   |   A <-> A    |   B <-> B
         * phi2 |   0   |   A <-> A    |   B <-> B
         * -----+-------+--------------+--------------
         * phi1 |   1   |   A <-> A    |   B <-> B      <- bit19 raises
         * phi2 |   1   |   A <-> A    |   B <-> B
         * -----+-------+--------------+--------------
         * phi1 |   1   |   X     A  --|-> A     B      <- shift phase 1
         * phi2 |   1   |   X     A  --|-> A     B
         * -----+-------+--------------+--------------
         * phi1 |   1   |   X --> X    |   A --> A      <- shift phase 2
         * phi2 |   1   |   X <-> X    |   A <-> A
         *
         *
         * Normal cycles
         * -------------
         * Normally, when noise is selected along with another waveform,
         * c1 and c2 are closed and the output bits pull down the corresponding
         * shift register bits.
         *
         *        noi_out_x             noi_out_x+1
         *          ^                     ^
         *          |                     |
         *          +-------------+       +-------------+
         *          |             |       |             |
         *          +---o<|---+   |       +---o<|---+   |
         *          |         |   |       |         |   |
         *       c2 |      c1 |   |    c2 |      c1 |   |
         *          |         |   |       |         |   |
         *  >---/---+---|>o---+   +---/---+---|>o---+   +---/--->
         *      LC                    LC                    LC
         *
         *
         * Shift phase 1
         * -------------
         * During shift phase 1 c1 and c2 are open, the SR bits are floating
         * and will be driven by the output of combined waveforms,
         * or slowly turn high.
         *
         *        noi_out_x             noi_out_x+1
         *          ^                     ^
         *          |                     |
         *          +-------------+       +-------------+
         *          |             |       |             |
         *          +---o<|---+   |       +---o<|---+   |
         *          |         |   |       |         |   |
         *       c2 /      c1 /   |    c2 /      c1 /   |
         *          |         |   |       |         |   |
         *  >-------+---|>o---+   +-------+---|>o---+   +------->
         *      LC                    LC                    LC
         *
         *
         * Shift phase 2 (phi1)
         * --------------------
         * During the first half cycle of shift phase 2 c1 is closed
         * so the value from of noi_out_x-1 enters the bit.
         *
         *        noi_out_x             noi_out_x+1
         *          ^                     ^
         *          |                     |
         *          +-------------+       +-------------+
         *          |             |       |             |
         *          +---o<|---+   |       +---o<|---+   |
         *          |         |   |       |         |   |
         *       c2 /      c1 |   |    c2 /      c1 |   |
         *          |         |   |       |         |   |
         *  >---/---+---|>o---+   +---/---+---|>o---+   +---/--->
         *      LC                    LC                    LC
         *
         *
         * Shift phase 2 (phi2)
         * --------------------
         * On the second half of shift phase 2 c2 closes and
         * we're back to normal cycles.
         */

        @inline(__always)
        static func do_writeback(_ waveform_old: UInt32, _ waveform_new: UInt32, _ is6581: Bool) -> Bool {
            // no writeback without combined waveforms

            if waveform_old <= 8 {
                // fixes SID/noisewriteback/noise_writeback_test2-{old,new}
                return false
            }

            if waveform_new < 8 {
                return false
            }

            if waveform_new == 8,
               // breaks noise_writeback_check_F_to_8_old
               // but fixes simple and scan
               waveform_old != 0xF
            {
                // fixes
                // noise_writeback_check_9_to_8_old
                // noise_writeback_check_A_to_8_old
                // noise_writeback_check_B_to_8_old
                // noise_writeback_check_D_to_8_old
                // noise_writeback_check_E_to_8_old
                // noise_writeback_check_F_to_8_old
                // noise_writeback_check_9_to_8_new
                // noise_writeback_check_A_to_8_new
                // noise_writeback_check_D_to_8_new
                // noise_writeback_check_E_to_8_new
                // noise_writeback_test1-{old,new}
                return false
            }

            // What's happening here?
            if is6581,
               ((waveform_old & 0x3) == 0x1 && (waveform_new & 0x3) == 0x2)
               || ((waveform_old & 0x3) == 0x2 && (waveform_new & 0x3) == 0x1)
            {
                // fixes
                // noise_writeback_check_9_to_A_old
                // noise_writeback_check_9_to_E_old
                // noise_writeback_check_A_to_9_old
                // noise_writeback_check_A_to_D_old
                // noise_writeback_check_D_to_A_old
                // noise_writeback_check_E_to_9_old
                return false
            }
            if waveform_old == 0xC {
                // fixes
                // noise_writeback_check_C_to_A_new
                return false
            }
            if waveform_new == 0xC {
                // fixes
                // noise_writeback_check_9_to_C_old
                // noise_writeback_check_A_to_C_old
                return false
            }

            // ok do the writeback
            return true
        }

        @inline(__always)
        static func get_noise_writeback(_ waveform_output: UInt32) -> UInt32 {
            ((waveform_output & (1 << 11)) >> 9) | // Bit 11 -> bit 20
                ((waveform_output & (1 << 10)) >> 6) | // Bit 10 -> bit 18
                ((waveform_output & (1 << 9)) >> 1) | // Bit  9 -> bit 14
                ((waveform_output & (1 << 8)) << 3) | // Bit  8 -> bit 11
                ((waveform_output & (1 << 7)) << 6) | // Bit  7 -> bit  9
                ((waveform_output & (1 << 6)) << 11) | // Bit  6 -> bit  5
                ((waveform_output & (1 << 5)) << 15) | // Bit  5 -> bit  2
                ((waveform_output & (1 << 4)) << 18) // Bit  4 -> bit  0
        }

        /*
         * Perform the actual shifting, moving the latched value into following bits.
         * The XORing for bit0 is done in this cycle using the test bit latched during
         * the previous phi2 cycle.
         */
        mutating func shift_phase2(_ waveform_old: UInt32, _ waveform_new: UInt32) {
            if WaveformGenerator.do_writeback(waveform_old, waveform_new, is6581) {
                // if noise is combined with another waveform the output drives the SR bits
                shift_latch = (shift_register & WaveformGenerator.shift_mask) | WaveformGenerator.get_noise_writeback(waveform_output)
            }

            // bit0 = (bit22 | test | reset) ^ bit17 = 1 ^ bit17 = ~bit17
            let bit22 = ((test_or_reset ? 1 : 0) | shift_latch) << 22
            let bit0 = (bit22 ^ (shift_latch << 17)) & (1 << 22)

            shift_register = (shift_latch >> 1) | bit0

            set_noise_output()
        }

        @inline(__always)
        mutating func write_shift_register() {
            if _slowPath(waveform > 0x8) {
                // Write changes to the shift register output caused by combined waveforms
                // back into the shift register.
                if _fastPath(shift_pipeline != 1), !test {
                    // the output pulls down the SR bits
                    shift_register = shift_register & (WaveformGenerator.shift_mask | WaveformGenerator.get_noise_writeback(waveform_output))
                    noise_output &= waveform_output
                } else {
                    // shift phase 1: the output drives the SR bits
                    noise_output = waveform_output
                }

                set_no_noise_or_noise_output()
            }
        }

        mutating func set_noise_output() {
            noise_output =
                ((shift_register & (1 << 2)) << 9) | // Bit 20 -> bit 11
                ((shift_register & (1 << 4)) << 6) | // Bit 18 -> bit 10
                ((shift_register & (1 << 8)) << 1) | // Bit 14 -> bit  9
                ((shift_register & (1 << 11)) >> 3) | // Bit 11 -> bit  8
                ((shift_register & (1 << 13)) >> 6) | // Bit  9 -> bit  7
                ((shift_register & (1 << 17)) >> 11) | // Bit  5 -> bit  6
                ((shift_register & (1 << 20)) >> 15) | // Bit  2 -> bit  5
                ((shift_register & (1 << 22)) >> 18) // Bit  0 -> bit  4

            set_no_noise_or_noise_output()
        }

        @inline(__always)
        mutating func set_no_noise_or_noise_output() {
            no_noise_or_noise_output = no_noise | noise_output
        }

        /// Write FREQ LO register.
        ///
        /// - Parameter freq_lo: low 8 bits of frequency
        mutating func writeFREQ_LO(_ freq_lo: UInt8) { freq = (freq & 0xFF00) | (UInt32(freq_lo) & 0xFF) }

        /// Write FREQ HI register.
        ///
        /// - Parameter freq_hi: high 8 bits of frequency
        mutating func writeFREQ_HI(_ freq_hi: UInt8) { freq = (UInt32(freq_hi) << 8 & 0xFF00) | (freq & 0xFF) }

        /// Write PW LO register.
        ///
        /// - Parameter pw_lo: low 8 bits of pulse width
        mutating func writePW_LO(_ pw_lo: UInt8) { pw = (pw & 0xF00) | (UInt32(pw_lo) & 0x0FF) }

        /// Write PW HI register.
        ///
        /// - Parameter pw_hi: high 8 bits of pulse width
        mutating func writePW_HI(_ pw_hi: UInt8) { pw = (UInt32(pw_hi) << 8 & 0xF00) | (pw & 0x0FF) }

        /// Write CONTROL REGISTER register.
        ///
        /// - Parameter control: control register value
        mutating func writeCONTROL_REG(_ control8: UInt8) {
            let control = UInt32(control8)
            let waveform_prev = waveform
            let test_prev = test

            waveform = (control >> 4) & 0x0F
            test = (control & 0x08) != 0
            sync = (control & 0x02) != 0

            // Substitution of accumulator MSB when sawtooth = 0, ring_mod = 1.
            ring_msb_mask = ((~control >> 5) & (control >> 2) & 0x1) << 23

            if waveform != waveform_prev {
                // Set up waveform tables
                wave = model_wave + Int(waveform & 0x3) * 4096
                // We assume tha combinations including noise
                // behave the same as without
                switch waveform & 0x7 {
                case 3:
                    pulldown = model_pulldown + 0 * 4096
                case 4:
                    pulldown = (waveform & 0x8) != 0 ? model_pulldown + 4 * 4096 : nil
                case 5:
                    pulldown = model_pulldown + 1 * 4096
                case 6:
                    pulldown = model_pulldown + 2 * 4096
                case 7:
                    pulldown = model_pulldown + 3 * 4096
                default:
                    pulldown = nil
                }

                // no_noise and no_pulse are used in set_waveform_output() as bitmasks to
                // only let the noise or pulse influence the output when the noise or pulse
                // waveforms are selected.
                no_noise = (waveform & 0x8) != 0 ? 0x000 : 0xFFF
                set_no_noise_or_noise_output()
                no_pulse = (waveform & 0x4) != 0 ? 0x000 : 0xFFF

                if waveform == 0 {
                    // Change to floating DAC input.
                    // Reset fading time for floating DAC input.
                    floating_output_ttl = is6581 ? WaveformGenerator.FLOATING_OUTPUT_TTL_6581R3 : WaveformGenerator.FLOATING_OUTPUT_TTL_8580R5
                }
            }

            if test != test_prev {
                if test {
                    // Reset accumulator.
                    accumulator = 0

                    // Flush shift pipeline.
                    shift_pipeline = 0

                    // Latch the shift register value.
                    shift_latch = shift_register

                    // Set reset time for shift register.
                    shift_register_reset = is6581 ? WaveformGenerator.SHIFT_REGISTER_RESET_6581R3 : WaveformGenerator.SHIFT_REGISTER_RESET_8580R5
                } else {
                    // When the test bit is falling, the second phase of the shift is
                    // completed by enabling SRAM write.
                    shift_phase2(waveform_prev, waveform)
                }
            }
        }

        mutating func waveBitfade() {
            waveform_output &= waveform_output >> 1
            osc3 = waveform_output
            if waveform_output != 0 {
                floating_output_ttl = is6581 ? WaveformGenerator.FLOATING_OUTPUT_FADE_6581R3 : WaveformGenerator.FLOATING_OUTPUT_FADE_8580R5
            }
        }

        mutating func shiftregBitfade() {
            shift_register |= shift_register >> 1
            shift_register |= 0x400000
            if shift_register != 0x7FFFFF {
                shift_register_reset = is6581 ? WaveformGenerator.SHIFT_REGISTER_FADE_6581R3 : WaveformGenerator.SHIFT_REGISTER_FADE_8580R5
            }
        }

        /// The out-of-line part of clock() while the test bit is set and the shift register is fading.
        @inline(never)
        mutating func clockShiftRegisterReset() {
            shiftregBitfade()
            shift_latch = shift_register

            // New noise waveform output.
            set_noise_output()
        }

        /// SID reset.
        mutating func reset() {
            // accumulator is not changed on reset
            freq = 0
            pw = 0

            msb_rising = false

            waveform = 0
            osc3 = 0

            test = false
            sync = false

            wave = model_wave
            pulldown = nil

            ring_msb_mask = 0
            no_noise = 0xFFF
            no_pulse = 0xFFF
            pulse_output = 0xFFF

            shift_register_reset = 0
            shift_register = 0x7FFFFF
            // when reset is released the shift register is clocked once
            // so the lower bit is zeroed out
            // bit0 = (bit22 | test) ^ bit17 = 1 ^ 1 = 0
            test_or_reset = true
            shift_latch = shift_register
            shift_phase2(0, 0)

            shift_pipeline = 0

            waveform_output = 0
            floating_output_ttl = 0
        }

        /// Read OSC3 value.
        func readOSC() -> UInt8 { UInt8(truncatingIfNeeded: osc3 >> 4) }

        /// Read accumulator value.
        func readAccumulator() -> UInt32 { accumulator }

        /// Read freq value.
        func readFreq() -> UInt32 { freq }

        /// Read test value.
        func readTest() -> Bool { test }

        // MARK: Runs of cycles without special cases

        /// The number of coming cycles for which Quiet (below) does what clock() and output() do, as long as
        /// bit 19 of the accumulator does not rise (which Quiet watches for). 0 while a noise shift is in
        /// progress or noise is combined with another waveform; limited by the countdowns that fade the shift
        /// register (test bit set) and the floating DAC input (no waveform).
        @inline(__always)
        func quietCycles() -> Int32 {
            if shift_pipeline != 0 || waveform > 0x8 {
                return 0
            }
            var quiet = Int32.max
            if test, shift_register_reset != 0 {
                quiet = Int32(truncatingIfNeeded: shift_register_reset &- 1)
            }
            if waveform == 0, floating_output_ttl != 0 {
                let floating = Int32(truncatingIfNeeded: floating_output_ttl &- 1)
                if floating < quiet { quiet = floating }
            }
            return quiet < 0 ? 0 : quiet
        }

        /// What clock() and output() need in a run of quiet cycles, held in local variables (registers) for
        /// the duration of the run: the three members that change from cycle to cycle, and as constants
        /// everything else that is read. The members that are only written (waveform_output, osc3, msb_rising)
        /// are not kept up: the caller always follows a run with a cycle of clock() and output(), which sets
        /// them from scratch.
        struct Quiet {
            var accumulator: UInt32
            var pulse_output: UInt32
            var tri_saw_pipeline: UInt32
            /// 0 while the test bit is set: the accumulator stands still.
            let freq: UInt32
            let pw: UInt32
            let ring_msb_mask: UInt32
            let wave: UnsafePointer<Int16>
            let pulldown: UnsafePointer<Int16>?
            /// `no_pulse`, or all ones while the test bit is set (clock() sets pulse_output to 0xfff every cycle then).
            let no_pulse_or_test: UInt32
            let no_noise_or_noise_output: UInt32
            /// The output while no waveform is selected (the floating DAC input).
            let waveform_output: UInt32
            let hasWaveform: Bool
            let triSaw8580: Bool
            let saw6581: Bool
            let test: Bool

            @inline(__always)
            init(_ w: WaveformGenerator) {
                accumulator = w.accumulator
                pulse_output = w.pulse_output
                tri_saw_pipeline = w.tri_saw_pipeline
                freq = w.test ? 0 : w.freq
                pw = w.pw
                ring_msb_mask = w.ring_msb_mask
                wave = w.wave
                pulldown = w.pulldown
                no_pulse_or_test = w.test ? 0xFFF : w.no_pulse
                no_noise_or_noise_output = w.no_noise_or_noise_output
                waveform_output = w.waveform_output
                hasWaveform = w.waveform != 0
                triSaw8580 = (w.waveform & 3) != 0 && !w.is6581
                saw6581 = w.is6581 && (w.waveform & 0x2) != 0
                test = w.test
            }

            /// The accumulator after the next clock().
            @inline(__always)
            func nextAccumulator() -> UInt32 {
                (accumulator &+ freq) & 0xFFFFFF
            }

            /// output(), after the accumulator has been given nextAccumulator().
            @inline(__always)
            mutating func output(_ prevAccumulator: UInt32) -> UInt32 {
                var output = waveform_output
                if hasWaveform {
                    let ix = Int((accumulator ^ (~prevAccumulator & ring_msb_mask)) >> 12)
                    let wave_ix = UInt32(truncatingIfNeeded: wave[ix])
                    output = wave_ix & (no_pulse_or_test | pulse_output) & no_noise_or_noise_output
                    if let pulldown {
                        output = UInt32(truncatingIfNeeded: pulldown[Int(output)])
                    }

                    if triSaw8580 {
                        tri_saw_pipeline = wave_ix
                    }

                    if saw6581, (output & 0x800) == 0 {
                        accumulator &= 0x7FFFFF
                    }
                }

                pulse_output = ((accumulator >> 12) >= pw) ? 0xFFF : 0x000

                return output
            }

            /// Puts back what `cycles` cycles have changed.
            @inline(__always)
            func finish(_ w: inout WaveformGenerator, _ cycles: Int32) {
                w.accumulator = accumulator
                w.pulse_output = pulse_output
                w.tri_saw_pipeline = tri_saw_pipeline
                if !hasWaveform, w.floating_output_ttl != 0 {
                    w.floating_output_ttl &-= UInt32(truncatingIfNeeded: cycles)
                }
                if test, cycles > 0 {
                    if w.shift_register_reset != 0 {
                        w.shift_register_reset &-= UInt32(truncatingIfNeeded: cycles)
                    }
                    w.test_or_reset = true
                }
            }
        }

        /// SID clocking.
        @inline(__always)
        mutating func clock() {
            if _slowPath(test) {
                if _slowPath(shift_register_reset != 0) {
                    shift_register_reset &-= 1
                    if _slowPath(shift_register_reset == 0) {
                        clockShiftRegisterReset()
                    }
                }

                // Latch the test bit value for shift phase 2.
                test_or_reset = true

                // The test bit sets pulse high.
                pulse_output = 0xFFF
            } else {
                // Calculate new accumulator value;
                let accumulator_old = accumulator
                accumulator = (accumulator &+ freq) & 0xFFFFFF

                // Check which bit have changed from low to high
                let accumulator_bits_set = ~accumulator_old & accumulator

                // Check whether the MSB is set high. This is used for synchronization.
                msb_rising = (accumulator_bits_set & 0x800000) != 0

                // Shift noise register once for each time accumulator bit 19 is set high.
                // The shift is delayed 2 cycles.
                if _slowPath((accumulator_bits_set & 0x080000) != 0) {
                    // Pipeline: Detect rising bit, shift phase 1, shift phase 2.
                    shift_pipeline = 2
                } else if _slowPath(shift_pipeline != 0) {
                    shift_pipeline &-= 1
                    switch shift_pipeline {
                    case 0:
                        shift_phase2(waveform, waveform)
                    case 1:
                        // Start shift phase 1.
                        test_or_reset = false
                        shift_latch = shift_register
                    default:
                        break
                    }
                }
            }
        }

        /// 12-bit waveform output.
        ///
        /// - Parameter prevAccumulator: `prevVoice->accumulator`
        /// - Returns: the waveform generator digital output
        @inline(__always)
        mutating func output(_ prevAccumulator: UInt32) -> UInt32 {
            // Set output value.
            if _fastPath(waveform != 0) {
                let ix = Int((accumulator ^ (~prevAccumulator & ring_msb_mask)) >> 12)

                // The bit masks no_pulse and no_noise are used to achieve branch-free
                // calculation of the output value.
                let wave_ix = UInt32(truncatingIfNeeded: wave[ix])
                waveform_output = wave_ix & (no_pulse | pulse_output) & no_noise_or_noise_output
                if let pulldown {
                    waveform_output = UInt32(truncatingIfNeeded: pulldown[Int(waveform_output)])
                }

                // Triangle/Sawtooth output is delayed half cycle on 8580.
                // This will appear as a one cycle delay on OSC3 as it is latched
                // in the first phase of the clock.
                if (waveform & 3) != 0, !is6581 {
                    osc3 = tri_saw_pipeline & (no_pulse | pulse_output) & no_noise_or_noise_output
                    if let pulldown {
                        osc3 = UInt32(truncatingIfNeeded: pulldown[Int(osc3)])
                    }
                    tri_saw_pipeline = wave_ix
                } else {
                    osc3 = waveform_output
                }

                // In the 6581 the top bit of the accumulator may be driven low by combined waveforms
                // when the sawtooth is selected
                if is6581, (waveform & 0x2) != 0, (waveform_output & 0x800) == 0 {
                    msb_rising = false
                    accumulator &= 0x7FFFFF
                }

                write_shift_register()
            } else {
                // Age floating DAC input.
                if _fastPath(floating_output_ttl != 0) {
                    floating_output_ttl &-= 1
                    if _slowPath(floating_output_ttl == 0) {
                        waveBitfade()
                    }
                }
            }

            // The pulse level is defined as (accumulator >> 12) >= pw ? 0xfff : 0x000.
            // The expression -((accumulator >> 12) >= pw) & 0xfff yields the same
            // results without any branching (and thus without any pipeline stalls).
            // NB! This expression relies on that the result of a boolean expression
            // is either 0 or 1, and furthermore requires two's complement integer.
            // A few more cycles may be saved by storing the pulse width left shifted
            // 12 bits, and dropping the and with 0xfff (this is valid since pulse is
            // used as a bit mask on 12 bit values), yielding the expression
            // -(accumulator >= pw24). However this only results in negligible savings.

            // The result of the pulse width compare is delayed one cycle.
            // Push next pulse level into pulse level pipeline.
            pulse_output = ((accumulator >> 12) >= pw) ? 0xFFF : 0x000

            return waveform_output
        }
    }
}
