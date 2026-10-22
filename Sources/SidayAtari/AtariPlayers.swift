// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// The players of the Atari ST's music: SNDH files, and YM files recorded from the ST.
///
/// The loader asks each family in turn for a player (`TuneLoader`): nil is for a tune of a format
/// that is not this family's.
package enum AtariPlayers {
    // (Compiled here, and only called from elsewhere: see `TuneLoader`.)
    @export(interface)
    package static func player(_ data: [UInt8], format: TuneFormat, path: String?, options: LoadOptions,
                               companions: [[UInt8]?]) throws -> (any Renderer)? {
        switch format {
        case .ym:
            // A recording made on an Atari ST is played on the ST's chip, with the effects ST musicians
            // made between one set of registers and the next, unless a chip, clock or rate has been
            // asked for, which is to ask for the plain recording on a chip of one's own choosing.
            if options.chipType == nil, options.clockHz == nil, options.frameHz == nil, let atari = STYMRenderer(data) {
                return atari
            }
            // And two kinds of YM file are not recordings of the chip at all, but samples.
            return STSampleRenderer(data)
        case .sndh:
            return try SNDHRenderer(data, options: options)
        default:
            return nil
        }
    }
}
