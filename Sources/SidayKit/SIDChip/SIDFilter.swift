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
// Port of the per-cycle half of reSID's filter8580new.h / filter8580new.cc: the filter this
// version of reSID builds by default (NEW_8580_FILTER) and uses for both chip models. The table
// construction from the Filter constructor is in SIDTables.swift.
//
// Differences in form, not in result:
// - reSID picks the summer and mixer inputs with a 16-way and a 128-way switch written out by a
//   Perl script. Each case adds the selected inputs and picks a table offset by how many there
//   are, so here set_sum_mix() turns the routing bits into AND masks and an offset once per
//   register write (the `sum_*` and `mix_*` members), and the per-cycle code needs no switch.
// - Where reSID asserts that a table index is in range, the tables here have margins (see
//   SIDModelTables) or the index is clamped; identical while the asserts hold, and memory-safe when
//   they would not. `opamp_rev_mid`, `vcr_n_Ids_term_mid` and `resonance_res` are the same tables
//   addressed from the element the index is relative to, which takes an add or a shift out of the
//   feedback path that decides how fast the filter can be clocked.

extension SIDChip {
    // ----------------------------------------------------------------------------
    // The SID filter is modeled with a two-integrator-loop biquadratic filter,
    // which has been confirmed by Bob Yannes to be the actual circuit used in
    // the SID chip.
    //
    // Measurements show that excellent emulation of the SID filter is achieved,
    // except when high resonance is combined with high sustain levels.
    // In this case the SID op-amps are performing less than ideally and are
    // causing some peculiar behavior of the SID filter. This however seems to
    // have more effect on the overall amplitude than on the color of the sound.
    //
    // The theory for the filter circuit can be found in "Microelectric Circuits"
    // by Adel S. Sedra and Kenneth C. Smith. See filter8580new.h in reSID for the
    // full circuit description and the derivation of the integrator models.
    // ----------------------------------------------------------------------------
    struct Filter: ~Copyable {
        /// reSID's Filter::Randomnoise: 1024 values of `rand() % (1 << 19)` added to the voice
        /// outputs as dither. The C++ takes them from libc's rand(), so its output depends on the
        /// platform's generator and on anything else in the process that has called rand().
        /// This is macOS's rand() from its default seed (Park-Miller, x = 16807*x mod 2^31-1),
        /// i.e. what the first SID constructed in a fresh process gets on macOS.
        struct Randomnoise {
            let buffer: UnsafeMutablePointer<Int32>
            var index: Int32 = 0

            init() {
                buffer = .allocate(capacity: 1024)
                var next: UInt64 = 1
                for i in 0 ..< 1024 {
                    next = (16807 &* next) % 0x7FFF_FFFF
                    buffer[i] = Int32(truncatingIfNeeded: next) % (1 << 19)
                }
            }

            @inline(__always)
            mutating func getNoise() -> Int32 {
                index = (index &+ 1) & 0x3FF
                return buffer[Int(index)]
            }
        }

        // Filter enabled.
        var enabled = true

        // Filter cutoff frequency.
        var fc: UInt32 = 0

        // Filter resonance.
        var res: UInt32 = 0

        // Selects which voices to route through the filter.
        var filt: UInt32 = 0

        // Selects which filter outputs to route into the mixer.
        var mode: UInt32 = 0

        // Output master volume.
        var vol: UInt32 = 0

        // Used to mask out EXT IN if not connected, and for test purposes
        // (voice muting).
        var voice_mask: UInt32 = 0xF7

        // Select which inputs to route into the summer / mixer.
        // These are derived from filt, mode, and voice_mask.
        var sum: UInt32 = 0
        var mix: UInt32 = 0

        // The same routing as AND masks (0 or -1) and table offsets; see the note at the top of the file.
        // EXT IN only changes when input() is called, so its share of each sum is kept with the
        // table offset: sum_offset_ve = summer offset + (routed ? ve : 0), and likewise for the mixer.
        var sum_v1: Int32 = 0, sum_v2: Int32 = 0, sum_v3: Int32 = 0
        var sum_offset_ve: Int32 = 0
        var mix_v1: Int32 = 0, mix_v2: Int32 = 0, mix_v3: Int32 = 0
        var mix_Vlp: Int32 = 0, mix_Vbp: Int32 = 0, mix_Vhp: Int32 = 0
        var mix_filt = false
        var mix_offset_ve: Int32 = 0

        // State of filter.
        var Vhp: Int32 = 0 // highpass
        var Vbp: Int32 = 0 // bandpass
        var Vbp_x: Int32 = 0, Vbp_vc: Int32 = 0
        var Vlp: Int32 = 0 // lowpass
        var Vlp_x: Int32 = 0, Vlp_vc: Int32 = 0

        // Filter / mixer inputs.
        var ve: Int32 = 0
        var v3: Int32 = 0
        var v2: Int32 = 0
        var v1: Int32 = 0

        let sid_model: SIDModel
        let is6581: Bool

        // model_filter[sid_model], copied out of the shared tables.
        let kVddt: Int32 // K*(Vdd - Vth)
        let voice_scale_s14: Int32
        let voice_DC: Int32
        let filterGain: Int32
        /// `32767 * ((1 << 12) - f.filterGain)` from Filter::output().
        let dc_offset: Int32
        // Reverse op-amp transfer function.
        let opamp_rev: UnsafePointer<UInt16>
        /// `opamp_rev + (1 << 15)`: indexed with `vc >> 15`.
        let opamp_rev_mid: UnsafePointer<UInt16>
        // Lookup tables for gain and summer op-amps in output stage / filter.
        let summer: UnsafePointer<UInt16>
        let gain: UnsafePointer<UInt16>
        /// `f.gain[vol]`, set whenever `vol` changes.
        var gain_vol: UnsafePointer<UInt16>
        let resonance: UnsafePointer<UInt16>
        /// `f.resonance[res]`, set whenever `res` changes.
        var resonance_res: UnsafePointer<UInt16>
        let mixer: UnsafePointer<UInt16>
        // Cutoff frequency DAC output voltage table. FC is an 11 bit register.
        let f0_dac: UnsafePointer<UInt16>

        // 6581 only
        // Cutoff frequency DAC voltage, resonance.
        var Vddt_Vw_2: Int32 = 0, Vw_bias: Int32 = 0
        let n_snake: Int32

        // 8580 only
        var n_dac: Int32 = 0
        let n_param: Int32

        // DAC gate voltage
        var nVgt: Int32 = 0

        // VCR - 6581 only.
        let vcr_kVg: UnsafePointer<UInt16>
        let vcr_n_Ids_term: UnsafePointer<UInt16>
        /// `vcr_n_Ids_term + (1 << 15)`: indexed with `kVg - vx` and `kVg - vi`.
        let vcr_n_Ids_term_mid: UnsafePointer<UInt16>

        var rnd = Randomnoise()

        // ----------------------------------------------------------------------------
        // Constructor.
        // ----------------------------------------------------------------------------
        init(model: SIDModel, tables: SIDModelTables) {
            sid_model = model
            is6581 = model == .mos6581
            kVddt = tables.kVddt
            voice_scale_s14 = tables.voice_scale_s14
            voice_DC = tables.voice_DC
            filterGain = tables.filterGain
            dc_offset = 32767 &* ((1 << 12) &- tables.filterGain)
            opamp_rev = UnsafePointer(tables.opamp_rev)
            opamp_rev_mid = UnsafePointer(tables.opamp_rev) + (1 << 15)
            summer = UnsafePointer(tables.summer)
            gain = UnsafePointer(tables.gain)
            gain_vol = UnsafePointer(tables.gain)
            resonance = UnsafePointer(tables.resonance)
            resonance_res = UnsafePointer(tables.resonance)
            mixer = UnsafePointer(tables.mixer)
            f0_dac = UnsafePointer(tables.f0_dac)
            n_snake = tables.n_snake
            n_param = tables.n_param
            vcr_kVg = UnsafePointer(tables.vcr_kVg)
            vcr_n_Ids_term = UnsafePointer(tables.vcr_n_Ids_term)
            vcr_n_Ids_term_mid = UnsafePointer(tables.vcr_n_Ids_term) + (1 << 15)
            Vw_bias = 0
            nVgt = tables.nVgt

            enable_filter(true)
            set_voice_mask(0x07)
            input(0)
            reset()
        }

        deinit {
            rnd.buffer.deallocate()
        }

        // ----------------------------------------------------------------------------
        // Enable filter.
        // ----------------------------------------------------------------------------
        mutating func enable_filter(_ enable: Bool) {
            enabled = enable
            set_sum_mix()
        }

        // ----------------------------------------------------------------------------
        // Adjust the DAC bias parameter of the filter.
        // This gives user variable control of the exact CF -> center frequency
        // mapping used by the filter.
        // ----------------------------------------------------------------------------
        mutating func adjust_filter_bias(_ dac_bias: Double) {
            Vw_bias = sid_int(dac_bias * SIDModelTables.vo_N16(0))
            set_w0()

            // Gate voltage is controlled by the switched capacitor voltage divider
            // Ua = Ue * v = 4.75v  1<v<2
            nVgt = SIDModelTables.nVgt8580(dac_bias: dac_bias)
        }

        // ----------------------------------------------------------------------------
        // Mask for voices routed into the filter / audio output stage.
        // Used to physically connect/disconnect EXT IN, and for test purposes
        // (voice muting).
        // ----------------------------------------------------------------------------
        mutating func set_voice_mask(_ mask: UInt32) {
            voice_mask = 0xF0 | (mask & 0x0F)
            set_sum_mix()
        }

        // ----------------------------------------------------------------------------
        // SID reset.
        // ----------------------------------------------------------------------------
        mutating func reset() {
            fc = 0
            res = 0
            resonance_res = resonance
            filt = 0
            mode = 0
            vol = 0
            gain_vol = gain

            Vhp = 0
            Vbp = 0; Vbp_x = 0; Vbp_vc = 0
            Vlp = 0; Vlp_x = 0; Vlp_vc = 0

            set_w0()
            set_sum_mix()
        }

        // ----------------------------------------------------------------------------
        // Register functions.
        // ----------------------------------------------------------------------------
        mutating func writeFC_LO(_ fc_lo: UInt32) {
            fc = (fc & 0x7F8) | (fc_lo & 0x007)
            set_w0()
        }

        mutating func writeFC_HI(_ fc_hi: UInt32) {
            fc = ((fc_hi << 3) & 0x7F8) | (fc & 0x007)
            set_w0()
        }

        mutating func writeRES_FILT(_ res_filt: UInt32) {
            res = (res_filt >> 4) & 0x0F
            resonance_res = resonance + (Int(res) << 16)

            filt = res_filt & 0x0F
            set_sum_mix()
        }

        mutating func writeMODE_VOL(_ mode_vol: UInt32) {
            mode = mode_vol & 0xF0
            set_sum_mix()

            vol = mode_vol & 0x0F
            gain_vol = gain + (Int(vol) << 16)
        }

        // Set filter cutoff frequency.
        // (reSID computes both models' terms from both models' tables on every call; only the
        // chip's own model is read by its integrators, so only that one is computed here.)
        mutating func set_w0() {
            if is6581 {
                // MOS 6581
                let Vw = Vw_bias &+ Int32(f0_dac[Int(fc)])
                Vddt_Vw_2 = Int32(bitPattern: (UInt32(bitPattern: kVddt &- Vw) &* UInt32(bitPattern: kVddt &- Vw)) >> 1)
            } else {
                // MOS 8580 cutoff: 0 - 12.5kHz.
                n_dac = (n_param &* Int32(f0_dac[Int(fc)])) >> 11
            }
        }

        // Set input routing bits.
        mutating func set_sum_mix() {
            // NB! voice3off (mode bit 7) only affects voice 3 if it is routed directly
            // to the mixer.
            sum = (enabled ? filt : 0x00) & voice_mask
            mix =
                (enabled ? (mode & 0x70) | ((~(filt | ((mode & 0x80) >> 5))) & 0x0F) : 0x0F)
                    & voice_mask

            // The summer switch in Filter::clock(): Vi is the sum of the selected inputs,
            // offset = summer_offset<number of inputs>::value.
            @inline(__always) func mask(_ bits: UInt32, _ bit: UInt32) -> Int32 { (bits & bit) != 0 ? -1 : 0 }
            sum_v1 = mask(sum, 0x1)
            sum_v2 = mask(sum, 0x2)
            sum_v3 = mask(sum, 0x4)
            sum_offset_ve = sid_summer_offset((sum & 0xF).nonzeroBitCount) &+ (ve & mask(sum, 0x8))

            // The mixer switch in Filter::output(): the selected voices are added as they are,
            // the selected filter outputs are added together and scaled by filterGain first,
            // offset = mixer_offset<number of inputs>::value.
            mix_v1 = mask(mix, 0x01)
            mix_v2 = mask(mix, 0x02)
            mix_v3 = mask(mix, 0x04)
            mix_Vlp = mask(mix, 0x10)
            mix_Vbp = mask(mix, 0x20)
            mix_Vhp = mask(mix, 0x40)
            mix_filt = (mix & 0x70) != 0
            mix_offset_ve = sid_mixer_offset((mix & 0x7F).nonzeroBitCount) &+ (ve & mask(mix, 0x08))
        }

        // ----------------------------------------------------------------------------
        // SID clocking - 1 cycle.
        // ----------------------------------------------------------------------------
        @inline(__always)
        mutating func clock(_ voice1: Int32, _ voice2: Int32, _ voice3: Int32) {
            v1 = ((voice1 &* voice_scale_s14 &+ rnd.getNoise()) >> 18) &+ voice_DC
            v2 = ((voice2 &* voice_scale_s14 &+ rnd.getNoise()) >> 18) &+ voice_DC
            v3 = ((voice3 &* voice_scale_s14 &+ rnd.getNoise()) >> 18) &+ voice_DC

            // Sum inputs routed into the filter.
            let Vi = (v1 & sum_v1) &+ (v2 & sum_v2) &+ (v3 & sum_v3)
            let offset = sum_offset_ve

            // Calculate filter outputs.
            var lp_x = Vlp_x, lp_vc = Vlp_vc, bp_x = Vbp_x, bp_vc = Vbp_vc
            if is6581 {
                // MOS 6581.
                Vlp = solve_integrate_6581(1, Vbp, &lp_x, &lp_vc)
                Vbp = solve_integrate_6581(1, Vhp, &bp_x, &bp_vc)
            } else {
                // MOS 8580.
                Vlp = solve_integrate_8580(1, Vbp, &lp_x, &lp_vc)
                Vbp = solve_integrate_8580(1, Vhp, &bp_x, &bp_vc)
            }
            Vlp_x = lp_x; Vlp_vc = lp_vc; Vbp_x = bp_x; Vbp_vc = bp_vc

            // assert((Vbp >= 0) && (Vbp < (1 << 16)));
            let idx = offset &+ Int32(resonance_res[Int(Vbp)]) &+ Vlp &+ Vi
            // assert((idx >= 0) && (idx < summer_offset<5>::value));
            Vhp = Int32(summer[Int(idx)])
        }

        // ----------------------------------------------------------------------------
        // SID clocking - delta_t cycles.
        // ----------------------------------------------------------------------------
        @inline(__always)
        mutating func clock(_ delta_t: Int32, _ voice1: Int32, _ voice2: Int32, _ voice3: Int32) {
            var delta_t = delta_t

            v1 = ((voice1 &* voice_scale_s14 &+ rnd.getNoise()) >> 18) &+ voice_DC
            v2 = ((voice2 &* voice_scale_s14 &+ rnd.getNoise()) >> 18) &+ voice_DC
            v3 = ((voice3 &* voice_scale_s14 &+ rnd.getNoise()) >> 18) &+ voice_DC

            // Enable filter on/off.
            // This is not really part of SID, but is useful for testing.
            // On slow CPUs it may be necessary to bypass the filter to lower the CPU
            // load.
            if _slowPath(!enabled) {
                return
            }

            // Sum inputs routed into the filter.
            let Vi = (v1 & sum_v1) &+ (v2 & sum_v2) &+ (v3 & sum_v3)
            let offset = sum_offset_ve

            // Maximum delta cycles for filter fixpoint iteration to converge
            // is approximately 3.
            var delta_t_flt: Int32 = 3

            var lp_x = Vlp_x, lp_vc = Vlp_vc, bp_x = Vbp_x, bp_vc = Vbp_vc
            while delta_t != 0 {
                if _slowPath(delta_t < delta_t_flt) {
                    delta_t_flt = delta_t
                }

                // Calculate filter outputs.
                if is6581 {
                    // MOS 6581.
                    Vlp = solve_integrate_6581(delta_t_flt, Vbp, &lp_x, &lp_vc)
                    Vbp = solve_integrate_6581(delta_t_flt, Vhp, &bp_x, &bp_vc)
                } else {
                    // MOS 8580.
                    Vlp = solve_integrate_8580(delta_t_flt, Vbp, &lp_x, &lp_vc)
                    Vbp = solve_integrate_8580(delta_t_flt, Vhp, &bp_x, &bp_vc)
                }
                // assert((Vbp >= 0) && (Vbp < (1 << 16)));
                let idx = offset &+ Int32(resonance_res[Int(Vbp)]) &+ Vlp &+ Vi
                // assert((idx >= 0) && (idx < summer_offset<5>::value));
                Vhp = Int32(summer[Int(idx)])

                delta_t &-= delta_t_flt
            }
            Vlp_x = lp_x; Vlp_vc = lp_vc; Vbp_x = bp_x; Vbp_vc = bp_vc
        }

        // ----------------------------------------------------------------------------
        // SID audio input (16 bits).
        // ----------------------------------------------------------------------------
        mutating func input(_ sample: Int32) {
            // Scale to three times the peak-to-peak for one voice and add the op-amp
            // "zero" DC level.
            // NB! Adding the op-amp "zero" DC level is a (wildly inaccurate)
            // approximation of feeding the input through an AC coupling capacitor.
            // This could be implemented as a separate filter circuit, however the
            // primary use of the emulator is not to process external signals.
            // The upside is that the MOS8580 "digi boost" works without a separate (DC)
            // input interface.
            // Note that the input is 16 bits, compared to the 20 bit voice output.
            ve = ((sample &* voice_scale_s14 &* 3) >> 14) &+ Int32(mixer[0])
            set_sum_mix()
        }

        // ----------------------------------------------------------------------------
        // SID audio output (16 bits).
        // ----------------------------------------------------------------------------
        @inline(__always)
        func output() -> Int32 {
            // Sum inputs routed into the mixer.
            var Vi = (v1 & mix_v1) &+ (v2 & mix_v2) &+ (v3 & mix_v3)
            if mix_filt {
                let Vf = (Vlp & mix_Vlp) &+ (Vbp & mix_Vbp) &+ (Vhp & mix_Vhp)
                Vi = (((Vf &* filterGain) &+ dc_offset) >> 12) &+ Vi
            }

            // Sum the inputs in the mixer and run the mixer output through the gain.
            let idx1 = mix_offset_ve &+ Vi
            // assert((idx1 >= 0) && (idx1 < mixer_offset<8>::value));
            let idx2 = Int(mixer[Self.clamp(idx1, SIDModelTables.mixer_size)])
            // assert((idx2 >= 0) && (idx2 < (1 << 16)));
            return Int32(gain_vol[idx2]) - (1 << 15)
        }

        @inline(__always)
        static func clamp(_ index: Int32, _ size: Int) -> Int {
            let i = Int(index)
            return i < 0 ? 0 : (i >= size ? size - 1 : i)
        }

        /*
         Find output voltage in inverting integrator SID op-amp circuits, using a
         single fixpoint iteration step.

         A circuit diagram of a MOS 6581 integrator is shown below.

                          ---C---
                         |       |
           vi -----Rw-------[A>----- vo
                |      | vx
                 --Rs--

         From Kirchoff's current law it follows that

           IRw + IRs + ICr = 0

         Using the formula for current through a capacitor, i = C*dv/dt, we get

           IRw + IRs + C*(vc - vc0)/dt = 0
           dt/C*(IRw + IRs) + vc - vc0 = 0
           vc = vc0 - n*(IRw(vi,vx) + IRs(vi,vx))

         which may be rewritten as the following iterative fixpoint function:

           vc = vc0 - n*(IRw(vi,g(vc)) + IRs(vi,g(vc)))

         See filter8580new.h in reSID for the transistor models (the "snake" in triode mode and the
         voltage controlled resistor with the EKV model) behind the two current terms.
         */
        @inline(__always)
        func solve_integrate_6581(_ dt: Int32, _ vi: Int32, _ vx: inout Int32, _ vc: inout Int32) -> Int32 {
            // Note that all variables are translated and scaled in order to fit
            // in 16 bits. It is not necessary to explicitly translate the variables here,
            // since they are all used in subtractions which cancel out the translation:
            // (a - t) - (b - t) = a - b

            // "Snake" voltages for triode mode calculation.
            let Vgst = UInt32(bitPattern: kVddt &- vx)
            let Vgdt = UInt32(bitPattern: kVddt &- vi)
            let Vgdt_2 = Vgdt &* Vgdt

            // "Snake" current, scaled by (1/m)*2^13*m*2^16*m*2^16*2^-15 = m*2^30
            let n_I_snake = n_snake &* (Int32(bitPattern: (Vgst &* Vgst) &- Vgdt_2) >> 15)

            // VCR gate voltage.       // Scaled by m*2^16
            // Vg = Vddt - sqrt(((Vddt - Vw)^2 + Vgdt^2)/2)
            let kVg = Int32(vcr_kVg[Int((UInt32(bitPattern: Vddt_Vw_2) &+ (Vgdt_2 >> 1)) >> 16)])

            // VCR voltages for EKV model table lookup.
            // int Vgs = kVg - vx + (1 << 15); int Vgd = kVg - vi + (1 << 15);
            // (the 1 << 15 is in vcr_n_Ids_term_mid)
            let Vgs = kVg &- vx
            let Vgd = kVg &- vi

            // VCR current, scaled by m*2^15*2^15 = m*2^30
            let n_I_vcr = (Int32(vcr_n_Ids_term_mid[Int(Vgs)]) &- Int32(vcr_n_Ids_term_mid[Int(Vgd)])) << 15

            // Change in capacitor charge.
            vc = vc &- ((n_I_snake &+ n_I_vcr) &* dt)

            // vx = g(vc)
            // const int idx = (vc >> 15) + (1 << 15);  (the 1 << 15 is in opamp_rev_mid)
            // assert((idx >= 0) && (idx < (1 << 16)));
            vx = Int32(opamp_rev_mid[Int(vc >> 15)])

            // Return vo.
            return vx &+ (vc >> 14)
        }

        /*
         The 8580 integrator is similar to those found in 6581
         but the resistance is formed by multiple NMOS transistors
         in parallel controlled by the fc bits where the gate voltage
         is driven by a temperature dependent voltage divider.

                          ---C---
                         |       |
           vi -----Rfc------[A>----- vo
                         vx

           IRfc + ICr = 0
           IRfc + C*(vc - vc0)/dt = 0
           dt/C*(IRfc) + vc - vc0 = 0
           vc = vc0 - n*(IRfc(vi,vx))
           vc = vc0 - n*(IRfc(vi,g(vc)))

         IRfc = K/2*W/L*(Vgst^2 - Vgdt^2) = n*((Vgt - vx)^2 - (Vgt - vi)^2)
         */
        @inline(__always)
        func solve_integrate_8580(_ dt: Int32, _ vi: Int32, _ vx: inout Int32, _ vc: inout Int32) -> Int32 {
            // Note that all variables are translated and scaled in order to fit
            // in 16 bits. It is not necessary to explicitly translate the variables here,
            // since they are all used in subtractions which cancel out the translation:
            // (a - t) - (b - t) = a - b

            // Dac voltages.
            let Vgst = UInt32(bitPattern: nVgt &- vx)
            let Vgdt: UInt32 = vi < nVgt ? UInt32(bitPattern: nVgt &- vi) : 0 // triode/saturation mode

            // Dac current, scaled by (1/m)*2^13*m*2^16*m*2^16*2^-15 = m*2^30
            let n_I_rfc = (n_dac &* (Int32(bitPattern: (Vgst &* Vgst) &- (Vgdt &* Vgdt)) >> 15)) >> 4

            // Change in capacitor charge.
            vc = vc &- (n_I_rfc &* dt)

            // vx = g(vc)
            // const int idx = (vc >> 15) + (1 << 15);  (the 1 << 15 is in opamp_rev_mid)
            // assert((idx >= 0) && (idx < (1 << 16)));
            vx = Int32(opamp_rev_mid[Int(vc >> 15)])

            // Return vo.
            return vx &+ (vc >> 14)
        }
    }
}
