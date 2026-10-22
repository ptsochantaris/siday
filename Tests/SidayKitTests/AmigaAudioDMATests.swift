// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
import Testing

// Paula's voices, moved on a voice at a time and many words at once (`AmigaAudioDMA.run(to:)`), against
// the same moved on a step at a time as UAE moves them (`runByStepping`): the same interrupts asked for
// at the same moments, and the voices left the same, whatever a player writes to them and whenever; and
// the moment the next is asked for (`nextRequest`) as the steps come to it.

private struct Mix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ n: UInt64) -> UInt64 { next() % n }
}

@Test(arguments: 0 ..< 64)
func amigaAudioDMAGoesAsItsSteps(seed: Int) {
    var random = Mix64(state: UInt64(seed) &* 7919 &+ 1)
    var fast = AmigaAudioDMA(), stepped = AmigaAudioDMA()
    var fastRequests: UInt16 = 0, steppedRequests: UInt16 = 0
    var time: UInt64 = 0
    var dmacon: UInt16 = 0x200
    var adkcon: UInt16 = 0
    // (Lengths and periods of every kind: one word, none (the longest), words shorter and longer than a
    // line, and around the line's length.)
    let lengths: [UInt16] = [0, 1, 2, 3, 5, 16, 100, 1000, 30000]
    let periods: [UInt16] = [0, 16, 50, 100, 113, 114, 120, 200, 227, 228, 300, 428, 1000, 5000]
    for _ in 0 ..< 4000 {
        switch random.below(100) {
        case 0 ..< 30:
            // Time passes: a little, a line or so, a tick, or a long while.
            let spans: [UInt64] = [7, 113, 227, 2000, 70937, 200_000]
            time += random.below(spans[Int(random.below(UInt64(spans.count)))] + 1)
        case 30 ..< 45:
            let v = Int(random.below(4))
            let register: UInt16 = [0x0, 0x2, 0x4, 0x6, 0xA][Int(random.below(5))]
            let value: UInt16 = switch register {
            case 0x4: lengths[Int(random.below(UInt64(lengths.count)))]
            case 0x6: periods[Int(random.below(UInt64(periods.count)))] &+ UInt16(random.below(3))
            default: UInt16(truncatingIfNeeded: random.next())
            }
            fast.write(v, register, value, at: time, &fastRequests)
            stepped.write(v, register, value, at: time, &steppedRequests)
        case 45 ..< 60:
            // A voice's DMA on or off.
            let bit = UInt16(1) << UInt16(random.below(4))
            dmacon = random.below(3) == 0 ? dmacon & ~bit : dmacon | bit
            if random.below(40) == 0 { dmacon ^= 0x200 }
            fast.setDMA(dmacon, at: time)
            stepped.setDMA(dmacon, at: time)
        case 60 ..< 85:
            // The player answers the voices' interrupts, or some of them.
            let cleared = random.below(2) == 0 ? UInt16(0x780) : UInt16(0x80) << UInt16(random.below(4))
            fastRequests &= ~cleared
            steppedRequests &= ~cleared
        case 85 ..< 88:
            // Now and then, a voice modulating another.
            adkcon = random.below(3) == 0 ? UInt16(random.below(256)) : 0
        default:
            break
        }
        fast.run(to: time, intreq: &fastRequests, adkcon: adkcon)
        stepped.runByStepping(to: time, intreq: &steppedRequests, adkcon: adkcon)
        #expect(fast == stepped)
        #expect(fastRequests == steppedRequests)
        let fastNext = fast.nextEvent, steppedNext = stepped.nextEvent
        #expect(fastNext == steppedNext)
        if fast != stepped || fastRequests != steppedRequests { return }
        // When the next of some of the voices asks for its interrupt, against the steps that ask for it.
        let wanted = UInt16(random.below(16)) << 7
        let horizon = time + random.below(300_000)
        if AmigaAudioDMA.canTellRequests(of: wanted, adkcon: adkcon) {
            let asks = fast.nextRequest(of: wanted, intreq: fastRequests, adkcon: adkcon, by: horizon)
            var ahead = stepped, aheadRequests = steppedRequests
            if let asks {
                #expect(asks > time && asks <= horizon)
                ahead.runByStepping(to: asks - 1, intreq: &aheadRequests, adkcon: adkcon)
                #expect(aheadRequests & wanted & ~steppedRequests == 0)
                ahead.runByStepping(to: asks, intreq: &aheadRequests, adkcon: adkcon)
                #expect(aheadRequests & wanted & ~steppedRequests != 0)
            } else {
                ahead.runByStepping(to: horizon, intreq: &aheadRequests, adkcon: adkcon)
                #expect(aheadRequests & wanted & ~steppedRequests == 0)
            }
        }
    }
}
