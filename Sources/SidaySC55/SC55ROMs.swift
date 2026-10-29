// Copyright (C) 2024-2026 J.C. Moyer
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The SC-55's ROMs as jcmoyer's fork of Nuked SC-55 knows them (standard_romsets.cpp: their SHA-256 digests and
// Roland's part numbers), free software under the GNU General Public License, version 2 or any later version
// (see THIRD-PARTY.md).

import SidayFoundation

/// What a ROM file of an SC-55 is, by its size and SHA-256 digest, as jcmoyer's Nuked SC-55 lists them: those
/// of the first Sound Canvas with firmware 1.21, the one siday plays. (The fork lists the dumps of versions 1.00,
/// 1.10, 1.20 and 2.00 too; they are left out, unheard and unchecked here, and firmware 1.21 is the only one
/// whose voices siday knows the parts of.)
public struct SC55ROMFile: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// The H8/532's own ROM, of the firmware versions it goes with.
        case program(versions: [String])
        /// The board's ROM of the rest of the program, of one firmware version.
        case extraProgram(version: String)
        /// One of the three wave ROMs, A, B and C (0, 1, 2), the same in every SC-55.
        case wave(Int)
    }

    public let role: Role
    /// Roland's part number.
    public let part: String
    public let size: Int
    public let sha256: String

    /// What it is, for a listener.
    public var name: String {
        switch role {
        case let .program(versions): "SC-55 program ROM \(part) (firmware " + versions.joined(separator: ", ") + ")"
        case let .extraProgram(version): "SC-55 program ROM \(part) (firmware \(version))"
        case let .wave(n): "SC-55 wave ROM \(["A", "B", "C"][n]) \(part)"
        }
    }

    /// The ROM files of an SC-55 with firmware 1.21.
    public static let known: [SC55ROMFile] = [
        SC55ROMFile(role: .program(versions: ["1.20", "1.21"]), part: "R15199778", size: 32768, sha256: "7e1bacd1d7c62ed66e465ba05597dcd60dfc13fc23de0287fdbce6cf906c6544"),
        SC55ROMFile(role: .extraProgram(version: "1.21"), part: "R15209363", size: 262_144, sha256: "effc6132d68f7e300aaef915ccdd08aba93606c22d23e580daf9ea6617913af1"),
        SC55ROMFile(role: .wave(0), part: "R15209276", size: 1_048_576, sha256: "5655509a531804f97ea2d7ef05b8fec20ebf46216b389a84c44169257a4d2007"),
        SC55ROMFile(role: .wave(1), part: "R15209277", size: 1_048_576, sha256: "c655b159792d999b90df9e4fa782cf56411ba1eaa0bb3ac2bdaf09e1391006b1"),
        SC55ROMFile(role: .wave(2), part: "R15209281", size: 1_048_576, sha256: "334b2d16be3c2362210fdbec1c866ad58badeb0f84fd9bf5d0ac599baf077cc2"),
    ]

    /// The sizes of them all, for a look through many files that reads only those that may be one.
    public static let sizes: Set<Int> = Set(known.map { $0.size })

    /// What a file is, by its content alone: nil for a file that is none of these.
    public static func identify(_ data: [UInt8]) -> SC55ROMFile? { identify(data, in: known) }

    /// The same, in another list (for testing with made-up ROMs).
    static func identify(_ data: [UInt8], in table: [SC55ROMFile]) -> SC55ROMFile? {
        guard table.contains(where: { $0.size == data.count }) else { return nil }
        let digest = SHA256.hex(data)
        return table.first { $0.size == data.count && $0.sha256 == digest }
    }
}

extension SC55ROMSet {
    /// The firmware versions siday plays with: 1.21 (see `SC55ROMFile`).
    public static let versions = ["1.21"]

    /// Finds, among files, a whole SC-55: a program ROM and a board ROM of one firmware version (in the order
    /// of `versions`) and the three wave ROMs. Files that are none of these are passed over.
    /// - Returns: nil if they do not make one.
    public static func assemble(_ files: [[UInt8]]) -> SC55ROMSet? { assemble(files, table: SC55ROMFile.known) }

    static func assemble(_ files: [[UInt8]], table: [SC55ROMFile]) -> SC55ROMSet? {
        var programs: [(versions: [String], data: [UInt8])] = []
        var extras: [String: [UInt8]] = [:]
        var waves: [[UInt8]?] = [nil, nil, nil]
        for data in files {
            guard let file = SC55ROMFile.identify(data, in: table) else { continue }
            switch file.role {
            case let .program(versions): programs.append((versions, data))
            case let .extraProgram(version): extras[version] = data
            case let .wave(n): waves[n] = data
            }
        }
        guard let a = waves[0], let b = waves[1], let c = waves[2] else { return nil }
        for version in versions {
            guard let extra = extras[version], let program = programs.first(where: { $0.versions.contains(version) }) else { continue }
            let set = SC55ROMSet(version: version, program: program.data, extraProgram: extra, waves: [a, b, c])
            // Started once here, so that each tune starts from where this one is.
            let synth = SC55Synth(roms: set)
            synth.start()
            return SC55ROMSet(version: version, program: program.data, extraProgram: extra, waves: [a, b, c],
                              unscrambledWaves: synth.unscrambledWaves, started: synth.state)
        }
        return nil
    }
}
