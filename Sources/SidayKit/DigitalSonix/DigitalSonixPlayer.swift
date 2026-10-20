// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the replayer of Dragon's Breath (1990), by Andrew E. Bailey and David M. Hanlon of Digital
// Sonix & Chrome, as Wanted Team adapted it for EaglePlayer ("Digital Sonix & Chrome player module V1.0
// (19 May 2003)", carried by UADE as players/DigitalSonixChrome, whose source UADE also carries as
// amigasrc/players/wanted_team/DigitalSonixChrome/src/Digital Sonix & Chrome_v1.asm). The labels given are
// that source's.

/// The music of Dragon's Breath, by David Hanlon of Digital Sonix & Chrome: samples, and four tracks of
/// one byte a row each, a sample to start or $FF for none; nothing else, no effects, no envelopes. Each of
/// the game's tunes is a file of its own, and so is each of its banks of sound effects, laid out the same.
///
/// The file: a word of tempo, the number of samples and of the song's entries (bytes), the size of the
/// samples' sound and the length of a track (longs); the entries, six bytes each, where in the tracks a
/// pattern begins, how many times it is played, and its rows (an entry played no times ends a song: the
/// file may hold several, and its last entry is all noughts); the four tracks, one after the other; the
/// samples, 18 bytes each, a period, a length in bytes, where its loop begins, how many times it is
/// repeated, where its sound is (from the start of the samples' sound) and its volume; and their sound.
///
/// This is the player itself, as EaglePlayer's module runs it in UADE: what it tells Paula is what that
/// player tells her, tick by tick. It runs fifty times a second, its row every (tempo / 2 + 1,500) / tempo
/// ticks. A sample is started at once: Paula's voice turned off, told its volume, place and length, and
/// once it is quiet its period, and turned on again. Paula's audio interrupts then count the sample's
/// repeats: at its start, and each time she goes round, the player tells her what to play next, its loop
/// until it has been repeated as many times as the sample says, and then four bytes of silence. (They come
/// at most once a tick here, at the start of the tick after she has gone round: every loop of UnExoticA's
/// files lasts several ticks, so that what she is told still comes before she goes round again.) In UADE
/// about one note in forty has its first interrupt lost, the player clearing its request just after the
/// beam's line has begun and Paula has asked it (when that falls depends on the machine's timing to a
/// few clocks), and so its sample is played once more before its loop or its silence: that is the
/// machine's chance, not the player's meaning, and is not followed.
///
/// Each voice's writes are told Paula at their moments in the tick (`TFMXOutput.timed(at:)`), as they fall
/// in UADE: a note's sample is told it as it is turned off, and its period and its DMA turned on some 500
/// of Paula's clocks later, once the voice is quiet (the player waits on its audio interrupt for it); and
/// the next voice's note some 800 clocks after the one before (the medians of UADE's dumps of the music).
///
/// A song goes round, from the entry it began at, once it has played its last; a song of no entries (the
/// last of fanfares.dsc's four, which is only the file's closing entry, and which the player would read
/// on from through all its memory) is not counted as one. A track read past the file reads nothing.
struct DigitalSonixPlayer: ~Copyable {
    /// The module and what follows it, as Paula reads them.
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed, and the four bytes of silence (`Empty`) the
    /// interrupts give a sample once it has been repeated: the noughts after the module.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt + 0x20000 }
    static let mixingSpace = 2048

    private let fileSize: Int
    let sampleCount: Int
    private let entryCount: Int
    private let trackLength: Int
    /// Where the tracks, the samples' table and their sound begin, in the module.
    private let tracksAt: Int
    private let samplesAt: Int
    private let soundAt: Int
    /// The ticks a row (`lbB008082`).
    let speed: UInt8
    /// The entry each song begins at.
    private let songStarts: [Int]

    var songCount: Int { songStarts.count }
    private(set) var song = 0
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    // The player's variables, named as its source names them.
    /// The entry being played (`lbL008072`), the row of it (`lbL008076`), the song's first entry
    /// (`lbL00807A`), the times its pattern is still to be played (`lbL00807E`), and where in the first
    /// track the next row is (`lbL008330`, as a place in the module).
    private var entry = 0
    private var row = 0
    private var firstEntry = 0
    private var timesLeft = 0
    private var pointer = 0
    /// The ticks left of the row (`lbB008083`).
    private var countdown: UInt8 = 1
    /// For each voice, what its interrupts are still to do (`lbW00808C`): the repeats of its sample's
    /// loop after which it is given silence; -1 once it has been.
    private var repeatsLeft = InlineArray<4, Int>(repeating: -1)
    /// What each of Paula's period and volume registers was last given, and what they held as the tick
    /// just run began (what `PaulaTickRenderer` sets Paula to then, before the tick's writes are told).
    private var periods = InlineArray<4, UInt16>(repeating: 0)
    private var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var periodsBefore = InlineArray<4, UInt16>(repeating: 0)
    private var volumesBefore = InlineArray<4, UInt16>(repeating: 0)

    /// How long each tick is: the player is run by EaglePlayer's timer (it has an interrupt and does not
    /// start one of its own), which UADE's runs on a CIA's timer from $376B (score.s,
    /// `cia_timer_base_value`), 70,940 of Paula's clocks.
    static let tickClocks = (0x376B + 1) * 5
    /// A song that has not come to its end in an hour is taken never to.
    private static let mostTicks = 50 * 60 * 60

    /// Where in the tick, in Paula's clocks, the player's writes fall in UADE (see the type's comment):
    /// the first voice's note (a guess: only the distances between the voices are heard), its DMA turned
    /// on after it, and the next voice's note.
    static let firstNote = 300
    static let onClocks = 500
    static let voiceClocks = 800

    // MARK: - Reading

    @inline(__always) private static func byte(_ data: [UInt8], _ at: Int) -> UInt8 { at >= 0 && at < data.count ? data[at] : 0 }
    @inline(__always) private static func word(_ data: [UInt8], _ at: Int) -> UInt16 {
        UInt16(byte(data, at)) << 8 | UInt16(byte(data, at + 1))
    }
    @inline(__always) private static func long(_ data: [UInt8], _ at: Int) -> UInt32 {
        UInt32(word(data, at)) << 16 | UInt32(word(data, at + 2))
    }

    @inline(__always) private func byte(_ at: Int) -> UInt8 { at >= 0 && at < fileSize ? memory[at] : 0 }
    @inline(__always) private func word(_ at: Int) -> UInt16 { UInt16(byte(at)) << 8 | UInt16(byte(at + 1)) }
    @inline(__always) private func long(_ at: Int) -> UInt32 { UInt32(word(at)) << 16 | UInt32(word(at + 2)) }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check2`; it has no mark of its own): a tempo, samples
    /// and entries; samples' sound of an even size, no more than 512K and less than the file; tracks of
    /// no more than 128K; each entry but the last a place, even, no more than 128K, and the last all
    /// noughts; the samples' table within the file; and each sample's length, more than nought, and its
    /// place, within the samples' sound, the last ending where it ends.
    static func isOne(_ data: [UInt8]) -> Bool {
        guard data.count >= 12 else { return false }
        let samples = Int(data[2]), entries = Int(data[3])
        let soundSize = long(data, 4), trackLength = long(data, 8)
        guard word(data, 0) != 0, samples != 0, entries >= 2 else { return false }
        guard soundSize != 0, soundSize & 1 == 0, soundSize <= 0x80000, Int(soundSize) < data.count else { return false }
        guard trackLength != 0, trackLength <= 0x20000 else { return false }
        for i in 0 ..< entries - 1 {
            let place = long(data, 12 + 6 * i)
            guard place & 0x8000_0000 == 0, place & 1 == 0, place <= 0x20000 else { return false }
        }
        let last = 12 + 6 * (entries - 1)
        guard last + 6 <= data.count, long(data, last) == 0, word(data, last + 4) == 0 else { return false }
        let table = 12 + 6 * entries + 4 * Int(trackLength)
        let end = table + 18 * samples
        guard end < data.count else { return false }
        var place: UInt32 = 0
        for s in 0 ..< samples {
            let length = long(data, table + 18 * s + 2)
            guard length != 0, length & 0x8000_0000 == 0, length <= soundSize else { return false }
            place = long(data, table + 18 * s + 12)
            guard place <= soundSize else { return false }
        }
        return place &+ long(data, end - 16) == soundSize
    }

    /// Reads the module and starts song `song` (the first, if it has no such song). A module shorter than
    /// its samples' sound is refused, as `InitPlayer` refuses it.
    init(_ data: [UInt8], song: Int = 0) throws(TuneError) {
        fileSize = data.count
        silenceAt = (data.count + 15) & ~15
        memoryCapacity = silenceAt + 0x20000 + Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[i] = b }
        sampleCount = Int(Self.byte(data, 2))
        entryCount = Int(Self.byte(data, 3))
        trackLength = Int(min(0x20000, Self.long(data, 8)))
        tracksAt = 12 + 6 * entryCount
        samplesAt = tracksAt + 4 * trackLength
        soundAt = samplesAt + 18 * sampleCount
        // (`InstallSamples`: the tempo, a word with its sign, halved and 1,500 added, over itself, as the
        // player's routine for dividing longs with their signs does it.)
        let tempo = Int(Int16(bitPattern: Self.word(data, 0)))
        speed = tempo == 0 ? 1 : UInt8(truncatingIfNeeded: (tempo / 2 + 1500) / tempo)
        // The songs: each ends at an entry played no times (`InitPlayer` counts them); one that has no
        // entries before its end is none.
        var starts: [Int] = []
        var begun = 0
        for i in 0 ..< entryCount where Self.byte(data, 12 + 6 * i + 4) == 0 {
            if i > begun { starts.append(begun) }
            begun = i + 1
        }
        songStarts = starts
        // (Refused only once it is all made, that it may be undone as a whole.)
        guard Self.isOne(data) else { throw .malformed("not a Digital Sonix & Chrome module") }
        guard soundAt + Int(Self.long(data, 4)) <= data.count else { throw .malformed("the module is cut short") }
        guard !songStarts.isEmpty else { throw .malformed("the module has no song") }
        try select(song: song >= 0 && song < songCount ? song : 0)
    }

    deinit { memory.deallocate() }
}

// MARK: - Playing

extension DigitalSonixPlayer {
    /// Starts song `song`; and finds how long it is, played through to its end for up to an hour.
    mutating func select(song: Int) throws(TuneError) {
        guard song >= 0, song < songCount else { throw .unsupported("there is no song \(song + 1)") }
        self.song = song
        start()
        var none = TFMXSilentOutput()
        var ticks = 0
        while endings == 0, ticks < Self.mostTicks {
            _ = run(&none)
            ticks += 1
        }
        // (It comes to its end at its last row, whose ticks are still to be heard.)
        lengthClocks = endings > 0 ? UInt64(ticks - 1 + (speed == 0 ? 256 : Int(speed))) * UInt64(Self.tickClocks) : nil
        start()
    }

    /// `InitSound` and `Init`: the song from its first entry, its first row at the first tick.
    private mutating func start() {
        firstEntry = songStarts[song]
        entry = firstEntry
        row = 0
        pointer = entryPlace(entry)
        timesLeft = Int(byte(12 + 6 * entry + 4))
        countdown = 1
        repeatsLeft = .init(repeating: -1)
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        periodsBefore = .init(repeating: 0)
        volumesBefore = .init(repeating: 0)
        endings = 0
    }

    /// Where an entry's pattern begins in the first track, as a place in the module (`InstallSamples`
    /// makes each entry's place an address, from the tracks' start).
    private func entryPlace(_ entry: Int) -> Int { tracksAt + Int(long(12 + 6 * entry)) }

    /// The player's interrupt (`Play`), for a tick; and, at its start, what Paula's audio interrupts did
    /// since the tick before (`Audio0` to `Audio3`). Returns the tick's length in milliseconds (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        periodsBefore = periods
        volumesBefore = volumes
        // A voice whose loop has been repeated as many times as its sample says is given silence, to
        // play once she goes round again.
        for v in 0 ..< 4 where repeatsLeft[v] >= 0 && Int(output.loopCount(v)) >= repeatsLeft[v] {
            repeatsLeft[v] = -1
            output.takeNextBuffer(v, start: silenceAt, length: 2)
        }
        countdown &-= 1
        if countdown == 0 {
            countdown = speed
            playRow(&output)
        }
        return 20
    }

    /// `lbC005400`: each voice's byte of the row, and the row on; at the end of the entry's rows, its
    /// pattern again or the next entry, and at an entry played no times, the song's first again (telling
    /// EaglePlayer that the song has come to its end).
    private mutating func playRow<Output: TFMXOutput>(_ output: inout Output) {
        var at = Self.firstNote
        for v in 0 ..< 4 {
            let place = pointer + v * trackLength
            // (A track read past the file reads nothing.)
            let number = place < fileSize ? Int(byte(place)) : 0xFF
            if number != 0xFF, number < sampleCount {
                startSample(v, number, at: at, &output)
                at += Self.voiceClocks
            }
        }
        pointer += 1
        row += 1
        guard row == Int(byte(12 + 6 * entry + 5)) else { return }
        row = 0
        timesLeft -= 1
        if timesLeft != 0 {
            pointer = entryPlace(entry)
            return
        }
        entry += 1
        if entry >= entryCount || byte(12 + 6 * entry + 4) == 0 {
            entry = firstEntry
            endings += 1
        }
        pointer = entryPlace(entry)
        timesLeft = Int(byte(12 + 6 * entry + 4))
    }

    /// `lbC005936`: sample `number` started on voice `v`: the voice turned off, told the sample's volume,
    /// place and length, and once it is quiet its period, and turned on; and, by the interrupt at its start,
    /// what it is to play next, its loop if it is to be repeated, or else silence.
    private mutating func startSample<Output: TFMXOutput>(_ v: Int, _ number: Int, at: Int, _ output: inout Output) {
        let record = samplesAt + 18 * number
        let length = long(record + 2)
        let loopStart = long(record + 6)
        let repeats = Int(word(record + 10))
        let place = soundAt + Int(long(record + 12) & 0x7FFFF)
        // (`ChangeVolume`: seven bits, times EaglePlayer's 64, over 64.)
        volumes[v] = UInt16(byte(record + 16) & 0x7F)
        periods[v] = word(record)
        output.timed(at: at)
        output.off(v)
        output.writeVolume(v, min(64, volumes[v]))
        output.takeNextBuffer(v, start: place, length: UInt16(truncatingIfNeeded: length >> 1))
        output.timed(at: at + Self.onClocks)
        output.writePeriod(v, periods[v])
        output.on(v)
        if repeats == 0 {
            repeatsLeft[v] = -1
            output.takeNextBuffer(v, start: silenceAt, length: 2)
        } else {
            // (The loop's length, the sample's less where it begins, halved with its sign.)
            repeatsLeft[v] = repeats
            let loopLength = Int32(bitPattern: length &- loopStart) >> 1
            output.takeNextBuffer(v, start: place + Int(loopStart & 0x7FFFF), length: UInt16(truncatingIfNeeded: loopLength))
        }
    }

    /// Paula's period for the voice as the tick just run began (its writes in the tick are told at their
    /// moments).
    func period(_ voice: Int) -> UInt16 { periodsBefore[voice] }
    /// Paula's volume for the voice as the tick just run began, as she takes it: no more than 64.
    func volume(_ voice: Int) -> UInt16 { min(64, volumesBefore[voice]) }
    /// What the player last gave Paula's period register for the voice.
    func periodWritten(_ voice: Int) -> UInt16 { periods[voice] }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// Digital Sonix & Chrome's music, played on Paula by `PaulaTickRenderer`.
extension DigitalSonixPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Digital Sonix & Chrome")
        let plural = sampleCount == 1 ? "" : "s"
        info.detail = "David Hanlon's music for Dragon's Breath, the game's own replayer; \(sampleCount) sample\(plural)"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { Self.tickClocks }
}
