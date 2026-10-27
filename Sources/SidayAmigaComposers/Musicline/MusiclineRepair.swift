// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// The mending of a Musicline Editor module that has lost the byte after each CR (13) in it, where that
/// byte was a nought: as a file sent over a terminal's line loses them, whose CR and nought stand for a
/// CR alone. UnExoticA's Xenex-Remix.ml has: it has no CR followed by a nought in its 43,919 bytes, though
/// it has 395 CRs, and four of its chunks are each as many bytes short of their lengths as they lost; the
/// player stops reading it at the first (a part's), and so plays nothing of it.
///
/// A chunk that does not end where its length says, but a few bytes before (no more than it has CRs),
/// where the next begins, is mended: where it is as many bytes short as it has CRs, by a nought put back
/// after each; and a sample's packed sound, where it is not, by the fewest noughts its packing cannot be
/// read without (each after a CR that began a run, or was one of a run's lengths or deltas): the others
/// cannot be placed (a nought lost after a CR that was a byte of the sound itself fits anywhere such a
/// CR is), and each is a nought at the end of the sound instead. A chunk that cannot be mended so is left
/// as it is (and the player stops at it).
enum MusiclineRepair {
    /// The module mended, and what was done, if it has lost bytes so; nil if it has not.
    static func repaired(_ data: [UInt8]) -> (bytes: [UInt8], notes: [String])? {
        // (A CR and two noughts lose one of them, and leave a CR and a nought.)
        guard data.contains(13) else { return nil }
        func long(_ at: Int) -> Int {
            guard at >= 0, at + 4 <= data.count else { return 0 }
            return Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3])
        }
        func id(_ at: Int) -> String? {
            guard at >= 0, at + 4 <= data.count else { return nil }
            return String(decoding: data[at ..< at + 4], as: UTF8.self)
        }
        let known: Set<String> = ["TUNE", "PART", "ARPG", "INST", "SMPL", "INFO"]
        func isChunk(_ at: Int) -> Bool { at == data.count || id(at).map(known.contains) == true }

        var at = 8
        if id(at) != "VERS" { at = 12 + long(8) }
        guard id(at) == "VERS" else { return nil }
        at += 8 + long(at + 4)
        var out = Array(data[0 ..< min(at, data.count)])
        var restored = 0, unplaced = 0
        var unplacedSamples: [Int] = []
        var failed = false
        var sampleNumber = 0
        while at + 8 <= data.count, let name = id(at), known.contains(name) {
            let length = long(at + 4)
            if name == "SMPL" { sampleNumber += 1 }
            var end: Int
            switch name {
            case "TUNE":
                let count = Int(data[min(at + 8 + 39, data.count - 1)])
                end = at + 8 + 40 + 4 * count
                for c in 0 ..< count { end += long(at + 8 + 40 + 4 * c) }
            case "SMPL":
                end = at + 8 + 6 + length
            default:
                end = at + 8 + length
            }
            if isChunk(end) {
                out += data[at ..< min(end, data.count)]
                at = end
                continue
            }
            // Where the chunk ends: the next chunk's beginning, as few bytes before its length says as
            // there may be, no more than it has CRs.
            let crs = data[(at + 8) ..< min(end, data.count)].count(where: { $0 == 13 })
            guard let next = stride(from: end - 1, through: max(at + 9, end - crs), by: -1).first(where: { $0 <= data.count && isChunk($0) })
            else {
                failed = true
                break
            }
            let lost = end - next
            let body = Array(data[(at + 8) ..< next])
            if body.count(where: { $0 == 13 }) == lost {
                out += data[at ..< at + 8]
                for byte in body {
                    out.append(byte)
                    if byte == 13 { out.append(0) }
                }
                restored += lost
            } else if name == "SMPL", body.count > 56,
                      let mended = mendedSound(Array(body[56...]), lost: lost, command: body[4], size: long(at + 8))
            {
                let stream = mended.stream
                out += data[at ..< at + 4]
                let newLength = 50 + stream.count
                out += [UInt8(newLength >> 24 & 0xFF), UInt8(newLength >> 16 & 0xFF), UInt8(newLength >> 8 & 0xFF), UInt8(newLength & 0xFF)]
                out += body[0 ..< 56]
                out += stream
                restored += mended.placed
                unplaced += lost - mended.placed
                if lost > mended.placed { unplacedSamples.append(sampleNumber) }
            } else {
                failed = true
                break
            }
            at = next
        }
        guard restored + unplaced > 0 else { return nil }
        if at < data.count { out += data[at...] }
        var note = "The file has lost the nought after each CR byte in it, as a file sent over a terminal's line does: "
            + "siday put back the \(restored) whose places are certain"
        if unplaced > 0 {
            let which = unplacedSamples.map { "\($0)" }.joined(separator: ", ")
            note += unplaced == 1 ? ", and the one in the sound of sample \(which) whose place cannot be found is a nought at its end"
                : ", and the \(unplaced) in the sounds of samples \(which) whose places cannot be found are noughts at their ends"
        }
        note += failed ? "; a chunk it could not mend, and what follows it, are not played." : "."
        return (out, [note])
    }

    /// A sample's packed sound with the noughts its packing places put back: after a CR that is a run's
    /// first byte, a byte of its length or of its deltas, the fewest that make the sound unpack to its
    /// length (less a byte for each of the rest) and its bytes end where they do; the rest, whose places
    /// are not known, as noughts at its end. (Found as a walk through the bytes, each way the packing may
    /// be read at each CR kept apart.) nil where no reading fits.
    static func mendedSound(_ stream: [UInt8], lost: Int, command: UInt8, size: Int) -> (stream: [UInt8], placed: Int)? {
        // (How the packing is being read: 0 a byte of the sound or a run's start; 1, 2, 3 a run's first
        // byte and its length's two; 4 a run's deltas, `left` of them.)
        struct Reading: Hashable {
            var phase = 0
            var high = 0
            var left = 0
            var placed = 0
            var made = 0
        }
        func next(_ reading: Reading, _ byte: UInt8) -> (Reading, Int) {
            var r = reading
            switch r.phase {
            case 0:
                if byte == command {
                    r.phase = 1
                    return (r, 0)
                }
                return (r, 1)
            case 1:
                r.phase = 2
                return (r, 1)
            case 2:
                r.high = Int(byte)
                r.phase = 3
                return (r, 0)
            case 3:
                r.left = r.high << 8 | Int(byte)
                r.high = 0
                r.phase = r.left == 0 ? 0 : 4
                return (r, 0)
            default:
                let made = min(2, r.left)
                r.left -= made
                if r.left == 0 { r.phase = 0 }
                return (r, made)
            }
        }
        var readings: [Reading: [Int]] = [Reading(): []]
        for (i, byte) in stream.enumerated() {
            var after: [Reading: [Int]] = [:]
            func keep(_ r: Reading, _ places: [Int]) {
                guard r.made <= size else { return }
                if let kept = after[r], kept.lexicographicallyPrecedes(places) { return }
                after[r] = places
            }
            for (reading, places) in readings {
                var (r1, m1) = next(reading, byte)
                r1.made += m1
                keep(r1, places)
                // (A nought lost after this CR, unless the CR was a byte of the sound itself.)
                let literal = reading.phase == 0 && byte != command
                if byte == 13, !literal, reading.placed < lost {
                    var (r2, m2) = next(r1, 0)
                    r2.made += m2
                    r2.placed += 1
                    keep(r2, places + [i])
                }
            }
            guard !after.isEmpty, after.count <= 4096 else { return nil }
            readings = after
        }
        // (Of the readings that fit, the one that places the fewest, those the packing cannot be read
        // without: a nought lost after a CR of a run's deltas fits as well as one lost after a CR of the
        // sound itself, and which it was is not known; of those, the one whose first places come first.)
        var best: (placed: Int, places: [Int])?
        for (reading, places) in readings where reading.phase == 0 && reading.made + (lost - reading.placed) == size {
            if let found = best, found.placed < reading.placed
                || (found.placed == reading.placed && !places.lexicographicallyPrecedes(found.places))
            {
                continue
            }
            best = (reading.placed, places)
        }
        guard let best else { return nil }
        var mended: [UInt8] = []
        var places = Set(best.places)
        for (i, byte) in stream.enumerated() {
            mended.append(byte)
            if places.remove(i) != nil { mended.append(0) }
        }
        // The noughts that cannot be placed, at the sound's end: as bytes of it, or as a run of them where
        // a nought is the packing's command.
        let unplaced = lost - best.placed
        if unplaced > 0 {
            if command != 0 {
                mended += [UInt8](repeating: 0, count: unplaced)
            } else {
                let deltas = unplaced - 1
                mended += [command, 0, UInt8(deltas >> 8 & 0xFF), UInt8(deltas & 0xFF)] + [UInt8](repeating: 0, count: (deltas + 1) / 2)
            }
        }
        return (mended, best.placed)
    }
}
