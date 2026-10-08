// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// This file is part of a Swift port of reSIDfp, a SID emulator engine.
// Copyright 2011-2025 Leandro Nini <drfiemost@users.sourceforge.net>
// Copyright 2007-2010 Antti Lankila
// Copyright 2004 Dag Lem <resid@nimrod.no>
// Copyright 2000-2001 Simon White
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
// MOS 6581 / 8580 SID emulation: a Swift port of reSIDfp as shipped in libsidplayfp 2.16.1, kept
// structurally the same as the C++ so the two can be read side by side. This file is SID.h / SID.cpp,
// with the voice muting of libsidplayfp's sidemu.cpp (the part of the wrapper around reSIDfp that
// changes what the chip is told). The other classes are in ReSIDfpVoice.swift (Voice.h,
// ExternalFilter, Potentiometer), ReSIDfpWaveformGenerator.swift, ReSIDfpWaveformCalculator.swift,
// ReSIDfpEnvelopeGenerator.swift, ReSIDfpFilter.swift (Filter, Filter6581, Filter8580 and the
// integrators), ReSIDfpFilterModelConfig.swift (FilterModelConfig and its two models, OpAmp, Spline,
// Dac) and ReSIDfpResampler.swift (resample/).
//
// The output is bit-identical to the C++ for the same calls, in both sampling methods, when the C++
// is built with -ffp-contract=off and with its table-building threads run one after the other (see
// ReSIDfpFilterModelConfig.swift for why the stock C++ is not even identical to itself).
// Integer types follow the C++; wrapping operators are used wherever the C++ can wrap.
//
// Where the Swift is arranged differently, the result is the same:
// - A chip's model is fixed when it is created, so it has one filter, not reSIDfp's two (ReSIDfpFilter.swift).
// - The DAC tables SID::setChipModel() computes into each SID are computed once per model and shared (ModelTables).
// - The generators' prevVoice / nextVoice pointers are arguments (ReSIDfpWaveformGenerator.swift).
// - Filter::clock() is given the three voices' outputs instead of the voices.
// - The resampler is not a virtual class: each clocking loop is compiled once per model and sampling
//   method (clockCycles, clockQuietCycles). These loops' functions are `@inline(always)`: with
//   `@inline(__always)` the compiler leaves some of them as calls, which costs the specialisation as
//   well as the call.
// - Stretches of cycles in which no envelope can step and no oscillator needs a special case are run by
//   a leaner loop with its state in local variables and the oscillators a cycle ahead of the filter
//   (clockQuietCycles, WaveformGenerator.Quiet, EnvelopeGenerator.clockSteady).
// - clock() takes a limit on the number of samples and stops at it; SID::clock() has none.
// - State that reSIDfp shares between all chips of a model (the dither position, the 6581 filter
//   range) belongs to each chip, so chips do not affect each other (ReSIDfpFilterModelConfig.swift).
//
// Not ported: changing the chip model of an existing chip, SIDError (every argument is acceptable
// here), and the paddle inputs, which reSIDfp does not model either (POTX/POTY read 0xff).

/// reSIDfp's SamplingMethod.
public enum ReSIDfpSampling: Sendable {
    /// DECIMATE: the cycle nearest each sample point, linearly interpolated with the one before it
    /// (ZeroOrderResampler). libsidplayfp calls this "interpolate". Cheap, aliases.
    case decimate
    /// RESAMPLE: two cascaded Kaiser-windowed sinc resamplers (TwoPassSincResampler). libsidplayfp
    /// calls this "resample interpolate"; it is what sidplayfp uses by default.
    case resample
}

/// One SID chip, emulated by a port of reSIDfp. It owns its buffers and frees them when it goes.
///
/// To reproduce what libsidplayfp's ReSIDfp wrapper feeds its mixer (mono, one chip, no gain):
///
///     var sid = ReSIDfpChip(model: model, clockHz: Double(Float(cpuHz)), sampleRate: rate)   // .resample
///     sid.advanceDither(by: 10)               // only for a sample-exact match: see advanceDither
///     sid.setFilter6581Range(0.5); sid.setFilter6581Curve(0.5); sid.setFilter8580Curve(0.5)   // if the front end sets them
///     sid.input(digiBoost && model == .mos8580 ? -32768 : 0)   // ReSIDfp::model()
///     sid.reset(); sid.write(0x18, 0x0f)      // c64sid::reset()
///     // then 8000 * 3 scheduler events' worth of cycles clocked and discarded (Player::initialise): 167833 on PAL
///
/// libsidplayfp gives the engine the CPU clock rounded to single precision, hence `Double(Float(cpuHz))`.
/// Its mixer adds nothing for one chip in mono: the samples are the chip's.
///
/// For speed, hand `clock` as many cycles at a time as there are until the next register write: stretches
/// of cycles are run by a faster loop than single ones.
public struct ReSIDfpChip: ~Copyable {
    /// SID::envDAC and SID::oscDAC, which setChipModel() computes: the same for every chip of a model.
    final class ModelTables: @unchecked Sendable {
        static let mos6581 = ModelTables(.mos6581)
        static let mos8580 = ModelTables(.mos8580)

        static func tables(for model: SIDModel) -> ModelTables {
            model == .mos6581 ? mos6581 : mos8580
        }

        static var ENV_DAC_BITS: Int { 8 }
        static var OSC_DAC_BITS: Int { 12 }

        /// Emulated nonlinearity of the envelope DAC.
        let envDAC: UnsafeMutablePointer<Float> // 256

        /// Emulated nonlinearity of the oscillator DAC.
        let oscDAC: UnsafeMutablePointer<Float> // 4096

        private init(_ model: SIDModel) {
            envDAC = .allocate(capacity: 1 << ModelTables.ENV_DAC_BITS)
            oscDAC = .allocate(capacity: 1 << ModelTables.OSC_DAC_BITS)

            // calculate envelope DAC table
            do {
                var dacBuilder = Dac(ModelTables.ENV_DAC_BITS)
                dacBuilder.kinkedDac(model)

                for i in 0 ..< (1 << ModelTables.ENV_DAC_BITS) {
                    envDAC[i] = Float(dacBuilder.getOutput(UInt32(i)))
                }
            }

            // calculate oscillator DAC table
            let is6581 = model == .mos6581

            do {
                var dacBuilder = Dac(ModelTables.OSC_DAC_BITS)
                dacBuilder.kinkedDac(model)

                // const double offset = dacBuilder.getOutput(is6581 ? OFFSET_6581 : OFFSET_8580);
                let offset = dacBuilder.getOutput(0x7FF, is6581)

                for i in 0 ..< (1 << ModelTables.OSC_DAC_BITS) {
                    let dacValue = dacBuilder.getOutput(UInt32(i), is6581)
                    oscDAC[i] = Float(dacValue - offset)
                }
            }
        }
    }

    /**
     * Bus value stays alive for some time after each operation.
     * Values differs between chip models, the timings used here
     * are taken from VICE [1].
     * See also the discussion "How do I reliably detect 6581/8580 sid?" on CSDb [2].
     *
     *   Results from real C64 (testprogs/SID/bitfade/delayfrq0.prg):
     *
     *   (new SID) (250469/8580R5) (250469/8580R5)
     *   delayfrq0    ~7a000        ~108000
     *
     *   (old SID) (250407/6581)
     *   delayfrq0    ~01d00
     *
     * [1]: http://sourceforge.net/p/vice-emu/patches/99/
     * [2]: http://noname.c64.org/csdb/forums/?roomid=11&topicid=29025&showallposts=1
     */
    static var BUS_TTL_6581: Int32 { 0x01D00 }
    static var BUS_TTL_8580: Int32 { 0xA2000 }

    /// The filter of the chip's model (reSIDfp's `filter`, which points at `filter6581` or `filter8580`).
    var filter: Filter

    /// Resampler used by audio generation code: one of these two, by `sampling`.
    var zeroOrderResampler: ZeroOrderResampler
    var twoPassSincResampler: TwoPassSincResampler
    var sampling: ReSIDfpSampling

    /// External filter that provides high-pass and low-pass filtering
    /// to adjust sound tone slightly.
    var externalFilter = ExternalFilter()

    /// Paddle X register support
    let potX = Potentiometer()

    /// Paddle Y register support
    let potY = Potentiometer()

    /// SID voices (reSIDfp's voice[3])
    var voice0: Voice
    var voice1: Voice
    var voice2: Voice

    /// Used to amplify the output by x/2 to get an adequate playback volume
    var scaleFactor: Int32

    /// Time to live for the last written value
    var busValueTtl: Int32 = 0

    /// Current chip model's bus value TTL
    var modelTTL: Int32

    /// Time until #voiceSync must be run.
    var nextVoiceSync: UInt32 = 0

    /// Currently active chip model.
    let chipModel: SIDModel

    /// Currently selected combined waveforms strength.
    var cws = ReSIDfpCombinedWaveforms.average

    /// Last written value
    var busValue: UInt8 = 0

    /// A number of cycles in which the resampler cannot give more than one sample (see clockCycles).
    var minCyclesPerOutput = 1

    /// libsidplayfp's sidemu::isMuted: flags for muted voices (3 is the volume register's samples).
    var isMuted0 = false
    var isMuted1 = false
    var isMuted2 = false
    var isMuted3 = false

    // ----------------------------------------------------------------------------
    // Constructor.
    // ----------------------------------------------------------------------------

    /// Equivalent to reSIDfp's `SID sid; sid.setChipModel(model); sid.setSamplingParameters(clockHz,
    /// sampling, sampleRate); sid.reset();` in a process that has made no other SID.
    ///
    /// The first chip of each model builds that model's filter tables (14 MB; about 70 ms on an Apple M2,
    /// on four threads); they are shared by later chips and kept for the life of the process. Creating
    /// chips from several threads at once is safe. A chip itself owns about 200 KB (6581) or 60 KB (8580).
    ///
    /// The number of samples per second is not exactly `sampleRate`: reSIDfp's resamplers step by a whole
    /// number of 1024ths of a cycle, rounded down, so they run a little fast. At a PAL clock and 48000 Hz
    /// `.resample` gives 48010.5 samples per second of emulated time and `.decimate` 48001.4.
    ///
    /// If `.resample` cannot work at the given rates (a sample rate so low that the FIR would not fit
    /// reSIDfp's ring buffer, below about 90 Hz on PAL; reSIDfp asserts) the chip uses `.decimate`;
    /// `samplingMethod` tells which is in effect.
    public init(model: SIDModel, clockHz: Double, sampleRate: Double, sampling: ReSIDfpSampling = .resample) {
        chipModel = model
        let is6581 = model == .mos6581

        // SID::SID(): filter6581(new Filter6581()), filter8580(new Filter8580())
        filter = Filter(model: model)

        // setChipModel()
        scaleFactor = is6581 ? 3 : 5
        modelTTL = is6581 ? ReSIDfpChip.BUS_TTL_6581 : ReSIDfpChip.BUS_TTL_8580

        // calculate waveform-related tables
        let wavetables = WaveformCalculator.wftable.rows
        let pulldowntables = WaveformCalculator.buildPulldownTable(model, cws)

        // set voice tables
        let tables = ModelTables.tables(for: model)
        let wave = WaveformGenerator(is6581: is6581, waveformModels: wavetables, pulldownModels: pulldowntables)
        voice0 = Voice(waveformGenerator: wave, wavDAC: UnsafePointer(tables.oscDAC), envDAC: UnsafePointer(tables.envDAC))
        voice1 = voice0
        voice2 = voice0

        // setSamplingParameters()
        externalFilter.setClockFrequency(clockHz)

        zeroOrderResampler = ZeroOrderResampler(clockHz, sampleRate)
        self.sampling = .decimate
        if sampling == .resample {
            let (p1, p2) = TwoPassSincResampler.parameters(clockHz, sampleRate)
            if p1.usable, p2.usable {
                twoPassSincResampler = TwoPassSincResampler(p1, p2)
                self.sampling = .resample
            } else {
                twoPassSincResampler = TwoPassSincResampler()
            }
        } else {
            twoPassSincResampler = TwoPassSincResampler()
        }

        // Between two of a resampler's outputs there are more than cyclesPerSample / 1024 - 2 of its inputs.
        // Only the first pass counts for the two-pass resampler: the second gives at most one sample for
        // each of the first's.
        let cyclesPerSample = self.sampling == .resample ? twoPassSincResampler.s1.cyclesPerSample : zeroOrderResampler.cyclesPerSample
        minCyclesPerOutput = max(1, Int(cyclesPerSample >> 10) - 1)

        reset()
    }

    // The resamplers stay plain values with a `deallocate()` of their own: the clocking loops work on a
    // local copy of them and put it back. The chip is what there is only one of, so it frees them.
    deinit {
        twoPassSincResampler.deallocate()
    }

    /// Get currently emulated chip model.
    public var model: SIDModel { chipModel }

    /// The sampling method in effect.
    public var samplingMethod: ReSIDfpSampling { sampling }

    /// Set filter curve parameter for 6581 model: 0 sets the centre frequency high ("light"), 1 sets it
    /// low ("dark"); the default is 0.5. Does nothing on an 8580.
    ///
    /// Each call draws new dither for the cutoff DAC table, as in reSIDfp.
    public mutating func setFilter6581Curve(_ curve: Double) {
        filter.setFilter6581Curve(curve)
    }

    /// Set filter range parameter for 6581 model: 0 (dark) ... 1 (bright), which sets uCox to
    /// 1e-6 ... 40e-6. A new chip has uCox = 20e-6, which no setting gives exactly: 0.5 is 20.5e-6,
    /// and it is what the sidplayfp front end sets by default. Does nothing on an 8580.
    public mutating func setFilter6581Range(_ range: Double) {
        filter.setFilter6581Range(range)
    }

    /// Set filter curve parameter for 8580 model: 0 sets the centre frequency high ("light"), 1 sets it
    /// low ("dark"); the default is 0.5. Does nothing on a 6581.
    public mutating func setFilter8580Curve(_ curve: Double) {
        filter.setFilter8580Curve(curve)
    }

    /// Enable filter emulation (SID::enableFilter). With the filter disabled no voice is routed through
    /// it, whatever register $17 says.
    public mutating func setFilterEnabled(_ enabled: Bool) {
        filter.enable(enabled)
    }

    /// Set combined waveforms strength (SID::setCombinedWaveforms); a new chip uses `.average`.
    ///
    /// As in reSIDfp a voice goes on using the table it selected until its waveform next changes.
    public mutating func setCombinedWaveforms(_ strength: ReSIDfpCombinedWaveforms) {
        cws = strength

        // rebuild waveform-related tables
        let pulldowntables = WaveformCalculator.buildPulldownTable(chipModel, cws)

        voice0.waveformGenerator.setPulldownModels(pulldowntables)
        voice1.waveformGenerator.setPulldownModels(pulldowntables)
        voice2.waveformGenerator.setPulldownModels(pulldowntables)
    }

    /// Mute or unmute a voice the way libsidplayfp does (sidemu::voice): voices 0...2 by keeping the
    /// waveform and gate bits out of later writes to their control registers, 3 (samples) by forcing
    /// the volume nibble of later writes to register $18 to 15. Nothing changes until the next such write.
    public mutating func setVoiceMuted(_ voice: Int, _ muted: Bool) {
        switch voice {
        case 0: isMuted0 = muted
        case 1: isMuted1 = muted
        case 2: isMuted2 = muted
        case 3: isMuted3 = muted
        default: break
        }
    }

    // ----------------------------------------------------------------------------
    // Calculate the number of cycles according to current parameters
    // that it takes to reach sync.
    //
    // @param sync whether to do the actual voice synchronization
    // ----------------------------------------------------------------------------
    mutating func voiceSync(_ sync: Bool) {
        if sync {
            // Synchronize the 3 waveform generators.
            // WaveformGenerator::synchronize(), for each voice with its prevVoice and nextVoice:
            //
            // A special case occurs when a sync source is synced itself on the same
            // cycle as when its MSB is set high. In this case the destination will
            // not be synced. This has been verified by sampling OSC3.
            if _slowPath(voice0.waveformGenerator.msb_rising), voice1.waveformGenerator.sync,
               !(voice0.waveformGenerator.sync && voice2.waveformGenerator.msb_rising)
            {
                voice1.waveformGenerator.accumulator = 0
            }
            if _slowPath(voice1.waveformGenerator.msb_rising), voice2.waveformGenerator.sync,
               !(voice1.waveformGenerator.sync && voice0.waveformGenerator.msb_rising)
            {
                voice2.waveformGenerator.accumulator = 0
            }
            if _slowPath(voice2.waveformGenerator.msb_rising), voice0.waveformGenerator.sync,
               !(voice2.waveformGenerator.sync && voice1.waveformGenerator.msb_rising)
            {
                voice0.waveformGenerator.accumulator = 0
            }
        }

        // Calculate the time to next voice sync
        nextVoiceSync = UInt32(Int32.max)

        nextVoiceSync = ReSIDfpChip.voiceSyncTime(voice0.waveformGenerator, followingVoiceSync: voice1.waveformGenerator.sync, nextVoiceSync)
        nextVoiceSync = ReSIDfpChip.voiceSyncTime(voice1.waveformGenerator, followingVoiceSync: voice2.waveformGenerator.sync, nextVoiceSync)
        nextVoiceSync = ReSIDfpChip.voiceSyncTime(voice2.waveformGenerator, followingVoiceSync: voice0.waveformGenerator.sync, nextVoiceSync)
    }

    @inline(__always)
    static func voiceSyncTime(_ wave: borrowing WaveformGenerator, followingVoiceSync: Bool, _ nextVoiceSync: UInt32) -> UInt32 {
        let freq = wave.readFreq()

        if wave.readTest() || freq == 0 || !followingVoiceSync {
            return nextVoiceSync
        }

        let accumulator = wave.readAccumulator()
        let thisVoiceSync = ((0x7FFFFF &- accumulator) & 0xFFFFFF) / freq + 1

        return thisVoiceSync < nextVoiceSync ? thisVoiceSync : nextVoiceSync
    }

    // ----------------------------------------------------------------------------
    // SID reset.
    // ----------------------------------------------------------------------------

    /// SID::reset(). libsidplayfp follows it with a write of $0f to register $18 (c64sid::reset()).
    public mutating func reset() {
        voice0.reset()
        voice1.reset()
        voice2.reset()

        filter.reset()
        externalFilter.reset()

        if sampling == .resample {
            twoPassSincResampler.reset()
        } else {
            zeroOrderResampler.reset()
        }

        busValue = 0
        busValueTtl = 0
        voiceSync(false)
    }

    // ----------------------------------------------------------------------------
    // 16-bit input (EXT IN). Write 16-bit sample to audio input. NB! The caller
    // is responsible for keeping the value within 16 bits. Note that to mix in
    // an external audio signal, the signal should be resampled to 1MHz first to
    // avoid sampling noise.
    // ----------------------------------------------------------------------------

    /// EXT IN, a signed 16-bit sample. libsidplayfp's 8580 "digi boost" is `input(-32768)`; it calls
    /// `input(0)` otherwise (ReSIDfp::model()). Each call draws one dither value, as in reSIDfp.
    public mutating func input(_ sample: Int) {
        filter.input(Int16(truncatingIfNeeded: sample))
    }

    /// Moves this chip `count` places along its dither sequence, as if that many dithered values had been
    /// drawn. Only of use for reproducing a particular run of the C++ sample for sample: reSIDfp has one
    /// dither sequence per chip model, shared by every SID in the process, so a SID's output depends on
    /// what the others have drawn. libsidplayfp's front ends create three SIDs whatever the tune needs;
    /// each one that is constructed draws 5 values, and Filter8580::setFilterCurve() 2 more per SID.
    /// For the chip libsidplayfp ends up using (the first one created) that is `advanceDither(by: 10)`
    /// straight after `init`, and `advanceDither(by: 4)` after each `setFilter8580Curve` on an 8580.
    public mutating func advanceDither(by count: Int) {
        filter.rnd_index = Int32(truncatingIfNeeded: (Int(filter.rnd_index) + count) & 0x3FF)
    }

    // ----------------------------------------------------------------------------
    // Read registers.
    //
    // Reading a write only register returns the last char written to any SID register.
    // The individual bits in this value start to fade down towards zero after a few cycles.
    // All bits reach zero within approximately $2000 - $4000 cycles.
    // It has been claimed that this fading happens in an orderly fashion,
    // however sampling of write only registers reveals that this is not the case.
    // NOTE: This is not correctly modeled.
    // The actual use of write only registers has largely been made
    // in the belief that all SID registers are readable.
    // To support this belief the read would have to be done immediately
    // after a write to the same register (remember that an intermediate write
    // to another register would yield that value instead).
    // With this in mind we return the last value written to any SID register
    // for $2000 cycles without modeling the bit fading.
    // ----------------------------------------------------------------------------
    public mutating func read(_ register: Int) -> UInt8 {
        switch register {
        case 0x19: // X value of paddle
            busValue = potX.readPOT()
            busValueTtl = modelTTL

        case 0x1A: // Y value of paddle
            busValue = potY.readPOT()
            busValueTtl = modelTTL

        case 0x1B: // Voice #3 waveform output
            busValue = voice2.waveformGenerator.readOSC()
            busValueTtl = modelTTL

        case 0x1C: // Voice #3 ADSR output
            busValue = voice2.envelopeGenerator.readENV()
            busValueTtl = modelTTL

        default:
            // Reading from a write-only or non-existing register
            // makes the bus discharge faster.
            // Emulate this by halving the residual TTL.
            busValueTtl /= 2
        }

        return busValue
    }

    // ----------------------------------------------------------------------------
    // Write registers.
    // ----------------------------------------------------------------------------

    /// libsidplayfp's sidemu::writeReg() (the muting set with `setVoiceMuted`), then SID::write().
    public mutating func write(_ register: Int, _ value: UInt8) {
        var data = value

        switch register {
        case 0x04:
            // Ignore writes to control register to mute voices
            // Leave test/ring/sync bits untouched
            if _slowPath(isMuted0) { data &= 0x0E }
        case 0x0B:
            if _slowPath(isMuted1) { data &= 0x0E }
        case 0x12:
            if _slowPath(isMuted2) { data &= 0x0E }
        case 0x18:
            // Ignore writes to volume register to mute samples
            // Works only for volume-based digis
            // Trick suggested by LMan
            if _slowPath(isMuted3) { data |= 0x0F }
        default:
            break
        }

        writeRegister(register, data)
    }

    /// SID::write()
    mutating func writeRegister(_ offset: Int, _ value: UInt8) {
        busValue = value
        busValueTtl = modelTTL

        switch offset {
        case 0x00: // Voice #1 frequency (Low-byte)
            voice0.waveformGenerator.writeFREQ_LO(value)

        case 0x01: // Voice #1 frequency (High-byte)
            voice0.waveformGenerator.writeFREQ_HI(value)

        case 0x02: // Voice #1 pulse width (Low-byte)
            voice0.waveformGenerator.writePW_LO(value)

        case 0x03: // Voice #1 pulse width (bits #8-#15)
            voice0.waveformGenerator.writePW_HI(value)

        case 0x04: // Voice #1 control register
            voice0.writeCONTROL_REG(value)

        case 0x05: // Voice #1 Attack and Decay length
            voice0.envelopeGenerator.writeATTACK_DECAY(value)

        case 0x06: // Voice #1 Sustain volume and Release length
            voice0.envelopeGenerator.writeSUSTAIN_RELEASE(value)

        case 0x07: // Voice #2 frequency (Low-byte)
            voice1.waveformGenerator.writeFREQ_LO(value)

        case 0x08: // Voice #2 frequency (High-byte)
            voice1.waveformGenerator.writeFREQ_HI(value)

        case 0x09: // Voice #2 pulse width (Low-byte)
            voice1.waveformGenerator.writePW_LO(value)

        case 0x0A: // Voice #2 pulse width (bits #8-#15)
            voice1.waveformGenerator.writePW_HI(value)

        case 0x0B: // Voice #2 control register
            voice1.writeCONTROL_REG(value)

        case 0x0C: // Voice #2 Attack and Decay length
            voice1.envelopeGenerator.writeATTACK_DECAY(value)

        case 0x0D: // Voice #2 Sustain volume and Release length
            voice1.envelopeGenerator.writeSUSTAIN_RELEASE(value)

        case 0x0E: // Voice #3 frequency (Low-byte)
            voice2.waveformGenerator.writeFREQ_LO(value)

        case 0x0F: // Voice #3 frequency (High-byte)
            voice2.waveformGenerator.writeFREQ_HI(value)

        case 0x10: // Voice #3 pulse width (Low-byte)
            voice2.waveformGenerator.writePW_LO(value)

        case 0x11: // Voice #3 pulse width (bits #8-#15)
            voice2.waveformGenerator.writePW_HI(value)

        case 0x12: // Voice #3 control register
            voice2.writeCONTROL_REG(value)

        case 0x13: // Voice #3 Attack and Decay length
            voice2.envelopeGenerator.writeATTACK_DECAY(value)

        case 0x14: // Voice #3 Sustain volume and Release length
            voice2.envelopeGenerator.writeSUSTAIN_RELEASE(value)

        case 0x15: // Filter cut off frequency (bits #0-#2)
            filter.writeFC_LO(value)

        case 0x16: // Filter cut off frequency (bits #3-#10)
            filter.writeFC_HI(value)

        case 0x17: // Filter control
            filter.writeRES_FILT(value)

        case 0x18: // Volume and filter modes
            filter.writeMODE_VOL(value)

        default:
            break
        }

        // Update voicesync just in case.
        voiceSync(false)
    }

    // ----------------------------------------------------------------------------
    // Age the bus value and zero it if it's TTL has expired.
    //
    // @param n the number of cycles
    // ----------------------------------------------------------------------------
    @inline(__always)
    mutating func ageBusValue(_ n: UInt32) {
        if _fastPath(busValueTtl != 0) {
            busValueTtl = Int32(bitPattern: UInt32(bitPattern: busValueTtl) &- n)

            if _slowPath(busValueTtl <= 0) {
                busValue = 0
                busValueTtl = 0
            }
        }
    }

    // ----------------------------------------------------------------------------
    // Filter::clock(): SID clocking - 1 cycle
    // ----------------------------------------------------------------------------

    /// Filter::clock() from the point where it has the three voices' normalized outputs, and
    /// ExternalFilter::clock(): the last part of the body of the loop in SID::clock().
    @inline(always)
    static func clockFilter(_ V1: Int32, _ V2: Int32, _ V3: Int32, _ filter: inout Filter, _ externalFilter: inout ExternalFilter, is6581: Bool) -> Int32 {
        var Vsum: Int32 = 0
        var Vmix: Int32 = 0

        if filter.filt1 { Vsum &+= V1 } else { Vmix &+= V1 }
        if filter.filt2 { Vsum &+= V2 } else { Vmix &+= V2 }
        if filter.filt3 { Vsum &+= V3 } else { Vmix &+= V3 }
        if filter.filtE { Vsum &+= filter.Ve } else { Vmix &+= filter.Ve }

        filter.Vhp = Int32(filter.currentSummer[Int(Int32(filter.currentResonance[Int(filter.Vbp)]) &+ filter.Vlp &+ Vsum)])

        Vmix &+= is6581 ? filter.solveIntegrators6581() : filter.solveIntegrators8580()

        let sidOutput = Int32(filter.currentVolume[Int(filter.currentMixer[Int(Vmix)])])

        return externalFilter.clock(sidOutput &+ Int32(Int16.min))
    }

    /// One cycle of everything up to the resampler's input: the body of the loop in SID::clock().
    @inline(always)
    static func clockCycle(_ voice0: inout Voice, _ voice1: inout Voice, _ voice2: inout Voice, _ filter: inout Filter,
                           _ externalFilter: inout ExternalFilter, is6581: Bool) -> Int32
    {
        // clock waveform generators
        voice0.waveformGenerator.clock()
        voice1.waveformGenerator.clock()
        voice2.waveformGenerator.clock()

        // clock envelope generators
        voice0.envelopeGenerator.clock()
        voice1.envelopeGenerator.clock()
        voice2.envelopeGenerator.clock()

        // Filter::clock(voice[0], voice[1], voice[2]). Each voice is modulated by the one before it
        // (voice[0] by voice[2]); the three outputs are taken in this order because on the 6581 taking
        // one can clear the top bit of its own accumulator.
        let V1 = filter.getNormalizedVoice(voice0.output(voice2.waveformGenerator.accumulator), voice0.envelopeGenerator.output())
        let V2 = filter.getNormalizedVoice(voice1.output(voice0.waveformGenerator.accumulator), voice1.envelopeGenerator.output())
        // Voice 3 is silenced by voice3off if it is not routed through the filter.
        // If voice 3 is off we still need to clock the waveform generator
        let out3 = voice2.output(voice1.waveformGenerator.accumulator)
        let V3: Int32 = (filter.filt3 || !filter.voice3off) ? filter.getNormalizedVoice(out3, voice2.envelopeGenerator.output()) : 0

        return clockFilter(V1, V2, V3, &filter, &externalFilter, is6581: is6581)
    }

    /// Up to `count` cycles of SID::clock()'s inner loop, stopping early when the buffer is full.
    /// Returns the number of cycles run.
    ///
    /// Most cycles are "quiet": no envelope can step and no oscillator needs any of its special cases. How
    /// long that will last is known in advance (Voice.quietCycles), except for the oscillators' noise clock,
    /// which is watched for. All but the last cycle of such a stretch are run by clockQuietCycles(); every
    /// other cycle is clockCycle().
    @inline(always)
    static func clockCycles(_ chip: inout ReSIDfpChip, _ count: Int, _ buf: UnsafeMutablePointer<Int16>, _ s: inout Int, _ maxSamples: Int,
                            is6581: Bool, resample: Bool) -> Int
    {
        if s >= maxSamples { return 0 }

        let cyclesPerOutput = chip.minCyclesPerOutput
        let position = EnvelopeGenerator.RateCounter.tables.position
        var produced = s
        var i = 0
        while i < count {
            // The stretch clockQuietCycles() may run: one cycle less than the quiet cycles ahead, and no more
            // than can be relied on not to fill the buffer (n cycles make at most 2 + n / cyclesPerOutput samples).
            var stretch = Int(chip.voice0.quietCycles(position))
            let quiet1 = Int(chip.voice1.quietCycles(position)), quiet2 = Int(chip.voice2.quietCycles(position))
            if quiet1 < stretch { stretch = quiet1 }
            if quiet2 < stretch { stretch = quiet2 }
            if count &- i < stretch { stretch = count &- i }
            stretch &-= 1
            let room = (maxSamples &- produced &- 2) &* cyclesPerOutput
            if room < stretch { stretch = room }

            if stretch >= 4 {
                // A function of its own for each model and sampling method.
                if is6581 {
                    i &+= resample ? clockQuietCycles6581Resample(&chip, stretch, buf, &produced, maxSamples)
                        : clockQuietCycles6581Decimate(&chip, stretch, buf, &produced, maxSamples)
                } else {
                    i &+= resample ? clockQuietCycles8580Resample(&chip, stretch, buf, &produced, maxSamples)
                        : clockQuietCycles8580Decimate(&chip, stretch, buf, &produced, maxSamples)
                }
            }

            // One cycle of the general kind. After a quiet stretch there is always one to do (the stretch
            // was cut short by a noise clock, or its last cycle was left over), and the oscillators count on
            // it: see WaveformGenerator.Quiet.
            i &+= 1

            let c64Output = clockCycle(&chip.voice0, &chip.voice1, &chip.voice2, &chip.filter, &chip.externalFilter, is6581: is6581)

            if resample {
                if _slowPath(chip.twoPassSincResampler.input(c64Output)) {
                    buf[produced] = Resampler.getOutput(chip.twoPassSincResampler.output(), chip.scaleFactor)
                    produced &+= 1
                }
            } else {
                if _slowPath(chip.zeroOrderResampler.input(c64Output)) {
                    buf[produced] = Resampler.getOutput(chip.zeroOrderResampler.output(), chip.scaleFactor)
                    produced &+= 1
                }
            }
            if _slowPath(produced == maxSamples) { break }
        }
        s = produced
        return i
    }

    /// Up to `stretch` quiet cycles of SID::clock()'s inner loop: fewer if an oscillator's noise clock comes
    /// up, which ends the stretch before that cycle. Returns the number of cycles run. The caller makes sure
    /// that the stretch is quiet and that the buffer cannot fill up during it.
    ///
    /// The loop does what clockCycle() does, minus everything that cannot happen in a quiet cycle, arranged
    /// for speed:
    /// - What changes from cycle to cycle is in local variables for the duration: three values per oscillator
    ///   (WaveformGenerator.Quiet), the integrators' and the external filter's state, the dither index. A
    ///   local nothing can point to stays in a register; a member of the chip is stored and reloaded around
    ///   every store to the output and ring buffers, and the filter's integrators are one long chain of
    ///   dependent table lookups from each cycle to the next, so a few cycles of latency per member add up.
    /// - The envelopes are left alone until the end (EnvelopeGenerator.clockSteady): their outputs, the
    ///   envelope DAC's and the voices' DC levels are constants.
    /// - The oscillators run one cycle ahead of the filter. The voices' outputs feed the filter's chain; with
    ///   the voices for cycle n+1 computed alongside the filter for cycle n, the two overlap in the processor
    ///   instead of following each other. Neither depends on the other, so the result is the same.
    @inline(always)
    static func clockQuietCycles(_ chip: inout ReSIDfpChip, _ stretch: Int, _ buf: UnsafeMutablePointer<Int16>, _ s: inout Int, _ maxSamples: Int,
                                 is6581: Bool, resample: Bool) -> Int
    {
        var wave0 = WaveformGenerator.Quiet(chip.voice0.waveformGenerator)
        var wave1 = WaveformGenerator.Quiet(chip.voice1.waveformGenerator)
        var wave2 = WaveformGenerator.Quiet(chip.voice2.waveformGenerator)

        // Voice::output(): the envelopes stand still, so the envelope DAC's output and the voices' DC levels do.
        let env0 = Int(chip.voice0.envelopeGenerator.output())
        let env1 = Int(chip.voice1.envelopeGenerator.output())
        let env2 = Int(chip.voice2.envelopeGenerator.output())
        let envDAC0 = chip.voice0.envDAC[env0], envDAC1 = chip.voice1.envDAC[env1], envDAC2 = chip.voice2.envDAC[env2]
        let wavDAC = chip.voice0.wavDAC

        // Filter::getNormalizedVoice()
        let dc0 = chip.filter.voiceDC[env0], dc1 = chip.filter.voiceDC[env1], dc2 = chip.filter.voiceDC[env2]
        let voice_voltage_range = chip.filter.voice_voltage_range
        let N16 = chip.filter.N16
        let vmin = chip.filter.vmin
        let rnd_buffer = chip.filter.rnd_buffer
        var rnd_index = chip.filter.rnd_index

        // Filter::clock()
        let filt1 = chip.filter.filt1, filt2 = chip.filter.filt2, filt3 = chip.filter.filt3, filtE = chip.filter.filtE
        let voice3silent = !(chip.filter.filt3 || !chip.filter.voice3off)
        let lp = chip.filter.lp, bp = chip.filter.bp, hp = chip.filter.hp
        let Ve = chip.filter.Ve
        let currentSummer = chip.filter.currentSummer
        let currentResonance = chip.filter.currentResonance
        let currentMixer = chip.filter.currentMixer
        let currentVolume = chip.filter.currentVolume
        let opamp_rev = chip.filter.opamp_rev
        var Vhp = chip.filter.Vhp
        var Vbp = chip.filter.Vbp
        var Vlp = chip.filter.Vlp

        // Filter6581 / Filter8580: the two integrators.
        let hp6581 = chip.filter.filter6581.hpIntegrator, bp6581 = chip.filter.filter6581.bpIntegrator
        let filter8580 = chip.filter.filter8580
        var hp_vx = is6581 ? hp6581.vx : filter8580.hpIntegrator.vx
        var hp_vc = is6581 ? hp6581.vc : filter8580.hpIntegrator.vc
        var bp_vx = is6581 ? bp6581.vx : filter8580.bpIntegrator.vx
        var bp_vc = is6581 ? bp6581.vc : filter8580.bpIntegrator.vc
        let hp_nVddt_Vw_2 = hp6581.nVddt_Vw_2, bp_nVddt_Vw_2 = bp6581.nVddt_Vw_2
        let hp_nVddt = hp6581.nVddt, bp_nVddt = bp6581.nVddt
        let hp_nVt_nVmin = hp6581.nVt &+ hp6581.nVmin
        let bp_nVt_nVmin = bp6581.nVt &+ bp6581.nVmin
        let n_snake = chip.filter.filter6581.n_snake
        let vcr_nVg = chip.filter.filter6581.vcr_nVg
        let vcr_n_Ids_term = UnsafePointer(chip.filter.filter6581.vcr_n_Ids_term)
        let hp_nVgt = filter8580.hpIntegrator.nVgt, bp_nVgt = filter8580.bpIntegrator.nVgt
        let hp_n_dac = filter8580.hpIntegrator.n_dac, bp_n_dac = filter8580.bpIntegrator.n_dac

        // ExternalFilter
        var ext_Vlp = chip.externalFilter.Vlp
        var ext_Vhp = chip.externalFilter.Vhp
        let w0lp_1_s7 = chip.externalFilter.w0lp_1_s7
        let w0hp_1_s17 = chip.externalFilter.w0hp_1_s17

        var zeroOrderResampler = chip.zeroOrderResampler
        var twoPassSincResampler = chip.twoPassSincResampler
        let scaleFactor = chip.scaleFactor
        var produced = s

        // The voices' normalized outputs for the cycle the filter has not done yet.
        var V1: Int32 = 0, V2: Int32 = 0, V3: Int32 = 0
        var pending = false
        // The number of cycles the oscillators have done, and whether they may do more.
        var done = 0
        var more = true
        while true {
            var next1: Int32 = 0, next2: Int32 = 0, next3: Int32 = 0
            var voices = false
            if more {
                // clock waveform generators
                let accumulator0 = wave0.nextAccumulator()
                let accumulator1 = wave1.nextAccumulator()
                let accumulator2 = wave2.nextAccumulator()

                // Shift noise register once for each time accumulator bit 19 is set high: not here.
                let accumulator_bits_set = (~wave0.accumulator & accumulator0) | (~wave1.accumulator & accumulator1) | (~wave2.accumulator & accumulator2)
                if _slowPath((accumulator_bits_set & 0x080000) != 0) {
                    more = false
                } else {
                    wave0.accumulator = accumulator0
                    wave1.accumulator = accumulator1
                    wave2.accumulator = accumulator2
                    voices = true
                    done &+= 1
                    if done == stretch { more = false }

                    // Voice::output() and Filter::getNormalizedVoice(), with the dither in reSIDfp's order.
                    let out1 = wavDAC[Int(wave0.output(wave2.accumulator))] * envDAC0
                    let out2 = wavDAC[Int(wave1.output(wave0.accumulator))] * envDAC1
                    let out3 = wavDAC[Int(wave2.output(wave1.accumulator))] * envDAC2
                    next1 = Int32(FilterModelConfig.to_ushort_dither(N16 * (Double(out1) * voice_voltage_range + dc0 - vmin), FilterModelConfig.getNoise(&rnd_index, rnd_buffer)))
                    next2 = Int32(FilterModelConfig.to_ushort_dither(N16 * (Double(out2) * voice_voltage_range + dc1 - vmin), FilterModelConfig.getNoise(&rnd_index, rnd_buffer)))
                    if !voice3silent {
                        next3 = Int32(FilterModelConfig.to_ushort_dither(N16 * (Double(out3) * voice_voltage_range + dc2 - vmin), FilterModelConfig.getNoise(&rnd_index, rnd_buffer)))
                    }
                }
            }

            if pending {
                // Filter::clock()
                var Vsum: Int32 = 0
                var Vmix: Int32 = 0

                if filt1 { Vsum &+= V1 } else { Vmix &+= V1 }
                if filt2 { Vsum &+= V2 } else { Vmix &+= V2 }
                if filt3 { Vsum &+= V3 } else { Vmix &+= V3 }
                if filtE { Vsum &+= Ve } else { Vmix &+= Ve }

                Vhp = Int32(currentSummer[Int(Int32(currentResonance[Int(Vbp)]) &+ Vlp &+ Vsum)])

                // solveIntegrators()
                if is6581 {
                    Vbp = Integrator6581.solve(Vhp, &hp_vx, &hp_vc, hp_nVddt_Vw_2, hp_nVddt, hp_nVt_nVmin, n_snake, vcr_nVg, vcr_n_Ids_term, opamp_rev)
                    Vlp = Integrator6581.solve(Vbp, &bp_vx, &bp_vc, bp_nVddt_Vw_2, bp_nVddt, bp_nVt_nVmin, n_snake, vcr_nVg, vcr_n_Ids_term, opamp_rev)
                } else {
                    Vbp = Integrator8580.solve(Vhp, &hp_vx, &hp_vc, hp_nVgt, hp_n_dac, opamp_rev)
                    Vlp = Integrator8580.solve(Vbp, &bp_vx, &bp_vc, bp_nVgt, bp_n_dac, opamp_rev)
                }

                var Vfilt: Int32 = 0
                if lp { Vfilt &+= Vlp }
                if bp { Vfilt &+= Vbp }
                if hp { Vfilt &+= Vhp }
                Vmix &+= is6581 ? Filter.filterGain6581(Vfilt) : Vfilt

                let sidOutput = Int32(currentVolume[Int(currentMixer[Int(Vmix)])])
                let c64Output = ExternalFilter.clock(sidOutput &+ Int32(Int16.min), &ext_Vlp, &ext_Vhp, w0lp_1_s7, w0hp_1_s17)

                if resample {
                    if _slowPath(twoPassSincResampler.input(c64Output)), produced < maxSamples {
                        buf[produced] = Resampler.getOutput(twoPassSincResampler.output(), scaleFactor)
                        produced &+= 1
                    }
                } else {
                    if _slowPath(zeroOrderResampler.input(c64Output)), produced < maxSamples {
                        buf[produced] = Resampler.getOutput(zeroOrderResampler.output(), scaleFactor)
                        produced &+= 1
                    }
                }
            }

            if !voices { break }
            V1 = next1
            V2 = next2
            V3 = next3
            pending = true
        }

        // Put back what has changed.
        let position = EnvelopeGenerator.RateCounter.tables.position
        let sequence = EnvelopeGenerator.RateCounter.tables.sequence
        let cycles = Int32(truncatingIfNeeded: done)
        wave0.finish(&chip.voice0.waveformGenerator, cycles)
        wave1.finish(&chip.voice1.waveformGenerator, cycles)
        wave2.finish(&chip.voice2.waveformGenerator, cycles)
        if cycles > 0 {
            chip.voice0.envelopeGenerator.clockSteady(cycles, position, sequence)
            chip.voice1.envelopeGenerator.clockSteady(cycles, position, sequence)
            chip.voice2.envelopeGenerator.clockSteady(cycles, position, sequence)
        }
        chip.filter.rnd_index = rnd_index
        chip.filter.Vhp = Vhp
        chip.filter.Vbp = Vbp
        chip.filter.Vlp = Vlp
        if is6581 {
            chip.filter.filter6581.hpIntegrator.vx = hp_vx
            chip.filter.filter6581.hpIntegrator.vc = hp_vc
            chip.filter.filter6581.bpIntegrator.vx = bp_vx
            chip.filter.filter6581.bpIntegrator.vc = bp_vc
        } else {
            chip.filter.filter8580.hpIntegrator.vx = hp_vx
            chip.filter.filter8580.hpIntegrator.vc = hp_vc
            chip.filter.filter8580.bpIntegrator.vx = bp_vx
            chip.filter.filter8580.bpIntegrator.vc = bp_vc
        }
        chip.externalFilter.Vlp = ext_Vlp
        chip.externalFilter.Vhp = ext_Vhp
        if resample {
            chip.twoPassSincResampler = twoPassSincResampler
        } else {
            chip.zeroOrderResampler = zeroOrderResampler
        }
        s = produced
        return done
    }

    @inline(never)
    static func clockQuietCycles6581Resample(_ chip: inout ReSIDfpChip, _ stretch: Int, _ buf: UnsafeMutablePointer<Int16>, _ s: inout Int, _ maxSamples: Int) -> Int {
        clockQuietCycles(&chip, stretch, buf, &s, maxSamples, is6581: true, resample: true)
    }

    @inline(never)
    static func clockQuietCycles6581Decimate(_ chip: inout ReSIDfpChip, _ stretch: Int, _ buf: UnsafeMutablePointer<Int16>, _ s: inout Int, _ maxSamples: Int) -> Int {
        clockQuietCycles(&chip, stretch, buf, &s, maxSamples, is6581: true, resample: false)
    }

    @inline(never)
    static func clockQuietCycles8580Resample(_ chip: inout ReSIDfpChip, _ stretch: Int, _ buf: UnsafeMutablePointer<Int16>, _ s: inout Int, _ maxSamples: Int) -> Int {
        clockQuietCycles(&chip, stretch, buf, &s, maxSamples, is6581: false, resample: true)
    }

    @inline(never)
    static func clockQuietCycles8580Decimate(_ chip: inout ReSIDfpChip, _ stretch: Int, _ buf: UnsafeMutablePointer<Int16>, _ s: inout Int, _ maxSamples: Int) -> Int {
        clockQuietCycles(&chip, stretch, buf, &s, maxSamples, is6581: false, resample: false)
    }

    @inline(never)
    static func clockCycles6581Resample(_ chip: inout ReSIDfpChip, _ count: Int, _ buf: UnsafeMutablePointer<Int16>, _ s: inout Int, _ maxSamples: Int) -> Int {
        clockCycles(&chip, count, buf, &s, maxSamples, is6581: true, resample: true)
    }

    @inline(never)
    static func clockCycles6581Decimate(_ chip: inout ReSIDfpChip, _ count: Int, _ buf: UnsafeMutablePointer<Int16>, _ s: inout Int, _ maxSamples: Int) -> Int {
        clockCycles(&chip, count, buf, &s, maxSamples, is6581: true, resample: false)
    }

    @inline(never)
    static func clockCycles8580Resample(_ chip: inout ReSIDfpChip, _ count: Int, _ buf: UnsafeMutablePointer<Int16>, _ s: inout Int, _ maxSamples: Int) -> Int {
        clockCycles(&chip, count, buf, &s, maxSamples, is6581: false, resample: true)
    }

    @inline(never)
    static func clockCycles8580Decimate(_ chip: inout ReSIDfpChip, _ count: Int, _ buf: UnsafeMutablePointer<Int16>, _ s: inout Int, _ maxSamples: Int) -> Int {
        clockCycles(&chip, count, buf, &s, maxSamples, is6581: false, resample: false)
    }

    // ----------------------------------------------------------------------------
    // Clock SID forward using chosen output sampling algorithm.
    //
    // @param cycles c64 clocks to clock
    // @param buf audio output buffer
    // @return number of samples produced
    // ----------------------------------------------------------------------------

    /// Advances by up to `cycles` CPU cycles, writing mono 16-bit samples to `buffer`. It stops early
    /// when `maxSamples` have been written; on return `cycles` holds what was not consumed.
    /// Returns the number of samples written.
    public mutating func clock(_ cycles: inout Int, into buffer: UnsafeMutablePointer<Int16>, maxSamples: Int) -> Int {
        if cycles <= 0 || maxSamples <= 0 { return 0 }

        let is6581 = chipModel == .mos6581
        let resample = sampling == .resample
        var remaining = cycles
        var s = 0

        while remaining != 0 {
            let delta_t = min(Int(nextVoiceSync), remaining)

            if _fastPath(delta_t > 0) {
                let ran: Int = if is6581 {
                    resample ? ReSIDfpChip.clockCycles6581Resample(&self, delta_t, buffer, &s, maxSamples)
                        : ReSIDfpChip.clockCycles6581Decimate(&self, delta_t, buffer, &s, maxSamples)
                } else {
                    resample ? ReSIDfpChip.clockCycles8580Resample(&self, delta_t, buffer, &s, maxSamples)
                        : ReSIDfpChip.clockCycles8580Decimate(&self, delta_t, buffer, &s, maxSamples)
                }

                remaining -= ran
                nextVoiceSync &-= UInt32(truncatingIfNeeded: ran)

                // The buffer is full.
                if ran < delta_t { break }
            }

            if _slowPath(nextVoiceSync == 0) {
                voiceSync(true)
            }
        }

        ageBusValue(UInt32(truncatingIfNeeded: min(cycles - remaining, Int(Int32.max))))
        cycles = remaining
        return s
    }

    // ----------------------------------------------------------------------------
    // Clock SID forward with no audio production.
    //
    // _Warning_:
    // You can't mix this method of clocking with the audio-producing
    // clock() because components that don't affect OSC3/ENV3 are not
    // emulated.
    //
    // @param cycles c64 clocks to clock.
    // ----------------------------------------------------------------------------

    /// SID::clockSilent(): advances by `cycles` with no output, keeping only what OSC3 and ENV3 depend
    /// on up to date. Envelopes 1 and 2, the filter and the resampler stand still, so the sound is not
    /// what it would have been if this is mixed with the other `clock`.
    public mutating func clock(_ cycles: Int) {
        if cycles <= 0 { return }
        var remaining = cycles

        while remaining != 0 {
            let delta_t = min(Int(nextVoiceSync), remaining)

            if delta_t > 0 {
                ReSIDfpChip.clockSilentCycles(&self, delta_t)

                remaining -= delta_t
                nextVoiceSync &-= UInt32(truncatingIfNeeded: delta_t)
            }

            if nextVoiceSync == 0 {
                voiceSync(true)
            }
        }

        ageBusValue(UInt32(truncatingIfNeeded: min(cycles, Int(Int32.max))))
    }

    @inline(never)
    static func clockSilentCycles(_ chip: inout ReSIDfpChip, _ count: Int) {
        var sid = chip
        for _ in 0 ..< count {
            // clock waveform generators (can affect OSC3)
            sid.voice0.waveformGenerator.clock()
            sid.voice1.waveformGenerator.clock()
            sid.voice2.waveformGenerator.clock()

            _ = sid.voice0.waveformGenerator.output(sid.voice2.waveformGenerator.accumulator)
            _ = sid.voice1.waveformGenerator.output(sid.voice0.waveformGenerator.accumulator)
            _ = sid.voice2.waveformGenerator.output(sid.voice1.waveformGenerator.accumulator)

            // clock ENV3 only
            sid.voice2.envelopeGenerator.clock()
        }
        chip = sid
    }

    // MARK: Verification support

    /// Bytes held by the tables every chip of `model` shares, building them if they are not built yet.
    public static func sharedTableBytes(for model: SIDModel) -> Int {
        _ = ModelTables.tables(for: model)
        let common = (4 + 5 * 6) * 4096 * 2 + 1024 * 8 + (256 + 4096) * 4
        return common + (model == .mos6581 ? FilterModelConfig6581.instance.bytes : FilterModelConfig8580.instance.bytes)
    }

    /// Bytes this chip owns.
    public var ownedBytes: Int {
        filter.filter6581.bytes + twoPassSincResampler.s1.bytes + twoPassSincResampler.s2.bytes
    }

    /// Hands each internal lookup table to `body` as raw bytes (or, for a few values, as text), in the
    /// same order and layout as the C++ reference harness prints them, so the two can be compared
    /// table by table.
    public func withInternalTables(_ body: (String, UnsafeRawBufferPointer?, String) -> Void) {
        let is6581 = chipModel == .mos6581
        func table<T>(_ name: String, _ pointer: UnsafePointer<T>, _ count: Int) {
            body(name, UnsafeRawBufferPointer(start: pointer, count: count * MemoryLayout<T>.stride), "")
        }
        let fmc: FilterModelConfig = is6581 ? FilterModelConfig6581.instance : FilterModelConfig8580.instance
        table("rnd", FilterModelConfig.Randomnoise.buffer, 1024)
        body("rnd_index", nil, " \(filter.rnd_index)")
        let scalars: [Double] = [fmc.C, fmc.Vdd, fmc.Vth, fmc.Vddt, filter.uCox, fmc.vmin, fmc.vmax, fmc.denorm, fmc.norm, fmc.N16,
                                 fmc.voice_voltage_range, filter.currFactorCoeff]
        scalars.withUnsafeBytes { body("fmc_scalars", $0, "") }
        table("opamp_rev", fmc.opamp_rev, 1 << 16)
        table("summer", fmc.summer, FilterModelConfig.summer_offset(5))
        table("mixer", fmc.mixer, FilterModelConfig.mixer_offset(8))
        table("volume", fmc.volume, 16 << 16)
        table("resonance", fmc.resonance, 16 << 16)
        if is6581 {
            let f = FilterModelConfig6581.instance
            table("vcr_nVg", f.vcr_nVg, 1 << 16)
            table("vcr_n_Ids_term", f.vcr_n_Ids_term, 1 << 16)
            table("voiceDC", f.voiceDC, 256)
            table("f0_dac", filter.filter6581.f0_dac, 1 << 11)
            let hp = filter.filter6581.hpIntegrator, bp = filter.filter6581.bpIntegrator
            let ints: [Int32] = [hp.nVddt, hp.nVt, hp.nVmin, bp.nVddt, bp.nVt, bp.nVmin, Int32(bitPattern: hp.nVddt_Vw_2), Int32(bitPattern: bp.nVddt_Vw_2),
                                 filter.filter6581.n_snake, filter.Ve]
            body("filter_ints", nil, ints.map { " \($0)" }.joined())
        } else {
            let hp = filter.filter8580.hpIntegrator, bp = filter.filter8580.bpIntegrator
            let ints: [Int32] = [hp.nVgt, hp.n_dac, bp.nVgt, bp.n_dac, filter.Ve]
            body("filter_ints", nil, ints.map { " \($0)" }.joined())
        }
        let tables = ModelTables.tables(for: chipModel)
        table("envDAC", tables.envDAC, 256)
        table("oscDAC", tables.oscDAC, 4096)
        table("wftable", WaveformCalculator.wftable.rows, 4 * 4096)
        table("pulldown_1", WaveformCalculator.buildPulldownTable(chipModel, .average), 5 * 4096)
        table("pulldown_2", WaveformCalculator.buildPulldownTable(chipModel, .weak), 5 * 4096)
        table("pulldown_3", WaveformCalculator.buildPulldownTable(chipModel, .strong), 5 * 4096)
        body("extfilt", nil, " \(externalFilter.w0lp_1_s7) \(externalFilter.w0hp_1_s17)")
        if sampling == .resample {
            func pass(_ k: Int, _ s: borrowing SincResampler) {
                body("sinc\(k)", nil, " firN \(s.firN) firRES \(s.firRES) cyclesPerSample \(s.cyclesPerSample)")
                table("fir\(k)", s.firTable, Int(s.firN) * Int(s.firRES))
            }
            pass(1, twoPassSincResampler.s1)
            pass(2, twoPassSincResampler.s2)
        } else {
            body("zeroorder", nil, " cyclesPerSample \(zeroOrderResampler.cyclesPerSample)")
        }
    }
}
