// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ft2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

/// A module as FastTracker 2 holds one: an XM file, or a MOD file of up to 32 channels, which
/// FastTracker reads into the same shape.
final class FT2Module {
    private(set) var song = FT2Song()
    private(set) var title = ""
    /// True for a song whose slides are even in pitch; false for one that slides as the Amiga did.
    private(set) var linearFrqTab = false
    private(set) var patt = [[FT2Note]?](repeating: nil, count: 256)
    private(set) var pattLens = [UInt16](repeating: 64, count: 256)
    /// Instrument 0 stands in for one that is not there.
    private(set) var instr = [FT2Instrument?](repeating: nil, count: 129)
    /// True for a MOD file.
    private(set) var isMOD = false
    private var allocations: [UnsafeMutableRawPointer] = []

    deinit {
        for allocation in allocations { allocation.deallocate() }
    }

    /// A file being read as the reference reads one: reading the last byte is reaching the end, and
    /// nothing more is read after that.
    private struct File {
        let data: [UInt8]
        var at = 0
        var eof = false

        init(_ data: [UInt8]) { self.data = data }

        /// The next bytes, as many as there are of those asked for; the rest are zeros.
        mutating func read(_ count: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: max(0, count))
            guard !eof, count > 0 else { return out }
            let there = min(count, data.count - at)
            for i in 0 ..< there { out[i] = data[at + i] }
            at += there
            if at >= data.count { eof = true }
            return out
        }

        /// Moves on past some bytes, or to the end if there are not so many.
        mutating func skip(_ count: Int) {
            seek(count >= data.count - at ? data.count : at + count)
        }

        mutating func seek(_ to: Int) {
            at = max(0, to)
            eof = false
            if at >= data.count {
                at = data.count
                eof = true
            }
        }
    }

    private func allocateInstr(_ i: Int) -> FT2Instrument {
        if let have = instr[i] { return have }
        let made = FT2Instrument()
        for j in 0 ..< 16 {
            made.samp[j].pan = 128
            made.samp[j].vol = 64
        }
        instr[i] = made
        return made
    }

    /// Memory for a sample, with what the file has of it and silence after.
    private func sampleMemory(_ bytes: [UInt8]) -> UnsafeMutableRawPointer {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes.count + 16, alignment: 8)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: bytes.count + 16)
        bytes.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        allocations.append(memory)
        return memory
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            if byte == 0 { break }
            scalars.append(Unicode.Scalar(byte >= 0x20 && byte < 0x7F ? byte : 0x20))
        }
        return String(scalars).trimmed()
    }

    init(_ data: [UInt8]) throws {
        var f = File(data)
        // The stand-in instrument, which is silent.
        allocateInstr(0).samp[0].vol = 0

        let h = f.read(336)
        guard !f.eof else { throw TuneError.malformed("too short to be a module") }
        let reader = ByteReader(h)
        if Array(h[0 ..< 17]) != Array("Extended Module: ".utf8) {
            f.seek(0)
            try loadMOD(&f)
        } else {
            let ver = reader.u16le(58), headerSize = Int(Int32(truncatingIfNeeded: reader.u32le(60)))
            let antChn = reader.u16le(68), antPtn = reader.u16le(70), antInstrs = reader.u16le(72)
            guard ver >= 0x0102, ver <= 0x0104 else { throw TuneError.unsupported("an XM file of a version FastTracker 2 does not read") }
            // FastTracker itself reads only an even number of channels, and no more than 32. Other
            // trackers write XM files of any number, and those are played the same way.
            guard antChn >= 1, antChn <= Self.mostChannels else { throw TuneError.unsupported("an XM file of \(antChn) channels") }
            guard antPtn <= 256, antInstrs <= 128 else {
                throw TuneError.unsupported("an XM file with more patterns or instruments than FastTracker 2 has room for")
            }
            guard headerSize >= 0, headerSize < data.count - 60 else { throw TuneError.malformed("an XM file with nothing after its header") }
            f.seek(60 + headerSize)

            title = Self.text(h[17 ..< 37])
            song.len = UInt16(reader.u16le(64))
            song.repS = UInt16(reader.u16le(66))
            song.antChn = UInt8(antChn)
            linearFrqTab = reader.u16le(74) & 1 != 0
            for i in 0 ..< 256 { song.songTab[i] = h[80 + i] }
            song.antInstrs = UInt16(antInstrs)
            let defSpeed = reader.u16le(78)
            song.speed = UInt16(defSpeed == 0 ? 125 : defSpeed)
            song.tempo = UInt16(max(1, reader.u16le(76)))
            song.ver = UInt16(ver)

            if ver < 0x0104 {
                // The older layout: every instrument's header, then the patterns, then the samples.
                for i in 1 ..< antInstrs + 1 { try loadInstrHeader(&f, i) }
                try loadPatterns(&f, antPtn)
                for i in 1 ..< antInstrs + 1 { loadInstrSample(&f, i) }
            } else {
                try loadPatterns(&f, antPtn)
                for i in 1 ..< antInstrs + 1 {
                    try loadInstrHeader(&f, i)
                    loadInstrSample(&f, i)
                }
            }
        }
        if song.repS > song.len { song.repS = 0 }
        song.timer = 1
        setPosition(0)
        upDateInstrs()
    }

    private func setPosition(_ pos: Int) {
        song.songPos = Int16(pos)
        if song.len > 0, song.songPos >= Int16(bitPattern: song.len) { song.songPos = Int16(bitPattern: song.len) - 1 }
        song.pattNr = Int16(song.songTab[Int(song.songPos)])
        song.pattLen = Int16(bitPattern: pattLens[Int(song.pattNr)])
        song.pattPos = 0
        if song.pattPos >= song.pattLen { song.pattPos = song.pattLen - 1 }
    }

    private func patternEmpty(_ nr: Int) -> Bool {
        guard let rows = patt[nr] else { return true }
        return !rows.contains { $0.ton != 0 || $0.instr != 0 || $0.vol != 0 || $0.effTyp != 0 || $0.eff != 0 }
    }

    // MARK: XM

    private func loadInstrHeader(_ f: inout File, _ i: Int) throws {
        // An instrument's header says how long it is, and is read for no longer than FastTracker
        // knows it to be.
        let sizeBytes = f.read(4)
        var instrSize = Int(Int32(truncatingIfNeeded: ByteReader(sizeBytes).u32le(0)))
        if instrSize > 263 { instrSize = 263 }
        guard instrSize >= 4 else { throw TuneError.malformed("an XM file with a broken instrument") }
        var ih = [UInt8](repeating: 0, count: 263)
        let rest = f.eof ? [] : f.read(instrSize - 4)
        for k in 0 ..< rest.count { ih[4 + k] = rest[k] }
        let header = ByteReader(ih)

        let antSamp = header.u16le(27)
        guard antSamp <= 16 else { throw TuneError.malformed("an XM file with a broken instrument") }
        guard antSamp > 0 else { return }

        let ins = allocateInstr(i)
        for k in 0 ..< 96 { ins.ta[k] = ih[33 + k] }
        for k in 0 ..< 24 {
            ins.envVP[k] = Int16(truncatingIfNeeded: header.u16le(129 + k * 2))
            ins.envPP[k] = Int16(truncatingIfNeeded: header.u16le(177 + k * 2))
        }
        ins.envVPAnt = ih[225]
        ins.envPPAnt = ih[226]
        ins.envVSust = ih[227]
        ins.envVRepS = ih[228]
        ins.envVRepE = ih[229]
        ins.envPSust = ih[230]
        ins.envPRepS = ih[231]
        ins.envPRepE = ih[232]
        ins.envVTyp = ih[233]
        ins.envPTyp = ih[234]
        ins.vibTyp = ih[235]
        ins.vibSweep = ih[236]
        ins.vibDepth = ih[237]
        ins.vibRate = ih[238]
        ins.fadeOut = UInt16(header.u16le(239))
        ins.mute = ih[247] == 1 ? 1 : 0
        ins.antSamp = Int16(antSamp)

        guard !f.eof, f.at + antSamp * 40 <= f.data.count else { throw TuneError.malformed("an XM file that ends in an instrument") }
        let headers = ByteReader(f.read(antSamp * 40))
        for j in 0 ..< antSamp {
            let at = j * 40
            ins.samp[j].len = Int32(truncatingIfNeeded: headers.u32le(at))
            ins.samp[j].repS = Int32(truncatingIfNeeded: headers.u32le(at + 4))
            ins.samp[j].repL = Int32(truncatingIfNeeded: headers.u32le(at + 8))
            ins.samp[j].vol = headers[at + 12]
            ins.samp[j].fine = Int8(bitPattern: headers[at + 13])
            ins.samp[j].typ = headers[at + 14]
            ins.samp[j].pan = headers[at + 15]
            ins.samp[j].relTon = Int8(bitPattern: headers[at + 16])
        }
    }

    private func checkSampleRepeat(_ s: inout FT2Sample) {
        if s.repS < 0 { s.repS = 0 }
        if s.repL < 0 { s.repL = 0 }
        if s.repS > s.len { s.repS = s.len }
        if s.repS &+ s.repL > s.len { s.repL = s.len - s.repS }
    }

    private func loadInstrSample(_ f: inout File, _ i: Int) {
        guard let ins = instr[i] else { return }
        for j in 0 ..< Int(ins.antSamp) {
            // A file cut a little short keeps its last sample's length, and the end of it is silence.
            // One that speaks of far more than it holds is not believed.
            let left = f.eof ? 0 : f.data.count - f.at
            if Int(ins.samp[j].len) - left > Self.mostMissing { ins.samp[j].len = Int32(left & ~(ins.samp[j].typ & 16 != 0 ? 1 : 0)) }
            if ins.samp[j].len > 0 {
                // A sample is stored as the differences between one value and the next.
                var bytes = f.read(Int(ins.samp[j].len))
                if ins.samp[j].typ & 16 != 0 {
                    var old: UInt16 = 0
                    for k in 0 ..< bytes.count / 2 {
                        old &+= UInt16(bytes[k * 2]) | UInt16(bytes[k * 2 + 1]) << 8
                        bytes[k * 2] = UInt8(old & 0xFF)
                        bytes[k * 2 + 1] = UInt8(old >> 8)
                    }
                } else {
                    var old: UInt8 = 0
                    for k in 0 ..< bytes.count {
                        old &+= bytes[k]
                        bytes[k] = old
                    }
                }
                ins.samp[j].pek = sampleMemory(bytes)
            }
            checkSampleRepeat(&ins.samp[j])
        }
    }

    private func loadPatterns(_ f: inout File, _ antPtn: Int) throws {
        let antChn = Int(song.antChn)
        for i in 0 ..< antPtn {
            let start = ByteReader(f.read(5))
            let patternHeaderSize = Int(Int32(truncatingIfNeeded: start.u32le(0)))
            var pattLen: Int, dataLen: Int
            if song.ver == 0x0102 {
                let rest = ByteReader(f.read(3))
                pattLen = Int(rest[0]) + 1
                dataLen = rest.u16le(1)
                if patternHeaderSize > 8 { f.skip(patternHeaderSize - 8) }
            } else {
                let rest = ByteReader(f.read(4))
                pattLen = rest.u16le(0)
                dataLen = rest.u16le(2)
                if patternHeaderSize > 9 { f.skip(patternHeaderSize - 9) }
            }
            guard !f.eof else { throw TuneError.malformed("an XM file that ends in its patterns") }

            pattLens[i] = UInt16(pattLen)
            if dataLen > 0 {
                // Packed: a byte with its top bit set says which of a note's five bytes follow.
                //
                // FastTracker unpacks a pattern where it lies: the packed bytes are read into the end
                // of the pattern's memory and unpacked from its start. Where a pattern hardly packs
                // at all, the unpacked notes catch up with the packed ones and write over what has
                // not been read yet, and the last notes of the pattern come out as something else.
                // Files have gone out into the world like that, so it is done the same way here.
                let size = pattLen * antChn * 5
                let base = max(0, dataLen - size)
                var memory = [UInt8](repeating: 0, count: base + size)
                let packed = f.read(dataLen)
                var src = base + size - dataLen
                for k in 0 ..< dataLen { memory[src + k] = packed[k] }
                var dst = base
                func next() -> UInt8 {
                    defer { src += 1 }
                    return src < memory.count ? memory[src] : 0
                }
                func put(_ byte: UInt8) {
                    memory[dst] = byte
                    dst += 1
                }
                for _ in 0 ..< pattLen * antChn {
                    let first = next()
                    if first & 0x80 != 0 {
                        put(first & 0x01 != 0 ? next() : 0)
                        put(first & 0x02 != 0 ? next() : 0)
                        put(first & 0x04 != 0 ? next() : 0)
                        put(first & 0x08 != 0 ? next() : 0)
                        put(first & 0x10 != 0 ? next() : 0)
                    } else {
                        put(first)
                        put(next())
                        put(next())
                        put(next())
                        put(next())
                    }
                    if memory[dst - 5] > 97 { memory[dst - 5] = 0 }
                }
                var notes = [FT2Note](repeating: FT2Note(), count: pattLen * antChn)
                for n in 0 ..< notes.count {
                    let at = base + n * 5
                    notes[n] = FT2Note(ton: memory[at], instr: memory[at + 1], vol: memory[at + 2], effTyp: memory[at + 3], eff: memory[at + 4])
                }
                patt[i] = notes
            }
            if patternEmpty(i) {
                patt[i] = nil
                pattLens[i] = 64
            }
        }
    }

    /// Puts each sample in order for the mixer, which reads one sample past where it is playing: what
    /// it finds there is the start of the loop, or the sample before, or nothing.
    private func upDateInstrs() {
        for ins in instr {
            guard let ins else { continue }
            for j in 0 ..< 16 {
                checkSampleRepeat(&ins.samp[j])
                let s = ins.samp[j]
                guard let pek = s.pek else {
                    ins.samp[j].len = 0
                    ins.samp[j].repS = 0
                    ins.samp[j].repL = 0
                    continue
                }
                let sixteen = s.typ & 16 != 0
                var len = Int(s.len), loopStart = Int(s.repS), loopEnd = Int(s.repS) + Int(s.repL)
                if sixteen {
                    len >>= 1
                    loopStart >>= 1
                    loopEnd >>= 1
                }
                guard len >= 1 else { continue }
                // Asked in this order, which matters where a sample says it loops both ways at once.
                if sixteen {
                    let p = pek.assumingMemoryBound(to: Int16.self)
                    if s.typ & 1 != 0 {
                        p[loopEnd] = p[loopStart]
                    } else if s.typ & 2 != 0 {
                        p[loopEnd] = loopEnd > 0 ? p[loopEnd - 1] : 0
                    } else {
                        p[len] = 0
                    }
                } else {
                    let p = pek.assumingMemoryBound(to: Int8.self)
                    if s.typ & 1 != 0 {
                        p[loopEnd] = p[loopStart]
                    } else if s.typ & 2 != 0 {
                        p[loopEnd] = loopEnd > 0 ? p[loopEnd - 1] : 0
                    } else {
                        p[len] = 0
                    }
                }
            }
        }
    }

    // MARK: MOD

    /// How much of a sample may be missing from the end of a file and the sample still be taken at its word.
    private static let mostMissing = 1 << 20
    /// The most channels a module may have. FastTracker stops at 32; files from later trackers go on.
    static let mostChannels = 128

    private func loadMOD(_ f: inout File) throws {
        let ha = f.read(1084)
        guard !f.eof else { throw TuneError.malformed("too short to be a module") }
        let header = ByteReader(ha)
        let signature = Self.text(ha[1080 ..< 1084])
        // The four letters say how many channels: "6CHN", "12CH". FastTracker knows the even numbers
        // up to 32 and the Amiga's own; the odd ones and two from the Atari ST are taken the same way.
        var channels = 0
        let tag = Array(ha[1080 ..< 1084])
        func digit(_ byte: UInt8) -> Int? { byte >= 0x30 && byte <= 0x39 ? Int(byte) - 0x30 : nil }
        func isTag(_ text: StaticString) -> Bool { text.withUTF8Buffer { $0[0] == tag[0] && $0[1] == tag[1] && $0[2] == tag[2] && $0[3] == tag[3] } }
        if let n = digit(tag[0]), tag[1] == 0x43, tag[2] == 0x48, tag[3] == 0x4E {
            channels = n
        } else if let tens = digit(tag[0]), let ones = digit(tag[1]), tag[2] == 0x43, tag[3] == 0x48 {
            channels = tens * 10 + ones
        } else if isTag("M.K.") || isTag("M!K!") || isTag("FLT4") {
            channels = 4
        } else if isTag("OCTA") || isTag("CD81") || isTag("OKTA") {
            channels = 8
        }
        // FastTracker takes a file it does not know for one of the oldest kind, with 15 samples. Those
        // are ProTracker's to play here, so this asks to know the file.
        guard channels > 0, channels <= Self.mostChannels else {
            throw TuneError.unsupported("a module of a kind this player does not know (\(signature))")
        }

        isMOD = true
        title = Self.text(ha[0 ..< 20])
        song.antChn = UInt8(channels)
        song.len = UInt16(ha[950])
        song.repS = UInt16(ha[951])
        for i in 0 ..< 128 { song.songTab[i] = ha[952 + i] }
        song.antInstrs = 31
        song.tempo = 6
        song.speed = 125

        let last = Int(song.songTab[0 ..< 128].max() ?? 0)
        for a in 0 ... last {
            let bytes = f.read(channels * 4 * 64)
            guard !f.eof else { throw TuneError.malformed("a module that ends in its patterns") }
            var notes = [FT2Note](repeating: FT2Note(), count: channels * 64)
            for i in 0 ..< notes.count {
                let b = (bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3])
                var note = FT2Note()
                let period = UInt16(b.0 & 0x0F) << 8 | UInt16(b.1)
                for k in 0 ..< 96 where period >= ft2AmigaPeriod[k] {
                    note.ton = UInt8(k + 1)
                    break
                }
                note.instr = (b.0 & 0xF0) | (b.2 >> 4)
                note.effTyp = b.2 & 0x0F
                note.eff = b.3
                switch note.effTyp {
                case 0xC: if note.eff > 64 { note.eff = 64 }
                case 0x1, 0x2, 0xA: if note.eff == 0 { note.effTyp = 0 }
                case 0x5: if note.eff == 0 { note.effTyp = 3 }
                case 0x6: if note.eff == 0 { note.effTyp = 4 }
                default: break
                }
                notes[i] = note
            }
            patt[a] = notes
            pattLens[a] = 64
            if patternEmpty(a) { patt[a] = nil }
        }

        for a in 1 ... 31 {
            let at = 20 + (a - 1) * 30
            let len = 2 * header.u16be(at + 22)
            if len == 0 { continue }
            let ins = allocateInstr(a)
            var repS = 2 * header.u16be(at + 26), repL = 2 * header.u16be(at + 28)
            if repL <= 2 {
                repS = 0
                repL = 0
            }
            if repS + repL > len {
                if repS >= len {
                    repS = 0
                    repL = 0
                } else {
                    repL = len - repS
                }
            }
            ins.samp[0].typ = repL > 2 ? 1 : 0
            ins.samp[0].len = Int32(len)
            ins.samp[0].vol = min(64, ha[at + 25])
            ins.samp[0].fine = Int8(truncatingIfNeeded: 8 * ((2 * (Int(ha[at + 24] & 15) ^ 8)) - 16))
            ins.samp[0].repL = Int32(repL)
            ins.samp[0].repS = Int32(repS)
            ins.samp[0].pek = sampleMemory(f.read(len))
        }
    }
}
