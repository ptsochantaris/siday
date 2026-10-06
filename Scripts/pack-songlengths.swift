// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Packs the High Voltage SID Collection's Songlengths.md5 into the table that is built into SidayKit:
//
//     swift Scripts/pack-songlengths.swift <path to Songlengths.md5> <HVSC release number>
//
// It writes Sources/SidayKit/SIDFile/SongLengthsData.swift, which is to be committed. Run it from the
// top of the repository when a new release of the collection comes out. Setting SIDAY_SONGLENGTHS to
// the same file and running `swift test` then checks every entry of the table against the file.
//
// The file is five megabytes of text: for each tune a comment with its path, and a line with the MD5
// of the SID file and the length of each of its songs. Packed, it is a table that is searched where it
// lies, with nothing to read in or build when a player starts. BuiltInSongLengths.swift, which reads
// it, describes the layout.

import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3, let release = Int(arguments[2]) else {
    print("usage: swift Scripts/pack-songlengths.swift <path to Songlengths.md5> <HVSC release number>")
    exit(64)
}
guard let text = try? String(contentsOfFile: arguments[1], encoding: .isoLatin1) else {
    print("cannot read \(arguments[1])")
    exit(66)
}

let prefixLength = 6, blockSize = 32

/// "m:ss" or "m:ss.SSS", in milliseconds.
func milliseconds(_ length: Substring) -> Int? {
    let parts = length.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let minutes = Int(parts[0]) else { return nil }
    let seconds = parts[1].split(separator: ".", omittingEmptySubsequences: false)
    guard seconds.count <= 2, let whole = Int(seconds[0]), whole < 60 else { return nil }
    var fraction = 0
    if seconds.count == 2 {
        guard (1 ... 3).contains(seconds[1].count), let digits = Int(seconds[1]) else { return nil }
        fraction = digits * [100, 10, 1][seconds[1].count - 1]
    }
    return (minutes * 60 + whole) * 1000 + fraction
}

var entries: [[UInt8]: [Int]] = [:]
for line in text.split(whereSeparator: \.isNewline) {
    guard !line.hasPrefix(";"), !line.hasPrefix("["), let equals = line.firstIndex(of: "=") else { continue }
    let hex = Array(line[..<equals].utf8)
    guard hex.count == 32 else { fatalError("not an MD5: \(line)") }
    var digest: [UInt8] = []
    for index in stride(from: 0, to: 32, by: 2) {
        guard let byte = UInt8(String(decoding: hex[index ..< index + 2], as: UTF8.self), radix: 16) else { fatalError("not an MD5: \(line)") }
        digest.append(byte)
    }
    let lengths = line[line.index(after: equals)...].split(separator: " ").map { length -> Int in
        guard let value = milliseconds(length) else { fatalError("not a length: \(length) in \(line)") }
        return value
    }
    guard !lengths.isEmpty else { continue }
    if let known = entries[digest], known != lengths { fatalError("two entries for one file: \(line)") }
    entries[digest] = lengths
}

let sorted = entries.sorted { $0.key.lexicographicallyPrecedes($1.key) }
for index in 1 ..< sorted.count where sorted[index].key.prefix(prefixLength) == sorted[index - 1].key.prefix(prefixLength) {
    fatalError("two files share the first \(prefixLength) bytes of their MD5; the table needs longer keys")
}

func varint(_ value: Int, into bytes: inout [UInt8]) {
    var value = value
    while value >= 0x80 {
        bytes.append(UInt8(value & 0x7F) | 0x80)
        value >>= 7
    }
    bytes.append(UInt8(value))
}

func word(_ value: Int, into bytes: inout [UInt8]) {
    for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((value >> shift) & 0xFF)) }
}

var keys: [UInt8] = [], blocks: [UInt8] = [], lengths: [UInt8] = []
for (index, entry) in sorted.enumerated() {
    keys.append(contentsOf: entry.key.prefix(prefixLength))
    if index % blockSize == 0 { word(lengths.count, into: &blocks) }
    varint(entry.value.count, into: &lengths)
    for length in entry.value {
        // Whole seconds, doubled; an odd number has thousandths of a second after it.
        let seconds = length / 1000, thousandths = length % 1000
        varint(seconds << 1 | (thousandths == 0 ? 0 : 1), into: &lengths)
        if thousandths != 0 { varint(thousandths, into: &lengths) }
    }
}
var table: [UInt8] = []
word(sorted.count, into: &table)
table += keys + blocks + lengths

let encoded = Data(table).base64EncodedString()
var lines: [String] = []
var start = encoded.startIndex
while start < encoded.endIndex {
    let end = encoded.index(start, offsetBy: 120, limitedBy: encoded.endIndex) ?? encoded.endIndex
    lines.append(String(encoded[start ..< end]))
    start = end
}

let source = """
// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Written by Scripts/pack-songlengths.swift: do not edit. The lengths are the work of the High Voltage
// SID Collection's team (https://www.hvsc.c64.org), from the Songlengths.md5 of release \(release).

/// The song lengths of the High Voltage SID Collection, packed. See BuiltInSongLengths.swift.
enum SongLengthsData {
    /// The release of the collection the lengths are from.
    static let release = \(release)
    /// How many SID files it has lengths for.
    static let tunes = \(sorted.count)
    /// The table, in base64 with line breaks.
    static let packed: StaticString = \"\"\"
\(lines.joined(separator: "\n"))
\"\"\"
}

"""
let output = "Sources/SidayKit/SIDFile/SongLengthsData.swift"
do {
    try source.write(toFile: output, atomically: true, encoding: .utf8)
} catch {
    print("cannot write \(output): \(error.localizedDescription)")
    exit(73)
}
let songs = sorted.reduce(0) { $0 + $1.value.count }
print("\(sorted.count) tunes, \(songs) songs: a table of \(table.count) bytes, written to \(output)")
