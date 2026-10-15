// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// Files packed whole by one of the packers that modules were squeezed with, on the Amiga and on the
/// PC: each says so in its first letters, whatever is inside, and is unpacked before it is read.
enum Packed {
    /// The file as it was before it was packed, or as it is if it was not.
    static func unpacked(_ data: [UInt8]) throws(TuneError) -> [UInt8] {
        var data = data
        // (A packed file might itself have been packed again, though none has been seen so.)
        for _ in 0 ..< 4 {
            if PowerPacker.isPacked(data) {
                guard let unpacked = PowerPacker.unpack(data) else { throw .malformed("a PowerPacker file that does not unpack") }
                data = unpacked
            } else if data.count > 4, data.starts(with: [0x50, 0x58, 0x32, 0x30]) { // "PX20"
                throw .unsupported("a PowerPacker file locked with a password")
            } else if XPK.isPacked(data) {
                data = try XPK.unpack(data)
            } else if MMCMP.isPacked(data) {
                data = try MMCMP.unpack(data)
            } else {
                break
            }
        }
        return data
    }
}
