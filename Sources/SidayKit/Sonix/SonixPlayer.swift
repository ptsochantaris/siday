// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Made after the 68000 code of Mark Riley's Sonix Music Driver (1987-91), as Wanted Team adapted it for
// EaglePlayer ("Sonix Music Driver player module V2.0 (9 June 2004)", carried by UADE as
// players/SonixMusicDriver, whose source UADE also carries as amigasrc/players/wanted_team/
// SonixMusicDriver/src/Sonix Music Driver_AMP.asm). That player carries three of Mark Riley's: version
// 2.3c (from Dynamix's Rise of the Dragon) for SNX, 2.0b (Melbourne House's Magic Johnson's Basketball)
// for TINY and 2.0f (Synergistic's Vengeance of Excalibur) for SMUS. The labels given are that source's.

/// The Sonix Music Driver, Mark Riley's player of the music Aegis Sonix made, which games of 1987 to
/// 1991 used (as UnExoticA has them, Spirit of Excalibur, It Came from the Desert, Rocket Ranger, the
/// Carmen Sandiego games, Stellar 7, A-10 Tank Killer and others): a score of four tracks, each a list of
/// notes and rests and commands, and its instruments in files of their own, beside it in a folder
/// named Instruments. A score is one of three kinds: SMUS, the IFF Simple Music Score as Sonix saved
/// it (with an SNX1 chunk, and its instruments named in INS1 chunks); TINY, a game's own short form
/// (its instruments named in four letters each); and SNX, the driver's own (its instruments named
/// after its tracks).
///
/// An instrument (`NAME.instr`) is synthesised, a waveform of 128 bytes passed through 64 filters as it
/// is loaded, played through one of them as an envelope and a vibrato move it, its phase and its
/// pitch slid; or sampled, its sound in a file of its own (`NAME.ss`) in octaves; or an IFF 8SVX
/// sample, or (for SNX) an AIFF one.
///
/// This is the players themselves, as Wanted Team's EaglePlayer module runs them: what they tell
/// Paula is what that module tells her, tick by tick. Each sets its own timer: SNX's from its tempo (a
/// tick of the score every time the timer runs out), TINY's and SMUS's from a table of 128 tempos, in
/// which a score's tick is one to fifteen of the timer's. It owns the memory Paula plays from, as the
/// Amiga's is: the score, the instruments' files as they were loaded, the samples, the filtered
/// waveforms, the players' own variables, and the buffers a synthesised instrument's waveform is
/// written into as it plays; places the players keep as the Amiga's addresses are places in it.
///
/// Where a player would stop the machine (by dividing by nought), or read or write on through memory
/// for ever or near it, it is done as said where it is done; what it reads past what it has is nought,
/// and its sums and products wrap round, as the 68000's do.
struct SonixPlayer: ~Copyable {
    /// Which of the three kinds a score is, and so which of the players plays it.
    enum Kind {
        case smus, tiny, snx

        /// As Wanted Team's player names them (its prefixes, `Prefix1` to `Prefix3`).
        var name: String {
            switch self {
            case .smus: "SMUS"
            case .tiny: "TINY"
            case .snx: "SNX"
            }
        }

        var playerVersion: String {
            switch self {
            case .smus: "2.0f"
            case .tiny: "2.0b"
            case .snx: "2.3c"
            }
        }
    }

    let kind: Kind
    /// Everything the players have, as Paula reads it (see `moduleAt`).
    let memory: UnsafeMutablePointer<UInt8>
    let memoryCapacity: Int
    /// Where a voice with nothing to play is pointed: the room after all the player has, which it
    /// never writes into.
    let silenceAt: Int
    /// Unused here, but kept as `PaulaTickRenderer` wants it: past room that no voice reads into.
    var mixingAt: Int { silenceAt &+ 0x20000 }
    static let mixingSpace = 2048

    /// Where things are in `memory`: the score (`moduleAt`), the players' variables (`Sonix`, the 1336
    /// bytes of `Buffer` and the 132 of `Buffer2` after them, the score as SMUS and SNX keep it), and
    /// the chip memory of `Chip` (1024 bytes, four voices' two buffers of 128 for their waveforms) and
    /// `Empty` (8 bytes of nought, a sample's loop when it has none).
    let moduleAt: UInt32
    let sonixAt: UInt32
    let chipAt: UInt32
    var scoreAt: UInt32 { sonixAt &+ 1336 }
    /// What `memory` holds once the instruments are installed (everything below `silenceAt`), for the
    /// song to be started again from.
    private var image: [UInt8] = []

    let title: String
    /// The instruments the score names that are not played: not among those given, or (for a
    /// sampled one) its sound not among them, or not of a kind the player takes. The player itself
    /// would refuse the score (`EPR_ErrorExtLoad`, `EPR_CorruptModule`); here it is played without
    /// them, its notes for them silent, as notes for an instrument it has not are.
    private(set) var missingInstruments: [String]
    /// Where each instrument played was loaded in `memory`, its file and its sample's.
    let places: [Place]

    struct Place {
        var name: String
        var file: Int, size: Int
        var sound: Int?, soundSize: Int
    }
    /// How many instruments are played (for `tuneInfo`), and of them how many are synthesised.
    let instrumentCount: Int
    let synthesisedCount: Int

    var songCount: Int { 1 }
    var song: Int { 0 }
    private(set) var endings = 0
    var stops: Int { 0 }
    private(set) var lengthClocks: UInt64?

    /// The CIA's timer: what the player last set it to (`dtg_Timer`), and what the tick now running
    /// counts down from, the value it held when the tick began (a value set while the timer runs is
    /// taken up when it next runs out, as UADE's cia.c has it).
    var latch: UInt16 = 0x376B
    private var tickTimer: UInt16 = 0x376B
    /// The clock the SNX player divides by its tempo for its timer (`Clock`, `InitSound`): EaglePlayer's
    /// timer as UADE first sets it ($376B, score.s's `cia_timer_base_value`) times 125.
    static let clock: UInt32 = 0x376B &* 125

    /// What Paula's registers were last given, by voice.
    private(set) var periods = InlineArray<4, UInt16>(repeating: 0)
    private(set) var volumes = InlineArray<4, UInt16>(repeating: 0)
    private var locations = InlineArray<4, UInt32>(repeating: 0)
    private var lengths = InlineArray<4, UInt16>(repeating: 0)
    /// What the player told Paula in the tick, in order, to be told on to `TFMXOutput`.
    private(set) var pokes = InlineArray<64, Poke>(repeating: Poke())
    private(set) var pokeCount = 0

    struct Poke {
        /// DMA turned on or off, or a location or a length written (told on as both, as they then are).
        enum Kind: UInt8 { case on, off, location, length }
        var kind = Kind.on
        var voice: UInt8 = 0
        var location: UInt32 = 0
        var length: UInt16 = 0
    }

    /// A song that has not come to its end in an hour is taken never to.
    private static let mostClocks: UInt64 = 3600 &* 3_546_895

    // MARK: - Memory, as the 68000 reads and writes it

    @inline(__always) func byte(_ a: UInt32) -> UInt8 {
        let i = Int(a & 0xFF_FFFF)
        return i < memoryCapacity ? memory[i] : 0
    }

    @inline(__always) func word(_ a: UInt32) -> UInt16 { UInt16(byte(a)) << 8 | UInt16(byte(a &+ 1)) }
    @inline(__always) func long(_ a: UInt32) -> UInt32 { UInt32(word(a)) << 16 | UInt32(word(a &+ 2)) }
    @inline(__always) func signedByte(_ a: UInt32) -> Int16 { Int16(Int8(bitPattern: byte(a))) }

    /// Writes go anywhere below the silence (which is never written, that it stays silent).
    @inline(__always) func setByte(_ a: UInt32, _ v: UInt8) {
        let i = Int(a & 0xFF_FFFF)
        if i < silenceAt { memory[i] = v }
    }

    @inline(__always) func setWord(_ a: UInt32, _ v: UInt16) {
        setByte(a, UInt8(v >> 8))
        setByte(a &+ 1, UInt8(truncatingIfNeeded: v))
    }

    @inline(__always) func setLong(_ a: UInt32, _ v: UInt32) {
        setWord(a, UInt16(v >> 16))
        setWord(a &+ 2, UInt16(truncatingIfNeeded: v))
    }

    /// The player's variables, by their offsets from `Sonix` (A6 in the players).
    @inline(__always) func sByte(_ o: UInt32) -> UInt8 { byte(sonixAt &+ o) }
    @inline(__always) func sWord(_ o: UInt32) -> UInt16 { word(sonixAt &+ o) }
    @inline(__always) func sLong(_ o: UInt32) -> UInt32 { long(sonixAt &+ o) }
    @inline(__always) func setS(_ o: UInt32, byte v: UInt8) { setByte(sonixAt &+ o, v) }
    @inline(__always) func setS(_ o: UInt32, word v: UInt16) { setWord(sonixAt &+ o, v) }
    @inline(__always) func setS(_ o: UInt32, long v: UInt32) { setLong(sonixAt &+ o, v) }

    // MARK: - Paula, as the player tells her (EaglePlayer's amplifier, `PokeAdr` to `PokeDMA`)

    private mutating func log(_ poke: Poke) {
        guard pokeCount < 64 else { return }
        pokes[pokeCount] = poke
        pokeCount &+= 1
    }

    mutating func pokeAddress(_ v: Int, _ address: UInt32) {
        guard v >= 0 && v < 4 else { return }
        locations[v] = address & 0xFF_FFFF
        log(Poke(kind: .location, voice: UInt8(v), location: locations[v], length: lengths[v]))
    }

    mutating func pokeLength(_ v: Int, _ length: UInt16) {
        guard v >= 0 && v < 4 else { return }
        lengths[v] = length
        log(Poke(kind: .length, voice: UInt8(v), location: locations[v], length: length))
    }

    mutating func pokePeriod(_ v: Int, _ period: UInt16) {
        if v >= 0 && v < 4 { periods[v] = period }
    }

    mutating func pokeVolume(_ v: Int, _ volume: UInt16) {
        if v >= 0 && v < 4 { volumes[v] = volume }
    }

    /// DMACON, as `PokeDMA` gives it to `ENPP_DMAMask`: the four low bits, turned on with bit 15 set
    /// and off without.
    mutating func pokeDMA(_ mask: UInt16) {
        for v in 0 ..< 4 where mask & 1 << UInt16(v) != 0 {
            log(Poke(kind: mask & 0x8000 != 0 ? .on : .off, voice: UInt8(v)))
        }
    }

    // MARK: - Loading

    /// True for a file the player's check takes (`Check5`): an SNX, TINY or Sonix SMUS score.
    static func isOne(_ data: [UInt8]) -> Bool { (try? check(data)) != nil }

    /// Reads the score and its instruments, which are every file of the Instruments folder beside it,
    /// by the file's name as found (`SNARE2_R8.instr`, `Keyboard .instr`, `AThorns.ss`): each named
    /// instrument is looked for as the player does, as `NAME.instr` and, for a sampled one, the `.ss`
    /// its file names, without regard to case, and with a `.` in a name also matching a `_` in a file's
    /// (as UnExoticA has renamed them). An instrument not found is played without (see
    /// `missingInstruments`); a score with none found is refused.
    init(_ data: [UInt8], instruments: [(name: String, bytes: [UInt8])], song: Int = 0) throws(TuneError) {
        var refusal: TuneError?
        var kind = Kind.snx
        do throws(TuneError) {
            kind = try Self.check(data)
        } catch {
            refusal = error
        }
        self.kind = kind

        // The instruments the score names, in the order the player loads them (`ExtLoad`).
        var files = [String: [UInt8]]()
        for file in instruments { files[Self.lookupKey(file.name)] = file.bytes }
        func find(_ name: [UInt8], _ suffix: String) -> [UInt8]? {
            files[Self.lookupKey(Self.latin1(name) + suffix)]
        }
        let named = refusal == nil ? Self.instrumentNames(data, kind) : []
        if refusal == nil, named.isEmpty || named.count > 64 {
            // (`InitPlayer`: no more than 64 files, and at least one.)
            refusal = .malformed(named.isEmpty ? "it names no instruments" : "it names more than 64 instruments")
        }
        var missing: [String] = []
        var slots: [Slot] = []
        for name in named where refusal == nil {
            var slot = Slot(name: name)
            if let bytes = find(name.name, ".instr") {
                slot.instrument = Self.instrumentKind(bytes, kind)
                slot.bytes = bytes
                switch slot.instrument {
                case let .sampled(sound), let .tinySampled(sound):
                    if let ss = find(sound, ".ss"), ss.count >= 70 {
                        slot.sound = ss
                    } else {
                        missing.append(Self.latin1(sound) + ".ss")
                        slot.instrument = nil
                    }
                case .none: missing.append(Self.latin1(name.name) + ".instr")
                default: break
                }
            } else {
                missing.append(Self.latin1(name.name) + ".instr")
            }
            slots.append(slot)
        }
        if refusal == nil, !slots.isEmpty, slots.allSatisfy({ $0.instrument == nil }) {
            refusal = .missingCompanion("Its instruments, which are kept in an Instruments folder beside it, were not given with it.")
        }
        missingInstruments = missing
        instrumentCount = slots.count { $0.instrument != nil }
        synthesisedCount = slots.count { $0.instrument?.isSynthesised == true }

        // Where everything goes (see `moduleAt`): a little room first, that a pointer of nought points at
        // noughts, as the players take it.
        func aligned(_ n: Int) -> Int { (n &+ 15) & ~15 }
        var at = 0x400
        let moduleAt = at
        at &+= aligned(data.count &+ 4)
        for i in slots.indices where slots[i].instrument != nil {
            slots[i].at = at
            at &+= aligned(slots[i].bytes.count)
        }
        // The samples, each read into the chip memory `InitPlayer` takes for them, an even number of
        // bytes; then what it takes of other memory: 8192 bytes of filtered waveforms for each
        // synthesised instrument, 62 for an 8SVX one and 44 for an AIFF one.
        for i in slots.indices where slots[i].sound != nil {
            slots[i].soundAt = at
            at &+= (slots[i].sound!.count &+ 1) & ~1
        }
        at = aligned(at)
        for i in slots.indices {
            switch slots[i].instrument {
            case .synthesised, .tinySynthesised:
                slots[i].extraAt = at
                at &+= 8192
            case .iff:
                slots[i].extraAt = at
                at &+= 62
            case .aiff:
                slots[i].extraAt = at
                at &+= 44
            default: break
            }
        }
        at = aligned(at)
        let sonixAt = at
        at &+= aligned(1336 &+ 132)
        let chipAt = at
        at &+= aligned(1032)
        silenceAt = at
        memoryCapacity = at &+ 0x20000 &+ Self.mixingSpace
        memory = .allocate(capacity: memoryCapacity)
        memory.initialize(repeating: 0, count: memoryCapacity)
        for (i, b) in data.enumerated() { memory[moduleAt &+ i] = b }
        for slot in slots where slot.instrument != nil {
            for (i, b) in slot.bytes.enumerated() { memory[slot.at &+ i] = b }
            if let sound = slot.sound, let soundAt = slot.soundAt {
                for (i, b) in sound.enumerated() { memory[soundAt &+ i] = b }
            }
        }
        places = slots.compactMap { slot in
            slot.instrument == nil ? nil : Place(name: Self.latin1(slot.name.name), file: slot.at, size: slot.bytes.count,
                                                 sound: slot.soundAt, soundSize: slot.sound?.count ?? 0)
        }
        self.moduleAt = UInt32(moduleAt)
        self.sonixAt = UInt32(sonixAt)
        self.chipAt = UInt32(chipAt)
        title = refusal == nil ? Self.songName(data, kind) : ""

        if refusal == nil { refusal = install(slots, size: data.count) }
        image = Array(UnsafeBufferPointer(start: memory, count: silenceAt))
        if let refusal { throw refusal }
        begin()
    }

    deinit { memory.deallocate() }

    /// A file's name as it is looked up: in lower case, with `.` as `_`.
    static func lookupKey(_ name: String) -> String {
        var key = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if scalar == "." {
                key.append("_")
            } else if scalar.value >= 0x41, scalar.value <= 0x5A {
                key.append(Unicode.Scalar(scalar.value &+ 0x20)!)
            } else {
                key.append(scalar)
            }
        }
        return String(key)
    }

    /// Bytes of a name as the characters they are on the Amiga (Latin-1).
    static func latin1(_ bytes: [UInt8]) -> String {
        var s = String.UnicodeScalarView()
        for b in bytes { s.append(Unicode.Scalar(b)) }
        return String(s)
    }

    /// An instrument the score names: its name, and for TINY its place among the 64; SMUS's register.
    struct Name {
        var name: [UInt8]
        var index = 0
    }

    /// The file's bytes, read as the 68000 reads them, at any place (as 64 bits, that a place a long
    /// gives does not overflow where `Int` has 32): nought past the end.
    struct Bytes {
        let data: [UInt8]
        var count: Int64 { Int64(data.count) }
        func at(_ i: Int64) -> UInt8 { i >= 0 && i < count ? data[Int(i)] : 0 }
        func word(_ i: Int64) -> UInt16 { UInt16(at(i)) << 8 | UInt16(at(i &+ 1)) }
        func long(_ i: Int64) -> UInt32 { UInt32(word(i)) << 16 | UInt32(word(i &+ 2)) }
    }

    /// What `ExtLoad` loads: the names after SNX's tracks, each ended by a nought until an empty one;
    /// TINY's 64 names of four letters at 64, those not nought; SMUS's in its INS1 chunks, after the
    /// four bytes of the chunk's register and type, up to the chunk's end or a nought.
    static func instrumentNames(_ data: [UInt8], _ kind: Kind) -> [Name] {
        let d = Bytes(data: data)
        var names: [Name] = []
        switch kind {
        case .snx:
            var a: Int64 = 20
            for t in 0 ..< Int64(4) { a &+= Int64(d.long(4 &* t)) }
            repeat {
                var name: [UInt8] = []
                while a < d.count, d.at(a) != 0, name.count < 256 {
                    name.append(d.at(a))
                    a &+= 1
                }
                a &+= 1
                names.append(Name(name: name))
            } while a < d.count && d.at(a) != 0 && names.count <= 64
        case .tiny:
            for i in 0 ..< 64 where d.long(64 &+ 4 &* Int64(i)) != 0 {
                var name: [UInt8] = []
                for k in 0 ..< Int64(4) {
                    let b = d.at(64 &+ 4 &* Int64(i) &+ k)
                    if b == 0 { break }
                    name.append(b)
                }
                names.append(Name(name: name, index: i))
            }
        case .smus:
            var a = smusInstrumentsAt(data) ?? d.count
            while a &+ 8 <= d.count, d.long(a) == 0x494E_5331, names.count <= 64 {
                let size = (Int64(d.long(a &+ 4)) &+ 1) & ~1
                let end = min(d.count, a &+ 8 &+ size)
                var name: [UInt8] = []
                var i = a &+ 12
                while i < end, d.at(i) != 0 {
                    name.append(d.at(i))
                    i &+= 1
                }
                names.append(Name(name: name, index: Int(d.at(a &+ 8))))
                a &+= 8 &+ size
                guard a &+ 4 <= d.count, d.long(a) != 0x5452_414B else { break }
            }
        }
        return names
    }

    /// Where a Sonix SMUS's INS1 chunks begin: after its NAME and SNX1 chunks, at 24.
    static func smusInstrumentsAt(_ data: [UInt8]) -> Int64? {
        let d = Bytes(data: data)
        var a: Int64 = 24
        for _ in 0 ..< 2 { a &+= 8 &+ ((Int64(d.long(a &+ 4)) &+ 1) & ~1) }
        return a < d.count ? a : nil
    }

    /// The song's name: SMUS's NAME chunk (`InitPlayer`, `SongName`); the others have none.
    static func songName(_ data: [UInt8], _ kind: Kind) -> String {
        let d = Bytes(data: data)
        guard kind == .smus else { return "" }
        let size = Int64(d.long(28))
        var name = String.UnicodeScalarView()
        var i: Int64 = 32
        while i < min(d.count, 32 &+ min(size, 256)) {
            let b = d.at(i)
            if b == 0 { break }
            name.append(Unicode.Scalar(b >= 0x20 && b != 0x7F ? b : 0x20))
            i &+= 1
        }
        return String(name).trimmed()
    }

    /// The player's check (`Check5`), saying which kind a score is, or why it is none.
    static func check(_ data: [UInt8]) throws(TuneError) -> Kind {
        let d = Bytes(data: data)
        let size = d.count
        let notOne = TuneError.unsupported("not a Sonix Music Driver score")
        if d.long(0) == 0x464F_524D {
            // SmusCheck: an IFF SMUS whose chunks after its header are NAME, SNX1 and one or more INS1
            // (of a register below 64 and no MIDI) before its first TRAK, as Sonix saves it. (Its compare of
            // the header's SHDR is not acted on.) An IFF SMUS of any other program is not Sonix's.
            guard d.long(8) == 0x534D_5553 else { throw notOne }
            let notSonix = TuneError.unsupported("an IFF SMUS score not saved by Aegis Sonix, which the Sonix Music Driver does not play")
            guard d.at(23) != 0, d.long(24) == 0x4E41_4D45, d.long(28) & 0x8000_0000 == 0 else { throw notSonix }
            var a = 32 &+ ((Int64(d.long(28)) &+ 1) & ~1)
            guard d.long(a) == 0x534E_5831, d.long(a &+ 4) & 0x8000_0000 == 0 else { throw notSonix }
            a &+= 8 &+ ((Int64(d.long(a &+ 4)) &+ 1) & ~1)
            var count = 0
            repeat {
                guard a < size, d.long(a) == 0x494E_5331, d.long(a &+ 4) & 0x8000_0000 == 0 else { throw notSonix }
                let chunk = (Int64(d.long(a &+ 4)) &+ 1) & ~1
                guard d.at(a &+ 8) <= 63, d.at(a &+ 9) == 0 else { throw notSonix }
                count &+= 1
                // (Its table of registers has room for 64.)
                guard count <= 64 else { throw TuneError.malformed("it names more than 64 instruments") }
                a &+= 8 &+ chunk
            } while d.long(a) != 0x5452_414B
            return .smus
        }
        if d.word(0) & 0x00F0 != 0 {
            // TinyCheck: more than 332 bytes; the first track at $140 and three more after it, each
            // inside the file, even, and either empty ($FFFF) or begun with six bytes of nought and a
            // command of $80 to $82.
            guard size > 332, d.long(48) == 0x140 else { throw notOne }
            for t in 0 ..< Int64(3) {
                let offset = d.long(52 &+ 4 &* t)
                guard offset != 0, offset & 0x8000_0000 == 0, offset & 1 == 0, Int64(offset) < size else { throw notOne }
                let track = Int64(offset)
                if d.word(track) != 0xFFFF {
                    guard d.long(track) == 0, d.word(track &+ 4) == 0, d.at(track &+ 6) & 0x80 != 0, d.at(track &+ 6) <= 0x82 else {
                        throw notOne
                    }
                }
            }
            return .tiny
        }
        // SNX: four tracks, their lengths even and more than nought, ending before the file does; each
        // begun with a command (of $80 to $84) or empty; and an instrument named after them.
        var end: UInt32 = 20
        for t in 0 ..< Int64(4) {
            let length = d.long(4 &* t)
            guard length != 0, length & 0x8000_0000 == 0, length & 1 == 0 else { throw notOne }
            end &+= length
        }
        guard Int64(Int32(bitPattern: end)) < size else { throw notOne }
        var a: UInt32 = 20
        for t in 0 ..< Int64(4) {
            guard d.at(Int64(a)) & 0x80 != 0 else { throw notOne }
            if d.word(Int64(a)) != 0xFFFF { guard d.at(Int64(a)) <= 0x84 else { throw notOne } }
            a &+= d.long(4 &* t)
        }
        guard d.at(Int64(a)) != 0 else { throw notOne }
        return .snx
    }
}

// MARK: - Instruments

extension SonixPlayer {
    /// One of the instruments the score names, as it is loaded and installed.
    struct Slot {
        var name: Name
        var instrument: Instrument?
        var bytes: [UInt8] = []
        var sound: [UInt8]?
        var at = 0
        var soundAt: Int?
        var extraAt = 0
    }

    /// An instrument's file, as `InitPlayer` takes it (its first pass, from `NextFile`).
    enum Instrument: Equatable {
        /// SNX's and SMUS's: synthesised (502 bytes, "Synthesis" or nought first); sampled (128 bytes,
        /// "SampledSound", naming its .ss at 68); IFF 8SVX; AIFF (SNX's only, a FORM or a LIST of them).
        case synthesised, sampled([UInt8]), iff, aiff
        /// TINY's, by its first long: 1, synthesised (442 bytes); 2, sampled (32 bytes, naming its .ss in
        /// the four letters at 4); 3, an 8SVX of its own.
        case tinySynthesised, tinySampled([UInt8]), tinyIFF

        var isSynthesised: Bool { self == .synthesised || self == .tinySynthesised }
    }

    /// What kind an instrument's file is, or nil for one the player would take the score to be corrupt
    /// for (`EPR_CorruptModule`) or in error (`EPR_ErrorInFile`, a TINY sample of no name).
    static func instrumentKind(_ d: [UInt8], _ kind: Kind) -> Instrument? {
        func at(_ i: Int) -> UInt8 { i >= 0 && i < d.count ? d[i] : 0 }
        func long(_ i: Int) -> UInt32 { UInt32(at(i)) << 24 | UInt32(at(i &+ 1)) << 16 | UInt32(at(i &+ 2)) << 8 | UInt32(at(i &+ 3)) }
        func zeroEnded(_ from: Int, most: Int) -> [UInt8] {
            var name: [UInt8] = []
            var i = from
            while i < d.count, d[i] != 0, name.count < most {
                name.append(d[i])
                i &+= 1
            }
            return name
        }
        if kind == .tiny {
            switch long(0) {
            case 1: return d.count == 442 ? .tinySynthesised : nil
            case 2:
                guard d.count == 32, long(4) != 0 else { return nil }
                return .tinySampled(zeroEnded(4, most: 4))
            case 3: return .tinyIFF
            default: return nil
            }
        }
        if at(0) == 0 { return d.count == 502 ? .synthesised : nil }
        if long(0) == 0x5361_6D70 {
            guard long(4) == 0x6C65_6453, long(8) == 0x6F75_6E64, d.count == 128 else { return nil }
            return .sampled(zeroEnded(68, most: 60))
        }
        if long(0) == 0x5379_6E74 {
            guard long(4) == 0x6865_7369, at(8) == 0x73, at(9) == 0, d.count == 502 else { return nil }
            return .synthesised
        }
        var aiff = false
        if long(0) == 0x464F_524D {
            if long(8) == 0x4149_4646 {
                aiff = true
            } else {
                guard long(8) == 0x3853_5658, long(12) == 0x5648_4452 else { return nil }
            }
        } else {
            guard long(0) == 0x4C49_5354 else { return nil }
            aiff = true
        }
        // (The SMUS player takes no AIFF.)
        if aiff, kind == .smus { return nil }
        guard UInt64(d.count) == 8 &+ UInt64(long(4)) else { return nil }
        return aiff ? .aiff : .iff
    }

    /// `InitPlayer`'s second pass, from `NextFile2`, and the score set up: each instrument installed in
    /// the player's table (SNX's at $8A, SMUS's at $4A by its register, TINY's in the score's own 64,
    /// whose names become pointers to the instruments' files), a synthesised one's waveform filtered,
    /// an 8SVX's and an AIFF's header read; then SMUS's score read into `Buffer2` (`LoadSCORE`) and
    /// SNX's set out there (`InitScore`). Returns why the score is refused, if it is.
    private mutating func install(_ slots: [Slot], size: Int) -> TuneError? {
        let s = sonixAt
        switch kind {
        case .smus:
            // ($29A: the chip memory; $1CA: the voice last given a note; 0 the volume, 2 the tempo and 4
            // the pitch.)
            setS(0x29A, long: chipAt)
            setS(0x1CA, word: 0x3F)
            setS(0, word: 0xFF)
            setS(2, long: 0x0080_0080)
            // (The FORM's size must be within the file: `EPR_ModuleTooShort`.)
            guard UInt64(long(moduleAt &+ 4)) &+ 8 <= UInt64(size) else { return .malformed("it is cut short") }
        case .tiny:
            setS(0x106, long: chipAt)
            setS(0x22, word: 0x8000)
            setS(0x36, word: 0x3F)
            // (The last track's end must be within the file.)
            let track = long(moduleAt &+ 60)
            var a = moduleAt &+ track
            let end = moduleAt &+ UInt32(size & ~1)
            var found = false
            while a < end {
                if word(a) == 0xFFFF {
                    found = true
                    break
                }
                a &+= 2
            }
            guard found else { return .malformed("it is cut short") }
        case .snx:
            setS(0, long: 0x0078_0080)
            setS(0x3E2, long: chipAt)
            initScore()
        }
        if kind == .smus { loadScore(size: size) }
        for (index, slot) in slots.enumerated() {
            guard let instrument = slot.instrument else {
                // (An instrument not found leaves its place empty; TINY's name is taken out, that the
                // score does not take it for a pointer.)
                if kind == .tiny { setLong(moduleAt &+ 64 &+ 4 &* UInt32(slot.name.index), 0) }
                continue
            }
            let file = UInt32(slot.at)
            switch kind {
            case .tiny:
                // `NoTin` aside: the name becomes the file's place; the file's first long its "tech"
                // (`INITINSTRUMENT`), and its second where its filtered waveforms or its sample are.
                setLong(moduleAt &+ 64 &+ 4 &* UInt32(slot.name.index), file)
                switch instrument {
                case .tinySynthesised:
                    let filters = UInt32(slot.extraAt)
                    setByte(filters, 0x80)
                    setLong(file, Tech.synthesised.rawValue)
                    setLong(file &+ 4, filters)
                    // (`SETFILTER`, as the first byte of the filters' memory is $80.)
                    filter(wave: file &+ 8, into: filters)
                case .tinySampled:
                    setLong(file, Tech.sampled.rawValue)
                    setLong(file &+ 4, UInt32(slot.soundAt ?? 0))
                default:
                    setLong(file, Tech.iff.rawValue)
                }
            case .smus, .snx:
                // An entry of six bytes in the table: the instrument's place, and a count of its uses.
                let entry: UInt32
                if kind == .smus {
                    // `InstallToReal`: by its register, which is written, plus one, into the score's table
                    // of instruments at $40.
                    let register = UInt32(slot.name.index & 0x3F)
                    entry = s &+ 0x4A &+ 6 &* register
                    setByte(scoreAt &+ 0x40 &+ register, UInt8(register &+ 1))
                } else {
                    // By its place among the names, the number written into the score's table at $2A.
                    let number = UInt32(index)
                    entry = s &+ 0x8A &+ 6 &* number
                    setByte(scoreAt &+ 0x2A &+ number, UInt8(number &+ 1))
                }
                var info = file &+ 32
                switch instrument {
                case .sampled:
                    let sound = UInt32(slot.soundAt ?? 0)
                    setLong(info, Tech.sampled.rawValue)
                    // (The sample's use count, in its header.)
                    setWord(sound &+ 30, 1)
                    setLong(info &+ 68, sound)
                case .synthesised:
                    let filters = UInt32(slot.extraAt)
                    setLong(info, Tech.synthesised.rawValue)
                    setLong(info &- 4, filters)
                    filter(wave: info &+ 36, into: filters)
                case .iff:
                    info = UInt32(slot.extraAt)
                    installIFF(file, into: info, size: slot.bytes.count)
                    setLong(info, Tech.iff.rawValue)
                default:
                    // (One the player would take the score to be corrupt for is left out.)
                    info = UInt32(slot.extraAt)
                    guard installAIFF(file, into: info, size: slot.bytes.count) else {
                        missingInstruments.append(Self.latin1(slot.name.name) + ".instr")
                        setByte(scoreAt &+ 0x2A &+ UInt32(index), 0)
                        continue
                    }
                    setLong(info, Tech.aiff.rawValue)
                }
                setLong(entry, info)
                setWord(entry &+ 4, 1)
            }
        }
        return nil
    }

    /// What a player's "tech" is, the routines of an instrument of each kind: kept, where the player
    /// keeps the address of its code, as these.
    enum Tech: UInt32 {
        case synthesised = 0x00F0_0010, sampled = 0x00F0_0020, iff = 0x00F0_0030, aiff = 0x00F0_0040
    }

    /// `SetFilter` (and TINY's `SETFILTER`, the same): the waveform of 128 bytes at `wave` passed
    /// through each of the 64 filters of `SonixTables.filters`, one after another, each a resonant
    /// low-pass whose state carries on from the last; 8192 bytes, into `filters`.
    func filter(wave: UInt32, into filters: UInt32) {
        var out = filters
        var d3: UInt16 = 0
        var d4 = UInt16(bitPattern: signedByte(wave &+ 0x7F) &<< 7)
        for f in 0 ..< 64 {
            let d1full = SonixTables.filters[f]
            // The damping: (32768 less the filter's) times $E666, its upper word.
            let d2 = UInt16(truncatingIfNeeded: ((UInt32(0x8000 &- d1full) & 0xFFFF) &* 0xE666) >> 16)
            let d1 = d1full >> 1
            for i in 0 ..< 128 {
                var d6 = UInt16(bitPattern: signedByte(wave &+ UInt32(i)) &<< 7)
                d6 = d6 &- d4
                // MULS.W D1,D6; ASL.L #2,D6; SWAP D6.
                let product = Int32(Int16(bitPattern: d6)) &* Int32(Int16(bitPattern: d1))
                d6 = UInt16(truncatingIfNeeded: UInt32(bitPattern: product &<< 2) >> 16)
                d3 = d3 &+ d6
                d4 = d4 &+ d3
                // ROR.W #7: the byte written is bits 7 to 14.
                let rotated = d4 >> 7 | d4 << 9
                setByte(out, UInt8(truncatingIfNeeded: rotated))
                out &+= 1
                // MULS.W D2,D3; ASL.L #1,D3; SWAP D3.
                let damped = Int32(Int16(bitPattern: d3)) &* Int32(Int16(bitPattern: d2))
                d3 = UInt16(truncatingIfNeeded: UInt32(bitPattern: damped &<< 1) >> 16)
            }
        }
    }

    /// `InstallIFF`: an 8SVX instrument's header of 62 bytes, at `info`: its VHDR copied to $24, where
    /// its BODY's sound is at $3A, and at $38 how many times its lengths halve (while they halve evenly,
    /// its cycle is more than a sample, and with its octaves they make fewer than eight), by which the
    /// notes are moved down its octaves.
    private func installIFF(_ file: UInt32, into info: UInt32, size: Int) {
        for i in 0 ..< UInt32(20) { setByte(info &+ 0x24 &+ i, byte(file &+ 20 &+ i)) }
        // FindBody: the BODY chunk, looked for a word at a time from the VHDR's data on. (The player
        // would look on past the file for ever; here the end of the file is the end.)
        var a = file &+ 20
        let end = file &+ UInt32(size)
        while a &+ 4 <= end, long(a) != 0x424F_4459 { a &+= 2 }
        setLong(info &+ 0x3A, a &+ 8)
        var d2 = long(info &+ 0x24), d3 = long(info &+ 0x28), d4 = long(info &+ 0x2C)
        var d1: UInt16 = 0
        while true {
            d2 >>= 1
            d3 >>= 1
            d4 >>= 1
            d1 &+= 1
            if (d2 | d3) & 1 != 0 || d4 == 1 { break }
            let octaves = UInt8(truncatingIfNeeded: d1) &+ byte(info &+ 0x32)
            if Int8(bitPattern: octaves) >= 8 { break }
        }
        setWord(info &+ 0x38, d1)
    }
}

// MARK: - Playing

extension SonixPlayer {
    /// Starts the song (there is one), as a player newly loaded would; and finds how long it is.
    mutating func select(song _: Int) throws(TuneError) { begin() }

    private mutating func begin() {
        restart()
        var none = TFMXSilentOutput()
        var clocks: UInt64 = 0
        while endings == 0, clocks < Self.mostClocks {
            _ = run(&none)
            clocks &+= UInt64(fourVoiceTicks())
        }
        lengthClocks = endings > 0 ? clocks : nil
        restart()
    }

    /// The memory as it was once the instruments were installed, and the song started (`InitSound`).
    private mutating func restart() {
        image.withUnsafeBufferPointer { memory.update(from: $0.baseAddress!, count: $0.count) }
        periods = .init(repeating: 0)
        volumes = .init(repeating: 0)
        locations = .init(repeating: 0)
        lengths = .init(repeating: 0)
        pokeCount = 0
        endings = 0
        latch = 0x376B
        initSound()
        tickTimer = latch
    }

    /// `InitSound`: the score played from its start, for ever (`PlayScore` from nought to -1, D2 -1),
    /// at its volume at once; and the timer set as the score's tempo says.
    private mutating func initSound() {
        switch kind {
        case .snx:
            playSNXScore()
            // The tempo: the first track's first command's, if it is one ($82), or the score's.
            var tempo = UInt32(sWord(0))
            if byte(moduleAt &+ 20) == 0x82 { tempo = UInt32(byte(moduleAt &+ 21)) }
            latch = Self.divideClock(by: tempo) ?? latch
        case .tiny, .smus:
            playScore()
            // As the interrupt sets it (`lbC00D070`), from the tempo's entry in the table.
            if let timer = Self.scoreTimer(index: sWord(2) >> 1).timer { latch = timer }
        }
    }

    /// The SNX player's timer for a tempo: `Clock` over it, in a word; nil for nought, for which the
    /// 68000 would stop (here the timer is left as it was). A quotient too big for a word is not
    /// made, and leaves `Clock`'s lower word.
    static func divideClock(by tempo: UInt32) -> UInt16? {
        let divisor = tempo & 0xFFFF
        guard divisor != 0 else { return nil }
        let quotient = clock / divisor
        return UInt16(truncatingIfNeeded: quotient > 0xFFFF ? clock : quotient)
    }

    /// TINY's and SMUS's tempo (`lbC00D070`, `lbC0007F2`) from entry `index` of the table: how many
    /// of the player's ticks a score's tick is (its top four bits), the rate the envelopes go at (eight
    /// times the entry over those ticks), and the timer: 11,932 (the CIA's count for a sixtieth of a
    /// second on an NTSC Amiga) times the rate over 32,768. An entry past the table's 128 is the
    /// player's code that follows it, here nought, which it would divide by: nil.
    static func scoreTimer(index: UInt16) -> (ticks: UInt16, rate: UInt16, timer: UInt16?) {
        let entry = index < 128 ? SonixTables.tempos[Int(index)] : 0
        let ticks = entry >> 12
        guard ticks != 0 else { return (0, 0, nil) }
        let rate = UInt16(truncatingIfNeeded: (UInt32(entry) << 15) / UInt32(ticks << 12))
        let timer = UInt16(truncatingIfNeeded: (UInt32(rate) &* 0x2E9C) >> 15)
        return (ticks, rate, timer)
    }

    /// The player's interrupt (`Interrupt`), for a tick: its kind's player run, and what it told Paula
    /// told `output`, in order. Returns the tick's length in milliseconds (unused).
    mutating func run<Output: TFMXOutput>(_ output: inout Output) -> Int {
        tickTimer = latch
        pokeCount = 0
        switch kind {
        case .snx: playSNX()
        case .tiny, .smus: playScoreTick()
        }
        for i in 0 ..< pokeCount {
            let poke = pokes[i]
            let v = Int(poke.voice)
            switch poke.kind {
            case .on: output.on(v)
            case .off: output.off(v)
            case .location, .length: output.takeNextBuffer(v, start: Int(poke.location), length: poke.length)
            }
        }
        return 20
    }

    /// `SongEnd`: EaglePlayer told the song has come to its end.
    mutating func songEnded() { endings &+= 1 }

    /// The length of the tick now running, in Paula's clocks: the CIA's timer counts down at a fifth of
    /// her clock, and takes one more count than it is set to to come round.
    func fourVoiceTicks() -> Int { (Int(tickTimer) &+ 1) &* 5 }

    /// Paula's period for the voice, as the player last set it.
    func period(_ voice: Int) -> UInt16 { periods[voice] }
    /// Paula's volume for the voice, as she takes what the player last gave her: seven bits, 64 or
    /// more being full.
    func volume(_ voice: Int) -> UInt16 { min(64, volumes[voice] & 0x7F) }
    /// What the player last gave Paula's volume register for the voice.
    func volumeWritten(_ voice: Int) -> UInt16 { volumes[voice] }
}

/// The Sonix Music Driver, played on Paula by `PaulaTickRenderer`.
extension SonixPlayer: PaulaTickPlayer {
    var sevenVoiceStyle: TFMXSevenVoices.Style? { nil }
    var sevenVoiceTempo: Int { 0 }

    var tuneInfo: TuneInfo {
        var info = TuneInfo(format: "Sonix Music Driver (\(kind.name))")
        info.title = title
        let plural = instrumentCount == 1 ? "" : "s"
        info.detail = "Mark Riley's Sonix Music Driver \(kind.playerVersion); \(instrumentCount) instrument\(plural), \(synthesisedCount) synthesised"
        return info
    }

    var gain: Float { 0.46 }

    mutating func prepareToBeHeard() {}

    func fourVoiceTick(_: inout TFMXTiming) -> Int { fourVoiceTicks() }
}
