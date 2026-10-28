// Copyright (C) 2003-2009 Dean Beeler, Jerome Fisher; (C) 2011-2024 Dean Beeler, Jerome Fisher, Sergey V. Mikayev
// Swift port Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The MT-32's ROMs as Munt knows them (ROMInfo.cpp of libmt32emu 2.8.3: their sizes and SHA-1 digests, and
// how the halves of the split ones are joined), free software under the GNU Lesser General Public License,
// version 2.1 or any later version (see THIRD-PARTY.md).

import SidayFoundation

/// What a ROM file is: a whole ROM, or half of one, by its size and SHA-1 digest, as Munt lists them.
public struct MT32ROMFile: Sendable, Equatable {
    public enum Kind: Sendable { case control, pcm }

    /// How a file is a part of a ROM: the whole of it; its first or second half; or its even or odd bytes.
    public enum Piece: Sendable { case full, firstHalf, secondHalf, evenBytes, oddBytes }

    /// Munt's name for it (as `ctrl_cm32l_1_00`, `pcm_cm32l_h`).
    public let id: String
    /// What Munt calls it.
    public let name: String
    public let kind: Kind
    public let piece: Piece
    public let size: Int
    public let sha1: String
    /// The whole ROM it is a part of, for a half: its id.
    public let whole: String

    /// Every ROM file Munt knows.
    public static let known: [MT32ROMFile] = {
        var files: [MT32ROMFile] = []
        func add(_ id: String, _ name: String, _ kind: Kind, _ piece: Piece, _ size: Int, _ sha1: String, _ whole: String? = nil) {
            files.append(MT32ROMFile(id: id, name: name, kind: kind, piece: piece, size: size, sha1: sha1, whole: whole ?? id))
        }
        let halves: [(String, String, String, String, String)] = [
            ("1_04", "1.04", "9cd4858014c4e8a9dff96053f784bfaac1092a2e", "fe8db469b5bfeb37edb269fd47e3ce6d91014652", "5a5cb5a77d7d55ee69657c2f870416daed52dea7"),
            ("1_05", "1.05", "57a09d80d2f7ca5b9734edbe9645e6e700f83701", "52e3c6666db9ef962591a8ee99be0cde17f3a6b6", "e17a3a6d265bf1fa150312061134293d2b58288c"),
            ("1_06", "1.06", "cc83bf23cee533097fb4c7e2c116e43b50ebacc8", "bf4f15666bc46679579498386704893b630c1171", "a553481f4e2794c10cfe597fef154eef0d8257de"),
            ("1_07", "1.07", "13f06b38f0d9e0fc050b6503ab777bb938603260", "c55e165487d71fa88bd8c5e9c083bc456c1a89aa", "b083518fffb7f66b03c23b7eb4f868e62dc5a987"),
            ("bluer", "BlueRidge", "11a6ae5d8b6ee328b371af7f1e40b82125aa6b4d", "e0934320d7cbb5edfaa29e0d01ae835ef620085b", "7b8c2a5ddb42fd0732e2f22b3340dcf5360edf92"),
        ]
        for (id, version, a, b, full) in halves {
            let name = version == "BlueRidge" ? "MT-32 Control BlueRidge" : "MT-32 Control v" + version
            add("ctrl_mt32_" + id, name, .control, .full, 65536, full)
            add("ctrl_mt32_" + id + "_a", name + " (even bytes)", .control, .evenBytes, 32768, a, "ctrl_mt32_" + id)
            add("ctrl_mt32_" + id + "_b", name + " (odd bytes)", .control, .oddBytes, 32768, b, "ctrl_mt32_" + id)
        }
        add("ctrl_mt32_2_03", "MT-32 Control v2.03", .control, .full, 131_072, "5837064c9df4741a55f7c4d8787ac158dff2d3ce")
        add("ctrl_mt32_2_04", "MT-32 Control v2.04", .control, .full, 131_072, "2c16432b6c73dd2a3947cba950a0f4c19d6180eb")
        add("ctrl_mt32_2_06", "MT-32 Control v2.06", .control, .full, 131_072, "2869cf4c235d671668cfcb62415e2ce8323ad4ed")
        add("ctrl_mt32_2_07", "MT-32 Control v2.07", .control, .full, 131_072, "47b52adefedaec475c925e54340e37673c11707c")
        add("ctrl_cm32l_1_00", "CM-32L/LAPC-I Control v1.00", .control, .full, 65536, "73683d585cd6948cc19547942ca0e14a0319456d")
        add("ctrl_cm32l_1_02", "CM-32L/LAPC-I Control v1.02", .control, .full, 65536, "a439fbb390da38cada95a7cbb1d6ca199cd66ef8")
        add("ctrl_cm32ln_1_00", "CM-32LN/CM-500/LAPC-N Control v1.00", .control, .full, 65536, "dc1c5b1b90a4646d00f7daf3679733c7badc7077")
        add("pcm_mt32", "MT-32 PCM ROM", .pcm, .full, 524_288, "f6b1eebc4b2d200ec6d3d21d51325d5b48c60252")
        add("pcm_mt32_l", "MT-32 PCM ROM (first half)", .pcm, .firstHalf, 262_144, "3a1e19b0cd4036623fd1d1d11f5f25995585962b", "pcm_mt32")
        add("pcm_mt32_h", "MT-32 PCM ROM (second half)", .pcm, .secondHalf, 262_144, "2cadb99d21a6a4a6f5b61b6218d16e9b43f61d01", "pcm_mt32")
        add("pcm_cm32l", "CM-32L/CM-64/LAPC-I PCM ROM", .pcm, .full, 1_048_576, "289cc298ad532b702461bfc738009d9ebe8025ea")
        add("pcm_cm32l_h", "CM-32L/CM-64/LAPC-I PCM ROM (second half)", .pcm, .secondHalf, 524_288, "3ad889fde5db5b6437cbc2eb6e305312fec3df93", "pcm_cm32l")
        return files
    }()

    /// What a file is, by its content alone: nil for a file that is none of these.
    public static func identify(_ data: [UInt8]) -> MT32ROMFile? { identify(data, in: known) }

    /// The same, in another list of ROM files than Munt's (for testing the joining of halves).
    static func identify(_ data: [UInt8], in table: [MT32ROMFile]) -> MT32ROMFile? {
        guard table.contains(where: { $0.size == data.count }) else { return nil }
        let digest = SHA1.hex(data)
        return table.first { $0.size == data.count && $0.sha1 == digest }
    }

    /// The same, for a file whose digest is known already.
    public static func identify(size: Int, sha1: String) -> MT32ROMFile? {
        known.first { $0.size == size && $0.sha1 == sha1 }
    }
}

extension MT32ROMSet {
    /// The control ROMs of the LAPC-I's generation that siday plays MT-32 files with, the most wanted
    /// first: v1.00, Munt's "CM-32L/LAPC-I Control v1.00" (a dump of an LAPC-I's is this one), then v1.02. The
    /// two differ only in their program, below 0x8000; their sounds and settings are the same, and MT-32
    /// files come out the same, sample for sample, on either.
    public static let lapcIControls: [MT32ControlROM] = [.cm32l_1_00, .cm32l_1_02]

    /// Joins the halves of split ROMs as Munt joins them (a first and a second half one after the other;
    /// even and odd bytes interleaved), and finds a whole control ROM of one of `controls` (in that order of
    /// preference) and a PCM ROM that goes with it. Files that are none of the MT-32's ROMs are passed over.
    /// - Returns: nil if the files do not make such a set.
    public static func assemble(_ files: [[UInt8]], controls: [MT32ControlROM] = lapcIControls) -> MT32ROMSet? {
        assemble(files, controls: controls, table: MT32ROMFile.known)
    }

    /// The same, by another list of ROM files than Munt's (for testing).
    static func assemble(_ files: [[UInt8]], controls: [MT32ControlROM], table: [MT32ROMFile]) -> MT32ROMSet? {
        var wholes: [String: [UInt8]] = [:]
        var pieces: [(MT32ROMFile, [UInt8])] = []
        for data in files {
            guard let file = MT32ROMFile.identify(data, in: table) else { continue }
            if file.piece == .full {
                wholes[file.id] = data
            } else {
                pieces.append((file, data))
            }
        }
        for (file, data) in pieces where wholes[file.whole] == nil {
            // The other half of the same ROM; for the CM-32L's PCM, its first half is the MT-32's whole PCM ROM.
            let partner: [UInt8]?
            switch file.piece {
            case .firstHalf: partner = pieces.first { $0.0.whole == file.whole && $0.0.piece == .secondHalf }?.1
            case .secondHalf:
                partner = file.whole == "pcm_cm32l" ? wholes["pcm_mt32"] : pieces.first { $0.0.whole == file.whole && $0.0.piece == .firstHalf }?.1
            case .evenBytes: partner = pieces.first { $0.0.whole == file.whole && $0.0.piece == .oddBytes }?.1
            case .oddBytes: partner = pieces.first { $0.0.whole == file.whole && $0.0.piece == .evenBytes }?.1
            case .full: partner = nil
            }
            guard let partner else { continue }
            var joined: [UInt8]
            switch file.piece {
            case .firstHalf: joined = data + partner
            case .secondHalf: joined = partner + data
            case .evenBytes, .oddBytes:
                let even = file.piece == .evenBytes ? data : partner, odd = file.piece == .evenBytes ? partner : data
                joined = []
                joined.reserveCapacity(even.count * 2)
                for i in 0 ..< even.count {
                    joined.append(even[i])
                    joined.append(odd[i])
                }
            case .full: continue
            }
            // Kept only if the whole is the ROM it should be.
            if let whole = MT32ROMFile.identify(joined, in: table), whole.id == file.whole { wholes[file.whole] = joined }
        }
        for control in controls {
            guard let controlData = wholes[control.rawValue] else { continue }
            guard let pcm = wholes[control.isCM32LKind ? "pcm_cm32l" : "pcm_mt32"] else { continue }
            // (Of a control ROM of 128 KB, the MT-32 2.0x's, the first 64 KB are taken, as mt32emu takes them.)
            return MT32ROMSet(control: control, controlData: Array(controlData.prefix(65536)), pcmData: pcm)
        }
        return nil
    }
}
