// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The players of the Amiga's trackers: ProTracker's modules and those packed or made in its likeness,
/// MED, SoundFX, Oktalyzer, AHX and HivelyTracker, and DigiBooster Pro.
///
/// The loader asks each family in turn for a player (`TuneLoader`): nil is for a tune of a format
/// that is not this family's.
package enum AmigaTrackerPlayers {
    /// - Parameter widerModule: the player for a module of more voices than the Amiga's four, which is
    ///   a PC tracker's (FastTracker 2's, `TrackerPlayers`), or nil if it is not one.
    package static func player(_ data: [UInt8], format: TuneFormat, path: String?, options: LoadOptions,
                               companions: [[UInt8]?], widerModule: ([UInt8]) -> (any Renderer)?) throws -> (any Renderer)? {
        switch format {
        case .mfp:
            // A ProTracker module packed with its samples in a file of their own.
            guard let samples = companions.first ?? nil else {
                throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
            }
            return try MODRenderer(MagneticFieldsPacker.module(data, samples: samples), options: options,
                                   origin: "packed by the Magnetic Fields Packer")
        case .mod:
            // A module of the Amiga's four channels is ProTracker's to play. One of more is a PC
            // tracker's, and FastTracker 2 plays those. (And a MED module that has been named as if
            // it were a MOD file says in its first letters what it is.)
            if data.count > 4, data[0] == 0x4D, data[1] == 0x4D, data[2] == 0x44, data[3] >= 0x30, data[3] <= 0x33 {
                return try MEDRenderer(data, options: options)
            }
            // A module packed for a game or a demo is unpacked into the ProTracker module it was. As
            // libxmp does, a module that says what it is in four letters is taken to be one first, and
            // one of the oldest, which says nothing, only once no packer has taken it.
            func unpacked() throws -> (any Renderer)? {
                guard let (packer, module) = ProWizard.unpack(data) else { return nil }
                return try MODRenderer(module, options: options, origin: "packed by \(packer)")
            }
            // (Startrekker kept its synthesised instruments in a file of their own beside the module,
            // which is no tune, whatever it is named.)
            if data.count >= 16, [UInt8]("ST1.2 ModuleINFO".utf8) == Array(data[0 ..< 16]) || [UInt8]("ST1.3 ModuleINFO".utf8) == Array(data[0 ..< 16])
                || [UInt8]("AudioSculpture10".utf8) == Array(data[0 ..< 16])
            {
                throw TuneError.unsupported("Startrekker's synthesised instruments for the module beside it, and not a tune of its own")
            }
            if ChipTrackerFile.isOne(data) {
                return try MODRenderer(ChipTrackerFile.module(data), options: options, origin: "ChipTracker")
            }
            if AMOSBankFile.isOne(data) {
                return try MODRenderer(AMOSBankFile.module(data), options: options, origin: "an AMOS music bank")
            }
            if !ProTrackerModule.saysWhatItIs(data), let renderer = try unpacked() { return renderer }
            do {
                // (With Startrekker's synthesised instruments from the file beside it, if it has one.)
                return try MODRenderer(data, options: options, synthesised: companions.first ?? nil)
            } catch let error as TuneError {
                if case .unsupported = error, let more = widerModule(data) { return more }
                if let renderer = try unpacked() { return renderer }
                throw error
            }
        case .med:
            return try MEDRenderer(data, options: options)
        case .sfx:
            return try SoundFXRenderer(data, options: options)
        case .okt:
            return try OktalyzerRenderer(data, options: options)
        case .dbm:
            return try DBMRenderer(data, options: options)
        case .ahx, .hvl:
            // HivelyTracker reads both its own files and AHX's, so a file of either may be found
            // under the other's name. Each says which it is in its first three letters.
            if data.starts(with: [0x48, 0x56, 0x4C]) || (format == .hvl && !data.starts(with: [0x54, 0x48, 0x58])) {
                return try HVLRenderer(data, options: options)
            }
            return try AHXRenderer(data, options: options)
        default:
            return nil
        }
    }
}
