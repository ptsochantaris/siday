// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// What a module of some other tracker's is made into so that Impulse Tracker's replayer can play it.
///
/// Impulse Tracker read the files of the trackers before it, and played them with a replayer that
/// can do all that theirs could: 64 channels, each anywhere between the speakers, samples of eight
/// bits or sixteen that loop forwards or back and forth, and Scream Tracker's commands under the same
/// letters. A file of a tracker whose own replayer is not here is read into that shape: its samples
/// as Impulse Tracker's, its patterns packed as an IT file packs them, and its commands as the
/// letters that do the same. What such a file asks for that Impulse Tracker cannot do is left out,
/// and each kind of file says what that is.
///
/// A module made this way is played with Impulse Tracker's "old effects" and "compatible Gxx" on, as
/// Impulse Tracker itself played an S3M file: a vibrato as deep as Scream Tracker's and ProTracker's,
/// and a slide to a note that remembers its speed apart from the other slides.
enum IT2ForeignModule {
    /// Impulse Tracker's commands, which are numbered by their letters from A as 1.
    enum Command {
        static let A: UInt8 = 1, B: UInt8 = 2, C: UInt8 = 3, D: UInt8 = 4, E: UInt8 = 5, F: UInt8 = 6, G: UInt8 = 7, H: UInt8 = 8
        static let I: UInt8 = 9, J: UInt8 = 10, K: UInt8 = 11, L: UInt8 = 12, O: UInt8 = 15, Q: UInt8 = 17, R: UInt8 = 18, S: UInt8 = 19
        static let T: UInt8 = 20, U: UInt8 = 21, V: UInt8 = 22, X: UInt8 = 24
    }

    /// The note that cuts a channel's sound off.
    static let noteCut: UInt8 = 254
    /// How many samples and patterns such a module has room for: all that a pattern can name.
    static let sampleRoom = IT2Module.mostSamples, patternRoom = IT2Module.mostPatterns
    /// The header's flags: stereo, "old effects" and "compatible Gxx"; slides by the Amiga's periods;
    /// samples and no instruments.
    static let flags = ITF_STEREO | ITF_OLD_EFFECTS | ITF_COMPAT_GXX

    /// One channel's part of a row: which of a note, an instrument, the volume column and a command
    /// it has (as the bits Impulse Tracker packs them under: 1, 2, 4 and 8), and what they are.
    struct Cell {
        var mask: UInt8 = 0
        var note: UInt8 = 0, instrument: UInt8 = 0, volume: UInt8 = 0, command: UInt8 = 0, value: UInt8 = 0

        var hasNote: Bool { mask & 1 != 0 }
        var hasInstrument: Bool { mask & 2 != 0 }
        var hasVolume: Bool { mask & 4 != 0 }
        var hasCommand: Bool { mask & 8 != 0 }

        mutating func set(note: UInt8) {
            self.note = note
            mask |= 1
        }

        mutating func set(instrument: UInt8) {
            self.instrument = instrument
            mask |= 2
        }

        /// The volume column: 0 to 64 is a volume, and `volumeColumn(pan:)` and
        /// `volumeColumn(command:_:)` give its other meanings.
        mutating func set(volume: UInt8) {
            self.volume = volume
            mask |= 4
        }

        mutating func set(command: UInt8, _ value: UInt8) {
            self.command = command
            self.value = value
            mask |= 8
        }

        mutating func clearCommand() {
            command = 0
            value = 0
            mask &= ~8
        }
    }

    /// A pattern being put together: so many rows of 64 channels.
    struct Pattern {
        let rows: Int
        private(set) var cells: [Cell]

        init(rows: Int = 64) {
            self.rows = rows
            cells = [Cell](repeating: Cell(), count: rows * MAX_HOST_CHANNELS)
        }

        /// A cell; one outside the pattern is empty, and what is put there goes nowhere.
        subscript(row: Int, channel: Int) -> Cell {
            get { row >= 0 && row < rows && channel >= 0 && channel < MAX_HOST_CHANNELS ? cells[row * MAX_HOST_CHANNELS + channel] : Cell() }
            set { if row >= 0, row < rows, channel >= 0, channel < MAX_HOST_CHANNELS { cells[row * MAX_HOST_CHANNELS + channel] = newValue } }
        }

        /// The pattern as an IT file has it: for each row, each channel that has anything (its
        /// number from 1, with the top bit to say that a mask follows; the mask; and what the mask
        /// says is there), and a nought to end the row.
        func packed() -> [UInt8] {
            var bytes: [UInt8] = []
            for row in 0 ..< rows {
                for channel in 0 ..< MAX_HOST_CHANNELS {
                    let cell = cells[row * MAX_HOST_CHANNELS + channel]
                    if cell.mask & 15 == 0 { continue }
                    bytes.append(UInt8(channel + 1) | 0x80)
                    bytes.append(cell.mask & 15)
                    if cell.hasNote { bytes.append(cell.note) }
                    if cell.hasInstrument { bytes.append(cell.instrument) }
                    if cell.hasVolume { bytes.append(cell.volume) }
                    if cell.hasCommand {
                        bytes.append(cell.command)
                        bytes.append(cell.value)
                    }
                }
                bytes.append(0)
            }
            return bytes
        }
    }

    /// One of sixteen places between the speakers, as Impulse Tracker's S8x has them: from 0 at the
    /// left to 64 at the right.
    static func pan(ofSixteen place: UInt8) -> UInt8 {
        let place = Int(place & 15)
        return UInt8(((place << 4 | place) + 2) >> 2)
    }

    /// The volume column's way of putting a note at a place from 0 to 64.
    static func volumeColumn(pan: UInt8) -> UInt8 {
        128 + min(pan, 64)
    }

    /// How fast the volume column's slide to a note goes, for each of its nine settings.
    private static let slideToNoteSpeeds: [UInt8] = [1, 4, 8, 16, 32, 64, 96, 128, 255]

    /// The volume column's way of doing what a command does, where it has one that does exactly
    /// that: its slides of volume and of pitch go by one to nine and no more, its slide to a note at
    /// nine speeds, and its vibrato sets a depth and not a speed.
    static func volumeColumn(command: UInt8, _ value: UInt8) -> UInt8? {
        let high = value >> 4, low = value & 15
        switch command {
        case Command.D:
            if low == 0, high >= 1, high <= 9 { return 85 + high }
            if high == 0, low >= 1, low <= 9 { return 95 + low }
            if low == 15, high >= 1, high <= 9 { return 65 + high }
            if high == 15, low >= 1, low <= 9 { return 75 + low }
        case Command.E:
            if value & 3 == 0, value >= 4, value <= 36 { return 105 + value >> 2 }
        case Command.F:
            if value & 3 == 0, value >= 4, value <= 36 { return 115 + value >> 2 }
        case Command.G:
            if value == 0 { return 193 }
            if let setting = slideToNoteSpeeds.firstIndex(of: value) { return 194 + UInt8(setting) }
        case Command.H:
            if high == 0, low >= 1, low <= 9 { return 203 + low }
        default: break
        }
        return nil
    }

    /// Puts into a cell the commands a file has for it, of which Impulse Tracker has room for one
    /// and whatever the volume column can do. The first that the volume column cannot do has the
    /// command's place, and the volume column takes another if it is free and can; a place between
    /// the speakers goes wherever is left. Says how many had nowhere to go.
    static func place(commands: [(command: UInt8, value: UInt8)], pan: UInt8?, in cell: inout Cell) -> Int {
        var left = 0
        if !commands.isEmpty {
            let main = commands.firstIndex { volumeColumn(command: $0.command, $0.value) == nil } ?? 0
            cell.set(command: commands[main].command, commands[main].value)
            for (index, other) in commands.enumerated() where index != main {
                if !cell.hasVolume, let column = volumeColumn(command: other.command, other.value) {
                    cell.set(volume: column)
                } else {
                    left += 1
                }
            }
        }
        if let pan {
            if !cell.hasVolume {
                cell.set(volume: volumeColumn(pan: Self.pan(ofSixteen: pan)))
            } else if !cell.hasCommand {
                cell.set(command: Command.S, 0x80 | (pan & 15))
            } else {
                left += 1
            }
        }
        return left
    }

    /// A slide of volume as Impulse Tracker's Dxy, Kxy and Lxy take one, from a tracker's that gives
    /// both a way up and a way down and goes by one of them: ProTracker's goes up, Scream Tracker's
    /// down. (Impulse Tracker, given both, does nothing.) A value that Impulse Tracker reads as a
    /// fine slide is one for Scream Tracker too, and is left alone for it.
    static func volumeSlide(_ value: UInt8, upWins: Bool) -> UInt8 {
        let high = value >> 4, low = value & 15
        if high == 0 || low == 0 { return value }
        if upWins { return value & 0xF0 }
        if high == 15 || low == 15 { return value }
        return low
    }

    // MARK: An instrument without a note

    // Impulse Tracker is alone in what it does with a row that names an instrument and no note: if
    // the channel's note has ended, or was of another instrument, it plays the note again. To
    // ProTracker, to Scream Tracker and to those that followed them, such a row sets the channel's
    // volume to the instrument's own and says what the next note is to be played on, and no more;
    // tunes are full of them, to bring back a volume that has been slid away. So such a row is given
    // to Impulse Tracker as the volume alone. It then does not know of the instrument, and the next
    // note on the channel that names none is given it by name, with the volume the channel was last
    // set to, which naming an instrument would otherwise put back to the instrument's own.
    //
    // For that the patterns are gone through in the order the tune plays them, which is as near as
    // can be got to knowing what a channel holds when a row is reached. A pattern that the tune plays
    // in more than one place may be reached with its channels holding other things, and need
    // settling otherwise: it is then written out again, as a pattern of its own for that place.

    /// What a channel holds as the patterns are gone through.
    struct ChannelMemory {
        /// The instrument the tune's own tracker would play the next note on; nought for none yet.
        var instrument: UInt8 = 0
        /// The instrument Impulse Tracker has been told of.
        var told: UInt8 = 0
        /// The volume last set, by an instrument or by a row. (Slides are not followed.)
        var volume: UInt8 = 64
        /// True once a note has been started on the channel.
        var started = false
        /// True if the channel's note has been cut short by SCx and none started since.
        var cut = false
    }

    /// Makes a cell one that Impulse Tracker will take as the tune's own tracker took it, and
    /// remembers what the channel holds after it.
    /// - Parameters:
    ///   - slideStartsNote: what a slide to a note does on a channel that has played nothing yet.
    ///     Impulse Tracker starts the note, and so on its Ultrasound did Scream Tracker; ProTracker
    ///     slid a pitch that nothing was playing at, and the channel stayed silent.
    ///   - cutIsSilence: true if the tune's tracker cut a note short by turning it down to nothing,
    ///     as ProTracker did, so that setting its volume again brought it back. Impulse Tracker ends
    ///     the note. But an instrument named with no note after that is, for once, just what brings
    ///     Impulse Tracker to play the note again, from its start: so there it is left to.
    ///   - ownVolume: the volume of an instrument, by its number; nil if the file has none such.
    static func settle(_ cell: inout Cell, _ memory: inout ChannelMemory, slideStartsNote: Bool = true, cutIsSilence: Bool = false,
                       ownVolume: (UInt8) -> UInt8?) {
        let wasCut = memory.cut && cutIsSilence && memory.started
        if cell.hasNote || (wasCut && cell.hasInstrument) { memory.cut = false }
        if cell.hasCommand, cell.command == Command.S, cell.value & 0xF0 == 0xC0 { memory.cut = true }
        if cell.hasNote, cell.note < 120 {
            let slides = cell.hasCommand && (cell.command == Command.G || cell.command == Command.L)
                || cell.hasVolume && cell.volume >= 193 && cell.volume <= 202
            if slides, !memory.started, !slideStartsNote {
                cell.mask &= ~1
                cell.note = 0
            } else {
                memory.started = true
            }
        }
        if cell.hasInstrument {
            memory.instrument = cell.instrument
            if let volume = ownVolume(cell.instrument) { memory.volume = volume }
            if cell.hasNote || wasCut {
                memory.told = cell.instrument
                // (An instrument with no volume of its own leaves the channel's as it was.)
                if !cell.hasVolume, ownVolume(cell.instrument) == nil { cell.set(volume: memory.volume) }
            } else {
                // The instrument alone: its volume, unless the row has one of its own.
                cell.mask &= ~2
                cell.instrument = 0
                if !cell.hasVolume, let volume = ownVolume(memory.instrument) { cell.set(volume: volume) }
            }
        } else if cell.hasNote, cell.note < 120, memory.instrument != memory.told {
            cell.set(instrument: memory.instrument)
            memory.told = memory.instrument
            if !cell.hasVolume { cell.set(volume: memory.volume) }
        }
        if cell.hasVolume, cell.volume <= 64 { memory.volume = cell.volume }
    }

    /// Goes down a tune's list of patterns and has each settled for its place, by `settled`, which
    /// is given a pattern's number and gives it back packed. Gives all the patterns there then are,
    /// and changes the list to name them: a pattern that came out differently in a later place is
    /// another pattern, numbered after the file's own, while there are numbers left. (254 in the
    /// list is a mark to be passed over, and 255 its end.) The patterns the list never names are
    /// settled last, as if they followed.
    static func settledDownTheList(_ orders: inout [UInt8], patterns count: Int, settled: (Int) -> [UInt8]) -> [[UInt8]?] {
        var packed = [[UInt8]?](repeating: Pattern().packed(), count: patternRoom)
        var versions = [[Int]](repeating: [], count: count)
        var next = count
        func keep(_ bytes: [UInt8], of pattern: Int) -> Int {
            if let same = versions[pattern].first(where: { packed[$0].map { $0 == bytes } ?? false }) { return same }
            var number = pattern
            if !versions[pattern].isEmpty {
                guard next < patternRoom else { return versions[pattern][0] }
                number = next
                next += 1
            }
            packed[number] = bytes
            versions[pattern].append(number)
            return number
        }
        for place in orders.indices {
            if orders[place] == 255 { break }
            let pattern = Int(orders[place])
            if pattern < count { orders[place] = UInt8(keep(settled(pattern), of: pattern)) }
        }
        for pattern in 0 ..< count where versions[pattern].isEmpty { _ = keep(settled(pattern), of: pattern) }
        return packed
    }

    /// The rate a sample is played at, from what its file says. It is what the file says, unless this
    /// player's sound is being set beside libxmp's: libxmp keeps a rate as a number of semitones and
    /// 128ths of one from 8363 Hz, cut short, and so plays every sample up to four fifths of a cent
    /// flat. Two tunes a fraction of a cent apart are the same tune to the ear, but their voices
    /// drift against one another, and no measure of how alike two sounds are sees past that.
    static func rate(_ hz: Int) -> UInt32 {
        guard ITRenderer.roundsRatesAsLibxmp, hz > 0 else { return UInt32(max(0, hz)) }
        let steps = Double(Int(1536.0 * log(Double(hz) / 8363.0) / log(2.0)))
        return UInt32(8363.0 * pow(2.0, steps / 1536.0) + 0.5)
    }

    /// A sample as the replayer holds one, from its sound: signed, eight bits or sixteen.
    /// - Parameters:
    ///   - rate: how many samples a second it plays at for C-5, the note numbered 60.
    ///   - loopEnd: the first sample beyond the part that repeats.
    ///   - pan: where it puts its channel, from 0 to 64 or `PAN_SURROUND`; nil to leave the channel where it is.
    static func sample(sound8: [Int8] = [], sound16: [Int16] = [], volume: UInt8, rate: UInt32, loops: Bool = false, backAndForth: Bool = false,
                       loopStart: Int = 0, loopEnd: Int = 0, pan: UInt8? = nil) -> IT2Sample {
        let s = IT2Sample()
        s.GlobVol = 64
        s.Vol = min(volume, 64)
        s.Cvt = 1
        s.C5Speed = rate
        if let pan { s.DefPan = 0x80 | pan }
        let sixteen = !sound16.isEmpty
        let frames = sixteen ? sound16.count : sound8.count
        guard frames > 0 else { return s }

        let bytes = sixteen ? frames * 2 : frames
        let memory = IT2Module.allocate(bytes)
        s.OrigData = memory
        let data = memory + IT2Module.SMP_DAT_OFFSET
        s.Data = data
        if sixteen {
            sound16.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        } else {
            sound8.withUnsafeBytes { data.copyMemory(from: $0.baseAddress!, byteCount: bytes) }
        }
        s.Length = UInt32(frames)
        s.Flags = SMPF_ASSOCIATED_WITH_HEADER | (sixteen ? SMPF_16BIT : 0)
        // A loop that is not within the sample, or has nothing in it, is no loop.
        let end = min(loopEnd, frames)
        if loops, loopStart >= 0, loopStart < end {
            s.LoopBegin = UInt32(loopStart)
            s.LoopEnd = UInt32(end)
            s.Flags |= SMPF_USE_LOOP | (backAndForth ? SMPF_LOOP_PINGPONG : 0)
        }
        return s
    }
}

// MARK: For comparing

/// What was read from a module, as numbers: for setting beside what another player made of the same
/// file. Every list is in the file's order.
public struct ModuleListing: Sendable {
    public struct Sample: Sendable {
        public var length = 0, loopStart = 0, loopEnd = 0
        public var loops = false, backAndForth = false, sixteenBit = false
        public var volume = 0, rate = 0
        /// Where it puts its channel, from 0 to 64, or 100 for surround; -1 if it leaves it alone.
        public var pan = -1
        /// A sum over its sound, taken as sixteen bits whatever it is.
        public var sum: UInt32 = 0
        /// The rest of what an IT file says of it: how loud it is beside the others, the loop it
        /// holds while its key is down, whether it has two sides, and the vibrato it has of its own.
        public var globalVolume = 0
        public var sustainStart = 0, sustainEnd = 0
        public var sustains = false, sustainBackAndForth = false, stereo = false, hasSound = false
        public var vibratoSpeed = 0, vibratoDepth = 0, vibratoRate = 0, vibratoWave = 0
    }

    /// An envelope: its points as ticks and levels, and the numbers of the points its loops run between.
    public struct Envelope: Sendable {
        public var flags = 0
        public var ticks: [Int] = [], levels: [Int] = []
        public var loopStart = 0, loopEnd = 0, sustainStart = 0, sustainEnd = 0
        /// The point it goes to when its key is let go; 255 for none.
        public var releaseNode = 255
    }

    public struct Instrument: Sendable {
        public var newNoteAction = 0, duplicateCheck = 0, duplicateAction = 0
        public var fadeOut = 0, globalVolume = 0, pan = 0
        public var pitchPanSeparation = 0, pitchPanCentre = 0, randomVolume = 0, randomPan = 0
        public var cutoff = 0, resonance = 0, midiChannel = 0
        /// For each of 120 notes, the note it plays and the sample it plays it on.
        public var notes: [Int] = [], samples: [Int] = []
        public var volume = Envelope(), panning = Envelope(), pitch = Envelope()
    }

    /// One of an MPTM file's songs: where it lies in `orders`, and what it starts with.
    public struct Sequence: Sendable {
        public var first = 0, count = 0, restart = 0, speed = 0
        /// In ten-thousandths.
        public var tempo = 0
    }

    /// What an MPTM file says of its song beyond what an IT file says.
    public struct OpenMPT: Sendable {
        /// 0 for Impulse Tracker's way of keeping time, 1 for OpenMPT's "alternative", 2 for its "modern".
        public var tempoMode = 0
        public var rowsPerBeat = 0, tempoCeiling = 0
        public var swing: [Int] = []
        public var softPanning = false
        public var sequences: [Sequence] = []
        /// For each pattern the file has: its number, its rows, its own rows to a beat and its own swing.
        public var patterns: [(number: Int, rows: Int, rowsPerBeat: Int, swing: [Int])] = []
        /// The values that go on into the rows below their command: where, the value, and how many rows.
        public var longValues: [(pattern: Int, row: Int, channel: Int, value: Int, rows: Int)] = []
    }

    /// One channel's part of a row: -1 for whatever it does not have.
    public struct Cell: Sendable {
        public var pattern = 0, row = 0, channel = 0
        public var note = -1, instrument = -1, volume = -1, command = -1, value = -1
    }

    public var speed = 0, tempo = 0, globalVolume = 0
    public var orders: [Int] = []
    /// Each of 64 channels' place from 0 to 64, or 100 for surround, with 128 added if it is not heard.
    public var pans: [Int] = []
    public var samples: [Sample] = []
    public var cells: [Cell] = []
    public var mixVolume = 0
    /// Each of 64 channels' volume, of 64.
    public var channelVolumes: [Int] = []
    public var instruments: [Instrument] = []
    /// Nil for any module but an MPTM file's.
    public var openMPT: OpenMPT?
}

/// What the replayer was doing on one tick of a tune, as numbers: for the same purpose.
public struct ModuleTick: Sendable {
    public var order = 0, row = 0, tempo = 0, speed = 0
    /// How long the tick lasted, in frames.
    public var frames = 0
    /// For each of the first 32 channels: the rate its sample is played at, in samples a second
    /// (nought for a channel that is silent), its volume of 128, and its place from 0 to 64.
    public var rates: [Int] = [], volumes: [Int] = [], pans: [Int] = []
}

public extension ITRenderer {
    /// For comparing with libxmp, and set by nothing else: see `IT2ForeignModule.rate`.
    nonisolated(unsafe) static var roundsRatesAsLibxmp = false

    /// Where in the file's list of patterns each of the tune's songs starts.
    var songStarts: [Int] { songList.map { $0.start } }

    /// One of the tune's songs (the first, unless another is asked for) played in silence from its
    /// start for so many seconds, tick by tick.
    func ticks(seconds: Double, song: Int = 0) -> [ModuleTick] {
        let player = IT2Player(module, order: song > 0 && song < songList.count ? songList[song].start : 0)
        var ticks: [ModuleTick] = []
        var frames = 0
        while Double(frames) < seconds * Double(outputSampleRate) {
            player.Update()
            if player.cameRound, !ticks.isEmpty { break }
            var tick = ModuleTick()
            tick.order = Int(player.CurrentOrder)
            tick.row = Int(player.CurrentRow)
            tick.tempo = Int(player.Tempo)
            tick.speed = Int(player.CurrentSpeed)
            for channel in 0 ..< 32 {
                let sc = player.sChn + channel
                let sounding = sc.pointee.Flags & SF_CHAN_ON != 0 && sc.pointee.Flags & SF_NOTE_STOP == 0 && sc.pointee.HostChnNum & CHN_DISOWNED == 0
                tick.rates.append(sounding && sc.pointee.FinalVol128 > 0 ? Int(sc.pointee.Frequency) : 0)
                tick.volumes.append(sounding ? Int(sc.pointee.FinalVol128) : 0)
                tick.pans.append(Int(sc.pointee.FinalPan))
            }
            tick.frames = player.mixer.skipTick()
            ticks.append(tick)
            frames += tick.frames
        }
        return ticks
    }

    /// The module as the replayer has it, read back out of what it plays from.
    func listing() -> ModuleListing {
        var listing = ModuleListing()
        listing.speed = Int(module.InitialSpeed)
        listing.tempo = Int(module.InitialTempo)
        listing.globalVolume = Int(module.GlobalVol)
        listing.orders = module.Orders.map { Int($0) }
        listing.pans = module.ChnlPan.map { Int($0) }
        for index in 0 ..< module.sampleLimit {
            guard let s = module.sample(index) else { continue }
            var sample = ModuleListing.Sample()
            sample.length = Int(s.Length)
            sample.loops = s.Flags & SMPF_USE_LOOP != 0
            sample.backAndForth = s.Flags & SMPF_LOOP_PINGPONG != 0
            sample.sixteenBit = s.Flags & SMPF_16BIT != 0
            sample.loopStart = Int(s.LoopBegin)
            sample.loopEnd = Int(s.LoopEnd)
            sample.volume = Int(s.Vol)
            sample.rate = Int(s.C5Speed)
            sample.pan = s.DefPan & 0x80 != 0 ? Int(s.DefPan & 0x7F) : -1
            sample.globalVolume = Int(s.GlobVol)
            sample.sustains = s.Flags & SMPF_USE_SUSTAINLOOP != 0
            sample.sustainBackAndForth = s.Flags & SMPF_SUSTAINLOOP_PINGPONG != 0
            sample.sustainStart = Int(s.SustainLoopBegin)
            sample.sustainEnd = Int(s.SustainLoopEnd)
            sample.stereo = s.Flags & SMPF_STEREO != 0 && s.DataR != nil
            sample.hasSound = s.Data != nil
            sample.vibratoSpeed = Int(s.AutoVibratoSpeed)
            sample.vibratoDepth = Int(s.AutoVibratoDepth)
            sample.vibratoRate = Int(s.AutoVibratoRate)
            sample.vibratoWave = Int(s.AutoVibratoWaveform)
            if let data = s.Data {
                var sum: UInt32 = 0
                for k in 0 ..< Int(s.Length) {
                    let value = sample.sixteenBit ? data.load(fromByteOffset: k * 2, as: Int16.self) : Int16(data.load(fromByteOffset: k, as: Int8.self)) << 8
                    sum = sum &* 31 &+ UInt32(UInt16(bitPattern: value))
                }
                sample.sum = sum
            }
            listing.samples.append(sample)
        }
        for index in 0 ..< module.patternLimit where module.hasPattern(index) {
            let pattern = module.pattern(index)
            var masks = [UInt8](repeating: 0, count: 64)
            var last = [ModuleListing.Cell](repeating: ModuleListing.Cell(), count: 64)
            var at = 0, row = 0
            func next() -> Int {
                at += 1
                return at <= pattern.data.count ? Int(pattern.data[at - 1]) : 0
            }
            while row < Int(pattern.rows), at < pattern.data.count {
                let what = next()
                if what == 0 {
                    row += 1
                    continue
                }
                let channel = ((what & 0x7F) - 1) & 63
                if what & 0x80 != 0 { masks[channel] = UInt8(next()) }
                let mask = masks[channel]
                var cell = ModuleListing.Cell()
                cell.pattern = index
                cell.row = row
                cell.channel = channel
                if mask & 1 != 0 { last[channel].note = next() }
                if mask & 2 != 0 { last[channel].instrument = next() }
                if mask & 4 != 0 { last[channel].volume = next() }
                if mask & 8 != 0 {
                    last[channel].command = next()
                    last[channel].value = next()
                }
                if mask & 0x11 != 0 { cell.note = last[channel].note }
                if mask & 0x22 != 0 { cell.instrument = last[channel].instrument }
                if mask & 0x44 != 0 { cell.volume = last[channel].volume }
                if mask & 0x88 != 0 {
                    cell.command = last[channel].command
                    cell.value = last[channel].value
                }
                listing.cells.append(cell)
            }
        }
        listing.mixVolume = Int(module.MixVolume)
        listing.channelVolumes = module.ChnlVol.map { Int($0) }
        func envelope(_ from: IT2Envelope) -> ModuleListing.Envelope {
            var envelope = ModuleListing.Envelope()
            envelope.flags = Int(from.Flags)
            let count = min(Int(from.Num), from.Tick.count, from.Magnitude.count)
            envelope.ticks = from.Tick[..<count].map { Int($0) }
            envelope.levels = from.Magnitude[..<count].map { Int($0) }
            envelope.loopStart = Int(from.LoopBegin)
            envelope.loopEnd = Int(from.LoopEnd)
            envelope.sustainStart = Int(from.SustainLoopBegin)
            envelope.sustainEnd = Int(from.SustainLoopEnd)
            envelope.releaseNode = Int(from.ReleaseNode)
            return envelope
        }
        for index in 0 ..< (module.usesInstruments ? module.InsNum : 0) {
            let from = module.instrument(index)
            var instrument = ModuleListing.Instrument()
            instrument.newNoteAction = Int(from.NNA)
            instrument.duplicateCheck = Int(from.DCT)
            instrument.duplicateAction = Int(from.DCA)
            instrument.fadeOut = Int(from.FadeOut)
            instrument.globalVolume = Int(from.GlobVol)
            instrument.pan = Int(from.DefPan)
            instrument.pitchPanSeparation = Int(Int8(bitPattern: from.PitchPanSep))
            instrument.pitchPanCentre = Int(from.PitchPanCenter)
            instrument.randomVolume = Int(from.RandVol)
            instrument.randomPan = Int(from.RandPan)
            instrument.cutoff = Int(from.FilterCutoff)
            instrument.resonance = Int(from.FilterResonance)
            instrument.midiChannel = Int(from.MIDIChn)
            instrument.notes = from.SmpNoteTable.map { Int($0 & 0xFF) }
            instrument.samples = from.SmpNoteTable.map { Int($0 >> 8) }
            instrument.volume = envelope(from.VolEnv)
            instrument.panning = envelope(from.PanEnv)
            instrument.pitch = envelope(from.PitchEnv)
            listing.instruments.append(instrument)
        }
        if let song = module.openMPT {
            var openMPT = ModuleListing.OpenMPT()
            openMPT.tempoMode = song.tempoMode == .modern ? 2 : song.tempoMode == .alternative ? 1 : 0
            openMPT.rowsPerBeat = song.rowsPerBeat
            openMPT.tempoCeiling = song.tempoCeiling
            openMPT.swing = song.swing.map { Int($0) }
            openMPT.softPanning = song.softPanning
            for from in song.sequences {
                var sequence = ModuleListing.Sequence()
                sequence.first = from.first
                sequence.count = from.count
                sequence.restart = from.restart
                sequence.speed = Int(from.speed)
                sequence.tempo = from.tempo
                openMPT.sequences.append(sequence)
            }
            for index in 0 ..< module.patternLimit where module.hasPattern(index) {
                openMPT.patterns.append((index, Int(module.pattern(index).rows), index < song.patternRowsPerBeat.count ? Int(song.patternRowsPerBeat[index]) : 0,
                                         index < song.patternSwing.count ? song.patternSwing[index].map { Int($0) } : []))
            }
            for (place, long) in song.longValues {
                openMPT.longValues.append((place >> 16, (place >> 6) & 0x3FF, place & 63, long & 0xFF_FFFF, long >> 24))
            }
            listing.openMPT = openMPT
        }
        return listing
    }
}
