// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how its loaders put a tracker's two commands to a note into one cell (`soundlib/modcommand.cpp`).

/// One channel's part of a row as OpenMPT holds it when it reads a module of another tracker's: a
/// note, an instrument, a volume column that can do more than Impulse Tracker's, and a command. A
/// tracker that gives a note two commands has them put into such a cell as OpenMPT puts them, and
/// the cell is then made into Impulse Tracker's (see `cell`), as nearly as Impulse Tracker's cell
/// can hold it.
struct OpenMPTCell {
    /// OpenMPT's commands that the trackers read this way come to, each numbered by how much it
    /// matters when there is room for only one (OpenMPT's `ModCommand::GetEffectWeight`).
    enum Effect: Int, Comparable {
        case none = 0, keyOff = 5, tremolo = 6, fineVibrato = 7, vibrato = 8, finetune = 10, s = 13, midi = 16, panSlide = 18, pan = 19
        case noteSlideUp = 21, noteSlideDown = 23, portaUp = 24, portaDown = 28, volumeSlide = 31, vibratoVolume = 33, volume = 34
        case offset = 39, tremor = 40, retrig = 41, arpeggio = 43, slideToNote = 45, slideToNoteVolume = 46
        case channelVolume = 51, globalVolumeSlide = 52, globalVolume = 53, tempo = 54, speed = 55, jump = 56, breakRow = 57

        static func < (a: Effect, b: Effect) -> Bool { a.rawValue < b.rawValue }

        /// Impulse Tracker's command for it; nought for one it has none for.
        var letter: UInt8 {
            switch self {
            case .none, .keyOff, .finetune, .noteSlideUp, .noteSlideDown, .volume: 0
            case .tremolo: IT2ForeignModule.Command.R
            case .fineVibrato: 21 // U
            case .vibrato: IT2ForeignModule.Command.H
            case .s: IT2ForeignModule.Command.S
            case .midi: 26 // Z
            case .panSlide: 16 // P
            case .pan: IT2ForeignModule.Command.X
            case .portaUp: IT2ForeignModule.Command.F
            case .portaDown: IT2ForeignModule.Command.E
            case .volumeSlide: IT2ForeignModule.Command.D
            case .vibratoVolume: IT2ForeignModule.Command.K
            case .offset: IT2ForeignModule.Command.O
            case .tremor: IT2ForeignModule.Command.I
            case .retrig: IT2ForeignModule.Command.Q
            case .arpeggio: IT2ForeignModule.Command.J
            case .slideToNote: IT2ForeignModule.Command.G
            case .slideToNoteVolume: IT2ForeignModule.Command.L
            case .channelVolume: 13 // M
            case .globalVolumeSlide: 23 // W
            case .globalVolume: IT2ForeignModule.Command.V
            case .tempo: IT2ForeignModule.Command.T
            case .speed: IT2ForeignModule.Command.A
            case .jump: IT2ForeignModule.Command.B
            case .breakRow: IT2ForeignModule.Command.C
            }
        }

        /// True for one that sets something outright, of which a note given two the same keeps one.
        var isOutright: Bool {
            switch self {
            case .arpeggio, .pan, .offset, .jump, .volume, .breakRow, .speed, .tempo, .channelVolume, .globalVolume, .keyOff, .midi, .finetune: true
            default: false
            }
        }
    }

    /// What OpenMPT's volume column can do: more than Impulse Tracker's, which has slides of one to
    /// nine and OpenMPT's of up to fifteen, and pitch slides of up to 55.
    enum Column: Equatable {
        case volume(UInt8), pan(UInt8), slideUp(UInt8), slideDown(UInt8), fineUp(UInt8), fineDown(UInt8)
        case portaUp(UInt8), portaDown(UInt8), slideToNote(UInt8), vibratoDepth(UInt8), offset(UInt8)

        /// Impulse Tracker's volume column for it, if it has room for it.
        var byte: UInt8? {
            func within(_ base: UInt8, _ value: UInt8) -> UInt8? { value <= 9 ? base + value : nil }
            switch self {
            case .volume(let v): return min(v, 64)
            case .pan(let p): return 128 + min(p, 64)
            case .fineUp(let v): return within(65, v)
            case .fineDown(let v): return within(75, v)
            case .slideUp(let v): return within(85, v)
            case .slideDown(let v): return within(95, v)
            case .portaDown(let v): return within(105, v)
            case .portaUp(let v): return within(115, v)
            case .slideToNote(let v): return within(193, v)
            case .vibratoDepth(let v): return within(203, v)
            // (OpenMPT's own, which the replayer has for a module that is played as OpenMPT plays one.)
            case .offset(let v): return within(223, v)
            }
        }

        /// The command that does what it does, for the command's place when the volume column has
        /// no room for it.
        var asCommand: (Effect, UInt8)? {
            switch self {
            case .volume(let v): return (.volume, v)
            case .pan(let p): return (.pan, p >= 64 ? 255 : p * 4)
            case .fineUp(let v): return (.volumeSlide, min(v, 14) << 4 | 0x0F)
            case .fineDown(let v): return (.volumeSlide, 0xF0 | min(v, 14))
            case .slideUp(let v): return (.volumeSlide, min(v, 15) << 4)
            case .slideDown(let v): return (.volumeSlide, min(v, 15))
            case .portaUp(let v): return (.portaUp, min(v, 0x37) * 4)
            case .portaDown(let v): return (.portaDown, min(v, 0x37) * 4)
            case .slideToNote(let v): return (.slideToNote, OpenMPTCell.slideToNoteSpeeds[Int(min(v, 9))])
            case .vibratoDepth(let v): return (.vibrato, min(v, 15))
            case .offset: return nil
            }
        }
    }

    var note: UInt8?
    var instrument: UInt8 = 0
    var column: Column?
    var effect = Effect.none
    var value: UInt8 = 0

    /// What Impulse Tracker's volume column does at each of its speeds of a slide to a note.
    private static let slideToNoteSpeeds: [UInt8] = [0x00, 0x01, 0x04, 0x08, 0x10, 0x20, 0x40, 0x60, 0x80, 0xFF]

    /// A command as the volume column would do it, as OpenMPT makes one so (`ConvertToVolCommand`):
    /// exactly, or with `force`, as nearly as it can. Nil if it cannot.
    static func column(_ effect: Effect, _ value: UInt8, force: Bool) -> Column? {
        switch effect {
        case .volume:
            return .volume(min(value, 64))
        case .portaUp, .portaDown:
            if !force, value & 3 != 0 || value >= 0xE0 { return nil }
            return effect == .portaUp ? .portaUp(value / 4) : .portaDown(value / 4)
        case .slideToNote:
            if value >= 0xF0 { return .slideToNote(9) }
            for n in 0 ..< 10 where force ? value <= slideToNoteSpeeds[n] : value == slideToNoteSpeeds[n] {
                return .slideToNote(UInt8(n))
            }
            return nil
        case .vibrato:
            if force { return .vibratoDepth(min(value & 0x0F, 9)) }
            if value & 0x0F > 9 || value & 0xF0 != 0 { return nil }
            return .vibratoDepth(value & 0x0F)
        case .fineVibrato:
            if !force, value != 0 { return nil }
            return .vibratoDepth(0)
        case .pan:
            return .pan(value == 255 ? 64 : value / 4)
        case .volumeSlide:
            if value == 0 { return nil }
            if value & 0x0F == 0 { return .slideUp(value >> 4) }
            if value & 0xF0 == 0 { return .slideDown(value) }
            if value & 0x0F == 0x0F { return .fineUp(value >> 4) }
            if value & 0xF0 == 0xF0 { return .fineDown(value & 0x0F) }
            return nil
        case .s:
            if value & 0xF0 == 0x80 { return .pan((value & 0x0F) << 2 + 2) }
            return nil
        default:
            return nil
        }
    }

    /// Puts two commands into the cell as OpenMPT does (`FillInTwoCommands`): one into the volume
    /// column if either can go there, exactly, or failing that as nearly as it can; and if neither
    /// can, the one that matters more by OpenMPT's reckoning, and an offset beside it, if the other
    /// is one, as the volume column's coarser one. Of two the same that set something outright,
    /// the second is passed over. Gives back the command that had no room, if one had none (and
    /// the second of two the same, if it would have set something else).
    /// - Parameter coarseOffset: false to have an offset that had no room left out, unless it is
    ///   O00, which needs no more room than the volume column has.
    @discardableResult
    mutating func fill(_ first: (Effect, UInt8), _ second: (Effect, UInt8), coarseOffset: Bool = true) -> (Effect, UInt8)? {
        var (e1, v1) = first, (e2, v2) = second
        var passedOver: (Effect, UInt8)?
        if e1 == e2, e1.isOutright {
            if v1 != v2 { passedOver = second }
            e2 = .none
        }
        for n in 0 ..< 4 {
            let made = Self.column(e1, v1, force: n > 1)
            if e1 == .none || made != nil {
                column = made
                effect = e2
                value = v2
                return passedOver
            }
            swap(&e1, &e2)
            swap(&v1, &v2)
        }
        if e1 > e2 {
            swap(&e1, &e2)
            swap(&v1, &v2)
        }
        if e2 == .offset, coarseOffset || v2 == 0 {
            column = .offset(v2 == 0 ? 0 : UInt8(max(Int(v2) * 9 / 255, 1)))
            effect = e1
            value = v1
            return nil
        }
        column = nil
        effect = e2
        value = v2
        return (e1, v1)
    }

    /// The cell as Impulse Tracker's, with what had to be left out of it. A volume column that
    /// Impulse Tracker's has no room for goes to the command's place, if that is free; and a volume
    /// that OpenMPT has as a command goes to the volume column, and what was there to the command's
    /// place. The rest is left out, and `lost` is the command that was (or what the volume column
    /// would have done, as a command; `none` for what no command does).
    func cell() -> (cell: IT2ForeignModule.Cell, lost: Effect?) {
        var cell = IT2ForeignModule.Cell()
        if let note { cell.set(note: note) }
        if instrument != 0 { cell.set(instrument: instrument) }
        var column = column, effect = effect, value = value, lost: Effect?
        if effect == .volume {
            if let held = column, let instead = held.asCommand, held.byte != nil {
                (effect, value) = instead
            } else if column != nil {
                lost = .volume
                effect = .none
            } else {
                effect = .none
            }
            if lost == nil { column = .volume(min(self.value, 64)) }
        }
        if let held = column {
            if let byte = held.byte {
                cell.set(volume: byte)
            } else if effect == .none, let instead = held.asCommand {
                (effect, value) = instead
            } else {
                lost = held.asCommand?.0 ?? Effect.none
            }
        }
        if effect != .none {
            if effect.letter != 0 {
                cell.set(command: effect.letter, value)
            } else {
                lost = effect
            }
        }
        return (cell, lost)
    }
}
