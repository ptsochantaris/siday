// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// The player of the Commodore 64's SID tunes.
///
/// The loader asks each family in turn for a player (`TuneLoader`): nil is for a tune of a format
/// that is not this family's.
package enum C64Players {
    // (Compiled here, and only called from elsewhere: see `TuneLoader`.)
    @export(interface)
    package static func player(_ data: [UInt8], format: TuneFormat, path: String?, options: LoadOptions,
                               companions: [[UInt8]?]) throws -> (any Renderer)? {
        switch format {
        case .sid:
            return try SIDRenderer(data, path: path, options: options)
        default:
            return nil
        }
    }
}
