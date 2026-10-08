// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Packs AdLib instrument banks (.BNK files) into the one bank that is built into SidayKit:
//
//     swift Scripts/pack-bank.swift <AdLib's own STANDARD.BNK> <other banks…> [--last <banks…>]
//
// It writes Sources/SidayKit/OPL/AdLibBankData.swift, which is to be committed. Run it from the top
// of the repository.
//
// A ROL file names its instruments and leaves the sounds to a bank beside it, and banks went from
// hand to hand growing as they went, so there are many and they do not all agree. Where they differ
// on a name, this is who wins:
//
// - AdLib's own bank, the first one given, on every name it has;
// - then the sound that the most of the other banks give the name, and where that is a tie, the bank
//   given earlier;
// - then the banks after `--last`, in order, for the names still without a sound. Those are banks
//   made for other things than Visual Composer's tunes, which are worth having for the names alone.
//
// A name is taken in capitals, as players compare them, and one that is not plain text is left out.
// AdLibBank.swift, which reads the table, describes its layout.

import Foundation

var first: [String] = [], last: [String] = []
var afterLast = false
for argument in CommandLine.arguments.dropFirst() {
    if argument == "--last" {
        afterLast = true
    } else if afterLast {
        last.append(argument)
    } else {
        first.append(argument)
    }
}
guard !first.isEmpty else {
    print("usage: swift Scripts/pack-bank.swift <AdLib's own STANDARD.BNK> <other banks…> [--last <banks…>]")
    exit(64)
}

/// The instruments of a bank that are in use, in the bank's order: each one's name, and its sound as
/// the eleven numbers the chip is given for it.
func instruments(of path: String) -> [(name: [UInt8], sound: [UInt8])] {
    guard let file = FileManager.default.contents(atPath: path).map({ [UInt8]($0) }), file.count >= 28,
          Array(file[2 ..< 8]) == Array("ADLIB-".utf8)
    else {
        print("not a bank: \(path)")
        exit(66)
    }
    func word(_ at: Int) -> Int { Int(file[at]) | Int(file[at + 1]) << 8 }
    let total = word(10), names = word(12) | word(14) << 16, sounds = word(16) | word(18) << 16
    var found: [(name: [UInt8], sound: [UInt8])] = []
    for entry in 0 ..< total {
        let at = names + entry * 12
        guard at + 12 <= file.count else { break }
        guard file[at + 2] != 0 else { continue }
        var name = Array(file[at + 3 ..< at + 11].prefix { $0 != 0 })
        guard !name.isEmpty, name.allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { continue }
        name = name.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }
        let record = sounds + word(at) * 30
        guard record + 30 <= file.count else { continue }
        // Thirteen numbers for each operator, as Instrument Maker showed them, and a waveform each.
        func registers(_ o: Int, wave: Int) -> [UInt8] {
            let v = (0 ..< 13).map { Int(file[record + o + $0]) }
            return [
                UInt8(truncatingIfNeeded: v[9] << 7 | v[10] << 6 | v[5] << 5 | v[11] << 4 | v[1]),
                UInt8(truncatingIfNeeded: v[0] << 6 | v[8]),
                UInt8(truncatingIfNeeded: v[3] << 4 | v[6]),
                UInt8(truncatingIfNeeded: v[4] << 4 | v[7]),
                UInt8(truncatingIfNeeded: v[2] << 1 | (v[12] ^ 1)),
                file[record + wave],
            ]
        }
        // The second operator's share in how the two are joined is never used.
        found.append((name, registers(2, wave: 28) + registers(15, wave: 29).enumerated().filter { $0.offset != 4 }.map(\.element)))
    }
    return found
}

var chosen: [[UInt8]: [UInt8]] = [:]
for (name, sound) in instruments(of: first[0]) where chosen[name] == nil { chosen[name] = sound }
let own = chosen.count

// The other banks' votes. Two copies of one bank are one voice.
var votes: [[UInt8]: [(sound: [UInt8], count: Int)]] = [:]
var seen: Set<[[UInt8]]> = []
for path in first.dropFirst() {
    let bank = instruments(of: path)
    guard seen.insert(bank.map { $0.name + $0.sound }).inserted else { continue }
    var inThisBank: Set<[UInt8]> = []
    for (name, sound) in bank where inThisBank.insert(name).inserted {
        if let at = votes[name]?.firstIndex(where: { $0.sound == sound }) {
            votes[name]![at].count += 1
        } else {
            votes[name, default: []].append((sound, 1))
        }
    }
}
for (name, sounds) in votes where chosen[name] == nil {
    // The first of those with the most votes: they are in the order the banks were given.
    chosen[name] = sounds.max { $0.count < $1.count }!.sound
}
let voted = chosen.count - own

for path in last {
    for (name, sound) in instruments(of: path) where chosen[name] == nil { chosen[name] = sound }
}

let names = chosen.keys.sorted { $0.lexicographicallyPrecedes($1) }
var sounds: [[UInt8]] = [], place: [[UInt8]: Int] = [:]
var table: [UInt8] = [UInt8(names.count & 0xFF), UInt8(names.count >> 8)]
for name in names {
    let sound = chosen[name]!
    if place[sound] == nil {
        place[sound] = sounds.count
        sounds.append(sound)
    }
    table += name + [UInt8](repeating: 0, count: 8 - name.count)
    table += [UInt8(place[sound]! & 0xFF), UInt8(place[sound]! >> 8)]
}
guard names.count < 65536, sounds.count < 65536 else { fatalError("too many for the table") }
for sound in sounds { table += sound }

var base64 = ""
let text = Data(table).base64EncodedString()
var index = text.startIndex
while index < text.endIndex {
    let end = text.index(index, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
    base64 += text[index ..< end] + "\n"
    index = end
}

let output = """
// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Written by Scripts/pack-bank.swift: do not edit. The instruments are from AdLib's STANDARD.BNK and
// the banks that grew out of it among the people who wrote and passed on ROL files.

/// AdLib instruments by name, packed. See AdLibBank.swift.
enum AdLibBankData {
    /// How many names it has.
    static let instruments = \(names.count)
    /// The table, in base64 with line breaks.
    static let packed: StaticString = \"\"\"
\(base64)\"\"\"
}

"""
try! output.write(toFile: "Sources/SidayKit/OPL/AdLibBankData.swift", atomically: true, encoding: .utf8)
print("\(names.count) names (\(own) AdLib's own, \(voted) from the other banks, \(names.count - own - voted) from the last), "
    + "\(sounds.count) different sounds, \(table.count) bytes")
