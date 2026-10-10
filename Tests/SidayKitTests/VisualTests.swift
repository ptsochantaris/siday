// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// The pictures to listen by.

/// Paints for some seconds at thirty frames a second, with the voices doing one thing throughout.
private func watch(_ visualiser: Visualiser, from start: Double = 0, seconds: Double, levels: [Float], pitches: [Float], strike: Bool = false) {
    for frame in 0 ..< Int(seconds * 30) {
        visualiser.hear(levels: levels, pitches: pitches, struck: levels.map { _ in strike && frame == 0 })
        visualiser.paint(at: start + Double(frame) / 30)
    }
}

/// How many dots of each row of a lava lamp are wax: red or orange, where the liquid is blue.
private func wax(_ visualiser: Visualiser) -> [Int] {
    guard let pixels = visualiser.pixels else { return [] }
    return (0 ..< visualiser.height).map { row in
        (0 ..< visualiser.width).count { column in
            let at = (row * visualiser.width + column) * 4
            return pixels[at] > 140 && Int(pixels[at]) > Int(pixels[at + 2]) + 40
        }
    }
}

/// How bright each row of the picture is, top to bottom: the sum of its red, green and blue.
private func rows(_ visualiser: Visualiser) -> [Int] {
    guard let pixels = visualiser.pixels else { return [] }
    return (0 ..< visualiser.height).map { row in
        var sum = 0
        for column in 0 ..< visualiser.width {
            let at = (row * visualiser.width + column) * 4
            sum += Int(pixels[at]) + Int(pixels[at + 1]) + Int(pixels[at + 2])
        }
        return sum
    }
}

/// The row about which the picture's light is balanced, counting only what is well above the dimmest row.
private func balance(_ visualiser: Visualiser, above upTo: Int) -> Double {
    let light = rows(visualiser).prefix(upTo)
    let floor = light.min() ?? 0
    var total = 0.0, weighted = 0.0
    for (row, sum) in light.enumerated() {
        total += Double(sum - floor)
        weighted += Double(sum - floor) * Double(row)
    }
    return total > 0 ? weighted / total : 0
}

private func copy(_ visualiser: Visualiser) -> [UInt8] {
    Array(UnsafeBufferPointer(start: visualiser.pixels, count: visualiser.width * visualiser.height * 4))
}

@Test func pictureIsSizedForItsSpace() {
    // Half the points of the space, within limits, in fours, and of its shape.
    #expect(Visualiser.size(for: 728, 410) == (364, 204))
    #expect(Visualiser.size(for: 2560, 1440) == (448, 252))
    #expect(Visualiser.size(for: 200, 100) == (160, 80))
    #expect(Visualiser.size(for: 0, 0) == (0, 0))
}

@Test func pictureIsPaintedWhateverItIsGiven() {
    for mode in Visualiser.Mode.allCases {
        let visualiser = Visualiser(mode: mode)
        // Nothing to paint on yet, and no voices.
        visualiser.paint(at: 0)
        #expect(visualiser.pixels == nil)
        visualiser.resize(width: 160, height: 92)
        visualiser.paint(at: 0.1)
        // Voices come and go in number, and the picture changes size, between one frame and the next.
        watch(visualiser, from: 1, seconds: 0.5, levels: [1, 0.5, 0], pitches: [60, 0, 72])
        visualiser.resize(width: 200, height: 64)
        watch(visualiser, from: 2, seconds: 0.5, levels: [Float](repeating: 0.8, count: 32), pitches: [Float](repeating: 64, count: 32))
        watch(visualiser, from: 3, seconds: 0.2, levels: [], pitches: [])
        let picture = copy(visualiser)
        #expect(picture.count == 200 * 64 * 4)
        #expect(stride(from: 3, to: picture.count, by: 4).allSatisfy { picture[$0] == 255 })
        #expect(picture.contains { $0 != 0 && $0 != 255 })
    }
}

@Test func lavaFloatsHigherForAHigherNote() {
    /// The row the wax above the pool is balanced about.
    func height(of pitch: Float) -> Double {
        let visualiser = Visualiser(mode: .lava)
        visualiser.resize(width: 160, height: 100)
        // (The tune has been heard to go from one note to the other, so the lamp knows its range.)
        watch(visualiser, seconds: 0.1, levels: [1], pitches: [40])
        watch(visualiser, from: 0.1, seconds: 0.1, levels: [1], pitches: [90])
        watch(visualiser, from: 0.2, seconds: 8, levels: [1], pitches: [pitch])
        let rows = wax(visualiser).prefix(85)
        let total = rows.reduce(0, +)
        return total > 0 ? Double(rows.enumerated().reduce(0) { $0 + $1.offset * $1.element }) / Double(total) : -1
    }
    let low = height(of: 40), high = height(of: 90)
    #expect(high > 0 && high < 35)
    #expect(low > 55)

    // A voice that falls silent sinks back into the pool.
    let visualiser = Visualiser(mode: .lava)
    visualiser.resize(width: 160, height: 100)
    watch(visualiser, seconds: 6, levels: [1], pitches: [90])
    #expect(wax(visualiser)[10 ..< 60].reduce(0, +) > 200)
    watch(visualiser, from: 6, seconds: 14, levels: [0], pitches: [0])
    #expect(wax(visualiser)[10 ..< 60].reduce(0, +) == 0)
}

@Test func auroraIsHigherForAHigherNote() {
    func height(of pitch: Float) -> Double {
        let visualiser = Visualiser(mode: .aurora)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.1, levels: [1], pitches: [40])
        watch(visualiser, from: 0.1, seconds: 0.1, levels: [1], pitches: [90])
        watch(visualiser, from: 0.2, seconds: 6, levels: [1], pitches: [pitch])
        return balance(visualiser, above: 100)
    }
    #expect(height(of: 90) < height(of: 40) - 25)
}

@Test func pictureNeverFlashes() {
    // The worst there is: every voice from nothing to as loud as it goes, at once, with a note struck.
    for mode in Visualiser.Mode.allCases {
        let visualiser = Visualiser(mode: mode)
        visualiser.resize(width: 200, height: 120)
        watch(visualiser, seconds: 3, levels: [0, 0, 0, 0], pitches: [0, 0, 0, 0])
        var before = rows(visualiser).reduce(0, +)
        var greatest = 0
        for frame in 0 ..< 120 {
            visualiser.hear(levels: [1, 1, 1, 1], pitches: [50, 60, 70, 80], struck: [Bool](repeating: frame == 0, count: 4))
            visualiser.paint(at: 3 + Double(frame) / 60)
            let after = rows(visualiser).reduce(0, +)
            greatest = max(greatest, abs(after - before))
            before = after
        }
        // From one frame to the next, the light in the whole picture changes by less than a fiftieth
        // of all the light a picture can hold.
        #expect(greatest < 200 * 120 * 765 / 50)
    }
}

@Test func lavaChangesColourByItselfTooSlowlyToSee() {
    let visualiser = Visualiser(mode: .lava)
    visualiser.resize(width: 160, height: 92)
    /// The colour of the wax: the mean red, green and blue of the bright dots.
    func wax() -> (red: Int, green: Int, blue: Int) {
        let picture = copy(visualiser)
        var red = 0, green = 0, blue = 0, count = 0
        for at in stride(from: 0, to: picture.count, by: 4) where max(picture[at], picture[at + 1], picture[at + 2]) > 150 {
            red += Int(picture[at])
            green += Int(picture[at + 1])
            blue += Int(picture[at + 2])
            count += 1
        }
        return count > 0 ? (red / count, green / count, blue / count) : (0, 0, 0)
    }
    watch(visualiser, seconds: 5, levels: [0.8, 0.8], pitches: [55, 70])
    // It starts out red and orange.
    let first = wax()
    #expect(first.red > 180 && first.red > first.green + 60 && first.green > first.blue)
    // A second on, it is as good as the same colour.
    watch(visualiser, from: 5, seconds: 1, levels: [0.8, 0.8], pitches: [55, 70])
    let next = wax()
    #expect(abs(next.red - first.red) < 8 && abs(next.green - first.green) < 8 && abs(next.blue - first.blue) < 8)
    // A minute and a half on it is three tenths of the way round the wheel, where red has turned green.
    watch(visualiser, from: 6, seconds: 90, levels: [0.8, 0.8], pitches: [55, 70])
    let later = wax()
    #expect(later.green > 180 && later.green > later.red + 60)
}

@Test func coloursAskedForComeSlowly() {
    let visualiser = Visualiser(mode: .lava)
    visualiser.resize(width: 160, height: 92)
    watch(visualiser, seconds: 5, levels: [0.8, 0.8], pitches: [55, 70])
    func difference(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } }
    let settled = copy(visualiser)
    visualiser.shuffle()
    visualiser.paint(at: 5)
    // The frame after asking is all but the same picture.
    #expect(difference(settled, copy(visualiser)) < 160 * 92 * 3 * 4)
    watch(visualiser, from: 5, seconds: 8, levels: [0.8, 0.8], pitches: [55, 70])
    #expect(difference(settled, copy(visualiser)) > 160 * 92 * 3 * 4)
}

@Test func auroraFadesToItsEdges() {
    // Light at the very top of the sky and along the very bottom, and then a long silence: the
    // picture comes back to the sky it would have been had nothing sounded, in every row.
    func sky(sounding: Bool) -> [Int] {
        let visualiser = Visualiser(mode: .aurora)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.1, levels: [sounding ? 1 : 0, 0], pitches: [40, 0])
        watch(visualiser, from: 0.1, seconds: 5, levels: sounding ? [1, 1] : [0, 0], pitches: [90, 0])
        if sounding {
            let lit = rows(visualiser)
            #expect(lit[0] > 160 * 30 && lit[99] > 160 * 30)
        }
        watch(visualiser, from: 5.1, seconds: 80, levels: [0, 0], pitches: [0, 0])
        return rows(visualiser)
    }
    let after = sky(sounding: true), never = sky(sounding: false)
    for row in 0 ..< 100 { #expect(abs(after[row] - never[row]) <= 160 * 3, "row \(row)") }
}

@Test func mirrorBallLightsAHigherRowForAHigherNote() {
    /// The row the coloured light is balanced about: the dots that are plainly one colour and not
    /// the white the ball always throws.
    func height(of pitch: Float) -> Double {
        let visualiser = Visualiser(mode: .ball)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.1, levels: [1], pitches: [40])
        watch(visualiser, from: 0.1, seconds: 0.1, levels: [1], pitches: [90])
        watch(visualiser, from: 0.2, seconds: 4, levels: [1], pitches: [pitch])
        guard let pixels = visualiser.pixels else { return -1 }
        var total = 0.0, weighted = 0.0
        for row in 0 ..< 100 {
            // (Not the ball itself, which shows every colour it throws.)
            for column in 0 ..< 160 where row >= 32 || column < 64 || column >= 96 {
                let at = (row * 160 + column) * 4
                let colours = [Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2])]
                let strength = Double((colours.max() ?? 0) - (colours.min() ?? 0))
                guard strength > 40 else { continue }
                total += strength
                weighted += strength * Double(row)
            }
        }
        return total > 0 ? weighted / total : -1
    }
    let low = height(of: 40), high = height(of: 90)
    #expect(low > 0 && high > 0)
    #expect(high < low - 20)
}

@Test func mirrorBallGivesEachVoiceAColourOfItsOwn() {
    // Two voices that are next to one another among sixteen, one high and one low: their rows of
    // light are plainly different colours, and not two shades of one.
    let visualiser = Visualiser(mode: .ball)
    visualiser.resize(width: 160, height: 100)
    var levels = [Float](repeating: 0, count: 16), pitches = levels
    levels[4] = 1
    levels[5] = 1
    pitches[4] = 84
    pitches[5] = 48
    watch(visualiser, seconds: 4, levels: levels, pitches: pitches)
    guard let pixels = visualiser.pixels else { return }
    /// The colour of the coloured light in some rows, as parts of its red, green and blue that add up to 1.
    func colour(rows: Range<Int>) -> [Double] {
        var sums = [0.0, 0.0, 0.0]
        for row in rows {
            for column in 0 ..< 160 where row >= 32 || column < 64 || column >= 96 {
                let at = (row * 160 + column) * 4
                let parts = [Double(pixels[at]), Double(pixels[at + 1]), Double(pixels[at + 2])]
                guard (parts.max() ?? 0) - (parts.min() ?? 0) > 40 else { continue }
                for part in 0 ..< 3 { sums[part] += parts[part] }
            }
        }
        let total = sums.reduce(0, +)
        return total > 0 ? sums.map { $0 / total } : [0, 0, 0]
    }
    let high = colour(rows: 0 ..< 40), low = colour(rows: 60 ..< 100)
    #expect(high.reduce(0, +) > 0.99 && low.reduce(0, +) > 0.99)
    #expect(zip(high, low).reduce(0) { $0 + abs($1.0 - $1.1) } > 0.4)
}
