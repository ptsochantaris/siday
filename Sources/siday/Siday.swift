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

@main
struct Siday: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "siday",
        abstract: "Plays AY/YM, Atari ST and SID chiptunes and MOD, XM and S3M modules from files and folders.",
        discussion: """
        Keys while playing: space pause · n or → next · p or ← previous · + and - subsong · q quit.
        Folders are searched recursively. The files are only ever read.
        """
    )

    @Argument(help: "Files or folders to play.")
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

    @Option(help: "The sound card an S3M file is played on: gus, or sb for a Sound Blaster Pro's eight bits. Default: the one the file was saved with.")
    var s3mCard: ST3Card?

    @Option(help: "Path to HVSC's Songlengths.md5, remembered for later runs. Also read from $SIDAY_SONGLENGTHS, and found automatically beside an HVSC tree. A tune it does not have, or any tune when there is no such file, gets the length that comes with the player.")
    var songlengths: String?

    @Option(help: "Render each tune to a WAV file in this folder instead of playing.")
    var wav: String?

    @Flag(help: "List what would be played, with format, length and title, and exit.")
    var list = false

    @Flag(help: "Load and render a few seconds of every file without sound; report per format.")
    var check = false

    @Flag(help: "Render at full speed and report the multiple of real time.")
    var bench = false

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
        if paths.isEmpty, !testTone, zex == nil, sidTrace == nil {
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
            var renderer = try tuneFiles.load(scan.files[0])
            let frames = Int((maxTime.flatMap(parseTime) ?? 20) * Double(outputSampleRate))
            // A YM file played on a chip of another machine has no reference output; for the comparison
            // it is played as the reference player plays every YM file, on the Atari ST's.
            if !(renderer is any ReferenceComparable), scan.files[0].pathExtension.lowercased() == "ym",
               let atari = STYMRenderer([UInt8](try Data(contentsOf: scan.files[0])), always: true) {
                renderer = atari
            }
            if let atari = renderer as? any ReferenceComparable {
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
            try play(scan.files)
        }
    }

    // MARK: Playing

    private func play(_ files: [URL]) throws {
        let ring = SampleRing(frames: 8192)
        let output = try AudioOutput(ring: ring)
        let engine = Engine(ring: ring, playlist: files, files: tuneFiles, policy: policy, television: self.output.television)
        Terminal.enterKeyMode()
        engine.start()

        var generation = 0
        var length = 0.0
        var paused = false
        var statusShown = false
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
            case nil: break
            }
            let state = engine.nowPlaying.withLock { state -> NowPlaying in
                let copy = state
                state.messages.removeAll()
                return copy
            }
            for message in state.messages {
                clearStatus()
                print(message)
            }
            if state.generation != generation {
                generation = state.generation
                length = state.length
                clearStatus()
                print(state.header)
            }
            if state.finished { break loop }
            if Terminal.interactive, generation > 0 {
                let played = Double(ring.framesPlayed.load(ordering: .relaxed)) / Double(outputSampleRate)
                print("\r  \(formatTime(played)) / \(formatTime(length))\(paused ? "  paused" : "")\u{1B}[K", terminator: "")
                fflush(stdout)
                statusShown = true
            }
        }
        clearStatus()
        fflush(stdout)
        output.stop()
        Terminal.restore()
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
        // Loading can mean running a tune silently to find its length, so files are loaded on every core,
        // a batch at a time, and printed in order.
        let batch = 256
        for start in stride(from: 0, to: files.count, by: batch) {
            let slice = files[start ..< min(start + batch, files.count)]
            let lines = Mutex([String](repeating: "", count: slice.count))
            DispatchQueue.concurrentPerform(iterations: slice.count) { i in
                let url = slice[slice.startIndex + i]
                let line: String
                do {
                    let renderer = try loader.load(url)
                    let session = TuneSession(renderer: renderer, policy: policy)
                    let length = renderer.knownLength == nil ? "  ?  " : formatTime(session.displayLength).leftPadded(to: 5)
                    let songs = renderer.subsongCount > 1 ? " [\(renderer.subsongCount) songs]" : ""
                    let text = describe(renderer.info)
                    line = "\(renderer.info.format.padding(toLength: 4, withPad: " ", startingAt: 0)) \(length)  \(text.isEmpty ? "" : text + "  ")\(url.path)\(songs)"
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
        for url in files {
            do {
                let renderer = try tuneFiles.load(url)
                let first = policy.allSubsongs ? 0 : policy.firstSubsong(of: renderer)
                let last = policy.allSubsongs ? renderer.subsongCount - 1 : first
                for subsong in first ... last {
                    if renderer.subsongCount > 1 { renderer.select(subsong: subsong) }
                    let session = TuneSession(renderer: renderer, policy: policy)
                    var writer = WAVWriter()
                    var television = output.television.map { Television($0) }
                    while !session.finished {
                        let produced = session.render(into: buffer, frames: block)
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
            do {
                let renderer = try loader.load(url)
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
        print("format     ok  silent  rejected  bad")
        for (format, tally) in tallies.sorted(by: { $0.key < $1.key }) {
            print(String(format: "%-6@ %6d  %6d  %8d  %3d", format as NSString, tally.ok, tally.silent, tally.rejected, tally.bad))
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
