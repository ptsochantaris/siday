// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from ProWizard for libxmp (src/loaders/prowizard/theplayer.c), Copyright (C) 1997-1999 Sylvain
// "Asle" Chipaux and Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr, used under
// the MIT licence (see THIRD-PARTY.md).

/// (Not yet ported: says no to every file.)
enum ThePlayer {
    static func test50(_ data: [UInt8], _ size: Int) -> Int { -1 }

    static func test60(_ data: [UInt8], _ size: Int) -> Int { -1 }

    static func depack50(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        throw .unsupported("not yet unpacked")
    }

    static func depack60(_ input: inout PackedReader, _ output: inout ModuleWriter) throws(TuneError) {
        throw .unsupported("not yet unpacked")
    }
}
