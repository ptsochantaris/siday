// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

public enum TuneFormat: String, CaseIterable, Sendable {
    case pt3, pt2, pt1, stc, stp, asc, sqt, psc, ftc, fxm, psm, gtr
    case vtx, ym, ay, sid, sndh, mod, med, ahx, hvl, xm, s3m, it, cmf, rol, fmt
    case mtm, dtm, amf
    case gdm, ptm, ult, c67
    case mptm
    case mt2
    case sfx, okt
    case composer669 = "669"
    case stm, stx
    case far
    case dbm
    case mdl
    case j2b
    case dmf
    case imf
    case ams
    case plm
    case dsm
    case digi
    case vgm
    case sap
    case agi
    case mfp
    case tfmx
    case hip
    case fc
    case puma
    case pap
    case gmc
    case ims
    case masi
    case symmod
    case bp
    case sid1, sid2
    case mug
    case dm2
    case mxtx
    case sa
    case sonix
    case rjp
    case dln
    case dw
    case mw
    case jd
    case mon, jt
    case bd
    case cust
    case dl
    case core, jmf, bds, gray, hd, spl, dz, mii, bss, sm, sb, rh, rho, fred, dsr, scumm, scn, mc, mcr

    /// The format a file name's extension stands for, in any case. A MED module is as often named
    /// for the four letters it begins with as it is called MED, and an SNDH file was once called SND.
    public init?(fileExtension: String) {
        let name = fileExtension.lowercased()
        if name == "mmd0" || name == "mmd1" || name == "mmd2" || name == "mmd3" || name == "mmdc" {
            self = .med
        } else if name == "vgz" {
            // (A VGM file packed by gzip, which is how they are mostly kept.)
            self = .vgm
        } else if name == "smn" {
            // (SidMon's, by the Amiga's name for them; one named SID is found by how it begins.)
            self = .sid1
        } else if name == "mug2" || name == "dmu" || name == "dmu2" {
            // (Digital Mugician's, either of its two.)
            self = .mug
        } else if name == "dlm2" {
            self = .dm2
        } else if name == "sonic" || name == "sa-p" || name == "lion" || name == "sa_old" {
            // (Sonic Arranger's, by the names the Amiga's players knew them by.)
            self = .sa
        } else if name == "cus" || name == "custom" {
            // (DeliTracker's custom modules, by the other names they are kept under.)
            self = .cust
        } else if name == "avp" {
            // (Martin Walker's, by the other name UADE knows them by.)
            self = .mw
        } else if name == "dwold" {
            // (David Whittaker's, by the other name UADE knows them by.)
            self = .dw
        } else if name == "smus" || name == "snx" || name == "tiny" {
            // (The Sonix Music Driver's scores, of its three kinds.)
            self = .sonix
        } else if name == "bp3" || name == "sndmon" {
            // (SoundMon's, as the Amiga's players named them: bp3 for 2.2's.)
            self = .bp
        } else if name == "gmc" {
            // (Game Music Creator's, which ProWizard would make a ProTracker module of, but which
            // is played by its own player.)
            self = .gmc
        } else if ProWizard.extensions.contains(name) || name == "kris" || name == "abk" {
            // (A module packed by one of the packers games and demos used, named for the packer; or
            // one of ChipTracker's, or an AMOS music bank, which are read into a module.)
            self = .mod
        } else if name == "mdat" || name == "tfx" || name == "tfm" {
            // (TFMX's notes, named for its file of them, which the samples are beside; or a module
            // of one file.)
            self = .tfmx
        } else if name == "hipc" || name == "hip7" || name == "sog" || name == "soc" || name == "s7g" || name == "mcmd" {
            // (Jochen Hippel's, by the names they are kept under: compressed, of seven voices, or
            // with his player before them.)
            self = .hip
        } else if name == "fc13" || name == "fc14" || name == "fc3" || name == "fc4" || name == "smod" {
            // (Future Composer's, by its versions.)
            self = .fc
        } else if name == "snd" {
            // (As SNDH files were named before the format had a name of its own.)
            self = .sndh
        } else if name == "masi" {
            // (Epic MegaGames' files are named PSM, and found to be theirs by how they begin.)
            return nil
        } else {
            self.init(rawValue: name)
        }
    }

    /// The format a file of this kind is, by how it begins, where two formats share a name: Pro Sound
    /// Maker's files for the ZX Spectrum and Epic MegaGames' MASI files are both PSM files, and the
    /// second says what it is in its first bytes; and a SID file is the Commodore 64's, but for one of
    /// SidMon's for the Amiga, which begins with its player's code. (`leading` is the start of the
    /// file, as much of it as there is up to `leadingBytes`.)
    public func refined(byLeading leading: [UInt8]) -> TuneFormat {
        switch self {
        case .psm: MASIFile.isOne(leading) ? .masi : self
        // (SidMon's own check looks for its code further in too; those found begin with it.)
        case .sid: SidMon1Player.isOne(leading) ? .sid1 : self
        default: self
        }
    }

    /// How much of the start of a file `refined(byLeading:)` looks at.
    public static let leadingBytes = 64

    /// True for a kind of the Amiga's music whose file is the composer's own code, played as Wanted Team's
    /// player of it for EaglePlayer plays it, by the recipe they share (`WantedTeamPlayer`).
    public var isWantedTeamCode: Bool {
        switch self {
        case .core, .jmf, .bds, .gray, .hd, .spl, .dz, .mii, .bss, .sm, .sb, .rh, .rho, .fred, .dsr, .scumm, .scn, .mc, .mcr: true
        default: false
        }
    }

    /// True if a file of this kind may be found by how it begins to be another (see `refined(byLeading:)`).
    public var sharesItsName: Bool { self == .psm || self == .sid }

    /// The word that begins the heading under which FORMATS.md tells of this format: its own name,
    /// or for a format that shares a part, the first name in that heading.
    public var chapter: String {
        switch self {
        case .pt3, .pt2, .pt1, .stc, .stp, .asc, .sqt, .psc, .ftc, .fxm, .psm, .gtr, .vtx, .ay: "PT3"
        case .sfx, .okt: "SFX"
        case .mfp: "MOD"
        case .fc: "HIP"
        case .pap, .gmc, .ims: "PUMA"
        case .sid1, .sid2: "SIDMON"
        case .jt: "MON"
        case .dl: "DLN"
        case .jmf, .bds, .gray, .hd, .spl, .dz, .mii, .bss, .sm, .sb, .rh, .rho, .fred, .dsr, .scumm, .scn, .mc, .mcr: "CORE"
        case .mtm, .dtm, .amf: "MTM"
        case .gdm, .ptm: "GDM"
        case .stx: "STM"
        default: rawValue.uppercased()
        }
    }
}

/// Makes a player for a tune from the bytes of its file. The library reads no files itself: whoever
/// uses it brings the bytes, from a disk, a download or anywhere else.
public enum TuneLoader {
    /// - Parameter path: where the file came from, if it is known. A SID tune missing from the song-length
    ///   database by content is looked up by its place in the HVSC collection instead.
    /// - Parameter companions: the files the tune needs beside its own, for a kind that does: one for
    ///   each that `Companions.wanted(for:fileName:)` gives, in its order, nil for one that was not found.
    public static func load(_ data: [UInt8], format: TuneFormat, path: String? = nil, options: LoadOptions = LoadOptions(),
                            companions: [[UInt8]?] = []) throws -> any Renderer {
        guard !data.isEmpty else { throw TuneError.malformed("empty file") }
        // A module packed whole, by any of the packers modules were found packed with, is unpacked
        // first, and is then the module it was.
        let data = try Packed.unpacked(data)
        switch format.refined(byLeading: Array(data.prefix(TuneFormat.leadingBytes))) {
        case .vtx:
            return try AYFramePlayer(source: RegisterDumpSource.vtx(data), options: options)
        case .ym:
            // A recording made on an Atari ST is played on the ST's chip, with the effects ST musicians
            // made between one set of registers and the next, unless a chip, clock or rate has been
            // asked for, which is to ask for the plain recording on a chip of one's own choosing.
            if options.chipType == nil, options.clockHz == nil, options.frameHz == nil, let atari = STYMRenderer(data) {
                return atari
            }
            // And two kinds of YM file are not recordings of the chip at all, but samples.
            if let sampled = STSampleRenderer(data) { return sampled }
            return try AYFramePlayer(source: RegisterDumpSource.ym(data), options: options)
        case .pt3, .pt2, .pt1, .stc, .stp, .asc, .sqt, .psc, .ftc, .fxm, .psm, .gtr:
            if let (type1, module1, type2, module2) = TurboSoundPair.split(data) {
                let pair = try TurboSoundPair(trackerSource(module1, format: type1), trackerSource(module2, format: type2))
                return AYFramePlayer(source: pair, options: options)
            }
            return try trackerPlayer(data, format: format, options)
        case .ay:
            return try AYFileRenderer(data, options: options)
        case .sid:
            return try SIDRenderer(data, path: path, options: options)
        case .sndh:
            return try SNDHRenderer(data, options: options)
        case .sap:
            return try SAPRenderer(data, options: options)
        case .tfmx:
            // Chris Hülsbeck's TFMX: its samples in a file of their own, unless the file is one of
            // the forms that keep them in it.
            do {
                return try PaulaTickRenderer(TFMXPlayer(data, samples: companions.first ?? nil), options: options)
            } catch TuneError.missingCompanion {
                throw Companions.missing(Companions.wanted(for: format, fileName: fileName(path))[0])
            }
        case .hip, .fc:
            // Jochen Hippel's TFMX, in its several kinds, and Future Composer; with the samples that a
            // compressed song may keep in a file of their own after it.
            if format == .hip, HippelPlayer.keepsSamplesApart(data) {
                guard let samples = companions.first ?? nil else {
                    throw Companions.missing(Companions.wanted(for: format, fileName: fileName(path))[0])
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
                throw Companions.missing(Companions.wanted(for: format, fileName: fileName(path))[0])
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
                    throw Companions.missing(Companions.wanted(for: format, fileName: fileName(path))[0])
                }
                return try PaulaTickRenderer(MaxTraxPlayer(data, instruments: instruments), options: options)
            }
            return try PaulaTickRenderer(MaxTraxPlayer(data), options: options)
        case .sonix:
            // The Sonix Music Driver's scores, with the instruments of the folder beside them.
            guard let folder = companions.first ?? nil else {
                _ = try SonixPlayer.check(data)
                throw Companions.missing(Companions.wanted(for: format, fileName: fileName(path))[0])
            }
            return try PaulaTickRenderer(SonixPlayer(data, instruments: CompanionFolder.unpack(folder)), options: options)
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
            return try PaulaTickRenderer(DeliCustomPlayer(data, name: fileName(path)), options: options)
        case .dl:
            // Dave Lowe's earlier music, his own code with it, hosted in the same way.
            return try PaulaTickRenderer(DaveLoweCodePlayer(data, name: fileName(path)), options: options)
        case .bd:
            // Ben Daglish's drivers, each with its music, run on an Amiga of their own.
            return try PaulaTickRenderer(DaglishPlayer(data), options: options)
        case .core:
            // The composers' own code that Wanted Team's players find and call, each run on an Amiga
            // of its own as their player for EaglePlayer runs it.
            return try PaulaTickRenderer(CoreDesignPlayer(data, name: fileName(path)), options: options)
        case .jmf:
            return try PaulaTickRenderer(JankoMrsicFlogelPlayer(data, name: fileName(path)), options: options)
        case .bds:
            return try PaulaTickRenderer(DaglishSIDPlayer(data, name: fileName(path)), options: options)
        case .gray:
            return try PaulaTickRenderer(FredGrayPlayer(data, name: fileName(path)), options: options)
        case .hd:
            return try PaulaTickRenderer(HowieDaviesPlayer(data, name: fileName(path)), options: options)
        case .spl:
            return try PaulaTickRenderer(SoundProgrammingLanguagePlayer(data, name: fileName(path)), options: options)
        case .dz:
            return try PaulaTickRenderer(DariusZendehPlayer(data, name: fileName(path)), options: options)
        case .mii:
            return try PaulaTickRenderer(MarkIIPlayer(data, name: fileName(path)), options: options)
        case .bss:
            return try PaulaTickRenderer(BeathovenSynthesizerPlayer(data, name: fileName(path)), options: options)
        case .sm:
            return try PaulaTickRenderer(SoundMasterPlayer(data, name: fileName(path)), options: options)
        case .sb:
            return try PaulaTickRenderer(SteveBarrettPlayer(data, name: fileName(path)), options: options)
        case .rh:
            return try PaulaTickRenderer(RobHubbardPlayer(data, name: fileName(path)), options: options)
        case .rho:
            return try PaulaTickRenderer(RobHubbardSTPlayer(data, name: fileName(path)), options: options)
        case .fred:
            return try PaulaTickRenderer(FredMonitorPlayer(data, name: fileName(path)), options: options)
        case .dsr:
            return try PaulaTickRenderer(DesirePlayer(data, name: fileName(path)), options: options)
        case .scumm:
            return try PaulaTickRenderer(ScummPlayer(data, name: fileName(path)), options: options)
        case .scn:
            return try PaulaTickRenderer(SeanConnollyPlayer(data, name: fileName(path)), options: options)
        case .mc:
            return try PaulaTickRenderer(MarkCookseyPlayer(data, name: fileName(path)), options: options)
        case .mcr:
            // Mark Cooksey's replayer of 1988, with its song data beside it, which the player loads by the
            // name it makes of the replayer's.
            let name = fileName(path)
            guard let songs = companions.first ?? nil else {
                guard MarkCooksey.isOne(data) else { throw TuneError.unsupported("not a module of Mark Cooksey's") }
                throw Companions.missing(Companions.wanted(for: format, fileName: name)[0])
            }
            return try PaulaTickRenderer(MarkCookseyPlayer(data, name: name, files: [(Companions.markCookseySongs(of: name), songs)]),
                                         options: options)
        case .jd:
            // Special FX's drivers, each with its music, run on an Amiga of their own.
            return try PaulaTickRenderer(SpecialFXPlayer(data), options: options)
        case .mw:
            // Martin Walker's drivers, each with its music, run on an Amiga of their own.
            return try PaulaTickRenderer(MartinWalkerPlayer(data), options: options)
        case .dln:
            // Dave Lowe's later music, as the players of Flink and Super Street Fighter II had it.
            return try PaulaTickRenderer(DaveLoweNewPlayer(data), options: options)
        case .rjp:
            // Richard Joseph's modules, with their samples from the file beside them.
            guard let samples = companions.first ?? nil else {
                guard RichardJosephPlayer.isOne(data) else { throw TuneError.unsupported("not a Richard Joseph Player module") }
                throw Companions.missing(Companions.wanted(for: format, fileName: fileName(path))[0])
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
        case .mfp:
            // A ProTracker module packed with its samples in a file of their own.
            guard let samples = companions.first ?? nil else {
                throw Companions.missing(Companions.wanted(for: format, fileName: fileName(path))[0])
            }
            return try MODRenderer(MagneticFieldsPacker.module(data, samples: samples), options: options,
                                   origin: "packed by the Magnetic Fields Packer")
        case .agi:
            // A sound from one of Sierra's adventure games, as the Amiga versions played it or on the
            // PC's chip, as the options say.
            return try AGIFile.renderer(data, options: options)
        case .mod:
            // A module of the Amiga's four channels is ProTracker's to play. One of more is a PC
            // tracker's, and FastTracker 2 plays those. (And a MED module that has been named as if
            // it were a MOD file says in its first letters what it is.)
            if data.count > 4, data[0] == 0x4D, data[1] == 0x4D, data[2] == 0x44, data[3] >= 0x30, data[3] <= 0x33 {
                return try MEDRenderer(data, options: options)
            }
            // A module packed for a game or a demo is unpacked into the ProTracker module it was. As
            // libxmp does, a module that says what it is in four letters is taken to be one first, and
            // one of the oldest, which says nothing, only once no packer has taken it.
            func unpacked() throws -> (any Renderer)? {
                guard let (packer, module) = ProWizard.unpack(data) else { return nil }
                return try MODRenderer(module, options: options, origin: "packed by \(packer)")
            }
            // (Startrekker kept its synthesised instruments in a file of their own beside the module,
            // which is no tune, whatever it is named.)
            if data.count >= 16, [UInt8]("ST1.2 ModuleINFO".utf8) == Array(data[0 ..< 16]) || [UInt8]("ST1.3 ModuleINFO".utf8) == Array(data[0 ..< 16])
                || [UInt8]("AudioSculpture10".utf8) == Array(data[0 ..< 16])
            {
                throw TuneError.unsupported("Startrekker's synthesised instruments for the module beside it, and not a tune of its own")
            }
            if ChipTrackerFile.isOne(data) {
                return try MODRenderer(ChipTrackerFile.module(data), options: options, origin: "ChipTracker")
            }
            if AMOSBankFile.isOne(data) {
                return try MODRenderer(AMOSBankFile.module(data), options: options, origin: "an AMOS music bank")
            }
            if !ProTrackerModule.saysWhatItIs(data), let renderer = try unpacked() { return renderer }
            do {
                return try MODRenderer(data, options: options)
            } catch let error as TuneError {
                if case .unsupported = error, let more = try? XMRenderer(data, options: options) { return more }
                if let renderer = try unpacked() { return renderer }
                throw error
            }
        case .med:
            return try MEDRenderer(data, options: options)
        case .sfx:
            return try SoundFXRenderer(data, options: options)
        case .okt:
            return try OktalyzerRenderer(data, options: options)
        case .composer669:
            return try Composer669Renderer(data, options: options)
        case .stm:
            return try STMRenderer(data, options: options)
        case .stx:
            // A Scream Tracker 2 module in another kind of file, read into an STM file.
            return try STXFile.renderer(data, options: options)
        case .far:
            return try FarandoleRenderer(data, options: options)
        case .dbm:
            return try DBMRenderer(data, options: options)
        case .mdl:
            // Digitrakker's, which Impulse Tracker's replayer plays as OpenMPT plays them.
            return try MDLFile.renderer(data, options: options)
        case .j2b:
            // Jazz Jackrabbit 2's, packed with zlib, which OpenMPT reads into the shape of an IT file.
            return try J2BFile.renderer(data, options: options)
        case .dmf:
            // X-Tracker's, which Impulse Tracker's replayer plays as OpenMPT plays them.
            return try DMFFile.renderer(data, options: options)
        case .imf:
            // Imago Orpheus's, which OpenMPT reads into the shape of an IT file: so it is here.
            return try IMFFile.renderer(data, options: options)
        case .ams:
            // Velvet Studio's and Extreme's Tracker's, which OpenMPT reads into the shape of an IT file.
            return try AMSFile.renderer(data, options: options)
        case .plm:
            // Disorder Tracker 2's, likewise.
            return try PLMFile.renderer(data, options: options)
        case .ahx, .hvl:
            // HivelyTracker reads both its own files and AHX's, so a file of either may be found
            // under the other's name. Each says which it is in its first three letters.
            if data.starts(with: [0x48, 0x56, 0x4C]) || (format == .hvl && !data.starts(with: [0x54, 0x48, 0x58])) {
                return try HVLRenderer(data, options: options)
            }
            return try AHXRenderer(data, options: options)
        case .xm:
            return try XMRenderer(data, options: options)
        case .mtm:
            // Three trackers' modules that FastTracker 2's replayer plays, each read into its shape.
            return XMRenderer(try FT2Module(MTMFile.read(data)), options: options)
        case .dtm:
            return XMRenderer(try FT2Module(DTMFile.read(data)), options: options)
        case .amf:
            return XMRenderer(try FT2Module(AMFFile.read(data)), options: options)
        case .digi:
            // DIGI Booster's, which FastTracker 2's replayer plays as OpenMPT plays them.
            return XMRenderer(try FT2Module(DIGIFile.read(data)), options: options)
        case .s3m:
            return try S3MRenderer(data, options: options)
        case .dsm:
            // The Digital Sound Interface Kit's, which Scream Tracker 3's replayer plays as OpenMPT
            // plays them: read into an S3M file.
            return try DSMFile.renderer(data, options: options)
        case .masi:
            // Epic MegaGames' music, likewise. (A file named PSM that begins as one of these is one.)
            return try MASIFile.renderer(data, options: options)
        case .it:
            return try ITRenderer(data, options: options)
        case .gdm:
            // Neither of these two has a replayer of its own here: each is read into the shape of an
            // Impulse Tracker module, and Impulse Tracker's replayer plays it.
            return try GDMFile.renderer(data, options: options)
        case .ptm:
            return try PTMFile.renderer(data, options: options)
        case .ult:
            return try ULTFile.renderer(data, options: options)
        case .c67:
            return try C67File.renderer(data, options: options)
        case .mptm:
            // OpenMPT's own kind of file, which is an IT file with more after it: Impulse Tracker's
            // replayer plays as much of it as it has been taught to.
            return try MPTMFile.renderer(data, options: options)
        case .mt2:
            // MadTracker 2's, which OpenMPT reads into the shape of an IT file: so it is here.
            return try MT2File.renderer(data, options: options)
        case .symmod:
            // Symphonie's, which OpenMPT reads into a module of its own kind: played as an MPTM file is.
            return try SymMODFile.renderer(data, options: options)
        case .cmf:
            return try CMFTune.renderer(data)
        case .rol:
            // Its instruments from the banks found for it, its own first.
            return try ROLTune.renderer(data, banks: companions.compactMap { $0.map { AdLibBank($0) } })
        case .fmt:
            return try FMTTune.renderer(data)
        case .vgm:
            // What was written to the AdLib's or Sound Blaster's FM chip, and when. (A VGZ file has
            // been unpacked above.)
            return try VGMRenderer(data, options: options)
        }
    }

    /// One player per kind of module, each built for its own source type. (Handing `trackerSource`'s
    /// result to a generic player would need the type at run time, which Embedded Swift does not have.)
    /// The last part of a path, the file's own name; empty if there is no path.
    private static func fileName(_ path: String?) -> String {
        guard let path else { return "" }
        return path.utf8.split(separator: 0x2F).last.map { String(decoding: Array($0), as: UTF8.self) } ?? ""
    }

    private static func trackerPlayer(_ data: [UInt8], format: TuneFormat, _ options: LoadOptions) throws -> any Renderer {
        switch format {
        case .pt3: return try AYFramePlayer(source: PT3Source(data), options: options)
        case .pt2: return try AYFramePlayer(source: PT2Source(data), options: options)
        case .pt1: return try AYFramePlayer(source: PT1Source(data), options: options)
        case .stc: return try AYFramePlayer(source: STCSource(data), options: options)
        case .stp: return try AYFramePlayer(source: STPSource(data), options: options)
        case .sqt: return try AYFramePlayer(source: SQTSource(data), options: options)
        case .asc: return try AYFramePlayer(source: ASCSource(data), options: options)
        case .psc: return try AYFramePlayer(source: PSCSource(data), options: options)
        case .ftc: return try AYFramePlayer(source: FTCSource(data), options: options)
        case .fxm: return try AYFramePlayer(source: FXMSource(data), options: options)
        case .psm: return try AYFramePlayer(source: PSMSource(data), options: options)
        case .gtr: return try AYFramePlayer(source: GTRSource(data), options: options)
        default: throw TuneError.unsupported("\(format.rawValue.uppercased()) is not a tracker module format")
        }
    }

    static func trackerSource(_ data: [UInt8], format: TuneFormat) throws -> any AYFrameSource {
        switch format {
        case .pt3: return try PT3Source(data)
        case .pt2: return try PT2Source(data)
        case .pt1: return try PT1Source(data)
        case .stc: return try STCSource(data)
        case .stp: return try STPSource(data)
        case .sqt: return try SQTSource(data)
        case .asc: return try ASCSource(data)
        case .psc: return try PSCSource(data)
        case .ftc: return try FTCSource(data)
        case .fxm: return try FXMSource(data)
        case .psm: return try PSMSource(data)
        case .gtr: return try GTRSource(data)
        default: throw TuneError.unsupported("\(format.rawValue.uppercased()) is not a tracker module format")
        }
    }
}
