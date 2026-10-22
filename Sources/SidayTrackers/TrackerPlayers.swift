// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// The players of the PC's trackers: Impulse Tracker's, FastTracker 2's, Scream Tracker's and OpenMPT's
/// modules, and the others' that are read into the shape of one of theirs.
///
/// The loader asks each family in turn for a player (`TuneLoader`): nil is for a tune of a format
/// that is not this family's.
package enum TrackerPlayers {
    /// True for a file that begins as Epic MegaGames' MASI files do, though it is named as a PSM file
    /// (`TuneFormat.refined(byLeading:)`).
    package static func isMASI(_ leading: [UInt8]) -> Bool { MASIFile.isOne(leading) }

    // (Compiled here, and only called from elsewhere: see `TuneLoader`.)
    @export(interface)
    package static func player(_ data: [UInt8], format: TuneFormat, path: String?, options: LoadOptions,
                               companions: [[UInt8]?]) throws -> (any Renderer)? {
        switch format {
        case .composer669:
            return try Composer669Renderer(data, options: options)
        case .stm:
            return try STMRenderer(data, options: options)
        case .stx:
            // A Scream Tracker 2 module in another kind of file, read into an STM file.
            return try STXFile.renderer(data, options: options)
        case .far:
            return try FarandoleRenderer(data, options: options)
        case .mdl:
            // Digitrakker's, which Impulse Tracker's replayer plays as OpenMPT plays them.
            return try MDLFile.renderer(data, options: options)
        case .j2b:
            // Jazz Jackrabbit 2's, packed with zlib, which OpenMPT reads into the shape of an IT file.
            return try J2BFile.renderer(data, options: options)
        case .dmf:
            // X-Tracker's, which Impulse Tracker's replayer plays as OpenMPT plays them.
            return try DMFFile.renderer(data, options: options)
        case .imf:
            // Imago Orpheus's, which OpenMPT reads into the shape of an IT file: so it is here.
            return try IMFFile.renderer(data, options: options)
        case .ams:
            // Velvet Studio's and Extreme's Tracker's, which OpenMPT reads into the shape of an IT file.
            return try AMSFile.renderer(data, options: options)
        case .plm:
            // Disorder Tracker 2's, likewise.
            return try PLMFile.renderer(data, options: options)
        case .xm:
            return try XMRenderer(data, options: options)
        case .mtm:
            // Three trackers' modules that FastTracker 2's replayer plays, each read into its shape.
            return XMRenderer(try FT2Module(MTMFile.read(data)), options: options)
        case .dtm:
            return XMRenderer(try FT2Module(DTMFile.read(data)), options: options)
        case .amf:
            return XMRenderer(try FT2Module(AMFFile.read(data)), options: options)
        case .digi:
            // DIGI Booster's, which FastTracker 2's replayer plays as OpenMPT plays them.
            return XMRenderer(try FT2Module(DIGIFile.read(data)), options: options)
        case .s3m:
            return try S3MRenderer(data, options: options)
        case .dsm:
            // The Digital Sound Interface Kit's, which Scream Tracker 3's replayer plays as OpenMPT
            // plays them: read into an S3M file.
            return try DSMFile.renderer(data, options: options)
        case .masi:
            // Epic MegaGames' music, likewise. (A file named PSM that begins as one of these is one.)
            return try MASIFile.renderer(data, options: options)
        case .it:
            return try ITRenderer(data, options: options)
        case .gdm:
            // Neither of these two has a replayer of its own here: each is read into the shape of an
            // Impulse Tracker module, and Impulse Tracker's replayer plays it.
            return try GDMFile.renderer(data, options: options)
        case .ptm:
            return try PTMFile.renderer(data, options: options)
        case .ult:
            return try ULTFile.renderer(data, options: options)
        case .c67:
            return try C67File.renderer(data, options: options)
        case .mptm:
            // OpenMPT's own kind of file, which is an IT file with more after it: Impulse Tracker's
            // replayer plays as much of it as it has been taught to.
            return try MPTMFile.renderer(data, options: options)
        case .mt2:
            // MadTracker 2's, which OpenMPT reads into the shape of an IT file: so it is here.
            return try MT2File.renderer(data, options: options)
        case .symmod:
            // Symphonie's, which OpenMPT reads into a module of its own kind: played as an MPTM file is.
            return try SymMODFile.renderer(data, options: options)
        default:
            return nil
        }
    }
}
