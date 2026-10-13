// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how it plays an instrument on the AdLib's FM chip (`soundlib/OPL.cpp`, and what `soundlib/Snd_fx.cpp`
// and `soundlib/Sndmix.cpp` ask of it).

/// The AdLib's FM chip as OpenMPT plays it: an instrument of an MPTM file can be a patch for the
/// chip in place of a sample, and its notes are then the chip's.
///
/// The chip is the OPL3, with eighteen voices of two operators each, and OpenMPT gives them out as
/// notes ask for them: a note takes a voice nobody has, or one whose key has been let go. The
/// replayer plays such a note as it plays any other, on a voice of its own with a sample that has
/// no sound in it, and so everything that can be done to a note is done to this one: its volume,
/// its envelopes and its fading, its slides and vibrato, and what becomes of it when the next note
/// arrives. After each tick this looks at what the replayer's voices have come to, and tells the
/// chip: a patch for a note that has begun, and for every note that is sounding a pitch, a level
/// and a side.
///
/// OpenMPT knows a note by the channel it is on, and a note that its channel has let go to make
/// room for the next by the place it is moved to. Here the first is the channel's number, and the
/// second is the replayer's voice, counted from after the channels.
///
/// OpenMPT's own chip is another emulator of the OPL3, so what is heard is not, sample for sample,
/// what it plays; what is told to the chip is the same.
final class OpenMPTAdLib {
    static let voiceCount = 18
    /// The replayer keeps a note's pitch as the rate its sample is played at, a whole number of
    /// samples a second, which for a sample is as fine as is needed. The chip's pitch is finer than
    /// that for a low note, and OpenMPT keeps a rate in sixteenths. So where a file slides its
    /// notes in proportion to their pitch ("linear slides"), a note for the chip has its rate kept
    /// multiplied by sixteen, and every slide leaves it so; where a file slides them the Amiga's
    /// way, which goes by the rate itself, it cannot be.
    static let fineShift = 4
    /// True if the rates of the replayer this plays for are kept so.
    var fine = false

    /// What the file asks of how the chip is played, from its "playback behaviours".
    struct Behaviour {
        /// True if a note that is fading goes on being told its pitch and level, and is cut off the
        /// chip when it has faded: OpenMPT's way since its version 1.29. Before, a note left to
        /// fade was let ring as it was.
        var flexibleNoteOff = true
        /// True if a note that its channel lets go, to fade or to have its key let go, keeps its
        /// voice on the chip. Before OpenMPT 1.30 it gave the voice up to the note after it.
        var keepsVoiceWhenLetGo = true
        /// True unless the file asks for Impulse Tracker's way with a channel in surround, which
        /// is that nothing moves it: OpenMPT's own lets an instrument's envelope move it to one side.
        var surroundIsMoved = true
    }

    private static let invalid: UInt8 = 0xFF, wasCut: UInt8 = 0x80, voiceMask: UInt8 = 0x7F
    private static let KEYON_BIT: UInt8 = 0x20
    private static let noOwner = -1

    // The chip's registers, by OpenMPT's names for them.
    private static let AM_VIB = 0x20, KSL_LEVEL = 0x40, ATTACK_DECAY = 0x60, SUSTAIN_RELEASE = 0x80, WAVE_SELECT = 0xE0
    private static let FNUM_LOW = 0xA0, KEYON_BLOCK = 0xB0, FEEDBACK_CONNECTION = 0xC0
    private static let CONNECTION_BIT: UInt8 = 0x01, VOICE_TO_LEFT: UInt8 = 0x10, VOICE_TO_RIGHT: UInt8 = 0x20, STEREO_BITS: UInt8 = 0x30
    private static let KSL_MASK: UInt8 = 0xC0, TOTAL_LEVEL_MASK: UInt8 = 0x3F

    private let behaviour: Behaviour
    private let chip: UnsafeMutablePointer<OPL3Chip>

    // OPL.h's own.
    private var m_KeyOnBlock = [UInt8](repeating: 0, count: OpenMPTAdLib.voiceCount)
    /// Which note has each of the chip's voices, and which voice each note has: a note is a number
    /// below 64 for a channel's own, and 64 and the replayer's voice for one the channel has let go.
    private var m_OPLtoChan = [Int](repeating: OpenMPTAdLib.noOwner, count: OpenMPTAdLib.voiceCount)
    private var m_ChanToOPL = [UInt8](repeating: OpenMPTAdLib.invalid, count: MAX_HOST_CHANNELS + MAX_SLAVE_CHANNELS)
    private var m_Patches = [[UInt8]](repeating: [UInt8](repeating: 0, count: 12), count: OpenMPTAdLib.voiceCount)

    // What the replayer's voices were when last looked at.
    /// The note each of the replayer's voices is on the chip as; less than nought for none.
    private var attached = [Int](repeating: OpenMPTAdLib.noOwner, count: MAX_SLAVE_CHANNELS)
    /// How many notes each had been given when it was attached, to tell the next from it.
    private var started = [UInt8](repeating: 0, count: MAX_SLAVE_CHANNELS)
    private var patchOf = [IT2Sample?](repeating: nil, count: MAX_SLAVE_CHANNELS)
    /// The voice of the replayer's that is playing each channel's own note on the chip.
    private var owned = [Int](repeating: OpenMPTAdLib.noOwner, count: MAX_HOST_CHANNELS)

    /// What each register of the chip's two sets is to be set to, in the order they were set since
    /// the chip last made sound: the register in the high bits, its value in the low eight.
    private var pending: [UInt32] = []
    /// What each was last set to, so that the chip is told only of a change.
    private var written = [Int16](repeating: -1, count: 512)

    // From the chip's rate to the player's: as `ST3AdLib` does it.
    private let window: UnsafeMutablePointer<Float>
    private let sinc: UnsafeMutablePointer<Float>
    private var position: UInt64 = 0
    private let step: UInt64

    /// Every register set since this was last emptied, for setting beside what OpenMPT sets: nil
    /// unless that is wanted.
    var log: [UInt32]?

    init(behaviour: Behaviour) {
        self.behaviour = behaviour
        chip = .allocate(capacity: 1)
        chip.initialize(to: OPL3Chip())
        window = .allocate(capacity: 32)
        window.initialize(repeating: 0, count: 32)
        sinc = .allocate(capacity: st3Sinc.count)
        for i in 0 ..< st3Sinc.count { sinc[i] = st3Sinc[i] }
        step = UInt64((4_294_967_296.0 * (OPL3Chip.rate / Double(outputSampleRate))).rounded())
        // OPL::Reset: the chip is an OPL3, and none of its voices are paired into ones of four operators.
        Port(0x105, 1)
        Port(0x104, 0)
    }

    deinit {
        chip.deinitialize(count: 1)
        chip.deallocate()
        window.deallocate()
        sinc.deallocate()
    }

    // MARK: OPL.cpp

    private func Port(_ reg: Int, _ value: UInt8) {
        log?.append(UInt32(reg & 0x1FF) << 8 | UInt32(value))
        if written[reg & 0x1FF] == Int16(value) { return }
        written[reg & 0x1FF] = Int16(value)
        // (No more than the chip can be told between two of its samples is kept: a tick sets a few dozen.)
        if pending.count < 1000 { pending.append(UInt32(reg & 0x1FF) << 8 | UInt32(value)) }
    }

    private static func ChannelToRegister(_ oplCh: UInt8) -> Int {
        oplCh < 9 ? Int(oplCh) : Int(oplCh - 9) | 0x100
    }

    /// Where a voice's first operator is among the registers.
    private static func OperatorToRegister(_ oplCh: UInt8) -> Int {
        let OPLChannelToOperator = [0, 1, 2, 8, 9, 10, 16, 17, 18]
        return oplCh < 9 ? OPLChannelToOperator[Int(oplCh)] : OPLChannelToOperator[Int(oplCh - 9)] | 0x100
    }

    private func GetVoice(_ c: Int) -> UInt8 {
        if m_ChanToOPL[c] & Self.wasCut != 0 || m_ChanToOPL[c] == Self.invalid { return Self.invalid }
        return m_ChanToOPL[c] & Self.voiceMask
    }

    private func AllocateVoice(_ c: Int) -> UInt8 {
        // The voice it had before, if it still has it, or if it was cut and nobody has taken it since.
        var oplCh = m_ChanToOPL[c]
        if oplCh != Self.invalid {
            if oplCh & Self.wasCut == 0 { return oplCh }
            oplCh &= Self.voiceMask
            if m_OPLtoChan[Int(oplCh)] == Self.noOwner || m_OPLtoChan[Int(oplCh)] == c {
                m_OPLtoChan[Int(oplCh)] = c
                m_ChanToOPL[c] = oplCh
                return oplCh
            }
        }
        // One nobody has; or failing that one whose key has been let go, and of those one that was cut.
        var releasedChn = Self.invalid, releasedCutChn = Self.invalid
        for voice in 0 ..< Self.voiceCount {
            if m_OPLtoChan[voice] == Self.noOwner {
                m_OPLtoChan[voice] = c
                m_ChanToOPL[c] = UInt8(voice)
                return UInt8(voice)
            } else if m_KeyOnBlock[voice] & Self.KEYON_BIT == 0 {
                releasedChn = UInt8(voice)
                if m_ChanToOPL[m_OPLtoChan[voice]] & Self.wasCut != 0 { releasedCutChn = UInt8(voice) }
            }
        }
        if releasedChn != Self.invalid {
            if releasedCutChn != Self.invalid { releasedChn = releasedCutChn }
            m_ChanToOPL[m_OPLtoChan[Int(releasedChn)]] = Self.invalid
            m_OPLtoChan[Int(releasedChn)] = c
            m_ChanToOPL[c] = releasedChn
        }
        return GetVoice(c)
    }

    private func MoveChannel(_ from: Int, _ to: Int) {
        let oplCh = GetVoice(from)
        if oplCh == Self.invalid { return }
        m_OPLtoChan[Int(oplCh)] = to
        m_ChanToOPL[from] = Self.invalid
        m_ChanToOPL[to] = oplCh
    }

    private func NoteOff(_ c: Int) {
        let oplCh = GetVoice(c)
        if oplCh == Self.invalid || m_KeyOnBlock[Int(oplCh)] & Self.KEYON_BIT == 0 { return }
        m_KeyOnBlock[Int(oplCh)] &= ~Self.KEYON_BIT
        Port(Self.KEYON_BLOCK | Self.ChannelToRegister(oplCh), m_KeyOnBlock[Int(oplCh)])
    }

    /// The key let go and the level brought right down. (Which is not silence: what is left of the
    /// note as it dies away is still there, 48 decibels down.)
    private func NoteCut(_ c: Int, unassign: Bool = true) {
        let oplCh = GetVoice(c)
        if oplCh == Self.invalid { return }
        NoteOff(c)
        Volume(c, 0, applyToModulator: false)
        if unassign {
            m_OPLtoChan[Int(oplCh)] = Self.noOwner
            m_ChanToOPL[c] |= Self.wasCut
        }
    }

    private func Frequency(_ c: Int, _ milliHertz: UInt32, keyOff: Bool) {
        let oplCh = GetVoice(c)
        if oplCh == Self.invalid { return }
        var fnum: UInt32 = 1023, block: UInt32 = 7
        if milliHertz <= 6_208_431 {
            if milliHertz > 3_104_215 { block = 7 } else if milliHertz > 1_552_107 { block = 6 } else if milliHertz > 776_053 { block = 5 }
            else if milliHertz > 388_026 { block = 4 } else if milliHertz > 194_013 { block = 3 } else if milliHertz > 97006 { block = 2 }
            else if milliHertz > 48503 { block = 1 } else { block = 0 }
            // The chip's own rate is 49,716 a second. (Rounded to the nearest.)
            fnum = UInt32((UInt64(milliHertz) * UInt64(1 << (20 - block)) + 24_858_000) / 49_716_000)
        }
        fnum |= block << 10
        let channel = Self.ChannelToRegister(oplCh)
        m_KeyOnBlock[Int(oplCh)] = (keyOff ? 0 : Self.KEYON_BIT) | UInt8(truncatingIfNeeded: fnum >> 8)
        Port(Self.FNUM_LOW | channel, UInt8(truncatingIfNeeded: fnum))
        Port(Self.KEYON_BLOCK | channel, m_KeyOnBlock[Int(oplCh)])
    }

    /// An operator's level with a note's volume, of 63, worked into it.
    private static func CalcVolume(_ trackerVol: UInt8, _ kslVolume: UInt8) -> UInt8 {
        if trackerVol >= 63 { return kslVolume }
        let vol = UInt32(trackerVol > 0 ? trackerVol + 1 : 0)
        return (kslVolume & KSL_MASK) | UInt8(63 - ((63 - UInt32(kslVolume & TOTAL_LEVEL_MASK)) * vol) / 64)
    }

    private func Volume(_ c: Int, _ vol: UInt8, applyToModulator: Bool) {
        let oplCh = GetVoice(c)
        if oplCh == Self.invalid { return }
        let modulator = Self.OperatorToRegister(oplCh), carrier = modulator + 3
        let level2 = m_Patches[Int(oplCh)][2], level3 = m_Patches[Int(oplCh)][3], connection = m_Patches[Int(oplCh)][10]
        // (The first operator is heard itself only where the two are added.)
        if connection & Self.CONNECTION_BIT != 0 || applyToModulator { Port(Self.KSL_LEVEL + modulator, Self.CalcVolume(vol, level2)) }
        if !applyToModulator { Port(Self.KSL_LEVEL + carrier, Self.CalcVolume(vol, level3)) }
    }

    /// The chip knows left, middle and right and nothing between: a place of 256 is one of them.
    private func Pan(_ c: Int, _ pan: Int) {
        let oplCh = GetVoice(c)
        if oplCh == Self.invalid { return }
        var fbConn = m_Patches[Int(oplCh)][10] & ~Self.STEREO_BITS
        if pan <= 170 { fbConn |= Self.VOICE_TO_LEFT }
        if pan >= 85 { fbConn |= Self.VOICE_TO_RIGHT }
        Port(Self.FEEDBACK_CONNECTION | Self.ChannelToRegister(oplCh), fbConn)
    }

    private func Patch(_ c: Int, _ patch: [UInt8]) {
        let oplCh = AllocateVoice(c)
        if oplCh == Self.invalid || patch.count < 11 { return }
        m_Patches[Int(oplCh)] = patch
        let modulator = Self.OperatorToRegister(oplCh), carrier = modulator + 3
        for op in 0 ..< 2 {
            let opReg = op == 1 ? carrier : modulator
            Port(Self.AM_VIB | opReg, patch[0 + op])
            Port(Self.KSL_LEVEL | opReg, patch[2 + op])
            Port(Self.ATTACK_DECAY | opReg, patch[4 + op])
            Port(Self.SUSTAIN_RELEASE | opReg, patch[6 + op])
            Port(Self.WAVE_SELECT | opReg, patch[8 + op])
        }
        Port(Self.FEEDBACK_CONNECTION | Self.ChannelToRegister(oplCh), patch[10])
    }

    // MARK: After a tick

    /// True for a voice of the replayer's that is playing a note of an FM instrument.
    @inline(__always) private static func isFM(_ sc: IT2SlavePointer) -> Bool {
        sc.pointee.Flags & SF_CHAN_ON != 0 && sc.pointee.SmpPtr?.AdLib != nil
    }

    /// The replayer has played a tick: the chip is told what has become of every FM note.
    func update(_ player: IT2Player) {
        fine = player.fineFMPitch
        let sChn = player.sChn, hChn = player.hChn
        let instruments = player.module.Flags & ITF_INSTR_MODE != 0

        // Channel by channel, as OpenMPT goes: what became of the note it had, and the note it has now.
        for host in 0 ..< MAX_HOST_CHANNELS {
            let hc = hChn + host
            var now = Self.noOwner
            if hc.pointee.Flags & HF_CHAN_ON != 0, let sc = hc.pointee.SlaveChnPtr, Self.isFM(sc), sc.pointee.HostChnNum == UInt8(host),
               sc.pointee.Flags & (SF_NOTE_STOP | SF_CHN_MUTED) == 0 {
                now = sc - sChn
            }
            let old = owned[host]
            if old != Self.noOwner, old != now || started[old] != (sChn + old).pointee.Started {
                let sc = sChn + old
                if attached[old] == host {
                    let ended = old == now || !Self.isFM(sc) || sc.pointee.Flags & SF_NOTE_STOP != 0 || sc.pointee.HostChnNum & CHN_DISOWNED == 0
                    if ended, now == Self.noOwner, old != now, Self.isFM(sc) {
                        // Over, with no note come to take its place: its key is let go now, and it
                        // gives up its voice below, when every channel's new note has found one.
                        NoteOff(host)
                        continue
                    } else if ended {
                        NoteCut(host)
                        attached[old] = Self.noOwner
                    } else if behaviour.keepsVoiceWhenLetGo || sc.pointee.NNA == 1 {
                        // Let go to play on, or to fade or have its key let go: it keeps its voice,
                        // under another name.
                        MoveChannel(host, MAX_HOST_CHANNELS + old)
                        attached[old] = MAX_HOST_CHANNELS + old
                    } else {
                        NoteOff(host)
                        attached[old] = Self.noOwner
                        sc.pointee.Flags |= SF_NOTE_STOP
                    }
                }
                owned[host] = Self.noOwner
            }
            if now != Self.noOwner, owned[host] == Self.noOwner {
                let sc = sChn + now
                guard let sample = sc.pointee.SmpPtr, let patch = sample.AdLib else { continue }
                Patch(host, patch)
                attached[now] = host
                started[now] = sc.pointee.Started
                patchOf[now] = sample
                owned[host] = now
            }
        }

        // Then every note that is on the chip: its pitch, its level and its side; or its end.
        for voice in 0 ..< MAX_SLAVE_CHANNELS where attached[voice] != Self.noOwner {
            let sc = sChn + voice
            let note = attached[voice]
            if !Self.isFM(sc) || sc.pointee.Flags & SF_NOTE_STOP != 0 {
                NoteCut(note)
                attached[voice] = Self.noOwner
                patchOf[voice] = nil
                if note < MAX_HOST_CHANNELS { owned[note] = Self.noOwner }
                continue
            }
            if GetVoice(note) == Self.invalid {
                // Another note has taken its voice. One that its channel had let go is over.
                if note >= MAX_HOST_CHANNELS {
                    sc.pointee.Flags |= SF_NOTE_STOP
                    attached[voice] = Self.noOwner
                    patchOf[voice] = nil
                }
                continue
            }
            if let sample = sc.pointee.SmpPtr, sample !== patchOf[voice], let patch = sample.AdLib {
                // (A slide to a note of another instrument: the voice goes over to its patch.)
                Patch(note, patch)
                patchOf[voice] = sample
            }
            if sc.pointee.Flags & SF_CHN_MUTED != 0 { continue }

            let fading = sc.pointee.Flags & SF_FADEOUT != 0
            if !behaviour.flexibleNoteOff, fading {
                // OpenMPT's older way: a note that is fading has its key let go and is then left to
                // ring as the patch has it, with nothing more told to the chip.
                NoteOff(note)
                continue
            }

            let ins = instruments && sc.pointee.Ins != 0xFF ? sc.pointee.InsPtr : nil
            if let ins, sc.pointee.Flags & SF_VOLENV_ON != 0, ins.VolEnv.Flags & (ENVF_ENABLED | ENVF_LOOP | ENVF_SUSTAINLOOP) == ENVF_ENABLED {
                // A note whose volume envelope has run to its end, and ends at nothing, will not be
                // heard again: it is taken off the chip, a tick before the replayer would have ended it.
                let last = min(Int(ins.VolEnv.Num), ins.VolEnv.Tick.count, ins.VolEnv.Magnitude.count) - 1
                if last >= 0, ins.VolEnv.Magnitude[last] == 0, Int(sc.pointee.VolEnvState.Tick) >= Int(ins.VolEnv.Tick[last]) {
                    NoteCut(note)
                    attached[voice] = Self.noOwner
                    patchOf[voice] = nil
                    if note < MAX_HOST_CHANNELS { owned[note] = Self.noOwner }
                    if sc.pointee.HostChnNum & CHN_DISOWNED == 0 {
                        sc.pointee.HostChnNum |= CHN_DISOWNED
                        sc.pointee.HostChnPtr?.pointee.Flags &= ~HF_CHAN_ON
                    }
                    sc.pointee.Flags |= SF_NOTE_STOP
                    continue
                }
            }

            // The filter's cutoff, where a note has a filter, is how hard the first operator bends
            // the second; and a filter's envelope moves it from tick to tick.
            let host = Int(sc.pointee.HostChnNum & 63)
            let letGo = sc.pointee.HostChnNum & CHN_DISOWNED != 0
            let cutoff = letGo ? Int(UInt16(bitPattern: sc.pointee.VolEnvState.CurNode) >> 8) : Int(player.FilterParameters[host])
            let resonance = letGo ? Int(sc.pointee.MIDIBank >> 8) : Int(player.FilterParameters[64 + host])
            var computed = cutoff * 2
            if let ins, ins.PitchEnv.Flags & ENVF_TYPE_FILTER != 0, ins.PitchEnv.Flags & ENVF_ENABLED != 0, ins.PitchEnv.Num > 0 {
                computed = cutoff * Int(sc.pointee.MIDIBank & 0xFF) / 128
            }
            if resonance != 0 || computed < 254 { Volume(note, UInt8(max(0, min(254, computed)) / 4), applyToModulator: true) }

            let keyOff = sc.pointee.Flags & SF_NOTE_OFF != 0 || (fading && sc.pointee.FadeOut == 0)
            // From the rate a sample would be played at to a pitch: 8,363 a second is middle C, 261.625 Hz.
            let rate = UInt64(UInt32(bitPattern: max(0, sc.pointee.Frequency)))
            let divisor: UInt64 = fine ? 8363 << UInt64(Self.fineShift) : 8363
            Frequency(note, UInt32(min((rate * 261_625 + divisor / 2) / divisor, UInt64(UInt32.max))), keyOff: keyOff)
            Volume(note, UInt8((UInt32(sc.pointee.VolNoGlobal) * 63 + 16384) >> 15), applyToModulator: false)
            var place = sc.pointee.FinalPan == PAN_SURROUND || player.module.Flags & ITF_STEREO == 0 ? 128 : Int(sc.pointee.FinalPan) * 4
            if sc.pointee.FinalPan == PAN_SURROUND, behaviour.surroundIsMoved, let ins, ins.PanEnv.Flags & ENVF_ENABLED != 0 {
                place = max(0, min(256, 128 + Int(Int8(truncatingIfNeeded: sc.pointee.PanEnvState.Value >> 16)) * 4))
            }
            Pan(note, place)
        }
    }

    // MARK: Sound

    /// Which channel each of the chip's voices is playing a note of; less than nought for none.
    func channel(ofVoice voice: Int, _ sChn: IT2SlavePointer) -> Int {
        let note = m_OPLtoChan[voice]
        if note == Self.noOwner { return -1 }
        return note < MAX_HOST_CHANNELS ? note : Int(sChn[note - MAX_HOST_CHANNELS].HostChnNum & 63)
    }

    /// The channel that last had a note on each of the chip's voices; less than nought for none
    /// yet. A note that is cut gives its voice up, and what is left of it is heard a little longer
    /// all the same (see `NoteCut`): that is still its channel's sound.
    private var lastChannel = [Int](repeating: OpenMPTAdLib.noOwner, count: OpenMPTAdLib.voiceCount)

    /// Leaves out of the chip's sound the voices that are playing notes of the channels marked in
    /// `muted`, a bit for each of the 64, and brings the others back: see `Renderer.setMuted`. It is
    /// asked before each tick's sound is made, since notes take and give up voices from tick to
    /// tick. A voice left out plays on, and its level is told as ever.
    func leaveOut(_ muted: UInt64, _ sChn: IT2SlavePointer) {
        // (The chip has a bit for each of its channels: see `OPL3Chip.muted`.)
        var voices: UInt32 = 0
        for voice in 0 ..< Self.voiceCount {
            let channel = channel(ofVoice: voice, sChn)
            if channel >= 0 { lastChannel[voice] = channel }
            let last = lastChannel[voice]
            if last >= 0, (muted >> UInt64(last)) & 1 != 0 { voices |= 1 << UInt32(voice) }
        }
        chip.pointee.muted = voices
    }

    /// How far each of the chip's eighteen voices has swung since this was last asked.
    func takeLevels(into levels: UnsafeMutablePointer<Float>) {
        chip.pointee.takeLevels(into: levels, count: Self.voiceCount)
    }

    /// Adds `frames` frames of the chip to a buffer of left and right in turn, at `level`. What the
    /// replayer has set since the last frames were made is set first.
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int, level: Float) {
        for write in pending { chip.pointee.OPL3_WriteRegBuffered(UInt16(write >> 8), UInt8(truncatingIfNeeded: write)) }
        pending.removeAll(keepingCapacity: true)

        var frac = position
        let delta = step
        let window = window, sinc = sinc
        let scale = level * (1.0 / 32768.0)
        for n in 0 ..< frames {
            frac &+= delta
            while frac >= 1 << 32 {
                frac -= 1 << 32
                for i in 0 ..< 15 {
                    window[i] = window[i + 1]
                    window[16 + i] = window[16 + i + 1]
                }
                let made = chip.pointee.OPL3_Generate()
                window[15] = Float(made.left)
                window[31] = Float(made.right)
            }
            let frac32 = UInt32(truncatingIfNeeded: frac)
            let phase = Int(frac32 >> 24)
            let between = Float(Int32(frac32 & 0xFF_FFFF)) * (1.0 / 16_777_216.0)
            let sinc1 = sinc + (phase << 4), sinc2 = sinc + ((phase + 1) << 4)
            var sumL: Float = 0, sumR: Float = 0
            for i in 0 ..< 16 {
                let y1 = sinc1[i], y2 = sinc2[i]
                let y = y1 + ((y2 - y1) * between)
                sumL += window[i] * y
                sumR += window[16 + i] * y
            }
            buffer[n * 2] += sumL * scale
            buffer[n * 2 + 1] += sumR * scale
        }
        position = frac
    }
}
