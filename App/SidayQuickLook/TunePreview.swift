// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SidayFiles
import SidayPlayer

/// One tune, as a Quick Look preview has it: its details as soon as it is loaded, and its sound as Quick
/// Look plays a recording: on the Mac as soon as the preview is on show, and on iPhone and iPad once
/// play is pressed. Quick Look makes previews of the files beside the one on show ahead of time, and
/// keeps some after they go out of view, so a preview plays only while it is on show (see `show(_:)`),
/// and only one plays at a time. It is played as the app plays it, with the settings as they are until
/// changed (see `PreviewEngine`).
@Observable final class TunePreview {
    /// What is known of the tune, once it is loaded; why it does not play, if it does not.
    private(set) var tune: Tune?
    private(set) var problem: String?
    /// For a tune that keeps part of itself in a file beside it, which a preview cannot read.
    private(set) var note: String?
    private(set) var fileName = ""
    private(set) var playing = false
    /// True once the song has been heard to its end, when play starts it again.
    private(set) var finished = false

    /// True once play has been pressed: until then, there is nothing for the lights to show.
    private(set) var started = false

    /// Whether the preview is on show; and whether it is to play while it is, until the listener pauses it.
    @ObservationIgnored private var shown = false
    #if os(macOS)
    @ObservationIgnored private var wanted = true
    #else
    @ObservationIgnored private var wanted = false
    #endif
    /// The preview on show, which is the only one let play.
    private static weak var onShow: TunePreview?

    @ObservationIgnored private var engine: PreviewEngine?
    /// The first of the files the tune wants beside it that a preview could not read.
    @ObservationIgnored private var lacking: Companion?
    @ObservationIgnored private let display = Display()
    /// (The app's pictures to listen by, of which a preview shows none.)
    @ObservationIgnored private let visualisers = Visualisers(mode: .lava)

    /// Reads the file, and has the engine load it, silent until the preview is on show.
    func open(_ url: URL) throws {
        fileName = url.lastPathComponent
        let bytes = [UInt8](try Data(contentsOf: url))
        var companions: [[UInt8]?] = []
        if let format = TuneFormat(url: url) {
            companions = CompanionFiles.read(for: url, format: format).companions
            // (A preview is given the one file: one beside it, which the app could be let read, cannot
            // be. If the tune does not play without it, that is why.)
            let wanted = Companions.wanted(for: format, fileName: fileName)
            lacking = wanted.indices.first { $0 >= companions.count || companions[$0] == nil }.map { wanted[$0] }
        }
        let engine = engine ?? PreviewEngine(silent: ProcessInfo.processInfo.arguments.contains("-SidaySilent")) { [weak self] news in
            self?.hear(news)
        }
        self.engine = engine
        engine.load(bytes, name: fileName, companions: companions)
    }

    /// Plays, or pauses; from the start again once the song is over.
    func togglePlay() {
        guard let engine, tune != nil else { return }
        if finished {
            finished = false
            engine.restart()
            wanted = true
        } else {
            wanted = !playing
        }
        // (A preview whose button is pressed is on show, whatever it has been told.)
        show(true)
    }

    /// The preview has come into view, or gone out of it: it plays while it is in view, and the one
    /// that was in view before it stops.
    func show(_ on: Bool) {
        shown = on
        if on {
            if let other = Self.onShow, other !== self { other.show(false) }
            Self.onShow = self
        } else if Self.onShow === self {
            Self.onShow = nil
        }
        settle()
    }

    /// Stops the sound for good: the preview is going away.
    func close() {
        show(false)
        engine?.stop()
        engine = nil
    }

    /// Plays or pauses, as being on show, the listener and the song's end have it.
    private func settle() {
        let play = shown && wanted && !finished && tune != nil && engine != nil
        guard play != playing else { return }
        playing = play
        if play { started = true }
        engine?.play(play)
    }

    /// What is shown for one frame of the screen.
    func frame(at time: Double) -> Frame {
        guard let engine else { return Frame() }
        return display.frame(engine.heard, serial: 1, at: time, visualisers: visualisers)
    }

    private func hear(_ news: PreviewEngine.News) {
        switch news {
        case let .loaded(tune, problem):
            self.tune = tune
            self.problem = tune == nil ? problem ?? String(localized: "The file could not be played.") : nil
            if tune == nil, let lacking {
                note = String(localized: "\(fileName) keeps \(lacking.what) \(Companions.whereKept(lacking)), which a preview cannot open. The app can play it.")
            }
            settle()
        case .ended:
            playing = false
            finished = true
            engine?.play(false)
        }
    }
}
