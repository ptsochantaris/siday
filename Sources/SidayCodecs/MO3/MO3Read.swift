// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from libopenmpt (`soundlib/Load_mo3.cpp`), Copyright (c) 2004-2026 OpenMPT Project
// Developers and Contributors, used under the BSD 3-Clause licence (see THIRD-PARTY.md), whose MO3
// unpacking is based on UNMO3 by Laurent Clévy, relicensed to BSD with his permission.

import SidayFoundation

extension MO3Song {
    /// What `ReadMO3` keeps of each sample's header until the sample data is read, after the music:
    /// an Ogg sample's shared header may be another sample's, read later.
    struct SampleInfo {
        var flags: UInt16
        var length: UInt32
        var compressedSize: Int32
        var encoderDelay: UInt16
        var sharedHeader: Int16
        var chunk: MO3Bytes? = nil
    }

    /// The most pattern cells a file may ask for. The MO3 format has room for a great many more, which
    /// a few bytes can claim; a real module has a few million at most.
    static let maximumCells = 1 << 23

    /// `ValidateHeader`.
    static func validHeader(_ data: [UInt8]) -> Bool {
        guard data.count >= 8, data[0] == 0x4D, data[1] == 0x4F, data[2] == 0x33 else { return false }
        let musicSize = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        // libopenmpt allows up to 512 MB of music (not samples), being what the LZ packing can reach from
        // a few dozen bytes, and far beyond any real module.
        return musicSize > 422 && musicSize < 0x2000_0000 && data[3] <= 5
    }

    /// `ReadMO3`, as far as the end of the music: everything but the samples' sound.
    static func read(_ data: [UInt8]) throws(TuneError) -> (song: MO3Song, infos: [SampleInfo], sampleStart: Int) {
        guard validHeader(data) else { throw .unsupported("not an MO3 file") }
        var song = MO3Song()
        let version = data[3]
        song.version = version
        let musicSize = UInt32(data[4]) | UInt32(data[5]) << 8 | UInt32(data[6]) << 16 | UInt32(data[7]) << 24
        var packedStart = 8
        var compressedSize: UInt32 = 0
        if version >= 5 {
            // The size of the packed music.
            guard data.count >= 12 else { throw .malformed("the MO3 file is cut short") }
            compressedSize = UInt32(data[8]) | UInt32(data[9]) << 8 | UInt32(data[10]) << 16 | UInt32(data[11]) << 24
            guard UInt64(compressedSize) <= UInt64(data.count - 12) else { throw .malformed("the MO3 file is cut short") }
            packedStart = 12
        }
        let unpacked = MO3Unpack.music(data, from: packedStart, size: musicSize)
        var music = MO3Bytes(unpacked.music)

        song.name = music.nullString()
        song.message = music.nullString()

        // MO3FileHeader, 422 bytes.
        guard var header = music.structure(422) else { throw .malformed("the MO3 file's header is cut short") }
        let numChannels = Int(header.u8())
        let numOrders = Int(header.u16())
        let restartPos = header.u16()
        let numPatterns = Int(header.u16())
        let numTracks = Int(header.u16())
        let numInstruments = Int(header.u16())
        let numSamples = Int(header.u16())
        let defaultSpeed = header.u8()
        let defaultTempo = header.u8()
        let flags = header.u32()
        let globalVol = header.u8()
        song.panSeparation = header.u8()
        let sampleVolume = Int8(bitPattern: header.u8())
        var chnVolume = [UInt8](repeating: 0, count: 64), chnPan = [UInt8](repeating: 0, count: 64)
        for i in 0 ..< 64 { chnVolume[i] = header.u8() }
        for i in 0 ..< 64 { chnPan[i] = header.u8() }
        var sfxMacros = [UInt8](repeating: 0, count: 16)
        for i in 0 ..< 16 { sfxMacros[i] = header.u8() }
        var fixedMacros = [(UInt8, UInt8)](repeating: (0, 0), count: 128)
        for i in 0 ..< 128 { fixedMacros[i] = (header.u8(), header.u8()) }

        guard numChannels > 0, numChannels <= 192, restartPos <= numOrders, numInstruments < 256, numSamples < 4000 else {
            throw .malformed("the MO3 file's header is not one")
        }

        let kind: Kind
        if flags & 0x0100 != 0 { kind = .it } else if flags & 0x0002 != 0 { kind = .s3m } else if flags & 0x0080 != 0 {
            kind = .mod
        } else if flags & 0x0008 != 0 { kind = .mtm } else { kind = .xm }
        song.kind = kind
        song.channels = numChannels
        song.restart = restartPos
        song.speed = defaultSpeed != 0 ? UInt32(defaultSpeed) : 6
        song.tempo = defaultTempo != 0 ? UInt32(defaultTempo) : 125
        song.linearSlides = flags & 0x0001 != 0
        song.amigaLimits = flags & 0x0010 != 0 && kind == .s3m
        song.fastVolumeSlides = flags & 0x0004 != 0 && kind == .s3m
        song.itOldEffects = flags & 0x0800 == 0 && kind == .it
        song.itCompatibleGxx = flags & 0x0400 == 0 && kind == .it
        song.extendedFilterRange = flags & 0x200000 != 0
        song.vblankTiming = flags & 0x80000 != 0
        song.modPlugMode = flags & 0x10000 != 0
        // InitializeGlobals sets the global volume to the full 256 for every format.
        if kind == .it {
            song.globalVolume = UInt32(min(globalVol, 128)) * 2
        } else if kind == .s3m {
            song.globalVolume = UInt32(min(globalVol, 64)) * 4
        }
        if sampleVolume < 0 {
            song.samplePreAmp = UInt32(bitPattern: Int32(sampleVolume) + 52)
        } else {
            song.samplePreAmp = UInt32(exp(Double(sampleVolume) * 3.1 / 20.0)) + 51
        }

        // The header has room for 64 channels, as IT's has.
        for i in 0 ..< min(numChannels, 64) {
            if kind == .it { song.channelVolume[i] = min(chnVolume[i], 64) }
            if kind != .xm {
                if chnPan[i] == 127 {
                    song.channelSurround[i] = true
                } else if chnPan[i] == 255 {
                    song.channelPan[i] = 256
                } else {
                    song.channelPan[i] = UInt16(chnPan[i])
                }
            }
        }

        // The MIDI macros that the header has room for, which are used if any of them is set.
        if sfxMacros.contains(where: { $0 != 0 }) || fixedMacros.contains(where: { $0.1 != 0 }) {
            let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
            func set(_ slot: Int, _ text: [UInt8]) {
                for i in 0 ..< 32 { song.macros[slot * 32 + i] = i < text.count ? text[i] : 0 }
            }
            func h(_ v: UInt8) -> [UInt8] { [hex[Int(v >> 4)], hex[Int(v & 15)]] }
            for i in 0 ..< 16 {
                set(9 + i, sfxMacros[i] != 0 ? Array("F0F0".utf8) + h(sfxMacros[i] &- 1) + [0x7A] : [])
            }
            for i in 0 ..< 128 {
                set(25 + i, fixedMacros[i].1 != 0 ? Array("F0F0".utf8) + h(fixedMacros[i].1 &- 1) + h(fixedMacros[i].0) : [])
            }
        }

        // ReadOrderFromFile, which reads nothing at all if the orders are not all there.
        let hasOrderSeparators = kind != .mod && kind != .xm
        if music.canRead(numOrders) {
            for _ in 0 ..< numOrders {
                let p = UInt16(music.u8())
                if hasOrderSeparators, p == 0xFF {
                    song.orders.append(stopOrder)
                } else if hasOrderSeparators, p == 0xFE {
                    song.orders.append(skipOrder)
                } else {
                    song.orders.append(p)
                }
            }
        }

        // Which track each channel of each pattern plays, each pattern's length, and the tracks.
        var trackChunk = music.chunk(numPatterns * numChannels * 2)
        var patLengthChunk = music.chunk(numPatterns * 2)
        var tracks: [MO3Bytes] = []
        tracks.reserveCapacity(min(numTracks, music.bytesLeft / 4 + 1))
        for _ in 0 ..< numTracks {
            let len = music.u32()
            // A pattern can be at most 65535 rows long, a row at most 31 bytes with its status bytes;
            // with some margin, 2 MB a track.
            guard len < 0x20_0000 else { throw .malformed("one of the MO3 file's tracks is too long") }
            tracks.append(music.chunk(len))
        }

        let noteOffset: UInt8 = kind == .mtm ? 13 + 1 : kind != .it ? 12 + 1 : 1
        var onlyAmigaNotes = true
        var cells = 0
        song.patterns.reserveCapacity(numPatterns)
        for _ in 0 ..< numPatterns {
            let numRows = Int(patLengthChunk.u16())
            // CPatternContainer::Insert makes no pattern of no rows or more than 4096; and then, as in
            // libopenmpt, the next pattern takes the track numbers this one would have had.
            guard numRows > 0, numRows <= 4096 else {
                song.patterns.append(nil)
                continue
            }
            cells += numRows * numChannels
            guard cells <= maximumCells else { throw .unsupported("the MO3 file has more pattern data than siday plays") }
            var pattern = Pattern(rows: numRows, cells: [Cell](repeating: Cell(), count: numRows * numChannels))
            for chn in 0 ..< numChannels {
                let trackIndex = Int(trackChunk.u16())
                guard trackIndex < tracks.count else { continue }
                var track = tracks[trackIndex]
                track.rewind()
                var row = 0
                while row < numRows {
                    let b = track.u8()
                    if b == 0 { break }
                    let numCommands = Int(b & 0x0F), rep = Int(b >> 4)
                    var m = Cell()
                    for _ in 0 ..< numCommands {
                        // ReadArray, which gives zeros unless both bytes are there.
                        var cmd0: UInt8 = 0, cmd1: UInt8 = 0
                        if track.canRead(2) {
                            cmd0 = track.u8()
                            cmd1 = track.u8()
                        }
                        importCommand(&m, cmd0, cmd1, kind: kind, noteOffset: noteOffset, onlyAmigaNotes: &onlyAmigaNotes)
                    }
                    let targetRow = min(row + rep, numRows)
                    while row < targetRow {
                        pattern.cells[row * numChannels + chn] = m
                        row += 1
                    }
                }
            }
            song.patterns.append(pattern)
        }

        if kind == .mod, numChannels == 4, onlyAmigaNotes {
            song.amigaLimits = true
            song.isAmiga = true
        }

        // Instruments. Even in IT's sample mode their headers are there, and are passed over.
        let isSampleMode = kind != .xm && flags & 0x0200 == 0
        song.instrumentMode = !isSampleMode
        for _ in 0 ..< numInstruments {
            var instrument = Instrument()
            if isSampleMode {
                while music.byte() ?? 0 != 0 {}
                if version >= 5 { while music.byte() ?? 0 != 0 {} }
                guard music.skip(826) else { throw .malformed("the MO3 file's instruments are cut short") }
                song.instruments.append(instrument)
                continue
            }
            instrument.exists = true
            instrument.name = music.nullString()
            if version >= 5 { instrument.filename = music.nullString() }
            guard let header = music.structure(826) else { throw .malformed("the MO3 file's instruments are cut short") }
            convertInstrument(header, into: &instrument, kind: kind)
            song.instruments.append(instrument)
        }

        // Samples' headers.
        var infos: [SampleInfo] = []
        let frequencyIsHertz = version >= 5 || flags & 0x0001 == 0
        for _ in 0 ..< numSamples {
            var sample = Sample()
            sample.name = music.nullString()
            if version >= 5 { sample.filename = music.nullString() }
            guard let header = music.structure(41) else { throw .malformed("the MO3 file's samples are cut short") }
            let info = convertSample(header, into: &sample, kind: kind, frequencyIsHertz: frequencyIsHertz)
            var sharedHeader: Int16 = 0
            if version >= 5, info.flags & 0xF000 == 0x7000 { sharedHeader = music.i16() }
            infos.append(SampleInfo(flags: info.flags, length: info.length, compressedSize: info.compressedSize,
                                    encoderDelay: info.encoderDelay, sharedHeader: sharedHeader))
            song.samples.append(sample)
        }

        if kind == .xm {
            // PropagateXMAutoVibrato: each instrument's vibrato goes to every sample it plays.
            for instrument in song.instruments where instrument.exists {
                for s in instrument.keyboard where s != 0 && Int(s) <= song.samples.count {
                    song.samples[Int(s) - 1].vibratoType = instrument.vibrato.type
                    song.samples[Int(s) - 1].vibratoSweep = instrument.vibrato.sweep
                    song.samples[Int(s) - 1].vibratoDepth = instrument.vibrato.depth
                    song.samples[Int(s) - 1].vibratoRate = instrument.vibrato.rate
                }
            }
        }

        // Plug-ins.
        if flags & 0x100000 != 0, music.canRead(1) {
            let pluginFlags = music.u8()
            if pluginFlags & 1 != 0 {
                var list: [UInt32] = []
                for _ in 0 ..< numChannels { list.append(music.u32()) }
                song.channelPlugIns = list
            }
            while music.canRead(1) {
                let plug = Int(music.u8())
                if plug == 0 { break }
                let len = music.u32()
                guard len < musicSize, UInt64(musicSize - len) >= UInt64(music.position) else {
                    throw .malformed("one of the MO3 file's plug-ins is too long")
                }
                let chunk = music.chunk(len)
                if plug <= 250 { song.plugIns.append((plug - 1, Array(chunk.all))) }
            }
        }

        // The chunks after: VERS, PRHI, MIDI, OMPT.
        while music.canRead(8) {
            let id = music.u32()
            let len = music.u32()
            guard len < musicSize, UInt64(musicSize - len) >= UInt64(music.position) else {
                throw .malformed("one of the MO3 file's chunks is too long")
            }
            var chunk = music.chunk(len)
            switch id {
            case UInt32(magic: "VERS"):
                song.hasVersion = true
                switch kind {
                case .it:
                    song.cwtv = chunk.u16()
                    song.cmwt = chunk.u16()
                case .s3m:
                    song.cwtv = chunk.u16()
                case .xm:
                    song.trackerName = Array(chunk.chunk(min(32, chunk.length)).all)
                case .mtm:
                    song.mtmVersion = chunk.u8()
                case .mod:
                    break
                }
            case UInt32(magic: "PRHI"):
                song.rowsPerBeat = UInt32(chunk.u8())
                song.rowsPerMeasure = UInt32(chunk.u8())
            case UInt32(magic: "MIDI"):
                // The whole MIDI setup, which ReadStruct takes only if it is all there; then Sanitize.
                if chunk.canRead(153 * 32) {
                    song.macros = Array(chunk.chunk(153 * 32).all)
                    sanitizeMacros(&song.macros)
                    song.hasMIDIChunk = true
                }
            case UInt32(magic: "OMPT"):
                if chunk.magic("PNAM") {
                    var names = chunk.chunk(chunk.u32())
                    let count = min(names.length / 32, song.patterns.count)
                    song.patternNames = []
                    for _ in 0 ..< count { song.patternNames.append(Array(names.chunk(32).all)) }
                }
                if chunk.magic("CNAM") {
                    var names = chunk.chunk(chunk.u32())
                    let count = min(names.length / 20, numChannels)
                    song.channelNames = []
                    for _ in 0 ..< count { song.channelNames.append(Array(names.chunk(20).all)) }
                }
                song.extensions = Array(chunk.rest)
                if song.cwtv > 0x0889, song.cwtv <= 0x08FF { song.isMPTM = true }
            default:
                break
            }
        }

        if (kind == .it && song.cwtv >= 0x0100 && song.cwtv < 0x0214) || (kind == .s3m && song.cwtv >= 0x3100 && song.cwtv < 0x3214)
            || (kind == .s3m && song.cwtv >= 0x1300 && song.cwtv < 0x1320)
        {
            // libopenmpt ignores the MIDI macros of files made with IT before 2.14 and early ST3s.
            for i in 9 * 32 ..< 153 * 32 { song.macros[i] = 0 }
        }

        // Where the samples' data starts.
        let sampleStart: Int
        if version < 5 {
            // Not known until the music is unpacked to the end.
            guard unpacked.whole else { throw .malformed("the MO3 file's music is cut short") }
            sampleStart = unpacked.end
        } else {
            sampleStart = 12 + Int(compressedSize)
        }
        return (song, infos, sampleStart)
    }

    /// One command of a track, as `ReadMO3` makes it into OpenMPT's.
    private static func importCommand(_ m: inout Cell, _ cmd0: UInt8, _ cmd1: UInt8, kind: Kind, noteOffset: UInt8,
                                      onlyAmigaNotes: inout Bool)
    {
        typealias C = MO3Command
        typealias V = MO3VolumeCommand
        func effect(_ c: UInt8, _ p: UInt8) {
            m.command = c
            m.param = p
        }
        func volume(_ c: UInt8, _ v: UInt8) {
            m.volcmd = c
            m.vol = v
        }
        switch cmd0 {
        case 0x01:
            var note = cmd1
            if note < 120 {
                note += noteOffset
            } else if note == 0xFF {
                note = MO3Note.keyOff
            } else if note == 0xFE {
                note = MO3Note.noteCut
            } else {
                note = MO3Note.fade
            }
            m.note = note
            // ModCommand::IsAmigaNote.
            if MO3Note.isNote(note), note < MO3Note.middleC - 12 || note >= MO3Note.middleC + 24 { onlyAmigaNotes = false }
        case 0x02:
            m.instr = cmd1 &+ 1
        case 0x06:
            // Tone portamento.
            if m.volcmd == V.none, kind == .xm, cmd1 & 0x0F == 0 {
                volume(V.tonePortamento, cmd1 >> 4)
                return
            } else if m.volcmd == V.none, kind == .it {
                let portaVolCmd: [UInt8] = [0x00, 0x01, 0x04, 0x08, 0x10, 0x20, 0x40, 0x60, 0x80, 0xFF]
                if let i = portaVolCmd.firstIndex(of: cmd1) {
                    volume(V.tonePortamento, UInt8(i))
                    return
                }
            }
            effect(C.tonePortamento, cmd1)
        case 0x07:
            if m.volcmd == V.none, cmd1 < 10, kind == .it {
                volume(V.vibratoDepth, cmd1)
            } else {
                effect(C.vibrato, cmd1)
            }
        case 0x0B:
            if m.volcmd == V.none {
                if kind == .it, cmd1 == 0xFF {
                    volume(V.panning, 64)
                    return
                }
                if (kind == .it && cmd1 & 0x03 == 0) || (kind == .xm && cmd1 & 0x0F == 0) {
                    volume(V.panning, cmd1 / 4)
                    return
                }
            }
            effect(C.panning8, cmd1)
        case 0x0F:
            if kind != .mod, m.volcmd == V.none, cmd1 <= 64 {
                volume(V.volume, cmd1)
            } else {
                effect(C.volume, cmd1)
            }
        case 0x10:
            effect(C.patternBreak, cmd1)
            if kind != .it { m.param = (m.param >> 4) &* 10 &+ (m.param & 0x0F) }
        case 0x12:
            effect(cmd1 < 0x20 ? C.speed : C.tempo, cmd1)
        case 0x14, 0x15:
            if cmd1 & 0xF0 != 0 {
                volume(cmd0 == 0x14 ? V.volSlideUp : V.fineVolUp, cmd1 >> 4)
            } else {
                volume(cmd0 == 0x14 ? V.volSlideDown : V.fineVolDown, cmd1 & 0x0F)
            }
        case 0x1B:
            if cmd1 & 0xF0 != 0 { volume(V.panSlideRight, cmd1 >> 4) } else { volume(V.panSlideLeft, cmd1 & 0x0F) }
        case 0x1D:
            effect(C.xFinePortaUpDown, 0x10 | cmd1)
        case 0x1E:
            effect(C.xFinePortaUpDown, 0x20 | cmd1)
        case 0x1F, 0x20:
            volume(cmd0 == 0x1F ? V.vibratoSpeed : V.vibratoDepth, cmd1)
        case 0x22:
            // IT and S3M's volume slide, which with a tone portamento or vibrato before it is K or L.
            if m.command == C.tonePortamento {
                m.command = C.tonePortaVol
            } else if m.command == C.vibrato {
                m.command = C.vibratoVol
            } else {
                m.command = C.volumeSlide
            }
            m.param = cmd1
        case 0x30:
            m.vol = cmd1 % 10
            if cmd1 < 10 {
                m.volcmd = V.fineVolUp
            } else if cmd1 < 20 {
                m.volcmd = V.fineVolDown
            } else if cmd1 < 30 {
                m.volcmd = V.volSlideUp
            } else if cmd1 < 40 {
                m.volcmd = V.volSlideDown
            }
        case 0x31, 0x32:
            volume(cmd0 == 0x31 ? V.portaDown : V.portaUp, cmd1)
        case 0x34:
            if cmd1 >= 223, cmd1 <= 232 { volume(V.offset, cmd1 - 223) }
        default:
            if Int(cmd0) < effectTranslation.count { effect(effectTranslation[Int(cmd0)], cmd1) }
        }
    }

    /// `effTrans`: the MO3 commands that are OpenMPT's commands as they are.
    private static let effectTranslation: [UInt8] = {
        typealias C = MO3Command
        return [
            C.none, C.none, C.none, C.arpeggio,
            C.portamentoUp, C.portamentoDown, C.tonePortamento, C.vibrato,
            C.tonePortaVol, C.vibratoVol, C.tremolo, C.panning8,
            C.offset, C.volumeSlide, C.positionJump, C.volume,
            C.patternBreak, C.modCmdEx, C.tempo, C.tremor,
            C.none, C.none, C.globalVolume, C.globalVolSlide,
            C.keyOff, C.setEnvPosition, C.panningSlide, C.none,
            C.retrig, C.xFinePortaUpDown, C.xFinePortaUpDown, C.none,
            C.none, C.speed, C.volumeSlide, C.portamentoDown,
            C.portamentoUp, C.tremor, C.retrig, C.fineVibrato,
            C.channelVolume, C.channelVolSlide, C.panningSlide, C.s3mCmdEx,
            C.tempo, C.globalVolSlide, C.panbrello, C.midi,
            C.none, C.none, C.none, C.dummy,
            C.none, C.xParam, C.smoothMIDI, C.delayCut,
            C.fineTune, C.fineTuneSmooth,
        ]
    }()

    /// `MO3Envelope::ConvertToMPT`.
    private static func convertEnvelope(_ h: inout MO3Bytes, shift: Int16, kind: Kind) -> Envelope {
        var env = Envelope()
        let flags = h.u8()
        let numNodes = h.u8()
        let sustainStart = h.u8(), sustainEnd = h.u8(), loopStart = h.u8(), loopEnd = h.u8()
        var points: [(Int16, Int16)] = []
        for _ in 0 ..< 25 { points.append((h.i16(), h.i16())) }
        env.enabled = flags & 0x01 != 0
        env.sustain = flags & 0x02 != 0
        env.loop = flags & 0x04 != 0
        env.filter = flags & 0x10 != 0
        env.carry = flags & 0x20 != 0
        env.sustainStart = sustainStart
        env.sustainEnd = kind == .xm ? sustainStart : sustainEnd
        env.loopStart = loopStart
        env.loopEnd = loopEnd
        for ev in 0 ..< Int(min(numNodes, 25)) {
            var tick = UInt16(bitPattern: points[ev].0)
            if ev > 0, tick < env.nodes[ev - 1].tick { tick = env.nodes[ev - 1].tick &+ 1 }
            let value = UInt8(min(max(Int32(points[ev].1 >> shift), 0), 64))
            env.nodes.append(EnvelopeNode(tick: tick, value: value))
        }
        return env
    }

    /// `MO3Instrument::ConvertToMPT`.
    private static func convertInstrument(_ header: MO3Bytes, into ins: inout Instrument, kind: Kind) {
        var h = header
        let flags = h.u32()
        var map = [(UInt16, UInt16)]()
        for _ in 0 ..< 120 { map.append((h.u16(), h.u16())) }
        if kind == .xm {
            for i in 0 ..< 96 { ins.keyboard[i + 12] = map[i].1 &+ 1 }
        } else {
            for i in 0 ..< 120 {
                ins.noteMap[i] = UInt8(truncatingIfNeeded: map[i].0 &+ 1)
                ins.keyboard[i] = map[i].1 &+ 1
            }
        }
        ins.volumeEnvelope = convertEnvelope(&h, shift: 0, kind: kind)
        ins.panEnvelope = convertEnvelope(&h, shift: 0, kind: kind)
        ins.pitchEnvelope = convertEnvelope(&h, shift: 5, kind: kind)
        ins.vibrato = (h.u8(), h.u8(), h.u8(), h.u8())
        ins.fadeOut = UInt32(h.u16())
        let midiChannel = h.u8(), midiBank = h.u8(), midiPatch = h.u8(), midiBend = h.u8()
        let globalVol = h.u8()
        let panning = h.u16()
        let nna = h.u8(), pps = h.u8(), ppc = h.u8(), dct = h.u8(), dca = h.u8()
        let volSwing = h.u16(), panSwing = h.u16()
        let cutoff = h.u8(), resonance = h.u8()

        if midiChannel >= 128 {
            ins.plugIn = UInt32(midiChannel) - 127
        } else if midiChannel < 17, flags & 0x01 != 0 {
            // XM, or IT from a recent encoder.
            ins.midiChannel = midiChannel + 1
        } else if midiChannel > 0, midiChannel < 17 {
            // IT from MO3 before 2.4.1, where channel 0 is "no channel".
            ins.midiChannel = midiChannel + 1
        }
        if ins.midiChannel != 0 {
            if kind == .xm {
                ins.midiProgram = midiPatch &+ 1
            } else {
                if midiBank < 128 { ins.midiBank = UInt16(midiBank) + 1 }
                if midiPatch < 128 { ins.midiProgram = midiPatch + 1 }
            }
            ins.midiPitchWheelDepth = Int8(bitPattern: midiBend)
        }
        if kind == .it { ins.globalVolume = UInt32(min(globalVol, 128) / 2) }
        if panning <= 256 {
            ins.pan = UInt32(panning)
            ins.setPan = true
        }
        ins.nna = nna
        ins.pps = Int8(bitPattern: pps)
        ins.ppc = ppc
        ins.dct = dct
        ins.dna = dca
        ins.volSwing = UInt8(min(volSwing, 100))
        ins.panSwing = UInt8(min(panSwing, 256) / 4)
        ins.cutoff = min(cutoff & 0x7F, 0x7F) | (cutoff & 0x80)
        ins.resonance = min(resonance & 0x7F, 0x7F) | (resonance & 0x80)
    }

    /// `MO3Sample::ConvertToMPT`, and what is kept of the header for reading the sound.
    private static func convertSample(_ header: MO3Bytes, into s: inout Sample, kind: Kind, frequencyIsHertz: Bool)
        -> (flags: UInt16, length: UInt32, compressedSize: Int32, encoderDelay: UInt16)
    {
        var h = header
        let freqFinetune = h.u32()
        let transpose = Int8(bitPattern: h.u8())
        let defaultVolume = h.u8()
        let panning = h.u16()
        let length = h.u32(), loopStart = h.u32(), loopEnd = h.u32()
        let flags = h.u16()
        let vibType = h.u8(), vibSweep = h.u8(), vibDepth = h.u8(), vibRate = h.u8()
        let globalVol = h.u8()
        let sustainStart = h.u32(), sustainEnd = h.u32()
        let compressedSize = h.i32()
        let encoderDelay = h.u16()

        if kind == .it || kind == .s3m {
            if frequencyIsHertz {
                s.c5Speed = freqFinetune
            } else {
                let speed = (8363.0 * pow(2.0, Double(Int32(bitPattern: freqFinetune &+ 1408)) / 1536.0)).rounded()
                s.c5Speed = speed >= 4294967295.0 ? .max : speed <= 0 ? 0 : UInt32(speed)
            }
        } else {
            s.fineTune = Int8(truncatingIfNeeded: freqFinetune)
            if kind != .mtm { s.fineTune = Int8(truncatingIfNeeded: Int(s.fineTune) - 128) }
            s.relativeTone = transpose
        }
        s.volume = UInt16(min(defaultVolume, 64)) * 4
        if panning <= 256 {
            s.pan = panning
            s.setPan = true
        }
        s.length = length
        s.loopStart = loopStart
        s.loopEnd = loopEnd
        s.loop = flags & 0x10 != 0
        s.pingPong = flags & 0x20 != 0
        s.sustain = flags & 0x100 != 0
        s.sustainPingPong = flags & 0x200 != 0
        // AutoVibratoIT2XM.
        let it2xm: [UInt8] = [0, 3, 1, 4, 2, 0, 0, 0]
        s.vibratoType = it2xm[Int(vibType & 7)]
        s.vibratoSweep = vibSweep
        s.vibratoDepth = vibDepth
        s.vibratoRate = vibRate
        if kind == .it { s.globalVolume = UInt16(min(globalVol, 64)) }
        s.xmInstrument = globalVol
        s.sustainStart = sustainStart
        s.sustainEnd = sustainEnd
        return (flags, length, compressedSize, encoderDelay)
    }

    /// `MIDIMacroConfig::Sanitize`: each macro ends at its first 0, with nothing after it, and what
    /// is not printable is a space.
    static func sanitizeMacros(_ macros: inout [UInt8]) {
        for slot in 0 ..< 153 {
            let base = slot * 32
            macros[base + 31] = 0
            var length = 0
            while length < 32, macros[base + length] != 0 { length += 1 }
            for i in length ..< 32 { macros[base + i] = 0 }
            for i in 0 ..< length where macros[base + i] < 32 || macros[base + i] >= 127 { macros[base + i] = 0x20 }
        }
    }
}
