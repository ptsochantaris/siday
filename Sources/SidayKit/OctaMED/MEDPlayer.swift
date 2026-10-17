// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday. What OctaMED's own players do was learned by running them, in an emulated Amiga,
// beside this one and comparing what each told the sound chip, tick by tick, or what each mixed for
// it, byte by byte, and by reading how they go about it where the two disagreed. None of their code
// is here. The table of periods is built from ProTracker's, which is from pt2-clone, Copyright (c)
// Olav Sørensen, used under the BSD 3-Clause licence (see THIRD-PARTY.md).

/// What the player told the sound chip in one tick: for setting beside what OctaMED's own player
/// tells it, which is how this one is checked.
public struct MEDRegisterTick: Sendable {
    /// A place in the module's samples, and a length in words from there.
    public struct Stretch: Sendable {
        /// Which instrument's sample, counting from 1, or nought for none of them.
        public var instrument: Int
        public var offset: Int
        public var words: Int
    }

    /// A waveform of a synthetic sound: where it is in the file, and its length in words.
    public struct Waveform: Sendable {
        public var place: Int
        public var words: Int
    }

    public struct Voice: Sendable {
        public var period: Int?
        public var volume: Int?
        /// A note begun on this tick: where the chip was told to play from, and how far.
        public var start: Stretch?
        /// And where it was told to go on from after that.
        public var loop: Stretch?
        /// The waveform a synthetic sound changed to on this tick.
        public var waveform: Waveform?
    }

    public var voices = [Voice](repeating: Voice(), count: 4)
    /// In five-to-eight channel mode: what was mixed on this tick for each voice that has two
    /// tracks, a byte for each sample the chip is to play (empty for a voice with one track), and
    /// how many words of it the chip was told to play.
    public var mixed = [[Int8]](repeating: [], count: 4)
    public var mixedWords = 0
    /// How long the tick lasted, in the colour clocks the sound chip counts.
    public var clocks = 0
    /// Where the tune was: the block and the line whose commands were carried out, and which tick
    /// of the line it was.
    public var block = 0
    public var line = 0
    public var tickOfLine = 0
}

/// The player for OctaMED modules that use the Amiga's four voices as they are: what OctaMED did,
/// each time its timer fired, to turn a module's blocks into what it told Paula.
///
/// A line of a block lasts so many ticks. On the first of them the line's notes are read and
/// started, and its commands are gone through twice: once before the notes, for those that say how
/// a note is to be played or where the tune goes next, and then on every tick of the line, for
/// those that bend a note while it sounds. After the commands, each voice is told its period and
/// its volume again, whether or not they have changed.
///
/// An instrument need not be a sample. A synthetic sound is a handful of short waveforms and two
/// lists of instructions, one for its volume and one for its waveform and pitch, which are carried
/// on by a step or so on every tick for as long as its note sounds: that is where its movement
/// comes from. A hybrid sound is such a pair of lists played on a sample.
///
/// In five-to-eight channel mode there are more tracks than voices, and OctaMED mixed them in pairs:
/// the first track with the fifth, the second with the sixth, and so on, each pair into a stretch
/// of memory that one voice then played. It mixed a tick's worth at a time, and the length of that
/// stretch was the tempo: the voice finishing it was what called the player for the next tick. The
/// mixing is crude, as it had to be on that machine, and is done here in the same way, so that it
/// sounds as it did: samples are stepped through without smoothing, the two are added with nothing
/// to stop them overflowing, and a sample that would end part of the way through a tick is not
/// begun on that tick at all. A pair has one volume between its two tracks.
///
/// In mixing mode, which came last, there are as many tracks as the song likes, up to 64, and all
/// of them are mixed (see `MEDMixer`). The player is the same player, but that it reckons a track's
/// pitch in samples a second where the others reckon it in periods of the sound chip's clock: so
/// the table of periods is a table of rates, and a slide, which is still written as so many
/// periods, is worked out by going from the rate to a period and back.
///
/// It does as OctaMED's player does where that is odd, too, since tunes were written by ear against it.
struct MEDPlayer: ~Copyable {
    /// The timer that keeps the tempo counts cycles of a clock a fifth as fast as the sound chip's.
    static let clocksPerTimerCount = 5
    /// The sound chip's clock, in whole cycles a second.
    static let chipClock = Int(Paula.clockHz)
    /// The longest a tick can be, in the sound chip's clocks: the timer counting all it can, four times.
    static let longestTick = 4 * 65536 * clocksPerTimerCount

    /// What a tempo is divided into for the timer: for a tempo as such, and for beats a minute.
    private static let tempoTimer = 470_000, beatTimer = 1_773_447
    /// The timer for the tempos up to ten, which stand for the speeds of the older trackers.
    private static let slowTimers: [Int] = [2417, 4833, 7250, 9666, 12083, 14500, 16916, 19332, 21436, 24163]

    /// For a sample recorded at several octaves: which of the recordings each octave of notes is
    /// played from, counting from the shortest, by how many recordings there are (two to seven).
    private static let recordings: [[Int]] = [
        [1, 1, 0, 0, 0, 0], [2, 2, 1, 1, 0, 0], [3, 3, 2, 2, 1, 0], [4, 3, 2, 1, 1, 0], [5, 4, 3, 2, 1, 0], [6, 5, 4, 3, 2, 1],
    ]
    /// And how many octaves below its place on the stave the lowest octave of notes then sounds.
    private static let recordingDepth = [1, 2, 3, 3, 4, 5]

    /// A row of the table of periods has two octaves below ProTracker's three, and three above.
    private static let periodsInRow = 96, lowPeriods = 24
    private static let noMorePages = 0xFFFE

    /// The period of a voice that plays what has been mixed for it, at the better of the two
    /// qualities OctaMED had; and that period times 16,384, which the period of a note is divided
    /// into for how far to step through its sample.
    private static let mixPeriod = 124, mixClock: UInt32 = 124 * 16384
    /// How many words are mixed for a tick at each of the ten tempos of five-to-eight channel mode,
    /// halved; and the same for a module made when the better quality was half as fast.
    private static let mixWords: [Int] = [101, 110, 119, 128, 137, 146, 156, 165, 174, 183]
    private static let slowMixWords: [Int] = [110, 120, 130, 140, 150, 160, 170, 180, 190, 200]

    /// In mixing mode: what a period is divided into for the rate it stands for, and a rate for its
    /// period. (It is the clock of an American Amiga's sound chip, whichever Amiga is played on.)
    private static let rateClock: UInt32 = 3_579_545
    /// The rate of the lowest note at no fine tuning, times 65,536; how much more or less of that
    /// each step of fine tuning is; and the twelfth root of two, times 65,536, which is the next
    /// note's rate over this one's.
    private static let lowestRate = 68_583_572, fineTuneStep = 509_916, semitone: UInt32 = 69433
    /// A row of the table of rates is six octaves. The table has room either side of its rows,
    /// for a note that is off one end or the other.
    private static let ratesInRow = 72, ratesBefore = 128
    /// The divisor of a tick's length, in seconds, when the tempo is not in beats a minute.
    private static let tempoClock = 709_376

    /// What OctaMED keeps for a track in five-to-eight channel mode in place of a voice of the
    /// chip: the registers of a voice it mixes itself.
    private struct Lane {
        /// Where in memory the track's sample has got to; nought when it is playing nothing.
        var place = 0
        var period: UInt16 = 0
        /// Where the sample ends or goes round, and where it goes round to: nought to stop there.
        var end = 0, restart = 0
        /// For a track that has a voice to itself: the lengths the chip is to be given, in words.
        var words: UInt16 = 0, loopWords: UInt16 = 0
        /// For the lights: how far the track's sample swung in what was last mixed.
        var swing: Float = 0
        var struck = false
        /// True for a track that is left out of what is mixed: it plays on, and is not added in.
        var muted = false
    }
    private static let periodCount = 16 * periodsInRow + 256
    /// A synthetic sound's list is given up for the tick after this many instructions, none of
    /// which has waited for the next. (OctaMED's own player would go round such a list for ever.)
    private static let mostInstructions = 512

    /// What a track keeps of the synthetic or hybrid sound it is playing: how far it has got in
    /// each of the sound's two lists, and what they have set.
    ///
    /// A place in a list is kept as OctaMED's player keeps it, one less than which entry is read
    /// next, in a byte that goes round: where a jump lands depends on it.
    private struct Program {
        /// Where the sound's structure is in the file; -1 when the track is playing none.
        var place = -1
        var volumeAt: UInt8 = 0, waveAt: UInt8 = 0
        /// How many ticks until each list is gone on with, and how many ticks apart that is.
        var volumeCount: Int8 = 0, waveCount: Int8 = 0
        var volumeSpeed: UInt8 = 0, waveSpeed: UInt8 = 0
        /// How many more times a list is to be passed over, when it has been told to wait.
        var volumeWait: UInt8 = 0, waveWait: UInt8 = 0
        /// The volume the list has reached, of 64, and how much it is changing by each time.
        var volume: UInt8 = 0
        var volumeSlide: Int8 = 0
        /// A waveform being read as the shape of the volume, a byte each time: where the next byte
        /// is, and where to begin again after the last; -1 for no shape, and for not beginning again.
        var envelope = -1, envelopeRestart = -1
        var envelopeCount: UInt8 = 0
        /// How much the period is changing by each time, and how far that has taken it.
        var pitchSlide: UInt16 = 0, pitchSlid: UInt16 = 0
        /// A run of notes in the waveform list, played in turn, a tick each: where the next is, and
        /// where the run begins. Nought for none.
        var arpeggioAt: UInt8 = 0, arpeggioFrom: UInt8 = 0
        var vibratoDepth: UInt16 = 0, vibratoSpeed: UInt16 = 0, vibratoPlace: UInt16 = 0
        /// The waveform the vibrato follows; -1 for a sine wave.
        var vibratoWave = -1
        /// The note being played, which the notes of an arpeggio are counted from.
        var note: UInt8 = 0
    }

    private struct Track {
        /// The last note written on the track, which arpeggios are counted from, and the note on the
        /// line being played: nought for none.
        var lastNote: UInt8 = 0
        var lineNote: UInt8 = 0
        /// The instrument last named on the track, and what was taken from it then.
        var instrument = 0
        var hasInstrument = false
        var volume: Int8 = 0
        var transpose: Int8 = 0
        var hold: UInt8 = 0, decay: UInt8 = 0
        var fineTune: Int8 = 0
        var outputDevice: UInt8 = 0
        var sampleOffset: UInt16 = 0
        /// True if a command on the line says its note is not to be started with the line.
        var waits = false
        /// How many ticks the note has before it is let go; below nought if it is not being held.
        var holdLeft: Int8 = 0
        /// How fast the note is to fade once let go, and how fast it is fading now.
        var decayOfNote: UInt8 = 0
        var fade: UInt8 = 0

        var period: UInt16 = 0
        /// Where in the table of periods this track's notes are looked up; -1 before its first note.
        var periodTable = -1
        /// Where the voice is to go on from when it has played what it was started with.
        var loopStart = -1
        var loopWords: UInt16 = 0
        var slideTarget: UInt16 = 0
        var slideSpeed: UInt8 = 0
        var vibratoShift: UInt8 = 0, vibratoSpeed: UInt8 = 0, vibratoPlace: UInt8 = 0
        var vibratoDepth: Int16 = 0
        var tremoloSpeed: UInt8 = 0, tremoloPlace: UInt8 = 0
        var tremoloDepth: Int16 = 0
        /// The volume a tremolo wants for this tick; below nought for none.
        var tremoloVolume: Int8 = -1
        /// What vibrato and arpeggio move the period by, for this tick only.
        var bend: UInt16 = 0, arpeggio: UInt16 = 0
        /// The track's own volume and the song's, as one number: 256 for both at their fullest.
        var gain: UInt16 = 0
        var program = Program()
        /// Whether the last note was of a synthetic sound (1), a hybrid (-1), or a sample.
        var soundKind: Int8 = 0
        /// True if a command has said where in its waveform list the next synthetic note is to begin.
        var keepsWavePlace = false
        /// True if a command has said the next note is to be played backwards (in mixing mode).
        var backwards = false
    }

    let module: MEDModule
    var paula: Paula
    var mixer: MEDMixer
    let mode: MEDModule.Mode
    /// How many tracks can be heard: the chip's four voices, or eight tracks mixed into them, or
    /// as many as a song in mixing mode has channels for.
    let channels: Int
    /// Where each track lies between left and right, in mixing mode: a command can move one.
    private var pans: [Int8]
    /// How long a tick lasts: so many of such a part of a second.
    private(set) var tickTime: (count: Int, per: Int) = (1, 50)
    private let song: MEDModule.Song
    private let songIndex: Int
    private let tracks: UnsafeMutablePointer<Track>

    /// True if what a track was last given to play is a sample, or a hybrid, which is one too: not
    /// a synthetic sound, which is made of waveforms drawn in the tracker.
    func playsSample(_ track: Int) -> Bool {
        track < 0 || track >= MEDModule.mostTracks || tracks[track].soundKind <= 0
    }
    private let periods: UnsafeMutablePointer<UInt16>
    private let sine: UnsafeMutablePointer<Int8>
    private let visited: UnsafeMutablePointer<Bool>
    private let lanes: UnsafeMutablePointer<Lane>
    /// The volume of each voice in five-to-eight channel mode, which its two tracks share.
    private var pairVolumes: InlineArray<4, UInt8> = [0, 0, 0, 0]
    /// How many words are mixed for a tick at the tempo as it is now, how many the voices are
    /// playing in this tick, and how many they have been told to play in the next.
    private var mixWordsNow = 0, wordsPlaying = 0, wordsNext = 0
    /// Which of a voice's stretches of memory was last mixed into.
    private var mixBuffer = 0
    /// The instruments' volumes, which a command can change for the rest of the tune.
    private var volumes: [UInt8]

    private var counter: UInt8
    private var ticksPerLine: UInt8
    private var tempoNow = 0
    /// True if a command that changes the tempo is to do nothing, and if OctaMED's other mistakes
    /// in mixing mode are to be made: see `playAsOctaMEDs`.
    private var keepsFirstTempo = false, asOctaMEDs = false
    private var block = 0, line = 0
    private var section = 0, position = 0
    /// The line whose commands are being carried out, which the tune has by then moved on from.
    private var commandBlock = 0, commandLine = 0
    /// Set by a command when the tune is to leave the block after this line: 1 to go on to the next
    /// place in the order, -1 to go to the place it has just been set to.
    private var leaving: Int8 = 0
    private var keepsLine = false
    /// The line to go to next, and one more; nought for the line after this.
    private var lineWanted = 0
    private var loopLine = 0, loopsLeft = 0
    private var delay = 0
    private var starting: UInt16 = 0
    /// Which of the chip's voices are switched on.
    private var sounding: UInt16 = 0
    /// Which page of commands is being carried out on this tick.
    private var pageCount = 0

    /// What the timer counts down from. It takes a new count only as it finishes the old one.
    private var timer = 0
    /// How long the tick just run lasts, in the sound chip's clocks.
    private(set) var tickClocks = 0
    /// True once the tune has told the player to stop.
    private(set) var stopped = false
    private var wrapped = false

    /// Which places in the order of playing have been played, and whether a note has been.
    private(set) var ordersPlayed: [Bool]
    private(set) var playedNote = false
    /// Which of the file's songs first played each line, shared between them and not this player's
    /// to free, and which song this is. See `ModuleSongs`.
    private let firstPlayedBy: UnsafeMutablePointer<UInt8>?
    private let songNumber: UInt8
    private var metEarlierSong = false
    private(set) var ledIntoEarlierSong = false

    /// For the comparison with OctaMED's own player: when this is not nil, each tick is written down.
    var record: MEDRegisterTick?

    /// Where each track's sound is kept for its scope, once it is wanted (`keepWaves`). The chip
    /// keeps a voice's own, and the mixer the tracks of mixing mode; the two tracks that share a
    /// voice in five-to-eight channel mode are kept here, as each was before the two were added.
    private var waves: ChannelWaves?
    /// What each track that shares a voice gave to the stretches mixed for the voice, byte for
    /// byte: the stretch being mixed, which the chip plays on the next tick, and the one it is
    /// playing on this; and how many bytes each has. A slot for each of the eight tracks, the
    /// stretches being mixed first. Only there while the sound is kept.
    private var laneBytes: UnsafeMutablePointer<Int8>?
    private var laneCounts = InlineArray<16, Int>(repeating: 0)
    /// The volume the chip was told for each voice when the stretch it is playing began.
    private var laneVolumes: InlineArray<4, UInt8> = [0, 0, 0, 0]

    /// - Parameters:
    ///   - song: which of the file's songs.
    ///   - place: where in its order of playing to start; nil for where the file says.
    ///   - firstPlayedBy: which of the songs found in this order first played each line.
    ///   - songNumber: which of them this is.
    init(_ module: MEDModule, song index: Int, model: AmigaModel, place: Int? = nil, firstPlayedBy: UnsafeMutablePointer<UInt8>? = nil,
         songNumber: UInt8 = 0) {
        self.module = module
        songIndex = index
        song = module.songs[index]
        self.firstPlayedBy = firstPlayedBy
        self.songNumber = songNumber
        mode = song.mode
        channels = mode == .mixing ? song.channels : (mode == .eightChannel ? 8 : 4)
        pans = song.trackPans
        lanes = .allocate(capacity: 8)
        lanes.initialize(repeating: Lane(), count: 8)
        // (Only a song in mixing mode has any use for the mixer: another is given one of no size.)
        let mixes = song.mode == .mixing
        mixer = MEDMixer(memory: UnsafePointer(module.memory), size: module.silence, rate: outputSampleRate, channels: mixes ? song.channels : 1,
                         stereo: song.stereo, freePan: song.freePan, volumeAdjust: song.volumeAdjust, echo: mixes ? song.echo : 0,
                         echoDepth: song.echoDepth, echoMilliseconds: song.echoLength, separation: song.separation)
        paula = Paula(rate: Double(outputSampleRate * 2), model: model, memory: UnsafePointer(module.memory), size: module.memorySize,
                      silence: module.silence)
        volumes = song.instruments.map { $0.volume }
        ordersPlayed = [Bool](repeating: false, count: max(1, song.places.count))
        visited = .allocate(capacity: max(1, song.rowsInAll))
        visited.initialize(repeating: false, count: max(1, song.rowsInAll))

        // The periods. Each fine tuning has a row: ProTracker's three octaves, the highest of them
        // three times more for the notes above, and below them two octaves that ProTracker has not
        // got. Those two are ProTracker's own, four times and twice as long, for a sample that is
        // not tuned; for one that is, each note is a twelfth root of two from the last, and the
        // rounding makes those a little different. (And one row begins from 3588, where the rule
        // would have had 3600.) The rows lie one after another, in ProTracker's order, because a
        // note beyond the end of one is read from the start of the next.
        periods = .allocate(capacity: Self.periodCount)
        periods.initialize(repeating: 0, count: Self.periodCount)
        for row in 0 ..< 16 {
            let at = row * Self.periodsInRow
            let top = Int(proTrackerPeriods[row * 37])
            for note in 0 ..< Self.lowPeriods {
                if row == 0 {
                    periods[at + note] = UInt16(Int(proTrackerPeriods[note % 12]) * (note < 12 ? 4 : 2))
                } else {
                    let lowest = row == 9 ? 3588.0 : Double(top * 4)
                    periods[at + note] = UInt16(lowest * exp(-Double(note) * log(2.0) / 12.0) + 0.5)
                }
            }
            for note in 0 ..< 72 {
                periods[at + Self.lowPeriods + note] = UInt16(proTrackerPeriods[row * 37 + (note < 36 ? note : 24 + note % 12)])
            }
        }
        if song.mode == .mixing {
            // In mixing mode the table is of rates: for each fine tuning, lowest first, six octaves
            // from the lowest note, each note the last one's rate times the twelfth root of two,
            // worked out in whole numbers as OctaMED worked it out (the top of the highest rows
            // runs out of bits, there as here).
            periods.update(repeating: 0, count: Self.periodCount)
            for row in 0 ..< 16 {
                var rate = UInt32(truncatingIfNeeded: Self.lowestRate + (row - 8) * Self.fineTuneStep)
                for note in 0 ..< Self.ratesInRow {
                    periods[Self.ratesBefore + row * Self.ratesInRow + note] = UInt16(rate >> 16)
                    rate = (rate >> 16) &* Self.semitone &+ (((rate & 0xFFFF) &* Self.semitone) >> 16)
                }
            }
        }
        // One turn of a sine wave, 127 high, for vibrato and tremolo.
        sine = .allocate(capacity: 32)
        for i in 0 ..< 32 { sine[i] = Int8((127.0 * sin(Double(i) * Double.pi / 16.0)).rounded()) }

        // The track volumes and the song's own are those of the file's first song, whichever is played.
        tracks = .allocate(capacity: MEDModule.mostTracks)
        tracks.initialize(repeating: Track(), count: MEDModule.mostTracks)
        let first = module.songs[0]
        let master = UInt16(bitPattern: Int16(Int8(bitPattern: first.masterVolume)))
        for track in 0 ..< min(first.trackVolumes.count, MEDModule.mostTracks) {
            let volume = UInt16(bitPattern: Int16(Int8(bitPattern: first.trackVolumes[track])))
            tracks[track].gain = (master &* volume) >> 4
        }

        ticksPerLine = UInt8(truncatingIfNeeded: song.ticksPerLine)
        counter = ticksPerLine
        if let place, place < song.places.count {
            section = song.places[place].section
            position = song.places[place].position
        } else {
            section = song.firstSection
        }
        let sequence = song.sequences[song.sections[section]]
        let opening = position < sequence.count ? Int(sequence[position]) : 0
        block = opening < song.blocks.count ? opening : 0
        paula.setLightFilter(song.filterOn)
        setTempo(song.tempo)
        if mode == .eightChannel {
            // The voices that play what is mixed are set going at once, on a stretch of silence.
            wordsPlaying = mixWordsNow
            wordsNext = mixWordsNow
            for voice in 0 ..< 4 where song.mixed[voice] {
                paula.setLocation(voice, mixPlace(voice, 0))
                paula.setLength(voice, UInt16(mixWordsNow))
                paula.setPeriod(voice, UInt16(Self.mixPeriod))
                paula.setVolume(voice, 64)
                paula.start(voices: 1 << voice)
            }
        }
    }

    deinit {
        lanes.deallocate()
        tracks.deallocate()
        periods.deallocate()
        sine.deallocate()
        visited.deallocate()
        laneBytes?.deallocate()
    }

    // MARK: The sound chip

    /// A place in the module's memory and a length from there, as the record of a tick has them.
    private func stretch(from place: Int, words: UInt16) -> MEDRegisterTick.Stretch {
        let found = module.instrument(at: place, song: songIndex)
        return MEDRegisterTick.Stretch(instrument: found.number, offset: found.offset, words: Int(words))
    }

    private mutating func stop(_ voice: Int) {
        paula.stop(voices: 1 << voice)
        sounding &= ~(1 << voice)
    }

    // MARK: Tempo

    /// Sets the timer for a tempo. In beats a minute it is the lines of a beat that are counted,
    /// and the timer fires four times for each tick.
    private mutating func setTempo(_ tempo: Int) {
        guard !keepsFirstTempo else { return }
        tempoNow = tempo
        if mode == .mixing {
            // In mixing mode a tick is a length of sound and not a count of a timer: ten seconds
            // over the lines there are in a minute's beats, or the tempo's old count in a clock of
            // its own. (A tempo below eight is too slow for that count to hold, and what is left
            // of it is a tempo of 42.)
            if song.beatsPerMinute {
                let lines = (tempo & 0xFFFF) * song.linesPerBeat
                if lines != 0 { tickTime = (10, lines) }
            } else if tempo & 0xFFFF != 0 {
                let count = Self.tempoTimer / (tempo & 0xFFFF)
                tickTime = (count > 0xFFFF ? Self.tempoTimer & 0xFFFF : count, Self.tempoClock)
            }
            return
        }
        if mode == .eightChannel {
            // Ten tempos, the first the fastest, and anything else is the tenth.
            let slot = tempo >= 1 && tempo <= 9 ? tempo - 1 : 9
            mixWordsNow = (song.flags & 0x80 != 0 ? Self.slowMixWords[slot] : Self.mixWords[slot]) * 2
            return
        }
        if song.beatsPerMinute {
            let lines = (tempo &* song.linesPerBeat) & 0xFFFF
            guard lines != 0 else { return }
            // A count too long for the timer is not divided at all, and its lower half is what is set.
            let count = Self.beatTimer / lines
            timer = count > 0xFFFF ? Self.beatTimer & 0xFFFF : count
        } else if tempo > 10 {
            timer = Self.tempoTimer / (tempo & 0xFFFF)
        } else if tempo >= 1 {
            timer = Self.slowTimers[tempo - 1]
        } else {
            // No tempo at all. OctaMED's player sets the timer from whatever lies before its table;
            // here it is left as it is, or at the usual fifty ticks a second.
            if timer == 0 { timer = Self.tempoTimer / 33 }
        }
    }

    // MARK: Notes

    /// Where a fine tuning's periods begin in the table, at the lowest note of an ordinary sample.
    private static func row(ofFineTune fineTune: Int8) -> Int {
        (fineTune >= 0 ? Int(fineTune) : 16 + Int(fineTune)) * periodsInRow + lowPeriods
    }

    /// Where a fine tuning's rates begin in the table of rates that mixing mode has.
    private static func rates(ofFineTune fineTune: Int8) -> Int {
        ratesBefore + (Int(fineTune) + 8) * ratesInRow
    }

    /// One of a rate and a period for the other, as OctaMED divides for it: in sixteen bits, and a
    /// result too large for them is what was left of the clock.
    private static func turned(_ value: UInt16) -> UInt16 {
        let whole = rateClock / UInt32(value)
        return UInt16(truncatingIfNeeded: whole > 0xFFFF ? rateClock : whole)
    }

    private static func words(_ bytes: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: UInt32(truncatingIfNeeded: bytes) >> 1)
    }

    /// Starts a note on a track: points the voice at the sample and works out the note's period.
    /// The voice itself is set going at the end of the tick, with any others that begin on it.
    /// - Returns: what is left where OctaMED's player keeps its count of pages of commands, which
    ///   starting a note writes over; -1 if it is left alone. See `runTick`.
    @discardableResult private mutating func strike(_ t: Int, _ note: UInt8) -> Int {
        if mode == .eightChannel {
            // A note on a track that has had no instrument named is played, in this mode, on the
            // first instrument. (OctaMED's player then took how to transpose it and where it
            // repeats from the very bottom of the Amiga's memory, which is not the module's to
            // say: here it is not transposed and does not repeat.)
            var instrument = song.instruments[tracks[t].instrument]
            guard instrument.kind != .absent else { return 0 }
            if !tracks[t].hasInstrument {
                instrument.transpose = 0
                instrument.shortRepeatStart = 0
                instrument.shortRepeatWords = 0
            }
            return strikeMixed(t, note, instrument)
        }
        guard tracks[t].hasInstrument else { return -1 }
        let number = tracks[t].instrument
        let instrument = song.instruments[number]
        guard instrument.kind != .absent else { return 0 }
        if mode == .mixing { return strikeInMixing(t, note, instrument) }
        var n = Int8(bitPattern: note) &+ song.transpose &+ instrument.transpose
        // An instrument for a sound card is not for these voices, and leaves them be. (What is left
        // in the count is then part of where the instrument is in the Amiga's memory, which is
        // anybody's guess: it is taken to be more than any number of pages.)
        guard tracks[t].outputDevice == 0 else { return Self.noMorePages }
        if t < 4 {
            // A synthetic sound that follows another is not cut off: the voice plays on, and takes
            // up the new sound's waveform when it comes to the end of the one it is playing.
            if tracks[t].soundKind <= 0 || instrument.kind != .synthetic { stop(t) }
            tracks[t].program.place = -1
        }
        n &-= 1
        guard t < 4 else { return Self.noMorePages }
        tracks[t].fade = 0
        tracks[t].decayOfNote = tracks[t].decay
        tracks[t].vibratoPlace = 0
        tracks[t].tremoloPlace = 0
        starting |= 1 << t

        if instrument.kind == .synthetic {
            // No sample to point the voice at: the sound's waveform list does that. Its notes are
            // looked up two octaves lower than a sample's, and none is too low or too high to be.
            let table = Self.row(ofFineTune: tracks[t].fineTune) - Self.lowPeriods
            tracks[t].soundKind = 1
            tracks[t].program.note = UInt8(bitPattern: n)
            tracks[t].period = periods[table + Int(UInt8(bitPattern: n))]
            tracks[t].periodTable = table
            tracks[t].loopStart = -1
            beginProgram(t, instrument.program)
            playedNote = true
            return Self.noMorePages
        }
        tracks[t].soundKind = instrument.isHybrid ? -1 : 0
        tracks[t].program.note = UInt8(bitPattern: n)

        // A note too low or too high for the table is brought an octave nearer: as many as it takes
        // from below, but one only from above.
        while n < 0 { n &+= 12 }
        if n > 62 { n &-= 12 }
        let index = Int(n)

        var start = instrument.offset
        // A stereo sample's left half is for the voices on the left, and its right for the others.
        if instrument.stereo, t == 1 || t == 2 { start &+= instrument.length }
        var length = instrument.length
        var repeatStart = instrument.repeatStart, repeatLength = instrument.repeatLength
        var table = Self.row(ofFineTune: tracks[t].fineTune)
        let period: UInt16
        switch instrument.kind {
        case .sample:
            period = periods[table + index]
        case .extended:
            table -= Self.lowPeriods
            period = periods[table + index]
        case .octaves(let count):
            // The recordings lie shortest first, each twice the length of the one before, so the
            // shortest is the whole length over one less than a power of two: as far as sixteen
            // bits can say.
            let octave = min(index / 12, 5)
            let which = Self.recordings[count - 2][octave]
            let all = (1 << count) - 1
            let shortest = (length / all > 0xFFFF ? length : length / all) & 0xFFFF
            start &+= shortest * ((1 << which) - 1)
            length = shortest << which
            repeatStart <<= which
            repeatLength <<= which
            let octaveOfTable = min(octave, count == 2 ? 4 : 5) - Self.recordingDepth[count - 2] + which
            period = periods[table + octaveOfTable * 12 + index % 12]
        default:
            // A sound this player does not make.
            starting &= ~(1 << t)
            return Self.noMorePages
        }
        playedNote = true

        // (Added so as to go round, and not to stop the player, when a damaged file's numbers are
        // more than a whole number in a browser can hold.)
        let loopStart = start &+ repeatStart
        let loopEnd = repeatLength > 2 ? loopStart &+ repeatLength : 0
        let end = start &+ length
        // A sample offset that is past the end of the sample is not taken.
        var begin = start &+ Int(tracks[t].sampleOffset)
        if end <= begin { begin = start }

        let first: UInt16
        if instrument.loops, loopEnd != 0 {
            tracks[t].loopStart = loopStart
            tracks[t].loopWords = Self.words(loopEnd &- loopStart)
            first = module.playsThroughBuffers ? UInt16(clamping: max(0, loopEnd &- begin) >> 1) : Self.words(loopEnd &- begin)
        } else {
            tracks[t].loopStart = module.silence
            tracks[t].loopWords = 1
            first = module.playsThroughBuffers ? UInt16(clamping: max(0, end &- begin) >> 1) : Self.words(end &- begin)
        }
        paula.setLocation(t, begin)
        paula.setLength(t, first)
        if record != nil { record!.voices[t].start = stretch(from: begin, words: first) }
        tracks[t].period = period
        tracks[t].periodTable = table
        if instrument.isHybrid { beginProgram(t, instrument.program) }
        return Int(period)
    }

    /// Has the player, in mixing mode, make the three mistakes of OctaMED's own that it otherwise
    /// puts right, so that the two can be set side by side and be the same. The player OctaMED
    /// gave out for mixing mode plays each track's first tick at no volume at all (having left
    /// the volume that a tremolo would set at nought, where its other players start it at none),
    /// which takes the front off a tune's first notes. It takes no notice of a command that
    /// changes the tempo: it works the tempo out again, from the tempo the song began with. And it
    /// plays an instrument meant for a sound card a semitone sharp (see `strikeInMixing`).
    mutating func playAsOctaMEDs() {
        guard mode == .mixing else { return }
        asOctaMEDs = true
        keepsFirstTempo = true
        for t in 0 ..< MEDModule.mostTracks { tracks[t].tremoloVolume = 0 }
    }

    /// Starts a note on a track in mixing mode: gives the mixer its sample, and looks up its rate.
    ///
    /// No note is too low or too high here: one off either end of its row of the table is read
    /// from the row before or after. A sample recorded at several octaves is played as if it were
    /// one sample, which is all this mode knows of.
    private mutating func strikeInMixing(_ t: Int, _ note: UInt8, _ instrument: MEDModule.Instrument) -> Int {
        var n = Int8(bitPattern: note) &+ song.transpose &+ instrument.transpose
        // An instrument for a sound card is played with the rest, as the mixing is all there is.
        // (OctaMED's own player then plays it a semitone sharp, having forgotten to count its
        // notes from nought: which is done here only when the two are being set side by side.)
        let forCard = tracks[t].outputDevice != 0
        if !forCard, t < channels {
            if tracks[t].soundKind <= 0 || instrument.kind != .synthetic { mixer.expectWaveform(t) }
            tracks[t].program.place = -1
        }
        if !forCard || !asOctaMEDs { n &-= 1 }
        guard t < channels else { return Self.noMorePages }
        tracks[t].fade = 0
        tracks[t].decayOfNote = tracks[t].decay
        tracks[t].vibratoPlace = 0
        tracks[t].tremoloPlace = 0
        let table = Self.rates(ofFineTune: tracks[t].fineTune)
        tracks[t].periodTable = table
        tracks[t].program.note = UInt8(bitPattern: n)
        playedNote = true
        if instrument.kind == .synthetic {
            tracks[t].soundKind = 1
            tracks[t].period = periods[table + Int(UInt8(bitPattern: n))]
            beginProgram(t, instrument.program)
            return Self.noMorePages
        }
        tracks[t].soundKind = instrument.isHybrid ? -1 : 0
        tracks[t].period = periods[table + Int(n)]
        let repeats = instrument.loops && instrument.repeatLength > 2
        mixer.play(t, sample: instrument.offset, bytes: instrument.length, sixteenBit: instrument.sixteenBit, stereo: instrument.stereo,
                   repeatStart: repeats ? instrument.repeatStart : 0, repeatLength: repeats ? instrument.repeatLength : 0,
                   backAndForth: instrument.backAndForth, backwards: tracks[t].backwards, from: Int(tracks[t].sampleOffset))
        if instrument.isHybrid { beginProgram(t, instrument.program) }
        return Self.noMorePages
    }

    /// Turns a track off in mixing mode, as a command or the end of a held note does.
    private mutating func silenceInMixing(_ t: Int) {
        guard tracks[t].outputDevice == 0 else { return }
        mixer.silence(t)
        tracks[t].program.place = -1
        tracks[t].soundKind = 0
        tracks[t].sampleOffset = 0
    }

    /// Starts a note on a track in five-to-eight channel mode: says where its sample is, where it
    /// ends or goes round, and its period, for the mixing to take up on the next tick.
    ///
    /// Only samples are played in this mode, and a sample repeats where the song says it does: the
    /// longer repeats a later OctaMED could write are not looked at.
    private mutating func strikeMixed(_ t: Int, _ note: UInt8, _ instrument: MEDModule.Instrument) -> Int {
        var n = Int8(bitPattern: note) &+ song.transpose &+ instrument.transpose
        tracks[t].vibratoPlace = 0
        n &-= 1
        guard t < 8, instrument.program < 0 else { return Self.noMorePages }
        while n < 0 { n &+= 12 }
        if n > 62 { n &-= 12 }
        let index = Int(n)

        var start = instrument.offset
        if instrument.stereo, t & 3 == 1 || t & 3 == 2 { start &+= instrument.length }
        var length = instrument.length
        var repeatStart = instrument.shortRepeatStart, repeatWords = instrument.shortRepeatWords
        var table = Self.row(ofFineTune: tracks[t].fineTune)
        let period: UInt16
        switch instrument.kind {
        case .sample:
            period = periods[table + index]
        case .extended:
            table -= Self.lowPeriods
            period = periods[table + index]
        case .octaves(let count):
            // As for the four voices, but that the lengths are worked out in sixteen bits here.
            let octave = min(index / 12, 5)
            let which = Self.recordings[count - 2][octave]
            let all = (1 << count) - 1
            let shortest = (length / all > 0xFFFF ? length : length / all) & 0xFFFF
            start &+= shortest * ((1 << which) - 1)
            length = (shortest << which) & 0xFFFF
            repeatStart = (repeatStart << which) & 0xFFFF
            repeatWords = (repeatWords << which) & 0xFFFF
            let octaveOfTable = min(octave, count == 2 ? 4 : 5) - Self.recordingDepth[count - 2] + which
            period = periods[table + octaveOfTable * 12 + index % 12]
        default:
            return Self.noMorePages
        }
        playedNote = true

        let loopStart = start &+ repeatStart * 2
        let loopEnd = repeatWords > 1 ? loopStart &+ repeatWords * 2 : 0
        let end = start &+ length
        var begin = start &+ Int(tracks[t].sampleOffset)
        if end <= begin { begin = start }

        let alone = t < 4 && !song.mixed[t]
        lanes[t].place = begin
        if instrument.loops {
            lanes[t].restart = loopStart
            lanes[t].end = loopEnd
            lanes[t].words = Self.words(loopEnd &- begin)
            lanes[t].loopWords = Self.words(loopEnd &- loopStart)
        } else {
            lanes[t].restart = alone ? module.silence : 0
            lanes[t].end = end &- 1
            lanes[t].words = Self.words(end &- begin)
            lanes[t].loopWords = 1
        }
        lanes[t].period = period
        lanes[t].struck = true
        tracks[t].period = period
        tracks[t].periodTable = table
        return Int(period)
    }

    /// Silences a track in five-to-eight channel mode.
    private mutating func silence(_ t: Int) {
        tracks[t].period = 0
        if t < 8 { lanes[t].period = 0 }
    }

    /// Where a voice's stretches of mixed sound are in the memory the chip plays from.
    private func mixPlace(_ voice: Int, _ buffer: Int) -> Int {
        module.mixSpace + (voice * MEDModule.mixBuffers + buffer) * MEDModule.mixBufferSize
    }

    /// What OctaMED did first each time a voice came to the end of what had been mixed for it:
    /// told the voices their volumes, mixed the next stretch for each voice that has two tracks,
    /// and gave each voice that has one its new note, if it has one.
    private mutating func mixTick() {
        wordsPlaying = wordsNext
        wordsNext = mixWordsNow
        mixBuffer = (mixBuffer + 1) % MEDModule.mixBuffers
        if record != nil { record!.mixedWords = wordsNext }
        var starting: UInt16 = 0
        for voice in 0 ..< 4 {
            paula.setVolume(voice, UInt16(pairVolumes[voice]))
            if record != nil { record!.voices[voice].volume = Int(pairVolumes[voice]) }
            if song.mixed[voice] {
                mixPair(voice)
                continue
            }
            // A voice with one track is played by the chip as it would be with four.
            lanes[voice].swing = 0
            guard lanes[voice].period != 0 else {
                paula.stop(voices: 1 << voice)
                continue
            }
            paula.setPeriod(voice, lanes[voice].period)
            if record != nil { record!.voices[voice].period = Int(lanes[voice].period) }
            guard lanes[voice].place != 0 else { continue }
            paula.stop(voices: 1 << voice)
            paula.setLocation(voice, lanes[voice].place)
            paula.setLength(voice, lanes[voice].words)
            if record != nil { record!.voices[voice].start = stretch(from: lanes[voice].place, words: lanes[voice].words) }
            lanes[voice].place = 0
            starting |= 1 << voice
        }
        guard starting != 0 else { return }
        paula.start(voices: starting)
        for voice in 0 ..< 4 where starting & (1 << voice) != 0 {
            paula.setLocation(voice, lanes[voice].restart)
            paula.setLength(voice, lanes[voice].loopWords)
            if record != nil { record!.voices[voice].loop = stretch(from: lanes[voice].restart, words: lanes[voice].loopWords) }
        }
    }

    /// Where a track's sample is read from for one tick's mixing, and how far it is stepped for
    /// each byte mixed, in 65,536ths of a byte: nowhere, and no step, for a track that is silent.
    ///
    /// The step is the mixing's period over the note's, worked out as OctaMED did it, in whole
    /// numbers that lose a little. And where a sample ends is only looked at here, before a tick's
    /// worth is mixed: one that would end within the tick is stopped, or sent round, before it.
    private mutating func feed(_ lane: Int) -> (from: Int, step: UInt32) {
        let period = UInt32(lanes[lane].period)
        guard period != 0, lanes[lane].place != 0 else { return (module.silence, 0) }
        // (A period too short for the division to fit sixteen bits leaves no step at all.)
        let whole = Self.mixClock / period
        let quotient = whole > 0xFFFF ? Self.mixClock & 0xFFFF : whole
        let ahead = Int((quotient &* UInt32((mixWordsNow << 3) & 0xFFFF)) >> 16)
        if lanes[lane].place &+ ahead &- lanes[lane].end >= 0 {
            guard lanes[lane].restart != 0 else {
                lanes[lane].place = 0
                return (module.silence, 0)
            }
            lanes[lane].place = lanes[lane].restart
        }
        return (lanes[lane].place, quotient << 2)
    }

    /// Mixes a tick's worth of a voice's two tracks into the stretch of memory the voice is to
    /// play after the one it is playing: a byte from each, added, with nothing between the bytes
    /// of a sample but the last one again.
    private mutating func mixPair(_ voice: Int) {
        let first = feed(voice), second = feed(voice + 4)
        let count = (mixWordsNow >> 1) * 4
        // (A sample is read on past its end, as OctaMED read it: but not past the end of the file,
        // where the Amiga had whatever it had.)
        let memory = module.memory, size = module.silence
        let out = memory + mixPlace(voice, mixBuffer)
        var a: UInt32 = 0, b: UInt32 = 0
        var swingA = Swing<Int8>(from: -128, to: 127), swingB = Swing<Int8>(from: -128, to: 127)
        for i in 0 ..< count {
            let ia = first.from + Int(Int16(truncatingIfNeeded: a >> 16)), ib = second.from + Int(Int16(truncatingIfNeeded: b >> 16))
            let x: Int8 = ia >= 0 && ia < size ? memory[ia] : 0, y: Int8 = ib >= 0 && ib < size ? memory[ib] : 0
            swingA.note(x)
            swingB.note(y)
            out[i] = x &+ y
            a &+= first.step
            b &+= second.step
        }
        // A track that is left out of the sound has now been read and measured as ever. What was
        // mixed is made again without it: the other track's bytes alone, or silence.
        if lanes[voice].muted || lanes[voice + 4].muted {
            let kept = lanes[voice].muted ? second : first
            let silent = lanes[voice].muted && lanes[voice + 4].muted
            var c: UInt32 = 0
            for i in 0 ..< count {
                let at = kept.from + Int(Int16(truncatingIfNeeded: c >> 16))
                out[i] = !silent && at >= 0 && at < size ? memory[at] : 0
                c &+= kept.step
            }
        }
        if let laneBytes {
            // For the scopes: what was mixed on the tick before is what the chip now plays, at the
            // volume it has just been told; and each track's bytes of this tick's are kept apart.
            laneVolumes[voice] = pairVolumes[voice]
            for (lane, feed) in [(voice, first), (voice + 4, second)] {
                let mixing = laneBytes + lane * MEDModule.mixBufferSize, playing = laneBytes + (8 + lane) * MEDModule.mixBufferSize
                playing.update(from: mixing, count: laneCounts[lane])
                laneCounts[8 + lane] = laneCounts[lane]
                let kept = min(count, MEDModule.mixBufferSize)
                var c: UInt32 = 0
                for i in 0 ..< kept {
                    let at = feed.from + Int(Int16(truncatingIfNeeded: c >> 16))
                    mixing[i] = at >= 0 && at < size ? memory[at] : 0
                    c &+= feed.step
                }
                laneCounts[lane] = kept
            }
        }
        // The part of a byte that the last step came to is dropped: the next tick begins on a whole one.
        if first.step != 0 { lanes[voice].place &+= Int(a >> 16) }
        if second.step != 0 { lanes[voice + 4].place &+= Int(b >> 16) }
        let loudness = Float(min(64, pairVolumes[voice] & 127)) / (64 * 256)
        lanes[voice].swing = swingA.moved ? Float(Int(swingA.high) - Int(swingA.low)) * loudness : 0
        lanes[voice + 4].swing = swingB.moved ? Float(Int(swingB.high) - Int(swingB.low)) * loudness : 0
        if record != nil { record!.mixed[voice] = (0 ..< count).map { out[$0] } }
    }

    /// Half way through a tick's sound, in five-to-eight channel mode: the voices are told where
    /// to go on from when they finish what they are playing, which is what was mixed at the start
    /// of the tick. (OctaMED told them at the start. But the chip here keeps time by itself, and
    /// may be a sample early or late in reaching the end of a stretch: so it is told in the
    /// middle, where it cannot be mistaken about which stretch is meant.)
    mutating func halfTick() {
        guard mode == .eightChannel else { return }
        for voice in 0 ..< 4 where song.mixed[voice] {
            paula.setLocation(voice, mixPlace(voice, mixBuffer))
            paula.setLength(voice, UInt16(wordsNext))
        }
    }

    /// Starts keeping each track's sound in `waves`, for its scope: by the mixer in mixing mode,
    /// at its rate; and otherwise at the chip's, by the chip for a track that has a voice to
    /// itself and here for two that share one (`keepSharedWaves`).
    mutating func keepWaves(_ waves: ChannelWaves) {
        self.waves = waves
        guard mode != .mixing else {
            mixer.waves = waves
            return
        }
        paula.waves = waves
        guard mode == .eightChannel else { return }
        for voice in 0 ..< 4 { paula.waveNumbers[voice] = song.mixed[voice] ? -1 : voice }
        if laneBytes == nil {
            let space = 16 * MEDModule.mixBufferSize
            laneBytes = .allocate(capacity: space)
            laneBytes!.initialize(repeating: 0, count: space)
        }
    }

    /// Keeps so many samples of the sound of each track that shares a voice in five-to-eight
    /// channel mode, before the chip makes them, from so far into a tick of so many: what the
    /// track gave to the stretch the chip is playing, which lasts the tick, spread over it, at the
    /// volume the chip plays it at. The fifth to eighth tracks of a voice that has one track are
    /// silent, and so is any that is kept for another of the file's songs and not this one.
    mutating func keepSharedWaves(from start: Int, count: Int, of total: Int) {
        guard let waves, mode != .mixing else { return }
        for track in min(channels, waves.voices) ..< waves.voices { waves.silence(track, count: count) }
        guard let laneBytes, total > 0 else { return }
        for voice in 0 ..< 4 {
            guard song.mixed[voice] else {
                waves.silence(voice + 4, count: count)
                continue
            }
            let volume = Float(min(64, laneVolumes[voice] & 127)) * (1.0 / (128.0 * 64.0))
            for lane in [voice, voice + 4] {
                let bytes = laneBytes + (8 + lane) * MEDModule.mixBufferSize, have = laneCounts[8 + lane]
                guard have > 0 else {
                    waves.silence(lane, count: count)
                    continue
                }
                for i in 0 ..< count { waves.store(lane, at: i, Float(bytes[(start + i) * have / total]) * volume) }
            }
        }
    }

    /// Leaves tracks out of the sound, or brings them back: see `Renderer.setMuted`. A mark for
    /// each track, numbered as the lights are; true for one not to be heard, and a track with no
    /// mark is heard.
    ///
    /// In mixing mode it is the mixer that leaves a track out. With four tracks it is the chip,
    /// whose voices they are. With five to eight, a track that has a voice to itself is left out
    /// by the chip, and one of two that share a voice is left out where the two are added, so
    /// that the other is heard as it was; with both left out the chip leaves out the voice, which
    /// silences at once what was mixed for it before it was told.
    mutating func setMuted(_ muted: [Bool]) {
        func marked(_ track: Int) -> Bool { track < muted.count && muted[track] }
        switch mode {
        case .mixing:
            mixer.setMuted(muted)
        case .eightChannel:
            var chip = [false, false, false, false]
            for voice in 0 ..< 4 {
                lanes[voice].muted = marked(voice)
                lanes[voice + 4].muted = marked(voice + 4)
                chip[voice] = marked(voice) && (!song.mixed[voice] || marked(voice + 4))
            }
            paula.setMuted(chip)
        case .fourChannel:
            paula.setMuted(muted)
        }
    }

    /// How far each track has swung since this was last asked, where 1 is as far as a voice at
    /// full volume can.
    mutating func takeLevels(into levels: inout [Float]) {
        if mode == .mixing { return mixer.takeLevels(into: &levels) }
        guard mode == .eightChannel else { return paula.takeLevels(into: &levels) }
        var alone = [Float](repeating: 0, count: 4)
        paula.takeLevels(into: &alone)
        for t in 0 ..< 8 { levels[t] = t < 4 && !song.mixed[t] ? alone[t] : lanes[t].swing }
    }

    /// The pitch of each track's note, and whether one has begun since this was last asked.
    mutating func takeNotes(into notes: inout TickNotes) {
        if mode == .mixing { return mixer.takeNotes(into: &notes) }
        guard mode == .eightChannel else { return paula.takeNotes(into: &notes) }
        for t in 0 ..< 8 {
            let sounding = lanes[t].period != 0 && (lanes[t].place != 0 || t < 4 && !song.mixed[t])
            notes.pitches[t] = sounding ? ChannelPitch.note(ofRate: Paula.clockHz / Double(max(Paula.shortestPeriod, Int(lanes[t].period)))) : 0
            if lanes[t].struck { notes.struck[t] = true }
            lanes[t].struck = false
        }
    }

    /// Starts the note of the line again, or for the first time if a command kept it waiting.
    private mutating func strikeAgain(_ t: Int) {
        let note = tracks[t].lineNote
        guard note != 0 else { return }
        if tracks[t].holdLeft >= 0 {
            tracks[t].holdLeft &+= Int8(bitPattern: counter)
        } else {
            beginHold(t)
        }
        let left = strike(t, note)
        if left >= 0 { pageCount = left }
    }

    private mutating func beginHold(_ t: Int) {
        tracks[t].holdLeft = tracks[t].hold != 0 ? Int8(bitPattern: tracks[t].hold) : -1
    }

    /// The note a track's transposes make of one, as the byte OctaMED's player keeps it in.
    private func transposed(_ note: UInt8, _ t: Int) -> UInt8 {
        note &- 1 &+ UInt8(bitPattern: song.transpose) &+ UInt8(bitPattern: tracks[t].transpose)
    }

    // MARK: Synthetic sounds

    /// Sets a track's sound going from the top of its lists, as a new note does.
    ///
    /// Not everything is set back. The volume the last note's list had reached stays until this
    /// one's list sets another, and so does a waveform that was being read as the volume's shape,
    /// if it was to begin again.
    private mutating func beginProgram(_ t: Int, _ place: Int) {
        var now = Program()
        now.place = place
        now.note = tracks[t].program.note
        now.volume = tracks[t].program.volume
        now.envelopeRestart = tracks[t].program.envelopeRestart
        now.envelopeCount = tracks[t].program.envelopeCount
        if tracks[t].keepsWavePlace { now.waveAt = tracks[t].program.waveAt }
        now.volumeSpeed = module.byte(place + 18)
        now.waveSpeed = module.byte(place + 19)
        tracks[t].program = now
    }

    /// Carries a track's synthetic sound on by one tick: its volume list, then its waveform list,
    /// then what they have set going. It leaves the volume where a tremolo would have left it.
    /// - Returns: the period the voice is to have.
    private mutating func runProgram(_ t: Int) -> UInt16 {
        var now = tracks[t].program
        var period = tracks[t].period
        let lists = now.place

        // (The counts are bytes, but one that cannot go lower is still taken to have run out.)
        let volumeDue = now.volumeCount <= 1
        now.volumeCount &-= 1
        if volumeDue {
            now.volumeCount = Int8(bitPattern: now.volumeSpeed)
            runVolumeList(&now)
        }
        // The list's volume is a part of the track's own.
        let level = UInt16(now.volume) &* UInt16(UInt8(bitPattern: tracks[t].volume))
        tracks[t].tremoloVolume = Int8(truncatingIfNeeded: Int16(bitPattern: level) >> 6)

        let waveDue = now.waveCount <= 1
        now.waveCount &-= 1
        if waveDue {
            now.waveCount = Int8(bitPattern: now.waveSpeed)
            now.pitchSlid &+= now.pitchSlide
            var waits = false
            if now.waveWait != 0 {
                now.waveWait &-= 1
                waits = now.waveWait != 0
            }
            if !waits, let waveform = runWaveList(&now, period: &period, from: tracks[t].period) {
                // The voice is told of the new waveform now, and goes over to it when it has
                // played the old one to its end.
                if mode == .mixing {
                    mixer.setWaveform(t, at: waveform)
                } else {
                    let words = module.word(waveform)
                    paula.setLength(t, UInt16(truncatingIfNeeded: words))
                    paula.setLocation(t, waveform + 2)
                    if record != nil { record!.voices[t].waveform = MEDRegisterTick.Waveform(place: waveform + 2, words: words) }
                }
            }
        }

        if now.arpeggioAt != 0 {
            let note = module.byte(lists + 150 + Int(now.arpeggioAt)) &+ now.note
            period = periods[tracks[t].periodTable + Int(note)]
            let next = now.arpeggioAt &+ 1
            now.arpeggioAt = module.byte(lists + 150 + Int(next)) >= 0x80 ? now.arpeggioFrom : next
        }
        var bent: UInt16 = 0
        if now.vibratoDepth != 0 {
            let at = Int(now.vibratoPlace >> 4) & 0x1F
            let wave = now.vibratoWave == -1 ? sine[at] : Int8(bitPattern: module.byte(now.vibratoWave + at))
            let bend = Int32(wave) * Int32(Int16(bitPattern: now.vibratoDepth))
            bent = UInt16(bitPattern: Int16(truncatingIfNeeded: bend) >> 8)
            now.vibratoPlace &+= now.vibratoSpeed
        }
        tracks[t].program = now
        guard mode == .mixing else { return period &+ bent &+ now.pitchSlid }
        // In mixing mode the slide and the vibrato are still so many periods, and the pitch is a
        // rate: and it is not let fall below a rate of 113.
        if period != 0 {
            let shifted = Self.turned(period) &+ bent &+ now.pitchSlid
            if shifted != 0 { period = Self.turned(shifted) }
        }
        return max(113, period)
    }

    /// One turn of a synthetic sound's volume list: what was set going is carried on, and then
    /// instructions are read until one of them sets a volume or waits.
    private func runVolumeList(_ now: inout Program) {
        if now.volumeSlide != 0 {
            let volume = Int8(bitPattern: now.volume) &+ now.volumeSlide
            now.volume = volume < 0 ? 0 : (volume > 64 ? 64 : UInt8(volume))
        }
        if now.envelope != -1 {
            // The shape is 128 bytes, from the lowest volume to the highest.
            now.volume = (module.byte(now.envelope) &+ 128) >> 2
            now.envelope += 1
            now.envelopeCount &+= 1
            if now.envelopeCount >= 0x80 {
                now.envelopeCount = 0
                now.envelope = now.envelopeRestart
            }
        }
        if now.volumeWait != 0 {
            // A wait of more than 127 is one below nought, and so is over at once.
            let over = Int8(bitPattern: now.volumeWait) <= 1
            now.volumeWait &-= 1
            if !over { return }
        }

        let list = now.place + 21
        var at = now.volumeAt
        for _ in 0 ..< Self.mostInstructions {
            at &+= 1
            let instruction = module.byte(list + Int(at))
            guard instruction >= 0x80 else {
                now.volume = instruction
                break
            }
            let data = module.byte(list + 1 + Int(at))
            switch instruction & 0x0F {
            case 0x0:
                now.volumeSpeed = data
                at &+= 1
                continue
            case 0x1:
                now.volumeWait = data
                at &+= 1
            case 0x2:
                now.volumeSlide = 0 &- Int8(bitPattern: data)
                at &+= 1
                continue
            case 0x3:
                now.volumeSlide = Int8(bitPattern: data)
                at &+= 1
                continue
            case 0x4, 0x5:
                // A waveform as the shape of the volume, once or over and over.
                now.envelope = module.waveform(Int(Int8(bitPattern: data)), of: now.place) + 2
                now.envelopeRestart = instruction & 0x0F == 0x5 ? now.envelope : -1
                now.envelopeCount = 0
                at &+= 1
                continue
            case 0x6:
                now.envelope = -1
                continue
            case 0xA:
                // A jump for the other list.
                now.waveAt = data
                now.waveWait = 0
                at &+= 1
                continue
            case 0xE:
                at = data
                continue
            case 0xB, 0xF:
                // The end, which is come back to every time.
                at &-= 1
            default:
                break
            }
            break
        }
        now.volumeAt = at
    }

    /// One turn of a synthetic sound's waveform list: instructions are read until one of them is a
    /// waveform or waits.
    /// - Returns: where the waveform is, if the list came to one.
    private func runWaveList(_ now: inout Program, period: inout UInt16, from note: UInt16) -> Int? {
        let list = now.place + 149
        var at = now.waveAt
        var waveform: Int?
        for _ in 0 ..< Self.mostInstructions {
            at &+= 1
            let instruction = module.byte(list + Int(at))
            guard instruction >= 0x80 else {
                waveform = module.waveform(Int(instruction), of: now.place)
                break
            }
            let data = module.byte(list + 1 + Int(at))
            switch instruction & 0x0F {
            case 0x0:
                now.waveSpeed = data
                at &+= 1
                continue
            case 0x1:
                now.waveWait = data
                at &+= 1
            case 0x2:
                now.pitchSlide = UInt16(data)
                at &+= 1
                continue
            case 0x3:
                now.pitchSlide = UInt16(bitPattern: Int16(0 &- Int8(bitPattern: data)))
                at &+= 1
                continue
            case 0x4:
                now.vibratoDepth = UInt16(data)
                at &+= 1
                continue
            case 0x5:
                now.vibratoSpeed = UInt16(data &+ 1)
                at &+= 1
                continue
            case 0x6:
                // Back to the pitch of the note.
                now.pitchSlid = 0
                period = note
                continue
            case 0x7:
                now.vibratoWave = module.waveform(Int(Int8(bitPattern: data)), of: now.place) + 2
                at &+= 1
                continue
            case 0xA:
                // A jump for the other list.
                now.volumeAt = data
                now.volumeWait = 0
                at &+= 1
                continue
            case 0xC:
                // A run of notes begins here, and the list goes on from after its end.
                now.arpeggioFrom = at
                now.arpeggioAt = at
                for _ in 0 ..< 256 {
                    at &+= 1
                    if module.byte(list + Int(at)) >= 0x80 { break }
                }
                continue
            case 0xD:
                continue
            case 0xE:
                at = data
                continue
            case 0xB, 0xF:
                at &-= 1
            default:
                break
            }
            break
        }
        now.waveAt = at
        return waveform
    }

    // MARK: Commands that act as a line is read

    /// Carries out a command that is to act before the line's notes are started. True if it says
    /// the track's note is not to be started with the others.
    private mutating func lineCommand(_ t: Int, _ number: UInt8, _ data: UInt8) -> Bool {
        switch number {
        case 0x03:
            // A slide to the note, which is therefore not started: the note is where to slide to.
            guard t < channels else { return true }
            if tracks[t].lineNote != 0 {
                let table = tracks[t].periodTable
                let note = transposed(tracks[t].lineNote, t)
                guard table != -1, note < 0x80 else { return true }
                tracks[t].slideTarget = periods[table + Int(note)]
            }
            if data != 0 { tracks[t].slideSpeed = data }
            return true
        case 0x08:
            if mode != .eightChannel { tracks[t].decay = data >> 4 }
            tracks[t].hold = data & 0x0F
        case 0x09:
            ticksPerLine = data & 0x1F == 0 ? 0x20 : data & 0x1F
        case 0x0B:
            if Int(data) <= song.sequences[song.sections[section]].count {
                position = Int(data)
                leaving = -1
            }
        case 0x0C:
            if mode == .eightChannel {
                // The volume of the voice, which is both its tracks': and the track itself keeps
                // no account of it.
                let volume = song.hexVolumes ? data : (data >> 4) &* 10 &+ (data & 0x0F)
                if volume <= 64, t < 8 { pairVolumes[t & 3] = volume }
            } else if data & 0x80 != 0 {
                // With the top bit, the volume is the instrument's own from now on.
                let volume = data & 0x7F
                guard volume <= 64 else { break }
                volumes[tracks[t].instrument] = volume
                tracks[t].volume = Int8(volume)
            } else {
                let volume = song.hexVolumes ? data : (data >> 4) &* 10 &+ (data & 0x0F)
                if volume <= 64 { tracks[t].volume = Int8(volume) }
            }
        case 0x0E:
            // Where in its waveform list a synthetic sound's note is to begin.
            guard t < channels, mode != .eightChannel else { break }
            tracks[t].keepsWavePlace = true
            tracks[t].program.waveAt = data
        case 0x0F:
            switch data {
            case 0x00:
                leaving = 1
            case 0x01 ... 0xF0:
                setTempo(Int(data))
            case 0xF2, 0xF4, 0xF5:
                // The note is to come late: the commands of the ticks start it.
                beginHold(t)
                return true
            case 0xFD:
                // The pitch of the note, without the note.
                guard t < channels else { break }
                let table = tracks[t].periodTable
                guard table != -1, tracks[t].lineNote != 0 else { return true }
                tracks[t].period = periods[table + Int(transposed(tracks[t].lineNote, t))]
                return true
            case 0xFE:
                stopped = true
            case 0xFF:
                if mode == .eightChannel {
                    silence(t)
                } else if mode == .mixing {
                    silenceInMixing(t)
                } else if t < 4, tracks[t].outputDevice == 0 {
                    tracks[t].sampleOffset = 0
                    tracks[t].program.place = -1
                    tracks[t].soundKind = 0
                    stop(t)
                }
            default:
                break
            }
        case 0x15:
            let fineTune = Int8(bitPattern: data)
            if fineTune >= -8, fineTune <= 7 { tracks[t].fineTune = fineTune }
        case 0x16:
            // Nought marks the line; a number goes back to the marked line that many times.
            if data == 0 {
                loopLine = line
                break
            }
            if loopsLeft != 0 {
                loopsLeft -= 1
                if loopsLeft == 0 { break }
            } else {
                loopsLeft = Int(data)
            }
            lineWanted = loopLine + 1
            // The lines about to be played again have not been played for the last time.
            if let row = rowIndex(ofPlace: place, line: loopLine) {
                var again = row
                while again <= row + (line - loopLine), again < song.rowsInAll {
                    visited[again] = false
                    again += 1
                }
            }
        case 0x19:
            tracks[t].sampleOffset = UInt16(data) << 8
        case 0x1D:
            leaving = 1
            keepsLine = true
            lineWanted = Int(data) + 1
        case 0x1E:
            if delay == 0 { delay = Int(data) + 1 }
        case 0x1F:
            beginHold(t)
            return true
        case 0x20:
            // The next note backwards.
            if mode == .mixing, data == 0 { tracks[t].backwards = true }
        case 0x2E:
            // Where the track lies between left and right, for a song that says where its tracks lie.
            let place = Int8(bitPattern: data)
            if mode == .mixing, t < channels, t < pans.count, place >= -16, place <= 16 { pans[t] = place }
        case 0x2F:
            guard mode == .mixing else { break }
            if data & 0xF0 == 0xE0 {
                // How fast the echo dies away: the larger the number, the slower.
                let depth = 7 - Int(data & 0x0F)
                if depth >= 1, depth <= 6 { mixer.setEchoDepth(depth) }
            } else if data & 0xF0 == 0xD0 {
                let separation = Int(data & 0x0F) - (data & 0x08 != 0 ? 16 : 0)
                if separation >= -4, separation <= 4 { mixer.setSeparation(separation) }
            }
        default:
            break
        }
        return false
    }

    // MARK: Commands that act on every tick

    private mutating func slideVolume(_ t: Int, _ data: UInt8) {
        var volume = tracks[t].volume
        if data & 0xF0 != 0 {
            volume &+= Int8(data >> 4)
            if volume > 64 { volume = 64 }
        } else {
            volume &-= Int8(bitPattern: data)
            if volume < 0 { volume = 0 }
        }
        setVolume(t, volume)
    }

    /// Gives a track the volume a command has worked out for it. In five-to-eight channel mode it
    /// is the track's voice that is given it, and the track goes on counting from where it was:
    /// so a slide there goes one step and no further, however long it lasts.
    private mutating func setVolume(_ t: Int, _ volume: Int8) {
        if mode == .eightChannel {
            if t < 8 { pairVolumes[t & 3] = UInt8(bitPattern: volume) }
        } else {
            tracks[t].volume = volume
        }
    }

    private mutating func slideToNote(_ t: Int) {
        let target = tracks[t].slideTarget
        guard target != 0 else { return }
        if mode == .mixing {
            // By so many periods towards the note's rate, and no further.
            let now = tracks[t].period
            guard now != 0 else { return }
            let speed = UInt16(tracks[t].slideSpeed)
            var next = target
            if now > target {
                let period = Self.turned(now) &+ speed
                if period != 0, Self.turned(period) > target { next = Self.turned(period) }
            } else {
                let period = Self.turned(now)
                if period > speed, Self.turned(period - speed) < target { next = Self.turned(period - speed) }
            }
            tracks[t].period = next
            if next == target { tracks[t].slideTarget = 0 }
            return
        }
        var period = tracks[t].period
        let speed = UInt16(tracks[t].slideSpeed)
        var arrived: Bool
        if period > target {
            period &-= speed
            arrived = Int16(bitPattern: period) <= Int16(bitPattern: target)
        } else {
            period &+= speed
            arrived = Int16(bitPattern: period) >= Int16(bitPattern: target)
        }
        if arrived {
            period = target
            tracks[t].slideTarget = 0
        }
        tracks[t].period = period
    }

    private mutating func vibrate(_ t: Int) {
        let wave = Int32(sine[Int(tracks[t].vibratoPlace >> 2) & 0x1F]) * Int32(tracks[t].vibratoDepth)
        tracks[t].bend = UInt16(bitPattern: Int16(truncatingIfNeeded: wave) >> Int16(tracks[t].vibratoShift & 63))
        tracks[t].vibratoPlace &+= tracks[t].vibratoSpeed
        if mode == .mixing {
            // The bend is so many periods: what it does to the rate is worked out from that.
            let bend = tracks[t].bend
            tracks[t].bend = 0
            guard tracks[t].period != 0 else { return }
            let period = Self.turned(tracks[t].period) &+ bend
            if period != 0 { tracks[t].bend = Self.turned(period) &- tracks[t].period }
        }
    }

    /// In mixing mode: slides a track's pitch by so many periods, up for a number above nought.
    private mutating func slideRate(_ t: Int, up amount: UInt16) {
        guard tracks[t].period != 0 else { return }
        let period = Self.turned(tracks[t].period) &- amount
        if period != 0 { tracks[t].period = Self.turned(period) }
    }

    private mutating func vibrato(_ t: Int, _ data: UInt8, shift: UInt8) {
        tracks[t].vibratoShift = shift
        if counter == 0, data != 0 {
            if data & 0x0F != 0 { tracks[t].vibratoDepth = Int16(data & 0x0F) }
            if data & 0xF0 != 0 { tracks[t].vibratoSpeed = (data & 0xF0) >> 3 }
        }
        vibrate(t)
    }

    private mutating func tremolo(_ t: Int, _ data: UInt8) {
        if counter == 0, data != 0 {
            if data & 0x0F != 0 { tracks[t].tremoloDepth = Int16(data & 0x0F) }
            if data & 0xF0 != 0 { tracks[t].tremoloSpeed = (data & 0xF0) >> 2 }
        }
        let wave = Int32(sine[Int(tracks[t].tremoloPlace >> 3) & 0x1F]) * Int32(tracks[t].tremoloDepth)
        tracks[t].tremoloPlace &+= tracks[t].tremoloSpeed
        let volume = Int8(truncatingIfNeeded: Int16(truncatingIfNeeded: wave) >> 7) &+ tracks[t].volume
        tracks[t].tremoloVolume = max(0, min(64, volume))
    }

    private mutating func tickCommand(_ t: Int, _ number: UInt8, _ data: UInt8) {
        // The older trackers did not slide on the first tick of a line, and a song can ask for that.
        let slides = counter != 0 || !song.slidesSkipFirstTick
        switch number {
        case 0x00:
            // An arpeggio: the note, and the two notes above it that the command names, in turn.
            guard data != 0 else { break }
            let table = tracks[t].periodTable
            guard table != -1 else { break }
            let step = counter % 3
            let above = step == 0 ? data >> 4 : (step == 1 ? data & 0x0F : 0)
            let note = transposed(tracks[t].lastNote, t)
            tracks[t].arpeggio = periods[table + Int(note & 0x7F)] &- periods[table + Int((note &+ above) & 0x7F)]
        case 0x01 where mode == .mixing:
            if slides { slideRate(t, up: UInt16(data)) }
        case 0x02 where mode == .mixing:
            if slides { slideRate(t, up: 0 &- UInt16(data)) }
        case 0x11 where mode == .mixing:
            if counter == 0 { slideRate(t, up: UInt16(data)) }
        case 0x12 where mode == .mixing:
            if counter == 0 { slideRate(t, up: 0 &- UInt16(data)) }
        case 0x20 where mode == .mixing:
            // Along the sample, or back along it, by so many times 256 samples.
            if counter == 0 { mixer.jump(t, by: Int(Int8(bitPattern: data))) }
        case 0x21 where mode == .mixing:
            // Up by so many 2048ths of the pitch, on every tick: as far as the highest rate there is.
            let more = UInt16(truncatingIfNeeded: ((UInt32(tracks[t].period) * UInt32(data)) << 5) >> 16)
            let sum = tracks[t].period.addingReportingOverflow(more)
            tracks[t].period = sum.overflow ? 0xFFFF : sum.partialValue
        case 0x22 where mode == .mixing:
            let less = UInt16(truncatingIfNeeded: ((UInt32(tracks[t].period) * UInt32(data)) << 5) >> 16)
            tracks[t].period = less > tracks[t].period ? 1 : tracks[t].period - less
        case 0x01:
            guard slides else { break }
            let period = Int16(bitPattern: tracks[t].period &- UInt16(data))
            tracks[t].period = period < 113 ? 113 : UInt16(bitPattern: period)
        case 0x02:
            if slides { tracks[t].period &+= UInt16(data) }
        case 0x03:
            if slides { slideToNote(t) }
        case 0x04:
            vibrato(t, data, shift: 5)
        case 0x05:
            guard slides else { break }
            slideVolume(t, data)
            slideToNote(t)
        case 0x06:
            guard slides else { break }
            slideVolume(t, data)
            vibrate(t)
        case 0x07:
            tremolo(t, data)
        case 0x0A, 0x0D:
            if slides { slideVolume(t, data) }
        case 0x0F:
            switch data {
            case 0xF1, 0xF2:
                if counter == 3 { strikeAgain(t) }
            case 0xF3:
                if counter != 0, counter & 1 == 0 { strikeAgain(t) }
            case 0xF4:
                if counter == ticksPerLine / 3 { strikeAgain(t) }
            case 0xF5:
                if counter == (ticksPerLine / 3) &* 2 { strikeAgain(t) }
            case 0xF8:
                paula.setLightFilter(false)
            case 0xF9:
                paula.setLightFilter(true)
            default:
                break
            }
        case 0x11:
            if counter == 0 { tracks[t].period &-= UInt16(data) }
        case 0x12:
            if counter == 0 { tracks[t].period &+= UInt16(data) }
        case 0x13:
            // A note that begins sharp, for three ticks.
            if Int8(bitPattern: counter) < 3 { tracks[t].bend = 0 &- UInt16(data) }
        case 0x14:
            vibrato(t, data, shift: 6)
        case 0x18:
            if counter == data { tracks[t].volume = 0 }
        case 0x1A:
            guard counter == 0 else { break }
            let volume = tracks[t].volume &+ Int8(bitPattern: data)
            setVolume(t, volume > 64 ? 64 : volume)
        case 0x1B:
            guard counter == 0 else { break }
            let volume = tracks[t].volume &- Int8(bitPattern: data)
            setVolume(t, volume < 0 ? 0 : volume)
        case 0x1F:
            // The note late by so many ticks, and again every so many.
            let late = data >> 4, every = data & 0x0F
            if late != 0 {
                if Int8(bitPattern: counter) < Int8(late) { break }
                if counter == late {
                    strikeAgain(t)
                    break
                }
            }
            if every != 0, counter % every == 0 { strikeAgain(t) }
        default:
            break
        }
    }

    /// Carries out a line's commands for one tick, a page at a time.
    ///
    /// A command that starts a note leaves the note's period where OctaMED's player was counting
    /// the pages, so the pages after that one are not reached on that tick: and that is what a
    /// tune written with it sounds like. (A note for an instrument that is not there leaves nought,
    /// and the second page is next whichever page that was: it is gone round a few times here,
    /// where OctaMED's player never stops.)
    private mutating func tickCommands(_ block: MEDModule.Block, voices: Int) {
        let mask: UInt8 = song.version == 0 ? 0x0F : (mode == .mixing ? 0x3F : 0x1F)
        pageCount = 0
        var turns = 0
        while pageCount < block.pages, turns < block.pages + 4 {
            let page = pageCount
            for t in 0 ..< voices {
                let command = module.command(block, page: page, line: commandLine, track: t)
                tickCommand(t, command.number & mask, command.data)
            }
            pageCount = (pageCount + 1) & 0xFFFF
            turns += 1
        }
    }

    // MARK: Lines

    /// The place in the order of playing that is being played.
    private var place: Int {
        section < song.firstPlaceOfSection.count ? song.firstPlaceOfSection[section] + position : 0
    }

    /// Where a line of a place is in the tables that have an entry for every line; nil if it has none.
    private func rowIndex(ofPlace place: Int, line: Int) -> Int? {
        guard place >= 0, place < song.places.count, line >= 0 else { return nil }
        let first = song.firstRowOfPlace[place]
        let next = place + 1 < song.places.count ? song.firstRowOfPlace[place + 1] : song.rowsInAll
        return min(first + line, next - 1)
    }

    /// Reads the line the tune is at, starts its notes, and moves the tune on to the line after.
    private mutating func playLine() {
        let now = song.blocks[block]
        let last = now.lines - 1
        if let row = rowIndex(ofPlace: place, line: line) {
            visited[row] = true
            if let firstPlayedBy, firstPlayedBy[row] == ModuleSongs.unplayed { firstPlayedBy[row] = songNumber }
            if place < ordersPlayed.count { ordersPlayed[place] = true }
        }

        for t in 0 ..< now.tracks {
            let cell = module.cell(now, line: min(line, last), track: t)
            // A note with its top bit set is no note.
            let note = cell.note < 0x80 ? cell.note : 0
            tracks[t].lineNote = note
            if note != 0 { tracks[t].lastNote = note }
            tracks[t].waits = false
            guard cell.instrument != 0 else { continue }
            let number = Int(cell.instrument) - 1
            let instrument = song.instruments[number]
            tracks[t].instrument = number
            tracks[t].hasInstrument = true
            tracks[t].transpose = instrument.transpose
            tracks[t].hold = instrument.hold
            tracks[t].fineTune = instrument.fineTune
            tracks[t].sampleOffset = 0
            tracks[t].keepsWavePlace = false
            tracks[t].backwards = false
            if mode == .eightChannel {
                // An instrument has no volume of its own here: naming one turns its voice full up.
                tracks[t].volume = 64
                if t < 8 { pairVolumes[t & 3] = 64 }
                continue
            }
            tracks[t].volume = Int8(bitPattern: volumes[number])
            tracks[t].decay = instrument.decay
            tracks[t].outputDevice = instrument.outputDevice
        }

        // A command numbered beyond those there are is taken for the one it is that many past.
        let mask: UInt8 = song.version == 0 ? 0x0F : (mode == .eightChannel ? 0x1F : 0x3F)
        for page in 0 ..< now.pages {
            for t in 0 ..< now.tracks {
                let command = module.command(now, page: page, line: line, track: t)
                guard command.number != 0 else { continue }
                if lineCommand(t, command.number & mask, command.data) { tracks[t].waits = true }
                if stopped { return }
            }
        }

        for t in 0 ..< now.tracks where !tracks[t].waits && tracks[t].lineNote != 0 {
            beginHold(t)
            strike(t, tracks[t].lineNote)
        }

        // On to the next line, or out of the block.
        commandBlock = block
        commandLine = line
        var next = line + 1
        if lineWanted != 0 {
            next = lineWanted - 1
            lineWanted = 0
        }
        if next > last || leaving != 0 {
            if !keepsLine { next = 0 }
            nextPlace()
            leaving = 0
            keepsLine = false
        }
        line = next

        // A held note stays held over a line that has an instrument and no note, which is how
        // holding is written, or a note that is slid to.
        let ahead = song.blocks[block]
        for t in 0 ..< ahead.tracks where tracks[t].holdLeft >= 0 {
            let cell = module.cell(ahead, line: line, track: t)
            let holds: Bool
            if cell.note == 0 {
                holds = cell.instrument != 0
            } else if cell.note & 0x7F == 0 {
                holds = true
            } else {
                holds = module.command(ahead, page: 0, line: line, track: t).number == 3
            }
            if holds { tracks[t].holdLeft &+= Int8(bitPattern: ticksPerLine) }
        }
    }

    /// Moves to the block that is next in the order of playing: the one after this, or the one a
    /// command has just named. After the last of a section comes the next section, and after the
    /// last section the first.
    private mutating func nextPlace() {
        var tries = 0
        while true {
            var sequence = song.sequences[song.sections[section]]
            var to = position
            if leaving >= 0 { to += 1 }
            if to >= sequence.count {
                section += 1
                if section >= song.sections.count {
                    section = 0
                    wrapped = true
                }
                sequence = song.sequences[song.sections[section]]
                to = 0
            }
            position = to
            let entry = to < sequence.count ? Int(sequence[to]) : 0
            // Numbers from 32768 up are kept for something else, and passed over.
            if entry < 0x8000 || song.version < 2 {
                block = entry < song.blocks.count ? entry : 0
                return
            }
            // An order with nothing in it to play would be gone round for ever.
            tries += 1
            if tries > song.places.count + song.sections.count + 1 {
                stopped = true
                return
            }
            if leaving < 0 { leaving = 1 }
        }
    }

    // MARK: Ticks

    /// A note that has been held as long as it was to be is let go: stopped, or left to fade.
    private mutating func holdAndFade(_ t: Int) {
        if tracks[t].holdLeft >= 0 {
            tracks[t].holdLeft &-= 1
            if tracks[t].holdLeft < 0 {
                if mode == .eightChannel {
                    // Nothing fades in this mode.
                    silence(t)
                } else if tracks[t].soundKind != 0 {
                    // A synthetic sound let go is sent to a place in its volume list: its decay
                    // says which.
                    tracks[t].program.volumeAt = tracks[t].decayOfNote
                    tracks[t].program.volumeWait = 0
                } else {
                    tracks[t].fade = tracks[t].decayOfNote
                    if tracks[t].fade == 0 {
                        if mode == .mixing { silenceInMixing(t) } else { stop(t) }
                    }
                }
            }
        }
        if tracks[t].fade != 0 {
            tracks[t].volume &-= Int8(bitPattern: tracks[t].fade)
            if tracks[t].volume < 0 {
                tracks[t].volume = 0
                tracks[t].fade = 0
            }
        }
    }

    /// One tick of the player's timer. False when the tick is the last of a pass through the tune:
    /// the next would play a line that has been played before, or the tune has run off its end.
    mutating func runTick() -> Bool {
        // The timer is already counting down again from what it was set to before this tick.
        let counting = timer
        if record != nil { record = MEDRegisterTick() }
        defer {
            if mode == .eightChannel {
                // The tick lasts as long as the voices take to play what was mixed for it.
                tickClocks = wordsPlaying * 2 * Self.mixPeriod
            } else {
                tickClocks = (song.beatsPerMinute ? counting + 1 + 3 * (timer + 1) : counting + 1) * Self.clocksPerTimerCount
            }
            if mode != .mixing { tickTime = (tickClocks, Self.chipClock) }
            record?.clocks = tickClocks
            // (In what is written down of the mixing, a tick ends with its tempo: the sound that
            // follows it is that long.)
            if mode == .mixing { mixer.tick(tempo: tempoNow) }
        }
        guard !stopped else { return true }
        if mode == .eightChannel { mixTick() }

        starting = 0
        let next = counter &+ 1
        if Int8(bitPattern: next) >= Int8(bitPattern: ticksPerLine) || next == 0 {
            counter = 0
            // A line that a command has delayed has its commands carried out again, as on its first tick.
            var due = true
            if delay != 0 {
                delay -= 1
                due = delay == 0
            }
            if due {
                playLine()
                if stopped {
                    // The tune has stopped itself: nothing more is done, and the voices are turned off.
                    paula.stop(voices: 15)
                    sounding = 0
                    if mode == .mixing {
                        for t in 0 ..< channels { mixer.silence(t) }
                    }
                    return true
                }
            }
        } else {
            counter = next
        }

        let now = song.blocks[commandBlock]
        let voices = min(channels, now.tracks)
        if record != nil {
            record!.block = commandBlock
            record!.line = commandLine
            record!.tickOfLine = Int(counter)
        }
        for t in 0 ..< voices { holdAndFade(t) }
        tickCommands(now, voices: voices)
        if mode == .eightChannel {
            // Only the periods are passed on: the mixing takes them up on the next tick.
            for t in 0 ..< voices {
                lanes[t].period = tracks[t].period &+ tracks[t].bend &- tracks[t].arpeggio
                tracks[t].bend = 0
                tracks[t].arpeggio = 0
            }
            return endOfTick()
        }
        if mode == .mixing {
            for t in 0 ..< voices {
                let own = tracks[t].program.place >= 0 ? runProgram(t) : tracks[t].period
                let rate = own &+ tracks[t].bend &- tracks[t].arpeggio
                tracks[t].bend = 0
                tracks[t].arpeggio = 0
                let level = tracks[t].tremoloVolume >= 0 ? tracks[t].tremoloVolume : tracks[t].volume
                tracks[t].tremoloVolume = -1
                // (A volume of more than a byte's half is, to OctaMED's mixing, none.)
                let volume = Int((UInt16(UInt8(bitPattern: level)) &* tracks[t].gain) >> 8) & 0xFF
                mixer.setVolume(t, volume > 128 ? 0 : volume, place: t < pans.count ? Int(pans[t]) : 0)
                mixer.setRate(t, Int(rate))
            }
            return endOfTick()
        }
        for t in 0 ..< voices {
            let own = tracks[t].program.place >= 0 ? runProgram(t) : tracks[t].period
            let period = own &+ tracks[t].bend &- tracks[t].arpeggio
            tracks[t].bend = 0
            tracks[t].arpeggio = 0
            let level = tracks[t].tremoloVolume >= 0 ? tracks[t].tremoloVolume : tracks[t].volume
            tracks[t].tremoloVolume = -1
            let volume = (UInt16(UInt8(bitPattern: level)) &* tracks[t].gain) >> 8
            paula.setPeriod(t, period)
            paula.setVolume(t, volume)
            if record != nil {
                record!.voices[t].period = Int(period)
                record!.voices[t].volume = Int(volume)
            }
        }
        // The voices that have a new note start together, and are then told where to go on from
        // when they reach the end of what they have just been given.
        if starting != 0 {
            // A voice that is already on is not started again by being switched on: only a
            // synthetic sound leaves one on for its next note.
            paula.start(voices: starting & ~sounding)
            for t in 0 ..< 4 where starting & sounding & (1 << t) != 0 { paula.noteStruck(t) }
            sounding |= starting
            for t in 0 ..< 4 where starting & (1 << t) != 0 && tracks[t].loopStart != -1 {
                paula.setLocation(t, tracks[t].loopStart)
                paula.setLength(t, tracks[t].loopWords)
                if record != nil { record!.voices[t].loop = stretch(from: tracks[t].loopStart, words: tracks[t].loopWords) }
            }
        }

        return endOfTick()
    }

    /// False if the tick that follows begins a line that has been played before, or the tune has
    /// run off its end: the tick just run was then the last of a pass through the tune.
    private mutating func endOfTick() -> Bool {
        let after = counter &+ 1
        if Int8(bitPattern: after) >= Int8(bitPattern: ticksPerLine) || after == 0, delay <= 1 {
            let row = rowIndex(ofPlace: place, line: line)
            let seen = row.map { visited[$0] } ?? false
            if !seen, !wrapped, !metEarlierSong, let row, let firstPlayedBy, firstPlayedBy[row] < songNumber {
                // On into what a song before this one played, which from here is part of this one.
                metEarlierSong = true
                ledIntoEarlierSong = true
            }
            if seen || wrapped {
                wrapped = false
                visited.update(repeating: false, count: max(1, song.rowsInAll))
                return false
            }
        }
        return true
    }
}
