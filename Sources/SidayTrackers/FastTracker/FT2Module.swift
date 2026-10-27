// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ft2play, Copyright (c) Olav Sørensen, used under the BSD 3-Clause licence
// (see THIRD-PARTY.md).

import SidayFoundation

/// A module as FastTracker 2 holds one: an XM file, or a MOD file of up to 32 channels, which
/// FastTracker reads into the same shape.
final class FT2Module {
    private(set) var song = FT2Song()
    private(set) var title = ""
    /// True for a song whose slides are even in pitch; false for one that slides as the Amiga did.
    private(set) var linearFrqTab = false
    private(set) var patt = [[FT2Note]?](repeating: nil, count: 256)
    private(set) var pattLens = [UInt16](repeating: 64, count: 256)
    /// Instrument 0 stands in for one that is not there.
    private(set) var instr = [FT2Instrument?](repeating: nil, count: 129)
    /// True for a MOD file.
    private(set) var isMOD = false
    /// For a module of another tracker's (see `ForeignModule`): what kind of file it was, what
    /// made it, and how loud that kind is to be played.
    private(set) var foreign: (format: String, tracker: String, loudness: Float)?
    /// Where each channel is between the speakers, from 0 on the left to 255 on the right, in a
    /// module whose channels have places. Empty for FastTracker's own, where it is each sample
    /// that has one.
    private(set) var channelPanning: [UInt8] = []
    /// True for a module in which setting the speed puts the tempo back to 125, and setting the
    /// tempo puts the speed back to 6: MultiTracker's way, and no other tracker's.
    private(set) var speedAndTempoUndoEachOther = false
    /// True for a module whose vibrato is a quarter as deep as FastTracker's: see `ForeignModule`.
    private(set) var vibratoIsAQuarterAsDeep = false
    /// True for a module of DIGI Booster's: see `ForeignModule.playsAsDigiBooster`.
    private(set) var playsAsDigiBooster = false
    /// True unless the file is an XM file that gives itself away as some other tracker's than
    /// FastTracker 2: by what it says made it, or, where it says FastTracker, as ModPlug Tracker's
    /// files do, by a song name padded out with nothing in place of spaces or by what ModPlug
    /// Tracker writes after all that FastTracker reads. (These are the first of the signs OpenMPT
    /// goes by. FastTracker lets any letter be typed for a command, and a letter it has no command
    /// for in a file of its own is nothing: a mark for a demo to keep time by, as often as not.)
    private(set) var madeByFastTracker = true
    /// What the command Z does to a channel's filter in a file that a later tracker made, by its
    /// value: 0 if it sets where the filter closes and 1 if it sets how it rings, and the value
    /// it sets, or nil for the command's own; nil for a value that does neither. They are the
    /// file's macros if it has any, and otherwise the ones ModPlug Tracker began with: values to
    /// 7F close the filter, and 80 to 8F make it ring, in sixteen steps.
    private(set) var filterMacros: [(sets: UInt8, value: UInt8?)?] = FT2Module.usualMacros()

    private static func usualMacros() -> [(sets: UInt8, value: UInt8?)?] {
        var macros = [(sets: UInt8, value: UInt8?)?](repeating: nil, count: 256)
        for value in 0 ..< 0x80 { macros[value] = (0, nil) }
        for step in 0 ..< 16 { macros[0x80 + step] = (1, UInt8(step * 8)) }
        return macros
    }
    /// What the file asks for that is not played as it asks: see `TuneInfo.shortfalls`. An XM file
    /// from a later tracker may have what FastTracker never had, and is read as FastTracker reads it.
    private(set) var shortfalls: [String] = []
    /// What an XM file of ModPlug Tracker's or OpenMPT's has to be heard through besides its
    /// samples, if it has any: plug-ins that are OpenMPT's own, with something sent through them
    /// (see `ModPlugSound`).
    private(set) var sound: ModPlugSound?
    /// True for a file that a later tracker made whose patterns put a channel in ModPlug's own
    /// reverb (X99): see `ModPlugReverb`.
    private(set) var reverbs = false
    /// And the plug-in each instrument plays through, counted from 1, by the instrument's number;
    /// nought for none.
    private(set) var instrumentPlugIns = [Int](repeating: 0, count: 256)
    /// And how each instrument's notes are read between a sample's points, by OpenMPT's number for
    /// the way, where the file says (see `IT2Resampling`).
    private(set) var instrumentResamplings = [UInt8](repeating: IT2Resampling.own, count: 256)
    /// For an XM file that ModPlug Tracker or OpenMPT made: how OpenMPT adds its channels up (its
    /// "mix levels", by their numbers), the song's pre-amp, and how many channels OpenMPT takes it
    /// to have. Nil for any other file, which is played as loud as FastTracker plays it.
    private(set) var openMPTMix: (mode: Int, preAmp: Int, channels: Int)?
    /// True for an XM file of a tracker whose arpeggio went as the other trackers' did, and not as
    /// FastTracker's, as OpenMPT reckons it: MadTracker 2, Skale Tracker, ModPlug Tracker up to
    /// 1.16, and OpenMPT itself in a file it saved not to be played as FastTracker plays it (see
    /// `keepsFastTrackersWay`). See `FT2Player.arpeggiatesAsOtherTrackers`.
    private(set) var arpeggioOfOtherTrackers = false
    /// True for an XM file in which OpenMPT plays the commands ModPlug Tracker added under X:
    /// those of ModPlug Tracker up to 1.16, and of OpenMPT itself that it did not save to be played
    /// strictly as FastTracker plays it (see `keepsFastTrackersWay`). See `FT2Replayer.xFinePorta`.
    private(set) var playsModPlugXCommands = false
    /// And true if, in such a file, a note's sample or the volume column putting a channel
    /// somewhere takes it out of surround, as 8xx always does (OpenMPT's 10th way).
    private(set) var panningEndsSurround = false
    /// True for an XM file in which OpenMPT keeps the whole of a sample's finetune, where
    /// FastTracker drops its lowest three bits (OpenMPT's 76th way, which it had from 1.22.07.19).
    /// See `FT2Player.notePeriod`.
    private(set) var fineTunesFully = false
    /// How the pattern loops (E6x) of an XM file go where the tracker that made it had them go
    /// otherwise than FastTracker 2, as OpenMPT plays such a file (see `keepsFastTrackersWay`):
    /// a loop is not begun in a channel while another channel's is going (where OpenMPT has not
    /// its 17th way); a loop that goes back on a row is not cut short by a jump or a break on that
    /// row (its 68th); and a loop leaves nothing behind it for the next pattern (its 63rd). See
    /// `FT2Player.oneLoopAtATime`, `FT2Player.loopsBeforeJumps` and `FT2Player.loopsLeaveNothingBehind`.
    private(set) var oneLoopAtATime = false
    private(set) var loopsBeforeJumps = false
    private(set) var loopsLeaveNothingBehind = false
    /// True for an XM file of ModPlug Tracker's or OpenMPT's: a place in its list of patterns that
    /// names a pattern the file has not got is passed over, as OpenMPT passes over one, where
    /// FastTracker plays an empty pattern of 64 rows. See `FT2Player.passOverMissingPatterns`.
    private(set) var passesOverMissingPatterns = false
    /// And true for such a file from before OpenMPT 1.22.02.02, in which a place that names
    /// pattern 255, which the file has not got, is the end of the song: the "---" of those
    /// trackers' lists, as OpenMPT reads one.
    private(set) var endsAtPattern255 = false
    /// How many patterns the file has.
    private(set) var patternCount = 256
    /// How much louder such a file is played than one of FastTracker's own: by its pre-amp, the
    /// composer's, against the usual one of the way it asks to be added up by (48, or 128 in the
    /// ways of OpenMPT 1.17). One for any other file.
    ///
    /// Not by its way of adding up, though OpenMPT plays it by that (ModPlug Tracker's, some 8 dB
    /// quieter, and more so the more channels; or the "compatible" one, whose panning puts a
    /// channel in the middle at half on each side where FastTracker's has it at seven tenths).
    /// Those turn a whole tracker's files up or down together, and the tunes of every kind are to
    /// be about as loud as each other. Measured over the files to hand, the files of each way come
    /// out about as loud as FastTracker's own this way, whatever their count of channels.
    var openMPTLevel: Float {
        guard let mix = openMPTMix else { return 1 }
        return Float(max(1, min(2000, mix.preAmp))) / openMPTUsualPreAmp(mix.mode)
    }

    private func openMPTUsualPreAmp(_ mode: Int) -> Float { mode >= 1 && mode <= 3 ? 128 : 48 }

    /// How loud OpenMPT has a voice of such a file in its own mix, which is what its plug-ins and
    /// ModPlug's reverb are given, against how loud the voice is heard here: by its way of adding up,
    /// which `openMPTLevel` leaves out. The plug-ins have to be given the voices as loud as OpenMPT
    /// gives them, and what they make put back as much quieter, or a plug-in that does not merely
    /// make a sound louder or quieter (a distortion, a compressor) makes another sound, and what it
    /// makes is heard too loud or too quiet beside the voices that go by it.
    ///
    /// A voice in the middle in a file of OpenMPT's "compatible" way (4) is 2.35 dB louder there than
    /// it is heard here (by measure, beside libopenmpt). The others follow from how OpenMPT adds up
    /// in each way (`SoundFilePlayConfig.cpp` and `Sndmix.cpp`): the ways of ModPlug Tracker and the
    /// first of OpenMPT's (0 to 2) turn the voices down by a table of the file's count of channels
    /// and by 16 more, and have a usual pre-amp of 128 rather than 48 in the last two of them; the
    /// third of OpenMPT 1.17's (3) does not turn them down at all, and so has them twice as loud as
    /// the compatible way, which turns them down by half; and the compatible way of FastTracker (5)
    /// has a voice in the middle at seven tenths on each side, not at half. A way OpenMPT does not
    /// know it adds up as the third.
    var openMPTMixLevel: Float {
        guard let mix = openMPTMix else { return 1 }
        let compatible: Float = 1.311
        let ofCompatible: Float = switch mix.mode {
        case 0 ... 2: IT2Mixer.PreAmpTable[max(1, min(31, mix.channels)) / 2]
        case 4: 1
        case 5: Float(2).squareRoot()
        default: 2
        }
        return compatible * ofCompatible * openMPTUsualPreAmp(mix.mode) / 48
    }

    /// What OpenMPT turns its whole numbers into for a plug-in, against what it makes them for the
    /// sound it gives out (a 2^27th): a 2^28th in ModPlug Tracker's way (0) and a 2^31st in the
    /// first of OpenMPT 1.17's (1), so that what a plug-in is given there is half or a sixteenth as
    /// loud; and what it gives back is made as much louder.
    var openMPTPlugInScale: Float {
        switch openMPTMix?.mode {
        case 0?: 0.5
        case 1?: Float(1 << 27) / Float(Int32.max)
        default: 1
        }
    }
    /// What is found on the way through a file that `shortfalls` is made from: samples the file
    /// ends before the end of, and samples in stereo.
    private var cutShort = Shortfall.CutShort()
    /// Why the instruments of an XM file from one on are not read, which are silent: the file
    /// ends before them, or what it says of one cannot be right, and nothing after it can be taken
    /// at its word. Nil for a file whose instruments are all there.
    private var lost: (from: Int, why: Lost)?
    private enum Lost { case cutShort, damaged }
    /// True for an XM file that has what FastTracker 2 had no room for: more than 128 instruments,
    /// or more than 16 samples in one. It was made by a later tracker, whatever it says.
    private var beyondFastTracker = false
    /// The samples ModPlug Tracker packed its own way (see `unpackADPCM`), each by its instrument
    /// and its place in it, as `instrument << 5 | sample`.
    private var packedSamples: [Int] = []
    /// The samples that are in stereo, each as FastTracker has it, one side after the other, and
    /// with its two sides apart: see `playAsFastTracker`.
    private var inStereo: [(instrument: Int, sample: Int, plain: FT2Sample, sides: FT2Sample)] = []
    /// The patterns that are empty, each with as many rows as the file says it has: see
    /// `keepWaysOfLaterTracker`. Played so in a file of a later tracker's, and as 64 in FastTracker's.
    private var emptyPatterns: [(pattern: Int, rows: Int)] = []
    /// The samples of a later tracker's XM file whose kind has the marks FastTracker's mixer takes
    /// for its own (see `keepWaysOfLaterTracker`), with those marks: played without them, and with
    /// them as FastTracker has them.
    private var markedSamples: [(instrument: Int, sample: Int, marks: UInt8)] = []
    private var allocations: [UnsafeMutableRawPointer] = []

    deinit {
        for allocation in allocations { allocation.deallocate() }
    }

    /// A file being read as the reference reads one: reading the last byte is reaching the end, and
    /// nothing more is read after that.
    private struct File {
        let data: [UInt8]
        var at = 0
        var eof = false

        init(_ data: [UInt8]) { self.data = data }

        /// The next bytes, as many as there are of those asked for; the rest are zeros.
        mutating func read(_ count: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: max(0, count))
            guard !eof, count > 0 else { return out }
            let there = min(count, data.count - at)
            for i in 0 ..< there { out[i] = data[at + i] }
            at += there
            if at >= data.count { eof = true }
            return out
        }

        /// Moves on past some bytes, or to the end if there are not so many.
        mutating func skip(_ count: Int) {
            seek(count >= data.count - at ? data.count : at + count)
        }

        mutating func seek(_ to: Int) {
            at = max(0, to)
            eof = false
            if at >= data.count {
                at = data.count
                eof = true
            }
        }
    }

    private func allocateInstr(_ i: Int) -> FT2Instrument {
        if let have = instr[i] { return have }
        let made = FT2Instrument()
        for j in 0 ..< 16 {
            made.samp[j].pan = 128
            made.samp[j].vol = 64
        }
        instr[i] = made
        return made
    }

    /// Memory for a sample, with what the file has of it and silence after.
    private func sampleMemory(_ bytes: [UInt8]) -> UnsafeMutableRawPointer {
        let memory = UnsafeMutableRawPointer.allocate(byteCount: bytes.count + 16, alignment: 8)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: bytes.count + 16)
        bytes.withUnsafeBytes { memory.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        allocations.append(memory)
        return memory
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            if byte == 0 { break }
            scalars.append(Unicode.Scalar(byte >= 0x20 && byte < 0x7F ? byte : 0x20))
        }
        return String(scalars).trimmed()
    }

    init(_ data: [UInt8]) throws {
        var f = File(data)
        // The stand-in instrument, which is silent.
        allocateInstr(0).samp[0].vol = 0

        let h = f.read(336)
        guard !f.eof else { throw TuneError.malformed("too short to be a module") }
        let reader = ByteReader(h)
        if Array(h[0 ..< 17]) != Array("Extended Module: ".utf8) {
            f.seek(0)
            try loadMOD(&f)
        } else {
            let ver = reader.u16le(58), headerSize = Int(Int32(truncatingIfNeeded: reader.u32le(60)))
            let antChn = reader.u16le(68), antPtn = reader.u16le(70), antInstrs = reader.u16le(72)
            guard ver >= 0x0102, ver <= 0x0104 else { throw TuneError.unsupported("an XM file of a version FastTracker 2 does not read") }
            // FastTracker itself reads only an even number of channels, and no more than 32. Other
            // trackers write XM files of any number, and those are played the same way.
            guard antChn >= 1, antChn <= Self.mostChannels else { throw TuneError.unsupported("an XM file of \(antChn) channels") }
            // FastTracker has room for 128 instruments. The trackers after it have room for more,
            // ModPlug Tracker, OpenMPT, MilkyTracker and DigiBooster Pro for 255, and a file with more
            // than 128 is theirs, whatever it says made it.
            guard antPtn <= 256, antInstrs <= 255 else {
                throw TuneError.unsupported("an XM file with more patterns or instruments than any tracker has room for")
            }
            guard headerSize >= 0, headerSize < data.count - 60 else { throw TuneError.malformed("an XM file with nothing after its header") }
            f.seek(60 + headerSize)
            patternCount = antPtn
            if antInstrs > 128 {
                instr += [FT2Instrument?](repeating: nil, count: antInstrs - 128)
                beyondFastTracker = true
            }

            // (In the letters of DOS, where FastTracker ran; OpenMPT's own files are in Windows'.)
            title = reader.encoded(at: 17, length: 20, as: h[38 ..< 45].elementsEqual("OpenMPT".utf8) ? .windows1252 : .dos)
            song.len = UInt16(reader.u16le(64))
            song.repS = UInt16(reader.u16le(66))
            song.antChn = UInt8(antChn)
            linearFrqTab = reader.u16le(74) & 1 != 0
            for i in 0 ..< 256 { song.songTab[i] = h[80 + i] }
            song.antInstrs = UInt16(antInstrs)
            let defSpeed = reader.u16le(78)
            song.speed = UInt16(defSpeed == 0 ? 125 : defSpeed)
            song.tempo = UInt16(max(1, reader.u16le(76)))
            song.ver = UInt16(ver)

            if ver < 0x0104 {
                // The older layout: every instrument's header, then the patterns, then the samples.
                // (An instrument lost here leaves nothing to say where the patterns are, nor
                // anything of the samples.)
                for i in 1 ..< antInstrs + 1 where loadInstrHeader(&f, i) != nil {
                    throw TuneError.malformed("an XM file with a broken instrument")
                }
                try loadPatterns(&f, antPtn)
                for i in 1 ..< antInstrs + 1 { loadInstrSample(&f, i) }
            } else {
                try loadPatterns(&f, antPtn)
                for i in 1 ..< antInstrs + 1 {
                    if let why = loadInstrHeader(&f, i) {
                        lost = (i, why)
                        // (Nothing that follows is taken for what a later tracker wrote after the instruments.)
                        if why == .damaged { f.seek(data.count) }
                        break
                    }
                    loadInstrSample(&f, i)
                }
            }
        }
        if !isMOD {
            let saysFastTracker = Array(h[38 ..< 58]) == Array("FastTracker v2.00   ".utf8) && reader.u32le(60) == 276
            let extras = ByteReader(data)
            let modPlugWroteMore = f.at + 8 <= data.count && [0x74_78_65_74, 0x49_44_49_4D, 0x4D_41_4E_50, 0x4D_41_4E_43, 0x58_46_48_43, 0x4D_50_54_58, 0x4D_50_54_53]
                .contains(extras.u32le(f.at)) || (f.at + 4 <= data.count && extras[f.at] == 0x46 && extras[f.at + 1] == 0x58)
            madeByFastTracker = saysFastTracker && (reader.u16le(58) < 0x0104 || !h[17 ..< 37].contains(0) && !modPlugWroteMore) && !beyondFastTracker
            // (ModPlug Tracker's: by the signs above, or by the name its first versions gave the format.
            // OpenMPT goes by more signs than these, and the two agree on all but about one file in
            // a hundred of those that have them.)
            let byModPlug = saysFastTracker && !madeByFastTracker || Array(h[38 ..< 58]) == Array("FastTracker v 2.00  ".utf8)
            openMPTMix = Self.openMPTMix(of: data, name: Array(h[38 ..< 58]), byModPlug: byModPlug, channels: Int(song.antChn))
            let name = Array(h[38 ..< 58])
            arpeggioOfOtherTrackers = !Self.keepsFastTrackersWay(51, since: 0x0117_0302, data, name: name, byModPlug: byModPlug)
            playsModPlugXCommands = !Self.keepsFastTrackersWay(58, since: 0x0118_0000, data, name: name, byModPlug: byModPlug)
            panningEndsSurround = Self.keepsFastTrackersWay(10, since: 0x0117_0302, data, name: name, byModPlug: byModPlug)
            fineTunesFully = !Self.keepsFastTrackersWay(76, since: 0x0122_0719, data, name: name, byModPlug: byModPlug)
            keepWaysOfLaterTracker(data, name: name, byModPlug: byModPlug)
            noteWhatLaterTrackersAdded(data, after: f.at)
        }
        // A file that has lost all it would have been heard by, or whose samples are silent, is not a
        // tune (see `Shortfall.nothingToHear`); nor is one whose instruments are plug-ins and nothing else.
        guard instr.contains(where: { $0?.samp.contains { Shortfall.sounds($0.pek, count: Int($0.len)) || Shortfall.sounds($0.pekR, count: Int($0.len)) } ?? false }) else {
            throw instrumentPlugIns.contains { $0 > 0 } ? Shortfall.onlyPlugInsToHear : Shortfall.nothingToHear
        }
        if let sentence = cutShort.sentence { shortfalls.append(sentence) }
        if let lost {
            // What is lost is said of only as far as the song plays it.
            let played = instrumentsPlayed()
            let missing = (lost.from ..< instr.count).filter { played[$0] }.count
            if let sentence = Shortfall.instrumentsLost(missing, damaged: lost.why == .damaged, samplesToo: cutShort.sentence != nil) {
                shortfalls.append(sentence)
            }
        }
        if song.repS > song.len { song.repS = 0 }
        song.timer = 1
        setPosition(0)
        upDateInstrs()
    }

    /// Which instruments the song plays, by number: those named in the patterns that its order
    /// list plays.
    private func instrumentsPlayed() -> [Bool] {
        var played = [Bool](repeating: false, count: 256)
        for position in 0 ..< min(256, Int(song.len)) {
            guard let pattern = patt[Int(song.songTab[position])] else { continue }
            for note in pattern { played[Int(note.instr)] = true }
        }
        return played
    }

    /// Says how samples in stereo are to be played. FastTracker 2 knows nothing of them, and no
    /// file of its own has one: to it a sample's two sides, which lie one after the other in the
    /// file, are one long sample. The trackers that came after it, which are the ones that make
    /// such samples, play the two sides together, the left side on the left and the right on the
    /// right, each as loud as the channel's place between them makes that side; and that is how
    /// they are played here, the mixer reading the two sides as one voice. They can be had as
    /// FastTracker has them for setting what is played beside the player this is ported from; and
    /// so can the empty patterns and the kinds of samples of a later tracker's file (see
    /// `keepWaysOfLaterTracker`).
    func playAsFastTracker(_ asFastTracker: Bool) {
        for one in inStereo { instr[one.instrument]?.samp[one.sample] = asFastTracker ? one.plain : one.sides }
        for one in markedSamples {
            guard let ins = instr[one.instrument] else { continue }
            ins.samp[one.sample].typ = asFastTracker ? ins.samp[one.sample].typ | one.marks : ins.samp[one.sample].typ & ~0x0C
        }
        for one in emptyPatterns { pattLens[one.pattern] = UInt16(asFastTracker ? 64 : one.rows) }
    }

    /// Plays an XM file that a later tracker made with what that tracker did otherwise than
    /// FastTracker 2 with what is in it, where it is known (FastTracker's own files are left
    /// as they are):
    ///
    /// - An empty pattern is as long as the file says. FastTracker, reading a file, lets go of a
    ///   pattern with nothing in it and gives it 64 rows, whatever its length was (as the player
    ///   this is ported from does, and as OpenMPT knows: an empty pattern it saves for FastTracker
    ///   has a break put in its last row so that it is not one); the trackers after it keep the
    ///   length, as OpenMPT does. (Not in a file of "Fasttracker II clone"'s, which OpenMPT takes
    ///   for FastTracker's own.)
    /// - The two bits of a sample's kind that FastTracker never wrote and its mixer takes for its
    ///   own marks, 4 for a voice going backwards and 8 for one that is off, are nothing, as they
    ///   are to OpenMPT, which reads only the loop, sixteen bits and stereo there. (FastTracker's
    ///   mixer leaves a sample with the 8 silent; Xrns2XMod, which writes Renoise's songs as XM
    ///   files, sets it.)
    /// - In a file of ModPlug Tracker's or OpenMPT's, a place in the list that names a pattern the
    ///   file has not got is passed over (see `passesOverMissingPatterns`).
    /// - Pattern loops go as they do in OpenMPT for a file of its own or of ModPlug Tracker's (see
    ///   `oneLoopAtATime`). In a file of DigiBooster Pro's, the next pattern is not started on the
    ///   row a loop began on, which is FastTracker's mistake alone: DigiBooster 3's replayer, by
    ///   which DigiBooster Pro's own modules are played here, does not make it, and nor can
    ///   DigiBooster Pro have, for in its XM files that loop from a later row the first rows of
    ///   pattern after pattern would never be heard. Its other ways with loops are left as
    ///   FastTracker's, as OpenMPT plays such a file.
    private func keepWaysOfLaterTracker(_ data: [UInt8], name: [UInt8], byModPlug: Bool) {
        if madeByFastTracker {
            emptyPatterns = []
            return
        }
        if name == Array("Fasttracker II clone".utf8) { emptyPatterns = [] }
        emptyPatterns = emptyPatterns.filter { $0.rows >= 1 && $0.rows <= 256 }
        for i in 1 ..< instr.count {
            guard let ins = instr[i] else { continue }
            for j in 0 ..< Int(ins.antSamp) where ins.samp[j].typ & 0x0C != 0 {
                markedSamples.append((i, j, ins.samp[j].typ & 0x0C))
            }
        }
        for k in inStereo.indices { inStereo[k].sides.typ &= ~0x0C }
        playAsFastTracker(false)

        let version = Self.modPlugVersion(data, name: name)
        passesOverMissingPatterns = openMPTMix != nil
        endsAtPattern255 = passesOverMissingPatterns && patternCount <= 255 && (version != 0 || byModPlug) && version < 0x0122_0202
        oneLoopAtATime = !Self.keepsFastTrackersWay(17, since: 0x0117_0302, data, name: name, byModPlug: byModPlug)
        loopsBeforeJumps = !Self.keepsFastTrackersWay(68, since: 0x0120_0069, data, name: name, byModPlug: byModPlug)
        loopsLeaveNothingBehind = !Self.keepsFastTrackersWay(63, since: 0x0118_0201, data, name: name, byModPlug: byModPlug)
            || name.starts(with: Array("DigiBooster Pro".utf8))
    }

    /// Whether a place in the list of patterns names a pattern to be played, for finding the songs
    /// of the file: one that is passed over, or that ends the song, does not (see
    /// `passesOverMissingPatterns`).
    func namesPattern(at place: Int) -> Bool {
        !passesOverMissingPatterns || Int(song.songTab[place]) < patternCount
    }

    /// The version of OpenMPT that saved a file, by its name or by what it wrote after the song,
    /// as a number of four bytes; nought if neither says.
    private static func modPlugVersion(_ data: [UInt8], name: [UInt8]) -> Int {
        if name.starts(with: Array("OpenMPT ".utf8)) {
            // (OpenMPT writes each part of its version in hex digits, as "1.27" for 0x0127.)
            let parts = String(decoding: name.dropFirst(8), as: UTF8.self).split(separator: ".").map { Int($0.filter { $0.isHexDigit }, radix: 16) ?? 0 }
            return (0 ..< 4).reduce(0) { $0 << 8 | ($1 < parts.count ? min(255, parts[$1]) : 0) }
        }
        var extras = ModPlugExtras()
        extras.readSongExtras(ByteReader(data))
        return extras.savedWith ?? 0
    }

    /// How OpenMPT adds the channels of an XM file up, as its loader works it out, for a file of
    /// OpenMPT's (by its name, from its version) or ModPlug Tracker's (by the signs it leaves, or by a
    /// version of its own written in the song's extras), and as the song's extras then say, if
    /// they do. Nil for a file of any other tracker's.
    private static func openMPTMix(of data: [UInt8], name: [UInt8], byModPlug: Bool, channels: Int) -> (mode: Int, preAmp: Int, channels: Int)? {
        var extras = ModPlugExtras()
        extras.readSongExtras(ByteReader(data))
        var mode: Int?
        // (A version in four parts, a byte each: "1.22.07.19" was the first to add up as FastTracker does.)
        var version = extras.savedWith ?? 0
        let addsUpAsFastTracker = 1 << 24 | 22 << 16 | 7 << 8 | 19
        if name.starts(with: Array("OpenMPT ".utf8)) {
            let parts = String(decoding: name.dropFirst(8), as: UTF8.self).split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
            version = (0 ..< 4).reduce(0) { $0 << 8 | ($1 < parts.count ? min(255, parts[$1]) : 0) }
            mode = version < addsUpAsFastTracker ? 4 : 5
        } else if byModPlug || extras.savedWith != nil {
            mode = 0
        }
        if let said = extras.mixLevels, mode != nil || extras.hasSongExtras { mode = said }
        guard var mode else { return nil }
        // (A file of the versions after that and before 1.23.01.04 says it adds up the old way, and does not.)
        if mode == 4, version >= addsUpAsFastTracker, version < (1 << 24 | 23 << 16 | 1 << 8 | 4) { mode = 5 }
        return (mode, extras.preAmp ?? 48, max(channels, extras.channels))
    }

    /// Whether OpenMPT plays an XM file with one of FastTracker's ways, by its number among
    /// OpenMPT's ways of playing (51 its arpeggio, 58 its keeping to its own X commands): MadTracker
    /// 2 and Skale Tracker, by the tracker's name, without FastTracker's arpeggio; ModPlug Tracker's
    /// files without any of its ways, which OpenMPT turns off together; and OpenMPT's own by what
    /// the file says of its ways, or, before 1.26 and with its "compatible play", by whether the
    /// version had the way yet (`since`), and before that play itself (1.17.02.46) with none.
    private static func keepsFastTrackersWay(_ way: Int, since: Int, _ data: [UInt8], name: [UInt8], byModPlug: Bool) -> Bool {
        if name.starts(with: Array("MadTracker 2.0\0".utf8)) || name.starts(with: Array("Skale Tracker\0".utf8))
            || name.starts(with: Array("Sk@le Tracker\0".utf8)) { return way != 51 }
        var extras = ModPlugExtras()
        extras.readSongExtras(ByteReader(data))
        let version = modPlugVersion(data, name: name)
        if !name.starts(with: Array("OpenMPT ".utf8)), byModPlug || version == 0 { return !byModPlug }
        // (A file with OpenMPT's extras has none of its ways but those they list; one without, all.)
        let listed = { (way: Int) in !extras.hasSongExtras || way < extras.behaviours.count && extras.behaviours[way] }
        var compatible = listed(0)
        if version < 0x0117_0246, version != 0x0117_0000 { compatible = false }
        if compatible, version < 0x0126_0000 { return version >= since }
        return listed(way)
    }

    /// Looks over an XM file for what a later tracker put in it that FastTracker does not play,
    /// and says so in `shortfalls`. Nothing that is played is changed by it.
    /// - Parameter end: where in the file the last of what FastTracker reads ended.
    private func noteWhatLaterTrackersAdded(_ data: [UInt8], after end: Int) {
        // What ModPlug Tracker and OpenMPT write after everything FastTracker reads: macros, and plug-ins.
        var extras = ModPlugExtras()
        let file = ByteReader(data)
        let afterPieces = extras.readPieces(file, at: end, before: data.count)
        if extras.macros != nil {
            let chosen = extras.filterMacro(file, 0)
            for value in 0 ..< 256 { filterMacros[value] = value < 0x80 ? chosen : extras.filterMacro(file, 16 + value - 0x80) }
        }

        // Which instruments the patterns play, and which commands of ModPlug Tracker's they have.
        var used = [Bool](repeating: false, count: 256)
        var commands = Shortfall.Kinds()
        var macroValues = [Bool](repeating: false, count: 256)
        for case let pattern? in patt {
            for note in pattern {
                if note.instr != 0 { used[Int(note.instr)] = true }
                // (A sweep from side to side, 34, is played in a file that is not FastTracker's
                // own, and so is the setting of a filter; in one that is, they are nothing, as they
                // were to FastTracker. What is left is a macro of the file's own that sends
                // something else: the filter's kind, or a plug-in's setting.)
                if note.effTyp == 35 || note.effTyp == 36, !madeByFastTracker { macroValues[Int(note.eff)] = true }
                if note.effTyp == 33, note.eff == 0x99, playsModPlugXCommands { reverbs = true }
                // (Of ModPlug Tracker's X commands, those for notes left playing and for envelopes
                // are not played.)
                if note.effTyp == 33, playsModPlugXCommands {
                    if note.eff >> 4 == 7 { commands.note(1) }
                }
            }
        }
        if macroValues.indices.contains(where: { value in
            macroValues[value] && filterMacros[value] == nil && extras.macroSendsSomething(file, value < 0x80 ? 0 : 16 + value - 0x80)
        }) { commands.note(0) }
        if let sentence = Shortfall.commandsLeftOut(commands.named(["the setting of a filter or a plug-in", "the settings of notes left playing and of envelopes"]),
                                                    why: "which FastTracker 2 did not have") {
            shortfalls.append(sentence)
        }

        extras.readInstrumentExtras(file, from: afterPieces, instruments: Int(song.antInstrs))
        // The plug-ins that are OpenMPT's own are played, as they are for an IT file of these
        // trackers'; a voice goes to the one its instrument plays through, or else its channel's.
        var sound = ModPlugSound()
        sound.plugIns = extras.plugIns
        sound.channelPlugIns = Array(extras.channelPlugIns.prefix(Int(song.antChn)))
        sound.plugInScale = openMPTPlugInScale
        for i in 1 ..< instr.count where i - 1 < extras.instrumentPlugIns.count { instrumentPlugIns[i] = extras.instrumentPlugIns[i - 1] }
        for i in 1 ..< instr.count where i - 1 < extras.resamplings.count && extras.resamplings[i - 1] < IT2Resampling.own { instrumentResamplings[i] = extras.resamplings[i - 1] }
        if !madeByFastTracker, sound.sendsToPlugIns(instruments: instrumentPlugIns) { self.sound = sound }
        // What is not heard: an instrument that is a plug-in that is not played, and nothing else
        // (one with a sample is heard, through its plug-in or without it), and the plug-ins that
        // are somebody else's program.
        var unheard = 0
        for i in 1 ..< instr.count where used[i] && extras.playsThroughPlugIn(instrument: i - 1) && !extras.isPlayed(plugIn: instrumentPlugIns[i]) {
            let hasSample = instr[i].map { ins in ins.samp.contains { $0.len > 0 } } ?? false
            if !hasSample { unheard += 1 }
        }
        shortfalls.append(contentsOf: Shortfall.plugIns(unheard: unheard, bare: 0, channels: 0))
        let leftOut = extras.plugInsLeftOut
        if let sentence = Shortfall.plugInsLeftOut(leftOut.names, of: leftOut.all) { shortfalls.append(sentence) }
    }

    /// A module of another tracker's, already read into what FastTracker can play.
    init(_ module: ForeignModule) throws {
        allocateInstr(0).samp[0].vol = 0
        guard module.channels >= 1, module.channels <= Self.mostChannels else {
            throw TuneError.unsupported("\(module.aFile) of \(module.channels) channels")
        }
        guard !module.orders.isEmpty else { throw TuneError.malformed("\(module.aFile) with no order to play its patterns in") }
        guard module.patterns.count <= 256, module.samples.count <= 128 else {
            throw TuneError.unsupported("\(module.aFile) with more patterns or instruments than FastTracker 2 has room for")
        }
        guard module.samples.contains(where: { $0.map { Shortfall.sounds($0.data) || Shortfall.sounds($0.right ?? []) } ?? false }) else {
            throw Shortfall.nothingToHear
        }
        foreign = (module.format, module.tracker, module.loudness)
        shortfalls = module.shortfalls
        title = module.title
        channelPanning = (0 ..< module.channels).map { $0 < module.panning.count ? module.panning[$0] : 128 }
        speedAndTempoUndoEachOther = module.speedAndTempoUndoEachOther
        vibratoIsAQuarterAsDeep = module.vibratoIsAQuarterAsDeep
        playsAsDigiBooster = module.playsAsDigiBooster
        song.antChn = UInt8(module.channels)
        song.len = UInt16(min(256, module.orders.count))
        song.repS = UInt16(max(0, min(255, module.restart)))
        for i in 0 ..< Int(song.len) { song.songTab[i] = module.orders[i] }
        song.antInstrs = UInt16(module.samples.count)
        song.tempo = UInt16(max(1, min(255, module.speed)))
        song.speed = UInt16(max(1, min(255, module.tempo)))

        for (i, pattern) in module.patterns.enumerated() {
            let rows = max(1, min(256, pattern.rows))
            pattLens[i] = UInt16(rows)
            guard pattern.notes.count >= rows * module.channels else { continue }
            patt[i] = pattern.notes
            if patternEmpty(i) { patt[i] = nil }
        }
        for (i, sample) in module.samples.enumerated() {
            guard let sample, !sample.data.isEmpty else { continue }
            let ins = allocateInstr(i + 1)
            // Lengths are in bytes, and a sample of sixteen bits has a whole number of pairs of them.
            let whole = sample.sixteenBit ? ~1 : ~0
            let length = sample.data.count & whole
            let repeatStart = max(0, min(length, sample.repeatStart & whole))
            let repeatLength = max(0, min(length - repeatStart, sample.repeatLength & whole))
            ins.antSamp = 1
            ins.samp[0].len = Int32(length)
            ins.samp[0].repS = Int32(repeatStart)
            ins.samp[0].repL = Int32(repeatLength)
            ins.samp[0].typ = (repeatLength > 0 ? sample.backAndForth ? 2 : 1 : 0) | (sample.sixteenBit ? 16 : 0)
            ins.samp[0].vol = min(64, sample.volume)
            ins.samp[0].fine = sample.fineTune
            ins.samp[0].relTon = sample.relativeNote
            ins.samp[0].rate = sample.rate == 8363 ? 0 : UInt32(max(0, min(ForeignModule.highestRate, sample.rate)))
            ins.samp[0].pek = sampleMemory(sample.data)
            if let right = sample.right { ins.samp[0].pekR = sampleMemory(right + [UInt8](repeating: 0, count: max(0, sample.data.count - right.count))) }
        }
        if song.repS > song.len { song.repS = 0 }
        song.timer = 1
        setPosition(0)
        upDateInstrs()
    }

    private func setPosition(_ pos: Int) {
        song.songPos = Int16(pos)
        if song.len > 0, song.songPos >= Int16(bitPattern: song.len) { song.songPos = Int16(bitPattern: song.len) - 1 }
        song.pattNr = Int16(song.songTab[Int(song.songPos)])
        song.pattLen = Int16(bitPattern: pattLens[Int(song.pattNr)])
        song.pattPos = 0
        if song.pattPos >= song.pattLen { song.pattPos = song.pattLen - 1 }
    }

    private func patternEmpty(_ nr: Int) -> Bool {
        guard let rows = patt[nr] else { return true }
        return !rows.contains { $0.ton != 0 || $0.instr != 0 || $0.vol != 0 || $0.effTyp != 0 || $0.eff != 0 }
    }

    // MARK: XM

    /// Reads an instrument's header, and those of its samples. Says why, if the instrument cannot be
    /// read, and with it none of those after it.
    private func loadInstrHeader(_ f: inout File, _ i: Int) -> Lost? {
        // A file that ends before an instrument has lost it, and the ones after it.
        guard !f.eof, f.data.count - f.at >= 4 else { return .cutShort }
        // An instrument's header says how long it is, and is read for no longer than FastTracker
        // knows it to be. A length of nought is the whole of it, as OpenMPT reads one: ModPlug
        // Tracker's MOD Plugin, for one, writes an empty instrument so.
        let sizeBytes = f.read(4)
        let stated = Int(Int32(truncatingIfNeeded: ByteReader(sizeBytes).u32le(0)))
        var instrSize = stated == 0 ? 263 : stated
        // (Shorter than the four bytes that say how long it is, or so long that it reads as less
        // than nought, or longer than FastTracker's and than the rest of the file, it cannot be right.)
        guard instrSize >= 4, instrSize <= 263 || instrSize - 4 <= f.data.count - f.at else { return .damaged }
        if instrSize > 263 { instrSize = 263 }
        var ih = [UInt8](repeating: 0, count: 263)
        let rest = f.eof ? [] : f.read(instrSize - 4)
        for k in 0 ..< rest.count { ih[4 + k] = rest[k] }
        // ft2play, which this is ported from, goes on from there; OpenMPT passes over the rest of a
        // longer one. The one file to hand with a header longer than FastTracker's, MED2XM's, has
        // the rest, nought, in every one of its instruments, and is laid out to be read past it.
        if stated > 263 { f.skip(stated - 263) }
        let header = ByteReader(ih)

        // FastTracker has room for sixteen samples in an instrument, and ModPlug Tracker and
        // OpenMPT for 32, which is as many as OpenMPT reads; a file with more than sixteen is
        // theirs, whatever it says made it. More than 32 cannot be right.
        let antSamp = header.u16le(27)
        guard antSamp <= 32 else { return .damaged }
        guard antSamp > 0 else { return nil }
        guard !f.eof, f.at + antSamp * 40 <= f.data.count else { return .cutShort }

        let ins = allocateInstr(i)
        if antSamp > 16 {
            beyondFastTracker = true
            var more = FT2Sample()
            more.pan = 128
            more.vol = 64
            ins.samp += [FT2Sample](repeating: more, count: 16)
        }
        for k in 0 ..< 96 { ins.ta[k] = ih[33 + k] }
        for k in 0 ..< 24 {
            ins.envVP[k] = Int16(truncatingIfNeeded: header.u16le(129 + k * 2))
            ins.envPP[k] = Int16(truncatingIfNeeded: header.u16le(177 + k * 2))
        }
        ins.envVPAnt = ih[225]
        ins.envPPAnt = ih[226]
        ins.envVSust = ih[227]
        ins.envVRepS = ih[228]
        ins.envVRepE = ih[229]
        ins.envPSust = ih[230]
        ins.envPRepS = ih[231]
        ins.envPRepE = ih[232]
        ins.envVTyp = ih[233]
        ins.envPTyp = ih[234]
        ins.vibTyp = ih[235]
        ins.vibSweep = ih[236]
        ins.vibDepth = ih[237]
        ins.vibRate = ih[238]
        ins.fadeOut = UInt16(header.u16le(239))
        ins.mute = ih[247] == 1 ? 1 : 0
        ins.antSamp = Int16(antSamp)

        let headers = ByteReader(f.read(antSamp * 40))
        for j in 0 ..< antSamp {
            let at = j * 40
            ins.samp[j].len = Int32(truncatingIfNeeded: headers.u32le(at))
            ins.samp[j].repS = Int32(truncatingIfNeeded: headers.u32le(at + 4))
            ins.samp[j].repL = Int32(truncatingIfNeeded: headers.u32le(at + 8))
            ins.samp[j].vol = headers[at + 12]
            ins.samp[j].fine = Int8(bitPattern: headers[at + 13])
            ins.samp[j].typ = headers[at + 14]
            ins.samp[j].pan = headers[at + 15]
            ins.samp[j].relTon = Int8(bitPattern: headers[at + 16])
            // (What ModPlug Tracker says of a sample of eight bits in mono that it packed. FastTracker
            // writes the length of the sample's name there, which is never more than 22.)
            if ins.samp[j].typ & 48 == 0, headers[at + 17] == 0xAD { packedSamples.append(i << 5 | j) }
        }
        return nil
    }

    private func checkSampleRepeat(_ s: inout FT2Sample) {
        if s.repS < 0 { s.repS = 0 }
        if s.repL < 0 { s.repL = 0 }
        if s.repS > s.len { s.repS = s.len }
        if s.repS &+ s.repL > s.len { s.repL = s.len - s.repS }
    }

    private func loadInstrSample(_ f: inout File, _ i: Int) {
        guard let ins = instr[i] else { return }
        for j in 0 ..< Int(ins.antSamp) {
            // A file cut a little short keeps its last sample's length, and the end of it is silence.
            // One that speaks of far more than it holds is not believed.
            let left = f.eof ? 0 : f.data.count - f.at
            if packedSamples.contains(i << 5 | j) {
                // (Packed, a sample takes sixteen bytes and half a byte for each of its own.)
                let length = Int(ins.samp[j].len)
                cutShort.add(length: length, there: (left - 16) * 2)
                if 16 + (length + 1) / 2 - left > Self.mostMissing { ins.samp[j].len = Int32(max(0, left - 16) * 2) }
                if ins.samp[j].len > 0 {
                    let stored = 16 + (Int(ins.samp[j].len) + 1) / 2
                    let there = min(stored, left)
                    ins.samp[j].pek = sampleMemory(Self.unpackADPCM(Array(f.read(stored).prefix(there)), length: Int(ins.samp[j].len)))
                }
                checkSampleRepeat(&ins.samp[j])
                continue
            }
            cutShort.add(length: Int(ins.samp[j].len), there: left)
            if Int(ins.samp[j].len) - left > Self.mostMissing { ins.samp[j].len = Int32(left & ~(ins.samp[j].typ & 16 != 0 ? 1 : 0)) }
            if ins.samp[j].len > 0 {
                // A sample is stored as the differences between one value and the next.
                let stored = f.read(Int(ins.samp[j].len))
                if ins.samp[j].typ & 32 != 0 { inStereo.append((i, j, ins.samp[j], apart(ins.samp[j], stored))) }
                var bytes = stored
                if ins.samp[j].typ & 16 != 0 {
                    var old: UInt16 = 0
                    for k in 0 ..< bytes.count / 2 {
                        old &+= UInt16(bytes[k * 2]) | UInt16(bytes[k * 2 + 1]) << 8
                        bytes[k * 2] = UInt8(old & 0xFF)
                        bytes[k * 2 + 1] = UInt8(old >> 8)
                    }
                } else {
                    var old: UInt8 = 0
                    for k in 0 ..< bytes.count {
                        old &+= bytes[k]
                        bytes[k] = old
                    }
                }
                ins.samp[j].pek = sampleMemory(bytes)
            }
            checkSampleRepeat(&ins.samp[j])
            if let last = inStereo.last, last.instrument == i, last.sample == j {
                inStereo[inStereo.count - 1].plain = ins.samp[j]
                ins.samp[j] = last.sides
            }
        }
    }

    /// Unpacks an eight-bit sample packed as ModPlug Tracker packed them, as OpenMPT unpacks one:
    /// sixteen differences, and then two samples a byte, the low four bits first, each the one
    /// before it moved by the difference those bits pick. What the file does not have is silent.
    private static func unpackADPCM(_ stored: [UInt8], length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        guard stored.count >= 16 else { return out }
        var sample: UInt8 = 0
        for i in 0 ..< min(stored.count - 16, (length + 1) / 2) {
            let byte = stored[16 + i]
            sample &+= stored[Int(byte & 0x0F)]
            out[i * 2] = sample
            sample &+= stored[Int(byte >> 4)]
            if i * 2 + 1 < length { out[i * 2 + 1] = sample }
        }
        return out
    }

    /// A sample in stereo with its two sides apart, from the bytes of it in the file: the left
    /// side and then the right, each stored as differences of its own. It is half as long, and
    /// what it repeats is where it was in each side.
    private func apart(_ sample: FT2Sample, _ stored: [UInt8]) -> FT2Sample {
        var sides = sample
        let sixteenBit = sample.typ & 16 != 0
        let half = sixteenBit ? (stored.count / 2) & ~1 : stored.count / 2
        var left = [UInt8](repeating: 0, count: half), right = left
        if sixteenBit {
            var l: UInt16 = 0, r: UInt16 = 0
            for k in stride(from: 0, to: half, by: 2) {
                l &+= UInt16(stored[k]) | UInt16(stored[k + 1]) << 8
                r &+= UInt16(stored[half + k]) | UInt16(stored[half + k + 1]) << 8
                (left[k], left[k + 1]) = (UInt8(truncatingIfNeeded: l), UInt8(truncatingIfNeeded: l >> 8))
                (right[k], right[k + 1]) = (UInt8(truncatingIfNeeded: r), UInt8(truncatingIfNeeded: r >> 8))
            }
        } else {
            var l: UInt8 = 0, r: UInt8 = 0
            for k in 0 ..< half {
                l &+= stored[k]
                r &+= stored[half + k]
                left[k] = l
                right[k] = r
            }
        }
        let even: Int32 = sixteenBit ? ~1 : ~0
        // (The mark that says it is in stereo is taken off: to the mixer that same bit means a voice
        // fading out, which is cut when its tick is done, and a sample with it was heard for a tick.)
        sides.typ &= ~0x20
        sides.len = Int32(half)
        sides.repS = (sample.repS / 2) & even
        sides.repL = (sample.repL / 2) & even
        sides.pek = sampleMemory(left)
        sides.pekR = sampleMemory(right)
        checkSampleRepeat(&sides)
        return sides
    }

    private func loadPatterns(_ f: inout File, _ antPtn: Int) throws {
        let antChn = Int(song.antChn)
        for i in 0 ..< antPtn {
            let start = ByteReader(f.read(5))
            let patternHeaderSize = Int(Int32(truncatingIfNeeded: start.u32le(0)))
            var pattLen: Int, dataLen: Int
            if song.ver == 0x0102 {
                let rest = ByteReader(f.read(3))
                pattLen = Int(rest[0]) + 1
                dataLen = rest.u16le(1)
                if patternHeaderSize > 8 { f.skip(patternHeaderSize - 8) }
            } else {
                let rest = ByteReader(f.read(4))
                pattLen = rest.u16le(0)
                dataLen = rest.u16le(2)
                if patternHeaderSize > 9 { f.skip(patternHeaderSize - 9) }
            }
            guard !f.eof else { throw TuneError.malformed("an XM file that ends in its patterns") }

            pattLens[i] = UInt16(pattLen)
            if dataLen > 0 {
                // Packed: a byte with its top bit set says which of a note's five bytes follow.
                //
                // FastTracker unpacks a pattern where it lies: the packed bytes are read into the end
                // of the pattern's memory and unpacked from its start. Where a pattern hardly packs
                // at all, the unpacked notes catch up with the packed ones and write over what has
                // not been read yet, and the last notes of the pattern come out as something else.
                // Files have gone out into the world like that, so it is done the same way here.
                let size = pattLen * antChn * 5
                let base = max(0, dataLen - size)
                var memory = [UInt8](repeating: 0, count: base + size)
                let packed = f.read(dataLen)
                var src = base + size - dataLen
                for k in 0 ..< dataLen { memory[src + k] = packed[k] }
                var dst = base
                func next() -> UInt8 {
                    defer { src += 1 }
                    return src < memory.count ? memory[src] : 0
                }
                func put(_ byte: UInt8) {
                    memory[dst] = byte
                    dst += 1
                }
                for _ in 0 ..< pattLen * antChn {
                    let first = next()
                    if first & 0x80 != 0 {
                        put(first & 0x01 != 0 ? next() : 0)
                        put(first & 0x02 != 0 ? next() : 0)
                        put(first & 0x04 != 0 ? next() : 0)
                        put(first & 0x08 != 0 ? next() : 0)
                        put(first & 0x10 != 0 ? next() : 0)
                    } else {
                        put(first)
                        put(next())
                        put(next())
                        put(next())
                        put(next())
                    }
                    if memory[dst - 5] > 97 { memory[dst - 5] = 0 }
                }
                var notes = [FT2Note](repeating: FT2Note(), count: pattLen * antChn)
                for n in 0 ..< notes.count {
                    let at = base + n * 5
                    notes[n] = FT2Note(ton: memory[at], instr: memory[at + 1], vol: memory[at + 2], effTyp: memory[at + 3], eff: memory[at + 4])
                }
                patt[i] = notes
            }
            if patternEmpty(i) {
                patt[i] = nil
                pattLens[i] = 64
                emptyPatterns.append((i, pattLen))
            }
        }
    }

    /// Puts each sample in order for the mixer, which reads one sample past where it is playing: what
    /// it finds there is the start of the loop, or the sample before, or nothing.
    private func upDateInstrs() {
        for ins in instr {
            guard let ins else { continue }
            for j in ins.samp.indices { putInOrder(&ins.samp[j]) }
        }
        // A sample in stereo is there twice over, and both are put in order.
        for index in inStereo.indices {
            putInOrder(&inStereo[index].plain)
            if let sides = instr[inStereo[index].instrument]?.samp[inStereo[index].sample] { inStereo[index].sides = sides }
        }
    }

    private func putInOrder(_ sample: inout FT2Sample) {
        checkSampleRepeat(&sample)
        let s = sample
        guard let pek = s.pek else {
            sample.len = 0
            sample.repS = 0
            sample.repL = 0
            return
        }
        let sixteen = s.typ & 16 != 0
        var len = Int(s.len), loopStart = Int(s.repS), loopEnd = Int(s.repS) + Int(s.repL)
        if sixteen {
            len >>= 1
            loopStart >>= 1
            loopEnd >>= 1
        }
        guard len >= 1 else { return }
        // (Both sides of a sample in stereo.)
        for side in [pek, s.pekR].compactMap({ $0 }) {
            // Asked in this order, which matters where a sample says it loops both ways at once.
            if sixteen {
                let p = side.assumingMemoryBound(to: Int16.self)
                if s.typ & 1 != 0 {
                    p[loopEnd] = p[loopStart]
                } else if s.typ & 2 != 0 {
                    p[loopEnd] = loopEnd > 0 ? p[loopEnd - 1] : 0
                } else {
                    p[len] = 0
                }
            } else {
                let p = side.assumingMemoryBound(to: Int8.self)
                if s.typ & 1 != 0 {
                    p[loopEnd] = p[loopStart]
                } else if s.typ & 2 != 0 {
                    p[loopEnd] = loopEnd > 0 ? p[loopEnd - 1] : 0
                } else {
                    p[len] = 0
                }
            }
        }
    }

    // MARK: MOD

    /// How much of a sample may be missing from the end of a file and the sample still be taken at its word.
    private static let mostMissing = 1 << 20
    /// The most channels a module may have. FastTracker stops at 32; files from later trackers go on.
    static let mostChannels = 128

    private func loadMOD(_ f: inout File) throws {
        let ha = f.read(1084)
        guard !f.eof else { throw TuneError.malformed("too short to be a module") }
        let header = ByteReader(ha)
        let signature = Self.text(ha[1080 ..< 1084])
        // The four letters say how many channels: "6CHN", "12CH". FastTracker knows the even numbers
        // up to 32 and the Amiga's own; the odd ones and two from the Atari ST are taken the same way.
        var channels = 0
        let tag = Array(ha[1080 ..< 1084])
        func digit(_ byte: UInt8) -> Int? { byte >= 0x30 && byte <= 0x39 ? Int(byte) - 0x30 : nil }
        func isTag(_ text: StaticString) -> Bool { text.withUTF8Buffer { $0[0] == tag[0] && $0[1] == tag[1] && $0[2] == tag[2] && $0[3] == tag[3] } }
        if let n = digit(tag[0]), tag[1] == 0x43, tag[2] == 0x48, tag[3] == 0x4E {
            channels = n
        } else if let tens = digit(tag[0]), let ones = digit(tag[1]), tag[2] == 0x43, tag[3] == 0x48 {
            channels = tens * 10 + ones
        } else if isTag("M.K.") || isTag("M!K!") || isTag("FLT4") {
            channels = 4
        } else if isTag("OCTA") || isTag("CD81") || isTag("OKTA") {
            channels = 8
        }
        // FastTracker takes a file it does not know for one of the oldest kind, with 15 samples. Those
        // are ProTracker's to play here, so this asks to know the file.
        guard channels > 0, channels <= Self.mostChannels else {
            throw TuneError.unsupported("a module of a kind this player does not know (\(signature))")
        }

        isMOD = true
        title = header.dos(at: 0, length: 20)
        song.antChn = UInt8(channels)
        song.len = UInt16(ha[950])
        song.repS = UInt16(ha[951])
        for i in 0 ..< 128 { song.songTab[i] = ha[952 + i] }
        song.antInstrs = 31
        song.tempo = 6
        song.speed = 125

        let last = Int(song.songTab[0 ..< 128].max() ?? 0)
        for a in 0 ... last {
            let bytes = f.read(channels * 4 * 64)
            guard !f.eof else { throw TuneError.malformed("a module that ends in its patterns") }
            var notes = [FT2Note](repeating: FT2Note(), count: channels * 64)
            for i in 0 ..< notes.count {
                let b = (bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3])
                var note = FT2Note()
                let period = UInt16(b.0 & 0x0F) << 8 | UInt16(b.1)
                for k in 0 ..< 96 where period >= ft2AmigaPeriod[k] {
                    note.ton = UInt8(k + 1)
                    break
                }
                note.instr = (b.0 & 0xF0) | (b.2 >> 4)
                note.effTyp = b.2 & 0x0F
                note.eff = b.3
                switch note.effTyp {
                case 0xC: if note.eff > 64 { note.eff = 64 }
                case 0x1, 0x2, 0xA: if note.eff == 0 { note.effTyp = 0 }
                case 0x5: if note.eff == 0 { note.effTyp = 3 }
                case 0x6: if note.eff == 0 { note.effTyp = 4 }
                default: break
                }
                notes[i] = note
            }
            patt[a] = notes
            pattLens[a] = 64
            if patternEmpty(a) { patt[a] = nil }
        }

        for a in 1 ... 31 {
            let at = 20 + (a - 1) * 30
            let len = 2 * header.u16be(at + 22)
            if len == 0 { continue }
            let ins = allocateInstr(a)
            var repS = 2 * header.u16be(at + 26), repL = 2 * header.u16be(at + 28)
            if repL <= 2 {
                repS = 0
                repL = 0
            }
            if repS + repL > len {
                if repS >= len {
                    repS = 0
                    repL = 0
                } else {
                    repL = len - repS
                }
            }
            ins.samp[0].typ = repL > 2 ? 1 : 0
            ins.samp[0].len = Int32(len)
            ins.samp[0].vol = min(64, ha[at + 25])
            ins.samp[0].fine = Int8(truncatingIfNeeded: 8 * ((2 * (Int(ha[at + 24] & 15) ^ 8)) - 16))
            ins.samp[0].repL = Int32(repL)
            ins.samp[0].repS = Int32(repS)
            cutShort.add(length: len, there: f.eof ? 0 : f.data.count - f.at)
            ins.samp[0].pek = sampleMemory(f.read(len))
        }
    }
}
