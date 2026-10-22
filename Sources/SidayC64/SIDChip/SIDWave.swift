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
// Port of reSID's wave.h / wave.cc.
//
// reSID links the three oscillators with sync_source / sync_dest pointers. A Swift struct cannot
// point at its siblings, so the functions that look at a neighbour take what they need as
// arguments; SIDChip passes voice 3 to voice 1, voice 1 to voice 2 and voice 2 to voice 3.

// Number of cycles after which the shift register is reset
// when the test bit is set.
private let SHIFT_REGISTER_RESET_START_6581: Int32 = 35000 // 0x8000
private let SHIFT_REGISTER_RESET_BIT_6581: Int32 = 1000
private let SHIFT_REGISTER_RESET_START_8580: Int32 = 2_519_864 // 0x950000
private let SHIFT_REGISTER_RESET_BIT_8580: Int32 = 315_000

// Number of cycles after which the waveform output fades to 0 when setting
// the waveform register to 0.
//
// We have two SOAS/C samplings showing that floating DAC
// keeps its state for at least 0x14000 cycles.
//
// This can't be found via sampling OSC3, it seems that
// the actual analog output must be sampled and timed.
private let FLOATING_OUTPUT_TTL_START_6581: Int32 = 182_000 // ~200ms
private let FLOATING_OUTPUT_TTL_BIT_6581: Int32 = 1500
private let FLOATING_OUTPUT_TTL_START_8580: Int32 = 4_400_000 // ~5s
private let FLOATING_OUTPUT_TTL_BIT_8580: Int32 = 50000

extension SIDChip {
    // ----------------------------------------------------------------------------
    // A 24 bit accumulator is the basis for waveform generation. FREQ is added to
    // the lower 16 bits of the accumulator each cycle.
    // The accumulator is set to zero when TEST is set, and starts counting
    // when TEST is cleared.
    // The noise waveform is taken from intermediate bits of a 23 bit shift
    // register. This register is clocked by bit 19 of the accumulator.
    // ----------------------------------------------------------------------------
    struct WaveformGenerator {
        var accumulator: UInt32

        // Tell whether the accumulator MSB was set high on this cycle.
        var msb_rising = false

        // Fout  = (Fn*Fclk/16777216)Hz
        var freq: UInt32 = 0
        // PWout = (PWn/40.95)%
        var pw: UInt32 = 0

        var shift_register: UInt32 = 0

        // Remaining time to fully reset shift register.
        var shift_register_reset: Int32 = 0
        // Emulation of pipeline causing bit 19 to clock the shift register.
        var shift_pipeline: Int32 = 0

        // Helper variables for waveform table lookup.
        var ring_msb_mask: UInt32 = 0
        var no_noise: UInt32 = 0
        var noise_output: UInt32 = 0
        var no_noise_or_noise_output: UInt32 = 0
        var no_pulse: UInt32 = 0
        var pulse_output: UInt32 = 0

        // The control register right-shifted 4 bits; used for waveform table lookup.
        var waveform: UInt32 = 0

        /// Which of the special cases in set_waveform_output() the selected waveform can need;
        /// see set_output_kind().
        var output_kind: UInt32 = 0

        // 8580 tri/saw pipeline
        var tri_saw_pipeline: UInt32
        var osc3: UInt32 = 0

        // The remaining control register bits.
        var test: UInt32 = 0
        var ring_mod: UInt32 = 0
        var sync: UInt32 = 0
        // The gate bit is handled by the EnvelopeGenerator.

        // DAC input.
        var waveform_output: UInt32 = 0
        // Fading time for floating DAC input (waveform 0).
        var floating_output_ttl: Int32 = 0

        let sid_model: SIDModel
        /// `sid_model == MOS6581`, kept as a flag for the per-cycle code.
        let is6581: Bool

        // Sample data for waveforms, not including noise.
        var wave: UnsafePointer<UInt16>
        let model_wave: UnsafePointer<UInt16>
        // DAC lookup tables.
        let model_dac: UnsafePointer<UInt16>

        // ----------------------------------------------------------------------------
        // Constructor.
        // ----------------------------------------------------------------------------
        init(model: SIDModel, tables: SIDModelTables) {
            sid_model = model
            is6581 = model == .mos6581
            model_wave = UnsafePointer(tables.model_wave)
            model_dac = UnsafePointer(tables.wave_dac)
            wave = model_wave

            // Accumulator's even bits are high on powerup
            accumulator = 0x555555

            tri_saw_pipeline = 0x555

            reset()
        }

        // ----------------------------------------------------------------------------
        // Register functions.
        // ----------------------------------------------------------------------------
        mutating func writeFREQ_LO(_ freq_lo: UInt32) {
            freq = (freq & 0xFF00) | (freq_lo & 0x00FF)
        }

        mutating func writeFREQ_HI(_ freq_hi: UInt32) {
            freq = ((freq_hi << 8) & 0xFF00) | (freq & 0x00FF)
        }

        mutating func writePW_LO(_ pw_lo: UInt32) {
            pw = (pw & 0xF00) | (pw_lo & 0x0FF)
            // Push next pulse level into pulse level pipeline.
            pulse_output = (accumulator >> 12) >= pw ? 0xFFF : 0x000
        }

        mutating func writePW_HI(_ pw_hi: UInt32) {
            pw = ((pw_hi << 8) & 0xF00) | (pw & 0x0FF)
            // Push next pulse level into pulse level pipeline.
            pulse_output = (accumulator >> 12) >= pw ? 0xFFF : 0x000
        }

        static func do_pre_writeback(_ waveform_prev: UInt32, _ waveform: UInt32, _ is6581: Bool) -> Bool {
            // no writeback without combined waveforms
            if waveform_prev <= 0x8 {
                return false
            }
            if waveform_prev == 0xC {
                if is6581 {
                    return false
                } else if waveform != 0x9, waveform != 0xE {
                    return false
                }
            }
            // What's happening here?
            if is6581,
               ((waveform_prev & 0x3) == 0x1 && (waveform & 0x3) == 0x2)
               || ((waveform_prev & 0x3) == 0x2 && (waveform & 0x3) == 0x1)
            {
                return false
            }
            // ok do the writeback
            return true
        }

        mutating func writeCONTROL_REG(_ control: UInt32, _ sync_source_accumulator: UInt32) {
            let waveform_prev = waveform
            let test_prev = test
            waveform = (control >> 4) & 0x0F
            test = control & 0x08
            ring_mod = control & 0x04
            sync = control & 0x02

            // Set up waveform table.
            wave = model_wave + Int(waveform & 0x7) * (1 << 12)
            set_output_kind()

            // Substitution of accumulator MSB when sawtooth = 0, ring_mod = 1.
            ring_msb_mask = ((~control >> 5) & (control >> 2) & 0x1) << 23

            // no_noise and no_pulse are used in set_waveform_output() as bitmasks to
            // only let the noise or pulse influence the output when the noise or pulse
            // waveforms are selected.
            no_noise = (waveform & 0x8) != 0 ? 0x000 : 0xFFF
            no_noise_or_noise_output = no_noise | noise_output
            no_pulse = (waveform & 0x4) != 0 ? 0x000 : 0xFFF

            // Test bit rising.
            // The accumulator is cleared, while the the shift register is prepared for
            // shifting by interconnecting the register bits. The internal SRAM cells
            // start to slowly rise up towards one. The SRAM cells reach one within
            // approximately $8000 cycles, yielding a shift register value of
            // 0x7fffff.
            if test_prev == 0, test != 0 {
                // Reset accumulator.
                accumulator = 0

                // Flush shift pipeline.
                shift_pipeline = 0

                // Set reset time for shift register.
                shift_register_reset = is6581 ? SHIFT_REGISTER_RESET_START_6581 : SHIFT_REGISTER_RESET_START_8580

                // The test bit sets pulse high.
                pulse_output = 0xFFF
            } else if test_prev != 0, test == 0 {
                // When the test bit is falling, the second phase of the shift is
                // completed by enabling SRAM write.

                // During first phase of the shift the bits are interconnected
                // and the output of each bit is latched into the following.
                // The output may overwrite the latched value.
                if Self.do_pre_writeback(waveform_prev, waveform, is6581) {
                    write_shift_register()
                }

                // bit0 = (bit22 | test) ^ bit17 = 1 ^ bit17 = ~bit17
                let bit0 = (~shift_register >> 17) & 0x1
                shift_register = ((shift_register << 1) | bit0) & 0x7FFFFF

                // Set new noise waveform output.
                set_noise_output()
            }

            if waveform != 0 {
                // Set new waveform output.
                set_waveform_output(sync_source_accumulator)
            } else if waveform_prev != 0 {
                // Change to floating DAC input.
                // Reset fading time for floating DAC input.
                floating_output_ttl = is6581 ? FLOATING_OUTPUT_TTL_START_6581 : FLOATING_OUTPUT_TTL_START_8580
            }

            // The gate bit is handled by the EnvelopeGenerator.
        }

        mutating func wave_bitfade() {
            waveform_output &= waveform_output >> 1
            osc3 = waveform_output
            if waveform_output != 0 {
                floating_output_ttl = is6581 ? FLOATING_OUTPUT_TTL_BIT_6581 : FLOATING_OUTPUT_TTL_BIT_8580
            }
        }

        mutating func shiftreg_bitfade() {
            shift_register |= 1
            shift_register |= shift_register << 1

            // New noise waveform output.
            set_noise_output()
            if shift_register != 0x7FFFFF {
                shift_register_reset = is6581 ? SHIFT_REGISTER_RESET_BIT_6581 : SHIFT_REGISTER_RESET_BIT_8580
            }
        }

        func readOSC() -> UInt32 {
            osc3 >> 4
        }

        // ----------------------------------------------------------------------------
        // SID reset.
        // ----------------------------------------------------------------------------
        mutating func reset() {
            // accumulator is not changed on reset
            freq = 0
            pw = 0

            msb_rising = false

            waveform = 0
            test = 0
            ring_mod = 0
            sync = 0

            wave = model_wave
            set_output_kind()

            ring_msb_mask = 0
            no_noise = 0xFFF
            no_pulse = 0xFFF
            pulse_output = 0xFFF

            // reset shift register
            // when reset is released the shift register is clocked once
            shift_register = 0x7FFFFE
            shift_register_reset = 0
            set_noise_output()

            shift_pipeline = 0

            waveform_output = 0
            osc3 = 0
            floating_output_ttl = 0
        }

        // ----------------------------------------------------------------------------
        // SID clocking - 1 cycle.
        // ----------------------------------------------------------------------------
        @inline(__always)
        mutating func clock() {
            if _slowPath(test != 0) {
                // Count down time to fully reset shift register.
                if shift_register_reset != 0 {
                    shift_register_reset &-= 1
                    if shift_register_reset == 0 {
                        shiftreg_bitfade()
                    }
                }

                // The test bit sets pulse high.
                pulse_output = 0xFFF
            } else {
                // Calculate new accumulator value;
                let accumulator_next = (accumulator &+ freq) & 0xFFFFFF
                let accumulator_bits_set = ~accumulator & accumulator_next
                accumulator = accumulator_next

                // Check whether the MSB is set high. This is used for synchronization.
                msb_rising = (accumulator_bits_set & 0x800000) != 0

                // Shift noise register once for each time accumulator bit 19 is set high.
                // The shift is delayed 2 cycles.
                if _slowPath((accumulator_bits_set & 0x080000) != 0) {
                    // Pipeline: Detect rising bit, shift phase 1, shift phase 2.
                    shift_pipeline = 2
                } else if _slowPath(shift_pipeline != 0) {
                    shift_pipeline &-= 1
                    if shift_pipeline == 0 {
                        clock_shift_register()
                    }
                }
            }
        }

        // ----------------------------------------------------------------------------
        // SID clocking - delta_t cycles.
        // ----------------------------------------------------------------------------
        @inline(__always)
        mutating func clock(_ delta_t: Int32) {
            if _slowPath(test != 0) {
                // Count down time to fully reset shift register.
                if shift_register_reset != 0 {
                    shift_register_reset &-= delta_t
                    if shift_register_reset <= 0 {
                        shift_register = 0x7FFFFF
                        shift_register_reset = 0

                        // New noise waveform output.
                        set_noise_output()
                    }
                }

                // The test bit sets pulse high.
                pulse_output = 0xFFF
            } else {
                // Calculate new accumulator value;
                var delta_accumulator = UInt32(bitPattern: delta_t) &* freq
                let accumulator_next = (accumulator &+ delta_accumulator) & 0xFFFFFF
                let accumulator_bits_set = ~accumulator & accumulator_next
                accumulator = accumulator_next

                // Check whether the MSB is set high. This is used for synchronization.
                msb_rising = (accumulator_bits_set & 0x800000) != 0

                // NB! Any pipelined shift register clocking from single cycle clocking
                // will be lost. It is not worth the trouble to flush the pipeline here.

                // Shift noise register once for each time accumulator bit 19 is set high.
                // Bit 19 is set high each time 2^20 (0x100000) is added to the accumulator.
                var shift_period: UInt32 = 0x100000

                while delta_accumulator != 0 {
                    if delta_accumulator < shift_period {
                        shift_period = delta_accumulator
                        // Determine whether bit 19 is set on the last period.
                        // NB! Requires two's complement integer.
                        if shift_period <= 0x080000 {
                            // Check for flip from 0 to 1.
                            if ((accumulator &- shift_period) & 0x080000) != 0 || (accumulator & 0x080000) == 0 {
                                break
                            }
                        } else {
                            // Check for flip from 0 (to 1 or via 1 to 0) or from 1 via 0 to 1.
                            if ((accumulator &- shift_period) & 0x080000) != 0, (accumulator & 0x080000) == 0 {
                                break
                            }
                        }
                    }

                    // Shift the noise/random register.
                    // NB! The two-cycle pipeline delay is only modeled for 1 cycle clocking.
                    clock_shift_register()

                    delta_accumulator &-= shift_period
                }

                // Calculate pulse high/low.
                // NB! The one-cycle pipeline delay is only modeled for 1 cycle clocking.
                pulse_output = (accumulator >> 12) >= pw ? 0xFFF : 0x000
            }
        }

        // ----------------------------------------------------------------------------
        // Synchronize oscillators.
        // This must be done after all the oscillators have been clock()'ed since the
        // oscillators operate in parallel.
        // Note that the oscillators must be clocked exactly on the cycle when the
        // MSB is set high for hard sync to operate correctly. See SID::clock().
        // ----------------------------------------------------------------------------
        @inline(__always)
        func synchronize(_ sync_dest: inout WaveformGenerator, _ sync_source_msb_rising: Bool) {
            // A special case occurs when a sync source is synced itself on the same
            // cycle as when its MSB is set high. In this case the destination will
            // not be synced. This has been verified by sampling OSC3.
            if _slowPath(msb_rising), sync_dest.sync != 0, !(sync != 0 && sync_source_msb_rising) {
                sync_dest.accumulator = 0
            }
        }

        // ----------------------------------------------------------------------------
        // Waveform output.
        // The output from SID 8580 is delayed one cycle compared to SID 6581;
        // this is only modeled for single cycle clocking (see sid.cc).
        // ----------------------------------------------------------------------------
        //
        // See wave.h in reSID for the description of each waveform and of combined waveforms.

        // Noise:
        // The noise output is taken from intermediate bits of a 23-bit shift register
        // which is clocked by bit 19 of the accumulator.
        // The shift is delayed 2 cycles after bit 19 is set high; this is only
        // modeled for single cycle clocking.
        //
        // Operation: Calculate EOR result, shift register, set bit 0 = result.
        //
        //                reset    -------------------------------------------
        //                  |     |                                           |
        //           test--OR-->EOR<--                                        |
        //                  |         |                                       |
        //                  2 2 2 1 1 1 1 1 1 1 1 1 1                         |
        // Register bits:   2 1 0 9 8 7 6 5 4 3 2 1 0 9 8 7 6 5 4 3 2 1 0 <---
        //                      |   |       |     |   |       |     |   |
        // Waveform bits:       1   1       9     8   7       6     5   4
        //                      1   0
        //
        // The low 4 waveform bits are zero (grounded).

        @inline(__always)
        mutating func clock_shift_register() {
            // bit0 = (bit22 | test) ^ bit17
            let bit0 = ((shift_register >> 22) ^ (shift_register >> 17)) & 0x1
            shift_register = ((shift_register << 1) | bit0) & 0x7FFFFF

            // New noise waveform output.
            set_noise_output()
        }

        @inline(__always)
        mutating func write_shift_register() {
            // Write changes to the shift register output caused by combined waveforms
            // back into the shift register.
            // A bit once set to zero cannot be changed, hence the and'ing.
            // FIXME: Write test program to check the effect of 1 bits and whether
            // neighboring bits are affected.

            let w = waveform_output
            var bits: UInt32 = ~UInt32(0x144A25) // ~((1<<20)|(1<<18)|(1<<14)|(1<<11)|(1<<9)|(1<<5)|(1<<2)|(1<<0))
            bits |= (w & 0x800) << 9 // Bit 11 -> bit 20
            bits |= (w & 0x400) << 8 // Bit 10 -> bit 18
            bits |= (w & 0x200) << 5 // Bit  9 -> bit 14
            bits |= (w & 0x100) << 3 // Bit  8 -> bit 11
            bits |= (w & 0x080) << 2 // Bit  7 -> bit  9
            bits |= (w & 0x040) >> 1 // Bit  6 -> bit  5
            bits |= (w & 0x020) >> 3 // Bit  5 -> bit  2
            bits |= (w & 0x010) >> 4 // Bit  4 -> bit  0
            shift_register &= bits

            noise_output &= waveform_output
            no_noise_or_noise_output = no_noise | noise_output
        }

        @inline(__always)
        mutating func set_noise_output() {
            let r = shift_register
            var bits: UInt32 = (r & 0x100000) >> 9
            bits |= (r & 0x040000) >> 8
            bits |= (r & 0x004000) >> 5
            bits |= (r & 0x000800) >> 3
            bits |= (r & 0x000200) >> 2
            bits |= (r & 0x000020) << 1
            bits |= (r & 0x000004) << 3
            bits |= (r & 0x000001) << 4
            noise_output = bits

            no_noise_or_noise_output = no_noise | noise_output
        }

        @inline(__always)
        static func noise_pulse6581(_ noise: UInt32) -> UInt32 {
            noise < 0xF00 ? 0x000 : noise & (noise << 1) & (noise << 2)
        }

        @inline(__always)
        static func noise_pulse8580(_ noise: UInt32) -> UInt32 {
            noise < 0xFC0 ? noise & (noise << 1) : 0xFC0
        }

        /// set_waveform_output() tests the waveform bits and the chip model on every cycle to decide
        /// on the noise+pulse output, the 8580 triangle/sawtooth pipeline, the 6581 accumulator MSB
        /// write-back, the shift register write-back and the floating DAC. Which of those can apply
        /// is settled when the control register is written, so it is worked out here once:
        ///   0  anything goes: set_waveform_output() as reSID has it
        ///   1  none of them: the table lookup and the pulse compare are all there is
        ///   2  as 1, with the 8580 triangle/sawtooth pipeline for OSC3
        mutating func set_output_kind() {
            let noise_pulse = (waveform & 0xC) == 0xC
            let msb_writeback = (waveform & 0x2) != 0 && (waveform & 0xD) != 0 && is6581
            let shift_writeback = waveform > 0x8
            if waveform == 0 || noise_pulse || msb_writeback || shift_writeback {
                output_kind = 0
            } else if (waveform & 3) != 0, !is6581 {
                output_kind = 2
            } else {
                output_kind = 1
            }
        }

        /// set_waveform_output() for the per-cycle code: the two common cases written out, anything
        /// else passed on.
        @inline(__always)
        mutating func set_waveform_output_fast(_ sync_source_accumulator: UInt32) {
            let kind = output_kind
            if _slowPath(kind == 0) {
                set_waveform_output(sync_source_accumulator)
                return
            }
            let ix = Int((accumulator ^ (~sync_source_accumulator & ring_msb_mask)) >> 12)
            let wave_ix = UInt32(wave[ix])
            let mask = (no_pulse | pulse_output) & no_noise_or_noise_output
            waveform_output = wave_ix & mask
            if kind == 2 {
                osc3 = tri_saw_pipeline & mask
                tri_saw_pipeline = wave_ix
            } else {
                osc3 = waveform_output
            }
            pulse_output = (accumulator >> 12) >= pw ? 0xFFF : 0x000
        }

        @inline(__always)
        mutating func set_waveform_output(_ sync_source_accumulator: UInt32) {
            // Set output value.
            if _fastPath(waveform != 0) {
                // The bit masks no_pulse and no_noise are used to achieve branch-free
                // calculation of the output value.
                let ix = Int((accumulator ^ (~sync_source_accumulator & ring_msb_mask)) >> 12)

                waveform_output = UInt32(wave[ix]) & (no_pulse | pulse_output) & no_noise_or_noise_output

                if _slowPath((waveform & 0xC) == 0xC) {
                    waveform_output = is6581 ?
                        Self.noise_pulse6581(waveform_output) : Self.noise_pulse8580(waveform_output)
                }

                // Triangle/Sawtooth output is delayed half cycle on 8580.
                // This will appear as a one cycle delay on OSC3 as it is
                // latched in the first phase of the clock.
                if (waveform & 3) != 0, !is6581 {
                    osc3 = tri_saw_pipeline & (no_pulse | pulse_output) & no_noise_or_noise_output
                    tri_saw_pipeline = UInt32(wave[ix])
                } else {
                    osc3 = waveform_output
                }

                if (waveform & 0x2) != 0, _slowPath((waveform & 0xD) != 0), is6581 {
                    // In the 6581 the top bit of the accumulator may be driven low by combined waveforms
                    // when the sawtooth is selected
                    accumulator &= (waveform_output << 12) | 0x7FFFFF
                }

                if _slowPath(waveform > 0x8), test == 0, shift_pipeline != 1 {
                    // Combined waveforms write to the shift register.
                    write_shift_register()
                }
            } else {
                // Age floating DAC input.
                if floating_output_ttl != 0 {
                    floating_output_ttl &-= 1
                    if _slowPath(floating_output_ttl == 0) {
                        wave_bitfade()
                    }
                }
            }

            // The pulse level is defined as (accumulator >> 12) >= pw ? 0xfff : 0x000.
            // The result of the pulse width compare is delayed one cycle.
            // Push next pulse level into pulse level pipeline.
            pulse_output = (accumulator >> 12) >= pw ? 0xFFF : 0x000
        }

        @inline(__always)
        mutating func set_waveform_output(_ delta_t: Int32, _ sync_source_accumulator: UInt32) {
            // Set output value.
            if _fastPath(waveform != 0) {
                // The bit masks no_pulse and no_noise are used to achieve branch-free
                // calculation of the output value.
                let ix = Int((accumulator ^ (~sync_source_accumulator & ring_msb_mask)) >> 12)
                waveform_output =
                    UInt32(wave[ix]) & (no_pulse | pulse_output) & no_noise_or_noise_output
                // Triangle/Sawtooth output delay for the 8580 is not modeled
                osc3 = waveform_output

                if (waveform & 0x2) != 0, (waveform & 0xD) != 0, is6581 {
                    accumulator &= (waveform_output << 12) | 0x7FFFFF
                }

                if waveform > 0x8, test == 0 {
                    // Combined waveforms write to the shift register.
                    // NB! Since cycles are skipped in delta_t clocking, writes will be
                    // missed. Single cycle clocking must be used for 100% correct operation.
                    write_shift_register()
                }
            } else {
                if floating_output_ttl != 0 {
                    // Age floating D/A output.
                    floating_output_ttl &-= delta_t
                    if floating_output_ttl <= 0 {
                        floating_output_ttl = 0
                        waveform_output = 0
                        osc3 = 0
                    }
                }
            }
        }

        // ----------------------------------------------------------------------------
        // Waveform output (12 bits).
        // ----------------------------------------------------------------------------

        // The digital waveform output is converted to an analog signal by a 12-bit
        // DAC. Re-vectorized die photographs reveal that the DAC is an R-2R ladder
        // built up as follows:
        //
        //        12V     11  10   9   8   7   6   5   4   3   2   1   0    GND
        // Strange  |      |   |   |   |   |   |   |   |   |   |   |   |     |  Missing
        // part    2R     2R  2R  2R  2R  2R  2R  2R  2R  2R  2R  2R  2R    2R  term.
        // (bias)   |      |   |   |   |   |   |   |   |   |   |   |   |     |
        //          --R-   --R---R---R---R---R---R---R---R---R---R---R--   ---
        //                 |          _____
        //               __|__     __|__   |
        //               -----     =====   |
        //               |   |     |   |   |
        //        12V ---     -----     ------- GND
        //                      |
        //                     wout
        //
        // Bit on:  5V
        // Bit off: 0V (GND)
        //
        // As is the case with all MOS 6581 DACs, the termination to (virtual) ground
        // at bit 0 is missing. The MOS 8580 has correct termination, and has also
        // done away with the bias part on the left hand side of the figure above.

        @inline(__always)
        func output() -> Int32 {
            // DAC imperfections are emulated by using waveform_output as an index
            // into a DAC lookup table. readOSC() uses waveform_output directly.
            Int32(model_dac[Int(waveform_output & 0xFFF)])
        }
    }
}
