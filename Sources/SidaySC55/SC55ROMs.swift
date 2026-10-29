// Copyright (C) 2024-2026 J.C. Moyer
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The Sound Canvas's ROMs as jcmoyer's fork of Nuked SC-55 knows them (standard_romsets.cpp: their SHA-256 digests
// and Roland's part numbers), free software under the GNU General Public License, version 2 or any later version
// (see THIRD-PARTY.md).

import SidayFoundation

/// What a ROM file of a Sound Canvas is, by its size and SHA-256 digest, as jcmoyer's Nuked SC-55 lists them:
/// those of the first SC-55 with firmware 1.21, and those of the SC-55mkII with firmware 1.01, the two siday
/// plays. (The fork lists the SC-55's dumps of versions 1.00, 1.10, 1.20 and 2.00 too, and other models'; they
/// are left out, unheard and unchecked here, and these two are the only firmware whose voices siday knows the
/// parts of.)
public struct SC55ROMFile: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// The H8/532's own ROM, of the firmware versions it goes with.
        case program(versions: [String])
        /// The board's ROM of the rest of the program, of one firmware version.
        case extraProgram(version: String)
        /// The SC-55mkII's second processor's program, its M37450's own ROM.
        case subProgram
        /// One of the wave ROMs, the same in every one of the model: on the SC-55, A, B and C (0, 1, 2); on the
        /// SC-55mkII, its 16-megabit one and its 8-megabit one (0, 1).
        case wave(Int)
    }

    public let model: SC55Model
    public let role: Role
    /// Roland's part number.
    public let part: String
    public let size: Int
    public let sha256: String

    public init(model: SC55Model = .sc55, role: Role, part: String, size: Int, sha256: String) {
        self.model = model
        self.role = role
        self.part = part
        self.size = size
        self.sha256 = sha256
    }

    /// What it is, for a listener.
    public var name: String {
        switch role {
        case let .program(versions): model.name + " program ROM \(part) (firmware " + versions.joined(separator: ", ") + ")"
        case let .extraProgram(version): model.name + " program ROM \(part) (firmware \(version))"
        case .subProgram: model.name + " second processor's ROM \(part)"
        case let .wave(n): model.name + " wave ROM \(["A", "B", "C"][n]) \(part)"
        }
    }

    /// The ROM files of an SC-55 with firmware 1.21, and of an SC-55mkII with firmware 1.01.
    public static let known: [SC55ROMFile] = [
        SC55ROMFile(role: .program(versions: ["1.20", "1.21"]), part: "R15199778", size: 32768, sha256: "7e1bacd1d7c62ed66e465ba05597dcd60dfc13fc23de0287fdbce6cf906c6544"),
        SC55ROMFile(role: .extraProgram(version: "1.21"), part: "R15209363", size: 262_144, sha256: "effc6132d68f7e300aaef915ccdd08aba93606c22d23e580daf9ea6617913af1"),
        SC55ROMFile(role: .wave(0), part: "R15209276", size: 1_048_576, sha256: "5655509a531804f97ea2d7ef05b8fec20ebf46216b389a84c44169257a4d2007"),
        SC55ROMFile(role: .wave(1), part: "R15209277", size: 1_048_576, sha256: "c655b159792d999b90df9e4fa782cf56411ba1eaa0bb3ac2bdaf09e1391006b1"),
        SC55ROMFile(role: .wave(2), part: "R15209281", size: 1_048_576, sha256: "334b2d16be3c2362210fdbec1c866ad58badeb0f84fd9bf5d0ac599baf077cc2"),
        SC55ROMFile(model: .sc55mk2, role: .program(versions: ["1.01"]), part: "R15199858", size: 32768, sha256: "8a1eb33c7599b746c0c50283e4349a1bb1773b5c0ec0e9661219bf6c067d2042"),
        SC55ROMFile(model: .sc55mk2, role: .extraProgram(version: "1.01"), part: "R00233567", size: 524_288, sha256: "a4c9fd821059054c7e7681d61f49ce6f42ed2fe407a7ec1ba0dfdc9722582ce0"),
        SC55ROMFile(model: .sc55mk2, role: .subProgram, part: "R15199880", size: 4096, sha256: "b0b5f865a403f7308b4be8d0ed3ba2ed1c22db881b8a8326769dea222f6431d8"),
        SC55ROMFile(model: .sc55mk2, role: .wave(0), part: "R15209359", size: 2_097_152, sha256: "c6429e21b9b3a02fbd68ef0b2053668433bee0bccd537a71841bc70b8874243b"),
        SC55ROMFile(model: .sc55mk2, role: .wave(1), part: "R15279813", size: 1_048_576, sha256: "5b753f6cef4cfc7fcafe1430fecbb94a739b874e55356246a46abe24097ee491"),
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
    /// The firmware versions siday plays with, of each model (see `SC55ROMFile`).
    public static func versions(of model: SC55Model) -> [String] {
        switch model {
        case .sc55: ["1.21"]
        case .sc55mk2: ["1.01"]
        }
    }

    /// The ROMs a model is made of, for a listener.
    public static func wholeSet(of model: SC55Model) -> String {
        switch model {
        case .sc55: "its two program ROMs and its three wave ROMs"
        case .sc55mk2: "its two program ROMs, its second processor's ROM and its two wave ROMs"
        }
    }

    /// Finds, among files, a whole Sound Canvas of a model: a program ROM and a board ROM of one firmware
    /// version (in the order of `versions`), the second processor's ROM if the model has one, and its wave
    /// ROMs. Files that are none of these, or another model's, are passed over.
    /// - Parameter previous: a set put together before, which is given back as it is if these files make the
    ///   same one, so that its synthesiser is not started again.
    /// - Returns: nil if they do not make one.
    public static func assemble(_ files: [[UInt8]], model: SC55Model = .sc55, reusing previous: SC55ROMSet? = nil) -> SC55ROMSet? {
        assemble(files, model: model, table: SC55ROMFile.known, reusing: previous)
    }

    /// Every whole Sound Canvas among files: one of each model whose ROMs are all there.
    /// - Parameter previous: sets put together before, given back as they are where these files make the same.
    public static func assembleAll(_ files: [[UInt8]], reusing previous: [SC55ROMSet] = []) -> [SC55ROMSet] {
        // (Each file's digest worked out once, for both.)
        let identified = identify(files, in: SC55ROMFile.known)
        return SC55Model.allCases.compactMap { model in assemble(identified, model: model, reusing: previous.first { $0.model == model }) }
    }

    static func assemble(_ files: [[UInt8]], model: SC55Model = .sc55, table: [SC55ROMFile], reusing previous: SC55ROMSet? = nil) -> SC55ROMSet? {
        assemble(identify(files, in: table), model: model, reusing: previous)
    }

    private static func identify(_ files: [[UInt8]], in table: [SC55ROMFile]) -> [(file: SC55ROMFile, data: [UInt8])] {
        files.compactMap { data in SC55ROMFile.identify(data, in: table).map { ($0, data) } }
    }

    private static func assemble(_ identified: [(file: SC55ROMFile, data: [UInt8])], model: SC55Model, reusing previous: SC55ROMSet?) -> SC55ROMSet? {
        let waveCount = model == .sc55 ? 3 : 2
        var programs: [(versions: [String], data: [UInt8])] = []
        var extras: [String: [UInt8]] = [:]
        var sub: [UInt8]?
        var waves = [[UInt8]?](repeating: nil, count: waveCount)
        for (file, data) in identified {
            guard file.model == model else { continue }
            switch file.role {
            case let .program(versions): programs.append((versions, data))
            case let .extraProgram(version): extras[version] = data
            case .subProgram: sub = data
            case let .wave(n): if n < waveCount { waves[n] = data }
            }
        }
        let found = waves.compactMap { $0 }
        guard found.count == waveCount, model == .sc55 || sub != nil else { return nil }
        for version in versions(of: model) {
            guard let extra = extras[version], let program = programs.first(where: { $0.versions.contains(version) }) else { continue }
            if let previous, previous.model == model, previous.version == version, previous.program == program.data, previous.extraProgram == extra,
               previous.subProgram == sub ?? [], previous.waves == found { return previous }
            let set = SC55ROMSet(model: model, version: version, program: program.data, extraProgram: extra, subProgram: sub ?? [], waves: found)
            // Started once here, so that each tune starts from where this one is.
            let synth = SC55Synth(roms: set)
            synth.start()
            return SC55ROMSet(model: model, version: version, program: program.data, extraProgram: extra, subProgram: sub ?? [], waves: found,
                              unscrambledWaves: synth.unscrambledWaves, started: synth.state)
        }
        return nil
    }
}
