// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// MARK: Settings and the songs of a file

@Test func shortSongsArePassedOverWhenAFilesSongsArePlayedInTurn() {
    // A tune, two sound effects, a song of unknown length, another tune.
    let lengths: [Double?] = [95, 1.5, 4, nil, 30]
    #expect(PlaybackPolicy.playedInTurn(lengths, shortest: 5) == [true, false, false, true, true])
    #expect(PlaybackPolicy.playedInTurn(lengths, shortest: 0) == [true, true, true, true, true])
    // A file of nothing but short ones plays them all.
    #expect(PlaybackPolicy.playedInTurn([1, 2, 3], shortest: 5) == [true, true, true])
    #expect(PlaybackPolicy.playedInTurn([3], shortest: 5) == [true])
    #expect(PlaybackPolicy.playedInTurn([], shortest: 5) == [])
}

@Test func settingsAsTheyComeAreTheCommandLinesOwn() {
    var options = LoadOptions(), policy = PlaybackPolicy()
    Setting.apply(Setting.standards, to: &options, &policy)
    let plain = LoadOptions(), usual = PlaybackPolicy()
    #expect(policy.loops == usual.loops && policy.loopFade == usual.loopFade && policy.defaultTime == usual.defaultTime && policy.maxTime == nil)
    #expect(options.chipType == nil && options.clockHz == nil && options.frameHz == nil)
    #expect(options.sidModel == plain.sidModel && options.sidEngine == plain.sidEngine && options.sidFilterCurve == plain.sidFilterCurve)
    #expect(options.amigaModel == plain.amigaModel && options.amigaSeparation == plain.amigaSeparation && options.s3mCard == nil)
    // But for the songs of a file, which a page that lists them plays in turn, all but the shortest.
    #expect(policy.allSubsongs && policy.shortestSong == 5)
}

@Test func settingsAreApplied() {
    var values = Setting.standards
    func choose(_ setting: Setting, _ code: String) {
        guard case .choice(let choices) = setting.kind, let place = choices.firstIndex(where: { $0.code == code }) else {
            Issue.record("\(setting.name) has no \(code)")
            return
        }
        values[setting.rawValue] = Double(place)
    }
    choose(.songs, "main"); choose(.shortestSong, "0"); choose(.loops, "3"); choose(.fade, "0"); choose(.defaultTime, "300"); choose(.maxTime, "600")
    choose(.chip, "ym"); choose(.clock, "1750000"); choose(.frameRate, "48.83")
    choose(.sidModel, "8580"); choose(.sidEngine, "resid"); choose(.amiga, "a500"); choose(.s3mCard, "sb")
    values[Setting.sidFilter.rawValue] = 80
    values[Setting.amigaSeparation.rawValue] = 100
    var options = LoadOptions(), policy = PlaybackPolicy()
    Setting.apply(values, to: &options, &policy)
    #expect(!policy.allSubsongs && policy.shortestSong == 0 && policy.loops == 3 && policy.loopFade == 0 && policy.defaultTime == 300 && policy.maxTime == 600)
    #expect(options.chipType == .ym && options.clockHz == 1_750_000 && options.frameHz == 48.828125)
    #expect(options.sidModel == .mos8580 && options.sidEngine == .resid && options.sidFilterCurve == 0.8)
    #expect(options.amigaModel == .a500 && options.amigaSeparation == 1 && options.s3mCard == .sb)
    // Nonsense is made sense of, and a short list leaves the rest as they come.
    Setting.apply([99, -4, .nan], to: &options, &policy)
    #expect(!policy.allSubsongs && policy.shortestSong == 0 && policy.loops == 1 && policy.loopFade == 20)
}

@Test func stereoIsTheWayRoundTheSettingsSay() {
    var values = Setting.standards
    #expect(Setting.stereo(for: .abc, values) == .abc && Setting.stereo(for: .mono, values) == .mono)
    values[Setting.stereoOrder.rawValue] = 1
    #expect(Setting.stereo(for: .abc, values) == .acb)
    // Mono and the televisions are mono whatever they say, and a front end that asks for one way
    // round by name gets it.
    #expect(Setting.stereo(for: .mono, values) == .mono && Setting.stereo(for: .wood, values) == .mono)
    #expect(Setting.stereo(for: .acb, Setting.standards) == .acb)
    #expect(Setting.stereo(for: .abc, []) == .abc)
}

@Test func settingsHaveNamesAndCodesOfTheirOwn() {
    #expect(Set(Setting.allCases.map { $0.name }).count == Setting.allCases.count)
    #expect(Setting.Group.allCases.flatMap { $0.settings } == Setting.allCases)
    for setting in Setting.allCases {
        #expect(!setting.title.isEmpty && !setting.about.isEmpty)
        #expect(setting.settled(setting.standard) == setting.standard)
        if case .choice(let choices) = setting.kind {
            #expect(choices.count > 1 && Set(choices.map { $0.code }).count == choices.count)
            // (What a setting is kept as has no comma or equals sign in it, which the keeping uses.)
            #expect(choices.allSatisfy { !$0.code.contains(",") && !$0.code.contains("=") })
        }
    }
}

@Test func aSettingOnlyMeansMakingATuneAgainIfItHasToDoWithIt() {
    #expect(Setting.sidModel.changes(.sid) && !Setting.sidModel.changes(.pt3) && !Setting.sidModel.changes(.mod))
    #expect(Setting.clock.changes(.pt3) && Setting.clock.changes(.ay) && Setting.clock.changes(.ym) && !Setting.clock.changes(.sid) && !Setting.clock.changes(.sndh))
    #expect(Setting.amiga.changes(.mod) && !Setting.amiga.changes(.xm))
    #expect(Setting.s3mCard.changes(.s3m) && !Setting.s3mCard.changes(.it))
    #expect(Setting.loops.changes(.sid) && Setting.fade.changes(.mod))
    #expect(!Setting.songs.changes(.sid) && !Setting.shortestSong.changes(.sid))
}
