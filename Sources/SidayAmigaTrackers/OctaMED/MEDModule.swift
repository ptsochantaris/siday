// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written for siday from the published description of the file format (Teijo Kinnunen's "MED/OctaMED
// MMD0/MMD1/MMD2/MMD3 file formats", revision 6). No code here is taken from OctaMED or from any
// other player.

import SidayFoundation

private extension ByteReader {
    /// Four bytes as a number, the first the most: a place in a file, or a length. One too large to
    /// be either is brought down to where it is still neither, and can still be added to. (A file
    /// with nonsense in it has numbers of all sizes, and a whole number in a browser has only 32
    /// bits: the largest would come out below nought there, or past what can be counted.)
    func long(_ i: Int) -> Int {
        let high = u16be(i)
        return high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | u16be(i + 2)
    }
}

/// A module made with MED or OctaMED on the Amiga: a file that begins "MMD0", "MMD1", "MMD2" or "MMD3".
///
/// Such a file is a set of structures that point at one another, by how far each is from the start
/// of the file. One file can hold several songs, each with its own blocks (which is what MED calls
/// patterns) and its own order to play them in, all sharing one set of instruments.
///
/// A block is as many tracks wide and as many lines long as its composer liked. A note on a line
/// may have several commands, a first beside it and more on further pages of the block. The four
/// kinds of file differ in how much of this they can say, and all of them are read into one shape.
///
/// The samples are not copied out. The whole file is the memory the sound chip plays from, as it was
/// on the Amiga, where the file was loaded in one piece: so a loop that runs past the end of its
/// sample goes on into whatever follows it in the file, as it did there.
final class MEDModule {
    /// What an instrument is made of.
    enum Kind: Equatable {
        /// Nothing in this file: an empty place, or an instrument for a MIDI synthesiser.
        case absent
        /// A sample, eight bits.
        case sample
        /// A sample recorded several times over, each an octave below the one before and twice as
        /// long, so that low notes need not be played slowly: so many of them, the highest first.
        case octaves(Int)
        /// A sample that may be played two octaves lower than others.
        case extended
        /// A sound the player makes itself from short waveforms and two lists of instructions.
        case synthetic
        case unknown
    }

    struct Instrument {
        var name = ""
        var kind = Kind.absent
        /// Where the sample is in the file, and how long it is, in bytes. A stereo sample is two of
        /// that length, the left and then the right.
        var offset = 0
        var length = 0
        var stereo = false
        /// True for a sample of sixteen bits, which the Amiga's own sound chip cannot play and
        /// OctaMED's mixing can. Its length is still in bytes, a side.
        var sixteenBit = false
        /// Its volume, up to 64, and how many semitones its notes are moved by. These are the song's.
        var volume: UInt8 = 0
        var transpose: Int8 = 0
        /// How many ticks a note is held before it is let go; nought for as long as it likes. And how
        /// fast it then fades: nought to stop at once.
        var hold: UInt8 = 0
        var decay: UInt8 = 0
        var fineTune: Int8 = 0
        var loops = false
        /// True if it repeats by going back and forth over the part that repeats.
        var backAndForth = false
        /// The part that repeats, in bytes from the sample's start (or for the mixing of a sample
        /// of sixteen bits, in samples).
        var repeatStart = 0
        var repeatLength = 0
        /// And as the song being played has it, in words: which is all that five-to-eight channel
        /// mode goes by.
        var shortRepeatStart = 0
        var shortRepeatWords = 0
        /// Nought for the Amiga's own sound chip. Anything else is a sound card, and is not heard.
        var outputDevice: UInt8 = 0
        /// The MIDI channel its notes are sent out on, as the song has it; nought for none. Nothing
        /// is played by it: it is kept so that an instrument that is nothing else can be said to be
        /// one that is not heard.
        var midiChannel: UInt8 = 0
        /// For a synthetic sound, where its structure is in the file: the two lists of instructions
        /// and the table of its waveforms. A hybrid sound has one too, and is otherwise the sample
        /// that the lists are played on. For a plain sample, -1.
        var program = -1

        var isHybrid: Bool { program >= 0 && kind != .synthetic }
    }

    /// One place in a block: a note and an instrument. The commands are kept apart.
    struct Cell {
        /// The note as the file has it: nought for none, 1 for the lowest C.
        var note: UInt8 = 0
        var instrument: UInt8 = 0
    }

    struct Command {
        var number: UInt8 = 0
        var data: UInt8 = 0
    }

    struct Block {
        var tracks = 0
        var lines = 0
        /// How many commands a note has: one, and one more for each further page.
        var pages = 1
        /// Where its notes and commands begin in `cells` and `commands`.
        var firstCell = 0
        var firstCommand = 0
        /// Where they are in the file: the notes with their first commands, and each further page.
        /// And whether the notes are the three bytes of the oldest kind of file, or four.
        var notesInFile = -1
        var pagesInFile: [Int] = []
        var old = false
    }

    /// What a song needs to be played on.
    enum Mode: Equatable {
        /// The Amiga's four voices, each track straight to one of them.
        case fourChannel
        /// OctaMED's way of getting five to eight tracks out of four voices, by mixing two into one.
        case eightChannel
        /// OctaMED Soundstudio's mixing of any number of tracks in software.
        case mixing
    }

    struct Song {
        var title = ""
        /// Which of the four kinds of file its structures are of. The songs of one file need not agree.
        var version = 0
        var mode = Mode.fourChannel
        var instruments = [Instrument](repeating: Instrument(), count: MEDModule.mostInstruments)
        var blocks: [Block] = []
        /// The order of playing: a list of sections, each of them naming one of the sequences, which
        /// are lists of blocks. The older kinds of file have one sequence and so one section.
        var sections: [Int] = []
        var sequences: [[UInt16]] = []
        var firstSection = 0
        /// The tempo: either beats a minute, or a number that sets the timer directly.
        var tempo = 0
        var ticksPerLine = 6
        var beatsPerMinute = false
        /// In beats a minute, how many lines make a beat.
        var linesPerBeat = 1
        var transpose: Int8 = 0
        var flags: UInt8 = 0
        var masterVolume: UInt8 = 64
        var trackVolumes: [UInt8] = []
        /// In five-to-eight channel mode, which of the four voices have two tracks mixed into them.
        /// Eight channels is all four; with fewer, the first voices are left a track each.
        var mixed = [true, true, true, true]

        // What a song in mixing mode says of its mixing.
        /// How many tracks are mixed: tracks beyond these are not heard.
        var channels = 4
        /// False to mix everything to the middle.
        var stereo = false
        /// True if tracks may be placed anywhere between the sides, and not only on one or the other.
        var freePan = false
        /// A percentage by which the whole is louder or quieter; nought for as it is.
        var volumeAdjust = 0
        /// The echo: 0 for none, 1 for an echo, 2 for one that crosses from side to side; how many
        /// times it is halved each time round; and how long it takes, in milliseconds.
        var echo = 0, echoDepth = 0, echoLength = 0
        /// How far apart the sides are kept, from -4 to 4.
        var separation = 0
        /// Where each track lies between left (-16) and right (16).
        var trackPans: [Int8] = []
        /// The samples the file ends before the end of. (Nothing is played by it.)
        var cutShort = Shortfall.CutShort()

        var filterOn: Bool { flags & 0x01 != 0 }
        /// Volumes in commands are written in hexadecimal, and not as two decimal digits.
        var hexVolumes: Bool { flags & 0x10 != 0 }
        /// Slides do nothing on the first tick of a line, as in the trackers MED grew up beside.
        var slidesSkipFirstTick: Bool { flags & 0x20 != 0 }

        /// Every place in the order of playing, as a section and how far into its sequence.
        var places: [(section: Int, position: Int)] = []
        /// For a table with one entry for every line of every place: where each place's lines begin.
        var firstRowOfPlace: [Int] = []
        var rowsInAll = 0
        /// Where a section's places begin in `places`.
        var firstPlaceOfSection: [Int] = []
    }

    static let mostInstruments = 63
    /// More tracks than this the player has no room for.
    static let mostTracks = 64
    private static let mostSongs = 64
    /// A voice with nothing to play is pointed here, after the file: a stretch of silence.
    private static let silenceLength = 16
    /// The most that is mixed for a voice in one tick of five-to-eight channel mode, in bytes; and
    /// how many such stretches each voice has room for after the silence. (OctaMED made do with
    /// two, one playing while the other was filled. A third leaves the chip, which here keeps its
    /// own time, a tick's grace to get from one to the next.)
    static let mixBufferSize = 800, mixBuffers = 3

    private(set) var songs: [Song] = []
    let comment: String
    /// The file, and silence after it: what the sound chip plays from.
    let memory: UnsafeMutablePointer<Int8>
    let memorySize: Int
    let silence: Int
    /// Where the stretches that tracks are mixed into begin: a voice's own lie one after another.
    let mixSpace: Int
    let cells: UnsafeMutablePointer<Cell>
    let commands: UnsafeMutablePointer<Command>
    /// True if the file has a sample or a loop that the sound chip cannot be given directly: one of
    /// 128 KB or more, or a loop that begins or ends on an odd byte. OctaMED then plays every sample
    /// by copying it, a little at a time, to where the chip is reading.
    let playsThroughBuffers: Bool
    /// For a song saved in MED's first format (see `MED4File`), which MED saved it and what of it
    /// could not be read into a module; nil for a module.
    let firstFormat: (detail: String, shortfalls: [String])?

    deinit {
        memory.deallocate()
        cells.deallocate()
        commands.deallocate()
    }

    /// A byte of the file as it lay in the Amiga's memory; nought beyond its end.
    @inline(__always) func byte(_ at: Int) -> UInt8 {
        at >= 0 && at < silence ? UInt8(bitPattern: memory[at]) : 0
    }

    @inline(__always) func word(_ at: Int) -> Int {
        Int(byte(at)) << 8 | Int(byte(at + 1))
    }

    /// Where a synthetic sound keeps one of its waveforms, by the waveform's number: the two bytes
    /// of its length, in words, with the waveform after them.
    ///
    /// The sound has a table of these places, each written as how far it is from the sound's own
    /// start, and a count of how many it has. A number beyond the count finds whatever is in the
    /// table there, which on the Amiga was then taken for a place in the machine's memory: here it
    /// is the silence after the file.
    func waveform(_ number: Int, of program: Int) -> Int {
        guard number >= 0, number < word(program + 20) else { return silence }
        let entry = program + 278 + number * 4
        let high = word(entry)
        guard high < 0x4000 else { return silence }
        let to = program &+ (high << 16 | word(entry + 2))
        return to >= 0 && to < silence ? to : silence
    }

    /// The note and instrument on a line of a block.
    ///
    /// A tune can be sent to a line that its block has not got. OctaMED's player then reads on past
    /// the end of the block, into whatever comes after it in the file, and takes that for notes and
    /// commands: so that is what is read here, too.
    @inline(__always) func cell(_ block: Block, line: Int, track: Int) -> Cell {
        guard line >= 0, track >= 0, track < block.tracks else { return Cell() }
        if line < block.lines { return cells[block.firstCell + line * block.tracks + track] }
        guard block.notesInFile >= 0 else { return Cell() }
        let p = block.notesInFile + (line * block.tracks + track) * (block.old ? 3 : 4)
        return block.old ? Self.oldCell(byte(p), byte(p + 1)) : Cell(note: byte(p), instrument: byte(p + 1) & 0x3F)
    }

    @inline(__always) func command(_ block: Block, page: Int, line: Int, track: Int) -> Command {
        guard line >= 0, track >= 0, track < block.tracks, page >= 0, page < block.pages else { return Command() }
        if line < block.lines { return commands[block.firstCommand + (page * block.lines + line) * block.tracks + track] }
        guard block.notesInFile >= 0 else { return Command() }
        let place = line * block.tracks + track
        if page > 0 {
            let p = block.pagesInFile[page - 1] + place * 2
            return Command(number: byte(p), data: byte(p + 1))
        }
        let p = block.notesInFile + place * (block.old ? 3 : 4)
        return block.old ? Command(number: byte(p + 1) & 0x0F, data: byte(p + 2)) : Command(number: byte(p + 2), data: byte(p + 3))
    }

    /// In the oldest kind of file a note is six bits, and the instrument's number is in three pieces.
    private static func oldCell(_ first: UInt8, _ second: UInt8) -> Cell {
        Cell(note: first & 0x3F, instrument: second >> 4 | (first & 0x80) >> 3 | (first & 0x40) >> 1)
    }

    /// Which instrument's sample a place in the memory is in, counting from 1, and how far into it:
    /// nought for a place that is in none.
    func instrument(at place: Int, song: Int) -> (number: Int, offset: Int) {
        guard place < silence else { return (0, 0) }
        for (i, instrument) in songs[song].instruments.enumerated() where instrument.kind != .absent {
            let length = max(1, instrument.length) * (instrument.stereo ? 2 : 1)
            if place >= instrument.offset, place < instrument.offset + length { return (i + 1, place - instrument.offset) }
        }
        return (0, 0)
    }

    init(_ file: [UInt8]) throws {
        var data = file
        if MMDCFile.isOne(data) { data = try MMDCFile.mmd0(data) }
        if MED4File.isOne(data) {
            let read = try MED4File.mmd0(data)
            data = read.file
            firstFormat = (read.detail, read.shortfalls)
        } else {
            firstFormat = nil
        }
        let file = ByteReader(data)
        let size = data.count
        func tag(_ at: Int, _ text: StaticString) -> Bool {
            text.withUTF8Buffer { letters in (0 ..< letters.count).allSatisfy { file[at + $0] == letters[$0] } }
        }
        if tag(0, "MED"), file[3] >= 2, file[3] <= 3 {
            throw TuneError.unsupported("a song in one of MED's first formats (MED2, MED3): only MED4 and its modules, MMD0 to MMD3, are played")
        }
        guard size >= 52, tag(0, "MMD"), file[3] >= 0x30, file[3] <= 0x33 else { throw TuneError.malformed("not a MED module") }

        /// A place in the file that something is said to be at, or nil if there is nothing there.
        func pointer(_ at: Int) -> Int? {
            let to = file.long(at)
            return to > 0 && to < size ? to : nil
        }

        // The songs: each has a header like the file's own, found from the one before it. (There are
        // files that say where a next song is and have none there: a song's header says it is one.)
        var headers = [0]
        while headers.count < Self.mostSongs, let expansion = pointer(headers[headers.count - 1] + 32), let next = pointer(expansion),
              next + 52 <= size, !headers.contains(next), tag(next, "MCN") || tag(next, "MMD") {
            headers.append(next)
        }
        // What is said of the instruments beyond their eight bytes in a song is said once, for the
        // first song, and so is where they repeat.
        let first = try Self.places(of: 0, file, size)
        let expansion = pointer(32)
        let extras = expansion.flatMap { pointer($0 + 4) }
        let extraCount = expansion.map { min(Self.mostInstruments, file.u16be($0 + 8)) } ?? 0
        let extraSize = expansion.map { file.u16be($0 + 10) } ?? 0
        var shared = [Instrument](repeating: Instrument(), count: Self.mostInstruments)
        for i in 0 ..< Self.mostInstruments {
            let entry = first.song + i * 8
            let repeatStart = file.u16be(entry) * 2, repeatLength = file.u16be(entry + 2) * 2
            if let extras, extraCount > 0 {
                // An instrument the list does not reach has nothing said of it, and does not repeat.
                guard i < extraCount else { continue }
                let extra = extras + i * extraSize
                shared[i].hold = file[extra]
                shared[i].decay = file[extra + 1]
                if extraSize >= 4 {
                    let fineTune = Int8(bitPattern: file[extra + 3])
                    if fineTune >= -8, fineTune <= 7 { shared[i].fineTune = fineTune }
                }
                shared[i].loops = extraSize >= 6 ? file[extra + 5] & 1 != 0 : repeatLength > 2
                shared[i].backAndForth = extraSize >= 6 && file[extra + 5] & 8 != 0
                if extraSize >= 9 { shared[i].outputDevice = file[extra + 8] }
                if extraSize >= 18 {
                    shared[i].repeatStart = file.long(extra + 10)
                    shared[i].repeatLength = file.long(extra + 14)
                } else {
                    shared[i].repeatStart = repeatStart
                    shared[i].repeatLength = repeatLength
                }
            } else {
                shared[i].loops = repeatLength > 2
                shared[i].repeatStart = repeatStart
                shared[i].repeatLength = repeatLength
            }
        }
        if let expansion, let names = pointer(expansion + 20) {
            let count = min(Self.mostInstruments, file.u16be(expansion + 24)), each = file.u16be(expansion + 26)
            for i in 0 ..< count where each > 0 {
                shared[i].name = Self.text(file, at: names + i * each, length: min(each, 40))
            }
        }
        var comment = ""
        if let expansion, let text = pointer(expansion + 12) {
            comment = Self.text(file, at: text, length: min(file.long(expansion + 16), 4096))
        }
        self.comment = comment

        // The blocks of every song, into one run of notes and one of commands.
        var songs: [Song] = []
        var cells: [Cell] = []
        var commands: [Command] = []
        for header in headers {
            var song = try Self.song(at: header, file, size, shared: shared)
            let at = try Self.places(of: header, file, size)
            let blockCount = file.u16be(at.song + 504)
            for number in 0 ..< blockCount {
                var block = Block(tracks: 4, lines: 1, pages: 1, firstCell: cells.count, firstCommand: commands.count)
                guard let blocks = at.blocks, let start = pointer(blocks + number * 4) else {
                    // A block that is not there is played as one empty line.
                    cells.append(contentsOf: [Cell](repeating: Cell(), count: 4))
                    commands.append(contentsOf: [Command](repeating: Command(), count: 4))
                    song.blocks.append(block)
                    continue
                }
                let old = song.version == 0
                block.tracks = old ? Int(file[start]) : file.u16be(start)
                block.lines = (old ? Int(file[start + 1]) : file.u16be(start + 2)) + 1
                guard block.tracks <= Self.mostTracks else {
                    throw TuneError.unsupported("a MED module with a block of \(block.tracks) tracks")
                }
                let notes = start + (old ? 2 : 8), each = old ? 3 : 4
                let count = block.tracks * block.lines
                guard notes + count * each <= size else { throw TuneError.malformed("a MED module cut short in the middle of a block") }
                // The further pages of commands.
                var pages: [Int] = []
                if !old, let about = pointer(start + 4), let table = pointer(about + 12) {
                    for page in 0 ..< min(file.u16be(table), 32) {
                        guard let commands = pointer(table + 4 + page * 4), commands + count * 2 <= size else { break }
                        pages.append(commands)
                    }
                }
                block.pages = 1 + pages.count
                block.notesInFile = notes
                block.pagesInFile = pages
                block.old = old
                cells.reserveCapacity(cells.count + count)
                commands.reserveCapacity(commands.count + count * block.pages)
                for i in 0 ..< count {
                    let p = notes + i * each
                    if old {
                        cells.append(Self.oldCell(file[p], file[p + 1]))
                        commands.append(Command(number: file[p + 1] & 0x0F, data: file[p + 2]))
                    } else {
                        cells.append(Cell(note: file[p], instrument: file[p + 1] & 0x3F))
                        commands.append(Command(number: file[p + 2], data: file[p + 3]))
                    }
                }
                for page in pages {
                    for i in 0 ..< count { commands.append(Command(number: file[page + i * 2], data: file[page + i * 2 + 1])) }
                }
                song.blocks.append(block)
            }
            if song.blocks.isEmpty { throw TuneError.malformed("a MED module with no blocks") }

            // The order of playing, laid out as places, and a row for each line of each place.
            for (section, sequence) in song.sections.enumerated() {
                song.firstPlaceOfSection.append(song.places.count)
                for position in 0 ..< song.sequences[sequence].count {
                    song.places.append((section, position))
                    song.firstRowOfPlace.append(song.rowsInAll)
                    let block = Int(song.sequences[sequence][position])
                    song.rowsInAll += block < song.blocks.count ? song.blocks[block].lines : 1
                }
            }
            songs.append(song)
        }
        self.songs = songs
        self.cells = .allocate(capacity: max(1, cells.count))
        self.commands = .allocate(capacity: max(1, commands.count))
        for i in 0 ..< cells.count { self.cells[i] = cells[i] }
        for i in 0 ..< commands.count { self.commands[i] = commands[i] }

        mixSpace = size + Self.silenceLength
        memorySize = mixSpace + 4 * Self.mixBuffers * Self.mixBufferSize
        silence = size
        memory = .allocate(capacity: memorySize)
        memory.initialize(repeating: 0, count: memorySize)
        for i in 0 ..< size { memory[i] = Int8(bitPattern: data[i]) }

        // Whether samples are played by copying: decided as OctaMED's own loader decides it.
        var throughBuffers = songs[0].instruments.contains { $0.kind != .absent && $0.length >= 0x20000 }
        if !throughBuffers, let expansion, let extras, extraSize >= 18 {
            for i in 0 ..< file.u16be(expansion + 8) {
                let both = file.long(extras + i * extraSize + 10) | file.long(extras + i * extraSize + 14)
                if both & 1 != 0 || both >= 0x20000 { throughBuffers = true }
            }
        }
        playsThroughBuffers = throughBuffers
    }

    /// Where a song's own structure, its blocks and its instruments are, from its header.
    private static func places(of header: Int, _ file: ByteReader, _ size: Int) throws -> (song: Int, blocks: Int?, instruments: Int?) {
        let song = file.long(header + 8)
        guard song > 0, song + 788 <= size else { throw TuneError.malformed("a MED module cut short before its song") }
        func pointer(_ at: Int) -> Int? {
            let to = file.long(at)
            return to > 0 && to < size ? to : nil
        }
        return (song, pointer(header + 16), pointer(header + 24))
    }

    /// Everything about a song but its blocks.
    private static func song(at header: Int, _ file: ByteReader, _ size: Int, shared: [Instrument]) throws -> Song {
        let at = try places(of: header, file, size)
        func pointer(_ from: Int) -> Int? {
            let to = file.long(from)
            return to > 0 && to < size ? to : nil
        }
        var song = Song()
        // The songs after the first are marked "MCNT" or "MCN" and a digit; either way the last
        // letter says which kind of file their structures are of, and a T is the oldest.
        let kind = file[header + 3]
        song.version = kind >= 0x31 && kind <= 0x33 ? Int(kind) - 0x30 : 0
        let s = at.song
        let flags2 = file[s + 768]
        song.flags = file[s + 767]
        song.mode = flags2 & 0x80 != 0 ? .mixing : (song.flags & 0x40 != 0 ? .eightChannel : .fourChannel)
        song.tempo = file.u16be(s + 764)
        song.transpose = Int8(bitPattern: file[s + 766])
        song.beatsPerMinute = flags2 & 0x20 != 0
        song.linesPerBeat = Int(flags2 & 0x1F) + 1
        song.ticksPerLine = Int(file[s + 769])
        song.masterVolume = file[s + 786]
        if let expansion = pointer(header + 32) {
            if let name = pointer(expansion + 44) { song.title = text(file, at: name, length: min(file.long(expansion + 48), 256)) }
            // Four bytes, one for each voice: nought for a voice that two tracks are mixed into.
            for voice in 0 ..< 4 { song.mixed[voice] = file[expansion + 36 + voice] == 0 }
        }

        // The instruments: the song's own few words on each, and the sample itself.
        let sampleCount = min(mostInstruments, Int(file[s + 787]))
        song.instruments = shared
        for i in 0 ..< mostInstruments {
            song.instruments[i].volume = file[s + i * 8 + 6]
            song.instruments[i].shortRepeatStart = file.u16be(s + i * 8)
            song.instruments[i].shortRepeatWords = file.u16be(s + i * 8 + 2)
            song.instruments[i].transpose = Int8(bitPattern: file[s + i * 8 + 7])
            song.instruments[i].midiChannel = file[s + i * 8 + 4]
            guard i < sampleCount, let table = at.instruments else { continue }
            // A sample that a file cut short no longer has is still an instrument: one of no length,
            // whose notes are silent but are notes all the same.
            let sample = file.long(table + i * 4)
            guard sample != 0 else { continue }
            let type = file.s16be(sample + 4)
            song.instruments[i].length = file.long(sample)
            song.instruments[i].offset = sample + 6
            if type == -1 {
                song.instruments[i].kind = .synthetic
                song.instruments[i].program = sample
            } else if type == -2 {
                // A hybrid: its first waveform is a sample, with a sample's own few words before it.
                song.instruments[i].program = sample
                let inner = sample + file.long(sample + 278)
                if file.u16be(sample + 20) > 0, inner + 6 <= size {
                    song.instruments[i].length = file.long(inner)
                    song.instruments[i].offset = inner + 6
                    read(kind: file.s16be(inner + 4), into: &song.instruments[i])
                } else {
                    song.instruments[i].length = 0
                    song.instruments[i].offset = size
                    song.instruments[i].kind = .sample
                }
            } else {
                read(kind: type, into: &song.instruments[i])
                // (A place for it beyond the end of the file is no place: it has lost all of itself,
                // however long it was.)
                let said = sample + 6 <= size ? min(song.instruments[i].length, 1 << 28) * (song.instruments[i].stereo ? 2 : 1) : 1 << 16
                song.cutShort.add(length: said, there: size - sample - 6)
            }
        }

        if song.version >= 2 {
            let sequenceCount = file.u16be(s + 522)
            if let table = pointer(s + 508) {
                for i in 0 ..< min(sequenceCount, 4096) {
                    guard let sequence = pointer(table + i * 4) else {
                        song.sequences.append([])
                        continue
                    }
                    let length = min(file.u16be(sequence + 40), max(0, (size - sequence - 42) / 2))
                    song.sequences.append((0 ..< length).map { UInt16(file.u16be(sequence + 42 + $0 * 2)) })
                }
            }
            if let table = pointer(s + 512) {
                for i in 0 ..< min(file.u16be(s + 506), 4096) {
                    let sequence = file.u16be(table + i * 2)
                    song.sections.append(sequence < song.sequences.count ? sequence : 0)
                }
            }
            if song.sequences.isEmpty { song.sequences = [[0]] }
            if song.sections.isEmpty { song.sections = [0] }
            // Where it was when it was saved, which is where the player begins.
            let section = file.u16be(header + 12)
            song.firstSection = section < song.sections.count ? section : 0
            let trackCount = min(file.u16be(s + 520), mostTracks)
            if let volumes = pointer(s + 516) { song.trackVolumes = (0 ..< trackCount).map { file[volumes + $0] } }
            if let pans = pointer(s + 524) { song.trackPans = (0 ..< trackCount).map { Int8(bitPattern: file[pans + $0]) } }
            let mixing = file[s + 531]
            song.stereo = mixing & 1 != 0
            song.freePan = mixing & 2 != 0
            song.volumeAdjust = file.u16be(s + 532)
            song.channels = file.u16be(s + 534) == 0 ? 4 : min(file.u16be(s + 534), mostTracks)
            song.echo = Int(file[s + 536])
            song.echoDepth = Int(file[s + 537])
            song.echoLength = file.u16be(s + 538)
            song.separation = Int(Int8(bitPattern: file[s + 540]))
        } else {
            let length = min(file.u16be(s + 506), 256)
            song.sequences = [(0 ..< max(1, length)).map { UInt16(file[s + 508 + $0]) }]
            song.sections = [0]
            song.trackVolumes = (0 ..< 16).map { file[s + 770 + $0] }
        }
        return song
    }

    /// What kind of sample a sample says it is.
    private static func read(kind type: Int, into instrument: inout Instrument) {
        if type < 0 {
            instrument.kind = .unknown
        } else {
            instrument.sixteenBit = type & 0x10 != 0
            instrument.stereo = type & 0x20 != 0
            switch type & 0x0F {
            case 0: instrument.kind = .sample
            case 1: instrument.kind = .octaves(5)
            case 2: instrument.kind = .octaves(3)
            case 3: instrument.kind = .octaves(2)
            case 4: instrument.kind = .octaves(4)
            case 5: instrument.kind = .octaves(6)
            case 6: instrument.kind = .octaves(7)
            default: instrument.kind = .extended
            }
        }
    }

    /// Text that ends at a nought, in the Amiga's own letters.
    private static func text(_ file: ByteReader, at start: Int, length: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for i in 0 ..< max(0, length) {
            let byte = file[start + i]
            if byte == 0 { break }
            scalars.append(Unicode.Scalar(byte == 0x0A || byte >= 0x20 ? byte : 0x20))
        }
        return String(scalars).trimmed(newlines: true)
    }
}
