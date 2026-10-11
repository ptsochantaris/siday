// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Testing

// OpenMPT's own effects, which a file of ModPlug Tracker's or OpenMPT's is heard through. Each is
// set here beside what OpenMPT's own class gives for the same made-up sound: the numbers below are
// from libopenmpt 0.8.9's classes, compiled so that every multiplication and addition is rounded on
// its own, as Swift rounds them. The thorough checks are made outside the package, over thousands of
// settings and every setting the files to hand keep.

/// A case: an effect as made, or with these settings, or restored from these bytes; a second of one
/// of two made-up sounds; and twelve frames of what OpenMPT's class makes of it.
private struct Golden {
    let make: () -> OpenMPTEffect
    let settings: [Float], chunk: [UInt8]
    let noise: Bool
    let frames: [(frame: Int, left: Float, right: Float)]
}

/// A second of sound that is the same wherever it is made: two saws of different lengths, or noise
/// from a rule.
private func madeUpSound(noise: Bool) -> (left: [Float], right: [Float]) {
    var left = [Float](repeating: 0, count: 48000), right = left
    var state: UInt32 = 1
    for n in 0 ..< 48000 {
        if noise {
            state = state &* 1_664_525 &+ 1_013_904_223
            left[n] = Float(Int32(bitPattern: state) >> 8) / 16_777_216
            state = state &* 1_664_525 &+ 1_013_904_223
            right[n] = Float(Int32(bitPattern: state) >> 8) / 16_777_216
        } else {
            left[n] = Float((n * 37) % 201 - 100) / 200
            right[n] = Float((n * 53) % 157 - 78) / 200
        }
    }
    return (left, right)
}

private func played(_ effect: OpenMPTEffect, _ sound: (left: [Float], right: [Float]), block: Int = 512) -> (left: [Float], right: [Float]) {
    var left = [Float](repeating: 0, count: sound.left.count), right = left
    var done = 0
    while done < left.count {
        let count = min(block, left.count - done)
        sound.left.withUnsafeBufferPointer { inL in
            sound.right.withUnsafeBufferPointer { inR in
                left.withUnsafeMutableBufferPointer { outL in
                    right.withUnsafeMutableBufferPointer { outR in
                        effect.process(inLeft: inL.baseAddress! + done, inRight: inR.baseAddress! + done, outLeft: outL.baseAddress! + done,
                                       outRight: outR.baseAddress! + done, frames: count)
                    }
                }
            }
        }
        done += count
    }
    return (left, right)
}

private func goldenCases() -> [Golden] { [
    Golden(make: { OpenMPTEcho() }, settings: [], chunk: [], noise: false,
           frames: [(157, 0.202500001, -0.194999993), (4710, -0.242500007, -0.194999993), (8241, -0.25, 0.194999993), (12560, -0.230000004, -0.194999993), (16248, 0.215000004, 0.194999993), (20410, -0.217500001, -0.194999993), (25120, -0.352894187, -0.333564043), (28260, -0.343564063, -0.333564043), (33127, -0.422870159, -0.333564043), (36267, -0.413540006, -0.333564043), (40977, -0.399544835, -0.333564043), (44117, -0.390214682, -0.333564043)]),
    Golden(make: { OpenMPTEcho() }, settings: [0.75, 0.625, 0.0625, 0.125, 1], chunk: [], noise: false,
           frames: [(157, 0.10125, -0.0974999964), (6068, 0.125, -0.167649165), (8681, 0.125, -0.148899168), (15650, 0.312905371, -0.316719443), (18769, 0.324638903, -0.326169252), (20893, 0.324182183, -0.325712502), (24125, 0.316652775, -0.330196977), (28210, 0.300950319, -0.303363413), (35592, -0.283521742, -0.398975164), (36451, 0.311601937, -0.305013657), (42671, 0.309325635, -0.307242692), (46262, 0.311325401, -0.328410983)]),
    Golden(make: { OpenMPTChorus() }, settings: [], chunk: [], noise: false,
           frames: [(3368, 0.361117482, 0.30782643), (6227, -0.369184732, -0.358173192), (8795, 0.314762294, -0.362902373), (14744, -0.29974246, -0.302618682), (19628, -0.381246865, -0.317482054), (22712, 0.356591523, -0.380756885), (24723, -0.389007151, 0.347588032), (29987, 0.342593431, -0.332672), (34866, -0.292898655, -0.312891126), (39917, 0.324559838, -0.331166029), (43356, 0.299044609, -0.312176883), (47278, 0.312794685, -0.299818158)]),
    Golden(make: { OpenMPTChorus() }, settings: [0.75, 0.5, 0.875, 0, 0.25, 0.875, 0.375], chunk: [], noise: false,
           frames: [(684, 0.346713483, 0.346403062), (5848, -0.298165143, -0.270952523), (8653, 0.325418741, -0.308857083), (12119, 0.3476125, -0.305727124), (17187, 0.337327182, 0.405510843), (22521, 0.347749352, -0.301157147), (27763, 0.288020015, -0.383029133), (31101, -0.279854536, -0.273906618), (34925, 0.288582504, 0.283715755), (38809, 0.322820246, -0.319681287), (43400, -0.292450875, 0.320916116), (46750, 0.379726022, 0.365459085)]),
    Golden(make: { OpenMPTFlanger(legacy: false) }, settings: [], chunk: [], noise: false,
           frames: [(1279, -0.531061888, -0.409440875), (5142, -0.469276488, -0.361021042), (8987, 0.309745073, -0.365508556), (15202, -0.40426752, -0.336359978), (19755, -0.344253302, -0.344675243), (21446, -0.366313666, -0.278353333), (25019, -0.494378, -0.340665042), (31305, -0.443399996, -0.34319514), (35476, -0.307328045, -0.313654691), (38861, -0.472770214, -0.40019542), (41676, -0.403549552, -0.323491216), (47025, 0.236044735, -0.217756301)]),
    Golden(make: { OpenMPTFlanger(legacy: false) }, settings: [0.75, 0, 0.875, 0.5, 0.75, 0.125, 0.625], chunk: [], noise: false,
           frames: [(367, -0.539994478, -0.470528901), (7085, 0.553951979, -0.461361259), (11152, -0.643409133, -0.455886424), (12112, -0.832949758, -0.445423603), (18608, 0.585160136, -0.469163358), (22536, -0.855760336, -0.475396961), (24503, -0.627583325, -0.449608564), (29989, -0.544638395, -0.467874616), (34788, -0.551266193, -0.474018574), (39267, 0.557975173, -0.456772596), (40135, -0.685567558, -0.442077398), (44205, -0.709863782, -0.459612489)]),
    Golden(make: { OpenMPTFlanger(legacy: true) }, settings: [], chunk: [], noise: false,
           frames: [(3733, -0.407967806, -0.365467817), (7068, -0.42392391, -0.401423931), (11660, -0.323680729, -0.383680731), (14527, -0.337239325, -0.337239325), (18340, -0.48754245, -0.360042453), (23056, -0.43833679, -0.360836804), (27798, -0.388784409, -0.341284424), (28880, -0.404925466, -0.342425466), (35328, -0.429294109, -0.451794118), (37127, -0.371880531, -0.354380548), (41531, -0.380951315, -0.32345131), (47017, 0.294929475, 0.297429472)]),
    Golden(make: { OpenMPTFlanger(legacy: true) }, settings: [0.75, 0, 0.875, 0.5, 0.75, 0.125, 0.625], chunk: [], noise: false,
           frames: [(1874, 0.522365332, -0.549494565), (4663, -0.574199319, -0.514517188), (11565, 0.489929736, -0.531983376), (15908, -0.560238123, -0.577552915), (18515, -0.608779192, -0.597588241), (21261, -0.509120464, -0.55822587), (25103, 0.514235377, -0.531141996), (29212, -0.498003364, -0.570478439), (33965, -0.582991838, 0.490868926), (37583, -0.622479081, -0.501134694), (43081, -0.499551117, -0.496023864), (44244, -0.585770428, 0.476786137)]),
    Golden(make: { OpenMPTGargle() }, settings: [], chunk: [], noise: false,
           frames: [(1179, -0.455183893, -0.372863382), (5726, -0.454763591, 0.375674248), (10359, 0.359378278, 0.359378278), (12560, -0.457180411, -0.387609452), (19388, 0.426900148, 0.378388792), (23941, -0.429903656, 0.372583181), (26299, -0.382828325, -0.3779203), (28574, 0.391195297, -0.386243433), (33127, -0.49283275, -0.388292462), (39955, 0.393651456, 0.379071802), (42313, 0.448712766, -0.371514857), (46866, -0.416440457, -0.377246052)]),
    Golden(make: { OpenMPTGargle() }, settings: [0.125, 1], chunk: [], noise: false,
           frames: [(157, 0.405000001, -0.389999986), (4710, -0.485000014, -0.389999986), (8398, 0.405000001, 0.389999986), (12560, -0.460000008, -0.389999986), (17270, -0.444999993, -0.389999986), (20567, 0.469999999, -0.389999986), (25120, -0.419999987, -0.389999986), (28260, -0.409999996, -0.389999986), (33127, -0.495000005, -0.389999986), (36267, -0.485000014, -0.389999986), (41134, 0.435000002, -0.389999986), (44117, -0.460000008, -0.389999986)]),
    Golden(make: { OpenMPTDigiBoosterEcho() }, settings: [], chunk: [], noise: false,
           frames: [(157, 0.278437495, -0.268124998), (7850, -0.337621689, -0.294590235), (9186, 0.305799872, -0.300172418), (12326, 0.312679946, -0.298883528), (17427, 0.304779291, -0.287063003), (20567, 0.312411606, -0.285774112), (27706, -0.281936973, 0.279641211), (31791, -0.315893024, 0.282319367), (34931, -0.308006167, 0.284045309), (38071, -0.30011934, 0.285771251), (41211, -0.287063658, 0.286688626), (47882, -0.290047854, 0.280556709)]),
    Golden(make: { OpenMPTDigiBoosterEcho() }, settings: [], chunk: [69, 99, 104, 111, 20, 200, 100, 64], noise: false,
           frames: [(3531, 0.307886362, 0.256134629), (5101, 0.323770642, 0.251234651), (8241, -0.276195645, 0.25008738), (12951, -0.263246477, 0.247786179), (19231, -0.255704075, 0.253557265), (20801, -0.252448708, 0.253656), (27472, -0.256655306, 0.251150727), (29042, -0.2534675, 0.251317054), (35713, -0.257341385, 0.248483628), (38228, 0.335241199, 0.248502493), (42938, -0.267257124, 0.248641253), (47648, -0.257535428, 0.248981908)]),
    Golden(make: { OpenMPTWavesReverb() }, settings: [1, 0.850000024, 0.5, 0.25], chunk: [], noise: true,
           frames: [(17, 0.381465346, -0.443672299), (600, -0.102410071, -0.285292208), (1501, -0.198649108, -0.354784667), (3000, -0.288814485, -0.222366259), (5000, 0.0903038606, -0.195100367), (9000, 0.426704615, 0.212644488), (14000, 0.10376858, 0.199903563), (20000, -0.469761103, 0.422233433), (27000, -0.103686921, 0.247411922), (35000, -0.178247854, -0.206388742), (42000, 0.320710272, 0.148001164), (47900, -0.257825971, 0.138302103)]),
    Golden(make: { OpenMPTI3DL2Reverb() }, settings: [0.949999988, 0.899999976, 0, 0.100000001, 0.400000006, 0.699999988, 0.0500000007, 0.899999976, 0.200000003, 0.800000012, 0.699999988, 0.25, 1], chunk: [], noise: true,
           frames: [(1930, 0.0315623879, -0.0291978996), (1931, 0.0344515182, -0.0322994478), (2107, -0.0368018039, 0.0294048991), (3007, 0.0495218076, 0.0346600562), (5007, -0.0342088975, -0.0339801721), (9000, -0.0479687229, 0.0445951447), (14004, -0.0377302207, -0.0681056604), (20000, 0.0321053937, -0.0905058011), (27000, -0.11008545, -0.0433339961), (35002, -0.0332055986, -0.0506419614), (42000, -0.0623156652, 0.10718289), (47906, -0.0369372666, 0.136909708)]),
    Golden(make: { OpenMPTI3DL2Reverb() }, settings: [0.949999988, 0.899999976, 0, 0.100000001, 0.400000006, 0.699999988, 0.0500000007, 0.899999976, 0.200000003, 0.800000012, 0.699999988, 0.25, 0], chunk: [], noise: true,
           frames: [(2655, 0.0752350166, -0.118480563), (2712, 0.0705532581, -0.057299383), (2713, 0.073182337, -0.0744005814), (3045, -0.0643448755, 0.071408011), (5024, -0.0913854837, -0.0624281019), (9001, -0.0679442212, 0.171385661), (14000, -0.100496642, 0.125041366), (20006, -0.139191329, 0.0634705126), (27000, 0.0637529194, -0.136546671), (35004, -0.0741311014, -0.0777990818), (42000, -0.133630052, 0.0757406056), (47908, 0.0722471625, 0.0836410299)]),
    Golden(make: { OpenMPTDistortion() }, settings: [0.800000012, 0.5, 0.600000024, 0.300000012, 0.400000006], chunk: [], noise: true,
           frames: [(19, -0.259127676, -0.167598307), (600, 1.2610265, -1.24393511), (1500, 1.26022196, 0.611381412), (3000, -1.04950404, 0.9434129), (5000, 0.870023489, -1.31049681), (9000, -1.2681998, -0.830118299), (14000, 0.966072202, 0.942542791), (20000, 0.710848093, 1.17475998), (27000, 0.213344693, 1.21680605), (35000, -1.21145976, 1.26055539), (42000, -1.28066921, 1.19074655), (47900, -0.595134914, -1.29338205)]),
    Golden(make: { OpenMPTParamEq() }, settings: [0.300000012, 0.5, 0.800000012], chunk: [], noise: true,
           frames: [(17, 0.655180931, -0.625198185), (600, -0.471190631, -0.303907633), (1500, 0.369530976, 0.363963127), (3000, -0.511679292, -0.27696076), (5001, 0.475235999, 0.153559595), (9000, 0.512100279, 0.146602273), (14001, 0.129653156, -0.861299813), (20000, -1.03756714, 0.182199448), (27002, -0.379423171, 0.500335336), (35003, -0.527974606, 0.580258787), (42000, 0.463207185, 0.633006573), (47900, -0.528992414, 0.221510306)]),
    Golden(make: { OpenMPTCompressor() }, settings: [0.600000024, 0.100000001, 0.200000003, 0.400000006, 0.5, 0.5], chunk: [], noise: true,
           frames: [(16, 1.04681277, -0.991664469), (601, -1.48385859, 1.40488112), (1500, 1.53635335, -0.605561972), (3000, 0.70536381, -0.596439004), (5010, 0.308023572, -0.283679545), (9007, -0.210299239, -0.208939105), (14009, -0.203077197, 0.207293287), (20039, -0.214611366, -0.208052278), (27020, -0.207768679, 0.201386675), (35238, 0.211160138, 0.214916736), (42084, -0.200050086, 0.209883049), (47954, 0.217070431, -0.204764143)]),
] }

@Test func openMPTEffectsGiveWhatOpenMPTsOwnGive() {
    for (number, one) in goldenCases().enumerated() {
        let effect = one.make()
        if !one.chunk.isEmpty { #expect(effect.restore(chunk: one.chunk)) }
        for (index, value) in one.settings.enumerated() { effect.setParameter(index, value) }
        effect.resume()
        let sound = played(effect, madeUpSound(noise: one.noise))
        for frame in one.frames {
            #expect(sound.left[frame.frame] == frame.left && sound.right[frame.frame] == frame.right, "case \(number), frame \(frame.frame)")
        }
    }
}

@Test func openMPTEffectsGiveTheSameHoweverTheSoundIsCut() {
    // A mixer gives an effect a tick at a time, of whatever length the tempo makes it.
    for one in goldenCases() {
        let whole = one.make(), cut = one.make()
        for effect in [whole, cut] {
            if !one.chunk.isEmpty { _ = effect.restore(chunk: one.chunk) }
            for (index, value) in one.settings.enumerated() { effect.setParameter(index, value) }
            effect.resume()
        }
        let sound = madeUpSound(noise: one.noise)
        #expect(played(whole, sound).left == played(cut, sound, block: 333).left)
    }
}

@Test func openMPTEffectsTakeAnySettingAndAnySound() {
    // A setting can be anything a file has in it, and so can the sound: nothing traps, and what is
    // not a number goes in as nought.
    let wild: [Float] = [-3, 0, 0.5, 1, 7, .nan, .infinity, -.infinity, 1e30]
    for one in goldenCases() {
        let effect = one.make()
        for index in -2 ..< effect.parameterCount + 3 {
            for value in wild {
                effect.setParameter(index, value)
                if index >= 0, index < effect.parameterCount { #expect(effect.parameter(index) >= 0 && effect.parameter(index) <= 1) }
            }
        }
        _ = effect.restore(chunk: [])
        _ = effect.restore(chunk: [UInt8](repeating: 0xFF, count: 9))
        effect.resume()
        _ = played(effect, madeUpSound(noise: true))
        _ = played(effect, ([.nan, 1e30, -1e30, 0], [0, .infinity, 2, -2]), block: 3)
    }
}

// MARK: Which plug-in

@Test func plugInIsFoundAsOpenMPTFindsIt() {
    func kind(_ first: UInt32, _ second: UInt32, _ name: String) -> ModPlugPlugIn.Kind? {
        var plugIn = ModPlugPlugIn()
        plugIn.first = first
        plugIn.second = second
        plugIn.libraryName = name
        return plugIn.kind
    }
    let dmo: UInt32 = 0x4458_4D4F
    #expect(kind(dmo, 0xEF3E_932C, "Echo") == .echo && kind(dmo, 0x87FC_0268, "WavesReverb") == .wavesReverb)
    // The two flangers have the same numbers, and are told apart by name; with any other name it is the newer.
    #expect(kind(dmo, 0xEFCA_3D92, "Flanger") == .flanger && kind(dmo, 0xEFCA_3D92, "flanger (legacy)") == .flangerLegacy)
    #expect(kind(dmo, 0xEFCA_3D92, "") == .flanger)
    // By its numbers alone, or by its name alone.
    #expect(kind(dmo, 0xEF01_1F79, "something else") == .compressor && kind(1, 2, "ParamEq") == .paramEq)
    #expect(kind(0x304D_4244, 0x6F68_6345, "DigiBooster Pro Echo") == .digiBoosterEcho)
    // Somebody else's program, and no program at all.
    let neither = kind(0x5673_7450, 0x1234_5678, "Classic Reverb")
    #expect(neither == nil)
    let empty = ModPlugPlugIn()
    #expect(!empty.isThere)
    #expect(empty.makeEffect() == nil)
}

@Test func plugInIsReadFromAFileThatMayEndAnywhere() {
    func long(_ value: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) } }
    var piece = long(0x4458_4D4F) + long(0xEF3E_932C) + [0x15, 2, 20, 0] + long(0x83) + [UInt8](repeating: 0, count: 16)
    piece += Array("mine".utf8) + [UInt8](repeating: 0, count: 28) + Array("Echo".utf8) + [UInt8](repeating: 0, count: 60)
    let settings: [Float] = [0.25, 0.5, 0.125, 0.75, 1]
    piece += long(24) + long(0) + settings.flatMap { long($0.bitPattern) }
    piece += long(16) + Array("PROG".utf8) + long(7) + Array("DWRT".utf8) + long(Float(0.375).bitPattern)
    let whole = ModPlugPlugIn([9, 9] + piece + [9], at: 2, size: piece.count)
    #expect(whole.isThere && whole.kind == .echo && whole.name == "mine" && whole.libraryName == "Echo" && whole.title == "Echo")
    #expect(whole.routingFlags == 0x15 && whole.mixMode == 2 && whole.gain == 20 && whole.outputRouting == 0x83 && whole.dryRatio == 0.375)
    let effect = whole.makeEffect()
    #expect(effect != nil)
    for index in 0 ..< 5 { #expect(effect?.parameter(index) == settings[index]) }
    // Cut short anywhere, or said to be longer than it is, it is read as far as it goes.
    for length in 0 ..< piece.count {
        let cut = ModPlugPlugIn(Array(piece[..<length]), at: 0, size: piece.count + 100)
        _ = cut.makeEffect()
        let whole = length >= 8
        #expect(whole || cut.second != 0xEF3E_932C)
    }
    // (Settings that are not all there are not taken: the effect is as made.)
    let short = ModPlugPlugIn(Array(piece[..<(128 + 4 + 12)]), at: 0, size: piece.count)
    let asMade = short.makeEffect()?.parameter(0)
    #expect(asMade == 0.5)
}
