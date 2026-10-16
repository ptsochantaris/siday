// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import ArgumentParser
import SidayKit
import Foundation
import Synchronization

extension OutputStyle: ExpressibleByArgument {}
extension AYChipType: ExpressibleByArgument {}
extension SIDModelChoice: ExpressibleByArgument {}
extension SIDEngineChoice: ExpressibleByArgument {}
extension AmigaModel: ExpressibleByArgument {}
extension ST3Card: ExpressibleByArgument {}
extension Levelling: ExpressibleByArgument {}

@main
struct Siday: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "siday",
        abstract: "Plays AY/YM, Atari ST and SID chiptunes, MOD, MED, SFX, OKT, AHX, HVL, DBM, XM, S3M, IT, MPTM, MT2, MTM, DTM, AMF, GDM, PTM, ULT, 669, STM, STX, FAR, C67, MDL, DMF, IMF, AMS, PLM, DSM, DIGI and J2B modules and CMF, ROL, FMT and VGM tunes for the AdLib and Sound Blaster from files, folders and playlists.",
        discussion: """
        Keys while playing: space pause · n or → next · p or ← previous · + and - subsong · i the format's story · q quit.
        Each voice of a tune has a light on the status line. 1 to 9, and 0 for the tenth, leave a voice out or bring it back; [ and ] choose one, m leaves it out or brings it back, and s plays it alone (s again brings the others back). A voice left out goes on playing, unheard, and the tune is as long as it is whole. Every tune starts with all its voices.
        Folders are searched recursively. The files are only ever read.
        A playlist (Ay_Emul's AYL) plays the tunes it names, in its order. In a folder, the playlists add only the tunes the folder does not itself hold.
        """
    )

    @Argument(help: "Files, folders or playlists to play.")
    var paths: [String] = []

    @Flag(help: "Play in random order.")
    var shuffle = false

    @Option(help: "Only these formats, comma-separated (for example pt3,stc,sid).")
    var formats: String?

    @Option(help: "Only files whose path contains this text (case-insensitive).")
    var match: String?

    @Option(help: "Passes through a looping tune before it fades.")
    var loops = 1

    @Option(help: "Seconds of fade-out for a tune still playing where it ends (never longer than the tune itself).")
    var fade = 20.0

    @Option(help: "Time given to tunes whose length is unknown (m:ss).")
    var defaultTime = "3:00"

    @Option(help: "Cap on any tune's playing time (m:ss).")
    var maxTime: String?

    @Flag(help: "Play every song in multi-song files instead of only the file's start song.")
    var allSubsongs = false

    @Option(help: "AY chip type: ay or ym. Default: what the file says, otherwise ay.")
    var chip: AYChipType?

    @Option(help: "What the tune is heard through: mono; abc or acb, the AY chip's three channels spread across the stereo field (a SID has one output, so for a SID tune these are mono); or the speaker of an early-1980s television, plastic (a small portable) or wood (a large set in a wooden cabinet).")
    var output: OutputStyle = .mono

    @Option(help: "AY clock in Hz. Default: what the file says, otherwise 1773400.")
    var clock: Double?

    @Option(help: "AY player interrupt rate in Hz. Default: what the file says, otherwise 50.")
    var frameRate: Double?

    @Option(help: "SID model: auto, 6581 or 8580.")
    var sidModel: SIDModelChoice = .auto

    @Option(help: "SID emulation: residfp, or the lighter resid.")
    var sidEngine: SIDEngineChoice = .residfp

    @Option(help: "Where the 6581's filter sits, from 0 (bright) to 1 (dark); real chips varied. residfp only.")
    var sidFilterCurve = 0.5

    @Option(help: "Which Amiga a module is heard on: a1200, or a500 with its muffling filter.")
    var amiga: AmigaModel = .a1200

    @Option(help: "How far apart a module's left and right are kept, in percent. 100 is the Amiga's own, which is harsh in headphones.")
    var amigaSeparation = 20.0

    @Option(help: "How far apart the left and right of a recording from the first Sound Blaster Pro or the Creative Music System (a VGM file of their chips) are kept, in percent. 100 is the card's own, which is harsh in headphones.")
    var sbProSeparation = 20.0

    @Option(help: "The sound card an S3M file is played on: gus, or sb for a Sound Blaster Pro's eight bits. Default: the one the file was saved with.")
    var s3mCard: ST3Card?

    @Option(help: "Bring every tune to the same loudness: off, full, or partial (halfway there, so that a quiet tune is still quieter than a loud one, but not by as much). Each song is measured as it plays, by playing it through unheard, and the next while it plays; what is found is kept for later runs. A song is turned up by no more than 6 dB. With --list, says how far each tune would be turned up or down. Default: off, each tune as loud as its file has it.")
    var level: Levelling = .off

    @Option(help: "Path to HVSC's Songlengths.md5, remembered for later runs. Also read from $SIDAY_SONGLENGTHS, and found automatically beside an HVSC tree. A tune it does not have, or any tune when there is no such file, gets the length that comes with the player.")
    var songlengths: String?

    @Option(help: "Render each tune to a WAV file in this folder instead of playing.")
    var wav: String?

    @Flag(help: "List what would be played, with format, length and title, and exit. A * after the length marks a tune that is not played quite as its file asks: an instrument that is not heard, a command that is left out, a file that is cut short.")
    var list = false

    @Flag(help: "With --list, say under each tune marked * what it is that is not played as its file asks.")
    var shortfalls = false

    @Flag(help: "Load and render a few seconds of every file without sound; report per format. The last column counts the tunes that --list would mark.")
    var check = false

    @Flag(help: "Render at full speed and report the multiple of real time.")
    var bench = false

    @Option(help: "Leave these voices out of every tune, played or rendered to WAV, by number from 1, comma-separated (for example 2,4). They are numbered as the lights on the status line.")
    var mute: String?

    @Option(help: "Hear only this voice of every tune, played or rendered to WAV, by number from 1.")
    var solo: Int?

    @Option(help: "Print what siday's FORMATS.md says of a format, given by its name (for example it or pt3) or by a file of it, and exit.")
    var about: String?

    @Option(help: "Start multi-song files at this song number instead of the file's own start song.")
    var subsong: Int?

    @Option(help: .hidden)
    var dumpAy: Int?

    /// Prints every SID register write in the first N seconds as "cycle register value".
    @Option(help: .hidden)
    var dumpSid: Double?

    @Flag(help: .hidden)
    var testTone = false

    /// Runs a CP/M program (ZEXDOC, ZEXALL) on the Z80 core and prints its output and T-state total.
    @Option(help: .hidden)
    var zex: String?

    /// Prints every AY register write and beeper change of the first file (an .ay) for this many frames,
    /// for the song chosen with --subsong.
    @Option(help: .hidden)
    var ayLog: Int?

    /// Prints, for every song of every ZXAYEMUL file, the length the file states and the length a silent run finds.
    @Flag(help: .hidden)
    var ayLengths = false

    /// Renders a SID register-write trace through SIDChip (see SIDTrace.swift). An empty path prints table digests only.
    @Option(help: .hidden)
    var sidTrace: String?

    /// model=6581|8580,clock=<Hz>,rate=<Hz>,sampling=fast|interpolate|resample|fastmem,out=<file>,readback=<file>,reads=<file>,tables,bench,repeat=<n>
    @Option(help: .hidden)
    var sidTraceOptions = ""

    /// Writes raw Float32 stereo for the first file, for comparison against reference emulators.
    @Option(help: .hidden)
    var raw: String?

    func validate() throws {
        if paths.isEmpty, !testTone, zex == nil, sidTrace == nil, about == nil {
            throw ValidationError("Give at least one file or folder.")
        }
        if !(0 ... 1).contains(sidFilterCurve) { throw ValidationError("--sid-filter-curve should be between 0 and 1") }
        if !(0 ... 120).contains(fade) { throw ValidationError("--fade should be between 0 and 120 seconds") }
        if parseTime(defaultTime) == nil { throw ValidationError("--default-time should look like 3:00") }
        if let maxTime, parseTime(maxTime) == nil { throw ValidationError("--max-time should look like 5:00") }
        if loops < 1 { throw ValidationError("--loops must be at least 1") }
        if let subsong, subsong < 1 { throw ValidationError("--subsong counts from 1") }
        if let songlengths, !FileManager.default.fileExists(atPath: (songlengths as NSString).expandingTildeInPath) {
            throw ValidationError("--songlengths: no file at \(songlengths)")
        }
    }

    /// How tunes are loaded: the emulation's options, and where to look for song lengths.
    private var tuneFiles: TuneFiles {
        var options = LoadOptions()
        options.stereo = output.stereo
        options.chipType = chip
        options.clockHz = clock
        options.frameHz = frameRate
        options.sidModel = sidModel
        options.sidEngine = sidEngine
        options.amigaModel = amiga
        options.amigaSeparation = amigaSeparation / 100
        options.sbProSeparation = sbProSeparation / 100
        options.s3mCard = s3mCard
        options.sidFilterCurve = sidFilterCurve
        return TuneFiles(options: options, songLengthsPath: songLengthsPath)
    }

    /// The file named with `--songlengths`, when it is a song-length database.
    private var namedSongLengths: String? {
        guard let songlengths else { return nil }
        let path = URL(fileURLWithPath: (songlengths as NSString).expandingTildeInPath).standardizedFileURL.path
        return SongLengthFiles.database(atPath: path) != nil ? path : nil
    }

    /// The song-length database to use: the one named now, the environment's, or the remembered one.
    private var songLengthsPath: String? {
        namedSongLengths ?? ProcessInfo.processInfo.environment["SIDAY_SONGLENGTHS"]
            ?? UserDefaults(suiteName: "siday")?.string(forKey: "songlengths")
    }

    /// Remembers the database named now for later runs. A file that is not one is passed over and not
    /// remembered: it would hide every tune's length, in this run and in each one after it.
    private func rememberSongLengths() {
        guard let songlengths else { return }
        if let path = namedSongLengths {
            UserDefaults(suiteName: "siday")?.set(path, forKey: "songlengths")
        } else {
            FileHandle.standardError.write(Data("siday: --songlengths: no song lengths in \(songlengths); not used, and not remembered\n".utf8))
        }
    }

    /// The voices asked to be left out of every tune.
    private var leftOut: LeftOut {
        var leftOut = LeftOut()
        leftOut.voices = Set((mute ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }.map { $0 - 1 })
        leftOut.alone = solo.flatMap { $0 > 0 ? $0 - 1 : nil }
        return leftOut
    }

    private var policy: PlaybackPolicy {
        var policy = PlaybackPolicy()
        policy.loops = loops
        policy.loopFade = fade
        policy.defaultTime = parseTime(defaultTime) ?? 180
        policy.maxTime = maxTime.flatMap(parseTime)
        policy.allSubsongs = allSubsongs
        policy.startSubsong = subsong.map { $0 - 1 }
        return policy
    }

    func run() throws {
        if let about {
            // A format by its name, or by a file's.
            let format = TuneFormat(rawValue: about.lowercased()) ?? TuneFormat(url: URL(fileURLWithPath: (about as NSString).expandingTildeInPath))
            guard let format, let story = FormatStories.setOut(on: format, width: Terminal.width, bold: Terminal.interactive) else {
                throw ValidationError("--about: no format called '\(about)'. Known: \(TuneFormat.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            print(story)
            return
        }
        if let sidTrace {
            try SIDTrace.run(trace: sidTrace, options: sidTraceOptions)
            return
        }
        if testTone {
            try playTestTone()
            return
        }
        if let zex {
            let program = try [UInt8](Data(contentsOf: URL(fileURLWithPath: zex)))
            let start = DispatchTime.now().uptimeNanoseconds
            let result = Z80CPM.run(program: program) { text in
                FileHandle.standardOutput.write(Data(text.utf8))
            }
            let taken = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            print("\n\(result.instructions) instructions, \(result.tstates) T-states, \(String(format: "%.1f", taken)) s")
            return
        }

        rememberSongLengths()
        var wanted = Set(TuneFormat.allCases)
        if let formats {
            wanted = []
            for name in formats.lowercased().split(separator: ",") {
                guard let format = TuneFormat(rawValue: String(name)) else {
                    throw ValidationError("Unknown format '\(name)'. Known: \(TuneFormat.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                wanted.insert(format)
            }
        }
        var scan = Scanner(formats: wanted, match: match).scan(paths)
        for problem in scan.problems { FileHandle.standardError.write(Data("siday: \(problem)\n".utf8)) }
        guard !scan.files.isEmpty else {
            throw ValidationError("Nothing to play.")
        }
        if shuffle { scan.files.shuffle() }

        if ayLengths {
            for url in scan.files {
                guard let renderer = try? tuneFiles.load(url) as? AYFileRenderer else { continue }
                for (song, lengths) in renderer.lengthSurvey().enumerated() {
                    print("\(lengths.stated)\t\(lengths.measured)\t\(song)\t\(url.path)")
                }
            }
        } else if let ayLog {
            try dumpAYPortLog(scan.files[0], frames: ayLog)
        } else if let dumpAy {
            try dumpRegisters(scan.files[0], frames: dumpAy)
        } else if let dumpSid {
            let renderer = try tuneFiles.load(scan.files[0])
            guard let logger = renderer as? any SIDWriteLogging else {
                throw ValidationError("\(scan.files[0].lastPathComponent) is not a SID tune")
            }
            if let subsong { renderer.select(subsong: subsong - 1) }
            var text = ""
            if ProcessInfo.processInfo.environment["SIDAY_HARDWARE_READS"] != nil, let sid = renderer as? SIDRenderer {
                for (address, value) in sid.dumpHardwareReads(seconds: dumpSid) {
                    text += String(format: "%04x %02x\n", address, value)
                }
                FileHandle.standardOutput.write(Data(text.utf8))
                return
            }
            for (cycle, register, value) in logger.dumpWrites(seconds: dumpSid) {
                text += "\(cycle) \(String(format: "%02x %02x", register, value))\n"
            }
            FileHandle.standardOutput.write(Data(text.utf8))
        } else if let raw {
            ST3Player.repeatsReferenceSlips = ProcessInfo.processInfo.environment["SIDAY_REFERENCE_SLIPS"] != nil
            ITRenderer.roundsRatesAsLibxmp = ProcessInfo.processInfo.environment["SIDAY_RATES_AS_LIBXMP"] != nil
            var renderer = try tuneFiles.load(scan.files[0])
            let frames = Int((maxTime.flatMap(parseTime) ?? 20) * Double(outputSampleRate))
            // A YM file played on a chip of another machine has no reference output; for the comparison
            // it is played as the reference player plays every YM file, on the Atari ST's.
            if !(renderer is any ReferenceComparable), scan.files[0].pathExtension.lowercased() == "ym",
               let atari = STYMRenderer([UInt8](try Data(contentsOf: scan.files[0])), always: true) {
                renderer = atari
            }
            // HivelyTracker's replayer plays AHX files too. To compare this player's port of it with
            // it on those, an AHX file is played as that replayer plays one, with the Amiga's two
            // sides as far apart as the variable says, from 0 (together) to 4.
            if let apart = ProcessInfo.processInfo.environment["SIDAY_AHX_AS_HIVELY"].flatMap({ Int($0) }),
               scan.files[0].pathExtension.lowercased() == "ahx" {
                renderer = try HVLRenderer([UInt8](try Data(contentsOf: scan.files[0])), options: tuneFiles.options, ahxStereo: apart)
            }
            // OctaMED's player for its mixing mode gets three things wrong, which this one puts
            // right. To compare the sound of the two, a MED file is played with them wrong.
            if ProcessInfo.processInfo.environment["SIDAY_MED_AS_OCTAMED"] != nil, let med = renderer as? MEDRenderer {
                med.makesOctaMEDsMistakes = true
            }
            // What FastTracker's replayer was given to play, as text: an XM or a MOD file as it reads
            // them, or an MTM, a DTM or an AMF file as this player's loaders made of them.
            if ProcessInfo.processInfo.environment["SIDAY_FT2_LISTING"] != nil, let module = renderer as? XMRenderer {
                FileHandle.standardOutput.write(Data(module.listing().utf8))
                return
            }
            if let trace = ProcessInfo.processInfo.environment["SIDAY_MED_TRACE"], let med = renderer as? MEDRenderer {
                // What the player tells the sound chip, a line a tick, for setting beside what
                // OctaMED's own player tells it: the tick's number, how long the tick before it
                // lasted in the chip's clocks, where the tune was (block, line and tick of the line),
                // and for each voice its period, its volume, and where a note was started and is to
                // go on from (an instrument, a place in it, and words).
                // The variable's value is which of the file's own songs, counting from 1, to be
                // played from its top; or the song asked for by number is, if one is.
                if let subsong { renderer.select(subsong: subsong - 1) }
                let fileSong = subsong == nil ? Int(trace).map { max(0, $0 - 1) } : nil
                // (A song in mixing mode has no sound chip to be told anything. What is written for
                // it is what the mixer is told, in order, a line for each thing: what it was (the
                // kinds of `MEDMixEvent`, numbered from nought), which track, and six numbers; after
                // a first line of what the song says of its mixing.)
                let events = med.mixEvents(seconds: maxTime.flatMap(parseTime) ?? 20, fileSong: fileSong)
                if !events.isEmpty {
                    var lines = "mix " + med.mixSettings.map(String.init).joined(separator: " ") + "\n"
                    for event in events {
                        lines += "\(event.kind.rawValue) \(event.track) \(event.a) \(event.b) \(event.c) \(event.d) \(event.e) \(event.f)\n"
                    }
                    FileHandle.standardOutput.write(Data(lines.utf8))
                    return
                }
                var text = ""
                var before = 0
                // (And for a module of five to eight channels, what was mixed for each voice on each
                // tick, as bytes one after another, is written to the file SIDAY_MED_MIXED names:
                // for each tick and each voice, how many bytes, in two bytes, and then the bytes.)
                var mixed = Data()
                func place(_ stretch: MEDRegisterTick.Stretch) -> String {
                    (stretch.instrument == 0 ? "z" : "\(stretch.instrument)+\(stretch.offset)") + ":\(stretch.words)"
                }
                for (number, tick) in med.registerTicks(seconds: maxTime.flatMap(parseTime) ?? 20, fileSong: fileSong).enumerated() {
                    let voices = tick.voices.map { voice in
                        "P\(voice.period.map(String.init) ?? "-") V\(voice.volume.map(String.init) ?? "-")"
                            + (voice.start.map { " S" + place($0) } ?? "") + (voice.loop.map { " L" + place($0) } ?? "")
                            + (voice.waveform.map { " W\($0.place):\($0.words)" } ?? "")
                    }
                    text += "\(number) \(before) \(tick.block):\(tick.line).\(tick.tickOfLine) | " + voices.joined(separator: " | ")
                        + (tick.mixedWords != 0 ? " | M\(tick.mixedWords)" : "") + "\n"
                    before = tick.clocks
                    for voice in tick.mixed where tick.mixedWords != 0 {
                        mixed.append(contentsOf: [UInt8(voice.count & 0xFF), UInt8(voice.count >> 8)])
                        mixed.append(contentsOf: voice.map { UInt8(bitPattern: $0) })
                    }
                }
                FileHandle.standardOutput.write(Data(text.utf8))
                if let path = ProcessInfo.processInfo.environment["SIDAY_MED_MIXED"] { try mixed.write(to: URL(fileURLWithPath: path)) }
                return
            }
            if ProcessInfo.processInfo.environment["SIDAY_MODULE_LISTING"] != nil, let module = renderer as? ITRenderer {
                // What was read from a module that Impulse Tracker's replayer plays, as text, for
                // setting beside what another player made of the same file: a GDM or a PTM file
                // above all, which are not that replayer's own.
                let listing = module.listing()
                var text = "speed \(listing.speed) tempo \(listing.tempo) gvol \(listing.globalVolume)\n"
                text += "orders " + listing.orders.map(String.init).joined(separator: " ") + "\n"
                text += "pans " + listing.pans.map(String.init).joined(separator: " ") + "\n"
                for (index, sample) in listing.samples.enumerated() {
                    text += "ins \(index + 1) len \(sample.length) lps \(sample.loopStart) lpe \(sample.loopEnd) loop \(sample.loops ? 1 : 0)"
                        + " bidir \(sample.backAndForth ? 1 : 0) bits \(sample.sixteenBit ? 16 : 8) vol \(sample.volume) rate \(sample.rate)"
                        + " pan \(sample.pan) sum \(sample.sum)\n"
                }
                for cell in listing.cells {
                    text += "\(cell.pattern) \(cell.row) \(cell.channel): n\(cell.note) i\(cell.instrument) v\(cell.volume) c\(cell.command):\(cell.value)\n"
                }
                // (And with the variable set to "openmpt", the rest of what an IT or an MPTM file
                // says, for setting beside what OpenMPT made of the file: the song's settings and
                // its lists of patterns, the channels, the rest of each sample, the instruments with
                // their envelopes, and each pattern's length and time.)
                if ProcessInfo.processInfo.environment["SIDAY_MODULE_LISTING"] == "openmpt" {
                    var more = module.info.shortfalls.map { "shortfall " + $0 }
                    if let song = listing.openMPT {
                        more.append("song mode \(song.tempoMode) rpb \(song.rowsPerBeat) ceiling \(song.tempoCeiling) softpan \(song.softPanning ? 1 : 0) mixvol \(listing.mixVolume)"
                            + " seqs \(song.sequences.count) swing " + song.swing.map(String.init).joined(separator: ","))
                        for (index, sequence) in song.sequences.enumerated() {
                            more.append("seq \(index) count \(sequence.count) restart \(sequence.restart - sequence.first) speed \(sequence.speed) tempo \(sequence.tempo) : "
                                + listing.orders[sequence.first ..< min(listing.orders.count, sequence.first + sequence.count)].map(String.init).joined(separator: " "))
                        }
                        for pattern in song.patterns {
                            more.append("pat \(pattern.number) rows \(pattern.rows) rpb \(pattern.rowsPerBeat) swing " + pattern.swing.map(String.init).joined(separator: ","))
                        }
                        for long in song.longValues.sorted(by: { ($0.pattern, $0.row, $0.channel) < ($1.pattern, $1.row, $1.channel) }) {
                            more.append("long \(long.pattern) \(long.row) \(long.channel) \(long.value) \(long.rows)")
                        }
                    }
                    for channel in listing.pans.indices {
                        more.append("chn \(channel) pan \(listing.pans[channel]) vol \(listing.channelVolumes[channel])")
                    }
                    for (index, sample) in listing.samples.enumerated() {
                        more.append("smpx \(index + 1) gvol \(sample.globalVolume) sus \(sample.sustainStart) sue \(sample.sustainEnd) susloop \(sample.sustains ? 1 : 0)"
                            + " susbidir \(sample.sustainBackAndForth ? 1 : 0) stereo \(sample.stereo ? 1 : 0) sound \(sample.hasSound ? 1 : 0)"
                            + " vs \(sample.vibratoSpeed) vd \(sample.vibratoDepth) vr \(sample.vibratoRate) vw \(sample.vibratoWave)")
                    }
                    func envelope(_ name: String, _ index: Int, _ e: ModuleListing.Envelope) -> String {
                        "env \(index + 1) \(name) flags \(e.flags) num \(e.ticks.count) ls \(e.loopStart) le \(e.loopEnd) ss \(e.sustainStart) se \(e.sustainEnd) rel \(e.releaseNode) "
                            + zip(e.ticks, e.levels).map { "\($0):\($1)" }.joined(separator: " ")
                    }
                    for (index, instrument) in listing.instruments.enumerated() {
                        more.append("insx \(index + 1) nna \(instrument.newNoteAction) dct \(instrument.duplicateCheck) dca \(instrument.duplicateAction) fade \(instrument.fadeOut)"
                            + " gvol \(instrument.globalVolume) pan \(instrument.pan) pps \(instrument.pitchPanSeparation) ppc \(instrument.pitchPanCentre)"
                            + " rv \(instrument.randomVolume) rp \(instrument.randomPan) ifc \(instrument.cutoff) ifr \(instrument.resonance) midi \(instrument.midiChannel)")
                        more.append("map \(index + 1) " + zip(instrument.notes, instrument.samples).map { "\($0):\($1)" }.joined(separator: " "))
                        more.append(envelope("v", index, instrument.volume))
                        more.append(envelope("p", index, instrument.panning))
                        more.append(envelope("f", index, instrument.pitch))
                    }
                    text = more.joined(separator: "\n") + "\n" + text
                }
                FileHandle.standardOutput.write(Data(text.utf8))
                return
            }
            if ProcessInfo.processInfo.environment["SIDAY_MODULE_TICKS"] != nil, let module = renderer as? ITRenderer {
                // And what that replayer does with it, a line a tick: where the tune is, its tempo and
                // speed, and for each channel the rate its sample plays at, its volume and its place.
                var text = ""
                // (With the variable set to "frames", only where the tune is on each tick and how
                // many frames the tick lasts: for setting an MPTM file's timekeeping beside OpenMPT's.)
                if ProcessInfo.processInfo.environment["SIDAY_MODULE_TICKS"] == "frames" {
                    // (Of the song asked for by number, if one is; and its first line says where in the
                    // file's list of patterns that song starts.)
                    let song = (subsong ?? 1) - 1
                    text += "song \(song + 1) of \(module.subsongCount) starts at \(song >= 0 && song < module.songStarts.count ? module.songStarts[song] : 0)\n"
                    for tick in module.ticks(seconds: maxTime.flatMap(parseTime) ?? 20, song: song) {
                        text += "\(tick.order) \(tick.row) \(tick.frames) \(tick.speed) \(tick.tempo)\n"
                    }
                    FileHandle.standardOutput.write(Data(text.utf8))
                    return
                }
                for (number, tick) in module.ticks(seconds: maxTime.flatMap(parseTime) ?? 20).enumerated() {
                    text += "\(number) \(tick.order):\(tick.row) bpm\(tick.tempo) spd\(tick.speed) |"
                    for channel in tick.rates.indices { text += " \(tick.rates[channel])/\(tick.volumes[channel])/\(tick.pans[channel])" }
                    text += "\n"
                }
                FileHandle.standardOutput.write(Data(text.utf8))
                return
            }
            // (And for a DBM file, what DigiBooster 3's replayer does with it, a line a tick: see
            // `DBMRenderer.trace`.)
            if ProcessInfo.processInfo.environment["SIDAY_MODULE_TICKS"] != nil, let module = renderer as? DBMRenderer {
                if let subsong { renderer.select(subsong: subsong - 1) }
                let lines = module.trace(seconds: maxTime.flatMap(parseTime) ?? 20)
                FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                return
            }
            // (And so for a SoundFX or an Oktalyzer module: see `amigaRoutineTrace`.)
            if let text = try amigaRoutineTrace(of: renderer, subsong: subsong, seconds: maxTime.flatMap(parseTime) ?? 20) {
                FileHandle.standardOutput.write(Data(text.utf8))
                return
            }
            // (With SIDAY_RAW_AS_HEARD set, what is written is what is heard, as numbers with a point and
            // not as a reference player would write it: for setting the web player's sound beside this one's.)
            if let atari = renderer as? any ReferenceComparable, ProcessInfo.processInfo.environment["SIDAY_RAW_AS_HEARD"] == nil {
                // The machine's own sixteen-bit output as the reference player writes it: one channel, or
                // for a module two.
                if let subsong { renderer.select(subsong: subsong - 1) }
                print("length \(renderer.knownLength.map { Int(($0 * Double(outputSampleRate)).rounded()) } ?? -1)")
                try atari.renderRaw(frames: frames).withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: raw))
                return
            }
            var samples = [Float](repeating: 0, count: frames * 2)
            samples.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: frames) }
            try samples.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: raw))
        } else if list {
            listFiles(scan.files)
        } else if check {
            checkFiles(scan.files)
        } else if bench {
            benchFiles(scan.files)
        } else if let wav {
            try renderWAVs(scan.files, to: wav)
        } else {
            try play(scan.files, notes: scan.notes)
        }
    }

    // MARK: Playing

    private func play(_ files: [URL], notes: [URL: String]) throws {
        let ring = SampleRing(frames: 8192)
        let output = try AudioOutput(ring: ring)
        let levels = level == .off ? nil : Levels(files: tuneFiles, policy: policy)
        levels?.start()
        let engine = Engine(ring: ring, playlist: files, files: tuneFiles, policy: policy, television: self.output.television, leftOut: leftOut,
                            levelling: level, levels: levels)
        Terminal.enterKeyMode()
        engine.start()

        var generation = 0
        var length = 0.0
        var paused = false
        var statusShown = false
        /// The voice that m and s are for, once one has been chosen; shown on the status line.
        var chosen: Int?
        var voices = 0
        var muted: [Bool] = []
        /// Which of the files is playing.
        var playing = -1
        func clearStatus() {
            if statusShown, Terminal.interactive { print("\r\u{1B}[K", terminator: "") }
            statusShown = false
        }
        loop: while true {
            let key = Terminal.readKey(timeout: 100)
            switch key {
            case .quit: engine.send(.quit)
            case .next: engine.send(.next)
            case .previous: engine.send(.previous)
            case .nextSubsong: engine.send(.nextSubsong)
            case .previousSubsong: engine.send(.previousSubsong)
            case .pause:
                paused.toggle()
                ring.paused.store(paused, ordering: .relaxed)
            case let .voice(voice):
                if voice < voices { engine.send(.mute(voice)) }
            case let .choose(step):
                if voices > 0 { chosen = ((chosen ?? (step > 0 ? -1 : voices)) + step + voices) % voices }
            case .muteChosen:
                if let chosen { engine.send(.mute(chosen)) }
            case .soloChosen:
                if let chosen { engine.send(.solo(chosen)) }
            case .about:
                // The playing tune's format's story, above the status line.
                if files.indices.contains(playing), let format = TuneFormat(url: files[playing]),
                   let story = FormatStories.setOut(on: format, width: Terminal.width, bold: true) {
                    clearStatus()
                    print(story + "\n")
                }
            case nil: break
            }
            let state = engine.nowPlaying.withLock { state -> NowPlaying in
                let copy = state
                state.messages.removeAll()
                for voice in state.levels.indices { state.levels[voice] = 0 }
                return copy
            }
            voices = state.levels.count
            muted = state.muted
            for message in state.messages {
                clearStatus()
                print(message)
            }
            if state.generation != generation {
                generation = state.generation
                playing = state.index
                length = state.length
                chosen = nil
                clearStatus()
                print(state.header)
                // What the playlist it came from says about it.
                if files.indices.contains(state.index), let note = notes[files[state.index]] { print("  \u{201C}\(note)\u{201D}") }
                // What is not played as the file asks, under the tune's own line.
                for shortfall in state.shortfalls { print("  \(shortfall)") }
            }
            if state.finished { break loop }
            if Terminal.interactive, generation > 0 {
                let played = Double(ring.framesPlayed.load(ordering: .relaxed)) / Double(outputSampleRate)
                var time = "  \(formatTime(played)) / \(formatTime(length))"
                if level != .off { time += state.levelChange.map { String(format: "  %+.1f dB", $0) } ?? "  … dB" }
                let lights = Self.lights(state.levels, muted: muted, chosen: chosen, room: Terminal.width - time.count - 12)
                print("\r\(time)\(lights.isEmpty ? "" : "  " + lights)\(paused ? "  paused" : "")\u{1B}[K", terminator: "")
                fflush(stdout)
                statusShown = true
            }
        }
        clearStatus()
        fflush(stdout)
        output.stop()
        Terminal.restore()
    }

    /// A light for each voice, as on the web player's page but in a line of text: a bar as tall as the
    /// voice is loud, faint for a voice left out, and the chosen voice shown the other way round.
    /// Four to a group, so that a voice can be counted to. As many groups as there is room for.
    static func lights(_ levels: [Float], muted: [Bool], chosen: Int?, room: Int) -> String {
        let bars = Array("▁▂▃▄▅▆▇█")
        var text = "", width = 0
        for voice in levels.indices {
            if voice > 0, voice % 4 == 0 {
                if width + 6 > room {
                    text += " …"
                    break
                }
                text += " "
                width += 1
            }
            var light = String(bars[max(0, min(bars.count - 1, Int(levels[voice] * Float(bars.count))))])
            if voice < muted.count, muted[voice] { light = "\u{1B}[2m" + light + "\u{1B}[22m" }
            if voice == chosen { light = "\u{1B}[7m" + light + "\u{1B}[27m" }
            text += light
            width += 1
        }
        return text
    }

    private func playTestTone() throws {
        let ring = SampleRing(frames: 8192)
        let output = try AudioOutput(ring: ring)
        print("Playing a 440 Hz tone for two seconds, left then right.")
        var buffer = [Float](repeating: 0, count: 512 * 2)
        var n = 0
        let total = outputSampleRate * 2
        while n < total {
            if ring.writableFrames < 512 {
                usleep(2000)
                continue
            }
            for i in 0 ..< 512 {
                let v = Float(sin(2 * Double.pi * 440 * Double(n + i) / Double(outputSampleRate))) * 0.25
                buffer[i * 2] = n < total / 2 ? v : 0
                buffer[i * 2 + 1] = n < total / 2 ? 0 : v
            }
            buffer.withUnsafeBufferPointer { ring.write($0.baseAddress!, frames: 512) }
            n += 512
        }
        while ring.bufferedFrames > 0 { usleep(2000) }
        usleep(100_000)
        output.stop()
    }

    // MARK: Tools

    private func listFiles(_ files: [URL]) {
        let loader = tuneFiles
        let policy = policy
        let explains = shortfalls
        let levels = level == .off ? nil : Levels(files: tuneFiles, policy: policy)
        // Loading can mean running a tune silently to find its length, so files are loaded on every core,
        // a batch at a time, and printed in order.
        let batch = 256
        for start in stride(from: 0, to: files.count, by: batch) {
            let slice = files[start ..< min(start + batch, files.count)]
            let lines = Mutex([String](repeating: "", count: slice.count))
            DispatchQueue.concurrentPerform(iterations: slice.count) { i in
                let url = slice[slice.startIndex + i]
                var line: String
                do {
                    let renderer = try loader.load(url)
                    let session = TuneSession(renderer: renderer, policy: policy)
                    let length = renderer.knownLength == nil ? "  ?  " : formatTime(session.displayLength).leftPadded(to: 5)
                    var songs = renderer.subsongCount > 1 ? " [\(renderer.subsongCount) songs]" : ""
                    if renderer.subsongCount > 1, policy.allSubsongs {
                        // Asked for every song: how long each is, where that is known.
                        let lengths = renderer.songs.map { $0.length.map { formatTime($0) } ?? "?" }
                        songs = " [\(renderer.subsongCount) songs: \(lengths.joined(separator: " "))]"
                    }
                    // Levelled, how far the song would be turned up or down: measured, unless it has been before.
                    if let levels, let level = levels.measure(url, song: policy.firstSubsong(of: renderer)) {
                        songs += String(format: "  %+.1f dB", level.change(self.level))
                    }
                    let text = describe(renderer.info)
                    // A tune that is not played quite as its file asks is marked, and with --shortfalls says why.
                    let mark = renderer.info.shortfalls.isEmpty ? " " : "*"
                    line = "\(renderer.info.format.padding(toLength: 4, withPad: " ", startingAt: 0)) \(length)\(mark) \(text.isEmpty ? "" : text + "  ")\(url.path)\(songs)"
                    if explains { for shortfall in renderer.info.shortfalls { line += "\n             \(shortfall)" } }
                } catch {
                    line = "----   -    \(url.path): \(error)"
                }
                lines.withLock { $0[i] = line }
            }
            for line in lines.withLock({ $0 }) { print(line) }
        }
    }

    private func renderWAVs(_ files: [URL], to folder: String) throws {
        let directory = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let block = 1024
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { buffer.deallocate() }
        // Levelled, each song is measured before it is written, and written at the level it needs.
        let levels = level == .off ? nil : Levels(files: tuneFiles, policy: policy)
        for url in files {
            do {
                let renderer = try tuneFiles.load(url)
                let first = policy.allSubsongs ? 0 : policy.firstSubsong(of: renderer)
                let last = policy.allSubsongs ? renderer.subsongCount - 1 : first
                for subsong in first ... last {
                    if renderer.subsongCount > 1 { renderer.select(subsong: subsong) }
                    let session = TuneSession(renderer: renderer, policy: policy)
                    // Voices left out: heard through another player of the song, as when playing.
                    let marks = leftOut.marks(renderer.channelCount)
                    if marks.contains(true) {
                        let twin = try tuneFiles.load(url)
                        if twin.subsongCount > 1 { twin.select(subsong: subsong) }
                        twin.setMuted(marks)
                        session.heard = twin
                    }
                    var writer = WAVWriter()
                    var television = output.television.map { Television($0) }
                    var gain = LevelGain(levels?.measure(url, song: subsong)?.gain(level) ?? 1)
                    while !session.finished {
                        let produced = session.render(into: buffer, frames: block)
                        gain.apply(buffer, frames: produced)
                        television?.process(buffer, frames: produced)
                        writer.append(buffer, frames: produced)
                    }
                    var name = url.deletingPathExtension().lastPathComponent + "." + url.pathExtension.lowercased()
                    if renderer.subsongCount > 1 { name += "-\(subsong + 1)" }
                    let target = directory.appendingPathComponent(name + ".wav")
                    guard !FileManager.default.fileExists(atPath: target.path) else {
                        print("exists, not overwritten: \(target.path)")
                        continue
                    }
                    try writer.write(to: target)
                    print("\(formatTime(session.elapsed).leftPadded(to: 5))  \(target.path)")
                }
            } catch {
                print("skipped \(url.lastPathComponent): \(error)")
            }
        }
    }

    private func benchFiles(_ files: [URL]) {
        let seconds = 60
        let block = 1024
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
        defer { buffer.deallocate() }
        var totalRendered = 0.0, totalTaken = 0.0
        for url in files.prefix(50) {
            guard let renderer = try? tuneFiles.load(url) else { continue }
            let start = DispatchTime.now().uptimeNanoseconds
            var frames = 0
            while frames < seconds * outputSampleRate {
                renderer.render(into: buffer, frames: block)
                frames += block
            }
            let taken = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            totalRendered += Double(seconds)
            totalTaken += taken
            print(String(format: "%7.0fx  %@  %@", Double(seconds) / taken, renderer.info.format, url.lastPathComponent))
        }
        if totalTaken > 0 {
            print(String(format: "%7.0fx  overall", totalRendered / totalTaken))
        }
    }

    private func checkFiles(_ files: [URL]) {
        struct Tally {
            var ok = 0, silent = 0, rejected = 0, bad = 0
            /// Tunes that load and are not played quite as their files ask (see `TuneInfo.shortfalls`).
            var marked = 0
            var notes: [String] = []
        }
        let loader = {
            var loader = tuneFiles
            loader.options.findsMissingLengths = false
            return loader
        }()
        let results = Mutex<[String: Tally]>([:])
        let done = Atomic<Int>(0)
        let seconds = 8
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            let url = files[i]
            let format = url.pathExtension.lowercased()
            var outcome = 0 // 0 ok, 1 silent, 2 rejected, 3 bad output
            var note: String?
            var marked = false
            do {
                let renderer = try loader.load(url)
                marked = !renderer.info.shortfalls.isEmpty
                let block = 1024
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: block * 2)
                defer { buffer.deallocate() }
                var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
                var broken = false
                var frames = 0
                while frames < seconds * outputSampleRate {
                    renderer.render(into: buffer, frames: block)
                    // The first half second is left out of the silence test: a SID settles from its power-on
                    // click, which would make a dead tune look alive.
                    let settled = frames >= outputSampleRate / 2
                    for k in 0 ..< block * 2 {
                        let v = buffer[k]
                        if !v.isFinite { broken = true }
                        if abs(v) > 4 { broken = true }
                        guard settled else { continue }
                        if v < low { low = v }
                        if v > high { high = v }
                    }
                    frames += block
                }
                if broken {
                    outcome = 3
                    note = "bad samples: \(url.path)"
                } else if high - low < 0.0005 {
                    outcome = 1
                    note = "silent: \(url.path)"
                }
            } catch {
                outcome = 2
                note = "\(error): \(url.path)"
            }
            results.withLock {
                var tally = $0[format, default: Tally()]
                switch outcome {
                case 0: tally.ok += 1
                case 1: tally.silent += 1
                case 2: tally.rejected += 1
                default: tally.bad += 1
                }
                if marked { tally.marked += 1 }
                if let note { tally.notes.append(note) }
                $0[format] = tally
            }
            let count = done.add(1, ordering: .relaxed).newValue
            if count % 2000 == 0 {
                FileHandle.standardError.write(Data("  \(count)/\(files.count)\n".utf8))
            }
        }
        let tallies = results.withLock { $0 }
        for (format, tally) in tallies.sorted(by: { $0.key < $1.key }) {
            for note in tally.notes.sorted() { print("\(format): \(note)") }
        }
        print("format     ok  silent  rejected  bad  marked")
        for (format, tally) in tallies.sorted(by: { $0.key < $1.key }) {
            print(String(format: "%-6@ %6d  %6d  %8d  %3d  %6d", format as NSString, tally.ok, tally.silent, tally.rejected, tally.bad, tally.marked))
        }
    }

    /// One line per AY register write (`W frame tstate register value`) and beeper change
    /// (`B frame tstate level`), then the register state at the end of each frame (`F frame bytes`).
    private func dumpAYPortLog(_ url: URL, frames: Int) throws {
        guard let renderer = try tuneFiles.load(url) as? AYFileRenderer else {
            throw ValidationError("\(url.lastPathComponent) is not a ZXAYEMUL file")
        }
        if let subsong { renderer.select(subsong: subsong - 1) }
        let (events, states) = renderer.portLog(frames: frames)
        var text = "# songs=\(renderer.subsongCount) song=\(renderer.currentSubsong) machine=\(renderer.machineKind)\n"
        var next = 0
        for (frame, state) in states.enumerated() {
            while next < events.count, events[next].frame <= frame {
                let event = events[next]
                text += event.register == 16
                    ? "B \(event.frame) \(event.tstate) \(event.value)\n"
                    : "W \(event.frame) \(event.tstate) \(event.register) \(String(format: "%02X", event.value))\n"
                next += 1
            }
            text += "F \(frame) " + state.map { String(format: "%02X", $0) }.joined() + "\n"
        }
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    private func dumpRegisters(_ url: URL, frames: Int) throws {
        let renderer = try tuneFiles.load(url)
        guard let dumper = renderer as? any AYRegisterDumping else {
            throw ValidationError("\(url.lastPathComponent) is not a frame-based AY tune")
        }
        var text = ""
        for frame in dumper.dumpFrames(maxFrames: frames) {
            text += frame.map { String(format: "%02X", $0) }.joined() + "\n"
        }
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
