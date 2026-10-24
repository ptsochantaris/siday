// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// The players of recordings: Ogg Vorbis, MP3 and WAV files, music as it was heard.
///
/// The loader asks each family in turn for a player (`TuneLoader`): nil is for a tune of a format
/// that is not this family's.
package enum RecordingPlayers {
    /// What every recording is multiplied by, to be as loud as every other kind of tune (see FORMATS.md):
    /// the middle of the loudness of the collection's 777 Ogg Vorbis recordings that are not silence,
    /// -16.8 LUFS as they are, brought to the formats' own, -22.95 LUFS.
    static let gain: Float = 0.49

    // (Compiled here, and only called from elsewhere: see `TuneLoader`.)
    @export(interface)
    package static func player(_ data: [UInt8], format: TuneFormat, path _: String?, options: LoadOptions,
                               companions _: [[UInt8]?]) throws -> (any Renderer)? {
        switch format {
        case .ogg:
            let file = try VorbisFile(data)
            return try RecordingRenderer(file, format: "Ogg Vorbis", detail: detail(file, ""), gain: gain, options: options)
        case .mp3:
            // (An MP2 or MP1 file is named for its layer.)
            let file = try MP3File(data)
            return try RecordingRenderer(file, format: "MP\(file.layer)", detail: detail(file, ""), gain: gain, options: options)
        case .wav:
            let file = try WAVFile(data)
            return try RecordingRenderer(file, format: "WAV", detail: detail(file, file.detail), gain: gain, options: options)
        default:
            return nil
        }
    }

    /// A line about a recording: how many samples a second, in mono or stereo, and how they are kept.
    static func detail(_ source: some RecordingSource, _ kept: String) -> String {
        // (In kilohertz, to as many places as it has: 44.1, 22.05, 11.025.)
        var fraction = String(1000 + source.sampleRate % 1000).dropFirst()
        while fraction.last == "0" { fraction = fraction.dropLast() }
        let rate = "\(source.sampleRate / 1000)" + (fraction.isEmpty ? "" : "." + fraction)
        let sides = source.channels == 1 ? "mono" : "stereo"
        return ["\(rate) kHz \(sides)", kept].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

extension VorbisFile: RecordingSource {}
extension MP3File: RecordingSource {}
