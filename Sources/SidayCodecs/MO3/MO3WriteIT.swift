// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from libopenmpt (`soundlib/Load_it.cpp`, `ITTools.cpp`, `Tables.cpp`), Copyright (c)
// 2004-2026 OpenMPT Project Developers and Contributors, used under the BSD 3-Clause licence (see
// THIRD-PARTY.md).

import SidayFoundation

extension MO3Song {
    /// The tracker version an IT file is written as having been made with, and the field after it:
    /// what the MO3 file kept (VERS); else, for a file it says ModPlug Tracker made, the signs ModPlug
    /// Tracker 1.09 to 1.16 left in its IT files (2.17, compatible with 2.00, and no channel of the
    /// 64 it does not use left at its default); else Impulse Tracker 2.14's.
    var itVersion: (cwtv: UInt16, cmwt: UInt16, modPlug: Bool) {
        if hasVersion { return (cwtv, cmwt, false) }
        if modPlugMode { return (0x0217, 0x0200, true) }
        return (0x0214, 0x0214, false)
    }

    /// `CSoundFile::SaveIT`, for IT and MPTM: the header, orders and offsets; OpenMPT's MIDI macros,
    /// pattern and channel names and plug-ins; the message; instruments, sample headers, patterns and
    /// sample data; and then OpenMPT's instrument and song extensions as the MO3 file kept them.
    func writeIT(_ notes: inout [String]) -> [UInt8] {
        let version = itVersion
        let isOpenMPT = version.cwtv & 0xF000 == 0x5000
        let maxChannels = min(isMPTM ? 127 : 64, channels)
        var w = MO3Writer()

        // Orders as the MO3 file has them, which ends them with "---" as IT's own files do.
        var orderBytes: [UInt8] = orders.map { $0 == Self.stopOrder ? 0xFF : $0 == Self.skipOrder || $0 > 0xFF ? 0xFE : UInt8($0) }
        if orderBytes.last != 0xFF { orderBytes.append(0xFF) }
        while orderBytes.count < 2 { orderBytes.append(0xFF) }
        if orderBytes.count > 0xFFFF { orderBytes = Array(orderBytes.prefix(0xFFFE)) + [0xFF] }

        let insnum = instrumentMode ? instruments.count : 0
        let smpnum = samples.count
        var patnum = 0
        for (i, p) in patterns.enumerated() where p != nil { patnum = i + 1 }

        var flags: UInt16 = 0x01 | 0x40
        var special: UInt16 = 0x02 | 0x04
        if insnum > 0 { flags |= 0x04 }
        if linearSlides { flags |= 0x08 }
        if itOldEffects { flags |= 0x10 }
        if itCompatibleGxx { flags |= 0x20 }
        if extendedFilterRange { flags |= 0x1000 }
        let embedMacros = macros != Self.defaultMacros
        if embedMacros {
            flags |= 0x80
            special |= 0x08
        }
        // IT has one pitch wheel depth for all its instruments, which MO3 gives to those that play on
        // MIDI channels (libopenmpt leaves the others at 2); else, as OpenMPT, the first that is not 0.
        var pwd: UInt8 = 0
        if let midi = instruments.prefix(insnum).first(where: { $0.exists && $0.midiChannel != 0 }) {
            pwd = UInt8(truncatingIfNeeded: abs(Int(midi.midiPitchWheelDepth)))
        } else { for i in 0 ..< insnum where instruments[i].exists && instruments[i].midiPitchWheelDepth != 0 {
            pwd = UInt8(truncatingIfNeeded: abs(Int(instruments[i].midiPitchWheelDepth)))
            break
        } }

        // OpenMPT's extras: pattern names, channel names, plug-ins.
        var extra = MO3Writer()
        if embedMacros { extra.append(macros) }
        let named = patternNames.lastIndex(where: { name in name.contains { $0 != 0 } }).map { $0 + 1 } ?? 0
        if named > 0 {
            extra.text("PNAM")
            extra.u32(UInt32(named * 32))
            for i in 0 ..< named { extra.field(patternNames[i], 32) }
        }
        let namedChannels = channelNames.lastIndex(where: { name in name.contains { $0 != 0 } }).map { $0 + 1 } ?? 0
        if namedChannels > 0 {
            extra.text("CNAM")
            extra.u32(UInt32(namedChannels * 20))
            for i in 0 ..< namedChannels { extra.field(channelNames[i], 20) }
        }
        writePlugIns(&extra)

        // Header.
        w.text("IMPM")
        w.field(name, 26)
        w.u8(UInt8(clamping: rowsPerBeat ?? 4))
        w.u8(UInt8(clamping: rowsPerMeasure ?? 16))
        w.u16(UInt16(orderBytes.count))
        w.u16(UInt16(insnum))
        w.u16(UInt16(smpnum))
        w.u16(UInt16(patnum))
        w.u16(version.cwtv)
        w.u16(version.cmwt)
        w.u16(flags)
        let specialAt = w.count
        w.u16(special)
        w.u8(UInt8(globalVolume / 2))
        w.u8(UInt8(min(samplePreAmp, 128)))
        w.u8(UInt8(clamping: speed))
        w.u8(UInt8(clamping: tempo))
        w.u8(panSeparation)
        w.u8(pwd)
        let messageLengthAt = w.count
        w.u16(0)
        w.u32(0)
        // OpenMPT says it is itself, unless the file was a compatibility export (no extensions).
        if isOpenMPT, !extensions.isEmpty { w.text("OMPT") } else { w.u32(0) }
        for i in 0 ..< 64 {
            if i < min(channels, 64) {
                w.u8(channelSurround[i] ? 100 : UInt8(channelPan[i] >> 2))
            } else {
                w.u8(version.modPlug ? 0xFF : 0xA0)
            }
        }
        for i in 0 ..< 64 { w.u8(i < min(channels, 64) ? channelVolume[i] : 64) }

        w.append(orderBytes)
        let pointersAt = w.count
        w.zeros((insnum + smpnum + patnum) * 4)
        // An edit history of no entries.
        w.u16(0)
        w.append(extra.bytes)

        if !message.isEmpty {
            let length = min(message.count + 1, 0xFFFF)
            w.put16(w.readU16(at: specialAt) | 0x01, at: specialAt)
            w.put16(UInt16(length), at: messageLengthAt)
            w.put32(UInt32(w.count), at: messageLengthAt + 2)
            w.append(message.prefix(length - 1))
            w.u8(0)
        }

        // Instruments.
        for i in 0 ..< insnum {
            w.put32(UInt32(w.count), at: pointersAt + i * 4)
            writeITInstrument(instruments[i], &w, trkvers: isOpenMPT ? version.cwtv : 0)
        }
        // Sample headers, filled in when the data's place is known.
        var sampleHeadersAt: [Int] = []
        for i in 0 ..< smpnum {
            w.put32(UInt32(w.count), at: pointersAt + (insnum + i) * 4)
            sampleHeadersAt.append(w.count)
            w.zeros(80)
        }
        // Patterns.
        var cutPatterns = 0
        for p in 0 ..< patnum {
            guard let pattern = patterns[p] else { continue }
            if pattern.rows == 64, pattern.cells.allSatisfy({ $0.isEmpty }) { continue }
            w.put32(UInt32(w.count), at: pointersAt + (insnum + smpnum + p) * 4)
            if !writeITPattern(pattern, &w, maxChannels: maxChannels) { cutPatterns += 1 }
        }
        if cutPatterns > 0 {
            notes.append(Shortfall.some(cutPatterns, one: "patterns has more in it than an IT pattern holds, and is cut short.",
                                        many: "patterns have more in them than an IT pattern holds, and are cut short."))
        }
        // Sample data.
        for i in 0 ..< smpnum {
            writeITSample(samples[i], &w, headerAt: sampleHeadersAt[i])
        }
        // OpenMPT's extensions, as the file kept them; and for an MPTM, where its own data begins.
        if !extensions.isEmpty {
            let start = w.count
            w.append(extensions)
            if isMPTM {
                if let offset = mptmDataOffset(extensions) {
                    w.u32(UInt32(start + offset))
                } else {
                    notes.append("Its OpenMPT data is not where OpenMPT keeps it, and is left out.")
                }
            }
        }
        return w.bytes
    }

    /// Where, in the OMPT chunk's extensions, the MPTM data ("228") starts, read as libopenmpt reads
    /// what comes before it: the instrument extensions ("XTPM", each field a code, a size, and that many
    /// bytes for each instrument) and the song extensions ("STPM", each a code, a size and the bytes).
    func mptmDataOffset(_ ext: [UInt8]) -> Int? {
        var r = MO3Bytes(ext)
        let mpts = UInt32(magic: "STPM"), mptm = UInt32(0x0438_3232)
        func ascii(_ code: UInt32) -> Bool { code & 0x8080_8080 == 0 && code & 0x6060_6060 != 0 }
        if instrumentMode, !instruments.isEmpty, r.magic("XTPM") {
            while r.canRead(6) {
                let code = r.u32()
                if code == mpts || code == mptm || !ascii(code) {
                    r.pos -= 4
                    break
                }
                let size = Int(r.u16())
                r.skip(size * instruments.count)
            }
        }
        if r.magic("STPM") {
            while r.canRead(7) {
                let code = r.u32()
                let size = Int(r.u16())
                if code == mptm {
                    r.pos -= 6
                    break
                }
                if !ascii(code) || !r.canRead(size) { return nil }
                r.skip(size)
            }
        }
        guard r.canRead(4), r.data[r.pos] == 0x32, r.data[r.pos + 1] == 0x32, r.data[r.pos + 2] == 0x38 else { return nil }
        return r.pos
    }

    /// The FXnn chunks of the plug-ins, as the MO3 file kept their contents, and CHFX for which
    /// plug-in each channel goes through (SaveMixPlugins).
    func writePlugIns(_ w: inout MO3Writer) {
        for plugIn in plugIns {
            let i = plugIn.index
            w.u8(0x46)
            w.u8(i >= 100 ? 0x30 + UInt8(i / 100) : 0x58)
            w.u8(0x30 + UInt8((i / 10) % 10))
            w.u8(0x30 + UInt8(i % 10))
            w.u32(UInt32(plugIn.data.count))
            w.append(plugIn.data)
        }
        if let list = channelPlugIns {
            let count = (list.prefix(channels).lastIndex { $0 != 0 }).map { $0 + 1 } ?? 0
            if count > 0 {
                w.text("CHFX")
                w.u32(UInt32(count * 4))
                for c in 0 ..< count { w.u32(list[c]) }
            }
        }
    }

    /// `ITInstrument::ConvertToIT` and `ITInstrumentEx::ConvertToIT`.
    private func writeITInstrument(_ ins: Instrument, _ w: inout MO3Writer, trkvers: UInt16) {
        w.text("IMPI")
        w.field(ins.filename, 13, terminated: true)
        w.u8(ins.nna)
        w.u8(ins.dct)
        w.u8(ins.dna)
        w.u16(UInt16(min(ins.fadeOut >> 5, 256)))
        w.i8(ins.pps)
        w.u8(ins.ppc)
        w.u8(UInt8(min(ins.globalVolume * 2, 128)))
        w.u8(UInt8(min(ins.pan / 4, 64)) | (ins.setPan ? 0 : 0x80))
        w.u8(min(ins.volSwing, 100))
        w.u8(min(ins.panSwing, 64))
        w.u16(trkvers)
        var seen = [Bool](repeating: false, count: samples.count)
        var nos = 0
        var needsHigh = false
        for k in ins.keyboard where k != 0 && Int(k) <= samples.count && !seen[Int(k) - 1] {
            seen[Int(k) - 1] = true
            nos += 1
        }
        for k in ins.keyboard where k >= 256 && k < 4000 { needsHigh = true }
        w.u8(UInt8(truncatingIfNeeded: nos))
        w.u8(0)
        w.field(ins.name, 26)
        w.u8(ins.cutoff)
        w.u8(ins.resonance)
        if ins.midiChannel != 0 || ins.plugIn == 0 || ins.plugIn > 127 {
            w.u8(ins.midiChannel)
        } else {
            w.u8(UInt8(ins.plugIn) + 128)
        }
        w.u8(ins.midiProgram > 0 ? ins.midiProgram - 1 : 0xFF)
        if ins.midiBank > 0 {
            w.u8(UInt8((ins.midiBank - 1) & 0x7F))
            w.u8(UInt8(truncatingIfNeeded: (ins.midiBank - 1) >> 7))
        } else {
            w.u8(0xFF)
            w.u8(0xFF)
        }
        for i in 0 ..< 120 {
            let n = ins.noteMap[i]
            w.u8(n >= 1 && n <= 120 ? n - 1 : UInt8(i))
            let k = ins.keyboard[i]
            w.u8(k < 4000 ? UInt8(truncatingIfNeeded: k) : 0)
        }
        writeITEnvelope(ins.volumeEnvelope, &w, offset: 0, empty: 64)
        writeITEnvelope(ins.panEnvelope, &w, offset: 32, empty: 32)
        writeITEnvelope(ins.pitchEnvelope, &w, offset: 32, empty: 32, filter: ins.pitchEnvelope.filter)
        if needsHigh {
            w.text("XTPM")
            for i in 0 ..< 120 { w.u8(ins.keyboard[i] < 4000 ? UInt8(ins.keyboard[i] >> 8) : 0) }
        } else {
            w.zeros(4)
        }
    }

    /// `ITEnvelope::ConvertToIT`.
    private func writeITEnvelope(_ env: Envelope, _ w: inout MO3Writer, offset: UInt8, empty: UInt8, filter: Bool = false) {
        var flags: UInt8 = 0
        if env.enabled { flags |= 0x01 }
        if env.loop { flags |= 0x02 }
        if env.sustain { flags |= 0x04 }
        if env.carry { flags |= 0x08 }
        if filter { flags |= 0x80 }
        w.u8(flags)
        let count = min(env.nodes.count, 25)
        // OpenMPT gives an envelope of no points two, so that Impulse Tracker can edit it; one that is
        // not used is left with none, as the MO3 file has it.
        let invent = env.nodes.isEmpty && (env.enabled || env.loop || env.sustain || env.carry)
        w.u8(invent ? 2 : UInt8(count))
        w.u8(env.loopStart)
        w.u8(env.loopEnd)
        w.u8(env.sustainStart)
        w.u8(env.sustainEnd)
        if invent {
            // So that an envelope there is none of can still be edited in Impulse Tracker.
            let v = UInt8(bitPattern: Int8(truncatingIfNeeded: Int(empty) - Int(offset)))
            w.u8(v); w.u16(0)
            w.u8(v); w.u16(10)
            w.zeros(23 * 3)
        } else {
            for i in 0 ..< 25 {
                if i < count {
                    w.u8(UInt8(truncatingIfNeeded: Int(Int8(bitPattern: env.nodes[i].value)) - Int(offset)))
                    w.u16(env.nodes[i].tick)
                } else {
                    w.zeros(3)
                }
            }
        }
        w.u8(0)
    }

    /// A pattern packed as IT packs it, each channel's last mask, note, instrument, volume and command
    /// remembered. False if it had to be cut, IT's patterns holding at most 65535 bytes.
    private func writeITPattern(_ pattern: Pattern, _ w: inout MO3Writer, maxChannels: Int) -> Bool {
        let headerAt = w.count
        w.u16(0)
        w.u16(UInt16(pattern.rows))
        w.u32(0)
        struct State { var note: UInt8 = 0, instr: UInt8 = 0, vol: UInt8 = 0, command: UInt8 = 0, param: UInt8 = 0, valid: UInt8 = 0, mask: UInt8 = 0xFF }
        var states = [State](repeating: State(), count: maxChannels)
        var buf: [UInt8] = []
        buf.reserveCapacity(7 * maxChannels + 1)
        var writeSize = 0
        var whole = true
        for row in 0 ..< pattern.rows {
            buf.removeAll(keepingCapacity: true)
            for ch in 0 ..< maxChannels {
                var m = pattern.cells[row * channels + ch]
                if m.command == MO3Command.volume, m.volcmd != MO3VolumeCommand.none { m = Self.volumeToVolumeColumn(m) }
                if m.note == MO3Note.pc || m.note == MO3Note.pcs { continue }
                var b: UInt8 = 1
                var vol: UInt8 = 0xFF
                var note = m.note
                if note >= 1, note <= 120 {
                    note = m.note - 1
                } else if note == MO3Note.fade {
                    note = isMPTM ? 0xFD : 0xF6
                } else if note == MO3Note.noteCut {
                    note = 0xFE
                } else if note == MO3Note.keyOff {
                    note = 0xFF
                } else {
                    b = 0
                }
                if m.instr != 0 { b |= 2 }
                if m.volcmd != MO3VolumeCommand.none {
                    typealias V = MO3VolumeCommand
                    vol = min(m.vol, 9)
                    switch m.volcmd {
                    case V.volume: vol = min(m.vol, 64)
                    case V.panning: vol = min(m.vol, 64) + 128
                    case V.volSlideUp: vol += 85
                    case V.volSlideDown: vol += 95
                    case V.fineVolUp: vol += 65
                    case V.fineVolDown: vol += 75
                    case V.vibratoDepth: vol += 203
                    case V.tonePortamento: vol += 193
                    case V.portaDown: vol += 105
                    case V.portaUp: vol += 115
                    case V.vibratoSpeed: vol = 203
                    case V.offset: vol += 223
                    default: vol = 0xFF
                    }
                }
                if vol != 0xFF { b |= 4 }
                var command: UInt8 = 0, param: UInt8 = 0
                if m.command == MO3Command.volume, vol == 0xFF {
                    vol = min(m.param, 64)
                    b |= 4
                } else if m.command != MO3Command.none {
                    (command, param) = s3mSaveConvert(m.command, m.param, toIT: true, extended: true)
                    if command != 0 { b |= 8 }
                }
                guard b != 0 else { continue }
                var s = states[ch]
                if b & 1 != 0 {
                    if note == s.note, s.valid & 1 != 0 { b = (b & ~1) | 0x10 } else { s.note = note; s.valid |= 1 }
                }
                if b & 2 != 0 {
                    if m.instr == s.instr, s.valid & 2 != 0 { b = (b & ~2) | 0x20 } else { s.instr = m.instr; s.valid |= 2 }
                }
                if b & 4 != 0 {
                    if vol == s.vol, s.valid & 4 != 0 { b = (b & ~4) | 0x40 } else { s.vol = vol; s.valid |= 4 }
                }
                if b & 8 != 0 {
                    if command == s.command, param == s.param, s.valid & 8 != 0 {
                        b = (b & ~8) | 0x80
                    } else {
                        s.command = command
                        s.param = param
                        s.valid |= 8
                    }
                }
                if b != s.mask {
                    s.mask = b
                    buf.append(UInt8(ch + 1) | 0x80)
                    buf.append(b)
                } else {
                    buf.append(UInt8(ch + 1))
                }
                states[ch] = s
                if b & 1 != 0 { buf.append(note) }
                if b & 2 != 0 { buf.append(m.instr) }
                if b & 4 != 0 { buf.append(vol) }
                if b & 8 != 0 {
                    buf.append(command)
                    buf.append(param)
                }
            }
            buf.append(0)
            if writeSize > 0xFFFF - buf.count {
                whole = false
                break
            }
            writeSize += buf.count
            w.append(buf)
        }
        w.put16(UInt16(writeSize), at: headerAt)
        return whole
    }

    /// A cell with a volume command (Cxx in MOD terms) beside a volume-column command, which IT
    /// cannot hold: libopenmpt reads an MO3 track's commands one after another and gives the volume
    /// column to the first that fits there, which for an IT file's G or H (kept in MO3 before the
    /// volume) puts them in the volume column and the volume in the effect column, where the IT file
    /// had them the other way about. They are put back so.
    static func volumeToVolumeColumn(_ cell: Cell) -> Cell {
        typealias V = MO3VolumeCommand
        var m = cell
        let portaVolCmd: [UInt8] = [0x00, 0x01, 0x04, 0x08, 0x10, 0x20, 0x40, 0x60, 0x80, 0xFF]
        switch m.volcmd {
        case V.tonePortamento where m.vol < 10:
            m.command = MO3Command.tonePortamento
            m.param = portaVolCmd[Int(m.vol)]
        case V.vibratoDepth:
            m.command = MO3Command.vibrato
            m.param = m.vol
        case V.panning:
            m.command = MO3Command.panning8
            m.param = m.vol >= 64 ? 0xFF : m.vol * 4
        default:
            return cell
        }
        m.volcmd = V.volume
        m.vol = cell.param
        return m
    }

    /// `ITSample::ConvertToIT`, and the sample's data after the patterns, the second channel of a
    /// stereo sample after the first.
    private func writeITSample(_ s: Sample, _ w: inout MO3Writer, headerAt: Int) {
        var h = MO3Writer()
        h.text("IMPS")
        h.field(s.filename, 13, terminated: true)
        h.u8(UInt8(truncatingIfNeeded: s.globalVolume))
        let hasData = s.hasData
        var flags: UInt8 = 0
        var cvt: UInt8 = 0
        if s.adlib != nil {
            flags = 0x01
            cvt = 0x40
        } else {
            if hasData { flags |= 0x01 }
            if s.loop { flags |= 0x10 }
            if s.sustain { flags |= 0x20 }
            if s.pingPong { flags |= 0x40 }
            if s.sustainPingPong { flags |= 0x80 }
            if hasData {
                if s.isStereo { flags |= 0x04 }
                if s.is16Bit { flags |= 0x02 }
                cvt = 0x01
            }
        }
        h.u8(flags)
        h.u8(UInt8(truncatingIfNeeded: s.volume / 4))
        h.field(s.name, 26)
        h.u8(cvt)
        h.u8(UInt8(truncatingIfNeeded: s.pan / 4) | (s.setPan ? 0x80 : 0))
        let length: UInt32 = s.adlib != nil ? 12 : hasData ? s.length : 0
        h.u32(length)
        h.u32(s.loopStart)
        h.u32(s.loopEnd)
        h.u32(s.c5Speed != 0 ? s.c5Speed : 8363)
        h.u32(s.sustainStart)
        h.u32(s.sustainEnd)
        h.u32(UInt32(w.count))
        // Auto-vibrato: rate, depth, sweep, type (AutoVibratoXM2IT).
        let xm2it: [UInt8] = [0, 2, 4, 1, 3, 0, 0, 0]
        // OpenMPT's saver keeps these to IT's own ranges (64 and 32); the file holds more, which the
        // MO3 may have kept, and libopenmpt reads up to 255 and 127.
        h.u8(s.vibratoRate)
        h.u8(min(s.vibratoDepth, 127))
        h.u8(s.vibratoSweep)
        h.u8(xm2it[Int(s.vibratoType & 7)])
        w.bytes.replaceSubrange(headerAt ..< headerAt + 80, with: h.bytes)
        if let patch = s.adlib {
            w.append(patch)
        } else if hasData {
            s.writeSplit(&w, frames: Int(s.length))
        }
    }
}

extension MO3Song.Sample {
    /// The sound, signed and little-endian, the second channel after the first (`stereoSplit`).
    func writeSplit(_ w: inout MO3Writer, frames: Int) {
        let channels = isStereo ? 2 : 1
        for c in 0 ..< channels {
            if let d = data16 {
                var k = c
                for _ in 0 ..< frames {
                    let v = UInt16(bitPattern: d[k])
                    w.bytes.append(UInt8(truncatingIfNeeded: v))
                    w.bytes.append(UInt8(truncatingIfNeeded: v >> 8))
                    k += channels
                }
            } else if let d = data8 {
                var k = c
                for _ in 0 ..< frames {
                    w.bytes.append(UInt8(bitPattern: d[k]))
                    k += channels
                }
            }
        }
    }
}

extension MO3Writer {
    func readU16(at offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
}
