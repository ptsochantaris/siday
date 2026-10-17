// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's telling of Jochen Hippel's and Future Composer's files
// (src/Jochen/Probe.cpp and HippelDecoder.cpp's detect), Copyright (C) Michael Schwendt, used under
// the GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

// Future Composer's files begin with "SMOD" or "FC14". Jochen Hippel's own come in many forms: most
// of the .hip and .sog files are the 68000 player of a game with the music after it, a few are the
// music alone; the compressed ones (COSO) have a header of their own before the TFMX one; and some
// of the files are the player with no music that can be found at all. The music is found by its
// "TFMX" and "COSO" marks, or for a file whose marks cannot be found, by a piece of the player's code.

extension HippelDecoder {
    /// What `probe` finds: which reading of the module to try, and where its header is (or $FFFFFFFF,
    /// for a file told by its player's code alone, which the library then cannot read).
    struct Probe {
        var kind: InitKind
        var format: HippelFormat
        var header: UInt32
    }

    /// The library's `detect`: Future Composer, then compressed TFMX, then TFMX, then MCMD. (What it
    /// reads past the end of the file is taken to be nought.)
    static func probe(_ data: [UInt8]) -> Probe? {
        data.withUnsafeBufferPointer { probe($0) }
    }

    static func probe(_ d: UnsafeBufferPointer<UInt8>) -> Probe? {
        if let p = fcDetect(d) { return p }
        if let p = cosoDetect(d) { return p }
        if let p = tfmxDetect(d) { return p }
        if let p = mcmdDetect(d) { return p }
        return nil
    }

    @inline(__always) static func at(_ d: UnsafeBufferPointer<UInt8>, _ i: Int) -> UInt8 {
        i >= 0 && i < d.count ? d[i] : 0
    }

    static func wordAt(_ d: UnsafeBufferPointer<UInt8>, _ i: Int) -> UInt16 {
        UInt16(at(d, i)) << 8 | UInt16(at(d, i + 1))
    }

    static func has(_ d: UnsafeBufferPointer<UInt8>, _ tag: [UInt8], at i: Int) -> Bool {
        guard i >= 0, i + tag.count <= d.count else { return false }
        for k in 0 ..< tag.count where d[i + k] != tag[k] { return false }
        return true
    }

    /// The first place from `from` where `needle` is whole before `end`, as `std::search` finds it.
    static func search(_ d: UnsafeBufferPointer<UInt8>, from: Int, to end: Int, _ needle: [UInt8]) -> Int? {
        let n = needle.count
        guard from >= 0, n > 0, end - from >= n else { return nil }
        let first = needle[0]
        var i = from
        while i <= end - n {
            if d[i] == first {
                var j = 1
                while j < n, d[i + j] == needle[j] { j += 1 }
                if j == n { return i }
            }
            i += 1
        }
        return nil
    }

    static let smodTag: [UInt8] = Array("SMOD".utf8)
    static let fc14Tag: [UInt8] = Array("FC14".utf8)
    static let tfmxTag: [UInt8] = Array("TFMX".utf8)
    static let cosoTag: [UInt8] = Array("COSO".utf8)
    static let mcmdTag: [UInt8] = Array("MCMD".utf8)
    /// With this much, a 68000 player before the module can be looked past.
    static let probeSize = 0xB80
    static let mcmdProbeSize = 0x8D2

    // MARK: Future Composer

    static func fcDetect(_ d: UnsafeBufferPointer<UInt8>) -> Probe? {
        // The track table's length is a long, but its upper word is always nought, as no module has
        // so many steps.
        if d.count >= 6, !(d[4] == 0 && d[5] == 0) { return nil }
        if d.count >= 5 {
            if has(d, smodTag, at: 0), d[4] == 0 { return Probe(kind: .smod, format: .futureComposer10, header: 0) }
            if has(d, fc14Tag, at: 0), d[4] == 0 { return Probe(kind: .fc14, format: .futureComposer14, header: 0) }
        }
        // (A very few hacked SMOD modules say "FC13", which no version of Future Composer wrote: they
        // are not played, as they are likely to be wrong in other ways too.)
        return nil
    }

    // MARK: Compressed TFMX

    static func cosoDetect(_ d: UnsafeBufferPointer<UInt8>) -> Probe? {
        // "COSO", and "TFMX" at +$20.
        if d.count >= 0x24, has(d, cosoTag, at: 0), has(d, tfmxTag, at: 0x20) {
            return Probe(kind: .coso, format: .compressedTFMX, header: 0)
        }
        if d.count >= probeSize, let h = cosoFindTags(d) {
            return Probe(kind: .coso, format: .compressedTFMX, header: h)
        }
        if cosoFindPlayer(d) {
            // Not the module itself: the library's full reading of the file is left to find it.
            return Probe(kind: .coso, format: .compressedTFMX, header: 0xFFFF_FFFF)
        }
        return nil
    }

    /// A "COSO" with a "TFMX" $20 after it.
    static func cosoFindTags(_ d: UnsafeBufferPointer<UInt8>) -> UInt32? {
        var pos = 0
        while pos < d.count, let h = search(d, from: pos, to: d.count, cosoTag) {
            if h + 0x40 < d.count, has(d, tfmxTag, at: h + 0x20) { return UInt32(h) }
            pos = h + 1
        }
        return nil
    }

    /// The compressed patterns' code of the player: tests for $FE and $FD, each followed by the same
    /// two moves.
    static func cosoFindPlayer(_ d: UnsafeBufferPointer<UInt8>) -> Bool {
        let pattCode: [UInt8] = [0x0C, 0x00, 0x00, 0xFE, 0x66]
        var pos = 0
        while pos < d.count, let o = search(d, from: pos, to: d.count, pattCode) {
            if wordAt(d, o + 6) == 0x1151, wordAt(d, o + 0xA) == 0x1159,
               wordAt(d, o + 0x10) == 0x0C00, wordAt(d, o + 0x12) == 0x00FD,
               wordAt(d, o + 0x16) == 0x1151, wordAt(d, o + 0x1A) == 0x1159,
               wordAt(d, o + 8) == wordAt(d, o + 0x18), wordAt(d, o + 0xC) == wordAt(d, o + 0x1C) {
                return true
            }
            pos = o + pattCode.count
        }
        return false
    }

    // MARK: TFMX

    static func tfmxDetect(_ d: UnsafeBufferPointer<UInt8>) -> Probe? {
        // TFMX with no player before it is rare. Chris Hülsbeck's TFMX begins "TFMX-SONG" or "TFMX ",
        // so "TFMX" and a nought is enough to begin with.
        if d.count >= 5, has(d, tfmxTag, at: 0), d[4] == 0 {
            return Probe(kind: .tfmx, format: .tfmx, header: 0)
        }
        if d.count >= probeSize, let h = tfmxFindTag(d) {
            return Probe(kind: .tfmx, format: .tfmx, header: h)
        }
        if tfmx7VFindPlayer(d) {
            return Probe(kind: .tfmx, format: .tfmx, header: 0xFFFF_FFFF)
        }
        return nil
    }

    /// The first "TFMX", which must be followed by a nought, and not be a compressed module's (with a
    /// "COSO" $20 before it).
    static func tfmxFindTag(_ d: UnsafeBufferPointer<UInt8>) -> UInt32? {
        guard let h = search(d, from: 0, to: d.count, tfmxTag) else { return nil }
        if at(d, h + 4) != 0 { return nil }
        if h >= 0x20, has(d, cosoTag, at: h - 0x20) { return nil }
        return UInt32(h)
    }

    /// The jump on a sequence's command in the player's code, with the instruments' table of jumps
    /// after it, as TFMX's and COSO's players have it (TFMX 7V's sound sequences' table is longer).
    static func tfmx7VFindPlayer(_ d: UnsafeBufferPointer<UInt8>) -> Bool {
        let seqJmp: [UInt8] = [0x04, 0x40, 0x00, 0xE0, 0xD0, 0x40, 0x30, 0x3B, 0x00, 0x06, 0x4E, 0xFB, 0x00]
        var found = false
        var pos = 0
        while pos < d.count, let r = search(d, from: pos, to: d.count, seqJmp) {
            let o = r + seqJmp.count
            if at(d, o) == 0x14, wordAt(d, o + 3) == 0x16, wordAt(d, o + 5) == 0x16, wordAt(d, o + 7) == 0x16,
               wordAt(d, o + 9) == 0x16, wordAt(d, o + 11) == 0x16, wordAt(d, o + 13) == 0x16, wordAt(d, o + 15) == 0x16 {
                found = true
            }
            pos = o + 1
        }
        return found
    }

    // MARK: MCMD

    static func mcmdDetect(_ d: UnsafeBufferPointer<UInt8>) -> Probe? {
        if d.count > 0x12, has(d, mcmdTag, at: 0), d[4] == 0 {
            return Probe(kind: .mcmd, format: .mcmd, header: 0)
        }
        // The MCMD player is $8C0 bytes long.
        if d.count >= mcmdProbeSize, let h = search(d, from: 0, to: d.count, mcmdTag) {
            return Probe(kind: .mcmd, format: .mcmd, header: UInt32(h))
        }
        return nil
    }

    // MARK: In the module

    /// Whether the player before a compressed module does TFMX's portamento, as some do: its code
    /// shifting the portamento's speed by eleven and adding it to the voice's offset.
    func tfmxFindPortamentoCode() -> Bool {
        let portaCode: [UInt8] = [0x76, 0x0B, 0x24, 0x28, 0x00] // MOVEQ #11,D3; MOVE.L ($00??,A0),D2
        let d = UnsafeBufferPointer(start: memory, count: length)
        var pos = 0
        while pos < length, let r = Self.search(d, from: pos, to: length, portaCode) {
            let o = UInt32(r)
            let voiceVar = word(o &+ UInt32(portaCode.count) &- 1)
            if word(o &- 6) == 0x4A01 || word(o &- 4) == 0x4A01, // TST.B D1
               word(o &+ 12) == voiceVar,
               word(o &+ 6) & 0xFFF1 == 0xE7A1, // LSL.L D3,D1 or ASL.L D3,D1
               word(o &+ 8) == 0xD481, // ADD.L D1,D2
               word(o &+ 10) == 0x2142, // MOVE.L D2,$00??(A0)
               word(o &+ 14) == 0x4842 { // SWAP D2
                return true
            }
            // (The library looks again from the same place here, and so for ever: siday looks on
            // from the next byte. No file of UnExoticA's collection has code like this that fails.)
            pos = r + 1
        }
        return false
    }
}
