// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from st3play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// An S3M file as Scream Tracker 3 holds one.
///
/// Scream Tracker's own samples are eight bits and no longer than 64,000 bytes. Trackers that came
/// after it wrote S3M files with sixteen-bit samples and longer ones, so every sample is held here in
/// sixteen bits, and a file with a long sample is marked as one Scream Tracker could not have made.
final class ST3Module {
    /// An instrument: a sample, or a voice of the AdLib card's.
    struct Instrument {
        var type: UInt8 = 0
        var length: UInt32 = 0, lbeg: UInt32 = 0, lend: UInt32 = 0
        var vol: UInt8 = 0
        var flags: UInt8 = 0
        var c2spd: UInt32 = 0
        var guspos: UInt16 = 0
        var lend512: UInt16 = 0
        /// Where its sample is in `samples`; -1 if it has none.
        var baseptr = -1
        /// For a voice of the AdLib card's: the numbers that set up the card's chip for it.
        var adlib = InlineArray<12, UInt8>(repeating: 0)
    }

    static let mostOrders = 256, mostInstruments = 99, mostPatterns = 100

    let title: String
    // The header, by its own names.
    let ordnum: Int, insnum: Int, patnum: Int
    let flags: UInt16, cwtv: UInt16, ffv: UInt16
    let globalvol: UInt8, initspeed: UInt8, inittempo: UInt8
    let mastermul: UInt8
    let ultraclick: UInt8
    let channel: [UInt8]
    private(set) var order = [UInt8](repeating: 255, count: mostOrders + 1)
    private(set) var defaultpan = [UInt8](repeating: 0, count: 32)
    private(set) var ins = [Instrument](repeating: Instrument(), count: mostInstruments + 1)
    private(set) var patp = [[UInt8]?](repeating: nil, count: mostPatterns + 1)
    /// Every sample, one after another, each with room after it for its loop to be written out again.
    let samples: UnsafeMutablePointer<Int16>
    let samplesCount: Int
    /// True if the file was saved by Scream Tracker 3 with a Sound Blaster, as far as can be told.
    let savedWithSoundBlaster: Bool
    /// True if some sample is longer than Scream Tracker allows, or of sixteen bits.
    let beyondScreamTracker: Bool
    /// True if the file is taken to be one that Scream Tracker 3 itself saved: it says so, and
    /// has what Scream Tracker leaves in a file and other trackers that say the same do not.
    let madeByScreamTracker: Bool
    /// True for a DSM file's module, which is played as OpenMPT plays one where it and Scream Tracker
    /// differ (see `DSMFile`): a slide to a note that names another sample than the one sounding
    /// goes on with that one, at its rate, where Scream Tracker takes up the other's rate; a slide on
    /// a channel whose sample has ended starts it again, where Scream Tracker slides it in silence;
    /// and a tempo is the tempo asked for, where Scream Tracker's timer on a Gravis Ultrasound goes
    /// by whole ticks a second, so that a tempo of 136 is played as 135 is.
    var playsAsDSIK = false
    /// What the file asks for that is not played as it asks: see `TuneInfo.shortfalls`. An S3M file
    /// from a later tracker may have what Scream Tracker never had.
    private(set) var shortfalls: [String] = []
    /// The samples that are in stereo: which they are, and each as Scream Tracker has it, its left
    /// side alone, its right side, and with its two sides mixed into one. See `playStereoSamples`.
    /// (And where the file says a loop of it was last written out again, which putting a sample
    /// in order changes.)
    private var inStereo: [(instrument: Int, left: [Int16], right: [Int16], mixed: [Int16], lend512: UInt16)] = []
    /// For a file with samples in stereo: the right side of each, at the same place as its left
    /// side is in `samples`, while they are played apart (see `playStereoSamples`).
    private var rightMemory: Memory<Int16>?
    var samplesRight: UnsafeMutablePointer<Int16>? { rightMemory?.pointer }
    /// True while samples in stereo are played with their sides apart.
    private(set) var stereoApart = false
    /// Where in `samples` each sample in stereo begins.
    var stereoBases: Set<Int> { Set(inStereo.map { ins[$0.instrument].baseptr }) }
    /// What is said of samples in stereo, if there are any the tune plays, for when they are mixed into one.
    private(set) var stereoSentence: String?

    deinit {
        samples.deallocate()
    }

    init(_ data: [UInt8]) throws {
        let f = ByteReader(data)
        guard data.count > 0x60, f[0x2C] == 0x53, f[0x2D] == 0x43, f[0x2E] == 0x52, f[0x2F] == 0x4D else {
            throw TuneError.malformed("not an S3M file")
        }
        ordnum = f.u16le(0x20)
        insnum = f.u16le(0x22)
        patnum = f.u16le(0x24)
        guard ordnum <= Self.mostOrders, insnum <= Self.mostInstruments, patnum <= Self.mostPatterns else {
            throw TuneError.unsupported("an S3M file with more orders, instruments or patterns than Scream Tracker 3 has room for")
        }
        title = f.dos(at: 0, length: 27)
        var flags = UInt16(f.u16le(0x26))
        cwtv = UInt16(f.u16le(0x28))
        ffv = UInt16(f.u16le(0x2A))
        globalvol = f[0x30]
        initspeed = f[0x31]
        inittempo = f[0x32]
        var mastermul = f[0x33]
        var ultraclick = f[0x34]
        channel = (0 ..< 32).map { f[0x40 + $0] }

        var songMadeWithST3 = cwtv >> 12 == 1
        if cwtv == 0x1300 { flags |= 64 } // the first version slid volumes on every tick
        if !songMadeWithST3 || cwtv < 0x1310 { ultraclick = 16 }
        if ffv == 1 {
            switch mastermul {
            case 0 ... 6: mastermul = (mastermul + 1) << 4
            case 7: mastermul = 0x7F
            default: break
            }
        }
        if mastermul == 2 { mastermul = 0x20 }
        if mastermul == 2 + 16 { mastermul = 0x20 + 128 }
        // (A GUS has no more than 32 voices; a file that asks for more is asking for nothing real.)
        if ultraclick == 0 || ultraclick > 32 { ultraclick = 16 }
        self.flags = flags
        self.mastermul = mastermul
        self.ultraclick = ultraclick

        var at = 0x60
        for i in 0 ..< ordnum { order[i] = f[at + i] }
        at += ordnum
        let insoff = (0 ..< insnum).map { f.u16le(at + $0 * 2) }
        at += insnum * 2
        let patoff = (0 ..< patnum).map { f.u16le(at + $0 * 2) }
        at += patnum * 2
        if f[0x35] == 252 {
            for i in 0 ..< 32 { defaultpan[i] = f[at + i] }
        }

        var offsets = [Int](repeating: 0, count: insnum)
        var beyond = false
        for i in 0 ..< insnum {
            let o = insoff[i] << 4
            guard o + 0x50 <= data.count else { continue }
            ins[i].type = f[o]
            if ins[i].type >= 2, ins[i].type <= 7 {
                for k in 0 ..< 12 { ins[i].adlib[k] = f[o + 16 + k] }
            }
            ins[i].length = UInt32(truncatingIfNeeded: f.u32le(o + 16))
            ins[i].lbeg = UInt32(truncatingIfNeeded: f.u32le(o + 20))
            ins[i].lend = UInt32(truncatingIfNeeded: f.u32le(o + 24))
            ins[i].vol = f[o + 28]
            ins[i].flags = f[o + 31]
            ins[i].c2spd = UInt32(truncatingIfNeeded: f.u32le(o + 32))
            ins[i].guspos = UInt16(f.u16le(o + 40))
            ins[i].lend512 = UInt16(f.u16le(o + 42))
            // (A sample whose place in the file has nothing in its lower part is taken not to be there.)
            offsets[i] = f.u16le(o + 14) == 0 ? 0 : Int(f.u16le(o + 14)) << 4 + Int(f[o + 13]) << 20
            if ins[i].type == 1, ins[i].length > 64000 || ins[i].flags & 4 != 0 { beyond = true }
        }
        beyondScreamTracker = beyond

        for i in 0 ..< patnum where patoff[i] != 0 {
            let o = patoff[i] << 4
            // A pattern says how long it is, and that length counts the two bytes that say so.
            let length = f.u16le(o)
            var bytes = [UInt8](repeating: 0, count: max(length, 2))
            for k in 0 ..< max(0, length - 2) { bytes[k] = f[o + 2 + k] }
            patp[i] = bytes
        }

        // Where each sample goes, and how much of it the file has.
        var total = 0
        var cutShort = Shortfall.CutShort()
        for i in 0 ..< insnum where ins[i].type == 1 && offsets[i] != 0 {
            let bytesPerSample = ins[i].flags & 4 != 0 ? 2 : 1
            let stated = Int(truncatingIfNeeded: ins[i].length)
            let there = max(0, (data.count - offsets[i]) / bytesPerSample)
            if stated > 0, stated < 1 << 28 { cutShort.add(length: stated * bytesPerSample, there: data.count - offsets[i]) }
            if stated < 0 || stated > there { ins[i].length = UInt32(there) }
            // Scream Tracker's limit, kept for the files it could have made.
            if !beyond, ins[i].length > 64000 { ins[i].length = 64000 }
            ins[i].baseptr = total
            total += Int(ins[i].length) + 512 + 2
        }
        samplesCount = total + 16
        samples = .allocate(capacity: samplesCount)
        samples.initialize(repeating: 0, count: samplesCount)
        let unsigned = ffv != 1
        for i in 0 ..< insnum where ins[i].baseptr >= 0 {
            let base = ins[i].baseptr, length = Int(ins[i].length), sixteenBit = ins[i].flags & 4 != 0
            let left = Self.side(f, from: offsets[i], length: length, sixteenBit: sixteenBit, unsigned: unsigned)
            for k in 0 ..< length { samples[base + k] = left[k] }
            // A sample in stereo has its right side after its left, if the file goes on that far.
            let bytes = length * (sixteenBit ? 2 : 1)
            if ins[i].flags & 2 != 0, length > 0, offsets[i] + bytes * 2 <= data.count {
                let right = Self.side(f, from: offsets[i] + bytes, length: length, sixteenBit: sixteenBit, unsigned: unsigned)
                inStereo.append((i, left, right, (0 ..< length).map { k in Int16((Int(left[k]) + Int(right[k])) >> 1) }, ins[i].lend512))
            }
        }
        if !inStereo.isEmpty {
            let memory = Memory<Int16>(capacity: samplesCount)
            memory.pointer.initialize(repeating: 0, count: samplesCount)
            rightMemory = memory
        }

        // Was it saved with a Sound Blaster? Scream Tracker left a mark in each sample when it was:
        // where the sample would have been in a GUS's memory is 1, or in its first version nothing.
        var soundBlaster = false
        var gusPositions = 0, sampleCount = 0
        for instrument in ins[0 ..< insnum] where instrument.type == 1 {
            gusPositions |= Int(instrument.guspos)
            sampleCount += 1
        }
        // Other trackers say they are version 3.20, and leave nothing there at all.
        if songMadeWithST3, cwtv == 0x1320, gusPositions == 0 { songMadeWithST3 = false }
        if songMadeWithST3, sampleCount >= 2, gusPositions <= 1 { soundBlaster = true }
        savedWithSoundBlaster = soundBlaster
        madeByScreamTracker = songMadeWithST3

        noteWhatIsNotPlayed(f, insoff)
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }
        for i in 0 ..< Self.mostInstruments { checkins(i) }
        playStereoSamples(asScreamTracker: false)
    }

    /// Says how samples in stereo are to be played. Scream Tracker knows nothing of them, and no
    /// file of its own has one: it plays the left side, which comes first in the file, and never
    /// gets to the right. The trackers that came after it, which are the ones that make such
    /// samples, play the two sides together: `apart`, the left side on the left and the right on
    /// the right, as a Gravis Ultrasound can, each of its voices having its own place between the
    /// speakers; otherwise mixed into one, as for the Sound Blaster, whose channels are each to
    /// one side. They can be had as Scream Tracker has them for setting what is played beside the
    /// player this is ported from.
    func playStereoSamples(asScreamTracker: Bool, apart: Bool = false) {
        stereoApart = apart && !asScreamTracker && rightMemory != nil
        for one in inStereo {
            let base = ins[one.instrument].baseptr, sides = asScreamTracker || stereoApart ? one.left : one.mixed
            // As the file has it, with nothing after its end, and then put in order afresh.
            for k in 0 ..< sides.count { samples[base + k] = sides[k] }
            for k in sides.count ..< sides.count + 512 + 2 { samples[base + k] = 0 }
            if stereoApart, let right = samplesRight {
                for k in 0 ..< one.right.count { right[base + k] = one.right[k] }
                for k in one.right.count ..< one.right.count + 512 + 2 { right[base + k] = 0 }
                // (In order as the left side is put: from the same point, the same way.)
                ins[one.instrument].lend512 = one.lend512
                checkins(one.instrument, in: right)
            }
            ins[one.instrument].lend512 = one.lend512
            checkins(one.instrument)
        }
    }

    /// One side of a sample, as it lies in the file from a place on.
    private static func side(_ f: ByteReader, from: Int, length: Int, sixteenBit: Bool, unsigned: Bool) -> [Int16] {
        if sixteenBit {
            return (0 ..< length).map { k in
                let value = UInt16(f[from + k * 2]) | UInt16(f[from + k * 2 + 1]) << 8
                return Int16(bitPattern: unsigned ? value ^ 0x8000 : value)
            }
        }
        return (0 ..< length).map { k in Int16(Int8(bitPattern: unsigned ? f[from + k] ^ 0x80 : f[from + k])) << 8 }
    }

    /// The command of later trackers that is found in S3M files and is not played, by its number
    /// (a command's letter, counted from A as 1) and by what it does: Z, which sets a filter that
    /// Scream Tracker's sound cards have not got. (And S99, which puts a channel in ModPlug's own
    /// reverb: that is played in an IT, MPTM or XM file of ModPlug Tracker's or OpenMPT's, but not
    /// on Scream Tracker's cards, and is said to be left out.)
    ///
    /// Others are not counted. M, N and W, a channel's volume and the slides of it and of the
    /// whole tune's, are played in a file that a later tracker made (see
    /// `ST3Player.playsLaterCommands`). In a file that Scream Tracker itself saved, all of these
    /// are nothing, as they were to Scream Tracker and to whoever heard the tune there. So are the
    /// three that put a channel somewhere between the speakers (X), slide it there (P) or sweep it
    /// from side to side (Y), on a card whose voices have places (see `ST3Player.laterPanning`);
    /// on the Sound Blaster, whose channels are each to a side, they are nothing, and that is not
    /// said: a file of a later tracker's is played on the Gravis Ultrasound unless it is asked for.
    private static let commandsOfLaterTrackers: [UInt8] = [26]
    private static let whatTheyDo = ["the setting of a filter", "ModPlug's reverb"]

    /// Looks over the file for what its patterns use that is not played as the file asks, and
    /// says so in `shortfalls`. Nothing that is played is changed by it.
    private func noteWhatIsNotPlayed(_ f: ByteReader, _ insoff: [Int]) {
        var used = [Bool](repeating: false, count: 256)
        var commands = Shortfall.Kinds()
        for case let pattern? in patp {
            var at = 0
            while at < pattern.count {
                let what = pattern[at]
                at += 1
                if what & 0x20 != 0 {
                    if at + 1 < pattern.count { used[Int(pattern[at + 1])] = true }
                    at += 2
                }
                if what & 0x40 != 0 { at += 1 }
                if what & 0x80 != 0 {
                    if at < pattern.count, !madeByScreamTracker, let kind = Self.commandsOfLaterTrackers.firstIndex(of: pattern[at]) { commands.note(kind) }
                    if at + 1 < pattern.count, !madeByScreamTracker, pattern[at] == 19, pattern[at + 1] == 0x99 { commands.note(1) }
                    at += 2
                }
            }
        }
        // A sample in stereo is not played as two: see `playStereoSamples`. A packed one is read
        // as if it were not.
        var stereo = 0, packed = 0, drums = 0
        for i in 0 ..< insnum where used[i + 1] {
            let o = insoff[i] << 4
            if ins[i].type == 1, ins[i].length > 0, ins[i].baseptr >= 0 {
                if inStereo.contains(where: { $0.instrument == i }) { stereo += 1 }
                if f[o + 30] != 0 { packed += 1 }
            }
            if ins[i].type >= 3, ins[i].type <= 7 { drums += 1 }
        }
        if stereo > 0 {
            let sentence = Shortfall.some(stereo, one: "samples is in stereo, and is heard with its two sides mixed into one.", many: "samples are in stereo, and are heard with their two sides mixed into one.")
            stereoSentence = sentence
            shortfalls.append(sentence)
        }
        if packed > 0 {
            shortfalls.append(Shortfall.some(packed, one: "samples is packed, which Scream Tracker's never were: it is not heard as it should be.",
                                             many: "samples are packed, which Scream Tracker's never were: they are not heard as they should be."))
        }
        if drums > 0 {
            shortfalls.append(Shortfall.some(drums, one: "instruments is one of the AdLib card's drums, which Scream Tracker never played, and is not heard.",
                                             many: "instruments are the AdLib card's drums, which Scream Tracker never played, and are not heard."))
        }
        if let sentence = Shortfall.commandsLeftOut(commands.named(Self.whatTheyDo), why: "which Scream Tracker did not have") { shortfalls.append(sentence) }
    }

    /// Puts a sample in order: a loop is written out again past its end, 512 samples of it, so that
    /// the mixer need not think about the join; a sample with no loop is trailed away to silence.
    /// - Parameter memory: the samples it is put in order in: `samples`, or the right sides of those in stereo.
    private func checkins(_ i: Int, in memory: UnsafeMutablePointer<Int16>? = nil) {
        guard ins[i].type == 1 else { return }
        guard ins[i].length != 0, ins[i].baseptr >= 0 else {
            ins[i].flags &= 0xFE
            return
        }
        if ins[i].vol > 64 { ins[i].vol = 64 }
        // Scream Tracker has sixteen bits for the rate a sample plays C-4 at. Trackers after it wrote
        // higher ones, and a sample cut down to 65,535 is out of tune with the rest: a third of a
        // semitone flat for one of 66,904. They are kept, but for a rate no file could mean.
        if ins[i].c2spd > (ST3Player.repeatsReferenceSlips ? 65535 : 1 << 20) { ins[i].c2spd = ST3Player.repeatsReferenceSlips ? 65535 : 1 << 20 }
        if ins[i].lend == ins[i].lbeg { ins[i].flags &= 0xFE }
        if ins[i].lend < ins[i].lbeg { ins[i].lend = ins[i].lbeg + 1 }
        if ins[i].lbeg > ins[i].length { ins[i].lbeg = ins[i].length }
        if ins[i].lend > ins[i].length { ins[i].lend = ins[i].length }
        // (A loop that lies past the sample's end is closed up to nothing by those two, and is no loop:
        // Scream Tracker's player, which repeats a short loop until it is long enough, would go round
        // one of no length for ever.)
        if ins[i].lend <= ins[i].lbeg { ins[i].flags &= 0xFE }

        let p = (memory ?? samples) + ins[i].baseptr
        let length = Int(ins[i].length)
        // Scream Tracker kept, in the instrument, where it had last written a loop out again, and
        // saved that with the file; a sample that comes with it set is first closed up again.
        if ins[i].lend512 > 0 {
            for k in Int(ins[i].lend512) ..< max(Int(ins[i].lend512), length) { p[k] = p[k + 512] }
        }
        if ins[i].flags & 1 != 0 {
            let u = Int(ins[i].lend), v = Int(ins[i].lbeg)
            var k = length - 1
            while k >= u {
                p[k + 512] = p[k]
                k -= 1
            }
            for k in 0 ..< 512 { p[u + k] = p[v + k] }
            ins[i].lend512 = UInt16(truncatingIfNeeded: ins[i].lend)
        } else {
            ins[i].lend512 = 0
            var a = Int(p[length - 1])
            for k in 0 ..< 512 {
                p[length + k] = Int16(a)
                if a > 0 {
                    a = max(0, a - 4 * 256)
                } else if a < 0 {
                    a = min(0, a + 4 * 256)
                }
            }
        }
    }
}
