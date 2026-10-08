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
// MOS 6581 / 8580 SID emulation: a Swift port of reSID 1.0 (the version carried by VICE), kept
// structurally the same as the C++ so the two can be read side by side. This file is sid.h / sid.cc;
// the other classes are in SIDWave.swift (wave.h/.cc), SIDEnvelope.swift (envelope.h/.cc),
// SIDVoice.swift (voice.h/.cc and extfilt.h/.cc), SIDFilter.swift (filter8580new.h, the filter
// this version builds by default and uses for both models) and SIDTables.swift (the table-building
// half of filter8580new.cc, dac.cc, spline.h); SIDWaveTables.swift is generated from the .dat files.
//
// The output is bit-identical to the C++ (built with clang on macOS) for the same register writes,
// in all four sampling methods. Integer types follow the C++: reSID's reg4...reg24 are
// `unsigned int` (UInt32 here) and cycle_count is `int` (Int32); wrapping operators are used
// wherever the C++ can wrap.
//
// Where the Swift is arranged differently, for speed or because Swift needs it, the result is the same:
// - reSID's static tables are built once per chip model and shared (SIDModelTables); a chip's
//   model is fixed when it is created, so only that model's tables are built.
// - The oscillators' sync_source / sync_dest pointers are arguments (SIDWave.swift).
// - The filter's routing switches are AND masks, and four of its tables have margins in place of
//   reSID's range asserts (SIDFilter.swift, SIDTables.swift).
// - The envelope pipelines share one word and their handling is out of line (SIDEnvelope.swift).
// - Waveforms that need none of set_waveform_output()'s special cases take a short path, and
//   synchronize() is skipped while no sync bit is set (SIDWave.swift, sync_any below).
// - Each output sample's run of cycles is a function of its own, with the write pipeline and the
//   bus value ageing taken out of the loop (clock_run_interpolate / clock_run_resample below).
// - The FIR tables are padded to a multiple of 32 coefficients (fir_stride below).
// - The filter's dither comes from a copy of macOS's rand() rather than from libc (Filter.Randomnoise).
//
// Not ported: SID::State / read_state / write_state, the raw debug output, the `interleave` argument
// of clock(), changing the chip model of an existing chip, and the paddle inputs (which reSID does
// not model either: POTX/POTY read 0xff).

public enum SIDModel: Sendable { case mos6581, mos8580 }

/// reSID's sampling_method.
public enum SIDSampling: Sendable {
    /// SAMPLE_FAST: delta clocking, nearest sample. Not cycle exact (pipelines are not modelled).
    case fast
    /// SAMPLE_INTERPOLATE: cycle exact, linear interpolation between the two nearest cycles.
    case interpolate
    /// SAMPLE_RESAMPLE: cycle exact, Kaiser-windowed sinc resampling with interpolated FIR tables.
    case resample
    /// SAMPLE_RESAMPLE_FASTMEM: as `resample` with one large FIR table and no interpolation.
    case resampleFastMem
}

/// One SID chip. It owns its buffers and frees them when it goes.
public struct SIDChip: ~Copyable {
    var sid_model: SIDModel
    // reSID's voice[3].
    var voice0: Voice
    var voice1: Voice
    var voice2: Voice
    var filter: Filter
    var extfilt: ExternalFilter
    // Potentiometer potx, poty: readPOT() is not modelled and returns 0xff.

    /// True while any voice has its sync bit set: synchronize() does nothing otherwise, so the
    /// per-cycle code skips it.
    var sync_any = false

    /// DAC tables shared by the three voices; see Voice.output(_:_:).
    let voice_dac: UnsafePointer<Int32>
    let envelope_dac: UnsafePointer<UInt16>

    var bus_value: UInt32 = 0
    var bus_value_ttl: Int32 = 0

    // The data bus TTL for the selected chip model
    var databus_ttl: Int32 = 0

    // Pipeline for writes on the MOS8580.
    var write_pipeline: Int32 = 0
    var write_address: UInt32 = 0

    var clock_frequency: Double = 0

    // Used to amplify the output by scaleFactor/2 to get an adequate playback volume
    var scaleFactor: Int32 = 3

    // Resampling constants.
    // The error in interpolated lookup is bounded by 1.234/L^2,
    // while the error in non-interpolated lookup is bounded by
    // 0.7854/L + 0.4113/L^2, see
    // http://www-ccrma.stanford.edu/~jos/resample/Choice_Table_Size.html
    // For a resolution of 16 bits this yields L >= 285 and L >= 51473,
    // respectively.
    static var FIR_N: Int32 { 125 }
    static var FIR_RES: Int32 { 285 }
    static var FIR_RES_FASTMEM: Int32 { 51473 }
    static var FIR_SHIFT: Int32 { 15 }

    static var RINGSIZE: Int32 { 1 << 14 }
    static var RINGMASK: Int32 { RINGSIZE - 1 }

    // Fixed point constants (16.16 bits).
    static var FIXP_SHIFT: Int32 { 16 }
    static var FIXP_MASK: Int32 { 0xFFFF }

    // Sampling variables.
    var sampling = SIDSampling.fast
    var cycles_per_sample: Int32 = 0
    var sample_offset: Int32 = 0
    var sample_index: Int32 = 0
    var sample_prev: Int32 = 0 // short
    var sample_now: Int32 = 0 // short
    var fir_N: Int32 = 0
    var fir_RES: Int32 = 0
    var fir_beta: Double = 0
    var fir_f_cycles_per_sample: Double = 0
    var fir_filter_scale: Double = 0

    // Ring buffer with overflow for contiguous storage of RINGSIZE samples.
    // (FIR_PAD further elements, always zero, follow it: see fir_stride.)
    var sample: UnsafeMutablePointer<Int16>?

    // FIR_RES filter tables (FIR_N*FIR_RES).
    // reSID stores the fir_RES tables back to back, fir_N coefficients each. Here each table is
    // followed by zeros up to fir_stride, a multiple of FIR_PAD, so a convolution can run over
    // fir_stride elements in whole vectors with no scalar tail; the extra products are all zero.
    var fir: UnsafeMutablePointer<Int16>?
    var fir_stride: Int32 = 0
    static var FIR_PAD: Int32 { 32 }

    // ----------------------------------------------------------------------------
    // Constructor.
    // ----------------------------------------------------------------------------

    /// Equivalent to reSID's `SID sid; sid.set_chip_model(model); sid.set_voice_mask(0x07); sid.input(0);
    /// sid.set_sampling_parameters(clockHz, sampling, sampleRate);`.
    ///
    /// The first chip of each model builds that model's lookup tables (a few hundred milliseconds
    /// and about 11 MB); they are shared by later chips and kept for the life of the process.
    /// If reSID would reject the sampling parameters (see `setSamplingParameters`) the chip falls back
    /// to `.interpolate`; `sampling` tells which method is in effect.
    public init(model: SIDModel, clockHz: Double, sampleRate: Double, sampling: SIDSampling = .resample) {
        let tables = SIDModelTables.tables(for: model)
        sid_model = model
        voice0 = Voice(model: model, tables: tables)
        voice1 = Voice(model: model, tables: tables)
        voice2 = Voice(model: model, tables: tables)
        filter = Filter(model: model, tables: tables)
        extfilt = ExternalFilter()
        voice_dac = UnsafePointer(tables.voice_dac)
        envelope_dac = UnsafePointer(tables.env_dac)

        // set_chip_model():
        /*
           results from real C64 (testprogs/SID/bitfade/delayfrq0.prg):

           (new SID) (250469/8580R5) (250469/8580R5)
           delayfrq0    ~7a000        ~108000

           (old SID) (250407/6581)
           delayfrq0    ~01d00

         */
        databus_ttl = model == .mos8580 ? 0xA2000 : 0x1D00

        scaleFactor = model == .mos8580 ? 5 : 3

        if !setSamplingParameters(clockHz: clockHz, sampling: sampling, sampleRate: sampleRate) {
            _ = setSamplingParameters(clockHz: clockHz, sampling: .interpolate, sampleRate: sampleRate)
        }
    }

    // ----------------------------------------------------------------------------
    // Destructor.
    // ----------------------------------------------------------------------------
    deinit {
        sample?.deallocate()
        fir?.deallocate()
    }

    public var model: SIDModel { sid_model }

    /// The sampling method in effect.
    public var samplingMethod: SIDSampling { sampling }

    // ----------------------------------------------------------------------------
    // SID reset.
    // ----------------------------------------------------------------------------
    public mutating func reset() {
        voice0.reset()
        voice1.reset()
        voice2.reset()
        filter.reset()
        extfilt.reset()
        sync_any = false

        bus_value = 0
        bus_value_ttl = 0
    }

    // ----------------------------------------------------------------------------
    // Write 16-bit sample to audio input.
    // Note that to mix in an external audio signal, the signal should be
    // resampled to 1MHz first to avoid sampling noise.
    // ----------------------------------------------------------------------------

    /// EXT IN, a signed 16-bit sample. It is only heard when bit 3 of the voice mask is set
    /// (`setVoiceMask(0x0f)`); reSID's 8580 "digi boost" is `setVoiceMask(0x0f)` and `input(-32768)`.
    public mutating func input(_ sample: Int) {
        // The input can be used to simulate the MOS8580 "digi boost" hardware hack.
        filter.input(Int32(Int16(truncatingIfNeeded: sample)))
    }

    // ----------------------------------------------------------------------------
    // Read registers.
    //
    // Reading a write only register returns the last byte written to any SID
    // register. The individual bits in this value start to fade down towards
    // zero after a few cycles. All bits reach zero within approximately
    // $2000 - $4000 cycles.
    // It has been claimed that this fading happens in an orderly fashion, however
    // sampling of write only registers reveals that this is not the case.
    // NB! This is not correctly modeled.
    // The actual use of write only registers has largely been made in the belief
    // that all SID registers are readable. To support this belief the read
    // would have to be done immediately after a write to the same register
    // (remember that an intermediate write to another register would yield that
    // value instead). With this in mind we return the last value written to
    // any SID register for $4000 cycles without modeling the bit fading.
    // ----------------------------------------------------------------------------
    public mutating func read(_ register: Int) -> UInt8 {
        switch register {
        case 0x19:
            bus_value = 0xFF // potx.readPOT()
            bus_value_ttl = databus_ttl
        case 0x1A:
            bus_value = 0xFF // poty.readPOT()
            bus_value_ttl = databus_ttl
        case 0x1B:
            bus_value = voice2.wave.readOSC()
            bus_value_ttl = databus_ttl
        case 0x1C:
            bus_value = voice2.envelope.readENV()
            bus_value_ttl = databus_ttl
        default:
            break
        }
        return UInt8(truncatingIfNeeded: bus_value)
    }

    // ----------------------------------------------------------------------------
    // Write registers.
    // Writes are one cycle delayed on the MOS8580. This is only modeled for
    // single cycle clocking.
    // ----------------------------------------------------------------------------
    public mutating func write(_ register: Int, _ value: UInt8) {
        write_address = UInt32(truncatingIfNeeded: register)
        bus_value = UInt32(value)
        bus_value_ttl = databus_ttl

        if _slowPath(sampling == .fast), sid_model == .mos8580 {
            // Fake one cycle pipeline delay on the MOS8580
            // when using non cycle accurate emulation.
            // This will make the SID detection method work.
            write_pipeline = 1
        } else {
            write()
        }
    }

    // ----------------------------------------------------------------------------
    // Write registers.
    // ----------------------------------------------------------------------------
    mutating func write() {
        switch write_address {
        case 0x00:
            voice0.wave.writeFREQ_LO(bus_value)
        case 0x01:
            voice0.wave.writeFREQ_HI(bus_value)
        case 0x02:
            voice0.wave.writePW_LO(bus_value)
        case 0x03:
            voice0.wave.writePW_HI(bus_value)
        case 0x04:
            voice0.writeCONTROL_REG(bus_value, voice2.wave.accumulator)
        case 0x05:
            voice0.envelope.writeATTACK_DECAY(bus_value)
        case 0x06:
            voice0.envelope.writeSUSTAIN_RELEASE(bus_value)
        case 0x07:
            voice1.wave.writeFREQ_LO(bus_value)
        case 0x08:
            voice1.wave.writeFREQ_HI(bus_value)
        case 0x09:
            voice1.wave.writePW_LO(bus_value)
        case 0x0A:
            voice1.wave.writePW_HI(bus_value)
        case 0x0B:
            voice1.writeCONTROL_REG(bus_value, voice0.wave.accumulator)
        case 0x0C:
            voice1.envelope.writeATTACK_DECAY(bus_value)
        case 0x0D:
            voice1.envelope.writeSUSTAIN_RELEASE(bus_value)
        case 0x0E:
            voice2.wave.writeFREQ_LO(bus_value)
        case 0x0F:
            voice2.wave.writeFREQ_HI(bus_value)
        case 0x10:
            voice2.wave.writePW_LO(bus_value)
        case 0x11:
            voice2.wave.writePW_HI(bus_value)
        case 0x12:
            voice2.writeCONTROL_REG(bus_value, voice1.wave.accumulator)
        case 0x13:
            voice2.envelope.writeATTACK_DECAY(bus_value)
        case 0x14:
            voice2.envelope.writeSUSTAIN_RELEASE(bus_value)
        case 0x15:
            filter.writeFC_LO(bus_value)
        case 0x16:
            filter.writeFC_HI(bus_value)
        case 0x17:
            filter.writeRES_FILT(bus_value)
        case 0x18:
            filter.writeMODE_VOL(bus_value)
        default:
            break
        }
        sync_any = (voice0.wave.sync | voice1.wave.sync | voice2.wave.sync) != 0

        // Tell clock() that the pipeline is empty.
        write_pipeline = 0
    }

    // ----------------------------------------------------------------------------
    // Mask for voices routed into the filter / audio output stage.
    // Used to physically connect/disconnect EXT IN, and for test purposed
    // (voice muting).
    // ----------------------------------------------------------------------------

    /// Bits 0-2 enable voices 1-3, bit 3 connects EXT IN. The default is 0x07.
    public mutating func setVoiceMask(_ mask: Int) {
        filter.set_voice_mask(UInt32(truncatingIfNeeded: mask))
    }

    // ----------------------------------------------------------------------------
    // Enable filter.
    // ----------------------------------------------------------------------------
    public mutating func setFilterEnabled(_ enabled: Bool) {
        filter.enable_filter(enabled)
    }

    // ----------------------------------------------------------------------------
    // Adjust the DAC bias parameter of the filter.
    // This gives user variable control of the exact CF -> center frequency
    // mapping used by the filter.
    // ----------------------------------------------------------------------------

    /// reSID's adjust_filter_bias. On the 6581 `bias` shifts the cutoff DAC voltage; on the 8580 it
    /// moves the DAC gate voltage (VICE passes millivolts / 1000, in the range -5...5).
    public mutating func adjustFilterBias(_ bias: Double) {
        filter.adjust_filter_bias(bias)
    }

    // ----------------------------------------------------------------------------
    // Enable external filter.
    // ----------------------------------------------------------------------------

    /// The C64's audio output stage (16 kHz low-pass, 1.6 Hz high-pass). On by default.
    public mutating func setExternalFilterEnabled(_ enabled: Bool) {
        extfilt.enable_filter(enabled)
    }

    // ----------------------------------------------------------------------------
    // I0() computes the 0th order modified Bessel function of the first kind.
    // This function is originally from resample-1.5/filterkit.c by J. O. Smith.
    // ----------------------------------------------------------------------------
    static func I0(_ x: Double) -> Double {
        // Max error acceptable in I0.
        let I0e = 1e-6

        var sum = 1.0, u = 1.0
        var n = 1

        let halfx = x / 2.0

        repeat {
            let temp = halfx / Double(n)
            n += 1
            u *= temp * temp
            sum += u
        } while u >= I0e * sum

        return sum
    }

    // ----------------------------------------------------------------------------
    // Setting of SID sampling parameters.
    //
    // Use a clock freqency of 985248Hz for PAL C64, 1022730Hz for NTSC C64.
    // The default end of passband frequency is pass_freq = 0.9*sample_freq/2
    // for sample frequencies up to ~ 44.1kHz, and 20kHz for higher sample
    // frequencies.
    //
    // For resampling, the ratio between the clock frequency and the sample
    // frequency is limited as follows:
    //   125*clock_freq/sample_freq < 16384
    // E.g. provided a clock frequency of ~ 1MHz, the sample frequency can not
    // be set lower than ~ 8kHz. A lower sample frequency would make the
    // resampling code overfill its 16k sample ring buffer.
    //
    // The end of passband frequency is also limited:
    //   pass_freq <= 0.9*sample_freq/2

    // E.g. for a 44.1kHz sampling rate the end of passband frequency is limited
    // to slightly below 20kHz. This constraint ensures that the FIR table is
    // not overfilled.
    // ----------------------------------------------------------------------------
    @discardableResult
    public mutating func setSamplingParameters(clockHz clock_freq: Double, sampling method: SIDSampling,
                                               sampleRate sample_freq: Double, passFrequency: Double = -1,
                                               filterScale filter_scale: Double = 0.97) -> Bool
    {
        var pass_freq = passFrequency
        let resampling = method == .resample || method == .resampleFastMem

        // Check resampling constraints.
        if resampling {
            // Check whether the sample ring buffer would overfill.
            if sid_int(Double(Self.FIR_N) * clock_freq / sample_freq) >= Self.RINGSIZE {
                return false
            }

            // The default passband limit is 0.9*sample_freq/2 for sample
            // frequencies below ~ 44.1kHz, and 20kHz for higher sample frequencies.
            if pass_freq < 0 {
                pass_freq = 20000
                if 2 * pass_freq / sample_freq >= 0.9 {
                    pass_freq = 0.9 * sample_freq / 2
                }
            }
            // Check whether the FIR table would overfill.
            else if pass_freq > 0.9 * sample_freq / 2 {
                return false
            }

            // The filter scaling is only included to avoid clipping, so keep
            // it sane.
            if filter_scale < 0.9 || filter_scale > 1.0 {
                return false
            }
        }

        clock_frequency = clock_freq
        sampling = method

        cycles_per_sample =
            sid_int(clock_freq / sample_freq * Double(1 << Self.FIXP_SHIFT) + 0.5)

        sample_offset = 0
        sample_prev = 0
        sample_now = 0

        // FIR initialization is only necessary for resampling.
        if !resampling {
            sample?.deallocate()
            fir?.deallocate()
            sample = nil
            fir = nil
            return true
        }

        // Allocate sample buffer.
        if sample == nil {
            sample = .allocate(capacity: Int(Self.RINGSIZE) * 2 + Int(Self.FIR_PAD))
        }
        // Clear sample buffer.
        sample!.initialize(repeating: 0, count: Int(Self.RINGSIZE) * 2 + Int(Self.FIR_PAD))
        sample_index = 0

        let pi = 3.1415926535897932385

        // 16 bits -> -96dB stopband attenuation.
        let A = -20 * log10(1.0 / Double(1 << 16))
        // A fraction of the bandwidth is allocated to the transition band,
        let dw = (1 - 2 * pass_freq / sample_freq) * pi * 2
        // The cutoff frequency is midway through the transition band (nyquist)
        let wc = pi

        // For calculation of beta and N see the reference for the kaiserord
        // function in the MATLAB Signal Processing Toolbox:
        // http://www.mathworks.com/access/helpdesk/help/toolbox/signal/kaiserord.html
        let beta = 0.1102 * (A - 8.7)
        let I0beta = Self.I0(beta)

        // The filter order will maximally be 124 with the current constraints.
        // N >= (96.33 - 7.95)/(2.285*0.1*pi) -> N >= 123
        // The filter order is equal to the number of zero crossings, i.e.
        // it should be an even number (sinc is symmetric about x = 0).
        var N = sid_int((A - 7.95) / (2.285 * dw) + 0.5)
        N += N & 1

        let f_samples_per_cycle = sample_freq / clock_freq
        let f_cycles_per_sample = clock_freq / sample_freq

        // The filter length is equal to the filter order + 1.
        // The filter length must be an odd number (sinc is symmetric about x = 0).
        var fir_N_new = sid_int(Double(N) * f_cycles_per_sample) + 1
        fir_N_new |= 1

        // Check whether the sample ring buffer would overflow.
        // (An assert in reSID.)
        if fir_N_new >= Self.RINGSIZE {
            sample?.deallocate()
            fir?.deallocate()
            sample = nil
            fir = nil
            sampling = .interpolate
            return false
        }

        // We clamp the filter table resolution to 2^n, making the fixed point
        // sample_offset a whole multiple of the filter table resolution.
        let res = method == .resample ?
            Self.FIR_RES : Self.FIR_RES_FASTMEM
        let n = sid_int(ceil(log(Double(res) / f_cycles_per_sample) / log(Double(Float(2.0)))))
        let fir_RES_new = Int32(1) << n

        /* Determine if we need to recalculate table, or whether we can reuse earlier cached copy.
         * This pays off on slow hardware such as current Android devices.
         */
        if fir != nil, fir_RES_new == fir_RES, fir_N_new == fir_N, beta == fir_beta,
           f_cycles_per_sample == fir_f_cycles_per_sample, fir_filter_scale == filter_scale
        {
            return true
        }
        fir_RES = fir_RES_new
        fir_N = fir_N_new
        fir_beta = beta
        fir_f_cycles_per_sample = f_cycles_per_sample
        fir_filter_scale = filter_scale

        // Allocate memory for FIR tables.
        fir?.deallocate()
        fir_stride = (fir_N + Self.FIR_PAD - 1) & ~(Self.FIR_PAD - 1)
        let firN = Int(fir_N), firRES = Int(fir_RES), stride = Int(fir_stride)
        let table = UnsafeMutablePointer<Int16>.allocate(capacity: stride * firRES)
        table.initialize(repeating: 0, count: stride * firRES)
        fir = table

        // Calculate fir_RES FIR tables for linear interpolation.
        for i in 0 ..< firRES {
            let fir_offset = i * stride + firN / 2
            let j_offset = Double(i) / Double(firRES)
            // Calculate FIR table. This is the sinc function, weighted by the
            // Kaiser window.
            for j in -(firN / 2) ... firN / 2 {
                let jx = Double(j) - j_offset
                let wt = wc * jx / f_cycles_per_sample
                let temp = jx / Double(firN / 2)
                let Kaiser = abs(temp) <= 1 ? Self.I0(beta * (1 - temp * temp).squareRoot()) / I0beta : 0
                let sincwt = abs(wt) >= 1e-6 ? sin(wt) / wt : 1
                let val = Double(1 << Self.FIR_SHIFT) * filter_scale * f_samples_per_cycle * wc / pi * sincwt * Kaiser
                // sid.cc's round() macro: (x>=0.0?floor(x+0.5):ceil(x-0.5))
                let rounded = val >= 0.0 ? floor(val + 0.5) : ceil(val - 0.5)
                table[fir_offset + j] = Int16(truncatingIfNeeded: sid_int(rounded))
            }
        }

        return true
    }

    // ----------------------------------------------------------------------------
    // Adjustment of SID sampling frequency.
    //
    // In some applications, e.g. a C64 emulator, it can be desirable to
    // synchronize sound with a timer source. This is supported by adjustment of
    // the SID sampling frequency.
    //
    // NB! Adjustment of the sampling frequency may lead to noticeable shifts in
    // frequency, and should only be used for interactive applications. Note also
    // that any adjustment of the sampling frequency will change the
    // characteristics of the resampling filter, since the filter is not rebuilt.
    // ----------------------------------------------------------------------------
    public mutating func adjustSamplingFrequency(_ sample_freq: Double) {
        cycles_per_sample =
            sid_int(clock_frequency / sample_freq * Double(1 << Self.FIXP_SHIFT) + 0.5)
    }

    // ----------------------------------------------------------------------------
    // Read 16-bit sample from audio output.
    // ----------------------------------------------------------------------------

    /// AUDIO OUT as reSID's output(): the external filter's current output, before the
    /// scaleFactor/2 amplification the sampling functions apply. Nominally 16 bits, not clipped.
    public var output: Int {
        Int(extfilt.output())
    }

    // ----------------------------------------------------------------------------
    // SID clocking - 1 cycle.
    // ----------------------------------------------------------------------------
    @inline(__always)
    mutating func clock_cycle() {
        clock_voices_and_filters()

        // Pipelined writes on the MOS8580.
        if _slowPath(write_pipeline != 0) {
            write()
        }

        // Age bus value.
        bus_value_ttl &-= 1
        if _slowPath(bus_value_ttl == 0) {
            bus_value = 0
        }
    }

    /// reSID's clock() up to and including the external filter.
    @inline(__always)
    mutating func clock_voices_and_filters() {
        // Clock amplitude modulators.
        voice0.envelope.clock()
        voice1.envelope.clock()
        voice2.envelope.clock()

        // Clock oscillators.
        voice0.wave.clock()
        voice1.wave.clock()
        voice2.wave.clock()

        // Synchronize oscillators.
        if _slowPath(sync_any) {
            voice0.wave.synchronize(&voice1.wave, voice2.wave.msb_rising)
            voice1.wave.synchronize(&voice2.wave, voice0.wave.msb_rising)
            voice2.wave.synchronize(&voice0.wave, voice1.wave.msb_rising)
        }

        // Calculate waveform output.
        voice0.wave.set_waveform_output_fast(voice2.wave.accumulator)
        voice1.wave.set_waveform_output_fast(voice0.wave.accumulator)
        voice2.wave.set_waveform_output_fast(voice1.wave.accumulator)

        // Clock filter.
        filter.clock(voice0.output(voice_dac, envelope_dac), voice1.output(voice_dac, envelope_dac),
                     voice2.output(voice_dac, envelope_dac))

        // Clock external filter.
        extfilt.clock(filter.output())
    }

    // The sampling functions below clock the chip in runs of about twenty cycles, one run per
    // output sample. Each run is a loop of clock() calls in reSID; here the loops are functions of
    // their own (kept out of line so that nothing but the chip state competes for registers), and
    // the two parts of clock() that do not depend on the cycle are taken out of the loop:
    //
    // - The write pipeline can only be loaded by write(), which cannot happen inside a run, so a
    //   pending write is dealt with in the first cycle and not looked for again.
    // - The bus value is only seen by read(), again outside a run, so it is aged once for the
    //   whole run. clock() decrements bus_value_ttl and clears bus_value when it becomes zero: over
    //   n cycles that happens exactly when 0 < bus_value_ttl <= n.

    /// The first cycle of a run, if a pipelined write is pending: reSID's clock() as it stands,
    /// without the bus ageing. Returns the number of cycles clocked (0 or 1).
    @inline(__always)
    mutating func clock_pending_write(_ count: Int32) -> Int32 {
        if _slowPath(write_pipeline != 0), count > 0 {
            clock_voices_and_filters_out_of_line()
            write()
            return 1
        }
        return 0
    }

    /// The Swift optimiser inlines an `@inline(__always)` function of this size only once per caller,
    /// so each run function has exactly one inlined use, in its loop; the rare first cycle goes here.
    @inline(never)
    mutating func clock_voices_and_filters_out_of_line() {
        clock_voices_and_filters()
    }

    @inline(__always)
    mutating func age_bus_value(_ count: Int32) {
        if _slowPath(bus_value_ttl > 0 && bus_value_ttl <= count) {
            bus_value = 0
        }
        bus_value_ttl &-= count
    }

    /// `for (int i = delta_t_sample; i > 0; i--) { clock(); if (i <= 2) { sample_prev = sample_now; sample_now = clip(output()); } }`
    @inline(never)
    mutating func clock_run_interpolate(_ delta_t_sample: Int32) {
        var i = delta_t_sample
        if clock_pending_write(i) != 0 {
            if i <= 2 {
                sample_prev = sample_now
                sample_now = Self.clip(extfilt.output())
            }
            i -= 1
        }
        while i > 0 {
            clock_voices_and_filters()
            if _slowPath(i <= 2) {
                sample_prev = sample_now
                sample_now = Self.clip(extfilt.output())
            }
            i -= 1
        }
        age_bus_value(delta_t_sample)
    }

    /// `for (int i = 0; i < delta_t_sample; i++) { clock(); sample[sample_index] = sample[sample_index + RINGSIZE] = clip(output()); ++sample_index &= RINGMASK; }`
    @inline(never)
    mutating func clock_run_resample(_ delta_t_sample: Int32, _ sample: UnsafeMutablePointer<Int16>) {
        var i: Int32 = 0
        var index = sample_index
        if clock_pending_write(delta_t_sample) != 0 {
            let value = Int16(truncatingIfNeeded: Self.clip(extfilt.output()))
            sample[Int(index)] = value
            sample[Int(index &+ Self.RINGSIZE)] = value
            index = (index &+ 1) & Self.RINGMASK
            i = 1
        }
        while i < delta_t_sample {
            clock_voices_and_filters()
            let value = Int16(truncatingIfNeeded: Self.clip(extfilt.output()))
            sample[Int(index)] = value
            sample[Int(index &+ Self.RINGSIZE)] = value
            index = (index &+ 1) & Self.RINGMASK
            i += 1
        }
        sample_index = index
        age_bus_value(delta_t_sample)
    }

    /// reSID's clock(): advances exactly one cycle, cycle exact, with no output.
    public mutating func clock() {
        clock_cycle()
    }

    // ----------------------------------------------------------------------------
    // SID clocking - delta_t cycles.
    // ----------------------------------------------------------------------------

    /// reSID's clock(delta_t): advances `cycles` cycles with no output, using delta clocking
    /// (the oscillators, envelopes and filters are stepped in multi-cycle jumps, as in `.fast`),
    /// so it is quick but not cycle exact. Call `clock()` per cycle when exactness matters.
    public mutating func clock(_ cycles: Int) {
        var remaining = cycles
        while remaining > 0 {
            let step = Int32(clamping: remaining)
            clock_delta(step)
            remaining -= Int(step)
        }
    }

    mutating func clock_delta(_ delta_t: Int32) {
        var delta_t = delta_t

        // Pipelined writes on the MOS8580.
        if _slowPath(write_pipeline != 0), _fastPath(delta_t > 0) {
            // Step one cycle by a recursive call to ourselves.
            write_pipeline = 0
            clock_delta_step(1)
            write()
            delta_t -= 1
        }

        clock_delta_step(delta_t)
    }

    /// The body of reSID's clock(delta_t) after the write pipeline has been dealt with.
    @inline(never)
    mutating func clock_delta_step(_ delta_t: Int32) {
        if _slowPath(delta_t <= 0) {
            return
        }

        // Age bus value.
        bus_value_ttl &-= delta_t
        if _slowPath(bus_value_ttl <= 0) {
            bus_value = 0
            bus_value_ttl = 0
        }

        // Clock amplitude modulators.
        voice0.envelope.clock(delta_t)
        voice1.envelope.clock(delta_t)
        voice2.envelope.clock(delta_t)

        // Clock and synchronize oscillators.
        // Loop until we reach the current cycle.
        var delta_t_osc = delta_t
        while delta_t_osc != 0 {
            var delta_t_min = delta_t_osc

            // Find minimum number of cycles to an oscillator accumulator MSB toggle.
            // We have to clock on each MSB on / MSB off for hard sync to operate
            // correctly.
            Self.next_msb_toggle(voice0.wave, voice1.wave.sync, &delta_t_min)
            Self.next_msb_toggle(voice1.wave, voice2.wave.sync, &delta_t_min)
            Self.next_msb_toggle(voice2.wave, voice0.wave.sync, &delta_t_min)

            // Clock oscillators.
            voice0.wave.clock(delta_t_min)
            voice1.wave.clock(delta_t_min)
            voice2.wave.clock(delta_t_min)

            // Synchronize oscillators.
            voice0.wave.synchronize(&voice1.wave, voice2.wave.msb_rising)
            voice1.wave.synchronize(&voice2.wave, voice0.wave.msb_rising)
            voice2.wave.synchronize(&voice0.wave, voice1.wave.msb_rising)

            delta_t_osc &-= delta_t_min
        }

        // Calculate waveform output.
        voice0.wave.set_waveform_output(delta_t, voice2.wave.accumulator)
        voice1.wave.set_waveform_output(delta_t, voice0.wave.accumulator)
        voice2.wave.set_waveform_output(delta_t, voice1.wave.accumulator)

        // Clock filter.
        filter.clock(delta_t, voice0.output(), voice1.output(), voice2.output())

        // Clock external filter.
        extfilt.clock(delta_t, filter.output())
    }

    /// The loop body of "find minimum number of cycles to an oscillator accumulator MSB toggle".
    @inline(__always)
    static func next_msb_toggle(_ wave: WaveformGenerator, _ sync_dest_sync: UInt32, _ delta_t_min: inout Int32) {
        // It is only necessary to clock on the MSB of an oscillator that is
        // a sync source and has freq != 0.
        if _fastPath(!(sync_dest_sync != 0 && wave.freq != 0)) {
            return
        }

        let freq = wave.freq
        let accumulator = wave.accumulator

        // Clock on MSB off if MSB is on, clock on MSB on if MSB is off.
        let delta_accumulator =
            ((accumulator & 0x800000) != 0 ? 0x1000000 : 0x800000) &- accumulator

        var delta_t_next = Int32(bitPattern: delta_accumulator / freq)
        if _fastPath(delta_accumulator % freq != 0) {
            delta_t_next &+= 1
        }

        if _slowPath(delta_t_next < delta_t_min) {
            delta_t_min = delta_t_next
        }
    }

    // ----------------------------------------------------------------------------
    // SID clocking with audio sampling.
    // Fixed point arithmetics are used.
    //
    // The example below shows how to clock the SID a specified amount of cycles
    // while producing audio output:
    //
    // while (delta_t) {
    //   bufindex += sid.clock(delta_t, buf + bufindex, buflength - bufindex);
    //   write(dsp, buf, bufindex*2);
    //   bufindex = 0;
    // }
    //
    // ----------------------------------------------------------------------------

    /// reSID's clock(delta_t, buf, n): advances by up to `cycles` CPU cycles, writing mono 16-bit samples.
    /// On return `cycles` holds the cycles not yet consumed (non-zero only when the buffer filled up);
    /// the result is the number of samples written.
    public mutating func clock(_ cycles: inout Int, into buffer: UnsafeMutablePointer<Int16>, maxSamples: Int) -> Int {
        if cycles <= 0 { return 0 }
        let wanted = Int32(clamping: cycles)
        var delta_t = wanted
        let n = Int32(clamping: maxSamples)
        let s: Int32
        switch sampling {
        case .fast:
            s = clock_fast(&delta_t, buffer, n)
        case .interpolate:
            s = clock_interpolate(&delta_t, buffer, n)
        case .resample:
            s = clock_resample(&delta_t, buffer, n)
        case .resampleFastMem:
            s = clock_resample_fastmem(&delta_t, buffer, n)
        }
        cycles -= Int(wanted - delta_t)
        return Int(s)
    }

    @inline(__always)
    static func clip(_ input: Int32) -> Int32 {
        // Saturated arithmetics to guard against 16 bit sample overflow.
        if _slowPath(input > 32767) {
            return 32767
        }
        if _slowPath(input < -32768) {
            return -32768
        }
        return input
    }

    @inline(__always)
    static func amplify(_ input: Int32, _ scaleFactor: Int32) -> Int16 {
        Int16(truncatingIfNeeded: clip((scaleFactor &* input) / 2))
    }

    // ----------------------------------------------------------------------------
    // SID clocking with audio sampling - delta clocking picking nearest sample.
    // ----------------------------------------------------------------------------
    mutating func clock_fast(_ delta_t: inout Int32, _ buf: UnsafeMutablePointer<Int16>, _ n: Int32) -> Int32 {
        var s: Int32 = 0

        while s < n {
            let next_sample_offset = sample_offset &+ cycles_per_sample &+ (1 << (Self.FIXP_SHIFT - 1))
            var delta_t_sample = next_sample_offset >> Self.FIXP_SHIFT

            if delta_t_sample > delta_t {
                delta_t_sample = delta_t
            }

            clock_delta(delta_t_sample)

            delta_t &-= delta_t_sample
            if delta_t == 0 {
                sample_offset &-= delta_t_sample << Self.FIXP_SHIFT
                break
            }

            sample_offset = (next_sample_offset & Self.FIXP_MASK) &- (1 << (Self.FIXP_SHIFT - 1))
            buf[Int(s)] = Self.amplify(extfilt.output(), scaleFactor)
            s += 1
        }

        return s
    }

    // ----------------------------------------------------------------------------
    // SID clocking with audio sampling - cycle based with linear sample
    // interpolation.
    //
    // Here the chip is clocked every cycle. This yields higher quality
    // sound since the samples are linearly interpolated, and since the
    // external filter attenuates frequencies above 16kHz, thus reducing
    // sampling noise.
    // ----------------------------------------------------------------------------
    mutating func clock_interpolate(_ delta_t: inout Int32, _ buf: UnsafeMutablePointer<Int16>, _ n: Int32) -> Int32 {
        var s: Int32 = 0

        while s < n {
            let next_sample_offset = sample_offset &+ cycles_per_sample
            var delta_t_sample = next_sample_offset >> Self.FIXP_SHIFT

            if delta_t_sample > delta_t {
                delta_t_sample = delta_t
            }

            clock_run_interpolate(delta_t_sample)

            delta_t &-= delta_t_sample
            if delta_t == 0 {
                sample_offset &-= delta_t_sample << Self.FIXP_SHIFT
                break
            }

            sample_offset = next_sample_offset & Self.FIXP_MASK

            buf[Int(s)] = Self.amplify(
                sample_prev &+ ((sample_offset &* (sample_now &- sample_prev)) >> Self.FIXP_SHIFT),
                scaleFactor
            )
            s += 1
        }

        return s
    }

    // ----------------------------------------------------------------------------
    // SID clocking with audio sampling - cycle based with audio resampling.
    //
    // This is the theoretically correct (and computationally intensive) audio
    // sample generation. The samples are generated by resampling to the specified
    // sampling frequency. The work rate is inversely proportional to the
    // percentage of the bandwidth allocated to the filter transition band.
    //
    // This implementation is based on the paper "A Flexible Sampling-Rate
    // Conversion Method", by J. O. Smith and P. Gosset, or rather on the
    // expanded tutorial on the "Digital Audio Resampling Home Page":
    // http://www-ccrma.stanford.edu/~jos/resample/
    //
    // By building shifted FIR tables with samples according to the
    // sampling frequency, the implementation below dramatically reduces the
    // computational effort in the filter convolutions, without any loss
    // of accuracy. The filter convolutions are also vectorizable on
    // current hardware.
    //
    // Further possible optimizations are:
    // * An equiripple filter design could yield a lower filter order, see
    //   http://www.mwrf.com/Articles/ArticleID/7229/7229.html
    // * The Convolution Theorem could be used to bring the complexity of
    //   convolution down from O(n*n) to O(n*log(n)) using the Fast Fourier
    //   Transform, see http://en.wikipedia.org/wiki/Convolution_theorem
    // * Simply resampling in two steps can also yield computational
    //   savings, since the transition band will be wider in the first step
    //   and the required filter order is thus lower in this step.
    //   Laurent Ganier has found the optimal intermediate sampling frequency
    //   to be (via derivation of sum of two steps):
    //     2 * pass_freq + sqrt [ 2 * pass_freq * orig_sample_freq
    //       * (dest_sample_freq - 2 * pass_freq) / dest_sample_freq ]
    //
    // NB! the result of right shifting negative numbers is really
    // implementation dependent in the C++ standard.
    // ----------------------------------------------------------------------------
    mutating func clock_resample(_ delta_t: inout Int32, _ buf: UnsafeMutablePointer<Int16>, _ n: Int32) -> Int32 {
        guard let sample, let fir else { return 0 }
        let fir_N = Int(self.fir_N), fir_stride = Int(self.fir_stride)
        var s: Int32 = 0

        while s < n {
            let next_sample_offset = sample_offset &+ cycles_per_sample
            var delta_t_sample = next_sample_offset >> Self.FIXP_SHIFT

            if delta_t_sample > delta_t {
                delta_t_sample = delta_t
            }

            clock_run_resample(delta_t_sample, sample)

            delta_t &-= delta_t_sample
            if delta_t == 0 {
                sample_offset &-= delta_t_sample << Self.FIXP_SHIFT
                break
            }

            sample_offset = next_sample_offset & Self.FIXP_MASK

            var fir_offset = (sample_offset &* fir_RES) >> Self.FIXP_SHIFT
            let fir_offset_rmd = (sample_offset &* fir_RES) & Self.FIXP_MASK
            var fir_start = UnsafePointer(fir) + Int(fir_offset) * fir_stride
            var sample_start = UnsafePointer(sample) + (Int(sample_index) - fir_N - 1 + Int(Self.RINGSIZE))

            // Convolution with filter impulse response.
            let v1 = Self.convolve(sample_start, fir_start, fir_stride)

            // Use next FIR table, wrap around to first FIR table using
            // next sample.
            fir_offset += 1
            if _slowPath(fir_offset == fir_RES) {
                fir_offset = 0
                sample_start += 1
            }
            fir_start = UnsafePointer(fir) + Int(fir_offset) * fir_stride

            // Convolution with filter impulse response.
            let v2 = Self.convolve(sample_start, fir_start, fir_stride)

            // Linear interpolation.
            // fir_offset_rmd is equal for all samples, it can thus be factorized out:
            // sum(v1 + rmd*(v2 - v1)) = sum(v1) + rmd*(sum(v2) - sum(v1))
            var v = v1 &+ Int32(bitPattern: (UInt32(bitPattern: fir_offset_rmd) &* UInt32(bitPattern: v2 &- v1)) >> UInt32(Self.FIXP_SHIFT))

            v >>= Self.FIR_SHIFT

            buf[Int(s)] = Self.amplify(v, scaleFactor)
            s += 1
        }

        return s
    }

    /// `for (j = 0; j < fir_N; j++) v += sample_start[j]*fir_start[j];` with C's wrapping int sum,
    /// run over the zero-padded table length (a multiple of FIR_PAD). The products past fir_N are
    /// zero whatever the ring buffer holds there, and a wrapping sum does not depend on its order,
    /// so the result is the same.
    @inline(__always)
    static func convolve(_ sample_start: UnsafePointer<Int16>, _ fir_start: UnsafePointer<Int16>, _ fir_stride: Int) -> Int32 {
        var v: Int32 = 0
        for j in 0 ..< fir_stride {
            v &+= Int32(sample_start[j]) &* Int32(fir_start[j])
        }
        return v
    }

    // ----------------------------------------------------------------------------
    // SID clocking with audio sampling - cycle based with audio resampling.
    // ----------------------------------------------------------------------------
    mutating func clock_resample_fastmem(_ delta_t: inout Int32, _ buf: UnsafeMutablePointer<Int16>, _ n: Int32) -> Int32 {
        guard let sample, let fir else { return 0 }
        let fir_N = Int(self.fir_N), fir_stride = Int(self.fir_stride)
        var s: Int32 = 0

        while s < n {
            let next_sample_offset = sample_offset &+ cycles_per_sample
            var delta_t_sample = next_sample_offset >> Self.FIXP_SHIFT

            if delta_t_sample > delta_t {
                delta_t_sample = delta_t
            }

            clock_run_resample(delta_t_sample, sample)

            delta_t &-= delta_t_sample
            if delta_t == 0 {
                sample_offset &-= delta_t_sample << Self.FIXP_SHIFT
                break
            }

            sample_offset = next_sample_offset & Self.FIXP_MASK

            let fir_offset = (sample_offset &* fir_RES) >> Self.FIXP_SHIFT
            let fir_start = UnsafePointer(fir) + Int(fir_offset) * fir_stride
            let sample_start = UnsafePointer(sample) + (Int(sample_index) - fir_N + Int(Self.RINGSIZE))

            // Convolution with filter impulse response.
            var v = Self.convolve(sample_start, fir_start, fir_stride)

            v >>= Self.FIR_SHIFT

            buf[Int(s)] = Self.amplify(v, scaleFactor)
            s += 1
        }

        return s
    }

    // MARK: Verification support

    /// Hands each internal lookup table to `body` as raw bytes, in the same order and layout as the
    /// C++ reference harness prints them, so the two can be compared table by table.
    public func withInternalTables(_ body: (String, UnsafeRawBufferPointer) -> Void) {
        let t = SIDModelTables.tables(for: sid_model)
        let is6581 = sid_model == .mos6581
        let scalars: [Int32] = [
            t.kVddt, t.voice_scale_s14, t.voice_DC, t.ak, t.bk, t.vc_min, t.vc_max, t.filterGain,
            is6581 ? t.n_snake : t.n_param, is6581 ? filter.Vw_bias : filter.nVgt,
            extfilt.w0lp_1_s7, extfilt.w0hp_1_s17,
            cycles_per_sample, fir_N, fir_RES, scaleFactor,
        ]
        scalars.withUnsafeBytes { body("scalars", $0) }
        withUnsafeBytes(of: t.vo_N16) { body("vo_N16", $0) }
        func table<T>(_ name: String, _ pointer: UnsafePointer<T>, _ count: Int) {
            body(name, UnsafeRawBufferPointer(start: pointer, count: count * MemoryLayout<T>.stride))
        }
        table("opamp_rev", t.opamp_rev, 1 << 16)
        table("summer", t.summer, SIDModelTables.summer_size)
        table("gain", t.gain, 16 << 16)
        table("resonance", t.resonance, 16 << 16)
        table("mixer", t.mixer, SIDModelTables.mixer_size)
        table("f0_dac", t.f0_dac, 1 << 11)
        if is6581 {
            table("vcr_kVg", t.vcr_kVg, 1 << 16)
            table("vcr_n_Ids_term", t.vcr_n_Ids_term, 1 << 16)
        }
        table("rnd", filter.rnd.buffer, 1024)
        table("model_wave", t.model_wave, 8 << 12)
        table("wave_dac", t.wave_dac, 1 << 12)
        table("env_dac", t.env_dac, 1 << 8)
        if let fir {
            // In reSID's layout, without the padding between tables.
            var packed = [Int16](repeating: 0, count: Int(fir_N) * Int(fir_RES))
            for i in 0 ..< Int(fir_RES) {
                for j in 0 ..< Int(fir_N) { packed[i * Int(fir_N) + j] = fir[i * Int(fir_stride) + j] }
            }
            packed.withUnsafeBytes { body("fir", $0) }
        }
    }
}
