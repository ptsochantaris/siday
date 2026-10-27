// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The wording of `TuneInfo.shortfalls`: what a file asks for that is not played as it asks.
///
/// Each loader says what it leaves out, in its own words; what is here is what they share, so that
/// a count reads the same from all of them ("Three of its instruments…") and a file that is cut
/// short is said to be so in one way.
package enum Shortfall {
    private static let units = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                                "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    /// A count in words, as far as words go on being easier to read than figures.
    package static func number(_ count: Int) -> String {
        if count >= 0, count < 20 { return units[count] }
        guard count >= 20, count < 100 else { return "\(count)" }
        return count % 10 == 0 ? tens[count / 10] : tens[count / 10] + "-" + units[count % 10]
    }

    /// The start of a sentence about some of what a file has: "One of its " or "Three of its ",
    /// and then whichever of the two endings goes with the count.
    package static func some(_ count: Int, one: String, many: String) -> String {
        capitalNumber(count) + " of its " + (count == 1 ? one : many)
    }

    /// A count in words with a capital, to begin a sentence with.
    package static func capitalNumber(_ count: Int) -> String {
        let words = number(count)
        guard let first = words.utf8.first, first >= 0x61, first <= 0x7A else { return words }
        return String(decoding: [first - 0x20] + Array(words.utf8.dropFirst()), as: UTF8.self)
    }

    /// Things named one after another, as they are written in a sentence.
    package static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// The sentence for commands that are in a file's patterns and are not played, each named by
    /// what it does; nil if there are none.
    /// - Parameter why: what is to be said of them all, after a comma: "which MultiTracker did not have".
    package static func commandsLeftOut(_ names: [String], why: String = "") -> String? {
        guard !names.isEmpty else { return nil }
        let reason = why.isEmpty ? "" : ", " + why
        return some(names.count, one: "commands is left out\(reason): ", many: "commands are left out\(reason): ") + list(names) + "."
    }

    /// Which of a few kinds of thing have been come upon in a file: commands that are not played,
    /// say, each kind to be named once however often it is there.
    package struct Kinds {
        package init() {}

        private var seen: UInt32 = 0

        package mutating func note(_ kind: Int) {
            seen |= 1 << UInt32(kind & 31)
        }

        var isEmpty: Bool { seen == 0 }

        /// The names of the kinds that were come upon, from the names of them all in order.
        package func named(_ names: [String]) -> [String] {
            names.indices.filter { seen & (1 << UInt32($0 & 31)) != 0 }.map { names[$0] }
        }
    }

    /// What to say of the plug-ins of a file from ModPlug Tracker or OpenMPT that are not played:
    /// all of them, where the replayer has not been taught any; where it has, see `plugInsLeftOut`.
    /// - Parameters:
    ///   - unheard: how many instruments that the tune plays are a plug-in and nothing else.
    ///   - bare: how many have a sample, and a plug-in that it is sent through.
    ///   - channels: how many channels are sent through one.
    package static func plugIns(unheard: Int, bare: Int, channels: Int) -> [String] {
        var sentences: [String] = []
        if unheard > 0 {
            sentences.append(some(unheard, one: "instruments plays through a plug-in, and is not heard.", many: "instruments play through plug-ins, and are not heard."))
        }
        if bare > 0 {
            sentences.append(some(bare, one: "instruments is sent through a plug-in, and is heard without it.", many: "instruments are sent through plug-ins, and are heard without them."))
        }
        if channels > 0 {
            sentences.append(some(channels, one: "channels is sent through a plug-in, and is heard without it.", many: "channels are sent through plug-ins, and are heard without them."))
        }
        return sentences
    }

    /// What to say of the plug-ins of a file that are not OpenMPT's own, and so are not played:
    /// how many of how many, and which programs they are, each named once. Nil if there are none.
    /// - Parameters:
    ///   - names: the name of each plug-in that is left out, which may be empty.
    ///   - all: how many plug-ins the file has, those that are played among them.
    package static func plugInsLeftOut(_ names: [String], of all: Int) -> String? {
        guard !names.isEmpty else { return nil }
        var programs: [String] = []
        for name in names where !name.isEmpty && !programs.contains(name) { programs.append(name) }
        if programs.count > 4 { programs = Array(programs.prefix(3)) + ["\(number(programs.count - 3)) more"] }
        let named = programs.isEmpty ? "" : " (" + list(programs) + ")"
        let rest = names.count == 1 ? " is left out, and it is heard without what that does to its sound."
            : " are left out, and it is heard without what they do to its sound."
        if names.count >= all {
            return (names.count == 1 ? "Its plug-in" : "Its \(number(names.count)) plug-ins") + named + rest
        }
        return capitalNumber(names.count) + " of its \(number(all)) plug-ins" + named + rest
    }

    /// The samples of a file that ends before they do.
    ///
    /// A great many files are a few bytes short, the last sample's last bytes having been lost
    /// somewhere along the way, and nobody can hear it. So a sample counts only if it has lost a
    /// sixteenth of itself or more, or two thousand bytes, and at least thirty-two.
    package struct CutShort {
        package init() {}

        /// Samples that have nothing left of them at all, and those that have lost their ends.
        private(set) var missing = 0, shortened = 0

        /// Takes note of a sample.
        /// - Parameters:
        ///   - length: how long the file says it is.
        ///   - there: how much of that the file has; nought or less if it ends before the sample begins.
        package mutating func add(length: Int, there: Int) {
            let lost = length - max(0, min(length, there))
            guard lost >= 32, lost >= 2048 || lost * 16 >= length else { return }
            if there <= 0 { missing += 1 } else { shortened += 1 }
        }

        /// What to say of them; nil if the file has all that matters of its samples.
        package var sentence: String? {
            let silent = Shortfall.some(missing, one: "samples is missing", many: "samples are missing")
            switch (missing, shortened) {
            case (0, 0): return nil
            case (0, 1): return "The file is cut short: its last sample ends in silence."
            case (0, _): return "The file is cut short: \(Shortfall.number(shortened)) of its samples end in silence."
            case (_, 0): return "The file is cut short: " + Shortfall.lowercased(silent) + ", and \(missing == 1 ? "is" : "are") silent."
            case (_, 1): return "The file is cut short: " + Shortfall.lowercased(silent) + ", and another ends in silence."
            default: return "The file is cut short: " + Shortfall.lowercased(silent) + ", and \(Shortfall.number(shortened)) more end in silence."
            }
        }
    }

    /// A sentence about what a file has lost, with what it is the consequence of put before it.
    package static func cutShort(_ lost: String) -> String {
        "The file is cut short: " + lowercased(lost)
    }

    /// What to say of the instruments of a file that are lost, which are silent: those the file
    /// ends before, or those from one on whose header cannot be right, after which nothing in the
    /// file can be taken at its word. Nil if the song plays none of them.
    /// - Parameters:
    ///   - count: how many of the instruments the song plays are lost.
    ///   - damaged: true if they are lost to a header that cannot be right, not to the file's end.
    ///   - samplesToo: true if `CutShort` has already said that the file is cut short.
    package static func instrumentsLost(_ count: Int, damaged: Bool, samplesToo: Bool) -> String? {
        guard count > 0 else { return nil }
        let which = (count == 1 ? "one of the instruments it plays is " : "\(number(count)) of the instruments it plays are ")
        let silent = count == 1 ? ", and is silent." : ", and are silent."
        if damaged { return "The file is damaged part of the way through: " + which + "lost" + silent }
        if samplesToo { return capitalNumber(count) + (count == 1 ? " of the instruments it plays is missing too" : " of the instruments it plays are missing too") + silent }
        return cutShort(which + "missing" + silent)
    }

    /// A sentence's beginning made fit for its middle: its first letter small.
    private static func lowercased(_ text: String) -> String {
        guard let first = text.utf8.first, first >= 0x41, first <= 0x5A else { return text }
        return String(decoding: [first + 0x20] + Array(text.utf8.dropFirst()), as: UTF8.self)
    }
}
