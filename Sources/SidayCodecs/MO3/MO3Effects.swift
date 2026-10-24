// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from libopenmpt (`soundlib/Load_s3m.cpp`, `MODTools.cpp`, `ModCommand.cpp`), Copyright (c)
// 2004-2026 OpenMPT Project Developers and Contributors, used under the BSD 3-Clause licence (see
// THIRD-PARTY.md).

/// OpenMPT's commands put back into the letters and numbers of the formats, as its savers put them.
extension MO3Song {
    typealias C = MO3Command

    /// `ModCommand::ExtendedMODtoS3MEffect`: an Exy of MOD and XM as the Sxy (or other command) of S3M
    /// and IT that does the same.
    static func extendedMODtoS3M(_ command: inout UInt8, _ param: inout UInt8) {
        guard command == C.modCmdEx else { return }
        command = C.s3mCmdEx
        switch param & 0xF0 {
        case 0x00: command = C.none
        case 0x10: command = C.portamentoUp; param |= 0xF0
        case 0x20: command = C.portamentoDown; param |= 0xF0
        case 0x30: param = (param & 0x0F) | 0x10
        case 0x40: param = (param & 0x03) | 0x30
        case 0x50: param = (param ^ 0x58) | 0x20
        case 0x60: param = (param & 0x0F) | 0xB0
        case 0x70: param = (param & 0x03) | 0x40
        case 0x90: command = C.retrig; param = param & 0x0F
        case 0xA0:
            if param & 0x0F != 0 { command = C.volumeSlide; param = (param << 4) | 0x0F } else { command = C.none }
        case 0xB0:
            if param & 0x0F != 0 { command = C.volumeSlide; param = 0xF0 | min(param & 0x0F, 0x0E) } else { command = C.none }
        case 0xC0: if param == 0xC0 { command = C.none }
        case 0xD0: if param == 0xD0 { command = C.none }
        default: break
        }
    }

    /// `ModCommand::ExtendedS3MtoMODEffect`.
    static func extendedS3MtoMOD(_ command: inout UInt8, _ param: inout UInt8) {
        guard command == C.s3mCmdEx else { return }
        command = C.modCmdEx
        switch param & 0xF0 {
        case 0x10: param = (param & 0x0F) | 0x30
        case 0x20: param = (param ^ 0x28) | 0x50
        case 0x30: param = (param & 0x0F) | 0x40
        case 0x40: param = (param & 0x0F) | 0x70
        case 0x50, 0x60, 0x90, 0xA0: command = C.xFinePortaUpDown
        case 0x80: command = C.panning8; param = (param & 0x0F) &* 0x11
        case 0xB0: param = (param & 0x0F) | 0x60
        case 0x70: command = C.none
        default: break
        }
    }

    /// `CSoundFile::S3MSaveConvert`: a command as an S3M or IT letter (with 0x40 taken off) and value.
    /// `extended` is for an IT saved with OpenMPT's own commands (not a compatibility export).
    func s3mSaveConvert(_ sourceCommand: UInt8, _ sourceParam: UInt8, toIT: Bool, extended: Bool) -> (UInt8, UInt8) {
        var command: UInt8 = 0
        var param = sourceParam
        let extendedIT = extended && toIT
        let isModOrXM = kind == .mod || kind == .xm
        switch sourceCommand {
        case C.dummy: command = param != 0 ? 0x40 : 0
        case C.speed: command = 0x41
        case C.positionJump: command = 0x42
        case C.patternBreak:
            command = 0x43
            if !toIT { param = ((param / 10) << 4) &+ (param % 10) }
        case C.volumeSlide: command = 0x44
        case C.portamentoDown:
            command = 0x45
            if param >= 0xE0, isModOrXM { param = 0xDF }
        case C.portamentoUp:
            command = 0x46
            if param >= 0xE0, isModOrXM { param = 0xDF }
        case C.tonePortamento: command = 0x47
        case C.vibrato: command = 0x48
        case C.tremor: command = 0x49
        case C.arpeggio: command = 0x4A
        case C.vibratoVol: command = 0x4B
        case C.tonePortaVol: command = 0x4C
        case C.channelVolume: command = 0x4D
        case C.channelVolSlide: command = 0x4E
        case C.offset: command = 0x4F
        case C.panningSlide: command = 0x50
        case C.retrig: command = 0x51
        case C.tremolo: command = 0x52
        case C.s3mCmdEx: command = 0x53
        case C.tempo: command = 0x54
        case C.fineVibrato: command = 0x55
        case C.globalVolume: command = 0x56
        case C.globalVolSlide: command = 0x57
        case C.panning8:
            command = 0x58
            let isITLike = kind == .it || kind == .xm || kind == .mod
            if toIT, !isITLike {
                if param == 0xA4 {
                    command = 0x53
                    param = 0x91
                } else if param == 0x80 {
                    param = 0xFF
                } else if param < 0x80 {
                    param <<= 1
                } else {
                    command = 0
                }
            } else if !toIT, isITLike {
                param >>= 1
            }
        case C.panbrello: command = 0x59
        case C.midi: command = 0x5A
        case C.smoothMIDI: command = extendedIT ? 0x5C : 0x5A
        case C.xFinePortaUpDown:
            switch param & 0xF0 {
            case 0x10: command = 0x46; param = (param & 0x0F) | 0xE0
            case 0x20: command = 0x45; param = (param & 0x0F) | 0xE0
            case 0x90: command = 0x53
            default: command = 0
            }
        case C.modCmdEx:
            var c = C.modCmdEx, p = param
            Self.extendedMODtoS3M(&c, &p)
            return s3mSaveConvert(c, p, toIT: toIT, extended: extended)
        case C.delayCut: command = extendedIT ? 0x5D : 0
        case C.xParam: command = extendedIT ? 0x5B : 0
        case C.fineTune: command = extendedIT ? 0x5E : 0
        case C.fineTuneSmooth: command = extendedIT ? 0x5F : 0
        default: command = 0
        }
        if command == 0 { param = 0 }
        return (command & ~0x40, param)
    }

    /// `CSoundFile::ModSaveCommand`: a command as a MOD or XM effect number and value.
    func modSaveCommand(_ sourceCommand: UInt8, _ sourceParam: UInt8, toXM: Bool) -> (UInt8, UInt8) {
        var command: UInt8 = 0
        var param = sourceParam
        switch sourceCommand {
        case C.none: command = 0; param = 0
        case C.arpeggio: command = 0
        case C.portamentoUp, C.portamentoDown:
            command = sourceCommand == C.portamentoUp ? 0x01 : 0x02
            // UseCombinedPortamentoCommands: of these kinds, only MTM keeps fine slides in E1x/E2x
            // and has them in OpenMPT as extra-high portamento values.
            if kind != .mod, kind != .xm, param >= 0xE0 {
                let direction: UInt8 = sourceCommand == C.portamentoUp ? 0x10 : 0x20
                command = 0x0E
                param = param < 0xF0 ? ((param & 0x0F) >> 2) | direction : (param & 0x0F) | direction
            }
        case C.tonePortamento: command = 0x03
        case C.vibrato: command = 0x04
        case C.tonePortaVol: command = 0x05
        case C.vibratoVol: command = 0x06
        case C.tremolo: command = 0x07
        case C.panning8:
            command = 0x08
            if kind == .s3m {
                if param <= 0x80 {
                    param = UInt8(min(Int(param) * 2, 255))
                } else if param == 0xA4 {
                    if !toXM {
                        command = 0
                        param = 0
                    } else {
                        command = 0x58 - 55
                        param = 91
                    }
                }
            }
        case C.offset: command = 0x09
        case C.volumeSlide: command = 0x0A
        case C.positionJump: command = 0x0B
        case C.volume: command = 0x0C
        case C.patternBreak:
            command = 0x0D
            param = ((param / 10) << 4) | (param % 10)
        case C.modCmdEx: command = 0x0E
        case C.speed:
            command = 0x0F
            param = min(param, 0x1F)
        case C.tempo:
            command = 0x0F
            param = max(param, 0x20)
        case C.globalVolume: command = 0x47 - 55
        case C.globalVolSlide: command = 0x48 - 55
        case C.keyOff: command = 0x4B - 55
        case C.setEnvPosition: command = 0x4C - 55
        case C.panningSlide: command = 0x50 - 55
        case C.retrig: command = 0x52 - 55
        case C.tremor: command = 0x54 - 55
        case C.dummy: command = 0x57 - 55
        case C.xFinePortaUpDown: command = 0x58 - 55
        case C.panbrello: command = 0x59 - 55
        case C.midi: command = 0x5A - 55
        case C.smoothMIDI: command = 0x5C - 56
        case C.xParam: command = 0x23 + 3
        case C.s3mCmdEx:
            var c = C.s3mCmdEx, p = param
            Self.extendedS3MtoMOD(&c, &p)
            return modSaveCommand(c, p, toXM: toXM)
        default: command = 0; param = 0
        }
        // No XM effects in a MOD.
        if command > 0x0F, !toXM {
            command = 0
            param = 0
        }
        return (command, param)
    }
}
