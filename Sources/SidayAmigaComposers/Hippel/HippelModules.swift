// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's reading of Jochen Hippel's modules and of Future Composer's
// (src/Jochen/HippelDecoder.cpp's init, TFMX.cpp, COSO.cpp, TFMX7V.cpp, ModPack.cpp, MCMD.cpp, FC.cpp,
// SMOD.cpp, TraitsByChecksum.cpp and LiveFix.h, and src/CRCLight.cpp), Copyright (C) Michael Schwendt,
// used under the GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

import SidayChips
import SidayFoundation

// Jochen Hippel's TFMX (not Chris Hülsbeck's, which shares its name) is a header of counts, then the
// sound modulation sequences (a voice's waves, transposes and wave modulation), the volume modulation
// sequences (the instruments: an envelope, and the sound sequence and vibrato to play), the patterns
// (a note and its instrument, two bytes, on each row), the track table (each step a pattern for each
// voice, its transpose and its instruments' transpose), the songs (each a first and last step and a
// speed), and the samples. Its compressed form (COSO, from 1989) leaves out what patterns and
// sequences do not use, finding them by tables of places instead; TFMX 7V has seven voices (four of
// them mixed onto Paula's fourth by its player) and longer steps. Future Composer (1988 to 1990) was
// a tracker made from Hippel's player, with a module of its own, and MCMD is another made from it.

extension HippelDecoder {
    /// Reads the module, `file`, into the memory and starts song `song`: the library's `init` with a
    /// new decoder, which includes its playing the song through once to find how long it is (in which
    /// it learns a little more of which player the module wants).
    mutating func setUp(_ file: [UInt8], song songNumber: Int) throws(TuneError) {
        guard let probe = Self.probe(file), probe.header != 0xFFFF_FFFF else {
            throw .malformed("not a module of Jochen Hippel's players or Future Composer")
        }
        offsets.header = probe.header
        format = probe.format
        initKind = probe.kind
        sndModFuncs = [.e0, .e1, .e2, .e3, .e4, .e5, .e6, .e7, .e8, .e9, .eaSkip]

        for i in 0 ..< file.count { memory[i] = file[i] }
        length = file.count
        size = length + Self.silenceData.count
        // The silent sequences after the module, so that the same reading of the memory finds them.
        offsets.silence = UInt32(length)
        for i in 0 ..< Self.silenceData.count { memory[length + i] = Self.silenceData[i] }
        // A short silent sample, for samples whose places are outside the module.
        silentSample = Sample(startOffs: 0, repOffs: 0, len: 1, repLen: 1, pStart: length + 1)
        for s in 0 ..< 256 { samples[s] = silentSample }

        var silent = TFMXSilentOutput()
        switch initKind {
        case .smod: admin.initialized = smodInit(songNumber, &silent)
        case .fc14: admin.initialized = fcInit(songNumber, &silent)
        case .tfmx: admin.initialized = tfmxInit(songNumber, &silent)
        case .coso: admin.initialized = cosoInit(songNumber, &silent)
        case .mcmd: admin.initialized = mcmdInit(songNumber, &silent)
        }
        guard admin.initialized else { throw .malformed("a module of Jochen Hippel's players that cannot be played") }

        // The song is played through, up to 59 minutes, to find how long it is.
        duration = 0
        let loopModeBefore = loopMode
        loopMode = false
        var four = TFMXTiming()
        lengthClocks = (0, 0)
        repeat {
            duration &+= UInt32(run(&silent))
            lengthClocks.four &+= UInt64(four.fourVoiceTick(rate: rate, timer: nil, fiftyIsTheFrame: initKind == .coso))
            lengthClocks.seven &+= UInt64(TFMXSevenVoices.Style.hippel.tickClocks(tempo: sevenVoiceTempo))
        } while !songEnd && duration < 1000 * 60 * 59
        loopMode = loopModeBefore

        // What that showed of the player.
        if usesE7SetDiffWave() { sndModFuncs[7] = .e7SetDiffWave }
        if analyze.negVibSpeed { traits.vibSpeedFlag = true }
        if Analyze.has(analyze.sndSeqs, 0x80) { traits.volSeqSnd80 = true }

        restart(&silent)
        // The voices the song is played through are new ones, as the library's mixer's are.
        for v in 0 ..< 8 { paula[v] = PaulaRegisters(start: length + 1) }
        endings = 0
        stops = 0
    }

    // MARK: TFMX

    static let tfmxTrackTabColumnSize: UInt8 = 3
    static let tfmxTrackTabStepSize: UInt8 = 12
    static let tfmxSongTabEntrySize: UInt32 = 6
    static let tfmxSampleStructSize = 0x12 + 4 + 2 + 4 + 2
    static let cosoSampleStructSize = 4 + 2 + 2 + 2
    static let sevenVoicesTrackTabStepSize: UInt8 = 0x1C
    static let sevenVoicesTrackTabColumnSize: UInt8 = 4
    static let sevenVoicesSongTabEntrySize: UInt32 = 8
    static let mcmdSampleStructSize = 0x12 + 4 + 2 + 2 + 2

    mutating func tfmxInit<Output: TFMXOutput>(_ songNumber: Int, _ out: inout Output) -> Bool {
        admin.startSong = songNumber < 0 ? 0 : songNumber
        setRate(50 << 8)
        stats.voices = 4
        trackColumnSize = Self.tfmxTrackTabColumnSize
        trackStepLen = Self.tfmxTrackTabStepSize
        traits.sampleStructSize = Self.tfmxSampleStructSize

        startSongKind = .tfmx
        nextNoteKind = .tfmx
        vibratoKind = .tfmx
        portamentoKind = .tfmx

        traits.vibScaling = true
        traits.vibSpeedFlag = true
        traits.sndSeqGoto = true
        traits.porta40SetSnd = true // harmless for modules that do not use it
        traitsByChecksum()
        if blacklisted { return false }

        // (The module is not moved to the beginning of the memory, so its header is where it is.)
        let h = offsets.header
        stats.sndSeqs = 1 + Int(word(h &+ 4))
        stats.volSeqs = 1 + Int(word(h &+ 6))
        stats.patterns = 1 + Int(word(h &+ 8))
        stats.trackSteps = 1 + Int(word(h &+ 0xA))
        traits.patternSize = Int(byte(h &+ 0xD))
        if traits.patternSize != Self.patternLength { return false } // perhaps never
        // There may be songs that cannot be played, but they are counted to find the samples.
        stats.songs = Int(word(h &+ 0x10))
        if stats.songs > 32 { return false }
        if admin.startSong >= stats.songs { admin.startSong = 0 }
        stats.samples = min(Int(word(h &+ 0x12)), 256)

        var offs = h &+ 0x20
        offsets.sndModSeqs = offs
        offs &+= UInt32(truncatingIfNeeded: stats.sndSeqs * 64)
        offsets.volModSeqs = offs
        offs &+= UInt32(truncatingIfNeeded: stats.volSeqs * 64)
        offsets.patterns = offs
        offs &+= UInt32(truncatingIfNeeded: stats.patterns * traits.patternSize)
        offsets.trackTable = offs
        trackTabLen = Int32(truncatingIfNeeded: stats.trackSteps * Int(trackStepLen))
        offs &+= UInt32(bitPattern: trackTabLen)
        offsets.subSongTab = offs
        // The songs, and one more that is not used.
        offs &+= UInt32(truncatingIfNeeded: stats.songs + 1) &* Self.tfmxSongTabEntrySize
        if Int(offs) >= length { return false }
        offsets.sampleHeaders = offs
        offs &+= UInt32(truncatingIfNeeded: stats.samples * traits.sampleStructSize)
        offsets.sampleData = offs

        if rejectsAtariSequences() { return false }

        vSongs.removeAll()
        let maybe4V = tfmx4VMaybe()
        let maybe7V = tfmx7VMaybe()
        if !maybe4V, maybe7V {
            sevenVoicesSubInit()
            findSongs(Self.sevenVoicesSongTabEntrySize)
        } else {
            findSongs(Self.tfmxSongTabEntrySize)
        }
        if vSongs.isEmpty { return false }

        var sh = offsets.sampleHeaders &+ 0x12 // past the name
        for sam in 0 ..< stats.samples {
            // The places are from the start of the samples.
            let startOffs = long(sh) &+ offsets.sampleData
            samples[sam].startOffs = startOffs
            samples[sam].len = word(sh &+ 4)
            samples[sam].repOffs = UInt32(word(sh &+ 8)) // the lower word only
            samples[sam].repLen = word(sh &+ 10)
            samples[sam].assertBoundaries(length)
            if long(startOffs) == Self.ssmp {
                traits.foundSSMP = true
            } else if samples[sam].repLen == 1 {
                // A sample played once.
                let o = samples[sam].startOffs &+ samples[sam].repOffs
                setByte(o &+ 1, 0)
                setByte(o, 0)
            }
            sh &+= UInt32(traits.sampleStructSize)
        }
        restart(&out)
        return true
    }

    /// Atari ST modules seem to use other sound sequence commands, and are not played: a command like
    /// $E2 $E5 with fewer than $E5 samples would make no sense on the Amiga.
    mutating func rejectsAtariSequences() -> Bool {
        // The library counts its sequences in a byte, and so for a module of more than 256 goes round
        // the first 256 for ever, unless one of them is refused: siday refuses the module instead.
        for seq in 0 ..< min(stats.sndSeqs, 256) {
            let seqOffs = getSndSeq(UInt8(seq))
            if stats.samples < 0xE5, byte(seqOffs) == 0xE2, byte(seqOffs &+ 1) >= 0xE5 { return true }
        }
        return stats.sndSeqs > 256
    }

    mutating func findSongs(_ songEntrySize: UInt32) {
        // A song whose first step is not before its last would end at once.
        for so in 0 ..< stats.songs {
            let offsetSongDef = offsets.subSongTab &+ UInt32(so) &* songEntrySize
            if word(offsetSongDef) < word(offsetSongDef &+ 2) {
                vSongs.append(UInt8(truncatingIfNeeded: so))
            }
        }
    }

    /// The song asked for, as a place in the table of songs. (The library takes one beyond the songs
    /// it found from beyond its list of them; siday takes the first.)
    func songDefinition(_ entrySize: UInt32) -> UInt32 {
        let index = admin.startSong < vSongs.count ? admin.startSong : 0
        return offsets.subSongTab &+ UInt32(vSongs[index]) &* entrySize
    }

    mutating func tfmxStartSong<Output: TFMXOutput>(_ out: inout Output) {
        let offsetSongDef = songDefinition(Self.tfmxSongTabEntrySize)
        firstStep = Int(word(offsetSongDef))
        lastStep = Int(word(offsetSongDef &+ 2))
        admin.startSpeed = Int(word(offsetSongDef &+ 4))
        admin.speed = Int16(truncatingIfNeeded: admin.startSpeed)
        setTrackRange()
        reset(&out)
    }

    /// Whether the module looks like one of four voices: the unused song after the songs is empty but
    /// for its speed, and the samples' places, after it, are in the module.
    func tfmx4VMaybe() -> Bool {
        let probeOffset = offsets.subSongTab &+ Self.tfmxSongTabEntrySize &* UInt32(truncatingIfNeeded: stats.songs)
        if Int(probeOffset) >= length || word(probeOffset) != 0 || word(probeOffset &+ 2) != 0 || byte(probeOffset &+ 4) != 0 {
            return false
        }
        var sh = offsets.sampleHeaders
        for _ in 0 ..< stats.samples {
            sh &+= 0x12 // past the name
            // No module is as long as 16 MB.
            if byte(sh) != 0 || byte(sh &+ 6) != 0 { return false }
            if long(sh) &+ offsets.sampleData > UInt32(length) { return false }
            sh &+= 4 + 2 + 4 + 2
        }
        return true
    }

    /// Whether the module looks like one of seven voices, whose steps and songs are longer.
    func tfmx7VMaybe() -> Bool {
        let probeOffset = sevenVoicesProbeOffset()
        if Int(probeOffset) >= length || long(probeOffset) != 0 || long(probeOffset &+ 4) != 0 { return false }
        var sh = probeOffset &+ Self.sevenVoicesSongTabEntrySize &+ 0x12 // past the name
        for _ in 0 ..< stats.samples {
            if byte(sh) != 0 || byte(sh &+ 6) != 0 { return false }
            if long(sh) &+ offsets.sampleData > UInt32(length) { return false }
            sh &+= UInt32(traits.sampleStructSize)
        }
        return true
    }

    /// Where the unused song after the songs would be, for seven voices.
    func sevenVoicesProbeOffset() -> UInt32 {
        offsets.trackTable
            &+ UInt32(truncatingIfNeeded: stats.trackSteps) &* UInt32(Self.sevenVoicesTrackTabStepSize)
            &+ UInt32(truncatingIfNeeded: stats.songs) &* Self.sevenVoicesSongTabEntrySize
    }

    // MARK: TFMX 7V

    /// Switches from TFMX or compressed TFMX to seven voices.
    mutating func sevenVoicesSubInit() {
        stats.voices = 7
        trackColumnSize = Self.sevenVoicesTrackTabColumnSize
        trackStepLen = Self.sevenVoicesTrackTabStepSize
        trackTabLen = Int32(truncatingIfNeeded: stats.trackSteps * Int(trackStepLen))

        var offs = offsets.trackTable
        // The first step's second byte sets Paula's fourth voice's period (not done); its third, the
        // rate.
        sevenVoicesSetRate(signedByte(offs &+ 2))
        offs &+= UInt32(bitPattern: trackTabLen)
        offsets.subSongTab = offs
        offs &+= UInt32(truncatingIfNeeded: stats.songs + 1) &* Self.sevenVoicesSongTabEntrySize
        offsets.sampleHeaders = offs
        offs &+= UInt32(truncatingIfNeeded: stats.samples * traits.sampleStructSize)
        offsets.sampleData = offs

        startSongKind = .sevenVoices
        vibratoKind = .coso
        portamentoKind = .coso

        traits.sndSeqGoto = true
        traits.sndSeqToTrans = false
        traits.skipToWaveMod = true
        traits.volSeqSnd80 = true
        traits.porta40SetSnd = true
        traits.voiceVolume = true
        traits.randomVolume = true

        sndModFuncs[1] = .e1WaveMod
        sndModFuncs[7] = .e7SetDiffWave
        sndModFuncs[10] = .ea

        format = format == .compressedTFMX ? .compressedTFMX7V : .tfmx7V
    }

    mutating func sevenVoicesStartSong<Output: TFMXOutput>(_ out: inout Output) {
        let offsetSongDef = songDefinition(Self.sevenVoicesSongTabEntrySize)
        firstStep = Int(word(offsetSongDef))
        lastStep = Int(word(offsetSongDef &+ 2))
        admin.startSpeed = Int(word(offsetSongDef &+ 6))
        setTrackRange()
        reset(&out)
    }

    /// TFMX 7V's rate: fifty ticks a second, made faster or slower by `x` 256ths.
    mutating func sevenVoicesSetRate(_ x: Int8) {
        sevenVoiceTempo = Int(x)
        setRate(UInt32(((50 << 8) * 256) / (256 + Int(x))))
    }

    // MARK: Compressed TFMX

    mutating func cosoInit<Output: TFMXOutput>(_ songNumber: Int, _ out: inout Output) -> Bool {
        admin.startSong = songNumber < 0 ? 0 : songNumber
        setRate(50 << 8)
        stats.voices = 4
        trackColumnSize = Self.tfmxTrackTabColumnSize
        trackStepLen = Self.tfmxTrackTabStepSize
        traits.sampleStructSize = Self.cosoSampleStructSize

        startSongKind = .tfmx
        nextNoteKind = .coso
        vibratoKind = .coso
        portamentoKind = .coso
        // Some players of compressed modules do TFMX's portamento.
        if tfmxFindPortamentoCode() { portamentoKind = .tfmx }

        traits.compressed = true
        traits.vibSpeedFlag = true
        traits.skipToWaveMod = true
        traits.sndSeqGoto = true
        traits.volSeqSnd80 = true
        traits.porta40SetSnd = true
        traits.voiceVolume = true

        sndModFuncs[1] = .e1WaveMod
        sndModFuncs[7] = .e7SetDiffWave
        sndModFuncs[10] = .ea

        var h = offsets.header // the COSO header
        var ht = h &+ 0x20 // the TFMX header

        // Broken or cut files ("cryptoburners - pack*.hipc": without samples, without the module's
        // data, or with their samples cut short).
        if long(h &+ 0xC) == 0 || long(h &+ 0x10) == 0 || long(h &+ 0x14) == 0 || long(h &+ 0x1C) == 0
            || long(h &+ 0x18) >= UInt32(length) {
            return false
        }

        // Some files are packs of modules, whose headers are kept.
        var headers: [UInt32] = [h]
        // There may be songs that cannot be played, but they are counted to find the samples. (In a
        // pack, these are the first module's.)
        stats.songs = Int(word(ht &+ 0x10))
        offsets.sampleHeaders = h &+ long(h &+ 0x18)
        offsets.sampleData = h &+ long(h &+ 0x1C)

        vSongs.removeAll()
        let (isModPack, reject) = cosoIsModPack(&headers)
        if stats.songs > 32 { return false }
        if admin.startSong >= stats.songs { admin.startSong = 0 }
        if isModPack {
            if reject { return false }
            // The songs of all of the pack's modules, the song asked for found in its own.
            vSongs = [UInt8](repeating: 0, count: stats.songs)
            for header in headers {
                h = header
                var songsInThisMod = Int(UInt8(truncatingIfNeeded: word(h &+ 0x20 &+ 0x10)))
                if songsInThisMod > stats.songs { songsInThisMod = stats.songs }
                if admin.startSong < songsInThisMod {
                    offsets.header = h
                    ht = h &+ 0x20
                    for so in 0 ..< songsInThisMod { vSongs[so] = UInt8(so) }
                    break
                }
                admin.startSong -= songsInThisMod
            }
        }

        offsets.sndModSeqs = h &+ long(h &+ 0x4)
        offsets.volModSeqs = h &+ long(h &+ 0x8)
        offsets.patterns = h &+ long(h &+ 0xC)
        offsets.trackTable = h &+ long(h &+ 0x10)
        offsets.subSongTab = h &+ long(h &+ 0x14)

        stats.sndSeqs = 1 + Int(word(ht &+ 0x4))
        stats.volSeqs = 1 + Int(word(ht &+ 0x6))
        stats.patterns = 1 + Int(word(ht &+ 0x8))
        stats.trackSteps = 1 + Int(word(ht &+ 0xA))
        // A compressed pattern's size is not fixed.
        traits.patternSize = 0
        stats.samples = min(Int(word(ht &+ 0x12)), 256) // not one more, as in TFMX

        let maybe4V = coso4VMaybe()
        let maybe7V = coso7VMaybe()
        if !maybe4V, maybe7V {
            sevenVoicesSubInit()
            findSongs(Self.sevenVoicesSongTabEntrySize)
        } else if !isModPack {
            findSongs(Self.tfmxSongTabEntrySize)
        }
        if vSongs.isEmpty { return false }

        trackTabLen = Int32(truncatingIfNeeded: stats.trackSteps * Int(trackStepLen))
        traitsByChecksum()
        if blacklisted { return false }

        if rejectsAtariSequences() { return false }

        var sh = offsets.sampleHeaders
        for sam in 0 ..< stats.samples {
            samples[sam].startOffs = long(sh) &+ offsets.sampleData
            samples[sam].len = word(sh &+ 4)
            samples[sam].repOffs = UInt32(word(sh &+ 6))
            samples[sam].repLen = word(sh &+ 8)
            samples[sam].assertBoundaries(length)
            // Samples played once.
            if samples[sam].repLen == 1 {
                let o = samples[sam].startOffs &+ samples[sam].repOffs
                setByte(o &+ 1, 0)
                setByte(o, 0)
            }
            sh &+= UInt32(traits.sampleStructSize)
        }
        restart(&out)
        return true
    }

    /// Whether the module looks like one of four voices: the unused song after the songs is empty but
    /// for its speed.
    func coso4VMaybe() -> Bool {
        let probeOffset = offsets.subSongTab &+ Self.tfmxSongTabEntrySize &* UInt32(truncatingIfNeeded: stats.songs)
        return !(Int(probeOffset) >= length || word(probeOffset) != 0 || word(probeOffset &+ 2) != 0 || byte(probeOffset &+ 4) != 0)
    }

    func coso7VMaybe() -> Bool {
        let probeOffset = sevenVoicesProbeOffset()
        if Int(probeOffset) >= length || long(probeOffset) != 0 || long(probeOffset &+ 4) != 0 { return false }
        var sh = probeOffset &+ Self.sevenVoicesSongTabEntrySize
        for _ in 0 ..< stats.samples {
            if long(sh) &+ offsets.sampleData > UInt32(length) { return false }
            sh &+= UInt32(traits.sampleStructSize)
        }
        return true
    }

    /// How many headers of a pack siday follows before taking the pack to go round for ever (where
    /// the library would go on until it ran out of memory) and refusing it.
    static let packLimit = 4096

    /// Whether the file is a pack of compressed modules, and if so whether it is to be refused. Some
    /// .hipc files hold several, one of the offsets of each module's header used as a link to the next
    /// header, the last module holding the samples. One kind links by the samples' offset at +$1C
    /// (each module having the samples' headers over again); another by the sample headers' offset
    /// at +$18, which is sometimes $18 too high, and whose modules' counts of songs may be wrong too.
    mutating func cosoIsModPack(_ headers: inout [UInt32]) -> (Bool, Bool) {
        var h = offsets.header
        // Delirium's custom player's pack ("cust.ingame_1-7.hipc"), linked by +$1C.
        var nextHeader = offsets.sampleData
        var foundLink = false
        while nextHeader != 0, long(nextHeader) == Self.cosoHex {
            foundLink = true
            if long(nextHeader &+ 0x20) != Self.tfmxHex { return (true, true) } // a COSO without TFMX
            if headers.count >= Self.packLimit { return (true, true) }
            headers.append(nextHeader)
            stats.songs += Int(word(nextHeader &+ 0x20 &+ 0x10))
            offsets.sampleHeaders = nextHeader &+ long(nextHeader &+ 0x18)
            nextHeader &+= long(nextHeader &+ 0x1C)
            offsets.sampleData = nextHeader
        }
        if foundLink { return (true, false) }

        // Linked by +$18, as "astaroth.hipc" is: its second header's link is $18 too high, and says it
        // has four songs, when it has one.
        nextHeader = offsets.sampleHeaders
        while nextHeader != 0 {
            if long(nextHeader) == Self.cosoHex {
            } else if long(nextHeader &- 0x18) == Self.cosoHex {
                nextHeader &-= 0x18 // a broken offset, it seems
            } else {
                break
            }
            if long(nextHeader &+ 0x20) != Self.tfmxHex { return (true, true) }
            if headers.count >= Self.packLimit { return (true, true) }
            h = nextHeader
            headers.append(h)

            offsets.subSongTab = h &+ long(h &+ 0x14)
            // This may be a link, and again $18 too high.
            offsets.sampleHeaders = h &+ long(h &+ 0x18)
            nextHeader = offsets.sampleHeaders
            // The link to the next header, if there is one, tells how many songs this module has.
            if long(nextHeader) == Self.cosoHex {
            } else if long(nextHeader &- 0x18) == Self.cosoHex {
                nextHeader &-= 0x18
            }
            if offsets.subSongTab != h {
                let songs = UInt16(truncatingIfNeeded: (nextHeader &- offsets.subSongTab) / 6)
                setWord(h &+ 0x20 &+ 0x10, songs) // the header mended
                stats.songs += Int(songs)
            }
            stats.samples = Int(word(h &+ 0x20 &+ 0x12)) // the last module's is right
            offsets.sampleData = offsets.sampleHeaders &+ UInt32(truncatingIfNeeded: stats.samples * traits.sampleStructSize)
        }
        return (false, false)
    }

    static let cosoHex: UInt32 = 0x434F_534F // "COSO"
    static let tfmxHex: UInt32 = 0x5446_4D58 // "TFMX"

    // MARK: MCMD

    // MCMD, whose author is not known, is TFMX with a shorter header and sample headers, $3F
    // instruments in a pattern, the compressed modules' vibrato, TFMX's portamento with its bits
    // moved, other sound sequence commands, and a note's second byte able to set its sound sequence.

    mutating func mcmdInit<Output: TFMXOutput>(_ songNumber: Int, _ out: inout Output) -> Bool {
        admin.startSong = songNumber < 0 ? 0 : songNumber
        setRate(50 << 8)
        stats.voices = 4
        trackColumnSize = Self.tfmxTrackTabColumnSize
        trackStepLen = Self.tfmxTrackTabStepSize
        traits.sampleStructSize = Self.mcmdSampleStructSize

        startSongKind = .mcmd
        nextNoteKind = .tfmx
        vibratoKind = .coso
        portamentoKind = .tfmx

        traits.sndSeqGoto = true
        traits.portaIsBit6 = true
        traits.porta80SetSnd = true

        sndModFuncs[1] = .e1WaveMod
        sndModFuncs[5] = .e7SetDiffWave
        sndModFuncs[6] = .undef
        sndModFuncs[9] = .undef
        sndModFuncs[10] = .undef

        let h = offsets.header
        stats.sndSeqs = Int(word(h &+ 4))
        stats.volSeqs = Int(word(h &+ 6))
        stats.patterns = Int(word(h &+ 8))
        stats.trackSteps = Int(word(h &+ 0xA))
        traits.patternSize = Int(byte(h &+ 0xD))
        stats.songs = Int(word(h &+ 0xE))
        stats.samples = Int(word(h &+ 0x10))

        var offs = h &+ 0x12
        offsets.sndModSeqs = offs
        offs &+= UInt32(truncatingIfNeeded: stats.sndSeqs * 64)
        offsets.volModSeqs = offs
        offs &+= UInt32(truncatingIfNeeded: stats.volSeqs * 64)
        offsets.patterns = offs
        offs &+= UInt32(truncatingIfNeeded: stats.patterns * traits.patternSize)
        offsets.trackTable = offs
        trackTabLen = Int32(truncatingIfNeeded: stats.trackSteps * Int(trackStepLen))
        offs &+= UInt32(bitPattern: trackTabLen)
        offsets.subSongTab = offs
        offs &+= UInt32(truncatingIfNeeded: stats.songs) &* Self.sevenVoicesSongTabEntrySize
        if Int(offs) >= length { return false }
        offsets.sampleHeaders = offs
        offs &+= UInt32(truncatingIfNeeded: stats.samples * traits.sampleStructSize)
        offsets.sampleData = offs

        var sh = offsets.sampleHeaders &+ 0x12 // past the name
        // (The library does not stop at its 256 samples here, and writes past them: siday stops.)
        for sam in 0 ..< stats.samples {
            let startOffs = long(sh) &+ offsets.sampleData
            if sam < 256 {
                samples[sam].startOffs = startOffs
                samples[sam].len = word(sh &+ 4)
                samples[sam].repOffs = UInt32(word(sh &+ 6))
                samples[sam].repLen = word(sh &+ 8)
                samples[sam].assertBoundaries(length)
                if samples[sam].repLen == 1 {
                    let o = samples[sam].startOffs &+ samples[sam].repOffs
                    setByte(o &+ 1, 0)
                    setByte(o, 0)
                }
            }
            sh &+= UInt32(traits.sampleStructSize)
        }
        restart(&out)
        return true
    }

    mutating func mcmdStartSong<Output: TFMXOutput>(_ out: inout Output) {
        let offsetSongDef = offsets.subSongTab &+ UInt32(truncatingIfNeeded: admin.startSong) &* Self.sevenVoicesSongTabEntrySize
        firstStep = Int(word(offsetSongDef))
        lastStep = Int(word(offsetSongDef &+ 2))
        admin.startSpeed = Int(word(offsetSongDef &+ 4))
        setTrackRange()
        reset(&out)
    }

    // MARK: Future Composer

    static let smodSampleHeadersOffset: UInt32 = 0x28
    static let smodTrackTabOffset: UInt32 = 0x64
    static let fc14WaveHeadersOffset: UInt32 = 0x64
    static let fc14TrackTabOffset: UInt32 = 0xB4

    /// Future Composer 1.0 to 1.3, read as 1.4 is.
    mutating func smodInit<Output: TFMXOutput>(_ songNumber: Int, _ out: inout Output) -> Bool {
        traits.isSMOD = true
        traits.periodMax = Traits.smodPeriodMax
        return fcInit(songNumber, &out)
    }

    mutating func fcInit<Output: TFMXOutput>(_: Int, _ out: inout Output) -> Bool {
        admin.startSong = 0 // the format has no songs
        setRate(50 << 8)
        stats.voices = 4
        stats.songs = 1
        traits.patternSize = Self.patternLength

        trackColumnSize = Self.tfmxTrackTabColumnSize
        trackStepLen = Self.tfmxTrackTabStepSize + 1
        offsets.trackTable = traits.isSMOD ? Self.smodTrackTabOffset : Self.fc14TrackTabOffset
        trackTabLen = Int32(bitPattern: long(4))
        offsets.patterns = long(8)
        // A track table of no length ("cult.smod"), which this mends well enough.
        if trackTabLen == 0 { trackTabLen = Int32(bitPattern: offsets.patterns &- offsets.trackTable) }
        // The lengths of the patterns, and of the sequences, each 64 bytes, give how many there are.
        stats.patterns = Int(long(12) / UInt32(traits.patternSize))
        offsets.sndModSeqs = long(16)
        stats.sndSeqs = Int(long(20) / 64)
        offsets.volModSeqs = long(24)
        stats.volSeqs = Int(long(28) / 64)

        startSongKind = .fc
        nextNoteKind = .fc
        vibratoKind = .tfmx
        portamentoKind = .fc

        traits.vibScaling = true
        traits.sndSeqToTrans = true
        traits.sndSeqGoto = false
        traits.volSeqEA = true
        traits.checkSSMPtag = true

        sndModFuncs[5] = .undef
        sndModFuncs[6] = .undef
        sndModFuncs[7] = .e7
        sndModFuncs[9] = .fcE9
        sndModFuncs[10] = .fcEAPitchbend

        var sampleOffset = long(32)
        offsets.sampleData = sampleOffset
        var sampleHeader = Self.smodSampleHeadersOffset // the same in 1.4
        offsets.sampleHeaders = sampleHeader

        // Ten samples, or sample packs of ten samples each. Lengths are in words, repeats' offsets in
        // bytes (even), repeats' lengths in words (one at least). A sample played once has its repeat at
        // its end, at a word of nought, one word long.
        for sam in 0 ..< 10 {
            samples[sam].startOffs = sampleOffset
            let sampleLength = word(sampleHeader)
            samples[sam].len = sampleLength
            samples[sam].repOffs = UInt32(word(sampleHeader &+ 2))
            samples[sam].repLen = word(sampleHeader &+ 4)
            samples[sam].assertBoundaries(length)

            // A sample played once has a word of it cleared, so that it does not beep at its end where
            // it goes round. (Future Composer 1.4 does it differently from those before it.)
            if traits.isSMOD, samples[sam].repLen == 1 {
                setByte(sampleOffset &+ 1, 0)
                setByte(sampleOffset, 0)
            }
            sampleOffset &+= UInt32(sampleLength)
            sampleOffset &+= UInt32(sampleLength)
            if !traits.isSMOD {
                // Not where a sample pack's "SSMP" is.
                let pos = sampleOffset
                if long(pos) != Self.ssmp, samples[sam].repLen == 1 {
                    setByte(pos &+ 1, 0)
                    setByte(pos, 0)
                }
                // Future Composer 1.4 keeps a silent word after each sample (but not after an empty one).
                if sampleLength != 0 { sampleOffset &+= 2 }
            }
            sampleHeader &+= 6
        }

        if traits.isSMOD {
            // The waveforms built in.
            stats.samples = 10 + 47
            for wave in 0 ..< 47 {
                let sam = 10 + wave
                samples[sam].startOffs = UInt32(HippelTables.smodWaveInfo[wave * 4])
                samples[sam].pStart = wavesAt + Int(samples[sam].startOffs)
                samples[sam].len = HippelTables.smodWaveInfo[wave * 4 + 1]
                samples[sam].repOffs = UInt32(HippelTables.smodWaveInfo[wave * 4 + 2])
                samples[sam].repLen = HippelTables.smodWaveInfo[wave * 4 + 3]
            }
        } else {
            // Eighty waveforms of the module's, $100 bytes long at most.
            stats.samples = 10 + 80
            var waveOffset = long(36)
            var waveHeader = Self.fc14WaveHeadersOffset
            for wave in 0 ..< 80 {
                let sam = 10 + wave
                samples[sam].startOffs = waveOffset
                let waveLength = byte(waveHeader)
                waveHeader &+= 1
                samples[sam].len = UInt16(waveLength)
                samples[sam].repOffs = 0
                samples[sam].repLen = UInt16(waveLength)
                samples[sam].assertBoundaries(length)
                waveOffset &+= UInt32(waveLength)
                waveOffset &+= UInt32(waveLength)
            }
        }

        mendShaolin()
        restart(&out)
        return true
    }

    mutating func fcStartSong<Output: TFMXOutput>(_ out: inout Output) {
        // The whole track table is played.
        firstStep = -1
        lastStep = -1
        // The speed is the first step's. (Some players read it from the step a song starts at, which is
        // wrong for a song started part way through.)
        admin.startSpeed = Int(byte(offsets.trackTable &+ UInt32(Self.tfmxTrackTabStepSize)))
        setTrackRange()
        reset(&out)
    }

    // MARK: Mending the Chambers of Shaolin

    /// Whether pattern `n` is the one given. (The library reads the memory raw here, checking only that
    /// the pattern begins less than its number before the module's end: so does siday, which has
    /// zeros after the module's silence where the library has whatever is there.)
    func havePattern(_ n: Int, _ wanted: [UInt8]) -> Bool {
        let pattStart = offsets.patterns &+ UInt32(truncatingIfNeeded: n * traits.patternSize)
        guard n < stats.patterns, Int(pattStart &+ UInt32(n)) < length else { return false }
        for i in 0 ..< traits.patternSize where memory[Int(pattStart) + i] != wanted[i] { return false }
        return true
    }

    mutating func replacePattern(_ n: Int, _ new: [UInt8]) {
        let pattStart = Int(offsets.patterns &+ UInt32(truncatingIfNeeded: n * traits.patternSize))
        for i in 0 ..< traits.patternSize where pattStart + i < size { memory[pattStart + i] = new[i] }
    }

    /// The modules of the game Chambers of Shaolin that came with Future Composer 1.2 and 1.3 are
    /// broken, and are in many collections: their patterns are mended as they are read, from Jochen
    /// Hippel's own modules where those have no portamento (which Future Composer does differently),
    /// and otherwise as near as the library's author could make them.
    mutating func mendShaolin() {
        if HippelTables.shaolin1.allSatisfy({ havePattern($0.pattern, $0.original) }) {
            for fix in HippelTables.shaolin1 { replacePattern(fix.pattern, fix.fixed) }
        }
        if HippelTables.shaolin2.allSatisfy({ havePattern($0.pattern, $0.original) }) {
            for fix in HippelTables.shaolin2 { replacePattern(fix.pattern, fix.fixed) }
        }
        if HippelTables.shaolin3.allSatisfy({ havePattern($0.pattern, $0.original) }) {
            for fix in HippelTables.shaolin3 { replacePattern(fix.pattern, fix.fixed) }
            if HippelTables.shaolin3Pattern25.allSatisfy({ havePattern($0.pattern, $0.original) }) {
                for fix in HippelTables.shaolin3Pattern25 { replacePattern(fix.pattern, fix.fixed) }
            }
        }
        if havePattern(0x1A, HippelTables.shaolin5Pattern1A), havePattern(0x17, HippelTables.shaolin5Pattern17) {
            // (Unchecked in the library: siday reads only inside the module and its silence.)
            let at = Int(offsets.trackTable &+ 0x33 &* UInt32(trackStepLen))
            let steps = HippelTables.shaolin5StepsOriginal
            if at + steps.count <= size, (0 ..< steps.count).allSatisfy({ memory[at + $0] == steps[$0] }) {
                for (i, value) in HippelTables.shaolin5StepsFixed.enumerated() { memory[at + i] = value }
            }
        }
    }

    // MARK: Players known by their checksums

    /// The CRC-32 of `count` bytes from `at`, reading outside the module and its silence as nought
    /// (the library's own guarded pointer for this, which is new and has never been written outside).
    func crc32(_ at: UInt32, _ count: UInt32) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        var at = at
        for _ in 0 ..< count {
            let b = Int(at) < size ? memory[Int(at)] : 0
            at &+= 1
            crc = TFMXDecoder.crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// As a module does not say which player it wants, a few players are told by the checksum of their
    /// code before the module (up to the silent sequences in it, which come before its voices'
    /// variables), and a few compressed modules by their track tables'.
    mutating func traitsByChecksum() {
        if offsets.header != 0 {
            var crc1: UInt32 = 0
            let d = UnsafeBufferPointer(start: memory, count: size)
            if let silenceOffs = Self.search(d, from: 0, to: Int(offsets.header), Self.silenceData) {
                crc1 = crc32(0, UInt32(silenceOffs))
            }
            // Wings of Death (its end, intro, outro and title): the player goes from a sustained sound
            // sequence to the volume sequence (heard in the outro's bass line), where the others go
            // on to the wave modulation.
            if crc1 == 0x3BCB_814B {
                traits.skipToWaveMod = true
            } else if crc1 == 0x4C0A_6454 {
                traits.skipToWaveMod = false
            }
            if crc1 == 0x3BCB_814B || crc1 == 0x4C0A_6454 {
                traits.vibScaling = false
                sndModFuncs[1] = .e1WaveMod
                sndModFuncs[5] = .e5
                sndModFuncs[6] = .e6
                sndModFuncs[7] = .e7SetDiffWave
                sndModFuncs[9] = .undef
            }
            // The Seven Gates of Jambala, Leaving Teramis and a few more.
            if crc1 == 0xB610_5CBF || crc1 == 0xB4F7_98E6 || crc1 == 0xED5C_FAC0 || crc1 == 0x6C55_F30A {
                traits.sndSeqToTrans = true
                traits.sndSeqGoto = false
                sndModFuncs[5] = .e5RepOffs // (not used by those modules)
                sndModFuncs[7] = .e7SetDiffWave
            }
            // Grand Monster Slam, the Atari ST's music for the Amiga, as the Wanted Team published it
            // ("SOG.GrandSlamMonsterST"), with Wings of Death's player before it: three of its samples
            // are by mistake defined as repeating (heard in the PING), where on the Atari ST they have
            // no length and are played once.
            if crc1 == 0x3BCB_814B, crc32(0x2950, 0x2A04 - 0x2950) == 0x9C2F_EB18 {
                setByte(0x2A02, 0) // DIG-1:PING.DIK
                setByte(0x2A03, 1)
                setByte(0x296C, 0) // DIG-1:TUSCH.DIK
                setByte(0x296D, 1)
                setByte(0x29E4, 0) // DIG-1:BONGO.DIK
                setByte(0x29E5, 1)
            }
            // Wings of Death, the Atari ST's music for the Amiga, as the Wanted Team published it
            // ("SOG.WingsOfDeathST intro"), with the Amiga game's player before it, which is not the one
            // to play it: the file known, with its high transposes from the Atari ST and its strong
            // portamento, is played with the lower periods, a weaker portamento and the compressed
            // modules' vibrato; any other release of it is not played.
            if crc1 == 0x4C0A_6454 {
                let crc2 = crc32(0x4A3C, 0x4CB2 - 0x4A3C) // the sample headers
                let crc3 = crc32(0x2EF4, 64) // pattern $40
                let crc4 = crc32(0x43F4, 0x4A18 - 0x43F4) // the track table
                if crc2 == 0xED03_955B {
                    if crc3 == 0x9668_1DEC, crc4 == 0x4320_2C79 {
                        traits.lowerPeriods = true
                        traits.periodMin = 0x002C
                        traits.portaWeaker = true
                        vibratoKind = .coso
                    } else {
                        blacklisted = true
                    }
                }
            }
        }

        if traits.compressed {
            let crc2 = crc32(offsets.trackTable, UInt32(bitPattern: trackTabLen))
            switch crc2 {
            // Astaroth, Chambers of Shaolin, Dragonflight (musf).
            case 0x5495_CC19, 0x7866_963A, 0xC04A_79A7, 0xC5EC_120D, 0x2158_D5FC, 0x2518_E0AA, 0x3E8F_7323:
                portamentoKind = .tfmx
            // Wings of Death's levels 1 to 7: compressed, but wanting a player with TFMX's vibrato and
            // portamento.
            case 0x6084_AE9F, 0x08EC_439C, 0x664A_0708, 0x5CBC_C3E9, 0x0585_14E2, 0x9BEA_B3A4, 0xB618_5651:
                traits.skipToWaveMod = true
                traits.vibScaling = false
                portamentoKind = .tfmx
                vibratoKind = .tfmx
            // A Prehistoric Tale (music4), which glitches at 0:53 and 1:11 as a new step's transpose
            // is heard at once in the sound playing: mended as it plays.
            case 0x5CF7_578F:
                traits.avoidTRglitch = true
            // Enchanted Land (3): its second song is the first three seconds of its first.
            case 0xCB44_1135:
                vSongs = [0]
            default:
                break
            }
        }
    }
}
