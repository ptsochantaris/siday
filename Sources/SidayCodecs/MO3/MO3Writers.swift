// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from libopenmpt (`soundlib/Load_s3m.cpp`, `S3MTools.cpp`, `Load_mod.cpp`, `MODTools.cpp`,
// `Load_mtm.cpp`, `Tables.cpp`), Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors,
// used under the BSD 3-Clause licence (see THIRD-PARTY.md).

import SidayFoundation

extension MO3Song {
    // MARK: S3M

    /// `CSoundFile::SaveS3M`: the header, orders and parapointers, the channel panning, the
    /// patterns and then the samples, all on sixteen-byte boundaries; the tracker the MO3 file kept
    /// (VERS), else Scream Tracker 3.20.
    func writeS3M(_ notes: inout [String]) -> [UInt8] {
        let writeChannels = min(32, channels)
        var writeOrders = orders.count
        if writeOrders < 2 { writeOrders = 2 } else if writeOrders % 2 != 0 { writeOrders += 1 }
        writeOrders = min(writeOrders, 256)
        let writeSamples = min(max(samples.count, 1), 99)
        var writePatterns = 0
        for (i, p) in patterns.enumerated() where p != nil { writePatterns = i + 1 }
        writePatterns = min(writePatterns, 100)
        if samples.count > 99 { notes.append("It has more samples than an S3M holds, and those past the 99th are left out.") }

        var w = MO3Writer()
        w.field(name, 28, terminated: true)
        w.u8(0x1A)
        w.u8(0x10)
        w.zeros(2)
        w.u16(UInt16(writeOrders))
        w.u16(UInt16(writeSamples))
        w.u16(UInt16(writePatterns))
        var flags: UInt16 = 0
        if fastVolumeSlides { flags |= 0x40 }
        if amigaLimits { flags |= 0x10 }
        w.u16(flags)
        w.u16(hasVersion ? cwtv : 0x1320)
        w.u16(2)
        w.text("SCRM")
        w.u8(UInt8(min(globalVolume / 4, 64)))
        w.u8(UInt8(min(max(speed, 1), 254)))
        w.u8(UInt8(min(max(tempo, 33), 255)))
        w.u8(UInt8(min(max(samplePreAmp, 16), 127)) | 0x80)
        w.u8(16)
        w.u8(0xFC)
        w.zeros(2 + 4 + 2 + 2)
        let channelTableAt = w.count
        w.zeros(32)
        for i in 0 ..< writeOrders {
            let p = i < orders.count ? orders[i] : Self.stopOrder
            w.u8(p == Self.stopOrder ? 0xFF : p == Self.skipOrder || p > 0xFF ? 0xFE : UInt8(p))
        }
        let sampleHeaderOffset = (w.count + (writeSamples + writePatterns) * 2 + 32 + 15) & ~15
        for s in 0 ..< writeSamples { w.u16(UInt16((sampleHeaderOffset + s * 80) / 16)) }
        let patternPointersAt = w.count
        w.zeros(writePatterns * 2)
        for c in 0 ..< 32 {
            w.u8(c < channels ? UInt8((Int(channelPan[c]) * 15 + 128) / 256) | 0x20 : 0x08)
        }
        while w.count < sampleHeaderOffset { w.u8(0x80) }
        w.zeros(writeSamples * 80)

        // Patterns, 64 rows each.
        var isPCM = [Bool](repeating: false, count: 32), isAdlib = [Bool](repeating: false, count: 32)
        var cut = 0
        for p in 0 ..< writePatterns {
            let pattern = patterns[p]
            if pattern == nil || pattern!.cells.allSatisfy({ $0.isEmpty }) { continue }
            guard w.count <= 0xFFFF0 else {
                notes.append("Its patterns are more than an S3M file has room for, and some are left out.")
                break
            }
            w.put16(UInt16(w.count / 16), at: patternPointersAt + p * 2)
            var buffer: [UInt8] = [0, 0]
            let pat = pattern!
            if pat.rows > 64 { cut += 1 }
            for row in 0 ..< 64 {
                guard row < pat.rows else {
                    buffer.append(0)
                    continue
                }
                var writeBreak = pat.rows < 64 && row + 1 == pat.rows && !rowHasJump(pat, row)
                for chn in 0 ..< writeChannels {
                    let m = pat.cells[row * channels + chn]
                    var info = UInt8(chn)
                    var note = m.note
                    if m.note != 0 || m.instr != 0 {
                        info |= 0x20
                        if m.note >= MO3Note.pcs {
                            note = 0xFE
                        } else if m.note >= 13, m.note <= 108 {
                            let n = m.note - 13
                            note = (n % 12) + ((n / 12) << 4)
                        } else {
                            note = 0xFF
                        }
                        if m.instr > 0, Int(m.instr) <= samples.count {
                            let s = samples[Int(m.instr) - 1]
                            if s.adlib != nil { isAdlib[chn] = true } else if s.hasData { isPCM[chn] = true }
                        }
                    }
                    var vol = min(m.vol, 64)
                    if m.volcmd == MO3VolumeCommand.volume {
                        info |= 0x40
                    } else if m.volcmd == MO3VolumeCommand.panning {
                        info |= 0x40
                        vol |= 0x80
                    } else if m.command == MO3Command.volume {
                        info |= 0x40
                        vol = min(m.param, 64)
                    }
                    var command: UInt8 = 0, param: UInt8 = 0
                    if m.command != MO3Command.none, m.command != MO3Command.volume {
                        (command, param) = s3mSaveConvert(m.command, m.param, toIT: false, extended: false)
                        if command != 0 || param != 0 { info |= 0x80 }
                    }
                    if writeBreak, info & 0x80 == 0 {
                        info |= 0x80
                        command = 0x43 ^ 0x40
                        writeBreak = false
                    }
                    if info & 0xE0 != 0 {
                        buffer.append(info)
                        if info & 0x20 != 0 { buffer.append(note); buffer.append(m.instr) }
                        if info & 0x40 != 0 { buffer.append(vol) }
                        if info & 0x80 != 0 { buffer.append(command); buffer.append(param) }
                    }
                }
                buffer.append(0)
            }
            let length = min(buffer.count, 0xFFFF)
            buffer[0] = UInt8(length & 0xFF)
            buffer[1] = UInt8(length >> 8)
            if buffer.count % 16 != 0 { buffer.append(contentsOf: repeatElement(0, count: 16 - buffer.count % 16)) }
            w.append(buffer)
        }
        if cut > 0 {
            notes.append(Shortfall.some(cut, one: "patterns is longer than the 64 rows of an S3M pattern, and is cut short.",
                                        many: "patterns are longer than the 64 rows of an S3M pattern, and are cut short."))
        }

        // Samples: headers, and the data, unsigned, after the patterns.
        for i in 0 ..< writeSamples {
            var h = MO3Writer()
            let s = i < samples.count ? samples[i] : Sample()
            var dataLength = 0
            if let patch = s.adlib {
                h.u8(2)
                h.field(s.filename, 12)
                h.zeros(3)
                h.append(patch)
            } else if s.hasData {
                h.u8(1)
                h.field(s.filename, 12)
                h.zeros(3)
                h.u32(s.length)
                h.u32(s.loopStart)
                h.u32(s.loopEnd)
                dataLength = Int(s.length)
            } else {
                h.u8(0)
                h.field(s.filename, 12)
                h.zeros(15)
            }
            h.u8(UInt8(min(s.volume / 4, 64)))
            h.u8(0)
            h.u8(0)
            var f: UInt8 = s.loop ? 0x01 : 0
            if s.hasData, s.adlib == nil {
                if s.is16Bit { f |= 0x04 }
                if s.isStereo { f |= 0x02 }
            }
            h.u8(s.adlib == nil && s.hasData ? f : 0)
            h.u32(s.c5Speed != 0 ? s.c5Speed : 8363)
            h.zeros(4 + 2 + 2 + 4)
            h.field(s.name, 28, terminated: true)
            h.text(s.adlib != nil ? "SCRI" : "SCRS")
            if dataLength > 0 {
                let at = w.count
                guard at <= 0xFFF_FFF0 else { break }
                h.bytes[13] = UInt8((at >> 20) & 0xFF)
                h.bytes[14] = UInt8((at >> 4) & 0xFF)
                h.bytes[15] = UInt8((at >> 12) & 0xFF)
                let start = w.count
                s.writeSplit(&w, frames: dataLength)
                // Unsigned.
                if s.is16Bit {
                    var k = start + 1
                    while k < w.count { w.bytes[k] ^= 0x80; k += 2 }
                } else {
                    for k in start ..< w.count { w.bytes[k] ^= 0x80 }
                }
                while (w.count - start) % 16 != 0 { w.u8(0x80) }
            }
            w.bytes.replaceSubrange(sampleHeaderOffset + i * 80 ..< sampleHeaderOffset + i * 80 + 80, with: h.bytes)
        }

        // The channel table: left channels for samples, then right; AdLib channels apart.
        var sampleCh = 0, adlibCh = 0
        for c in 0 ..< 32 {
            var ch: UInt8 = 0xFF
            if c < channels {
                ch = UInt8(sampleCh % 16)
                if isPCM[c] {
                    ch = UInt8(sampleCh % 16)
                    sampleCh += 1
                } else if isAdlib[c] {
                    ch = UInt8(16 + adlibCh % 9)
                    adlibCh += 1
                }
            }
            w.bytes[channelTableAt + c] = ch
        }
        return w.bytes
    }

    /// `CPattern::RowHasJump`: a position jump or pattern break on the row.
    private func rowHasJump(_ pattern: Pattern, _ row: Int) -> Bool {
        for c in 0 ..< channels {
            let m = pattern.cells[row * channels + c]
            if m.command == MO3Command.positionJump || m.command == MO3Command.patternBreak { return true }
        }
        return false
    }

    // MARK: MOD

    /// ProTracker's periods, from C-0 (`ProTrackerPeriodTable`).
    static let proTrackerPeriods: [UInt16] = [
        2 * 1712, 2 * 1616, 2 * 1524, 2 * 1440, 2 * 1356, 2 * 1280, 2 * 1208, 2 * 1140, 2 * 1076, 2 * 1016, 2 * 960, 2 * 906,
        1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960, 907,
        856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
        428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
        214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
        107, 101, 95, 90, 85, 80, 75, 71, 67, 63, 60, 56,
        53, 50, 47, 45, 42, 40, 37, 35, 33, 31, 30, 28,
    ]

    /// A sample as a MOD keeps it: eight bits, one channel. A sample of sixteen bits (an MP3 one,
    /// decoded) is rounded to eight, and the two sides of a stereo one are mixed.
    func eightBitMono(_ s: Sample) -> [Int8] {
        let frames = Int(s.length)
        var out = [Int8](repeating: 0, count: frames)
        let channels = s.isStereo ? 2 : 1
        if let d = s.data16 {
            for k in 0 ..< frames {
                var v = Int(d[k * channels])
                if channels == 2 { v = (v + Int(d[k * 2 + 1]) + 1) >> 1 }
                out[k] = Int8(clamping: (v + 128) >> 8)
            }
        } else if let d = s.data8 {
            for k in 0 ..< frames {
                var v = Int(d[k * channels])
                if channels == 2 { v = (v + Int(d[k * 2 + 1]) + 1) >> 1 }
                out[k] = Int8(clamping: v)
            }
        }
        return out
    }

    /// `CSoundFile::SaveMod`: 31 sample headers, the orders, the channels' tag, the patterns of 64
    /// rows each, and the samples, as eight bits.
    func writeMOD(_ notes: inout [String]) -> [UInt8] {
        var w = MO3Writer()
        w.field(name, 20)
        if samples.count > 31 { notes.append("It has more samples than a MOD holds, and those past the 31st are left out.") }
        if samples.contains(where: { $0.hasData && ($0.is16Bit || $0.isStereo) }) {
            notes.append("Some of its samples are of sixteen bits or in stereo, and are played at eight bits in mono, as a MOD's are.")
        }
        var lengths = [Int](repeating: 0, count: 32)
        for smp in 1 ... 31 {
            let s = smp <= samples.count ? samples[smp - 1] : Sample()
            w.field(s.name, 22)
            var writeLength = s.hasData ? Int(s.length) : 0
            if writeLength % 2 != 0 { writeLength += 1 }
            writeLength = min(writeLength, 0x1FFFE)
            lengths[smp] = writeLength
            w.u16be(UInt16(writeLength / 2))
            let fineTune: UInt8 = s.relativeTone < 0 ? 0x08 : s.relativeTone > 0 ? 0x07 : UInt8(bitPattern: s.fineTune) >> 4
            w.u8(fineTune)
            w.u8(UInt8(min(s.volume / 4, 64)))
            var loopStart: UInt16 = 0, loopLength: UInt16 = 1
            if s.loop, UInt64(s.loopStart) + 2 < UInt64(writeLength) {
                let low = (Int(s.loopStart) & ~1) + 2
                let loopEnd = min(max(Int(clamping: s.loopEnd), low), writeLength) & ~1
                loopStart = UInt16(s.loopStart / 2)
                loopLength = UInt16((loopEnd - (Int(s.loopStart) & ~1)) / 2)
            }
            w.u16be(loopStart)
            w.u16be(loopLength)
        }
        var orderList: [UInt8] = []
        var writePatterns = 0
        var restartAt = 0
        for (i, p) in orders.enumerated() where orderList.count < 128 {
            if i == Int(restart) { restartAt = orderList.count }
            if p < 128 {
                orderList.append(UInt8(p))
                writePatterns = max(writePatterns, Int(p) + 1)
            }
        }
        w.u8(UInt8(orderList.count))
        w.u8(UInt8(restartAt))
        w.append(orderList)
        w.zeros(128 - orderList.count)
        let writeChannels = min(99, channels)
        if writeChannels == 4 {
            w.text(writePatterns <= 64 ? "M.K." : "M!K!")
        } else if writeChannels < 10 {
            w.u8(0x30 + UInt8(writeChannels))
            w.text("CHN")
        } else {
            w.u8(0x30 + UInt8(writeChannels / 10))
            w.u8(0x30 + UInt8(writeChannels % 10))
            w.text("CH")
        }
        var lost = 0
        for (i, p) in patterns.enumerated() where i >= writePatterns && p != nil { lost += 1 }
        if lost > 0 { notes.append(Shortfall.some(lost, one: "patterns is in no order, which a MOD cannot keep, and is left out.",
                                                       many: "patterns are in no order, which a MOD cannot keep, and are left out.")) }
        for p in 0 ..< writePatterns {
            guard p < patterns.count, let pattern = patterns[p] else {
                w.zeros(writeChannels * 64 * 4)
                continue
            }
            for row in 0 ..< 64 {
                guard row < pattern.rows else {
                    w.zeros(writeChannels * 4)
                    continue
                }
                var writeBreak = pattern.rows < 64 && row + 1 == pattern.rows && !rowHasJump(pattern, row)
                for chn in 0 ..< writeChannels {
                    let m = pattern.cells[row * channels + chn]
                    var (command, param) = modSaveCommand(m.command, m.param, toXM: false)
                    if m.volcmd == MO3VolumeCommand.volume, command == 0, param == 0 {
                        command = 0x0C
                        param = min(m.vol, 64)
                    }
                    if writeBreak, command == 0, param == 0 {
                        command = 0x0D
                        writeBreak = false
                    }
                    var period: UInt16 = 0
                    if m.note >= 25, Int(m.note) < Self.proTrackerPeriods.count + 25 { period = Self.proTrackerPeriods[Int(m.note) - 25] }
                    let instr = m.instr > 31 ? 0 : m.instr
                    w.u8(UInt8((period >> 8) & 0x0F) | (instr & 0x10))
                    w.u8(UInt8(period & 0xFF))
                    w.u8(((instr & 0x0F) << 4) | (command & 0x0F))
                    w.u8(param)
                }
            }
        }
        for smp in 1 ... 31 where lengths[smp] > 0 {
            let data = eightBitMono(samples[smp - 1])
            for v in data.prefix(lengths[smp]) { w.u8(UInt8(bitPattern: v)) }
            if data.count < lengths[smp] { w.zeros(lengths[smp] - data.count) }
        }
        return w.bytes
    }

    // MARK: MTM

    /// A MultiTracker file, as `ReadMTM` reads one (OpenMPT has no MTM saver): the header, sample
    /// headers, orders, tracks of 64 rows and the patterns that list them, the message, and the
    /// samples, unsigned.
    func writeMTM(_ notes: inout [String]) -> [UInt8] {
        let numChannels = min(32, channels)
        var tracks: [[UInt8]] = []
        var trackIndex: [[UInt8]: Int] = [:]
        var lastPattern = 0
        for (i, p) in patterns.enumerated() where p != nil { lastPattern = i }
        lastPattern = min(lastPattern, 255)
        var patternTracks: [[UInt16]] = []
        var cut = 0
        for p in 0 ... lastPattern {
            var list = [UInt16](repeating: 0, count: 32)
            if p < patterns.count, let pattern = patterns[p] {
                if pattern.rows > 64 { cut += 1 }
                for chn in 0 ..< numChannels {
                    var track = [UInt8](repeating: 0, count: 192)
                    var any = false
                    for row in 0 ..< min(64, pattern.rows) {
                        let m = pattern.cells[row * channels + chn]
                        let (command, param) = modSaveCommand(m.command, m.param, toXM: false)
                        var note: UInt8 = 0
                        if m.note >= 37, m.note <= 37 + 63 { note = m.note - 37 }
                        let instr = min(m.instr, 63)
                        track[row * 3] = note << 2 | (instr >> 4)
                        track[row * 3 + 1] = (instr & 0x0F) << 4 | (command & 0x0F)
                        track[row * 3 + 2] = param
                        if note != 0 || instr != 0 || command != 0 || param != 0 { any = true }
                    }
                    guard any else { continue }
                    if let at = trackIndex[track] {
                        list[chn] = UInt16(at + 1)
                    } else {
                        tracks.append(track)
                        trackIndex[track] = tracks.count - 1
                        list[chn] = UInt16(tracks.count)
                    }
                }
            }
            patternTracks.append(list)
        }
        if cut > 0 {
            notes.append(Shortfall.some(cut, one: "patterns is longer than the 64 rows of an MTM pattern, and is cut short.",
                                        many: "patterns are longer than the 64 rows of an MTM pattern, and are cut short."))
        }
        // The message, in lines of 40 bytes, the last of each a 0.
        var comment: [UInt8] = []
        for line in message.isEmpty ? [] : message.split(separator: 0x0D, omittingEmptySubsequences: false) {
            comment.append(contentsOf: line.prefix(39))
            comment.append(contentsOf: repeatElement(0, count: 40 - min(line.count, 39)))
        }
        if comment.count > 0xFFFF { comment = Array(comment.prefix(0xFFFF / 40 * 40)) }

        var w = MO3Writer()
        w.text("MTM")
        w.u8(mtmVersion ?? 0x10)
        w.field(name, 20)
        w.u16(UInt16(clamping: tracks.count))
        w.u8(UInt8(lastPattern))
        w.u8(UInt8(max(0, min(orders.count, 128) - 1)))
        w.u16(UInt16(comment.count))
        let numSamples = min(samples.count, 255)
        w.u8(UInt8(numSamples))
        w.u8(0)
        w.u8(64)
        w.u8(UInt8(numChannels))
        for c in 0 ..< 32 {
            w.u8(c < numChannels ? UInt8(min(max((Int(channelPan[c]) - 8) >> 4, 0), 15)) : 0)
        }
        for i in 0 ..< numSamples {
            let s = samples[i]
            w.field(s.name, 22)
            let factor: UInt32 = s.is16Bit ? 2 : 1
            let length = s.hasData ? s.length : 0
            w.u32(length &* factor)
            w.u32(s.loop ? s.loopStart &* factor : 0)
            w.u32(s.loop ? (s.loopEnd &+ 1) &* factor : 0)
            w.i8(s.fineTune)
            w.u8(UInt8(min(s.volume / 4, 64)))
            w.u8(s.is16Bit ? 1 : 0)
        }
        for i in 0 ..< 128 {
            let p = i < orders.count ? orders[i] : 0
            w.u8(p > 0xFF ? 0xFF : UInt8(p))
        }
        for t in tracks { w.append(t) }
        for list in patternTracks { for t in list { w.u16(t) } }
        w.append(comment)
        for i in 0 ..< numSamples where samples[i].hasData {
            let s = samples[i]
            if s.isStereo { notes.append("Some of its samples are in stereo, and are played in mono, as an MTM's are.") }
            if s.is16Bit, let d = s.data16 {
                for k in 0 ..< Int(s.length) {
                    let v = s.isStereo ? (Int(d[2 * k]) + Int(d[2 * k + 1]) + 1) >> 1 : Int(d[k])
                    w.u16(UInt16(bitPattern: Int16(clamping: v)) ^ 0x8000)
                }
            } else if let d = s.data8 {
                for k in 0 ..< Int(s.length) {
                    let v = s.isStereo ? (Int(d[2 * k]) + Int(d[2 * k + 1]) + 1) >> 1 : Int(d[k])
                    w.u8(UInt8(bitPattern: Int8(clamping: v)) ^ 0x80)
                }
            }
        }
        return w.bytes
    }
}
