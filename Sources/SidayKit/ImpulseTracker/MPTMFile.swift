// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// the layout of an MPTM file, which is its own (`soundlib/Load_it.cpp`, `ITTools.cpp`,
// `InstrumentExtensions.cpp`, `ModSequence.cpp`, `pattern.cpp`, `tuning.cpp` and
// `common/serialization_utils.cpp`), and what it makes of what it reads there.

/// An MPTM file: OpenMPT's own kind of module.
///
/// It is an IT file with more put after it. The IT file is all there, and Impulse Tracker's replayer
/// plays it; what follows says what an IT file has no room for, and that replayer has been taught as
/// much of it as it honestly can be: OpenMPT's other ways of keeping time, a tempo that is a
/// fraction or higher than 255, patterns of up to 1024 rows, a list of more than 256 of them, several
/// lists in one file (which are its songs), envelopes of more than 25 points with a point to go to
/// when a key is let go, and a few commands of its own (see `OpenMPTSong`).
///
/// OpenMPT also plays an instrument on the AdLib's FM chip, and sends sound through plug-ins. The
/// chip is here, and is played as OpenMPT plays it (`OpenMPTAdLib`). A plug-in is somebody's
/// program, and most are not here; but a few are OpenMPT's own, an echo and reverbs and the like,
/// and those are played, wired as the file wires them (`OpenMPTPlugIns`). Any other plug-in is left
/// out, and what was sent through it is heard without it, as OpenMPT plays a file on a machine that
/// has not got the program. An instrument that is nothing but such a plug-in is not heard, and if
/// half a file's notes or more are for such instruments the file is refused.
///
/// And OpenMPT tunes instruments to scales that are not the twelve equal steps of every other
/// module: a temperament, or a scale with more or fewer steps to the octave, or with no octave at
/// all. Those are played as OpenMPT plays them (`OpenMPTTuning`).
///
/// OpenMPT plays these files in its own way and not in Impulse Tracker's where the two differ, and
/// which of its ways a file wants is written in the file, flag by flag. Those flags are not followed
/// here, but for the few that are named below: this is Impulse Tracker's replayer.
enum MPTMFile {
    // MARK: Reading

    /// A place in the file that moves on as it is read from. Whatever is asked for beyond the end is
    /// nought, and a number too large to be a place in a file or a length is brought down to one
    /// that is still neither, and that can have another such added to it. (A whole number in a
    /// browser has 32 bits.)
    private struct Reader {
        let data: [UInt8]
        var at: Int

        init(_ data: [UInt8], at: Int = 0) {
            self.data = data
            self.at = max(0, min(at, data.count))
        }

        var left: Int { data.count - at }

        mutating func skip(_ count: Int) {
            at = count >= left ? data.count : at + max(0, count)
        }

        mutating func u8() -> Int {
            guard at < data.count else { return 0 }
            at += 1
            return Int(data[at - 1])
        }

        mutating func u16() -> Int {
            let low = u8()
            return low | u8() << 8
        }

        mutating func u32() -> Int {
            let low = UInt32(u16())
            return Int(min(low | UInt32(u16()) << 16, Self.most))
        }

        static let most: UInt32 = 0x3FFF_FFFF

        /// A number written in as few of 1, 2, 4 or 8 bytes as hold it, the first two bits saying which.
        mutating func adaptive64() -> Int {
            let first = u8()
            var value = UInt64(first >> 2)
            for i in 0 ..< (1 << (first & 3)) - 1 { value |= UInt64(u8()) << UInt64((i + 1) * 8 - 2) }
            return Int(min(value, UInt64(Self.most)))
        }

        /// One in up to four bytes, the first two bits saying how many more follow.
        mutating func adaptive32() -> Int {
            let first = u8()
            var value = UInt64(first >> 2)
            for i in 0 ..< first & 3 { value |= UInt64(u8()) << UInt64((i + 1) * 8 - 2) }
            return Int(min(value, UInt64(Self.most)))
        }

        /// One in one byte or two, the first bit saying which.
        mutating func adaptive16() -> Int {
            let first = u8()
            return first & 1 == 0 ? first >> 1 : first >> 1 | u8() << 7
        }

        mutating func bytes(_ count: Int) -> [UInt8] {
            let n = max(0, min(count, left))
            at += n
            return Array(data[at - n ..< at])
        }

        /// True, having passed over them, if the next four bytes are these.
        mutating func magic(_ text: String) -> Bool {
            let wanted = Array(text.utf8)
            guard left >= wanted.count, data[at ..< at + wanted.count].elementsEqual(wanted) else { return false }
            at += wanted.count
            return true
        }
    }

    /// OpenMPT's own way of putting named things one after another in a file: a heading, the things,
    /// and a list of where each is and what it is called. An MPTM file's last part is one of these,
    /// and some of the things in it are more of them.
    private struct Chunk {
        struct Entry {
            var name: [UInt8]
            /// Where it starts in the file, and how long it is; less than nought if the list does not say.
            var start: Int, size: Int
        }

        private(set) var entries: [Entry] = []

        /// Nil if what is at that place is not one of these, or not the one of this name.
        init?(_ data: [UInt8], at start: Int, named name: String) {
            var r = Reader(data, at: start)
            guard start >= 0, start < data.count, r.magic("228") else { return nil }
            let own = r.bytes(r.u8())
            guard own.elementsEqual(Array(name.utf8)) else { return nil }
            let header = r.u8()
            var nameBytes = header & 3 == 3 ? 4 : header & 3
            let headerData = r.adaptive32()
            var flags = 0
            if headerData >= 2 {
                let first = r.u8()
                if first == 0 { flags = r.u8() }
                r.skip(first == 0 ? headerData - 2 : headerData - 1)
            }
            if header & 0x10 != 0 { _ = r.adaptive64() } // the version of OpenMPT that wrote it
            if header & 0x20 != 0 { r.skip(r.u8()) }
            var namesVary = false
            if flags & 1 != 0 {
                let n = r.u8()
                if n & 1 != 0 { namesVary = true } else { nameBytes = n >> 1 }
            }
            let fixedSize = flags & 2 != 0 ? r.adaptive32() : 0
            let hasStart = header & 4 != 0, hasSize = header & 8 != 0, hasDescription = header & 0x80 != 0
            let hasMap = namesVary || nameBytes > 0 || hasStart || hasSize || hasDescription
            if flags & 4 != 0 {
                let size = r.adaptive16()
                r.skip(header & 0x40 != 0 ? size * 2 : size)
            }
            if flags & 8 != 0 { r.skip(5) }
            let count = r.adaptive64()
            guard count <= 16000 else { return nil }
            let mapAt = hasMap ? r.adaptive64() : 0
            let headerEnd = r.at - start
            guard hasMap || fixedSize > 0 else { return }

            r = Reader(data, at: hasMap ? min(Int(Reader.most), start) + mapAt : start + headerEnd)
            var relative: [Int] = []
            for i in 0 ..< count {
                if r.left <= 0 { break }
                let length = namesVary ? r.adaptive16() : nameBytes
                var entry = Entry(name: hasMap ? r.bytes(length) : [], start: 0, size: -1)
                if hasMap, hasStart { entry.start = r.adaptive64() }
                if fixedSize > 0 { entry.size = fixedSize } else if hasMap, hasSize { entry.size = r.adaptive64() }
                if !hasStart, entry.size >= 0 { entry.start = i > 0 ? min(Int(Reader.most), relative[i - 1] + max(0, entries[i - 1].size)) : 0 }
                relative.append(entry.start)
                if hasMap, hasDescription {
                    let size = r.adaptive16()
                    r.skip(header & 0x40 != 0 ? size * 2 : size)
                }
                entries.append(entry)
            }
            // The things are counted from the start of all this, or from where they begin if the
            // list gives no places and only sizes.
            let dataBegin = !hasMap || mapAt == headerEnd ? r.at : start + headerEnd
            for i in entries.indices {
                entries[i].start = min(data.count, min(Int(Reader.most), hasStart ? start : dataBegin) + entries[i].start)
            }
        }

        func entry(_ name: String) -> Entry? {
            let wanted = Array(name.utf8)
            return entries.first { $0.name == wanted }
        }

        func entry(_ name: [UInt8]) -> Entry? {
            entries.first { $0.name == name }
        }

        /// A whole number of so many bytes at most, the first the least; nil if there is no such thing.
        func number(_ name: String, bytes: Int, in data: [UInt8]) -> Int? {
            guard let entry = entry(name) else { return nil }
            var r = Reader(data, at: entry.start)
            var value: UInt32 = 0
            for i in 0 ..< min(4, entry.size >= 0 ? min(entry.size, bytes) : bytes) { value |= UInt32(r.u8()) << UInt32(i * 8) }
            return Int(min(value, 0x7FFF_FFFF))
        }
    }

    // MARK: What a file is

    /// The header of the IT file that an MPTM file begins with, by its own names.
    private struct Header {
        let orders: Int, instruments: Int, samples: Int, patterns: Int
        let version: Int, flags: Int, special: Int

        init(_ data: [UInt8]) {
            var r = Reader(data, at: 0x20)
            orders = r.u16()
            instruments = r.u16()
            samples = r.u16()
            patterns = r.u16()
            version = r.u16()
            _ = r.u16()
            flags = r.u16()
            special = r.u16()
        }

        /// Where the lists of where the instruments, samples and patterns are begin.
        var places: Int { 192 + orders }
    }

    /// Where OpenMPT's own last part of the file begins: the file's last four bytes say.
    private static func ownPart(_ data: [UInt8]) -> Int? {
        guard data.count >= 0x104, data.starts(with: [0x49, 0x4D, 0x50, 0x4D]) else { return nil }
        let header = Header(data)
        guard header.version > 0x888, header.version <= 0xFFF else { return nil }
        var r = Reader(data, at: data.count - 4)
        let at = r.u32()
        guard at >= 0x100, at < data.count - 3, data[at] == 0x32, data[at + 1] == 0x32, data[at + 2] == 0x38 else { return nil }
        return at
    }

    /// True for a file that is one of these, and not an IT file under the name of one.
    static func isOne(_ data: [UInt8]) -> Bool {
        ownPart(data) != nil
    }

    // MARK: The parts that are OpenMPT's

    /// What OpenMPT says of an instrument beyond what an IT file's instrument says.
    private struct InstrumentExtras {
        /// Which plug-in it plays through, counted from 1; nought for none.
        var plugin = 0
        /// 1 for a filter that lets the high notes through and not the low.
        var filterMode = 0xFF
        var cutoffSwing = 0, resonanceSwing = 0
        /// The tempo it is to keep time with, its whole part and its ten-thousandths; nought for none.
        var pitchTempoLock = 0, pitchTempoLockFraction = 0
        var releaseNode = Int(IT2Envelope.noReleaseNode)
        /// For each of its three envelopes, how many points and their ticks and levels, where the
        /// file gives them apart from the instrument: for an envelope of more than 25.
        var points = [Int](repeating: -1, count: 3)
        var ticks = [[UInt16]](repeating: [], count: 3)
        var levels = [[UInt8]](repeating: [], count: 3)
    }

    /// The instruments' "extended properties": after a mark, one property after another, each with
    /// its four-letter name, a size, and that many bytes for every instrument in turn.
    private static func instrumentExtras(_ r: inout Reader, count: Int) -> [InstrumentExtras] {
        var extras = [InstrumentExtras](repeating: InstrumentExtras(), count: count)
        guard r.magic("XTPM") else { return extras }
        while r.left >= 6 {
            let code = r.bytes(4)
            // The song's own properties follow, or the file's last part, or something that is no name.
            if code == Array("STPM".utf8) || code == [0x32, 0x32, 0x38, 0x04] || code.contains(where: { $0 & 0x80 != 0 }) || !code.contains(where: { $0 & 0x60 != 0 }) {
                r.at -= 4
                break
            }
            let size = r.u16()
            // (The names are written last letter first.)
            let name = String(decoding: code.reversed(), as: UTF8.self)
            for index in 0 ..< count {
                let whole = r.left >= size
                var field = Reader(r.data, at: r.at)
                r.skip(size)
                guard whole else { continue }
                func number() -> Int {
                    var value: UInt32 = 0
                    for i in 0 ..< min(4, size) { value |= UInt32(field.u8()) << UInt32(i * 8) }
                    return Int(min(value, 0x7FFF_FFFF))
                }
                switch name {
                case "MiP.": extras[index].plugin = number()
                case "FM..": extras[index].filterMode = number() & 0xFF
                case "CS..": extras[index].cutoffSwing = number()
                case "RS..": extras[index].resonanceSwing = number()
                case "PTTL": extras[index].pitchTempoLock = number()
                // (The fraction is written first letter first, unlike every other name.)
                case "FTTP": extras[index].pitchTempoLockFraction = number()
                case "VERN": extras[index].releaseNode = number() & 0xFF
                case "VE..", "PE..", "PiE.": extras[index].points[name == "VE.." ? 0 : name == "PE.." ? 1 : 2] = min(240, number())
                case "VP[.", "PP[.", "PiP[": extras[index].ticks[name == "VP[." ? 0 : name == "PP[." ? 1 : 2] = (0 ..< size / 2).map { _ in UInt16(field.u16()) }
                case "VE[.", "PE[.", "PiE[": extras[index].levels[name == "VE[." ? 0 : name == "PE[." ? 1 : 2] = (0 ..< size).map { _ in UInt8(field.u8()) }
                default: break
                }
            }
        }
        return extras
    }

    /// What OpenMPT says of the song beyond what an IT file's header says.
    private struct SongExtras {
        var tempo: Int?, tempoFraction = 0
        var rowsPerBeat: Int?
        var tempoMode = 0
        var mixLevels: Int?
        var preAmp: Int?
        /// How loud its plug-in instruments are, which is how loud its FM instruments are too: 48 if it does not say.
        var synthVolume = 48
        /// How many channels OpenMPT is to give the song, if that is more than its patterns use.
        var channels = 0
        var restart = 0
        /// The version of OpenMPT that last saved the file, a byte for each of its four parts.
        var savedWith = 0
        var swing: [UInt32] = []
        /// OpenMPT's ways of playing that the file asks for, by their numbers; nil if it does not say.
        var behaviours: [Bool]?
        /// Each sample's nine cue points, by the sample's number from 1.
        var cues: [Int: [UInt32]] = [:]
        var found = false
    }

    /// The numbers of the few of OpenMPT's ways of playing that are looked at.
    private enum Behaviour {
        static let compatiblePlay = 0, oldSwing = 1, tempoClamp = 8, tremorAsImpulseTracker = 22, offsetAsImpulseTracker = 27, legacyReleaseNode = 94
        static let jumpsEndLoops = 103, jumpsEndLoopsOld = 49, unmappedNotesDoNothing = 123
        static let fmFlexibleNoteOff = 99, fmKeepsVoiceWhenLetGo = 105, surroundIsNotMoved = 37
        static let itVibrato = 21

        /// The ways of playing that "compatible play" stood for until OpenMPT 1.26, each with the
        /// version that brought it in, as OpenMPT gives them to a file saved before then.
        static let compatiblePlayWays: [(behaviour: Int, since: Int)] = [
            (8, 0x0117_0302), (9, 0x0117_0302), (10, 0x0117_0302), (11, 0x0117_0246), (12, 0x0117_0249), (13, 0x0117_0249),
            (14, 0x0117_0249), (15, 0x0117_0249), (16, 0x0117_0249), (17, 0x0117_0249), (18, 0x0117_0251), (19, 0x0117_0251),
            (20, 0x0117_0252), (21, 0x0117_0302), (22, 0x0117_0302), (23, 0x0117_0302), (24, 0x0117_0302), (25, 0x0117_0302),
            (26, 0x0117_0302), (27, 0x0117_0302), (28, 0x0118_0000), (29, 0x0118_0000), (30, 0x0118_0001), (31, 0x0118_0100),
            (32, 0x0119_0001), (33, 0x0119_0021), (34, 0x0119_0030), (35, 0x0120_0014), (36, 0x0120_0035), (37, 0x0120_0053),
            (38, 0x0120_0054), (39, 0x0120_0056), (88, 0x0120_0076), (40, 0x0120_0206), (41, 0x0121_0116), (42, 0x0121_0125),
            (43, 0x0121_0125), (44, 0x0122_0709), (45, 0x0122_0719), (46, 0x0123_0403), (47, 0x0124_0106), (48, 0x0124_0106),
            (49, 0x0125_0019),
        ]
    }

    /// Half of how far an instrument's higher notes go to one side, rounded away from the middle.
    static func halved(_ separation: UInt8) -> UInt8 {
        let value = Int(Int8(bitPattern: separation))
        return UInt8(bitPattern: Int8((value + (value >= 0 ? 1 : -1)) / 2))
    }

    /// An envelope that an OpenMPT before 1.20 played as FastTracker plays one, made into one that
    /// Impulse Tracker plays the same: with no loop it holds its last point, and a loop is a tick
    /// shorter, which is made so by a point put in a tick before its end.
    static func asFastTrackerLooped(_ from: IT2Envelope) -> IT2Envelope {
        var envelope = from
        let count = min(Int(envelope.Num), envelope.Tick.count, envelope.Magnitude.count)
        if envelope.SustainLoopBegin > envelope.LoopEnd, envelope.Flags & ENVF_LOOP != 0 { envelope.Flags &= ~ENVF_SUSTAINLOOP }
        if envelope.Flags & (ENVF_LOOP | ENVF_SUSTAINLOOP) == 0 {
            envelope.Flags |= ENVF_SUSTAINLOOP
            envelope.SustainLoopBegin = UInt8(max(1, count) - 1)
            envelope.SustainLoopEnd = UInt8(max(1, count) - 1)
        }
        let end = Int(envelope.LoopEnd)
        if envelope.LoopEnd > envelope.LoopBegin, envelope.Flags & ENVF_LOOP != 0, end < count {
            if Int(envelope.Tick[end]) - 1 > Int(envelope.Tick[end - 1]) {
                // A point a tick before the loop's end, at the level the envelope has there: found as
                // OpenMPT finds it, in 65536ths of the whole and rounded to one of 64.
                let tick = Int(envelope.Tick[end]) - 1
                let before = (Int(envelope.Magnitude[end - 1]) + 32) * 65536 / 64, after = (Int(envelope.Magnitude[end]) + 32) * 65536 / 64
                let first = Int(envelope.Tick[end - 1]), last = Int(envelope.Tick[end])
                let between = max(0, min(65536, before + Int(Int64(tick - first) * Int64(after - before) / Int64(last - first))))
                envelope.Tick.insert(UInt16(tick), at: end)
                envelope.Magnitude.insert(Int8((between * 64 + 32768) / 65536 - 32), at: end)
                envelope.Num += 1
            } else {
                envelope.LoopEnd -= 1
            }
        }
        return envelope
    }

    /// The rows of a beat, each as long as the file says against the others, made to add up to as
    /// many whole rows as there are: as OpenMPT makes them.
    private static func normalised(_ swing: [UInt32]) -> [UInt32] {
        guard !swing.isEmpty else { return [] }
        let unity = UInt64(OpenMPTSong.swingUnity)
        var held = swing.map { UInt64(max(unity / 4, min(unity * 4, UInt64($0)))) }
        let mean = max(1, held.reduce(0, +) / UInt64(held.count))
        var remain = Int64(unity) * Int64(held.count)
        for i in held.indices {
            held[i] = (held[i] * unity + mean / 2) / mean
            remain -= Int64(held[i])
        }
        held[0] = UInt64(max(0, Int64(held[0]) + remain))
        return held.map { UInt32(truncatingIfNeeded: $0) }
    }

    private static func swing(_ r: inout Reader) -> [UInt32] {
        let count = r.u16()
        guard count <= 4096 else { return [] }
        return normalised((0 ..< count).map { _ in UInt32(r.u16()) | UInt32(r.u16()) << 16 })
    }

    /// The song's own "extended properties", which are laid out as the instruments' are but with one
    /// value each.
    private static func songExtras(_ r: inout Reader) -> SongExtras {
        var extras = SongExtras()
        guard r.magic("STPM") else { return extras }
        extras.found = true
        while r.left >= 7 {
            let code = r.bytes(4)
            let size = r.u16()
            if code == [0x32, 0x32, 0x38, 0x04] || code.contains(where: { $0 & 0x80 != 0 }) || !code.contains(where: { $0 & 0x60 != 0 }) || r.left < size { break }
            var field = Reader(r.data, at: r.at)
            r.skip(size)
            func number() -> Int {
                var value: UInt32 = 0
                for i in 0 ..< min(4, size) { value |= UInt32(field.u8()) << UInt32(i * 8) }
                return Int(min(value, 0x7FFF_FFFF))
            }
            // (Most of the names are written last letter first, and a few are not.)
            switch String(decoding: code, as: UTF8.self) {
            case "..TD": extras.tempo = number()
            case "DTFR": extras.tempoFraction = number()
            case ".BPR": extras.rowsPerBeat = number()
            case "..MT": extras.tempoMode = number()
            case ".MMP": extras.mixLevels = number()
            case ".APS": extras.preAmp = number()
            case "VTSV": extras.synthVolume = number()
            case "...C": extras.channels = number()
            case "..PR": extras.restart = number()
            case "VWSL": extras.savedWith = number()
            case "SWNG": if size > 2 { extras.swing = swing(&field) }
            case ".FSM":
                var flags: [Bool] = []
                for _ in 0 ..< size {
                    let byte = field.u8()
                    for bit in 0 ..< 8 { flags.append(byte & (1 << bit) != 0) }
                }
                extras.behaviours = flags
            case "CUES":
                if size > 2 {
                    let sample = field.u16()
                    extras.cues[sample] = (0 ..< 9).map { _ in field.left >= 4 ? UInt32(field.u16()) | UInt32(field.u16()) << 16 : UInt32.max }
                }
            default: break
            }
        }
        return extras
    }

    /// The tunings the file carries, by name, as OpenMPT reads them: nil for one it would not read.
    private static func tunings(_ data: [UInt8], at start: Int) -> [(name: [UInt8], tuning: OpenMPTTuning?)] {
        guard let collection = Chunk(data, at: start, named: "TC") else { return [] }
        var tunings: [(name: [UInt8], tuning: OpenMPTTuning?)] = []
        for entry in collection.entries where entry.name == [0x32] { // "2"
            guard let chunk = Chunk(data, at: entry.start, named: "CTB244RTI") else {
                tunings.append(([], nil))
                continue
            }
            var name: [UInt8] = []
            if let entry = chunk.entry("0") {
                var r = Reader(data, at: entry.start)
                name = r.bytes(min(255, r.adaptive64()))
                if let end = name.firstIndex(of: 0) { name = Array(name[..<end]) }
            }
            var ratios: [Float] = []
            if let table = chunk.entry("RTI0") {
                var r = Reader(data, at: table.start)
                let count = min(256, r.adaptive64())
                ratios = (0 ..< count).map { _ in Float(bitPattern: UInt32(r.u16()) | UInt32(r.u16()) << 16) }
            }
            // (What OpenMPT has for whatever is not said: a table that starts 64 notes below middle C.)
            let tuning = OpenMPTTuning(kind: chunk.number("2", bytes: 2, in: data) ?? 0, given: ratios,
                                       lowest: Int(Int16(truncatingIfNeeded: chunk.number("RTI1", bytes: 2, in: data) ?? 0xFFC0)),
                                       notes: chunk.number("RTI4", bytes: 2, in: data) ?? 0,
                                       groupSize: Int(Int16(truncatingIfNeeded: chunk.number("RTI2", bytes: 2, in: data) ?? 0)),
                                       groupRatio: Float(bitPattern: UInt32(truncatingIfNeeded: chunk.number("RTI3", bytes: 4, in: data) ?? 0)),
                                       fineSteps: chunk.number("4", bytes: 4, in: data) ?? 0)
            tunings.append((name, tuning))
        }
        return tunings
    }

    /// The tuning each instrument has, for those that have one: the file gives each tuning in use a
    /// number, and each instrument the number of its own.
    private static func tuned(_ data: [UInt8], at start: Int, instruments: Int, tunings: [(name: [UInt8], tuning: OpenMPTTuning?)]) -> [OpenMPTTuning?] {
        var r = Reader(data, at: start)
        var names: [Int: [UInt8]] = [:]
        let count = r.u16()
        guard count <= 500 else { return [] }
        for _ in 0 ..< count {
            let name = r.bytes(r.u8())
            names[r.u16()] = name
        }
        return (0 ..< instruments).map { _ in
            guard r.left >= 2, let name = names[r.u16()] else { return nil }
            // OpenMPT's word for no tuning; and one it does not find among the file's is no tuning either.
            if name == Array("->MPT_ORIGINAL_IT<-".utf8) { return nil }
            return tunings.first(where: { $0.name == name })?.tuning
        }
    }

    // MARK: Making the module

    /// One channel's part of a row as the IT file's pattern has it.
    private typealias Cell = IT2ForeignModule.Cell

    /// A pattern as the file packs it, unpacked: `rows` rows of 64 cells.
    private static func unpacked(_ packed: [UInt8], rows: Int) -> IT2ForeignModule.Pattern {
        var pattern = IT2ForeignModule.Pattern(rows: rows)
        var masks = [UInt8](repeating: 0, count: 64)
        var last = [Cell](repeating: Cell(), count: 64)
        var at = 0, row = 0
        func next() -> UInt8 {
            at += 1
            return at <= packed.count ? packed[at - 1] : 0
        }
        while row < rows, at < packed.count {
            let what = next()
            if what == 0 {
                row += 1
                continue
            }
            let channel = (Int(what & 0x7F) - 1) & 63
            if what & 0x80 != 0 { masks[channel] = next() }
            let mask = masks[channel]
            if mask & 1 != 0 { last[channel].note = next() }
            if mask & 2 != 0 { last[channel].instrument = next() }
            if mask & 4 != 0 { last[channel].volume = next() }
            if mask & 8 != 0 {
                last[channel].command = next()
                last[channel].value = next()
            }
            var cell = Cell()
            if mask & 0x11 != 0 { cell.set(note: last[channel].note) }
            if mask & 0x22 != 0 { cell.set(instrument: last[channel].instrument) }
            if mask & 0x44 != 0 { cell.set(volume: last[channel].volume) }
            if mask & 0x88 != 0 { cell.set(command: last[channel].command, last[channel].value) }
            pattern[row, channel] = cell
        }
        return pattern
    }

    /// OpenMPT's own commands, by the numbers an MPTM file gives them after Impulse Tracker's 26.
    private enum Own {
        static let Z: UInt8 = 26, longValue: UInt8 = 27, smoothMacro: UInt8 = 28, delayCut: UInt8 = 29, bend: UInt8 = 30, smoothBend: UInt8 = 31
    }

    /// What kind of sound a sample has, as far as playing it here goes.
    private enum SampleKind {
        case sound, none
        /// A patch for the AdLib's FM chip.
        case fm
        /// In a file of its own beside the module.
        case elsewhere
    }

    static func renderer(_ data: [UInt8], options: LoadOptions) throws -> ITRenderer {
        guard let ownAt = ownPart(data) else {
            // An IT file under an MPTM file's name is an IT file.
            return try ITRenderer(data, options: options)
        }
        let header = Header(data)
        // (Two short-lived layouts of 2006 and 2007, which kept the list of patterns and the tunings otherwise.)
        guard header.version >= 0x88E else { throw TuneError.unsupported("an MPTM file of OpenMPT 1.17's making") }
        let file = try IT2Module(data, openMPT: true)
        guard let own = Chunk(data, at: ownAt, named: "mptm") else { throw TuneError.malformed("an MPTM file whose own part cannot be read") }

        // MARK: Where the file's own extras are

        // After the last of the samples' sound and of the patterns, whichever ends later. A sample
        // packed as Impulse Tracker packs them is in blocks, each with its length before it.
        var r = Reader(data, at: header.places + header.instruments * 4)
        let samplePlaces = (0 ..< header.samples).map { _ in r.u32() }
        let patternPlaces = (0 ..< header.patterns).map { _ in r.u32() }
        var extrasAt = header.samples > 0 ? samplePlaces[header.samples - 1] + 80 : 0
        var kinds = [SampleKind](repeating: .none, count: file.sampleLimit)
        for index in 0 ..< header.samples where samplePlaces[index] > 0 && samplePlaces[index] + 80 <= data.count {
            var s = Reader(data, at: samplePlaces[index] + 0x12)
            let flags = s.u8()
            s.at = samplePlaces[index] + 0x2E
            let convert = s.u8()
            s.at = samplePlaces[index] + 0x30
            let length = s.u32()
            s.at = samplePlaces[index] + 0x48
            let soundAt = s.u32()
            guard soundAt <= data.count else { continue }
            s.at = soundAt
            let sixteen = flags & Int(SMPF_16BIT) != 0, sides = flags & Int(SMPF_STEREO) != 0 ? 2 : 1
            if convert == Int(IT2Module.adLibPatch) {
                kinds[index] = file.sample(index)?.AdLib != nil ? .fm : .none
                s.skip(12)
            } else if convert == 0x80 {
                kinds[index] = length > 0 ? .elsewhere : .none
                // The name of its file, with how long that is before it, seven bits to a byte.
                var nameLength = 0, more = true
                while more, s.left > 0 {
                    let byte = s.u8()
                    nameLength = min(0xFFFF, nameLength << 7 | byte & 0x7F)
                    more = byte & 0x80 != 0
                }
                s.skip(nameLength)
            } else if length > 0 {
                kinds[index] = file.sample(index)?.Data != nil ? .sound : .none
                if flags & Int(SMPF_COMPRESSED) != 0 {
                    let block = sixteen ? 0x4000 : 0x8000
                    for _ in 0 ..< sides {
                        var done = 0
                        while done < length, s.left >= 2 {
                            s.skip(s.u16())
                            done += block
                        }
                    }
                } else {
                    // (As much as there is of it: a number of bytes that a browser cannot count is more than any file.)
                    s.skip(length <= 0x0FFF_FFFF ? length * (sixteen ? 2 : 1) * sides : s.left)
                }
            }
            extrasAt = max(extrasAt, s.at)
        }
        // (And how many rows each pattern has, as OpenMPT takes it: one the file leaves out is 64
        // empty rows, and one of no rows, or of more than 1024, is no pattern at all.)
        var patternRows = [Int](repeating: 64, count: header.patterns)
        for (index, place) in patternPlaces.enumerated() where place > 0 && place <= data.count {
            var p = Reader(data, at: place)
            let length = p.u16()
            let rows = p.u16()
            patternRows[index] = rows < 1 || rows > 1024 ? 0 : rows
            if rows < 1 || rows > 1024 || p.left < 4 { continue }
            p.skip(4 + length)
            extrasAt = max(extrasAt, p.at)
        }

        r = Reader(data, at: extrasAt)
        var instrumentExtras = instrumentExtras(&r, count: header.instruments)
        let song = songExtras(&r)

        // MARK: Plug-ins

        // They are kept between the header and the first of the instruments, samples and patterns,
        // after the history of the file's making and its MIDI settings: each plug-in by its place,
        // and which of them each channel is sent through.
        var plugins = Set<Int>()
        var sound = ModPlugSound()
        do {
            var p = Reader(data, at: header.places)
            var firstPlace = data.count
            for _ in 0 ..< header.instruments + header.samples + header.patterns {
                let place = p.u32()
                if place > 0 { firstPlace = min(firstPlace, place) }
            }
            if header.special & 2 != 0 { p.skip(p.u16() * 8) }
            if header.flags & Int(ITF_REQ_MIDI_CFG) != 0 || header.special & 8 != 0 { p.skip(IT2Module.midiDataLength) }
            if p.magic("PNAM") { p.skip(p.u32()) }
            if p.magic("CNAM") { p.skip(p.u32()) }
            while p.at + 8 <= firstPlace, p.left >= 9 {
                let code = p.bytes(4)
                let size = p.u32()
                if code == Array("IMPI".utf8) || code == Array("IMPS".utf8) || code == Array("XTPM".utf8) || code == Array("STPM".utf8) || size > p.left { break }
                // "FX00" to "FX99" and on to "F255": a plug-in, which is there if it says what it is.
                let digits = code.map { Int($0) - 0x30 }
                if code[0] == 0x46, code[1] == 0x58 || (0 ... 9).contains(digits[1]), (0 ... 9).contains(digits[2]), (0 ... 9).contains(digits[3]) {
                    let number = (code[1] == 0x58 ? 0 : digits[1] * 100) + digits[2] * 10 + digits[3]
                    let plugIn = ModPlugPlugIn(data, at: p.at, size: size)
                    if size >= 8, plugIn.isThere {
                        plugins.insert(number + 1)
                        while sound.plugIns.count <= number { sound.plugIns.append(ModPlugPlugIn()) }
                        sound.plugIns[number] = plugIn
                    }
                } else if code == Array("CHFX".utf8) {
                    var channels = Reader(data, at: p.at)
                    sound.channelPlugIns = (0 ..< min(size / 4, MAX_HOST_CHANNELS)).map { _ in min(channels.u32(), 255) }
                }
                p.skip(size)
            }
        }

        // MARK: Instruments and samples

        // An instrument's MIDI channel is, in an old file, where its plug-in is named; and in any
        // file it is something to tell a plug-in, where to Impulse Tracker it means a note that is
        // not a sample's at all. So it is taken away, and the instrument plays its samples.
        let instrumentMode = file.usesInstruments

        // OpenMPT has changed how it plays some things since it first wrote these files, and when it
        // reads one written before such a change it changes the file to suit, so that the file
        // sounds as it did. The same is done here, by the version that last saved the file: its four
        // parts a byte each, as 0x01170302 for 1.17.03.02. (A file that does not say is left alone.)
        let saved = song.savedWith == 0 ? Int(Int32.max) : song.savedWith
        var behaviours = song.behaviours ?? []
        func asks(_ behaviour: Int) -> Bool { behaviour < behaviours.count && behaviours[behaviour] }
        func set(_ behaviour: Int, _ on: Bool) {
            while behaviours.count <= behaviour { behaviours.append(false) }
            behaviours[behaviour] = on
        }
        // "Compatible play", which until 1.26 was one switch for all of Impulse Tracker's ways together.
        let compatible = asks(Behaviour.compatiblePlay) && !(saved < 0x0117_0246 && saved != 0x0117_0000)
        if compatible, saved < 0x0126_0000 {
            for (behaviour, since) in Behaviour.compatiblePlayWays { set(behaviour, saved >= since || saved == since & 0x7FFF_0000) }
        }
        if saved < 0x0117_0000 { set(Behaviour.tempoClamp, true) }
        // (And a way of playing that came in with a later version is not one an earlier version
        // can have asked for, whatever its file says; but that a file made for another program
        // gives only the first two parts of the version.)
        for (behaviour, since) in [(Behaviour.jumpsEndLoops, 0x0129_0032), (Behaviour.unmappedNotesDoNothing, 0x0132_0013)] {
            if saved < since, saved != since & 0x7FFF_0000 { set(behaviour, false) }
        }

        // (And with anything random in an instrument, what is random is played as it was before 1.17.02.50.)
        if saved < 0x0117_0250, (0 ..< header.instruments).contains(where: {
            let ins = file.instrument($0), extras = instrumentExtras[$0]
            return ins.RandVol | ins.RandPan != 0 || extras.cutoffSwing | extras.resonanceSwing != 0
        }) { set(Behaviour.oldSwing, true) }

        for index in 0 ..< header.instruments {
            let ins = file.instrument(index)
            if ins.MIDIChn >= 128, instrumentExtras[index].plugin == 0 { instrumentExtras[index].plugin = Int(ins.MIDIChn) - 128 }
            ins.MIDIChn = 0
            // (A note that is to be played as no note at all is played as itself.)
            for note in 0 ..< 120 where ins.SmpNoteTable[note] & 0xFF >= 120 { ins.SmpNoteTable[note] = ins.SmpNoteTable[note] & 0xFF00 | UInt16(note) }
            let extras = instrumentExtras[index]
            if extras.filterMode <= 1 { ins.FilterMode = UInt8(extras.filterMode) }
            ins.CutSwing = UInt8(min(64, extras.cutoffSwing & 0xFF))
            ins.ResSwing = UInt8(min(64, extras.resonanceSwing & 0xFF))
            for which in 0 ..< 3 where extras.points[which] >= 0 || !extras.ticks[which].isEmpty || !extras.levels[which].isEmpty {
                // An envelope given again in the extras, which is how one of more points than an IT
                // file has room for is given at all: how many points, and then the ticks and the
                // levels of as many of them as there are.
                var envelope = which == 0 ? ins.VolEnv : which == 1 ? ins.PanEnv : ins.PitchEnv
                let count = extras.points[which] >= 0 ? extras.points[which] : Int(envelope.Num)
                let room = max(25, count)
                var ticks = [UInt16](repeating: 0, count: room), levels = [Int8](repeating: 0, count: room)
                for i in 0 ..< min(count, Int(envelope.Num), 25) {
                    ticks[i] = envelope.Tick[i]
                    levels[i] = envelope.Magnitude[i]
                }
                for i in 0 ..< min(count, extras.ticks[which].count) { ticks[i] = extras.ticks[which][i] }
                // (Given from 0 to 64, where the two that are not for volume are kept from -32 to 32.)
                for i in 0 ..< min(count, extras.levels[which].count) { levels[i] = Int8(min(64, Int(extras.levels[which][i])) - (which == 0 ? 0 : 32)) }
                envelope.Num = UInt8(count)
                envelope.Tick = ticks
                envelope.Magnitude = levels
                if which == 0 { ins.VolEnv = envelope } else if which == 1 { ins.PanEnv = envelope } else { ins.PitchEnv = envelope }
            }
            if extras.releaseNode != Int(IT2Envelope.noReleaseNode), ins.VolEnv.Num > 0 {
                ins.VolEnv.ReleaseNode = UInt8(min(extras.releaseNode, Int(ins.VolEnv.Num) - 1))
                // (Until 1.28 a key let go moved the level by as much as the envelope had moved, and not in proportion.)
                if saved < 0x0128_0012 { set(Behaviour.legacyReleaseNode, true) }
            }

            // What an older OpenMPT meant by the same numbers.
            if saved < 0x0120_0000 {
                // The volume's random swing was of 64 and not of 100.
                ins.RandVol = UInt8(min(100, Int(ins.RandVol) * 100 / 64))
                if !compatible || saved < 0x0118_0000 { ins.PitchPanSep = halved(ins.PitchPanSep) }
                if !compatible || saved < 0x0117_0302 { ins.PitchEnv = asFastTrackerLooped(ins.PitchEnv) }
            }
            if saved < 0x0122_0312, saved != 0x0122_0000, compatible || asks(Behaviour.oldSwing), ins.PanEnv.Flags & ENVF_ENABLED != 0 { ins.RandPan = 0 }
            if saved < 0x0126_0000 {
                // How far higher notes go to one side was half as much, and the random swing of a
                // note's place a quarter.
                ins.PitchPanSep = halved(ins.PitchPanSep)
                if !compatible || saved < 0x0118_0000 { ins.RandPan = UInt8((Int(ins.RandPan) + 3) / 4) }
            }
        }
        if saved < 0x0120_0000, saved < 0x0117_0302 || !compatible {
            // A sample's own vibrato that was to come in at once said so with nought, which to
            // Impulse Tracker is never.
            for index in 0 ..< header.samples {
                guard let s = file.sample(index) else { continue }
                if s.AutoVibratoRate == 0, s.AutoVibratoDepth & 0x7F | s.AutoVibratoSpeed != 0 { s.AutoVibratoRate = 255 }
            }
        }
        for index in 0 ..< header.samples {
            guard let s = file.sample(index) else { continue }
            // As OpenMPT has them: a rate, and loops that are within the sample and have something in them.
            if s.C5Speed == 0 { s.C5Speed = 8363 } else if s.C5Speed < 256 { s.C5Speed = 256 }
            s.LoopEnd = min(s.LoopEnd, s.Length)
            s.SustainLoopEnd = min(s.SustainLoopEnd, s.Length)
            if s.LoopBegin >= s.LoopEnd {
                s.LoopBegin = 0
                s.LoopEnd = 0
                s.Flags &= ~(SMPF_USE_LOOP | SMPF_LOOP_PINGPONG)
            }
            if s.SustainLoopBegin >= s.SustainLoopEnd {
                s.SustainLoopBegin = 0
                s.SustainLoopEnd = 0
                s.Flags &= ~(SMPF_USE_SUSTAINLOOP | SMPF_SUSTAINLOOP_PINGPONG)
            }
            // Nine places a note can be started from, which are 2048 samples apart if the file names none.
            s.cues = song.cues[index + 1] ?? (1 ... 9).map { UInt32($0) << 11 }
        }

        // MARK: Lists of patterns

        // The file's own lists ("sequences"), each a song: its patterns by sixteen-bit numbers,
        // where it starts again, and its speed and tempo. An older file has one list in the same
        // part of the file, and an older one still only the IT file's.
        struct List {
            var patterns: [Int] = []
            var restart: Int?
            var speed = 0, tempo = 0
        }
        var lists: [List] = []
        if let entry = own.entry("mptSeqC"), let all = Chunk(data, at: entry.start, named: "mptSeqC") {
            let count = min(50, all.number("n", bytes: 1, in: data) ?? 0)
            for index in 0 ..< count {
                var list = List()
                if let one = all.entry([UInt8(index)]), let chunk = Chunk(data, at: one.start, named: "mptSeq") {
                    let length = min(4096, chunk.number("l", bytes: 2, in: data) ?? 0)
                    if let places = chunk.entry("a") {
                        var p = Reader(data, at: places.start)
                        list.patterns = (0 ..< length).map { _ in p.u16() }
                    }
                    if let restart = chunk.number("r", bytes: 2, in: data), restart < length { list.restart = restart }
                    list.tempo = chunk.number("t", bytes: 4, in: data) ?? 0
                    list.speed = chunk.number("s", bytes: 4, in: data) ?? 0
                }
                lists.append(list)
            }
        }
        if lists.isEmpty {
            var list = List()
            if let entry = own.entry("2") {
                var p = Reader(data, at: entry.start)
                list.patterns = (0 ..< min(4096, p.u16())).map { _ in p.u16() }
            } else {
                // (An MPTM file's count of them has no end of the list in it, as an IT file's has.)
                var p = Reader(data, at: 192)
                list.patterns = (0 ..< min(256, header.orders)).map { _ in
                    let pattern = p.u8()
                    return pattern >= 0xFE ? 0xFF00 | pattern : pattern
                }
            }
            lists.append(list)
        }
        // A list with no pattern in it is no song, and is left out: a file may keep an empty one.
        let withPatterns = lists.filter { list in list.patterns.contains { $0 < header.patterns && patternRows[$0] > 0 } }
        if !withPatterns.isEmpty { lists = withPatterns }

        // The speed and the tempo the header gives, and the song's extras after it, are every
        // list's that does not give its own.
        var h = Reader(data, at: 0x32)
        let headerSpeed = h.u8(), headerTempo = h.u8()
        var tempo = max(31, headerTempo) * OpenMPTSong.tempoUnit
        if let whole = song.tempo { tempo = min(whole, 0xFFFF) * OpenMPTSong.tempoUnit }
        tempo += min(song.tempoFraction, OpenMPTSong.tempoUnit - 1)
        tempo = max(OpenMPTSong.leastTempo * OpenMPTSong.tempoUnit, min(OpenMPTSong.mostTempo * OpenMPTSong.tempoUnit, tempo))

        var openMPT = OpenMPTSong()
        var orders: [UInt8] = []
        var tooMany = false
        for (index, list) in lists.enumerated() {
            if index > 0 { orders.append(255) }
            var sequence = OpenMPTSong.Sequence()
            sequence.first = orders.count
            sequence.count = list.patterns.count
            // (Where it starts again is its own to say, and the song's extras' if it does not.)
            sequence.restart = orders.count + (list.restart ?? (song.restart < list.patterns.count ? song.restart : 0))
            sequence.speed = UInt8(max(1, min(255, list.speed > 0 ? list.speed : headerSpeed > 0 ? headerSpeed : 6)))
            sequence.tempo = list.tempo > 0
                ? max(OpenMPTSong.leastTempo * OpenMPTSong.tempoUnit, min(OpenMPTSong.mostTempo * OpenMPTSong.tempoUnit, list.tempo)) : tempo
            for pattern in list.patterns {
                // 0xFFFF ends the song and 0xFFFE is passed over, as an IT file's 255 and 254 are.
                // (The replayer names a pattern in a byte; a file with more patterns than that is refused below.)
                // And a place that names a pattern the file does not have is passed over too.
                if pattern >= 0xFFFE { orders.append(pattern == 0xFFFE ? 254 : 255) } else if pattern >= header.patterns || patternRows[pattern] == 0 {
                    orders.append(254)
                } else if pattern < IT2Module.mostPatterns {
                    orders.append(UInt8(pattern))
                } else {
                    tooMany = true
                    orders.append(254)
                }
            }
            openMPT.sequences.append(sequence)
        }
        if tooMany { throw TuneError.unsupported("an MPTM file with more than \(IT2Module.mostPatterns) patterns") }

        // MARK: Time

        openMPT.tempoMode = song.tempoMode == 2 ? .modern : song.tempoMode == 1 ? .alternative : .classic
        // The rows of a beat: the header's, if it says it has them; the song's extras' if not.
        var q = Reader(data, at: 0x1E)
        var rowsPerBeat = header.special & 4 != 0 ? q.u8() : 4
        if let own = song.rowsPerBeat { rowsPerBeat = own }
        if rowsPerBeat == 0, openMPT.tempoMode == .modern { rowsPerBeat = 1 }
        openMPT.rowsPerBeat = min(rowsPerBeat, 0xFFFF)
        if !song.swing.isEmpty {
            // (Made as long as a beat without being evened out again, as OpenMPT leaves it.)
            openMPT.swing = (0 ..< max(1, openMPT.rowsPerBeat)).map { $0 < song.swing.count ? song.swing[$0] : 0 }
        }
        openMPT.tempoCeiling = asks(Behaviour.tempoClamp) ? 255 : OpenMPTSong.mostTempo
        openMPT.legacyReleaseNode = asks(Behaviour.legacyReleaseNode)
        openMPT.offsetAsImpulseTracker = asks(Behaviour.offsetAsImpulseTracker)
        openMPT.loopsOutlastJumps = !asks(Behaviour.jumpsEndLoops) && !asks(Behaviour.jumpsEndLoopsOld)
        openMPT.unmappedNotesKeepCommands = !asks(Behaviour.unmappedNotesDoNothing)
        openMPT.itVibrato = asks(Behaviour.itVibrato)

        // Each pattern's own rows to a beat and swing, where it has them.
        openMPT.patternRowsPerBeat = [UInt16](repeating: 0, count: file.patternLimit)
        openMPT.patternSwing = [[UInt32]](repeating: [], count: file.patternLimit)
        if let entry = own.entry("mptPc"), let all = Chunk(data, at: entry.start, named: "mptPc") {
            for index in 0 ..< min(file.patternLimit, all.number("num", bytes: 2, in: data) ?? file.patternLimit) {
                guard let one = all.entry([UInt8(index & 0xFF), UInt8(index >> 8)]), let chunk = Chunk(data, at: one.start, named: "mptP") else { continue }
                let beat = chunk.number("RPB.", bytes: 4, in: data) ?? 0, measure = chunk.number("RPM.", bytes: 4, in: data) ?? 0
                // (Only a pair that makes sense is taken: a beat of some rows, and a measure of no fewer.)
                if beat >= 1, beat <= 0xFFFF, measure >= beat, measure <= 0xFFFF { openMPT.patternRowsPerBeat[index] = UInt16(beat) }
                // The rows that change a plug-in's setting, which are kept here and not in the IT
                // file's pattern: a row at a time, each cell with which of its six parts differ
                // from the cell last given for its channel.
                if let entry = chunk.entry("data"), index < patternRows.count, sound.plugIns.contains(where: { $0.kind != nil }) {
                    var d = Reader(data, at: entry.start)
                    let end = entry.size >= 0 ? min(data.count, entry.start + entry.size) : data.count
                    var last = [[UInt8]](repeating: [0, 0, 0, 0, 0, 0], count: 128)
                    var row = 0
                    while row < patternRows[index], d.at < end {
                        let what = d.u8()
                        if what == 0 {
                            row += 1
                            continue
                        }
                        let channel = (what & 0x7F) - 1
                        guard channel >= 0 else { continue }
                        if what & 0x80 != 0 {
                            let mask = d.u8()
                            for part in 0 ..< 6 where mask & (1 << part) != 0 { last[channel][part] = UInt8(d.u8()) }
                        }
                        let cell = last[channel]
                        guard cell[0] == 0xFC || cell[0] == 0xFB, cell[1] > 0 else { continue }
                        let setting = Int(cell[2]) << 8 | Int(cell[3]), value = min(999, Int(cell[4]) << 8 | Int(cell[5]))
                        guard setting < 1024 else { continue }
                        let note = UInt32(cell[0] == 0xFB ? 1 : 0) << 31 | UInt32(cell[1]) << 20 | UInt32(setting) << 10 | UInt32(value)
                        openMPT.parameterNotes[index << 16 | row, default: []].append(note)
                    }
                }
                if let entry = chunk.entry("SWNG") {
                    var s = Reader(data, at: entry.start)
                    let swing = swing(&s)
                    if !swing.isEmpty {
                        let beat = Int(openMPT.patternRowsPerBeat[index])
                        // (And this one is evened out again once it has been made as long as the beat.)
                        openMPT.patternSwing[index] = normalised((0 ..< beat).map { $0 < swing.count ? swing[$0] : 0 })
                    }
                }
            }
        }

        // MARK: Tunings

        // An instrument can be tuned to a scale of OpenMPT's: see `OpenMPTTuning`, and the replayer's
        // `openMPTTunedPitch`, which plays its notes, slides and vibratos as OpenMPT plays them.
        if header.instruments > 0, let map = own.entry("1") {
            let all = own.entry("0").map { tunings(data, at: $0.start) } ?? []
            for (instrument, tuning) in tuned(data, at: map.start, instruments: header.instruments, tunings: all).enumerated() {
                if let tuning { file.instrument(instrument).Tuning = tuning }
            }
        }

        // MARK: Patterns

        // Every pattern is unpacked, looked through and packed again. A command of OpenMPT's own
        // that the replayer has not been taught is taken out or made into the nearest it has; a value
        // that goes on into the rows below is put together and kept apart; and every note is counted
        // under whether it will be heard.
        var packed = [[UInt8]?](repeating: nil, count: file.patternLimit)
        var rowCounts = [UInt16](repeating: 0, count: file.patternLimit)
        var played = [Bool](repeating: false, count: file.patternLimit)
        for order in orders where Int(order) < file.patternLimit { played[Int(order)] = true }
        var notes = 0, pluginNotes = 0, fmNotes = 0, elsewhereNotes = 0
        var silentInstruments = Set<Int>(), elsewhereInstruments = Set<Int>(), usedInstruments = Set<Int>()
        // The plug-ins that are not OpenMPT's own, and so are not played.
        let leftOut = plugins.filter { sound.plugIns[$0 - 1].kind == nil }
        var bends = 0, reverbs = 0, speakerCommands = 0
        // The file's MIDI macros, for telling one that sets a filter from one that sets a plug-in:
        // sixteen that a command chooses among and gives a value, and 128 with a value of their own.
        let macros = file.midiData ?? IT2Module.defaultMIDIData()
        func macroIsForPlugIn(_ slot: Int) -> Bool {
            let at = slot * 32
            guard at + 6 <= macros.count, macros[at ..< at + 4].elementsEqual(Array("F0F0".utf8)) else { return false }
            return macros[at + 4] >= 0x38 || (macros[at + 4] == 0x30 && macros[at + 5] == 0x33) // "8…" and up, or "03"
        }
        var highestChannel = 0
        typealias Command = IT2ForeignModule.Command
        let oldEffects = file.Flags & ITF_OLD_EFFECTS != 0
        let tremorAsImpulseTracker = asks(Behaviour.tremorAsImpulseTracker)

        /// A cell of a file that an older OpenMPT saved, made to mean to the OpenMPT of now what it
        /// meant to that one: which is what OpenMPT does to such a file as it reads it.
        func asNow(_ cell: inout Cell) {
            func clearVolume() {
                cell.mask &= ~4
                cell.volume = 0
            }
            var command = cell.hasCommand ? cell.command : 0
            if command > 31 || command == 0 {
                // (No command of OpenMPT's has such a number.)
                cell.clearCommand()
                command = 0
            }
            let high = cell.value & 0xF0, low = cell.value & 0x0F
            if saved < 0x0117_0302 || (!compatible && saved < 0x0120_0000) {
                // A volume for the whole song beyond the most there is was the most; a note cut or
                // delayed by no ticks was cut at once, or not delayed.
                if command == Command.V { cell.value = min(cell.value, 128) }
                if command == Command.S, cell.value == 0xC0 {
                    cell.clearCommand()
                    cell.set(note: IT2ForeignModule.noteCut)
                    command = 0
                } else if command == Command.S, cell.value == 0xD0 {
                    cell.clearCommand()
                    command = 0
                }
            }
            // A slide given both a way up and a way down went one of them, where Impulse Tracker does nothing.
            let ofNote = (saved < 0x0118_0000 || (!compatible && saved < 0x0120_0000))
                && (command == Command.D || command == Command.K || command == Command.L || command == 16)
            let ofChannel = saved < 0x0120_0000 && (command == 23 || command == 14)
            if ofNote || ofChannel, low != 0, low != 0x0F, high != 0, high != 0xF0 { cell.value &= command == 23 ? 0xF0 : 0x0F }
            // An instrument the file does not have silenced the channel.
            if saved < 0x0122_0104, saved != 0x0122_0000, !compatible, instrumentMode, cell.hasInstrument, Int(cell.instrument) > header.instruments {
                cell.set(volume: 0)
            }
            // I11 was I00.
            if command == Command.I, cell.value == 0x11, saved < 0x0129_1202, tremorAsImpulseTracker, !oldEffects { cell.value = 0 }
            // A vibrato in the volume column beside one in the command took turns with it.
            if cell.hasVolume, cell.volume >= 203, cell.volume <= 212, saved < 0x0127_0037, saved != 0x0127_0000 {
                let depth = cell.volume - 203
                if command == Command.K, depth > 0 {
                    cell.set(command: Command.D, cell.value)
                } else if command == Command.H || command == Command.U, low == 0 {
                    cell.set(command: Command.H, cell.value | depth & 0x0F)
                    clearVolume()
                } else if command == Command.H || command == Command.K || command == Command.U {
                    clearVolume()
                }
            }
            // And an offset in the command took the place of one in the volume column, until 1.30
            // made the two work together.
            if cell.hasVolume, cell.volume >= 223, cell.volume <= 232, command == Command.O, saved < 0x0130_0014 {
                if cell.value != 0 || cell.volume == 223 { clearVolume() } else { cell.clearCommand() }
            }
        }

        for index in 0 ..< min(header.patterns, file.patternLimit) where patternRows[index] > 0 {
            let rows = patternRows[index]
            // (A pattern with nothing in it is so many empty rows.)
            var pattern = file.hasPattern(index) ? unpacked(file.pattern(index).data, rows: rows) : IT2ForeignModule.Pattern(rows: rows)
            if saved < 0x0120_0000 {
                // Of several delays on one row, of ticks or of rows, the last was the one that counted.
                for row in 0 ..< rows {
                    var ticks = false, repeats = false
                    for channel in (0 ..< MAX_HOST_CHANNELS).reversed() {
                        let cell = pattern[row, channel]
                        guard cell.hasCommand, cell.command == Command.S, cell.value & 0xF0 == 0x60 || cell.value & 0xF0 == 0xE0 else { continue }
                        let isTicks = cell.value & 0xF0 == 0x60
                        if isTicks ? ticks : repeats { pattern[row, channel].clearCommand() }
                        if isTicks { ticks = true } else { repeats = true }
                    }
                }
            }
            var instruments = [Int](repeating: 0, count: MAX_HOST_CHANNELS)
            var chosenMacro = [Int](repeating: 0, count: MAX_HOST_CHANNELS)
            for row in 0 ..< rows {
                for channel in 0 ..< MAX_HOST_CHANNELS {
                    var cell = pattern[row, channel]
                    if cell.mask == 0 { continue }
                    highestChannel = max(highestChannel, channel)
                    if cell.hasInstrument { instruments[channel] = Int(cell.instrument) }
                    if cell.hasNote, cell.note >= 120, cell.note < 251 {
                        // (Above the 120 notes Impulse Tracker has, and below the marks that are not notes.)
                        cell.mask &= ~1
                        cell.note = 0
                    }
                    if cell.hasNote, cell.note < 120, played[index] {
                        // What will play it, as far as can be told from the rows above it.
                        let instrument = instruments[channel]
                        var sample = instrument
                        var plugin = 0
                        if instrumentMode {
                            sample = Int(file.instrument(instrument - 1).SmpNoteTable[Int(cell.note)] >> 8)
                            if instrument >= 1, instrument <= header.instruments { plugin = instrumentExtras[instrument - 1].plugin }
                        }
                        let kind = sample >= 1 && sample <= kinds.count ? kinds[sample - 1] : .none
                        notes += 1
                        if instrument > 0 { usedInstruments.insert(instrument) }
                        switch kind {
                        case .sound: break
                        case .fm:
                            fmNotes += 1
                        case .elsewhere:
                            elsewhereNotes += 1
                            elsewhereInstruments.insert(instrument)
                        case .none:
                            // (A plug-in that is an effect makes no sound of a note, here or in OpenMPT.)
                            if leftOut.contains(plugin) {
                                pluginNotes += 1
                                silentInstruments.insert(instrument)
                            }
                        }
                    }
                    asNow(&cell)
                    if cell.hasCommand {
                        switch cell.command & 31 {
                        case Own.bend, Own.smoothBend:
                            cell.clearCommand()
                            if played[index] { bends += 1 }
                        case IT2ForeignModule.Command.B, IT2ForeignModule.Command.C, IT2ForeignModule.Command.T, IT2ForeignModule.Command.O:
                            // A value that goes on into the rows below: for one row, or for an offset two.
                            var value = Int(cell.value), more = 0
                            let most = cell.command & 31 == IT2ForeignModule.Command.O ? 2 : 1
                            while more < most, row + more + 1 < rows {
                                let below = pattern[row + more + 1, channel]
                                guard below.hasCommand, below.command & 31 == Own.longValue else { break }
                                value = value << 8 | Int(below.value)
                                more += 1
                            }
                            if more > 0 { openMPT.longValues[OpenMPTSong.place(pattern: index, row: row, channel: channel)] = more << 24 | value }
                        case IT2ForeignModule.Command.S:
                            if cell.value & 0xF0 == 0xF0 { chosenMacro[channel] = Int(cell.value & 0x0F) }
                            if played[index], cell.value == 0x99 { reverbs += 1 }
                            if played[index], cell.value >= 0x9A, cell.value <= 0x9D { speakerCommands += 1 }
                        default: break
                        }
                    }
                    pattern[row, channel] = cell
                }
            }
            packed[index] = pattern.packed()
            rowCounts[index] = UInt16(rows)
        }

        // MARK: What is not heard

        let unheard = pluginNotes + elsewhereNotes
        if notes > 0, unheard * 2 >= notes {
            if pluginNotes >= elsewhereNotes { throw TuneError.unsupported("an MPTM file that is mostly for plug-ins") }
            throw TuneError.unsupported("an MPTM file most of whose samples are in other files")
        }

        var shortfalls: [String] = []
        func say(_ count: Int, one: String, many: String) {
            if count == 1 { shortfalls.append(one) } else if count > 1 { shortfalls.append(Shortfall.capitalNumber(count) + many) }
        }
        say(silentInstruments.count, one: "One of its instruments plays through a plug-in, and is not heard.",
            many: " of its instruments play through plug-ins, and are not heard.")
        say(elsewhereInstruments.count, one: "One of its instruments has its sample in another file, and is not heard.",
            many: " of its instruments have their samples in other files, and are not heard.")
        if let sentence = Shortfall.plugInsLeftOut(leftOut.sorted().map { sound.plugIns[$0 - 1].title }, of: plugins.count) { shortfalls.append(sentence) }
        say(bends, one: "One command that bends a note's pitch is left out.", many: " commands that bend a note's pitch are left out.")
        if reverbs > 0 { shortfalls.append("Its reverb is left out.") }
        if speakerCommands > 0 { shortfalls.append("What it asks of four speakers, and of filters on its whole sound, is left out.") }

        // MARK: The rest

        // Where each channel is, how loud, and whether it is heard: as the IT file has them, but
        // that a channel the file says nothing of is in the middle and is heard.
        var pans = file.ChnlPan, volumes = file.ChnlVol
        for channel in 0 ..< MAX_HOST_CHANNELS {
            let place = pans[channel] & 0x7F
            if pans[channel] == 0xFF {
                pans[channel] = 32
                volumes[channel] = 64
            } else if place > 64, place != PAN_SURROUND {
                pans[channel] = pans[channel] & 0x80 | 32
            }
            volumes[channel] = min(volumes[channel], 64)
        }

        // How loud. What the header calls the mixing volume is OpenMPT's "sample pre-amp", which can
        // be more than the header's byte holds; and which of its ways of adding the channels up
        // ("mix levels") a file asks for decides how loud that makes it. The way it has that is
        // like Impulse Tracker's is as loud as Impulse Tracker. Its way of 1.17 is twice as loud,
        // and puts a channel that is to one side at no more than a channel in the middle. Its oldest
        // ways are quieter the more channels a song has, by a table of ModPlug Tracker's.
        let preAmp = max(1, min(2000, song.preAmp ?? Int(file.MixVolume)))
        let mixLevels = song.mixLevels ?? (song.found ? 0 : 3)
        openMPT.softPanning = mixLevels == 3
        var level: Float = mixLevels == 3 ? 2 : 1
        if mixLevels < 3 {
            let channels = max(1, min(31, max(highestChannel + 1, song.channels)))
            level = IT2Mixer.PreAmpTable[channels / 2]
        }
        openMPT.gain = Float(preAmp) / Float(min(preAmp, 128)) * level * loudness

        // MARK: Plug-ins and FM

        // What there is to hear besides samples. The FM chip is as loud as OpenMPT makes it against
        // the samples, which depends on all of the above; a plug-in is given sound as loud as
        // OpenMPT gives it, which in its two oldest ways of adding up is a half and a sixteenth of
        // what it would otherwise be; and in all but those two the song's volume is applied last.
        sound.level = Float(preAmp) / Float(min(preAmp, 128)) * level
        sound.plugInScale = mixLevels == 0 ? 0.5 : mixLevels == 1 ? 1.0 / 16.0 : 1
        sound.globalVolumeAtMaster = mixLevels >= 2
        sound.adLibLevel = ModPlugSound.adLibLevel(synthVolume: song.synthVolume)
        if fmNotes > 0 {
            sound.adLib = OpenMPTAdLib.Behaviour(flexibleNoteOff: asks(Behaviour.fmFlexibleNoteOff), keepsVoiceWhenLetGo: asks(Behaviour.fmKeepsVoiceWhenLetGo),
                                                 surroundIsMoved: !asks(Behaviour.surroundIsNotMoved))
        }
        if instrumentMode {
            for index in 0 ..< header.instruments {
                file.instrument(index).MixPlug = UInt8(max(0, min(255, instrumentExtras[index].plugin)))
                let lock = instrumentExtras[index]
                if lock.pitchTempoLock > 0 || lock.pitchTempoLockFraction > 0 {
                    file.instrument(index).TempoLock = UInt32(max(0, min(1000, lock.pitchTempoLock))) * UInt32(OpenMPTSong.tempoUnit)
                        + UInt32(max(0, min(OpenMPTSong.tempoUnit - 1, lock.pitchTempoLockFraction)))
                }
            }
        }
        let instrumentPlugIns = instrumentMode ? (0 ..< header.instruments).map { instrumentExtras[$0].plugin } : []
        let heard = sound.adLib != nil || sound.sendsToPlugIns(instruments: instrumentPlugIns)

        // The version that last saved it, as OpenMPT writes one: 1.28.05, each part in base sixteen.
        var madeWith = "OpenMPT"
        if song.savedWith != 0 {
            func part(_ value: Int) -> String {
                let digits = Array("0123456789ABCDEF".utf8)
                return String(decoding: [digits[(value >> 4) & 15], digits[value & 15]], as: UTF8.self)
            }
            madeWith += " \((song.savedWith >> 24) & 0x7F)." + part(song.savedWith >> 16) + "." + part(song.savedWith >> 8)
        }
        var ways = file.modPlug
        if song.found {
            ways = IT2Module.ModPlugWays(asked: song.behaviours ?? [], savedWith: song.savedWith, wideRange: file.Flags & ITF_MPT_EXT_FILTER_RANGE != 0)
            ways.oldFilterSwing = asks(Behaviour.oldSwing)
        }
        let module = IT2Module(openMPT: openMPT, sound: heard ? sound : nil, file: file, madeWith: madeWith, orders: orders, mixVolume: UInt8(min(preAmp, 128)),
                               speed: openMPT.sequences[0].speed, tempo: UInt8(min(255, openMPT.sequences[0].tempo / OpenMPTSong.tempoUnit)),
                               channelPans: pans, channelVolumes: volumes, patterns: packed, rows: rowCounts,
                               ways: ways)
        return ITRenderer(module: module, format: "MPTM", shortfalls: shortfalls, options: options)
    }

    /// Set by measure, so that these files are about as loud as IT files are: played as loud as
    /// OpenMPT plays them, the middle one of them is three decibels louder than the middle IT file.
    private static let loudness: Float = 0.7
}
