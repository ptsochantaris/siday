// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written from what audio.device's commands are documented to do (Commodore's Autodocs and the ROM
// Kernel Reference Manual: Devices) and from what Kickstart 1.3's audio.device (34.1), which the games
// were made for, was measured to write to Paula, in what order and from which of its interrupts, for
// Electronic Arts' players on an A500, as Copperline runs it: none of its code is in it.

import SidayM68000

/// What audio.device keeps of Paula's four channels, for `AmigaExec`: who has each (by the key of an
/// allocation, and its precedence), and the writes (CMD_WRITE) queued on each, the first of them playing.
///
/// A write is started as 34.1 starts one, on a channel with nothing playing: its length and location
/// written, its interrupt let through, a period of 1 if it brings its own period and volume, and the
/// first byte of its sample, twice, written by hand (AUDxDAT), which plays it and asks for the interrupt
/// at once. The interrupt turns the channel's DMA on; the next, as Paula takes up the sample and begins
/// its first block, writes the write's period and volume (if it asks, ADIOF_PERVOL), and for a write that
/// plays for ever with nothing behind it turns the channel's interrupt off. A write's blocks are counted
/// by the interrupt at each block's start (ioa_Cycles of them, nought for ever); as the last begins, the
/// next write's length and location are written, for Paula to take up as it ends, and at the start of
/// that one's first block the one before is done. The replies go out from the device's software
/// interrupt (`softInterrupt`): at once in a task, once the interrupts are over in one.
struct AmigaAudioDevice {
    enum Phase {
        /// Nothing playing.
        case idle
        /// The first word written by hand, its interrupt asked for.
        case kicked
        /// The DMA on, waiting for the first block to begin.
        case starting
        /// Playing the first write in the queue.
        case playing
    }

    struct Write {
        let request: UInt32
        let cycles: UInt16
        let perVol: Bool
        /// The blocks of it begun so far.
        var blocks = 0
    }

    struct Channel {
        var queue: [Write] = []
        var phase = Phase.idle
        /// Whether Paula's location and length are the next write's, to be taken up as the block ends.
        var nextLoaded = false
        /// The key of the allocation that has the channel (nought for none), and its precedence.
        var key: UInt16 = 0
        var precedence: Int8 = 0
    }

    var opened = false
    var channels = [Channel](repeating: Channel(), count: 4)
    /// The key the next allocation that brings none is given.
    var nextKey: UInt16 = 1
    /// The requests (and their errors), and the messages of ADIOF_WRITEMESSAGE, that the software
    /// interrupt is to reply, in order.
    var replies: [(request: UInt32, error: Int8, message: Bool)] = []

    // IOAudio's fields past its IORequest (devices/audio.i).
    static let allocKey: UInt32 = 32, data: UInt32 = 34, length: UInt32 = 38, period: UInt32 = 42
    static let volume: UInt32 = 44, cycles: UInt32 = 46, writeMessage: UInt32 = 48
    // Commands and flags.
    static let cmdReset: UInt16 = 1, cmdWrite: UInt16 = 3, cmdFlush: UInt16 = 8, free: UInt16 = 9, perVol: UInt16 = 12
    static let allocate: UInt16 = 32
    static let flagWriteMessage: UInt8 = 0x04, flagPerVol: UInt8 = 0x10, flagSyncCycle: UInt8 = 0x20, flagNoWait: UInt8 = 0x40
    /// ADIOERR_ALLOCFAILED, ADIOERR_NOALLOCATION.
    static let allocFailed: Int8 = -10, noAllocation: Int8 = -12
    /// What 34.1 writes to ADKCON as it resets each channel: that channel's modulation bits and the
    /// ones it is modulated by, cleared.
    static let modulationBits: [UInt16] = [0x0011, 0x0033, 0x0066, 0x00CC]
    /// The order exec's handler of level 4 takes Paula's channels in (as score's has it).
    static let interruptOrder = [1, 3, 0, 2]
}

extension AmigaExec {
    /// A write to Paula's registers, from the device, at the moment the processor has reached.
    private func paula(_ m: borrowing AmigaMachine, _ register: UInt32, _ value: UInt16) {
        m.chips.write16(AmigaChips.custom + register, value, at: m.cpu.cycles)
    }

    private func channelRegister(_ channel: Int, _ offset: UInt32) -> UInt32 { 0xA0 + UInt32(channel * 16) + offset }

    /// OpenDevice: the request is given a key if it brings none, and if it asks for channels (ioa_Length
    /// more than nought), they are allocated as by ADCMD_ALLOCATE without waiting. The error, nought if it
    /// opened.
    mutating func audioOpen(_ request: UInt32, _ m: inout AmigaMachine) -> Int8 {
        if m.peek16(request + AmigaAudioDevice.allocKey) == 0 { m.poke16(request + AmigaAudioDevice.allocKey, newKey()) }
        guard m.peek32(request + AmigaAudioDevice.length) != 0 else { return 0 }
        return allocateChannels(request, m)
    }

    private mutating func newKey() -> UInt16 {
        let key = audio.nextKey
        audio.nextKey = audio.nextKey == 0xFFFF ? 1 : audio.nextKey + 1
        return key
    }

    /// CloseDevice: the channels of the request's key freed.
    mutating func audioClose(_ request: UInt32, _ m: inout AmigaMachine) {
        let key = m.peek16(request + AmigaAudioDevice.allocKey)
        for c in 0 ..< 4 where audio.channels[c].key == key && key != 0 {
            resetChannel(c, m)
            audio.channels[c].key = 0
        }
    }

    /// ADCMD_ALLOCATE (and OpenDevice's allocation): the first of the request's combinations of channels
    /// (ioa_Data, ioa_Length of them) whose every channel is free, is the key's already, or is had by an
    /// allocation of lower precedence; those channels reset, and the request's io_Unit made them. With
    /// none, it fails (ADIOERR_ALLOCFAILED): it does not wait for one, as it would without ADIOF_NOWAIT,
    /// which no player here needs.
    private mutating func allocateChannels(_ request: UInt32, _ m: borrowing AmigaMachine) -> Int8 {
        var key = m.peek16(request + AmigaAudioDevice.allocKey)
        if key == 0 {
            key = newKey()
            m.poke16(request + AmigaAudioDevice.allocKey, key)
        }
        let precedence = Int8(bitPattern: m.peek8(request + Self.lnPri))
        let masks = m.peek32(request + AmigaAudioDevice.data), count = min(m.peek32(request + AmigaAudioDevice.length), 16)
        for i in 0 ..< count {
            let mask = m.peek8(masks + i) & 0xF
            let possible = (0 ..< 4).allSatisfy { c in
                mask & (1 << UInt8(c)) == 0 || audio.channels[c].key == 0 || audio.channels[c].key == key || audio.channels[c].precedence < precedence
            }
            guard possible else { continue }
            for c in 0 ..< 4 where mask & (1 << UInt8(c)) != 0 {
                resetChannel(c, m)
                audio.channels[c].key = key
                audio.channels[c].precedence = precedence
            }
            m.poke32(request + Self.ioUnit, UInt32(mask))
            return 0
        }
        return AmigaAudioDevice.allocFailed
    }

    /// The channels of `request`'s unit that its key has.
    private func ownedChannels(_ request: UInt32, _ m: borrowing AmigaMachine) -> [Int] {
        let unit = m.peek32(request + Self.ioUnit), key = m.peek16(request + AmigaAudioDevice.allocKey)
        return (0 ..< 4).filter { unit & (1 << UInt32($0)) != 0 && audio.channels[$0].key == key && key != 0 }
    }

    /// The device's BeginIO. False for a command not given here, which stops the player.
    mutating func audioCommand(_ request: UInt32, _ m: inout AmigaMachine) -> Bool {
        let command = m.peek16(request + Self.ioCommand), flags = m.peek8(request + Self.ioFlags)
        m.poke8(request + Self.ioError, 0)
        // (The times 34.1 took, each command's median as measured: see `AmigaExec.costs`.)
        charge = switch command {
        case AmigaAudioDevice.allocate: 3220
        case AmigaAudioDevice.cmdFlush: 3478
        case AmigaAudioDevice.cmdReset: 2393
        case AmigaAudioDevice.perVol: 615
        default: 0
        }
        switch command {
        case AmigaAudioDevice.allocate:
            done(request, error: allocateChannels(request, m), m)
        case AmigaAudioDevice.free, AmigaAudioDevice.cmdReset:
            for c in ownedChannels(request, m) {
                resetChannel(c, m)
                if command == AmigaAudioDevice.free { audio.channels[c].key = 0 }
            }
            done(request, error: 0, m)
        case AmigaAudioDevice.cmdFlush:
            for c in ownedChannels(request, m) { stopChannel(c, m) }
            done(request, error: 0, m)
        case AmigaAudioDevice.perVol:
            guard flags & AmigaAudioDevice.flagSyncCycle == 0 else {
                failure = "a player that asks audio.device to change a sound's period and volume as its cycle ends"
                return false
            }
            for c in ownedChannels(request, m) { writePeriodAndVolume(c, request, m) }
            done(request, error: 0, m)
        case AmigaAudioDevice.cmdWrite:
            // (Queued, so not done at once, whatever IOF_QUICK asked.)
            m.poke8(request + Self.ioFlags, flags & ~Self.iofQuick)
            m.poke8(request + Self.lnType, Self.ntMessage)
            let channels = ownedChannels(request, m)
            guard let c = channels.first else {
                done(request, error: AmigaAudioDevice.noAllocation, m)
                return true
            }
            write(c, request, m)
        default:
            failure = "a player that asks audio.device for its command \(command), which siday's does not give"
            return false
        }
        return true
    }

    /// AbortIO: a write taken out of its channel's queue and replied as aborted; the one playing stops
    /// its channel, and the next, if any, starts.
    mutating func audioAbort(_ request: UInt32, _ m: inout AmigaMachine) {
        for c in 0 ..< 4 {
            guard let i = audio.channels[c].queue.firstIndex(where: { $0.request == request }) else { continue }
            if i == 0, audio.channels[c].phase != .idle {
                var rest = audio.channels[c].queue
                rest.removeFirst()
                audio.channels[c].queue = [audio.channels[c].queue[0]]
                stopChannel(c, m)
                for w in rest { write(c, w.request, m) }
            } else {
                audio.channels[c].queue.remove(at: i)
                audio.replies.append((request, Self.aborted, false))
            }
            return
        }
    }

    // MARK: Paula

    /// CMD_WRITE: started at once on a channel with nothing playing, otherwise queued; and if the write
    /// in front is in its last block, its length and location written now for Paula to take up next.
    private mutating func write(_ c: Int, _ request: UInt32, _ m: borrowing AmigaMachine) {
        let flags = m.peek8(request + Self.ioFlags)
        let w = AmigaAudioDevice.Write(request: request, cycles: m.peek16(request + AmigaAudioDevice.cycles),
                                       perVol: flags & AmigaAudioDevice.flagPerVol != 0)
        audio.channels[c].queue.append(w)
        guard audio.channels[c].queue.count > 1 else {
            start(c, m)
            charge = 1880
            return
        }
        loadNextIfLast(c, m)
        charge = 880
    }

    /// The first write of the queue started on its idle channel. (A write that brings its own period and
    /// volume has them at the start of its first block, and plays its first word by hand at a period of 1,
    /// at the volume the channel has; one that does not plays at the period and volume the channel has.)
    private mutating func start(_ c: Int, _ m: borrowing AmigaMachine) {
        let w = audio.channels[c].queue[0], request = w.request
        let bit = UInt16(0x80) << UInt16(c)
        loadSample(c, request, m)
        paula(m, 0x9C, bit)
        paula(m, 0x9A, 0x8000 | bit)
        if w.perVol { paula(m, channelRegister(c, 6), 1) }
        let first = UInt16(m.peek8(m.peek32(request + AmigaAudioDevice.data)))
        paula(m, channelRegister(c, 0xA), first << 8 | first)
        audio.channels[c].phase = .kicked
        audio.channels[c].nextLoaded = false
    }

    /// AUDxLEN and AUDxLC, from the request.
    private func loadSample(_ c: Int, _ request: UInt32, _ m: borrowing AmigaMachine) {
        let data = m.peek32(request + AmigaAudioDevice.data)
        paula(m, channelRegister(c, 4), UInt16(truncatingIfNeeded: m.peek32(request + AmigaAudioDevice.length) / 2))
        paula(m, channelRegister(c, 0), UInt16(truncatingIfNeeded: data >> 16))
        paula(m, channelRegister(c, 2), UInt16(truncatingIfNeeded: data))
    }

    private func writePeriodAndVolume(_ c: Int, _ request: UInt32, _ m: borrowing AmigaMachine) {
        paula(m, channelRegister(c, 6), m.peek16(request + AmigaAudioDevice.period))
        paula(m, channelRegister(c, 8), m.peek16(request + AmigaAudioDevice.volume))
    }

    /// If the write playing is in its last block and one is queued behind it whose sample Paula does not
    /// yet have, it is given it.
    private mutating func loadNextIfLast(_ c: Int, _ m: borrowing AmigaMachine) {
        let ch = audio.channels[c]
        guard ch.phase == .playing, ch.queue.count > 1, !ch.nextLoaded, ch.queue[0].cycles != 0,
              ch.queue[0].blocks >= Int(ch.queue[0].cycles) else { return }
        loadSample(c, ch.queue[1].request, m)
        audio.channels[c].nextLoaded = true
    }

    /// A channel stopped (CMD_FLUSH, and the first part of a reset): its request cleared if a write was
    /// playing, its DMA and its interrupt turned off (its period and volume left as they are); and the
    /// writes on it to be replied by the software interrupt, as aborted.
    private mutating func stopChannel(_ c: Int, _ m: borrowing AmigaMachine) {
        let bit = UInt16(0x80) << UInt16(c)
        if !audio.channels[c].queue.isEmpty { paula(m, 0x9C, bit) }
        paula(m, 0x96, 1 << UInt16(c))
        paula(m, 0x9A, bit)
        for w in audio.channels[c].queue { audio.replies.append((w.request, Self.aborted, false)) }
        audio.channels[c].queue.removeAll()
        audio.channels[c].phase = .idle
        audio.channels[c].nextLoaded = false
    }

    /// A channel reset (CMD_RESET, ADCMD_FREE, an allocation): stopped, its period 1 and volume nought,
    /// and its modulation cleared.
    private mutating func resetChannel(_ c: Int, _ m: borrowing AmigaMachine) {
        stopChannel(c, m)
        paula(m, channelRegister(c, 6), 1)
        paula(m, channelRegister(c, 8), 0)
        paula(m, 0x9E, AmigaAudioDevice.modulationBits[c])
    }

    /// Paula's interrupts (level 4), for each channel asking, in exec's order (1, 3, 0, 2), until none is.
    mutating func audioInterrupt(_ m: inout AmigaMachine) {
        for _ in 0 ..< 16 {
            let asked = m.chips.intena & m.chips.intreq & 0x0780
            guard asked != 0 else { return }
            for c in AmigaAudioDevice.interruptOrder where asked & (UInt16(0x80) << UInt16(c)) != 0 { channelInterrupt(c, m) }
        }
    }

    private mutating func channelInterrupt(_ c: Int, _ m: borrowing AmigaMachine) {
        let bit = UInt16(0x80) << UInt16(c)
        switch audio.channels[c].phase {
        case .idle:
            paula(m, 0x9C, bit)
            paula(m, 0x9A, bit)
        case .kicked:
            // The word written by hand has been taken: the DMA on.
            paula(m, 0x9C, bit)
            paula(m, 0x96, 0x8000 | 1 << UInt16(c))
            audio.channels[c].phase = .starting
        case .starting:
            audio.channels[c].queue[0].blocks = 1
            audio.channels[c].phase = .playing
            blockBegins(c, first: true, m)
        case .playing:
            let front = audio.channels[c].queue[0]
            if front.cycles != 0, front.blocks >= Int(front.cycles) {
                // It has played all its blocks: this one is the next write's, which Paula has been given.
                audio.channels[c].queue.removeFirst()
                audio.replies.append((front.request, 0, false))
                guard audio.channels[c].nextLoaded, !audio.channels[c].queue.isEmpty else {
                    // Nothing behind it: the channel's DMA and interrupt turned off, its period and volume
                    // left (as 34.1 does when Marble Madness's attack of a note ends before the rest of the
                    // note is sent).
                    paula(m, 0x96, 1 << UInt16(c))
                    paula(m, 0x9A, bit)
                    audio.channels[c].phase = .idle
                    audio.channels[c].nextLoaded = false
                    return
                }
                audio.channels[c].nextLoaded = false
                audio.channels[c].queue[0].blocks = 1
                blockBegins(c, first: true, m)
            } else {
                // (Counted no further than the most a write can ask for.)
                if front.blocks <= Int(UInt16.max) { audio.channels[c].queue[0].blocks += 1 }
                blockBegins(c, first: false, m)
            }
        }
    }

    /// A block of the first write in the queue begins: its period and volume if it is its first and it
    /// asks, its message sent if it asks for one (ADIOF_WRITEMESSAGE); the channel's interrupt off if it
    /// plays for ever with nothing behind it; the request cleared; and the next write given to Paula if
    /// this is the last block.
    private mutating func blockBegins(_ c: Int, first: Bool, _ m: borrowing AmigaMachine) {
        let bit = UInt16(0x80) << UInt16(c)
        let w = audio.channels[c].queue[0]
        if first, w.perVol { writePeriodAndVolume(c, w.request, m) }
        if first, m.peek8(w.request + Self.ioFlags) & AmigaAudioDevice.flagWriteMessage != 0 {
            audio.replies.append((w.request + AmigaAudioDevice.writeMessage, 0, true))
        }
        if w.cycles == 0, audio.channels[c].queue.count == 1 { paula(m, 0x9A, bit) }
        paula(m, 0x9C, bit)
        loadNextIfLast(c, m)
    }

    /// The device's software interrupt: the replies it has to make, in order.
    mutating func softInterrupt(_ m: inout AmigaMachine) {
        guard !audio.replies.isEmpty else { return }
        let replies = audio.replies
        audio.replies.removeAll()
        for r in replies {
            if r.message {
                reply(r.request, m)
            } else {
                m.poke8(r.request + Self.ioError, UInt8(bitPattern: r.error))
                reply(r.request, m)
            }
        }
    }
}
