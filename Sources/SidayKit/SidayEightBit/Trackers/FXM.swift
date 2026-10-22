// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

// Fuxoft AY Language player, ported from Ay_Emul by Sergey Bulba (Players.pas, FXM_Get_Registers and GetTimeFXM).
// Field names and control flow follow the Pascal so the two can be read side by side. The Pascal relies on
// 8- and 16-bit variables wrapping; here every field is an Int and the wrap is applied explicitly.
//
// This is not a pattern tracker. Each channel runs its own small program of notes, jumps, calls and counted
// loops, with a stack of its own, and addresses in it are absolute: a .fxm file is "FXSM", the address the
// music was assembled for, and the music itself, which starts with the entry points of the three channels.
// A program has no end. A tune that stops does so by going round a silent loop for ever.

public final class FXMSource: AYFrameSource {
    private struct Channel {
        var addressInPattern = 0, pointInSample = 0, samplePointer = 0, pointInOrnament = 0, ornamentPointer = 0, ton = 0
        var fxmMixer = 0, note = 0, volume = 0, amplitude = 0
        var transposit = 0, noteSkipCounter = 0, sampleTikCounter = 0
        var b0e = false, b1e = false, b2e = false, b3e = false
        /// FXM_Stek: return addresses, loop counters with the address to loop to, and saved transpositions.
        var stek: [Int] = []
    }

    private static let headerSize = 6
    /// What a NOISE+ sum is masked with. A .fxm file always gets 31; only the AMAD kind of .ay file can ask for
    /// the 15 that some early players used.
    private static let amadAndsix = 31
    /// More steps than any program takes to reach its next note, and more stack than any program uses.
    private static let stepLimit = 65536, stekLimit = 65536

    private let mem: ModuleMemory
    private let address: Int
    private var noiseBase = 0
    private var a = Channel(), b = Channel(), c = Channel()
    /// Set when a program cannot go on: its stack ran out, or it never reached a note.
    private var broken = false

    // The Pascal player does not know where the tune loops: Ay_Emul measures it before playing (GetTimeFXM)
    // and wraps its tick counter at that length. Here the loops are counted off by tick in the same way.
    /// Ticks before the first loop and from each loop to the next. Five minutes, as Ay_Emul gives a tune whose
    /// loop it does not find, unless something better is known.
    private var time = 15000, period = 15000
    /// Tick after which nothing more is heard, for a tune that ends in a silent loop.
    private var lastTick = Int.max
    private var tickCounter = 0, nextLoop = 0
    public private(set) var loopCount = 0
    public private(set) var hasEnded = false
    public let info: TuneInfo

    public init(_ data: [UInt8]) throws {
        guard data.count >= Self.headerSize + 6 else { throw TuneError.malformed("not an FXM module") }
        // LoadTrackerModule: everything after the header goes to the address the header names.
        address = Int(data[4]) | Int(data[5]) << 8
        let length = min(data.count - Self.headerSize, 65536 - address)
        var image = [UInt8](repeating: 0, count: address)
        image.append(contentsOf: data[Self.headerSize ..< Self.headerSize + length])
        mem = ModuleMemory(image)

        // Ay_Emul opens a .fxm file without testing it, and does not look at the signature either. What is
        // asked for here is the least a module needs to start: three programs that begin inside it.
        for channel in 0 ..< 3 {
            let entry = mem.word(address + channel * 2)
            guard address + 6 <= 65536, entry >= address, entry < address + length else {
                throw TuneError.malformed("FXM structure is not valid")
            }
        }

        var info = TuneInfo(format: "FXM")
        info.detail = "Fuxoft AY Language"
        self.info = info

        // GetTimeFXM tells where a pass is over by the jumps in the three programs. That is where the music
        // begins again, but it finds no such place in some tunes that do loop, and in a tune that plays a
        // section twice before going on it takes the repeat for the loop. So the output of the player is
        // looked at as well: it says how long a pass really is, and where the tune is first heard to repeat,
        // which may be a little way into the second pass when that does not begin quite as the first did.
        // GetTimeFXM's answer is taken if it is no later than that, with a whole pass played and the
        // repeating begun.
        let cycle = findCycle()
        let jumps = Self.getTime(mem, address, after: cycle.map { max($0.start, $0.length) } ?? 0)
        var known = true
        if let (start, length) = cycle {
            time = start + length
            period = length
            if let (tm, _) = jumps, tm < time { time = tm }
        } else if let (tm, lp) = jumps {
            time = tm
            period = max(tm - lp, 1)
        } else {
            known = false
        }
        if known { findEnd() }
        restart()
    }

    public func restart() {
        loopCount = 0
        hasEnded = false
        broken = false
        tickCounter = 0
        nextLoop = time
        noiseBase = 0
        var channel = Channel()
        channel.noteSkipCounter = 1
        channel.fxmMixer = 8
        a = channel; b = channel; c = channel
        a.addressInPattern = mem.word(address)
        b.addressInPattern = mem.word(address + 2)
        c.addressInPattern = mem.word(address + 4)
    }

    /// Ticks the player is run for to find the loop: forty minutes. A loop of up to a quarter of that is found.
    private static let observed = 120_000

    /// The tick from which what the player sends to the chip repeats, and after how many ticks it does.
    /// Not from Ay_Emul. Nil if a program goes wrong or the second half of the run is not the same thing at
    /// least twice over.
    private func findCycle() -> (start: Int, length: Int)? {
        let regs = UnsafeMutablePointer<AYRegs>.allocate(capacity: 1)
        regs.initialize(to: AYRegs())
        defer { regs.deallocate() }
        restart()
        var frames = [Int]()
        frames.reserveCapacity(Self.observed)
        for _ in 0 ..< Self.observed {
            tick(regs)
            if broken { return nil }
            // All the player writes: three 12-bit tone periods, the noise period, the mixer and three volumes.
            let r = regs[0]
            frames.append(r.tonA | r.tonB << 12 | r.tonC << 24 | r.noise << 36 | r.mixer << 41 | r.amplA << 47 | r.amplB << 52 | r.amplC << 57)
        }
        // The smallest period of the second half, by the prefix function of Knuth, Morris and Pratt.
        let half = Self.observed / 2
        var prefix = [Int](repeating: 0, count: half)
        var k = 0
        for i in 1 ..< half {
            while k > 0, frames[half + i] != frames[half + k] { k = prefix[k - 1] }
            if frames[half + i] == frames[half + k] { k += 1 }
            prefix[i] = k
        }
        let length = half - prefix[half - 1]
        guard length * 2 <= half else { return nil }
        // The repeating goes back as far as each tick is still the same as the one a period later.
        var start = half
        while start > 0, frames[start - 1] == frames[start - 1 + length] { start -= 1 }
        return (start, length)
    }

    /// Looks for a tune that stops: one of which nothing is heard for a whole pass after the first, on any
    /// channel. Such a tune ends with its last sound instead of looping. Not from Ay_Emul, which would go on
    /// repeating the silence.
    private func findEnd() {
        let regs = UnsafeMutablePointer<AYRegs>.allocate(capacity: 1)
        regs.initialize(to: AYRegs())
        defer { regs.deallocate() }
        // No pass is longer than the first, which may have an introduction.
        let until = time + max(time, 3000)
        var heard = 0
        restart()
        while tickCounter < until {
            tick(regs)
            if broken { return }
            if regs[0].amplA | regs[0].amplB | regs[0].amplC != 0 {
                if tickCounter > time { return }
                heard = tickCounter
            }
        }
        lastTick = max(heard, 1)
    }

    // MARK: Player

    private func realGetRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        regs[0].noise = noiseBase & 31
        ch.b2e = false
        if ch.ton != 0 {
            ch.amplitude = ch.volume & 15
        } else {
            ch.amplitude = 0
        }
    }

    private func getRegisters(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        ch.sampleTikCounter = s8(ch.sampleTikCounter - 1)
        if ch.sampleTikCounter == 0 {
            // The envelope: pairs of volume and duration, single bytes for one tick at volume + 50, and jumps.
            var guardCount = 0
            sample: repeat {
                let value = Int(mem[ch.pointInSample])
                switch value {
                case 0x00 ... 0x1D:
                    ch.volume = value
                    ch.pointInSample = u16(ch.pointInSample + 1)
                    ch.sampleTikCounter = mem.signed(ch.pointInSample)
                    ch.pointInSample = u16(ch.pointInSample + 1)
                    break sample
                case 0x80:
                    ch.pointInSample = mem.word(ch.pointInSample + 1)
                default:
                    ch.volume = u8(value - 0x32)
                    ch.pointInSample = u16(ch.pointInSample + 1)
                    ch.sampleTikCounter = 1
                    break sample
                }
                guardCount += 1
                if guardCount >= Self.stepLimit { broken = true }
            } while !broken
        }
        if ch.ton != 0, !ch.b2e {
            // The vibrato: signed steps for the tone period, or for the note once b3e is set, and commands.
            var guardCount = 0
            ornament: repeat {
                let value = Int(mem[ch.pointInOrnament])
                switch value {
                case 0x80:
                    ch.pointInOrnament = mem.word(ch.pointInOrnament + 1)
                case 0x82:
                    ch.pointInOrnament = u16(ch.pointInOrnament + 1)
                    ch.b3e = true
                case 0x83:
                    ch.pointInOrnament = u16(ch.pointInOrnament + 1)
                    ch.b3e = false
                case 0x84:
                    ch.pointInOrnament = u16(ch.pointInOrnament + 1)
                    ch.fxmMixer ^= 9
                default:
                    if ch.b3e {
                        ch.note = u8(ch.note + value)
                        ch.ton = TrackerTables.FXM_Table[min(ch.note, 0x53)]
                    } else {
                        ch.ton = u16(ch.ton + s8(value))
                    }
                    ch.pointInOrnament = u16(ch.pointInOrnament + 1)
                    break ornament
                }
                guardCount += 1
                if guardCount >= Self.stepLimit { broken = true }
            } while !broken
        }
        realGetRegisters(&ch, regs)
    }

    private func patternInterpreter(_ ch: inout Channel, _ regs: UnsafeMutablePointer<AYRegs>) {
        ch.noteSkipCounter = s8(ch.noteSkipCounter - 1)
        if ch.noteSkipCounter != 0 {
            getRegisters(&ch, regs)
            return
        }
        // The Pascal trusts the program. One that pops an empty stack, never stops pushing or never reaches a
        // note has gone wrong, and the tune is over.
        var guardCount = 0
        repeat {
            let value = Int(mem[ch.addressInPattern])
            switch value {
            case 0x00 ... 0x7F:
                if value != 0 {
                    ch.note = u8(value - 1 + ch.transposit)
                    ch.ton = TrackerTables.FXM_Table[min(ch.note, 0x53)]
                    ch.b3e = false
                } else {
                    ch.ton = 0
                }
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.noteSkipCounter = mem.signed(ch.addressInPattern)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.pointInOrnament = ch.ornamentPointer
                if !ch.b1e {
                    ch.b1e = ch.b0e
                    ch.pointInSample = ch.samplePointer
                    ch.volume = Int(mem[ch.pointInSample])
                    ch.pointInSample = u16(ch.pointInSample + 1)
                    ch.sampleTikCounter = mem.signed(ch.pointInSample)
                    ch.pointInSample = u16(ch.pointInSample + 1)
                    realGetRegisters(&ch, regs)
                } else {
                    getRegisters(&ch, regs)
                }
                return
            case 0x80:
                // JUMP
                ch.addressInPattern = mem.word(ch.addressInPattern + 1)
            case 0x81:
                // CALL
                ch.stek.append(u16(ch.addressInPattern + 3))
                ch.addressInPattern = mem.word(ch.addressInPattern + 1)
            case 0x82:
                // LOOP: the count, then the address of what is repeated.
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.stek.append(Int(mem[ch.addressInPattern]))
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.stek.append(ch.addressInPattern)
            case 0x83:
                // NEXT
                let i = ch.stek.count
                guard i >= 2 else { broken = true; break }
                ch.stek[i - 2] = u16(ch.stek[i - 2] - 1)
                if ch.stek[i - 2] & 255 != 0 {
                    ch.addressInPattern = ch.stek[i - 1]
                } else {
                    ch.stek.removeLast(2)
                    ch.addressInPattern = u16(ch.addressInPattern + 1)
                }
            case 0x84:
                // NOISE
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                noiseBase = Int(mem[ch.addressInPattern])
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0x85:
                // TYPE
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.fxmMixer = Int(mem[ch.addressInPattern])
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0x86:
                // VIB
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.ornamentPointer = mem.word(ch.addressInPattern)
                ch.addressInPattern = u16(ch.addressInPattern + 2)
            case 0x87:
                // ENV
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.samplePointer = mem.word(ch.addressInPattern)
                ch.addressInPattern = u16(ch.addressInPattern + 2)
            case 0x88:
                // TR
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.transposit = mem.signed(ch.addressInPattern)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0x89:
                // RET
                guard let top = ch.stek.popLast() else { broken = true; break }
                ch.addressInPattern = top
            case 0x8A:
                // LEG+
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.b0e = true
                ch.b1e = false
            case 0x8B:
                // LEG-
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.b0e = false
                ch.b1e = false
            case 0x8C:
                // EXTERNAL_CALL: machine code, which is not run.
                ch.addressInPattern = u16(ch.addressInPattern + 3)
            case 0x8D:
                // NOISE+
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                noiseBase = u8(noiseBase + Int(mem[ch.addressInPattern])) & Self.amadAndsix
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0x8E:
                // TR+
                ch.addressInPattern = u16(ch.addressInPattern + 1)
                ch.transposit = s8(ch.transposit + Int(mem[ch.addressInPattern]))
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0x8F:
                // Save the transposition.
                ch.stek.append(u16(ch.transposit))
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            case 0x90:
                // Restore it.
                guard let top = ch.stek.popLast() else { broken = true; break }
                ch.transposit = s8(top)
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            default:
                ch.addressInPattern = u16(ch.addressInPattern + 1)
            }
            guardCount += 1
            if guardCount >= Self.stepLimit || ch.stek.count > Self.stekLimit { broken = true }
        } while !broken
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        if hasEnded { return }
        if tickCounter == nextLoop {
            loopCount += 1
            nextLoop += period
        }
        tickCounter += 1

        patternInterpreter(&a, regs)
        patternInterpreter(&b, regs)
        patternInterpreter(&c, regs)
        if broken {
            a.amplitude = 0
            b.amplitude = 0
            c.amplitude = 0
        }

        regs[0].tonA = a.ton & 0xFFF
        regs[0].tonB = b.ton & 0xFFF
        regs[0].tonC = c.ton & 0xFFF
        regs[0].amplA = a.amplitude
        regs[0].amplB = b.amplitude
        regs[0].amplC = c.amplitude
        regs[0].mixer = (a.fxmMixer | b.fxmMixer << 1 | c.fxmMixer << 2) & 0x3F

        if broken || tickCounter >= lastTick { hasEnded = true }
    }

    // MARK: Length

    /// The three programs with everything but their control flow left out, as GetTimeFXM follows them.
    /// It differs from the Pascal in one respect: there every byte from 0x8F up is taken for a note, which the
    /// player does not do (0x8F and 0x90 save and restore the transposition, the rest are skipped). Here they
    /// are what they are in the player, so that this cannot drift away from what is played.
    private struct Walker {
        var j = [0, 0, 0], a = [1, 1, 1], transposit = [0, 0, 0]
        var stek: [[Int]] = [[], [], []]
        /// Where each channel last jumped to: the target of a JUMP, or the LOOP command a NEXT went back to.
        var jj = [0, 0, 0]
        /// Whether each channel's last command run included a JUMP (f7) or a NEXT that went back (f6).
        var f7 = [false, false, false], f6 = [false, false, false]
        /// FXM_Loop_Found's run only: the first tick at which each combination of the three positions was
        /// seen, at the start of a tick or on reaching a LOOP command.
        var seen: [Int: Int]?
        var tr = 0

        init(_ mem: ModuleMemory, _ address: Int) {
            for n in 0 ..< 3 { j[n] = mem.word(address + n * 2) }
        }

        static func key(_ j: [Int]) -> Int { j[0] | j[1] << 16 | j[2] << 32 }

        mutating func see() {
            let key = Self.key(j)
            if seen?[key] == nil { seen?[key] = tr }
        }

        /// All three channels have just gone back, at least one of them by a JUMP.
        var allJumped: Bool {
            (f7[0] && (f7[1] || f6[1]) && (f7[2] || f6[2]))
                || ((f7[0] || f6[0]) && f7[1] && (f7[2] || f6[2]))
                || ((f7[0] || f6[0]) && (f7[1] || f6[1]) && f7[2])
        }

        /// One interrupt. False where the Pascal raises a bad file structure error.
        mutating func tick(_ mem: ModuleMemory) -> Bool {
            for n in 0 ..< 3 {
                a[n] = u8(a[n] - 1)
                guard a[n] == 0 else { continue }
                f7[n] = false
                f6[n] = false
                var guardCount = 0
                interpret: while true {
                    let pc = j[n]
                    switch Int(mem[pc]) {
                    case 0x00 ... 0x7F:
                        if pc + 2 >= 65536 { return false }
                        a[n] = Int(mem[pc + 1])
                        j[n] = pc + 2
                        break interpret
                    case 0x80:
                        if pc >= 65536 - 2 { return false }
                        j[n] = mem.word(pc + 1)
                        jj[n] = j[n]
                        f7[n] = true
                    case 0x81:
                        if pc >= 65536 - 3 { return false }
                        stek[n].append(pc + 3)
                        j[n] = mem.word(pc + 1)
                    case 0x82:
                        see()
                        stek[n].append(Int(mem[pc + 1]))
                        stek[n].append(pc + 2)
                        j[n] = pc + 2
                    case 0x83:
                        let k = stek[n].count
                        if k < 2 { return false }
                        stek[n][k - 2] = u16(stek[n][k - 2] - 1)
                        if stek[n][k - 2] & 255 != 0 {
                            j[n] = stek[n][k - 1]
                            if j[n] < 2 { return false }
                            jj[n] = j[n] - 2
                            f6[n] = true
                        } else {
                            stek[n].removeLast(2)
                            j[n] = pc + 1
                        }
                    case 0x84, 0x85, 0x8D:
                        j[n] = pc + 2
                    case 0x88:
                        transposit[n] = mem.signed(pc + 1)
                        j[n] = pc + 2
                    case 0x8E:
                        transposit[n] = s8(transposit[n] + Int(mem[pc + 1]))
                        j[n] = pc + 2
                    case 0x86, 0x87, 0x8C:
                        j[n] = pc + 3
                    case 0x89:
                        guard let top = stek[n].popLast() else { return false }
                        j[n] = top
                    case 0x8F:
                        stek[n].append(u16(transposit[n]))
                        j[n] = pc + 1
                    case 0x90:
                        guard let top = stek[n].popLast() else { return false }
                        transposit[n] = s8(top)
                        j[n] = pc + 1
                    default:
                        j[n] = pc + 1
                    }
                    guardCount += 1
                    if j[n] >= 65536 || guardCount >= FXMSource.stepLimit || stek[n].count > FXMSource.stekLimit { return false }
                }
            }
            return true
        }
    }

    /// GetTimeFXM: the tune is over at the first tick in which all three channels jump back and land where
    /// they have all been together before (FXM_Loop_Found). Returns the ticks before that one and the tick at
    /// which they were there, which Ay_Emul takes for the loop point. Nil if there is no such tick within an
    /// hour, where Ay_Emul gives up, or if a program goes wrong. Ay_Emul stops at the first such tick; here
    /// those before `after` ticks have been played are passed over.
    private static func getTime(_ mem: ModuleMemory, _ address: Int, after: Int) -> (Int, Int)? {
        if address > 65536 - 6 { return nil }
        var walker = Walker(mem, address)
        var seen: [Int: Int]?
        var tm = 0
        repeat {
            guard walker.tick(mem) else { return nil }
            tm += 1
            if tm > 180_000 { return nil }
            guard walker.allJumped, tm > after else { continue }
            if seen == nil {
                // FXM_Loop_Found starts again from the top each time and stops at the first tick that ends
                // with all three channels having jumped, wherever it was called from. So one run answers
                // every call.
                var again = Walker(mem, address)
                again.seen = [:]
                repeat {
                    again.see()
                    guard again.tick(mem) else { return nil }
                    again.tr += 1
                } while !again.allJumped
                seen = again.seen
            }
            if let lp = seen?[Walker.key(walker.jj)] { return (tm - 1, lp) }
        } while true
    }
}
