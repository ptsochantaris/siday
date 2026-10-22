// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// What a program on the machine writes to Paula, told to whoever plays it (`TFMXOutput`, which
/// `PaulaTickRenderer` hears), each write at the moment within the tick it was made.
///
/// Her registers do as the hardware's do: a voice's location and length are where it goes on from when
/// it next comes round (and where it starts, when its DMA is turned on), its period is taken up as it
/// finishes the sample it is on, and its volume at once. A voice plays while its bit of DMACON and the
/// DMA's master bit (DMAEN) are both set.
///
/// `PaulaTickRenderer` sets each voice's period and volume, and the filter, once more after the player
/// has run, as they were as the tick began (`periods`, `volumes`, `lightFilter`), which changes nothing;
/// what the program wrote is done after that, at its moment.
struct AmigaPaulaFeed {
    /// What the registers held as the tick began: the volume as Paula takes it, seven bits and no more
    /// than 64.
    private(set) var periods = InlineArray<4, UInt16>(repeating: 0)
    private(set) var volumes = InlineArray<4, UInt16>(repeating: 0)
    private(set) var lightFilter = false

    // The registers as written so far.
    private var locations = InlineArray<4, UInt32>(repeating: 0)
    private var lengths = InlineArray<4, UInt16>(repeating: 0)
    private var periodsNow = InlineArray<4, UInt16>(repeating: 0)
    private var volumesNow = InlineArray<4, UInt16>(repeating: 0)
    private var filterNow = false
    private var dmacon: UInt16 = 0
    /// The voices whose DMA is on.
    private var playing: UInt16 = 0

    /// The chip RAM's size: a location outside it is read as nothing.
    private let memorySize: Int

    init(memorySize: Int) {
        self.memorySize = memorySize
    }

    /// The registers as the machine is switched on: nothing in them, the filter off.
    mutating func reset() {
        self = AmigaPaulaFeed(memorySize: memorySize)
    }

    /// As a tick begins: what the registers hold now is what they held as it began.
    mutating func beginTick() {
        periods = periodsNow
        for v in 0 ..< 4 { volumes[v] = min(64, volumesNow[v] & 0x7F) }
        lightFilter = filterNow
    }

    /// Tells `output` the writes, each at its moment: its processor's cycles into the call halved (two to
    /// each of Paula's clocks), and `lead` clocks after that.
    mutating func tell<Output: TFMXOutput>(_ writes: [AmigaWrite], lead: Int = 0, _ output: inout Output) {
        var told = -1
        for write in writes {
            let clocks = lead + max(0, write.cycles) / 2
            if clocks != told {
                output.timed(at: clocks)
                told = clocks
            }
            take(write, &output)
        }
    }

    private mutating func take<Output: TFMXOutput>(_ write: AmigaWrite, _ output: inout Output) {
        switch write.register {
        case 0x096:
            dmacon = write.value & 0x8000 != 0 ? dmacon | write.value & 0x7FFF : dmacon & ~write.value
            let now = dmacon & 0x200 != 0 ? dmacon & 0xF : 0
            for v in 0 ..< 4 {
                let bit: UInt16 = 1 << UInt16(v)
                if now & bit != 0, playing & bit == 0 {
                    output.on(v)
                } else if now & bit == 0, playing & bit != 0 {
                    output.off(v)
                }
            }
            playing = now
        case AmigaWrite.filter:
            filterNow = write.value != 0
            output.writeLightFilter(filterNow)
        case 0x0A0 ..< 0x0E0:
            let v = Int(write.register - 0xA0) >> 4
            switch write.register & 0xF {
            case 0x0:
                locations[v] = locations[v] & 0xFFFF | UInt32(write.value) << 16
                tellBuffer(v, &output)
            case 0x2:
                locations[v] = locations[v] & 0xFFFF_0000 | UInt32(write.value & 0xFFFE)
                tellBuffer(v, &output)
            case 0x4:
                lengths[v] = write.value
                tellBuffer(v, &output)
            case 0x6:
                periodsNow[v] = write.value
                output.writePeriod(v, write.value)
            case 0x8:
                volumesNow[v] = write.value
                output.writeVolume(v, write.value)
            default:
                // (AUDxDAT, which a voice whose DMA is off plays a word of by hand: no player of music
                // here does.)
                break
            }
        default:
            // (ADKCON, whose modulation of one voice by another no player of music here uses.)
            break
        }
    }

    private func tellBuffer<Output: TFMXOutput>(_ v: Int, _ output: inout Output) {
        // Chip RAM is two megabytes at most; a location past the machine's is read as nothing.
        let at = Int(locations[v] & 0x1F_FFFE)
        output.takeNextBuffer(v, start: at < memorySize ? at : memorySize, length: lengths[v])
    }
}
