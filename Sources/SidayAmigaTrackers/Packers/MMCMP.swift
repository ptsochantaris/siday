// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// After the MMCMP decompressor in Teemu Suutari's ancient (BSD 2-Clause; see THIRD-PARTY.md).

import SidayFoundation

/// MMCMP, Music Module Compressor, by Emmanuel Giasson, who signed himself Zirconia: a DOS packer for PC trackers'
/// modules of any kind, which knew a module's samples from the rest of it and packed each sample as
/// the sound it is. Such a file begins "ziRCONia".
///
/// The file is a list of blocks, each to be unpacked into one or more places in the module: as it
/// is, or as bytes or 16-bit values told in as few bits as are needed, the number of bits changing
/// as the sound does, and perhaps by their differences from the value before.
enum MMCMP {
    static func isPacked(_ data: [UInt8]) -> Bool {
        data.count >= 24 && data.starts(with: [0x7A, 0x69, 0x52, 0x43, 0x4F, 0x4E, 0x69, 0x61])
    }

    /// The unpacked data, or why not.
    static func unpack(_ data: [UInt8]) throws(TuneError) -> [UInt8] {
        guard isPacked(data) else { throw .malformed("not an MMCMP file") }
        let file = ByteReader(data)
        guard file.u16le(8) == 14 else { throw .malformed("an MMCMP file of a kind not known") }
        let blocks = file.u16le(12), size = file.u32le(14), list = file.u32le(18)
        guard size > 0, size <= 1 << 28, list + blocks * 4 <= data.count else { throw .malformed("an MMCMP file cut short") }
        var output = [UInt8](repeating: 0, count: size)

        for block in 0 ..< blocks {
            let at = file.u32le(list + block * 4)
            guard at + 20 < data.count else { throw .malformed("an MMCMP file cut short") }
            let unpackedSize = file.u32le(at), packedSize = file.u32le(at + 4)
            let places = file.u16le(at + 12), flags = file.u16le(at + 14)
            let tableSize = file.u16le(at + 16)
            var width = file.u16le(at + 18) + 1
            let table = at + 20 + places * 8
            guard tableSize <= packedSize, table + packedSize <= data.count else { throw .malformed("an MMCMP file cut short") }

            // Where the bits are, read from the lowest of each byte up.
            var next = table + tableSize
            let end = table + packedSize
            var held: UInt32 = 0, heldCount = 0
            func bits(_ count: Int) throws(TuneError) -> Int {
                var value = 0, done = 0
                while done < count {
                    if heldCount == 0 {
                        guard next < end else { throw .malformed("an MMCMP file cut short") }
                        held = UInt32(data[next])
                        next += 1
                        heldCount = 8
                    }
                    let taken = min(count - done, heldCount)
                    value |= Int(held & (1 << UInt32(taken) - 1)) << done
                    held >>= UInt32(taken)
                    heldCount -= taken
                    done += taken
                }
                return value
            }

            // The places the block goes to, one after another.
            var place = 0, target = 0, room = 0
            func put(_ byte: UInt8, mayRunOver: Bool = false) throws(TuneError) {
                while room == 0 {
                    if mayRunOver, place >= places { return }
                    guard place < places else { throw .malformed("an MMCMP file that unpacks to more than it says") }
                    target = file.u32le(at + 20 + place * 8)
                    room = file.u32le(at + 24 + place * 8)
                    guard target + room <= size else { throw .malformed("an MMCMP file that unpacks to more than it says") }
                    place += 1
                }
                room -= 1
                output[target] = byte
                target += 1
            }

            let deltas = flags & 2 != 0, stereo = flags & 0x100 != 0
            if flags & 1 == 0 {
                // As it is.
                for i in table + tableSize ..< end {
                    try put(data[i])
                }
            } else if flags & 4 == 0 {
                // Bytes, each standing for an entry in the block's table. The values at the top of the
                // range a width can hold are not bytes but say how wide the next ones are, unless they
                // say the width it is already, when they are the bytes at the top of the table.
                guard width <= 8 else { throw .malformed("an MMCMP file that does not unpack") }
                let more = [3, 3, 3, 3, 2, 1, 0, 0]
                var last: [UInt8] = [0, 0], side = 0
                var count = 0
                while count < unpackedSize {
                    let extra = more[width - 1]
                    let threshold = (1 << width) - (1 << (3 - extra))
                    var value = try bits(width)
                    if value >= threshold {
                        let wider = (try bits(extra) | (value - threshold) << extra) + 1
                        if wider != width {
                            width = wider
                            continue
                        }
                        value = 0xF8 | (try bits(3))
                        if value == 0xFF, try bits(1) == 1 { break }
                    }
                    guard value < tableSize else { throw .malformed("an MMCMP file that does not unpack") }
                    var byte = data[table + value]
                    if deltas {
                        byte &+= last[side]
                        last[side] = byte
                        if stereo { side ^= 1 }
                    }
                    try put(byte)
                    count += 1
                }
            } else {
                // Sixteen-bit values, each told as it is, folded so that small values either side of
                // nought take few bits.
                guard width <= 16 else { throw .malformed("an MMCMP file that does not unpack") }
                let more = [4, 4, 4, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
                var last: [Int16] = [0, 0], side = 0
                var count = 0
                while count < unpackedSize {
                    let extra = more[width - 1]
                    let threshold = (1 << width) - (1 << (4 - extra))
                    var value = try bits(width)
                    if value >= threshold {
                        let wider = (try bits(extra) | (value - threshold) << extra) + 1
                        if wider != width {
                            width = wider
                            continue
                        }
                        value = 0xFFF0 | (try bits(4))
                        if value == 0xFFFF, try bits(1) == 1 { break }
                    }
                    var sample = value & 1 != 0 ? (-value - 1) >> 1 : value >> 1
                    if deltas {
                        sample += Int(last[side])
                        last[side] = Int16(truncatingIfNeeded: sample)
                        if stereo { side ^= 1 }
                    } else if flags & 0x200 == 0 {
                        sample ^= 0x8000
                    }
                    let low = UInt8(truncatingIfNeeded: sample), high = UInt8(truncatingIfNeeded: sample >> 8)
                    if flags & 0x400 != 0 {
                        try put(high)
                        try put(low, mayRunOver: true)
                    } else {
                        try put(low)
                        try put(high, mayRunOver: true)
                    }
                    count += 2
                }
            }
        }
        return output
    }
}
