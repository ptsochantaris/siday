// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from st3play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// The two sound cards Scream Tracker played on, as far as it used them.
///
/// The Gravis Ultrasound mixes for itself: the tracker only tells it, a tick at a time, what each of
/// its voices is to play, how loud and where, and the card ramps a volume from one level to the next.
/// That is the card's sound chip, the GF1, and Scream Tracker's driver for it, whose way of running
/// out of voices is part of how its tunes sound. On a Sound Blaster Pro the tracker mixes: every
/// channel added into eight bits, with no smoothing, at 22 kHz in stereo or 43 kHz in mono.
///
/// Either way the card makes sound at a rate of its own, which is brought to the player's rate
/// through a windowed sinc.
final class ST3Cards {
    /// A voice's filter, in a file whose Z sets one (see `ST3Player.playsFilter`): OpenMPT's, as
    /// `FT2Player.setFilter` has it, at the card's own rate. Its last two samples on each side too.
    struct Filter {
        var on = false
        var a0: Float = 0, b0: Float = 0, b1: Float = 0
        var y1: Float = 0, y2: Float = 0, y1R: Float = 0, y2R: Float = 0
    }

    private struct GUSVoice {
        // Where in the samples it is, where its loop starts and where it ends; -1 for nowhere.
        var SA = -1, SAS = -1, SAE = -1
        var SA_frac: UInt16 = 0
        var SACI: UInt8 = 1, SVCI: UInt8 = 1
        var LOff: UInt16 = 0, ROff: UInt16 = 0
        var SVRI: UInt16 = 0, SVLI: UInt16 = 0, SVSI: UInt16 = 0, SVEI: UInt16 = 0
        var SFCI: UInt16 = 1 << 9
        /// All ones, or none for a voice of a channel that is left out of the sound: it plays on,
        /// and what it would add to the sound is made nothing by this.
        var heard: Int32 = -1
        /// For the lights: the channel the voice was last given to, and the lowest and highest its
        /// sample has been of late.
        var owner = -1
        var low: Int32 = .max, high: Int32 = .min
        /// True for a voice playing a sample in stereo, whose right side is in `samplesRight`.
        var stereo = false
        var filter = Filter()
        /// All ones for a voice of a channel put in ModPlug's reverb, which goes there and not to
        /// the card's own output; none for any other.
        var reverb: Int32 = 0
    }

    /// What of a channel the Sound Blaster's mixer needs, kept apart from the channel while it mixes.
    private struct SBVoice {
        var base = -1
        var pos: UInt32 = 0, poslow: UInt32 = 0, end: UInt32 = 0, loop: UInt32 = 0, speed: UInt32 = 0
        var vol: UInt8 = 0
        var mixtype: Int8 = 0
        /// For the lights: the lowest and highest the voice has been in this tick.
        var low: Int32 = .max, high: Int32 = .min
    }

    private static let gusVolTable: [UInt16] = [
        4096, 36848, 40944, 43008, 45040, 46080, 47104, 48128, 49136, 49664, 50176,
        50688, 51200, 51712, 52224, 52736, 53232, 53504, 53760, 54016, 54272, 54528,
        54784, 55040, 55296, 55552, 55808, 56064, 56320, 56576, 56832, 57088, 57328,
        57472, 57600, 57728, 57856, 57984, 58112, 58240, 58368, 58496, 58624, 58752,
        58880, 59008, 59136, 59264, 59392, 59520, 59648, 59776, 59904, 60032, 60160,
        60288, 60416, 60544, 60672, 60800, 60928, 61056, 61184, 61312,
        256, // quieter than nothing
    ]
    /// How much quieter each of sixteen places between the speakers makes one side.
    private static let panOffsTable: [UInt16] = [0, 13, 26, 41, 57, 75, 94, 116, 141, 169, 203, 244, 297, 372, 500, 4095]
    /// The Sound Blaster mixer's volumes.
    private static let xvol: [UInt8] = [
        0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60,
        64, 68, 72, 76, 80, 85, 89, 93, 97, 101, 105, 109, 113, 117,
        121, 125, 129, 133, 137, 141, 145, 149, 153, 157, 161, 165,
        170, 174, 178, 182, 186, 190, 194, 198, 202, 206, 210, 214,
        218, 222, 226, 230, 234, 238, 242, 246, 250, 255, 255,
    ]

    private let card: ST3Card
    private let samples: UnsafePointer<Int16>
    private let samplesCount: Int
    /// For a song whose samples in stereo are played so: their right sides, at the same places as
    /// their left sides in `samples`, and where those begin.
    private let samplesRight: UnsafePointer<Int16>?
    private let stereoBases: Set<Int>
    /// True for a file with samples Scream Tracker could not hold, whose lengths are not cut to sixteen bits.
    private let wide: Bool
    private let stereo: Bool

    let sinc: UnsafeMutablePointer<Float>
    private let bufferL: UnsafeMutablePointer<Float>, bufferR: UnsafeMutablePointer<Float>
    private var resamplingFrac: UInt64 = 0
    private let resamplingDelta: UInt64
    /// How many samples a second the card makes.
    private let cardRate: Float

    /// For a file that puts channels in ModPlug's reverb (S99), on a Gravis Ultrasound: the reverb,
    /// at the player's rate; what the card's voices sent to it in the sample last made, and the last
    /// sixteen of those, brought to the player's rate as the card's output is; and whether anything
    /// has been sent since the reverb was last given a block.
    private var reverb: ModPlugReverb?
    private var sentL: Int32 = 0, sentR: Int32 = 0
    private let sendL: UnsafeMutablePointer<Float>, sendR: UnsafeMutablePointer<Float>

    // The GUS.
    private let voices: UnsafeMutablePointer<GUSVoice>
    private var gv = 0
    private var activeVoices = 14
    /// How many of its voices the card is given notes on, and how many it mixes: as Scream Tracker
    /// asks, and one more for each of a later tracker's channels past the sixteen (see
    /// `ST3Module.extraChannels`), which no GUS had, the card going on at the rate it has for
    /// the voices asked for.
    private var voicePool = 16, mixedVoices = 14
    private var stchannelpan = [UInt8](repeating: 0, count: 48)
    private var voiceused = [Int8](repeating: 0, count: 64)
    private var channeltrig = [UInt8](repeating: 255, count: 64)
    private var somevoice: UInt8 = 0, voicetry: UInt8 = 0, g_maxvoices: UInt8 = 0

    // The Sound Blaster Pro.
    private let sbVoices: UnsafeMutablePointer<SBVoice>
    /// Each channel's filter, which outlasts the voices that are made afresh for every mixing.
    private let sbFilters: UnsafeMutablePointer<Filter>
    private let postTable: UnsafeMutablePointer<Int8>

    /// The channels left out of the sound, a bit for each, by its number in the player.
    private var muted: UInt64 = 0

    init(card: ST3Card, module: ST3Module, stereo: Bool, extraChannels: Int = 0) {
        self.card = card
        self.stereo = stereo
        samples = UnsafePointer(module.samples)
        samplesCount = module.samplesCount
        let apart = card == .gus && stereo && module.stereoApart
        samplesRight = apart ? module.samplesRight.map { UnsafePointer($0) } : nil
        stereoBases = apart ? module.stereoBases : []
        wide = module.beyondScreamTracker
        sinc = .allocate(capacity: st3Sinc.count)
        for i in 0 ..< st3Sinc.count { sinc[i] = st3Sinc[i] }
        bufferL = .allocate(capacity: 16)
        bufferR = .allocate(capacity: 16)
        bufferL.initialize(repeating: 0, count: 16)
        bufferR.initialize(repeating: 0, count: 16)
        sendL = .allocate(capacity: 16)
        sendR = .allocate(capacity: 16)
        sendL.initialize(repeating: 0, count: 16)
        sendR.initialize(repeating: 0, count: 16)
        voices = .allocate(capacity: 64)
        voices.initialize(repeating: GUSVoice(), count: 64)
        sbVoices = .allocate(capacity: 16)
        sbVoices.initialize(repeating: SBVoice(), count: 16)
        sbFilters = .allocate(capacity: 16)
        sbFilters.initialize(repeating: Filter(), count: 16)
        postTable = .allocate(capacity: 2048)
        postTable.initialize(repeating: 0, count: 2048)

        let output = Double(outputSampleRate)
        let cardRate: Double
        switch card {
        case .gus:
            // The more voices a GUS is asked for, the slower it gets round them all.
            activeVoices = max(14, min(32, Int(module.ultraclick)))
            cardRate = Double(14 * 44100) / Double(activeVoices)
            voicePool = min(64, Int(module.ultraclick) + extraChannels)
            mixedVoices = max(activeVoices, voicePool)
        case .sb:
            cardRate = 1_000_000.0 / Double(256 - (stereo ? 210 : 233))
        }
        resamplingDelta = UInt64((4_294_967_296.0 * (cardRate / output)).rounded())
        self.cardRate = Float(cardRate)
        if card == .gus, module.asksForReverb { reverb = ModPlugReverb(sampleRate: outputSampleRate) }

        switch card {
        case .gus:
            for i in 0 ..< 64 {
                voices[i].LOff = Self.panOffsTable[7]
                voices[i].ROff = Self.panOffsTable[15 - 7]
            }
            g_maxvoices = UInt8(module.ultraclick)
            shutupgus()
            for i in 0 ..< mixedVoices {
                select(i)
                voices[gv].SACI = 3
                voices[gv].SVCI = 3
            }
            for i in 0 ..< 16 {
                let pan: UInt8 = stereo ? (i < 8 ? 0x3 : 0xC) : 7
                stchannelpan[i] = pan
                select(i)
                setBalance(pan)
            }
            for i in ST3Module.firstExtraChannel ..< ST3Player.ACHANNELS { stchannelpan[i] = 7 }
        case .sb:
            // The table that squeezes the sum of the channels into eight bits.
            let mastervol = max(16, Int(module.mastermul & 127))
            let c = (2048 * 16) / mastervol
            let a = (2048 - c) / 2
            let b = a + c
            let delta16 = UInt16(truncatingIfNeeded: 65536 / c)
            var smp16: UInt16 = 0
            for i in 0 ..< 2048 {
                if i < a {
                    postTable[i] = -128
                } else if i < b {
                    postTable[i] = Int8(bitPattern: UInt8(smp16 >> 8) ^ 0x80)
                    smp16 &+= delta16
                } else {
                    postTable[i] = 127
                }
            }
        }
    }

    deinit {
        sinc.deallocate()
        bufferL.deallocate()
        bufferR.deallocate()
        sendL.deallocate()
        sendR.deallocate()
        voices.deallocate()
        sbVoices.deallocate()
        sbFilters.deallocate()
        postTable.deallocate()
    }

    /// Gives a voice its channel's filter (see `ST3Player.playsFilter`): two poles, closing at 110 Hz
    /// times two to the power of a quarter and a twenty-fourth of the cutoff, ringing by 24 dB at
    /// the most, as OpenMPT has it in an S3M file. A voice given a note afresh, or one whose filter
    /// is only now on, starts it from nothing.
    private func tell(_ ch: ST3Channel, _ filter: inout Filter, afresh: Bool) {
        ch.filterChanged = false
        if afresh || ch.filtered && !filter.on {
            filter.y1 = 0
            filter.y2 = 0
            filter.y1R = 0
            filter.y2R = 0
        }
        filter.on = ch.filtered
        guard ch.filtered else { return }
        let damping = powf(10, -Float(ch.resonance) * ((24.0 / 128.0) / 20.0))
        let frequency = min(cardRate * 0.5, max(120, min(20000, 110 * powf(2, 0.25 + Float(ch.cutoff) / 24))))
        let r = frequency * (2 * Float.pi) / cardRate
        let d = (2 * damping - min(2, (1 - 2 * damping) * r)) / r
        let e = 1 / (r * r)
        filter.a0 = 1 / (1 + d + e)
        filter.b0 = (d + e + e) / (1 + d + e)
        filter.b1 = -e / (1 + d + e)
    }

    /// What a filter makes of the next sample, without moving it on.
    @inline(__always) private static func through(_ filter: Filter, _ x: Float) -> Float {
        max(-131_072, min(131_072, x * filter.a0 + filter.y1 * filter.b0 + filter.y2 * filter.b1))
    }

    /// Leaves channels out of the sound, or brings them back: see `Renderer.setMuted`. A bit for
    /// each of the card's channels by its number in the player (the sixteen, and from the 33rd a
    /// later tracker's channels past them), set for one not to be heard.
    ///
    /// How it is done is shaped by the compiler. `render`, with the making of either card's sample
    /// inside it, is as much as will be kept in one piece: a test of each voice there ("is this
    /// one left out?") and one of the two is made a call of, for every sample, at a few hundredths
    /// of the player's speed. So a GUS's voice has an `&` on each side and no test, and a Sound
    /// Blaster's channels are added up as ever, with what is not to be heard taken away first.
    func setMuted(_ channels: UInt64) {
        muted = channels
        // A GUS's voices are their channels': the note's, and the one's before it sliding away.
        // (A Sound Blaster's channels are looked up as they are mixed: see `sbMutedPart`.)
        for i in 0 ..< 64 { voices[i].heard = isMuted(voices[i].owner) ? 0 : -1 }
    }

    /// True if a channel of samples is sounding: it has not come to the end of its sample.
    func isSounding(_ ch: ST3Channel) -> Bool {
        switch card {
        case .gus:
            guard ch.aguschannel >= 0, Int(ch.aguschannel) < mixedVoices else { return false }
            let voice = voices[Int(ch.aguschannel)]
            return voice.SACI & 3 == 0 && voice.SA >= 0
        case .sb:
            return ch.m_speed != 0 && ch.m_base >= 0
        }
    }

    /// Which of the card's sixteen places a channel of samples is at.
    func balance(of ch: ST3Channel) -> UInt8 {
        ch.apanpos >= 0xF0 ? ch.apanpos & 0x0F : stchannelpan[Int(ch.channelnum) & 15]
    }

    /// Puts a channel's voice at one of the card's sixteen places as it plays, on a card that has
    /// them: for a later tracker's commands (see `ST3Player.laterPanning`). Unless it is only moving
    /// for a moment, the channel's next notes start there too.
    func place(_ ch: ST3Channel, balance: UInt8, moving: Bool) {
        if !moving { ch.apanpos = 0xF0 | balance }
        guard stereo, card == .gus, ch.aguschannel >= 0, Int(ch.aguschannel) < mixedVoices else { return }
        let voice = Int(ch.aguschannel)
        voices[voice].LOff = Self.panOffsTable[Int(balance & 15)]
        voices[voice].ROff = Self.panOffsTable[15 - Int(balance & 15)]
    }

    private func isMuted(_ channel: Int) -> Bool {
        channel >= 0 && channel < 64 && muted & (1 << UInt64(channel)) != 0
    }

    // MARK: The GUS's registers

    private func select(_ voice: Int) {
        gv = max(0, min(mixedVoices - 1, voice))
    }

    private func setBalance(_ balance: UInt8) {
        voices[gv].LOff = Self.panOffsTable[Int(balance & 15)]
        voices[gv].ROff = Self.panOffsTable[15 - Int(balance & 15)]
    }

    private func setVolumeSlide(_ ch: ST3Channel, _ currVol: UInt8, _ targetVol: UInt8) {
        guard currVol != targetVol else { return }
        ch.m_oldvol = targetVol
        let currLogVol = Self.gusVolTable[min(64, Int(currVol))], targetLogVol = Self.gusVolTable[min(64, Int(targetVol))]
        voices[gv].SVRI = UInt16(15 & 63) << 3
        voices[gv].SVLI = currLogVol >> 1
        if currLogVol < targetLogVol {
            voices[gv].SVSI = (currLogVol >> 8) << 7
            voices[gv].SVEI = (targetLogVol >> 8) << 7
            voices[gv].SVCI = 0 // a rising ramp
        } else {
            voices[gv].SVSI = (targetLogVol >> 8) << 7
            voices[gv].SVEI = (currLogVol >> 8) << 7
            voices[gv].SVCI = 64 // a falling one
        }
    }

    private func shutupgus() {
        for i in 0 ..< voicePool {
            select(i)
            voices[gv].SACI = 0b0000_0011
            voices[gv].SVLI = 0
            setBalance(7)
            voices[gv].SVCI = 0b0000_0011
            voiceused[i] = 0
        }
    }

    /// Finds voices that can be given to a new note.
    private func freevoices() {
        // Those that have stopped.
        var voicesfreed = false
        for i in 0 ..< voicePool where voiceused[i] <= 0 {
            select(i)
            if voices[gv].SACI & 1 != 0 {
                voiceused[i] = 0
                voicesfreed = true
            }
        }
        if voicesfreed { return }
        // Or the one that has been fading out the longest.
        var voice = -1
        var notusedcount: Int8 = -103
        for i in 0 ..< voicePool where voiceused[i] <= 0 && voiceused[i] >= notusedcount {
            voice = i
            notusedcount = voiceused[i]
        }
        if voice == -1 {
            // Or any, by turns.
            somevoice &+= 1
            if somevoice >= voicePool { somevoice = 0 }
            voiceused[Int(somevoice)] = 0
        } else {
            voiceused[voice] = 0
        }
    }

    private func noLoop(_ ch: ST3Channel) -> Bool { wide ? ch.m_loop == 0xFFFF_FFFF : UInt16(truncatingIfNeeded: ch.m_loop) == 65535 }
    private func address(_ ch: ST3Channel, _ offset: UInt32) -> Int { ch.m_base < 0 || offset > 0x7FFF_FFF ? -1 : ch.m_base + Int(offset) }

    /// After a tick: the voices that were given a note are started.
    func gusTrigger() {
        for i in 0 ..< 64 {
            if voiceused[i] < 0 { voiceused[i] += 1 }
            if channeltrig[i] != 255 {
                select(i)
                voices[gv].SACI = channeltrig[i]
                channeltrig[i] = 255
            }
        }
    }

    /// Where a channel of samples lies between the two sides, from -1 on the left to 1 on the right.
    func side(of ch: ST3Channel) -> Float {
        let channel = Int(ch.channelnum)
        guard stereo, channel < 16 || channel >= ST3Module.firstExtraChannel && card == .gus else { return 0 }
        switch card {
        case .gus:
            let balance = ch.apanpos >= 0xF0 ? ch.apanpos & 0x0F : stchannelpan[channel]
            return (Float(balance) - 7.5) / 7.5
        case .sb:
            // The Sound Blaster has a channel on one side or the other, or on both.
            let mixtype = ch.amixtype
            if mixtype == 0 || mixtype == 2 { return channel >= 8 ? -1 : 1 }
            if mixtype == 1 || mixtype == 3 { return channel < 8 ? -1 : 1 }
            return 0
        }
    }

    /// After a tick: what has changed on a channel is told to the card.
    func gusUpdate(_ ch: ST3Channel, stereo: Bool) {
        if ch.aguschannel >= 0 {
            select(Int(ch.aguschannel))
            if ch.m_oldpos == ch.m_pos {
                // The same note going on: where it has got to, and its pitch and volume.
                if ch.m_speed != 0 {
                    var pos = UInt32(truncatingIfNeeded: ch.m_base < 0 || voices[gv].SA < 0 ? 0x7FFF_FFFF : voices[gv].SA - ch.m_base)
                    if pos >= (wide ? UInt32(truncatingIfNeeded: samplesCount) : 65536) { pos = 0 }
                    ch.m_pos = pos
                    ch.m_oldpos = pos
                }
                let frequency: UInt16
                switch g_maxvoices {
                case 16: frequency = UInt16(truncatingIfNeeded: ch.m_speed >> 6)
                case 24: frequency = UInt16(truncatingIfNeeded: (ch.m_speed &+ ch.m_speed) / 85)
                case 32: frequency = UInt16(truncatingIfNeeded: ch.m_speed >> 5)
                default: frequency = UInt16(truncatingIfNeeded: ch.m_speed)
                }
                voices[gv].SFCI = frequency >> 1
                setVolumeSlide(ch, ch.m_oldvol, ch.m_vol)
                if ch.filterChanged { tell(ch, &voices[gv].filter, afresh: false) }
                voices[gv].reverb = ch.reverb ? -1 : 0
                return
            }
            // A new note: the old one slides away to nothing on its voice, and the channel takes another.
            setVolumeSlide(ch, ch.m_oldvol, 64)
            voiceused[Int(ch.aguschannel)] = -4
        }

        var nochannel = true
        while nochannel {
            ch.m_oldpos = ch.m_pos
            for _ in 0 ..< voicePool {
                voicetry &+= 1
                if voicetry >= voicePool { voicetry = 0 }
                if voiceused[Int(voicetry)] == 0 {
                    nochannel = false
                    break
                }
            }
            if nochannel { freevoices() }
        }

        if wide ? ch.m_end == 0 : UInt16(truncatingIfNeeded: ch.m_end) == 0 {
            voiceused[Int(voicetry)] = 0
            ch.aguschannel = -1
            return
        }
        voiceused[Int(voicetry)] = 1
        ch.aguschannel = Int8(voicetry)
        select(Int(voicetry))
        voices[gv].owner = Int(ch.channelnum)
        voices[gv].heard = isMuted(Int(ch.channelnum)) ? 0 : -1
        voices[gv].stereo = samplesRight != nil && stereoBases.contains(ch.m_base)
        ch.filterBegun = false
        tell(ch, &voices[gv].filter, afresh: true)
        voices[gv].reverb = ch.reverb ? -1 : 0
        if ch.m_end == 0 {
            voiceused[Int(ch.aguschannel)] = -1
            ch.aguschannel = -1
            ch.m_vol = 0
            ch.m_oldvol = 0
        }

        voices[gv].SACI = 0b0000_0010 // stopped
        voices[gv].SVLI = 0
        if stereo, ch.apanpos >= 0xF0 {
            setBalance(ch.apanpos & 0x0F)
        } else {
            setBalance(stchannelpan[Int(ch.channelnum)])
        }
        voices[gv].SAE = address(ch, ch.m_end)
        voices[gv].SAS = noLoop(ch) ? address(ch, 0) : address(ch, ch.m_loop)
        voices[gv].SA = address(ch, ch.m_pos)
        voices[gv].SA_frac = 0
        voices[gv].SFCI = UInt16(truncatingIfNeeded: ch.m_speed >> 6) >> 1

        if ch.aguschannel >= 0 {
            if ch.m_end == 0 {
                channeltrig[Int(ch.aguschannel)] = 0b0000_0010 // stop
            } else if noLoop(ch) {
                channeltrig[Int(ch.aguschannel)] = 0b0000_0000
            } else {
                channeltrig[Int(ch.aguschannel)] = 0b0000_1000 // loop
            }
        }
        setVolumeSlide(ch, ch.m_vol == 1 ? 2 : 1, ch.m_vol)
    }

    // MARK: Sound

    /// One sample of the GUS's own output.
    @inline(__always) private func gusSample() -> (Float, Float) {
        var left: Int32 = 0, right: Int32 = 0
        var sentLeft: Int32 = 0, sentRight: Int32 = 0
        for i in 0 ..< mixedVoices {
            let v = voices + i
            if v.pointee.SACI & 2 != 0 { v.pointee.SACI |= 1 }
            if v.pointee.SVCI & 2 != 0 { v.pointee.SVCI |= 1 }

            if v.pointee.SACI & 1 == 0, v.pointee.SA >= 0, v.pointee.SAE >= 0 {
                if v.pointee.SA >= v.pointee.SAE {
                    // The end: round the loop, or stop.
                    if v.pointee.SACI & 8 != 0, v.pointee.SAS >= 0 {
                        let over = v.pointee.SA - v.pointee.SAE, loopLength = v.pointee.SAE - v.pointee.SAS
                        v.pointee.SA = loopLength <= 0 ? v.pointee.SAS : v.pointee.SAS + over % loopLength
                    } else {
                        v.pointee.SACI |= 1
                    }
                }
                if v.pointee.SACI & 1 == 0 {
                    let at = v.pointee.SA
                    let first = at >= 0 && at < samplesCount ? Int32(samples[at]) : 0
                    let second = at + 1 >= 0 && at + 1 < samplesCount ? Int32(samples[at + 1]) : 0
                    var smp = Int32(Int16(truncatingIfNeeded: first &+ (((second &- first) &* Int32(Int16(bitPattern: v.pointee.SA_frac))) >> 9)))
                    // The card's volumes are logarithms: a part that doubles, and a part that scales.
                    let vol = Int32(v.pointee.SVLI >> 3)
                    let volL = max(0, Int32(Int16(truncatingIfNeeded: vol - Int32(v.pointee.LOff))))
                    let volR = max(0, Int32(Int16(truncatingIfNeeded: vol - Int32(v.pointee.ROff))))
                    // (A sample in stereo: its right side, read as its left is, is what goes to the right.)
                    var smpR = smp
                    if v.pointee.stereo, let samplesRight {
                        let firstR = at >= 0 && at < samplesCount ? Int32(samplesRight[at]) : 0
                        let secondR = at + 1 >= 0 && at + 1 < samplesCount ? Int32(samplesRight[at + 1]) : 0
                        smpR = Int32(Int16(truncatingIfNeeded: firstR &+ (((secondR &- firstR) &* Int32(Int16(bitPattern: v.pointee.SA_frac))) >> 9)))
                    }
                    if v.pointee.filter.on {
                        // (A later tracker's file: the sample goes through the channel's filter.)
                        let out = Self.through(v.pointee.filter, Float(smp))
                        v.pointee.filter.y2 = v.pointee.filter.y1
                        v.pointee.filter.y1 = out
                        if v.pointee.stereo {
                            var right = v.pointee.filter
                            right.y1 = right.y1R
                            right.y2 = right.y2R
                            let outR = Self.through(right, Float(smpR))
                            v.pointee.filter.y2R = v.pointee.filter.y1R
                            v.pointee.filter.y1R = outR
                            smpR = Int32(outR)
                            smp = Int32(out)
                        } else {
                            smp = Int32(out)
                            smpR = smp
                        }
                    }
                    if smp < v.pointee.low { v.pointee.low = smp }
                    if smp > v.pointee.high { v.pointee.high = smp }
                    // (A voice of a channel that is left out of the sound adds nothing to it. One in
                    // ModPlug's reverb is added to what is sent there instead.)
                    let outL = ((smp &* (256 + (volL & 0xFF))) >> (24 - (volL >> 8))) & v.pointee.heard
                    let outR = ((smpR &* (256 + (volR & 0xFF))) >> (24 - (volR >> 8))) & v.pointee.heard
                    left &+= outL & ~v.pointee.reverb
                    right &+= outR & ~v.pointee.reverb
                    sentLeft &+= outL & v.pointee.reverb
                    sentRight &+= outR & v.pointee.reverb
                    v.pointee.SA_frac &+= v.pointee.SFCI
                    v.pointee.SA += Int(v.pointee.SA_frac >> 9)
                    v.pointee.SA_frac &= (1 << 9) - 1
                }
            }

            if v.pointee.SVCI & 1 == 0 {
                // The volume on its way from one level to another.
                if v.pointee.SVCI & 64 != 0 {
                    v.pointee.SVLI &-= v.pointee.SVRI
                    if Int16(bitPattern: v.pointee.SVLI) <= Int16(bitPattern: v.pointee.SVSI) {
                        v.pointee.SVLI = v.pointee.SVSI
                        v.pointee.SVCI |= 1
                    }
                } else {
                    v.pointee.SVLI &+= v.pointee.SVRI
                    if v.pointee.SVLI >= v.pointee.SVEI {
                        v.pointee.SVLI = v.pointee.SVEI
                        v.pointee.SVCI |= 1
                    }
                }
            }
        }
        sentL = sentLeft
        sentR = sentRight
        return (Float(max(-32768, min(32767, left))) * (1.0 / 32768.0), Float(max(-32768, min(32767, right))) * (1.0 / 32768.0))
    }

    /// What the channels left out of the sound are about to add to the two sides of a Sound
    /// Blaster's next sample: what `sbSample` will make of each of them, worked out before it does,
    /// for it to take away. The two are to be kept alike. It is done so, and only when there is
    /// such a channel, so that the mixing itself asks nothing more of each channel than it did.
    @inline(never)
    private func sbMutedPart() -> (UInt16, UInt16) {
        var left: UInt16 = 0, right: UInt16 = 0
        for i in 0 ..< 16 where muted & (1 << UInt64(i)) != 0 {
            let ch = sbVoices + i
            if ch.pointee.speed == 0 || ch.pointee.pos == 0xFFFF_FFFF || ch.pointee.base < 0 || ch.pointee.pos >= ch.pointee.end { continue }
            let at = ch.pointee.base &+ Int(truncatingIfNeeded: ch.pointee.pos)
            let value = at >= 0 && at < samplesCount ? samples[at] : 0
            // (Through the channel's filter, as `sbSample` will have it, if it has one.)
            let byte = sbFilters[i].on ? Int(Int16(max(-32768, min(32767, Self.through(sbFilters[i], Float(value)))))) >> 8 : Int(value >> 8)
            let smp = UInt16(truncatingIfNeeded: (byte * Int(Self.xvol[min(64, Int(ch.pointee.vol))])) >> 8)
            if stereo {
                let mixtype = ch.pointee.mixtype
                if mixtype == 0 || mixtype == 2 {
                    if i >= 8 { left &+= smp } else { right &+= smp }
                } else if mixtype == 1 || mixtype == 3 {
                    if i < 8 { left &+= smp } else { right &+= smp }
                } else {
                    left &+= smp
                    right &+= smp
                }
            } else {
                left &+= smp
                right &+= smp
            }
        }
        return (left, right)
    }

    /// One sample of what Scream Tracker mixes for a Sound Blaster Pro.
    @inline(__always) private func sbSample() -> (Float, Float) {
        var left: UInt16 = 1024, right: UInt16 = 1024
        // Every channel is added in below, as ever: what those left out of the sound will add is
        // taken away here first, which comes to the same sum without them.
        if muted & 0xFFFF != 0 {
            let unheard = sbMutedPart()
            left &-= unheard.0
            right &-= unheard.1
        }
        for i in 0 ..< 16 {
            let ch = sbVoices + i
            if ch.pointee.speed == 0 || ch.pointee.pos == 0xFFFF_FFFF || ch.pointee.base < 0 || ch.pointee.pos >= ch.pointee.end { continue }
            let at = ch.pointee.base &+ Int(truncatingIfNeeded: ch.pointee.pos)
            let value = at >= 0 && at < samplesCount ? samples[at] : 0
            var byte = Int(value >> 8)
            if sbFilters[i].on {
                // (A later tracker's file: the sample goes through the channel's filter.)
                let out = Self.through(sbFilters[i], Float(value))
                sbFilters[i].y2 = sbFilters[i].y1
                sbFilters[i].y1 = out
                byte = Int(Int16(max(-32768, min(32767, out)))) >> 8
            }
            let level = (byte * Int(Self.xvol[min(64, Int(ch.pointee.vol))])) >> 8
            let smp = UInt16(truncatingIfNeeded: level)
            if level < Int(ch.pointee.low) { ch.pointee.low = Int32(level) }
            if level > Int(ch.pointee.high) { ch.pointee.high = Int32(level) }
            if stereo {
                let mixtype = ch.pointee.mixtype
                if mixtype == 0 || mixtype == 2 {
                    if i >= 8 { left &+= smp } else { right &+= smp }
                } else if mixtype == 1 || mixtype == 3 {
                    if i < 8 { left &+= smp } else { right &+= smp }
                } else {
                    left &+= smp
                    right &+= smp
                }
            } else {
                left &+= smp
                right &+= smp
            }
            ch.pointee.poslow &+= ch.pointee.speed
            ch.pointee.pos &+= ch.pointee.poslow >> 16
            ch.pointee.poslow &= 0xFFFF
            if ch.pointee.pos >= ch.pointee.end {
                if wide ? ch.pointee.loop != 0xFFFF_FFFF : UInt16(truncatingIfNeeded: ch.pointee.loop) != 65535 {
                    // Back by the length of the loop, which is safe for the loop having been written out again.
                    let back = ch.pointee.loop &- ch.pointee.end
                    ch.pointee.pos &+= wide ? back : UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: back)))
                } else {
                    ch.pointee.speed = 0
                }
            }
        }
        return (Float(postTable[Int(left & 2047)]) * (1.0 / 128.0), Float(postTable[Int(right & 2047)]) * (1.0 / 128.0))
    }

    /// The card's sound as OpenMPT's mix has it, for its reverb: 27 bits for a sample at its loudest,
    /// which the card's loudest is a little over half of, set by measure beside libopenmpt.
    private static let reverbScale = 0.57 * Double(1 << 27)

    /// `render` for a Gravis Ultrasound with ModPlug's reverb: what is sent to it is brought to the
    /// player's rate as the card's output is, and given to it in OpenMPT's whole numbers and blocks,
    /// and what it makes, which has in it what was sent, is added to the card's output.
    private func renderWithReverb(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int, _ reverb: ModPlugReverb) {
        var frac = resamplingFrac
        let delta = resamplingDelta
        withUnsafeTemporaryAllocation(of: Float.self, capacity: count * 2) { sent in
            guard let sent = sent.baseAddress else { return }
            var sentAny: Int32 = 0
            for n in 0 ..< count {
                frac &+= delta
                while frac >= 1 << 32 {
                    frac -= 1 << 32
                    for i in 0 ..< 15 {
                        bufferL[i] = bufferL[i + 1]
                        bufferR[i] = bufferR[i + 1]
                        sendL[i] = sendL[i + 1]
                        sendR[i] = sendR[i + 1]
                    }
                    let (l, r) = gusSample()
                    bufferL[15] = l
                    bufferR[15] = r
                    sendL[15] = Float(sentL) * (1.0 / 32768.0)
                    sendR[15] = Float(sentR) * (1.0 / 32768.0)
                    sentAny |= sentL | sentR
                }
                let frac32 = UInt32(truncatingIfNeeded: frac)
                let phase = Int(frac32 >> 24)
                let between = Float(Int32(frac32 & 0xFF_FFFF)) * (1.0 / 16_777_216.0)
                let sinc1 = sinc + (phase << 4), sinc2 = sinc + ((phase + 1) << 4)
                var sumL: Float = 0, sumR: Float = 0, sumSL: Float = 0, sumSR: Float = 0
                for i in 0 ..< 16 {
                    let y1 = sinc1[i], y2 = sinc2[i]
                    let y = y1 + ((y2 - y1) * between)
                    sumL += bufferL[i] * y
                    sumR += bufferR[i] * y
                    sumSL += sendL[i] * y
                    sumSR += sendR[i] * y
                }
                left[n] = sumL
                right[n] = sumR
                sent[n * 2] = sumSL
                sent[n * 2 + 1] = sumSR
            }
            let scale = Self.reverbScale, back = Float(1 / scale)
            withUnsafeTemporaryAllocation(of: Int32.self, capacity: ModPlugReverb.maxFrames * 2) { added in
                guard let added = added.baseAddress else { return }
                var done = 0
                while done < count {
                    let frames = min(ModPlugReverb.maxFrames, count - done)
                    let send = reverb.sendBuffer
                    if sentAny != 0 {
                        reverb.touch(send: send, frames: frames)
                        let from = sent + done * 2
                        for i in 0 ..< frames * 2 { send[i] &+= Int32(max(-2.0e9, min(2.0e9, (Double(from[i]) * scale).rounded()))) }
                    }
                    added.update(repeating: 0, count: frames * 2)
                    reverb.process(main: added, send: send, frames: frames)
                    for i in 0 ..< frames {
                        left[done + i] += Float(added[i * 2]) * back
                        right[done + i] += Float(added[i * 2 + 1]) * back
                    }
                    done += frames
                }
            }
        }
        resamplingFrac = frac
    }

    /// How loud each of the card's sixteen channels was in the samples made since this was last asked.
    func takeLevels(into levels: inout [Float]) {
        for channel in 0 ..< 16 { levels[channel] = 0 }
        for channel in ST3Module.firstExtraChannel ..< min(levels.count, ST3Player.ACHANNELS) { levels[channel] = 0 }
        switch card {
        case .gus:
            // The card's volumes are logarithms; this is what one comes to, as a part of the loudest.
            func gain(_ volume: Int32) -> Float {
                Float(256 + (volume & 0xFF)) * Float(1 << min(15, Int(volume >> 8)))
            }
            let full = gain(Int32(Self.gusVolTable[63] >> 4))
            for i in 0 ..< mixedVoices {
                let v = voices + i
                if v.pointee.high > v.pointee.low, v.pointee.owner >= 0, v.pointee.owner < 16 || v.pointee.owner >= ST3Module.firstExtraChannel,
                   v.pointee.owner < levels.count {
                    // (The volume is where it has got to: a voice that is sliding away has all but gone.)
                    let level = min(1, Float(v.pointee.high - v.pointee.low) * (1.0 / 65536.0) * gain(Int32(v.pointee.SVLI >> 3)) / full)
                    // A channel is the loudest of its voices: the note, and the one before it sliding away.
                    if level > levels[v.pointee.owner] { levels[v.pointee.owner] = level }
                }
                v.pointee.low = .max
                v.pointee.high = .min
            }
        case .sb:
            // (Each voice's swing starts afresh when the channels are next read.)
            for i in 0 ..< 16 where sbVoices[i].high > sbVoices[i].low {
                levels[i] = min(1, Float(sbVoices[i].high - sbVoices[i].low) / 254)
            }
        }
    }

    /// Makes `count` samples at the player's rate. For a Sound Blaster the channels are read first and
    /// told afterwards where they have got to.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int, channels: [ST3Channel]) {
        if card == .sb {
            for i in 0 ..< 16 {
                let ch = channels[i]
                sbVoices[i] = SBVoice(base: ch.m_base, pos: ch.m_pos, poslow: ch.m_poslow, end: ch.m_end, loop: ch.m_loop, speed: ch.m_speed,
                                      vol: ch.m_vol, mixtype: ch.amixtype)
                if ch.filterChanged || ch.filterBegun {
                    tell(ch, &sbFilters[i], afresh: ch.filterBegun)
                    ch.filterBegun = false
                }
            }
        }
        if let reverb { return renderWithReverb(left: left, right: right, count: count, reverb) }
        var frac = resamplingFrac
        let delta = resamplingDelta
        for n in 0 ..< count {
            frac &+= delta
            while frac >= 1 << 32 {
                frac -= 1 << 32
                for i in 0 ..< 15 {
                    bufferL[i] = bufferL[i + 1]
                    bufferR[i] = bufferR[i + 1]
                }
                let (l, r) = card == .gus ? gusSample() : sbSample()
                bufferL[15] = l
                bufferR[15] = r
            }
            let frac32 = UInt32(truncatingIfNeeded: frac)
            let phase = Int(frac32 >> 24)
            let between = Float(Int32(frac32 & 0xFF_FFFF)) * (1.0 / 16_777_216.0)
            let sinc1 = sinc + (phase << 4), sinc2 = sinc + ((phase + 1) << 4)
            var sumL: Float = 0, sumR: Float = 0
            for i in 0 ..< 16 {
                let y1 = sinc1[i], y2 = sinc2[i]
                let y = y1 + ((y2 - y1) * between)
                sumL += bufferL[i] * y
                sumR += bufferR[i] * y
            }
            left[n] = sumL
            right[n] = sumR
        }
        resamplingFrac = frac
        if card == .sb {
            for i in 0 ..< 16 {
                channels[i].m_pos = sbVoices[i].pos
                channels[i].m_poslow = sbVoices[i].poslow
                channels[i].m_speed = sbVoices[i].speed
            }
        }
    }
}
