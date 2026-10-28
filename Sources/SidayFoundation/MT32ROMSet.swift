// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// (The names of the control ROMs are Munt's, from ROMInfo.cpp of libmt32emu 2.8.3.)

/// A control ROM: the program of the synthesiser's controller, which makes it the model it is.
public enum MT32ControlROM: String, Sendable, CaseIterable {
    case mt32_1_04 = "ctrl_mt32_1_04", mt32_1_05 = "ctrl_mt32_1_05", mt32_1_06 = "ctrl_mt32_1_06", mt32_1_07 = "ctrl_mt32_1_07"
    case mt32BlueRidge = "ctrl_mt32_bluer"
    case mt32_2_03 = "ctrl_mt32_2_03", mt32_2_04 = "ctrl_mt32_2_04", mt32_2_06 = "ctrl_mt32_2_06", mt32_2_07 = "ctrl_mt32_2_07"
    case cm32l_1_00 = "ctrl_cm32l_1_00", cm32l_1_02 = "ctrl_cm32l_1_02", cm32ln_1_00 = "ctrl_cm32ln_1_00"

    /// What Munt calls it.
    public var name: String {
        switch self {
        case .mt32_1_04: "MT-32 Control v1.04"
        case .mt32_1_05: "MT-32 Control v1.05"
        case .mt32_1_06: "MT-32 Control v1.06"
        case .mt32_1_07: "MT-32 Control v1.07"
        case .mt32BlueRidge: "MT-32 Control BlueRidge"
        case .mt32_2_03: "MT-32 Control v2.03"
        case .mt32_2_04: "MT-32 Control v2.04"
        case .mt32_2_06: "MT-32 Control v2.06"
        case .mt32_2_07: "MT-32 Control v2.07"
        case .cm32l_1_00: "CM-32L/LAPC-I Control v1.00"
        case .cm32l_1_02: "CM-32L/LAPC-I Control v1.02"
        case .cm32ln_1_00: "CM-32LN/CM-500/LAPC-N Control v1.00"
        }
    }

    /// True for the CM-32L's kind (the LAPC-I's, the CM-64's), which takes the larger PCM ROM.
    public var isCM32LKind: Bool { self == .cm32l_1_00 || self == .cm32l_1_02 || self == .cm32ln_1_00 }
}

/// A control ROM and a PCM ROM that go together, whole, ready for a synthesiser.
public struct MT32ROMSet: Sendable {
    public let control: MT32ControlROM
    public let controlData: [UInt8]
    public let pcmData: [UInt8]

    public init(control: MT32ControlROM, controlData: [UInt8], pcmData: [UInt8]) {
        self.control = control
        self.controlData = controlData
        self.pcmData = pcmData
    }
}
