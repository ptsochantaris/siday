// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// its ways of reading a sample between its points (`soundlib/IntMixer.h`, `Sndmix.cpp`), with the
// tables of `soundlib/Tables.cpp` and `WindowedFIR.cpp`.

/// How a file of OpenMPT's is read between a sample's points, as OpenMPT reads it. OpenMPT lets
/// whoever writes a tune choose how, and the choice is kept in the file: for the whole song in an MPTM
/// file, and for each instrument in an MPTM or an IT file, where the instrument's own goes before the
/// song's. Some choose to have no smoothing at all, or only a straight line from one point to the
/// next, for the grit that gives a sample played below its own rate; and the tune is heard as they
/// heard it. A file that does not say is read as OpenMPT reads one by itself: through its sinc that
/// is made duller for a fast voice.
struct IT2Resampling {
    /// OpenMPT's numbers for its ways: the point a voice is at, as it is; a straight line between
    /// two points; a curve through four; a sinc of eight, made duller for a voice going faster
    /// through its sample than the sound is made, so that what is too high for the sound is not folded
    /// back into it; a sinc of eight without that; and the mixer's own, which is what a song or an
    /// instrument that does not say has.
    static let nearest: UInt8 = 0, linear: UInt8 = 1, cubic: UInt8 = 2, sincLowPass: UInt8 = 3, sinc: UInt8 = 4, own: UInt8 = 5

    /// The song's way, for a voice whose instrument does not say.
    let song: UInt8
    /// True if the module plays instruments, which may then each have a way of their own.
    let instruments: Bool

    init(_ module: IT2Module) {
        let asked = module.openMPT?.resampling ?? Self.own
        song = asked < Self.own ? asked : Self.sincLowPass
        instruments = module.usesInstruments
    }

    /// Which of the mixer's tables a voice is read through: its own first, and then OpenMPT's
    /// (see `IT2Mixer.openMPTKernels`).
    /// - Parameter speed: how far the voice goes through its sample for every frame of sound, with
    ///   32 bits of fraction.
    @inline(__always)
    func table(_ sc: UnsafeMutablePointer<IT2SlaveChannel>, speed: UInt64) -> Int {
        var way = song
        if instruments, let ins = sc.pointee.InsPtr, ins.Resampling < Self.own { way = ins.Resampling }
        return Self.table(way: way, speed: speed)
    }

    /// The same for a way, by OpenMPT's number for it.
    @inline(__always)
    static func table(way: UInt8, speed: UInt64) -> Int {
        switch way {
        case Self.nearest: return 1
        case Self.linear: return 2
        case Self.cubic: return 3
        // (Faster than 1.1875 times, and than 1.5 times, as OpenMPT has it.)
        case Self.sincLowPass: return speed > 0x1_8000_0000 ? 6 : speed > 0x1_3000_0000 ? 5 : 4
        case Self.sinc: return 7
        default: return 0
        }
    }
}

extension IT2Mixer {
    /// OpenMPT's ways as the mixer's tables, each the weights of the eight samples about a voice's
    /// point for each of 4096 places between two samples, in the order `IT2Resampling.table` gives:
    /// the point itself; the line; OpenMPT's curve, which has 256 places between two samples; its
    /// sinc at its usual 0.97 of the highest a sample can hold, and at 0.5 and 0.425 of it for the
    /// faster voices; and its other sinc, at 0.97, which has another window and is made to add up to
    /// one.
    /// The same, in memory of their own that lasts, for a mixer that reads them a voice at a time.
    nonisolated(unsafe) static let openMPTTables: UnsafePointer<Float> = {
        let tables = UnsafeMutablePointer<Float>.allocate(capacity: openMPTKernels.count)
        for i in openMPTKernels.indices { tables[i] = openMPTKernels[i] }
        return UnsafePointer(tables)
    }()

    static let openMPTKernels: [Float] = {
        var tables = [Float](repeating: 0, count: kernelLength * 3)
        for phase in 0 ..< phases {
            let at = phase * 8
            tables[at + 3] = 1
            let fraction = Float(phase) / Float(phases)
            tables[kernelLength + at + 3] = 1 - fraction
            tables[kernelLength + at + 4] = fraction
            for tap in 0 ..< 4 {
                tables[2 * kernelLength + at + 2 + tap] = Float(openMPTCubic[(phase >> 4) * 4 + tap]) / 16384
            }
        }
        tables += kernel(kaiserBeta: 9.6377, cutoff: 0.97)
        tables += kernel(kaiserBeta: 8.5, cutoff: 0.5)
        tables += kernel(kaiserBeta: 7, cutoff: 0.425)
        tables += windowedFIR(cutoff: 0.97)
        return tables
    }()

    /// OpenMPT's "windowed FIR": a sinc under a window of four cosines (its "Kaiser 4T"), made to add
    /// up to one at every place.
    private static func windowedFIR(cutoff: Double) -> [Float] {
        var lut = [Float](repeating: 0, count: kernelLength)
        for phase in 0 ..< phases {
            let offset = Double(phase) / Double(phases) - 0.5
            var weights = [Double](repeating: 0, count: 8), sum = 0.0
            for tap in 0 ..< 8 {
                let across = Double(tap) - offset
                var x = across - 3.5
                var weight: Double
                if abs(x) < 1e-8 {
                    weight = cutoff
                } else {
                    let w = 2 * Double.pi / 7 * across
                    let window = 0.40243 - 0.49804 * cos(w) + 0.09831 * cos(2 * w) - 0.00122 * cos(3 * w)
                    x *= Double.pi
                    weight = window * sin(cutoff * x) / x
                }
                weights[tap] = weight
                sum += weight
            }
            for tap in 0 ..< 8 { lut[phase * 8 + tap] = Float(weights[tap] / sum) }
        }
        return lut
    }

    /// OpenMPT's curve through four points (it calls it a cubic spline), for 256 places between two
    /// samples: the weights of the point before, the point, and the two after, of 16,384.
    private static let openMPTCubic: [Int16] = [
    0, 16384, 0, 0, -31, 16383, 32, 0, -63, 16381, 65, 0, -93, 16378, 100, -1,
    -124, 16374, 135, -1, -153, 16368, 172, -3, -183, 16361, 209, -4, -211, 16353, 247, -5,
    -240, 16344, 287, -7, -268, 16334, 327, -9, -295, 16322, 368, -12, -322, 16310, 410, -14,
    -348, 16296, 453, -17, -374, 16281, 497, -20, -400, 16265, 541, -23, -425, 16248, 587, -26,
    -450, 16230, 634, -30, -474, 16210, 681, -33, -497, 16190, 729, -37, -521, 16168, 778, -41,
    -543, 16145, 828, -46, -566, 16121, 878, -50, -588, 16097, 930, -55, -609, 16071, 982, -60,
    -630, 16044, 1035, -65, -651, 16016, 1089, -70, -671, 15987, 1144, -75, -691, 15957, 1199, -81,
    -710, 15926, 1255, -87, -729, 15894, 1312, -93, -748, 15861, 1370, -99, -766, 15827, 1428, -105,
    -784, 15792, 1488, -112, -801, 15756, 1547, -118, -818, 15719, 1608, -125, -834, 15681, 1669, -132,
    -850, 15642, 1731, -139, -866, 15602, 1794, -146, -881, 15561, 1857, -153, -896, 15520, 1921, -161,
    -911, 15477, 1986, -168, -925, 15434, 2051, -176, -939, 15390, 2117, -184, -952, 15344, 2184, -192,
    -965, 15298, 2251, -200, -978, 15251, 2319, -208, -990, 15204, 2387, -216, -1002, 15155, 2456, -225,
    -1014, 15106, 2526, -234, -1025, 15055, 2596, -242, -1036, 15004, 2666, -251, -1046, 14952, 2738, -260,
    -1056, 14899, 2810, -269, -1066, 14846, 2882, -278, -1075, 14792, 2955, -287, -1084, 14737, 3028, -296,
    -1093, 14681, 3102, -306, -1102, 14624, 3177, -315, -1110, 14567, 3252, -325, -1118, 14509, 3327, -334,
    -1125, 14450, 3403, -344, -1132, 14390, 3480, -354, -1139, 14330, 3556, -364, -1145, 14269, 3634, -374,
    -1152, 14208, 3712, -384, -1157, 14145, 3790, -394, -1163, 14082, 3868, -404, -1168, 14018, 3947, -414,
    -1173, 13954, 4027, -424, -1178, 13889, 4107, -434, -1182, 13823, 4187, -445, -1186, 13757, 4268, -455,
    -1190, 13690, 4349, -465, -1193, 13623, 4430, -476, -1196, 13555, 4512, -486, -1199, 13486, 4594, -497,
    -1202, 13417, 4676, -507, -1204, 13347, 4759, -518, -1206, 13276, 4842, -528, -1208, 13205, 4926, -539,
    -1210, 13134, 5010, -550, -1211, 13061, 5094, -560, -1212, 12989, 5178, -571, -1212, 12915, 5262, -581,
    -1213, 12842, 5347, -592, -1213, 12767, 5432, -603, -1213, 12693, 5518, -613, -1213, 12617, 5603, -624,
    -1212, 12542, 5689, -635, -1211, 12466, 5775, -645, -1210, 12389, 5862, -656, -1209, 12312, 5948, -667,
    -1208, 12234, 6035, -677, -1206, 12156, 6122, -688, -1204, 12078, 6209, -698, -1202, 11999, 6296, -709,
    -1200, 11920, 6384, -720, -1197, 11840, 6471, -730, -1194, 11760, 6559, -740, -1191, 11679, 6647, -751,
    -1188, 11598, 6735, -761, -1184, 11517, 6823, -772, -1181, 11436, 6911, -782, -1177, 11354, 6999, -792,
    -1173, 11271, 7088, -802, -1168, 11189, 7176, -812, -1164, 11106, 7265, -822, -1159, 11022, 7354, -832,
    -1155, 10939, 7442, -842, -1150, 10855, 7531, -852, -1144, 10771, 7620, -862, -1139, 10686, 7709, -872,
    -1134, 10602, 7798, -882, -1128, 10516, 7886, -891, -1122, 10431, 7975, -901, -1116, 10346, 8064, -910,
    -1110, 10260, 8153, -919, -1103, 10174, 8242, -929, -1097, 10088, 8331, -938, -1090, 10001, 8420, -947,
    -1083, 9915, 8508, -956, -1076, 9828, 8597, -965, -1069, 9741, 8686, -973, -1062, 9654, 8774, -982,
    -1054, 9566, 8863, -991, -1047, 9479, 8951, -999, -1039, 9391, 9039, -1007, -1031, 9303, 9127, -1015,
    -1024, 9216, 9216, -1024, -1015, 9127, 9303, -1031, -1007, 9039, 9391, -1039, -999, 8951, 9479, -1047,
    -991, 8863, 9566, -1054, -982, 8774, 9654, -1062, -973, 8686, 9741, -1069, -965, 8597, 9828, -1076,
    -956, 8508, 9915, -1083, -947, 8420, 10001, -1090, -938, 8331, 10088, -1097, -929, 8242, 10174, -1103,
    -919, 8153, 10260, -1110, -910, 8064, 10346, -1116, -901, 7975, 10431, -1122, -891, 7886, 10516, -1128,
    -882, 7798, 10602, -1134, -872, 7709, 10686, -1139, -862, 7620, 10771, -1144, -852, 7531, 10855, -1150,
    -842, 7442, 10939, -1155, -832, 7354, 11022, -1159, -822, 7265, 11106, -1164, -812, 7176, 11189, -1168,
    -802, 7088, 11271, -1173, -792, 6999, 11354, -1177, -782, 6911, 11436, -1181, -772, 6823, 11517, -1184,
    -761, 6735, 11598, -1188, -751, 6647, 11679, -1191, -740, 6559, 11760, -1194, -730, 6471, 11840, -1197,
    -720, 6384, 11920, -1200, -709, 6296, 11999, -1202, -698, 6209, 12078, -1204, -688, 6122, 12156, -1206,
    -677, 6035, 12234, -1208, -667, 5948, 12312, -1209, -656, 5862, 12389, -1210, -645, 5775, 12466, -1211,
    -635, 5689, 12542, -1212, -624, 5603, 12617, -1213, -613, 5518, 12693, -1213, -603, 5432, 12767, -1213,
    -592, 5347, 12842, -1213, -581, 5262, 12915, -1212, -571, 5178, 12989, -1212, -560, 5094, 13061, -1211,
    -550, 5010, 13134, -1210, -539, 4926, 13205, -1208, -528, 4842, 13276, -1206, -518, 4759, 13347, -1204,
    -507, 4676, 13417, -1202, -497, 4594, 13486, -1199, -486, 4512, 13555, -1196, -476, 4430, 13623, -1193,
    -465, 4349, 13690, -1190, -455, 4268, 13757, -1186, -445, 4187, 13823, -1182, -434, 4107, 13889, -1178,
    -424, 4027, 13954, -1173, -414, 3947, 14018, -1168, -404, 3868, 14082, -1163, -394, 3790, 14145, -1157,
    -384, 3712, 14208, -1152, -374, 3634, 14269, -1145, -364, 3556, 14330, -1139, -354, 3480, 14390, -1132,
    -344, 3403, 14450, -1125, -334, 3327, 14509, -1118, -325, 3252, 14567, -1110, -315, 3177, 14624, -1102,
    -306, 3102, 14681, -1093, -296, 3028, 14737, -1084, -287, 2955, 14792, -1075, -278, 2882, 14846, -1066,
    -269, 2810, 14899, -1056, -260, 2738, 14952, -1046, -251, 2666, 15004, -1036, -242, 2596, 15055, -1025,
    -234, 2526, 15106, -1014, -225, 2456, 15155, -1002, -216, 2387, 15204, -990, -208, 2319, 15251, -978,
    -200, 2251, 15298, -965, -192, 2184, 15344, -952, -184, 2117, 15390, -939, -176, 2051, 15434, -925,
    -168, 1986, 15477, -911, -161, 1921, 15520, -896, -153, 1857, 15561, -881, -146, 1794, 15602, -866,
    -139, 1731, 15642, -850, -132, 1669, 15681, -834, -125, 1608, 15719, -818, -118, 1547, 15756, -801,
    -112, 1488, 15792, -784, -105, 1428, 15827, -766, -99, 1370, 15861, -748, -93, 1312, 15894, -729,
    -87, 1255, 15926, -710, -81, 1199, 15957, -691, -75, 1144, 15987, -671, -70, 1089, 16016, -651,
    -65, 1035, 16044, -630, -60, 982, 16071, -609, -55, 930, 16097, -588, -50, 878, 16121, -566,
    -46, 828, 16145, -543, -41, 778, 16168, -521, -37, 729, 16190, -497, -33, 681, 16210, -474,
    -30, 634, 16230, -450, -26, 587, 16248, -425, -23, 541, 16265, -400, -20, 497, 16281, -374,
    -17, 453, 16296, -348, -14, 410, 16310, -322, -12, 368, 16322, -295, -9, 327, 16334, -268,
    -7, 287, 16344, -240, -5, 247, 16353, -211, -4, 209, 16361, -183, -3, 172, 16368, -153,
    -1, 135, 16374, -124, -1, 100, 16378, -93, 0, 65, 16381, -63, 0, 32, 16383, -31,
    ]
}
