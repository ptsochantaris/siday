// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation
import SidayKit

// What a player with a screen does between a file and the sound it hands to be heard: the web player's
// engine and the app both play tunes through this. It loads a tune and starts its songs; makes its
// sound a block at a time, as the command-line player renders it; finishes what it made on its way
// to be heard (the song's level, the television, the spectrum analyser); and keeps what is known of
// each voice, for its light, its scope and the picture to listen by.
//
// A front end may render a whole song as fast as it can and keep it, so that the listener can move
// about in it, as the web player does. What it keeps is the tune as the chip made it: `pull` makes
// the sound and `present` finishes it, so a television can be put in the way or taken out of it at
// any moment; a change between mono and stereo is a change to what the chip makes, and the song has
// to be rendered again (`setOutput` says when).

/// One tune at a time: what the command-line player's engine does between a file and the sound card.
public final class TunePlayer {
    /// The length of a block, as the command-line player renders them: the rules that end a tune look
    /// at the sound a block at a time, so the two front ends must cut it the same way.
    public static let blockFrames = 512

    public private(set) var options = LoadOptions()
    /// How long tunes are played, and which song of a file is the first: the page lists a file's
    /// songs, and goes on to the next when one ends.
    private var policy = PlaybackPolicy()
    /// The listener's settings, as last given (see `Setting`): they are what `options` and `policy`
    /// are made from, apart from what the tune is heard through and the song lengths.
    private var settings = Setting.standards
    /// The kind of tune that is loaded.
    public private(set) var format: TuneFormat?
    /// What tunes are heard through.
    private var style = OutputStyle.mono
    public private(set) var renderer: (any Renderer)?
    /// What is known of the loaded tune: its player's, with the chip its kind of file is most likely
    /// played on where the player names none.
    public var info: TuneInfo? {
        guard var info = renderer?.info else { return nil }
        if info.chips.isEmpty, let format { info.chips = [format.likelyChip] }
        return info
    }
    private var session: TuneSession?
    private var television: Television?
    /// How the loaded tune's channels were placed when it was loaded, if that is something it has:
    /// an AY tune has three channels to place, a SID tune has a single output, and an Atari ST joins
    /// its three into one.
    private var layout: StereoLayout?
    /// True for a tune whose stereo is its own (a module's), which the choice of output only keeps or folds.
    private var ownStereo = false
    private let block = UnsafeMutablePointer<Float>.allocate(capacity: TunePlayer.blockFrames * 2)
    private var blockLength = 0
    private var blockCursor = 0
    /// The last thing to tell the page in words: a tune's details, or why a file would not load.
    public private(set) var text: [UInt8] = []
    /// Why the last file would not load, if it would not.
    public private(set) var problem: String?
    private var spectrum = SpectrumAnalyzer()
    /// The analyser's bars and then their caps, each as a byte from 0 to 255.
    public private(set) var bars: [UInt8] = []
    /// What is known of each voice of the tune for the sound made since this was last taken: how
    /// bright its light has been, from 0 to 255; its pitch, in half semitones (120 is middle C), or 0
    /// for none; 1 if a note was started on it; and the side it is heard from, from 1 for the left
    /// through 128 for the middle to 255 for the right. And what was handed over the last time they
    /// were taken: all the lights, then all the pitches, then all the marks, then all the sides,
    /// then for each voice what it is: 1 if it is playing a sample, 2 if it is the computer's own
    /// loudspeaker, and 0 for a chip's voice.
    private var lights: [UInt8] = []
    private var pitches: [UInt8] = []
    private var struck: [UInt8] = []
    private var sides: [UInt8] = []
    private var sampled: [UInt8] = []
    /// The voice that is the computer's own loudspeaker, if one is (`Renderer.speakerChannel`).
    private var speaker: Int?
    public private(set) var voicesTaken: [UInt8] = []
    /// Each voice's scope as the sound handed out so far ends: `ChannelWaves.points` bytes a voice.
    public private(set) var scopes: [UInt8] = []
    public var voiceCount: Int { lights.count }
    /// The voices the listener has left out of the sound: a mark for each, true for one not to be
    /// heard, or none at all. A song is rendered whole and kept, so a change here is heard when
    /// the song has been rendered again (see `setMuted`).
    private var muted: [Bool] = []
    /// How the song that is loaded ended when it was last played with every voice heard, and which
    /// song of the file that was. A song with voices left out is played to the same ending: by its
    /// own sound it might be taken to have fallen silent, or to have nothing left to fade.
    private var ending: TuneSession.Ending?
    private var endingOf = 0
    /// True while the session is one that follows `ending`.
    private var following = false
    /// How far songs are brought to the same loudness (see `Levelling`), and what is known of the
    /// song's own: what it is kept under, from the file's digest; what it was found to be, once it
    /// is known; and the meter it is being measured by while the song is rendered whole, which costs
    /// next to nothing, since the song is rendered whole anyway. A song rendered again as it was, for
    /// voices left out or brought back, keeps its level.
    private var levelling = Levelling.off
    private var digest = ""
    public private(set) var levelKey = ""
    public private(set) var level: SongLevel?
    private var meter: LoudnessMeter?
    /// True once the song has been measured here, and not given its level from what was kept.
    public private(set) var levelFound = false
    /// The gain on what is heard, and how much of the song has been heard since it started.
    private var gain = LevelGain()
    private var presented = 0

    /// The files the next tune to be loaded needs beside its own, as `TuneLoader.load` takes them: one
    /// for each it names, nil for one that was not found. Given before each load (`siday_companion`).
    public var companions: [[UInt8]?] = []

    /// What was found of the songs of the files loaded lately, by playing them through (see
    /// `LoadOptions.measuresEverySong`), under their digests: the newest last. A file is loaded again
    /// for each of its songs and each change to how it is heard, and is not played through again.
    private var measured: [(key: String, measures: SongMeasures)] = []
    private static let measuredKept = 32

    private func remember(_ measures: SongMeasures, key: String) {
        measured.removeAll { $0.key == key }
        measured.append((key, measures))
        if measured.count > Self.measuredKept { measured.removeFirst() }
    }

    /// True while some of the songs of the tune that is loaded have still to be played through to
    /// find how long they are (`SongInfo.pending`). They are, as they are selected; and all of them
    /// by `measure`, made on another thread or in another worker so as not to hold up the sound,
    /// whose finding is given back to `adopt`.
    public var songsPending: Bool { renderer?.songs.contains { $0.pending } ?? false }

    /// Plays every song of a tune through, as a load of it here would, to find how long each is: for
    /// `adopt`, on another player. Nil for a tune that is not played through (or will not load).
    /// Returned with the digest it is kept under. (The other player's settings make no difference,
    /// and are left as they are: the players that play their songs through count in their own clocks,
    /// before any sound is made of them, and none of what they are given makes a song longer or
    /// shorter. Which Amiga, and how far apart its sides are, is only how it sounds.)
    public func measure(_ data: [UInt8], name: String) -> (key: String, measures: SongMeasures)? {
        let fileExtension = name.split(separator: ".").count > 1 ? String(name.split(separator: ".").last ?? "") : ""
        guard let named = TuneFormat(fileExtension: fileExtension) else { return nil }
        let format = named.refined(byLeading: Array(data.prefix(TuneFormat.leadingBytes)))
        guard let measures = try? TuneLoader.load(data, format: format, path: name, options: options, companions: companions).songMeasures
        else { return nil }
        return (SongLevel.digest(of: data, companions: companions), measures)
    }

    /// Takes what `measure` found, and keeps it. Returns true if it is of the tune that is loaded and
    /// told it something it did not know: its songs, and `text`, then say how long each is.
    public func adopt(_ measures: SongMeasures, key: String) -> Bool {
        remember(measures, key: key)
        guard key == digest, songsPending, let renderer else { return false }
        renderer.adopt(measures)
        describe()
        return true
    }

    /// Loads a tune and starts its first song. Returns false, with the reason in `text`, if it cannot be played.
    public func load(_ data: [UInt8], name: String) -> Bool {
        problem = nil
        renderer = nil
        session = nil
        layout = nil
        format = nil
        // (A song loaded to be heard whole will say how it ends by being played. One loaded with
        // voices left out is the song that was just heard whole, and ends as that did.)
        if !muted.contains(true) { ending = nil }
        let fileExtension = name.split(separator: ".").count > 1 ? String(name.split(separator: ".").last ?? "") : ""
        guard let named = TuneFormat(fileExtension: fileExtension) else {
            problem = "unknown file type .\(fileExtension)"
            text = Array((problem ?? "").utf8)
            return false
        }
        let format = named.refined(byLeading: Array(data.prefix(TuneFormat.leadingBytes)))
        do {
            // (The songs are played through as far as the one to start with, unless they were before.)
            let digest = SongLevel.digest(of: data, companions: companions)
            var options = options
            options.measuresEverySong = false
            options.songMeasures = measured.last { $0.key == digest }?.measures
            let loaded = try TuneLoader.load(data, format: format, path: name, options: options, companions: companions)
            renderer = loaded
            self.digest = digest
            self.format = format
            layout = format == .sid || format == .sndh || format == .cmf || format == .rol || format == .fmt || format == .stm || format == .stx ? nil : options.stereo
            ownStereo = format == .mod || format == .med || format == .ahx || format == .hvl || format == .xm || format == .s3m || format == .it
                || format == .mtm || format == .dtm || format == .amf
                || format == .gdm || format == .ptm || format == .ult || format == .c67
                || format == .mptm
                || format == .mt2
                || format == .sfx || format == .okt
                || format == .composer669 || format == .far || format == .dbm
                || format == .mdl
                || format == .symmod
                || format == .j2b
                || format == .dmf
                || format == .imf || format == .ams
                || format == .plm
                || format == .dsm || format == .masi
                || format == .digi
                || format == .vgm
                || format == .sap
                || format == .agi
                || format == .mfp
                || format == .tfmx
                || format == .hip || format == .fc
                || format == .puma || format == .pap || format == .gmc || format == .ims
                || format == .bp || format == .sid1 || format == .sid2 || format == .mug || format == .dm2 || format == .mxtx || format == .sa || format == .sonix || format == .rjp || format == .dln || format == .dw || format == .mw || format == .jd || format == .mon || format == .jt || format == .bd || format == .cust || format == .dl
                || format.isWantedTeamCode || format.isPortedGamePlayer
            // A song chosen to start with while some were still to be played through may turn out,
            // once it has been, not to be the one: shorter than the shortest that is played, or one of
            // a file of nothing but songs that short, which are then all played, from the first. What
            // is known only grows, so the choice comes to rest; at the latest when every song is known.
            var first = policy.firstSubsong(of: loaded)
            select(first)
            for _ in 0 ... loaded.subsongCount {
                let chosen = policy.firstSubsong(of: loaded)
                if chosen == first { break }
                first = chosen
                select(first)
            }
            return true
        } catch let error as TuneError {
            problem = error.description
            text = Array(error.description.utf8)
        } catch {
            problem = "the file could not be played"
            text = Array("the file could not be played".utf8)
        }
        return false
    }

    /// Starts a song of the loaded tune from its beginning.
    public func select(_ subsong: Int) {
        guard let renderer else { return }
        let song = min(max(0, subsong), renderer.subsongCount - 1)
        if renderer.subsongCount > 1 || song != renderer.currentSubsong { renderer.select(subsong: song) }
        if muted.contains(true), let ending, endingOf == song {
            renderer.setMuted((0 ..< renderer.channelCount).map { $0 < muted.count && muted[$0] })
            session = TuneSession(renderer: renderer, policy: policy, following: ending)
            following = true
        } else {
            renderer.setMuted([])
            session = TuneSession(renderer: renderer, policy: policy)
            following = false
        }
        session?.keepChannelWaves()
        let key = SongLevel.key(digest: digest, song: song, options: options, policy: policy, playedOn: SongLevel.playedOn(renderer, options: options))
        if key != levelKey {
            levelKey = key
            level = nil
            levelFound = false
            gain = LevelGain()
            presented = 0
        }
        meter = following || level != nil ? nil : LoudnessMeter()
        lights = [UInt8](repeating: 0, count: renderer.channelCount)
        pitches = lights
        struck = lights
        sides = [UInt8](repeating: 128, count: lights.count)
        sampled = lights
        speaker = renderer.speakerChannel
        voicesTaken = lights + lights + lights + sides + lights
        scopes = [UInt8](repeating: 128, count: lights.count * ChannelWaves.points)
        settle()
        blockLength = 0
        blockCursor = 0
        if let measures = renderer.songMeasures { remember(measures, key: digest) }
        describe()
    }

    /// Says what the tune is in `text`.
    private func describe() {
        guard let renderer else { return }
        text = Array(Self.details(of: info ?? renderer.info, songs: renderer.subsongCount > 1 ? renderer.songs : []).utf8)
    }

    /// What a tune is, in words for the page. One line each: format, title, author, detail. Then a
    /// line for each song when there are several: its length in milliseconds, if that is known, or a
    /// question mark while it is still to be found (`SongInfo.pending`), a tab, a 1 if there is known
    /// to be nothing in it and a 0 if not, a tab, and its name, if it has one. Then a line for each
    /// thing the file asks for that is not played as it asks (`TuneInfo.shortfalls`): an exclamation
    /// mark, which no song's line begins with, and the sentence. Then a line for each chip it is heard
    /// as made by (`TuneInfo.chips`): a hash and the chip's name. The page takes them apart again.
    public static func details(of info: TuneInfo, songs: [SongInfo]) -> String {
        func tidy(_ field: String) -> String { String(field.map { $0.isNewline || $0 == "\t" ? " " : $0 }) }
        var lines = [info.format, info.title, info.author, info.detail].map(tidy)
        if songs.count > 1 {
            for song in songs {
                lines.append("\(song.pending ? "?" : song.length.map { String(Int($0 * 1000)) } ?? "")\t\(song.empty ? 1 : 0)\t\(tidy(song.title))")
            }
        }
        for shortfall in info.shortfalls { lines.append("!" + tidy(shortfall)) }
        for chip in info.chips { lines.append("#" + chip.rawValue) }
        return lines.joined(separator: "\n")
    }

    public init() {
        Setting.apply(settings, to: &options, &policy)
    }

    /// Says which voices are to be left out of the song when it is next loaded: a mark for each,
    /// or none. Returns true if the song can be loaded so at once: no voice is left out, or it is
    /// known how the song that is loaded ends. If not, the song has to be played through whole
    /// first, which is what tells how it ends.
    public func setMuted(_ marks: [Bool]) -> Bool {
        muted = marks.contains(true) ? marks : []
        return muted.isEmpty || (ending != nil && endingOf == subsong)
    }

    /// HVSC's own list of song lengths, to be asked before the lengths that are built in; nil for none.
    public func setSongLengths(_ database: SongLengthDatabase?) {
        options.songLengths = database
    }

    /// The ROMs of an MT-32 of the LAPC-I's kind (see `KeptFiles`), on whose synthesiser the MIDI files
    /// written for the MT-32 that are loaded after it are played; nil for none, and FM.
    public func setMT32ROMs(_ roms: MT32ROMSet?) {
        options.mt32ROMs = roms
    }

    /// The ROMs of an SC-55 (see `KeptFiles`), on which the MIDI files loaded after it are played (those
    /// written for the MT-32 only when there are no MT-32 ROMs); nil for none, and FM.
    public func setSC55ROMs(_ roms: SC55ROMSet?) {
        options.sc55ROMs = roms
    }

    /// Changes the listener's settings: a value for each, in the order of `Setting`'s cases. Returns
    /// true if the tune that is loaded has to be loaded again to be heard as they now are.
    public func setSettings(_ values: [Double]) -> Bool {
        let before = settings
        settings = Setting.allCases.map { $0.settled($0.rawValue < values.count ? values[$0.rawValue] : $0.standard) }
        Setting.apply(settings, to: &options, &policy)
        let levelling = Setting.levelling(settings)
        if levelling != self.levelling {
            self.levelling = levelling
            if let level { gain.glide(to: level.gain(levelling)) }
        }
        let placedOtherwise = placeChannels()
        guard let format, let renderer else { return false }
        return placedOtherwise || Setting.allCases.contains { settings[$0.rawValue] != before[$0.rawValue] && $0.changes(format, played: renderer) }
    }

    /// Changes what tunes are heard through. Returns true if the tune that is loaded has to be loaded
    /// again to be heard that way: its channels were placed otherwise when it was rendered.
    public func setOutput(_ style: OutputStyle) -> Bool {
        if style.television != television?.set { television = style.television.map { Television($0) } }
        self.style = style
        return placeChannels()
    }

    /// Works out how a tune's channels are to be placed, from what tunes are heard through and from
    /// the settings, which say which way round stereo is. Returns true if the tune that is loaded
    /// had its channels placed otherwise.
    private func placeChannels() -> Bool {
        let stereo = Setting.stereo(for: style, settings)
        options.stereo = stereo
        // A module has a stereo of its own, which only mono does away with.
        return layout.map { ownStereo ? ($0 == .mono) != (stereo == .mono) : $0 != stereo } ?? false
    }

    /// What is about to be presented does not follow from what was presented last: the song has
    /// started, or the listener has moved to another place in it.
    public func settle() {
        television?.reset()
        spectrum.reset()
    }

    /// Finishes sound that `pull` made, where it lies, as it goes to be heard: through the television,
    /// if one is switched on, and past the spectrum analyser. Interleaved stereo.
    public func present(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        gain.apply(samples, frames: frames)
        presented += frames
        television?.process(samples, frames: frames)
        spectrum.add(samples, frames: frames)
    }

    /// Fills `output` with the next `frames` frames of the tune, interleaved stereo, as the chip made
    /// them. Returns false once the tune is over: what is left of the buffer is then silence.
    public func pull(into output: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        var filled = 0
        while filled < frames {
            if blockCursor == blockLength {
                guard let session, !session.finished else { break }
                blockLength = session.render(into: block, frames: Self.blockFrames)
                blockCursor = 0
                if meter != nil {
                    meter?.take(block, frames: blockLength)
                    if session.finished, let meter {
                        setLevel(SongLevel(loudness: meter.loudness, truePeak: meter.truePeak))
                        levelFound = true
                    }
                }
                for voice in 0 ..< min(lights.count, session.channelLevels.count) {
                    lights[voice] = max(lights[voice], UInt8(ChannelLight.brightness(of: session.channelLevels[voice]) * 255))
                    let pitch = session.channelPitches[voice]
                    if pitch > 0 { pitches[voice] = UInt8(max(1, min(255, (pitch * 2).rounded()))) }
                    if session.channelStruck[voice] { struck[voice] = 1 }
                    sides[voice] = UInt8(max(1, min(255, (128 + session.channelSides[voice] * 127).rounded())))
                    sampled[voice] = voice == speaker ? 2 : session.channelsSampled[voice] ? 1 : 0
                }
                // A song heard whole has just said how it ends.
                if session.finished, !following, ending == nil {
                    ending = session.ending
                    endingOf = subsong
                }
                if blockLength == 0 { break }
            }
            let count = min(frames - filled, blockLength - blockCursor)
            (output + filled * 2).update(from: block + blockCursor * 2, count: count * 2)
            filled += count
            blockCursor += count
        }
        if filled < frames {
            (output + filled * 2).update(repeating: 0, count: (frames - filled) * 2)
        }
        return filled == frames || !(session?.finished ?? true)
    }

    /// Gives the song its level, found by measuring it or from what was kept: at once, if hardly
    /// any of it has been heard, and otherwise by a glide from where it is.
    public func setLevel(_ level: SongLevel) {
        self.level = level
        meter = nil
        if presented < outputSampleRate / 10 {
            gain = LevelGain(level.gain(levelling))
        } else {
            gain.glide(to: level.gain(levelling))
        }
    }

    /// True if the song is not to be heard until it is levelled: songs are levelled, and its level
    /// is not known yet.
    public var waitsForLevel: Bool { levelling != .off && level == nil }

    /// Starts the song at about its level, by what has been measured of it so far, when it cannot
    /// wait any longer to be measured whole: at once, if hardly any of it has been heard. Once it
    /// has been measured whole it glides from there to its level.
    public func startAtProvisionalLevel() {
        guard waitsForLevel, presented < outputSampleRate / 10, let meter, meter.frames >= 2 * outputSampleRate else { return }
        gain = LevelGain(SongLevel(loudness: meter.loudness, truePeak: meter.truePeak).gain(levelling))
    }

    public var levelChange: Double {
        guard levelling != .off, let level else { return .nan }
        return level.change(levelling)
    }

    /// Brings `bars` up to date with what has been presented.
    public func analyse() {
        spectrum.analyse()
        bars = (spectrum.levels + spectrum.caps).map { UInt8(max(0, min(255, $0 * 255))) }
    }

    /// Brings `scopes` up to the end of the sound handed out so far: the session has made the rest
    /// of its block too, and that is not heard yet.
    public func takeScopes() {
        guard let session, !scopes.isEmpty else { return }
        let behind = blockLength - blockCursor
        scopes.withUnsafeMutableBufferPointer { session.takeChannelWaves(into: $0.baseAddress!, behind: behind) }
    }

    /// Hands over what is known of the voices for the sound made since they were last taken, in `voicesTaken`.
    public func takeVoices() {
        let count = lights.count
        for voice in 0 ..< count {
            voicesTaken[voice] = lights[voice]
            voicesTaken[count + voice] = pitches[voice]
            voicesTaken[count * 2 + voice] = struck[voice]
            voicesTaken[count * 3 + voice] = sides[voice]
            voicesTaken[count * 4 + voice] = sampled[voice]
            lights[voice] = 0
            pitches[voice] = 0
            struck[voice] = 0
        }
    }

    /// How many of the lights are always shown: the rest are for voices a tune may never use.
    public var lightsAlwaysShown: Int { min(lights.count, renderer?.channelsAlwaysShown ?? 0) }

    public var subsongCount: Int { renderer?.subsongCount ?? 0 }
    public var subsong: Int { renderer?.currentSubsong ?? 0 }
    public var length: Double { session?.displayLength ?? 0 }
    /// False when the file does not say how long the song is, and `length` is only the time it is allowed.
    public var lengthIsKnown: Bool { renderer?.knownLength != nil }
    public var playedLength: Double { session?.playedLength ?? 0 }
    /// For a song that ended because it had fallen silent, or never made a sound: the seconds of
    /// silence it took to be sure. 0 for a song that is still playing or ended any other way.
    public var silenceAtEnd: Double {
        guard let session, session.end == .silent || session.end == .neverSounded else { return 0 }
        return session.silence
    }

    /// Seconds of the song made so far.
    public var position: Double {
        guard let session else { return 0 }
        return Double(session.framesRendered - (blockLength - blockCursor)) / Double(outputSampleRate)
    }

    /// 0 while a tune is playing, 1 when it has run its course, 2 when it fell silent, 3 when it never made a sound.
    public var state: Int {
        switch session?.end {
        case .playing?: 0
        case .completed?: 1
        case .silent?: 2
        case .neverSounded?: 3
        case nil: -1
        }
    }
}
