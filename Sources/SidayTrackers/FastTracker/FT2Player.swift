// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ft2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

import SidayFoundation

// What the replayer tells the mixer of a voice.
private let Status_SetVol: UInt8 = 1, Status_SetPan: UInt8 = 2, Status_SetFrq: UInt8 = 4
private let Status_StartTone: UInt8 = 8, Status_StopTone: UInt8 = 16, Status_QuickVol: UInt8 = 32
// How a voice is playing.
private let SType_Fwd: UInt8 = 1, SType_Rev: UInt8 = 2, SType_RevDir: UInt8 = 4, SType_Off: UInt8 = 8, SType_Fadeout: UInt8 = 32

/// A voice of the mixer. There are two to a channel: when a note is cut short by the next, the old
/// one fades out on one voice while the new one starts on the other, which is what keeps it from clicking.
struct FT2Voice {
    var SBase: UnsafeRawPointer?, SRevBase: UnsafeRawPointer?
    /// For a sample in stereo, from a later tracker's file: where its right side is, read as the
    /// left is, and its filter's last two samples. The left side is then heard on the left only and
    /// the right on the right.
    var SBaseR: UnsafeRawPointer?, SRevBaseR: UnsafeRawPointer?
    var filterY1R: Float = 0, filterY2R: Float = 0
    var SType: UInt8 = 0, SPan: UInt8 = 0, SVol: UInt8 = 0
    // The volume wanted on each side, the volume it has got to, and the step from one towards the other.
    var SLVol1: Int32 = 0, SRVol1: Int32 = 0, SLVol2: Int32 = 0, SRVol2: Int32 = 0, SLVolIP: Int32 = 0, SRVolIP: Int32 = 0, SVolIPLen: Int32 = 0
    var SLen: Int32 = 0, SRepS: Int32 = 0, SRepL: Int32 = 0, SPos: Int32 = 0
    var sixteen = false
    var SPosDec: UInt32 = 0, SFrq: UInt32 = 0
    /// For a file that a later tracker made: the filter its sample is played through, if any, as
    /// the three numbers that make one and the last two samples that came out of it.
    var filtered = false
    var filterA0: Float = 0, filterB0: Float = 0, filterB1: Float = 0, filterY1: Float = 0, filterY2: Float = 0
    /// True for a voice of a channel that is left out of the sound: it plays on, and is not heard.
    var muted = false
    /// The place of the plug-in the voice is sent to, for a song that has OpenMPT's (see
    /// `FT2Player.playsPlugIns`); less than nought if it goes straight to the listener.
    var place = -1
    /// For a file of ModPlug Tracker's or OpenMPT's: what the voice last put out on each side
    /// when its sample ran out, dying away (see `FT2Player.endsDieAway`).
    var tailL: Int32 = 0, tailR: Int32 = 0
    /// For a file of ModPlug Tracker's or OpenMPT's: how the voice's sample is read between its
    /// points, by OpenMPT's number for the way (see `FT2Player.readsAsOpenMPT`); `fastTrackers` for
    /// FastTracker's line from one to the next. And whether it has been round its loop.
    var way = FT2Voice.fastTrackers
    var looped = false
    /// For a file whose X commands are ModPlug Tracker's (see `FT2Player.playsModPlugXCommands`):
    /// whether the voice is played backwards by X9F, which the mixer does as it does the way back
    /// of a loop that goes back and forth: `backwardsOnce` for the whole of a sample that does not
    /// loop, which ends at its start; `backwardsRound` for a loop that goes round, which goes round
    /// backwards; nought for neither (a loop that goes back and forth only turns). And whether it
    /// is in surround, its right side turned over.
    var backwards: UInt8 = 0
    var surround = false
    static let backwardsOnce: UInt8 = 1, backwardsRound: UInt8 = 2
    static let fastTrackers: UInt8 = 255
}

/// FastTracker 2's replayer and mixer, playing a module: the replayer is in `FT2Replayer.swift`, and
/// here is what it stands on. A tick of the song is a whole number of samples, and the mixer is
/// FastTracker's own, in whole numbers throughout, with its linear interpolation and its ramping of
/// volumes, both of which the tracker had switched on as it came.
final class FT2Player {
    let module: FT2Module
    var song: FT2Song
    let stm: [FT2Channel]
    let instr: [FT2Instrument?]
    let linearFrqTab: Bool
    /// Three things that are so only for a module of another tracker's, read into FastTracker's shape:
    /// see `FT2Module.channelPanning`, `FT2Module.speedAndTempoUndoEachOther` and `FT2Module.foreign`.
    let panningIsOfChannels: Bool
    /// True if commands are played that FastTracker 2 has not got and the trackers after it
    /// have: for an XM file that another tracker made. So far, a sweep from side to side.
    let playsLaterCommands: Bool
    /// True if arpeggio goes as it did in the trackers other than FastTracker, for an XM file of
    /// one of theirs: see `FT2Module.arpeggioOfOtherTrackers` and `arpAsOtherTrackers`.
    let arpeggiatesAsOtherTrackers: Bool
    /// True if the commands that ModPlug Tracker added under X are played, as OpenMPT plays them
    /// in such a file (see `FT2Module.playsModPlugXCommands`): X5x the wave of a sweep from side to
    /// side, X6x ticks more on a row, X90 and X91 surround off and on, X98 and X99 ModPlug's reverb,
    /// X9E and X9F the sample forwards and backwards, and XAx where in a long sample 9xx starts.
    let playsModPlugXCommands: Bool
    /// True if a sample's finetune is heard whole, as OpenMPT plays such a file: see
    /// `FT2Module.fineTunesFully` and `notePeriod`.
    let fineTunesFully: Bool
    /// False for sound that will be heard in mono, in which a channel in surround is not turned over,
    /// and would be no more than its two sides taking each other away.
    var stereoOutput = true
    /// The ticks that X6x has added to the row playing.
    var frameDelay: UInt16 = 0
    /// True from X9B, until X9A: a channel in surround can be put somewhere and stay in surround.
    var surroundPans = false
    let speedAndTempoUndoEachOther: Bool
    /// How far a vibrato's sum is brought down: by 5 places, or by 7 for a module whose vibrato is
    /// a quarter as deep. See `ForeignModule.vibratoIsAQuarterAsDeep`.
    let vibratoShift: Int
    /// True if a loop inside a pattern is not to leave the next pattern starting on its row.
    let loopsLeaveNothingBehind: Bool
    /// True for a file of ModPlug Tracker's or OpenMPT's. A sample that runs out while it is loud
    /// stops dead in FastTracker's mixer, with a click; in theirs, what it last put out dies away,
    /// by a 256th of itself a frame, as it does here for such a file.
    let endsDieAway: Bool
    /// And true for such a file to have its voices read between their samples' points as OpenMPT
    /// reads them, through eight points and not two: by the way an instrument asks for, or else
    /// OpenMPT's own, a sinc that is made duller for a voice going faster through its sample than
    /// the sound is made (see `IT2Resampling`). The voice moves through its sample as it does in
    /// FastTracker's mixer; only what is heard of the sample between its points is OpenMPT's.
    let readsAsOpenMPT: Bool
    /// True for a module of DIGI Booster's: see `FT2DigiBooster.swift`.
    let playsAsDigiBooster: Bool

    static let rate: Int32 = Int32(outputSampleRate)
    /// FastTracker's "amplification", as it comes.
    static let amp: UInt32 = 4
    /// The longest a tick can be: the slowest tempo a file can give is one beat a minute.
    static let mostSamplesPerTick = Int(rate * 5 / 2)

    private(set) var speedVal: Int32 = 0
    private let quickVolSizeVal: Int32
    let frequenceDivFactor: UInt32, frequenceMulFactor: UInt32
    private let CDA_Amp: UInt32

    private let CI: UnsafeMutablePointer<FT2Voice>
    private var chnReloc: [Int]
    /// A tick of sound, left and right in turn, at 256 times the size it goes out at.
    let mixBuffer: UnsafeMutablePointer<Int32>
    /// A tick that is not heard, for the voices of channels that are left out of the sound to be
    /// mixed into as ever: it is there once a channel has been left out. See `setMuted`.
    private var unheard: UnsafeMutablePointer<Int32>?
    /// Where each channel's sound is kept for its scope, if it is wanted (see `keepWaves`).
    private var waves: ChannelWaves?
    /// While a voice is being mixed for its scope: the tick it is mixed into in place of its own,
    /// which it is then added to; and that tick of its own, once the voice has asked for it.
    private var voiceTick: UnsafeMutablePointer<Int32>?
    private var voiceTarget: UnsafeMutablePointer<Int32>?
    /// A channel's sound in the tick being made, its note and the one dying away under it together.
    private var channelWave: UnsafeMutablePointer<Float>?
    /// For the lights: how loud each channel is in the tick last made, which is told as it is heard.
    var levels: HeardLevels
    /// And what each is playing.
    var notes: TickNotes
    /// The lowest and highest the voice being mixed has had its sample, and the most its volume has been.
    private var swing = Swing<Int32>(from: -65536, to: 65536)
    private var loudest: Float = 0
    /// And how many of the tick's frames it sounded for: all of them, unless its sample ran out or
    /// it was on its way to silence.
    private var sounded: Int32 = 0

    /// The song's plug-ins, for a song that has OpenMPT's and is to be heard: see `playsPlugIns`.
    private var plugIns: OpenMPTPlugIns?
    /// A tick for each place of a plug-in that voices are sent to, in the mixer's whole numbers,
    /// and which of them have had a voice mixed into them in the tick being made.
    private var placeTicks: [UnsafeMutablePointer<Int32>?] = []
    private var placesUsed: [Int] = []
    /// ModPlug's own reverb, for a song whose channels are put in it and that is to be heard: the
    /// tick that the voices sent to it are mixed into, and whether anything was this tick.
    private var reverb: ModPlugReverb?
    private var reverbTick: UnsafeMutablePointer<Int32>?
    private var reverbUsed = false
    /// The tick as the plug-ins have it, left and right in turn.
    private var plugInTick: UnsafeMutablePointer<Float>?
    /// From the mixer's whole numbers to the level OpenMPT has the voices at in its own mix, as a
    /// number that is 1 at the top of the sound it gives out: what ModPlug's reverb is given, and,
    /// in OpenMPT's terms for plug-ins, what they are (see `FT2Module.openMPTMixLevel`).
    private var openMPTMixLevel: Float { XMRenderer.gain * module.openMPTLevel * module.openMPTMixLevel }

    private let visited: UnsafeMutablePointer<Bool>
    /// True when the tick just run began a row that has been played before.
    private(set) var cameRound = false
    /// Which places in the list of patterns have been played, and whether a note has been.
    private(set) var ordersPlayed = [Bool](repeating: false, count: 256)
    var playedNote = false
    /// Which of the file's songs first played each row, shared between them and not this player's
    /// to free, and which song this is. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>?
    private let songNumber: UInt8
    private var metEarlierSong = false
    /// True if this song went on into a row that a song before it played, other than by running off
    /// the end of the list of patterns and starting again where the file says to.
    private(set) var ledIntoEarlierSong = false
    var offTheEnd = false
    /// True once the song has run off the end of the list of patterns, into a song before it: it is
    /// over, and no more of it is read. What is sounding then is left to die away.
    private(set) var over = false
    /// How many rows the table of who played a row first has: 256 for each of 256 places.
    static let rowsInAll = 256 * 256
    /// True once the song has stopped itself, with a speed of nothing.
    var stopped: Bool { song.tempo == 0 }

    /// - Parameters:
    ///   - position: where in the list of patterns to start.
    ///   - firstPlayedBy: for a file of several songs, which of them first played each row.
    ///   - songNumber: which of them this is.
    ///   - asFastTracker: with nothing done for a file because another tracker made it: what the
    ///     player this is ported from does, for setting the two side by side.
    init(_ module: FT2Module, position: Int = 0, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil, songNumber: UInt8 = 0,
         asFastTracker: Bool = false) {
        playsLaterCommands = !module.madeByFastTracker && !asFastTracker
        arpeggiatesAsOtherTrackers = module.arpeggioOfOtherTrackers && !asFastTracker
        playsModPlugXCommands = module.playsModPlugXCommands && !asFastTracker
        fineTunesFully = module.fineTunesFully && !asFastTracker
        endsDieAway = module.openMPTMix != nil && !asFastTracker
        readsAsOpenMPT = endsDieAway
        self.firstPlayedBy = firstPlayedBy
        self.songNumber = songNumber
        self.module = module
        song = module.song
        if position > 0, position < Int(song.len) {
            song.songPos = Int16(position)
            song.pattNr = Int16(song.songTab[position & 0xFF])
            song.pattLen = Int16(bitPattern: module.pattLens[Int(UInt8(truncatingIfNeeded: song.pattNr))])
            song.pattPos = 0
        }
        instr = module.instr
        linearFrqTab = module.linearFrqTab
        panningIsOfChannels = !module.channelPanning.isEmpty
        speedAndTempoUndoEachOther = module.speedAndTempoUndoEachOther
        vibratoShift = module.vibratoIsAQuarterAsDeep ? 7 : 5
        loopsLeaveNothingBehind = module.foreign != nil
        playsAsDigiBooster = module.playsAsDigiBooster
        let placeholder = module.instr[0]!
        let channels = max(1, Int(module.song.antChn))
        stm = (0 ..< channels).map { FT2Channel(nr: $0, instrument: placeholder) }
        chnReloc = (0 ..< channels).map { $0 + $0 }
        levels = HeardLevels(voices: channels)
        notes = TickNotes(voices: channels)

        let rate = Double(Self.rate)
        // (A period is of the clock FastTracker reckons one by; but DIGI Booster's are of the Amiga's
        // own, as OpenMPT plays them, the clock of a PAL machine, 3,546,895 Hz.)
        frequenceDivFactor = UInt32((65536.0 * (module.playsAsDigiBooster ? 3_546_895.0 * 4 : 1712.0 * 8363.0) / rate).rounded())
        frequenceMulFactor = UInt32((256.0 * 65536.0 / rate * 8363.0).rounded())
        CDA_Amp = 8 * Self.amp
        quickVolSizeVal = Self.rate / 200

        CI = .allocate(capacity: channels * 2)
        CI.initialize(repeating: FT2Voice(), count: channels * 2)
        mixBuffer = .allocate(capacity: (Self.mostSamplesPerTick + 1) * 2)
        visited = .allocate(capacity: 256 * 256)
        visited.initialize(repeating: false, count: 256 * 256)

        for i in 0 ..< channels * 2 {
            CI[i].SPan = 128
            CI[i].SType = SType_Off
        }
        for ch in stm {
            ch.status = IS_Vol
            ch.oldPan = 128
            ch.outPan = 128
            ch.finalPan = 128
        }
        // A module of another tracker's has each channel in a place of its own from the start.
        for (i, pan) in module.channelPanning.prefix(channels).enumerated() {
            CI[i * 2].SPan = pan
            CI[i * 2 + 1].SPan = pan
            stm[i].oldPan = pan
            stm[i].outPan = pan
            stm[i].finalPan = pan
        }
        song.globVol = 64
        song.timer = 1
        P_SetSpeed(song.speed)
    }

    deinit {
        CI.deallocate()
        mixBuffer.deallocate()
        unheard?.deallocate()
        visited.deallocate()
        for tick in placeTicks { tick?.deallocate() }
        plugInTick?.deallocate()
        reverbTick?.deallocate()
        voiceTick?.deallocate()
        channelWave?.deallocate()
    }

    /// Keeps each channel's sound for its scope in `waves`, at the output's rate, from the next tick
    /// on: as loud as it is, and as it is before it is put to one side or the other (see `keepWave`).
    func keepWaves(in waves: ChannelWaves?) {
        self.waves = waves
        guard waves != nil, voiceTick == nil else { return }
        voiceTick = .allocate(capacity: (Self.mostSamplesPerTick + 1) * 2)
        channelWave = .allocate(capacity: Self.mostSamplesPerTick + 1)
    }

    /// How far a channel at its loudest swings either side of nothing in its scope: in the mixer's
    /// numbers, a sample at its loudest at the most a voice's volume can be.
    var fullWaveSwing: Float { Float(255 * CDA_Amp) * 4096 / 32 }

    /// Mixes a voice, for a channel whose sound is kept for its scope: into a tick of its own, which
    /// is then added to the tick it would have been mixed into, so that the sound is the same to the
    /// last bit; and that voice's sound is added to its channel's, the two sides together as one.
    private func keepWave(_ v: UnsafeMutablePointer<FT2Voice>, _ index: Int, _ waves: ChannelWaves) {
        guard let voiceTick, let channelWave else { return }
        let count = Int(speedVal)
        voiceTick.update(repeating: 0, count: count * 2)
        voiceTarget = nil
        keepingWave = true
        mix(v, speedVal)
        keepingWave = false
        // A voice of a channel is heard on both sides, each by how far it is to that side: the
        // larger the two make together (as the voice's volume does), with the sign of the larger.
        if index & 1 == 0 { channelWave.update(repeating: 0, count: count) }
        if let to = voiceTarget {
            for i in 0 ..< count * 2 { to[i] &+= voiceTick[i] }
            for i in 0 ..< count {
                let l = Float(voiceTick[i * 2]), r = Float(voiceTick[i * 2 + 1])
                let both = (l * l + r * r).squareRoot()
                channelWave[i] += abs(l) >= abs(r) ? (l < 0 ? -both : both) : (r < 0 ? -both : both)
            }
        }
        if index & 1 == 1 {
            let channel = index >> 1
            for i in 0 ..< count { waves.store(channel, at: i, channelWave[i]) }
        }
    }

    /// True while a voice is being mixed into a tick of its own, for its scope (see `keepWave`).
    private var keepingWave = false

    /// Makes the song's plug-ins, for a player whose sound is to be heard: one that only finds how
    /// long a tune is, or plays as FastTracker would, has no use for them.
    func playsPlugIns() {
        if reverb == nil, module.reverbs {
            reverb = ModPlugReverb(sampleRate: Int(Self.rate))
            let tick = UnsafeMutablePointer<Int32>.allocate(capacity: (Self.mostSamplesPerTick + 1) * 2)
            tick.initialize(repeating: 0, count: (Self.mostSamplesPerTick + 1) * 2)
            reverbTick = tick
        }
        guard plugIns == nil, let sound = module.sound, let made = OpenMPTPlugIns(sound) else { return }
        plugIns = made
        placeTicks = [UnsafeMutablePointer<Int32>?](repeating: nil, count: sound.plugIns.count)
        let tick = UnsafeMutablePointer<Float>.allocate(capacity: (Self.mostSamplesPerTick + 1) * 2)
        tick.initialize(repeating: 0, count: (Self.mostSamplesPerTick + 1) * 2)
        plugInTick = tick
    }

    /// The period of a note at `index` in FastTracker's table, which counts in sixteenths of a
    /// semitone and has the channel's finetune in it with its lowest three bits dropped: in a file
    /// whose finetune is heard whole, with those bits put back as OpenMPT puts them, half of them
    /// off a linear period and, for Amiga periods, that part of the way to the next.
    @inline(__always) func notePeriod(_ index: Int, _ ch: FT2Channel) -> UInt16 {
        let period = note2Period(index)
        guard fineTunesFully, ch.fineTune & 7 != 0, period != 0 else { return period }
        let fine = Int(ch.fineTune)
        if linearFrqTab { return UInt16(max(1, Int(period) - (fine / 2 - (fine & ~7) / 2))) }
        let next = note2Period(index + 1)
        guard next != 0 else { return period }
        return UInt16(max(1, Int(period) + ((Int(next) - Int(period)) * (fine & 7) + 4) / 8))
    }

    @inline(__always) func note2Period(_ i: Int) -> UInt16 {
        guard i >= 0, i < ft2LinearPeriods.count else { return 0 }
        return linearFrqTab ? ft2LinearPeriods[i] : ft2AmigaPeriods[i]
    }

    // MARK: Coming round

    /// A row is about to be played: has it been played before?
    func rowIsRead() {
        let at = Int(UInt8(truncatingIfNeeded: song.songPos)) << 8 | Int(UInt8(truncatingIfNeeded: song.pattPos))
        if visited[at] {
            cameRound = true
            visited.update(repeating: false, count: 256 * 256)
        } else if let firstPlayedBy, !metEarlierSong, firstPlayedBy[at] < songNumber {
            metEarlierSong = true
            if offTheEnd {
                // Off the end of the list and round to its top, which a song before this one played:
                // this one is over.
                cameRound = true
                over = true
                visited.update(repeating: false, count: 256 * 256)
            } else {
                // On into what a song before this one played, which from here is part of this one.
                ledIntoEarlierSong = true
            }
        }
        offTheEnd = false
        visited[at] = true
        if let firstPlayedBy, firstPlayedBy[at] == ModuleSongs.unplayed { firstPlayedBy[at] = songNumber }
        ordersPlayed[at >> 8] = true
    }

    /// A loop inside a pattern goes back: the rows it plays again have not been played for the last time.
    func rowsWillRepeat(from row: UInt8) {
        let base = Int(UInt8(truncatingIfNeeded: song.songPos)) << 8
        var again = Int(row)
        while again <= Int(UInt8(truncatingIfNeeded: song.pattPos)) {
            visited[base | again] = false
            again += 1
        }
    }

    // MARK: What the replayer tells the mixer

    func P_SetSpeed(_ value: UInt16) {
        let bpm = Int32(value == 0 ? 125 : value)
        speedVal = ((Self.rate + Self.rate) + (Self.rate >> 1)) / bpm
    }

    private func updateVolume(_ v: UnsafeMutablePointer<FT2Voice>, _ volIPLen: Int32) {
        let vol = UInt32(v.pointee.SVol) &* CDA_Amp
        v.pointee.SLVol1 = Int32(bitPattern: (vol &* ft2PanningTab[256 - Int(v.pointee.SPan)]) >> (32 - 28))
        v.pointee.SRVol1 = Int32(bitPattern: (vol &* ft2PanningTab[Int(v.pointee.SPan)]) >> (32 - 28))
        if v.pointee.surround, stereoOutput { v.pointee.SRVol1 = 0 &- v.pointee.SRVol1 }
        v.pointee.SLVolIP = (v.pointee.SLVol1 &- v.pointee.SLVol2) / volIPLen
        v.pointee.SRVolIP = (v.pointee.SRVol1 &- v.pointee.SRVol2) / volIPLen
        v.pointee.SVolIPLen = volIPLen
    }

    private func stopTone(_ nr: Int) -> UnsafeMutablePointer<FT2Voice> {
        // The voice that was playing fades out, and the channel moves to its other voice.
        let old = CI + chnReloc[nr]
        old.pointee.SType |= SType_Fadeout
        old.pointee.SVol = 0
        updateVolume(old, quickVolSizeVal)
        chnReloc[nr] ^= 1
        let v = CI + chnReloc[nr]
        v.pointee.SType = SType_Off
        return v
    }

    /// Stops a channel's note: it fades out, as one does that the next cuts short, and nothing follows it.
    func P_StopTone(_ nr: Int) {
        _ = stopTone(nr)
    }

    func P_StartTone(_ s: FT2Sample, _ smpStartPos: Int32, _ nr: Int) {
        let v = stopTone(nr)
        // (A note begins with no filter, until its row or its channel says otherwise: see `setFilter`.)
        if playsLaterCommands {
            stm[nr].filtered = false
            v.pointee.filtered = false
            v.pointee.filterY1 = 0
            v.pointee.filterY2 = 0
            v.pointee.filterY1R = 0
            v.pointee.filterY2R = 0
        }
        guard let (type, len) = shape(v, s) else { return }
        let sample16Bit = (type >> 4) & 1 != 0
        // A sample offset beyond the end of the sample: the voice stays cut.
        if smpStartPos >= len || s.pek == nil { return }
        v.pointee.SLen = len
        v.pointee.backwards = 0
        v.pointee.surround = stm[nr].surround
        v.pointee.SPos = smpStartPos
        v.pointee.SPosDec = 0
        v.pointee.SBase = UnsafeRawPointer(s.pek)
        v.pointee.SBaseR = s.pekR.map { UnsafeRawPointer($0) }
        // (Where it is sent: to its instrument's plug-in, or else its channel's.)
        if let plugIns { v.pointee.place = plugIns.place(instrumentPlugIn: module.instrumentPlugIns[Int(stm[nr].instrNr)], channel: nr) }
        v.pointee.sixteen = sample16Bit
        v.pointee.SType = type
        v.pointee.looped = false
        if readsAsOpenMPT {
            let asked = module.instrumentResamplings[Int(stm[nr].instrNr)]
            v.pointee.way = asked < IT2Resampling.own ? asked : IT2Resampling.sincLowPass
        }
        notes.struck[nr] = true
    }

    /// Gives a voice the shape of its sample: where its loop is and how it goes, and how long it is;
    /// nil for a sample with nothing in it that does not loop.
    private func shape(_ v: UnsafeMutablePointer<FT2Voice>, _ s: FT2Sample) -> (type: UInt8, length: Int32)? {
        var type = s.typ
        let sample16Bit = (type >> 4) & 1 != 0
        if type & (SType_Fwd + SType_Rev) != 0 {
            var repL = s.repL, repS = s.repS
            if sample16Bit {
                repL >>= 1
                repS >>= 1
            }
            v.pointee.SRevBase = s.pek.map { UnsafeRawPointer($0) + Int(repS &+ repS &+ repL) * (sample16Bit ? 2 : 1) }
            v.pointee.SRevBaseR = s.pekR.map { UnsafeRawPointer($0) + Int(repS &+ repS &+ repL) * (sample16Bit ? 2 : 1) }
            v.pointee.SRepL = repL
            v.pointee.SRepS = repS
            return (type, repS &+ repL)
        }
        type &= ~(SType_Fwd + SType_Rev)
        var len = s.len
        if sample16Bit { len >>= 1 }
        return len == 0 ? nil : (type, len)
    }

    /// X9F, in a file whose X commands are ModPlug Tracker's: the channel's sample is played
    /// backwards from where it is, as OpenMPT plays it; a note that has only just begun, on its row
    /// or of a sample that does not loop, from its end, or the end of its loop. A sample that does
    /// not loop ends at its start; one whose loop goes round goes round it backwards; one whose loop
    /// goes back and forth turns.
    func playBackwards(_ nr: Int, noteOnRow: Bool) {
        let v = CI + chnReloc[nr]
        let type = v.pointee.SType
        guard type & SType_Off == 0, v.pointee.SBase != nil, v.pointee.SLen > 0, type & SType_RevDir == 0 else { return }
        let width = v.pointee.sixteen ? 2 : 1
        let loops = type & (SType_Fwd + SType_Rev) != 0 && v.pointee.SRepL > 0
        var index = v.pointee.SPos
        if index == 0, v.pointee.SPosDec == 0, noteOnRow || !loops { index = v.pointee.SLen - 1 }
        if !loops || index < v.pointee.SRepS {
            // (The sample up to where it is, as a loop back and forth from its start, already on its
            // way back, and stopped when it is at the start.)
            let length = loops ? v.pointee.SLen : index + 1
            v.pointee.SRepS = 0
            v.pointee.SRepL = length
            v.pointee.SLen = length
            v.pointee.SRevBase = v.pointee.SBase.map { $0 + Int(length) * width }
            v.pointee.SRevBaseR = v.pointee.SBaseR.map { $0 + Int(length) * width }
            v.pointee.backwards = FT2Voice.backwardsOnce
        } else if type & SType_Rev == 0 {
            // (The loop, as one that goes back and forth and on the way back stays so.)
            v.pointee.SRevBase = v.pointee.SBase.map { $0 + Int(v.pointee.SRepS &+ v.pointee.SRepS &+ v.pointee.SRepL) * width }
            v.pointee.SRevBaseR = v.pointee.SBaseR.map { $0 + Int(v.pointee.SRepS &+ v.pointee.SRepS &+ v.pointee.SRepL) * width }
            v.pointee.backwards = FT2Voice.backwardsRound
        }
        v.pointee.SType = (type & ~(SType_Fwd + SType_Rev)) | SType_Rev | SType_RevDir
        v.pointee.SPos = 2 &* v.pointee.SRepS &+ v.pointee.SRepL &- 1 &- index
        v.pointee.SPosDec = 0
    }

    /// X9E: the channel's sample forwards again from where it is, with the loop it has.
    func playForwards(_ nr: Int) {
        let v = CI + chnReloc[nr]
        guard v.pointee.SType & SType_Off == 0, v.pointee.SType & SType_RevDir != 0 else { return }
        let index = 2 &* v.pointee.SRepS &+ v.pointee.SRepL &- 1 &- v.pointee.SPos
        let ch = stm[nr]
        guard let (type, len) = shape(v, ch.instrSeg.samp[Int(ch.sampleNr)]) else { return }
        v.pointee.SType = type
        v.pointee.SLen = len
        v.pointee.backwards = 0
        v.pointee.SPos = max(0, min(len - 1, index))
        v.pointee.SPosDec = 0
    }

    /// X90 and X91: the channel's notes in surround, or not, from this one on.
    func setSurround(_ nr: Int, _ on: Bool) {
        stm[nr].surround = on
        (CI + chnReloc[nr]).pointee.surround = on
        stm[nr].status |= IS_Vol
    }

    /// XAx on a row with a note: the note starts that many times 64K into its sample, if it is so long.
    func startHigh(_ nr: Int, _ value: UInt8) {
        let v = CI + chnReloc[nr]
        let place = Int32(value) << 16
        if v.pointee.SType & SType_Off == 0, v.pointee.backwards == 0, v.pointee.SType & SType_RevDir == 0, place < v.pointee.SLen {
            v.pointee.SPos = place
            v.pointee.SPosDec = 0
        }
    }

    private func mix_UpdateChannelVolPanFrq() {
        for i in 0 ..< Int(song.antChn) {
            let ch = stm[i]
            let status = ch.status
            ch.status = 0
            if playsLaterCommands, ch.filterChanged || status & IS_NyTon != 0 { setFilter(CI + chnReloc[i], ch, newNote: status & IS_NyTon != 0) }
            if status == 0 { continue }
            let v = CI + chnReloc[i]
            if status & IS_Pan != 0 { v.pointee.SPan = ch.finalPan }
            if status & IS_Vol != 0 {
                // 0 to 256 is made 0 to 255, which is how FastTracker keeps a multiplication from overflowing.
                var vol = ch.finalVol
                if vol > 0 { vol -= 1 }
                v.pointee.SVol = UInt8(truncatingIfNeeded: vol)
            }
            if status & (IS_Vol + IS_Pan) != 0 { updateVolume(v, status & IS_QuickVol != 0 ? quickVolSizeVal : speedVal) }
            if status & IS_Period != 0 {
                v.pointee.SFrq = getFrequenceValue(ch.finalPeriod)
                // A sample with a rate of its own is played that much faster or slower than one of
                // FastTracker's, whatever the note and whatever is done to the note.
                if ch.sampleRate != 0 {
                    v.pointee.SFrq = UInt32(truncatingIfNeeded: min(0x7FFF_FFFF, UInt64(v.pointee.SFrq) &* UInt64(ch.sampleRate) / 8363))
                }
            }
        }
    }

    /// Tells a voice of its channel's filter, in a file that a later tracker made. The filter is
    /// OpenMPT's, as it has it for an XM file: two poles, closing at 110 Hz times two to the power
    /// of a quarter and a twenty-fourth of the setting (which is 5 kHz at its most open, so that a
    /// filter that is on is always heard), and ringing by 24 dB at the most. A note begins with
    /// it on if its channel's filter is closed at all.
    private func setFilter(_ v: UnsafeMutablePointer<FT2Voice>, _ ch: FT2Channel, newNote: Bool) {
        ch.filterChanged = false
        if newNote, ch.cutoff < 127 { ch.filtered = true }
        if ch.filtered, !v.pointee.filtered {
            v.pointee.filterY1 = 0
            v.pointee.filterY2 = 0
            v.pointee.filterY1R = 0
            v.pointee.filterY2R = 0
        }
        v.pointee.filtered = ch.filtered
        guard ch.filtered else { return }
        let damping = powf(10, -Float(ch.resonance) * ((24.0 / 128.0) / 20.0))
        let rate = Float(Self.rate)
        let frequency = min(rate * 0.5, max(120, min(20000, 110 * powf(2, 0.25 + Float(ch.cutoff) / 24))))
        let r = frequency * (2 * Float.pi) / rate
        let d = (2 * damping - min(2, (1 - 2 * damping) * r)) / r
        let e = 1 / (r * r)
        v.pointee.filterA0 = 1 / (1 + d + e)
        v.pointee.filterB0 = (d + e + e) / (1 + d + e)
        v.pointee.filterB1 = -e / (1 + d + e)
    }

    private func mix_SaveIPVolumes() {
        for i in 0 ..< Int(song.antChn) * 2 {
            // A voice that was fading out has had its tick, and is cut.
            if CI[i].SType & SType_Fadeout != 0 { CI[i].SType = SType_Off }
            CI[i].SLVol2 = CI[i].SLVol1
            CI[i].SRVol2 = CI[i].SRVol1
            CI[i].SVolIPLen = 0
        }
    }

    // MARK: Mixing

    /// Leaves channels out of the sound, or brings them back: see `Renderer.setMuted`. A mark for
    /// each channel, true for one not to be heard; a channel with no mark is heard. Both of a
    /// channel's voices are its own, the note and the one before it fading out.
    ///
    /// A voice that is left out is mixed like any other, into a tick of its own that goes nowhere,
    /// so that the mixing itself has nothing to ask of each sample and is as fast as it was.
    func setMuted(_ muted: [Bool]) {
        for i in 0 ..< stm.count * 2 { CI[i].muted = i >> 1 < muted.count && muted[i >> 1] }
        if unheard == nil, muted.contains(true) {
            let tick = UnsafeMutablePointer<Int32>.allocate(capacity: (Self.mostSamplesPerTick + 1) * 2)
            tick.initialize(repeating: 0, count: (Self.mostSamplesPerTick + 1) * 2)
            unheard = tick
        }
    }

    /// Runs a tick of the song without making its sound. True unless the tick began a row that has
    /// been played before.
    func runSilentTick() -> Bool {
        cameRound = false
        mainPlayer()
        return !cameRound
    }

    /// Runs a tick of the song and makes its sound in `mixBuffer`. Returns how many samples it is.
    func runTick() -> Int {
        cameRound = false
        mix_SaveIPVolumes()
        mainPlayer()
        mix_UpdateChannelVolPanFrq()
        let count = Int(speedVal)
        mixBuffer.update(repeating: 0, count: count * 2)
        if let plugIns {
            plugIns.begin(frames: count)
            placesUsed.removeAll(keepingCapacity: true)
        }
        reverbUsed = false
        // A voice at its loudest, in the mixer's numbers, whichever side it is on.
        let full = Float(255 * CDA_Amp) * 4096
        let waves = waves
        for i in 0 ..< Int(song.antChn) * 2 {
            swing.clear()
            loudest = 0
            if let waves { keepWave(CI + i, i, waves) } else { mix(CI + i, speedVal) }
            // A channel is the louder of its two voices: the note, and the one before it dying away.
            let level = swing.moved ? min(1, Float(swing.high - swing.low) * (0.5 / 32768.0) * loudest / full) : 0
            if i & 1 == 0 || level > levels.now[i >> 1] { levels.now[i >> 1] = level }
            if i & 1 == 0 { levels.until[i >> 1] = 0 }
            if level > 0 { levels.until[i >> 1] = max(levels.until[i >> 1], Int(sounded)) }
        }
        waves?.advance(by: count)
        if reverb != nil { addReverb(count) }
        if plugIns != nil { sendThroughPlugIns(count) }
        for i in 0 ..< Int(song.antChn) {
            // The channel's own voice, and not the one a note before it is dying away on.
            let v = CI + chnReloc[i]
            let playing = v.pointee.SType & SType_Off == 0 && v.pointee.SBase != nil && v.pointee.SFrq > 0
            notes.pitches[i] = playing ? ChannelPitch.note(ofRate: Double(v.pointee.SFrq) * Double(Self.rate) / 65536) : 0
        }
        return count
    }

    /// What OpenMPT does to a tick once its voices are mixed, for a song with plug-ins of its own:
    /// what was sent to each plug-in is given to it, the plug-ins are run, and what they make is
    /// added to the tick, which master effects then work on as a whole.
    private func sendThroughPlugIns(_ count: Int) {
        guard let plugIns, let tick = plugInTick else { return }
        // (As loud as OpenMPT has the voices in the file's way of adding up; the plug-ins make that
        // what OpenMPT gives them.)
        let level = openMPTMixLevel
        for place in placesUsed {
            guard let sent = placeTicks[place] else { continue }
            let input = plugIns.buffer(ofPlace: place)
            for i in 0 ..< count * 2 { input[i] += Float(sent[i]) * level }
        }
        if !placesUsed.isEmpty || (0 ..< Int(song.antChn) * 2).contains(where: { CI[$0].SType & SType_Off == 0 }) { plugIns.voiceMixed() }
        for i in 0 ..< count * 2 { tick[i] = Float(mixBuffer[i]) * level }
        plugIns.process(master: tick, frames: count)
        let back = 1 / level
        for i in 0 ..< count * 2 {
            let value = (tick[i] * back).rounded()
            mixBuffer[i] = value >= 2_147_483_648 ? Int32.max : value < -2_147_483_648 ? Int32.min : Int32(value)
        }
    }

    /// What OpenMPT does with ModPlug's reverb after a tick's voices are mixed, before the plug-ins:
    /// what was sent to it is given to it, in OpenMPT's whole numbers and blocks, and what it makes
    /// is added to the tick.
    private func addReverb(_ count: Int) {
        guard let reverb, let reverbTick else { return }
        // (FastTracker's numbers as OpenMPT's, whose mix has 27 bits for a sample at its loudest.)
        let scale = Double(openMPTMixLevel) * Double(1 << 27), back = 1 / scale
        withUnsafeTemporaryAllocation(of: Int32.self, capacity: ModPlugReverb.maxFrames * 2) { added in
            guard let added = added.baseAddress else { return }
            var done = 0
            while done < count {
                let frames = min(ModPlugReverb.maxFrames, count - done)
                let send = reverb.sendBuffer
                if reverbUsed {
                    reverb.touch(send: send, frames: frames)
                    let from = reverbTick + done * 2
                    for i in 0 ..< frames * 2 { send[i] &+= Int32(max(-2.0e9, min(2.0e9, (Double(from[i]) * scale).rounded()))) }
                }
                // (What the reverb gives is only ever added to the mix, so it is given nothing to add to.)
                added.update(repeating: 0, count: frames * 2)
                reverb.process(main: added, send: send, frames: frames)
                let to = mixBuffer + done * 2
                for i in 0 ..< frames * 2 where added[i] != 0 {
                    to[i] = Int32(clamping: Int64(to[i]) + Int64((Double(added[i]) * back).rounded()))
                }
                done += frames
            }
        }
    }

    /// The tick a voice is mixed into: the song's, or the one for the plug-in it is sent to, or that
    /// for ModPlug's reverb, or for a voice of a channel left out of the sound, one that is not heard.
    /// While a voice is mixed for its scope, it is the voice's own tick that is given, and the one
    /// it would have been is kept to add that to.
    @inline(__always) private func target(of v: UnsafeMutablePointer<FT2Voice>) -> UnsafeMutablePointer<Int32> {
        guard keepingWave, let voiceTick else { return ownTarget(of: v) }
        voiceTarget = ownTarget(of: v)
        return voiceTick
    }

    @inline(__always) private func ownTarget(of v: UnsafeMutablePointer<FT2Voice>) -> UnsafeMutablePointer<Int32> {
        if v.pointee.muted, let unheard { return unheard }
        let place = v.pointee.place
        guard place >= 0, plugIns != nil, place < placeTicks.count else {
            // (The two voices of a channel, its note and the one before dying away, are side by side.)
            if let reverbTick, stm[(v - CI) / 2].reverb {
                if !reverbUsed {
                    reverbTick.update(repeating: 0, count: Int(speedVal) * 2)
                    reverbUsed = true
                }
                return reverbTick
            }
            return mixBuffer
        }
        if let tick = placeTicks[place] {
            if !placesUsed.contains(place) {
                tick.update(repeating: 0, count: Int(speedVal) * 2)
                placesUsed.append(place)
            }
            return tick
        }
        let tick = UnsafeMutablePointer<Int32>.allocate(capacity: (Self.mostSamplesPerTick + 1) * 2)
        tick.initialize(repeating: 0, count: (Self.mostSamplesPerTick + 1) * 2)
        placeTicks[place] = tick
        placesUsed.append(place)
        return tick
    }

    private func mix(_ v: UnsafeMutablePointer<FT2Voice>, _ numSamples: Int32) {
        // (A voice on its way to silence is heard only for as long as it takes to get there.)
        sounded = v.pointee.SLVol1 | v.pointee.SRVol1 == 0 ? min(numSamples, v.pointee.SVolIPLen) : numSamples
        if v.pointee.tailL | v.pointee.tailR != 0 { dieAway(v, into: target(of: v), frames: numSamples, from: (v.pointee.tailL, v.pointee.tailR), carried: true) }
        if v.pointee.SType & SType_Off != 0 { return }
        guard let base = v.pointee.SBase else { return }

        if UInt32(bitPattern: v.pointee.SLVol1 | v.pointee.SRVol1 | v.pointee.SLVol2 | v.pointee.SRVol2) == 0 {
            // Silent: the voice is only moved on.
            let samplesToMix = UInt64(v.pointee.SFrq) &* UInt64(UInt32(numSamples))
            let samples = Int32(truncatingIfNeeded: samplesToMix >> 16)
            let samplesFrac = Int32(truncatingIfNeeded: samplesToMix & 0xFFFF) &+ Int32(v.pointee.SPosDec >> 16)
            var realPos = v.pointee.SPos &+ samples &+ (samplesFrac >> 16)
            if realPos >= v.pointee.SLen, !wrap(v, &realPos) { return }
            v.pointee.SPosDec = UInt32(samplesFrac & 0xFFFF) << 16
            v.pointee.SPos = realPos
        } else if let right = v.pointee.SBaseR {
            // (A sample in stereo: see `FT2Module.playStereoSamples`.)
            if v.pointee.sixteen {
                mix(v, numSamples, base.assumingMemoryBound(to: Int16.self), v.pointee.SRevBase?.assumingMemoryBound(to: Int16.self), shift: 0,
                    right: right.assumingMemoryBound(to: Int16.self), rightReverse: v.pointee.SRevBaseR?.assumingMemoryBound(to: Int16.self))
            } else {
                mix(v, numSamples, base.assumingMemoryBound(to: Int8.self), v.pointee.SRevBase?.assumingMemoryBound(to: Int8.self), shift: 8,
                    right: right.assumingMemoryBound(to: Int8.self), rightReverse: v.pointee.SRevBaseR?.assumingMemoryBound(to: Int8.self))
            }
        } else if v.pointee.sixteen {
            mix(v, numSamples, base.assumingMemoryBound(to: Int16.self), v.pointee.SRevBase?.assumingMemoryBound(to: Int16.self), shift: 0, right: nil, rightReverse: nil)
        } else {
            mix(v, numSamples, base.assumingMemoryBound(to: Int8.self), v.pointee.SRevBase?.assumingMemoryBound(to: Int8.self), shift: 8, right: nil, rightReverse: nil)
        }
    }

    /// What a voice last put out on each side, dying away over so many frames of `to` (as OpenMPT has
    /// it, by a 256th of itself a frame, and by one at least), and kept for the ticks after.
    /// - Parameter carried: true for what was kept from the ticks before, false for what it last
    ///   put out, which is added to that.
    private func dieAway(_ v: UnsafeMutablePointer<FT2Voice>, into to: UnsafeMutablePointer<Int32>, frames: Int32, from: (Int32, Int32), carried: Bool) {
        @inline(__always) func step(_ x: Int32) -> Int32 { (x &+ (x > 0 ? 0xFF : 0)) >> 8 }
        var (l, r) = from
        var at = to
        for _ in 0 ..< max(0, frames) {
            l &-= step(l)
            r &-= step(r)
            at[0] &+= l
            at[1] &+= r
            at += 2
        }
        if carried {
            v.pointee.tailL = l
            v.pointee.tailR = r
        } else {
            v.pointee.tailL &+= l
            v.pointee.tailR &+= r
        }
    }

    /// A voice has run off the end of what it was playing: round its loop, or off. False if it is off.
    @inline(__always) private func wrap(_ v: UnsafeMutablePointer<FT2Voice>, _ realPos: inout Int32) -> Bool {
        var SType = v.pointee.SType
        guard SType & (SType_Fwd + SType_Rev) != 0, v.pointee.SRepL > 0, v.pointee.backwards != FT2Voice.backwardsOnce else {
            v.pointee.SType = SType_Off
            return false
        }
        if v.pointee.backwards == FT2Voice.backwardsRound {
            repeat { realPos &-= v.pointee.SRepL } while realPos >= v.pointee.SLen
            v.pointee.looped = true
            return true
        }
        repeat {
            realPos &-= v.pointee.SRepL
            SType ^= SType_RevDir
        } while realPos >= v.pointee.SLen
        v.pointee.SType = SType
        v.pointee.looped = true
        return true
    }

    /// FastTracker's mixing of one voice into the tick, with its interpolation between one sample
    /// and the next and its ramp from the volume a voice had to the volume it is to have. The
    /// oddities are FastTracker's, and are what make the result the same as its own to the bit.
    /// With `right`, the voice is a sample in stereo, whose left side is `linear` and is heard on
    /// the left, and whose right side is read in step with it and heard on the right.
    @inline(__always) private func mix<T: FixedWidthInteger & SignedInteger>(
        _ v: UnsafeMutablePointer<FT2Voice>, _ numSamples: Int32, _ linear: UnsafePointer<T>, _ reverse: UnsafePointer<T>?, shift: Int32,
        right: UnsafePointer<T>?, rightReverse: UnsafePointer<T>?
    ) {
        // (A voice of a channel that is left out of the sound is mixed where it is not heard.)
        var audioMix = target(of: v)
        var realPos = v.pointee.SPos
        var pos = v.pointee.SPosDec
        var mixBuffPos: UInt16 = (32768 + 96) - 8
        var lVolIP = v.pointee.SLVolIP, rVolIP = v.pointee.SRVolIP
        let filtered = v.pointee.filtered, a0 = v.pointee.filterA0, b0 = v.pointee.filterB0, b1 = v.pointee.filterB1
        var y1 = v.pointee.filterY1, y2 = v.pointee.filterY2
        var y1R = v.pointee.filterY1R, y2R = v.pointee.filterY2R
        defer {
            v.pointee.filterY1 = y1
            v.pointee.filterY2 = y2
            v.pointee.filterY1R = y1R
            v.pointee.filterY2R = y2R
        }

        var bytesLeft = numSamples
        // (What was last added to each side, for a sample that runs out: see `endsDieAway`.)
        var lastL: Int32 = 0, lastR: Int32 = 0
        // (OpenMPT's way of reading the sample, for a file of its own: see `readsAsOpenMPT`.)
        let way = v.pointee.way
        let table: UnsafePointer<Float>? = way == FT2Voice.fastTrackers ? nil
            : IT2Mixer.openMPTTables + (IT2Resampling.table(way: way, speed: UInt64(v.pointee.SFrq) << 16) - 1) * IT2Mixer.kernelLength
        let edges = FT2Edges(v.pointee)
        let toNext = Float(1 << shift)
        while bytesLeft > 0 {
            var frq = Int32(bitPattern: v.pointee.SFrq)
            var i = (v.pointee.SLen &- 1) &- realPos
            if i > 65535 { i = 65535 }
            var samplesToMix: Int32
            if frq != 0 {
                let tmp32 = (UInt32(bitPattern: i) << 16) | ((0xFFFF_0000 &- pos) >> 16)
                samplesToMix = Int32(truncatingIfNeeded: tmp32 / UInt32(bitPattern: frq)) &+ 1
            } else {
                samplesToMix = 65535
            }
            // (A count that has gone below nothing would have this go round for ever.)
            if samplesToMix > bytesLeft || samplesToMix < 1 { samplesToMix = bytesLeft }

            if v.pointee.SVolIPLen == 0 {
                lVolIP = 0
                rVolIP = 0
            } else {
                if samplesToMix > v.pointee.SVolIPLen { samplesToMix = v.pointee.SVolIPLen }
                v.pointee.SVolIPLen -= samplesToMix
            }
            bytesLeft -= samplesToMix

            var lVol = v.pointee.SLVol2, rVol = v.pointee.SRVol2
            let backwards = v.pointee.SType & (SType_Rev + SType_RevDir) == SType_Rev + SType_RevDir
            let origin: UnsafePointer<T>
            // (The right side of a sample in stereo, at the same place as the left.)
            let originR: UnsafePointer<T>?
            if backwards, let reverse {
                frq = 0 &- frq
                realPos = ~realPos
                origin = reverse
                originR = rightReverse
                pos ^= 0xFFFF_0000
            } else {
                origin = linear
                originR = right
            }
            var smpPtr = origin + Int(realPos)
            let offsetR = originR.map { $0 - origin } ?? 0
            pos &+= UInt32(mixBuffPos)
            let ipValH = Int(frq >> 16)
            let ipValL = (UInt32(bitPattern: frq & 0xFFFF) << 16) &+ 8

            var low = Int32.max, high = Int32.min
            let volumeBefore = Float(lVol) * Float(lVol) + Float(rVol) * Float(rVol)
            var n = samplesToMix
            while n > 0 {
                var sample2: Int32
                if let table {
                    let t = table + Int(pos >> 20) * 8
                    sample2 = Int32((edges.read(linear, at: smpPtr - linear, t) * toNext).rounded())
                    pos &= ~1
                } else {
                    let sample = Int32(smpPtr[0]) << shift
                    sample2 = Int32(smpPtr[1]) << shift
                    sample2 &-= sample
                    pos >>= 1
                    sample2 = Int32(truncatingIfNeeded: (Int64(sample2) &* Int64(Int32(bitPattern: pos))) >> 32)
                    pos &+= pos
                    sample2 &+= sample2
                    sample2 &+= sample
                }
                if filtered {
                    // (A later tracker's file: the sample goes through the channel's filter.)
                    let out = Float(sample2) * a0 + y1 * b0 + y2 * b1
                    y2 = y1
                    y1 = max(-131_072, min(131_072, out))
                    sample2 = Int32(y1)
                }
                if sample2 < low { low = sample2 }
                if sample2 > high { high = sample2 }
                sample2 <<= 28 - 16
                var sampleR = sample2
                if let right {
                    let p = smpPtr + offsetR
                    var next: Int32
                    if let table {
                        // (OpenMPT's way, at the same place as the left side.)
                        next = Int32((edges.read(right, at: smpPtr - linear, table + Int(pos >> 20) * 8) * toNext).rounded())
                    } else {
                        let first = Int32(p[0]) << shift
                        next = (Int32(p[1]) << shift) &- first
                        // (The same fraction of the way to the next as the left side: `pos` is back to twice it.)
                        next = Int32(truncatingIfNeeded: (Int64(next) &* Int64(Int32(bitPattern: pos >> 1))) >> 32)
                        next &+= next
                        next &+= first
                    }
                    if filtered {
                        let out = Float(next) * a0 + y1R * b0 + y2R * b1
                        y2R = y1R
                        y1R = max(-131_072, min(131_072, out))
                        next = Int32(y1R)
                    }
                    if next < low { low = next }
                    if next > high { high = next }
                    sampleR = next << (28 - 16)
                }
                lastL = Int32(truncatingIfNeeded: (Int64(sample2) &* Int64(lVol)) >> 32)
                lastR = Int32(truncatingIfNeeded: (Int64(sampleR) &* Int64(rVol)) >> 32)
                audioMix[0] &+= lastL
                audioMix[1] &+= lastR
                audioMix += 2
                smpPtr += ipValH
                if ipValL > ~pos { smpPtr += 1 }
                pos &+= ipValL
                lVol &+= lVolIP
                rVol &+= rVolIP
                n -= 1
            }
            if low <= high {
                swing.note(low)
                swing.note(high)
                loudest = max(loudest, max(volumeBefore, Float(lVol) * Float(lVol) + Float(rVol) * Float(rVol)).squareRoot())
            }

            if backwards, reverse != nil {
                pos ^= 0xFFFF_0000
                realPos = ~Int32(truncatingIfNeeded: smpPtr - origin)
            } else {
                realPos = Int32(truncatingIfNeeded: smpPtr - origin)
            }
            mixBuffPos = UInt16(truncatingIfNeeded: pos)
            pos &= 0xFFFF_0000
            if realPos >= v.pointee.SLen, !wrap(v, &realPos) {
                sounded = min(sounded, numSamples - bytesLeft)
                if endsDieAway { dieAway(v, into: audioMix, frames: bytesLeft, from: (lastL, lastR), carried: false) }
                return
            }
            v.pointee.SLVol2 = lVol
            v.pointee.SRVol2 = rVol
        }
        v.pointee.SPosDec = pos & 0xFFFF_0000
        v.pointee.SPos = realPos
    }
}

/// Where a voice's sample ends and loops, for reading it through eight points (see
/// `FT2Player.readsAsOpenMPT`). Past the end of a loop comes its start again, or for a ping-pong
/// loop its end backwards; and the same before its start, once the voice has been round. Past the
/// end of a sample that does not loop is its last value held, and before its start its first.
struct FT2Edges {
    let length: Int, loopStart: Int, loopLength: Int
    /// 0 for no loop, 1 for one forwards, 2 for one that goes back and forth.
    let kind: Int
    let looped: Bool

    init(_ v: FT2Voice) {
        length = Int(max(0, v.SLen))
        loopStart = Int(max(0, v.SRepS))
        loopLength = Int(max(0, v.SRepL))
        kind = v.SType & SType_Rev != 0 && loopLength > 0 ? 2 : v.SType & SType_Fwd != 0 && loopLength > 0 ? 1 : 0
        looped = v.looped
    }

    /// The place in the sample that is read for `index`.
    @inline(__always) func place(_ index: Int) -> Int {
        if kind != 0 {
            let loopEnd = loopStart + loopLength
            if index >= loopEnd {
                let d = (index - loopEnd) % (kind == 2 ? 2 * loopLength : loopLength)
                return kind == 1 ? loopStart + d : d < loopLength ? loopEnd - 1 - d : loopStart + d - loopLength
            }
            if index < loopStart, looped {
                let d = (loopStart - 1 - index) % (kind == 2 ? 2 * loopLength : loopLength)
                return kind == 1 ? loopEnd - 1 - d : d < loopLength ? loopStart + d : loopEnd - 1 - (d - loopLength)
            }
        }
        return index < 0 ? 0 : index >= length ? length - 1 : index
    }

    /// The eight samples about `index` of `base`, each by its weight in `t`.
    @inline(__always) func read<T: FixedWidthInteger & SignedInteger>(_ base: UnsafePointer<T>, at index: Int, _ t: UnsafePointer<Float>) -> Float {
        let low = kind != 0 && looped ? loopStart : 0
        var out: Float = 0
        if index - 3 >= low, index + 4 < length {
            let s = base + index
            out = Float(Int32(s[-3])) * t[0]
            out += Float(Int32(s[-2])) * t[1]
            out += Float(Int32(s[-1])) * t[2]
            out += Float(Int32(s[0])) * t[3]
            out += Float(Int32(s[1])) * t[4]
            out += Float(Int32(s[2])) * t[5]
            out += Float(Int32(s[3])) * t[6]
            out += Float(Int32(s[4])) * t[7]
        } else if length > 0 {
            for tap in 0 ..< 8 { out += Float(Int32(base[place(index + tap - 3)])) * t[tap] }
        }
        return out
    }
}
