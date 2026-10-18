// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The choices a listener has about how tunes are played, other than what they are heard through
/// (which is `OutputStyle`): the command-line player's options, set out for a front end that has no
/// command line and shows them as a panel of settings instead.
///
/// The value of each is a number. For one chosen from a list it is the place in the list of what is
/// chosen; for one set along a scale it is how far along, from 0 to 100. So a front end can show and
/// keep them all alike, and hand them over as a list of numbers in the order of the cases here.
public enum Setting: Int, CaseIterable, Sendable {
    case songs, shortestSong, loops, fade, defaultTime, maxTime, levelling
    case chip, clock, frameRate, stereoOrder, sbProSeparation
    case sidModel, sidEngine, sidFilter
    case amiga, amigaSeparation, s3mCard
    case agiReplay

    /// One of the things a setting can be chosen to be.
    public struct Choice: Sendable {
        /// What it is kept as from one visit to the next: it stays the same if the list is added to.
        public let code: String
        /// What it is called in the list.
        public let title: String
        /// The number it stands for, where it stands for one: seconds, times, cycles a second.
        public let amount: Double

        init(_ code: String, _ title: String, _ amount: Double = 0) {
            self.code = code
            self.title = title
            self.amount = amount
        }
    }

    public enum Kind: Sendable {
        /// One of a list.
        case choice([Choice])
        /// A place on a scale, from 0 to 100, and what the two ends of it are.
        case scale(low: String, high: String)
    }

    /// The settings are shown in groups, by what they have to do with.
    public enum Group: Int, CaseIterable, Sendable {
        case playing, ay, sid, modules

        public var title: String {
            switch self {
            case .playing: "Playing"
            case .ay: "AY and YM chips"
            case .sid: "SID chip"
            case .modules: "Modules"
            }
        }

        public var settings: [Setting] { Setting.allCases.filter { $0.group == self } }
    }

    public var group: Group {
        switch self {
        case .songs, .shortestSong, .loops, .fade, .defaultTime, .maxTime, .levelling: .playing
        case .chip, .clock, .frameRate, .stereoOrder, .sbProSeparation: .ay
        case .sidModel, .sidEngine, .sidFilter: .sid
        case .amiga, .amigaSeparation, .s3mCard, .agiReplay: .modules
        }
    }

    /// What it is kept under from one visit to the next.
    public var name: String {
        switch self {
        case .songs: "songs"
        case .shortestSong: "shortest-song"
        case .loops: "loops"
        case .fade: "fade"
        case .defaultTime: "default-time"
        case .maxTime: "max-time"
        case .chip: "chip"
        case .clock: "clock"
        case .frameRate: "frame-rate"
        case .stereoOrder: "stereo-order"
        case .sidModel: "sid-model"
        case .sidEngine: "sid-engine"
        case .sidFilter: "sid-filter-curve"
        case .amiga: "amiga"
        case .amigaSeparation: "amiga-separation"
        case .s3mCard: "s3m-card"
        case .sbProSeparation: "sb-pro-separation"
        case .agiReplay: "agi"
        case .levelling: "level"
        }
    }

    public var title: String {
        switch self {
        case .songs: "A file's songs"
        case .shortestSong: "Pass over songs"
        case .loops: "A tune that repeats is played"
        case .fade: "Fade out over"
        case .defaultTime: "A tune of unknown length gets"
        case .maxTime: "No tune plays longer than"
        case .chip: "Chip"
        case .clock: "Clock"
        case .frameRate: "Player runs"
        case .stereoOrder: "In stereo"
        case .sidModel: "Model"
        case .sidEngine: "Emulation"
        case .sidFilter: "6581 filter"
        case .amiga: "Amiga"
        case .amigaSeparation: "Amiga left and right"
        case .s3mCard: "S3M sound card"
        case .sbProSeparation: "Sound Blaster Pro, CMS and stereo POKEY left and right"
        case .levelling: "Loudness"
        case .agiReplay: "Sierra's adventure games"
        }
    }

    /// What it does, in a sentence or two: for whoever is wondering whether to change it.
    public var about: String {
        switch self {
        case .songs:
            "A file can hold several songs. They can all be played, one after another, or only the one the file names as its main song. Either way, any of them can be picked by hand."
        case .shortestSong:
            "Many files keep sound effects and jingles beside their music. When a file's songs are played in turn, those shorter than this are passed over. They stay in the list of songs, to be picked by hand, and a file with nothing longer in it plays them all."
        case .loops:
            "Most of this music goes round for ever. This is how many times a tune is played through before it fades out."
        case .fade:
            "How long a tune that is still playing where it ends takes to fade out: never longer than the tune itself. A tune that comes to an end of its own is not faded."
        case .defaultTime:
            "How long a tune is played when nothing says how long it is: its file does not, and it neither stops nor is found to repeat."
        case .maxTime:
            "A limit on how long any one tune is played, whatever its own length."
        case .chip:
            "The sound chip came in two makes. The AY-3-8910 was in the ZX Spectrum and the Amstrad CPC, the YM2149 in the Atari ST; their steps of loudness are spaced differently, and the YM's envelopes rise and fall more smoothly. A file may say which its tune was written on; one that does not is played on an AY."
        case .clock:
            "How fast the chip is driven, which sets the pitch of everything it plays. Each computer drove it at a speed of its own, and a tune played at another's comes out higher or lower."
        case .frameRate:
            "How many times a second the tune's own player is run, which sets how fast the tune goes. Fifty for most computers; a Pentagon ran a little slower."
        case .stereoOrder:
            "Where the chip's three channels are put when a tune is heard in stereo. Computers were wired one way round or the other, and a tune made on one has its parts on the wrong sides on the other. It makes no difference in mono or through a television."
        case .sidModel:
            "The SID chip came in two models. The older 6581 has a darker, grittier filter and the 8580 a cleaner one. A tune was written for one of them, and usually says which."
        case .sidEngine:
            "How the SID chip is imitated. reSIDfp is the more faithful, above all to the 6581's filter. reSID is half the work, and its 6581 filter is drier."
        case .sidFilter:
            "Where the 6581's filter sits. No two of the real chips were alike in this, and they differed by as much as this goes. It is something only reSIDfp has."
        case .amiga:
            "Which Amiga a module made for one is heard on: a MOD, MED, AHX, SoundFX or Oktalyzer file, or a Sierra game's sound as the Amiga played it. The 500 has a filter in the way that takes off the top of the sound, above 4.4 kHz: the darker sound that much Amiga music was written on."
        case .amigaSeparation:
            "How far apart the left and right of a module made for the Amiga are kept: a MOD, MED, AHX, SoundFX or Oktalyzer file, or a Sierra game's sound as the Amiga played it. An Amiga put each of its four voices hard to one side, which is harsh in headphones. It makes no difference in mono or through a television."
        case .s3mCard:
            "The sound card an S3M file is played on: a Gravis Ultrasound, or a Sound Blaster Pro with its eight bits at 22 kHz. A file says which it was saved with; one that does not is given the Ultrasound."
        case .sbProSeparation:
            "How far apart the left and right of a recording from the first Sound Blaster Pro or the Creative Music System are kept (a VGM file of their chips), and of an 8-bit Atari tune for two POKEYs. The Sound Blaster Pro had one FM chip on each side and nothing of either on the other, the Atari's stereo upgrade one POKEY on each side, and the Creative Music System's music puts most of its voices on one side or the other: that is harsh in headphones. It makes no difference in mono or through a television."
        case .agiReplay:
            "The music of Sierra's adventure games of the 1980s, King's Quest to Manhunter (an AGI file), was written for the three-voice chip of IBM's PCjr and the Tandy 1000, and the Amiga versions of the games played it with routines of their own. The first plays every tone as a square wave, held at the note's volume; the later one plays it as a rounder wave that dies away over each note's first second. Which games had which is not known: Wanted Team's player of these files, by which they are heard on the Amiga today, plays the first unless told otherwise."
        case .levelling:
            "A tune is heard as loud as its file has it, so one written quiet is heard quiet. Levelled, each song is turned up or down to be as loud as the rest; halfway, it is moved half as far, and a quiet tune is still quieter than a loud one, but not by as much. No song is turned up by more than 6 dB. A song is measured the first time it is played: it waits up to a second to be, starts at about its level by what has been measured of it if that is not enough, and glides to its level once the whole of it has been. Its level is kept in this browser for the next time."
        }
    }

    public var kind: Kind {
        switch self {
        case .songs:
            .choice([Choice("all", "are all played, in turn"), Choice("main", "only the main one is played")])
        case .shortestSong:
            .choice([Choice("0", "never"), Choice("2", "shorter than 2 seconds", 2), Choice("5", "shorter than 5 seconds", 5),
                     Choice("10", "shorter than 10 seconds", 10), Choice("20", "shorter than 20 seconds", 20),
                     Choice("30", "shorter than 30 seconds", 30), Choice("60", "shorter than a minute", 60)])
        case .loops:
            .choice([Choice("1", "once", 1), Choice("2", "twice", 2), Choice("3", "3 times", 3), Choice("4", "4 times", 4), Choice("5", "5 times", 5)])
        case .fade:
            .choice([Choice("0", "no time at all", 0), Choice("5", "5 seconds", 5), Choice("10", "10 seconds", 10), Choice("20", "20 seconds", 20),
                     Choice("30", "30 seconds", 30), Choice("60", "a minute", 60)])
        case .defaultTime:
            .choice([Choice("60", "1:00", 60), Choice("120", "2:00", 120), Choice("180", "3:00", 180), Choice("240", "4:00", 240),
                     Choice("300", "5:00", 300), Choice("480", "8:00", 480), Choice("600", "10:00", 600)])
        case .maxTime:
            .choice([Choice("0", "its own length"), Choice("60", "1:00", 60), Choice("120", "2:00", 120), Choice("180", "3:00", 180),
                     Choice("300", "5:00", 300), Choice("600", "10:00", 600), Choice("900", "15:00", 900), Choice("1800", "30:00", 1800)])
        case .chip:
            .choice([Choice("auto", "As the file says"), Choice("ay", "AY-3-8910"), Choice("ym", "YM2149")])
        case .clock:
            .choice([Choice("auto", "As the file says"), Choice("1773400", "ZX Spectrum, 1.7734 MHz", 1_773_400),
                     Choice("1750000", "Pentagon, 1.75 MHz", 1_750_000), Choice("1000000", "Amstrad CPC, 1 MHz", 1_000_000),
                     Choice("2000000", "Atari ST, 2 MHz", 2_000_000)])
        case .frameRate:
            .choice([Choice("auto", "As the file says"), Choice("50", "50 times a second", 50),
                     Choice("48.83", "48.8 times a second (Pentagon)", 48.828125), Choice("60", "60 times a second", 60)])
        case .stereoOrder:
            .choice([Choice("abc", "A left, B centre, C right"), Choice("acb", "A left, C centre, B right")])
        case .sidModel:
            .choice([Choice("auto", "As the tune asks"), Choice("6581", "6581"), Choice("8580", "8580")])
        case .sidEngine:
            .choice([Choice("residfp", "reSIDfp"), Choice("resid", "reSID 1.0")])
        case .sidFilter:
            .scale(low: "bright", high: "dark")
        case .amiga:
            .choice([Choice("a1200", "Amiga 1200"), Choice("a500", "Amiga 500")])
        case .amigaSeparation, .sbProSeparation:
            .scale(low: "together", high: "apart")
        case .s3mCard:
            .choice([Choice("auto", "As the file says"), Choice("gus", "Gravis Ultrasound"), Choice("sb", "Sound Blaster Pro")])
        case .agiReplay:
            .choice([Choice("amiga", "Amiga, Sierra's first routine"), Choice("amiga-later", "Amiga, Sierra's later routine"),
                     Choice("pc", "PCjr and Tandy 1000")])
        case .levelling:
            .choice([Choice("off", "as each file has it"), Choice("full", "levelled, every song alike"), Choice("partial", "levelled halfway")])
        }
    }

    /// What it is until it is changed: what the command-line player does when it is told nothing,
    /// but for the songs of a file, which a page that lists them plays in turn.
    public var standard: Double {
        switch self {
        case .shortestSong: 2
        case .fade: 3
        case .defaultTime: 2
        case .sidFilter: 50
        case .amigaSeparation, .sbProSeparation: 20
        case .songs, .loops, .maxTime, .chip, .clock, .frameRate, .stereoOrder, .sidModel, .sidEngine, .amiga, .s3mCard, .levelling, .agiReplay: 0
        }
    }

    /// Every setting as it is until it is changed, in the order of the cases.
    public static var standards: [Double] { allCases.map { $0.standard } }

    /// A value made one that the setting can have: a place in its list, or a place on its scale.
    public func settled(_ value: Double) -> Double {
        switch kind {
        case .choice(let choices): Double(max(0, min(choices.count - 1, Int(value.isFinite ? value : standard))))
        case .scale: max(0, min(100, value.isFinite ? value : standard))
        }
    }

    /// The number a value of it stands for: what is chosen, where it is chosen from a list (seconds,
    /// times, cycles a second; nought where what is chosen is not a number), and otherwise the place
    /// on its scale.
    public func amount(of value: Double) -> Double {
        switch kind {
        case .choice(let choices): choices[Int(settled(value))].amount
        case .scale: settled(value)
        }
    }

    /// True if changing it changes the sound of a tune of this kind, or how long it is played, so
    /// that a tune which is playing has to be made again.
    /// - Parameter renderer: the tune itself, if it has been loaded. A kind of file is not always
    ///   one kind of tune: only the tune can say whether it is played on an Amiga.
    public func changes(_ format: TuneFormat, played renderer: (any Renderer)? = nil) -> Bool {
        switch self {
        // (A song is levelled as it is heard, and not made otherwise for it.)
        case .songs, .shortestSong, .levelling: false
        // (Which way round stereo is matters only to a tune that is being heard in stereo: whoever
        // knows what tunes are heard through says whether it does. See `stereo(for:_:)`.)
        case .stereoOrder: false
        case .loops, .fade, .defaultTime, .maxTime: true
        case .chip, .clock, .frameRate:
            switch format {
            case .sid, .sndh, .mod, .med, .ahx, .hvl, .xm, .s3m, .it, .cmf, .rol, .fmt: false
            case .mtm, .dtm, .amf: false
            case .gdm, .ptm, .ult, .c67: false
            case .mptm: false
            case .mt2: false
            case .sfx, .okt: false
            case .composer669, .stm, .stx, .far, .dbm: false
            case .mdl: false
            case .symmod: false
            case .j2b: false
            case .dmf: false
            case .imf, .ams: false
            case .plm: false
            case .dsm, .masi: false
            case .digi: false
            case .vgm: false
            case .sap: false
            case .agi: false
            case .mfp: false
            case .tfmx, .hip, .fc: false
            case .puma, .pap, .gmc, .ims: false
            default: true
            }
        case .sidModel, .sidEngine, .sidFilter: format == .sid
        case .amiga, .amigaSeparation: renderer?.isPlayedOnAnAmiga ?? (format == .mod || format == .med || format == .ahx || format == .sfx || format == .okt || format == .agi || format == .mfp || format == .tfmx || format == .hip || format == .fc || format == .puma || format == .pap || format == .gmc || format == .ims)
        case .s3mCard: format == .s3m
        case .sbProSeparation: format == .vgm || format == .sap
        case .agiReplay: format == .agi
        }
    }

    /// How the AY chip's channels are placed for what tunes are heard through, with the settings as
    /// they are: as the output style says, but that where it says stereo and no more, the settings
    /// say which way round. (That is for a front end which lists stereo once, and has the way round
    /// among its settings; one that lists both ways round has no need to ask.)
    public static func stereo(for style: OutputStyle, _ values: [Double]) -> StereoLayout {
        guard style == .abc, values.indices.contains(stereoOrder.rawValue) else { return style.stereo }
        return stereoOrder.settled(values[stereoOrder.rawValue]) == 1 ? .acb : .abc
    }

    /// How far songs are brought to the same loudness, with the settings as they are.
    public static func levelling(_ values: [Double]) -> Levelling {
        let place = values.indices.contains(levelling.rawValue) ? Int(levelling.settled(values[levelling.rawValue])) : 0
        return ([.off, .full, .partial] as [Levelling])[place]
    }

    /// Puts a whole list of values, one for each setting in the order of the cases, into the two
    /// things the player goes by. A list that is short leaves the rest as they are until changed.
    public static func apply(_ values: [Double], to options: inout LoadOptions, _ policy: inout PlaybackPolicy) {
        func value(_ setting: Setting) -> Double {
            setting.settled(values.indices.contains(setting.rawValue) ? values[setting.rawValue] : setting.standard)
        }
        func place(_ setting: Setting) -> Int { Int(value(setting)) }
        func amount(_ setting: Setting) -> Double { setting.amount(of: value(setting)) }
        /// (Nothing for the first in the list, which is to leave it to the file.)
        func amountIfChosen(_ setting: Setting) -> Double? { place(setting) == 0 ? nil : amount(setting) }

        policy.allSubsongs = place(.songs) == 0
        policy.shortestSong = amount(.shortestSong)
        policy.loops = max(1, Int(amount(.loops)))
        policy.loopFade = amount(.fade)
        policy.defaultTime = amount(.defaultTime)
        policy.maxTime = amountIfChosen(.maxTime)

        options.chipType = ([nil, .ay, .ym] as [AYChipType?])[place(.chip)]
        options.clockHz = amountIfChosen(.clock)
        options.frameHz = amountIfChosen(.frameRate)
        options.sidModel = ([.auto, .mos6581, .mos8580] as [SIDModelChoice])[place(.sidModel)]
        options.sidEngine = ([.residfp, .resid] as [SIDEngineChoice])[place(.sidEngine)]
        options.sidFilterCurve = value(.sidFilter) / 100
        options.amigaModel = ([.a1200, .a500] as [AmigaModel])[place(.amiga)]
        options.amigaSeparation = value(.amigaSeparation) / 100
        options.s3mCard = ([nil, .gus, .sb] as [ST3Card?])[place(.s3mCard)]
        options.sbProSeparation = value(.sbProSeparation) / 100
        options.agiReplay = ([.amiga, .amigaLater, .pc] as [AGIReplay])[place(.agiReplay)]
    }
}
