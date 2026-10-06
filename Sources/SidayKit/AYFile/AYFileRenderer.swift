// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

/// Z80 clock of the ZX Spectrum 128 and its frame of 69,888 T-states at 50 Hz, as Ay_Emul uses.
public let ayFileSpectrumCPUHz = 3_494_400.0
/// Clocks used once Amstrad CPC port use has been seen.
public let ayFileCPCCPUHz = 4_000_000.0
public let ayFileCPCChipHz = 1_000_000.0
/// The interrupt line is held for this many T-states at the start of every frame.
public let ayFileInterruptTStates = 32
/// Level of the beeper, added to both output channels: twice one AY channel at full volume. That is the
/// ratio of the ZX Spectrum Next's mixer (512 for the beeper against 255 for a channel), which JNext
/// follows, and close to Fuse's 50 against 24. Ay_Emul's default is half this, which makes the AY sound
/// too loud against the beeper in tunes that use both. 146/255 is one AY channel's level in mono.
public let ayFileBeeperLevel = 2.0 * 146.0 / 255.0

/// One AY register write or beeper change, stamped with the T-state within its frame at which the Z80 made it.
struct AYPortEvent {
    static let beeper: UInt8 = 255
    var tstate: Int32
    /// 0...13, or `beeper`.
    var register: UInt8
    var value: UInt8
}

/// Which machine's sound ports a tune turned out to use.
public enum AYFileMachine: Sendable {
    /// Nothing has addressed an AY yet (a beeper-only tune stays here).
    case undetected
    case spectrum
    case cpc
}

/// One line of the port log tools use to compare against other players.
public struct AYPortLogEntry: Sendable {
    public var frame: Int
    public var tstate: Int
    /// 0...13 for an AY register write, 16 for a beeper change.
    public var register: Int
    /// The byte written, before the chip masks it; 0 or 1 for the beeper.
    public var value: UInt8
}

/// The hardware around the Z80: AY ports of the Spectrum and the CPC, and the Spectrum beeper.
/// Port decoding follows Ay_Emul's `InitialOutProc`, `ZXOutProc` and `CPCOutProc`, except that a CPC is
/// only recognised through the exact port addresses 0xF4xx and 0xF6xx (see `portOut`).
final class AYMachine: Z80Bus {
    private(set) var kind = AYFileMachine.undetected
    private var selected: UInt8 = 0
    private var cpcData: UInt8 = 0
    private var cpcControl: UInt8 = 0
    private(set) var beeperOn = false
    private(set) var beeperChanges = 0
    /// Register values as a program reads them back, masked the way Ay_Emul stores them.
    let registers: UnsafeMutablePointer<UInt8>
    let events: UnsafeMutablePointer<AYPortEvent>
    private let capacity: Int
    var eventCount = 0
    var frame = 0
    var log: [AYPortLogEntry]?

    init(eventCapacity: Int) {
        capacity = eventCapacity
        events = .allocate(capacity: eventCapacity)
        events.initialize(repeating: AYPortEvent(tstate: 0, register: 0, value: 0), count: eventCapacity)
        registers = .allocate(capacity: 16)
        registers.initialize(repeating: 0, count: 16)
    }

    deinit {
        events.deallocate()
        registers.deallocate()
    }

    func reset() {
        kind = .undetected
        selected = 0
        cpcData = 0
        cpcControl = 0
        beeperOn = false
        beeperChanges = 0
        registers.update(repeating: 0, count: 16)
        eventCount = 0
        frame = 0
    }

    @inline(__always) private func append(_ register: UInt8, _ value: UInt8, _ tstate: Int) {
        guard eventCount < capacity else { return }
        events[eventCount] = AYPortEvent(tstate: Int32(truncatingIfNeeded: tstate), register: register, value: value)
        eventCount &+= 1
    }

    @inline(__always) private func setBeeper(_ on: Bool, _ tstate: Int) {
        guard on != beeperOn else { return }
        beeperOn = on
        beeperChanges &+= 1
        append(AYPortEvent.beeper, on ? 1 : 0, tstate)
        log?.append(AYPortLogEntry(frame: frame, tstate: tstate, register: 16, value: on ? 1 : 0))
    }

    /// Writes the selected register, which the caller has checked is below 14.
    @inline(__always) private func writeSelected(_ value: UInt8, _ tstate: Int) {
        let register = selected
        var stored = value
        switch register {
        case 1, 3, 5, 13: stored &= 0x0F
        case 6, 8, 9, 10: stored &= 0x1F
        case 7: stored &= 0x3F
        default: break
        }
        log?.append(AYPortLogEntry(frame: frame, tstate: tstate, register: Int(register), value: value))
        // Writing register 13 restarts the envelope even when the value is the same.
        if register != 13, registers[Int(register)] == stored { return }
        registers[Int(register)] = stored
        append(register, value, tstate)
    }

    /// The CPC reaches its AY through an 8255: port A carries the data, the top two bits of port C say
    /// what to do with it. Returns true when a register was written.
    @inline(__always) private func cpcStrobe(_ tstate: Int) -> Bool {
        switch cpcControl {
        case 0xC0:
            selected = cpcData
        case 0x80:
            if selected < 14 {
                writeSelected(cpcData, tstate)
                return true
            }
        default:
            break
        }
        return false
    }

    func portOut(_ port: UInt16, value: UInt8, tstate: Int) {
        switch kind {
        case .spectrum:
            // The ULA answers every even port; bit 4 drives the speaker.
            if port & 1 == 0 { setBeeper(value & 0x10 != 0, tstate) }
            // Partial decoding as on the 128: A15, A14 and A1 only.
            if port & 0xC002 == 0xC000 {
                selected = value
            } else if port & 0xC002 == 0x8000, selected < 14 {
                writeSelected(value, tstate)
            }
        case .cpc:
            switch UInt8(truncatingIfNeeded: port >> 8) & 0x0B {
            case 0x00:
                cpcData = value
                _ = cpcStrobe(tstate)
            case 0x02:
                cpcControl = value & 0xC0
                _ = cpcStrobe(tstate)
            default:
                break
            }
        case .undetected:
            if port & 1 == 0 { setBeeper(value & 0x10 != 0, tstate) }
            // Ay_Emul looks for the 8255 with the CPC's partial decoding here as well, which lets a beeper
            // tune that happens to write 0x92 to port 0x92FE pass for a CPC (it does: "Prodigy" in the
            // Project AY set falls silent after a second). Until a machine is known only the addresses CPC
            // software really uses, 0xF4xx and 0xF6xx, are taken for the 8255.
            switch UInt8(truncatingIfNeeded: port >> 8) {
            case 0xF4:
                cpcData = value
                _ = cpcStrobe(tstate)
            case 0xF6:
                cpcControl = value & 0xC0
                if cpcStrobe(tstate) {
                    // A completed write through the 8255 is what identifies a CPC tune.
                    kind = .cpc
                    setBeeper(false, tstate)
                }
            default:
                if port & 0xC002 == 0xC000 {
                    kind = .spectrum
                    selected = value
                } else if port & 0xC002 == 0x8000, selected < 14 {
                    kind = .spectrum
                    writeSelected(value, tstate)
                }
            }
        }
    }

    func portIn(_ port: UInt16, tstate _: Int) -> UInt8 {
        if kind != .cpc, port & 0xC002 == 0xC000, selected < 14 {
            return registers[Int(selected)]
        }
        return 0xFF
    }
}

/// Plays one song of a ZXAYEMUL file by running its Z80 code against an AY chip and a beeper.
public final class AYFileRenderer: Renderer {
    private let file: AYFile
    private let options: LoadOptions
    private let memory: UnsafeMutablePointer<UInt8>
    private let machine: AYMachine
    private var cpu: Z80<AYMachine>
    private let chip: UnsafeMutablePointer<AYChip>
    private let chipType: AYChipType
    /// Interrupts per second when the song does not ask for its own rate.
    private let baseFrameHz: Double
    private var frameHz: Double
    private let gain = ayOutputGain

    private var cpuHz = ayFileSpectrumCPUHz
    private var chipHz = defaultAYClockHz
    /// True once the CPC clocks are in use.
    private var usingCPCClocks = false
    private var chipIsCPC = false
    private var frameTStates = 69888
    private var tstatesPerStep = 0.0
    /// T-state within the current frame that the next oversampled step corresponds to.
    private var position = 0.0
    private var eventIndex = 0
    private var beeperLevel = 0.0

    public private(set) var info: TuneInfo
    public private(set) var currentSubsong = 0
    public var subsongCount: Int { file.songs.count }
    public var defaultSubsong: Int { file.firstSong }
    /// The machine the current song was found to use, from the silent run when it was selected
    /// or, failing that, from playback so far.
    public private(set) var machineKind = AYFileMachine.undetected

    /// Frames run silently when a song is selected, to find out which machine it drives before playing it.
    private static let detectionFrames = 150
    /// False until the first CPU frame of a song has run; keeps the log's frame numbers starting at 0.
    private var firstFrame = true
    /// Seconds of a song run silently to find its length when the file does not give one.
    private static let measuredSeconds = 360.0
    /// A song whose sound hardware is left untouched for this long has ended.
    private static let stillSeconds = 10.0
    /// Lengths found that way, in frames, by song; 0 when the run found neither an ending nor a repeat.
    private var measuredFrames: [Int: Int] = [:]

    public init(_ data: [UInt8], options: LoadOptions = LoadOptions()) throws {
        // An explicit frame rate plays the file exactly as written.
        file = try AYFile(data, corrected: options.frameHz == nil)
        self.options = options
        chipType = options.chipType ?? .ay
        baseFrameHz = min(max(options.frameHz ?? defaultAYFrameHz, 1), 2000)
        frameHz = baseFrameHz
        memory = .allocate(capacity: 65536)
        memory.initialize(repeating: 0, count: 65536)
        // An OUT takes at least 11 T-states and can change both the beeper and a register.
        let slowestFrameHz = file.songs.compactMap({ $0.frameHz }).reduce(baseFrameHz, min)
        let fastestCPUHz = file.songs.compactMap({ $0.cpuHz }).reduce(max(ayFileSpectrumCPUHz, ayFileCPCCPUHz), max)
        let longestFrame = Int(fastestCPUHz / slowestFrameHz) + 64
        machine = AYMachine(eventCapacity: longestFrame / 11 * 2 + 64)
        cpu = Z80(memory: memory, bus: machine)
        chip = .allocate(capacity: 1)
        chip.initialize(to: AYChip(type: chipType, clockHz: defaultAYClockHz, sampleRate: outputSampleRate, stereo: options.stereo))
        info = TuneInfo(format: "AY")
        info.author = file.author
        info.comment = file.misc
        select(subsong: file.firstSong)
    }

    deinit {
        chip.pointee.deallocate()
        chip.deallocate()
        memory.deallocate()
    }

    public var knownLength: Double? {
        var frames = file.songs[currentSubsong].lengthFrames
        if lengthIsMissing(currentSubsong), let measured = measuredFrames[currentSubsong], measured > 0 { frames = measured }
        return frames > 0 ? Double(frames) / frameHz : nil
    }

    /// The file names each song. A length is given where the file has a usable one, or where the song has
    /// been played and measured; the others are not run just to fill in the list.
    public var songs: [SongInfo] {
        file.songs.indices.map { song in
            var frames = file.songs[song].lengthFrames
            if lengthIsMissing(song) { frames = measuredFrames[song] ?? 0 }
            let rate = file.songs[song].frameHz ?? baseFrameHz
            return SongInfo(title: file.songs[song].name, length: frames > 0 ? Double(frames) / rate : nil)
        }
    }

    /// True when the file gives no usable length for a song: none at all, or the three minutes exactly
    /// (9000 interrupts) that many rips carry as a stand-in whatever the tune's real length.
    private func lengthIsMissing(_ song: Int) -> Bool {
        let frames = file.songs[song].lengthFrames
        return frames == 0 || (frames == 9000 && !file.songs[song].timingCorrected)
    }

    public var fileFade: Double? {
        let frames = file.songs[currentSubsong].fadeFrames
        return frames > 0 ? Double(frames) / frameHz : nil
    }

    public func select(subsong: Int) {
        currentSubsong = min(max(subsong, 0), file.songs.count - 1)
        frameHz = file.songs[currentSubsong].frameHz ?? baseFrameHz
        // Run the start of the song silently to see whether it is a CPC tune, then start again with the
        // right clocks. A tune that first touches its sound chip later than this is switched when it does.
        start(cpc: false)
        var frames = 0
        while machine.kind == .undetected, frames < Self.detectionFrames {
            runCPUFrame()
            frames += 1
        }
        let kind = machine.kind
        let beeperHeard = machine.beeperChanges > 1
        if options.findsMissingLengths, lengthIsMissing(currentSubsong), measuredFrames[currentSubsong] == nil {
            start(cpc: kind == .cpc)
            measuredFrames[currentSubsong] = measureLength()
        }
        start(cpc: kind == .cpc)
        info.title = file.songs[currentSubsong].name
        describe(kind, beeperOnly: kind == .undetected && beeperHeard)
    }

    /// Runs the song silently and returns its length in frames, or 0 if it neither ends nor repeats in
    /// the time allowed. Each frame is reduced to a signature of what it did to the sound hardware.
    private func measureLength() -> Int {
        let count = Int(Self.measuredSeconds * frameHz)
        var signatures = [UInt64](repeating: 0, count: count)
        let stillFrames = Int(Self.stillSeconds * frameHz)
        var unchanged = 0
        for frame in 0 ..< count {
            runCPUFrame()
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            func mix(_ byte: UInt8) { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            for register in 0 ..< 14 { mix(machine.registers[register]) }
            for index in 0 ..< machine.eventCount {
                mix(machine.events[index].register)
                mix(machine.events[index].value)
            }
            signatures[frame] = hash
            // Most songs without a length are short effects: stop as soon as one has plainly finished.
            unchanged = frame > 0 && hash == signatures[frame - 1] ? unchanged + 1 : 0
            if unchanged >= stillFrames, unchanged < frame {
                return frame - unchanged + Int(frameHz / 2)
            }
        }
        return Self.lengthInFrames(of: signatures, frameHz: frameHz) ?? 0
    }

    /// Finds where a run of per-frame signatures stops changing (the tune has ended) or settles into a
    /// repeat (it has looped), and returns the length up to there: the ending plus half a second, or the
    /// lead-in plus one pass of the loop.
    ///
    /// A repeat only counts if it carries on to the end of the run and covers at least half of it, so a
    /// phrase that is merely played a few times in a row is not taken for the loop. Longer tunes come back
    /// as nil.
    static func lengthInFrames(of signatures: [UInt64], frameHz: Double) -> Int? {
        let count = signatures.count
        guard count >= 2 else { return nil }
        var still = count - 1
        while still > 0, signatures[still - 1] == signatures[count - 1] { still -= 1 }
        if count - still >= Int(stillSeconds * frameHz), still > 0 { return still + Int(frameHz / 2) }
        for period in 2 ... max(2, count / 2) {
            let needed = max(period, count / 2 - period)
            var index = count - 1
            while index >= period, signatures[index] == signatures[index - period] { index -= 1 }
            let matched = count - 1 - index
            if matched >= needed { return count - matched }
        }
        return nil
    }

    private func describe(_ kind: AYFileMachine, beeperOnly: Bool) {
        machineKind = kind
        switch kind {
        case .cpc: info.detail = "Amstrad CPC"
        case .spectrum: info.detail = "ZX Spectrum"
        case .undetected: info.detail = beeperOnly ? "ZX Spectrum beeper" : "ZX Spectrum"
        }
        if file.songs[currentSubsong].timingCorrected { info.detail += ", timing corrected" }
    }

    private func setClocks(cpc: Bool) {
        usingCPCClocks = cpc
        cpuHz = cpc ? ayFileCPCCPUHz : (file.songs[currentSubsong].cpuHz ?? ayFileSpectrumCPUHz)
        frameTStates = max(64, Int((cpuHz / frameHz).rounded()))
        tstatesPerStep = cpuHz / (Double(outputSampleRate) * Double(ayDecimate))
    }

    private func rebuildChip(cpc: Bool) {
        chipIsCPC = cpc
        chipHz = options.clockHz ?? (cpc ? ayFileCPCChipHz : defaultAYClockHz)
        chip.pointee.deallocate()
        chip.pointee = AYChip(type: chipType, clockHz: chipHz, sampleRate: outputSampleRate, stereo: options.stereo)
    }

    /// Rebuilds memory, CPU and chip for the current song.
    private func start(cpc: Bool) {
        let song = file.songs[currentSubsong]
        file.buildMemory(song: currentSubsong, into: memory)
        cpu.reset()
        let preset = UInt16(song.highRegister) << 8 | UInt16(song.lowRegister)
        cpu.af = preset; cpu.bc = preset; cpu.de = preset; cpu.hl = preset
        cpu.altAF = preset; cpu.altBC = preset; cpu.altDE = preset; cpu.altHL = preset
        cpu.ix = preset; cpu.iy = preset
        cpu.i = 3
        cpu.sp = UInt16(truncatingIfNeeded: song.stack)
        machine.reset()
        setClocks(cpc: cpc)
        rebuildChip(cpc: cpc)
        // Forces a CPU frame before the first sample.
        position = Double(frameTStates)
        eventIndex = 0
        beeperLevel = 0
        firstFrame = true
    }

    /// Runs the Z80 for one frame, leaving that frame's port events in the machine.
    /// The work is bounded by the frame's T-states, so no program can stall rendering.
    private func runCPUFrame() {
        if machine.kind == .cpc, !usingCPCClocks { setClocks(cpc: true) }
        if firstFrame {
            firstFrame = false
        } else {
            machine.frame &+= 1
        }
        machine.eventCount = 0
        // The interrupt is a level held for the first T-states of the frame: it is taken at the first
        // instruction boundary inside that window at which interrupts are enabled.
        while cpu.tstates < ayFileInterruptTStates {
            if !cpu.interrupt() { cpu.step() }
        }
        cpu.run(until: frameTStates)
        cpu.rebase(by: frameTStates)
    }

    @inline(__always) private func apply(_ event: AYPortEvent) {
        if event.register == AYPortEvent.beeper {
            // Ay_Emul's sign: the speaker bit pulls the output down.
            beeperLevel = event.value != 0 ? -ayFileBeeperLevel : 0
        } else {
            chip.pointee.write(Int(event.register), event.value)
        }
    }

    /// Applies what is left of the finished frame, then runs the next one.
    private func advanceFrame() {
        while eventIndex < machine.eventCount {
            apply(machine.events[eventIndex])
            eventIndex += 1
        }
        eventIndex = 0
        let before = machine.kind
        runCPUFrame()
        if machine.kind != before, machine.kind != machineKind {
            if machine.kind == .cpc, !chipIsCPC {
                // First AY access of a CPC tune that stayed quiet through detection: nothing has been
                // written to the chip yet, so it can simply be replaced by one on the CPC's clock.
                rebuildChip(cpc: true)
            }
            describe(machine.kind, beeperOnly: false)
        }
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        let chip = chip
        let events = machine.events
        let gain = gain
        var position = position
        var frameLength = Double(frameTStates)
        var step = tstatesPerStep
        var beeper = beeperLevel
        var next = eventIndex
        var count = machine.eventCount
        var nextTime = next < count ? Double(events[next].tstate) : .infinity
        for i in 0 ..< frames {
            var complete = false
            repeat {
                if position >= frameLength {
                    position -= frameLength
                    eventIndex = next
                    beeperLevel = beeper
                    advanceFrame()
                    beeper = beeperLevel
                    frameLength = Double(frameTStates)
                    step = tstatesPerStep
                    next = 0
                    count = machine.eventCount
                    nextTime = count > 0 ? Double(events[0].tstate) : .infinity
                }
                while nextTime <= position {
                    let event = events[next]
                    if event.register == AYPortEvent.beeper {
                        beeper = event.value != 0 ? -ayFileBeeperLevel : 0
                    } else {
                        chip.pointee.write(Int(event.register), event.value)
                    }
                    next += 1
                    nextTime = next < count ? Double(events[next].tstate) : .infinity
                }
                complete = chip.pointee.innerStep(extra: beeper)
                position += step
            } while !complete
            let (left, right) = chip.pointee.finishSample()
            buffer[i * 2] = Float(left) * gain
            buffer[i * 2 + 1] = Float(right) * gain
        }
        self.position = position
        eventIndex = next
        beeperLevel = beeper
    }

    /// Restarts the current song and runs it for `frames` frames without sound, returning every AY
    /// register write and beeper change, and the register state at the end of each frame
    /// (14 register bytes as a program would read them back, then the beeper bit).
    /// The song is restarted again afterwards.
    /// For checking the length finder: every song's length in frames as the file gives it (0 when it does
    /// not) and as a silent run finds it (0 when it finds none).
    public func lengthSurvey() -> [(stated: Int, measured: Int)] {
        let current = currentSubsong
        var result: [(stated: Int, measured: Int)] = []
        for song in file.songs.indices {
            currentSubsong = song
            frameHz = file.songs[song].frameHz ?? baseFrameHz
            start(cpc: false)
            var frames = 0
            while machine.kind == .undetected, frames < Self.detectionFrames {
                runCPUFrame()
                frames += 1
            }
            start(cpc: machine.kind == .cpc)
            result.append((file.songs[song].lengthFrames, measureLength()))
        }
        select(subsong: current)
        return result
    }

    public func portLog(frames: Int) -> (events: [AYPortLogEntry], states: [[UInt8]]) {
        select(subsong: currentSubsong)
        machine.log = []
        var states: [[UInt8]] = []
        for _ in 0 ..< max(0, frames) {
            runCPUFrame()
            var state = [UInt8](repeating: 0, count: 15)
            for register in 0 ..< 14 { state[register] = machine.registers[register] }
            state[14] = machine.beeperOn ? 1 : 0
            states.append(state)
        }
        let events = machine.log ?? []
        machine.log = nil
        select(subsong: currentSubsong)
        return (events, states)
    }
}
