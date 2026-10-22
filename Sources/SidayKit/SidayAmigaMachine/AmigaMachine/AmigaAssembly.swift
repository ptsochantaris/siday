// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// 68000 code that the host writes into the machine for itself, hand-assembled a word at a time (each
/// with the instruction it is beside it), with labels for its branches and its addresses.
struct AmigaAssembly {
    private(set) var words: [UInt16] = []
    private var labels: [Int] = []
    private var shortBranches: [(at: Int, label: Int)] = []
    private var wordDisplacements: [(at: Int, label: Int)] = []
    private var longAddresses: [(at: Int, label: Int)] = []
    /// Where the code goes.
    let origin: UInt32

    init(at origin: UInt32) { self.origin = origin }

    /// The address the next word goes to.
    var here: UInt32 { origin + UInt32(words.count * 2) }

    /// A label, to be placed later with `place`.
    mutating func label() -> Int {
        labels.append(-1)
        return labels.count - 1
    }

    /// Places the label here.
    mutating func place(_ label: Int) { labels[label] = words.count * 2 }

    /// A label placed here.
    mutating func placed() -> Int {
        let l = label()
        place(l)
        return l
    }

    mutating func w(_ values: UInt16...) { words += values }

    /// A long, as two words.
    mutating func long(_ value: UInt32) { words += [UInt16(value >> 16), UInt16(value & 0xFFFF)] }

    /// A Bcc.S: the opcode's upper byte (as $6700 for BEQ.S), to `label`.
    mutating func branch(_ opcode: UInt16, to label: Int) {
        shortBranches.append((words.count, label))
        words.append(opcode & 0xFF00)
    }

    /// A word of displacement to `label` from this word's place (for a Bcc.W, a DBcc or a d16(PC)).
    mutating func displacement(to label: Int) {
        wordDisplacements.append((words.count, label))
        words.append(0)
    }

    /// The label's address, as a long.
    mutating func address(of label: Int) {
        longAddresses.append((words.count, label))
        words += [0, 0]
    }

    /// The address of a label once it is placed.
    func addressOf(_ label: Int) -> UInt32 { origin + UInt32(labels[label]) }

    /// The bytes of the code, every label filled in.
    func assembled() -> [UInt8] {
        var words = self.words
        for (at, label) in shortBranches {
            let d = labels[label] - (at * 2 + 2)
            words[at] |= UInt16(UInt8(truncatingIfNeeded: d))
        }
        for (at, label) in wordDisplacements {
            words[at] = UInt16(truncatingIfNeeded: labels[label] - at * 2)
        }
        for (at, label) in longAddresses {
            let address = origin + UInt32(labels[label])
            words[at] = UInt16(address >> 16)
            words[at + 1] = UInt16(address & 0xFFFF)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(words.count * 2)
        for word in words {
            bytes.append(UInt8(word >> 8))
            bytes.append(UInt8(word & 0xFF))
        }
        return bytes
    }
}
