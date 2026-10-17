// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// Each voice's scope (`ChannelWaves`): a held note stands still, a quiet voice is smaller, a silent
// one is flat, and the scope is of the sound as it is heard, not as far as it has been made.

/// A scope's distance from the middle at its highest.
private func height(_ scope: ArraySlice<UInt8>) -> Int { scope.map { abs(Int($0) - 128) }.max() ?? 0 }
/// The most that two scopes differ by at any point.
private func apart(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 }
/// How many points of two scopes are not the same.
private func differing(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int { zip(a, b).count { abs(Int($0) - Int($1)) > 2 } }

@Test func aHeldNoteStandsStill() {
    // A square wave of 100 samples a cycle, at full swing; scopes taken a part of a cycle apart.
    let waves = ChannelWaves(voices: 1, rate: 48000, fullSwing: 1)
    let note = ChannelPitch.note(ofHz: 480)
    var made = 0
    func make(_ count: Int) {
        for offset in 0 ..< count { waves.store(0, at: offset, (made + offset) % 100 < 50 ? 1 : -1) }
        waves.advance(by: count)
        made += count
    }
    var first = [UInt8](repeating: 0, count: ChannelWaves.points)
    var later = first
    make(3000)
    first.withUnsafeMutableBufferPointer { waves.take(0, pitch: note, periodic: true, behind: 0, into: $0.baseAddress!) }
    for step in [37, 61, 13, 99] {
        make(step)
        later.withUnsafeMutableBufferPointer { waves.take(0, pitch: note, periodic: true, behind: 0, into: $0.baseAddress!) }
        #expect(apart(first[...], later[...]) <= 2)
    }
    // Two cycles: up, down, up, down, beginning where it rises.
    #expect(first[0 ..< 16].allSatisfy { $0 > 200 } && first[16 ..< 32].allSatisfy { $0 < 56 })
    #expect(first[32 ..< 48].allSatisfy { $0 > 200 } && first[48 ..< 64].allSatisfy { $0 < 56 })
}

@Test func aScopeIsAsLoudAsItsVoice() {
    let waves = ChannelWaves(voices: 3, rate: 48000, fullSwing: 1)
    for offset in 0 ..< 4000 {
        let up = offset % 100 < 50
        waves.store(0, at: offset, up ? 1 : -1)
        waves.store(1, at: offset, up ? 0.25 : -0.25)
        waves.store(2, at: offset, 0)
    }
    waves.advance(by: 4000)
    var scopes = [UInt8](repeating: 0, count: ChannelWaves.points * 3)
    scopes.withUnsafeMutableBufferPointer { scopes in
        for voice in 0 ..< 3 {
            waves.take(voice, pitch: ChannelPitch.note(ofHz: 480), periodic: true, behind: 0, into: scopes.baseAddress! + voice * ChannelWaves.points)
        }
    }
    #expect(height(scopes[0 ..< 64]) == 127)
    // A quarter of the swing is half the height: the lights' gentle curve, so a quiet voice is still seen.
    #expect(abs(height(scopes[64 ..< 128]) - 64) <= 1)
    #expect(scopes[128 ..< 192].allSatisfy { $0 == 128 })
}

@Test func aScopeIsOfWhatIsHeard() {
    // A voice that is silent and then sounds: scopes of the time before it sounded are flat.
    let waves = ChannelWaves(voices: 1, rate: 48000, fullSwing: 1)
    for offset in 0 ..< 4000 { waves.store(0, at: offset, offset < 2000 ? 0 : (offset % 100 < 50 ? 1 : -1)) }
    waves.advance(by: 4000)
    var scope = [UInt8](repeating: 0, count: ChannelWaves.points)
    let note = ChannelPitch.note(ofHz: 480)
    scope.withUnsafeMutableBufferPointer { waves.take(0, pitch: note, periodic: true, behind: 2500, into: $0.baseAddress!) }
    #expect(scope.allSatisfy { $0 == 128 })
    // So is what the player has made and not handed out.
    waves.ahead = 2500
    scope.withUnsafeMutableBufferPointer { waves.take(0, pitch: note, periodic: true, behind: 0, into: $0.baseAddress!) }
    #expect(scope.allSatisfy { $0 == 128 })
    waves.ahead = 0
    scope.withUnsafeMutableBufferPointer { waves.take(0, pitch: note, periodic: true, behind: 0, into: $0.baseAddress!) }
    #expect(height(scope[...]) == 127)
    // And what is no longer kept is flat, not made up.
    scope.withUnsafeMutableBufferPointer { waves.take(0, pitch: note, periodic: true, behind: 100_000, into: $0.baseAddress!) }
    #expect(scope.allSatisfy { $0 == 128 })
}

/// A tune that sets its registers once: a tone on the first channel at full volume, the second at
/// a lower volume, and the third silent.
private final class HeldChord: AYFrameSource {
    let info = TuneInfo(format: "TEST")
    private(set) var loopCount = 0
    var chipCount: Int { 1 }
    func restart() {}
    func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        regs[0].tonA = 200
        regs[0].tonB = 317
        regs[0].mixer = 0b111_100
        regs[0].amplA = 15
        regs[0].amplB = 9
        regs[0].amplC = 0
    }
}

@Test func anAYChipsChannelsHaveScopes() {
    let session = TuneSession(renderer: AYFramePlayer(source: HeldChord(), options: LoadOptions()), policy: PlaybackPolicy())
    #expect(session.keepChannelWaves())
    var buffer = [Float](repeating: 0, count: 1024 * 2)
    var scopes = [UInt8](repeating: 0, count: ChannelWaves.points * 3)
    var first: [UInt8] = []
    for round in 0 ..< 6 {
        _ = buffer.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: 1000 + round * 7) }
        scopes.withUnsafeMutableBufferPointer { session.takeChannelWaves(into: $0.baseAddress!, behind: 0) }
        if round == 2 { first = scopes }
    }
    // The chip's squares stand still from one moment to another, as loud as they are, and a
    // channel that is silent is flat.
    // (A square's edge falls between two of the output's samples, and where between them is not
    // known: the point at an edge can differ, and no other.)
    #expect(differing(first[0 ..< 64], scopes[0 ..< 64]) <= 4)
    #expect(differing(first[64 ..< 128], scopes[64 ..< 128]) <= 4)
    #expect(height(scopes[0 ..< 64]) > 120)
    #expect(height(scopes[64 ..< 128]) > 20 && height(scopes[64 ..< 128]) < 100)
    #expect(scopes[128 ..< 192].allSatisfy { $0 == 128 })
}

@Test func aModulesVoicesHaveScopes() throws {
    // One pattern: a square wave on the first channel; nothing on the others.
    var file = Array("scope".utf8)
    file += [UInt8](repeating: 0, count: 20 - file.count)
    for sample in 0 ..< 31 {
        var header = [UInt8](repeating: 0, count: 30)
        if sample == 0 {
            header[22 ... 23] = [0, 16]
            header[25] = 64
            header[26 ... 29] = [0, 0, 0, 16]
        } else {
            header[29] = 1
        }
        file += header
    }
    file += [1, 127] + [UInt8](repeating: 0, count: 128) + Array("M.K.".utf8)
    var pattern = [UInt8](repeating: 0, count: 64 * 4 * 4)
    pattern.replaceSubrange(0 ..< 4, with: [UInt8(428 >> 8), UInt8(428 & 0xFF), 0x10, 0])
    file += pattern
    file += [UInt8](repeating: 0x7F, count: 16) + [UInt8](repeating: 0x81, count: 16)

    let session = TuneSession(renderer: try TuneLoader.load(file, format: .mod, options: LoadOptions()), policy: PlaybackPolicy())
    #expect(session.keepChannelWaves())
    var buffer = [Float](repeating: 0, count: 2048 * 2)
    _ = buffer.withUnsafeMutableBufferPointer { session.render(into: $0.baseAddress!, frames: 2048) }
    var scopes = [UInt8](repeating: 0, count: ChannelWaves.points * 4)
    scopes.withUnsafeMutableBufferPointer { session.takeChannelWaves(into: $0.baseAddress!, behind: 0) }
    #expect(height(scopes[0 ..< 64]) > 100)
    #expect(scopes[64...].allSatisfy { $0 == 128 })
}
