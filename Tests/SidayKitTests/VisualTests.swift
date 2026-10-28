// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayPlayer
@testable import SidayFoundation
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

@Test func auroraChangesColourByItselfTooSlowlyToSee() {
    let visualiser = Visualiser(mode: .aurora)
    visualiser.resize(width: 160, height: 92)
    /// The colour of the band: the mean red, green and blue of the bright dots.
    func band() -> (red: Int, green: Int, blue: Int) {
        let picture = copy(visualiser)
        var red = 0, green = 0, blue = 0, count = 0
        for at in stride(from: 0, to: picture.count, by: 4) where max(picture[at], picture[at + 1], picture[at + 2]) > 110 {
            red += Int(picture[at])
            green += Int(picture[at + 1])
            blue += Int(picture[at + 2])
            count += 1
        }
        return count > 0 ? (red / count, green / count, blue / count) : (0, 0, 0)
    }
    // Long enough for the band to have crossed the sky.
    watch(visualiser, seconds: 16, levels: [0.8], pitches: [60])
    // It starts out green, and is by now a little on the way to blue: green and blue, and little red.
    let first = band()
    #expect(first.green > 100 && first.blue > 100 && min(first.green, first.blue) > first.red + 50)
    // A second on, it is as good as the same colour.
    watch(visualiser, from: 16, seconds: 1, levels: [0.8], pitches: [60])
    let next = band()
    #expect(abs(next.red - first.red) < 8 && abs(next.green - first.green) < 8 && abs(next.blue - first.blue) < 8)
    // A minute and a half on it is three tenths of the way further round the wheel, where there
    // is red and blue, and little green.
    watch(visualiser, from: 17, seconds: 90, levels: [0.8], pitches: [60])
    let later = band()
    #expect(later.red > 100 && later.blue > 100 && min(later.red, later.blue) > later.green + 50)
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

/// What there is of a fountain's lights in the picture: how many dots are lit, the highest row any
/// of them is in, and the colour of the brightest, which is a light itself and not its tail.
private func fountain(_ visualiser: Visualiser) -> (dots: Int, top: Int, red: Int, green: Int, blue: Int) {
    guard let pixels = visualiser.pixels else { return (0, 0, 0, 0, 0) }
    var dots = 0, top = visualiser.height, brightest = 0, colour = (0, 0, 0)
    for row in 0 ..< visualiser.height {
        for column in 0 ..< visualiser.width {
            let at = (row * visualiser.width + column) * 4
            let most = max(Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
            guard most > 70 else { continue }
            dots += 1
            top = min(top, row)
            if most > brightest {
                brightest = most
                colour = (Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]))
            }
        }
    }
    return (dots, top, colour.0, colour.1, colour.2)
}

/// Strikes a note on a fountain's one voice and watches it for some seconds, at thirty frames a
/// second: the highest row its light reaches, and the most dots it ever lights.
private func flight(_ visualiser: Visualiser, from start: Double = 0, seconds: Double = 4, level: Float, then later: Float? = nil, pitch: Float = 60) -> (top: Int, dots: Int) {
    var top = visualiser.height, dots = 0
    for frame in 0 ..< Int(seconds * 30) {
        visualiser.hear(levels: [frame == 0 ? level : later ?? level], pitches: [pitch], struck: [frame == 0])
        visualiser.paint(at: start + Double(frame) / 30)
        let seen = fountain(visualiser)
        top = min(top, seen.top)
        dots = max(dots, seen.dots)
    }
    return (top, dots)
}

@Test func fountainSendsALightUpForANoteStruck() {
    let visualiser = Visualiser(mode: .fountain)
    visualiser.resize(width: 160, height: 100)
    // Nothing while nothing sounds, and nothing for a voice that only holds what it has.
    watch(visualiser, seconds: 1, levels: [0], pitches: [0])
    #expect(fountain(visualiser).dots == 0)
    watch(visualiser, from: 1, seconds: 1, levels: [1], pitches: [60])
    #expect(fountain(visualiser).dots == 0)
    // A note struck is a light, a small one, on its way up from the bottom of the picture.
    watch(visualiser, from: 2, seconds: 0.2, levels: [1], pitches: [60], strike: true)
    let leaving = fountain(visualiser)
    #expect(leaving.dots > 4 && leaving.top > 50)
    watch(visualiser, from: 2.2, seconds: 0.6, levels: [1], pitches: [60])
    let risen = fountain(visualiser)
    #expect(risen.dots > 4 && risen.dots < 300 && risen.top < leaving.top - 20)
    // It turns over and falls away, and bursts into nothing: there is never much of it.
    let rest = flight(visualiser, from: 2.8, level: 1)
    #expect(rest.dots < 300)
    #expect(fountain(visualiser).dots == 0)
}

@Test func fountainSendsALouderNoteHigher() {
    func top(level: Float, then later: Float? = nil) -> Int {
        let visualiser = Visualiser(mode: .fountain)
        visualiser.resize(width: 160, height: 100)
        return flight(visualiser, level: level, then: later).top
    }
    let loud = top(level: 1), less = top(level: 0.8), quiet = top(level: 0.3)
    #expect(loud < 15)
    // Most notes are nearly as loud as notes get, and so it is those that are furthest apart:
    // one a fifth less loud goes little more than half as high.
    #expect(less > 40 && less < 65)
    #expect(quiet > 80 && quiet < 95)
    // A note that is louder a moment after it is struck than at the moment itself goes as high as
    // it has turned out to be loud.
    #expect(top(level: 0.2, then: 1) < 20)
}

@Test func fountainLightIsTheColourOfItsNote() {
    /// The colour of the light of a note, in a tune that goes from 40 to 90.
    func colour(of pitch: Float) -> (dots: Int, top: Int, red: Int, green: Int, blue: Int) {
        let visualiser = Visualiser(mode: .fountain)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.1, levels: [1], pitches: [40])
        watch(visualiser, from: 0.1, seconds: 0.1, levels: [1], pitches: [90])
        watch(visualiser, from: 0.2, seconds: 0.5, levels: [1], pitches: [pitch], strike: true)
        return fountain(visualiser)
    }
    // As the flame's lamps are: red at the bottom, green in the middle, violet at the top, and pale
    // for what has no pitch.
    let low = colour(of: 40), middle = colour(of: 65), high = colour(of: 90), drum = colour(of: 0)
    #expect(low.red > 200 && low.red > low.green + 80 && low.red > low.blue + 120)
    #expect(middle.green > 200 && middle.green > middle.red + 120 && middle.green > middle.blue + 80)
    #expect(high.blue > 200 && high.blue > high.red + 20 && high.blue > high.green + 120)
    #expect(drum.red > 120 && abs(drum.red - drum.green) < 30 && abs(drum.red - drum.blue) < 30)
}

@Test func fountainSendsUpNoMoreThanEightLightsASecond() {
    /// How many lights are on their way up a second after a voice begins striking a note every so many frames.
    func lights(every frames: Int) -> Int {
        let visualiser = Visualiser(mode: .fountain)
        visualiser.resize(width: 160, height: 200)
        for frame in 0 ..< 60 {
            visualiser.hear(levels: [1], pitches: [60], struck: [frame % frames == 0])
            visualiser.paint(at: Double(frame) / 60)
        }
        // A light itself is as bright as anything gets, which its tail is not; and lights sent up
        // at different times are at different heights, with rows between them that have none.
        guard let pixels = visualiser.pixels else { return 0 }
        var lights = 0, dark = 2
        for row in 0 ..< 200 {
            let bright = (0 ..< 160).contains { column in
                let at = (row * 160 + column) * 4
                return max(pixels[at], pixels[at + 1], pixels[at + 2]) > 240
            }
            if bright, dark >= 2 { lights += 1 }
            dark = bright ? 0 : dark + 1
        }
        return lights
    }
    // Four notes a second are four lights. Thirty a second are eight, and not one or thirty.
    #expect(lights(every: 15) == 4)
    let many = lights(every: 2)
    #expect(many >= 7 && many <= 9)
}

@Test func fountainSendsItsLightsUpFromTheMiddle() {
    // A note struck four times a second, for long enough that lights are coming down as well.
    let visualiser = Visualiser(mode: .fountain)
    visualiser.resize(width: 200, height: 100)
    var leaving = 100 ..< 100, landing = 100 ..< 100
    for frame in 0 ..< 600 {
        visualiser.hear(levels: [1], pitches: [60], struck: [frame % 15 == 0])
        visualiser.paint(at: Double(frame) / 60)
        guard let pixels = visualiser.pixels else { continue }
        // Along the bottom of the picture, a light that is as bright as lights are is on its way
        // up, and one that is less so, but more than a tail's edge is, is on its way down.
        for row in 92 ..< 100 {
            for column in 0 ..< 200 {
                let at = (row * 200 + column) * 4
                let most = max(pixels[at], pixels[at + 1], pixels[at + 2])
                if most > 240 { leaving = min(leaving.lowerBound, column) ..< max(leaving.upperBound, column + 1) }
                if most > 90, most < 130 { landing = min(landing.lowerBound, column) ..< max(landing.upperBound, column + 1) }
            }
        }
    }
    // They leave by a spout in the middle, and come down all along the picture.
    #expect(leaving.count > 4 && leaving.lowerBound > 85 && leaving.upperBound < 115)
    #expect(landing.lowerBound < 50 && landing.upperBound > 150)
}

/// What there is of the rain's drops in the picture: how many dots are lit, the rows and columns
/// they lie within, and the column they are balanced about.
private func rain(_ visualiser: Visualiser) -> (dots: Int, top: Int, bottom: Int, left: Int, right: Int, middle: Double) {
    guard let pixels = visualiser.pixels else { return (0, 0, 0, 0, 0, 0) }
    var dots = 0, top = visualiser.height, bottom = -1, left = visualiser.width, right = -1, columns = 0
    for row in 0 ..< visualiser.height {
        for column in 0 ..< visualiser.width {
            let at = (row * visualiser.width + column) * 4
            guard max(pixels[at], pixels[at + 1], pixels[at + 2]) > 70 else { continue }
            dots += 1
            top = min(top, row)
            bottom = max(bottom, row)
            left = min(left, column)
            right = max(right, column)
            columns += column
        }
    }
    return (dots, top, bottom, left, right, dots > 0 ? Double(columns) / Double(dots) : 0)
}

/// Strikes a note on the rain's one voice and watches its drop for some seconds, at thirty frames
/// a second: what is seen of it in each frame.
private func drop(_ visualiser: Visualiser, from start: Double = 0, seconds: Double, level: Float, then later: Float? = nil,
                  pitch: Float = 60, side: Float = 0, sideThen: Float? = nil) -> [(dots: Int, top: Int, bottom: Int, left: Int, right: Int, middle: Double)] {
    (0 ..< Int(seconds * 30)).map { frame in
        visualiser.hear(levels: [frame == 0 ? level : later ?? level], pitches: [pitch], struck: [frame == 0], sides: [frame == 0 ? side : sideThen ?? side])
        visualiser.paint(at: start + Double(frame) / 30)
        return rain(visualiser)
    }
}

/// The places where a row of numbers turns: each least and each most of them in turn, taking no
/// notice of a turn of less than three.
private func turns(_ numbers: [Double]) -> (least: [Double], most: [Double]) {
    guard var extreme = numbers.first else { return ([], []) }
    var least: [Double] = [], most: [Double] = []
    var falling: Bool?
    for number in numbers {
        switch falling {
        case nil:
            if number <= extreme - 3 { falling = true } else if number >= extreme + 3 { falling = false } else { continue }
            extreme = number
        case true?:
            if number < extreme {
                extreme = number
            } else if number >= extreme + 3 {
                least.append(extreme)
                falling = false
                extreme = number
            }
        case false?:
            if number > extreme {
                extreme = number
            } else if number <= extreme - 3 {
                most.append(extreme)
                falling = true
                extreme = number
            }
        }
    }
    return (least, most)
}

@Test func rainFallsFromTheTopForANoteStruck() {
    let visualiser = Visualiser(mode: .rain)
    visualiser.resize(width: 160, height: 100)
    // Nothing while nothing sounds, and nothing for a voice that only holds what it has.
    watch(visualiser, seconds: 1, levels: [0], pitches: [0])
    #expect(rain(visualiser).dots == 0)
    watch(visualiser, from: 1, seconds: 1, levels: [1], pitches: [60])
    #expect(rain(visualiser).dots == 0)
    // A note struck is a drop at the top of the picture, a thin one, and it falls straight down:
    // it is at the bottom in two thirds of a second.
    let fall = drop(visualiser, from: 2, seconds: 0.6, level: 1)
    let begun = fall[5], later = fall[14]
    #expect(begun.dots > 6 && begun.top < 20 && begun.bottom < 40)
    #expect(later.dots > 6 && later.top > 40 && later.bottom < 99)
    for seen in fall.dropFirst() { #expect(seen.right - seen.left < 5 && abs(seen.middle - begun.middle) < 1) }
    #expect(drop(visualiser, from: 2.6, seconds: 0.1, level: 1).last?.bottom == 99)
}

@Test func rainDropIsAsBrightAtItsTailAsAtItsHead() {
    // A drop is its way of the last moment, all of one brightness: of the rows it is in as it
    // falls, all but those at its two round ends are as bright as anything in it.
    let visualiser = Visualiser(mode: .rain)
    visualiser.resize(width: 160, height: 100)
    _ = drop(visualiser, seconds: 0.4, level: 1)
    guard let pixels = visualiser.pixels else { return }
    var lit = 0, bright = 0
    for row in 0 ..< 100 {
        let most = (0 ..< 160).map { column in max(pixels[(row * 160 + column) * 4], pixels[(row * 160 + column) * 4 + 1], pixels[(row * 160 + column) * 4 + 2]) }.max() ?? 0
        if most > 70 { lit += 1 }
        if most > 235 { bright += 1 }
    }
    #expect(lit >= 10 && lit < 30 && bright >= lit - 3)
}

@Test func rainBouncesAsHighAsItsNoteIsLoud() {
    /// The highest row a drop reaches once it has met the bottom.
    func top(level: Float, then later: Float? = nil) -> Int {
        let visualiser = Visualiser(mode: .rain)
        visualiser.resize(width: 160, height: 100)
        return drop(visualiser, seconds: 4, level: level, then: later).dropFirst(23).map(\.top).min() ?? 0
    }
    let loud = top(level: 1), less = top(level: 0.8), quiet = top(level: 0.3)
    #expect(loud < 15)
    // As in the fountain, it is the loudest notes that are furthest apart.
    #expect(less > 40 && less < 65)
    #expect(quiet > 80 && quiet < 95)
    // A note that is louder a moment after it is struck than at the moment itself bounces as high
    // as it has turned out to be loud.
    #expect(top(level: 0.2, then: 1) < 15)
}

@Test func rainBouncesLessHighEachTimeAndFallsAway() {
    let visualiser = Visualiser(mode: .rain)
    visualiser.resize(width: 160, height: 100)
    let seen = drop(visualiser, seconds: 9, level: 1)
    // The tops of its bounces, one after another, as far as they are well clear of the bottom:
    // each is lower in the picture than the last, by nearly half. (A drop at the bottom of the
    // picture has its top edge in row 97.)
    let tops = turns(seen.dropFirst(23).prefix { $0.dots > 0 }.map { Double($0.top) }).least
    #expect(tops.count >= 5)
    for (higher, lower) in zip(tops.prefix(4), tops.dropFirst()) {
        #expect((97 - lower) < (97 - higher) * 0.65 && (97 - lower) > (97 - higher) * 0.45)
    }
    // It is there for some six seconds, and then it is gone, out of the bottom of the picture.
    #expect(seen[180].dots > 0)
    #expect(seen[240].dots == 0 && seen[269].dots == 0)
}

@Test func rainGoesFasterSidewaysTheHigherItsNote() {
    /// How far a drop goes from side to side in the first second after it has met the bottom, in a
    /// tune that goes from 40 to 90.
    func travel(of pitch: Float) -> Double {
        let visualiser = Visualiser(mode: .rain)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.1, levels: [1], pitches: [40])
        watch(visualiser, from: 0.1, seconds: 0.1, levels: [1], pitches: [90])
        let seen = drop(visualiser, from: 0.2, seconds: 2, level: 1, pitch: pitch).map(\.middle)
        return zip(seen[24 ..< 54], seen[25 ..< 55]).reduce(0) { $0 + abs($1.1 - $1.0) }
    }
    // A tenth of the picture's height a second for the lowest note, all of it for the highest.
    let low = travel(of: 40), middle = travel(of: 65), high = travel(of: 90)
    #expect(low > 5 && low < 15)
    #expect(middle > 40 && middle < 65)
    #expect(high > 80 && high < 110)
}

@Test func rainBouncesToEitherSide() {
    // Sixteen notes, each after the last one's drop has gone: some go off to the left and some to the right.
    let visualiser = Visualiser(mode: .rain)
    visualiser.resize(width: 160, height: 100)
    var left = 0, right = 0
    for note in 0 ..< 16 {
        let seen = drop(visualiser, from: Double(note) * 3, seconds: 3, level: 0.6)
        #expect(seen[89].dots == 0)
        if seen[27].middle < seen[22].middle - 1 { left += 1 }
        if seen[27].middle > seen[22].middle + 1 { right += 1 }
    }
    #expect(left + right == 16 && left >= 4 && right >= 4)
}

@Test func rainBouncesToTheSideItsNoteIsHeardFrom() {
    /// How many of sixteen notes' drops go off to the left, and how many to the right.
    func ways(side: Float, then later: Float? = nil) -> (left: Int, right: Int) {
        let visualiser = Visualiser(mode: .rain)
        visualiser.resize(width: 160, height: 100)
        var left = 0, right = 0
        for note in 0 ..< 16 {
            let seen = drop(visualiser, from: Double(note) * 3, seconds: 3, level: 0.6, side: side, sideThen: later)
            if seen[27].middle < seen[22].middle - 1 { left += 1 }
            if seen[27].middle > seen[22].middle + 1 { right += 1 }
        }
        return (left, right)
    }
    // All one way for a note on one side, however little; as chance has it for one in the middle.
    #expect(ways(side: -1) == (16, 0))
    #expect(ways(side: 1) == (0, 16))
    #expect(ways(side: -0.2) == (16, 0))
    #expect(ways(side: 0.2) == (0, 16))
    let middle = ways(side: 0.02)
    #expect(middle.left >= 4 && middle.right >= 4)
    // A note is not always where it will be at the moment it is struck: it is where it has turned
    // out to be that counts.
    #expect(ways(side: -1, then: 1) == (0, 16))
}

@Test func rainDropIsDimmerAfterEachBounce() {
    // The brightest there is of a drop: as bright as can be until it has bounced twice, and then
    // less so with each bounce, though never all at once, and never dark.
    let visualiser = Visualiser(mode: .rain)
    visualiser.resize(width: 160, height: 100)
    var brightest: [Int] = []
    for frame in 0 ..< 200 {
        visualiser.hear(levels: [1], pitches: [60], struck: [frame == 0])
        visualiser.paint(at: Double(frame) / 30)
        let seen = fountain(visualiser)
        brightest.append(max(seen.red, seen.green, seen.blue))
    }
    // It meets the bottom at two thirds of a second, and again two seconds after that.
    #expect(brightest[10] > 240 && brightest[70] > 240)
    #expect(brightest[110] < 215 && brightest[110] > 180)
    #expect(brightest[190] < 130 && brightest[190] > 60)
    for (before, after) in zip(brightest.dropFirst(20), brightest.dropFirst(21)) { #expect(after <= before + 6 && after >= before - 14) }
}

@Test func rainTurnsBackAtTheSides() {
    // The highest note there is, in a picture no wider than it is tall, which it would cross in a
    // second: it is never lost at a side, and goes back and forth for as long as it bounces.
    let visualiser = Visualiser(mode: .rain)
    visualiser.resize(width: 100, height: 100)
    let seen = drop(visualiser, seconds: 6, level: 1, pitch: 82)
    for one in seen.dropFirst() { #expect(one.dots > 6 && one.left >= 0 && one.right <= 99) }
    let sides = turns(seen.dropFirst(23).map(\.middle))
    #expect(sides.least.count >= 2 && sides.most.count >= 2)
    for side in sides.least { #expect(side < 12) }
    for side in sides.most { #expect(side > 88) }
}

@Test func rainDropIsTheColourOfItsNote() {
    /// The colour of the drop of a note, in a tune that goes from 40 to 90.
    func colour(of pitch: Float) -> (dots: Int, top: Int, red: Int, green: Int, blue: Int) {
        let visualiser = Visualiser(mode: .rain)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.1, levels: [1], pitches: [40])
        watch(visualiser, from: 0.1, seconds: 0.1, levels: [1], pitches: [90])
        watch(visualiser, from: 0.2, seconds: 0.4, levels: [1], pitches: [pitch], strike: true)
        return fountain(visualiser)
    }
    // As the fountain's lights are: red at the bottom, green in the middle, violet at the top, and
    // pale for what has no pitch.
    let low = colour(of: 40), middle = colour(of: 65), high = colour(of: 90), drum = colour(of: 0)
    #expect(low.red > 200 && low.red > low.green + 80 && low.red > low.blue + 120)
    #expect(middle.green > 200 && middle.green > middle.red + 120 && middle.green > middle.blue + 80)
    #expect(high.blue > 200 && high.blue > high.red + 20 && high.blue > high.green + 120)
    #expect(drum.red > 120 && abs(drum.red - drum.green) < 30 && abs(drum.red - drum.blue) < 30)
}

@Test func rainLetsNoMoreThanEightDropsFallASecond() {
    /// How many drops are falling half a second after a voice begins striking a note every so many
    /// frames: how many separate things are lit, each of them all in one piece.
    func drops(every frames: Int) -> Int {
        let visualiser = Visualiser(mode: .rain)
        visualiser.resize(width: 160, height: 200)
        for frame in 0 ..< 30 {
            visualiser.hear(levels: [1], pitches: [60], struck: [frame % frames == 0])
            visualiser.paint(at: Double(frame) / 60)
        }
        guard let pixels = visualiser.pixels else { return 0 }
        var lit = (0 ..< 160 * 200).map { max(pixels[$0 * 4], pixels[$0 * 4 + 1], pixels[$0 * 4 + 2]) > 70 }
        var pieces = 0
        for start in lit.indices where lit[start] {
            pieces += 1
            var waiting = [start]
            lit[start] = false
            while let at = waiting.popLast() {
                let row = at / 160, column = at % 160
                for nextRow in max(0, row - 1) ... min(199, row + 1) {
                    for nextColumn in max(0, column - 1) ... min(159, column + 1) where lit[nextRow * 160 + nextColumn] {
                        lit[nextRow * 160 + nextColumn] = false
                        waiting.append(nextRow * 160 + nextColumn)
                    }
                }
            }
        }
        return pieces
    }
    // Four notes a second are two drops in half a second. Thirty a second are four, and not one or fifteen.
    #expect(drops(every: 15) == 2)
    #expect(drops(every: 2) == 4)
}

/// The column the light of a picture is balanced about, counting only what is plainly lit.
private func balancedColumn(_ visualiser: Visualiser, brighter than: UInt8 = 60) -> Double {
    guard let pixels = visualiser.pixels else { return -1 }
    var total = 0.0, weighted = 0.0
    for row in 0 ..< visualiser.height {
        for column in 0 ..< visualiser.width {
            let at = (row * visualiser.width + column) * 4
            let strength = Double(max(pixels[at], pixels[at + 1], pixels[at + 2]))
            guard strength > Double(than) else { continue }
            total += strength
            weighted += strength * Double(column)
        }
    }
    return total > 0 ? weighted / total : -1
}

@Test func petriDishWavesBeginWhereTheNotesAre() {
    func place(of pitch: Float) -> Double {
        let visualiser = Visualiser(mode: .petri)
        visualiser.resize(width: 160, height: 100)
        watch(visualiser, seconds: 0.1, levels: [1], pitches: [40])
        watch(visualiser, from: 0.1, seconds: 0.1, levels: [1], pitches: [90])
        // One note, once the voice has come to its pitch, and a moment for its wave to set out.
        watch(visualiser, from: 0.2, seconds: 0.5, levels: [1], pitches: [pitch])
        watch(visualiser, from: 0.7, seconds: 0.4, levels: [1], pitches: [pitch], strike: true)
        return balancedColumn(visualiser)
    }
    // Low notes set off their waves to the left and high ones to the right.
    let low = place(of: 40), high = place(of: 90)
    #expect(low > 0 && low < 50)
    #expect(high > 110)
}

@Test func petriDishSpreadsInWaves() {
    let visualiser = Visualiser(mode: .petri)
    visualiser.resize(width: 160, height: 100)
    watch(visualiser, seconds: 0.2, levels: [1], pitches: [40])
    watch(visualiser, from: 0.2, seconds: 0.1, levels: [1], pitches: [90])
    watch(visualiser, from: 0.3, seconds: 0.5, levels: [1], pitches: [65])
    /// How far from where the note was struck what is lit lies, on the whole, and how much is lit.
    func reach(_ visualiser: Visualiser) -> (distance: Double, lit: Int) {
        guard let pixels = visualiser.pixels else { return (0, 0) }
        var total = 0.0, lit = 0
        for row in 0 ..< 100 {
            for column in 0 ..< 160 {
                let at = (row * 160 + column) * 4
                guard max(pixels[at], pixels[at + 1], pixels[at + 2]) > 90 else { continue }
                let dx = Double(column) - 80, dy = Double(row) - 15
                total += (dx * dx + dy * dy).squareRoot()
                lit += 1
            }
        }
        return (lit > 0 ? total / Double(lit) : 0, lit)
    }
    // One note in the middle: its wave goes out as a ring, further out and wider round as time goes on.
    watch(visualiser, from: 0.8, seconds: 0.1, levels: [1], pitches: [65], strike: true)
    let first = reach(visualiser)
    watch(visualiser, from: 0.9, seconds: 0.2, levels: [1], pitches: [65])
    let second = reach(visualiser)
    watch(visualiser, from: 1.1, seconds: 0.2, levels: [1], pitches: [65])
    let third = reach(visualiser)
    #expect(first.lit > 0)
    #expect(second.distance > first.distance + 1 && third.distance > second.distance + 1)
    #expect(third.lit > first.lit * 2)
}

@Test func petriDishFadesWhenTheMusicStops() {
    let visualiser = Visualiser(mode: .petri)
    visualiser.resize(width: 160, height: 100)
    // Some seconds of notes from four voices; then the music goes on, but strikes nothing more.
    for note in 0 ..< 16 {
        watch(visualiser, from: Double(note) * 0.5, seconds: 0.5, levels: [1, 0.9, 0.8, 1], pitches: [45, 57, 69, 81].map { $0 + Float(note % 5) }, strike: true)
    }
    // (The light there is above that of the dark ground, which is the picture before anything is sown.)
    let empty = Visualiser(mode: .petri)
    empty.resize(width: 160, height: 100)
    empty.paint(at: 0)
    let ground = rows(empty).reduce(0, +)
    let sounding = rows(visualiser).reduce(0, +) - ground
    watch(visualiser, from: 8, seconds: 1, levels: [1, 0.9, 0.8, 1], pitches: [45, 57, 69, 81])
    let soon = rows(visualiser).reduce(0, +) - ground
    watch(visualiser, from: 9, seconds: 30, levels: [0, 0, 0, 0], pitches: [0, 0, 0, 0])
    let later = rows(visualiser).reduce(0, +) - ground
    // It lives while it is sown, and is still there a moment after; but it drains away, slowly, to
    // nearly nothing.
    #expect(sounding > 160 * 100 * 765 / 50)
    #expect(soon > sounding / 3)
    #expect(later < sounding / 20)
}

@Test func petriDishWaveTakesTheColourOfItsVoice() {
    let visualiser = Visualiser(mode: .petri)
    visualiser.resize(width: 200, height: 100)
    // Two voices, far apart, one low and one high: each one's wave is the colour of its voice, and
    // the two are not alike.
    watch(visualiser, seconds: 0.2, levels: [1, 1], pitches: [40, 90])
    watch(visualiser, from: 0.2, seconds: 0.5, levels: [1, 1], pitches: [40, 90], strike: true)
    guard let pixels = visualiser.pixels else { Issue.record("no picture"); return }
    func colour(columns: Range<Int>) -> [Double] {
        var sums = [0.0, 0.0, 0.0], count = 0.0
        for row in 0 ..< 100 {
            for column in columns {
                let at = (row * 200 + column) * 4
                guard max(pixels[at], pixels[at + 1], pixels[at + 2]) > 80 else { continue }
                for channel in 0 ..< 3 { sums[channel] += Double(pixels[at + channel]) }
                count += 1
            }
        }
        return sums.map { $0 / max(1, count) }
    }
    let left = colour(columns: 0 ..< 70), right = colour(columns: 130 ..< 200)
    #expect(left.reduce(0, +) > 100 && right.reduce(0, +) > 100)
    #expect(zip(left, right).reduce(0) { $0 + abs($1.0 - $1.1) } > 120)
}
