// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// A parsed PSID/RSID file. Layout per HVSC's SID_file_format.txt.
struct SIDFile {
    enum Clock { case unknown, pal, ntsc, both }

    var isRSID = false
    var version = 0
    var loadAddress = 0
    var initAddress = 0
    var playAddress = 0
    var songs = 1
    var startSong = 1
    var speed: UInt32 = 0
    var name = "", author = "", released = ""
    var flags = 0
    var relocStartPage = 0
    var relocPages = 0
    /// The C64 memory image, without the load address.
    var image: [UInt8] = []

    var clock: Clock {
        switch (flags >> 2) & 3 {
        case 1: .pal
        case 2: .ntsc
        case 3: .both
        default: .unknown
        }
    }

    /// Model the tune asks for; "either" and "unknown" fall back to the 6581.
    var model: SIDModel { (flags >> 4) & 3 == 2 ? .mos8580 : .mos6581 }
    var isMUS: Bool { flags & 1 != 0 }
    var needsBASIC: Bool { isRSID && flags & 2 != 0 }
    var playSIDSpecific: Bool { !isRSID && flags & 2 != 0 }

    /// True when the given song (zero-based) is driven by the CIA timer rather than the vertical blank.
    func usesCIA(song: Int) -> Bool {
        let bit: Int
        if version < 2 || playSIDSpecific {
            bit = song % 32
        } else {
            bit = min(song, 31)
        }
        return speed & (1 << UInt32(bit)) != 0
    }

    init(_ data: [UInt8]) throws {
        let r = ByteReader(data)
        let magic = r.ascii(at: 0, length: 4)
        guard magic == "PSID" || magic == "RSID" else { throw TuneError.malformed("not a SID file") }
        isRSID = magic == "RSID"
        version = r.u16be(4)
        let dataOffset = r.u16be(6)
        guard dataOffset >= 0x76, dataOffset < r.count else { throw TuneError.malformed("bad SID header") }
        loadAddress = r.u16be(8)
        initAddress = r.u16be(0x0A)
        playAddress = r.u16be(0x0C)
        songs = max(1, r.u16be(0x0E))
        startSong = min(max(1, r.u16be(0x10)), songs)
        speed = UInt32(truncatingIfNeeded: r.u32be(0x12))
        func text(_ offset: Int) -> String {
            var end = offset
            while end < offset + 32, r[end] != 0 { end += 1 }
            return (TextEncoding.windows1252.decode(r.data[offset ..< min(end, r.count)]) ?? "").trimmed()
        }
        name = text(0x16)
        author = text(0x36)
        released = text(0x56)
        if version >= 2, dataOffset >= 0x7C {
            flags = r.u16be(0x76)
            relocStartPage = Int(r[0x78])
            relocPages = Int(r[0x79])
        }
        var start = dataOffset
        if loadAddress == 0 {
            loadAddress = r.u16le(start)
            start += 2
        }
        guard start < r.count else { throw TuneError.malformed("SID file has no data") }
        image = Array(r.data[start...])
        if initAddress == 0 { initAddress = loadAddress }
    }
}
