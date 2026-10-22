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
// Port of reSID's voice.h / voice.cc and extfilt.h / extfilt.cc.

extension SIDChip {
    struct Voice {
        var wave: WaveformGenerator
        var envelope: EnvelopeGenerator

        // Waveform D/A zero level.
        let wave_zero: Int32

        // ----------------------------------------------------------------------------
        // Constructor / set chip model.
        // ----------------------------------------------------------------------------
        init(model: SIDModel, tables: SIDModelTables) {
            wave = WaveformGenerator(model: model, tables: tables)
            envelope = EnvelopeGenerator(model: model, tables: tables)
            precondition(tables.wave_zero == (model == .mos6581 ? 0x380 : 0x9E0))

            if model == .mos6581 {
                // The waveform D/A converter introduces a DC offset in the signal
                // to the envelope multiplying D/A converter. The "zero" level of
                // the waveform D/A converter can be found as follows:
                //
                // Measure the "zero" voltage of voice 3 on the SID audio output
                // pin, routing only voice 3 to the mixer ($d417 = $0b, $d418 =
                // $0f, all other registers zeroed).
                //
                // Then set the sustain level for voice 3 to maximum and search for
                // the waveform output value yielding the same voltage as found
                // above. See voice.cc in reSID for the program that does this.
                //
                // The waveform output range is 0x000 to 0xfff, so the "zero"
                // level should ideally have been 0x800. In the measured chip, the
                // waveform output "zero" level was found to be 0x380 (i.e. $d41b
                // = 0x38) at an audio output voltage of 5.94V.
                //
                // With knowledge of the mixer op-amp characteristics, further estimates
                // of waveform voltages can be obtained by sampling the EXT IN pin.
                // From EXT IN samples, the corresponding waveform output can be found by
                // using the model for the mixer.
                //
                // Such measurements have been done on a chip marked MOS 6581R4AR
                // 0687 14, and the following results have been obtained:
                // * The full range of one voice is approximately 1.5V.
                // * The "zero" level rides at approximately 5.0V.
                //
                wave_zero = 0x380
            } else {
                // No DC offsets in the MOS8580.
                wave_zero = 0x9E0
            }
        }

        // ----------------------------------------------------------------------------
        // Register functions.
        // ----------------------------------------------------------------------------
        mutating func writeCONTROL_REG(_ control: UInt32, _ sync_source_accumulator: UInt32) {
            wave.writeCONTROL_REG(control, sync_source_accumulator)
            envelope.writeCONTROL_REG(control)
        }

        // ----------------------------------------------------------------------------
        // SID reset.
        // ----------------------------------------------------------------------------
        mutating func reset() {
            wave.reset()
            envelope.reset()
        }

        // ----------------------------------------------------------------------------
        // Amplitude modulated waveform output (20 bits).
        // Ideal range [-2048*255, 2047*255].
        // ----------------------------------------------------------------------------

        // The output for a voice is produced by a multiplying DAC, where the
        // waveform output modulates the envelope output.
        //
        // As noted by Bob Yannes: "The 8-bit output of the Envelope Generator was then
        // sent to the Multiplying D/A converter to modulate the amplitude of the
        // selected Oscillator Waveform (to be technically accurate, actually the
        // waveform was modulating the output of the Envelope Generator, but the result
        // is the same)".
        //
        //          7   6   5   4   3   2   1   0   VGND
        //          |   |   |   |   |   |   |   |     |   Missing
        //         2R  2R  2R  2R  2R  2R  2R  2R    2R   termination
        //          |   |   |   |   |   |   |   |     |
        //          --R---R---R---R---R---R---R--   ---
        //          |          _____
        //        __|__     __|__   |
        //        -----     =====   |
        //        |   |     |   |   |
        // 12V ---     -----     ------- GND
        //               |
        //              vout
        //
        // Bit on:  wout (see figure in wave.h)
        // Bit off: 5V (VGND)
        //
        // As is the case with all MOS 6581 DACs, the termination to (virtual) ground
        // at bit 0 is missing. The MOS 8580 has correct termination.
        //
        @inline(__always)
        func output() -> Int32 {
            // Multiply oscillator output with envelope output.
            (wave.output() &- wave_zero) &* envelope.output()
        }

        /// The same value, for the per-cycle code: `voice_dac` is the wave DAC table with wave_zero
        /// already subtracted and `envelope_dac` the envelope DAC table. Both are the same for the
        /// three voices, so SIDChip passes them in rather than have each voice fetch its own.
        @inline(__always)
        func output(_ voice_dac: UnsafePointer<Int32>, _ envelope_dac: UnsafePointer<UInt16>) -> Int32 {
            voice_dac[Int(wave.waveform_output & 0xFFF)] &* Int32(envelope_dac[Int(envelope.envelope_counter & 0xFF)])
        }
    }

    // ----------------------------------------------------------------------------
    // The audio output stage in a Commodore 64 consists of two STC networks,
    // a low-pass filter with 3-dB frequency 16kHz followed by a high-pass
    // filter with 3-dB frequency 1.6Hz (the latter provided an audio equipment
    // input impedance of 10kOhm).
    // The STC networks are connected with a BJT supposedly meant to act as
    // a unity gain buffer, which is not really how it works. A more elaborate
    // model would include the BJT, however DC circuit analysis yields BJT
    // base-emitter and emitter-base impedances sufficiently low to produce
    // additional low-pass and high-pass 3dB-frequencies in the order of hundreds
    // of kHz. This calls for a sampling frequency of several MHz, which is far
    // too high for practical use.
    // ----------------------------------------------------------------------------
    struct ExternalFilter {
        // Filter enabled.
        var enabled = true

        // State of filters (27 bits).
        var Vlp: Int32 = 0 // lowpass
        var Vhp: Int32 = 0 // highpass

        // Cutoff frequencies.
        let w0lp_1_s7: Int32
        let w0hp_1_s17: Int32

        // ----------------------------------------------------------------------------
        // Constructor.
        // ----------------------------------------------------------------------------
        init() {
            // Low-pass:  R = 10 kOhm, C = 1000 pF; w0l = dt/(dt+RC) = 1e-6/(1e-6+1e4*1e-9) = 0.091
            // High-pass: R =  1 kOhm, C =   10 uF; w0h = dt/(dt+RC) = 1e-6/(1e-6+1e3*1e-5) = 0.0000999
            // Assume a 1MHz clock.
            // Cutoff frequency accuracy (4 bits) is traded off for filter signal
            // accuracy (27 bits). This is crucial since w0lp and w0hp are so far apart.
            w0lp_1_s7 = sid_int(1e-6 / (1e-6 + 1e4 * 1e-9) * Double(1 << 7) + 0.5)
            w0hp_1_s17 = sid_int(1e-6 / (1e-6 + 1e3 * 1e-5) * Double(1 << 17) + 0.5)
        }

        // ----------------------------------------------------------------------------
        // Enable filter.
        // ----------------------------------------------------------------------------
        mutating func enable_filter(_ enable: Bool) {
            enabled = enable
        }

        // ----------------------------------------------------------------------------
        // SID reset.
        // ----------------------------------------------------------------------------
        mutating func reset() {
            // State of filter.
            Vlp = 0
            Vhp = 0
        }

        // ----------------------------------------------------------------------------
        // SID clocking - 1 cycle.
        // ----------------------------------------------------------------------------
        @inline(__always)
        mutating func clock(_ Vi: Int32) {
            // This is handy for testing.
            if _slowPath(!enabled) {
                // Vo  = Vlp - Vhp;
                Vlp = Vi << 11
                Vhp = 0
                return
            }

            // Calculate filter outputs.
            // Vlp = Vlp + w0lp*(Vi - Vlp)*delta_t;
            // Vhp = Vhp + w0hp*(Vlp - Vhp)*delta_t;
            // Vo  = Vlp - Vhp;

            let dVlp = (w0lp_1_s7 &* ((Vi << 11) &- Vlp)) >> 7
            let dVhp = (w0hp_1_s17 &* (Vlp &- Vhp)) >> 17
            Vlp = Vlp &+ dVlp
            Vhp = Vhp &+ dVhp
        }

        // ----------------------------------------------------------------------------
        // SID clocking - delta_t cycles.
        // ----------------------------------------------------------------------------
        @inline(__always)
        mutating func clock(_ delta_t: Int32, _ Vi: Int32) {
            var delta_t = delta_t
            // This is handy for testing.
            if _slowPath(!enabled) {
                // Vo  = Vlp - Vhp;
                Vlp = Vi << 11
                Vhp = 0
                return
            }

            // Maximum delta cycles for the external filter to work satisfactorily
            // is approximately 8.
            var delta_t_flt: Int32 = 8

            while delta_t != 0 {
                if _slowPath(delta_t < delta_t_flt) {
                    delta_t_flt = delta_t
                }

                // Calculate filter outputs.
                // Vlp = Vlp + w0lp*(Vi - Vlp)*delta_t;
                // Vhp = Vhp + w0hp*(Vlp - Vhp)*delta_t;
                // Vo  = Vlp - Vhp;

                let dVlp = (((w0lp_1_s7 &* delta_t_flt) >> 3) &* ((Vi << 11) &- Vlp)) >> 4
                let dVhp = (((w0hp_1_s17 &* delta_t_flt) >> 3) &* (Vlp &- Vhp)) >> 14
                Vlp = Vlp &+ dVlp
                Vhp = Vhp &+ dVhp

                delta_t &-= delta_t_flt
            }
        }

        // ----------------------------------------------------------------------------
        // Audio output (16 bits).
        // ----------------------------------------------------------------------------
        @inline(__always)
        func output() -> Int32 {
            (Vlp &- Vhp) >> 11
        }
    }
}
