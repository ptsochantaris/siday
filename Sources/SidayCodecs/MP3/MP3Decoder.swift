// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from minimp3, by lieff (https://github.com/lieff/minimp3), dedicated to the public domain
// under CC0: OpenMPT's copy of it, which libopenmpt decodes with. The names of the C's functions are
// given beside the code that is ported from each.

/// What `MP3Decoder.decodeFrame` says of the frame it decoded (`mp3dec_frame_info_t`).
public struct MP3FrameInfo: Sendable {
    /// How many bytes were used: the junk skipped before the frame, and the frame itself. When no
    /// frame was found, how many bytes were looked through and can be passed over.
    public var frameBytes = 0
    /// Where the frame starts, after the junk before it.
    public var frameOffset = 0
    public var channels = 0
    public var hz = 0
    /// 1, 2 or 3.
    public var layer = 0
    /// 0 for a stream of "free format", which does not say.
    public var bitrateKbps = 0

    public init() {}
}

/// minimp3's decoder (`mp3dec_t`), of MPEG-1, MPEG-2 and MPEG-2.5 audio, layers I, II and III. It keeps
/// none of the stream: it is given the bytes from the next frame on each time, and keeps only what
/// one frame leaves for the next, the bit reservoir and the filters' overlaps.
///
/// This is minimp3's portable code, which it uses where it has no SIMD (`MINIMP3_NO_SIMD`), with
/// every sum done in the same order and the same precision, so that a frame is decoded to the same
/// bits as the C would decode it to. The SIMD code does the same sums but rounds its sixteen-bit
/// samples a little differently.
public final class MP3Decoder {
    // mp3dec_t
    let mdctOverlap: UnsafeMutablePointer<Float> // [2][9*32]
    let qmfState: UnsafeMutablePointer<Float> // [15*2*32]
    var reserv = 0, freeFormatBytes = 0
    let header: UnsafeMutablePointer<UInt8> // [4]
    let reservBuf: UnsafeMutablePointer<UInt8> // [511]

    // mp3dec_scratch_t, which the C keeps on the stack, kept here between frames instead.
    var bs: MP3BitStream
    /// The bit reservoir's bytes and then the frame's. The C's array is as long as the most a frame
    /// can bring; past the end of what is in it, a read gets zeros.
    let maindata: UnsafeMutablePointer<UInt8> // [511 + 2304]
    let grInfo: UnsafeMutablePointer<MP3GranuleInfo> // [4]
    /// grbuf, scf and syn, one after the other in one block, as in the C's struct: a mixed block at
    /// 8 kHz is reordered (L3_reorder) from 24 lines past the end of the second channel's 576 and back,
    /// which in the C are the first of `scf`, and are here too.
    let scratchFloats: UnsafeMutablePointer<Float>
    let grbuf: UnsafeMutablePointer<Float> // [2][576]
    let scf: UnsafeMutablePointer<Float> // [40]
    let syn: UnsafeMutablePointer<Float> // [18 + 15][2*32]
    let istPos: UnsafeMutablePointer<UInt8> // [2][39]

    // L12_scale_info, which the C also keeps on the stack.
    let sciScf: UnsafeMutablePointer<Float> // [3*64]
    let sciBitalloc: UnsafeMutablePointer<UInt8> // [64]
    let sciScfcod: UnsafeMutablePointer<UInt8> // [64]
    var sciTotalBands = 0, sciStereoBands = 0

    /// Small arrays of the C's functions' own: L3_decode_scalefactors' `scf_size` and `iscf`, and the
    /// DCT's `t`.
    let scfSize: UnsafeMutablePointer<UInt8> // [4]
    let iscf: UnsafeMutablePointer<UInt8> // [40]
    let dctT: UnsafeMutablePointer<Float> // [4][8]

    let t = MP3TableMemory.shared

    static let maxBitReservoirBytes = 511
    static let maxL3FramePayloadBytes = 2304
    static let maxFreeFormatFrameSize = 2304
    static let maxFrameSyncMatches = 10
    static let mainDataCapacity = maxBitReservoirBytes + maxL3FramePayloadBytes

    /// mp3dec_init.
    public init() {
        mdctOverlap = .allocate(capacity: 2 * 9 * 32)
        qmfState = .allocate(capacity: 15 * 2 * 32)
        header = .allocate(capacity: 4)
        reservBuf = .allocate(capacity: Self.maxBitReservoirBytes)
        maindata = .allocate(capacity: Self.mainDataCapacity)
        grInfo = .allocate(capacity: 4)
        scratchFloats = .allocate(capacity: 2 * 576 + 40 + 33 * 64)
        grbuf = scratchFloats
        scf = scratchFloats + 2 * 576
        syn = scratchFloats + 2 * 576 + 40
        istPos = .allocate(capacity: 2 * 39)
        sciScf = .allocate(capacity: 3 * 64)
        sciBitalloc = .allocate(capacity: 64)
        sciScfcod = .allocate(capacity: 64)
        scfSize = .allocate(capacity: 4)
        iscf = .allocate(capacity: 40)
        dctT = .allocate(capacity: 32)
        mdctOverlap.initialize(repeating: 0, count: 2 * 9 * 32)
        qmfState.initialize(repeating: 0, count: 15 * 2 * 32)
        header.initialize(repeating: 0, count: 4)
        reservBuf.initialize(repeating: 0, count: Self.maxBitReservoirBytes)
        maindata.initialize(repeating: 0, count: Self.mainDataCapacity)
        grInfo.initialize(repeating: MP3GranuleInfo(sfbtab: MP3TableMemory.shared.scfLong), count: 4)
        grbuf.initialize(repeating: 0, count: 2 * 576)
        scf.initialize(repeating: 0, count: 40)
        syn.initialize(repeating: 0, count: 33 * 64)
        istPos.initialize(repeating: 0, count: 2 * 39)
        sciScf.initialize(repeating: 0, count: 3 * 64)
        sciBitalloc.initialize(repeating: 0, count: 64)
        sciScfcod.initialize(repeating: 0, count: 64)
        scfSize.initialize(repeating: 0, count: 4)
        iscf.initialize(repeating: 0, count: 40)
        dctT.initialize(repeating: 0, count: 32)
        bs = MP3BitStream(UnsafePointer(maindata), bytes: 0)
    }

    deinit {
        mdctOverlap.deallocate()
        qmfState.deallocate()
        header.deallocate()
        reservBuf.deallocate()
        maindata.deallocate()
        grInfo.deallocate()
        scratchFloats.deallocate()
        istPos.deallocate()
        sciScf.deallocate()
        sciBitalloc.deallocate()
        sciScfcod.deallocate()
        scfSize.deallocate()
        iscf.deallocate()
        dctT.deallocate()
    }

    /// mp3dec_init again: the next frame is looked for afresh, as at the start of a stream, and the
    /// decoder starts again from silence.
    public func reset() {
        header[0] = 0
    }

    /// mp3dec_decode_frame on `bytes` from `start` to the end: the number of samples per channel
    /// decoded (0 if none), written interleaved to `pcm`, which must have room for 1152 * 2, as floats
    /// from -1 to 1 (`MINIMP3_FLOAT_OUTPUT`); and what it found of the frame in `info`. A frame that
    /// needs more of the bit reservoir than the frames before it left is found, but gives no samples.
    public func decodeFrame(_ bytes: [UInt8], at start: Int, into pcm: UnsafeMutablePointer<Float>, info: inout MP3FrameInfo) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, start >= 0, start < buffer.count else { return decode(nil, 0, pcm, &info) }
            return decode(base + start, buffer.count - start, pcm, &info)
        }
    }

    /// The same, writing sixteen-bit samples, as minimp3 does by default (`mp3d_sample_t` as
    /// `int16_t`): libopenmpt decodes the MP3 samples of MO3 files to these.
    public func decodeFrame(_ bytes: [UInt8], at start: Int, into pcm: UnsafeMutablePointer<Int16>, info: inout MP3FrameInfo) -> Int {
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, start >= 0, start < buffer.count else { return decode(nil, 0, pcm, &info) }
            return decode(base + start, buffer.count - start, pcm, &info)
        }
    }

    /// The same on `count` bytes in memory.
    public func decodeFrame(_ data: UnsafePointer<UInt8>, count: Int, into pcm: UnsafeMutablePointer<Float>, info: inout MP3FrameInfo) -> Int {
        decode(data, max(0, count), pcm, &info)
    }

    public func decodeFrame(_ data: UnsafePointer<UInt8>, count: Int, into pcm: UnsafeMutablePointer<Int16>, info: inout MP3FrameInfo) -> Int {
        decode(data, max(0, count), pcm, &info)
    }

    /// mp3dec_decode_frame's first half: finds the frame, the next one quickly if it follows the last
    /// one decoded, or else by looking through the bytes as at the start of a stream. Fills in `info`
    /// and keeps the frame's header; or, if there is no frame, says in `info.frameBytes` how many
    /// bytes were looked through.
    @inline(__always)
    private func locate(_ mp3: UnsafePointer<UInt8>?, _ mp3Bytes: Int, _ info: inout MP3FrameInfo) -> (offset: Int, size: Int)? {
        var i = 0, frameSize = 0
        if let mp3, mp3Bytes > 4, header[0] == 0xFF, MP3Header.compare(UnsafePointer(header), mp3) {
            frameSize = MP3Header.frameBytes(mp3, freeFormatBytes) + MP3Header.padding(mp3)
            if frameSize != mp3Bytes, frameSize + MP3Header.size > mp3Bytes || !MP3Header.compare(mp3, mp3 + frameSize) {
                frameSize = 0
            }
        }
        if frameSize == 0 {
            clear()
            guard let mp3 else {
                info.frameBytes = 0
                return nil
            }
            i = MP3Header.findFrame(mp3, mp3Bytes, &freeFormatBytes, &frameSize)
            if frameSize == 0 || i + frameSize > mp3Bytes {
                info.frameBytes = i
                return nil
            }
        }
        guard let mp3 else { return nil }
        let hdr = mp3 + i
        header[0] = hdr[0]
        header[1] = hdr[1]
        header[2] = hdr[2]
        header[3] = hdr[3]
        info.frameBytes = i + frameSize
        info.frameOffset = i
        info.channels = MP3Header.isMono(hdr) ? 1 : 2
        info.hz = MP3Header.sampleRateHz(hdr)
        info.layer = 4 - MP3Header.layer(hdr)
        info.bitrateKbps = MP3Header.bitrateKbps(hdr)
        return (i, frameSize)
    }

    /// The C's `memset(dec, 0, sizeof(mp3dec_t))`, before it looks for a frame afresh.
    private func clear() {
        mdctOverlap.update(repeating: 0, count: 2 * 9 * 32)
        qmfState.update(repeating: 0, count: 15 * 2 * 32)
        reserv = 0
        freeFormatBytes = 0
        header.update(repeating: 0, count: 4)
        reservBuf.update(repeating: 0, count: Self.maxBitReservoirBytes)
    }

    /// mp3dec_decode_frame.
    func decode<Sample: MP3Sample>(_ mp3: UnsafePointer<UInt8>?, _ mp3Bytes: Int, _ pcmStart: UnsafeMutablePointer<Sample>, _ info: inout MP3FrameInfo) -> Int {
        guard let (i, frameSize) = locate(mp3, mp3Bytes, &info), let mp3 else { return 0 }
        let hdr = mp3 + i
        var success = true
        var pcm = pcmStart

        var bsFrame = MP3BitStream(hdr + MP3Header.size, bytes: frameSize - MP3Header.size)
        if MP3Header.isCRC(hdr) {
            _ = bsFrame.bits(16)
        }

        if info.layer == 3 {
            let mainDataBegin = Self.readSideInfo(&bsFrame, grInfo, hdr, t)
            if mainDataBegin < 0 || bsFrame.pos > bsFrame.limit {
                reset()
                return 0
            }
            success = restoreReservoir(&bsFrame, mainDataBegin)
            if success {
                let granules = MP3Header.isMPEG1(hdr) ? 2 : 1
                for igr in 0 ..< granules {
                    grbuf.update(repeating: 0, count: 2 * 576)
                    l3Decode(grInfo + igr * info.channels, info.channels)
                    synthGranule(grbuf, 18, info.channels, pcm, syn)
                    pcm += 576 * info.channels
                }
            }
            saveReservoir()
        } else {
            l12ReadScaleInfo(hdr, &bsFrame)
            grbuf.update(repeating: 0, count: 2 * 576)
            var at = 0
            for igr in 0 ..< 3 {
                at += l12DequantizeGranule(grbuf + at, &bsFrame, info.layer | 1)
                if at == 12 {
                    at = 0
                    l12ApplyScf384(sciScf + igr, grbuf)
                    synthGranule(grbuf, 12, info.channels, pcm, syn)
                    grbuf.update(repeating: 0, count: 2 * 576)
                    pcm += 384 * info.channels
                }
                if bsFrame.pos > bsFrame.limit {
                    reset()
                    return 0
                }
            }
        }
        return success ? MP3Header.frameSamples(UnsafePointer(header)) : 0
    }

    /// What `decode` would give for the frame, found by going through everything that decides it
    /// (the finding of the frame, its side information, the bit reservoir's bookkeeping, layer I
    /// and II's reading of the bits) without working out any sound: for counting a stream's samples
    /// quickly. The bit reservoir's bytes are not copied, only counted, so a decoder that has measured
    /// a frame must be reset before it decodes one.
    func measure(_ mp3: UnsafePointer<UInt8>?, _ mp3Bytes: Int, _ info: inout MP3FrameInfo) -> Int {
        guard let (i, frameSize) = locate(mp3, mp3Bytes, &info), let mp3 else { return 0 }
        let hdr = mp3 + i
        var success = true

        var bsFrame = MP3BitStream(hdr + MP3Header.size, bytes: frameSize - MP3Header.size)
        if MP3Header.isCRC(hdr) {
            _ = bsFrame.bits(16)
        }

        if info.layer == 3 {
            let mainDataBegin = Self.readSideInfo(&bsFrame, grInfo, hdr, t)
            if mainDataBegin < 0 || bsFrame.pos > bsFrame.limit {
                reset()
                return 0
            }
            // L3_restore_reservoir, L3_decode (which leaves the bit stream at the end of the last
            // granule's part 2 and 3) and L3_save_reservoir, counting bytes only.
            let frameBytes = (bsFrame.limit - bsFrame.pos) / 8
            let bytesHave = min(reserv, mainDataBegin)
            success = reserv >= mainDataBegin
            var end = 0
            if success {
                let granules = (MP3Header.isMPEG1(hdr) ? 2 : 1) * info.channels
                for g in 0 ..< granules { end += grInfo[g].part23Length }
            }
            let pos = (end + 7) / 8
            reserv = max(0, min(bytesHave + frameBytes - pos, Self.maxBitReservoirBytes))
        } else {
            l12ReadScaleInfo(hdr, &bsFrame)
            var at = 0
            for _ in 0 ..< 3 {
                at += l12DequantizeGranule(grbuf + at, &bsFrame, info.layer | 1)
                if at == 12 {
                    at = 0
                }
                if bsFrame.pos > bsFrame.limit {
                    reset()
                    return 0
                }
            }
        }
        return success ? MP3Header.frameSamples(UnsafePointer(header)) : 0
    }
}

/// minimp3's bit reader (`bs_t`, `bs_init`, `get_bits`). Reading past the end gives zeros, but the
/// place goes on counting, so that the reader of a frame can see that it went too far.
struct MP3BitStream {
    var buf: UnsafePointer<UInt8>
    var pos = 0, limit = 0

    /// bs_init.
    init(_ data: UnsafePointer<UInt8>, bytes: Int) {
        buf = data
        pos = 0
        limit = bytes * 8
    }

    /// get_bits.
    @inline(__always)
    mutating func bits(_ n: Int) -> UInt32 {
        let s = UInt32(truncatingIfNeeded: pos & 7)
        var shl = n + Int(s)
        var p = pos >> 3
        pos += n
        if pos > limit || n <= 0 {
            return 0
        }
        var cache: UInt32 = 0
        var next = UInt32(buf[p]) & (255 &>> s)
        p += 1
        shl -= 8
        while shl > 0 {
            cache |= next &<< UInt32(shl)
            next = UInt32(buf[p])
            p += 1
            shl -= 8
        }
        return cache | (next &>> UInt32(-shl))
    }
}

/// One granule of one channel's side information (`L3_gr_info_t`).
struct MP3GranuleInfo {
    var sfbtab: UnsafePointer<UInt8>
    var part23Length = 0, bigValues = 0, scalefacCompress = 0
    var globalGain = 0, blockType = 0, mixedBlockFlag = 0, nLongSfb = 0, nShortSfb = 0
    var tableSelect0 = 0, tableSelect1 = 0, tableSelect2 = 0
    var regionCount0 = 0, regionCount1 = 0, regionCount2 = 0
    var subblockGain0 = 0, subblockGain1 = 0, subblockGain2 = 0
    var preflag = 0, scalefacScale = 0, count1Table = 0, scfsi = 0

    init(sfbtab: UnsafePointer<UInt8>) {
        self.sfbtab = sfbtab
    }
}

/// What a sample of the decoder's output is made from the synthesis filter's sum (mp3d_scale_pcm).
protocol MP3Sample {
    static func fromSynthesis(_ sample: Float) -> Self
}

extension Float: MP3Sample {
    @inline(__always)
    static func fromSynthesis(_ sample: Float) -> Float {
        sample * (1.0 / 32768.0)
    }
}

extension Int16: MP3Sample {
    /// Rounded to nearest, a half away from zero, and clipped. (Not a number, which no frame gives,
    /// is 0, as the C's conversion gives it on arm64.)
    @inline(__always)
    static func fromSynthesis(_ sample: Float) -> Int16 {
        if sample >= 32766.5 { return 32767 }
        if sample <= -32767.5 { return -32768 }
        if sample.isNaN { return 0 }
        var s = Int16(sample + 0.5)
        if s < 0 { s -= 1 }
        return s
    }
}
