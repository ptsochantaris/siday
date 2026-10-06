// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// This file is part of a Swift port of reSIDfp, a SID emulator engine.
// Copyright 2011-2025 Leandro Nini <drfiemost@users.sourceforge.net>
// Copyright 2007-2010 Antti Lankila
// Copyright 2004 Dag Lem <resid@nimrod.no>
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
// Voice.h, ExternalFilter.h / ExternalFilter.cpp and Potentiometer.h.

extension ReSIDfpChip {
    // MARK: - Voice.h

    /// Representation of SID voice block.
    struct Voice {
        var waveformGenerator: WaveformGenerator

        var envelopeGenerator = EnvelopeGenerator()

        /// The DAC LUT for analog waveform output
        let wavDAC: UnsafePointer<Float>

        /// The DAC LUT for analog envelope output
        let envDAC: UnsafePointer<Float>

        init(waveformGenerator: WaveformGenerator, wavDAC: UnsafePointer<Float>, envDAC: UnsafePointer<Float>) {
            self.waveformGenerator = waveformGenerator
            self.wavDAC = wavDAC
            self.envDAC = envDAC
        }

        /// Amplitude modulated waveform output.
        ///
        /// The waveform DAC generates a voltage between virtual ground and Vdd
        /// (5-12 V for the 6581 and 4.75-9 V for the 8580)
        /// corresponding to oscillator state 0 .. 4095.
        ///
        /// The envelope DAC generates a voltage between waveform gen output and
        /// the virtual ground level, corresponding to envelope state 0 .. 255.
        ///
        /// Ideal range [-2048*255, 2047*255].
        ///
        /// - Parameter prevAccumulator: the accumulator of the voice this one is modulated by
        /// - Returns: the voice analog output
        @inline(__always)
        mutating func output(_ prevAccumulator: UInt32) -> Float {
            let wav = waveformGenerator.output(prevAccumulator)
            let env = envelopeGenerator.output()

            // DAC imperfections are emulated by using the digital output
            // as an index into a DAC lookup table.
            return wavDAC[Int(wav)] * envDAC[Int(env)]
        }

        /// The number of coming cycles in which the waveform generator needs none of its special cases and the
        /// envelope does not change (WaveformGenerator.quietCycles, EnvelopeGenerator.steadyCycles).
        @inline(__always)
        func quietCycles(_ rateCounterPosition: UnsafePointer<UInt16>) -> Int32 {
            let wave = waveformGenerator.quietCycles()
            let envelope = envelopeGenerator.steadyCycles(rateCounterPosition)
            return wave < envelope ? wave : envelope
        }

        /// Write control register.
        ///
        /// - Parameter control: Control register value.
        mutating func writeCONTROL_REG(_ control: UInt8) {
            waveformGenerator.writeCONTROL_REG(control)
            envelopeGenerator.writeCONTROL_REG(control)
        }

        /// SID reset.
        mutating func reset() {
            waveformGenerator.reset()
            envelopeGenerator.reset()
        }
    }

    // MARK: - ExternalFilter.h / ExternalFilter.cpp

    /// The audio output stage in a Commodore 64 consists of two STC networks, a
    /// low-pass RC filter with 3 dB frequency 16kHz followed by a DC-blocker which
    /// acts as a high-pass filter with a cutoff dependent on the attached audio
    /// equipment impedance. Here we suppose an impedance of 10kOhm resulting
    /// in a 3 dB attenuation at 1.6Hz.
    ///
    /// ~~~
    ///                                 9/12V
    /// -----+
    /// audio|       10k                  |
    ///      +---o----R---o--------o-----(K)          +-----
    ///  out |   |        |        |      |           |audio
    /// -----+   R 1k     C 1000   |      |    10 uF  |
    ///          |        |  pF    +-C----o-----C-----+ 10k
    ///                             470   |           |
    ///         GND      GND         pF   R 1K        | amp
    ///          *                   **   |           +-----
    ///
    ///
    ///                                  GND
    /// ~~~
    ///
    /// The STC networks are connected with a [BJT] based [common collector]
    /// used as a voltage follower (featuring a 2SC1815 NPN transistor).
    ///
    /// * To operate properly the 6581 audio output needs a pull-down resistor
    ///   (1KOhm recommended, not needed on 8580)
    ///
    /// ** The C64c board additionally includes a [bootstrap] condenser to increase
    ///    the input impedance of the common collector.
    ///
    /// [BJT]: https://en.wikipedia.org/wiki/Bipolar_junction_transistor
    /// [common collector]: https://en.wikipedia.org/wiki/Common_collector
    /// [bootstrap]: https://en.wikipedia.org/wiki/Bootstrapping_(electronics)
    struct ExternalFilter {
        /// Lowpass filter voltage
        var Vlp: Int32 = 0

        /// Highpass filter voltage
        var Vhp: Int32 = 0

        var w0lp_1_s7: Int32 = 0

        var w0hp_1_s17: Int32 = 0

        /// Get the 3 dB attenuation point.
        ///
        /// - Parameters:
        ///   - res: the resistance value in Ohms
        ///   - cap: the capacitance value in Farads
        static func getRC(_ res: Double, _ cap: Double) -> Double {
            res * cap
        }

        /// Constructor.
        init() {
            reset()
        }

        /// Setup of the external filter sampling parameters.
        ///
        /// - Parameter frequency: the main system clock frequency
        mutating func setClockFrequency(_ frequency: Double) {
            let dt = 1.0 / frequency

            // Low-pass:  R = 10kOhm, C = 1000pF; w0l = dt/(dt+RC) = 1e-6/(1e-6+1e4*1e-9) = 0.091
            // Cutoff 1/2*PI*RC = 1/2*PI*1e4*1e-9 = 15915.5 Hz
            w0lp_1_s7 = residfp_int((dt / (dt + ExternalFilter.getRC(10e3, 1000e-12))) * Double(1 << 7) + 0.5)

            // High-pass: R = 10kOhm, C = 10uF;   w0h = dt/(dt+RC) = 1e-6/(1e-6+1e4*1e-5) = 0.00000999
            // Cutoff 1/2*PI*RC = 1/2*PI*1e4*1e-5 = 1.59155 Hz
            w0hp_1_s17 = residfp_int((dt / (dt + ExternalFilter.getRC(10e3, 10e-6))) * Double(1 << 17) + 0.5)
        }

        /// SID reset.
        mutating func reset() {
            // State of filter.
            Vlp = 0 // 1 << (15 + 11);
            Vhp = 0
        }

        /// SID clocking.
        ///
        /// - Parameter input: input sample, signed 16 bit
        /// - Returns: filtered sample, signed 16 bit
        @inline(__always)
        mutating func clock(_ input: Int32) -> Int32 {
            ExternalFilter.clock(input, &Vlp, &Vhp, w0lp_1_s7, w0hp_1_s17)
        }

        /// clock() with the filter's members as arguments, so that a loop can keep them in local variables.
        @inline(__always)
        static func clock(_ input: Int32, _ Vlp: inout Int32, _ Vhp: inout Int32, _ w0lp_1_s7: Int32, _ w0hp_1_s17: Int32) -> Int32 {
            let Vi = input &<< 11
            let dVlp = (w0lp_1_s7 &* (Vi &- Vlp)) >> 7
            let dVhp = (w0hp_1_s17 &* (Vlp &- Vhp)) >> 17
            Vlp = Vlp &+ dVlp
            Vhp = Vhp &+ dVhp
            return (Vlp &- Vhp) >> 11
        }
    }

    // MARK: - Potentiometer.h

    /// Potentiometer representation.
    /// This class will probably never be implemented in any real way.
    ///
    /// @author Ken Händel
    /// @author Dag Lem
    struct Potentiometer {
        /// Read paddle value. Not modeled.
        ///
        /// - Returns: paddle value (always 0xff)
        func readPOT() -> UInt8 { 0xFF }
    }
}
