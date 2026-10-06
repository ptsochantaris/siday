// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Start-up state, ROM stand-ins and timing rules follow libsidplayfp (GPL-2.0-or-later; see THIRD-PARTY.md).

/// Lets tools pull the stream of SID register writes out of a tune for comparison against reference players.
public protocol SIDWriteLogging {
    /// Restarts the current subsong and returns every SID write in the first `seconds` as (cycle, register, value).
    func dumpWrites(seconds: Double) -> [(Int, UInt8, UInt8)]
}

/// Plays PSID and RSID files on the emulated C64.
public final class SIDRenderer: Renderer, SIDWriteLogging {
    private let file: SIDFile
    private let machine: C64Machine
    private var cpu = MOS6510<C64Machine>()
    private let lengths: [Double]?
    private let clockHz: Double
    private let ntsc: Bool
    private var idleAddress: UInt16 = 0
    private let gain: Float = 1.0 / 32768.0

    public private(set) var info: TuneInfo
    public private(set) var currentSubsong = 0
    public var subsongCount: Int { file.songs }
    public var defaultSubsong: Int { file.startSong - 1 }
    public var hasEnded: Bool { cpu.jammed }

    public var knownLength: Double? {
        guard let lengths, currentSubsong < lengths.count else { return nil }
        return lengths[currentSubsong]
    }

    public init(_ data: [UInt8], path: String?, options: LoadOptions) throws {
        file = try SIDFile(data)
        if file.isMUS { throw TuneError.unsupported("Compute!'s Sidplayer (MUS) data") }
        if file.needsBASIC { throw TuneError.unsupported("needs the C64 BASIC ROM") }
        guard file.loadAddress + file.image.count > file.loadAddress else { throw TuneError.malformed("empty SID image") }

        ntsc = file.clock == .ntsc
        clockHz = ntsc ? 1_022_727.14 : 985_248.61
        let model: SIDModel = switch options.sidModel {
        case .auto: file.model
        case .mos6581: .mos6581
        case .mos8580: .mos8580
        }
        machine = C64Machine(clockHz: clockHz, ntsc: ntsc, model: model, engine: options.sidEngine, filterCurve: options.sidFilterCurve)
        lengths = options.songLengths?.lengths(of: data, path: path)

        var info = TuneInfo(format: file.isRSID ? "RSID" : "PSID")
        info.title = file.name
        info.author = file.author
        info.comment = file.released
        info.detail = [file.released, model == .mos8580 ? "8580" : "6581", ntsc ? "NTSC" : "PAL"].filter { !$0.isEmpty }.joined(separator: ", ")
        self.info = info
        select(subsong: defaultSubsong)
    }

    /// Bank register value the PSID environment uses when calling a routine at `address`.
    private func bankValue(for address: Int) -> UInt8 {
        if address < 0xA000 { return 0x37 }
        if address < 0xD000 { return 0x36 }
        if address >= 0xE000 { return 0x35 }
        return 0x34
    }

    /// Chooses a page for the driver: the one the file names, otherwise the first page that the image, the
    /// BASIC ROM area and the system pages do not use (the same rule libsidplayfp applies).
    private func driverPage() -> Int? {
        if file.relocStartPage == 0xFF { return nil }
        if file.relocStartPage != 0 {
            return file.relocPages >= 1 ? file.relocStartPage : nil
        }
        let firstUsed = file.loadAddress >> 8
        let lastUsed = min(0xFFFF, file.loadAddress + file.image.count - 1) >> 8
        return (0x04 ..< 0xD0).first { !(firstUsed ... lastUsed).contains($0) && !(0xA0 ... 0xBF).contains($0) }
    }

    public func select(subsong: Int) {
        let song = min(max(0, subsong), file.songs - 1)
        currentSubsong = song
        machine.reset(booted: file.isRSID)
        let ram = machine.ram
        let video: UInt8 = ntsc ? 0 : 1
        ram[0x02A6] = video

        // With no free page declared, the cassette buffer is the least bad place.
        let base = driverPage().map { $0 << 8 } ?? 0x0300
        let page = UInt8(base >> 8)
        func setVector(_ address: Int, _ target: Int) {
            ram[address] = UInt8(target & 0xFF)
            ram[address + 1] = UInt8(target >> 8)
        }
        setVector(0x0314, base + PSIDDriver.interruptReturn)
        if !file.isRSID {
            // A PSID that provokes a BRK or an NMI without installing a handler simply returns.
            setVector(0x0316, 0xFE66)
            setVector(0x0318, 0xFE47)
        }
        for (i, byte) in PSIDDriver.code.enumerated() { ram[base + i] = byte }
        for offset in PSIDDriver.pagePatches { ram[base + offset] = page }
        ram[base + PSIDDriver.songOffset] = UInt8(song)
        // An RSID starts as on a real machine: timer interrupt running, no bank changes, interrupts enabled.
        ram[base + PSIDDriver.speedOffset] = file.isRSID || file.usesCIA(song: song) ? 1 : 0
        setVector(base + PSIDDriver.initVectorOffset, file.initAddress)
        setVector(base + PSIDDriver.playVectorOffset, file.playAddress)
        ram[base + PSIDDriver.initBankOffset] = file.isRSID ? 0 : bankValue(for: file.initAddress)
        ram[base + PSIDDriver.playBankOffset] = file.isRSID || file.playAddress == 0 ? 0 : bankValue(for: file.playAddress)
        ram[base + PSIDDriver.videoOffset] = video
        ram[base + PSIDDriver.clockOffset] = video
        ram[base + PSIDDriver.flagsOffset] = file.isRSID ? 0x00 : 0x04

        // The tune goes in last, as the reference player does it, along with the pointers the KERNAL's
        // LOAD would leave behind: start and end of the program, and BASIC's variable areas after it.
        let end = (file.loadAddress + file.image.count) & 0xFFFF
        for address in [0x2D, 0x2F, 0x31, 0xAE] { setVector(address, end) }
        setVector(0xAC, file.loadAddress)
        for (i, byte) in file.image.enumerated() where file.loadAddress + i < 0x10000 {
            ram[file.loadAddress + i] = byte
        }

        idleAddress = UInt16(base + PSIDDriver.idleLoop)
        cpu = MOS6510<C64Machine>()
        cpu.pc = UInt16(base + PSIDDriver.coldStart)
        cpu.s = 0xFF
        cpu.i = true
    }

    private func runSlice(_ cycles: Int) {
        var cpu = cpu
        let end = machine.clock + cycles
        while machine.clock < end {
            // Sitting in the idle loop (or halted) with nothing pending: jump to the next timer or raster event.
            if cpu.pc == idleAddress || cpu.jammed, machine.quiet(interruptsMasked: cpu.i) {
                machine.skipIdle(until: end)
            }
            cpu.step(machine)
        }
        self.cpu = cpu
        machine.syncSID()
    }

    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) {
        var done = 0
        while done < frames {
            if machine.sampleCount == 0 { runSlice(5000) }
            done += machine.drain(into: buffer + done * 2, count: frames - done, gain: gain)
        }
    }

    /// The first value read from each I/O or ROM address during the first `seconds`.
    public func dumpHardwareReads(seconds: Double) -> [(UInt16, UInt8)] {
        machine.hardwareReads = [:]
        _ = dumpWrites(seconds: seconds)
        let reads = machine.hardwareReads ?? [:]
        machine.hardwareReads = nil
        return reads.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    public func dumpWrites(seconds: Double) -> [(Int, UInt8, UInt8)] {
        machine.writeLog = []
        select(subsong: currentSubsong)
        let end = Int(seconds * clockHz)
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 2 * 4096)
        defer { scratch.deallocate() }
        while machine.clock < end {
            runSlice(5000)
            while machine.drain(into: scratch, count: 4096, gain: gain) > 0 {}
        }
        let log = machine.writeLog ?? []
        machine.writeLog = nil
        let reads = machine.hardwareReads
        select(subsong: currentSubsong)
        machine.hardwareReads = reads
        return log
    }
}
