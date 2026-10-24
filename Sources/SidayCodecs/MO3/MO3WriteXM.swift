// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from libopenmpt (`soundlib/Load_xm.cpp`, `XMTools.cpp`), Copyright (c) 2004-2026 OpenMPT
// Project Developers and Contributors, used under the BSD 3-Clause licence (see THIRD-PARTY.md).

import SidayFoundation

extension MO3Song {
    /// How the XM is written as having been made. With the tracker's name that the MO3 file kept
    /// (VERS), as that tracker; else, for a file the MO3 says ModPlug Tracker made, with the signs
    /// ModPlug Tracker's XM files have (FastTracker's name, but the song name ended with a 0 and no
    /// sample name's length kept); else as FastTracker 2 writes its files, which is how most XM files
    /// were made: its name and header size, the song name padded with spaces, each sample's name's
    /// length beside it, and none of what later trackers add after the instruments.
    enum XMMaker { case named, modPlug, fastTracker }

    var xmMaker: XMMaker { hasVersion && !trackerName.isEmpty ? .named : modPlugMode ? .modPlug : .fastTracker }

    /// `CSoundFile::SaveXM`.
    func writeXM(_ notes: inout [String]) -> [UInt8] {
        let maker = xmMaker
        var w = MO3Writer()
        w.text("Extended Module: ")
        if maker == .modPlug {
            w.field(name, 20)
        } else {
            w.field(Self.trimmed(name), 20, pad: 0x20)
        }
        w.u8(0x1A)
        switch maker {
        case .named: w.field(Self.trimmed(trackerName), 20, pad: 0x20)
        case .modPlug, .fastTracker: w.text("FastTracker v2.00   ")
        }
        w.u16(0x0104)

        // Orders, which in an XM are pattern numbers and nothing else.
        var orderList: [UInt8] = []
        var numPatterns = 0
        for (i, p) in patterns.enumerated() where p != nil { numPatterns = i + 1 }
        for p in orders where p != Self.skipOrder && p != Self.stopOrder && p <= 0xFF {
            orderList.append(UInt8(p))
            numPatterns = max(numPatterns, Int(p) + 1)
        }
        // FastTracker 2 keeps 256 orders whatever the song's length; OpenMPT as many as there are.
        let tableSize = maker == .named || orderList.count > 256 ? orderList.count : 256
        w.u32(UInt32(20 + tableSize))
        w.u16(UInt16(clamping: orderList.count))
        w.u16(restart)
        w.u16(UInt16(channels))
        w.u16(UInt16(clamping: numPatterns))
        w.u16(UInt16(instruments.count))
        var flags: UInt16 = 0
        if linearSlides { flags |= 0x01 }
        if extendedFilterRange { flags |= 0x1000 }
        w.u16(flags)
        w.u16(UInt16(min(max(speed, 1), 31)))
        w.u16(UInt16(clamping: tempo))
        w.append(orderList)
        w.zeros(tableSize - orderList.count)

        // Patterns.
        var cutPatterns = 0
        for p in 0 ..< numPatterns {
            guard p < patterns.count, let pattern = patterns[p] else {
                // There's nothing to write: an empty pattern of 64 rows.
                w.append([9, 0, 0, 0, 0, 64, 0, 0, 0])
                continue
            }
            if !writeXMPattern(pattern, &w) { cutPatterns += 1 }
        }
        if cutPatterns > 0 {
            notes.append(Shortfall.some(cutPatterns, one: "patterns has more in it than an XM pattern holds, and is cut short.",
                                        many: "patterns have more in them than an XM pattern holds, and are cut short."))
        }

        // Instruments, each with its own samples.
        let lists = xmSampleLists()
        var lost = 0
        var used = [Bool](repeating: false, count: samples.count)
        for list in lists { for s in list { used[s] = true } }
        for (i, s) in samples.enumerated() where !used[i] && s.hasData { lost += 1 }
        if lost > 0 {
            notes.append(Shortfall.some(lost, one: "samples is in no instrument, which an XM cannot keep, and is left out.",
                                        many: "samples are in no instrument, which an XM cannot keep, and are left out."))
        }
        for (i, ins) in instruments.enumerated() {
            writeXMInstrument(ins, samples: lists[i], &w, maker: maker)
        }

        if maker != .fastTracker || !message.isEmpty || macros != Self.defaultMacros || !plugIns.isEmpty {
            if !message.isEmpty {
                w.text("text")
                w.u32(UInt32(message.count))
                w.append(message)
            }
            if macros != Self.defaultMacros {
                w.text("MIDI")
                w.u32(UInt32(macros.count))
                w.append(macros)
            }
            let named = patternNames.lastIndex(where: { name in name.contains { $0 != 0 } }).map { $0 + 1 } ?? 0
            if named > 0 {
                w.text("PNAM")
                w.u32(UInt32(named * 32))
                for i in 0 ..< named { w.field(patternNames[i], 32) }
            }
            let namedChannels = channelNames.lastIndex(where: { name in name.contains { $0 != 0 } }).map { $0 + 1 } ?? 0
            if namedChannels > 0 {
                w.text("CNAM")
                w.u32(UInt32(namedChannels * 20))
                for i in 0 ..< namedChannels { w.field(channelNames[i], 20) }
            }
            writePlugIns(&w)
            w.append(extensions)
        }
        return w.bytes
    }

    /// A name without the spaces and 0s it was padded with.
    static func trimmed(_ s: [UInt8]) -> [UInt8] {
        var t = s
        if let zero = t.firstIndex(of: 0) { t = Array(t[..<zero]) }
        while t.last == 0x20 { t.removeLast() }
        return t
    }

    /// Which samples each instrument has, by number from 0. The MO3 file says, of each sample of an
    /// XM, which instrument it was in; where that agrees with what the instruments play, those are
    /// the lists, in the samples' order, so that every sample keeps its number. Else as OpenMPT's
    /// saver makes them: the samples an instrument plays, and after each any that no instrument
    /// plays (`XMInstrument::GetSampleList`).
    func xmSampleLists() -> [[Int]] {
        let n = instruments.count
        var lists = [[Int]](repeating: [], count: n)
        for (i, s) in samples.enumerated() where s.xmInstrument >= 1 && Int(s.xmInstrument) <= n {
            lists[Int(s.xmInstrument) - 1].append(i)
        }
        var agrees = lists.allSatisfy { $0.count <= 32 }
        for (i, ins) in instruments.enumerated() where agrees {
            for k in ins.keyboard[12 ..< 108] where k != 0 && Int(k) <= samples.count && !lists[i].contains(Int(k) - 1) {
                agrees = false
                break
            }
        }
        if agrees { return lists }

        var assigned = [Bool](repeating: false, count: samples.count + 1)
        for ins in instruments { for k in ins.keyboard where Int(k) < assigned.count { assigned[Int(k)] = true } }
        lists = []
        for ins in instruments {
            var list: [Int] = []
            for k in ins.keyboard[12 ..< 108] where k != 0 && Int(k) <= samples.count && !list.contains(Int(k) - 1) && list.count < 32 {
                list.append(Int(k) - 1)
            }
            var extra: [Int] = []
            for s in list {
                var next = s + 2
                while next <= samples.count, !assigned[next], list.count + extra.count < 32 {
                    assigned[next] = true
                    extra.append(next - 1)
                    next += 1
                }
            }
            lists.append(list + extra)
        }
        return lists
    }

    /// A pattern packed as XM packs it (and OpenMPT's saver: a pattern of nothing at all, which FT2
    /// would make 64 rows, given a break in its last cell to keep its length).
    private func writeXMPattern(_ pattern: Pattern, _ w: inout MO3Writer) -> Bool {
        var s: [UInt8] = []
        s.reserveCapacity(pattern.rows * channels * 2)
        let empty = pattern.cells.allSatisfy { $0.isEmpty }
        let count = pattern.rows * channels
        for j in 0 ..< count {
            let p = pattern.cells[j]
            var note = p.note
            var (command, param) = modSaveCommand(p.command, p.param, toXM: true)
            if note >= MO3Note.pcs {
                note = 97
            } else if note < 13 || note >= 13 + 96 {
                note = 0
            } else {
                note -= 12
            }
            var vol: UInt8 = 0
            typealias V = MO3VolumeCommand
            switch p.volcmd {
            case V.volume: vol = 0x10 &+ p.vol
            case V.volSlideDown: vol = 0x60 + (p.vol & 0x0F)
            case V.volSlideUp: vol = 0x70 + (p.vol & 0x0F)
            case V.fineVolDown: vol = 0x80 + (p.vol & 0x0F)
            case V.fineVolUp: vol = 0x90 + (p.vol & 0x0F)
            case V.vibratoSpeed: vol = 0xA0 + (p.vol & 0x0F)
            case V.vibratoDepth: vol = 0xB0 + (p.vol & 0x0F)
            case V.panning: vol = min(0xC0 &+ p.vol / 4, 0xCF)
            case V.panSlideLeft: vol = 0xD0 + (p.vol & 0x0F)
            case V.panSlideRight: vol = 0xE0 + (p.vol & 0x0F)
            case V.tonePortamento: vol = 0xF0 + (p.vol & 0x0F)
            default: break
            }
            if j == count - 1, empty, pattern.rows != 64 {
                command = 0x0D
                param = 0
            }
            if note != 0, p.instr != 0, vol > 0x0F, command != 0, param != 0 {
                s.append(contentsOf: [note, p.instr, vol, command, param])
            } else {
                var b: UInt8 = 0x80
                if note != 0 { b |= 0x01 }
                if p.instr != 0 { b |= 0x02 }
                if vol >= 0x10 { b |= 0x04 }
                if command != 0 { b |= 0x08 }
                if param != 0 { b |= 0x10 }
                s.append(b)
                if b & 1 != 0 { s.append(note) }
                if b & 2 != 0 { s.append(p.instr) }
                if b & 4 != 0 { s.append(vol) }
                if b & 8 != 0 { s.append(command) }
                if b & 16 != 0 { s.append(param) }
            }
        }
        if empty, pattern.rows == 64 { s = [] }
        var whole = true
        if s.count > 0xFFFF {
            s = Array(s.prefix(0xFFFF))
            whole = false
        }
        w.append([9, 0, 0, 0, 0, UInt8(pattern.rows & 0xFF), UInt8(pattern.rows >> 8), UInt8(s.count & 0xFF), UInt8(s.count >> 8)])
        w.append(s)
        return whole
    }

    /// `XMInstrumentHeader::ConvertToXM` and `Finalise`, the sample headers and the samples.
    private func writeXMInstrument(_ ins: Instrument, samples list: [Int], _ w: inout MO3Writer, maker: XMMaker) {
        let numSamples = list.count
        let midiEnabled = ins.midiChannel != 0
        var size = 263
        if numSamples == 0, !midiEnabled, maker != .modPlug { size = 263 - 230 }
        let start = w.count
        w.u32(UInt32(size))
        w.field(maker == .modPlug ? ins.name : Self.trimmed(ins.name), 22, pad: maker == .modPlug ? 0 : 0x20)
        w.u8(ins.midiProgram)
        w.u16(UInt16(numSamples))
        w.u32(numSamples > 0 ? 40 : 0)
        // XMInstrument.
        for i in 0 ..< 96 {
            let k = ins.keyboard[i + 12]
            if k > 0, let at = list.firstIndex(of: Int(k) - 1) {
                w.u8(UInt8(at))
            } else {
                // No sample: an empty slot, as the MO3 file has it; OpenMPT's saver makes it the first.
                w.u8(k > 0 ? 0 : UInt8(min(numSamples, 255)))
            }
        }
        func points(_ env: Envelope, maxValue: UInt8) {
            let n = min(12, env.nodes.count)
            for i in 0 ..< 12 {
                if i < n {
                    w.u16(env.nodes[i].tick)
                    w.u16(UInt16(min(env.nodes[i].value, maxValue)))
                } else {
                    w.u32(0)
                }
            }
        }
        points(ins.volumeEnvelope, maxValue: 64)
        points(ins.panEnvelope, maxValue: 63)
        let vol = ins.volumeEnvelope, pan = ins.panEnvelope
        w.u8(UInt8(min(12, vol.nodes.count)))
        w.u8(UInt8(min(12, pan.nodes.count)))
        w.u8(min(12, vol.sustainStart))
        w.u8(min(12, vol.loopStart))
        w.u8(min(12, vol.loopEnd))
        w.u8(min(12, pan.sustainStart))
        w.u8(min(12, pan.loopStart))
        w.u8(min(12, pan.loopEnd))
        func envFlags(_ e: Envelope) -> UInt8 { (e.enabled ? 1 : 0) | (e.sustain ? 2 : 0) | (e.loop ? 4 : 0) }
        w.u8(envFlags(vol))
        w.u8(envFlags(pan))
        // The first sample's auto-vibrato (ApplyAutoVibratoToXM).
        if let first = list.first {
            let s = samples[first]
            w.u8(s.vibratoType)
            w.u8(s.vibratoSweep)
            w.u8(s.vibratoDepth)
            w.u8(s.vibratoRate)
        } else {
            w.u32(0)
        }
        w.u16(UInt16(min(ins.fadeOut, 32767)))
        w.u8(midiEnabled ? 1 : 0)
        w.u8(midiEnabled ? (ins.midiChannel != 17 ? ins.midiChannel - 1 : 0) : 0)
        w.u16(ins.midiProgram != 0 ? UInt16(ins.midiProgram - 1) : 0)
        w.u16(UInt16(bitPattern: Int16(min(ins.midiPitchWheelDepth, 36))))
        w.u8(0)
        w.zeros(15)
        w.bytes.removeLast(w.count - start - size)

        for i in list {
            let s = samples[i]
            let hasData = s.hasData
            var length = hasData ? s.length : 0, loopStart = s.loopStart, loopLength = s.loopEnd &- s.loopStart
            var flags: UInt8 = s.pingPong ? 0x02 : s.loop ? 0x01 : 0
            if s.is16Bit, hasData {
                flags |= 0x10
                length &*= 2; loopStart &*= 2; loopLength &*= 2
            }
            if s.isStereo, hasData {
                flags |= 0x20
                length &*= 2; loopStart &*= 2; loopLength &*= 2
            }
            w.u32(length)
            w.u32(loopStart)
            w.u32(loopLength)
            w.u8(UInt8(min(s.volume / 4, 64)))
            w.i8(s.fineTune)
            w.u8(flags)
            w.u8(UInt8(min(s.pan, 255)))
            w.i8(s.relativeTone)
            // FastTracker 2 keeps the length of the sample's name here.
            let sampleName = Self.trimmed(s.name)
            w.u8(maker == .fastTracker ? UInt8(min(sampleName.count, 22)) : 0)
            w.field(maker == .modPlug ? s.name : sampleName, 22, pad: maker == .modPlug ? 0 : 0x20)
        }
        for i in list where samples[i].hasData {
            samples[i].writeDeltas(&w)
        }
    }
}

extension MO3Song.Sample {
    /// XM's sample data: deltas, the second channel after the first.
    func writeDeltas(_ w: inout MO3Writer) {
        let channels = isStereo ? 2 : 1
        let frames = Int(length)
        for c in 0 ..< channels {
            if let d = data16 {
                var k = c
                var last: Int16 = 0
                for _ in 0 ..< frames {
                    let v = UInt16(bitPattern: d[k] &- last)
                    last = d[k]
                    w.bytes.append(UInt8(truncatingIfNeeded: v))
                    w.bytes.append(UInt8(truncatingIfNeeded: v >> 8))
                    k += channels
                }
            } else if let d = data8 {
                var k = c
                var last: Int8 = 0
                for _ in 0 ..< frames {
                    w.bytes.append(UInt8(bitPattern: d[k] &- last))
                    last = d[k]
                    k += channels
                }
            }
        }
    }
}
