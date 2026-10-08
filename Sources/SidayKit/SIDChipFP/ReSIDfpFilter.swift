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
// Filter.h/.cpp, Filter6581.h/.cpp, Filter8580.h/.cpp, Integrator.h, Integrator6581.h/.cpp and
// Integrator8580.h/.cpp.
//
// In reSIDfp Filter is a base class with two virtual functions (updateCenterFrequency and
// solveIntegrators) and Filter6581 / Filter8580 derive from it; a SID owns one of each and sends
// every register write to both. A chip's model is fixed here, so there is one Filter: the base
// class's members, plus the members of the one derived class that is in use (`filter6581` or
// `filter8580`; the other is an empty placeholder). The two virtuals are a test of `is6581` where
// they are called from register writes; the per-cycle code (ReSIDfpChip.clock) calls
// solveIntegrators6581 / solveIntegrators8580 directly.
//
// Filter also holds what reSIDfp keeps in the shared FilterModelConfig but which is per-chip state
// here: the dither index, uCox and currFactorCoeff (see ReSIDfpFilterModelConfig.swift). And for the
// 6581 it holds `vcr_n_Ids_term`, FilterModelConfig6581::getVcr_n_Ids_term() tabulated for the
// chip's uCox; reSIDfp does that multiplication and conversion four times per cycle.
//
// The integrators are the critical part for speed. When a signal goes through the filter each cycle is
// one chain of dependent steps (the summer's lookup, then for each integrator a multiplication and three
// table lookups, the second integrator starting from the first one's result) which the next cycle
// cannot begin before the end of: about a hundred processor cycles on an Apple M2, whatever else the
// loop does. The arithmetic below is ordered so that as little as possible sits on that chain.

extension ReSIDfpChip {
    // MARK: - Integrator6581.h / Integrator6581.cpp

    /**
     * Find output voltage in inverting integrator SID op-amp circuits, using a
     * single fixpoint iteration step.
     *
     * A circuit diagram of a MOS 6581 integrator is shown below.
     *
     *                   +---C---+
     *                   |       |
     *     vi --o--Rw--o-o--[A>--o-- vo
     *          |      | vx
     *          +--Rs--+
     *
     * From Kirchoff's current law it follows that
     *
     *     IRw + IRs + ICr = 0
     *
     * Using the formula for current through a capacitor, i = C*dv/dt, we get
     *
     *     IRw + IRs + C*(vc - vc0)/dt = 0
     *     dt/C*(IRw + IRs) + vc - vc0 = 0
     *     vc = vc0 - n*(IRw(vi,vx) + IRs(vi,vx))
     *
     * which may be rewritten as the following iterative fixpoint function:
     *
     *     vc = vc0 - n*(IRw(vi,g(vc)) + IRs(vi,g(vc)))
     *
     * To accurately calculate the currents through Rs and Rw, we need to use
     * transistor models. Rs has a gate voltage of Vdd = 12V, and can be
     * assumed to always be in triode mode. For Rw, the situation is rather
     * more complex, as it turns out that this transistor will operate in
     * both subthreshold, triode, and saturation modes.
     *
     * The Shichman-Hodges transistor model routinely used in textbooks may
     * be written as follows:
     *
     *     Ids = 0                          , Vgst < 0               (subthreshold mode)
     *     Ids = K*W/L*(2*Vgst - Vds)*Vds   , Vgst >= 0, Vds < Vgst  (triode mode)
     *     Ids = K*W/L*Vgst^2               , Vgst >= 0, Vds >= Vgst (saturation mode)
     *
     * where
     *     K   = u*Cox/2 (transconductance coefficient)
     *     W/L = ratio between substrate width and length
     *     Vgst = Vg - Vs - Vt (overdrive voltage)
     *
     * This transistor model is also called the quadratic model.
     *
     * Note that the equation for the triode mode can be reformulated as
     * independent terms depending on Vgs and Vgd, respectively, by the
     * following substitution:
     *
     *     Vds = Vgst - (Vgst - Vds) = Vgst - Vgdt
     *
     *     Ids = K*W/L*(2*Vgst - Vds)*Vds
     *         = K*W/L*(2*Vgst - (Vgst - Vgdt)*(Vgst - Vgdt)
     *         = K*W/L*(Vgst + Vgdt)*(Vgst - Vgdt)
     *         = K*W/L*(Vgst^2 - Vgdt^2)
     *
     * This turns out to be a general equation which covers both the triode
     * and saturation modes (where the second term is 0 in saturation mode).
     * The equation is also symmetrical, i.e. it can calculate negative
     * currents without any change of parameters (since the terms for drain
     * and source are identical except for the sign).
     *
     * FIXME: Subthreshold as function of Vgs, Vgd.
     *
     *     Ids = I0*W/L*e^(Vgst/(Ut/k))   , Vgst < 0               (subthreshold mode)
     *
     * where
     *     I0 = (2 * uCox * Ut^2) / k
     *
     * The remaining problem with the textbook model is that the transition
     * from subthreshold to triode/saturation is not continuous.
     *
     * Realizing that the subthreshold and triode/saturation modes may both
     * be defined by independent (and equal) terms of Vgs and Vds,
     * respectively, the corresponding terms can be blended into (equal)
     * continuous functions suitable for table lookup.
     *
     * The EKV model (Enz, Krummenacher and Vittoz) essentially performs this
     * blending using an elegant mathematical formulation:
     *
     *     Ids = Is * (if - ir)
     *     Is = ((2 * u*Cox * Ut^2)/k) * W/L
     *     if = ln^2(1 + e^((k*(Vg - Vt) - Vs)/(2*Ut))
     *     ir = ln^2(1 + e^((k*(Vg - Vt) - Vd)/(2*Ut))
     *
     * For our purposes, the EKV model preserves two important properties
     * discussed above:
     *
     * - It consists of two independent terms, which can be represented by
     *   the same lookup table.
     * - It is symmetrical, i.e. it calculates current in both directions,
     *   facilitating a branch-free implementation.
     *
     * Rw in the circuit diagram above is a VCR (voltage controlled resistor),
     * as shown in the circuit diagram below.
     *
     *
     *                        Vdd
     *                           |
     *              Vdd         _|_
     *                 |    +---+ +---- Vw
     *                _|_   |
     *             +--+ +---o Vg
     *             |      __|__
     *             |      -----  Rw
     *             |      |   |
     *     vi -----o------+   +-------- vo
     *
     *
     * In order to calculalate the current through the VCR, its gate voltage
     * must be determined.
     *
     * Assuming triode mode and applying Kirchoff's current law, we get the
     * following equation for Vg:
     *
     *     u*Cox/2*W/L*((nVddt - Vg)^2 - (nVddt - vi)^2 + (nVddt - Vg)^2 - (nVddt - Vw)^2) = 0
     *     2*(nVddt - Vg)^2 - (nVddt - vi)^2 - (nVddt - Vw)^2 = 0
     *     (nVddt - Vg) = sqrt(((nVddt - vi)^2 + (nVddt - Vw)^2)/2)
     *
     *     Vg = nVddt - sqrt(((nVddt - vi)^2 + (nVddt - Vw)^2)/2)
     */
    struct Integrator6581 {
        // Integrator
        var vx: Int32 = 0
        var vc: Int32 = 0

        let wlSnake: Double

        var nVddt_Vw_2: UInt32 = 0

        // unsigned short in reSIDfp
        let nVddt: Int32
        let nVt: Int32
        let nVmin: Int32

        init(_ fmc: FilterModelConfig6581, _ rnd: inout Int32) {
            wlSnake = fmc.WL_snake
            nVddt = Int32(fmc.getNormalizedValue(fmc.Vddt, &rnd))
            nVt = Int32(fmc.getNormalizedValue(fmc.Vth, &rnd))
            nVmin = Int32(fmc.getNVmin())
        }

        /// The integrator of a chip that is not a 6581.
        init() {
            wlSnake = 0
            nVddt = 0
            nVt = 0
            nVmin = 0
        }

        mutating func setVw(_ Vw: UInt16) {
            let d = nVddt &- Int32(Vw)
            nVddt_Vw_2 = UInt32(bitPattern: (d &* d) >> 1)
        }

        /// - Parameters:
        ///   - vi: input
        ///   - n_snake: `fmc.getNormalizedCurrentFactor<13>(wlSnake)`
        ///   - vcr_nVg: `fmc.getVcr_nVg()`'s table
        ///   - vcr_n_Ids_term: `fmc.getVcr_n_Ids_term()` as a table (Filter6581.vcr_n_Ids_term)
        ///   - opamp_rev: `fmc.getOpampRev()`'s table
        @inline(__always)
        mutating func solve(_ vi: Int32, _ n_snake: Int32, _ vcr_nVg: UnsafePointer<UInt16>,
                            _ vcr_n_Ids_term: UnsafePointer<UInt16>, _ opamp_rev: UnsafePointer<UInt16>) -> Int32
        {
            Integrator6581.solve(vi, &vx, &vc, nVddt_Vw_2, nVddt, nVt &+ nVmin, n_snake, vcr_nVg, vcr_n_Ids_term, opamp_rev)
        }

        /// solve() with the integrator's members as arguments, so that a loop can keep vx and vc in local variables.
        ///
        /// - Parameter nVt_nVmin: `nVt + nVmin`
        @inline(__always)
        static func solve(_ vi: Int32, _ vx: inout Int32, _ vc: inout Int32, _ nVddt_Vw_2: UInt32, _ nVddt: Int32, _ nVt_nVmin: Int32,
                          _ n_snake: Int32, _ vcr_nVg: UnsafePointer<UInt16>, _ vcr_n_Ids_term: UnsafePointer<UInt16>,
                          _ opamp_rev: UnsafePointer<UInt16>) -> Int32
        {
            // Make sure Vgst>0 so we're not in subthreshold mode
            // assert(vx < nVddt);

            // Check that transistor is actually in triode mode
            // Vds < Vgs - Vth
            // assert(vi < nVddt);

            // "Snake" voltages for triode mode calculation.
            let Vgst = UInt32(bitPattern: nVddt &- vx)
            let Vgdt = UInt32(bitPattern: nVddt &- vi)

            let Vgst_2 = Vgst &* Vgst
            let Vgdt_2 = Vgdt &* Vgdt

            // "Snake" current, scaled by (1/m)*2^13*m*2^16*m*2^16*2^-15 = m*2^30
            let n_I_snake = n_snake &* (Int32(bitPattern: Vgst_2 &- Vgdt_2) >> 15)

            // VCR gate voltage.       // Scaled by m*2^16
            // Vg = Vddt - sqrt(((Vddt - Vw)^2 + Vgdt^2)/2)
            let nVg = Int32(vcr_nVg[Int((nVddt_Vw_2 &+ (Vgdt_2 >> 1)) >> 16)])

            // VCR voltages for EKV model table lookup.
            //   const int kVgt = (nVg - nVt) - nVmin;
            //   const int kVgt_Vs = (kVgt - vx) - INT16_MIN;
            //   const int kVgt_Vd = (kVgt - vi) - INT16_MIN;
            // with the terms that do not wait for the table lookup taken first. reSIDfp asserts that both are
            // within 0 ... 65535 and reads outside its table if they are not; here only their low 16 bits are used.
            let kVgt_Vs = nVg &+ ((32768 &- nVt_nVmin) &- vx)
            let kVgt_Vd = nVg &+ ((32768 &- nVt_nVmin) &- vi)

            // VCR current, scaled by m*2^15*2^15 = m*2^30
            // (If - Ir with each shifted left 15 bits is the difference shifted left 15 bits.)
            let If = UInt32(vcr_n_Ids_term[Int(kVgt_Vs & 0xFFFF)])
            let Ir = UInt32(vcr_n_Ids_term[Int(kVgt_Vd & 0xFFFF)])
            let n_I_vcr = Int32(bitPattern: (If &- Ir) << 15)

            // Change in capacitor charge.
            vc = vc &+ (n_I_snake &+ n_I_vcr)

            // vx = g(vc)
            let tmp = (vc >> 15) &+ 32768
            // assert(tmp <= UINT16_MAX);
            vx = Int32(opamp_rev[Int(tmp)])

            // Return vo.
            return vx &- (vc >> 14)
        }
    }

    // MARK: - Integrator8580.h / Integrator8580.cpp

    /**
     * 8580 integrator
     *
     *                   +---C---+
     *                   |       |
     *     vi -----Rfc---o--[A>--o-- vo
     *                   vx
     *
     *     IRfc + ICr = 0
     *     IRfc + C*(vc - vc0)/dt = 0
     *     dt/C*(IRfc) + vc - vc0 = 0
     *     vc = vc0 - n*(IRfc(vi,vx))
     *     vc = vc0 - n*(IRfc(vi,g(vc)))
     *
     * IRfc = K*W/L*(Vgst^2 - Vgdt^2) = n*((Vddt - vx)^2 - (Vddt - vi)^2)
     *
     * Rfc gate voltage is generated by an OP Amp and depends on chip temperature.
     */
    struct Integrator8580 {
        // Integrator
        var vx: Int32 = 0
        var vc: Int32 = 0

        // unsigned short in reSIDfp
        var nVgt: Int32 = 0
        var n_dac: Int32 = 0

        init(_ fmc: FilterModelConfig8580, _ rnd: inout Int32) {
            setV(1.5, fmc, &rnd)
        }

        /// The integrator of a chip that is not an 8580.
        init() {}

        /// Set Filter Cutoff resistor ratio.
        ///
        /// - Parameter currFactorCoeff: the filter's current factor coefficient
        mutating func setFc(_ wl: Double, _ currFactorCoeff: Double) {
            // Normalized current factor, 1 cycle at 1MHz.
            // fmc.getNormalizedCurrentFactor<17>(wl)
            n_dac = Int32(FilterModelConfig.to_ushort(Double(1 << 17) * currFactorCoeff * wl))
        }

        /// Set FC gate voltage multiplier.
        mutating func setV(_ v: Double, _ fmc: FilterModelConfig8580, _ rnd: inout Int32) {
            // Gate voltage is controlled by the switched capacitor voltage divider
            // Ua = Ue * v = 4.75v  1<v<2
            // assert(v > 1.0 && v < 2.0);
            let Vg = FilterModelConfig8580.getVref() * v
            let Vgt = Vg - fmc.Vth

            // Vg - Vth, normalized so that translated values can be subtracted:
            // Vgt - x = (Vgt - t) - (x - t)
            nVgt = Int32(fmc.getNormalizedValue(Vgt, &rnd))
        }

        @inline(__always)
        mutating func solve(_ vi: Int32, _ opamp_rev: UnsafePointer<UInt16>) -> Int32 {
            Integrator8580.solve(vi, &vx, &vc, nVgt, n_dac, opamp_rev)
        }

        /// solve() with the integrator's members as arguments, so that a loop can keep vx and vc in local variables.
        @inline(__always)
        static func solve(_ vi: Int32, _ vx: inout Int32, _ vc: inout Int32, _ nVgt: Int32, _ n_dac: Int32, _ opamp_rev: UnsafePointer<UInt16>) -> Int32 {
            // Make sure we're not in subthreshold mode
            // assert(vx < nVgt);

            // DAC voltages
            let Vgst = UInt32(bitPattern: nVgt &- vx)
            let Vgdt: UInt32 = (vi < nVgt) ? UInt32(bitPattern: nVgt &- vi) : 0 // triode/saturation mode

            let Vgst_2 = Vgst &* Vgst
            let Vgdt_2 = Vgdt &* Vgdt

            // DAC current, scaled by (1/m)*2^13*m*2^16*m*2^16*2^-15 = m*2^30
            let n_I_dac = (n_dac &* (Int32(bitPattern: Vgst_2 &- Vgdt_2) >> 15)) >> 4

            // Change in capacitor charge.
            vc = vc &+ n_I_dac

            // vx = g(vc)
            let tmp = (vc >> 15) &+ 32768
            // assert(tmp <= UINT16_MAX);
            vx = Int32(opamp_rev[Int(tmp)])

            // Return vo.
            return vx &- (vc >> 14)
        }
    }

    // MARK: - Filter6581.h / Filter6581.cpp

    /// The members Filter6581 adds to Filter. See Filter6581.h in reSIDfp for the description of the
    /// 6581 filter circuit, its DAC, its voltage controlled resistors and its op-amps.
    struct Filter6581: ~Copyable {
        /// VCR + associated capacitor connected to highpass output.
        var hpIntegrator: Integrator6581

        /// VCR + associated capacitor connected to bandpass output.
        var bpIntegrator: Integrator6581

        /// The cutoff frequency DAC output voltage table (1 << 11), owned by the chip.
        let f0_dac: UnsafeMutablePointer<UInt16>

        /// FilterModelConfig6581::vcr_nVg.
        let vcr_nVg: UnsafePointer<UInt16>

        /// `to_ushort(fmc.vcr_n_Ids_term[i] * uCox)` (1 << 16), owned by the chip.
        let vcr_n_Ids_term: UnsafeMutablePointer<UInt16>

        /// `fmc.getNormalizedCurrentFactor<13>(wlSnake)`
        var n_snake: Int32 = 0

        // The shared configuration lives for the whole process; unowned(unsafe) keeps reference counting
        // out of the chip's copies.
        unowned(unsafe) let fmc: FilterModelConfig6581?

        init(_ fmc: FilterModelConfig6581, _ rnd: inout Int32) {
            self.fmc = fmc
            hpIntegrator = Integrator6581(fmc, &rnd)
            bpIntegrator = Integrator6581(fmc, &rnd)
            f0_dac = .allocate(capacity: 1 << FilterModelConfig6581.DAC_BITS)
            fmc.getDAC(0.5, into: f0_dac, &rnd)
            vcr_nVg = UnsafePointer(fmc.vcr_nVg)
            vcr_n_Ids_term = .allocate(capacity: 1 << 16)
        }

        /// The placeholder in a chip that is not a 6581.
        init() {
            fmc = nil
            hpIntegrator = Integrator6581()
            bpIntegrator = Integrator6581()
            f0_dac = .allocate(capacity: 1)
            f0_dac.initialize(to: 0)
            vcr_n_Ids_term = .allocate(capacity: 1)
            vcr_n_Ids_term.initialize(to: 0)
            vcr_nVg = UnsafePointer(vcr_n_Ids_term)
        }

        deinit {
            f0_dac.deallocate()
            vcr_n_Ids_term.deallocate()
        }

        var bytes: Int { fmc == nil ? 4 : (1 << FilterModelConfig6581.DAC_BITS) * 2 + (1 << 16) * 2 }

        /// What depends on uCox: FilterModelConfig::setUCox() as far as the 6581's integrators see it.
        mutating func setUCox(_ uCox: Double, _ currFactorCoeff: Double) {
            guard let fmc else { return }
            fmc.fillVcr_n_Ids_term(vcr_n_Ids_term, uCox: uCox)
            n_snake = Int32(FilterModelConfig.to_ushort(Double(1 << 13) * currFactorCoeff * hpIntegrator.wlSnake))
        }
    }

    // MARK: - Filter8580.h / Filter8580.cpp

    /// The members Filter8580 adds to Filter. See Filter8580.h in reSIDfp for the description of the
    /// 8580 filter circuit.
    struct Filter8580 {
        /**
         * W/L ratio of frequency DAC bit 0,
         * other bit are proportional.
         * When no bit are selected a resistance with half
         * W/L ratio is selected.
         */
        static var DAC_WL0: Double { 0.00615 }

        /// VCR + associated capacitor connected to highpass output.
        var hpIntegrator: Integrator8580

        /// VCR + associated capacitor connected to bandpass output.
        var bpIntegrator: Integrator8580

        var cp = 0.0

        unowned(unsafe) let fmc: FilterModelConfig8580?

        init(_ fmc: FilterModelConfig8580, _ rnd: inout Int32) {
            self.fmc = fmc
            hpIntegrator = Integrator8580(fmc, &rnd)
            bpIntegrator = Integrator8580(fmc, &rnd)
            setFilterCurve(0.5, &rnd)
        }

        /// The placeholder in a chip that is not an 8580.
        init() {
            fmc = nil
            hpIntegrator = Integrator8580()
            bpIntegrator = Integrator8580()
        }

        /// Set filter curve type based on single parameter.
        ///
        /// - Parameter curvePosition: 0 .. 1, where 0 sets center frequency high ("light") and 1 sets it low ("dark"), default is 0.5
        mutating func setFilterCurve(_ curvePosition: Double, _ rnd: inout Int32) {
            guard let fmc else { return }
            // Adjust cp
            // 1.2 <= cp <= 1.8
            cp = 1.8 - curvePosition * 3.0 / 5.0

            hpIntegrator.setV(cp, fmc, &rnd)
            bpIntegrator.setV(cp, fmc, &rnd)
        }
    }

    // MARK: - Filter.h / Filter.cpp

    /// SID filter base class
    struct Filter: ~Copyable {
        static func summerIdx(_ i: Int) -> Int { FilterModelConfig.summer_offset(i) }
        static func mixerIdx(_ i: Int) -> Int { FilterModelConfig.mixer_offset(i) }

        let is6581: Bool

        // FilterModelConfig& fmc: the tables, and the values getNormalizedVoice() needs.
        let mixer: UnsafePointer<UInt16>
        let summer: UnsafePointer<UInt16>
        let resonance: UnsafePointer<UInt16>
        let volume: UnsafePointer<UInt16>
        let opamp_rev: UnsafePointer<UInt16>
        let voiceDC: UnsafePointer<Double>
        let rnd_buffer: UnsafePointer<Double>
        let N16: Double
        let vmin: Double
        let voice_voltage_range: Double

        /// FilterModelConfig::Randomnoise::index
        var rnd_index: Int32
        /// FilterModelConfig::uCox
        var uCox: Double
        /// FilterModelConfig::currFactorCoeff
        var currFactorCoeff: Double

        /// Current filter/voice mixer setting.
        var currentMixer: UnsafePointer<UInt16>

        /// Filter input summer setting.
        var currentSummer: UnsafePointer<UInt16>

        /// Filter resonance value.
        var currentResonance: UnsafePointer<UInt16>

        /// Current volume amplifier setting.
        var currentVolume: UnsafePointer<UInt16>

        /// Filter highpass state.
        var Vhp: Int32 = 0

        /// Filter bandpass state.
        var Vbp: Int32 = 0

        /// Filter lowpass state.
        var Vlp: Int32 = 0

        /// Filter external input.
        var Ve: Int32 = 0

        /// Filter cutoff frequency.
        var fc: UInt32 = 0

        /// Routing to filter or outside filter
        var filt1 = false
        var filt2 = false
        var filt3 = false
        var filtE = false

        /// Switch voice 3 off.
        var voice3off = false

        /// Highpass, bandpass, and lowpass filter modes.
        var hp = false
        var bp = false
        var lp = false

        /// Current volume.
        var vol: UInt8 = 0

        /// Filter enabled.
        var enabled = true

        /// Selects which inputs to route through filter.
        var filt: UInt8 = 0

        /// Filter6581's members (a placeholder on an 8580).
        var filter6581: Filter6581

        /// Filter8580's members (a placeholder on a 6581).
        var filter8580: Filter8580

        /// `Filter6581()` or `Filter8580()`: the base class constructor, then the derived class's members.
        init(model: SIDModel) {
            is6581 = model == .mos6581
            rnd_buffer = FilterModelConfig.Randomnoise.buffer
            let fmc: FilterModelConfig
            let fmc6581 = is6581 ? FilterModelConfig6581.instance : nil
            let fmc8580 = is6581 ? nil : FilterModelConfig8580.instance
            if let fmc6581 {
                fmc = fmc6581
                voiceDC = UnsafePointer(fmc6581.voiceDC)
            } else {
                fmc = fmc8580!
                voiceDC = UnsafePointer(fmc8580!.voiceDC)
            }
            mixer = UnsafePointer(fmc.mixer)
            summer = UnsafePointer(fmc.summer)
            resonance = UnsafePointer(fmc.resonance)
            volume = UnsafePointer(fmc.volume)
            opamp_rev = UnsafePointer(fmc.opamp_rev)
            N16 = fmc.N16
            vmin = fmc.vmin
            voice_voltage_range = fmc.voice_voltage_range
            rnd_index = fmc.rnd_index
            uCox = fmc.uCox
            currFactorCoeff = fmc.currFactorCoeff(fmc.uCox)
            currentMixer = mixer
            currentSummer = summer
            currentResonance = resonance
            currentVolume = volume
            filter6581 = Filter6581()
            filter8580 = Filter8580()

            // Filter::Filter()
            input(0)

            // Filter6581::Filter6581() / Filter8580::Filter8580()
            if let fmc6581 {
                filter6581 = Filter6581(fmc6581, &rnd_index)
                filter6581.setUCox(uCox, currFactorCoeff)
            } else if let fmc8580 {
                filter8580 = Filter8580(fmc8580, &rnd_index)
            }
        }

        // MARK: FilterModelConfig helper functions

        @inline(__always)
        mutating func getNoise() -> Double {
            rnd_index = (rnd_index &+ 1) & 0x3FF
            return rnd_buffer[Int(rnd_index)]
        }

        @inline(__always)
        mutating func getNormalizedValue(_ value: Double) -> UInt16 {
            FilterModelConfig.to_ushort_dither(N16 * (value - vmin), getNoise())
        }

        @inline(__always)
        func getVoiceVoltage(_ value: Float, _ env: UInt32) -> Double {
            Double(value) * voice_voltage_range + voiceDC[Int(env)]
        }

        @inline(__always)
        mutating func getNormalizedVoice(_ value: Float, _ env: UInt32) -> Int32 {
            Int32(getNormalizedValue(getVoiceVoltage(value, env)))
        }

        // MARK: Filter

        /// Update filter cutoff frequency.
        mutating func updateCenterFrequency() {
            if is6581 {
                // Filter6581::updateCenterFrequency()
                let Vw = filter6581.f0_dac[Int(fc)]
                filter6581.hpIntegrator.setVw(Vw)
                filter6581.bpIntegrator.setVw(Vw)
            } else {
                // Filter8580::updateCenterFrequency()
                var wl: Double
                var dacWL = Filter8580.DAC_WL0
                if fc != 0 {
                    wl = 0.0
                    for i in 0 ..< 11 {
                        if (fc & (1 << UInt32(i))) != 0 {
                            wl += dacWL
                        }
                        dacWL *= 2.0
                    }
                } else {
                    wl = dacWL / 2.0
                }

                filter8580.hpIntegrator.setFc(wl, currFactorCoeff)
                filter8580.bpIntegrator.setFc(wl, currFactorCoeff)
            }
        }

        /// Update filter resonance.
        ///
        /// - Parameter res: the new resonance value
        mutating func updateResonance(_ res: UInt8) { currentResonance = resonance + (Int(res) * (1 << 16)) }

        /// Mixing configuration modified (offsets change)
        mutating func updateMixing() {
            currentVolume = volume + (Int(vol) * (1 << 16))

            var Nsum = 0
            var Nmix = 0

            if filt1 { Nsum += 1 } else { Nmix += 1 }
            if filt2 { Nsum += 1 } else { Nmix += 1 }

            if filt3 { Nsum += 1 }
            else if !voice3off { Nmix += 1 }

            if filtE { Nsum += 1 } else { Nmix += 1 }

            currentSummer = summer + Filter.summerIdx(Nsum)

            if lp { Nmix += 1 }
            if bp { Nmix += 1 }
            if hp { Nmix += 1 }

            currentMixer = mixer + Filter.mixerIdx(Nmix)
        }

        /// Write Frequency Cutoff Low register.
        ///
        /// - Parameter fc_lo: Frequency Cutoff Low-Byte
        mutating func writeFC_LO(_ fc_lo: UInt8) {
            fc = (fc & 0x7F8) | (UInt32(fc_lo) & 0x007)
            updateCenterFrequency()
        }

        /// Write Frequency Cutoff High register.
        ///
        /// - Parameter fc_hi: Frequency Cutoff High-Byte
        mutating func writeFC_HI(_ fc_hi: UInt8) {
            fc = (UInt32(fc_hi) << 3 & 0x7F8) | (fc & 0x007)
            updateCenterFrequency()
        }

        /// Write Resonance/Filter register.
        ///
        /// - Parameter res_filt: Resonance/Filter
        mutating func writeRES_FILT(_ res_filt: UInt8) {
            filt = res_filt

            updateResonance((res_filt >> 4) & 0x0F)

            if enabled {
                filt1 = (filt & 0x01) != 0
                filt2 = (filt & 0x02) != 0
                filt3 = (filt & 0x04) != 0
                filtE = (filt & 0x08) != 0
            }

            updateMixing()
        }

        /// Write filter Mode/Volume register.
        ///
        /// - Parameter mode_vol: Filter Mode/Volume
        mutating func writeMODE_VOL(_ mode_vol: UInt8) {
            vol = mode_vol & 0x0F
            lp = (mode_vol & 0x10) != 0
            bp = (mode_vol & 0x20) != 0
            hp = (mode_vol & 0x40) != 0

            voice3off = (mode_vol & 0x80) != 0

            updateMixing()
        }

        /// Enable filter.
        mutating func enable(_ enable: Bool) {
            enabled = enable

            if enabled {
                writeRES_FILT(filt)
            } else {
                filt1 = false
                filt2 = false
                filt3 = false
                filtE = false
            }
        }

        /// SID reset.
        mutating func reset() {
            writeFC_LO(0)
            writeFC_HI(0)
            writeMODE_VOL(0)
            writeRES_FILT(0)
        }

        /// Apply a signal to EXT-IN
        ///
        /// - Parameter input: a signed 16 bit sample
        mutating func input(_ input: Int16) { Ve = getNormalizedVoice(Float(input) / 32768.0, 0) }

        // MARK: Filter6581 / Filter8580 member functions that use the base class

        @inline(__always)
        mutating func solveIntegrators6581() -> Int32 {
            Vbp = filter6581.hpIntegrator.solve(Vhp, filter6581.n_snake, filter6581.vcr_nVg, UnsafePointer(filter6581.vcr_n_Ids_term), opamp_rev)
            Vlp = filter6581.bpIntegrator.solve(Vbp, filter6581.n_snake, filter6581.vcr_nVg, UnsafePointer(filter6581.vcr_n_Ids_term), opamp_rev)

            var Vfilt: Int32 = 0
            if lp { Vfilt &+= Vlp }
            if bp { Vfilt &+= Vbp }
            if hp { Vfilt &+= Vhp }

            return Filter.filterGain6581(Vfilt)
        }

        /// The end of Filter6581::solveIntegrators().
        @inline(__always)
        static func filterGain6581(_ Vfilt: Int32) -> Int32 {
            // The filter input resistors are slightly bigger than the voice ones
            // Scale the values accordingly
            let filterGain: Int32 = 3809 // static_cast<int>(0.93 * (1 << 12))

            // Scaling unsigned values adds a DC offset
            let offset: Int32 = 32767 &* ((1 << 12) &- filterGain)

            // assert(Vfilt >= 0);
            return (Vfilt &* filterGain &+ offset) >> 12
        }

        @inline(__always)
        mutating func solveIntegrators8580() -> Int32 {
            Vbp = filter8580.hpIntegrator.solve(Vhp, opamp_rev)
            Vlp = filter8580.bpIntegrator.solve(Vbp, opamp_rev)

            var Vfilt: Int32 = 0
            if lp { Vfilt &+= Vlp }
            if bp { Vfilt &+= Vbp }
            if hp { Vfilt &+= Vhp }

            return Vfilt
        }

        /// Set filter curve type based on single parameter (Filter6581::setFilterCurve).
        ///
        /// - Parameter curvePosition: 0 .. 1, where 0 sets center frequency high ("bright") and 1 sets it low ("dark").
        ///                            Default is 0.5
        mutating func setFilter6581Curve(_ curvePosition: Double) {
            guard let fmc = filter6581.fmc else { return }
            fmc.getDAC(curvePosition, into: filter6581.f0_dac, &rnd_index)
            updateCenterFrequency()
        }

        /// Set filter offset and range based on single parameter (Filter6581::setFilterRange).
        ///
        /// - Parameter adjustment: 0 .. 1, where 0 sets center frequency low ("dark"), 1 sets it high ("bright").
        ///                         This also affects the range. Default is 0.5
        mutating func setFilter6581Range(_ adjustment: Double) {
            guard let fmc = filter6581.fmc, let new_uCox = fmc.uCox(forRange: adjustment, current: uCox) else { return }
            // FilterModelConfig::setUCox()
            uCox = new_uCox
            currFactorCoeff = fmc.currFactorCoeff(new_uCox)
            filter6581.setUCox(uCox, currFactorCoeff)
        }

        /// Set filter curve type based on single parameter (Filter8580::setFilterCurve).
        mutating func setFilter8580Curve(_ curvePosition: Double) {
            filter8580.setFilterCurve(curvePosition, &rnd_index)
        }
    }
}
