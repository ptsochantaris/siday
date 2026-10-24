// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from libopenmpt (`soundlib/Load_mo3.cpp`, `SampleIO.cpp`, `ModSampleCopy.h`,
// `SampleFormatMP3.cpp`, `MPEGFrame.cpp`, `ModSample.cpp` and `src/openmpt/soundbase/SampleConvert.hpp`),
// Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors, used under the BSD 3-Clause
// licence (see THIRD-PARTY.md), whose MO3 unpacking is based on UNMO3 by Laurent Clévy, relicensed to
// BSD with his permission.

import SidayFoundation

extension MO3Song {
    /// libopenmpt's longest sample (`MAX_SAMPLE_LENGTH`), in frames.
    static let maximumSampleLength: UInt32 = 0x1000_0000
    /// How far a Vorbis sample's stated length is believed past the end of what its stream decodes
    /// to: libopenmpt makes the sample as long as its header says and leaves the rest silent, which a
    /// header that lies would make a vast silence of.
    static let silenceBelieved: UInt32 = 1 << 20

    /// The second half of `ReadMO3`: every sample's sound, from `start` in the file.
    mutating func readSamples(_ data: [UInt8], infos: inout [SampleInfo], from start: Int) {
        var file = MO3Bytes(data)
        file.seek(start)
        var unsupported = 0

        // Uncompressed samples are read as they come; the others' bytes are found first, because an
        // Ogg sample's shared header may be a later sample's.
        for i in 0 ..< samples.count {
            let info = infos[i]
            let compression = info.flags & 0xF000
            if compression == 0, info.compressedSize == 0 {
                readUncompressed(&samples[i], &file, is16Bit: info.flags & 0x01 != 0, isStereo: info.flags & 0x400 != 0)
            } else if info.compressedSize > 0 {
                infos[i].chunk = file.chunk(UInt32(info.compressedSize))
            }
        }

        for i in 0 ..< samples.count {
            let info = infos[i]
            let smp = i + 1
            if info.compressedSize < 0, smp + Int(info.compressedSize) > 0 {
                // A duplicate of an earlier sample (ModSample::CopyWaveform).
                let from = samples[smp + Int(info.compressedSize) - 1]
                guard from.hasData else { continue }
                samples[i].length = min(samples[i].length, from.length)
                samples[i].is16Bit = from.is16Bit
                samples[i].isStereo = from.isStereo
                let count = Int(samples[i].length) * (samples[i].isStereo ? 2 : 1)
                samples[i].data8 = nil
                samples[i].data16 = nil
                guard count > 0 else { continue }
                if from.is16Bit { samples[i].data16 = Array(from.data16![0 ..< count]) } else { samples[i].data8 = Array(from.data8![0 ..< count]) }
                continue
            }
            guard info.length != 0, let chunk = info.chunk else { continue }
            if info.flags & 0x01 != 0 { samples[i].is16Bit = true }
            if info.flags & 0x400 != 0 { samples[i].isStereo = true }
            let numChannels = samples[i].isStereo ? 2 : 1
            let compression = info.flags & 0xF000

            switch compression {
            case 0x2000, 0x4000:
                // At best MO3's packing takes two bits a point, so a chunk of n bytes is at most 4n points.
                let maxLength = UInt64(chunk.length) * UInt64(4 / numChannels)
                if UInt64(samples[i].length) > maxLength { samples[i].length = UInt32(maxLength) }
                samples[i].length = min(samples[i].length, Self.maximumSampleLength)
                let count = Int(samples[i].length) * numChannels
                guard count > 0 else { continue }
                if samples[i].is16Bit {
                    var out = [Int16](repeating: 0, count: count)
                    out.withUnsafeMutableBufferPointer { p in
                        MO3Delta.unpack16(chunk, into: p.baseAddress!, length: Int(samples[i].length), channels: numChannels,
                                          prediction: compression == 0x4000)
                    }
                    samples[i].data16 = out
                } else {
                    var out = [Int8](repeating: 0, count: count)
                    out.withUnsafeMutableBufferPointer { p in
                        MO3Delta.unpack8(chunk, into: p.baseAddress!, length: Int(samples[i].length), channels: numChannels,
                                         prediction: compression == 0x4000)
                    }
                    samples[i].data8 = out
                }
            case 0x3000, 0x7000:
                if !readVorbis(i, infos: &infos) { unsupported += 1 }
            case 0x1000:
                if !readMP3(i, chunk: chunk, encoderDelay: info.encoderDelay, headerLength: info.length) { unsupported += 1 }
            case 0x8000:
                // An OPL patch: a bogus sample of 4 silent points, so that it plays (ModSample::SetAdlib).
                var c = chunk
                if let patch = c.structure(12) {
                    samples[i].adlib = Array(patch.all)
                    samples[i].is16Bit = false
                    samples[i].isStereo = false
                    samples[i].length = 4
                    samples[i].data8 = [0, 0, 0, 0]
                    samples[i].data16 = nil
                }
            default:
                unsupported += 1
            }
        }
        if unsupported > 0 {
            shortfalls.append(Shortfall.some(unsupported, one: "samples is kept in a way siday cannot unpack, and is silent.",
                                             many: "samples are kept in a way siday cannot unpack, and are silent."))
        }
    }

    /// `SampleIO::ReadSample` for MO3's uncompressed samples: signed, little-endian, the second channel
    /// after the first.
    private func readUncompressed(_ s: inout Sample, _ file: inout MO3Bytes, is16Bit: Bool, isStereo: Bool) {
        s.length = min(s.length, Self.maximumSampleLength)
        let bytes = is16Bit ? 2 : 1, channels = isStereo ? 2 : 1
        let frameSize = bytes * channels
        let encoded = UInt64(s.length) * UInt64(frameSize)
        let fileSize = Int(min(encoded, UInt64(file.bytesLeft)))
        guard fileSize >= 1 else { return }
        if s.length > 0x40000 {
            // Cut a long sample to the bytes there are; a short one is played on into silence, as
            // ProTracker MODs whose samples run past the end of the file need.
            let maxLength = (fileSize + frameSize - 1) / frameSize
            if UInt64(s.length) > UInt64(maxLength) { s.length = UInt32(maxLength) }
        }
        guard s.length >= 1 else { return }
        s.is16Bit = is16Bit
        s.isStereo = isStereo
        let length = Int(s.length)
        let start = file.pos
        var read = 0
        if is16Bit {
            var out = [Int16](repeating: 0, count: length * channels)
            file.data.withUnsafeBufferPointer { src in
                let p = src.baseAddress! + start
                func copy(_ from: Int, _ count: Int, _ to: Int) {
                    for k in 0 ..< count {
                        out[to + k * channels] = Int16(bitPattern: UInt16(p[from + 2 * k]) | UInt16(p[from + 2 * k + 1]) << 8)
                    }
                }
                if channels == 1 {
                    let n = min(fileSize / 2, length)
                    copy(0, n, 0)
                    read = n * 2
                } else {
                    let left = min(length * 2, fileSize), right = min(length * 2, fileSize - left)
                    copy(0, left / 2, 0)
                    copy(length * 2, right / 2, 1)
                    read = left / 2 * 2 + right / 2 * 2
                }
            }
            s.data16 = out
        } else {
            var out = [Int8](repeating: 0, count: length * channels)
            file.data.withUnsafeBufferPointer { src in
                let p = src.baseAddress! + start
                if channels == 1 {
                    let n = min(fileSize, length)
                    for k in 0 ..< n { out[k] = Int8(bitPattern: p[k]) }
                    read = n
                } else {
                    let left = min(length, fileSize), right = min(length, fileSize - left)
                    for k in 0 ..< left { out[2 * k] = Int8(bitPattern: p[k]) }
                    for k in 0 ..< right { out[2 * k + 1] = Int8(bitPattern: p[length + k]) }
                    read = left + right
                }
            }
            s.data8 = out
        }
        file.seek(start - file.start + read)
    }

    /// The Ogg Vorbis path of `ReadMO3` as libopenmpt builds it with stb_vorbis: the headers opened
    /// from the sample's own bytes, or from the start of another sample's when they are shared, and
    /// the sound decoded from the sample's own bytes, as many frames as the sample's length.
    private mutating func readVorbis(_ i: Int, infos: inout [SampleInfo]) -> Bool {
        let info = infos[i]
        guard let chunk = info.chunk else { return true }
        let smp = i + 1
        let sharedHeaderSize = Int(info.encoderDelay)
        let sharedIndex = smp + Int(info.sharedHeader) > 0 ? smp + Int(info.sharedHeader) : smp
        let shared = sharedIndex != smp && sharedIndex > 0 && sharedIndex <= samples.count && sharedHeaderSize > 0
        // The sample's bytes, on their own, so that the decoder reads none of what follows them.
        let own = Array(chunk.all)
        let decoder: VorbisDecoder
        var dataPos = 0
        if shared {
            guard let headerChunk = infos[sharedIndex - 1].chunk, headerChunk.length >= sharedHeaderSize else { return true }
            let head = Array(headerChunk.all.prefix(sharedHeaderSize))
            var consumed = 0
            guard let d = try? VorbisDecoder(head, at: 0, consumed: &consumed) else { return false }
            decoder = d
        } else {
            var consumed = 0
            guard let d = try? VorbisDecoder(own, at: 0, consumed: &consumed) else { return false }
            decoder = d
            dataPos = consumed
        }
        var s = samples[i]
        let channels = s.isStereo ? 2 : 1
        let length = Int(min(s.length, Self.maximumSampleLength))
        guard length > 0 else { return true }
        var out16: [Int16] = [], out8: [Int8] = []
        let reserve = min(length, own.count * 64) * channels
        if s.is16Bit { out16.reserveCapacity(reserve) } else { out8.reserveCapacity(reserve) }
        var offset = 0
        var error: VorbisError? = nil
        while error == nil || (error == .needMoreData && dataPos < own.count), offset < length {
            let (consumed, frames) = decoder.decodeFrame(own, from: dataPos, to: own.count)
            dataPos += consumed
            error = decoder.error
            let decoded = min(frames, length - offset)
            if decoded > 0 {
                if decoder.channels == channels {
                    for c in 0 ..< channels {
                        let p = decoder.samples(of: c)
                        if c == 0 {
                            if s.is16Bit { out16.append(contentsOf: repeatElement(0, count: decoded * channels)) } else {
                                out8.append(contentsOf: repeatElement(0, count: decoded * channels))
                            }
                        }
                        let base = (offset) * channels + c
                        if s.is16Bit {
                            for k in 0 ..< decoded { out16[base + k * channels] = Self.int16(p[k]) }
                        } else {
                            for k in 0 ..< decoded { out8[base + k * channels] = Self.int8(p[k]) }
                        }
                    }
                } else if s.is16Bit {
                    out16.append(contentsOf: repeatElement(0, count: decoded * channels))
                } else {
                    out8.append(contentsOf: repeatElement(0, count: decoded * channels))
                }
                offset += decoded
            } else if consumed == 0 {
                // stb_vorbis took nothing and gave nothing (for a last packet cut short, say), and would
                // do the same again: libopenmpt would ask for ever.
                break
            }
        }
        // libopenmpt's sample is as long as its header says, silent past what was decoded.
        var final = offset
        if UInt32(length - offset) <= Self.silenceBelieved {
            final = length
        } else {
            shortfalls.append("One of its samples decodes to less sound than its header says, and is cut where the sound ends.")
        }
        if s.is16Bit {
            out16.append(contentsOf: repeatElement(0, count: (final - offset) * channels))
            s.data16 = out16
        } else {
            out8.append(contentsOf: repeatElement(0, count: (final - offset) * channels))
            s.data8 = out8
        }
        s.length = UInt32(final)
        samples[i] = s
        return true
    }

    /// The MP3 path of `ReadMO3`: an info frame left in by old encoders taken out, the stream decoded
    /// to sixteen bits by minimp3 as `ReadMP3Sample` decodes it, and the encoder's delay cut off.
    private mutating func readMP3(_ i: Int, chunk: MO3Bytes, encoderDelay delay: UInt16, headerLength: UInt32) -> Bool {
        var sampleData = chunk
        var mpegData = chunk
        // MPEGFrame.
        let frame = Self.mpegFrame(&sampleData)
        var encoderDelay = delay
        let frameDelay = UInt16(truncatingIfNeeded: frame.numSamples &* 2)
        if frame.isLAME, encoderDelay >= frameDelay {
            // The info frame gives no sound, but counts towards the encoder delay.
            encoderDelay -= frameDelay
            sampleData.seek(Int(frame.frameSize))
            mpegData = sampleData.chunk(sampleData.bytesLeft)
        }
        guard let decoded = Self.decodeMP3(mpegData) else { return false }
        var s = samples[i]
        s.is16Bit = true
        s.isStereo = decoded.channels == 2
        var pcm = decoded.pcm
        var frames = pcm.count / decoded.channels
        let bytesPerFrame = 2 * decoded.channels
        let sizeInBytes = frames * bytesPerFrame
        if encoderDelay > 0, Int(encoderDelay) < sizeInBytes {
            // memmove by the delay in bytes, which need not be a whole number of points.
            let skip = Int(encoderDelay)
            pcm.withUnsafeMutableBytes { raw in
                let p = raw.baseAddress!
                p.copyMemory(from: p + skip, byteCount: sizeInBytes - skip)
            }
            frames -= skip / bytesPerFrame
        }
        frames = min(frames, Int(clamping: headerLength))
        s.length = UInt32(frames)
        s.data16 = Array(pcm[0 ..< frames * decoded.channels])
        samples[i] = s
        return true
    }

    /// What `MPEGFrame` finds of the frame at the start of `file`: its size, its samples (counting
    /// both channels), and whether it is a LAME or Xing info frame.
    static func mpegFrame(_ file: inout MO3Bytes) -> (frameSize: UInt16, numSamples: UInt16, isLAME: Bool) {
        var header = [UInt8](repeating: 0, count: 4)
        if file.canRead(4) { for k in 0 ..< 4 { header[k] = file.u8() } }
        guard isMPEGHeader(header[0], header[1], header[2]) else { return (0, 0, false) }
        let samplesPerFrame: [[UInt16]] = [[384, 1152, 1152], [384, 1152, 576]]
        let bitRates: [[[Int]]] = [
            [[0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
             [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
             [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]],
            [[0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
             [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
             [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]],
        ]
        let samplingRates: [[Int]] = [[11025, 12000, 8000], [0, 0, 0], [22050, 24000, 16000], [44100, 48000, 32000]]
        let coefficients: [[Int]] = [[12, 144, 144], [12, 144, 72]]
        let sideInfoSize: [[Int]] = [[17, 32], [9, 17]]
        let version = Int((header[1] & 0x18) >> 3)
        let mpeg1 = version == 3 ? 0 : 1
        let layer = 3 - Int((header[1] & 0x06) >> 1)
        let bitRate = Int((header[2] & 0xF0) >> 4)
        let sampleRate = Int((header[2] & 0x0C) >> 2)
        let padding = Int((header[2] & 0x02) >> 1)
        let stereo = (header[3] & 0xC0) >> 6 != 3
        let size = (coefficients[mpeg1][layer] * (bitRates[mpeg1][layer][bitRate] * 1000) / samplingRates[version][sampleRate] + padding)
            * (layer == 0 ? 4 : 1)
        let frameSize = UInt16(truncatingIfNeeded: size)
        var numSamples = samplesPerFrame[mpeg1][layer]
        if stereo { numSamples *= 2 }
        let lameOffset = sideInfoSize[mpeg1][stereo ? 1 : 0]
        guard Int(frameSize) >= lameOffset + 8 else { return (frameSize, numSamples, false) }
        // ReadStructPartial: as much of it as there is.
        var frame = [UInt8](repeating: 0, count: 36)
        for k in 0 ..< min(lameOffset + 4, file.bytesLeft) { frame[k] = file.u8() }
        // The first two bytes may be a CRC.
        for k in 2 ..< lameOffset where frame[k] != 0 { return (frameSize, numSamples, false) }
        let tag = frame[lameOffset ..< lameOffset + 4]
        let isLAME = tag.elementsEqual([0x49, 0x6E, 0x66, 0x6F]) || tag.elementsEqual([0x58, 0x69, 0x6E, 0x67])
        return (frameSize, numSamples, isLAME)
    }

    /// `MPEGFrame::IsMPEGHeader`.
    static func isMPEGHeader(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> Bool {
        a == 0xFF && b & 0xE0 == 0xE0 && b & 0x18 != 0x08 && b & 0x06 != 0x00 && c & 0x0C != 0x0C && c & 0xF0 != 0xF0
    }

    /// `ReadMP3Sample` with minimp3: the stream checked for being one, then decoded frame by frame
    /// while the frames agree in rate and channels. Nil for what is not an MP3 stream.
    static func decodeMP3(_ chunk: MO3Bytes) -> (pcm: [Int16], channels: Int)? {
        var file = chunk
        file.rewind()
        // Tags and padding may come first; anything else that is not a frame's header is not MP3.
        while file.canRead(4) {
            let m0 = file.u8(), m1 = file.u8(), m2 = file.u8()
            if m0 == 0x49, m1 == 0x44, m2 == 0x33 {
                var header = [UInt8](repeating: 0, count: 7)
                if file.canRead(7) { for k in 0 ..< 7 { header[k] = file.u8() } }
                var size: UInt32 = 0
                for k in 3 ..< 7 {
                    if header[k] & 0x80 != 0 { return nil }
                    size = size << 7 | UInt32(header[k])
                }
                file.skip(Int(size))
            } else if m0 == 0x41, m1 == 0x50, m2 == 0x45, file.magic("TAGEX") {
                let size = file.u32()
                // 16 + size, in 32 bits, as the C adds them.
                file.skip(Int(clamping: 16 &+ size))
            } else if (m0 == 0 || m0 == 0xFF), m1 == 0, m2 == 0 {
                // Some files are padded with zeros.
            } else if m0 == 0 {
                // Padding, perhaps, and then a header.
                file.pos -= 2
            } else if isMPEGHeader(m0, m1, m2) {
                break
            } else {
                return nil
            }
        }

        let decoder = MP3Decoder()
        var info = MP3FrameInfo()
        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: 1152 * 2)
        defer { buffer.deallocate() }
        var raw: [Int16] = []
        var rate = 0, channels = 0
        let begin = chunk.start, end = chunk.end
        chunk.data.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            var pos = begin
            repeat {
                let frameSamples = decoder.decodeFrame(base + pos, count: end - pos, into: buffer, info: &info)
                if frameSamples < 0 || info.frameBytes < 0 { break }
                if frameSamples > 0, info.frameBytes == 0 { break }
                if frameSamples == 0, info.frameBytes == 0 { break }
                if info.frameBytes > 0 {
                    if rate != 0, rate != info.hz { break }
                    if channels != 0, channels != info.channels { break }
                    rate = info.hz
                    channels = info.channels
                    if rate <= 0 { break }
                    if channels != 1, channels != 2 { break }
                    pos += min(info.frameBytes, end - pos)
                    if frameSamples > 0 { raw.append(contentsOf: UnsafeBufferPointer(start: buffer, count: frameSamples * channels)) }
                }
                if raw.count / max(channels, 1) > Int(maximumSampleLength) { break }
            } while pos < end
        }
        guard rate != 0, channels != 0, !raw.isEmpty, raw.count / channels <= Int(maximumSampleLength) else { return nil }
        return (raw, channels)
    }

    /// `SC::Convert<int16, float>`: clamped to -1...1 (NaN as 0), scaled, rounded half away from zero,
    /// and saturated.
    @inline(__always)
    static func int16(_ v: Float) -> Int16 {
        var x = v.isNaN ? 0 : min(max(v, -1), 1)
        x *= 32768
        let r = Int32(x.rounded())
        return Int16(clamping: r)
    }

    /// `SC::Convert<int8, float>`.
    @inline(__always)
    static func int8(_ v: Float) -> Int8 {
        var x = v.isNaN ? 0 : min(max(v, -1), 1)
        x *= 128
        let r = Int32(x.rounded())
        return Int8(clamping: r)
    }
}

/// MO3's lossless packing of samples: deltas, or deltas from a prediction, in a variable number of
/// bits each, read through the same control bits as the music.
enum MO3Delta {
    /// `UnpackMO3DeltaSample` and `UnpackMO3DeltaPredictionSample` for 8-bit samples.
    static func unpack8(_ chunk: MO3Bytes, into dst: UnsafeMutablePointer<Int8>, length: Int, channels: Int, prediction: Bool) {
        chunk.data.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            var source = MO3Source(base: base, index: chunk.start, end: chunk.end)
            var bits = MO3ControlBits()
            var dh: UInt8 = 4
            var previous: Int8 = 0
            var next: Int32 = 0
            for chn in 0 ..< channels {
                var p = chn
                let pEnd = p + length * channels
                while p < pEnd {
                    var val: UInt8 = 0
                    // MO3Delta8BitParams::Decode.
                    repeat {
                        guard bits.next(&source) else { break }
                        val = val &<< 1 &+ UInt8(truncatingIfNeeded: bits.carry)
                        guard bits.next(&source) else { break }
                    } while bits.carry != 0
                    var cl = dh
                    while cl > 0 {
                        guard bits.next(&source) else { break }
                        val = val &<< 1 &+ UInt8(truncatingIfNeeded: bits.carry)
                        cl -= 1
                    }
                    cl = 1
                    if val >= 4 {
                        cl = 7
                        while (1 << cl) & Int(val) == 0, cl > 1 { cl -= 1 }
                    }
                    dh = UInt8(truncatingIfNeeded: Int(dh) + Int(cl)) >> 1
                    bits.carry = Int32(val & 1)
                    val >>= 1
                    if bits.carry == 0 { val = ~val }
                    if prediction {
                        let delta = Int8(bitPattern: val)
                        val = val &+ UInt8(truncatingIfNeeded: next)
                        dst[p] = Int8(bitPattern: val)
                        let sval = Int8(bitPattern: val)
                        next = Int32(sval) * 2 + Int32(delta >> 1) - Int32(previous)
                        next = min(max(next, -128), 127)
                        previous = sval
                    } else {
                        val = val &+ UInt8(bitPattern: previous)
                        dst[p] = Int8(bitPattern: val)
                        previous = Int8(bitPattern: val)
                    }
                    p += channels
                }
            }
        }
    }

    /// The same for 16-bit samples, whose deltas come in a different number of bits at a time.
    static func unpack16(_ chunk: MO3Bytes, into dst: UnsafeMutablePointer<Int16>, length: Int, channels: Int, prediction: Bool) {
        chunk.data.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            var source = MO3Source(base: base, index: chunk.start, end: chunk.end)
            var bits = MO3ControlBits()
            var dh: UInt8 = 8
            var previous: Int16 = 0
            var next: Int32 = 0
            for chn in 0 ..< channels {
                var p = chn
                let pEnd = p + length * channels
                while p < pEnd {
                    var val: UInt16 = 0
                    // MO3Delta16BitParams::Decode.
                    if dh < 5 {
                        repeat {
                            guard bits.next(&source) else { break }
                            val = val &<< 1 &+ UInt16(truncatingIfNeeded: bits.carry)
                            guard bits.next(&source) else { break }
                            val = val &<< 1 &+ UInt16(truncatingIfNeeded: bits.carry)
                            guard bits.next(&source) else { break }
                        } while bits.carry != 0
                    } else {
                        repeat {
                            guard bits.next(&source) else { break }
                            val = val &<< 1 &+ UInt16(truncatingIfNeeded: bits.carry)
                            guard bits.next(&source) else { break }
                        } while bits.carry != 0
                    }
                    var cl = dh
                    while cl > 0 {
                        guard bits.next(&source) else { break }
                        val = val &<< 1 &+ UInt16(truncatingIfNeeded: bits.carry)
                        cl -= 1
                    }
                    cl = 1
                    if val >= 4 {
                        cl = 15
                        while (1 << cl) & Int(val) == 0, cl > 1 { cl -= 1 }
                    }
                    dh = UInt8(truncatingIfNeeded: Int(dh) + Int(cl)) >> 1
                    bits.carry = Int32(val & 1)
                    val >>= 1
                    if bits.carry == 0 { val = ~val }
                    if prediction {
                        let delta = Int16(bitPattern: val)
                        val = val &+ UInt16(truncatingIfNeeded: next)
                        dst[p] = Int16(bitPattern: val)
                        let sval = Int16(bitPattern: val)
                        next = Int32(sval) * 2 + Int32(delta >> 1) - Int32(previous)
                        next = min(max(next, -32768), 32767)
                        previous = sval
                    } else {
                        val = val &+ UInt16(bitPattern: previous)
                        dst[p] = Int16(bitPattern: val)
                        previous = Int16(bitPattern: val)
                    }
                    p += channels
                }
            }
        }
    }
}
