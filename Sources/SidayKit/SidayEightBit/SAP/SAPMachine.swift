// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ASAP (Another Slight Atari Player), Copyright (C) 2010-2026 Piotr Fusik, used under
// the GNU General Public License, version 2 or later (see THIRD-PARTY.md).
//
// As much of an 8-bit Atari as its music needs: the 6502, 64 KB of memory, one POKEY or two, and of
// the other chips only what tunes look at. ANTIC, which draws the screen, is its count of lines and
// its vertical blank, the WSYNC that holds the processor until a line ends, and the nine cycles of
// each line it takes from the processor to refresh the memory. Of GTIA there is the one bit of the
// console's loudspeaker, and whether the machine is a PAL or an NTSC one. There is no operating system: the tune's code is called as SAP files say
// it is to be called, with a few bytes of code put where the hardware's registers are, which no
// tune's code is in.

/// The 8-bit Atari of a SAP file.
final class SAPMachine {
    let memory: UnsafeMutablePointer<UInt8>
    let pokeys: POKEYPair
    let file: SAPFile

    // The 6502's registers (see SAP6502.swift). Each is a whole number; the flags N and Z are kept
    // as the value they were last set from, and V, D and I together.
    var cycle = 0
    var pc = 0
    var a = 0, x = 0, y = 0, s = 0xFF
    var nz = 0, c = 0, vdi = 0

    /// The cycle at which something next happens that the processor must stop for between instructions.
    var nextEventCycle = 0
    private var nextScanlineCycle = 0
    private enum NMIStatus { case reset, onVBlank, wasVBlank }
    private var nmist = NMIStatus.onVBlank
    private var consol = 8
    /// The console's loudspeaker as it is heard: as `consol`, unless it is left out.
    private var heardConsol = 8
    /// True if the console's loudspeaker is left out of the sound.
    var speakerLeftOut = false
    private var covox = InlineArray<4, Int>(repeating: 0x80)
    private var nextPlayerCycle = pokeyNever
    private(set) var gtiaOrCovoxPlayedThisFrame = false

    /// The machine's clock, PAL's or NTSC's.
    let clock: Double
    private let frameCycles: Int

    init(_ file: SAPFile, sampleRate: Int) {
        self.file = file
        memory = .allocate(capacity: 0x10000)
        memory.initialize(repeating: 0, count: 0x10000)
        pokeys = POKEYPair(sampleRate: sampleRate)
        clock = file.ntsc ? 1_789_772 : 1_773_447
        frameCycles = file.ntsc ? 262 * 114 : 312 * 114
        self.sampleRate = sampleRate
    }

    private let sampleRate: Int

    deinit {
        memory.deallocate()
    }

    // MARK: The hardware's registers

    func peekHardware(_ addr: Int) -> Int {
        switch addr & 0xFF1F {
        case 0xD014:
            return file.ntsc ? 0xF : 1
        case 0xD01F:
            return ~consol & 0xF
        case 0xD20A, 0xD21A, 0xD20E, 0xD21E:
            return pokeys.peek(addr, cycle)
        case 0xD20C, 0xD21C, 0xD20F, 0xD21F: // (the last two because some SAP files rely on it)
            return 0xFF
        case 0xD40B, 0xD41B:
            if cycle > frameCycles { return 0 }
            return cycle / 228
        case 0xD40F, 0xD41F:
            switch nmist {
            case .reset: return 0x1F
            case .wasVBlank: return 0x5F
            case .onVBlank: return cycle < 28291 ? 0x1F : 0x5F
            }
        default:
            return Int(memory[addr])
        }
    }

    func pokeHardware(_ addr: Int, _ data: Int) {
        if addr >> 8 == 0xD2 {
            let t = pokeys.poke(addr, data, cycle)
            if nextEventCycle > t { nextEventCycle = t }
        } else if addr & 0xFF0F == 0xD40A {
            // WSYNC: wait for the end of the line.
            let x = cycle % 114
            cycle += (x <= 106 ? 106 : 106 + 114) - x
        } else if addr & 0xFF0F == 0xD40F {
            nmist = cycle < 28292 ? .onVBlank : .reset
        } else if addr & 0xFF00 == file.covox {
            let which = addr & 3
            let pokey = which == 0 || which == 3 ? pokeys.base : pokeys.extra
            let delta = data - covox[which]
            if delta != 0 {
                pokey.addExternalDelta(cycle, delta << 17)
                covox[which] = data
                gtiaOrCovoxPlayedThisFrame = true
            }
        } else if addr & 0xFF1F == 0xD01F {
            // The console's loudspeaker: the opposite of what is written, against the POKEY's sound.
            if (consol ^ data) & 8 != 0 {
                pokeys.base.noteSpeakerMove(cycle)
                gtiaOrCovoxPlayedThisFrame = true
                if pokeys.base.keepsVoices { pokeys.base.moveSpeaker(cycle, up: data & 8 == 0) }
            }
            if !speakerLeftOut {
                let delta = ((heardConsol & 8) - (data & 8)) << 20
                if delta != 0 {
                    pokeys.base.addExternalDelta(cycle, delta)
                    pokeys.extra.addExternalDelta(cycle, delta)
                }
                heardConsol = data
            }
            consol = data
        } else {
            memory[addr] = UInt8(truncatingIfNeeded: data)
        }
    }

    // MARK: Calling the tune's code

    private static let codeAddress = 0xD200

    private func storeJSR(_ addr: Int, _ target: Int) {
        memory[addr] = 0x20 // JSR
        memory[addr + 1] = UInt8(target & 0xFF)
        memory[addr + 2] = UInt8(target >> 8 & 0xFF)
    }

    private func call6502(_ target: Int) {
        storeJSR(Self.codeAddress, target)
        memory[Self.codeAddress + 3] = 0xD2 // the way back: an instruction that stops the processor
        pc = Self.codeAddress
    }

    private static let saving: [UInt8] = [0x08, 0x48, 0x8A, 0x48, 0x98, 0x48] // PHP PHA TXA PHA TYA PHA
    private static let restoring: [UInt8] = [0x68, 0xA8, 0x68, 0xAA, 0x68, 0x40] // PLA TAY PLA TAX PLA RTI

    private func call6502PreservingRegisters(_ target: Int) {
        pushPC()
        let code = Self.codeAddress
        for (i, byte) in Self.saving.enumerated() { memory[code + i] = byte }
        storeJSR(code + 6, target)
        for (i, byte) in Self.restoring.enumerated() { memory[code + 9 + i] = byte }
        pc = code
    }

    private func call6502Player() {
        let player = file.player
        switch file.kind {
        case .b:
            call6502(player)
        case .c:
            call6502(player + 6)
        case .d:
            if player >= 0 { call6502PreservingRegisters(player) }
        case .s:
            let i = Int(memory[0x45]) - 1
            memory[0x45] = UInt8(i & 0xFF)
            if i == 0 { memory[0xB07B] &+= 1 }
        }
    }

    var isIRQ: Bool { pokeys.base.irqst != 0xFF }

    func handleEvent() {
        var cycle = self.cycle
        if cycle >= nextScanlineCycle {
            if cycle - nextScanlineCycle < 50 { // not WSYNC
                cycle += 9
                self.cycle = cycle
            }
            nextScanlineCycle += 114
            if cycle >= nextPlayerCycle {
                call6502Player()
                nextPlayerCycle += 114 * file.fastplay
            }
        }
        var next = nextScanlineCycle
        next = pokeys.base.checkIrq(cycle, next)
        next = pokeys.extra.checkIrq(cycle, next)
        nextEventCycle = next
    }

    @discardableResult private func do6502Frame() -> Int {
        nextEventCycle = 0
        nextScanlineCycle = 0
        nmist = nmist == .reset ? .onVBlank : .wasVBlank
        let cycles = frameCycles
        runCPU(until: cycles)
        cycle -= cycles
        if nextPlayerCycle != pokeyNever { nextPlayerCycle -= cycles }
        // (The three timers that can interrupt the processor.)
        pokeys.base.channels[3].endFrame(cycles)
        pokeys.base.channels[1].endFrame(cycles)
        pokeys.base.channels[0].endFrame(cycles)
        pokeys.extra.channels[3].endFrame(cycles)
        pokeys.extra.channels[1].endFrame(cycles)
        pokeys.extra.channels[0].endFrame(cycles)
        return cycles
    }

    /// One frame of the screen: the tune's code run for it, and its sound made.
    func doFrame() {
        gtiaOrCovoxPlayedThisFrame = false
        pokeys.startFrame()
        let cycles = do6502Frame()
        pokeys.endFrame(cycles)
    }

    private func do6502Init(_ pc: Int, _ a: Int, _ x: Int, _ y: Int) -> Bool {
        self.pc = pc
        self.a = a & 0xFF
        self.x = x & 0xFF
        self.y = y & 0xFF
        let escape = Self.codeAddress
        memory[escape] = 0xD2
        // The way back, where its RTS will take it.
        memory[0x1FE] = UInt8((escape - 1) & 0xFF)
        memory[0x1FF] = UInt8((escape - 1) >> 8)
        s = 0xFD
        for _ in 0 ..< 50 {
            do6502Frame()
            if self.pc == escape { return true }
        }
        return false
    }

    /// Starts the given song, counted from nought, from the beginning. False if its code does not
    /// come back from being started within a second.
    func start(song: Int) throws -> Bool {
        memory.update(repeating: 0, count: 0x10000)
        try file.load(into: memory)
        nextPlayerCycle = pokeyNever
        cycle = 0
        nz = 0
        c = 0
        vdi = 0
        nmist = .onVBlank
        consol = 8
        heardConsol = 8
        for i in 0 ..< 4 { covox[i] = 0x80 }
        pokeys.initialize(ntsc: file.ntsc, stereo: file.stereo, sampleRate: sampleRate)
        pokeys.base.mute(0xFF)
        pokeys.extra.mute(0xF)
        let player = file.player, music = file.music
        switch file.kind {
        case .b:
            guard do6502Init(file.initAddress, song, 0, 0) else { return false }
        case .c:
            guard do6502Init(player + 3, 0x70, music, music >> 8), do6502Init(player + 3, 0x00, song, 0) else { return false }
        case .d, .s:
            pc = file.initAddress
            a = song
            x = 0
            y = 0
            s = 0xFF
        }
        pokeys.base.mute(0)
        pokeys.extra.mute(0)
        nextPlayerCycle = 0
        return true
    }

    /// Starts keeping each voice's sound for its scope (see `POKEYPair.waves`): the channels of each
    /// POKEY, and the console's loudspeaker, which the first keeps.
    func keepVoices(in waves: ChannelWaves) {
        pokeys.base.keepVoices(speakerUp: consol & 8 == 0)
        pokeys.extra.keepVoices(speakerUp: false)
        pokeys.waves = waves
    }

    /// Fills `buffer` with `blocks` samples, one for each POKEY, running the machine as it needs.
    func generate(into buffer: UnsafeMutablePointer<Int16>, blocks: Int) {
        let width = pokeys.stereo ? 2 : 1
        var block = 0
        while true {
            block += pokeys.generate(into: buffer + block * width, blocks: blocks - block)
            if block >= blocks { break }
            doFrame()
        }
    }
}
