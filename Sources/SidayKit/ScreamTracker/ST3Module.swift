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
    /// An instrument that is a sample. (The other kind, a voice of the AdLib card's, is not played.)
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
    /// True if the file has instruments for the AdLib card, which are not played.
    let hasAdLib: Bool

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
        title = f.ascii(at: 0, length: 27)
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
        if ultraclick == 0 { ultraclick = 16 }
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
        var adlib = false, beyond = false
        for i in 0 ..< insnum {
            let o = insoff[i] << 4
            guard o + 0x50 <= data.count else { continue }
            ins[i].type = f[o]
            if ins[i].type >= 2, ins[i].type <= 7 { adlib = true }
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
        hasAdLib = adlib
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
        for i in 0 ..< insnum where ins[i].type == 1 && offsets[i] != 0 {
            let bytesPerSample = ins[i].flags & 4 != 0 ? 2 : 1
            let stated = Int(truncatingIfNeeded: ins[i].length)
            let there = max(0, (data.count - offsets[i]) / bytesPerSample)
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
            let base = ins[i].baseptr, from = offsets[i]
            if ins[i].flags & 4 != 0 {
                for k in 0 ..< Int(ins[i].length) {
                    let value = UInt16(f[from + k * 2]) | UInt16(f[from + k * 2 + 1]) << 8
                    samples[base + k] = Int16(bitPattern: unsigned ? value ^ 0x8000 : value)
                }
            } else {
                for k in 0 ..< Int(ins[i].length) {
                    samples[base + k] = Int16(Int8(bitPattern: unsigned ? f[from + k] ^ 0x80 : f[from + k])) << 8
                }
            }
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

        for i in 0 ..< Self.mostInstruments { checkins(i) }
    }

    /// Puts a sample in order: a loop is written out again past its end, 512 samples of it, so that
    /// the mixer need not think about the join; a sample with no loop is trailed away to silence.
    private func checkins(_ i: Int) {
        guard ins[i].type == 1 else { return }
        guard ins[i].length != 0, ins[i].baseptr >= 0 else {
            ins[i].flags &= 0xFE
            return
        }
        if ins[i].vol > 64 { ins[i].vol = 64 }
        if ins[i].c2spd > 65535 { ins[i].c2spd = 65535 }
        if ins[i].lend == ins[i].lbeg { ins[i].flags &= 0xFE }
        if ins[i].lend < ins[i].lbeg { ins[i].lend = ins[i].lbeg + 1 }
        if ins[i].lbeg > ins[i].length { ins[i].lbeg = ins[i].length }
        if ins[i].lend > ins[i].length { ins[i].lend = ins[i].length }

        let p = samples + ins[i].baseptr
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
