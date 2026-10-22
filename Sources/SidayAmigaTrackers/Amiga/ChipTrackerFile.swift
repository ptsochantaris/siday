// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// A module of ChipTracker's (1991), Krister Wombell's tracker, which some games' music was written
/// in: a ProTracker module in all but how it keeps its notes. Its title and its 31 samples are where a
/// ProTracker module's are, and after them, where that has the length of its song, it has "KRIS"; then
/// the length, and in place of patterns it has tracks, each one voice's 64 rows, and for each place
/// in the song the four tracks to play there, each moved up or down by so many semitones. A note is
/// kept as its place in a table of periods of six octaves, the lowest two below ProTracker's three,
/// and the replayer takes no account of a sample's finetune.
///
/// It is read into the ProTracker module it would be, a pattern for each different four tracks and
/// moves that a place in the song has, with each note's period as ChipTracker's table has it after the
/// move, and played as one: ChipTracker's commands are ProTracker's. This is the reading of its own
/// replayer, which Wanted Team keep in their player of the files for EaglePlayer.
enum ChipTrackerFile {
    /// True for a file with ChipTracker's four letters where they go.
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count >= 1984 && data[952] == 0x4B && data[953] == 0x52 && data[954] == 0x49 && data[955] == 0x53 // "KRIS"
    }

    /// The table of periods ChipTracker's replayer plays a note's place in: six octaves from C, the
    /// fourth ProTracker's first.
    private static let periods: [UInt16] = [
        6848, 6464, 6096, 5760, 5424, 5120, 4832, 4560, 4304, 4064, 3840, 3624,
        3424, 3232, 3048, 2880, 2712, 2560, 2416, 2280, 2152, 2032, 1920, 1812,
        1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016, 960, 906,
        856, 808, 762, 720, 678, 640, 604, 570, 538, 508, 480, 453,
        428, 404, 381, 360, 339, 320, 302, 285, 269, 254, 240, 226,
        214, 202, 190, 180, 170, 160, 151, 143, 135, 127, 120, 113,
    ]

    /// The ProTracker module the file is.
    static func module(_ data: [UInt8]) throws(TuneError) -> [UInt8] {
        guard isOne(data) else { throw .malformed("not a ChipTracker module") }
        let length = Int(data[956])
        guard length > 0, length <= 128 else { throw .malformed("a ChipTracker module of no song") }
        // A later ChipTracker could make sounds of its own, from waveforms kept before the tracks, and
        // mark them as samples whose names begin with nought (as OpenMPT reads them). No replayer of
        // those is to hand to play them by.
        for sample in 0 ..< 31 {
            let header = 22 + sample * 30
            if data[header] == 0, data[header + 1] | data[header + 5] | data[header + 10] | data[header + 19] != 0 {
                throw .unsupported("a ChipTracker module with sounds of its own making, which are not played")
            }
        }
        // Each place in the song: four tracks, and how far each is moved, a byte each.
        let places = 958
        var tracks = 0
        for entry in 0 ..< length * 4 { tracks = max(tracks, Int(data[places + entry * 2]) + 1) }
        let firstTrack = 1984
        let samples = firstTrack + tracks * 256
        guard samples <= data.count else { throw .malformed("a ChipTracker module cut short in its tracks") }

        var module: [UInt8] = []
        module.reserveCapacity(1084 + length * 1024 + data.count - samples)
        module += data[0 ..< 20]
        for sample in 0 ..< 31 {
            let header = 22 + sample * 30
            // Its name and its length; no finetune, which the replayer does not use; its volume; and
            // where its loop begins, which ChipTracker counts in bytes and ProTracker in words.
            module += data[header ..< header + 24]
            module.append(0)
            module.append(data[header + 25])
            let loopStart = (Int(data[header + 26]) << 8 | Int(data[header + 27])) >> 1
            module += [UInt8(loopStart >> 8), UInt8(loopStart & 0xFF), data[header + 28], data[header + 29]]
        }
        // The places that play the same four tracks, moved the same, share a pattern. (A song can have
        // more places than a ProTracker module can have patterns.)
        var firstPlaces: [Int] = []
        var order: [UInt8] = []
        for place in 0 ..< length {
            let entries = data[places + place * 8 ..< places + place * 8 + 8]
            if let same = firstPlaces.firstIndex(where: { data[places + $0 * 8 ..< places + $0 * 8 + 8] == entries }) {
                order.append(UInt8(same))
            } else {
                order.append(UInt8(firstPlaces.count))
                firstPlaces.append(place)
            }
        }
        module += [UInt8(length), data[957]]
        for place in 0 ..< 128 { module.append(place < length ? order[place] : 0) }
        module += [0x4D, 0x2E, 0x4B, 0x2E] // "M.K."

        for place in firstPlaces {
            var pattern = [UInt8](repeating: 0, count: 1024)
            for voice in 0 ..< 4 {
                let entry = places + (place * 4 + voice) * 2
                let track = firstTrack + Int(data[entry]) * 256
                let move = Int(Int8(bitPattern: data[entry + 1]))
                for row in 0 ..< 64 {
                    let event = track + row * 4
                    let note = data[event], sample = data[event + 1]
                    var period: UInt16 = 0
                    if note != 0xA8 {
                        // A note moved off the end of the table is a period of nothing, as the table
                        // is followed by noughts; one moved off its start, which the replayer would
                        // read from what lies before the table, is taken as nothing too.
                        let place = Int(note) / 2 + move
                        period = place >= 0 && place < periods.count ? periods[place] : 0
                    }
                    let at = (row * 4 + voice) * 4
                    pattern[at] = sample & 0xF0 | UInt8(period >> 8 & 0x0F)
                    pattern[at + 1] = UInt8(period & 0xFF)
                    pattern[at + 2] = (sample & 0x0F) << 4 | data[event + 2] & 0x0F
                    pattern[at + 3] = data[event + 3]
                }
            }
            module += pattern
        }
        module += data[samples...]
        return module
    }
}
