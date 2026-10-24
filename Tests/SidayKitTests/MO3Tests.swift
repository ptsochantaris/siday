// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayCodecs
@testable import SidayFoundation
import SidayKit
import Testing

// Fast checks of MO3's unpacking. The thorough checks are made outside the package, against libopenmpt
// 0.8.9 (built with its minimp3 and stb_vorbis, -ffp-contract=off, MINIMP3_NO_SIMD): every MO3 file of
// the collection is unpacked, and libopenmpt's reading of the MO3 is set beside its reading of the
// module rebuilt from it, field by field and by their sound. Here small MO3 files are made from nothing,
// of every kind of module and every way of keeping samples but MP3 and Vorbis (whose decoders have tests
// of their own), and their samples held to libopenmpt's numbers for the same files: FNV-1a over the
// sample's bytes as libopenmpt holds them, the channels interleaved.

/// FNV-1a over the bytes, as the scratch tool that took libopenmpt's numbers worked it out.
private func fnv(_ bytes: [UInt8]) -> UInt64 {
    var h: UInt64 = 1_469_598_103_934_665_603
    for b in bytes { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
    return h
}

private func sampleBytes(_ s: MO3Song.Sample) -> [UInt8] {
    if let d = s.data16 { return d.flatMap { [UInt8(truncatingIfNeeded: UInt16(bitPattern: $0)), UInt8(UInt16(bitPattern: $0) >> 8)] } }
    return (s.data8 ?? []).map { UInt8(bitPattern: $0) }
}

private func song(_ data: [UInt8]) throws -> MO3Song {
    var (song, infos, start) = try MO3Song.read(data)
    song.readSamples(data, infos: &infos, from: start)
    return song
}

private func example(_ name: String) -> [UInt8] { MO3Maker.examples().first { $0.0 == name }!.1.bytes() }

/// libopenmpt's numbers for the IT example's seven samples: raw 8 bits, raw 16-bit stereo, deltas of
/// 8 bits, predicted deltas of 16-bit stereo, a duplicate of the first, deltas of 16 bits and
/// predicted deltas of 8 bits.
private let itSamples: [(length: UInt32, hash: UInt64)] = [
    (16, 0x4B22_E49A_3720_7F83), (8, 0x1593_45CB_5AF5_86DA), (40, 0xFBE7_4DD1_BDBC_F7D5), (30, 0x5B80_F836_786E_C930),
    (16, 0x4B22_E49A_3720_7F83), (33, 0xE905_B25E_9D96_8F9B), (50, 0x3B2A_C13B_87AF_C36F),
]

@Test func mo3IsRecognised() {
    #expect(MO3.isOne(example("it")))
    #expect(!MO3.isOne(Array("MO3".utf8)))
    var bad = example("it")
    bad[3] = 6 // no version after 5
    #expect(!MO3.isOne(bad))
    var big = example("it")
    big[7] = 0x20 // 512 MB of music or more
    #expect(!MO3.isOne(big))
    #expect(!MO3.isOne(Array("MO3\u{5}\u{1}\u{0}\u{0}\u{0}".utf8)))
}

@Test func mo3SamplesAreUnpackedAsLibopenmptUnpacksThem() throws {
    for name in ["it", "itv1", "itins"] {
        let s = try song(example(name))
        #expect(s.samples.count == itSamples.count)
        for (i, expected) in itSamples.enumerated() {
            #expect(s.samples[i].length == expected.length, "\(name) sample \(i + 1)")
            #expect(fnv(sampleBytes(s.samples[i])) == expected.hash, "\(name) sample \(i + 1)")
        }
    }
    // Before version 5, with linear slides, a sample's frequency is reckoned from a fine tune.
    #expect(try song(example("itv1")).samples[0].c5Speed == 687_563)
    let xm = try song(example("xm"))
    #expect(fnv(sampleBytes(xm.samples[1])) == 0xE905_B25E_9D96_8F9B && xm.samples[1].fineTune == 16)
    let s3m = try song(example("s3m"))
    #expect(s3m.samples[2].adlib == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12] && s3m.samples[2].length == 4)
    #expect(fnv(sampleBytes(s3m.samples[2])) == 0x3154_46A0_86A2_3133)
}

@Test func mo3IsRebuiltAsItsOwnKindOfModuleAndPlayed() throws {
    let kinds: [(String, TuneFormat)] = [("it", .it), ("itv1", .it), ("itins", .it), ("xm", .xm), ("s3m", .s3m), ("mod", .mod), ("mtm", .mtm)]
    for (name, format) in kinds {
        let module = try MO3.unpacked(example(name))
        #expect(module.format == format, "\(name)")
        #expect(module.version == (name == "itv1" ? 1 : 5))
        let renderer = try TuneLoader.load(module.bytes, format: module.format)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 4096 * 2)
        defer { buffer.deallocate() }
        renderer.render(into: buffer, frames: 4096)
    }
    // The rebuilt IT keeps the samples' bytes as they were unpacked, after its sample headers' pointers.
    let it = try MO3.unpacked(example("it")).bytes
    let pointer = { (at: Int) in Int(it[at]) | Int(it[at + 1]) << 8 | Int(it[at + 2]) << 16 | Int(it[at + 3]) << 24 }
    let ordnum = Int(it[0x20]) | Int(it[0x21]) << 8
    let header = pointer(0xC0 + ordnum + 2 * 4)
    #expect(Array(it[header ..< header + 4]) == Array("IMPS".utf8))
    let data = pointer(header + 0x48)
    // Sample 3: 40 points of 8 bits.
    let unpacked = try song(example("it")).samples[2]
    #expect(Array(it[data ..< data + 40]) == sampleBytes(unpacked))
}

/// The loader plays an MO3 file as the module it was made from, and says that it is an MO3.
@Test func anMO3FileIsLoadedAsTheModuleItWasMadeFrom() throws {
    let renderer = try TuneLoader.load(example("xm"), format: .mo3)
    let module = try TuneLoader.load(try MO3.unpacked(example("xm")).bytes, format: .xm)
    #expect(renderer.info.format == "MO3")
    #expect(renderer.info.detail.hasPrefix("\(module.info.format) packed by MO3 5"))
    #expect(renderer.info.title == module.info.title)
    #expect(renderer.channelCount == module.channelCount)
    var a = [Float](repeating: 0, count: 4096 * 2), b = a
    a.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 4096) }
    b.withUnsafeMutableBufferPointer { module.render(into: $0.baseAddress!, frames: 4096) }
    #expect(a == b)
}

@Test func mo3UnpacksACopyOfEarlierBytes() {
    // "AB", then a copy of two bytes from two back (a 1, the length's pair 1 0, the offset byte 1,
    // and the length's next two bits 0 1), then "C" as it is.
    // Control bits: 0 (B), 1 1 0, 0 1, 0 (C) = 0b0110_0100 with the 1 that ends the byte below.
    let stream: [UInt8] = [0x41, 0b0110_0100, 0x42, 0x01, 0x43]
    let r = MO3Unpack.music(stream, from: 0, size: 5)
    #expect(r.music == Array("ABABC".utf8) && r.whole)
    // Asked for more than the stream holds: what there is, and not whole.
    let short = MO3Unpack.music(stream, from: 0, size: 100)
    #expect(short.music == Array("ABABC".utf8) && !short.whole)
    // A copy from before the start stops the unpacking.
    let before = MO3Unpack.music([0x41, 0b1100_0000, 0x05], from: 0, size: 10)
    #expect(before.music == [0x41] && !before.whole)
}

@Test func mo3SizesThatLieAreBoundedByTheData() throws {
    // A stated music size far beyond what the bytes hold.
    var music = example("itv1")
    music[4] = 0xFF; music[5] = 0xFF; music[6] = 0xFF; music[7] = 0x1F
    #expect(throws: TuneError.self) { try MO3.unpacked(music) }
    // A packed size past the end of the file.
    var packed = example("it")
    packed[8] = 0xFF; packed[9] = 0xFF; packed[10] = 0xFF; packed[11] = 0xFF
    #expect(throws: TuneError.self) { try MO3.unpacked(packed) }
    // A raw sample said to be 4 G points long is as long as its bytes.
    var maker = MO3Maker.examples().first { $0.0 == "it" }!.1
    maker.samples = [MO3Maker.Sample(name: "long", flags: 0, length: 0xFFFF_FFFF, data: MO3Maker.noise(0x50000, seed: 9))]
    let s = try song(maker.bytes())
    #expect(s.samples[0].length == 0x50000)
    // A packed sample is at most four points a byte.
    maker.samples = [MO3Maker.Sample(name: "packed", flags: 0x2000, length: 0xFFFF_FFFF, data: MO3Maker.noise(100, seed: 9))]
    #expect(try song(maker.bytes()).samples[0].length == 400)
    _ = try MO3.unpacked(maker.bytes())
}

@Test func mo3SurvivesDamage() {
    var seed: UInt32 = 12345
    func next() -> Int { seed = seed &* 1_103_515_245 &+ 12345; return Int(seed >> 8) }
    let originals = MO3Maker.examples().map { $0.1.bytes() }
    for round in 0 ..< 300 {
        var data = originals[round % originals.count]
        switch round % 3 {
        case 0: data = Array(data.prefix(next() % data.count))
        case 1: for _ in 0 ..< 1 + next() % 8 { data[next() % data.count] ^= UInt8(truncatingIfNeeded: 1 << (next() % 8)) }
        default: for _ in 0 ..< 1 + next() % 4 { data[8 + next() % (data.count - 8)] = UInt8(truncatingIfNeeded: next()) }
        }
        guard let module = try? MO3.unpacked(data) else { continue }
        if let renderer = try? TuneLoader.load(module.bytes, format: module.format) {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 1024 * 2)
            renderer.render(into: buffer, frames: 1024)
            buffer.deallocate()
        }
    }
}

/// Small MO3 files made from nothing, as Un4seen's encoder lays them out: the music LZ-packed (here as
/// literal bytes only, a 0 control bit before each), then the samples' data.
private struct MO3Maker {
    enum Kind { case it, xm, s3m, mod, mtm }
    struct Sample {
        var name: String
        var flags: UInt16          // MO3Sample flags: 0x01 16-bit, 0x10 loop, 0x400 stereo, 0x2000 delta, 0x4000 prediction, 0x8000 OPL
        var length: UInt32
        var loop: (UInt32, UInt32) = (0, 0)
        var frequency: UInt32 = 8363 // IT/S3M Hz; MOD/XM finetune + 128
        var volume: UInt8 = 64
        var data: [UInt8]           // the stored bytes (raw PCM, packed, or the OPL patch)
        var compressedSize: Int32? = nil // nil: data.count if packed, else 0 (raw); negative: duplicate
        var xmInstrument: UInt8 = 0
    }
    var kind: Kind
    var version: UInt8 = 5
    var channels = 4
    var orders: [UInt8] = [0]
    var rows = 4
    /// Each row's events per channel: (row, channel, [(cmd, value)]).
    var events: [(Int, Int, [(UInt8, UInt8)])] = []
    var instruments = 0
    var samples: [Sample] = []
    var name = "test"

    func bytes() -> [UInt8] {
        var m: [UInt8] = Array(name.utf8) + [0] + [0]
        var h = [UInt8](repeating: 0, count: 422)
        func put16(_ v: Int, _ at: Int) { h[at] = UInt8(v & 0xFF); h[at + 1] = UInt8((v >> 8) & 0xFF) }
        h[0] = UInt8(channels)
        put16(orders.count, 1)
        put16(0, 3)
        put16(1, 5)
        put16(channels, 7)
        put16(instruments, 9)
        put16(samples.count, 11)
        h[13] = 6
        h[14] = 125
        var flags: UInt32 = 0x20000
        switch kind {
        case .it: flags |= 0x0100 | 0x0001 | (instruments > 0 ? 0x0200 : 0)
        case .s3m: flags |= 0x0002
        case .mod: flags |= 0x0080
        case .mtm: flags |= 0x0008
        case .xm: flags |= 0x0001
        }
        h[15] = UInt8(flags & 0xFF); h[16] = UInt8((flags >> 8) & 0xFF); h[17] = UInt8((flags >> 16) & 0xFF)
        h[19] = 128
        h[20] = 128
        for c in 0 ..< 64 { h[22 + c] = 64; h[86 + c] = c % 2 == 0 ? 64 : 192 }
        m += h
        m += orders
        // Track c is channel c's, for the one pattern.
        for c in 0 ..< channels { m += [UInt8(c), 0] }
        m += [UInt8(rows & 0xFF), UInt8(rows >> 8)]
        for c in 0 ..< channels {
            var t: [UInt8] = []
            var row = 0
            for e in events.filter({ $0.1 == c }).sorted(by: { $0.0 < $1.0 }) {
                if e.0 > row { t += [UInt8((e.0 - row) << 4)]; row = e.0 }
                t += [UInt8(1 << 4 | e.2.count)]
                for (cmd, v) in e.2 { t += [cmd, v] }
                row += 1
            }
            t += [0]
            m += [UInt8(t.count & 0xFF), UInt8(t.count >> 8), 0, 0] + t
        }
        for i in 0 ..< instruments {
            m += Array("ins\(i)".utf8) + [0]
            if version >= 5 { m += [0] }
            var ins = [UInt8](repeating: 0, count: 826)
            for n in 0 ..< 120 { ins[4 + n * 4] = UInt8(n); ins[4 + n * 4 + 2] = UInt8(i % max(samples.count, 1)) }
            ins[4 + 480 + 106 * 3 + 4] = 0 // vibrato
            // fade out 256, panning off
            let base = 4 + 480 + 318 + 4
            ins[base] = 0; ins[base + 1] = 1
            ins[base + 7] = 0xFF; ins[base + 8] = 0xFF
            ins[base + 6] = 128
            m += ins
        }
        var dataBlock: [UInt8] = []
        for s in samples {
            m += Array(s.name.utf8) + [0]
            if version >= 5 { m += [0] }
            var sh = [UInt8](repeating: 0, count: 41)
            func p32(_ v: UInt32, _ at: Int) { for k in 0 ..< 4 { sh[at + k] = UInt8((v >> (8 * UInt32(k))) & 0xFF) } }
            p32(s.frequency, 0)
            sh[5] = s.volume
            sh[6] = 0xFF; sh[7] = 0xFF
            p32(s.length, 8)
            p32(s.loop.0, 12)
            p32(s.loop.1, 16)
            sh[20] = UInt8(s.flags & 0xFF); sh[21] = UInt8(s.flags >> 8)
            sh[26] = kind == .xm ? s.xmInstrument : 64
            let packed = s.flags & 0xF000 != 0
            let size = s.compressedSize ?? (packed ? Int32(s.data.count) : 0)
            p32(UInt32(bitPattern: size), 35)
            m += sh
            if size >= 0 { dataBlock += s.data }
        }
        var out: [UInt8] = Array("MO3".utf8) + [version]
        let n = UInt32(m.count)
        out += [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8(n >> 24)]
        // Packed music: the first byte as it is, then a control byte of eight 0 bits before every eight.
        var packed: [UInt8] = [m[0]]
        var i = 1
        while i < m.count {
            packed.append(0)
            for _ in 0 ..< 8 where i < m.count { packed.append(m[i]); i += 1 }
        }
        if version >= 5 {
            let c = UInt32(packed.count)
            out += [UInt8(c & 0xFF), UInt8((c >> 8) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8(c >> 24)]
        }
        return out + packed + dataBlock
    }

    /// Pseudo-random bytes, the same every time.
    static func noise(_ count: Int, seed: UInt32) -> [UInt8] {
        var x = seed
        return (0 ..< count).map { _ in x = x &* 1_664_525 &+ 1_013_904_223; return UInt8(x >> 24) }
    }

    /// The files the tests are made of.
    static func examples() -> [(String, MO3Maker)] {
        let ramp8: [UInt8] = (0 ..< 16).map { UInt8(bitPattern: Int8($0 * 8 - 64)) }
        let stereo16: [UInt8] = (0 ..< 16).flatMap { k -> [UInt8] in let v = UInt16(bitPattern: Int16(k * 1000 - 8000)); return [UInt8(v & 0xFF), UInt8(v >> 8)] }
        let sampleSet: [Sample] = [
            Sample(name: "raw8", flags: 0x10, length: 16, loop: (4, 16), data: ramp8),
            Sample(name: "raw16stereo", flags: 0x401, length: 8, data: stereo16),
            Sample(name: "delta8", flags: 0x2000, length: 40, data: noise(24, seed: 1)),
            Sample(name: "pred16stereo", flags: 0x4401, length: 30, data: noise(40, seed: 2)),
            Sample(name: "dup", flags: 0, length: 16, data: [], compressedSize: -4),
            Sample(name: "delta16", flags: 0x2001, length: 33, data: noise(29, seed: 3)),
            Sample(name: "pred8", flags: 0x4000, length: 50, data: noise(17, seed: 4)),
        ]
        let events: [(Int, Int, [(UInt8, UInt8)])] = [
            (0, 0, [(0x01, 48), (0x02, 0), (0x0F, 40)]),
            (0, 1, [(0x01, 50), (0x02, 1), (0x0A, 0x23)]),
            (1, 2, [(0x01, 52), (0x02, 2), (0x07, 0x44)]),
            (2, 3, [(0x01, 0xFF)]),
            (3, 0, [(0x01, 55), (0x02, 3), (0x10, 0x12)]),
        ]
        var it = MO3Maker(kind: .it)
        it.events = events
        it.samples = sampleSet
        it.events += [(1, 1, [(0x22, 0x0F), (0x2B, 0x80)]), (2, 0, [(0x06, 0x10), (0x22, 0x02)])]
        var itv1 = it
        itv1.version = 1
        var itInstruments = it
        itInstruments.instruments = 3
        var xm = MO3Maker(kind: .xm)
        xm.events = events + [(1, 3, [(0x14, 0x30), (0x1D, 0x03)])]
        xm.instruments = 2
        xm.samples = [Sample(name: "a", flags: 0x10, length: 16, loop: (4, 16), frequency: 128, data: ramp8, xmInstrument: 1),
                      Sample(name: "b", flags: 0x2001, length: 33, frequency: 128 + 16, data: noise(29, seed: 3), xmInstrument: 2)]
        var s3m = MO3Maker(kind: .s3m)
        s3m.events = events
        s3m.samples = [sampleSet[0], sampleSet[2], Sample(name: "opl", flags: 0x8000, length: 1, data: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])]
        var mod = MO3Maker(kind: .mod)
        mod.events = events
        mod.rows = 64
        mod.samples = [Sample(name: "a", flags: 0, length: 16, frequency: 128, data: ramp8), Sample(name: "b", flags: 0x2000, length: 40, frequency: 128, data: noise(24, seed: 1))]
        var mtm = MO3Maker(kind: .mtm)
        mtm.events = [(0, 0, [(0x01, 30), (0x02, 0)]), (1, 1, [(0x01, 40), (0x02, 1), (0x0D, 0x10)])]
        mtm.rows = 64
        mtm.samples = mod.samples
        return [("it", it), ("itv1", itv1), ("itins", itInstruments), ("xm", xm), ("s3m", s3m), ("mod", mod), ("mtm", mtm)]
    }
}
