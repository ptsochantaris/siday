// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayCodecs
import SidayFoundation

/// An MO3 file, played as the module it was made from (see `MO3`): that module's own player does
/// everything, and this says that it is an MO3, and what of the module could not be carried over.
final class MO3Player: Renderer {
    private let module: any Renderer
    let info: TuneInfo

    init(_ module: any Renderer, packed: MO3Module) {
        self.module = module
        var info = module.info
        // (As the format the file was made in is named: "IT", "XM" and so on.)
        let made = "\(module.info.format) packed by MO3 \(packed.version)"
        info.detail = module.info.detail.isEmpty ? made : made + "; " + module.info.detail
        info.format = "MO3"
        info.shortfalls = packed.shortfalls + module.info.shortfalls
        self.info = info
    }

    var subsongCount: Int { module.subsongCount }
    var defaultSubsong: Int { module.defaultSubsong }
    var currentSubsong: Int { module.currentSubsong }
    func select(subsong: Int) { module.select(subsong: subsong) }
    var songs: [SongInfo] { module.songs }
    var knownLength: Double? { module.knownLength }
    var loopLength: Double? { module.loopLength }
    var fileFade: Double? { module.fileFade }
    var loopCount: Int { module.loopCount }
    var endsByLooping: Bool { module.endsByLooping }
    var hasEnded: Bool { module.hasEnded }
    var isPlayedOnAnAmiga: Bool { module.isPlayedOnAnAmiga }
    func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) { module.render(into: buffer, frames: frames) }
    var channelCount: Int { module.channelCount }
    var channelsAlwaysShown: Int { module.channelsAlwaysShown }
    func takeChannelLevels(into levels: UnsafeMutablePointer<Float>) { module.takeChannelLevels(into: levels) }
    func takeChannelNotes(pitches: UnsafeMutablePointer<Float>, struck: UnsafeMutablePointer<Bool>) {
        module.takeChannelNotes(pitches: pitches, struck: struck)
    }
    func takeChannelSides(into sides: UnsafeMutablePointer<Float>) { module.takeChannelSides(into: sides) }
    func takeChannelsSampled(into sampled: UnsafeMutablePointer<Bool>) { module.takeChannelsSampled(into: sampled) }
    var channelsAreSampled: Bool { module.channelsAreSampled }
    var speakerChannel: Int? { module.speakerChannel }
    func keepChannelWaves() -> ChannelWaves? { module.keepChannelWaves() }
    func setMuted(_ muted: [Bool]) { module.setMuted(muted) }
    var songMeasures: SongMeasures? { module.songMeasures }
    func adopt(_ measures: SongMeasures) { module.adopt(measures) }
}
