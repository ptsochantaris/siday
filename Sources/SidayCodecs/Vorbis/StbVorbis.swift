// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from stb_vorbis 1.22 by Sean Barrett and its contributors, in the public domain (or under the
// MIT licence, at the user's choice): the copy libopenmpt 0.8.9 ships, built as libopenmpt builds it,
// with STB_VORBIS_NO_PULLDATA_API and STB_VORBIS_NO_STDIO. That leaves the push-data decoder, which is
// given its bytes each time and keeps none of its own, and that is what this is. The names are the
// original's, made Swift's own way, and each function says which one it is.
//
// It decodes what the original decodes, to the bit: the same sums are made in the same order, on
// floats where it has floats and on doubles where it has doubles, and its integers wrap where the
// original's do. The two can part only on streams made to break them: where the original would read
// or write outside its memory, this one stops with an error or reads a zero; and a stream whose setup
// asks for more than 256 MB is turned away for want of memory, where the original would ask malloc.

import SidayFoundation

/// The C library's ldexp, which stb_vorbis unpacks a codebook's floats with.
@_extern(c, "ldexp") private func ldexp(_ x: Double, _ exponent: Int32) -> Double

/// stb_vorbis's error codes (enum STBVorbisError), as it numbers them.
enum StbVorbisError {
    static let noError: Int32 = 0
    static let needMoreData: Int32 = 1
    static let invalidApiMixing: Int32 = 2
    static let outOfMemory: Int32 = 3
    static let featureNotSupported: Int32 = 4
    static let tooManyChannels: Int32 = 5
    static let unexpectedEOF: Int32 = 10
    static let invalidSetup: Int32 = 20
    static let invalidStream: Int32 = 21
    static let missingCapturePattern: Int32 = 30
    static let invalidStreamStructureVersion: Int32 = 31
    static let continuedPacketFlagInvalid: Int32 = 32
    static let invalidFirstPage: Int32 = 34
    static let badPacketType: Int32 = 35
    static let oggSkeletonNotSupported: Int32 = 38
}

// The original's settings, as libopenmpt leaves them.
private let maxChannels = 16 // STB_VORBIS_MAX_CHANNELS
private let pushdataCRCCount: Int32 = 4 // STB_VORBIS_PUSHDATA_CRC_COUNT
private let fastHuffmanLength: Int32 = 10 // STB_VORBIS_FAST_HUFFMAN_LENGTH
private let fastHuffmanTableSize = 1 << 10
private let fastHuffmanTableMask: UInt32 = 1023
/// The code length of a value with no code.
private let noCode: UInt8 = 255
/// What a read past the end of a packet gives.
private let EOP: Int32 = -1
private let invalidBits: Int32 = -1

private let pageflagContinuedPacket: UInt8 = 1
private let pageflagFirstPage: UInt8 = 2
private let pageflagLastPage: UInt8 = 4

private let packetID: Int32 = 1, packetComment: Int32 = 3, packetSetup: Int32 = 5

/// M_PI as the C library's header has it, a double.
private let Mpi = 3.14159265358979323846264338327950288

/// The most memory a stream's setup may take. The original takes what its codebooks ask for, and a
/// stream of a few bytes can ask for gigabytes; the streams that are music need a few hundred
/// kilobytes. A stream that asks for more than this is turned away as the original turns away one
/// it cannot find the memory for (VORBIS_outofmem).
private let setupMemoryLimit = 256 << 20

/// A codebook (Codebook). Its tables are the stream's own memory, kept by the decoder.
struct VorbisCodebook {
    var dimensions: Int32 = 0, entries: Int32 = 0
    var codewordLengths: UnsafeMutablePointer<UInt8>?
    var minimumValue: Float = 0
    var deltaValue: Float = 0
    var valueBits: UInt8 = 0
    var lookupType: UInt8 = 0
    var sequenceP: UInt8 = 0
    var sparse: UInt8 = 0
    var lookupValues: UInt32 = 0
    var multiplicands: UnsafeMutablePointer<Float>?
    var codewords: UnsafeMutablePointer<UInt32>?
    var fastHuffman: UnsafeMutablePointer<Int16>?
    var sortedCodewords: UnsafeMutablePointer<UInt32>?
    /// One past the start of its memory, so that `sortedValues[-1]` is there (and is -1).
    var sortedValues: UnsafeMutablePointer<Int32>?
    var sortedEntries: Int32 = 0
    /// Not the original's: the symbols at 32767 and above that have codes, in order, for a codebook
    /// that the original searches from end to end when the quick table has no answer (see
    /// `codebookDecodeScalarRaw`). There are at most 1024 of them, where the codebook can have 16
    /// million symbols.
    var farCodes: UnsafeMutablePointer<Int32>?
    var farCodeCount: Int32 = 0
}

/// A floor of type 1 (Floor1). Type 0 is not decoded, as in the original.
struct VorbisFloor1 {
    var partitions: UInt8 = 0
    var partitionClassList: UnsafeMutablePointer<UInt8>? // 32
    var classDimensions: UnsafeMutablePointer<UInt8>? // 16
    var classSubclasses: UnsafeMutablePointer<UInt8>? // 16
    var classMasterbooks: UnsafeMutablePointer<UInt8>? // 16
    var subclassBooks: UnsafeMutablePointer<Int16>? // 16 by 8
    var xList: UnsafeMutablePointer<UInt16>? // 31 * 8 + 2
    var sortedOrder: UnsafeMutablePointer<UInt8>? // 31 * 8 + 2
    var neighbors: UnsafeMutablePointer<UInt8>? // 31 * 8 + 2, by 2
    var floor1Multiplier: UInt8 = 0
    var rangebits: UInt8 = 0
    var values: Int32 = 0
}

/// A residue (Residue).
struct VorbisResidue {
    var begin: UInt32 = 0, end: UInt32 = 0
    var partSize: UInt32 = 0
    var classifications: UInt8 = 0
    var classbook: UInt8 = 0
    var classdata: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
    /// By classification, eight books each.
    var residueBooks: UnsafeMutablePointer<Int16>?
}

/// MappingChannel.
struct VorbisMappingChannel {
    var magnitude: UInt8 = 0
    var angle: UInt8 = 0
    var mux: UInt8 = 0
}

/// A mapping (Mapping).
struct VorbisMapping {
    var couplingSteps: UInt16 = 0
    var chan: UnsafeMutablePointer<VorbisMappingChannel>?
    var submaps: UInt8 = 0
    /// The original's submap_floor[15] and submap_residue[15], side by side as they lie in its struct,
    /// with the byte of padding after them: a sixteenth submap's floor is written over the first
    /// submap's residue there, and its residue into the padding, and so it is here. The floors are
    /// at 0 and the residues at 15.
    var submap: UnsafeMutablePointer<UInt8>? // 32
}

/// A mode (Mode).
struct VorbisMode {
    var blockflag: UInt8 = 0
    var mapping: UInt8 = 0
    var windowtype: UInt16 = 0
    var transformtype: UInt16 = 0
}

/// One of the pages being checked while the decoder looks for its place again (CRCscan).
struct VorbisCRCScan {
    var goalCRC: UInt32 = 0
    var bytesLeft: Int32 = 0
    var crcSoFar: UInt32 = 0
    var bytesDone: Int32 = 0
    var sampleLoc: UInt32 = 0
}

/// The CRC of an Ogg page (crc32_init): its polynomial is 0x04c11db7, from the specification.
private let crcTable: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0 ..< 256 {
        var s = UInt32(i) << 24
        for _ in 0 ..< 8 {
            s = (s << 1) ^ (s >= 1 << 31 ? 0x04c1_1db7 : 0)
        }
        table[i] = s
    }
    return table
}()

@inline(__always) private func crc32Update(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
    (crc << 8) ^ crcTable[Int(byte ^ UInt8(truncatingIfNeeded: crc >> 24))]
}

/// bit_reverse.
@inline(__always) private func bitReverse(_ x: UInt32) -> UInt32 {
    var n = x
    n = ((n & 0xAAAA_AAAA) >> 1) | ((n & 0x5555_5555) << 1)
    n = ((n & 0xCCCC_CCCC) >> 2) | ((n & 0x3333_3333) << 2)
    n = ((n & 0xF0F0_F0F0) >> 4) | ((n & 0x0F0F_0F0F) << 4)
    n = ((n & 0xFF00_FF00) >> 8) | ((n & 0x00FF_00FF) << 8)
    return (n >> 16) | (n << 16)
}

/// ilog: the number of bits it takes to write `n`, so that ilog(1) is 1, ilog(2) is 2 and ilog(4)
/// is 3, as the specification has it; 0 for 0 and for anything below. The original reads it from a
/// table of sixteen; this is the same.
@inline(__always) private func ilog(_ n: Int32) -> Int32 {
    n < 0 ? 0 : Int32(32 - n.leadingZeroBitCount)
}

/// float32_unpack: a codebook's packed float, made as the specification says.
private func float32Unpack(_ x: UInt32) -> Float {
    let mantissa = x & 0x1F_FFFF
    let sign = x & 0x8000_0000
    let exp = (x & 0x7FE0_0000) >> 21
    let res: Double = sign != 0 ? -Double(mantissa) : Double(mantissa)
    return Float(ldexp(Double(Float(res)), Int32(exp) - 788))
}

/// A double made an int as the original's casts make it on the machines it is built for: saturated
/// at the ends, and 0 for a NaN, where Swift would stop.
@inline(__always) private func cInt(_ d: Double) -> Int32 {
    if d.isNaN { return 0 }
    if d >= 2_147_483_647 { return .max }
    if d <= -2_147_483_648 { return .min }
    return Int32(d)
}

/// lookup1_values: the number of values in each dimension of a codebook whose vectors are every
/// combination of a few values.
private func lookup1Values(_ entries: Int32, _ dim: Int32) -> Int32 {
    var r = cInt(floor(exp(Double(Float(log(Double(Float(entries)))) / Float(dim)))))
    if cInt(floor(pow(Double(Float(r) + 1), Double(dim)))) <= entries { r &+= 1 }
    if pow(Double(Float(r) + 1), Double(dim)) <= Double(entries) { return -1 }
    if cInt(floor(pow(Double(Float(r)), Double(dim)))) > entries { return -1 }
    return r
}

/// The table of the floor's amplitudes (inverse_db_table), as it is in the specification. It is kept
/// as the bits of the floats the C compiler makes of the original's literals.
private let inverseDBTable: [UInt32] = [
    0x33E4_B43E, 0x33F3_9109, 0x3401_B28B, 0x340A_203C, 0x3413_1A23, 0x341C_A960, 0x3426_D7A7, 0x3431_AF4B,
    0x343D_3B50, 0x3449_8770, 0x3456_A023, 0x3464_92B8, 0x3473_6D55, 0x3481_9F88, 0x348A_0BFC, 0x3493_0493,
    0x349C_9269, 0x34A6_BF32, 0x34B1_953F, 0x34BD_1F93, 0x34C9_69E4, 0x34D6_80AD, 0x34E4_7136, 0x34F3_49A6,
    0x3501_8C88, 0x3509_F7C0, 0x3512_EF06, 0x351C_7B76, 0x3526_A6C0, 0x3531_7B37, 0x353D_03DA, 0x3549_4C5E,
    0x3556_613B, 0x3564_4FB9, 0x3573_25FC, 0x3581_798A, 0x3589_E386, 0x3592_D97C, 0x359C_6485, 0x35A6_8E52,
    0x35B1_6133, 0x35BC_E825, 0x35C9_2EDC, 0x35D6_41CE, 0x35E4_2E41, 0x35F3_0257, 0x3601_668F, 0x3609_CF4F,
    0x3612_C3F5, 0x361C_4D98, 0x3626_75E8, 0x3631_4732, 0x363C_CC74, 0x3649_115E, 0x3656_2265, 0x3664_0CCE,
    0x3672_DEB8, 0x3681_5397, 0x3689_BB1C, 0x3692_AE72, 0x369C_36AF, 0x36A6_5D81, 0x36B1_2D35, 0x36BC_B0C7,
    0x36C8_F3E4, 0x36D6_0301, 0x36E3_EB60, 0x36F2_BB1E, 0x3701_40A2, 0x3709_A6EB, 0x3712_98F1, 0x371C_1FC9,
    0x3726_451E, 0x3731_133D, 0x373C_951E, 0x3748_D66F, 0x3755_E3A2, 0x3763_C9F7, 0x3772_9789, 0x3781_2DAF,
    0x3789_92BE, 0x3792_8374, 0x379C_08E6, 0x37A6_2CBE, 0x37B0_F947, 0x37BC_7979, 0x37C8_B8FE, 0x37D5_C447,
    0x37E3_A892, 0x37F2_73F8, 0x3801_1AC0, 0x3809_7E93, 0x3812_6DF9, 0x381B_F206, 0x3826_1462, 0x3830_DF56,
    0x383C_5DD8, 0x3848_9B92, 0x3855_A4F2, 0x3863_8733, 0x3872_506E, 0x3881_07D3, 0x3889_6A6B, 0x3892_5882,
    0x389B_DB2A, 0x38A5_FC09, 0x38B0_C568, 0x38BC_423B, 0x38C8_7E29, 0x38D5_85A0, 0x38E3_65D9, 0x38F2_2CE8,
    0x3900_F4E9, 0x3909_5646, 0x3912_430E, 0x391B_C451, 0x3925_E3B5, 0x3930_AB7F, 0x393C_26A2, 0x3948_60C5,
    0x3955_6653, 0x3963_4483, 0x3972_0968, 0x3980_E201, 0x3989_4224, 0x3992_2D9D, 0x399B_AD7B, 0x39A5_CB63,
    0x39B0_9199, 0x39BC_0B0D, 0x39C8_4366, 0x39D5_470B, 0x39E3_2332, 0x39F1_E5ED, 0x3A00_CF1D, 0x3A09_2E05,
    0x3A12_1830, 0x3A1B_96A9, 0x3A25_B315, 0x3A30_77B7, 0x3A3B_EF7C, 0x3A48_260A, 0x3A55_27C7, 0x3A63_01E6,
    0x3A71_C278, 0x3A80_BC3B, 0x3A89_19E9, 0x3A92_02C6, 0x3A9B_7FDB, 0x3AA5_9ACB, 0x3AB0_5DD8, 0x3ABB_D3EF,
    0x3AC8_08B3, 0x3AD5_0888, 0x3AE2_E09F, 0x3AF1_9F07, 0x3B00_A95C, 0x3B09_05D0, 0x3B11_ED5E, 0x3B1B_690F,
    0x3B25_8284, 0x3B30_43FD, 0x3B3B_B867, 0x3B47_EB61, 0x3B54_E94D, 0x3B62_BF5D, 0x3B71_7B9C, 0x3B80_967F,
    0x3B88_F1BA, 0x3B91_D7F9, 0x3B9B_5247, 0x3BA5_6A41, 0x3BB0_2A27, 0x3BBB_9CE2, 0x3BC7_CE12, 0x3BD4_CA17,
    0x3BE2_9E20, 0x3BF1_5835, 0x3C00_83A6, 0x3C08_DDA7, 0x3C11_C298, 0x3C1B_3B82, 0x3C25_5201, 0x3C30_1054,
    0x3C3B_8161, 0x3C47_B0C8, 0x3C54_AAE5, 0x3C62_7CE8, 0x3C71_34D4, 0x3C80_70CF, 0x3C88_C996, 0x3C91_AD3A,
    0x3C9B_24C0, 0x3CA5_39C5, 0x3CAF_F685, 0x3CBB_65E5, 0x3CC7_9382, 0x3CD4_8BB9, 0x3CE2_5BB4, 0x3CF1_1179,
    0x3D00_5DFB, 0x3D08_B589, 0x3D11_97DF, 0x3D1B_0E02, 0x3D25_218D, 0x3D2F_DCB9, 0x3D3B_4A6D, 0x3D47_7640,
    0x3D54_6C91, 0x3D62_3A85, 0x3D70_EE22, 0x3D80_4B2A, 0x3D88_A17F, 0x3D91_8288, 0x3D9A_F748, 0x3DA5_0958,
    0x3DAF_C2F2, 0x3DBB_2EF8, 0x3DC7_5903, 0x3DD4_4D6D, 0x3DE2_195C, 0x3DF0_CAD1, 0x3E00_385B, 0x3E08_8D77,
    0x3E11_6D33, 0x3E1A_E090, 0x3E24_F127, 0x3E2F_A92E, 0x3E3B_1387, 0x3E47_3BCA, 0x3E54_2E4D, 0x3E61_F837,
    0x3E70_A784, 0x3E80_258F, 0x3E88_7973, 0x3E91_57E2, 0x3E9A_C9DC, 0x3EA4_D8F9, 0x3EAF_8F6D, 0x3EBA_F81B,
    0x3EC7_1E95, 0x3ED4_0F33, 0x3EE1_D717, 0x3EF0_843D, 0x3F00_12C6, 0x3F08_6572, 0x3F11_4293, 0x3F1A_B32B,
    0x3F24_C0CE, 0x3F2F_75B1, 0x3F3A_DCB2, 0x3F47_0165, 0x3F53_F01D, 0x3F61_B5FB, 0x3F70_60FB, 0x3F80_0000,
]

/// Everything a stb_vorbis decoder keeps (struct stb_vorbis), less what only the pull-data API uses.
/// It lives at one place in memory, kept by `StbVorbis`, which frees what it took when it goes, and its
/// functions are the original's.
struct VorbisState {
    var sampleRate: UInt32 = 0
    var channels: Int32 = 0
    /// The user comments, as bytes.
    var comments: [[UInt8]] = []

    // The bytes of this call, and where in them the decoder is. Between calls they are not kept.
    var data: UnsafePointer<UInt8>
    var stream = 0
    var streamEnd = 0

    /// Everything taken for the stream, given back all together.
    var allocations: [UnsafeMutableRawPointer] = []
    var memoryTaken = 0

    var eof = false
    var error: Int32 = 0

    var blocksize0: Int32 = 0, blocksize1: Int32 = 0
    var codebookCount: Int32 = 0
    var codebooks: UnsafeMutablePointer<VorbisCodebook>?
    var floorCount: Int32 = 0
    var floorTypes: UnsafeMutablePointer<UInt16> // 64
    var floorConfig: UnsafeMutablePointer<VorbisFloor1>?
    var residueCount: Int32 = 0
    var residueTypes: UnsafeMutablePointer<UInt16> // 64
    var residueConfig: UnsafeMutablePointer<VorbisResidue>?
    var mappingCount: Int32 = 0
    var mapping: UnsafeMutablePointer<VorbisMapping>?
    var modeCount: Int32 = 0
    var modeConfig: UnsafeMutablePointer<VorbisMode> // 64

    var channelBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> // 16
    var outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> // 16
    var previousWindow: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> // 16
    var previousLength: Int32 = 0
    var finalY: UnsafeMutablePointer<UnsafeMutablePointer<Int16>?> // 16

    var currentLoc: UInt32 = 0
    var currentLocValid = false

    // By block size: the twiddle factors, the windows and the bit reversals.
    var twiddleA: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> // 2
    var twiddleB: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> // 2
    var twiddleC: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> // 2
    var window: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> // 2
    var bitReverseTable: UnsafeMutablePointer<UnsafeMutablePointer<UInt16>?> // 2

    var lastPage: Int32 = 0
    var segmentCount: Int32 = 0
    var segments: UnsafeMutablePointer<UInt8> // 255
    var pageFlag: UInt8 = 0
    var bytesInSeg: UInt8 = 0
    var firstDecode = false
    var nextSeg: Int32 = 0
    var lastSeg = false
    var lastSegWhich: Int32 = 0
    var acc: UInt32 = 0
    var validBits: Int32 = 0
    var packetBytes: Int32 = 0
    var endSegWithKnownLoc: Int32 = 0
    var knownLocForPacket: UInt32 = 0
    var discardSamplesDeferred: Int32 = 0
    var samplesOutput: UInt32 = 0

    var pageCrcTests: Int32 = -1
    var scan: UnsafeMutablePointer<VorbisCRCScan> // 4

    var channelBufferStart: Int32 = 0
    var channelBufferEnd: Int32 = 0

    // What the original keeps on its stack or takes for the length of a call, kept here instead.
    var imdctBuffer: UnsafeMutablePointer<Float>?
    var partClassdata: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?
    var partClassdataPerChannel = 0
    var step2Flag: UnsafeMutablePointer<UInt8> // 256
    var zeroChannel: UnsafeMutablePointer<Bool> // 256
    var reallyZeroChannel: UnsafeMutablePointer<Bool> // 256
    var doNotDecode: UnsafeMutablePointer<UInt8> // 256
    var residueBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?> // 16
    var headerBytes: UnsafeMutablePointer<UInt8> // 6

    private static let nothing: [UInt8] = [0]

    /// vorbis_init.
    init() {
        var taken: [UnsafeMutableRawPointer] = []
        func make<T>(_ count: Int, _: T.Type) -> UnsafeMutablePointer<T> {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: count * MemoryLayout<T>.stride, alignment: 16)
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: count * MemoryLayout<T>.stride)
            taken.append(raw)
            return raw.assumingMemoryBound(to: T.self)
        }
        data = Self.nothing.withUnsafeBufferPointer { $0.baseAddress! }
        floorTypes = make(64, UInt16.self)
        residueTypes = make(64, UInt16.self)
        modeConfig = make(64, VorbisMode.self)
        channelBuffers = make(maxChannels, UnsafeMutablePointer<Float>?.self)
        outputs = make(maxChannels, UnsafeMutablePointer<Float>?.self)
        previousWindow = make(maxChannels, UnsafeMutablePointer<Float>?.self)
        finalY = make(maxChannels, UnsafeMutablePointer<Int16>?.self)
        twiddleA = make(2, UnsafeMutablePointer<Float>?.self)
        twiddleB = make(2, UnsafeMutablePointer<Float>?.self)
        twiddleC = make(2, UnsafeMutablePointer<Float>?.self)
        window = make(2, UnsafeMutablePointer<Float>?.self)
        bitReverseTable = make(2, UnsafeMutablePointer<UInt16>?.self)
        segments = make(255, UInt8.self)
        scan = make(Int(pushdataCRCCount), VorbisCRCScan.self)
        step2Flag = make(256, UInt8.self)
        zeroChannel = make(256, Bool.self)
        reallyZeroChannel = make(256, Bool.self)
        doNotDecode = make(256, UInt8.self)
        residueBuffers = make(maxChannels, UnsafeMutablePointer<Float>?.self)
        headerBytes = make(6, UInt8.self)
        allocations = taken
    }

    /// Gives back everything the stream took (vorbis_deinit).
    mutating func freeAll() {
        for p in allocations { p.deallocate() }
        allocations = []
    }

    // MARK: Memory

    /// setup_malloc: zeroed memory for `count` of a type, or nil where the original's would fail: for
    /// none at all (it asks malloc for nothing then, and takes that as a failure), or for more than
    /// the stream may have.
    /// The sizes are worked out in 64 bits, as `Int` has 32 in WebAssembly.
    mutating func setupMalloc<T>(_ count: Int64, _: T.Type, slack: Int = 0) -> UnsafeMutablePointer<T>? {
        if count <= 0 || count > Int64(setupMemoryLimit) { return nil }
        let bytes = count * Int64(MemoryLayout<T>.stride)
        if bytes > Int64(setupMemoryLimit - memoryTaken) { return nil }
        let all = Int(bytes) + slack * MemoryLayout<T>.stride
        memoryTaken += all
        let raw = UnsafeMutableRawPointer.allocate(byteCount: all, alignment: 16)
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: all)
        allocations.append(raw)
        return raw.assumingMemoryBound(to: T.self)
    }

    mutating func setupMalloc<T>(_ count: Int, _ type: T.Type, slack: Int = 0) -> UnsafeMutablePointer<T>? {
        setupMalloc(Int64(count), type, slack: slack)
    }

    /// error: notes the error, for a function to return false with.
    @discardableResult @inline(__always)
    mutating func fail(_ e: Int32) -> Bool {
        error = e
        return false
    }

    // MARK: Reading bytes

    /// get8: the next byte of this call's bytes, or 0 past their end, noting that the end was reached.
    @inline(__always)
    mutating func get8() -> UInt8 {
        let s = stream
        if s >= streamEnd {
            eof = true
            return 0
        }
        stream = s + 1
        return data[s]
    }

    /// get32.
    mutating func get32() -> UInt32 {
        var x = UInt32(get8())
        x &+= UInt32(get8()) << 8
        x &+= UInt32(get8()) << 16
        x &+= UInt32(get8()) << 24
        return x
    }

    /// getn.
    mutating func getn(_ into: UnsafeMutablePointer<UInt8>, _ n: Int) -> Bool {
        if stream + n > streamEnd {
            eof = true
            return false
        }
        into.update(from: data + stream, count: n)
        stream += n
        return true
    }

    /// skip.
    mutating func skip(_ n: Int) {
        stream += n
        if stream >= streamEnd { eof = true }
    }

    /// capture_pattern: "OggS".
    mutating func capturePattern() -> Bool {
        if get8() != 0x4F { return false }
        if get8() != 0x67 { return false }
        if get8() != 0x67 { return false }
        if get8() != 0x53 { return false }
        return true
    }

    /// start_page_no_capturepattern: the rest of a page's header.
    mutating func startPageNoCapturePattern() -> Bool {
        // stream structure version
        if get8() != 0 { return fail(StbVorbisError.invalidStreamStructureVersion) }
        pageFlag = get8()
        // absolute granule position
        let loc0 = get32()
        let loc1 = get32()
        // stream serial number: vorbis does not interleave, so it is not looked at
        _ = get32()
        // page sequence number
        lastPage = Int32(bitPattern: get32())
        // CRC32
        _ = get32()
        segmentCount = Int32(get8())
        if !getn(segments, Int(segmentCount)) { return fail(StbVorbisError.unexpectedEOF) }
        // Assume that the sample position of no segment is known.
        endSegWithKnownLoc = -2
        if loc0 != ~0 || loc1 != ~0 {
            // the last packet that ends on this page
            var i = segmentCount - 1
            while i >= 0 {
                if segments[Int(i)] < 255 { break }
                i -= 1
            }
            if i >= 0 {
                endSegWithKnownLoc = i
                knownLocForPacket = loc0
            }
        }
        nextSeg = 0
        return true
    }

    /// start_page.
    mutating func startPage() -> Bool {
        if !capturePattern() { return fail(StbVorbisError.missingCapturePattern) }
        return startPageNoCapturePattern()
    }

    /// start_packet.
    mutating func startPacket() -> Bool {
        while nextSeg == -1 {
            if !startPage() { return false }
            if pageFlag & pageflagContinuedPacket != 0 { return fail(StbVorbisError.continuedPacketFlagInvalid) }
        }
        lastSeg = false
        validBits = 0
        packetBytes = 0
        bytesInSeg = 0
        return true
    }

    /// maybe_start_packet.
    mutating func maybeStartPacket() -> Bool {
        if nextSeg == -1 {
            let x = get8()
            if eof { return false } // the end at a page's edge is not an error
            if x != 0x4F { return fail(StbVorbisError.missingCapturePattern) }
            if get8() != 0x67 { return fail(StbVorbisError.missingCapturePattern) }
            if get8() != 0x67 { return fail(StbVorbisError.missingCapturePattern) }
            if get8() != 0x53 { return fail(StbVorbisError.missingCapturePattern) }
            if !startPageNoCapturePattern() { return false }
            if pageFlag & pageflagContinuedPacket != 0 {
                // enough to read this packet with, if it is wanted
                lastSeg = false
                bytesInSeg = 0
                return fail(StbVorbisError.continuedPacketFlagInvalid)
            }
        }
        return startPacket()
    }

    /// next_segment.
    mutating func nextSegment() -> Int32 {
        if lastSeg { return 0 }
        if nextSeg == -1 {
            lastSegWhich = segmentCount - 1 // in case start_page fails
            if !startPage() {
                lastSeg = true
                return 0
            }
            if pageFlag & pageflagContinuedPacket == 0 {
                fail(StbVorbisError.continuedPacketFlagInvalid)
                return 0
            }
        }
        let len = segments[Int(nextSeg)]
        nextSeg += 1
        if len < 255 {
            lastSeg = true
            lastSegWhich = nextSeg - 1
        }
        if nextSeg >= segmentCount { nextSeg = -1 }
        bytesInSeg = len
        return Int32(len)
    }

    /// get8_packet_raw.
    @inline(__always)
    mutating func get8PacketRaw() -> Int32 {
        if bytesInSeg == 0 {
            if lastSeg { return EOP }
            if nextSegment() == 0 { return EOP }
        }
        bytesInSeg &-= 1
        packetBytes &+= 1
        return Int32(get8())
    }

    /// get8_packet.
    mutating func get8Packet() -> Int32 {
        let x = get8PacketRaw()
        validBits = 0
        return x
    }

    /// get32_packet.
    mutating func get32Packet() -> Int32 {
        var x = UInt32(bitPattern: get8Packet())
        x &+= UInt32(bitPattern: get8Packet()) &<< 8
        x &+= UInt32(bitPattern: get8Packet()) &<< 16
        x &+= UInt32(bitPattern: get8Packet()) &<< 24
        return Int32(bitPattern: x)
    }

    /// flush_packet.
    mutating func flushPacket() {
        while get8PacketRaw() != EOP {}
    }

    /// get_bits: the next `n` bits of the packet, least significant first; 0 once past its end. Its
    /// shifts are masked to five bits, as the machines the original runs on mask them.
    mutating func getBits(_ n: Int32) -> UInt32 {
        if validBits < 0 { return 0 }
        if validBits < n {
            if n > 24 {
                // the accumulator cannot take more than 24 at once
                var z = getBits(24)
                z &+= getBits(n - 24) &<< 24
                return z
            }
            if validBits == 0 { acc = 0 }
            while validBits < n {
                let z = get8PacketRaw()
                if z == EOP {
                    validBits = invalidBits
                    return 0
                }
                acc &+= UInt32(bitPattern: z) &<< validBits
                validBits += 8
            }
        }
        let z = acc & ((1 &<< UInt32(bitPattern: n)) &- 1)
        acc = acc &>> n
        validBits -= n
        return z
    }

    /// prep_huffman: as many bits in the accumulator as it can take without reading past the packet.
    @inline(__always)
    mutating func prepHuffman() {
        if validBits <= 24 {
            if validBits == 0 { acc = 0 }
            repeat {
                if lastSeg && bytesInSeg == 0 { return }
                let z = get8PacketRaw()
                if z == EOP { return }
                acc &+= UInt32(bitPattern: z) &<< validBits
                validBits &+= 8
            } while validBits <= 24
        }
    }

    // MARK: Codebooks

    /// codebook_decode_scalar_raw: a symbol found by search, where the quick table has none.
    mutating func codebookDecodeScalarRaw(_ c: UnsafeMutablePointer<VorbisCodebook>) -> Int32 {
        prepHuffman()

        if c.pointee.codewords == nil && c.pointee.sortedCodewords == nil { return -1 }

        // binary search: with sorted codewords and no plain ones, or with more than eight entries
        if c.pointee.entries > 8 ? c.pointee.sortedCodewords != nil : c.pointee.codewords == nil {
            let code = bitReverse(acc)
            let sorted = c.pointee.sortedCodewords!
            var x: Int32 = 0, n = c.pointee.sortedEntries
            while n > 1 {
                // sorted[x] <= code < sorted[x + n]
                let m = x + (n >> 1)
                if sorted[Int(m)] <= code {
                    x = m
                    n -= n >> 1
                } else {
                    n >>= 1
                }
            }
            // x is the sorted index; for a codebook that is not sparse, the symbol
            if c.pointee.sparse == 0 { x = c.pointee.sortedValues![Int(x)] }
            let len = Int32(c.pointee.codewordLengths![Int(x)])
            if validBits >= len {
                acc = acc &>> len
                validBits -= len
                return x
            }
            validBits = 0
            return -1
        }

        // A short codebook, or one whose codes are all ten bits or shorter, is searched in order. A code
        // of ten bits or shorter for one of the first 32767 symbols is in the quick table, and that had
        // no answer, so only those past it can match, and only one at most (the codes are a prefix code).
        // The original goes through every symbol; this goes through the few past the table that have codes.
        let lengths = c.pointee.codewordLengths!
        let codewords = c.pointee.codewords!
        let entries = c.pointee.entries
        if entries <= 8 {
            for i in 0 ..< Int(entries) {
                if let found = linearMatch(lengths, codewords, Int32(i)) { return found }
            }
        } else if let far = c.pointee.farCodes {
            for k in 0 ..< Int(c.pointee.farCodeCount) {
                if let found = linearMatch(lengths, codewords, far[k]) { return found }
            }
        }

        fail(StbVorbisError.invalidStream)
        validBits = 0
        return -1
    }

    /// One step of codebook_decode_scalar_raw's search in order: the symbol if its code is the next.
    @inline(__always)
    private mutating func linearMatch(_ lengths: UnsafeMutablePointer<UInt8>, _ codewords: UnsafeMutablePointer<UInt32>,
                                      _ i: Int32) -> Int32?
    {
        let len = lengths[Int(i)]
        if len == noCode { return nil }
        let l = Int32(len)
        if codewords[Int(i)] == (acc & ((1 &<< UInt32(l)) &- 1)) {
            if validBits >= l {
                acc = acc &>> l
                validBits -= l
                return i
            }
            validBits = 0
            return -1
        }
        return nil
    }

    /// DECODE_RAW: a symbol from the quick table if it is there, or by search.
    @inline(__always)
    mutating func decodeRaw(_ c: UnsafeMutablePointer<VorbisCodebook>) -> Int32 {
        if validBits < fastHuffmanLength { prepHuffman() }
        var v = Int32(c.pointee.fastHuffman![Int(acc & fastHuffmanTableMask)])
        if v >= 0 {
            let n = Int32(c.pointee.codewordLengths![Int(v)])
            acc = acc &>> n
            validBits &-= n
            if validBits < 0 {
                validBits = 0
                v = -1
            }
        } else {
            v = codebookDecodeScalarRaw(c)
        }
        return v
    }

    /// DECODE: a symbol, for a sparse codebook made a symbol from the sorted index.
    @inline(__always)
    mutating func decode(_ c: UnsafeMutablePointer<VorbisCodebook>) -> Int32 {
        let v = decodeRaw(c)
        if c.pointee.sparse != 0 { return c.pointee.sortedValues![Int(v)] }
        return v
    }

    /// codebook_decode_start.
    mutating func codebookDecodeStart(_ c: UnsafeMutablePointer<VorbisCodebook>) -> Int32 {
        var z: Int32 = -1
        // type 0 is only allowed where one value is read
        if c.pointee.lookupType == 0 {
            fail(StbVorbisError.invalidStream)
        } else {
            z = decodeRaw(c)
            if z < 0 { // the end of the packet?
                if bytesInSeg == 0 && lastSeg { return z }
                fail(StbVorbisError.invalidStream)
            }
        }
        return z
    }

    /// codebook_decode.
    mutating func codebookDecode(_ c: UnsafeMutablePointer<VorbisCodebook>, _ output: UnsafeMutablePointer<Float>,
                                 _ length: Int32) -> Bool
    {
        var z = codebookDecodeStart(c)
        if z < 0 { return false }
        let len = length > c.pointee.dimensions ? c.pointee.dimensions : length
        z &*= c.pointee.dimensions
        let mult = c.pointee.multiplicands! + Int(z)
        if c.pointee.sequenceP != 0 {
            var last: Float = 0
            let minimum = c.pointee.minimumValue
            var i = 0
            while i < Int(len) {
                let val = mult[i] + last
                output[i] += val
                last = val + minimum
                i += 1
            }
        } else {
            let last: Float = 0
            var i = 0
            while i < Int(len) {
                output[i] += mult[i] + last
                i += 1
            }
        }
        return true
    }

    /// codebook_decode_step.
    mutating func codebookDecodeStep(_ c: UnsafeMutablePointer<VorbisCodebook>, _ output: UnsafeMutablePointer<Float>,
                                     _ length: Int32, _ step: Int32) -> Bool
    {
        var z = codebookDecodeStart(c)
        var last: Float = 0
        if z < 0 { return false }
        let len = length > c.pointee.dimensions ? c.pointee.dimensions : length
        z &*= c.pointee.dimensions
        let mult = c.pointee.multiplicands! + Int(z)
        let sequence = c.pointee.sequenceP != 0
        var i: Int32 = 0
        while i < len {
            let val = mult[Int(i)] + last
            output[Int(i &* step)] += val
            if sequence { last = val }
            i += 1
        }
        return true
    }

    /// codebook_decode_deinterleave_repeat: vectors laid across the channels in turn, as residue type 2
    /// keeps them.
    mutating func codebookDecodeDeinterleaveRepeat(_ c: UnsafeMutablePointer<VorbisCodebook>,
                                                   _ outputs: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>,
                                                   _ ch: Int32, _ cInterP: inout Int32, _ pInterP: inout Int32,
                                                   _ len: Int32, _ totalDecodeIn: Int32) -> Bool
    {
        var cInter = cInterP
        var pInter = pInterP
        var effective = c.pointee.dimensions
        var totalDecode = totalDecodeIn

        // type 0 is only allowed where one value is read
        if c.pointee.lookupType == 0 { return fail(StbVorbisError.invalidStream) }

        let dimensions = c.pointee.dimensions
        let sequence = c.pointee.sequenceP != 0
        while totalDecode > 0 {
            var last: Float = 0
            var z = decodeRaw(c)
            if z < 0 {
                if bytesInSeg == 0 && lastSeg { return false }
                return fail(StbVorbisError.invalidStream)
            }

            // Stop short of the end of the buffers. (The original's sum for how far it may go adds the
            // channel twice over, where it means to take it away; that is kept, and the memory past
            // the end that it can then reach is there and is silence.)
            if cInter &+ pInter &* ch &+ effective > len &* ch {
                effective = len &* ch &- (pInter &* ch &- cInter)
            }

            z &*= dimensions
            let mult = c.pointee.multiplicands! + Int(z)
            var i = 0
            while i < Int(effective) {
                let val = mult[i] + last
                if let out = outputs[Int(cInter)] { out[Int(pInter)] += val }
                cInter += 1
                if cInter == ch {
                    cInter = 0
                    pInter += 1
                }
                if sequence { last = val }
                i += 1
            }

            totalDecode &-= effective
        }
        cInterP = cInter
        pInterP = pInter
        return true
    }

    // MARK: Floors and residues

    /// residue_decode.
    mutating func residueDecode(_ book: UnsafeMutablePointer<VorbisCodebook>, _ target: UnsafeMutablePointer<Float>,
                                _ offsetIn: Int32, _ n: Int32, _ rtype: Int32) -> Bool
    {
        var offset = offsetIn
        if rtype == 0 {
            let step = n / book.pointee.dimensions
            var k: Int32 = 0
            while k < step {
                if !codebookDecodeStep(book, target + Int(offset &+ k), n &- offset &- k, step) { return false }
                k += 1
            }
        } else {
            var k: Int32 = 0
            while k < n {
                if !codebookDecode(book, target + Int(offset), n &- k) { return false }
                k &+= book.pointee.dimensions
                offset &+= book.pointee.dimensions
            }
        }
        return true
    }

    /// decode_residue. `n` is half the block's size.
    mutating func decodeResidue(_ residueBuffers: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, _ ch: Int32,
                                _ n: Int32, _ rn: Int, _ doNotDecode: UnsafeMutablePointer<UInt8>)
    {
        let r = residueConfig! + rn
        let rtype = Int32(residueTypes[rn])
        let classbook = codebooks! + Int(r.pointee.classbook)
        let classwords = classbook.pointee.dimensions
        let actualSize = UInt32(bitPattern: rtype == 2 ? n &* 2 : n)
        let limitRBegin = r.pointee.begin < actualSize ? r.pointee.begin : actualSize
        let limitREnd = r.pointee.end < actualSize ? r.pointee.end : actualSize
        let nRead = Int32(bitPattern: limitREnd &- limitRBegin)
        let partRead = Int32(bitPattern: UInt32(bitPattern: nRead) / r.pointee.partSize)
        let perChannel = partClassdataPerChannel
        let partClassdata = self.partClassdata!
        let begin = Int32(bitPattern: r.pointee.begin)
        let partSize = Int32(bitPattern: r.pointee.partSize)
        let residueBooks = r.pointee.residueBooks!
        let classdata = r.pointee.classdata!

        for i in 0 ..< Int(ch) where doNotDecode[i] == 0 {
            residueBuffers[i]!.update(repeating: 0, count: Int(n))
        }

        if rtype == 2 && ch != 1 {
            var j: Int32 = 0
            while j < ch {
                if doNotDecode[Int(j)] == 0 { break }
                j += 1
            }
            if j == ch { return }

            for pass in 0 ..< 8 {
                var pcount: Int32 = 0, classSet = 0
                if ch == 2 {
                    while pcount < partRead {
                        let z = begin &+ pcount &* partSize
                        var cInter = z & 1, pInter = z >> 1
                        if pass == 0 {
                            let q = decode(classbook)
                            if q == EOP { return }
                            partClassdata[classSet] = classdata[Int(q)]
                        }
                        var i: Int32 = 0
                        while i < classwords && pcount < partRead {
                            var z = begin &+ pcount &* partSize
                            let c = Int(partClassdata[classSet]![Int(i)])
                            let b = residueBooks[c * 8 + pass]
                            if b >= 0 {
                                let book = codebooks! + Int(b)
                                if !codebookDecodeDeinterleaveRepeat(book, residueBuffers, ch, &cInter, &pInter, n, partSize) {
                                    return
                                }
                            } else {
                                z &+= partSize
                                cInter = z & 1
                                pInter = z >> 1
                            }
                            i += 1
                            pcount += 1
                        }
                        classSet += 1
                    }
                } else if ch > 2 {
                    while pcount < partRead {
                        let z = begin &+ pcount &* partSize
                        var cInter = z % ch, pInter = z / ch
                        if pass == 0 {
                            let q = decode(classbook)
                            if q == EOP { return }
                            partClassdata[classSet] = classdata[Int(q)]
                        }
                        var i: Int32 = 0
                        while i < classwords && pcount < partRead {
                            var z = begin &+ pcount &* partSize
                            let c = Int(partClassdata[classSet]![Int(i)])
                            let b = residueBooks[c * 8 + pass]
                            if b >= 0 {
                                let book = codebooks! + Int(b)
                                if !codebookDecodeDeinterleaveRepeat(book, residueBuffers, ch, &cInter, &pInter, n, partSize) {
                                    return
                                }
                            } else {
                                z &+= partSize
                                cInter = z % ch
                                pInter = z / ch
                            }
                            i += 1
                            pcount += 1
                        }
                        classSet += 1
                    }
                }
            }
            return
        }

        for pass in 0 ..< 8 {
            var pcount: Int32 = 0, classSet = 0
            while pcount < partRead {
                if pass == 0 {
                    for j in 0 ..< Int(ch) where doNotDecode[j] == 0 {
                        let temp = decode(classbook)
                        if temp == EOP { return }
                        partClassdata[j * perChannel + classSet] = classdata[Int(temp)]
                    }
                }
                var i: Int32 = 0
                while i < classwords && pcount < partRead {
                    for j in 0 ..< Int(ch) where doNotDecode[j] == 0 {
                        let c = Int(partClassdata[j * perChannel + classSet]![Int(i)])
                        let b = residueBooks[c * 8 + pass]
                        if b >= 0 {
                            let target = residueBuffers[j]!
                            let offset = begin &+ pcount &* partSize
                            let book = codebooks! + Int(b)
                            if !residueDecode(book, target, offset, partSize, rtype) { return }
                        }
                    }
                    i += 1
                    pcount += 1
                }
                classSet += 1
            }
        }
    }

    // MARK: The inverse MDCT

    /// inverse_mdct: the IMDCT of "The use of multirate filter banks for coding of high quality digital
    /// audio", as the original arranges it.
    mutating func inverseMDCT(_ buffer: UnsafeMutablePointer<Float>, _ n: Int, _ blocktype: Int) {
        let n2 = n >> 1, n4 = n >> 2, n8 = n >> 3
        let buf2 = imdctBuffer!
        let A = twiddleA[blocktype]!

        // copy and reflect the spectral data, and step 0, together
        do {
            var d = buf2 + (n2 - 2)
            var AA = A
            var e = buffer
            let eStop = buffer + n2
            while e != eStop {
                d[1] = (e[0] * AA[0] - e[2] * AA[1])
                d[0] = (e[0] * AA[1] + e[2] * AA[0])
                d -= 2
                AA += 2
                e += 4
            }

            e = buffer + (n2 - 3)
            while d >= buf2 {
                d[1] = (-e[2] * AA[0] - -e[0] * AA[1])
                d[0] = (-e[2] * AA[1] + -e[0] * AA[0])
                d -= 2
                AA += 2
                e -= 4
            }
        }

        let u = buffer
        let v = buf2

        // step 2
        do {
            var AA = A + (n2 - 8)
            var e0 = v + n4
            var e1 = v
            var d0 = u + n4
            var d1 = u

            while AA >= A {
                var v41_21 = e0[1] - e1[1]
                var v40_20 = e0[0] - e1[0]
                d0[1] = e0[1] + e1[1]
                d0[0] = e0[0] + e1[0]
                d1[1] = v41_21 * AA[4] - v40_20 * AA[5]
                d1[0] = v40_20 * AA[4] + v41_21 * AA[5]

                v41_21 = e0[3] - e1[3]
                v40_20 = e0[2] - e1[2]
                d0[3] = e0[3] + e1[3]
                d0[2] = e0[2] + e1[2]
                d1[3] = v41_21 * AA[0] - v40_20 * AA[1]
                d1[2] = v40_20 * AA[0] + v41_21 * AA[1]

                AA -= 8

                d0 += 4
                d1 += 4
                e0 += 4
                e1 += 4
            }
        }

        // step 3
        let ld = Int(ilog(Int32(n))) - 1

        // iteration 0
        imdctStep3Iter0Loop(n >> 4, u, n2 - 1 - n4 * 0, -(n >> 3), A)
        imdctStep3Iter0Loop(n >> 4, u, n2 - 1 - n4 * 1, -(n >> 3), A)

        // iteration 1
        imdctStep3InnerRLoop(n >> 5, u, n2 - 1 - n8 * 0, -(n >> 4), A, 16)
        imdctStep3InnerRLoop(n >> 5, u, n2 - 1 - n8 * 1, -(n >> 4), A, 16)
        imdctStep3InnerRLoop(n >> 5, u, n2 - 1 - n8 * 2, -(n >> 4), A, 16)
        imdctStep3InnerRLoop(n >> 5, u, n2 - 1 - n8 * 3, -(n >> 4), A, 16)

        var l = 2
        while l < (ld - 3) >> 1 {
            let k0 = n >> (l + 2), k0_2 = k0 >> 1
            let lim = 1 << (l + 1)
            for i in 0 ..< lim {
                imdctStep3InnerRLoop(n >> (l + 4), u, n2 - 1 - k0 * i, -k0_2, A, 1 << (l + 3))
            }
            l += 1
        }

        while l < ld - 6 {
            let k0 = n >> (l + 2), k1 = 1 << (l + 3), k0_2 = k0 >> 1
            let rlim = n >> (l + 6)
            let lim = 1 << (l + 1)
            var A0 = A
            var iOff = n2 - 1
            var r = rlim
            while r > 0 {
                imdctStep3InnerSLoop(lim, u, iOff, -k0_2, A0, k1, k0)
                A0 += k1 * 4
                iOff -= 8
                r -= 1
            }
            l += 1
        }

        // iterations ld-6, -5 and -4 together
        imdctStep3InnerSLoopLD654(n >> 5, u, n2 - 1, A, n)

        // steps 4, 5 and 6
        do {
            var bitrev = bitReverseTable[blocktype]!
            var d0 = v + (n4 - 4)
            var d1 = v + (n2 - 4)
            while d0 >= v {
                var k4 = Int(bitrev[0])
                d1[3] = u[k4 + 0]
                d1[2] = u[k4 + 1]
                d0[3] = u[k4 + 2]
                d0[2] = u[k4 + 3]

                k4 = Int(bitrev[1])
                d1[1] = u[k4 + 0]
                d1[0] = u[k4 + 1]
                d0[1] = u[k4 + 2]
                d0[0] = u[k4 + 3]

                d0 -= 4
                d1 -= 4
                bitrev += 2
            }
        }

        // step 7, in place
        do {
            var C = twiddleC[blocktype]!
            var d = v
            var e = v + (n2 - 4)

            while d < e {
                var a02 = d[0] - e[2]
                var a11 = d[1] + e[3]

                var b0 = C[1] * a02 + C[0] * a11
                var b1 = C[1] * a11 - C[0] * a02

                var b2 = d[0] + e[2]
                var b3 = d[1] - e[3]

                d[0] = b2 + b0
                d[1] = b3 + b1
                e[2] = b2 - b0
                e[3] = b1 - b3

                a02 = d[2] - e[0]
                a11 = d[3] + e[1]

                b0 = C[3] * a02 + C[2] * a11
                b1 = C[3] * a11 - C[2] * a02

                b2 = d[2] + e[0]
                b3 = d[3] - e[1]

                d[2] = b2 + b0
                d[3] = b3 + b1
                e[0] = b2 - b0
                e[1] = b1 - b3

                C += 4
                d += 4
                e -= 4
            }
        }

        // step 8, and the decode kernel, into the buffer
        do {
            var B = twiddleB[blocktype]! + (n2 - 8)
            var e = buf2 + (n2 - 8)
            var d0 = buffer
            var d1 = buffer + (n2 - 4)
            var d2 = buffer + n2
            var d3 = buffer + (n - 4)
            while e >= v {
                var p3 = e[6] * B[7] - e[7] * B[6]
                var p2 = -e[6] * B[6] - e[7] * B[7]

                d0[0] = p3
                d1[3] = -p3
                d2[0] = p2
                d3[3] = p2

                var p1 = e[4] * B[5] - e[5] * B[4]
                var p0 = -e[4] * B[4] - e[5] * B[5]

                d0[1] = p1
                d1[2] = -p1
                d2[1] = p0
                d3[2] = p0

                p3 = e[2] * B[3] - e[3] * B[2]
                p2 = -e[2] * B[2] - e[3] * B[3]

                d0[2] = p3
                d1[1] = -p3
                d2[2] = p2
                d3[1] = p2

                p1 = e[0] * B[1] - e[1] * B[0]
                p0 = -e[0] * B[0] - e[1] * B[1]

                d0[3] = p1
                d1[0] = -p1
                d2[3] = p0
                d3[0] = p0

                B -= 8
                e -= 8
                d0 += 4
                d2 += 4
                d1 -= 4
                d3 -= 4
            }
        }
    }

    // MARK: Decoding a packet

    /// get_window.
    func getWindow(_ length: Int32) -> UnsafeMutablePointer<Float>? {
        let len = length &<< 1
        if len == blocksize0 { return window[0] }
        if len == blocksize1 { return window[1] }
        return nil
    }

    /// do_floor: the floor's curve, multiplied into the residue.
    mutating func doFloor(_ map: UnsafeMutablePointer<VorbisMapping>, _ i: Int, _ n: Int32,
                          _ target: UnsafeMutablePointer<Float>, _ finalY: UnsafeMutablePointer<Int16>) -> Bool
    {
        let n2 = n >> 1
        let s = Int(map.pointee.chan![i].mux)
        let floor = Int(map.pointee.submap![s])
        if floorTypes[floor] == 0 {
            return fail(StbVorbisError.invalidStream)
        }
        let g = floorConfig! + floor
        let multiplier = Int32(g.pointee.floor1Multiplier)
        let sortedOrder = g.pointee.sortedOrder!
        let xList = g.pointee.xList!
        var lx: Int32 = 0, ly = Int32(finalY[0]) &* multiplier
        var q = 1
        while q < Int(g.pointee.values) {
            let j = Int(sortedOrder[q])
            if finalY[j] >= 0 {
                let hy = Int32(finalY[j]) &* multiplier
                let hx = Int32(xList[j])
                if lx != hx { drawLine(target, lx, ly, hx, hy, n2) }
                lx = hx
                ly = hy
            }
            q += 1
        }
        if lx < n2 {
            // draw_line(target, lx, ly, n, ly, n2), quicker
            let value = Float(bitPattern: inverseDBTable[Int(ly & 255)])
            var j = Int(lx)
            while j < Int(n2) {
                target[j] *= value
                j += 1
            }
        }
        return true
    }

    /// vorbis_decode_initial: the start of an audio packet, its mode and its windows.
    mutating func vorbisDecodeInitial(_ pLeftStart: inout Int32, _ pLeftEnd: inout Int32, _ pRightStart: inout Int32,
                                      _ pRightEnd: inout Int32, _ mode: inout Int32) -> Bool
    {
        channelBufferStart = 0
        channelBufferEnd = 0

        if eof { return false }
        if !maybeStartPacket() { return false }
        // the packet's type
        if getBits(1) != 0 {
            return fail(StbVorbisError.badPacketType)
        }

        let i = Int32(bitPattern: getBits(ilog(modeCount - 1)))
        if i == EOP { return false }
        if i >= modeCount { return false }
        mode = i
        let m = modeConfig + Int(i)
        let n: Int32, prev: UInt32, next: UInt32
        if m.pointee.blockflag != 0 {
            n = blocksize1
            prev = getBits(1)
            next = getBits(1)
        } else {
            prev = 0
            next = 0
            n = blocksize0
        }

        // the windows
        let windowCenter = n >> 1
        if m.pointee.blockflag != 0 && prev == 0 {
            pLeftStart = (n - blocksize0) >> 2
            pLeftEnd = (n + blocksize0) >> 2
        } else {
            pLeftStart = 0
            pLeftEnd = windowCenter
        }
        if m.pointee.blockflag != 0 && next == 0 {
            pRightStart = (n * 3 - blocksize0) >> 2
            pRightEnd = (n * 3 + blocksize0) >> 2
        } else {
            pRightStart = windowCenter
            pRightEnd = n
        }
        return true
    }

    /// vorbis_decode_packet_rest: the rest of an audio packet, into the channel buffers.
    mutating func vorbisDecodePacketRest(_ len: inout Int32, _ m: UnsafeMutablePointer<VorbisMode>, _ leftStartIn: Int32,
                                         _ rightStart: Int32, _ rightEnd: Int32, _ pLeft: inout Int32) -> Bool
    {
        var leftStart = leftStartIn
        let n = m.pointee.blockflag != 0 ? blocksize1 : blocksize0
        let map = mapping! + Int(m.pointee.mapping)
        let chan = map.pointee.chan!
        let submap = map.pointee.submap!
        let channelCount = Int(channels)

        // the floors
        let n2 = n >> 1

        for i in 0 ..< channelCount {
            let s = Int(chan[i].mux)
            var zero = false
            let floor = Int(submap[s])
            if floorTypes[floor] == 0 {
                return fail(StbVorbisError.invalidStream)
            }
            let g = floorConfig! + floor
            if getBits(1) != 0 {
                let rangeList: (Int32, Int32, Int32, Int32) = (256, 128, 86, 64)
                let range: Int32
                switch g.pointee.floor1Multiplier {
                case 1: range = rangeList.0
                case 2: range = rangeList.1
                case 3: range = rangeList.2
                default: range = rangeList.3
                }
                var offset = 2
                let finalY = self.finalY[i]!
                let rangeBits = ilog(range) - 1
                finalY[0] = Int16(truncatingIfNeeded: getBits(rangeBits))
                finalY[1] = Int16(truncatingIfNeeded: getBits(rangeBits))
                let partitionClassList = g.pointee.partitionClassList!
                let classDimensions = g.pointee.classDimensions!
                let classSubclasses = g.pointee.classSubclasses!
                let classMasterbooks = g.pointee.classMasterbooks!
                let subclassBooks = g.pointee.subclassBooks!
                for j in 0 ..< Int(g.pointee.partitions) {
                    let pclass = Int(partitionClassList[j])
                    let cdim = Int(classDimensions[pclass])
                    let cbits = Int32(classSubclasses[pclass])
                    let csub = (Int32(1) << cbits) - 1
                    var cval: Int32 = 0
                    if cbits != 0 {
                        let c = codebooks! + Int(classMasterbooks[pclass])
                        cval = decode(c)
                    }
                    for _ in 0 ..< cdim {
                        let book = subclassBooks[pclass * 8 + Int(cval & csub)]
                        cval = cval >> cbits
                        if book >= 0 {
                            let c = codebooks! + Int(book)
                            let temp = decode(c)
                            finalY[offset] = Int16(truncatingIfNeeded: temp)
                        } else {
                            finalY[offset] = 0
                        }
                        offset += 1
                    }
                }
                if validBits == invalidBits {
                    zero = true // as the specification says
                } else {
                    let step2Flag = self.step2Flag
                    let neighbors = g.pointee.neighbors!
                    let xList = g.pointee.xList!
                    step2Flag[0] = 1
                    step2Flag[1] = 1
                    var j = 2
                    while j < Int(g.pointee.values) {
                        let low = Int(neighbors[j * 2])
                        let high = Int(neighbors[j * 2 + 1])
                        let pred = predictPoint(Int32(xList[j]), Int32(xList[low]), Int32(xList[high]),
                                                Int32(finalY[low]), Int32(finalY[high]))
                        let val = Int32(finalY[j])
                        let highroom = range - pred
                        let lowroom = pred
                        let room = highroom < lowroom ? highroom &* 2 : lowroom &* 2
                        if val != 0 {
                            step2Flag[low] = 1
                            step2Flag[high] = 1
                            step2Flag[j] = 1
                            let y: Int32
                            if val >= room {
                                if highroom > lowroom {
                                    y = val &- lowroom &+ pred
                                } else {
                                    y = pred &- val &+ highroom &- 1
                                }
                            } else if val & 1 != 0 {
                                y = pred &- ((val &+ 1) >> 1)
                            } else {
                                y = pred &+ (val >> 1)
                            }
                            finalY[j] = Int16(truncatingIfNeeded: y)
                        } else {
                            step2Flag[j] = 0
                            finalY[j] = Int16(truncatingIfNeeded: pred)
                        }
                        j += 1
                    }

                    // the curve itself is made after the residue
                    for k in 0 ..< Int(g.pointee.values) where step2Flag[k] == 0 {
                        finalY[k] = -1
                    }
                }
            } else {
                zero = true
            }
            zeroChannel[i] = zero
        }

        // channels coupled to one that is not silent are not silent either
        reallyZeroChannel.update(from: zeroChannel, count: channelCount)
        for i in 0 ..< Int(map.pointee.couplingSteps) {
            let magnitude = Int(chan[i].magnitude), angle = Int(chan[i].angle)
            if !zeroChannel[magnitude] || !zeroChannel[angle] {
                zeroChannel[magnitude] = false
                zeroChannel[angle] = false
            }
        }

        // the residues
        for i in 0 ..< Int(map.pointee.submaps) {
            var ch: Int32 = 0
            for j in 0 ..< channelCount where Int(chan[j].mux) == i {
                if zeroChannel[j] {
                    doNotDecode[Int(ch)] = 1
                    residueBuffers[Int(ch)] = nil
                } else {
                    doNotDecode[Int(ch)] = 0
                    residueBuffers[Int(ch)] = channelBuffers[j]
                }
                ch += 1
            }
            let r = Int(submap[15 + i])
            // Only a sixteenth submap's floor, written over the first submap's residue, can be out of range.
            if r >= Int(residueCount) { return fail(StbVorbisError.invalidStream) }
            decodeResidue(residueBuffers, ch, n2, r, doNotDecode)
        }

        // the inverse coupling
        var i = Int(map.pointee.couplingSteps) - 1
        while i >= 0 {
            let n2 = Int(n >> 1)
            let m = channelBuffers[Int(chan[i].magnitude)]!
            let a = channelBuffers[Int(chan[i].angle)]!
            for j in 0 ..< n2 {
                let a2: Float, m2: Float
                if m[j] > 0 {
                    if a[j] > 0 {
                        m2 = m[j]
                        a2 = m[j] - a[j]
                    } else {
                        a2 = m[j]
                        m2 = m[j] + a[j]
                    }
                } else {
                    if a[j] > 0 {
                        m2 = m[j]
                        a2 = m[j] + a[j]
                    } else {
                        a2 = m[j]
                        m2 = m[j] - a[j]
                    }
                }
                m[j] = m2
                a[j] = a2
            }
            i -= 1
        }

        // the floors' curves
        for i in 0 ..< channelCount {
            if reallyZeroChannel[i] {
                channelBuffers[i]!.update(repeating: 0, count: Int(n2))
            } else {
                _ = doFloor(map, i, n, channelBuffers[i]!, finalY[i]!)
            }
        }

        // the inverse MDCT
        for i in 0 ..< channelCount {
            inverseMDCT(channelBuffers[i]!, Int(n), Int(m.pointee.blockflag))
        }

        // only needed after an error, to get to the next packet
        flushPacket()

        if firstDecode {
            // The first sample that is not thrown away is taken to be sample 0. That is not the
            // specification's way, which would read ahead to work it out, but it is the original's.
            currentLoc = 0 &- UInt32(bitPattern: n2)
            // samples may have to be thrown away from the next frame as well
            discardSamplesDeferred = n &- rightEnd
            currentLocValid = true
            firstDecode = false
        } else if discardSamplesDeferred != 0 {
            if discardSamplesDeferred >= rightStart &- leftStart {
                discardSamplesDeferred &-= rightStart &- leftStart
                leftStart = rightStart
                pLeft = leftStart
            } else {
                leftStart &+= discardSamplesDeferred
                pLeft = leftStart
                discardSamplesDeferred = 0
            }
        }

        // is this packet's sample number known from its page?
        if lastSegWhich == endSegWithKnownLoc {
            // the last page: work out the length of the (probably) short last frame
            if currentLocValid && pageFlag & pageflagLastPage != 0 {
                let currentEnd = knownLocForPacket
                if currentEnd < currentLoc &+ UInt32(bitPattern: rightEnd &- leftStart) {
                    if currentEnd < currentLoc {
                        len = 0 // a cut below nothing cannot be
                    } else {
                        len = Int32(bitPattern: currentEnd &- currentLoc)
                    }
                    len &+= leftStart // the original's comment says this "doesn't seem right"
                    if len > rightEnd { len = rightEnd }
                    currentLoc &+= UInt32(bitPattern: len)
                    return true
                }
            }
            // otherwise the page's granule is taken to be the middle of the last frame
            currentLoc = knownLocForPacket &- UInt32(bitPattern: n2 &- leftStart)
            currentLocValid = true
        }
        if currentLocValid {
            currentLoc &+= UInt32(bitPattern: rightStart &- leftStart)
        }

        len = rightEnd // the samples after the window reaches 0 are not wanted
        return true
    }

    /// vorbis_decode_packet.
    mutating func vorbisDecodePacket(_ len: inout Int32, _ pLeft: inout Int32, _ pRight: inout Int32) -> Bool {
        var mode: Int32 = 0, leftEnd: Int32 = 0, rightEnd: Int32 = 0
        if !vorbisDecodeInitial(&pLeft, &leftEnd, &pRight, &rightEnd, &mode) { return false }
        return vorbisDecodePacketRest(&len, modeConfig + Int(mode), pLeft, pRight, rightEnd, &pLeft)
    }

    /// vorbis_finish_frame: the overlap with the frame before, and what of this one waits for the next.
    mutating func vorbisFinishFrame(_ len: Int32, _ left: Int32, _ rightIn: Int32) -> Int32 {
        var right = rightIn
        // the overlap with the window before
        if previousLength != 0 {
            let n = previousLength
            guard let w = getWindow(n) else { return 0 }
            // Not in the original, which cannot get here with a frame that runs off its buffers.
            if left < 0 || Int(left) + Int(n) > Int(blocksize1) { return 0 }
            for i in 0 ..< Int(channels) {
                let buffer = channelBuffers[i]! + Int(left)
                let previous = previousWindow[i]!
                for j in 0 ..< Int(n) {
                    buffer[j] = buffer[j] * w[j] + previous[j] * w[Int(n) - 1 - j]
                }
            }
        }

        let prev = previousLength

        // the end of this frame is the next one's overlap
        previousLength = len &- right

        if right >= 0 && len > right && len <= blocksize1 {
            for i in 0 ..< Int(channels) {
                (previousWindow[i]!).update(from: channelBuffers[i]! + Int(right), count: Int(len - right))
            }
        }

        // with no packet before, this one has nothing to give, as the specification has it
        if prev == 0 { return 0 }

        // a short last frame
        if len < right { right = len }

        samplesOutput &+= UInt32(bitPattern: right &- left)

        return right &- left
    }

    /// is_whole_packet_present: whether the next packet is all in this call's bytes, by walking its pages.
    mutating func isWholePacketPresent() -> Bool {
        var s = nextSeg
        var first = true
        var p = stream

        if s != -1 { // the packet does not start on the next page
            while s < segmentCount {
                p += Int(segments[Int(s)])
                if segments[Int(s)] < 255 { break } // the first short segment ends it
                s += 1
            }
            // either it goes on to the next page, or it ends here
            if s == segmentCount { s = -1 }
            if p > streamEnd { return fail(StbVorbisError.needMoreData) }
            first = false
        }
        while s == -1 {
            // the page's header must be here
            if p + 26 >= streamEnd { return fail(StbVorbisError.needMoreData) }
            // and be a page's
            if data[p] != 0x4F || data[p + 1] != 0x67 || data[p + 2] != 0x67 || data[p + 3] != 0x53 {
                return fail(StbVorbisError.invalidStream)
            }
            if data[p + 4] != 0 { return fail(StbVorbisError.invalidStream) }
            if first { // the first page must not go on from a packet; the later ones must
                if previousLength != 0 {
                    if data[p + 5] & pageflagContinuedPacket != 0 { return fail(StbVorbisError.invalidStream) }
                }
                // with no frame before, the decoder is finding its place, and can start on one, to throw away
            } else {
                if data[p + 5] & pageflagContinuedPacket == 0 { return fail(StbVorbisError.invalidStream) }
            }
            let n = Int(data[p + 26]) // the number of segments
            let q = p + 27 // the segment table
            p = q + n // past the header
            // the segment table must be here
            if p > streamEnd { return fail(StbVorbisError.needMoreData) }
            var k = 0
            while k < n {
                p += Int(data[q + k])
                if data[q + k] < 255 { break }
                k += 1
            }
            s = Int32(k)
            if k == n { s = -1 } // it goes on to the next page
            if p > streamEnd { return fail(StbVorbisError.needMoreData) }
            first = false
        }
        return true
    }

    // MARK: Setup

    /// start_decoder: the three header packets.
    mutating func startDecoder() -> Bool {
        var longestFloorlist: Int32 = 0

        // the first page, the first packet
        firstDecode = true

        if !startPage() { return false }
        // the page's flags
        if pageFlag & pageflagFirstPage == 0 { return fail(StbVorbisError.invalidFirstPage) }
        if pageFlag & pageflagLastPage != 0 { return fail(StbVorbisError.invalidFirstPage) }
        if pageFlag & pageflagContinuedPacket != 0 { return fail(StbVorbisError.invalidFirstPage) }
        // the packet's length
        if segmentCount != 1 { return fail(StbVorbisError.invalidFirstPage) }
        let header = headerBytes
        if segments[0] != 30 {
            // the Ogg skeleton's "fishead" header, for the error to say so
            if segments[0] == 64,
               getn(header, 6),
               header[0] == UInt8(ascii: "f"), header[1] == UInt8(ascii: "i"), header[2] == UInt8(ascii: "s"),
               header[3] == UInt8(ascii: "h"), header[4] == UInt8(ascii: "e"), header[5] == UInt8(ascii: "a"),
               get8() == UInt8(ascii: "d"), get8() == 0
            {
                return fail(StbVorbisError.oggSkeletonNotSupported)
            } else {
                return fail(StbVorbisError.invalidFirstPage)
            }
        }

        // the identification header
        if Int32(get8()) != packetID { return fail(StbVorbisError.invalidFirstPage) }
        if !getn(header, 6) { return fail(StbVorbisError.unexpectedEOF) }
        if !Self.isVorbis(header) { return fail(StbVorbisError.invalidFirstPage) }
        // vorbis_version
        if get32() != 0 { return fail(StbVorbisError.invalidFirstPage) }
        channels = Int32(get8())
        if channels == 0 { return fail(StbVorbisError.invalidFirstPage) }
        if channels > Int32(maxChannels) { return fail(StbVorbisError.tooManyChannels) }
        sampleRate = get32()
        if sampleRate == 0 { return fail(StbVorbisError.invalidFirstPage) }
        _ = get32() // bitrate_maximum
        _ = get32() // bitrate_nominal
        _ = get32() // bitrate_minimum
        var x = get8()
        do {
            let log0 = Int32(x & 15)
            let log1 = Int32(x >> 4)
            blocksize0 = 1 &<< log0
            blocksize1 = 1 &<< log1
            if log0 < 6 || log0 > 13 { return fail(StbVorbisError.invalidSetup) }
            if log1 < 6 || log1 > 13 { return fail(StbVorbisError.invalidSetup) }
            if log0 > log1 { return fail(StbVorbisError.invalidSetup) }
        }

        // framing_flag
        x = get8()
        if x & 1 == 0 { return fail(StbVorbisError.invalidFirstPage) }

        // the second packet, the comments
        if !startPage() { return false }
        if !startPacket() { return false }
        if nextSegment() == 0 { return false }

        if get8Packet() != packetComment { return fail(StbVorbisError.invalidSetup) }
        for i in 0 ..< 6 { header[i] = UInt8(truncatingIfNeeded: get8Packet()) }
        if !Self.isVorbis(header) { return fail(StbVorbisError.invalidSetup) }
        // the vendor
        var len = get32Packet()
        if !readCommentString(len, keep: false) { return fail(StbVorbisError.outOfMemory) }
        // the user comments
        let commentListLength = get32Packet()
        comments = []
        if commentListLength > 0 {
            if !Self.cMallocWouldGive(commentListLength &* 8) { return fail(StbVorbisError.outOfMemory) }
        }
        var i: Int32 = 0
        while i < commentListLength {
            len = get32Packet()
            if !readCommentString(len, keep: true) { return fail(StbVorbisError.outOfMemory) }
            i += 1
        }

        // framing_flag
        x = UInt8(truncatingIfNeeded: get8Packet())
        if x & 1 == 0 { return fail(StbVorbisError.invalidSetup) }

        skip(Int(bytesInSeg))
        bytesInSeg = 0

        repeat {
            len = nextSegment()
            skip(Int(len))
            bytesInSeg = 0
        } while len != 0

        // the third packet, the setup
        if !startPacket() { return false }

        if !isWholePacketPresent() {
            // an error in the page's header is an error in the setup
            if error == StbVorbisError.invalidStream { error = StbVorbisError.invalidSetup }
            return false
        }

        if get8Packet() != packetSetup { return fail(StbVorbisError.invalidSetup) }
        for i in 0 ..< 6 { header[i] = UInt8(truncatingIfNeeded: get8Packet()) }
        if !Self.isVorbis(header) { return fail(StbVorbisError.invalidSetup) }

        if !setupCodebooks() { return false }

        // the time domain transforms, which are not used
        x = UInt8(truncatingIfNeeded: getBits(6) &+ 1)
        for _ in 0 ..< Int(x) {
            let z = getBits(16)
            if z != 0 { return fail(StbVorbisError.invalidSetup) }
        }

        if !setupFloors(&longestFloorlist) { return false }
        if !setupResidues() { return false }
        if !setupMappings() { return false }

        // the modes
        modeCount = Int32(getBits(6)) + 1
        for i in 0 ..< Int(modeCount) {
            let m = modeConfig + i
            m.pointee.blockflag = UInt8(truncatingIfNeeded: getBits(1))
            m.pointee.windowtype = UInt16(truncatingIfNeeded: getBits(16))
            m.pointee.transformtype = UInt16(truncatingIfNeeded: getBits(16))
            m.pointee.mapping = UInt8(truncatingIfNeeded: getBits(8))
            if m.pointee.windowtype != 0 { return fail(StbVorbisError.invalidSetup) }
            if m.pointee.transformtype != 0 { return fail(StbVorbisError.invalidSetup) }
            if Int32(m.pointee.mapping) >= mappingCount { return fail(StbVorbisError.invalidSetup) }
        }

        flushPacket()

        previousLength = 0

        for i in 0 ..< Int(channels) {
            channelBuffers[i] = setupMalloc(Int(blocksize1), Float.self)
            previousWindow[i] = setupMalloc(Int(blocksize1 / 2), Float.self)
            finalY[i] = setupMalloc(Int(longestFloorlist), Int16.self)
            if channelBuffers[i] == nil || previousWindow[i] == nil || finalY[i] == nil {
                return fail(StbVorbisError.outOfMemory)
            }
        }

        if !initBlocksize(0, blocksize0) { return false }
        if !initBlocksize(1, blocksize1) { return false }

        // The memory the original takes for the length of a frame, taken now: the IMDCT's buffer, and
        // the classifications of the most partitions any residue can have in a block (for residue
        // type 2, twice as many as the others, as its lengths are of all its channels together).
        imdctBuffer = setupMalloc(Int(blocksize1 >> 1), Float.self)
        var maxPartRead = 1
        for i in 0 ..< Int(residueCount) {
            let r = residueConfig! + i
            let actualSize = UInt32(blocksize1)
            let begin = r.pointee.begin < actualSize ? r.pointee.begin : actualSize
            let end = r.pointee.end < actualSize ? r.pointee.end : actualSize
            let partRead = Int((end &- begin) / r.pointee.partSize)
            if partRead > maxPartRead { maxPartRead = partRead }
        }
        partClassdataPerChannel = maxPartRead
        partClassdata = setupMalloc(Int(channels) * maxPartRead, UnsafeMutablePointer<UInt8>?.self)
        if imdctBuffer == nil || partClassdata == nil { return fail(StbVorbisError.outOfMemory) }

        return true
    }

    /// vorbis_validate: "vorbis".
    private static func isVorbis(_ h: UnsafeMutablePointer<UInt8>) -> Bool {
        h[0] == 0x76 && h[1] == 0x6F && h[2] == 0x72 && h[3] == 0x62 && h[4] == 0x69 && h[5] == 0x73
    }

    /// Whether the original's setup_malloc would find memory of this size, for the comments, which are
    /// not kept here in memory of that size. Its size is a C int, so that a size made from a number in
    /// the file can wrap: it fails for one that rounds up to nothing or below, and malloc gives what it
    /// is then asked for (up to two gigabytes, which the machines it is checked on give).
    private static func cMallocWouldGive(_ size: Int32) -> Bool {
        (size &+ 7) & ~7 > 0
    }

    /// A string of the comment header, of `len` bytes: kept as one of the comments if `keep`. False
    /// where the original would fail to find memory for it. Once the packet has ended, every byte
    /// still to be read is the end of the packet again, with nothing else changed, and the rest are
    /// not read one by one.
    private mutating func readCommentString(_ len: Int32, keep: Bool) -> Bool {
        if !Self.cMallocWouldGive(len &+ 1) { return false }
        var bytes: [UInt8] = []
        var j: Int32 = 0
        while j < len {
            let b = get8Packet()
            if b == EOP {
                if lastSeg && bytesInSeg == 0 { break }
            } else if keep {
                bytes.append(UInt8(b))
            }
            j += 1
        }
        if keep { comments.append(bytes) }
        return true
    }

    /// The codebooks, from start_decoder.
    private mutating func setupCodebooks() -> Bool {
        codebookCount = Int32(getBits(8)) + 1
        guard let books = setupMalloc(Int(codebookCount), VorbisCodebook.self),
              let fast = setupMalloc(Int(codebookCount) * fastHuffmanTableSize, Int16.self)
        else { return fail(StbVorbisError.outOfMemory) }
        codebooks = books
        for i in 0 ..< Int(codebookCount) {
            let c = books + i
            c.pointee.fastHuffman = fast + i * fastHuffmanTableSize
            var x = UInt8(truncatingIfNeeded: getBits(8))
            if x != 0x42 { return fail(StbVorbisError.invalidSetup) }
            x = UInt8(truncatingIfNeeded: getBits(8))
            if x != 0x43 { return fail(StbVorbisError.invalidSetup) }
            x = UInt8(truncatingIfNeeded: getBits(8))
            if x != 0x56 { return fail(StbVorbisError.invalidSetup) }
            x = UInt8(truncatingIfNeeded: getBits(8))
            c.pointee.dimensions = Int32(getBits(8) << 8) + Int32(x)
            x = UInt8(truncatingIfNeeded: getBits(8))
            let y = UInt8(truncatingIfNeeded: getBits(8))
            c.pointee.entries = Int32(getBits(8) << 16) + (Int32(y) << 8) + Int32(x)
            let ordered = getBits(1)
            c.pointee.sparse = ordered != 0 ? 0 : UInt8(getBits(1))

            if c.pointee.dimensions == 0 && c.pointee.entries != 0 { return fail(StbVorbisError.invalidSetup) }
            let entries = Int(c.pointee.entries)

            // The lengths of a sparse codebook are only for the length of its setup: the original takes
            // them from its temporary memory, which, unlike its setup memory, it gives even for nothing.
            let lengths: UnsafeMutablePointer<UInt8>
            if c.pointee.sparse != 0 {
                guard let l = setupMalloc(max(entries, 1), UInt8.self) else { return fail(StbVorbisError.outOfMemory) }
                lengths = l
            } else {
                guard let l = setupMalloc(entries, UInt8.self) else { return fail(StbVorbisError.outOfMemory) }
                lengths = l
                c.pointee.codewordLengths = l
            }

            var total: Int32 = 0
            if ordered != 0 {
                var currentEntry: Int32 = 0
                var currentLength = Int32(getBits(5)) + 1
                while currentEntry < c.pointee.entries {
                    let limit = c.pointee.entries - currentEntry
                    let n = Int32(getBits(ilog(limit)))
                    if currentLength >= 32 { return fail(StbVorbisError.invalidSetup) }
                    if currentEntry + n > c.pointee.entries { return fail(StbVorbisError.invalidSetup) }
                    (lengths + Int(currentEntry)).update(repeating: UInt8(currentLength), count: Int(n))
                    currentEntry += n
                    currentLength += 1
                }
            } else {
                for j in 0 ..< entries {
                    let present = c.pointee.sparse != 0 ? getBits(1) : 1
                    if present != 0 {
                        lengths[j] = UInt8(getBits(5) + 1)
                        total += 1
                        if lengths[j] == 32 { return fail(StbVorbisError.invalidSetup) }
                    } else {
                        lengths[j] = noCode
                    }
                }
            }

            if c.pointee.sparse != 0 && total >= c.pointee.entries >> 2 {
                // enough of a sparse codebook is there for it not to be sparse
                guard let l = setupMalloc(entries, UInt8.self) else { return fail(StbVorbisError.outOfMemory) }
                l.update(from: lengths, count: entries)
                c.pointee.codewordLengths = l
                c.pointee.sparse = 0
            }
            let codeLengths = c.pointee.sparse != 0 ? lengths : c.pointee.codewordLengths!

            // the size of the sorted tables
            let sortedCount: Int32
            if c.pointee.sparse != 0 {
                sortedCount = total
            } else {
                var count: Int32 = 0
                for j in 0 ..< entries where codeLengths[j] > UInt8(fastHuffmanLength) && codeLengths[j] != noCode {
                    count += 1
                }
                sortedCount = count
            }

            c.pointee.sortedEntries = sortedCount
            var values: UnsafeMutablePointer<UInt32>?

            if c.pointee.sparse == 0 {
                c.pointee.codewords = setupMalloc(entries, UInt32.self)
                if c.pointee.codewords == nil { return fail(StbVorbisError.outOfMemory) }
            } else {
                if c.pointee.sortedEntries != 0 {
                    c.pointee.codewordLengths = setupMalloc(Int(sortedCount), UInt8.self)
                    if c.pointee.codewordLengths == nil { return fail(StbVorbisError.outOfMemory) }
                    c.pointee.codewords = setupMalloc(Int(sortedCount), UInt32.self)
                    if c.pointee.codewords == nil { return fail(StbVorbisError.outOfMemory) }
                    values = setupMalloc(Int(sortedCount), UInt32.self)
                    if values == nil { return fail(StbVorbisError.outOfMemory) }
                }
            }

            if !computeCodewords(c, codeLengths, c.pointee.entries, values) {
                return fail(StbVorbisError.invalidSetup)
            }

            if c.pointee.sortedEntries != 0 {
                // with a place more, for the guard at the end
                c.pointee.sortedCodewords = setupMalloc(Int(sortedCount) + 1, UInt32.self)
                if c.pointee.sortedCodewords == nil { return fail(StbVorbisError.outOfMemory) }
                // with a place more at the front, so that sortedValues[-1] is there
                guard let sortedValues = setupMalloc(Int(sortedCount) + 1, Int32.self) else {
                    return fail(StbVorbisError.outOfMemory)
                }
                c.pointee.sortedValues = sortedValues + 1
                sortedValues[0] = -1
                computeSortedHuffman(c, codeLengths, values)
            }

            if c.pointee.sparse != 0 {
                c.pointee.codewords = nil
            }

            computeAcceleratedHuffman(c)
            if !findFarCodes(c) { return fail(StbVorbisError.outOfMemory) }

            c.pointee.lookupType = UInt8(getBits(4))
            if c.pointee.lookupType > 2 { return fail(StbVorbisError.invalidSetup) }
            if c.pointee.lookupType > 0 {
                c.pointee.minimumValue = float32Unpack(getBits(32))
                c.pointee.deltaValue = float32Unpack(getBits(32))
                c.pointee.valueBits = UInt8(getBits(4) + 1)
                c.pointee.sequenceP = UInt8(getBits(1))
                if c.pointee.lookupType == 1 {
                    let values = lookup1Values(c.pointee.entries, c.pointee.dimensions)
                    if values < 0 { return fail(StbVorbisError.invalidSetup) }
                    c.pointee.lookupValues = UInt32(values)
                } else {
                    c.pointee.lookupValues = UInt32(bitPattern: c.pointee.entries &* c.pointee.dimensions)
                    // Not the original's: it reads past its multiplicands when that product overflows.
                    if Int64(c.pointee.entries) * Int64(c.pointee.dimensions) != Int64(c.pointee.lookupValues) {
                        return fail(StbVorbisError.outOfMemory)
                    }
                }
                if c.pointee.lookupValues == 0 { return fail(StbVorbisError.invalidSetup) }
                if c.pointee.lookupValues > UInt32(setupMemoryLimit) { return fail(StbVorbisError.outOfMemory) }
                guard let mults = setupMalloc(Int(c.pointee.lookupValues), UInt16.self) else {
                    return fail(StbVorbisError.outOfMemory)
                }
                let valueBits = Int32(c.pointee.valueBits)
                for j in 0 ..< Int(c.pointee.lookupValues) {
                    mults[j] = UInt16(truncatingIfNeeded: getBits(valueBits))
                }

                // Room past the end, for the vectors that residue type 2 reads beyond the last (see
                // `codebookDecodeDeinterleaveRepeat`): the original reads its other memory there.
                let slack = 2 * maxChannels + 32
                let delta = c.pointee.deltaValue, minimum = c.pointee.minimumValue
                let sequence = c.pointee.sequenceP != 0
                if c.pointee.lookupType == 1 {
                    let sparse = c.pointee.sparse != 0
                    var last: Float = 0
                    // the multiplicands of every vector, worked out now, so as not to divide for each
                    if sparse && c.pointee.sortedEntries == 0 { continue }
                    let len = Int(sparse ? c.pointee.sortedEntries : c.pointee.entries)
                    let dimensions = Int(c.pointee.dimensions)
                    guard let multiplicands = setupMalloc(Int64(len) * Int64(dimensions), Float.self, slack: slack) else {
                        return fail(StbVorbisError.outOfMemory)
                    }
                    c.pointee.multiplicands = multiplicands
                    let lookupValues = c.pointee.lookupValues
                    for j in 0 ..< len {
                        let z = sparse ? UInt32(bitPattern: c.pointee.sortedValues![j]) : UInt32(j)
                        var div: UInt32 = 1
                        for k in 0 ..< dimensions {
                            let off = Int((z / div) % lookupValues)
                            let val = Float(mults[off]) * delta + minimum + last
                            multiplicands[j * dimensions + k] = val
                            if sequence { last = val }
                            if k + 1 < dimensions {
                                if div > UInt32.max / lookupValues { return fail(StbVorbisError.invalidSetup) }
                                div &*= lookupValues
                            }
                        }
                    }
                    c.pointee.lookupType = 2
                } else {
                    var last: Float = 0
                    guard let multiplicands = setupMalloc(Int(c.pointee.lookupValues), Float.self, slack: slack) else {
                        return fail(StbVorbisError.outOfMemory)
                    }
                    c.pointee.multiplicands = multiplicands
                    for j in 0 ..< Int(c.pointee.lookupValues) {
                        let val = Float(mults[j]) * delta + minimum + last
                        multiplicands[j] = val
                        if sequence { last = val }
                    }
                }
            }
        }
        return true
    }

    /// compute_codewords: the codes of a codebook from their lengths, each the first free one of its
    /// length, as the specification has it.
    private func computeCodewords(_ c: UnsafeMutablePointer<VorbisCodebook>, _ len: UnsafeMutablePointer<UInt8>, _ n: Int32,
                                  _ values: UnsafeMutablePointer<UInt32>?) -> Bool
    {
        var available = [UInt32](repeating: 0, count: 32)
        var m: Int32 = 0
        // the first entry
        var k: Int32 = 0
        while k < n {
            if len[Int(k)] < noCode { break }
            k += 1
        }
        if k == n { return true }
        addEntry(c, 0, k, m, Int32(len[Int(k)]), values)
        m += 1
        // every free leaf
        var i: Int32 = 1
        while i <= Int32(len[Int(k)]) {
            available[Int(i)] = 1 &<< UInt32(32 - i)
            i += 1
        }
        i = k + 1
        while i < n {
            var z = Int32(len[Int(i)])
            if z == Int32(noCode) {
                i += 1
                continue
            }
            // the lowest free leaf, which is the earliest
            while z > 0 && available[Int(z)] == 0 { z -= 1 }
            if z == 0 { return false }
            let res = available[Int(z)]
            available[Int(z)] = 0
            addEntry(c, bitReverse(res), i, m, Int32(len[Int(i)]), values)
            m += 1
            // the leaves below it are free
            if z != Int32(len[Int(i)]) {
                var y = Int32(len[Int(i)])
                while y > z {
                    available[Int(y)] = res &+ (1 &<< UInt32(32 - y))
                    y -= 1
                }
            }
            i += 1
        }
        return true
    }

    /// add_entry.
    @inline(__always)
    private func addEntry(_ c: UnsafeMutablePointer<VorbisCodebook>, _ huffCode: UInt32, _ symbol: Int32, _ count: Int32,
                          _ len: Int32, _ values: UnsafeMutablePointer<UInt32>?)
    {
        if c.pointee.sparse == 0 {
            c.pointee.codewords![Int(symbol)] = huffCode
        } else {
            c.pointee.codewords![Int(count)] = huffCode
            c.pointee.codewordLengths![Int(count)] = UInt8(truncatingIfNeeded: len)
            values![Int(count)] = UInt32(bitPattern: symbol)
        }
    }

    /// compute_accelerated_huffman: the quick table, of every code of ten bits or less.
    private func computeAcceleratedHuffman(_ c: UnsafeMutablePointer<VorbisCodebook>) {
        let fast = c.pointee.fastHuffman!
        fast.update(repeating: -1, count: fastHuffmanTableSize)
        var len = c.pointee.sparse != 0 ? c.pointee.sortedEntries : c.pointee.entries
        if len > 32767 { len = 32767 } // the most a 16-bit table can say
        guard let lengths = c.pointee.codewordLengths else { return }
        for i in 0 ..< Int(len) where lengths[i] <= UInt8(fastHuffmanLength) {
            var z = c.pointee.sparse != 0 ? bitReverse(c.pointee.sortedCodewords![i]) : c.pointee.codewords![i]
            // every combination of the bits above it
            while z < UInt32(fastHuffmanTableSize) {
                fast[Int(z)] = Int16(i)
                z += 1 << UInt32(lengths[i])
            }
        }
    }

    /// Not the original's: the symbols at 32767 and on that have codes, for a codebook that is
    /// searched in order (see `codebookDecodeScalarRaw`). False if there is no memory for them.
    private mutating func findFarCodes(_ c: UnsafeMutablePointer<VorbisCodebook>) -> Bool {
        if c.pointee.entries <= 32767 || c.pointee.sortedCodewords != nil || c.pointee.codewords == nil { return true }
        let lengths = c.pointee.codewordLengths!
        var count = 0
        for i in 32767 ..< Int(c.pointee.entries) where lengths[i] != noCode { count += 1 }
        if count == 0 { return true }
        guard let far = setupMalloc(count, Int32.self) else { return false }
        var k = 0
        for i in 32767 ..< Int(c.pointee.entries) where lengths[i] != noCode {
            far[k] = Int32(i)
            k += 1
        }
        c.pointee.farCodes = far
        c.pointee.farCodeCount = Int32(count)
        return true
    }

    /// include_in_sort.
    @inline(__always)
    private func includeInSort(_ c: UnsafeMutablePointer<VorbisCodebook>, _ len: UInt8) -> Bool {
        if c.pointee.sparse != 0 { return true }
        if len == noCode { return false }
        if len > UInt8(fastHuffmanLength) { return true }
        return false
    }

    /// compute_sorted_huffman: the codes too long for the quick table, reversed and sorted, for the
    /// binary search, with the symbol of each.
    private func computeSortedHuffman(_ c: UnsafeMutablePointer<VorbisCodebook>, _ lengths: UnsafeMutablePointer<UInt8>,
                                      _ values: UnsafeMutablePointer<UInt32>?)
    {
        let sorted = c.pointee.sortedCodewords!
        let sortedEntries = Int(c.pointee.sortedEntries)
        if c.pointee.sparse == 0 {
            var k = 0
            for i in 0 ..< Int(c.pointee.entries) where includeInSort(c, lengths[i]) {
                sorted[k] = bitReverse(c.pointee.codewords![i])
                k += 1
            }
        } else {
            for i in 0 ..< sortedEntries {
                sorted[i] = bitReverse(c.pointee.codewords![i])
            }
        }

        var buffer = UnsafeMutableBufferPointer(start: sorted, count: sortedEntries)
        buffer.sort()
        sorted[sortedEntries] = 0xFFFF_FFFF

        let len = Int(c.pointee.sparse != 0 ? c.pointee.sortedEntries : c.pointee.entries)
        // for each entry, its place among the sorted, by binary search
        for i in 0 ..< len {
            let huffLen = c.pointee.sparse != 0 ? lengths[Int(values![i])] : lengths[i]
            if includeInSort(c, huffLen) {
                let code = bitReverse(c.pointee.codewords![i])
                var x = 0, n = sortedEntries
                while n > 1 {
                    // sorted[x] <= code < sorted[x + n]
                    let m = x + (n >> 1)
                    if sorted[m] <= code {
                        x = m
                        n -= n >> 1
                    } else {
                        n >>= 1
                    }
                }
                if c.pointee.sparse != 0 {
                    c.pointee.sortedValues![x] = Int32(bitPattern: values![i])
                    c.pointee.codewordLengths![x] = huffLen
                } else {
                    c.pointee.sortedValues![x] = Int32(i)
                }
            }
        }
    }

    /// The floors, from start_decoder.
    private mutating func setupFloors(_ longestFloorlist: inout Int32) -> Bool {
        floorCount = Int32(getBits(6)) + 1
        guard let floors = setupMalloc(Int(floorCount), VorbisFloor1.self) else { return fail(StbVorbisError.outOfMemory) }
        floorConfig = floors
        for i in 0 ..< Int(floorCount) {
            floorTypes[i] = UInt16(truncatingIfNeeded: getBits(16))
            if floorTypes[i] > 1 { return fail(StbVorbisError.invalidSetup) }
            if floorTypes[i] == 0 {
                // order, rate, bark_map_size, amplitude_bits, amplitude_offset, and the books
                _ = getBits(8)
                _ = getBits(16)
                _ = getBits(16)
                _ = getBits(6)
                _ = getBits(8)
                let books = getBits(4) + 1
                for _ in 0 ..< Int(books) { _ = getBits(8) }
                return fail(StbVorbisError.featureNotSupported)
            }
            let g = floors + i
            guard let partitionClassList = setupMalloc(32, UInt8.self),
                  let classDimensions = setupMalloc(16, UInt8.self),
                  let classSubclasses = setupMalloc(16, UInt8.self),
                  let classMasterbooks = setupMalloc(16, UInt8.self),
                  let subclassBooks = setupMalloc(16 * 8, Int16.self),
                  let xList = setupMalloc(31 * 8 + 2, UInt16.self),
                  let sortedOrder = setupMalloc(31 * 8 + 2, UInt8.self),
                  let neighbors = setupMalloc((31 * 8 + 2) * 2, UInt8.self)
            else { return fail(StbVorbisError.outOfMemory) }
            g.pointee.partitionClassList = partitionClassList
            g.pointee.classDimensions = classDimensions
            g.pointee.classSubclasses = classSubclasses
            g.pointee.classMasterbooks = classMasterbooks
            g.pointee.subclassBooks = subclassBooks
            g.pointee.xList = xList
            g.pointee.sortedOrder = sortedOrder
            g.pointee.neighbors = neighbors

            var maxClass: Int32 = -1
            g.pointee.partitions = UInt8(getBits(5))
            for j in 0 ..< Int(g.pointee.partitions) {
                partitionClassList[j] = UInt8(getBits(4))
                if Int32(partitionClassList[j]) > maxClass { maxClass = Int32(partitionClassList[j]) }
            }
            var j: Int32 = 0
            while j <= maxClass {
                let jj = Int(j)
                classDimensions[jj] = UInt8(getBits(3) + 1)
                classSubclasses[jj] = UInt8(getBits(2))
                if classSubclasses[jj] != 0 {
                    classMasterbooks[jj] = UInt8(getBits(8))
                    if Int32(classMasterbooks[jj]) >= codebookCount { return fail(StbVorbisError.invalidSetup) }
                }
                for k in 0 ..< (1 << Int(classSubclasses[jj])) {
                    subclassBooks[jj * 8 + k] = Int16(truncatingIfNeeded: getBits(8)) - 1
                    if Int32(subclassBooks[jj * 8 + k]) >= codebookCount { return fail(StbVorbisError.invalidSetup) }
                }
                j += 1
            }
            g.pointee.floor1Multiplier = UInt8(getBits(2) + 1)
            g.pointee.rangebits = UInt8(getBits(4))
            xList[0] = 0
            xList[1] = UInt16(1 << Int(g.pointee.rangebits))
            var values = 2
            for j in 0 ..< Int(g.pointee.partitions) {
                let c = Int(partitionClassList[j])
                for _ in 0 ..< Int(classDimensions[c]) {
                    xList[values] = UInt16(truncatingIfNeeded: getBits(Int32(g.pointee.rangebits)))
                    values += 1
                }
            }
            g.pointee.values = Int32(values)
            // the order of the points, sorted by place
            var points = [UInt32](repeating: 0, count: values)
            for j in 0 ..< values { points[j] = UInt32(xList[j]) << 16 | UInt32(j) }
            points.sort()
            for j in 0 ..< values - 1 where points[j] >> 16 == points[j + 1] >> 16 {
                return fail(StbVorbisError.invalidSetup)
            }
            for j in 0 ..< values { sortedOrder[j] = UInt8(truncatingIfNeeded: points[j]) }
            // the neighbours of each
            for j in 2 ..< values {
                var low = 0, hi = 0
                var lowX = -1, highX = 65536
                let x = Int(xList[j])
                for k in 0 ..< j {
                    let xk = Int(xList[k])
                    if xk > lowX && xk < x {
                        low = k
                        lowX = xk
                    }
                    if xk < highX && xk > x {
                        hi = k
                        highX = xk
                    }
                }
                neighbors[j * 2] = UInt8(truncatingIfNeeded: low)
                neighbors[j * 2 + 1] = UInt8(truncatingIfNeeded: hi)
            }

            if Int32(values) > longestFloorlist { longestFloorlist = Int32(values) }
        }
        return true
    }

    /// The residues, from start_decoder.
    private mutating func setupResidues() -> Bool {
        residueCount = Int32(getBits(6)) + 1
        guard let residues = setupMalloc(Int(residueCount), VorbisResidue.self) else { return fail(StbVorbisError.outOfMemory) }
        residueConfig = residues
        var residueCascade = [UInt8](repeating: 0, count: 64)
        for i in 0 ..< Int(residueCount) {
            let r = residues + i
            residueTypes[i] = UInt16(truncatingIfNeeded: getBits(16))
            if residueTypes[i] > 2 { return fail(StbVorbisError.invalidSetup) }
            r.pointee.begin = getBits(24)
            r.pointee.end = getBits(24)
            if r.pointee.end < r.pointee.begin { return fail(StbVorbisError.invalidSetup) }
            r.pointee.partSize = getBits(24) + 1
            r.pointee.classifications = UInt8(getBits(6) + 1)
            r.pointee.classbook = UInt8(getBits(8))
            if Int32(r.pointee.classbook) >= codebookCount { return fail(StbVorbisError.invalidSetup) }
            let classifications = Int(r.pointee.classifications)
            for j in 0 ..< classifications {
                var highBits: UInt8 = 0
                let lowBits = UInt8(getBits(3))
                if getBits(1) != 0 { highBits = UInt8(getBits(5)) }
                residueCascade[j] = highBits &* 8 &+ lowBits
            }
            guard let books = setupMalloc(classifications * 8, Int16.self) else { return fail(StbVorbisError.outOfMemory) }
            r.pointee.residueBooks = books
            for j in 0 ..< classifications {
                for k in 0 ..< 8 {
                    if residueCascade[j] & (1 << UInt8(k)) != 0 {
                        books[j * 8 + k] = Int16(getBits(8))
                        if Int32(books[j * 8 + k]) >= codebookCount { return fail(StbVorbisError.invalidSetup) }
                    } else {
                        books[j * 8 + k] = -1
                    }
                }
            }
            // every classbook entry's classifications, worked out now, so as not to divide while decoding
            let classbook = codebooks! + Int(r.pointee.classbook)
            let entries = Int(classbook.pointee.entries)
            guard let classdata = setupMalloc(entries, UnsafeMutablePointer<UInt8>?.self) else {
                return fail(StbVorbisError.outOfMemory)
            }
            r.pointee.classdata = classdata
            let classwords = Int(classbook.pointee.dimensions)
            for j in 0 ..< entries {
                var temp = Int32(j)
                guard let d = setupMalloc(classwords, UInt8.self) else { return fail(StbVorbisError.outOfMemory) }
                classdata[j] = d
                var k = classwords - 1
                while k >= 0 {
                    d[k] = UInt8(truncatingIfNeeded: temp % Int32(classifications))
                    temp /= Int32(classifications)
                    k -= 1
                }
            }
        }
        return true
    }

    /// The mappings, from start_decoder.
    private mutating func setupMappings() -> Bool {
        mappingCount = Int32(getBits(6)) + 1
        guard let mappings = setupMalloc(Int(mappingCount), VorbisMapping.self) else { return fail(StbVorbisError.outOfMemory) }
        mapping = mappings
        for i in 0 ..< Int(mappingCount) {
            let m = mappings + i
            let mappingType = getBits(16)
            if mappingType != 0 { return fail(StbVorbisError.invalidSetup) }
            guard let chan = setupMalloc(Int(channels), VorbisMappingChannel.self),
                  let submap = setupMalloc(32, UInt8.self)
            else { return fail(StbVorbisError.outOfMemory) }
            m.pointee.chan = chan
            m.pointee.submap = submap
            if getBits(1) != 0 {
                m.pointee.submaps = UInt8(getBits(4) + 1)
            } else {
                m.pointee.submaps = 1
            }
            if getBits(1) != 0 {
                m.pointee.couplingSteps = UInt16(getBits(8) + 1)
                if Int32(m.pointee.couplingSteps) > channels { return fail(StbVorbisError.invalidSetup) }
                for k in 0 ..< Int(m.pointee.couplingSteps) {
                    chan[k].magnitude = UInt8(truncatingIfNeeded: getBits(ilog(channels - 1)))
                    chan[k].angle = UInt8(truncatingIfNeeded: getBits(ilog(channels - 1)))
                    if Int32(chan[k].magnitude) >= channels { return fail(StbVorbisError.invalidSetup) }
                    if Int32(chan[k].angle) >= channels { return fail(StbVorbisError.invalidSetup) }
                    if chan[k].magnitude == chan[k].angle { return fail(StbVorbisError.invalidSetup) }
                }
            } else {
                m.pointee.couplingSteps = 0
            }

            // the reserved field
            if getBits(2) != 0 { return fail(StbVorbisError.invalidSetup) }
            if m.pointee.submaps > 1 {
                for j in 0 ..< Int(channels) {
                    chan[j].mux = UInt8(getBits(4))
                    if chan[j].mux >= m.pointee.submaps { return fail(StbVorbisError.invalidSetup) }
                }
            } else {
                // the specification leaves this case out
                for j in 0 ..< Int(channels) { chan[j].mux = 0 }
            }

            for j in 0 ..< Int(m.pointee.submaps) {
                _ = getBits(8) // not used
                submap[j] = UInt8(truncatingIfNeeded: getBits(8))
                submap[15 + j] = UInt8(truncatingIfNeeded: getBits(8))
                if Int32(submap[j]) >= floorCount { return fail(StbVorbisError.invalidSetup) }
                if Int32(submap[15 + j]) >= residueCount { return fail(StbVorbisError.invalidSetup) }
            }
        }
        return true
    }

    /// init_blocksize: the twiddle factors, the window and the bit reversal of one block size.
    private mutating func initBlocksize(_ b: Int, _ n: Int32) -> Bool {
        let n2 = Int(n >> 1), n4 = Int(n >> 2), n8 = Int(n >> 3)
        guard let A = setupMalloc(n2, Float.self), let B = setupMalloc(n2, Float.self), let C = setupMalloc(n4, Float.self)
        else { return fail(StbVorbisError.outOfMemory) }
        twiddleA[b] = A
        twiddleB[b] = B
        twiddleC[b] = C
        // compute_twiddle_factors
        let dn = Double(n)
        var k2 = 0
        for k in 0 ..< n4 {
            A[k2] = Float(cos(Double(4 * k) * Mpi / dn))
            A[k2 + 1] = Float(-sin(Double(4 * k) * Mpi / dn))
            B[k2] = Float(cos(Double(k2 + 1) * Mpi / dn / 2)) * 0.5
            B[k2 + 1] = Float(sin(Double(k2 + 1) * Mpi / dn / 2)) * 0.5
            k2 += 2
        }
        k2 = 0
        for _ in 0 ..< n8 {
            C[k2] = Float(cos(Double(2 * (k2 + 1)) * Mpi / dn))
            C[k2 + 1] = Float(-sin(Double(2 * (k2 + 1)) * Mpi / dn))
            k2 += 2
        }
        // compute_window
        guard let w = setupMalloc(n2, Float.self) else { return fail(StbVorbisError.outOfMemory) }
        window[b] = w
        for i in 0 ..< n2 {
            let s = Float(sin((Double(i - 0) + 0.5) / Double(n2) * 0.5 * Mpi))
            w[i] = Float(sin(0.5 * Mpi * Double(s * s)))
        }
        // compute_bitreverse
        guard let rev = setupMalloc(n8, UInt16.self) else { return fail(StbVorbisError.outOfMemory) }
        bitReverseTable[b] = rev
        let ld = UInt32(ilog(n) - 1)
        for i in 0 ..< n8 {
            rev[i] = UInt16(truncatingIfNeeded: (bitReverse(UInt32(i)) >> (32 - ld + 3)) << 2)
        }
        return true
    }

    // MARK: The push-data API

    /// stb_vorbis_flush_pushdata: the next bytes do not follow on from the last, and the decoder is to
    /// look for its place again.
    mutating func flushPushdata() {
        previousLength = 0
        pageCrcTests = 0
        discardSamplesDeferred = 0
        currentLocValid = false
        firstDecode = false
        samplesOutput = 0
        channelBufferStart = 0
        channelBufferEnd = 0
    }

    /// vorbis_search_for_page_pushdata: looks through the bytes for an Ogg page whose CRC is right.
    /// Returns how many bytes it took.
    mutating func searchForPagePushdata(_ data: UnsafePointer<UInt8>, _ dataLenIn: Int32) -> Int32 {
        var dataLen = dataLenIn
        for i in 0 ..< Int(pageCrcTests) { scan[i].bytesDone = 0 }

        // with room for more scans, look for them first, as their headers may stop the search early
        if pageCrcTests < pushdataCRCCount {
            if dataLen < 4 { return 0 }
            dataLen -= 3 // so as not to miss a capture pattern across the end
            var i: Int32 = 0
            while i < dataLen {
                let at = Int(i)
                if data[at] == 0x4F, data[at + 1] == 0x67, data[at + 2] == 0x67, data[at + 3] == 0x53 {
                    // the whole page header must be here
                    if i + 26 >= dataLen || i + 27 + Int32(data[at + 26]) >= dataLen {
                        // read only up to this page, to have all of its header the next time
                        dataLen = i
                        break
                    }
                    // the page's length
                    var len = 27 + Int32(data[at + 26])
                    for j in 0 ..< Int(data[at + 26]) { len += Int32(data[at + 27 + j]) }
                    // the CRC up to the CRC in the header, which counts as 0
                    var crc: UInt32 = 0
                    var j = 0
                    while j < 22 {
                        crc = crc32Update(crc, data[at + j])
                        j += 1
                    }
                    while j < 26 {
                        crc = crc32Update(crc, 0)
                        j += 1
                    }
                    let n = Int(pageCrcTests)
                    pageCrcTests += 1
                    scan[n].bytesLeft = len - Int32(j)
                    scan[n].crcSoFar = crc
                    scan[n].goalCRC = UInt32(data[at + 22]) + (UInt32(data[at + 23]) << 8) + (UInt32(data[at + 24]) << 16)
                        + (UInt32(data[at + 25]) << 24)
                    // a page whose last packet goes on to the next gives no sample number yet
                    if data[at + 27 + Int(data[at + 26]) - 1] == 255 {
                        scan[n].sampleLoc = ~0
                    } else {
                        scan[n].sampleLoc = UInt32(data[at + 6]) + (UInt32(data[at + 7]) << 8) + (UInt32(data[at + 8]) << 16)
                            + (UInt32(data[at + 9]) << 24)
                    }
                    scan[n].bytesDone = i + Int32(j)
                    if pageCrcTests == pushdataCRCCount { break }
                    // go on while there is room for more
                }
                i += 1
            }
        }

        var i = 0
        while i < Int(pageCrcTests) {
            let n = scan[i].bytesDone
            var m = scan[i].bytesLeft
            if m > dataLen - n { m = dataLen - n }
            // m is how much of the page is in these bytes
            var crc = scan[i].crcSoFar
            var j: Int32 = 0
            while j < m {
                crc = crc32Update(crc, data[Int(n + j)])
                j += 1
            }
            scan[i].bytesLeft &-= m
            scan[i].crcSoFar = crc
            if scan[i].bytesLeft == 0 {
                // a page
                if scan[i].crcSoFar == scan[i].goalCRC {
                    dataLen = n + m // what is taken ends where the page does
                    pageCrcTests = -1 // no longer searching
                    previousLength = 0 // decode a frame, and give nothing of it
                    nextSeg = -1 // a new page
                    currentLoc = scan[i].sampleLoc // the sample number at the end of this page
                    currentLocValid = currentLoc != ~0
                    return dataLen
                }
                // not one
                pageCrcTests -= 1
                scan[i] = scan[Int(pageCrcTests)]
            } else {
                i += 1
            }
        }

        return dataLen
    }

    /// stb_vorbis_decode_frame_pushdata: decodes a frame from the bytes if it can. Returns how many
    /// bytes it took and how many samples it gave, which are at `outputs` until the next call.
    mutating func decodeFramePushdata(_ bytes: UnsafePointer<UInt8>, _ dataLen: Int32, _ samples: inout Int32) -> Int32 {
        if pageCrcTests >= 0 {
            samples = 0
            return searchForPagePushdata(bytes, dataLen)
        }

        data = bytes
        stream = 0
        streamEnd = Int(dataLen)
        error = StbVorbisError.noError

        // the whole packet must be here
        if !isWholePacketPresent() {
            samples = 0
            return 0
        }

        var len: Int32 = 0, left: Int32 = 0, right: Int32 = 0
        if !vorbisDecodePacket(&len, &left, &right) {
            // the error it stopped for
            let e = error
            if e == StbVorbisError.badPacketType {
                // throw the packet away and go on
                error = StbVorbisError.noError
                while get8Packet() != EOP {
                    if eof { break }
                }
                samples = 0
                return Int32(stream)
            }
            if e == StbVorbisError.continuedPacketFlagInvalid {
                if previousLength == 0 {
                    // finding its place again, this may be found, and the packet thrown away
                    error = StbVorbisError.noError
                    while get8Packet() != EOP {
                        if eof { break }
                    }
                    samples = 0
                    return Int32(stream)
                }
            }
            // it cannot go on from where it is
            flushPushdata()
            // the error it stopped for
            error = e
            samples = 0
            return 1
        }

        len = vorbisFinishFrame(len, left, right)
        for i in 0 ..< Int(channels) {
            outputs[i] = channelBuffers[i]! + Int(left)
        }

        samples = len
        return Int32(stream)
    }

    /// stb_vorbis_open_pushdata: the three headers, from the start of the bytes. Returns how many bytes
    /// they took, or nil with the error.
    mutating func openPushdata(_ bytes: UnsafePointer<UInt8>, _ dataLen: Int32) -> Int32? {
        data = bytes
        stream = 0
        streamEnd = Int(dataLen)
        if !startDecoder() {
            if eof { error = StbVorbisError.needMoreData }
            return nil
        }
        error = StbVorbisError.noError
        return Int32(stream)
    }
}

// The parts of the IMDCT that the original splits out into functions of their own.

/// imdct_step3_iter0_loop.
@inline(__always)
private func imdctStep3Iter0Loop(_ n: Int, _ e: UnsafeMutablePointer<Float>, _ iOff: Int, _ kOff: Int,
                                 _ AIn: UnsafeMutablePointer<Float>)
{
    var ee0 = e + iOff
    var ee2 = ee0 + kOff
    var A = AIn
    var i = n >> 2
    while i > 0 {
        var k00_20 = ee0[0] - ee2[0]
        var k01_21 = ee0[-1] - ee2[-1]
        ee0[0] += ee2[0]
        ee0[-1] += ee2[-1]
        ee2[0] = k00_20 * A[0] - k01_21 * A[1]
        ee2[-1] = k01_21 * A[0] + k00_20 * A[1]
        A += 8

        k00_20 = ee0[-2] - ee2[-2]
        k01_21 = ee0[-3] - ee2[-3]
        ee0[-2] += ee2[-2]
        ee0[-3] += ee2[-3]
        ee2[-2] = k00_20 * A[0] - k01_21 * A[1]
        ee2[-3] = k01_21 * A[0] + k00_20 * A[1]
        A += 8

        k00_20 = ee0[-4] - ee2[-4]
        k01_21 = ee0[-5] - ee2[-5]
        ee0[-4] += ee2[-4]
        ee0[-5] += ee2[-5]
        ee2[-4] = k00_20 * A[0] - k01_21 * A[1]
        ee2[-5] = k01_21 * A[0] + k00_20 * A[1]
        A += 8

        k00_20 = ee0[-6] - ee2[-6]
        k01_21 = ee0[-7] - ee2[-7]
        ee0[-6] += ee2[-6]
        ee0[-7] += ee2[-7]
        ee2[-6] = k00_20 * A[0] - k01_21 * A[1]
        ee2[-7] = k01_21 * A[0] + k00_20 * A[1]
        A += 8
        ee0 -= 8
        ee2 -= 8
        i -= 1
    }
}

/// imdct_step3_inner_r_loop.
@inline(__always)
private func imdctStep3InnerRLoop(_ lim: Int, _ e: UnsafeMutablePointer<Float>, _ d0: Int, _ kOff: Int,
                                  _ AIn: UnsafeMutablePointer<Float>, _ k1: Int)
{
    var e0 = e + d0
    var e2 = e0 + kOff
    var A = AIn
    var i = lim >> 2
    while i > 0 {
        var k00_20 = e0[-0] - e2[-0]
        var k01_21 = e0[-1] - e2[-1]
        e0[-0] += e2[-0]
        e0[-1] += e2[-1]
        e2[-0] = (k00_20) * A[0] - (k01_21) * A[1]
        e2[-1] = (k01_21) * A[0] + (k00_20) * A[1]

        A += k1

        k00_20 = e0[-2] - e2[-2]
        k01_21 = e0[-3] - e2[-3]
        e0[-2] += e2[-2]
        e0[-3] += e2[-3]
        e2[-2] = (k00_20) * A[0] - (k01_21) * A[1]
        e2[-3] = (k01_21) * A[0] + (k00_20) * A[1]

        A += k1

        k00_20 = e0[-4] - e2[-4]
        k01_21 = e0[-5] - e2[-5]
        e0[-4] += e2[-4]
        e0[-5] += e2[-5]
        e2[-4] = (k00_20) * A[0] - (k01_21) * A[1]
        e2[-5] = (k01_21) * A[0] + (k00_20) * A[1]

        A += k1

        k00_20 = e0[-6] - e2[-6]
        k01_21 = e0[-7] - e2[-7]
        e0[-6] += e2[-6]
        e0[-7] += e2[-7]
        e2[-6] = (k00_20) * A[0] - (k01_21) * A[1]
        e2[-7] = (k01_21) * A[0] + (k00_20) * A[1]

        e0 -= 8
        e2 -= 8

        A += k1
        i -= 1
    }
}

/// imdct_step3_inner_s_loop.
@inline(__always)
private func imdctStep3InnerSLoop(_ n: Int, _ e: UnsafeMutablePointer<Float>, _ iOff: Int, _ kOff: Int,
                                  _ A: UnsafeMutablePointer<Float>, _ aOff: Int, _ k0: Int)
{
    let A0 = A[0]
    let A1 = A[0 + 1]
    let A2 = A[0 + aOff]
    let A3 = A[0 + aOff + 1]
    let A4 = A[0 + aOff * 2 + 0]
    let A5 = A[0 + aOff * 2 + 1]
    let A6 = A[0 + aOff * 3 + 0]
    let A7 = A[0 + aOff * 3 + 1]

    var ee0 = e + iOff
    var ee2 = ee0 + kOff

    var i = n
    while i > 0 {
        var k00 = ee0[0] - ee2[0]
        var k11 = ee0[-1] - ee2[-1]
        ee0[0] = ee0[0] + ee2[0]
        ee0[-1] = ee0[-1] + ee2[-1]
        ee2[0] = (k00) * A0 - (k11) * A1
        ee2[-1] = (k11) * A0 + (k00) * A1

        k00 = ee0[-2] - ee2[-2]
        k11 = ee0[-3] - ee2[-3]
        ee0[-2] = ee0[-2] + ee2[-2]
        ee0[-3] = ee0[-3] + ee2[-3]
        ee2[-2] = (k00) * A2 - (k11) * A3
        ee2[-3] = (k11) * A2 + (k00) * A3

        k00 = ee0[-4] - ee2[-4]
        k11 = ee0[-5] - ee2[-5]
        ee0[-4] = ee0[-4] + ee2[-4]
        ee0[-5] = ee0[-5] + ee2[-5]
        ee2[-4] = (k00) * A4 - (k11) * A5
        ee2[-5] = (k11) * A4 + (k00) * A5

        k00 = ee0[-6] - ee2[-6]
        k11 = ee0[-7] - ee2[-7]
        ee0[-6] = ee0[-6] + ee2[-6]
        ee0[-7] = ee0[-7] + ee2[-7]
        ee2[-6] = (k00) * A6 - (k11) * A7
        ee2[-7] = (k11) * A6 + (k00) * A7

        ee0 -= k0
        ee2 -= k0
        i -= 1
    }
}

/// iter_54.
@inline(__always)
private func iter54(_ z: UnsafeMutablePointer<Float>) {
    let k00 = z[0] - z[-4]
    let y0 = z[0] + z[-4]
    let y2 = z[-2] + z[-6]
    let k22 = z[-2] - z[-6]

    z[-0] = y0 + y2 // z0 + z4 + z2 + z6
    z[-2] = y0 - y2 // z0 + z4 - z2 - z6

    let k33 = z[-3] - z[-7]

    z[-4] = k00 + k33 // z0 - z4 + z3 - z7
    z[-6] = k00 - k33 // z0 - z4 - z3 + z7

    let k11 = z[-1] - z[-5]
    let y1 = z[-1] + z[-5]
    let y3 = z[-3] + z[-7]

    z[-1] = y1 + y3 // z1 + z5 + z3 + z7
    z[-3] = y1 - y3 // z1 + z5 - z3 - z7
    z[-5] = k11 - k22 // z1 - z5 + z2 - z6
    z[-7] = k11 + k22 // z1 - z5 - z2 + z6
}

/// imdct_step3_inner_s_loop_ld654.
@inline(__always)
private func imdctStep3InnerSLoopLD654(_ n: Int, _ e: UnsafeMutablePointer<Float>, _ iOff: Int,
                                       _ A: UnsafeMutablePointer<Float>, _ baseN: Int)
{
    let aOff = baseN >> 3
    let A2 = A[0 + aOff]
    var z = e + iOff
    let base = z - 16 * n

    while z > base {
        var k00 = z[-0] - z[-8]
        var k11 = z[-1] - z[-9]
        var l00 = z[-2] - z[-10]
        var l11 = z[-3] - z[-11]
        z[-0] = z[-0] + z[-8]
        z[-1] = z[-1] + z[-9]
        z[-2] = z[-2] + z[-10]
        z[-3] = z[-3] + z[-11]
        z[-8] = k00
        z[-9] = k11
        z[-10] = (l00 + l11) * A2
        z[-11] = (l11 - l00) * A2

        k00 = z[-4] - z[-12]
        k11 = z[-5] - z[-13]
        l00 = z[-6] - z[-14]
        l11 = z[-7] - z[-15]
        z[-4] = z[-4] + z[-12]
        z[-5] = z[-5] + z[-13]
        z[-6] = z[-6] + z[-14]
        z[-7] = z[-7] + z[-15]
        z[-12] = k11
        z[-13] = -k00
        z[-14] = (l11 - l00) * A2
        z[-15] = (l00 + l11) * -A2

        iter54(z)
        iter54(z - 8)
        z -= 16
    }
}

/// predict_point.
@inline(__always)
private func predictPoint(_ x: Int32, _ x0: Int32, _ x1: Int32, _ y0: Int32, _ y1: Int32) -> Int32 {
    let dy = y1 &- y0
    let adx = x1 &- x0
    let err = abs(dy) &* (x &- x0)
    // Not the original's: it divides by nothing here only for a floor it has turned away.
    let off = adx == 0 ? 0 : err / adx
    return dy < 0 ? y0 &- off : y0 &+ off
}

/// draw_line: a line of the floor, in the integer steps the specification lays down, multiplied in.
@inline(__always)
private func drawLine(_ output: UnsafeMutablePointer<Float>, _ x0: Int32, _ y0: Int32, _ x1In: Int32, _ y1: Int32, _ n: Int32) {
    let dy = y1 &- y0
    let adx = x1In &- x0
    if adx <= 0 { return } // not the original's: its points are in order, and this cannot be
    var ady = abs(dy)
    var x = x0, y = y0
    var err: Int32 = 0
    let base = dy / adx
    let sy = dy < 0 ? base &- 1 : base &+ 1
    ady &-= abs(base) &* adx
    let x1 = x1In > n ? n : x1In
    if x < x1 {
        output[Int(x)] *= Float(bitPattern: inverseDBTable[Int(y & 255)])
        x += 1
        while x < x1 {
            err &+= ady
            if err >= adx {
                err &-= adx
                y &+= sy
            } else {
                y &+= base
            }
            output[Int(x)] *= Float(bitPattern: inverseDBTable[Int(y & 255)])
            x += 1
        }
    }
}

/// A stb_vorbis decoder: its state, where it lives in memory, and the memory it takes.
final class StbVorbis {
    let f: UnsafeMutablePointer<VorbisState>

    init() {
        f = .allocate(capacity: 1)
        f.initialize(to: VorbisState())
    }

    deinit {
        f.pointee.freeAll()
        f.deinitialize(count: 1)
        f.deallocate()
    }
}
