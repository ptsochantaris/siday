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

/// The coloured light on a mirror ball's wall, leaving out the ball itself and the white it always
/// throws: the row it is balanced about, and its colour as parts of red, green and blue that add up to 1.
private func wallLight(_ visualiser: Visualiser, rows: Range<Int> = 0 ..< 100) -> (row: Double, colour: [Double]) {
    guard let pixels = visualiser.pixels else { return (-1, [0, 0, 0]) }
    var total = 0.0, weighted = 0.0
    var sums = [0.0, 0.0, 0.0]
    for row in rows {
        for column in 0 ..< visualiser.width where row >= 32 || column < 64 || column >= 96 {
            let at = (row * visualiser.width + column) * 4
            let parts = [Double(pixels[at]), Double(pixels[at + 1]), Double(pixels[at + 2])]
            let strength = (parts.max() ?? 0) - (parts.min() ?? 0)
            guard strength > 40 else { continue }
            total += strength
            weighted += strength * Double(row)
            for part in 0 ..< 3 { sums[part] += parts[part] }
        }
    }
    let all = sums.reduce(0, +)
    return (total > 0 ? weighted / total : -1, all > 0 ? sums.map { $0 / all } : [0, 0, 0])
}

@Test func mirrorBallGivesEachVoiceAHeightOfItsOwn() {
    // Three voices, of which one plays: the first is at the top of the wall and the last at the
    // bottom, whatever note it is.
    func row(of voice: Int, pitch: Float) -> Double {
        let visualiser = Visualiser(mode: .ball)
        visualiser.resize(width: 160, height: 100)
        var levels: [Float] = [0, 0, 0], pitches = levels
        levels[voice] = 1
        pitches[voice] = pitch
        watch(visualiser, seconds: 4, levels: levels, pitches: pitches)
        return wallLight(visualiser).row
    }
    let top = row(of: 0, pitch: 40), middle = row(of: 1, pitch: 40), bottom = row(of: 2, pitch: 40)
    #expect(top > 0 && top < middle - 10 && middle < bottom - 10)
    #expect(abs(row(of: 0, pitch: 90) - top) < 4)
}

@Test func mirrorBallColoursALightByItsNote() {
    /// The colours of the top of the wall and the bottom, with a voice at each playing a note.
    func colours(_ upper: Float, _ lower: Float) -> (top: [Double], bottom: [Double]) {
        let visualiser = Visualiser(mode: .ball)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 4, levels: [1, 1], pitches: [upper, lower])
        return (wallLight(visualiser, rows: 0 ..< 30).colour, wallLight(visualiser, rows: 70 ..< 100).colour)
    }
    func difference(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } }
    // The same note is the same colour, in different voices at different heights.
    let same = colours(60, 60)
    #expect(same.top.reduce(0, +) > 0.99 && same.bottom.reduce(0, +) > 0.99)
    #expect(difference(same.top, same.bottom) < 0.1)
    // A note is coloured by how high it is, and an octave is a long way.
    let octave = colours(72, 60)
    #expect(difference(octave.top, octave.bottom) > 0.5)
    // And the note is what matters, not the voice: the same two notes the other way up.
    let swapped = colours(60, 72)
    #expect(difference(swapped.top, octave.bottom) < 0.1)
    // The lowest notes a tune plays are all one colour, so that those between are further apart.
    let lowest = colours(48, 50)
    #expect(difference(lowest.top, lowest.bottom) < 0.05)
    let between = colours(63, 66)
    #expect(difference(between.top, between.bottom) > 0.2)
}

@Test func pondTakesItsDropsWhereTheNotesAre() {
    /// The column the colour in the water is balanced about, after some notes struck at one pitch.
    func place(of pitch: Float) -> Double {
        let visualiser = Visualiser(mode: .pond)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.1, levels: [1], pitches: [40])
        watch(visualiser, from: 0.1, seconds: 0.1, levels: [1], pitches: [90])
        for note in 0 ..< 6 { watch(visualiser, from: 0.2 + Double(note) * 0.5, seconds: 0.5, levels: [1], pitches: [pitch], strike: true) }
        guard let pixels = visualiser.pixels else { return -1 }
        var total = 0.0, weighted = 0.0
        for row in 0 ..< 100 {
            for column in 0 ..< 160 {
                let at = (row * 160 + column) * 4
                let strength = Double(max(pixels[at], pixels[at + 1], pixels[at + 2]))
                guard strength > 110 else { continue }
                total += strength
                weighted += strength * Double(column)
            }
        }
        return total > 0 ? weighted / total : -1
    }
    // Low notes fall to the left and high ones to the right.
    let low = place(of: 40), high = place(of: 90)
    #expect(low > 0 && low < 60)
    #expect(high > 100)
}

@Test func pondComesToRest() {
    // Rings spread, cross and come back off the banks, and then the water is still again: as still
    // as if nothing had fallen in it.
    func water(disturbed: Bool) -> [UInt8] {
        let visualiser = Visualiser(mode: .pond)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.2, levels: [0, 0], pitches: [40, 90])
        if disturbed {
            for note in 0 ..< 8 { watch(visualiser, from: 0.2 + Double(note) * 0.25, seconds: 0.25, levels: [1, 1], pitches: [50, 0], strike: true) }
        } else {
            watch(visualiser, from: 0.2, seconds: 2, levels: [0, 0], pitches: [0, 0])
        }
        if disturbed {
            // (It is disturbed, at this point.)
            let picture = copy(visualiser)
            #expect(picture.contains { $0 > 120 && $0 < 255 })
        }
        watch(visualiser, from: 2.2, seconds: 60, levels: [0, 0], pitches: [0, 0])
        return copy(visualiser)
    }
    let after = water(disturbed: true), never = water(disturbed: false)
    #expect(zip(after, never).allSatisfy { abs(Int($0) - Int($1)) <= 3 })
}

/// How tall the fire is: how many rows of the picture, from the bottom, have something burning in
/// them (a dot plainly brighter than the hearth).
private enum FlameEnd { case top, bottom }

/// With `from: .bottom`, it is the lowest row with something burning in it instead, counted from the top.
private func flameHeight(_ visualiser: Visualiser, from end: FlameEnd = .top) -> Int {
    guard let pixels = visualiser.pixels else { return 0 }
    var tallest = 0, lowest = 0
    for row in 0 ..< visualiser.height {
        let burning = (0 ..< visualiser.width).contains { column in
            let at = (row * visualiser.width + column) * 4
            return max(pixels[at], pixels[at + 1], pixels[at + 2]) > 110
        }
        if burning {
            tallest = max(tallest, visualiser.height - row)
            lowest = row + 1
        }
    }
    return end == .top ? tallest : lowest
}

/// How wide the lamp is that stands in the middle of a picture of one voice, in dots, and the
/// colour of the middle of it. (The lamps stand four fifths of the way down.)
private func lamp(_ visualiser: Visualiser) -> (width: Int, red: Int, green: Int, blue: Int) {
    guard let pixels = visualiser.pixels else { return (0, 0, 0, 0) }
    let row = visualiser.height * 4 / 5
    let width = (0 ..< visualiser.width).count { column in
        let at = (row * visualiser.width + column) * 4
        return max(pixels[at], pixels[at + 1], pixels[at + 2]) > 150
    }
    let middle = (row * visualiser.width + visualiser.width / 2) * 4
    return (width, Int(pixels[middle]), Int(pixels[middle + 1]), Int(pixels[middle + 2]))
}

@Test func flameBurnsTallerForALouderVoice() {
    func height(level: Float) -> Int {
        let visualiser = Visualiser(mode: .flame)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 6, levels: [level], pitches: [60])
        return flameHeight(visualiser)
    }
    let quiet = height(level: 0.35), loud = height(level: 1)
    #expect(quiet > 20)
    #expect(loud > quiet + 12)
}

@Test func flameLampIsAsLargeAsItsVoiceIsLoud() {
    func width(level: Float) -> Int {
        let visualiser = Visualiser(mode: .flame)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 3, levels: [level], pitches: [60])
        return lamp(visualiser).width
    }
    let silent = width(level: 0), quiet = width(level: 0.35), middling = width(level: 0.7), loud = width(level: 1)
    #expect(silent == 0)
    #expect(quiet > 4 && quiet < middling - 5 && middling < loud - 5)
}

@Test func flameLampsStandLowerTheSmallerTheyAre() {
    /// How many rows at the foot of the picture have nothing lit in them, with so many voices at their loudest.
    func floor(voices: Int) -> Int {
        let visualiser = Visualiser(mode: .flame)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 3, levels: [Float](repeating: 1, count: voices), pitches: [Float](repeating: 60, count: voices))
        return visualiser.height - flameHeight(visualiser, from: .bottom)
    }
    // Many voices make small lamps, which are not left standing as high as a few large ones are.
    let few = floor(voices: 3), many = floor(voices: 16)
    #expect(few >= 5 && few <= 12)
    #expect(many >= 1 && many < few - 3)
}

@Test func flameStandsWhereItsVoiceIs() {
    /// The column the fire's light is balanced about, with one voice of three burning.
    func place(of voice: Int) -> Double {
        let visualiser = Visualiser(mode: .flame)
        visualiser.resize(width: 160, height: 100)
        var levels: [Float] = [0, 0, 0]
        levels[voice] = 1
        watch(visualiser, seconds: 5, levels: levels, pitches: [60, 60, 60])
        guard let pixels = visualiser.pixels else { return -1 }
        var total = 0.0, weighted = 0.0
        for row in 0 ..< 100 {
            for column in 0 ..< 160 where max(pixels[(row * 160 + column) * 4], pixels[(row * 160 + column) * 4 + 1]) > 110 {
                total += 1
                weighted += Double(column)
            }
        }
        return total > 0 ? weighted / total : -1
    }
    let first = place(of: 0), second = place(of: 1), third = place(of: 2)
    #expect(abs(first - 160 / 6) < 3 && abs(second - 80) < 3 && abs(third - 160 * 5 / 6) < 3)
}

@Test func flameGoesOutWithItsVoices() {
    let visualiser = Visualiser(mode: .flame)
    visualiser.resize(width: 160, height: 100)
    watch(visualiser, seconds: 5, levels: [1, 1], pitches: [50, 70])
    #expect(flameHeight(visualiser) > 40)
    // The voices fall silent: the lamps go, and what was burning rises away.
    watch(visualiser, from: 5, seconds: 8, levels: [0, 0], pitches: [0, 0])
    #expect(flameHeight(visualiser) == 0)
}

@Test func flameLampIsTheColourOfItsNote() {
    /// The colour of the lamp of a voice playing a note, in a tune that goes from 40 to 90.
    func colour(of pitch: Float) -> (width: Int, red: Int, green: Int, blue: Int) {
        let visualiser = Visualiser(mode: .flame)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.1, levels: [1], pitches: [40])
        watch(visualiser, from: 0.1, seconds: 0.1, levels: [1], pitches: [90])
        watch(visualiser, from: 0.2, seconds: 0.1, levels: [1], pitches: [pitch])
        return lamp(visualiser)
    }
    // As the analyser's bars are: red at the bottom, green in the middle, violet at the top. And
    // the lamp is the note's colour as soon as the note is heard.
    let low = colour(of: 40), middle = colour(of: 65), high = colour(of: 90)
    #expect(low.red > 200 && low.red > low.green + 80 && low.red > low.blue + 120)
    #expect(middle.green > 200 && middle.green > middle.red + 120 && middle.green > middle.blue + 80)
    #expect(high.blue > 200 && high.blue > high.red + 20 && high.blue > high.green + 120)
}

@Test func flameColoursAreFurtherApartInTheMiddleOfTheTune() {
    /// How unlike the lamps of two notes are, in a tune that goes from 40 to 90: how far apart
    /// they are in red, green and blue together.
    func unlikeness(_ one: Float, _ other: Float) -> Int {
        let first = colour(of: one), second = colour(of: other)
        return abs(first.red - second.red) + abs(first.green - second.green) + abs(first.blue - second.blue)
    }
    func colour(of pitch: Float) -> (width: Int, red: Int, green: Int, blue: Int) {
        let visualiser = Visualiser(mode: .flame)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.1, levels: [1], pitches: [40])
        watch(visualiser, from: 0.1, seconds: 0.1, levels: [1], pitches: [90])
        watch(visualiser, from: 0.2, seconds: 0.1, levels: [1], pitches: [pitch])
        return lamp(visualiser)
    }
    // The lowest few notes are all the one red, and a few notes apart in the middle are not at
    // all the same colour.
    #expect(unlikeness(40, 43) < 6)
    #expect(unlikeness(60, 63) > 40)
}

@Test func flameReachesTheTopOfThePicture() {
    let visualiser = Visualiser(mode: .flame)
    visualiser.resize(width: 160, height: 100)
    watch(visualiser, seconds: 8, levels: [1], pitches: [60])
    #expect(flameHeight(visualiser) > 95)
}

@Test func flameLampIsPaleForAVoiceWithNoPitch() {
    let visualiser = Visualiser(mode: .flame)
    visualiser.resize(width: 160, height: 100)
    watch(visualiser, seconds: 1, levels: [1], pitches: [0])
    let drum = lamp(visualiser)
    #expect(drum.width > 8)
    #expect(drum.red > 120 && abs(drum.red - drum.green) < 30 && abs(drum.red - drum.blue) < 30)
    // A note that is dying away is still its own colour, though no pitch is heard with it.
    watch(visualiser, from: 1, seconds: 1, levels: [1], pitches: [50])
    let note = lamp(visualiser)
    visualiser.hear(levels: [0.8], pitches: [0], struck: [false])
    visualiser.paint(at: 2.01)
    let dying = lamp(visualiser)
    #expect(abs(dying.red - note.red) < 12 && abs(dying.green - note.green) < 12 && abs(dying.blue - note.blue) < 12)
}

@Test func flameAnswersToItsVoiceWithoutWaiting() {
    // A lamp is as large as its voice is loud, and gets there in a fraction of a second, both ways:
    // it is not something that is merely on while there is sound.
    let visualiser = Visualiser(mode: .flame)
    visualiser.resize(width: 160, height: 100)
    watch(visualiser, seconds: 4, levels: [0.5], pitches: [60])
    let steady = lamp(visualiser).width
    // The voice comes in at its loudest, with a note struck.
    watch(visualiser, from: 4, seconds: 0.1, levels: [1], pitches: [60], strike: true)
    #expect(lamp(visualiser).width > steady + 6)
    // And drops back to less than it was.
    watch(visualiser, from: 4.1, seconds: 0.5, levels: [0.25], pitches: [60])
    let fallen = lamp(visualiser).width
    #expect(fallen > 2 && fallen < steady - 4)
}
