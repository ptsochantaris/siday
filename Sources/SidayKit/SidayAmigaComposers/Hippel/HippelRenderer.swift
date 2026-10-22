// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

extension HippelFormat {
    /// The kind of tune it is, as siday names it: Jochen Hippel's, or Future Composer's.
    var tuneFormat: String {
        switch self {
        case .futureComposer10, .futureComposer14: "FC"
        default: "HIP"
        }
    }

    /// The kind of file, for the tune's details.
    var detail: String {
        switch self {
        case .futureComposer10: "Future Composer 1.0 to 1.3"
        case .futureComposer14: "Future Composer 1.4"
        case .tfmx: "Jochen Hippel's TFMX"
        case .compressedTFMX: "Jochen Hippel's TFMX, compressed (COSO)"
        case .tfmx7V: "Jochen Hippel's TFMX 7V"
        case .compressedTFMX7V: "Jochen Hippel's TFMX 7V, compressed (COSO)"
        case .mcmd: "MCMD"
        }
    }
}

extension HippelPlayer {
    /// True for a song of compressed TFMX (COSO) whose samples are not in its file: its header says
    /// that there are some, and that they begin where the file ends. Amberstar's songs are kept so, and
    /// the game had one file of samples for all of them (`Companions`), which goes on the end.
    static func keepsSamplesApart(_ data: [UInt8]) -> Bool {
        guard data.count >= 0x20, data.starts(with: [0x43, 0x4F, 0x53, 0x4F]) else { return false } // COSO
        func long(_ at: Int) -> Int { Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3]) }
        let headers = long(0x18), samples = long(0x1C)
        return samples >= data.count && headers < samples
    }
}

/// Jochen Hippel's players and Future Composer, played on Paula by `PaulaTickRenderer`.
extension HippelPlayer: PaulaTickPlayer {
    var lengthClocks: UInt64? {
        guard duration < 1000 * 60 * 59 else { return nil }
        return format.isSevenVoices ? decoder.lengthClocks.seven : decoder.lengthClocks.four
    }

    var sevenVoiceStyle: TFMXSevenVoices.Style? { format.isSevenVoices ? .hippel : nil }
    var sevenVoiceTempo: Int { decoder.sevenVoiceTempo }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: format.tuneFormat)
        info.detail = format.detail
        return info
    }

    /// Jochen Hippel's songs are louder on the Amiga's chip than modules are, by 4.7 dB in the middle of
    /// UnExoticA's 190 that are heard, and are turned down by that (2026-10-18).
    var gain: Float { 0.27 }

    mutating func prepareToBeHeard() {
        loops = true
    }

    func fourVoiceTick(_ timing: inout TFMXTiming) -> Int { timing.fourVoiceTick(rate: rate, timer: nil) }
}
