// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// After the PowerPacker depacker in pt2-clone (Olav Sørensen, BSD 3-Clause; see THIRD-PARTY.md), which
// has it from Heikki Orsila's amigadepack.

/// PowerPacker, the packer Amiga users squeezed everything with, modules among it: such a file begins
/// "PP20".
///
/// Like most packers of its time it is read backwards from its end, a bit at a time, and what it
/// unpacks is written backwards from its end too: runs of bytes as they are, and copies of what has
/// already been unpacked.
enum PowerPacker {
    static func isPacked(_ data: [UInt8]) -> Bool {
        data.count > 12 && data[0] == 0x50 && data[1] == 0x50 && data[2] == 0x32 && data[3] == 0x30
    }

    /// The unpacked data, or nil if `data` is not a whole PowerPacker file.
    static func unpack(_ data: [UInt8]) -> [UInt8]? {
        guard isPacked(data), data.count & 3 == 0 else { return nil }
        // The last four bytes: the unpacked length, and how many bits at the end are padding.
        let end = data.count - 4
        let size = Int(data[end]) << 16 | Int(data[end + 1]) << 8 | Int(data[end + 2])
        guard size > 0 else { return nil }
        var output = [UInt8](repeating: 0, count: size)
        var source = end, target = size
        var buffer: UInt32 = 0, held = 0
        var failed = false

        func bits(_ count: Int) -> Int {
            while held < count {
                // Bytes 4 to 7 say how long the offsets are and are not packed data, but the packer's
                // own unpacker reads one byte into them at the very end, and so does this.
                guard source >= 8 else {
                    failed = true
                    return 0
                }
                source -= 1
                buffer |= UInt32(data[source]) << UInt32(held)
                held += 8
            }
            held -= count
            var value = 0
            for _ in 0 ..< count {
                value = value << 1 | Int(buffer & 1)
                buffer >>= 1
            }
            return value
        }

        _ = bits(Int(data[end + 3]))
        while target > 0, !failed {
            if bits(1) == 0 {
                // Bytes as they are: one, and more for as long as the count says there is more to count.
                var count = 1
                var more: Int
                repeat {
                    more = bits(2)
                    count += more
                } while more == 3 && !failed
                for _ in 0 ..< count {
                    let byte = bits(8)
                    guard target > 0, !failed else { return nil }
                    target -= 1
                    output[target] = UInt8(byte)
                }
                if target == 0 { break }
            }

            // A copy of something already unpacked: how long, and how far ahead it lies.
            let kind = bits(2)
            var offsetBits = Int(data[4 + kind])
            var count = kind + 2
            var offset: Int
            if kind == 3 {
                if bits(1) == 0 { offsetBits = 7 }
                offset = bits(offsetBits)
                var more: Int
                repeat {
                    more = bits(3)
                    count += more
                } while more == 7 && !failed
            } else {
                offset = bits(offsetBits)
            }
            guard !failed, target + offset < size else { return nil }
            for _ in 0 ..< count {
                guard target > 0 else { return nil }
                let byte = output[target + offset]
                target -= 1
                output[target] = byte
            }
        }
        return failed ? nil : output
    }
}
