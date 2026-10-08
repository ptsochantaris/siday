// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// A CMF file, Creative's music format for the Sound Blaster's FM chip: a handful of instruments
/// and a tune in MIDI, played by the driver that came with the card.
///
/// The tune's clock is the PC's timer, set to so many ticks a second. The timer and the chip took
/// their time from the one crystal, so a tick is a whole number of twenty-fourths of one of the
/// chip's samples, and the two are kept in step here to exactly that.
final class CMFTune: OPLTune {
    private let driver: SBFMDriver
    /// What the PC's timer counts down from for one tick.
    private let period: Int
    /// The part of a sample that ticks are over by, in twenty-fourths.
    private var remainder = 0

    var detail: String { "Sound Blaster FM, " + (driver.usedDrums ? "6 voices and drums" : "9 voices") }

    private init(_ data: [UInt8], instruments: Int, count: Int, music: Int, period: Int, card: OPLCard?) {
        driver = SBFMDriver(data, instruments: instruments, count: count, music: music, card: card)
        self.period = period
    }

    func tick() -> Int? {
        driver.sbfm_tick()
        if driver.g_status == 0 { return nil }
        remainder += period
        let samples = remainder / 24
        remainder %= 24
        return samples
    }

    /// A player for a CMF file.
    static func renderer(_ data: [UInt8]) throws -> OPLRenderer<CMFTune> {
        let file = ByteReader(data)
        guard data.count >= 40, file.ascii(at: 0, length: 4) == "CTMF" else { throw TuneError.malformed("not a CMF file") }
        let version = file.u16le(4)
        guard version == 0x0100 || version == 0x0101 else {
            throw TuneError.unsupported("CMF version \(version >> 8).\(version & 0xFF)")
        }
        let instruments = file.u16le(6), music = file.u16le(8)
        guard music < data.count else { throw TuneError.malformed("CMF with no music") }
        let count = version == 0x0100 ? Int(file[0x24]) : file.u16le(0x24)
        // The timer counts at 1,193,180 Hz, and sixteen bits is all the count it holds.
        let perSecond = file.u16le(0x0C)
        let divisor = perSecond == 0 ? 18643 : (0x1234DC / perSecond) & 0xFFFF
        let period = divisor == 0 ? 65536 : divisor

        var info = TuneInfo(format: "CMF")
        // A file's three texts come before its instruments, where it has them.
        func text(_ at: Int) -> String {
            let place = file.u16le(at)
            return place != 0 && place < instruments ? file.cString(at: place).0 : ""
        }
        info.title = text(0x0E)
        info.author = text(0x10)
        info.comment = text(0x12)

        return OPLRenderer(info: info) { card in
            CMFTune(data, instruments: instruments, count: count, music: music, period: period, card: card)
        }
    }
}
