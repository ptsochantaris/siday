// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ft2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

// What the replayer tells the mixer of a voice.
private let Status_SetVol: UInt8 = 1, Status_SetPan: UInt8 = 2, Status_SetFrq: UInt8 = 4
private let Status_StartTone: UInt8 = 8, Status_StopTone: UInt8 = 16, Status_QuickVol: UInt8 = 32
// How a voice is playing.
private let SType_Fwd: UInt8 = 1, SType_Rev: UInt8 = 2, SType_RevDir: UInt8 = 4, SType_Off: UInt8 = 8, SType_Fadeout: UInt8 = 32

/// A voice of the mixer. There are two to a channel: when a note is cut short by the next, the old
/// one fades out on one voice while the new one starts on the other, which is what keeps it from clicking.
struct FT2Voice {
    var SBase: UnsafeRawPointer?, SRevBase: UnsafeRawPointer?
    var SType: UInt8 = 0, SPan: UInt8 = 0, SVol: UInt8 = 0
    // The volume wanted on each side, the volume it has got to, and the step from one towards the other.
    var SLVol1: Int32 = 0, SRVol1: Int32 = 0, SLVol2: Int32 = 0, SRVol2: Int32 = 0, SLVolIP: Int32 = 0, SRVolIP: Int32 = 0, SVolIPLen: Int32 = 0
    var SLen: Int32 = 0, SRepS: Int32 = 0, SRepL: Int32 = 0, SPos: Int32 = 0
    var sixteen = false
    var SPosDec: UInt32 = 0, SFrq: UInt32 = 0
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
    /// For the lights: how loud each channel was in the tick last made.
    var levels: TickLevels
    /// And what each is playing.
    var notes: TickNotes
    /// The lowest and highest the voice being mixed has had its sample, and the most its volume has been.
    private var swing = Swing<Int32>(from: -65536, to: 65536)
    private var loudest: Float = 0

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
    /// How many rows the table of who played a row first has: 256 for each of 256 places.
    static let rowsInAll = 256 * 256
    /// True once the song has stopped itself, with a speed of nothing.
    var stopped: Bool { song.tempo == 0 }

    /// - Parameters:
    ///   - position: where in the list of patterns to start.
    ///   - firstPlayedBy: for a file of several songs, which of them first played each row.
    ///   - songNumber: which of them this is.
    init(_ module: FT2Module, position: Int = 0, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil, songNumber: UInt8 = 0) {
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
        let placeholder = module.instr[0]!
        let channels = max(1, Int(module.song.antChn))
        stm = (0 ..< channels).map { FT2Channel(nr: $0, instrument: placeholder) }
        chnReloc = (0 ..< channels).map { $0 + $0 }
        levels = TickLevels(voices: channels)
        notes = TickNotes(voices: channels)

        let rate = Double(Self.rate)
        frequenceDivFactor = UInt32((65536.0 * 1712.0 / rate * 8363.0).rounded())
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
        song.globVol = 64
        song.timer = 1
        P_SetSpeed(song.speed)
    }

    deinit {
        CI.deallocate()
        mixBuffer.deallocate()
        visited.deallocate()
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

    func P_StartTone(_ s: FT2Sample, _ smpStartPos: Int32, _ nr: Int) {
        let v = stopTone(nr)
        var type = s.typ
        let sample16Bit = (type >> 4) & 1 != 0
        var len: Int32
        if type & (SType_Fwd + SType_Rev) != 0 {
            var repL = s.repL, repS = s.repS
            if sample16Bit {
                repL >>= 1
                repS >>= 1
            }
            v.pointee.SRevBase = s.pek.map { UnsafeRawPointer($0) + Int(repS &+ repS &+ repL) * (sample16Bit ? 2 : 1) }
            v.pointee.SRepL = repL
            v.pointee.SRepS = repS
            len = repS &+ repL
        } else {
            type &= ~(SType_Fwd + SType_Rev)
            len = s.len
            if sample16Bit { len >>= 1 }
            if len == 0 { return }
        }
        // A sample offset beyond the end of the sample: the voice stays cut.
        if smpStartPos >= len || s.pek == nil { return }
        v.pointee.SLen = len
        v.pointee.SPos = smpStartPos
        v.pointee.SPosDec = 0
        v.pointee.SBase = UnsafeRawPointer(s.pek)
        v.pointee.sixteen = sample16Bit
        v.pointee.SType = type
        notes.struck[nr] = true
    }

    private func mix_UpdateChannelVolPanFrq() {
        for i in 0 ..< Int(song.antChn) {
            let ch = stm[i]
            let status = ch.status
            ch.status = 0
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
            if status & IS_Period != 0 { v.pointee.SFrq = getFrequenceValue(ch.finalPeriod) }
        }
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
        // A voice at its loudest, in the mixer's numbers, whichever side it is on.
        let full = Float(255 * CDA_Amp) * 4096
        for i in 0 ..< Int(song.antChn) * 2 {
            swing.clear()
            loudest = 0
            mix(CI + i, speedVal)
            // A channel is the louder of its two voices: the note, and the one before it dying away.
            let level = swing.moved ? min(1, Float(swing.high - swing.low) * (0.5 / 32768.0) * loudest / full) : 0
            if i & 1 == 0 || level > levels.now[i >> 1] { levels.now[i >> 1] = level }
        }
        levels.tickMade()
        for i in 0 ..< Int(song.antChn) {
            // The channel's own voice, and not the one a note before it is dying away on.
            let v = CI + chnReloc[i]
            let playing = v.pointee.SType & SType_Off == 0 && v.pointee.SBase != nil && v.pointee.SFrq > 0
            notes.pitches[i] = playing ? ChannelPitch.note(ofRate: Double(v.pointee.SFrq) * Double(Self.rate) / 65536) : 0
        }
        return count
    }

    private func mix(_ v: UnsafeMutablePointer<FT2Voice>, _ numSamples: Int32) {
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
        } else if v.pointee.sixteen {
            mix(v, numSamples, base.assumingMemoryBound(to: Int16.self), v.pointee.SRevBase?.assumingMemoryBound(to: Int16.self), shift: 0)
        } else {
            mix(v, numSamples, base.assumingMemoryBound(to: Int8.self), v.pointee.SRevBase?.assumingMemoryBound(to: Int8.self), shift: 8)
        }
    }

    /// A voice has run off the end of what it was playing: round its loop, or off. False if it is off.
    @inline(__always) private func wrap(_ v: UnsafeMutablePointer<FT2Voice>, _ realPos: inout Int32) -> Bool {
        var SType = v.pointee.SType
        guard SType & (SType_Fwd + SType_Rev) != 0, v.pointee.SRepL > 0 else {
            v.pointee.SType = SType_Off
            return false
        }
        repeat {
            realPos &-= v.pointee.SRepL
            SType ^= SType_RevDir
        } while realPos >= v.pointee.SLen
        v.pointee.SType = SType
        return true
    }

    /// FastTracker's mixing of one voice into the tick, with its interpolation between one sample
    /// and the next and its ramp from the volume a voice had to the volume it is to have. The
    /// oddities are FastTracker's, and are what make the result the same as its own to the bit.
    @inline(__always) private func mix<T: FixedWidthInteger & SignedInteger>(
        _ v: UnsafeMutablePointer<FT2Voice>, _ numSamples: Int32, _ linear: UnsafePointer<T>, _ reverse: UnsafePointer<T>?, shift: Int32
    ) {
        var audioMix = mixBuffer
        var realPos = v.pointee.SPos
        var pos = v.pointee.SPosDec
        var mixBuffPos: UInt16 = (32768 + 96) - 8
        var lVolIP = v.pointee.SLVolIP, rVolIP = v.pointee.SRVolIP

        var bytesLeft = numSamples
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
            if backwards, let reverse {
                frq = 0 &- frq
                realPos = ~realPos
                origin = reverse
                pos ^= 0xFFFF_0000
            } else {
                origin = linear
            }
            var smpPtr = origin + Int(realPos)
            pos &+= UInt32(mixBuffPos)
            let ipValH = Int(frq >> 16)
            let ipValL = (UInt32(bitPattern: frq & 0xFFFF) << 16) &+ 8

            var low = Int32.max, high = Int32.min
            let volumeBefore = Float(lVol) * Float(lVol) + Float(rVol) * Float(rVol)
            var n = samplesToMix
            while n > 0 {
                let sample = Int32(smpPtr[0]) << shift
                var sample2 = Int32(smpPtr[1]) << shift
                sample2 &-= sample
                pos >>= 1
                sample2 = Int32(truncatingIfNeeded: (Int64(sample2) &* Int64(Int32(bitPattern: pos))) >> 32)
                pos &+= pos
                sample2 &+= sample2
                sample2 &+= sample
                if sample2 < low { low = sample2 }
                if sample2 > high { high = sample2 }
                sample2 <<= 28 - 16
                audioMix[0] &+= Int32(truncatingIfNeeded: (Int64(sample2) &* Int64(lVol)) >> 32)
                audioMix[1] &+= Int32(truncatingIfNeeded: (Int64(sample2) &* Int64(rVol)) >> 32)
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
            if realPos >= v.pointee.SLen, !wrap(v, &realPos) { return }
            v.pointee.SLVol2 = lVol
            v.pointee.SRVol2 = rVol
        }
        v.pointee.SPosDec = pos & 0xFFFF_0000
        v.pointee.SPos = realPos
    }
}
