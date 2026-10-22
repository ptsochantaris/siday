// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// After the universal C version of the Ice 2.4 depacker that Hans Wessels placed in the public domain
// in 2007.

/// Ice 2.4, the packer most Atari ST music files are squeezed with: such a file begins "ICE!".
///
/// The packed data is read backwards from its end, and the original is written backwards from its
/// end too: runs of bytes as they are, and copies of what has already been unpacked.
enum ICE {
    static func isPacked(_ data: [UInt8]) -> Bool {
        data.count >= 12 && data[0] == 0x49 && data[1] == 0x43 && data[2] == 0x45 && data[3] == 0x21
    }

    /// The unpacked data, or nil if `data` is not a whole Ice 2.4 file.
    static func unpack(_ data: [UInt8]) -> [UInt8]? {
        guard isPacked(data) else { return nil }
        let reader = ByteReader(data)
        let packedSize = reader.u32be(4), size = reader.u32be(8)
        // A sixteenth of a megabyte unpacks to four megabytes at the very most: the size of the machine.
        guard packedSize >= 12, packedSize <= data.count, size > 0, size <= 16 << 20 else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        var source = packedSize, target = size
        var command = 0, mask = 0
        var short = false

        func bits(_ count: Int) -> Int {
            var value = 0
            for _ in 0 ..< count {
                value += value
                mask >>= 1
                if mask == 0 {
                    source -= 1
                    guard source >= 12 else {
                        short = true
                        return 0
                    }
                    command = Int(data[source])
                    mask = 0x80
                }
                if command & mask != 0 { value += 1 }
            }
            return value
        }

        // The last byte holds fewer than eight bits: its lowest set bit marks where they end.
        _ = bits(1)
        mask = 0x80
        while command & 1 == 0, mask > 1 {
            command >>= 1
            mask >>= 1
        }
        command >>= 1

        let literalBits = [1, 2, 2, 3, 8, 15], literalMost = [1, 3, 3, 7, 255, 32768], literalBase = [1, 2, 5, 8, 15, 270]
        let lengthBits = [0, 0, 1, 2, 10], lengthBase = [0, 1, 2, 4, 8]
        let offsetBits = [8, 5, 12], offsetBase = [32, 0, 288]

        while !short {
            if bits(1) != 0 {
                // Bytes as they are.
                var place = 0
                var length = bits(literalBits[0])
                while length == literalMost[place], place < 5 {
                    place += 1
                    length = bits(literalBits[place])
                }
                length = min(length + literalBase[place], target)
                guard source - length >= 12 else { return nil }
                for _ in 0 ..< length {
                    target -= 1
                    source -= 1
                    output[target] = data[source]
                }
                if target <= 0 { return output }
            }
            // And always after them, a copy of something already unpacked.
            var place = 0
            while place < 4, bits(1) != 0 { place += 1 }
            var length = lengthBase[place] + bits(lengthBits[place])
            var offset: Int
            if length != 0 {
                place = 0
                while place < 2, bits(1) != 0 { place += 1 }
                offset = offsetBase[place] + bits(offsetBits[place])
                if offset != 0 { offset += length }
            } else if bits(1) != 0 {
                offset = 64 + bits(9)
            } else {
                offset = bits(6)
            }
            length = min(length + 2, target)
            var from = target + offset + 1
            for _ in 0 ..< length {
                target -= 1
                from -= 1
                // A copy from beyond the end of the data is of nothing.
                output[target] = from < size ? output[from] : 0
            }
            if target <= 0 { return output }
        }
        return nil
    }
}
