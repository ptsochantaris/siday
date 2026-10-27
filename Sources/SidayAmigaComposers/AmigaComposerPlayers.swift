// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayChips
import SidayFoundation

/// The players of the Amiga's music systems and composers' formats that are played in Swift, each
/// as its own player played it.
///
/// The loader asks each family in turn for a player (`TuneLoader`): nil is for a tune of a format
/// that is not this family's.
package enum AmigaComposerPlayers {
    /// True for a file that begins as SidMon's do, with its player's code: one of SidMon's, though it
    /// is named as a SID file (`TuneFormat.refined(byLeading:)`).
    package static func isSidMon1(_ leading: [UInt8]) -> Bool { SidMon1Player.isOne(leading) }

    // (Compiled here, and only called from elsewhere: see `TuneLoader`.)
    @export(interface)
    package static func player(_ data: [UInt8], format: TuneFormat, path: String?, options: LoadOptions,
                               companions: [[UInt8]?]) throws -> (any Renderer)? {
        switch format {
        case .tfmx:
            // Chris Hülsbeck's TFMX: its samples in a file of their own, unless the file is one of
            // the forms that keep them in it.
            do {
                return try PaulaTickRenderer(TFMXPlayer(data, samples: companions.first ?? nil), options: options)
            } catch TuneError.missingCompanion {
                throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
            }
        case .hip, .fc:
            // Jochen Hippel's TFMX, in its several kinds, and Future Composer; with the samples that a
            // compressed song may keep in a file of their own after it.
            if format == .hip, HippelPlayer.keepsSamplesApart(data) {
                guard let samples = companions.first ?? nil else {
                    throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
                }
                return try PaulaTickRenderer(HippelPlayer(data + samples), options: options)
            }
            return try PaulaTickRenderer(HippelPlayer(data), options: options)
        case .puma:
            // PumaTracker's, with its waveforms built into the player.
            return try PaulaTickRenderer(PumaPlayer(data), options: options)
        case .pap:
            // Pierre Adane's packed modules, with their samples in a file of their own.
            guard let samples = companions.first ?? nil else {
                throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
            }
            return try PaulaTickRenderer(PAPPlayer(data, samples: samples), options: options)
        case .gmc:
            // Game Music Creator's, as its own player plays them.
            return try PaulaTickRenderer(GMCPlayer(data), options: options)
        case .sid1:
            // SidMon's, its player before it.
            return try PaulaTickRenderer(SidMon1Player(data), options: options)
        case .sid2:
            return try PaulaTickRenderer(SidMon2Player(data), options: options)
        case .mug:
            // Digital Mugician's, and Mugician II's of seven voices.
            return try PaulaTickRenderer(MugicianPlayer(data), options: options)
        case .dm2:
            // Delta Music 2.0's, each with its player in it.
            return try PaulaTickRenderer(DeltaMusicPlayer(data), options: options)
        case .mxtx:
            // MaxTrax's scores, with the instruments from the file beside them when they have none.
            if MaxTraxPlayer.needsInstruments(data) {
                guard let instruments = companions.first ?? nil else {
                    throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
                }
                return try PaulaTickRenderer(MaxTraxPlayer(data, instruments: instruments), options: options)
            }
            return try PaulaTickRenderer(MaxTraxPlayer(data), options: options)
        case .sonix:
            // The Sonix Music Driver's scores, with the instruments of the folder beside them.
            guard let folder = companions.first ?? nil else {
                _ = try SonixPlayer.check(data)
                throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
            }
            return try PaulaTickRenderer(SonixPlayer(data, instruments: CompanionFolder.unpack(folder)), options: options)
        case .dum:
            // Infogrames' scores, with their instruments beside them.
            guard let instruments = companions.first ?? nil else {
                guard InfogramesPlayer.isOne(data) else { throw TuneError.unsupported("not a score of Infogrames' player") }
                throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
            }
            return try PaulaTickRenderer(InfogramesPlayer(data, samples: instruments), options: options)
        case .ex:
            return try PaulaTickRenderer(FashionTrackerPlayer(data), options: options)
        case .dsc:
            return try PaulaTickRenderer(DigitalSonixPlayer(data), options: options)
        case .bye:
            return try PaulaTickRenderer(AndrewPartonPlayer(data), options: options)
        case .ems:
            return try PaulaTickRenderer(EMSPlayer(data), options: options)
        case .fw:
            return try PaulaTickRenderer(ForgottenWorldsPlayer(data), options: options)
        case .lme:
            return try PaulaTickRenderer(LMEPlayer(data), options: options)
        case .jam:
            return try PaulaTickRenderer(JamCrackerPlayer(data), options: options)
        case .amc:
            return try PaulaTickRenderer(AMComposerPlayer(data), options: options)
        case .cin:
            // Cinemaware's scores, with the instruments of the folder beside them.
            guard let folder = companions.first ?? nil else {
                guard CinemawarePlayer.isOne(data) else { throw TuneError.unsupported("not a score of Cinemaware's player") }
                throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
            }
            return try PaulaTickRenderer(CinemawarePlayer(data, instruments: CompanionFolder.unpack(folder)), options: options)
        case .ps:
            return try PaulaTickRenderer(PaulShieldsPlayer(data), options: options)
        case .sjs:
            // Scott Johnston's SoundPlayer, with its samples beside it.
            guard let samples = companions.first ?? nil else {
                guard SJSPlayer.isOne(data) else { throw TuneError.unsupported("not a score of SoundPlayer's") }
                throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
            }
            return try PaulaTickRenderer(SJSPlayer(data, samples: samples), options: options)
        case .dat:
            // Paul Robotham's scores on Pete Barnett's driver, with their samples beside them. (`.dat` is
            // the name of many files of other kinds, so a file is first found to be one of these scores.)
            guard PaulRobothamPlayer.isOne(data) else { throw TuneError.unsupported("not a score of Paul Robotham's") }
            guard let samples = companions.first ?? nil else {
                throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
            }
            return try PaulaTickRenderer(PaulRobothamPlayer(data, samples: samples), options: options)
        case .thm:
            // Thomas Hermann's, with its samples in the file beside it, or failing that each in the
            // folder of instruments beside it.
            guard ThomasHermannPlayer.isOne(data) else { throw TuneError.unsupported("not a module of Thomas Hermann's") }
            let samples = companions.first ?? nil, folder = companions.count > 1 ? companions[1] : nil
            guard samples != nil || folder != nil else { throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0]) }
            return try PaulaTickRenderer(ThomasHermannPlayer(data, samples: samples, instruments: folder.map(CompanionFolder.unpack) ?? []), options: options)
        case .sdr, .uds:
            // Synth Dream's and the Blade Packer's, each with its samples beside it.
            let isOne = format == .sdr ? SynthDreamPlayer.isOne(data) : BladePackerPlayer.isOne(data)
            guard isOne else { throw TuneError.unsupported(format == .sdr ? "not a module of Synth Dream's" : "not a module of the Blade Packer's") }
            guard let samples = companions.first ?? nil else { throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0]) }
            if format == .sdr { return try PaulaTickRenderer(SynthDreamPlayer(data, samples: samples), options: options) }
            return try PaulaTickRenderer(BladePackerPlayer(data, samples: samples), options: options)
        case .tf:
            // (Known by its name only: the player's own check takes some of Ron Klaren's modules too,
            // which begin as these do, with jumps.)
            guard TimFollinPlayer.isOne(data) else { throw TuneError.unsupported("not a module of Tim Follin's") }
            return try PaulaTickRenderer(TimFollinPlayer(data), options: options)
        case .snk:
            guard PaulSummersPlayer.isOne(data) else { throw TuneError.unsupported("not a module of Paul Summers's") }
            return try PaulaTickRenderer(PaulSummersPlayer(data), options: options)
        case .ast:
            guard ActionAmicsPlayer.isOne(data) else { throw TuneError.unsupported("not a module of Action Amics'") }
            return try PaulaTickRenderer(ActionAmicsPlayer(data), options: options)
        case .jpn:
            // Jason Page's scores, with their samples beside them; but for ViroCop's, of which there is none
            // to check a port of its routine by.
            guard JasonPagePlayer.isOne(data) else { throw TuneError.unsupported("not a score of Jason Page's") }
            if JasonPagePlayer.kind(of: data) == .third { throw TuneError.unsupported("a score of ViroCop's routine, which is not played") }
            guard let samples = companions.first ?? nil else { throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0]) }
            return try PaulaTickRenderer(JasonPagePlayer(data, samples: samples), options: options)
        case .mok:
            // Silmarils' music; a module of no more than two samples has the rest in the module of its
            // name up to its first underscore.
            guard SilmarilsPlayer.isOne(data) else { throw TuneError.unsupported("not a Silmarils module") }
            let samples = companions.first ?? nil
            if SilmarilsPlayer.needsCompanion(data), samples == nil { throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0]) }
            return try PaulaTickRenderer(SilmarilsPlayer(data, samples: samples), options: options)
        case .osp:
            // Karsten Obarski's Synth Pack songs, with the samples their folder shares beside them.
            guard SynthPackPlayer.isOne(data) else { throw TuneError.unsupported("not a Synth Pack song") }
            guard let samples = companions.first ?? nil else { throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0]) }
            return try PaulaTickRenderer(SynthPackPlayer(data, samples: samples), options: options)
        case .sct:
            // Holger Gehrmann's SoundControl, of its four versions, each with its samples.
            guard SoundControlPlayer.isOne(data) else { throw TuneError.unsupported("not a SoundControl module") }
            return try PaulaTickRenderer(SoundControlPlayer(data), options: options)
        case .rk:
            guard RonKlarenPlayer.isOne(data) else { throw TuneError.unsupported("not a module of Ron Klaren's") }
            return try PaulaTickRenderer(RonKlarenPlayer(data), options: options)
        case .dh:
            guard DavidHanneyPlayer.isOne(data) else { throw TuneError.unsupported("not a module of David Hanney's") }
            return try PaulaTickRenderer(DavidHanneyPlayer(data), options: options)
        case .psf:
            guard SoundfactoryPlayer.isOne(data) else { throw TuneError.unsupported("not a module of Soundfactory's") }
            return try PaulaTickRenderer(SoundfactoryPlayer(data), options: options)
        case .jpo:
            return try PaulaTickRenderer(SteveTurnerPlayer(data), options: options)
        case .psa:
            return try PaulaTickRenderer(PSAPlayer(data), options: options)
        case .tme:
            return try PaulaTickRenderer(TMEPlayer(data), options: options)
        case .pvp:
            return try PaulaTickRenderer(PVPPlayer(data), options: options)
        case .alp:
            // The Alcatraz Packer's: most with their samples in a file beside them.
            return try PaulaTickRenderer(ALPPlayer(data, samples: (companions.first ?? nil) ?? []), options: options)
        case .dln:
            // Dave Lowe's later music, as the players of Flink and Super Street Fighter II had it.
            return try PaulaTickRenderer(DaveLoweNewPlayer(data), options: options)
        case .rjp:
            // Richard Joseph's modules, with their samples from the file beside them.
            guard let samples = companions.first ?? nil else {
                guard RichardJosephPlayer.isOne(data) else { throw TuneError.unsupported("not a Richard Joseph Player module") }
                throw Companions.missing(Companions.wanted(for: format, fileName: Companions.fileName(path))[0])
            }
            return try PaulaTickRenderer(RichardJosephPlayer(data, samples: samples), options: options)
        case .sa:
            // Sonic Arranger's: the editor's modules, games' songs, and songs with their replayer.
            return try PaulaTickRenderer(SonicArrangerPlayer(data), options: options)
        case .bp:
            // Brian Postma's SoundMon, 2.0's and 2.2's, as his players play them.
            return try PaulaTickRenderer(SoundMonPlayer(data), options: options)
        case .ims:
            // Images Music System's, with a song for each place in the order its player starts one.
            return try PaulaTickRenderer(IMSPlayer(data), options: options)
        case .ml:
            // The Musicline Editor's modules, each tune of the file a song.
            guard MusiclinePlayer.isOne(data) else { throw TuneError.unsupported("not a Musicline Editor module") }
            return try PaulaTickRenderer(MusiclinePlayer(data), options: options)
        default:
            return nil
        }
    }
}
