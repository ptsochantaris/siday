// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayChips
import SidayFoundation

/// The players of the Amiga's music whose files are the composer's own code, run on an emulated
/// Amiga (`AmigaMachine`).
///
/// The loader asks each family in turn for a player (`TuneLoader`): nil is for a tune of a format
/// that is not this family's.
package enum AmigaMachinePlayers {
    // (Compiled here, and only called from elsewhere: see `TuneLoader`.)
    @export(interface)
    package static func player(_ data: [UInt8], format: TuneFormat, path: String?, options: LoadOptions,
                               companions: [[UInt8]?]) throws -> (any Renderer)? {
        switch format {
        case .dw:
            // David Whittaker's drivers, each with its music, run on an Amiga of their own.
            return try PaulaTickRenderer(WhittakerPlayer(data), options: options)
        case .mon, .jt:
            // The Maniacs of Noise's drivers, Charles Deenen's and Jeroen Tel's earlier one, each with
            // its music, run on an Amiga of their own: both are found under either name (the older
            // driver's files were also called MON), and are told apart by how they begin.
            if ManiacsOfNoisePlayer.isOne(data) { return try PaulaTickRenderer(ManiacsOfNoisePlayer(data), options: options) }
            if JeroenTelPlayer.isOne(data) { return try PaulaTickRenderer(JeroenTelPlayer(data), options: options) }
            throw TuneError.unsupported("not a module of the Maniacs of Noise's or of Jeroen Tel's")
        case .cust:
            // DeliTracker's custom modules, each a player of its own with its music, hosted on an
            // Amiga of their own as DeliTracker hosted them.
            return try PaulaTickRenderer(DeliCustomPlayer(data, name: Companions.fileName(path)), options: options)
        case .dl:
            // Dave Lowe's earlier music, his own code with it, hosted in the same way.
            return try PaulaTickRenderer(DaveLoweCodePlayer(data, name: Companions.fileName(path)), options: options)
        case .bd:
            // Ben Daglish's drivers, each with its music, run on an Amiga of their own.
            return try PaulaTickRenderer(DaglishPlayer(data), options: options)
        case .core:
            // The composers' own code that Wanted Team's players find and call, each run on an Amiga
            // of its own as their player for EaglePlayer runs it.
            return try PaulaTickRenderer(CoreDesignPlayer(data, name: Companions.fileName(path)), options: options)
        case .jmf:
            return try PaulaTickRenderer(JankoMrsicFlogelPlayer(data, name: Companions.fileName(path)), options: options)
        case .bds:
            return try PaulaTickRenderer(DaglishSIDPlayer(data, name: Companions.fileName(path)), options: options)
        case .gray:
            return try PaulaTickRenderer(FredGrayPlayer(data, name: Companions.fileName(path)), options: options)
        case .hd:
            return try PaulaTickRenderer(HowieDaviesPlayer(data, name: Companions.fileName(path)), options: options)
        case .spl:
            return try PaulaTickRenderer(SoundProgrammingLanguagePlayer(data, name: Companions.fileName(path)), options: options)
        case .dz:
            return try PaulaTickRenderer(DariusZendehPlayer(data, name: Companions.fileName(path)), options: options)
        case .mii:
            return try PaulaTickRenderer(MarkIIPlayer(data, name: Companions.fileName(path)), options: options)
        case .bss:
            return try PaulaTickRenderer(BeathovenSynthesizerPlayer(data, name: Companions.fileName(path)), options: options)
        case .sm:
            return try PaulaTickRenderer(SoundMasterPlayer(data, name: Companions.fileName(path)), options: options)
        case .sb:
            return try PaulaTickRenderer(SteveBarrettPlayer(data, name: Companions.fileName(path)), options: options)
        case .rh:
            return try PaulaTickRenderer(RobHubbardPlayer(data, name: Companions.fileName(path)), options: options)
        case .rho:
            return try PaulaTickRenderer(RobHubbardSTPlayer(data, name: Companions.fileName(path)), options: options)
        case .fred:
            return try PaulaTickRenderer(FredMonitorPlayer(data, name: Companions.fileName(path)), options: options)
        case .dsr:
            return try PaulaTickRenderer(DesirePlayer(data, name: Companions.fileName(path)), options: options)
        case .scumm:
            return try PaulaTickRenderer(ScummPlayer(data, name: Companions.fileName(path)), options: options)
        case .scn:
            return try PaulaTickRenderer(SeanConnollyPlayer(data, name: Companions.fileName(path)), options: options)
        case .mc:
            return try PaulaTickRenderer(MarkCookseyPlayer(data, name: Companions.fileName(path)), options: options)
        case .kh:
            // Kris Hatlelid's: most are music alone, played by his replayer beside them, `songplay`.
            let replayer = (companions.first ?? nil).map { [(name: KrisHatlelid.replayerName, bytes: $0)] } ?? []
            return try PaulaTickRenderer(KrisHatlelidPlayer(data, name: Companions.fileName(path), files: replayer), options: options)
        case .scr:
            return try PaulaTickRenderer(SeanConranPlayer(data, name: Companions.fileName(path)), options: options)
        case .tw:
            return try PaulaTickRenderer(SoundImagesPlayer(data, name: Companions.fileName(path)), options: options)
        case .wb:
            return try PaulaTickRenderer(WallyBebenPlayer(data, name: Companions.fileName(path)), options: options)
        case .md:
            return try PaulaTickRenderer(MikeDaviesPlayer(data, name: Companions.fileName(path)), options: options)
        case .jcb:
            return try PaulaTickRenderer(JasonBrookePlayer(data, name: Companions.fileName(path)), options: options)
        case .ash:
            // Ashley Hogg's: those of 1993 have their samples beside them, by the module's name.
            let name = Companions.fileName(path)
            let samples = (companions.first ?? nil).flatMap { bytes in
                AshleyHogg.samplesName(Array(name.utf8)).map { [(name: String(decoding: $0, as: UTF8.self), bytes: bytes)] }
            } ?? []
            return try PaulaTickRenderer(AshleyHoggPlayer(data, name: name, files: samples), options: options)
        case .jo:
            // Jesper Olsen's: some modules with his code in them, the rest played by the game's own driver
            // beside them, which Wanted Team kept as `WantedTeam.bin`.
            let driver = (companions.first ?? nil).map { [(name: JesperOlsen.replayerName, bytes: $0)] } ?? []
            return try PaulaTickRenderer(JesperOlsenPlayer(data, name: Companions.fileName(path), files: driver), options: options)
        case .dns:
            // Chris Hülsbeck's Dynamic Synthesizer, with its samples beside it.
            let name = Companions.fileName(path)
            guard let samples = companions.first ?? nil, let samplesName = DynamicSynthesizer.samplesName(name) else {
                guard DynamicSynthesizer.isOne(data) else { throw TuneError.unsupported("not a module of the Dynamic Synthesizer's") }
                throw Companions.missing(Companions.wanted(for: format, fileName: name)[0])
            }
            return try PaulaTickRenderer(DynamicSynthesizerPlayer(data, name: name, files: [(name: samplesName, bytes: samples)]), options: options)
        case .mcr:
            // Mark Cooksey's replayer of 1988, with its song data beside it, which the player loads by the
            // name it makes of the replayer's.
            let name = Companions.fileName(path)
            guard let songs = companions.first ?? nil else {
                guard MarkCooksey.isOne(data) else { throw TuneError.unsupported("not a module of Mark Cooksey's") }
                throw Companions.missing(Companions.wanted(for: format, fileName: name)[0])
            }
            return try PaulaTickRenderer(MarkCookseyPlayer(data, name: name, files: [(name: Companions.markCookseySongs(of: name), bytes: songs)]),
                                         options: options)
        case .jd:
            // Special FX's drivers, each with its music, run on an Amiga of their own.
            return try PaulaTickRenderer(SpecialFXPlayer(data), options: options)
        case .mw:
            // Martin Walker's drivers, each with its music, run on an Amiga of their own.
            return try PaulaTickRenderer(MartinWalkerPlayer(data), options: options)
        default:
            return nil
        }
    }
}
