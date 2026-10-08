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
    private struct GUSVoice {
        // Where in the samples it is, where its loop starts and where it ends; -1 for nowhere.
        var SA = -1, SAS = -1, SAE = -1
        var SA_frac: UInt16 = 0
        var SACI: UInt8 = 1, SVCI: UInt8 = 1
        var LOff: UInt16 = 0, ROff: UInt16 = 0
        var SVRI: UInt16 = 0, SVLI: UInt16 = 0, SVSI: UInt16 = 0, SVEI: UInt16 = 0
        var SFCI: UInt16 = 1 << 9
    }

    /// What of a channel the Sound Blaster's mixer needs, kept apart from the channel while it mixes.
    private struct SBVoice {
        var base = -1
        var pos: UInt32 = 0, poslow: UInt32 = 0, end: UInt32 = 0, loop: UInt32 = 0, speed: UInt32 = 0
        var vol: UInt8 = 0
        var mixtype: Int8 = 0
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
    /// True for a file with samples Scream Tracker could not hold, whose lengths are not cut to sixteen bits.
    private let wide: Bool
    private let stereo: Bool

    private let sinc: UnsafeMutablePointer<Float>
    private let bufferL: UnsafeMutablePointer<Float>, bufferR: UnsafeMutablePointer<Float>
    private var resamplingFrac: UInt64 = 0
    private let resamplingDelta: UInt64

    // The GUS.
    private let voices: UnsafeMutablePointer<GUSVoice>
    private var gv = 0
    private var activeVoices = 14
    private var stchannelpan = [UInt8](repeating: 0, count: 48)
    private var voiceused = [Int8](repeating: 0, count: 32)
    private var channeltrig = [UInt8](repeating: 255, count: 32)
    private var somevoice: UInt8 = 0, voicetry: UInt8 = 0, g_maxvoices: UInt8 = 0

    // The Sound Blaster Pro.
    private let sbVoices: UnsafeMutablePointer<SBVoice>
    private let postTable: UnsafeMutablePointer<Int8>

    init(card: ST3Card, module: ST3Module, stereo: Bool) {
        self.card = card
        self.stereo = stereo
        samples = UnsafePointer(module.samples)
        samplesCount = module.samplesCount
        wide = module.beyondScreamTracker
        sinc = .allocate(capacity: st3Sinc.count)
        for i in 0 ..< st3Sinc.count { sinc[i] = st3Sinc[i] }
        bufferL = .allocate(capacity: 16)
        bufferR = .allocate(capacity: 16)
        bufferL.initialize(repeating: 0, count: 16)
        bufferR.initialize(repeating: 0, count: 16)
        voices = .allocate(capacity: 32)
        voices.initialize(repeating: GUSVoice(), count: 32)
        sbVoices = .allocate(capacity: 16)
        sbVoices.initialize(repeating: SBVoice(), count: 16)
        postTable = .allocate(capacity: 2048)
        postTable.initialize(repeating: 0, count: 2048)

        let output = Double(outputSampleRate)
        let cardRate: Double
        switch card {
        case .gus:
            // The more voices a GUS is asked for, the slower it gets round them all.
            activeVoices = max(14, min(32, Int(module.ultraclick)))
            cardRate = Double(14 * 44100) / Double(activeVoices)
        case .sb:
            cardRate = 1_000_000.0 / Double(256 - (stereo ? 210 : 233))
        }
        resamplingDelta = UInt64((4_294_967_296.0 * (cardRate / output)).rounded())

        switch card {
        case .gus:
            for i in 0 ..< 32 {
                voices[i].LOff = Self.panOffsTable[7]
                voices[i].ROff = Self.panOffsTable[15 - 7]
            }
            g_maxvoices = UInt8(module.ultraclick)
            shutupgus()
            for i in 0 ..< 32 {
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
        voices.deallocate()
        sbVoices.deallocate()
        postTable.deallocate()
    }

    // MARK: The GUS's registers

    private func select(_ voice: Int) {
        gv = max(0, min(activeVoices - 1, voice))
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
        for i in 0 ..< Int(g_maxvoices) {
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
        for i in 0 ..< Int(g_maxvoices) where voiceused[i] <= 0 {
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
        for i in 0 ..< Int(g_maxvoices) where voiceused[i] <= 0 && voiceused[i] >= notusedcount {
            voice = i
            notusedcount = voiceused[i]
        }
        if voice == -1 {
            // Or any, by turns.
            somevoice &+= 1
            if somevoice >= g_maxvoices { somevoice = 0 }
            voiceused[Int(somevoice)] = 0
        } else {
            voiceused[voice] = 0
        }
    }

    private func noLoop(_ ch: ST3Channel) -> Bool { wide ? ch.m_loop == 0xFFFF_FFFF : UInt16(truncatingIfNeeded: ch.m_loop) == 65535 }
    private func address(_ ch: ST3Channel, _ offset: UInt32) -> Int { ch.m_base < 0 || offset > 0x7FFF_FFF ? -1 : ch.m_base + Int(offset) }

    /// After a tick: the voices that were given a note are started.
    func gusTrigger() {
        for i in 0 ..< 32 {
            if voiceused[i] < 0 { voiceused[i] += 1 }
            if channeltrig[i] != 255 {
                select(i)
                voices[gv].SACI = channeltrig[i]
                channeltrig[i] = 255
            }
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
                return
            }
            // A new note: the old one slides away to nothing on its voice, and the channel takes another.
            setVolumeSlide(ch, ch.m_oldvol, 64)
            voiceused[Int(ch.aguschannel)] = -4
        }

        var nochannel = true
        while nochannel {
            ch.m_oldpos = ch.m_pos
            for _ in 0 ..< Int(g_maxvoices) {
                voicetry &+= 1
                if voicetry >= g_maxvoices { voicetry = 0 }
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
        for i in 0 ..< activeVoices {
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
                    let smp = Int32(Int16(truncatingIfNeeded: first &+ (((second &- first) &* Int32(Int16(bitPattern: v.pointee.SA_frac))) >> 9)))
                    // The card's volumes are logarithms: a part that doubles, and a part that scales.
                    let vol = Int32(v.pointee.SVLI >> 3)
                    let volL = max(0, Int32(Int16(truncatingIfNeeded: vol - Int32(v.pointee.LOff))))
                    let volR = max(0, Int32(Int16(truncatingIfNeeded: vol - Int32(v.pointee.ROff))))
                    left &+= (smp &* (256 + (volL & 0xFF))) >> (24 - (volL >> 8))
                    right &+= (smp &* (256 + (volR & 0xFF))) >> (24 - (volR >> 8))
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
        return (Float(max(-32768, min(32767, left))) * (1.0 / 32768.0), Float(max(-32768, min(32767, right))) * (1.0 / 32768.0))
    }

    /// One sample of what Scream Tracker mixes for a Sound Blaster Pro.
    @inline(__always) private func sbSample() -> (Float, Float) {
        var left: UInt16 = 1024, right: UInt16 = 1024
        for i in 0 ..< 16 {
            let ch = sbVoices + i
            if ch.pointee.speed == 0 || ch.pointee.pos == 0xFFFF_FFFF || ch.pointee.base < 0 || ch.pointee.pos >= ch.pointee.end { continue }
            let at = ch.pointee.base &+ Int(truncatingIfNeeded: ch.pointee.pos)
            let byte = at >= 0 && at < samplesCount ? Int(samples[at] >> 8) : 0
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

    /// Makes `count` samples at the player's rate. For a Sound Blaster the channels are read first and
    /// told afterwards where they have got to.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int, channels: [ST3Channel]) {
        if card == .sb {
            for i in 0 ..< 16 {
                let ch = channels[i]
                sbVoices[i] = SBVoice(base: ch.m_base, pos: ch.m_pos, poslow: ch.m_poslow, end: ch.m_end, loop: ch.m_loop, speed: ch.m_speed,
                                      vol: ch.m_vol, mixtype: ch.amixtype)
            }
        }
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
