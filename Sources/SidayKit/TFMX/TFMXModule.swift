// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// A port of libtfmxaudiodecoder's reading of TFMX modules (src/Chris/TFMXDecoder.cpp, MergedFiles.cpp,
// SamplesFile.cpp, Songs.cpp and ByChecksum.cpp, and src/CRCLight.cpp), Copyright (C) Michael
// Schwendt, used under the GPL-2.0-or-later, as it is at its commit dcec102 of 2026-09-26.

// A TFMX module is two files, `mdat.` and `smpl.` in the Amiga's way of naming, `.mdat` and `.smpl` on
// the collections today: the notes and instruments, and the samples. Its header is 512 bytes: the
// text, then the 32 songs' first steps, last steps and speeds, the tracks' mutes, and the places of the
// track table, the patterns and the macros (or nought, for where they always were before modules were
// packed). A few files hold both halves, with a header of their own before them: TFMXPAK, TFHD and
// TFMX-MOD, the last a single song of a module, with its title, composer and game.

extension TFMXDecoder {
    /// True for a file that begins as a TFMX module or a file holding one does: "TFMX " (TFMX before its
    /// first release), "TFMX-SONG ", "tfmxsong", "TFMXPAK ", "TFHD" or "TFMX-MOD".
    static func isOne(_ data: [UInt8]) -> Bool {
        func begins(_ text: StaticString) -> Bool {
            let count = text.utf8CodeUnitCount
            guard data.count >= count else { return false }
            let tag = text.utf8Start
            for i in 0 ..< count where data[i] != tag[i] { return false }
            return true
        }
        return (data.count >= 5 && begins("TFMX") && data[4] == 0x20)
            || begins("TFMX-SONG ") || begins("tfmxsong") || begins("TFMXPAK ") || begins("TFHD") || begins("TFMX-MOD")
    }

    /// Reads the module, `file` and the samples file's `samples` (nil for none), into the memory, and
    /// starts song `song`: the library's `init` with a new decoder.
    mutating func setUp(_ file: [UInt8], samples: [UInt8]?, song songNumber: Int) throws(TuneError) {
        guard !file.isEmpty, Self.isOne(file) else { throw .malformed("not a TFMX module") }
        offsets.header = 0
        format = .pro
        for i in 0 ..< file.count { memory[i] = file[i] }
        size = file.count

        // A file holding both halves says where they are. Otherwise the samples are put after the module.
        if !isMerged() {
            guard let samples else { throw .missingCompanion("A TFMX module keeps its samples in a file of their own, which was not given with it.") }
            for i in 0 ..< samples.count { memory[size + i] = samples[i] }
            input.smplSize = UInt32(samples.count)
            input.mdatSize = UInt32(size) &- offsets.header
            offsets.sampleData = UInt32(size)
            size += samples.count
        }

        // (The module is not moved to the beginning of the memory, so its header is where it is.)
        let h = offsets.header
        var o1 = long(h &+ 0x1D0) // the track table
        var o2 = long(h &+ 0x1D4) // the patterns' places
        var o3 = long(h &+ 0x1D8) // the macros' places
        if o1 | o2 | o3 != 0 {
            variant.compressed = true
        } else {
            o1 = 0x800
            o2 = 0x400
            o3 = 0x600
        }
        // Places outside the file may be little-endian, as in a module converted from TFMX for the PC
        // ("Tony & Friends in Kellogg's Land").
        if Int(o1) >= size || Int(o2) >= size || Int(o3) >= size {
            o1 = o1.byteSwapped
            o2 = o2.byteSwapped
            o3 = o3.byteSwapped
        }
        offsets.trackTable = h &+ o1
        offsets.patterns = h &+ o2
        offsets.macros = h &+ o3
        guard Int(offsets.trackTable) < size, Int(offsets.patterns) < size, Int(offsets.macros) < size else {
            throw .malformed("a TFMX module whose parts are outside it")
        }

        offsets.sampleData = h &+ input.mdatSize
        offsets.silence = offsets.sampleData
        // TFMX clears the first two words of the samples, for samples played once.
        let o = offsets.sampleData
        setByte(o &+ 3, 0)
        setByte(o &+ 2, 0)
        setByte(o &+ 1, 0)
        setByte(o, 0)

        guard try !isAtariST() else { throw .unsupported("a TFMX module of the Atari ST's") }

        // The fields at $0A and $0C that say the module was packed, which are sometimes overwritten.
        let compressHint = long(h &+ 0x0C)
        if compressHint != 0, word(h &+ 0x0A) == 1 {
            offsets.trackTableEnd = offsets.trackTable &+ compressHint &- (0x800 - 0x10)
            if offsets.trackTableEnd > getPattOffset(0) { offsets.trackTableEnd = getPattOffset(0) }
        } else {
            offsets.trackTableEnd = getPattOffset(0)
        }

        // Defaults, which what follows may change.
        setRate(50 << 8)
        voiceCount = 4
        for v in 0 ..< 8 { channelToVoiceMap[v] = UInt8(v & 3) }
        variant = Variant()
        variant.execOrder = .macModSeq
        setMacroTable()

        // TFMX 1.5 and 2.2 cannot be told from the later players but by the header of TFMX before them
        // ("TFMX " and nought), a TFHD file's word, or a checksum (below).
        if (long(offsets.header) == 0x5446_4D58 && byte(offsets.header &+ 4) == 0x20) || input.versionHint == 1 {
            setTFMXv1()
        } else {
            format = .pro
        }
        traitsByChecksum()
        guard !blacklisted else { throw .unsupported("a TFMX module known to be broken") }

        findSongs()
        // Some files hold sound effects alone, and no songs.
        guard !songs.isEmpty else { throw .malformed("a TFMX module without songs") }
        // A file of one song (TFMX-MOD) is taken to have only that one.
        if input.startSongHint >= 0 { songs = [UInt8(truncatingIfNeeded: input.startSongHint)] }

        admin.startSong = max(songNumber, 0)
        if admin.startSong > songs.count - 1 { admin.startSong = 0 }
        var silent = TFMXSilentOutput()
        restart(&silent)
        admin.initialized = true

        // The song's length, from playing it through to its end, once.
        duration = 0
        let loopModeBefore = loopMode
        loopMode = false
        var four = TFMXTiming(), seven = TFMXTiming()
        lengthClocks = (0, 0)
        repeat {
            duration &+= UInt32(truncatingIfNeeded: run(&silent))
            lengthClocks.four &+= UInt64(four.fourVoiceTick(rate: rate, timer: ciaTimer))
            lengthClocks.seven &+= UInt64(seven.sevenVoiceTick(tempo: sevenVoiceTempo))
        } while !songEnd && duration < 1000 * 60 * 59
        loopMode = loopModeBefore

        adjustTraitsPost()
        restart(&silent)
        // Paula's voices are new: the library's mixer gives the decoder voices of its own once it is
        // ready, which start at silence of their own.
        for v in 0 ..< 8 { paula[v] = PaulaRegisters(start: size, length: 1, period: 0, volume: 0) }
    }

    /// The macro commands, as the players from TFMX Professional on have them.
    private mutating func setMacroTable() {
        macroTable = InlineArray(repeating: .nop)
        let commands: [MacroCommand] = [
            .stopSound, .startSample, .setBegin, .setLen, .wait, .loop, .cont, .stop,
            .addNote, .setNote, .reset, .portamento, .vibrato, .addVolNote, .setVolume, .envelope,
            .loopKeyUp, .addBegin, .addLen, .stopSample, .waitKeyUp, .goto, .return, .setPeriod,
            .sampleLoop, .oneShot, .waitOnDMA, .randomPlay, .splitKey, .splitVolume, .randomMask, .setPrevNote,
            // $20 (AddChannel, SubChannel or Signal in a few players) is not used by any module.
            .nop, .playMacro, .sid22, .sid23, .sid24, .sid25, .sid26, .sid27, .sid28, .sid29,
        ]
        for (number, command) in commands.enumerated() { macroTable[number] = command }
        macroTable[0x30] = .branchIfSame
        macroTable[0x31] = .keyUp
    }

    /// TFMX 1.5, and 2.2, which is like it but for the macros it adds from $1A to $1E and a few it does
    /// more with (AddVolume, which adds a note).
    mutating func setTFMXv1() {
        format = .tfmx
        variant.noAddBeginCount = true
        variant.vibratoUnscaled = true
        variant.vibratoTimeMask = true
        variant.finetuneUnscaled = true
        variant.portaUnscaled = true
        variant.portaOverride = true
        variant.setNoteV1 = true
        variant.extraWaitV1 = true
        variant.noDelayedDMAon = true
        variant.execOrder = .seqModMac
        macroTable[0xD] = .addVolume
        for m in 0x1A ..< 0x40 { macroTable[m] = .nop }
    }

    /// The track command 7VOICE, or a TFHD file's saying so, makes the module one of eight voices: the
    /// library's TFMX 7V is Hülsbeck's, of eight, the last four mixed onto Paula's fourth voice.
    mutating func adjustTraitsPost() {
        guard trackCmdUsed[3] || input.versionHint == 3 else { return }
        voiceCount = 8
        format = .sevenVoices
        channelToVoiceMap[3] = 7
        channelToVoiceMap[4] = 3
        channelToVoiceMap[5] = 4
        channelToVoiceMap[6] = 5
        channelToVoiceMap[7] = 6
    }

    // MARK: Files holding both halves

    /// Whether the file is one holding both halves, and if so, where the module is in it and how long
    /// it and the samples are.
    mutating func isMerged() -> Bool {
        input.versionHint = 0
        input.startSongHint = -1

        // "TFMXPAK 012345 0123456 >>>", an ASCII header of the early 1990s.
        if size > 31, Self.begins(memory, size, "TFMXPAK ") {
            // What is read is the first 31 bytes, as far as a nought among them.
            var probe: [UInt8] = []
            for i in 0 ..< 31 {
                if memory[i] == 0 { break }
                probe.append(memory[i])
            }
            var at = 8
            let first = Self.scanUnsigned(probe, &at)
            let second = first == nil ? nil : Self.scanUnsigned(probe, &at)
            if let first { input.mdatSize = first }
            if let second { input.smplSize = second }
            var arrows: Int?
            if probe.count >= 3 {
                for i in 0 ... probe.count - 3 where probe[i] == 0x3E && probe[i + 1] == 0x3E && probe[i + 2] == 0x3E {
                    arrows = i
                    break
                }
            }
            guard first != nil, second != nil, let arrows, input.mdatSize != 0, input.smplSize != 0 else { return false }
            offsets.header = UInt32(arrows + 3)
            return true
        }

        // The TFHD header, big-endian.
        if size > 0x12, Self.begins(memory, size, "TFHD") {
            // Two bytes of nought are required here, though they are the top of the header's length.
            if word(4) != 0 { return false }
            offsets.header = long(4)
            // 0 not said, 1 TFMX 1.5, 2 TFMX Pro, 3 TFMX 7V; with bit 7, forced.
            input.versionHint = Int(byte(8))
            input.mdatSize = long(10)
            input.smplSize = long(14)
            return input.mdatSize != 0 && input.smplSize != 0
        }

        // The TFMX-MOD header, little-endian.
        if size > 16, Self.begins(memory, size, "TFMX-MOD") {
            // Bytes of nought are required here, though they are the tops of two places.
            if byte(11) != 0 || byte(15) != 0 { return false }
            offsets.sampleData = Self.makeDword(byte(11), byte(10), byte(9), byte(8))
            offsets.header = 8 + 12
            input.mdatSize = offsets.sampleData &- offsets.header
            var offs = Self.makeDword(byte(15), byte(14), byte(13), byte(12))
            input.smplSize = offs &- input.mdatSize

            // Then what is said of the song, each a kind, a length and that many bytes.
            var startSong = -1
            repeat {
                let what = byte(offs)
                offs &+= 1
                let length = Self.makeWord(byte(offs &+ 1), byte(offs))
                offs &+= 2
                // (Rubbish at the end of some files looks like more, and is left unread.)
                if length == 0 || Int(offs) >= size || Int(offs) + Int(length) > size { break }
                switch what {
                case 1, 2, 6:
                    var text: [UInt8] = []
                    for _ in 0 ..< length {
                        let c = byte(offs)
                        offs &+= 1
                        // The Amiga's characters, as UTF-8.
                        if c < 128 {
                            text.append(c)
                        } else {
                            text.append(c > 0xBF ? 0xC3 : 0xC2)
                            text.append((c & 0x3F) + 0x80)
                        }
                    }
                    if what == 1 { author += text } else if what == 2 { game += text } else { title += text }
                case 0:
                    startSong = Int(Self.makeWord(byte(offs &+ 3), byte(offs &+ 2)))
                    offs &+= UInt32(length) * 4 // one long
                default:
                    offs &+= UInt32(length)
                }
            } while Int(offs) < size
            input.startSongHint = startSong
            return true
        }
        return false
    }

    private static func begins(_ memory: UnsafeMutablePointer<UInt8>, _ size: Int, _ text: StaticString) -> Bool {
        let count = text.utf8CodeUnitCount
        guard size >= count else { return false }
        for i in 0 ..< count where memory[i] != text.utf8Start[i] { return false }
        return true
    }

    /// The C library's `sscanf` reading a `%u` from `text` at `at`, as macOS's does: blanks skipped, a
    /// sign, decimal digits (a number too large for 64 bits being the largest), the 64 bits then cut
    /// to 32. Nil if there are no digits.
    static func scanUnsigned(_ text: [UInt8], _ at: inout Int) -> UInt32? {
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || (c >= 0x09 && c <= 0x0D) }
        while at < text.count, isSpace(text[at]) { at += 1 }
        var negative = false
        if at < text.count, text[at] == 0x2B || text[at] == 0x2D {
            negative = text[at] == 0x2D
            at += 1
        }
        var value: UInt64 = 0
        var digits = 0
        var overflow = false
        while at < text.count, text[at] >= 0x30, text[at] <= 0x39 {
            let (times, o1) = value.multipliedReportingOverflow(by: 10)
            let (sum, o2) = times.addingReportingOverflow(UInt64(text[at] - 0x30))
            if o1 || o2 { overflow = true }
            value = sum
            digits += 1
            at += 1
        }
        guard digits > 0 else { return nil }
        if overflow { return UInt32.max }
        return UInt32(truncatingIfNeeded: negative ? 0 &- value : value)
    }

    // MARK: Atari ST modules

    /// TFMX on the Atari ST had macro commands from $40 up. A module is taken to be one if, looking
    /// through its first seven macros in turn, one of those has been seen by the time a macro's Stop
    /// ($07) is. (The library looks through each macro as
    /// far as the next one's place, which for nonsense places may be as far as the top of 32 bits: its
    /// way through the bytes outside the memory, which all read the same, is taken in a stride here. A
    /// search that comes round past the top of 32 bits and round again without finding a Stop would
    /// never end there; that module is not played.)
    private func isAtariST() throws(TuneError) -> Bool {
        var foundHighMacroCmd = false
        for m in 0 ..< 7 {
            var macroOffs = getMacroOffset(UInt8(m))
            let macroEnd = getMacroOffset(UInt8(m + 1))
            if macroEnd <= macroOffs { break }
            var foundStop = false
            var turns = 0
            while macroOffs < macroEnd {
                if Int(macroOffs) >= size {
                    // Every byte from here to the end reads as the one outside.
                    let cmd = outside
                    if cmd == 7 {
                        foundStop = true
                        break
                    }
                    if cmd >= 0x40 { foundHighMacroCmd = true }
                    macroOffs &+= (macroEnd &- 1 &- macroOffs) / 4 * 4
                } else {
                    let cmd = byte(macroOffs)
                    if cmd == 7 {
                        foundStop = true
                        break
                    }
                    if cmd >= 0x40 { foundHighMacroCmd = true }
                }
                let next = macroOffs &+ 4
                if next < macroOffs {
                    turns += 1
                    if turns > 1 { throw .malformed("a TFMX module whose macros' places go nowhere") }
                }
                macroOffs = next
            }
            if foundStop, foundHighMacroCmd { return true }
        }
        return false
    }

    // MARK: Songs

    func getSongs() -> Int { songs.count }

    /// The songs the table of 32 defines that can be played: not those beyond the track table or ending
    /// before they begin, those whose one step leaves every track idle or ends the song, and those that
    /// are another's beginning over again.
    mutating func findSongs() {
        var seen: [(Int, Int, Int)] = []
        songs = []
        for so in 0 ..< 32 {
            let s1 = Int(word(offsets.header &+ 0x100 &+ UInt32(so << 1)))
            var s2 = Int(word(offsets.header &+ 0x140 &+ UInt32(so << 1)))
            let s3 = Int(word(offsets.header &+ 0x180 &+ UInt32(so << 1)))
            var s1next = s1
            let stepMax = Int(UInt16(truncatingIfNeeded: (offsets.trackTableEnd &- offsets.trackTable) / 0x10))
            // The first song's last step, if it is beyond the table, is brought back to it.
            if so == 0, s2 > stepMax { s2 = stepMax }
            // Step $1FF is not wrong in itself, but (1FF, 1FF, 0) was the 32nd song's stand-in, and some
            // files changed it to (0, 1FF, 5); yet (0, 1FF, speed) is a first song of Erno's.
            if s1 > s2 || s1 > 0x1FF || s2 > 0x1FF || s1 >= stepMax || (so > 0 && (s1 == 0x1FF || s2 == 0x1FF)) {
                continue
            }
            // A song of one step is not wrong in itself, but at times its tracks do not go on.
            if s1 == s2 {
                resetSequencer()
                sequencer.first = s1
                sequencer.current = s1
                sequencer.last = s2
                songEnd = false
                for t in 0 ..< 8 { tracks[t].PT = 0xFF }
                processTrackStep()
                var countInactive = 0
                for t in 0 ..< 8 where tracks[t].PT >= 0x90 { countInactive += 1 }
                // (The track command Stop ends a song at once.)
                if countInactive == 8 || songEnd { continue }
                if s1 != sequencer.current { s1next = sequencer.current }
            }
            // Not (X, X, speed) where a song before began at X, nor one that at once goes on to where a
            // song before began, nor a song exactly like one before.
            var skipSong = false
            for song in seen where (song.0 == s1 && s2 == song.0) || (s1next != s1 && song.0 == s1next) {
                skipSong = true
                break
            }
            if !skipSong, !seen.contains(where: { $0 == (s1, s2, s3) }) {
                songs.append(UInt8(so))
                seen.append((s1, s2, s3))
            }
        }
    }

    // MARK: Modules known by their checksums

    /// The CRC-32 of `count` bytes from `at`, reading outside the memory as nought (the library's own
    /// guarded pointer for this, which is new and has never been written outside).
    func crc32(_ at: UInt32, _ count: Int) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        var at = at
        for _ in 0 ..< count {
            let b = Int(at) < size ? memory[Int(at)] : 0
            at &+= 1
            crc = Self.crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// A long, reading outside the memory as nought, as `crc32` does.
    func checkedLong(_ at: UInt32) -> UInt32 {
        func b(_ i: UInt32) -> UInt32 { Int(i) < size ? UInt32(memory[Int(i)]) : 0 }
        return b(at) << 24 | b(at &+ 1) << 16 | b(at &+ 2) << 8 | b(at &+ 3)
    }

    static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0 ..< 256 {
            var c = UInt32(n)
            for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[n] = c
        }
        return table
    }()

    /// As the header does not say which player a module wants, a few known modules are told by the
    /// checksum of the first 256 bytes of their first pattern, and played as their games' players
    /// played them; and a few broken ones are mended, or not played.
    mutating func traitsByChecksum() {
        let p0 = offsets.header &+ checkedLong(offsets.patterns)
        let crc = crc32(p0, 0x100)
        switch crc {
        // Turrican II's music in the game (but not its loader's jingle) wants its own player, which runs
        // the macros and effects in another order.
        case 0xE2D6_B5E0, 0x0BF4_1B64, 0x19AC_72C3, 0x0385_4473, 0x9430_D9DE, 0xCBB8_42B0, 0x78CD_70F9:
            variant.execOrder = .modMacSeq
        // Turrican (1990) is TFMX 1 or 2 with some of the later macros, and wants the old vibrato and
        // portamento.
        case 0x7386_8FDA, 0x9373_0029, 0x6E79_9869, 0x3D00_FC52, 0xD76D_33ED, 0xB989_D570, 0x8FA8_0B4E,
             0x88F7_C34B, 0xB762_F2DC:
            setTFMXv1()
            variant.vibratoTimeMask = false
            macroTable[0x0D] = .addVolNote
            macroTable[0x1A] = .waitOnDMA
            macroTable[0x1C] = .splitKey
            macroTable[0x1D] = .splitVolume
        // Turrican 3, world 5: one copy of it is broken.
        case 0xC7AE_8DE6:
            if long(4 &+ getMacroOffset(0x4C)) != 0x0200_8C0E { blacklisted = true }
        // Danger Freak (1989), TFMX 1 without a note's detune.
        case 0x4896_0D8C, 0x5DCD_624F, 0x3F0B_151F:
            setTFMXv1()
            variant.noNoteDetune = true
        // Hard'n'Heavy (1989), TFMX 1 (and two copies someone packed); R-Type's intro below likewise.
        case 0x27F8_998C, 0x2644_7707, 0xD404_651B, 0xB534_8633:
            setTFMXv1()
        // R-Type (1989), with an extra wait in the macros' Loop. One copy lacks its first 192 samples.
        case 0x8AC7_0FC8:
            setTFMXv1()
            variant.macroLoopExtraWait = true
            if checkedLong(offsets.sampleData &+ 4) != 0xE8FF_20F9 || checkedLong(offsets.sampleData &+ 0xBC) != 0xE8F7_00FD {
                blacklisted = true
            }
        // The Adventures of Quik & Silva.
        case 0x04F4_69A6, 0xD37C_9008:
            variant.execOrder = .macModSeq
        // Rock'n'Roll's intro (1989; the rest of it has the header of TFMX before its first release).
        case 0xDA27_9570:
            setTFMXv1()
        // Grand Monster Slam, Circus Attractions, Gordian Tomb, Oxxonian, and X-Out's title, levels, end,
        // high scores, loader and shop: TFMX 1, for its vibrato.
        case 0xB544_57FC, 0x9770_7404, 0x5F04_D9AF, 0x72EF_7307, 0xF229_2EAE, 0x0629_665D,
             0x9264_F036, 0x22A8_6EFB, 0x711D_8520, 0x2F52_5EE0, 0x8412_D8D5, 0xC037_6A19, 0xADE3_9424,
             0x2ADB_F5F9, 0x236D_305D, 0x14AD_CE8C:
            setTFMXv1()
        // Z-Out, a player later than 2.2 that turns a voice on at once; and one instrument's sample
        // begins a byte late.
        case 0x8648_904B, 0xB7F7_00B2, 0x0EAB_BC61, 0x999C_8C6B, 0xDB5E_4AFC, 0x9D65_2521, 0xA1DC_3139:
            variant.noDelayedDMAon = true
            let mo = getMacroOffset(0x10)
            if long(mo &+ 4) == 0x0200_884F { setByte(mo &+ 4 &+ 3, 0x4E) }
        // Software Manager's second title, and BiFi Adventure 2's music in the game, whose tracks'
        // mutes are not heeded.
        case 0xA856_6760, 0xAB1A_6C6E:
            variant.noTrackMute = true
        // Ooops Up (Peter Thierolf), whose first two songs' beats a minute want a speed of 5.
        case 0x76F8_AA6E:
            variant.bpmSpeed5 = true
        // Erno's music for the demo Musication Vol. 1, played by TFMX 1.
        case 0x0EED_9C91, 0x1A5D_2B53, 0x22A9_2C26, 0xE60B_ABF2:
            setTFMXv1()
            // Danubius Replay's three guitar samples are brought down to centre on nought.
            if crc == 0x0EED_9C91 {
                for i in UInt32(4) ..< 0x303E4 {
                    let at = offsets.sampleData &+ i
                    setByte(at, byte(at) &- 0x38)
                }
            }
        // Puzzy, whose second song's last step is mended.
        case 0x5FB2_F54E:
            setTFMXv1()
            setByte(offsets.header &+ 0x143, 0x6F)
        // Sledge Hammer One, whose table of songs is mended, and whose first step is left out.
        case 0xCB3C_7113:
            setTFMXv1()
            setByte(offsets.header &+ 0x101, 0x04)
            setByte(offsets.header &+ 0x141, 0x6B)
            setByte(offsets.trackTable, 0xFF)
        // A broken Blade of Destiny title.
        case 0xC83B_701B:
            blacklisted = true
        // Bundesliga Manager Hattrick, whose second song is a piece of its title without the commands
        // that make it one of seven voices: it is made to begin at $1FF, which is no song.
        case 0x3C2E_B450:
            setWord(offsets.header &+ 0x100 &+ 2, 0x1FF)
        default:
            break
        }
    }
}
