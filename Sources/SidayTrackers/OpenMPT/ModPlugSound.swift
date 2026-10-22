// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how a file keeps a plug-in (`soundlib/Load_it.cpp`, `soundlib/plugins/PluginStructs.h`) and how
// OpenMPT finds the one it means (`soundlib/plugins/PluginManager.cpp`).

/// A plug-in as a file of ModPlug Tracker's or OpenMPT's keeps it: which program it is, its settings,
/// and how it is wired in.
///
/// A plug-in is somebody's program, and most are not here to be run. A few are OpenMPT's own, built
/// into the tracker so that a tune that uses them sounds the same on any machine, and those are
/// played (see `OpenMPTEffect`). The rest are left out as OpenMPT leaves out a plug-in it cannot
/// find: what was sent to one is heard without it.
struct ModPlugPlugIn {
    /// OpenMPT's own effects, in the order it looks through them.
    enum Kind {
        case chorus, compressor, distortion, echo, flanger, gargle, i3dl2Reverb, paramEq, wavesReverb, flangerLegacy, digiBoosterEcho, symMODEcho
    }

    private static let dmo: UInt32 = 0x4458_4D4F // "DXMO"
    private static let known: [(first: UInt32, second: UInt32, name: String, kind: Kind)] = [
        (dmo, 0xEFE6_629C, "Chorus", .chorus), (dmo, 0xEF01_1F79, "Compressor", .compressor), (dmo, 0xEF11_4C90, "Distortion", .distortion),
        (dmo, 0xEF3E_932C, "Echo", .echo), (dmo, 0xEFCA_3D92, "Flanger", .flanger), (dmo, 0xDAFD_8210, "Gargle", .gargle),
        (dmo, 0xEF98_5E71, "I3DL2Reverb", .i3dl2Reverb), (dmo, 0x120C_ED89, "ParamEq", .paramEq), (dmo, 0x87FC_0268, "WavesReverb", .wavesReverb),
        (dmo, 0xEFCA_3D92, "Flanger (Legacy)", .flangerLegacy),
        (0x304D_4244, 0x6F68_6345, "DigiBooster Pro Echo", .digiBoosterEcho), // "DBM0", "Echo"
        (0x4D6D_7953, 0x6F68_6345, "SymMOD Echo", .symMODEcho), // "SymM", "Echo"
    ]

    // Routing flags.
    static let applyToMaster: UInt8 = 0x01, bypassed: UInt8 = 0x02, dryMix: UInt8 = 0x04, expandMix: UInt8 = 0x08, autoSuspend: UInt8 = 0x10

    /// The two numbers that say which program it is, and a third for one that is one of several in a shell.
    var first: UInt32 = 0, second: UInt32 = 0, shell: UInt32 = 0
    var routingFlags: UInt8 = 0
    /// How what it makes is put together with what it was given: see `OpenMPTPlugIns`.
    var mixMode: UInt8 = 0
    /// How much louder it is made, in tenths; nought for as it is.
    var gain: UInt8 = 0
    /// Nought if what it makes goes to the listener; 128 and the place of another plug-in if it goes on to that.
    var outputRouting: UInt32 = 0
    /// What its user called it, and the name of the program's file.
    var name = "", libraryName = ""
    /// Its settings, in whatever form the program keeps them.
    var data: [UInt8] = []
    /// How much of what it was given is heard beside what it makes, from nought to one.
    var dryRatio: Float = 0

    /// True if the place has a plug-in in it at all.
    var isThere: Bool { first | second != 0 }

    /// The name to call it by in a sentence: its user's, or its file's.
    var title: String { libraryName.isEmpty ? name : libraryName }

    init() {}

    /// Reads one from the piece of a file that keeps it, which starts at `at` and is `size` bytes:
    /// 128 bytes that say what it is, its settings with their length before them, and then a few
    /// more things, each with a name of four letters. What is asked for beyond the end is nought.
    init(_ file: [UInt8], at: Int, size: Int) {
        // (A whole number in a browser has 32 bits: nothing is added that could pass them.)
        let end = at < 0 || at >= file.count ? 0 : size >= file.count - at ? file.count : at + max(0, size)
        func byte(_ index: Int) -> UInt8 { index >= at && index < end ? file[index] : 0 }
        func long(_ index: Int) -> UInt32 { UInt32(byte(index)) | UInt32(byte(index + 1)) << 8 | UInt32(byte(index + 2)) << 16 | UInt32(byte(index + 3)) << 24 }
        func text(_ index: Int, _ length: Int) -> String {
            var bytes: [UInt8] = []
            for i in 0 ..< length - 1 {
                let b = byte(index + i)
                if b == 0 { break }
                bytes.append(b)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        first = long(at)
        second = long(at + 4)
        routingFlags = byte(at + 8)
        mixMode = byte(at + 9)
        gain = byte(at + 10)
        outputRouting = long(at + 12)
        shell = long(at + 16)
        name = text(at + 32, 32)
        libraryName = text(at + 64, 64)
        var next = at + 128
        let length = Int(min(long(next), 0x3FFF_FFFF))
        next += 4
        let there = max(0, min(length, end - next))
        if there > 0 { data = Array(file[next ..< next + there]) }
        next += there
        // The rest: how much there is of it, and then one thing after another.
        let more = Int(min(long(next), 0x3FFF_FFFF))
        next += 4
        let last = more >= end - next ? end : next + more
        while next + 5 <= last {
            let code = long(next)
            next += 4
            var length = 4
            // (The two oldest are four bytes each and do not say so.)
            if code != 0x5452_5744, code != 0x474F_5250 { // "DWRT", "PROG"
                length = Int(min(long(next), 0x3FFF_FFFF))
                next += 4
                if length >= last - next { break }
            }
            if code == 0x5452_5744, next + 4 <= last {
                let ratio = Float(bitPattern: long(next))
                dryRatio = ratio >= 0 ? (ratio <= 1 ? ratio : 1) : 0 // (and nought for what is not a number)
            }
            next += length
        }
    }

    /// Which of OpenMPT's own effects it is, found as OpenMPT finds it: by its numbers and its
    /// name together, or else by its numbers, or else by its name.
    var kind: Kind? {
        var found: Kind?, quality = 0
        let wanted = Self.lowercased(libraryName)
        for entry in Self.known {
            let matchID = entry.first == first && entry.second == second && shell == 0
            let matchName = Self.lowercased(entry.name) == wanted
            if matchID, matchName { return entry.kind }
            if matchID, quality < 2 {
                found = entry.kind
                quality = 2
            } else if matchName, quality < 1 {
                found = entry.kind
                quality = 1
            }
        }
        return found
    }

    private static func lowercased(_ text: String) -> [UInt8] {
        text.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
    }

    /// The effect itself, with the settings the file keeps for it; nil for a program that is not here.
    func makeEffect() -> OpenMPTEffect? {
        guard isThere, let kind else { return nil }
        let effect: OpenMPTEffect
        switch kind {
        case .chorus: effect = OpenMPTChorus()
        case .compressor: effect = OpenMPTCompressor()
        case .distortion: effect = OpenMPTDistortion()
        case .echo: effect = OpenMPTEcho()
        case .flanger: effect = OpenMPTFlanger(legacy: false)
        case .flangerLegacy: effect = OpenMPTFlanger(legacy: true)
        case .gargle: effect = OpenMPTGargle()
        case .i3dl2Reverb: effect = OpenMPTI3DL2Reverb()
        case .paramEq: effect = OpenMPTParamEq()
        case .wavesReverb: effect = OpenMPTWavesReverb()
        case .digiBoosterEcho: effect = OpenMPTDigiBoosterEcho()
        case .symMODEcho: effect = OpenMPTSymMODEcho()
        }
        // Its settings: in a form of its own, or a nought and then each setting as a number, which
        // are taken only if they are all there.
        if !effect.restore(chunk: data), data.count >= 4, data[0] | data[1] | data[2] | data[3] == 0, (data.count - 4) / 4 >= effect.parameterCount {
            for index in 0 ..< effect.parameterCount {
                let at = 4 + index * 4
                let value = Float(bitPattern: UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24)
                effect.setParameter(index, value.isFinite ? value : 0)
            }
        }
        return effect
    }
}

/// What a file of ModPlug Tracker's or OpenMPT's has to be heard besides its samples, and what is
/// needed to put it together with them as OpenMPT does: its plug-ins, the instruments it has for
/// the AdLib's FM chip, and how loud OpenMPT plays the file, on which both depend.
///
/// A module has one of these only if there is something in it to play: an FM instrument, or a
/// plug-in that is one of OpenMPT's own with something sent through it. Any other module is mixed
/// as it always was, and none of this is reached.
struct ModPlugSound {
    /// The file's plug-ins by their places, the first place first.
    var plugIns: [ModPlugPlugIn] = []
    /// The plug-in each channel is sent through, counted from 1; nought for none.
    var channelPlugIns: [Int] = []
    /// How the FM chip is to be played, if the file has instruments for it.
    var adLib: OpenMPTAdLib.Behaviour?
    /// What the chip's sound is multiplied by to sit among the samples as OpenMPT has it.
    var adLibLevel: Float = 1
    /// What the mixer's sound is multiplied by to be as loud as OpenMPT makes it, which is what a
    /// plug-in is given: an effect that squashes or clips does so at a level.
    var level: Float = 1
    /// True if that is to be multiplied by what the mixer itself turns the file down by: for an IT
    /// file that ModPlug Tracker made, which the mixer makes quieter the more channels it has.
    var levelIsTheMixers = false
    /// And by what again to be what OpenMPT gives a plug-in, which in its oldest ways of adding up is
    /// less (a half, and a sixteenth). What the plug-ins give back is made as much louder again,
    /// and no louder than OpenMPT's whole numbers can be.
    var plugInScale: Float = 1
    /// True if the song's volume is applied to the whole sound at the end, after the plug-ins, and
    /// not to each voice: OpenMPT's way in all but its oldest ways of adding up.
    var globalVolumeAtMaster = true

    /// True if anything is sent through a plug-in that is played: a channel, an instrument (given
    /// the plug-in each instrument plays through, counted from 1), or the whole sound.
    func sendsToPlugIns(instruments: [Int]) -> Bool {
        func played(_ plugIn: Int) -> Bool { plugIn >= 1 && plugIn <= plugIns.count && plugIns[plugIn - 1].kind != nil }
        return channelPlugIns.contains(where: played) || instruments.contains(where: played)
            || plugIns.contains { $0.routingFlags & ModPlugPlugIn.applyToMaster != 0 && $0.kind != nil }
    }

    /// What OpenMPT multiplies the chip's sound by, against a sample at full volume, for a song
    /// whose "synth volume" is `synthVolume` (48 unless the file says otherwise).
    static func adLibLevel(synthVolume: Int) -> Float {
        Float(6169.0 / 4096.0) * Float(max(0, min(2000, synthVolume))) / 48
    }
}
