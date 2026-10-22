// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from the MED4 loader of libxmp, Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito
// Carraro Jr, used under the MIT licence (see THIRD-PARTY.md): the layout of the file.

import SidayFoundation

/// A MED4 file: a song saved by MED 2.10 to 3.00 on the Amiga, before MED saved modules in the
/// MMD0 format and its successors.
///
/// It says what an MMD0 module says, packed: a mask of which instruments there are, and for each
/// only those of its few words that are not as they would be by default; a song like an MMD0
/// song's; and blocks of which only the lines and tracks with something on them are kept, a nibble
/// at a time, each note and each command twelve bits of the three bytes that an MMD0 module gives
/// a note on a track. The samples are in the same shape as an MMD0 module's, one after another.
///
/// So it is read into the MMD0 module that MED would have saved of it, and played as that is (see
/// `MEDModule`). Left out: a synthetic or hybrid sound, whose structure is not an MMD0 module's,
/// and an instrument of any other kind that MED4 files are not known to have; and the hold and
/// decay of a note, which MED 3.00 kept in a part of the file that no description of the format
/// tells the layout of. A file that has either, and uses it, says so. A song whose instruments
/// are kept in files of their own is not played at all.
enum MED4File {
    static func isOne(_ data: [UInt8]) -> Bool {
        data.count > 4 && data[0] == 0x4D && data[1] == 0x45 && data[2] == 0x44 && data[3] == 4
    }

    /// Reads twelve bits and fewer at a time, from the high half of a byte and then its low.
    private struct Nibbles {
        let file: ByteReader
        var at: Int
        var half = false
        var byte: UInt8 = 0

        mutating func next() -> Int {
            half.toggle()
            if half {
                byte = file[at]
                at += 1
                return Int(byte >> 4)
            }
            return Int(byte & 0x0F)
        }

        mutating func read(_ count: Int) -> Int {
            var value = 0
            for _ in 0 ..< count { value = value << 4 | next() }
            return value
        }

        /// One bit for each of so many tracks, the first the highest of sixteen: as many nibbles as
        /// the tracks need.
        mutating func tracks(_ count: Int) -> Int {
            let nibbles = max(1, (count + 3) / 4)
            return read(nibbles) << (16 - 4 * nibbles)
        }
    }

    private struct Instrument {
        var name: [UInt8] = []
        var repeatWords = 0, repeatLength = 0
        var midiChannel: UInt8 = 0, midiPreset: UInt8 = 0, volume: UInt8 = 0
        var transpose: UInt8 = 0
    }

    /// The MMD0 module a MED4 file stands for; what could not be put in it, for each thing a
    /// sentence; and which MED saved it.
    static func mmd0(_ data: [UInt8]) throws -> (file: [UInt8], shortfalls: [String], detail: String) {
        let f = ByteReader(data)
        guard isOne(data) else { throw TuneError.malformed("not a MED4 file") }
        let most = MEDModule.mostInstruments

        // Which instruments there are: a byte that says which of eight bytes of a mask follow.
        var at = 4
        let which = f[at]
        at += 1
        var mask: UInt64 = 0, bytes = 0
        for i in 0 ..< 8 where which & (0x80 >> UInt8(i)) != 0 {
            mask = mask << 8 | UInt64(f[at])
            at += 1
            bytes += 1
        }
        mask <<= UInt64(8 * (8 - bytes))
        var instruments = [Instrument](repeating: Instrument(), count: 64)
        var slots = 0
        for i in 0 ..< 64 where mask & (1 << UInt64(63 - i)) != 0 {
            // A byte that says which of the instrument's words are left out, its name, and the rest.
            let absent = f[at], length = Int(f[at + 1])
            var one = Instrument()
            one.name = (0 ..< length).map { f[at + 2 + $0] }
            one.volume = 64
            at += 2 + length
            if absent & 0x01 == 0 { one.repeatWords = f.u16be(at); at += 2 }
            if absent & 0x02 == 0 { one.repeatLength = f.u16be(at); at += 2 }
            if absent & 0x04 == 0 { one.midiChannel = f[at]; at += 1 }
            if absent & 0x08 == 0 { one.midiPreset = f[at]; at += 1 }
            if absent & 0x30 == 0 { one.volume = f[at]; at += 1 }
            if absent & 0x40 == 0 { one.transpose = f[at]; at += 1 }
            instruments[i] = one
            slots = i + 1
        }

        // The song.
        let blockCount = f.u16be(at), length = f.u16be(at + 2)
        guard blockCount > 0, blockCount <= 256, length <= 256 else { throw TuneError.malformed("not a MED4 file") }
        at += 4
        let orders = (0 ..< length).map { f[at + $0] }
        at += length
        let tempo = f.u16be(at), transpose = f[at + 2], flags = f[at + 3], ticks = f.u16be(at + 4)
        // (Twenty bytes of the colours MED's screen was in.)
        at += 6 + 20
        let trackVolumes = (0 ..< 16).map { f[at + $0] }, masterVolume = f[at + 16]
        at += 17

        // The blocks, into an MMD0 module's: a byte of tracks, a byte of lines less one, and three
        // bytes to each note.
        var blocks: [[UInt8]] = []
        var used = [Bool](repeating: false, count: 64)
        for _ in 0 ..< blockCount {
            guard at < data.count else { throw TuneError.malformed("a MED4 file cut short in its blocks") }
            let size = Int(f[at]), start = at + 1
            let tracks = Int(f[start]), lines = Int(f[start + 1]) + 1, packed = f.u16be(start + 2)
            guard tracks <= 16 else { throw TuneError.malformed("a MED4 file with a block of more tracks than MED had") }
            // Whether each line has notes and commands, for each 32 lines: written out as masks, or
            // said by four bits of a control byte to be all or none.
            var control = start + 4
            var controls: [UInt8] = []
            for part in 0 ..< 4 where lines > part * 64 {
                controls.append(f[control])
                control += 1
            }
            var noteLines: [UInt32] = [], commandLines: [UInt32] = []
            for part in 0 ..< 8 where lines > part * 32 {
                let byte = controls[part / 2], shift = UInt8(4 * (part % 2))
                func lineMask(_ all: UInt8, _ none: UInt8) -> UInt32 {
                    if byte & (all >> shift) != 0 { return ~0 }
                    if byte & (none >> shift) != 0 { return 0 }
                    let mask = UInt32(f.u16be(control)) << 16 | UInt32(f.u16be(control + 2))
                    control += 4
                    return mask
                }
                noteLines.append(lineMask(0x80, 0x40))
                commandLines.append(lineMask(0x20, 0x10))
            }
            var cells = [UInt8](repeating: 0, count: 2 + tracks * lines * 3)
            cells[0] = UInt8(tracks)
            cells[1] = UInt8(lines - 1)
            var stream = Nibbles(file: f, at: start + size)
            for line in 0 ..< lines {
                let part = line / 32, bit = UInt32(1) << UInt32(31 - line % 32)
                if noteLines[part] & bit != 0 {
                    let present = stream.tracks(tracks)
                    for track in 0 ..< tracks where present & (0x8000 >> track) != 0 {
                        let note = stream.read(3), cell = 2 + (line * tracks + track) * 3
                        cells[cell] = UInt8(note >> 4)
                        cells[cell + 1] = cells[cell + 1] & 0x0F | UInt8(note & 0x0F) << 4
                        let instrument = (note >> 4 & 0x80) >> 3 | (note >> 4 & 0x40) >> 1 | note & 0x0F
                        used[instrument] = true
                    }
                }
                if commandLines[part] & bit != 0 {
                    let present = stream.tracks(tracks)
                    for track in 0 ..< tracks where present & (0x8000 >> track) != 0 {
                        let command = stream.read(3), cell = 2 + (line * tracks + track) * 3
                        cells[cell + 1] = cells[cell + 1] & 0xF0 | UInt8(command >> 8)
                        cells[cell + 2] = UInt8(command & 0xFF)
                    }
                }
            }
            blocks.append(cells)
            at = start + size + packed
        }

        // The samples: a mask of which there are, from instrument 1, and then each as an MMD0
        // module has it, its length and kind and then itself.
        guard flags & 0x08 != 0 else { throw TuneError.unsupported("a MED song whose instruments are kept in files of their own") }
        let samples = (UInt64(f.u16be(at)) << 48 | UInt64(f.u16be(at + 2)) << 32 | UInt64(f.u16be(at + 4)) << 16 | UInt64(f.u16be(at + 6))) << 1
        at += 8
        // (A sample that the file ends before is still an instrument, of no length: a module cut
        // short has those too, and says so.)
        let missing = -2
        var sampleAt = [Int](repeating: -1, count: 64)
        var notRead = 0
        for i in 0 ..< 64 where samples & (1 << UInt64(63 - i)) != 0 {
            guard at + 6 <= data.count else {
                sampleAt[i] = missing
                slots = max(slots, i + 1)
                continue
            }
            let high = f.u16be(at)
            let length = high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16be(at + 2)
            let kind = f.s16be(at + 4)
            if kind >= 0, kind <= 7 {
                sampleAt[i] = at
            } else if used[i + 1] {
                notRead += 1
            }
            slots = max(slots, i + 1)
            at = min(data.count, at + 6 + length)
        }
        slots = min(slots, most)

        // What follows the samples, in chunks: the version of MED, notes on the song, and the
        // hold and decay of the instruments.
        var version = (major: 2, minor: 10)
        var annotation: [UInt8] = []
        var holds = false
        while at + 8 <= data.count {
            let size = f.u16be(at + 4) < 0x4000 ? f.u16be(at + 4) << 16 | f.u16be(at + 6) : -1
            guard size > 0, at + 8 + size <= data.count else { break }
            switch (f[at], f[at + 1], f[at + 2], f[at + 3]) {
            case (0x4D, 0x45, 0x44, 0x56): version = (Int(f[at + 10]), Int(f[at + 11]))
            case (0x41, 0x4E, 0x4E, 0x4F): annotation = (0 ..< min(size, 4096)).map { f[at + 8 + $0] }
            case (0x48, 0x4C, 0x44, 0x43): holds = (0 ..< size).contains { f[at + 8 + $0] != 0 }
            default: break
            }
            at += 8 + size
        }

        // The MMD0 module: its header, the song, the expansion with the instruments' names and the
        // notes, the tables of where the blocks and samples are, the blocks and the samples.
        func long(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func word(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func even(_ bytes: inout [UInt8]) { if bytes.count & 1 != 0 { bytes.append(0) } }
        let songAt = 52, expansionAt = songAt + 788, namesAt = expansionAt + 64
        let annotationAt = namesAt + slots * 40
        let blockTableAt = annotationAt + (annotation.isEmpty ? 0 : (annotation.count + 2) & ~1)
        let sampleTableAt = blockTableAt + blocks.count * 4
        var body: [UInt8] = []
        var blockPlaces: [Int] = [], samplePlaces = [Int](repeating: 0, count: slots)
        var place = sampleTableAt + slots * 4
        for cells in blocks {
            blockPlaces.append(place)
            body += cells
            even(&body)
            place = sampleTableAt + slots * 4 + body.count
        }
        for i in 0 ..< slots where sampleAt[i] >= 0 {
            samplePlaces[i] = sampleTableAt + slots * 4 + body.count
            let high = f.u16be(sampleAt[i])
            let length = high >= 0x4000 ? 0x3FFF_FFFF : high << 16 | f.u16be(sampleAt[i] + 2)
            let end = min(data.count, sampleAt[i] + 6 + length)
            body += data[sampleAt[i] ..< end]
            even(&body)
        }

        var file = Array("MMD0".utf8) + long(0) + long(songAt) + long(0) + long(blockTableAt) + long(0) + long(sampleTableAt) + long(0)
        file += long(expansionAt) + long(0) + [UInt8](repeating: 0, count: 12)
        for i in 0 ..< 63 {
            let one = instruments[i]
            file += word(one.repeatWords) + word(one.repeatLength) + [one.midiChannel, one.midiPreset, one.volume, one.transpose]
        }
        file += word(blocks.count) + word(length) + orders + [UInt8](repeating: 0, count: 256 - length)
        // Five or six ticks to the line for a song of MED 2, which did not save its own: as libxmp
        // guesses it. (Neither bit 0x40 nor 0x80 of the flags is MED 3.00's: they would be eight
        // channels and a slower mixing.)
        let ticksPerLine = version.major == 2 ? (flags & 0x20 != 0 ? 5 : 6) : ticks & 0xFF
        file += word(tempo) + [transpose, flags & 0x3F, 0, UInt8(ticksPerLine)] + trackVolumes + [masterVolume, UInt8(slots)]
        // The expansion: no more than the names and the notes.
        var expansion = [UInt8](repeating: 0, count: 64)
        expansion.replaceSubrange(12 ..< 20, with: annotation.isEmpty ? long(0) + long(0) : long(annotationAt) + long(annotation.count))
        expansion.replaceSubrange(20 ..< 28, with: long(namesAt) + word(slots) + word(40))
        file += expansion
        for i in 0 ..< slots {
            let name = instruments[i].name.prefix(39)
            file += name + [UInt8](repeating: 0, count: 40 - name.count)
        }
        if !annotation.isEmpty {
            file += annotation + [0]
            even(&file)
        }
        file += blockPlaces.flatMap(long)
        file += samplePlaces.flatMap(long)
        file += body
        file.replaceSubrange(4 ..< 8, with: long(file.count))
        // Those the file ends before are where it ends.
        for i in 0 ..< slots where sampleAt[i] == missing {
            file.replaceSubrange(sampleTableAt + i * 4 ..< sampleTableAt + i * 4 + 4, with: long(file.count))
        }

        var shortfalls: [String] = []
        if notRead > 0 {
            shortfalls.append(Shortfall.some(notRead, one: "instruments is a synthetic sound in MED's first format, which is not read, and is silent.",
                                             many: "instruments are synthetic sounds in MED's first format, which are not read, and are silent."))
        }
        if holds {
            shortfalls.append("Its instruments' hold and decay are not read: every note is held to its end.")
        }
        let detail = "MED4, from MED \(version.major).\(version.minor < 10 ? "0" : "")\(version.minor)"
        return (file, shortfalls, detail)
    }
}
