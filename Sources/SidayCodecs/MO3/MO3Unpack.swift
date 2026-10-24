// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from libopenmpt (`soundlib/Load_mo3.cpp`), Copyright (c) 2004-2026 OpenMPT Project
// Developers and Contributors, used under the BSD 3-Clause licence (see THIRD-PARTY.md), whose MO3
// unpacking is based on UNMO3 by Laurent Clévy, relicensed to BSD with his permission.

/// Bytes read one at a time through a pointer, for the unpackers, which read a bit at a time and must
/// be quick. A read past the end gives nothing.
struct MO3Source {
    let base: UnsafePointer<UInt8>
    var index: Int
    let end: Int

    @inline(__always)
    mutating func byte() -> UInt8? {
        guard index < end else { return nil }
        index += 1
        return base[index - 1]
    }
}

/// `READ_CTRL_BIT`, the bits of the control stream that MO3's packing of music and samples shares,
/// taken from the most significant down, with a 1 put in below the last of each byte's bits to show
/// when the byte is used up. `next` is false where the C macro breaks out of the loop it is in, when
/// there is no next byte; `carry` is the bit, kept as the C keeps it even then.
struct MO3ControlBits {
    var data: UInt16 = 0
    var carry: Int32 = 0

    @inline(__always)
    mutating func next(_ source: inout MO3Source) -> Bool {
        data <<= 1
        carry = data > 0xFF ? 1 : 0
        data &= 0xFF
        if data == 0 {
            guard let b = source.byte() else { return false }
            data = UInt16(b) << 1 + 1
            carry = data > 0xFF ? 1 : 0
            data &= 0xFF
        }
        return true
    }

    /// `DECODE_CTRL_BITS`: a length, a 1 and then the first of each pair of bits, as long as the
    /// second of the pair is 1. Running out of bytes ends the pairs, and the C carries on after them.
    @inline(__always)
    mutating func length(_ value: inout Int32, _ source: inout MO3Source) {
        value &+= 1
        repeat {
            guard next(&source) else { break }
            value = value &<< 1 &+ carry
            guard next(&source) else { break }
        } while carry != 0
    }
}

enum MO3Unpack {
    /// `MO3FileReaderBuffer`: the music, LZ-packed, unpacked from `start` in `file` until it is
    /// `size` bytes long or the packing breaks off. A broken or short stream gives what was unpacked
    /// before the break, as the reader that libopenmpt reads the music through gives it, and says
    /// that it is not whole; `end` is where in the file the packed data stopped being read, which is
    /// where an MO3 before version 5 keeps its samples.
    static func music(_ file: [UInt8], from start: Int, size: UInt32) -> (music: [UInt8], end: Int, whole: Bool) {
        var out: [UInt8] = []
        // Room is made as the music grows, never for a stated size alone, which may be a lie; at first
        // for the packed bytes at the best ratio found in real files (about twenty to one).
        let available = max(0, file.count - start)
        out.reserveCapacity(Int(min(UInt64(size), UInt64(available) * 32 + 1024)))
        var totalRemain = size
        let end: Int = file.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, start < buffer.count, totalRemain > 0 else { return max(0, min(start, buffer.count)) }
            var source = MO3Source(base: base, index: start, end: buffer.count)
            // The first byte is always as it is.
            out.append(source.byte() ?? 0)
            totalRemain -= 1
            var bits = MO3ControlBits()
            var strLen: Int32 = 0, strOffset: Int32 = 0
            unpacking: while totalRemain > 0 {
                guard bits.next(&source) else { break }
                if bits.carry == 0 {
                    // A 0 is a byte as it is.
                    guard let b = source.byte() else { break }
                    out.append(b)
                    totalRemain -= 1
                    continue
                }
                // A 1 is a copy of earlier bytes: its length, and if that is more than 3 (coded with
                // more than one pair of bits) the top of a new offset back, else the last offset again.
                var lengthAdjust: Int32 = 0
                bits.length(&strLen, &source)
                strLen &-= 3
                if strLen < 0 {
                    strLen &+= 1
                } else {
                    guard let b = source.byte() else { break }
                    strOffset = ~(strLen &<< 8 | Int32(b))
                    strLen = 0
                    if strOffset < -1280 { lengthAdjust += 1 }
                    lengthAdjust += 1
                    if strOffset < -32000 { lengthAdjust += 1 }
                }
                if strOffset >= 0 || -out.count > Int(strOffset) { break }
                // Then two more bits of the length, and if both are 0, a longer length.
                guard bits.next(&source) else { break }
                strLen = strLen &<< 1 &+ bits.carry
                guard bits.next(&source) else { break }
                strLen = strLen &<< 1 &+ bits.carry
                if strLen == 0 {
                    bits.length(&strLen, &source)
                    strLen &+= 2
                }
                strLen &+= lengthAdjust
                if strLen <= 0 || totalRemain < UInt32(strLen) { break }
                // A byte at a time, as the copy may overlap what it makes (offset -1, length 2
                // repeats the last byte twice).
                var from = out.count + Int(strOffset)
                for _ in 0 ..< Int(strLen) {
                    out.append(out[from])
                    from += 1
                }
                totalRemain -= UInt32(strLen)
                strLen = 0
            }
            return source.index
        }
        return (out, end, totalRemain == 0)
    }
}
