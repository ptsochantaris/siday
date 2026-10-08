// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// An AdLib instrument: what the chip is told for the two operators of a voice.
struct AdLibInstrument: Equatable {
    /// For one operator: how it sounds (tremolo, vibrato, whether it holds, how its pitch is
    /// multiplied), its level, attack and decay, sustain and release, and waveform.
    struct Operator: Equatable {
        var ammulti: UInt8 = 0, ksltl: UInt8 = 0, ardr: UInt8 = 0, slrr: UInt8 = 0, waveform: UInt8 = 0
    }

    var modulator = Operator(), carrier = Operator()
    /// How far the first operator feeds back into itself, and how the two are joined.
    var fbc: UInt8 = 0

    /// From the eleven bytes one is kept in here: the first operator's five and how the two are
    /// joined, and then the second's five.
    fileprivate init(_ bytes: UnsafeBufferPointer<UInt8>, at: Int) {
        modulator = Operator(ammulti: bytes[at], ksltl: bytes[at + 1], ardr: bytes[at + 2], slrr: bytes[at + 3], waveform: bytes[at + 5])
        fbc = bytes[at + 4]
        carrier = Operator(ammulti: bytes[at + 6], ksltl: bytes[at + 7], ardr: bytes[at + 8], slrr: bytes[at + 9], waveform: bytes[at + 10])
    }

    init() {}

    /// From a bank file's record of an instrument: thirteen numbers for each operator as AdLib's
    /// Instrument Maker showed them, and a waveform for each. The numbers are put together as they
    /// are found, a number too big for its place spilling into its neighbour's as it did on a PC.
    fileprivate init(record: ArraySlice<UInt8>) {
        let r = record.startIndex
        func registers(_ o: Int) -> (Operator, UInt8) {
            let v = (0 ..< 13).map { Int(record[r + o + $0]) }
            let made = Operator(ammulti: UInt8(truncatingIfNeeded: v[9] << 7 | v[10] << 6 | v[5] << 5 | v[11] << 4 | v[1]),
                                ksltl: UInt8(truncatingIfNeeded: v[0] << 6 | v[8]),
                                ardr: UInt8(truncatingIfNeeded: v[3] << 4 | v[6]),
                                slrr: UInt8(truncatingIfNeeded: v[4] << 4 | v[7]))
            return (made, UInt8(truncatingIfNeeded: v[2] << 1 | (v[12] ^ 1)))
        }
        (modulator, fbc) = registers(2)
        carrier = registers(15).0
        modulator.waveform = record[r + 28]
        carrier.waveform = record[r + 29]
    }
}

/// A bank of AdLib instruments: a `.BNK` file, the kind that Visual Composer kept its sounds in.
///
/// A ROL file has no sounds of its own. It names its instruments, and whoever plays it is to have
/// a bank with instruments of those names. A name is eight letters at most, and capitals and small
/// letters are the same.
public struct AdLibBank: Sendable {
    private var sounds: [[UInt8]: [UInt8]] = [:]

    /// - Parameter file: the whole `.BNK` file. One that is not a bank makes a bank of nothing.
    public init(_ file: [UInt8]) {
        let bank = ByteReader(file)
        guard file.count >= 28, bank.ascii(at: 2, length: 6) == "ADLIB-" else { return }
        let total = bank.u16le(10), names = bank.u32le(12), records = bank.u32le(16)
        for entry in 0 ..< total {
            let at = names + entry * 12
            guard at + 12 <= file.count else { break }
            // A place in the list that is kept free for an instrument to come.
            guard file[at + 2] != 0 else { continue }
            let name = Self.capitals(file[at + 3 ..< at + 11])
            let record = records + bank.u16le(at) * 30
            guard record + 30 <= file.count, sounds[name] == nil else { continue }
            sounds[name] = Array(file[record ..< record + 30])
        }
    }

    /// How many instruments it has.
    public var count: Int { sounds.count }

    func instrument(named name: [UInt8]) -> AdLibInstrument? {
        sounds[name].map { AdLibInstrument(record: $0[...]) }
    }

    /// A name as it is looked up: up to its end, in capitals.
    static func capitals(_ name: some Sequence<UInt8>) -> [UInt8] {
        name.prefix { $0 != 0 }.prefix(8).map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }
    }
}

/// The instruments that come with the player, for a ROL file that has no bank beside it or names an
/// instrument its bank has not got.
///
/// They are AdLib's own, from the STANDARD.BNK that came with Visual Composer, and those of the
/// banks that grew out of it as people added their own and passed them on. Where banks disagree
/// about a name, AdLib's has it, and after that the most common.
///
/// The table is made by Scripts/pack-bank.swift, and is laid out to be searched where it lies:
///
/// - the number of names, in two bytes, low byte first;
/// - for each name, in order, its eight bytes (in capitals, with noughts after a shorter one) and
///   which sound it has, in two bytes;
/// - the sounds, eleven bytes each: the first operator's four settings, how the two are joined, its
///   waveform, and the second operator's four and its waveform.
enum BuiltInAdLibBank {
    static func instrument(named name: [UInt8]) -> AdLibInstrument? {
        table.withUnsafeBufferPointer { table in
            guard table.count >= 2, !name.isEmpty, name.count <= 8 else { return nil }
            let count = Int(table[0]) | Int(table[1]) << 8
            let names = 2, sounds = names + count * 10
            guard sounds <= table.count else { return nil }

            var low = 0, high = count
            while low < high {
                let middle = (low + high) / 2
                var order = 0
                for index in 0 ..< 8 where order == 0 {
                    order = Int(table[names + middle * 10 + index]) - (index < name.count ? Int(name[index]) : 0)
                }
                if order == 0 {
                    let sound = sounds + (Int(table[names + middle * 10 + 8]) | Int(table[names + middle * 10 + 9]) << 8) * 11
                    return sound + 11 <= table.count ? AdLibInstrument(table, at: sound) : nil
                } else if order < 0 {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            return nil
        }
    }

    /// The table, out of the base64 it is kept in. That is done once, the first time a ROL file is loaded.
    private static let table: [UInt8] = Base64.decode(AdLibBankData.packed)
}
