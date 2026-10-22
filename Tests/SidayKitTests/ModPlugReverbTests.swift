// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayTrackers
import Testing

// ModPlug's reverb, set beside what OpenMPT's own class (`CReverb`, libopenmpt 0.8.9) makes of the same
// made-up sound, played as OpenMPT's mixer plays it. The thorough check is made outside the package: 54
// cases, every room, four sample rates, blocks of one frame to a full one, offsets, changes of room and
// depth while playing, all of them alike to the last bit. These three keep the port as it is.

private struct Golden {
    let room: UInt32, depth: UInt32, seconds: Int, sendSeconds: Int, offsetSeconds: Int
    let sizes: [Int]
    let click: Bool
    /// An FNV-1a hash of every sample of the main mix, and of the two offsets and the countdown after
    /// each block; where the reverb shut itself down; and the left and right of the frames in `picks`.
    let hash: UInt32, shutAt: Int
    let values: [Int32]
}

private let picks = [100, 1000, 5000, 20000, 48000, 70000, 100_000, 150_000, 200_000, 250_000, 300_000, 380_000]

private let goldens = [
    // Noise sent in half-seconds for three seconds, in blocks of many sizes, then the tail.
    Golden(room: 0, depth: 8, seconds: 9, sendSeconds: 3, offsetSeconds: 0, sizes: [512, 1, 7, 256, 100], click: false,
           hash: 0xEA48_3FA3, shutAt: 360_036,
           values: [25_075_751, 3_124_073, 21_199_899, 14_840_026, 6_609_669, -9_747_967, -13_671_104, 17_109_048, 29363, -41487, -23_459_370,
                    24_814_964, 17_293_169, -30_810_528, -2798, 11315, 48, 113, 48, 113, 48, 113, 0, 0]),
    // A click in the hangar, whose reverb is ten seconds long, and the hangar's long wait before it stops.
    Golden(room: 16, depth: 12, seconds: 11, sendSeconds: 0, offsetSeconds: 0, sizes: [512], click: true,
           hash: 0x3DCA_CE6F, shutAt: 483_328,
           values: [0, 0, -13690, 4574, 13269, -1406, 63762, 28560, 170, 216, 219, 497, 219, 497, 219, 497, 219, 497, 219, 497, 219, 497, 219, 497]),
    // Offsets left by voices that stopped, dying away while sent and after.
    Golden(room: 1, depth: 8, seconds: 8, sendSeconds: 1, offsetSeconds: 2, sizes: [512, 37], click: false,
           hash: 0x745E_4DE4, shutAt: 264_581,
           values: [30_083_505, 7_692_795, 31_848_456, 11_299_409, 23_081_658, -21_482_780, -26_727_449, 24_437_327, 548_416, -307_531, -410_201,
                    1_253_688, 710_373, 19225, 511, 511, 511, 511, 511, 511, 0, 0, 0, 0]),
]

@Suite struct ModPlugReverbTests {
    @Test(arguments: goldens.indices) func matchesOpenMPT(_ index: Int) {
        let g = goldens[index]
        let rate = 48000
        let reverb = ModPlugReverb(sampleRate: rate, room: g.room, depth: g.depth)
        let main = UnsafeMutablePointer<Int32>.allocate(capacity: 1024)
        defer { main.deallocate() }
        let send = reverb.sendBuffer
        var state: UInt32 = 1, hash: UInt32 = 2_166_136_261
        func mix(_ v: Int32) { hash = (hash ^ UInt32(bitPattern: v)) &* 16_777_619 }
        var values = [Int32]()
        var frame = 0, shutAt = -1, n = 0, p = 0
        while frame < g.seconds * rate {
            let size = g.sizes[n % g.sizes.count]
            let touched = g.click ? n == 0 : (frame / (rate / 2)) % 2 == 0 && frame < g.sendSeconds * rate
            main.update(repeating: 0, count: 1024)
            if touched {
                reverb.touch(send: send, frames: size)
                for i in 0 ..< 2 * size {
                    if g.click {
                        send[i] &+= i == 0 ? 1 << 26 : i == 1 ? -(1 << 25) : 0
                        continue
                    }
                    state = state &* 1_664_525 &+ 1_013_904_223
                    send[i] &+= Int32(bitPattern: state) >> 6
                }
            }
            if frame < g.offsetSeconds * rate, n % 7 == 3 {
                reverb.rightOffset &+= 1 << 24
                reverb.leftOffset &-= 3 << 22
            }
            reverb.process(main: main, send: send, frames: size)
            for i in 0 ..< size {
                mix(main[2 * i])
                mix(main[2 * i + 1])
                while p < picks.count, picks[p] == frame + i {
                    values.append(main[2 * i])
                    values.append(main[2 * i + 1])
                    p += 1
                }
            }
            mix(reverb.rightOffset)
            mix(reverb.leftOffset)
            mix(Int32(bitPattern: reverb.samplesLeft))
            frame += size
            n += 1
            if shutAt < 0, reverb.samplesLeft == 0 { shutAt = frame }
        }
        #expect(values == g.values)
        #expect(shutAt == g.shutAt)
        #expect(hash == g.hash)
        #expect(reverb.rightOffset == 0 && reverb.leftOffset == 0)
    }

    /// Nothing sent, nothing added: the main mix is left as it was, and the send buffer is not read.
    @Test func silentWhenNothingIsSent() {
        let reverb = ModPlugReverb(sampleRate: 48000)
        let main = UnsafeMutablePointer<Int32>.allocate(capacity: 1024)
        defer { main.deallocate() }
        for i in 0 ..< 1024 { main[i] = Int32(i) &* 7919 }
        reverb.sendBuffer.update(repeating: 12345, count: 1024)
        reverb.process(main: main, send: reverb.sendBuffer, frames: 512)
        #expect((0 ..< 1024).allSatisfy { main[$0] == Int32($0) &* 7919 })
        #expect(reverb.samplesLeft == 0)
    }
}
