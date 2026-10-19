// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from it2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md): the "HQ" sound driver of his C port of Impulse Tracker 2.15's replayer, which
// is it2play's own and not one of Impulse Tracker's. The names are the original's, as in the other ports here.
//
// The few lines that are there for an MPTM file, and say so, are derived from OpenMPT, Copyright (c)
// 2004-2026 OpenMPT Project Developers and Contributors and Copyright (c) 1997-2003 Olivier Lapicque,
// used under the BSD 3-Clause licence (see THIRD-PARTY.md, and `IT2OpenMPT.swift`).

/// Two to the power of a `Float`, from the C library. The filter's cutoff is worked out with it, and
/// the libraries do not all round it the same way, so only the library's own gives what the original
/// gets from it.
@_extern(c, "exp2f") private func exp2f(_ x: Float) -> Float

/// it2play's high-quality sound driver: what makes sound of the replayer's voices.
///
/// Up to 256 voices are mixed in floating point. Each is read through an eight-point windowed sinc,
/// from a place kept to 32 bits of fraction, with its volume ramped towards where it is going, and
/// through the resonant filter if it has one. A sample may be stereo. A sample that runs out is not
/// cut off: its last output fades away, as the "WAV writer" driver's does. The filter is clamped and
/// a ping-pong loop turns as in Impulse Tracker's "SB16 MMX" driver.
///
/// A tick is mixed whole into a buffer of the mixer's own (`mixTick`), and taken from it as sixteen
/// bits or as floats (`postMix`).
final class IT2Mixer {
    // Higher is better. 14 is the most there can be for output rates of 32 kHz and above.
    private static let FREQ_MUL_EXTRA_BITS: Int64 = 14

    // A tick's length has 31 bits of fraction: one bit is left free for the test for overflow.
    private static let BPM_FRAC_BITS: UInt64 = 31
    private static let BPM_FRAC_SCALE: UInt32 = 1 << 31
    private static let BPM_FRAC_MASK: UInt32 = BPM_FRAC_SCALE - 1

    // 31 can be had as a file's first tempo, though 32 is the least otherwise.
    private static let MIN_BPM = 31, MAX_BPM = 255

    private static let SINC_WIDTH = 8, SINC_WIDTH_BITS = 3
    private static let SINC_PHASES = 4096

    /// How many bytes of room a sample has before its sound and after it.
    private static let SMP_DAT_OFFSET: Int64 = 8

    /// What a module made by ModPlug Tracker is turned down by, for the number of channels it uses.
    /// (The table is OpenMPT's, normalised.)
    static let PreAmpTable: [Float] = [
        64.0 / 0x60, 64.0 / 0x60, 64.0 / 0x60, 64.0 / 0x70,
        64.0 / 0x80, 64.0 / 0x88, 64.0 / 0x90, 64.0 / 0x98,
        64.0 / 0xA0, 64.0 / 0xA4, 64.0 / 0xA8, 64.0 / 0xAC,
        64.0 / 0xB0, 64.0 / 0xB4, 64.0 / 0xB8, 64.0 / 0xBC,
    ]

    /// The windowed sinc: for each of 4096 places between two samples, the weights of the eight
    /// samples around it. It is the same for every mixer, so it is made once.
    private static let sincKernel = kernel(kaiserBeta: 9.6377, cutoff: 1)
    /// How many places between two samples a table has, and how many weights in all.
    static let phases = SINC_PHASES, kernelLength = SINC_PHASES * SINC_WIDTH

    /// The same, with its cutoff a fraction of the highest a sample can hold.
    static func kernel(kaiserBeta: Double, cutoff: Double) -> [Float] {
        var lut = [Float](repeating: 0, count: IT2Mixer.SINC_PHASES * IT2Mixer.SINC_WIDTH)
        let besselI0BetaMul = 1.0 / IT2Mixer.besselI0(kaiserBeta)
        for i in 0 ..< IT2Mixer.SINC_PHASES * IT2Mixer.SINC_WIDTH {
            let tap = Double((i & (IT2Mixer.SINC_WIDTH - 1)) - ((IT2Mixer.SINC_WIDTH / 2) - 1))
            let x = tap - (Double(i >> IT2Mixer.SINC_WIDTH_BITS) * (1.0 / Double(IT2Mixer.SINC_PHASES)))

            // A Kaiser-Bessel window.
            let n = x * (1.0 / Double(IT2Mixer.SINC_WIDTH / 2))
            let window = IT2Mixer.besselI0(kaiserBeta * (1.0 - n * n).squareRoot()) * besselI0BetaMul

            lut[i] = Float(IT2Mixer.sinc(x * cutoff) * window * cutoff)
        }
        return lut
    }

    /// The zeroth-order modified Bessel function of the first kind, summed as a series.
    private static func besselI0(_ z: Double) -> Double {
        var s = 1.0, ds = 1.0, d = 2.0
        let zz = z * z
        repeat {
            ds *= zz / (d * d)
            s += ds
            d += 2.0
        } while ds > s * 1e-12
        return s
    }

    private static func sinc(_ x: Double) -> Double {
        if x == 0.0 { return 1.0 }
        let y = x * Double.pi
        return sin(y) / y
    }

    /// What of a voice's sample the mixing needs, found once for the voice each tick.
    private struct VoiceSample {
        /// The first frame of its sound, left (or only) and right.
        var Data: UnsafeMutableRawPointer
        var DataR: UnsafeMutableRawPointer?
        /// The first and the last frame that are the sample's own memory, the room either side of its
        /// sound included.
        var lowest: Int64, highest: Int64
    }

    private let sChn: UnsafeMutablePointer<IT2SlaveChannel>
    /// The filter's setting for each channel: 64 cutoffs, then 64 resonances. The replayer's.
    private let FilterParameters: UnsafeMutablePointer<UInt8>
    /// Whether the file is in stereo: in one that is not, every voice is in the middle.
    private let stereoOutput: Bool
    /// True if the two sides are to be heard together, as one. A voice in surround is then mixed as one
    /// in the middle, which is as loud on each side: with one side upside down, as surround has it,
    /// the two would cancel and the voice would not be heard at all. (Not in the original, which mixes
    /// for a mono card without stereo, and so without surround, at all.)
    var heardInMono = false
    /// For an MPTM file that asks for it: see `OpenMPTSong`.
    private let softPanning: Bool
    /// The sample number that stands for a MIDI note on a voice, which has no sound. See `IT2Module`.
    private let midiVoiceSample: UInt8

    // For a file of ModPlug Tracker's or OpenMPT's with plug-ins or FM instruments that are played
    // (see `ModPlugSound`); for any other, nil and false, and the tick is mixed as it always was.
    /// The song's plug-ins, which voices are sent through.
    private var plugIns: OpenMPTPlugIns?
    /// ModPlug's own reverb, for a file that puts channels in it and a mixer whose sound is to be
    /// heard: what the voices sent to it add up to in a tick, the mix's level as the reverb has it,
    /// and whether anything was sent this tick.
    private var reverb: ModPlugReverb?
    private let reverbSend: UnsafeMutablePointer<Float>?
    private let reverbScale: Float
    private var reverbSent = false
    /// The FM chip, which the replayer sets and whose sound is added to the voices'.
    var adLib: OpenMPTAdLib?
    private let adLibLevel: Float
    private let sound: ModPlugSound?
    /// True if the song's volume is left out of each voice and applied to the whole sound instead,
    /// after the plug-ins and the chip, as OpenMPT applies it.
    private let globalVolumeAtMaster: Bool
    /// The song's volume, of 128, as the replayer last had it; and what the sound is at on its way there.
    var GlobalVolume: UInt16 = 128
    private var masterVolume: Float = -1

    private var MixVolume: UInt16 = 0
    private var RealBytesToMix: Int32 = 0, BytesToMix: Int32 = 0
    private let FreqMulVal: Int32
    private var BytesToMixFractional: UInt32 = 0, CurrentFractional: UInt32 = 0, RandSeed: UInt32 = 0x1234_5000
    private let SamplesPerTickInt: UnsafeMutablePointer<UInt32>, SamplesPerTickFrac: UnsafeMutablePointer<UInt32>
    /// What the mixed sound is multiplied by to make sixteen bits of it.
    private(set) var MixGain: Float = 32768.0
    private let fMixBuffer: UnsafeMutablePointer<Float>
    /// How many floats there is room for in it.
    private let mixCapacity: Int
    /// The channels left out of the sound, a bit for each of the 64: see `setMuted`.
    private(set) var mutedChannels: UInt64 = 0
    /// Where the voices of those channels are mixed, to be heard by nobody: as much room as
    /// `fMixBuffer` has. There is none until a channel is left out.
    private var fMutedBuffer: UnsafeMutablePointer<Float>?
    private var fLastClickRemovalLeft: Float = 0, fLastClickRemovalRight: Float = 0, fPrngStateL: Float = 0, fPrngStateR: Float = 0
    /// For the lights: how loud each of the 64 channels is in the tick last mixed, which is told as
    /// it is heard; and the lowest and highest the voice being mixed has had its sample.
    var levels = HeardLevels(voices: 64)
    /// And what each is playing.
    var notes = TickNotes(voices: 64)
    /// And where each channel's note lies between the two sides, from -1 on the left to 1 on the
    /// right: that of the voice it last had hold of.
    private(set) var sides = [Float](repeating: 0, count: 64)
    /// For each channel, whether the voice it has hold of plays a sample, and not an FM instrument:
    /// nil, until it has had hold of one.
    private(set) var sampled = [Bool?](repeating: nil, count: 64)
    private var swing = Swing<Float>(from: -4, to: 4)

    /// Where each channel's sound is kept for its scope, if it is wanted (see `keepWaves`): which of
    /// the waves' voices each of the 64 channels is, less than nought for one not shown.
    private var waves: ChannelWaves?
    private var waveOfChannel = [Int](repeating: -1, count: 64)
    /// While a tick is mixed for the scopes: what one voice adds to the tick, mixed here first and
    /// then added where it goes; each channel's sound in the tick, of all its voices together, one
    /// channel after another; and the FM chip's voices, as each frame of the tick has them.
    private var voiceWave: UnsafeMutablePointer<Float>?
    private var channelWaves: UnsafeMutablePointer<Float>?
    private var chipWaves: UnsafeMutablePointer<Float>?

    // The filter's tables.
    private let QualityFactorTable: UnsafeMutablePointer<Float>
    private let FreqParameterMultiplier: Float, FreqMultiplier: Float
    /// Whose filter the voices have (see `IT2Module.Filter`), and for OpenMPT's: how many steps of
    /// the cutoff make an octave, and the rate the sound is made at.
    private let filter: IT2Module.Filter
    private let ownFilterStep: Float, ownFilterRate: Float

    private let fSincLUT: UnsafeMutablePointer<Float>
    /// For a file of ModPlug Tracker's or OpenMPT's: how its voices are read, as OpenMPT reads them.
    /// Nil for every other, whose voices are all read through the sinc.
    private let resampling: IT2Resampling?
    /// What the voice last mixed last added to each side.
    private var fLastLeftValue: Float = 0, fLastRightValue: Float = 0
    /// How much of what a sample that has ended last put out is lost on each frame after: a 4096th
    /// as the "WAV writer" driver has it, and for an MT2 or an MPTM file, which are played as OpenMPT
    /// plays them, and an IT file of ModPlug Tracker's or OpenMPT's, a 256th as their mixer has it.
    private let endDecay: Float
    /// True for a module of Symphonie's, whose voices that end on their way to a plug-in die away
    /// there as OpenMPT lets them (see `OpenMPTPlugIns.clickDecay`).
    private let symphonie: Bool

    /// Sets a voice's filter as OpenMPT sets its own (`SetupChannelFilter`, where a file does not
    /// ask for Impulse Tracker's): the same kind of filter, of two poles, with half the ring to it
    /// for the same resonance, and a cutoff held between 120 hertz and 20,000.
    /// - Parameters:
    ///   - cutoff: from 0 to 127.
    ///   - envelope: what the filter's envelope is at, of 512.
    @inline(__always)
    private func setOwnFilter(_ sc: UnsafeMutablePointer<IT2SlaveChannel>, cutoff: Int32, envelope: Int32, resonance: UInt8) {
        let damping = QualityFactorTable[Int(min(resonance, 127))]
        let frequency = min(ownFilterRate * 0.5, max(120, min(20000, 110 * exp2f(0.25 + Float(cutoff * envelope) / (ownFilterStep * 512)))))
        let r = frequency * (2 * Float.pi) / ownFilterRate
        let d = (2 * damping - min(2, (1 - 2 * damping) * r)) / r
        let e = 1 / (r * r)
        let a: Float = 1 / (1 + d + e)
        let b: Float = (d + e + e) * a
        sc.pointee.fFiltera = sc.pointee.HighPass ? 1 - a : a
        sc.pointee.fFilterb = b
        sc.pointee.fFilterc = 1 - a - b
    }

    /// Impulse Tracker's filter for a voice of a module of Imago Orpheus's, whose cutoffs are as
    /// OpenMPT has them: from 125 hertz up by six octaves, at their highest by the voice's envelope
    /// for the filter, if it has one (see `IT2Module.Filter.imagoOrpheus`).
    private func setImagoFilter(_ sc: UnsafeMutablePointer<IT2SlaveChannel>, cutoff: Int32, resonance: UInt8) {
        var envelope: Int32 = 512
        if sc.pointee.FilterEnvelope {
            envelope = max(0, min(512, (sc.pointee.PitchEnvState.Value + (32 << 16) + (1 << 12)) >> 13))
        } else if sc.pointee.MIDIBank & 0x00FF != 255 {
            envelope = Int32(sc.pointee.MIDIBank & 0x00FF) * 2
        }
        let p = QualityFactorTable[Int(min(resonance, 127))]
        let frequency = min(ownFilterRate * 0.5, max(120, min(20000, 125 * exp2f(Float(cutoff * envelope) * 6 / (127 * 512)))))
        let r = ownFilterRate / (frequency * 2 * Float.pi)
        let d = (p * r) + (p - 1.0)
        let e = r * r
        let a: Float = 1.0 / (1.0 + d + e)
        let b: Float = (d + e + e) * a
        sc.pointee.fFiltera = a
        sc.pointee.fFilterb = b
        sc.pointee.fFilterc = 1.0 - a - b
    }

    /// - Parameter softPanning: OpenMPT's way of 1.17 of placing a channel: one to a side is no
    ///   louder there than one in the middle. Nil for what the module's own song says, if it has one.
    /// - Parameter reverb: for a file whose channels can be put in ModPlug's reverb, what its sound
    ///   would be, for the level the reverb works at (see `IT2Module.reverb`).
    /// - Parameter resampling: true to read voices as OpenMPT does (see `IT2Resampling`).
    init(module: IT2Module, voices: UnsafeMutablePointer<IT2SlaveChannel>, filterParameters: UnsafeMutablePointer<UInt8>, sound: ModPlugSound? = nil,
         reverb: ModPlugSound? = nil, filter: IT2Module.Filter = .impulseTrackers, softPanning: Bool? = nil, quickEnds: Bool? = nil,
         resampling: Bool = false) {
        self.filter = filter
        globalVolumeAtMaster = sound?.globalVolumeAtMaster ?? false
        sChn = voices
        FilterParameters = filterParameters
        stereoOutput = module.Flags & ITF_STEREO != 0
        self.softPanning = softPanning ?? module.openMPT?.softPanning ?? false
        midiVoiceSample = module.midiVoiceSample

        // HQ_InitDriver. 32769 Hz is the lowest rate there can be, for FreqMulVal to fit in 31 bits.
        let mixingFrequency = max(32769, min(768_000, outputSampleRate))
        FreqMulVal = Int32((Double(UInt64(1) << UInt64(32 + Self.FREQ_MUL_EXTRA_BITS)) / Double(mixingFrequency)).rounded())

        // Room for the longest tick there can be. (An MPTM file's can be longer: see `OpenMPTSong`.)
        let maxSamplesToMix = max(Int(ceil((Double(mixingFrequency) * 2.5) / Double(Self.MIN_BPM))) + 1, module.openMPT?.longestTick ?? 0)
        fMixBuffer = .allocate(capacity: maxSamplesToMix * 2)
        fMixBuffer.initialize(repeating: 0, count: maxSamplesToMix * 2)
        mixCapacity = maxSamplesToMix * 2

        // How long a tick is at each tempo, in frames and a fraction of a frame.
        let tempos = (Self.MAX_BPM - Self.MIN_BPM) + 1
        SamplesPerTickInt = .allocate(capacity: tempos)
        SamplesPerTickFrac = .allocate(capacity: tempos)
        let dMixFreq25 = Double(mixingFrequency) * 2.5
        for bpm in Self.MIN_BPM ... Self.MAX_BPM {
            let dSamplesPerTick = dMixFreq25 / Double(bpm)
            let samplesPerTickFp = UInt64((dSamplesPerTick * Double(Self.BPM_FRAC_SCALE)) + 0.5) // rounded
            let i = bpm - Self.MIN_BPM
            SamplesPerTickInt[i] = UInt32(truncatingIfNeeded: samplesPerTickFp >> Self.BPM_FRAC_BITS)
            SamplesPerTickFrac[i] = UInt32(truncatingIfNeeded: samplesPerTickFp) & Self.BPM_FRAC_MASK
        }

        // (And for a file of ModPlug Tracker's or OpenMPT's, OpenMPT's ways after it.)
        self.resampling = resampling ? IT2Resampling(module) : nil
        let kernel = self.resampling == nil ? Self.sincKernel : Self.sincKernel + Self.openMPTKernels
        fSincLUT = .allocate(capacity: kernel.count)
        for i in 0 ..< kernel.count { fSincLUT[i] = kernel[i] }

        // What the original does once a file is loaded: the mixing volume,
        MixVolume = UInt16(module.MixVolume)

        // the filter's tables (Music_CalculateFilterTables), whose range ModPlug Tracker widened,
        let filterStep = module.Flags & ITF_MPT_EXT_FILTER_RANGE != 0 ? 20.0 : 24.0
        QualityFactorTable = .allocate(capacity: 128)
        for i in 0 ..< 128 {
            QualityFactorTable[i] = Float(pow(10.0, (Double(-i) * (filter == .impulseTrackers ? filterStep : 24.0)) / (128.0 * 20.0)))
        }
        FreqParameterMultiplier = Float(-1.0 / (filterStep * 256.0))
        let exp2Quarter = 0x1.306fe0a31b715p+0 // exp2(0.25)
        FreqMultiplier = Float((1.0 / (2.0 * Double.pi * 110.0 * exp2Quarter)) * Double(mixingFrequency))
        ownFilterStep = Float(filterStep)
        ownFilterRate = Float(mixingFrequency)
        endDecay = quickEnds ?? (module.madTracker || module.openMPT != nil) ? 1.0 / 256.0 : 1.0 / 4096.0
        symphonie = module.playsAsSymphonie

        // and the gain.
        MixGain = Self.mixGain(of: module)

        // (For a file with plug-ins or FM instruments that are played. The plug-ins themselves are
        // made only for a mixer that is to make sound: see `playsPlugIns`.)
        var level = sound?.level ?? 1
        if sound?.levelIsTheMixers == true { level *= MixGain * (1.0 / 32768.0) }
        self.sound = sound.map { known in
            var sound = known
            sound.level = level > 0 ? level : 1
            return sound
        }
        adLibLevel = (sound?.adLibLevel ?? 1) / (level > 0 ? level : 1)
        if let reverb {
            // (OpenMPT's mix is of 32-bit whole numbers, with 27 bits for a sample at its loudest.)
            var level = reverb.level
            if reverb.levelIsTheMixers { level *= MixGain * (1.0 / 32768.0) }
            reverbScale = (level > 0 ? level : 1) * Float(1 << 27)
            reverbSend = .allocate(capacity: mixCapacity)
            reverbSend?.initialize(repeating: 0, count: mixCapacity)
        } else {
            reverbScale = 1
            reverbSend = nil
        }

        // The original has no HQ_FixSamples: nothing is written about the samples' ends until a voice
        // is mixed. What voices have written there is cleared, though, so that a tune starts as it does
        // in a file just loaded however much of it has been played before.
        Self.clearSamplePadding(of: module)
    }

    deinit {
        fMixBuffer.deallocate()
        fMutedBuffer?.deallocate()
        reverbSend?.deallocate()
        SamplesPerTickInt.deallocate()
        SamplesPerTickFrac.deallocate()
        QualityFactorTable.deallocate()
        fSincLUT.deallocate()
        voiceWave?.deallocate()
        channelWaves?.deallocate()
        chipWaves?.deallocate()
    }

    /// Keeps the sound of the channels in `channels` for their scopes, as the voices of `waves` in
    /// that order, from the next tick on: at the output's rate, each as it is before it is put to
    /// one side or the other, its samples' voices and its notes on the FM chip together, and each
    /// at 1 either side of nothing at its loudest. Nil keeps none.
    func keepWaves(in waves: ChannelWaves?, channels: [Int]) {
        self.waves = waves
        waveOfChannel = [Int](repeating: -1, count: 64)
        for (voice, channel) in channels.enumerated() where channel >= 0 && channel < 64 { waveOfChannel[channel] = voice }
        guard waves != nil, voiceWave == nil else { return }
        let frames = mixCapacity / 2
        voiceWave = .allocate(capacity: mixCapacity)
        channelWaves = .allocate(capacity: frames * 64)
        chipWaves = .allocate(capacity: frames * OpenMPTAdLib.voiceCount)
    }

    /// What a voice mixed in `voiceWave` adds to the tick, added where it goes; and what it sounds
    /// like, both sides together as one, as loud as the voice is, added to its channel's scope. The
    /// sides are put together by how the voice was put on them: in the middle in a file that is not
    /// in stereo, upside down on one side in surround, the nearer side as loud as the middle with
    /// soft panning, and otherwise shared between the two.
    private func keepWave(_ sc: IT2SlavePointer, into target: UnsafeMutablePointer<Float>, surround: Bool) {
        guard let voiceWave, let channelWaves else { return }
        let frames = Int(RealBytesToMix)
        for i in 0 ..< frames * 2 { target[i] += voiceWave[i] }
        let channel = Int(sc.pointee.HostChnNum & 63)
        guard waveOfChannel[channel] >= 0 else { return }
        let wave = channelWaves + channel * frames
        // (As loud as the voice is without the song's mixing volume, which the lights leave out too.)
        let back = MixVolume > 0 ? 128 / Float(MixVolume) : 0
        for i in 0 ..< frames {
            let l = voiceWave[i * 2], r = voiceWave[i * 2 + 1]
            let both: Float
            if !stereoOutput {
                both = l
            } else if surround {
                both = l - r
            } else if softPanning {
                both = 2 * (abs(l) >= abs(r) ? l : r)
            } else {
                both = l + r
            }
            wave[i] += both * back
        }
    }

    /// Keeps the tick's scopes, once its voices and the FM chip have been mixed.
    private func storeWaves(_ waves: ChannelWaves) {
        guard let channelWaves else { return }
        let frames = Int(RealBytesToMix)
        for channel in 0 ..< 64 where waveOfChannel[channel] >= 0 {
            let voice = waveOfChannel[channel], wave = channelWaves + channel * frames
            for i in 0 ..< frames { waves.store(voice, at: i, wave[i]) }
        }
        waves.advance(by: frames)
    }

    /// setHQDriverMixGain: a module that came from ModPlug Tracker is turned down by its count of
    /// channels, which is found by looking through its patterns for the highest one used.
    private static func mixGain(of module: IT2Module) -> Float {
        guard (module.Cwtv == 0x0214 && module.Cmwt == 0x0202) || (module.Cwtv == 0x0217 && module.Cmwt == 0x0200) else { return 32768.0 }
        return 32768.0 * PreAmpTable[highestChannel(of: module) / 2]
    }

    /// How much louder than this mixer makes it an IT file that ModPlug Tracker or OpenMPT made is
    /// played: by a pre-amp of more than the header can hold, which is the composer's. One, for
    /// any other file.
    ///
    /// And by OpenMPT's ways of adding channels up only as far as they leave a file of each way
    /// about as loud as any other tune: the tunes of every kind are to be about as loud as each
    /// other, and ModPlug Tracker's own way turns its files down together, by some 8 dB, and the
    /// more the more channels a file has, which measured over the files to hand makes the
    /// few-channel ones louder than the rest and not more like them. So that way is not followed,
    /// and the mixer's own turning down of a file with one of ModPlug Tracker's two signatures, by
    /// its count of channels, which the player it is ported from does, is taken out again too.
    /// The ways of OpenMPT 1.17 are followed, which measured so are as loud as the rest. (Measured
    /// by how loud they are heard, LUFS, a file of ModPlug Tracker's own way comes out 1.4 dB louder
    /// than the rest even so, and is turned down by that.)
    static func modPlugLevel(of module: IT2Module) -> Float {
        guard let levels = module.modPlugLevels else { return 1 }
        var level: Float = levels.mixLevels == 3 ? 2 : levels.mixLevels == 0 ? 0.85 : 1
        if levels.mixLevels == 2 { level = PreAmpTable[max(1, min(31, max(highestChannel(of: module) + 1, levels.channels))) / 2] }
        if module.MixVolume > 0 { level *= Float(levels.preAmp) / Float(module.MixVolume) }
        return level * 32768.0 / mixGain(of: module)
    }

    /// The highest channel that a pattern of the module has anything on, counted from nought, and
    /// no more than 31.
    private static func highestChannel(of module: IT2Module) -> Int {
        var highestChannel = 0
        var maskvar = [UInt8](repeating: 0, count: 128)
        for i in 0 ..< min(Int(module.PatNum), 200) {
            let pattern = module.pattern(i)
            let data = pattern.data
            let rows = Int(pattern.rows)
            // A pattern the file does not have is not looked through. (The module gives what is played in
            // its place, which is told by what is in it.)
            if data.isEmpty || rows == 0 || (rows == 64 && data == IT2Module.EmptyPattern) { continue }

            var p = 0, row = 0
            // (The original trusts a pattern to end where its rows do.)
            while p < data.count {
                let byte = data[p]
                p += 1
                if byte == 0 {
                    row += 1
                    if row >= rows { break }
                } else {
                    let ch = Int((byte &- 1) & 127)
                    if ch > highestChannel { highestChannel = ch }
                    if highestChannel > 31 {
                        highestChannel = 31
                        break
                    }
                    if byte & 0x80 != 0 {
                        maskvar[ch] = p < data.count ? data[p] : 0
                        p += 1
                    }
                    if maskvar[ch] & 1 != 0 { p += 1 }
                    if maskvar[ch] & 2 != 0 { p += 1 }
                    if maskvar[ch] & 4 != 0 { p += 1 }
                    if maskvar[ch] & 8 != 0 { p += 2 }
                }
            }
            if highestChannel >= 31 { break }
        }

        return highestChannel
    }

    /// The room either side of every sample's sound, made nought as it is when a file has just been
    /// loaded. Voices write there (see `fixSamplesLoop`) and some of it stays, and a loop of four
    /// samples or fewer at a sample's edge is played with whatever is there.
    private static func clearSamplePadding(of module: IT2Module) {
        for i in 0 ..< module.sampleLimit {
            guard let s = module.sample(i) else { continue }
            let bytes = Int(s.Length) << (s.Flags & SMPF_16BIT != 0 ? 1 : 0)
            for side in 0 ..< 2 {
                guard let data = side == 0 ? s.Data : s.DataR else { continue }
                for k in 0 ..< Int(SMP_DAT_OFFSET) {
                    data.storeBytes(of: 0, toByteOffset: k - Int(SMP_DAT_OFFSET), as: UInt8.self)
                    data.storeBytes(of: 0, toByteOffset: bytes + k, as: UInt8.self)
                }
            }
        }
    }

    // MARK: Channels left out

    /// Leaves channels out of the sound, or brings them back: a bit for each of the 64, set for one
    /// that is not to be heard. See `Renderer.setMuted`.
    ///
    /// A channel is all the voices that are its: the note it has hold of, the notes before that
    /// which it has let go and which are still dying away, and its note on the FM chip. Each is
    /// left out where it would be added to the others, and to what is sent to a plug-in: so a
    /// plug-in is given nothing of a channel that is left out, and one that is on the whole sound
    /// has what is left of it. A voice left out is mixed all the same, into a buffer that nobody
    /// hears, so that it goes on exactly as it would if it were heard: its place in its sample, its
    /// ramp, its filter, where it ends, and how loud it is said to be.
    func setMuted(channels: UInt64) {
        mutedChannels = channels
        if channels != 0, fMutedBuffer == nil {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: mixCapacity)
            buffer.initialize(repeating: 0, count: mixCapacity)
            fMutedBuffer = buffer
        }
    }

    // MARK: Plug-ins

    /// Makes the song's plug-ins, for a mixer whose sound is to be heard: one that only finds how
    /// long a tune is has no use for them.
    func playsPlugIns() {
        if plugIns == nil, let sound {
            plugIns = OpenMPTPlugIns(sound)
            if symphonie { plugIns?.clickDecay = 1.0 / 256.0 }
        }
        if reverb == nil, reverbSend != nil { reverb = ModPlugReverb(sampleRate: outputSampleRate) }
    }

    /// Sets one of the settings of the plug-in in a place, counted from nought, while the tune
    /// plays; `slide` if it is to be moved by so much from where it is. Nothing is done without the plug-in.
    func setPlugInParameter(place: Int, _ index: Int, _ value: Float, slide: Bool = false) {
        guard let plugIns else { return }
        plugIns.setParameter(place: place, index, slide ? plugIns.parameter(place: place, index) + value : value)
    }

    func plugInParameter(place: Int, _ index: Int) -> Float {
        plugIns?.parameter(place: place, index) ?? 0
    }

    func plugInDryRatio(place: Int) -> Float {
        plugIns?.dryRatio(place: place) ?? 0
    }

    func setPlugInDryRatio(place: Int, _ ratio: Float) {
        plugIns?.setDryRatio(place: place, ratio)
    }

    // MARK: What the replayer asks

    /// HQ_SetTempo
    func setTempo(_ tempo: UInt8) {
        let index = Int(max(tempo, UInt8(Self.MIN_BPM))) - Self.MIN_BPM
        BytesToMix = Int32(bitPattern: SamplesPerTickInt[index])
        BytesToMixFractional = SamplesPerTickFrac[index]
    }

    /// A tick of so many frames and no fraction of one, whatever the tempo: for an MPTM file, whose
    /// ticks are measured in OpenMPT's ways and told to the mixer one by one.
    func setTickFrames(_ frames: Int32) {
        BytesToMix = frames
        BytesToMixFractional = 0
    }

    /// The tempo the song is at, in ten-thousandths of a beat a minute, for an MPTM file's
    /// instruments that keep their pitch to it (see `IT2Instrument.TempoLock`).
    private var musicTempo: UInt64 = 0
    private var musicTempoChanged = false
    func setMusicTempo(_ tempo: UInt64) {
        guard tempo != musicTempo else { return }
        musicTempo = tempo
        musicTempoChanged = true
    }

    /// HQ_SetMixVolume
    func setMixVolume(_ volume: UInt8) {
        MixVolume = UInt16(volume)
        // RecalculateAllVolumes
        for i in 0 ..< MAX_SLAVE_CHANNELS { sChn[i].Flags |= SF_RECALC_PAN | SF_RECALC_VOL }
    }

    /// HQ_ResetMixer
    func resetMixer() {
        CurrentFractional = 0
        RandSeed = 0x1234_5000
        fLastClickRemovalLeft = 0
        fLastClickRemovalRight = 0
        fPrngStateL = 0
        fPrngStateR = 0
    }

    /// After the replayer's `Update`: mixes one tick of sound into the mixer's own buffer.
    /// Returns how many stereo frames the tick is.
    func mixTick() -> Int {
        HQ_MixSamples(silent: false)
        return Int(RealBytesToMix)
    }

    /// A tick with no sound made of it, for finding how long a tune is: the voices are moved on and
    /// end as they would, and the tick is as long as it would be. Nothing is left to take with `postMix`.
    func skipTick() -> Int {
        HQ_MixSamples(silent: true)
        let frames = Int(RealBytesToMix)
        RealBytesToMix = 0
        return frames
    }

    // MARK: Taking what was mixed

    /// The tick just mixed, as the original's HQ_PostMix writes it: sixteen bits, left and right in
    /// turn, each with a dither of two random numbers' difference. `count` frames from frame `from`
    /// of the tick. The random numbers go on from frame to frame, so the frames of a tune are to be
    /// taken in order and once.
    func postMix(into output: UnsafeMutablePointer<Int16>, from: Int, count: Int) {
        guard from >= 0 else { return }
        let SamplesTodo = min(count, Int(RealBytesToMix) - from)
        guard SamplesTodo > 0 else { return }

        var fMixBufPtr = UnsafePointer(fMixBuffer) + from * 2
        var AudioOut16 = output
        let MixGain = MixGain
        var RandSeed = RandSeed, fPrngStateL = fPrngStateL, fPrngStateR = fPrngStateR
        for _ in 0 ..< SamplesTodo {
            // Left: the random numbers are between -0.5 and 0.5.
            RandSeed = (RandSeed &* 134_775_813) &+ 1
            var fPrng = Float(Int32(bitPattern: RandSeed)) * (0.5 / 2_147_483_648.0)
            var fOut = fMixBufPtr[0] * MixGain
            fOut = (fOut + fPrng) - fPrngStateL
            fPrngStateL = fPrng
            AudioOut16[0] = Self.clamp16(fOut)

            // Right.
            RandSeed = (RandSeed &* 134_775_813) &+ 1
            fPrng = Float(Int32(bitPattern: RandSeed)) * (0.5 / 2_147_483_648.0)
            fOut = fMixBufPtr[1] * MixGain
            fOut = (fOut + fPrng) - fPrngStateR
            fPrngStateR = fPrng
            AudioOut16[1] = Self.clamp16(fOut)

            fMixBufPtr += 2
            AudioOut16 += 2
        }
        self.RandSeed = RandSeed
        self.fPrngStateL = fPrngStateL
        self.fPrngStateR = fPrngStateR
    }

    /// A float cut to a whole number towards nothing and held to sixteen bits.
    @inline(__always)
    private static func clamp16(_ fOut: Float) -> Int16 {
        if fOut >= 32767.0 { return 32767 }
        if fOut <= -32768.0 { return -32768 }
        if fOut != fOut { return 0 } // not a number
        return Int16(truncatingIfNeeded: Int32(fOut))
    }

    /// The same frames at the same gain as floats, where 1.0 is the most sixteen bits can hold:
    /// with no dither, not rounded and not held to that. For listening. It leaves the dither's
    /// random numbers where they were.
    func postMix(into output: UnsafeMutablePointer<Float>, from: Int, count: Int) {
        guard from >= 0 else { return }
        let SamplesTodo = min(count, Int(RealBytesToMix) - from)
        guard SamplesTodo > 0 else { return }

        let fMixBufPtr = UnsafePointer(fMixBuffer) + from * 2
        let MixGain = MixGain
        for i in 0 ..< SamplesTodo * 2 {
            output[i] = (fMixBufPtr[i] * MixGain) * (1.0 / 32768.0)
        }
    }

    // MARK: Mixing a tick

    private func HQ_MixSamples(silent: Bool) {
        RealBytesToMix = BytesToMix

        CurrentFractional &+= BytesToMixFractional
        if CurrentFractional >= Self.BPM_FRAC_SCALE {
            CurrentFractional &= Self.BPM_FRAC_MASK
            RealBytesToMix += 1
        }

        let fMixBuffer = fMixBuffer
        if !silent {
            // The buffer starts not from silence but from what is left of the voices that have
            // ended, dying away, so that their ending makes no click.
            var fMixBufPtr = fMixBuffer
            var left = fLastClickRemovalLeft, right = fLastClickRemovalRight
            for _ in 0 ..< RealBytesToMix {
                fMixBufPtr[0] = left
                fMixBufPtr[1] = right
                fMixBufPtr += 2
                left -= left * endDecay
                right -= right * endDecay
            }
            fLastClickRemovalLeft = left
            fLastClickRemovalRight = right
        }

        if !silent {
            for channel in 0 ..< 64 {
                levels.now[channel] = 0
                levels.until[channel] = 0
                notes.pitches[channel] = 0
            }
            plugIns?.begin(frames: Int(RealBytesToMix))
            if reverb != nil, let reverbSend {
                reverbSend.update(repeating: 0, count: Int(RealBytesToMix) * 2)
                reverbSent = false
            }
            // (What the voices that are left out add up to is thrown away tick by tick.)
            if mutedChannels != 0 { fMutedBuffer?.update(repeating: 0, count: Int(RealBytesToMix) * 2) }
        }
        let waves = silent ? nil : waves
        if waves != nil { channelWaves?.update(repeating: 0, count: Int(RealBytesToMix) * 64) }
        defer { musicTempoChanged = false }

        for i in 0 ..< MAX_SLAVE_CHANNELS {
            let sc = sChn + i
            if sc.pointee.Flags & SF_CHAN_ON == 0 || sc.pointee.Smp == midiVoiceSample { continue }
            swing.clear()
            if !silent {
                // A note is struck where a voice is new; a channel's pitch is that of the voice it
                // still has hold of, and not of the ones it has let go to die away.
                let channel = Int(sc.pointee.HostChnNum & 63)
                if sc.pointee.Flags & SF_NEW_NOTE != 0 { notes.struck[channel] = true }
                if sc.pointee.HostChnNum & CHN_DISOWNED == 0 {
                    // (Surround is on both sides alike.)
                    sides[channel] = !stereoOutput || sc.pointee.FinalPan == PAN_SURROUND ? 0 : max(-1, min(1, (Float(sc.pointee.FinalPan) - 32) / 32))
                    sampled[channel] = sc.pointee.SmpPtr?.AdLib == nil
                }
                if sc.pointee.HostChnNum & CHN_DISOWNED == 0, sc.pointee.Frequency > 0 {
                    notes.pitches[channel] = ChannelPitch.note(ofRate: Double(sc.pointee.Frequency))
                    // (A note for the FM chip may have its rate kept finer: see `OpenMPTAdLib.fineShift`.)
                    if let adLib, adLib.fine, sc.pointee.SmpPtr?.AdLib != nil {
                        notes.pitches[channel] = ChannelPitch.note(ofRate: Double(sc.pointee.Frequency) / Double(1 << OpenMPTAdLib.fineShift))
                    }
                }
            }
            // How many of the tick's frames the voice sounded for: all of them, unless its sample ends
            // or it is on its way to silence, which its volume comes within a hundredth of in 300.
            var sounded = Int(RealBytesToMix)
            // A channel is the loudest of its voices: its note, and those before it still dying away.
            defer {
                if swing.moved {
                    let channel = Int(sc.pointee.HostChnNum & 63)
                    let level = min(1, (swing.high - swing.low) * 0.5 * Float(sc.pointee.FinalVol32768) * (1.0 / 32768.0))
                    if level > levels.now[channel] { levels.now[channel] = level }
                    if level > 0 { levels.until[channel] = max(levels.until[channel], sounded) }
                }
            }

            if sc.pointee.Flags & SF_NOTE_STOP != 0 { // the note is cut: it is ramped out over this tick
                sc.pointee.Flags &= ~SF_CHAN_ON

                sc.pointee.FinalVol32768 = 0
                sc.pointee.VolNoGlobal = 0
                sc.pointee.Flags |= SF_UPDATE_MIXERVOL
            }

            // (A note of an instrument tied to the tempo has its pitch again when the tempo moves.)
            let tempoLock = musicTempo > 0 ? sc.pointee.InsPtr?.TempoLock ?? 0 : 0
            if sc.pointee.Flags & SF_FREQ_CHANGE != 0 || (tempoLock != 0 && musicTempoChanged) {
                // Not a limit of Impulse Tracker's, but needed for safety.
                if UInt32(bitPattern: sc.pointee.Frequency) >= UInt32(Int32.max / 2) {
                    sc.pointee.Flags = SF_NOTE_STOP
                    if sc.pointee.HostChnNum & CHN_DISOWNED == 0 {
                        sc.pointee.HostChnPtr?.pointee.Flags &= ~HF_CHAN_ON // its channel is turned off
                    }
                    continue
                }

                // How far through the sample one frame of output goes, with 32 bits of fraction. For
                // an instrument tied to the tempo, as much higher as the song is faster than its tempo.
                var frequency = Int64(sc.pointee.Frequency)
                if tempoLock != 0 {
                    frequency = min(Int64(Int32.max), (frequency * Int64(musicTempo) + Int64(tempoLock / 2)) / Int64(tempoLock))
                }
                sc.pointee.Delta64 = UInt64(bitPattern: (frequency &* Int64(FreqMulVal)) >> Self.FREQ_MUL_EXTRA_BITS)
            }

            if sc.pointee.Flags & SF_NEW_NOTE != 0 {
                sc.pointee.fOldLeftVolume = 0
                sc.pointee.fOldRightVolume = 0

                // The voice is ramped in. (The note before it is ramped out in another voice.)
                sc.pointee.fCurrVolL = 0
                sc.pointee.fCurrVolR = 0

                // The filter starts afresh, and open.
                sc.pointee.fOldSamples = (0, 0, 0, 0)
                sc.pointee.fFiltera = 1.0
                sc.pointee.fFilterb = 0
                sc.pointee.fFilterc = 0
            }

            if sc.pointee.Flags & (SF_UPDATE_MIXERVOL | SF_LOOP_CHANGED | SF_PAN_CHANGED) != 0 {
                let FilterQ: UInt8
                if sc.pointee.HostChnNum & CHN_DISOWNED != 0 {
                    FilterQ = UInt8(truncatingIfNeeded: sc.pointee.MIDIBank >> 8) // a voice nobody owns keeps the filter it had
                } else {
                    let filterCutOff = FilterParameters[Int(sc.pointee.HostChnNum)]
                    FilterQ = FilterParameters[(64 + Int(sc.pointee.HostChnNum)) & 127]

                    // The channel's filter is kept in the voice, in the high bytes of two things it does not otherwise use.
                    sc.pointee.VolEnvState.CurNode = Int16(truncatingIfNeeded: (Int32(filterCutOff) << 8) | (Int32(sc.pointee.VolEnvState.CurNode) & 0x00FF))
                    sc.pointee.MIDIBank = (UInt16(FilterQ) << 8) | (sc.pointee.MIDIBank & 0x00FF)
                }

                // What the filter's envelope is at (0 to 255) by the cutoff (0 to 127).
                let cutoff = Int32(UInt16(bitPattern: sc.pointee.VolEnvState.CurNode) >> 8)
                let FilterFreqValue = UInt16(truncatingIfNeeded: Int32(sc.pointee.MIDIBank & 0x00FF) &* cutoff)
                if filter == .imagoOrpheus {
                    if FilterFreqValue != 127 * 255 || FilterQ != 0 { setImagoFilter(sc, cutoff: cutoff, resonance: FilterQ) }
                } else if filter != .impulseTrackers {
                    // OpenMPT's own: on by Impulse Tracker's rule, or by its own, which is that a
                    // note starts with it if its cutoff is below the top, that a macro or an
                    // envelope that sets it puts it on, and that once on it stays on.
                    let on: Bool
                    if filter == .openMPTsCurve {
                        on = FilterFreqValue != 127 * 255 || FilterQ != 0
                    } else {
                        if sc.pointee.Flags & SF_NEW_NOTE != 0 { sc.pointee.FilterOn = sc.pointee.FilterFromStart }
                        if sc.pointee.FilterSet { sc.pointee.FilterOn = true }
                        on = sc.pointee.FilterOn
                    }
                    if on {
                        // The envelope is at so much of 512, which is finer than Impulse Tracker
                        // has it; with none, at all of it.
                        var envelope: Int32 = 512
                        if sc.pointee.FilterEnvelope {
                            envelope = max(0, min(512, (sc.pointee.PitchEnvState.Value + (32 << 16) + (1 << 12)) >> 13))
                        } else if filter == .openMPTsCurve, sc.pointee.MIDIBank & 0x00FF != 255 {
                            envelope = Int32(sc.pointee.MIDIBank & 0x00FF) * 2
                        }
                        setOwnFilter(sc, cutoff: cutoff, envelope: envelope, resonance: FilterQ)
                    }
                } else if FilterFreqValue != 127 * 255 || FilterQ != 0 {
                    let r = exp2f(Float(FilterFreqValue) * FreqParameterMultiplier) * FreqMultiplier
                    // (A resonance above 127 would have the original read past its table.)
                    let p = QualityFactorTable[Int(min(FilterQ, 127))]
                    let d = (p * r) + (p - 1.0)
                    let e = r * r

                    let fFiltera: Float = 1.0 / (1.0 + d + e)
                    let fFilterb: Float = (d + e + e) * fFiltera
                    sc.pointee.fFiltera = fFiltera
                    sc.pointee.fFilterb = fFilterb
                    sc.pointee.fFilterc = 1.0 - fFiltera - fFilterb
                    // (An MPTM file's instrument can have the filter the other way up: see `mixLoop`.)
                    if sc.pointee.HighPass { sc.pointee.fFiltera = 1.0 - fFiltera }
                }

                if sc.pointee.Flags & SF_CHN_MUTED != 0 {
                    sc.pointee.fLeftVolume = 0
                    sc.pointee.fRightVolume = 0
                } else {
                    let Vol = Int32(globalVolumeAtMaster ? sc.pointee.VolNoGlobal : sc.pointee.FinalVol32768) &* Int32(MixVolume)
                    if !stereoOutput {
                        let volume = Float(Vol) * (1.0 / (32768.0 * 128.0))
                        sc.pointee.fLeftVolume = volume
                        sc.pointee.fRightVolume = volume
                    } else if sc.pointee.FinalPan == PAN_SURROUND {
                        let volume = Float(Vol) * (0.5 / (32768.0 * 128.0))
                        sc.pointee.fLeftVolume = volume
                        sc.pointee.fRightVolume = volume
                    } else if softPanning { // the nearer side as loud as the middle, the further one quieter
                        let FinalPan = Int32(sc.pointee.FinalPan)
                        sc.pointee.fLeftVolume = Float(min(32, 64 &- FinalPan) &* Vol) * (1.0 / (64.0 * 32768.0 * 128.0))
                        sc.pointee.fRightVolume = Float(min(32, FinalPan) &* Vol) * (1.0 / (64.0 * 32768.0 * 128.0))
                    } else { // somewhere between the speakers
                        let FinalPan = Int32(sc.pointee.FinalPan)
                        sc.pointee.fLeftVolume = Float((64 &- FinalPan) &* Vol) * (1.0 / (64.0 * 32768.0 * 128.0))
                        sc.pointee.fRightVolume = Float(FinalPan &* Vol) * (1.0 / (64.0 * 32768.0 * 128.0))
                    }
                }
            }

            // Just in case: it should not happen. (The voice's flags are left as they are.)
            if sc.pointee.Delta64 == 0 { continue }
            // A voice whose sample is stopped where it is is not mixed, and does not move on; and if
            // it is cut meanwhile, it ends there. (Only a module of Symphonie's stops one.) What it
            // last put out dies away; and when it goes on again it is ramped in from silence, as
            // OpenMPT's is, whose volume for a stopped voice is nothing from the next row on.
            if sc.pointee.Paused {
                sounded = 0
                if !silent { dieAway(sc) }
                sc.pointee.LastOutLeft = 0
                sc.pointee.LastOutRight = 0
                sc.pointee.fCurrVolL = 0
                sc.pointee.fCurrVolR = 0
                sc.pointee.fOldLeftVolume = 0
                sc.pointee.fOldRightVolume = 0
                sc.pointee.Flags &= ~(SF_RECALC_PAN | SF_RECALC_VOL | SF_FREQ_CHANGE | SF_UPDATE_MIXERVOL | SF_NEW_NOTE | SF_NOTE_STOP | SF_LOOP_CHANGED | SF_PAN_CHANGED)
                continue
            }

            var MixBlockSize = UInt32(bitPattern: RealBytesToMix)
            let FilterActive = sc.pointee.fFilterb > 0 || sc.pointee.fFilterc > 0
            let LoopLength = UInt32(bitPattern: sc.pointee.LoopEnd &- sc.pointee.LoopBegin) // the length, for one that does not loop

            // (A sample the file gives a length but no sound, which the original would read from nowhere, is silent.)
            let s = sc.pointee.SmpPtr
            sc.pointee.LastOutLeft = 0
            sc.pointee.LastOutRight = 0
            if silent || s?.Data == nil || (sc.pointee.fLeftVolume == 0 && sc.pointee.fRightVolume == 0
                && sc.pointee.fOldLeftVolume <= 0.000001 && sc.pointee.fOldRightVolume <= 0.000001 && !FilterActive) {
                // Silent, and with no filter to keep going: only its place in the sample is moved on.
                if Int32(bitPattern: LoopLength) > 0 {
                    if sc.pointee.LoopMode == LOOP_PINGPONG {
                        UpdatePingPongLoopHQ(sc, MixBlockSize)
                    } else if sc.pointee.LoopMode == LOOP_FORWARDS {
                        UpdateForwardsLoopHQ(sc, MixBlockSize)
                    } else {
                        UpdateNoLoopHQ(sc, MixBlockSize)
                    }
                }
            } else {
                let Surround = sc.pointee.FinalPan == PAN_SURROUND && !heardInMono
                if sc.pointee.fLeftVolume == 0, sc.pointee.fRightVolume == 0 { sounded = min(sounded, 300) }
                // A voice of a channel that is left out is added to nothing that is heard: see `setMuted`.
                let muted = (mutedChannels >> UInt64(sc.pointee.HostChnNum & 63)) & 1 != 0
                // Where its sound is added: to the tick, or for a song with plug-ins to what is
                // sent to the plug-in of the voice's instrument, or failing that of its channel.
                var place = -1
                if let plugIns, !muted {
                    let ofInstrument = sc.pointee.Ins != 0xFF ? Int(sc.pointee.InsPtr?.MixPlug ?? 0) : 0
                    place = plugIns.place(instrumentPlugIn: ofInstrument, channel: Int(sc.pointee.HostChnNum & 63))
                    plugIns.voiceMixed()
                }
                // (Or to what is sent to the reverb, for a voice put in it, unless it goes to a plug-in.)
                let reverbed = place < 0 && !muted && sc.pointee.Reverb && reverb != nil
                if reverbed { reverbSent = true }

                if Int32(bitPattern: LoopLength) > 0, let s, let Data = s.Data {
                    // Where the sample's memory begins and ends, at the width the voice reads it at.
                    let shift: Int64 = sc.pointee.SmpIs16Bit ? 1 : 0
                    let bytes = Int64(s.Length) << (s.Flags & SMPF_16BIT != 0 ? 1 : 0)
                    let v = VoiceSample(Data: Data, DataR: s.DataR,
                                        lowest: -(Self.SMP_DAT_OFFSET >> shift), highest: ((bytes + Self.SMP_DAT_OFFSET) >> shift) - 1)
                    let Stereo = s.Flags & SMPF_STEREO != 0 && s.DataR != nil
                    // Which of the sixteen mixing routines: see `Mix`.
                    let kind = (FilterActive ? 8 : 0) + (Stereo ? 4 : 0) + (Surround ? 2 : 0) + (sc.pointee.SmpIs16Bit ? 1 : 0)
                    let Delta64 = sc.pointee.Delta64

                    var fMixBufferPtr = fMixBuffer
                    if place >= 0, let plugIns { fMixBufferPtr = plugIns.buffer(ofPlace: place) }
                    if reverbed, let reverbSend { fMixBufferPtr = reverbSend }
                    if muted, let fMutedBuffer { fMixBufferPtr = fMutedBuffer }
                    // For the scopes, the voice is mixed on its own first, and then added where it
                    // goes. (Into nothing less than nought, which anything added to leaves as it is,
                    // so that what is added there afterwards is the same to the last bit.)
                    let target = fMixBufferPtr
                    if waves != nil, let voiceWave {
                        voiceWave.update(repeating: -0.0, count: Int(RealBytesToMix) * 2)
                        fMixBufferPtr = voiceWave
                    }
                    defer { if waves != nil { keepWave(sc, into: target, surround: Surround) } }
                    if sc.pointee.LoopMode == LOOP_PINGPONG {
                        while MixBlockSize > 0 {
                            // How many frames until the end of the loop it is heading for.
                            var SamplesToMix: UInt32
                            let Delta: Int64
                            if sc.pointee.LoopDirection == DIR_BACKWARDS {
                                if sc.pointee.SamplingPosition == sc.pointee.LoopBegin {
                                    sc.pointee.LoopDirection = DIR_FORWARDS
                                    sc.pointee.Frac64 = UInt64(UInt32(truncatingIfNeeded: 0 &- sc.pointee.Frac64))
                                    SamplesToMix = Self.framesWithin((sc.pointee.LoopEnd &- 1) &- sc.pointee.SamplingPosition,
                                                                     UInt32(truncatingIfNeeded: sc.pointee.Frac64) ^ UInt32.max, Delta64)
                                    Delta = Int64(bitPattern: Delta64)
                                } else {
                                    SamplesToMix = Self.framesWithin(sc.pointee.SamplingPosition &- (sc.pointee.LoopBegin &+ 1),
                                                                     UInt32(truncatingIfNeeded: sc.pointee.Frac64), Delta64)
                                    Delta = 0 &- Int64(bitPattern: Delta64)
                                }
                            } else {
                                SamplesToMix = Self.framesWithin((sc.pointee.LoopEnd &- 1) &- sc.pointee.SamplingPosition,
                                                                 UInt32(truncatingIfNeeded: sc.pointee.Frac64) ^ UInt32.max, Delta64)
                                Delta = Int64(bitPattern: Delta64)
                            }

                            if SamplesToMix > MixBlockSize { SamplesToMix = MixBlockSize }
                            if SamplesToMix == 0 { SamplesToMix = 1 } // (the original would go round for ever)

                            fixSamplesLoop(v, sc, pingpong: true) // for what the interpolation reads past the loop's ends
                            Mix(sc, fMixBufferPtr, SamplesToMix, Delta, v, kind)
                            unfixSamplesLoop(v, sc)

                            MixBlockSize -= SamplesToMix
                            fMixBufferPtr += Int(SamplesToMix) << 1

                            if sc.pointee.LoopDirection == DIR_BACKWARDS {
                                if sc.pointee.SamplingPosition <= sc.pointee.LoopBegin {
                                    if sc.pointee.Backwards == BACKWARDS_ONCE {
                                        // A sample that an MPTM file is playing backwards has come to
                                        // its start, which is its end, and ends as any sample does.
                                        sc.pointee.Backwards = 0
                                        sc.pointee.Flags = SF_NOTE_STOP
                                        if sc.pointee.HostChnNum & CHN_DISOWNED == 0 {
                                            sc.pointee.HostChnPtr?.pointee.Flags &= ~HF_CHAN_ON
                                        }

                                        sounded = min(sounded, Int(RealBytesToMix) - Int(MixBlockSize))
                                        var left = fLastLeftValue, right = fLastRightValue
                                        while MixBlockSize > 0 {
                                            fMixBufferPtr[0] += left
                                            fMixBufferPtr[1] += right
                                            fMixBufferPtr += 2

                                            left -= left * endDecay
                                            right -= right * endDecay
                                            MixBlockSize -= 1
                                        }
                                        fLastLeftValue = left
                                        fLastRightValue = right
                                        // (Nothing of a voice that is left out goes on.)
                                        if reverbed {
                                            reverbOffset(left, right)
                                        } else if place < 0, !muted {
                                            fLastClickRemovalLeft += left
                                            fLastClickRemovalRight += right
                                        } else if place >= 0 {
                                            plugIns?.addClick(toPlace: place, left: left, right: right)
                                        }
                                        break
                                    }

                                    let NewLoopPos = UInt32(bitPattern: sc.pointee.LoopBegin &- sc.pointee.SamplingPosition) % (LoopLength << 1)
                                    if NewLoopPos >= LoopLength {
                                        sc.pointee.SamplingPosition = (sc.pointee.LoopEnd &- 1) &- Int32(bitPattern: NewLoopPos &- LoopLength)

                                        if sc.pointee.SamplingPosition == sc.pointee.LoopBegin {
                                            sc.pointee.LoopDirection = DIR_FORWARDS
                                            sc.pointee.Frac64 = UInt64(UInt32(truncatingIfNeeded: 0 &- sc.pointee.Frac64))
                                        }
                                    } else {
                                        sc.pointee.LoopDirection = DIR_FORWARDS
                                        sc.pointee.SamplingPosition = sc.pointee.LoopBegin &+ Int32(bitPattern: NewLoopPos)
                                        sc.pointee.Frac64 = UInt64(UInt32(truncatingIfNeeded: 0 &- sc.pointee.Frac64))
                                    }

                                    sc.pointee.HasLooped = true
                                }
                            } else {
                                if UInt32(bitPattern: sc.pointee.SamplingPosition) >= UInt32(bitPattern: sc.pointee.LoopEnd) {
                                    let NewLoopPos = UInt32(bitPattern: sc.pointee.SamplingPosition &- sc.pointee.LoopEnd) % (LoopLength << 1)
                                    if NewLoopPos >= LoopLength {
                                        sc.pointee.SamplingPosition = sc.pointee.LoopBegin &+ Int32(bitPattern: NewLoopPos &- LoopLength)
                                    } else {
                                        sc.pointee.SamplingPosition = (sc.pointee.LoopEnd &- 1) &- Int32(bitPattern: NewLoopPos)
                                        if sc.pointee.SamplingPosition != sc.pointee.LoopBegin {
                                            sc.pointee.LoopDirection = DIR_BACKWARDS
                                            sc.pointee.Frac64 = UInt64(UInt32(truncatingIfNeeded: 0 &- sc.pointee.Frac64))
                                        }
                                    }

                                    sc.pointee.HasLooped = true
                                }
                            }
                        }
                    } else if sc.pointee.LoopMode == LOOP_FORWARDS {
                        while MixBlockSize > 0 {
                            var SamplesToMix = Self.framesWithin((sc.pointee.LoopEnd &- 1) &- sc.pointee.SamplingPosition,
                                                                 UInt32(truncatingIfNeeded: sc.pointee.Frac64) ^ UInt32.max, Delta64)

                            if SamplesToMix > MixBlockSize { SamplesToMix = MixBlockSize }
                            if SamplesToMix == 0 { SamplesToMix = 1 }

                            fixSamplesLoop(v, sc, pingpong: false)
                            Mix(sc, fMixBufferPtr, SamplesToMix, Int64(bitPattern: Delta64), v, kind)
                            unfixSamplesLoop(v, sc)

                            MixBlockSize -= SamplesToMix
                            fMixBufferPtr += Int(SamplesToMix) << 1

                            if UInt32(bitPattern: sc.pointee.SamplingPosition) >= UInt32(bitPattern: sc.pointee.LoopEnd) {
                                let past = UInt32(bitPattern: sc.pointee.SamplingPosition &- sc.pointee.LoopEnd) % LoopLength
                                sc.pointee.SamplingPosition = sc.pointee.LoopBegin &+ Int32(bitPattern: past)
                                sc.pointee.HasLooped = true
                            }
                        }
                    } else { // no loop
                        while MixBlockSize > 0 {
                            var SamplesToMix = Self.framesWithin((sc.pointee.LoopEnd &- 1) &- sc.pointee.SamplingPosition,
                                                                 UInt32(truncatingIfNeeded: sc.pointee.Frac64) ^ UInt32.max, Delta64)

                            if SamplesToMix > MixBlockSize { SamplesToMix = MixBlockSize }
                            if SamplesToMix == 0 { SamplesToMix = 1 }

                            fixSamplesNoLoop(v, sc)
                            Mix(sc, fMixBufferPtr, SamplesToMix, Int64(bitPattern: Delta64), v, kind)

                            MixBlockSize -= SamplesToMix
                            fMixBufferPtr += Int(SamplesToMix) << 1

                            if UInt32(bitPattern: sc.pointee.SamplingPosition) >= UInt32(bitPattern: sc.pointee.LoopEnd) {
                                sc.pointee.Flags = SF_NOTE_STOP
                                if sc.pointee.HostChnNum & CHN_DISOWNED == 0 {
                                    sc.pointee.HostChnPtr?.pointee.Flags &= ~HF_CHAN_ON
                                }

                                // The sample has ended: the last it put out dies away over what is left of the tick,
                                sounded = min(sounded, Int(RealBytesToMix) - Int(MixBlockSize))
                                var left = fLastLeftValue, right = fLastRightValue
                                while MixBlockSize > 0 {
                                    fMixBufferPtr[0] += left
                                    fMixBufferPtr[1] += right
                                    fMixBufferPtr += 2

                                    left -= left * endDecay
                                    right -= right * endDecay
                                    MixBlockSize -= 1
                                }
                                fLastLeftValue = left
                                fLastRightValue = right

                                // and what is left of it then goes on into the ticks after. (Nothing
                                // of a voice that is left out does.)
                                if reverbed {
                                    reverbOffset(left, right)
                                } else if place < 0, !muted {
                                    fLastClickRemovalLeft += left
                                    fLastClickRemovalRight += right
                                } else if place >= 0 {
                                    plugIns?.addClick(toPlace: place, left: left, right: right)
                                }

                                break
                            }
                        }
                    }

                    // (What it put out last, unless its sample has ended and that is dying away already.)
                    if sc.pointee.Flags & SF_CHAN_ON != 0 {
                        sc.pointee.LastOutLeft = fLastLeftValue
                        sc.pointee.LastOutRight = fLastRightValue
                    }
                }

                sc.pointee.fOldLeftVolume = sc.pointee.fCurrVolL
                if !Surround { sc.pointee.fOldRightVolume = sc.pointee.fCurrVolR }
            }

            sc.pointee.Flags &= ~(SF_RECALC_PAN | SF_RECALC_VOL | SF_FREQ_CHANGE | SF_UPDATE_MIXERVOL | SF_NEW_NOTE | SF_NOTE_STOP | SF_LOOP_CHANGED | SF_PAN_CHANGED)
        }

        if !silent, adLib != nil || plugIns != nil || reverb != nil { finishTick(fMixBuffer, Int(RealBytesToMix)) }
        if let waves { storeWaves(waves) }
    }

    /// A voice whose sample has just been stopped where it is (only a module of Symphonie's stops one):
    /// what it last put out is not cut off, which would click, but dies away over the tick and the
    /// ticks after as a sample's end does, as OpenMPT lets it die away when it stops mixing a channel.
    private func dieAway(_ sc: IT2SlavePointer) {
        var left = sc.pointee.LastOutLeft, right = sc.pointee.LastOutRight
        guard left != 0 || right != 0 else { return }
        // (Nothing of a voice that is left out goes on.)
        guard (mutedChannels >> UInt64(sc.pointee.HostChnNum & 63)) & 1 == 0 else { return }
        // Where it dies away is where the voice was going: see `HQ_MixSamples`.
        var place = -1
        if let plugIns {
            let ofInstrument = sc.pointee.Ins != 0xFF ? Int(sc.pointee.InsPtr?.MixPlug ?? 0) : 0
            place = plugIns.place(instrumentPlugIn: ofInstrument, channel: Int(sc.pointee.HostChnNum & 63))
            plugIns.voiceMixed()
        }
        let reverbed = place < 0 && sc.pointee.Reverb && reverb != nil
        var target = fMixBuffer
        if place >= 0, let plugIns { target = plugIns.buffer(ofPlace: place) }
        if reverbed, let reverbSend {
            target = reverbSend
            reverbSent = true
        }
        // (OpenMPT takes its share away before it adds what is left.)
        for _ in 0 ..< Int(RealBytesToMix) {
            left -= left * endDecay
            right -= right * endDecay
            target[0] += left
            target[1] += right
            target += 2
        }
        if reverbed {
            reverbOffset(left, right)
        } else if place >= 0 {
            plugIns?.addClick(toPlace: place, left: left, right: right)
        } else {
            fLastClickRemovalLeft += left
            fLastClickRemovalRight += right
        }
    }

    /// What is left of a voice in the reverb when it ends, which the reverb lets die away, as OpenMPT
    /// lets it die away in what is sent to the reverb.
    private func reverbOffset(_ left: Float, _ right: Float) {
        guard let reverb else { return }
        reverb.leftOffset &+= Int32((left * reverbScale).rounded())
        reverb.rightOffset &+= Int32((right * reverbScale).rounded())
    }

    /// Adds ModPlug's reverb to a tick: of what was sent to it, block by block as OpenMPT makes its mix.
    private func addReverb(_ fMixBuffer: UnsafeMutablePointer<Float>, _ frames: Int) {
        guard let reverb, let reverbSend else { return }
        let scale = reverbScale, back = 1 / reverbScale
        withUnsafeTemporaryAllocation(of: Int32.self, capacity: ModPlugReverb.maxFrames * 2) { added in
            guard let added = added.baseAddress else { return }
            var done = 0
            while done < frames {
                let count = min(ModPlugReverb.maxFrames, frames - done)
                let send = reverb.sendBuffer
                if reverbSent {
                    reverb.touch(send: send, frames: count)
                    let from = reverbSend + done * 2
                    for i in 0 ..< count * 2 { send[i] &+= Int32(max(-2.0e9, min(2.0e9, (from[i] * scale).rounded()))) }
                }
                // (What the reverb gives is only ever added to the mix, so it is given nothing to add to.)
                added.update(repeating: 0, count: count * 2)
                reverb.process(main: added, send: send, frames: count)
                let to = fMixBuffer + done * 2
                for i in 0 ..< count * 2 { to[i] += Float(added[i]) * back }
                done += count
            }
        }
    }

    /// What OpenMPT does to a tick once its voices are mixed, for a song that has the means: the FM
    /// chip's sound is added, and the reverb's, the whole is sent through the plug-ins, and the
    /// song's volume is applied.
    private func finishTick(_ fMixBuffer: UnsafeMutablePointer<Float>, _ frames: Int) {
        if let adLib {
            adLib.leaveOut(mutedChannels, sChn)
            let chipWaves = waves != nil ? chipWaves : nil
            adLib.render(into: fMixBuffer, frames: frames, level: adLibLevel, waves: chipWaves)
            // For the scopes, each of the chip's voices is the sound of the channel whose note it last had.
            if let chipWaves, let channelWaves {
                for voice in 0 ..< OpenMPTAdLib.voiceCount {
                    let channel = adLib.lastChannel(ofVoice: voice)
                    guard channel >= 0, waveOfChannel[channel] >= 0 else { continue }
                    let from = chipWaves + voice * frames, to = channelWaves + channel * frames
                    for i in 0 ..< frames { to[i] += from[i] }
                }
            }
            // A channel with a note on the chip is as loud as the chip's voice is.
            withUnsafeTemporaryAllocation(of: Float.self, capacity: OpenMPTAdLib.voiceCount) { swings in
                guard let swings = swings.baseAddress else { return }
                adLib.takeLevels(into: swings)
                for voice in 0 ..< OpenMPTAdLib.voiceCount {
                    let channel = adLib.channel(ofVoice: voice, sChn)
                    guard channel >= 0, swings[voice] > 0 else { continue }
                    if swings[voice] > levels.now[channel] { levels.now[channel] = swings[voice] }
                    levels.until[channel] = frames
                }
            }
        }
        addReverb(fMixBuffer, frames)
        plugIns?.process(master: fMixBuffer, frames: frames)
        guard globalVolumeAtMaster else { return }
        // The song's volume, reached over a moment so that a change of it makes no click.
        let wanted = Float(min(GlobalVolume, 128)) * (1.0 / 128.0)
        if masterVolume < 0 { masterVolume = wanted }
        let ramp = min(frames, 64)
        let step = ramp > 0 ? (wanted - masterVolume) / Float(ramp) : 0
        var volume = masterVolume
        for i in 0 ..< frames {
            if i < ramp { volume += step } else { volume = wanted }
            fMixBuffer[i * 2] *= volume
            fMixBuffer[i * 2 + 1] *= volume
        }
        masterVolume = wanted
    }

    /// How many frames of output a voice gives before it has gone `distance` frames of its sample
    /// and what is left of the frame it is in: that many and one more.
    @inline(__always)
    private static func framesWithin(_ distance: Int32, _ fraction: UInt32, _ Delta64: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: (((UInt64(UInt32(bitPattern: distance)) << 32) | UInt64(fraction)) / Delta64) &+ 1)
    }

    // MARK: Voices that are silent (zerovol.c)

    private func UpdateNoLoopHQ(_ sc: IT2SlavePointer, _ numSamples: UInt32) {
        var SamplingPosition = UInt32(bitPattern: sc.pointee.SamplingPosition)

        let Delta = sc.pointee.Delta64 &* UInt64(numSamples)
        let IntSamples = UInt32(truncatingIfNeeded: Delta >> 32)
        let FracSamples = Delta & 0xFFFF_FFFF

        sc.pointee.Frac64 &+= FracSamples
        SamplingPosition &+= UInt32(truncatingIfNeeded: sc.pointee.Frac64 >> 32)
        SamplingPosition &+= IntSamples
        sc.pointee.Frac64 &= 0xFFFF_FFFF

        if SamplingPosition >= UInt32(bitPattern: sc.pointee.LoopEnd) {
            sc.pointee.Flags = SF_NOTE_STOP
            if sc.pointee.HostChnNum & CHN_DISOWNED == 0 {
                sc.pointee.HostChnPtr?.pointee.Flags &= ~HF_CHAN_ON // the channel is off
                return
            }
        }

        sc.pointee.SamplingPosition = Int32(bitPattern: SamplingPosition)
    }

    private func UpdateForwardsLoopHQ(_ sc: IT2SlavePointer, _ numSamples: UInt32) {
        let Delta = sc.pointee.Delta64 &* UInt64(numSamples)
        let IntSamples = UInt32(truncatingIfNeeded: Delta >> 32)
        let FracSamples = Delta & 0xFFFF_FFFF

        sc.pointee.Frac64 &+= FracSamples
        sc.pointee.SamplingPosition &+= Int32(truncatingIfNeeded: sc.pointee.Frac64 >> 32)
        sc.pointee.SamplingPosition &+= Int32(bitPattern: IntSamples)
        sc.pointee.Frac64 &= 0xFFFF_FFFF

        if UInt32(bitPattern: sc.pointee.SamplingPosition) >= UInt32(bitPattern: sc.pointee.LoopEnd) {
            let LoopLength = UInt32(bitPattern: sc.pointee.LoopEnd &- sc.pointee.LoopBegin)
            if LoopLength == 0 {
                sc.pointee.SamplingPosition = 0
            } else {
                let past = UInt32(bitPattern: sc.pointee.SamplingPosition &- sc.pointee.LoopEnd) % LoopLength
                sc.pointee.SamplingPosition = sc.pointee.LoopBegin &+ Int32(bitPattern: past)
            }

            sc.pointee.HasLooped = true
        }
    }

    private func UpdatePingPongLoopHQ(_ sc: IT2SlavePointer, _ numSamples: UInt32) {
        let Delta = sc.pointee.Delta64 &* UInt64(numSamples)
        let IntSamples = UInt32(truncatingIfNeeded: Delta >> 32)
        let FracSamples = Delta & 0xFFFF_FFFF

        let LoopLength = UInt32(bitPattern: sc.pointee.LoopEnd &- sc.pointee.LoopBegin)
        if LoopLength == 0 { return } // (never, as it is called)

        if sc.pointee.LoopDirection == DIR_BACKWARDS {
            sc.pointee.Frac64 &-= FracSamples
            sc.pointee.SamplingPosition &+= Int32(truncatingIfNeeded: sc.pointee.Frac64 >> 32)
            sc.pointee.SamplingPosition &-= Int32(bitPattern: IntSamples)
            sc.pointee.Frac64 &= 0xFFFF_FFFF

            if sc.pointee.SamplingPosition <= sc.pointee.LoopBegin {
                if sc.pointee.Backwards == BACKWARDS_ONCE { // an MPTM file's sample played backwards, at its end
                    sc.pointee.Backwards = 0
                    sc.pointee.Flags = SF_NOTE_STOP
                    if sc.pointee.HostChnNum & CHN_DISOWNED == 0 { sc.pointee.HostChnPtr?.pointee.Flags &= ~HF_CHAN_ON }
                    return
                }

                let NewLoopPos = UInt32(bitPattern: sc.pointee.LoopBegin &- sc.pointee.SamplingPosition) % (LoopLength << 1)
                if NewLoopPos >= LoopLength {
                    sc.pointee.SamplingPosition = (sc.pointee.LoopEnd &- 1) &- Int32(bitPattern: NewLoopPos &- LoopLength)

                    if sc.pointee.SamplingPosition == sc.pointee.LoopBegin {
                        sc.pointee.LoopDirection = DIR_FORWARDS
                        sc.pointee.Frac64 = UInt64(UInt32(truncatingIfNeeded: 0 &- sc.pointee.Frac64))
                    }
                } else {
                    sc.pointee.LoopDirection = DIR_FORWARDS
                    sc.pointee.SamplingPosition = sc.pointee.LoopBegin &+ Int32(bitPattern: NewLoopPos)
                    sc.pointee.Frac64 = UInt64(UInt32(truncatingIfNeeded: 0 &- sc.pointee.Frac64))
                }

                sc.pointee.HasLooped = true
            }
        } else {
            sc.pointee.Frac64 &+= FracSamples
            sc.pointee.SamplingPosition &+= Int32(truncatingIfNeeded: sc.pointee.Frac64 >> 32)
            sc.pointee.SamplingPosition &+= Int32(bitPattern: IntSamples)
            sc.pointee.Frac64 &= 0xFFFF_FFFF

            if UInt32(bitPattern: sc.pointee.SamplingPosition) >= UInt32(bitPattern: sc.pointee.LoopEnd) {
                let NewLoopPos = UInt32(bitPattern: sc.pointee.SamplingPosition &- sc.pointee.LoopEnd) % (LoopLength << 1)
                if NewLoopPos >= LoopLength {
                    sc.pointee.SamplingPosition = sc.pointee.LoopBegin &+ Int32(bitPattern: NewLoopPos &- LoopLength)
                } else {
                    sc.pointee.SamplingPosition = (sc.pointee.LoopEnd &- 1) &- Int32(bitPattern: NewLoopPos)
                    if sc.pointee.SamplingPosition != sc.pointee.LoopBegin {
                        sc.pointee.LoopDirection = DIR_BACKWARDS
                        sc.pointee.Frac64 = UInt64(UInt32(truncatingIfNeeded: 0 &- sc.pointee.Frac64))
                    }
                }

                sc.pointee.HasLooped = true
            }
        }
    }

    // MARK: The samples past a loop's ends (hq_fixsample.c)

    // The interpolation reads three samples before the one a voice is at and four after it. Before a
    // voice is mixed, what it should find there is written just outside its loop's ends, or outside
    // the sample's for one that does not loop; after it, what was there is put back.
    //
    // The original takes a loop to lie within its sample, and a file's need not: one whose loop
    // starts where its sound ends is not unknown. Then it reads and writes memory that is not the
    // sample's. Here each sample is looked at first: one that is not the sample's own reads as
    // nought and is not written, so that all the original does within the sample is still done (the
    // start of a sample is filled in before it whatever its loop).

    /// The sample at `index`, or nought if that is not the sample's own memory.
    @inline(__always)
    private static func tap<T: FixedWidthInteger>(_ ptr: UnsafeMutablePointer<T>, _ index: Int64, _ v: VoiceSample) -> T {
        index >= v.lowest && index <= v.highest ? ptr[Int(index)] : 0
    }

    /// Writes the sample at `index`, if that is the sample's own memory.
    @inline(__always)
    private static func setTap<T: FixedWidthInteger>(_ ptr: UnsafeMutablePointer<T>, _ index: Int64, _ value: T, _ v: VoiceSample) {
        if index >= v.lowest && index <= v.highest { ptr[Int(index)] = value }
    }

    /// A loop: past its end comes its start again, or for a ping-pong loop its end backwards; and
    /// the same before its start, once it has been round.
    @inline(__always)
    private static func fixLoop<T: FixedWidthInteger>(
        _ ptr: UnsafeMutablePointer<T>, _ v: VoiceSample, _ loopBegin: Int64, _ loopEnd: Int64, _ HasLooped: Bool, _ pingpong: Bool,
        _ leftTmpSamples: inout (T, T, T), _ rightTmpSamples: inout (T, T, T, T)
    ) {
        if HasLooped {
            leftTmpSamples.0 = tap(ptr, loopBegin - 1, v)
            leftTmpSamples.1 = tap(ptr, loopBegin - 2, v)
            leftTmpSamples.2 = tap(ptr, loopBegin - 3, v)
            if pingpong {
                setTap(ptr, loopBegin - 1, tap(ptr, loopBegin, v), v)
                setTap(ptr, loopBegin - 2, tap(ptr, loopBegin + 1, v), v)
                setTap(ptr, loopBegin - 3, tap(ptr, loopBegin + 2, v), v)
            } else {
                setTap(ptr, loopBegin - 1, tap(ptr, loopEnd - 1, v), v)
                setTap(ptr, loopBegin - 2, tap(ptr, loopEnd - 2, v), v)
                setTap(ptr, loopBegin - 3, tap(ptr, loopEnd - 3, v), v)
            }
        } else {
            let first = tap(ptr, 0, v)
            setTap(ptr, -1, first, v)
            setTap(ptr, -2, first, v)
            setTap(ptr, -3, first, v)
        }

        rightTmpSamples.0 = tap(ptr, loopEnd, v)
        rightTmpSamples.1 = tap(ptr, loopEnd + 1, v)
        rightTmpSamples.2 = tap(ptr, loopEnd + 2, v)
        rightTmpSamples.3 = tap(ptr, loopEnd + 3, v)
        if pingpong {
            setTap(ptr, loopEnd, tap(ptr, loopEnd - 1, v), v)
            setTap(ptr, loopEnd + 1, tap(ptr, loopEnd - 2, v), v)
            setTap(ptr, loopEnd + 2, tap(ptr, loopEnd - 3, v), v)
            setTap(ptr, loopEnd + 3, tap(ptr, loopEnd - 4, v), v)
        } else {
            setTap(ptr, loopEnd, tap(ptr, loopBegin, v), v)
            setTap(ptr, loopEnd + 1, tap(ptr, loopBegin + 1, v), v)
            setTap(ptr, loopEnd + 2, tap(ptr, loopBegin + 2, v), v)
            setTap(ptr, loopEnd + 3, tap(ptr, loopBegin + 3, v), v)
        }
    }

    @inline(__always)
    private static func unfixLoop<T: FixedWidthInteger>(
        _ ptr: UnsafeMutablePointer<T>, _ v: VoiceSample, _ loopBegin: Int64, _ loopEnd: Int64, _ HasLooped: Bool,
        _ leftTmpSamples: (T, T, T), _ rightTmpSamples: (T, T, T, T)
    ) {
        setTap(ptr, loopEnd, rightTmpSamples.0, v)
        setTap(ptr, loopEnd + 1, rightTmpSamples.1, v)
        setTap(ptr, loopEnd + 2, rightTmpSamples.2, v)
        setTap(ptr, loopEnd + 3, rightTmpSamples.3, v)

        if HasLooped {
            setTap(ptr, loopBegin - 1, leftTmpSamples.0, v)
            setTap(ptr, loopBegin - 2, leftTmpSamples.1, v)
            setTap(ptr, loopBegin - 3, leftTmpSamples.2, v)
        }
    }

    /// No loop: before the sample is its first value held, and after it its last.
    @inline(__always)
    private static func fixNoLoop<T: FixedWidthInteger>(_ data: UnsafeMutablePointer<T>, _ v: VoiceSample, _ end: Int64) {
        let first = tap(data, 0, v)
        setTap(data, -1, first, v)
        setTap(data, -2, first, v)
        setTap(data, -3, first, v)
        let last = tap(data, end - 1, v)
        setTap(data, end, last, v)
        setTap(data, end + 1, last, v)
        setTap(data, end + 2, last, v)
        setTap(data, end + 3, last, v)
    }

    /// fixSamplesFwdLoop and fixSamplesPingpong
    private func fixSamplesLoop(_ v: VoiceSample, _ sc: IT2SlavePointer, pingpong: Bool) {
        // A loop of four samples or fewer would take complicated logic. It is rare, so it is left alone.
        if sc.pointee.LoopEnd &- sc.pointee.LoopBegin <= 4 { return }
        let LoopBegin = Int64(sc.pointee.LoopBegin), LoopEnd = Int64(sc.pointee.LoopEnd)
        let HasLooped = sc.pointee.HasLooped

        if sc.pointee.SmpIs16Bit {
            Self.fixLoop(v.Data.assumingMemoryBound(to: Int16.self), v, LoopBegin, LoopEnd, HasLooped, pingpong,
                         &sc.pointee.leftTmpSamples16, &sc.pointee.rightTmpSamples16)
            if let DataR = v.DataR { // the right of a stereo sample
                Self.fixLoop(DataR.assumingMemoryBound(to: Int16.self), v, LoopBegin, LoopEnd, HasLooped, pingpong,
                             &sc.pointee.leftTmpSamples16_R, &sc.pointee.rightTmpSamples16_R)
            }
        } else {
            Self.fixLoop(v.Data.assumingMemoryBound(to: Int8.self), v, LoopBegin, LoopEnd, HasLooped, pingpong,
                         &sc.pointee.leftTmpSamples8, &sc.pointee.rightTmpSamples8)
            if let DataR = v.DataR {
                Self.fixLoop(DataR.assumingMemoryBound(to: Int8.self), v, LoopBegin, LoopEnd, HasLooped, pingpong,
                             &sc.pointee.leftTmpSamples8_R, &sc.pointee.rightTmpSamples8_R)
            }
        }
    }

    /// unfixSamplesFwdLoop and unfixSamplesPingpong, which are the same.
    private func unfixSamplesLoop(_ v: VoiceSample, _ sc: IT2SlavePointer) {
        if sc.pointee.LoopEnd &- sc.pointee.LoopBegin <= 4 { return }
        let LoopBegin = Int64(sc.pointee.LoopBegin), LoopEnd = Int64(sc.pointee.LoopEnd)
        let HasLooped = sc.pointee.HasLooped

        if sc.pointee.SmpIs16Bit {
            Self.unfixLoop(v.Data.assumingMemoryBound(to: Int16.self), v, LoopBegin, LoopEnd, HasLooped,
                           sc.pointee.leftTmpSamples16, sc.pointee.rightTmpSamples16)
            if let DataR = v.DataR {
                Self.unfixLoop(DataR.assumingMemoryBound(to: Int16.self), v, LoopBegin, LoopEnd, HasLooped,
                               sc.pointee.leftTmpSamples16_R, sc.pointee.rightTmpSamples16_R)
            }
        } else {
            Self.unfixLoop(v.Data.assumingMemoryBound(to: Int8.self), v, LoopBegin, LoopEnd, HasLooped,
                           sc.pointee.leftTmpSamples8, sc.pointee.rightTmpSamples8)
            if let DataR = v.DataR {
                Self.unfixLoop(DataR.assumingMemoryBound(to: Int8.self), v, LoopBegin, LoopEnd, HasLooped,
                               sc.pointee.leftTmpSamples8_R, sc.pointee.rightTmpSamples8_R)
            }
        }
    }

    private func fixSamplesNoLoop(_ v: VoiceSample, _ sc: IT2SlavePointer) {
        let LoopEnd = Int64(sc.pointee.LoopEnd)

        if sc.pointee.SmpIs16Bit {
            Self.fixNoLoop(v.Data.assumingMemoryBound(to: Int16.self), v, LoopEnd)
            if let DataR = v.DataR { Self.fixNoLoop(DataR.assumingMemoryBound(to: Int16.self), v, LoopEnd) }
        } else {
            Self.fixNoLoop(v.Data.assumingMemoryBound(to: Int8.self), v, LoopEnd)
            if let DataR = v.DataR { Self.fixNoLoop(DataR.assumingMemoryBound(to: Int8.self), v, LoopEnd) }
        }
    }

    // MARK: The mixing routines (hq_m.c)

    /// Mixes so many frames of a voice, going `Delta64` through its sample with each, by whichever
    /// of the original's sixteen routines `kind` is: 1 for a sample of sixteen bits, 2 for surround,
    /// 4 for a stereo sample and 8 for the filter, added together.
    private func Mix(_ sc: IT2SlavePointer, _ fMixBufPtr: UnsafeMutablePointer<Float>, _ NumSamples: UInt32, _ Delta64: Int64,
                     _ v: VoiceSample, _ kind: Int) {
        // Will every sample it reads be the sample's own memory? It is, unless a file has a loop or a
        // length that is wrong, when the original reads whatever lies beyond: then nothing is read there.
        let pos = Int64(sc.pointee.SamplingPosition), frac = sc.pointee.Frac64
        var inside = false
        if frac >> 32 == 0 {
            let travel = Int64(NumSamples &- 1).multipliedReportingOverflow(by: Delta64)
            let last = ((pos << 32) | Int64(frac)).addingReportingOverflow(travel.partialValue)
            if !travel.overflow, !last.overflow {
                let end = last.partialValue >> 32
                inside = min(pos, end) - 3 >= v.lowest && max(pos, end) + 4 <= v.highest
            }
        }
        if !inside {
            if kind & 1 != 0 {
                mixChecked(sc, fMixBufPtr, NumSamples, Delta64, v, Int16.self, stereo: kind & 4 != 0, surround: kind & 2 != 0, filtered: kind & 8 != 0)
            } else {
                mixChecked(sc, fMixBufPtr, NumSamples, Delta64, v, Int8.self, stereo: kind & 4 != 0, surround: kind & 2 != 0, filtered: kind & 8 != 0)
            }
            return
        }

        switch kind {
        case 0: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int8.self, stereo: false, surround: false, filtered: false, checked: false)
        case 1: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int16.self, stereo: false, surround: false, filtered: false, checked: false)
        case 2: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int8.self, stereo: false, surround: true, filtered: false, checked: false)
        case 3: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int16.self, stereo: false, surround: true, filtered: false, checked: false)
        case 4: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int8.self, stereo: true, surround: false, filtered: false, checked: false)
        case 5: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int16.self, stereo: true, surround: false, filtered: false, checked: false)
        case 6: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int8.self, stereo: true, surround: true, filtered: false, checked: false)
        case 7: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int16.self, stereo: true, surround: true, filtered: false, checked: false)
        case 8: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int8.self, stereo: false, surround: false, filtered: true, checked: false)
        case 9: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int16.self, stereo: false, surround: false, filtered: true, checked: false)
        case 10: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int8.self, stereo: false, surround: true, filtered: true, checked: false)
        case 11: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int16.self, stereo: false, surround: true, filtered: true, checked: false)
        case 12: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int8.self, stereo: true, surround: false, filtered: true, checked: false)
        case 13: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int16.self, stereo: true, surround: false, filtered: true, checked: false)
        case 14: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int8.self, stereo: true, surround: true, filtered: true, checked: false)
        default: mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, Int16.self, stereo: true, surround: true, filtered: true, checked: false)
        }
    }

    /// The same for a voice that would read outside its sample's memory, slower: each sample is
    /// looked at before it is read.
    @inline(never)
    private func mixChecked<T: FixedWidthInteger & SignedInteger>(
        _ sc: IT2SlavePointer, _ fMixBufPtr: UnsafeMutablePointer<Float>, _ NumSamples: UInt32, _ Delta64: Int64, _ v: VoiceSample, _: T.Type,
        stereo: Bool, surround: Bool, filtered: Bool
    ) {
        mixLoop(sc, fMixBufPtr, NumSamples, Delta64, v, T.self, stereo: stereo, surround: surround, filtered: filtered, checked: true)
    }

    /// All sixteen of the original's routines, which differ in what is constant here: the width of
    /// the sample, whether it is stereo, whether the voice is in surround and whether it is filtered.
    @inline(__always)
    private func mixLoop<T: FixedWidthInteger & SignedInteger>(
        _ sc: IT2SlavePointer, _ fMixBuffer: UnsafeMutablePointer<Float>, _ NumSamples: UInt32, _ Delta64: Int64, _ v: VoiceSample, _: T.Type,
        stereo: Bool, surround: Bool, filtered: Bool, checked: Bool
    ) {
        let base = UnsafePointer<T>(v.Data.assumingMemoryBound(to: T.self))
        let baseR = UnsafePointer<T>((v.DataR ?? v.Data).assumingMemoryBound(to: T.self))
        let fSincLUT = UnsafePointer(fSincLUT) + (resampling.map { $0.table(sc, speed: Delta64.magnitude) * Self.kernelLength } ?? 0)
        let scale: Float = T.bitWidth == 8 ? 1.0 / 128.0 : 1.0 / 32768.0
        let lowest = v.lowest, highest = v.highest

        let delta = UInt64(bitPattern: Delta64)
        var SamplingPosition = sc.pointee.SamplingPosition
        var Frac64 = sc.pointee.Frac64
        var fCurrVolL = sc.pointee.fCurrVolL, fCurrVolR = sc.pointee.fCurrVolR
        let fLeftVolume = sc.pointee.fLeftVolume, fRightVolume = sc.pointee.fRightVolume
        let fFiltera = sc.pointee.fFiltera, fFilterb = sc.pointee.fFilterb, fFilterc = sc.pointee.fFilterc
        // Impulse Tracker's filter lets the low through. OpenMPT's can let the high through instead,
        // which is the same filter given what is left when the low is taken away: its first weight
        // is one less the usual, and what it remembers of each sample is what it put out less what
        // came in. Only an MPTM file's voice asks for it.
        let highPass = sc.pointee.HighPass
        var fOldSamples = sc.pointee.fOldSamples
        var fLastLeftValue = fLastLeftValue, fLastRightValue = fLastRightValue

        var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
        var fMixBufPtr = fMixBuffer
        var todo = NumSamples
        while todo > 0 {
            // The sample where the voice is, read through the sinc for how far past it the voice is.
            let t = fSincLUT + Int((UInt32(truncatingIfNeeded: Frac64) >> 17) & 0x7FF8)
            var fSample: Float, fSampleR: Float = 0
            if checked {
                fSample = Self.SincInterpolationChecked(base, SamplingPosition, t, scale, lowest, highest)
                if stereo { fSampleR = Self.SincInterpolationChecked(baseR, SamplingPosition, t, scale, lowest, highest) }
            } else {
                fSample = Self.SincInterpolation(base + Int(SamplingPosition), t, scale)
                if stereo { fSampleR = Self.SincInterpolation(baseR + Int(SamplingPosition), t, scale) }
            }

            if filtered {
                let fIn = fSample, fInR = fSampleR
                fSample = (fSample * fFiltera) + (fOldSamples.0 * fFilterb) + (fOldSamples.1 * fFilterc)

                // The filter is held where the SB16 MMX driver holds it.
                if fSample < -2.0 { fSample = -2.0 } else if fSample > 2.0 { fSample = 2.0 }

                fOldSamples.1 = fOldSamples.0
                fOldSamples.0 = highPass ? fSample - fIn : fSample

                if stereo {
                    fSampleR = (fSampleR * fFiltera) + (fOldSamples.2 * fFilterb) + (fOldSamples.3 * fFilterc)
                    if fSampleR < -2.0 { fSampleR = -2.0 } else if fSampleR > 2.0 { fSampleR = 2.0 }
                    fOldSamples.3 = fOldSamples.2
                    fOldSamples.2 = highPass ? fSampleR - fInR : fSampleR
                }
            }

            if fSample < low { low = fSample }
            if fSample > high { high = fSample }

            if surround {
                // Surround is the same on both sides, one of them upside down, at the left's volume.
                fLastLeftValue = fSample * fCurrVolL
                fMixBufPtr[0] += fLastLeftValue
                if stereo {
                    fLastRightValue = fSampleR * fCurrVolL
                    fMixBufPtr[1] -= fLastRightValue
                } else {
                    fMixBufPtr[1] -= fLastLeftValue
                }
            } else {
                fLastLeftValue = fSample * fCurrVolL
                fLastRightValue = (stereo ? fSampleR : fSample) * fCurrVolR
                fMixBufPtr[0] += fLastLeftValue
                fMixBufPtr[1] += fLastRightValue
            }
            fMixBufPtr += 2

            Frac64 &+= delta
            SamplingPosition &+= Int32(truncatingIfNeeded: Frac64 >> 32)
            Frac64 &= 0xFFFF_FFFF

            // The volume goes a sixty-fourth of the way to where it is going with each frame.
            fCurrVolL += (fLeftVolume - fCurrVolL) * (256.0 / 16384.0)
            if !surround { fCurrVolR += (fRightVolume - fCurrVolR) * (256.0 / 16384.0) }

            todo -= 1
        }

        if surround { fLastRightValue = stereo ? -fLastRightValue : -fLastLeftValue }
        if low <= high {
            swing.note(max(-4, low))
            swing.note(min(4, high))
        }

        sc.pointee.SamplingPosition = SamplingPosition
        sc.pointee.Frac64 = Frac64
        sc.pointee.fCurrVolL = fCurrVolL
        sc.pointee.fCurrVolR = fCurrVolR
        if filtered { sc.pointee.fOldSamples = fOldSamples }
        self.fLastLeftValue = fLastLeftValue
        self.fLastRightValue = fLastRightValue
    }

    /// The eight samples about `s`, each by its weight, added in the original's order.
    @inline(__always)
    // (Each sample by way of Int, whose conversion to Float is the processor's own: Int32's, in a generic
    // body like this one, was left a call to the general conversion. The value is the same.)
    private static func SincInterpolation<T: FixedWidthInteger & SignedInteger>(_ s: UnsafePointer<T>, _ t: UnsafePointer<Float>, _ scale: Float) -> Float {
        var out = Float(Int(truncatingIfNeeded: s[-3])) * t[0]
        out += Float(Int(truncatingIfNeeded: s[-2])) * t[1]
        out += Float(Int(truncatingIfNeeded: s[-1])) * t[2]
        out += Float(Int(truncatingIfNeeded: s[0])) * t[3]
        out += Float(Int(truncatingIfNeeded: s[1])) * t[4]
        out += Float(Int(truncatingIfNeeded: s[2])) * t[5]
        out += Float(Int(truncatingIfNeeded: s[3])) * t[6]
        out += Float(Int(truncatingIfNeeded: s[4])) * t[7]
        return out * scale
    }

    /// The same, with nothing for a sample that is not within `lowest ... highest`.
    @inline(__always)
    private static func SincInterpolationChecked<T: FixedWidthInteger & SignedInteger>(
        _ base: UnsafePointer<T>, _ position: Int32, _ t: UnsafePointer<Float>, _ scale: Float, _ lowest: Int64, _ highest: Int64
    ) -> Float {
        var out: Float = 0
        var index = Int64(position) - 3
        for tap in 0 ..< 8 {
            let sample: Float = index >= lowest && index <= highest ? Float(Int(truncatingIfNeeded: base[Int(index)])) : 0
            if tap == 0 { out = sample * t[0] } else { out += sample * t[tap] }
            index += 1
        }
        return out * scale
    }
}
