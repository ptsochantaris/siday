// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The song lengths of the High Voltage SID Collection, as they come with the player: every tune of
/// the release named by `release`, looked up by the contents of the SID file.
///
/// A SID file does not say how long its songs are, and most never end: they go round until they are
/// stopped. The collection's team have timed them all, and publish the times as `Songlengths.md5`.
/// A copy of that file given to the player (`SongLengthDatabase`) is asked first, since it may be
/// newer and can also find a tune by its place in the collection; this is what is left to ask.
///
/// The table is made from that file by Scripts/pack-songlengths.swift, and is laid out to be searched
/// where it lies, so nothing is read in or built when a player starts:
///
/// - the number of tunes, in four bytes, low byte first;
/// - for each tune, the first six bytes of the MD5 of its file, the tunes in the order of those bytes;
/// - for every thirty-second tune, where its lengths begin among the lengths, in four bytes;
/// - for each tune in the same order, the number of its songs and then each song's length. A length is
///   its whole seconds, doubled; if that is odd, the thousandths of a second follow. Each number takes
///   as many bytes as it needs, seven bits to a byte, low bits first, the top bit set on all but the last.
///
/// Six bytes of an MD5 are enough to tell the collection's tunes apart, which is checked when the table
/// is made, and to make it as good as certain that a file from somewhere else is not taken for one.
public enum BuiltInSongLengths {
    private static let keyLength = 6, blockSize = 32

    /// The release of the High Voltage SID Collection the lengths are from.
    public static var release: Int { SongLengthsData.release }

    /// The lengths of a SID file's songs in seconds, in order, if it is a tune of the collection.
    /// - Parameter file: the whole SID file.
    public static func lengths(of file: [UInt8]) -> [Double]? {
        lengths(md5: MD5.hash(file))
    }

    static func lengths(md5: [UInt8]) -> [Double]? {
        table.withUnsafeBufferPointer { table in
            guard table.count >= 4, md5.count >= keyLength else { return nil }
            let count = word(table, 0)
            let keys = 4, blocks = keys + count * keyLength, lengths = blocks + (count + blockSize - 1) / blockSize * 4
            guard lengths <= table.count else { return nil }

            // The tune whose key is this file's, if there is one.
            var low = 0, high = count
            while low < high {
                let middle = (low + high) / 2
                var order = 0
                for index in 0 ..< keyLength where order == 0 {
                    order = Int(table[keys + middle * keyLength + index]) - Int(md5[index])
                }
                if order == 0 {
                    low = middle
                    high = middle
                } else if order < 0 {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            guard low < count, (0 ..< keyLength).allSatisfy({ table[keys + low * keyLength + $0] == md5[$0] }) else { return nil }

            // Its lengths: from the start of its block, past those of the tunes before it.
            var at = lengths + word(table, blocks + low / blockSize * 4)
            func number() -> Int {
                var value = 0, shift = 0
                while at < table.count {
                    let byte = table[at]
                    at += 1
                    value |= Int(byte & 0x7F) << shift
                    if byte < 0x80 { break }
                    shift += 7
                }
                return value
            }
            var found: [Double] = []
            for tune in low / blockSize * blockSize ... low {
                let songs = number()
                for _ in 0 ..< songs {
                    let doubled = number()
                    let thousandths = doubled & 1 == 1 ? number() : 0
                    guard tune == low else { continue }
                    // Minutes, and seconds to the thousandth, put together as `SongLengthDatabase` puts
                    // them together from the text, so that the two agree to the last bit.
                    let seconds = doubled >> 1
                    found.append(Double(seconds / 60) * 60 + Double(seconds % 60 * 1000 + thousandths) / 1000)
                }
            }
            return found.isEmpty ? nil : found
        }
    }

    @inline(__always) private static func word(_ table: UnsafeBufferPointer<UInt8>, _ at: Int) -> Int {
        Int(table[at]) | Int(table[at + 1]) << 8 | Int(table[at + 2]) << 16 | Int(table[at + 3]) << 24
    }

    /// The table, out of the base64 it is kept in. That is done once, the first time a SID tune is loaded.
    private static let table: [UInt8] = Base64.decode(SongLengthsData.packed)
}
