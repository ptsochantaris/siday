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
    case core, jmf, bds, gray, hd, spl, dz, mii, bss, sm, sb, rh, rho, fred, dsr, scumm, scn, mc, mcr, jo, dns, kh, scr, wb, md, jcb, ash, tw
    case dum, ex, pvp, alp, dsc, bye, ems, fw, lme, jam, amc, psa, tme, jpo, cin, ps, sjs, dat, thm, psf, sdr, uds, tf, snk, ast, dh

    /// The format a file name's extension stands for, in any case: its own name (`TuneFormat.rawValue`),
    /// or one of the other names files of it are kept under (`otherNames`).
    public init?(fileExtension: String) {
        let name = fileExtension.lowercased()
        if let format = Self.otherNames[name] {
            self = format
        } else if name == "masi" {
            // (Epic MegaGames' files are named PSM, and found to be theirs by how they begin.)
            return nil
        } else {
            self.init(rawValue: name)
        }
    }

    /// The endings of the names of files packed by the packers that `ProWizard` unpacks, as UnExoticA and
    /// others name them.
    static let packedModuleNames: Set<String> = [
        "ac1d", "ntp", "prun", "pru1", "pru2", "pha", "tp3", "di", "p4x", "p40a", "p40b", "p41a",
        "pp21", "pp30", "p50a", "p60", "p60a", "p6x", "p61", "p61a", "np1", "np2", "np3", "gmc", "pro", "pr1", "pm1", "pm18a", "st26", "ice", "chan",
    ]

    /// The names other than their own that files of a format are kept under, as their extensions.
    static let otherNames: [String: TuneFormat] = {
        var names: [String: TuneFormat] = [
            // (A MED module is as often named for the four letters it begins with as it is called MED.)
            "mmd0": .med, "mmd1": .med, "mmd2": .med, "mmd3": .med, "mmdc": .med,
            // (A VGM file packed by gzip, which is how they are mostly kept.)
            "vgz": .vgm,
            // (SidMon's, by the Amiga's name for them; one named SID is found by how it begins.)
            "smn": .sid1,
            // (Digital Mugician's, either of its two.)
            "mug2": .mug, "dmu": .mug, "dmu2": .mug,
            "dlm2": .dm2,
            // (Sonic Arranger's, by the names the Amiga's players knew them by.)
            "sonic": .sa, "sa-p": .sa, "lion": .sa, "sa_old": .sa,
            // (DeliTracker's custom modules, by the other names they are kept under.)
            "cus": .cust, "custom": .cust,
            // (Martin Walker's, and David Whittaker's, by the other names UADE knows them by.)
            "avp": .mw, "dwold": .dw,
            // (The Sonix Music Driver's scores, of its three kinds.)
            "smus": .sonix, "snx": .sonix, "tiny": .sonix,
            // (SoundMon's, as the Amiga's players named them: bp3 for 2.2's.)
            "bp3": .bp, "sndmon": .bp,
            // (TFMX's notes, named for its file of them, which the samples are beside; or a module
            // of one file.)
            "mdat": .tfmx, "tfx": .tfmx, "tfm": .tfmx,
            // (Jochen Hippel's, by the names they are kept under: compressed, of seven voices, or
            // with his player before them.)
            "hipc": .hip, "hip7": .hip, "sog": .hip, "soc": .hip, "s7g": .hip, "mcmd": .hip,
            // (Future Composer's, by its versions.)
            "fc13": .fc, "fc14": .fc, "fc3": .fc, "fc4": .fc, "smod": .fc,
            // (As SNDH files were named before the format had a name of its own.)
            "snd": .sndh,
            // (One of ChipTracker's, or an AMOS music bank, which are read into a module.)
            "kris": .mod, "abk": .mod,
        ]
        // (A module packed by one of the packers games and demos used, named for the packer, which
        // is read into a module; but for Game Music Creator's, which ProWizard would make a
        // ProTracker module of, but which is played by its own player.)
        for name in packedModuleNames where name != "gmc" { names[name] = .mod }
        return names
    }()

    /// Every extension a tune's file can have, in lower case, in order: each format's own name, and
    /// the other names files of it are kept under. (MASI's own name is not one: its files are PSM files.)
    public static var fileExtensions: [String] {
        (allCases.filter { $0 != .masi }.map { $0.rawValue } + otherNames.keys).sorted()
    }

    /// True for a kind of the Amiga's music whose file is the composer's own code, played as Wanted Team's
    /// player of it for EaglePlayer plays it, by the recipe they share (`WantedTeamPlayer`).
    public var isWantedTeamCode: Bool {
        switch self {
        case .core, .jmf, .bds, .gray, .hd, .spl, .dz, .mii, .bss, .sm, .sb, .rh, .rho, .fred, .dsr, .scumm, .scn, .mc, .mcr, .jo, .dns, .kh, .scr, .wb, .md, .jcb, .ash, .tw: true
        default: false
        }
    }

    /// True for a kind of the Amiga's music played by a port of a game's own player, or of the player
    /// for EaglePlayer or DeliTracker that took its place (Infogrames', Fashion Tracker's and the rest).
    public var isPortedGamePlayer: Bool {
        switch self {
        case .dum, .ex, .pvp, .alp, .dsc, .bye, .ems, .fw, .lme, .jam, .amc, .psa, .tme, .jpo, .cin, .ps, .sjs, .dat, .thm, .psf, .sdr, .uds, .tf, .snk, .ast, .dh: true
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
        case .jmf, .bds, .gray, .hd, .spl, .dz, .mii, .bss, .sm, .sb, .rh, .rho, .fred, .dsr, .scumm, .scn, .mc, .mcr, .jo, .dns, .kh, .scr, .wb, .md, .jcb, .ash, .tw: "CORE"
        case .ex, .pvp, .alp, .dsc, .bye, .ems, .fw, .lme, .jam, .amc, .psa, .tme, .jpo, .cin, .ps, .sjs, .dat, .thm, .psf, .sdr, .uds, .tf, .snk, .ast, .dh: "DUM"
        case .mtm, .dtm, .amf: "MTM"
        case .gdm, .ptm: "GDM"
        case .stx: "STM"
        default: rawValue.uppercased()
        }
    }
}
