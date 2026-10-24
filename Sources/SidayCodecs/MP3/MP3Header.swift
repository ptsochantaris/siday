// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from minimp3, by lieff (https://github.com/lieff/minimp3), dedicated to the public domain
// under CC0: OpenMPT's copy of it, which libopenmpt decodes with.

/// The four bytes at the start of each frame, and the finding of frames in a stream of bytes: minimp3's
/// `HDR_` macros and `hdr_` functions, mp3d_match_frame and mp3d_find_frame.
enum MP3Header {
    static let size = 4

    @inline(__always) static func isMono(_ h: UnsafePointer<UInt8>) -> Bool { h[3] & 0xC0 == 0xC0 }
    @inline(__always) static func isMSStereo(_ h: UnsafePointer<UInt8>) -> Bool { h[3] & 0xE0 == 0x60 }
    @inline(__always) static func isFreeFormat(_ h: UnsafePointer<UInt8>) -> Bool { h[2] & 0xF0 == 0 }
    @inline(__always) static func isCRC(_ h: UnsafePointer<UInt8>) -> Bool { h[1] & 1 == 0 }
    @inline(__always) static func hasPadding(_ h: UnsafePointer<UInt8>) -> Bool { h[2] & 0x2 != 0 }
    @inline(__always) static func isMPEG1(_ h: UnsafePointer<UInt8>) -> Bool { h[1] & 0x8 != 0 }
    @inline(__always) static func isNotMPEG25(_ h: UnsafePointer<UInt8>) -> Bool { h[1] & 0x10 != 0 }
    @inline(__always) static func isIntensityStereo(_ h: UnsafePointer<UInt8>) -> Bool { h[3] & 0x10 != 0 }
    @inline(__always) static func isMSStereoFlag(_ h: UnsafePointer<UInt8>) -> Bool { h[3] & 0x20 != 0 }
    @inline(__always) static func stereoMode(_ h: UnsafePointer<UInt8>) -> Int { Int(h[3] >> 6) & 3 }
    @inline(__always) static func stereoModeExt(_ h: UnsafePointer<UInt8>) -> Int { Int(h[3] >> 4) & 3 }
    /// HDR_GET_LAYER: 3 for layer I, 1 for layer III.
    @inline(__always) static func layer(_ h: UnsafePointer<UInt8>) -> Int { Int(h[1] >> 1) & 3 }
    @inline(__always) static func bitrateIndex(_ h: UnsafePointer<UInt8>) -> Int { Int(h[2] >> 4) }
    @inline(__always) static func sampleRateIndex(_ h: UnsafePointer<UInt8>) -> Int { Int(h[2] >> 2) & 3 }
    /// HDR_GET_MY_SAMPLE_RATE: the sample rate's index among all nine, MPEG-2.5's first.
    @inline(__always) static func mySampleRate(_ h: UnsafePointer<UInt8>) -> Int {
        sampleRateIndex(h) + ((Int(h[1] >> 3) & 1) + (Int(h[1] >> 4) & 1)) * 3
    }
    @inline(__always) static func isFrame576(_ h: UnsafePointer<UInt8>) -> Bool { h[1] & 14 == 2 }
    @inline(__always) static func isLayer1(_ h: UnsafePointer<UInt8>) -> Bool { h[1] & 6 == 6 }

    /// hdr_valid.
    @inline(__always)
    static func isValid(_ h: UnsafePointer<UInt8>) -> Bool {
        h[0] == 0xFF && (h[1] & 0xF0 == 0xF0 || h[1] & 0xFE == 0xE2) && layer(h) != 0 && bitrateIndex(h) != 15 && sampleRateIndex(h) != 3
    }

    /// hdr_compare: whether the second is a valid header of a frame of the same stream as the first.
    @inline(__always)
    static func compare(_ h1: UnsafePointer<UInt8>, _ h2: UnsafePointer<UInt8>) -> Bool {
        isValid(h2) && (h1[1] ^ h2[1]) & 0xFE == 0 && (h1[2] ^ h2[2]) & 0x0C == 0 && isFreeFormat(h1) == isFreeFormat(h2)
    }

    /// hdr_bitrate_kbps.
    @inline(__always)
    static func bitrateKbps(_ h: UnsafePointer<UInt8>) -> Int {
        let row = (isMPEG1(h) ? 1 : 0) * 3 + layer(h) - 1
        return 2 * Int(MP3TableMemory.shared.halfRate[row * 15 + bitrateIndex(h)])
    }

    /// hdr_sample_rate_hz.
    @inline(__always)
    static func sampleRateHz(_ h: UnsafePointer<UInt8>) -> Int {
        let index = sampleRateIndex(h)
        let hz = index == 0 ? 44100 : index == 1 ? 48000 : 32000
        return (hz >> (isMPEG1(h) ? 0 : 1)) >> (isNotMPEG25(h) ? 0 : 1)
    }

    /// hdr_frame_samples.
    @inline(__always)
    static func frameSamples(_ h: UnsafePointer<UInt8>) -> Int {
        isLayer1(h) ? 384 : 1152 >> (isFrame576(h) ? 1 : 0)
    }

    /// hdr_frame_bytes: without the padding; for a stream of free format, `freeFormatSize`.
    @inline(__always)
    static func frameBytes(_ h: UnsafePointer<UInt8>, _ freeFormatSize: Int) -> Int {
        var frameBytes = frameSamples(h) * bitrateKbps(h) * 125 / sampleRateHz(h)
        if isLayer1(h) {
            frameBytes &= ~3 // slot align
        }
        return frameBytes != 0 ? frameBytes : freeFormatSize
    }

    /// hdr_padding.
    @inline(__always)
    static func padding(_ h: UnsafePointer<UInt8>) -> Int {
        hasPadding(h) ? (isLayer1(h) ? 4 : 1) : 0
    }

    /// hdr_is_null_or_tag: the start of an ID3v1 tag ("TAG" and a zero) or four zeros.
    @inline(__always)
    static func isNullOrTag(_ h: UnsafePointer<UInt8>) -> Bool {
        (h[0] == 0x54 && h[1] == 0x41 && h[2] == 0x47 && h[3] == 0) || (h[0] == 0 && h[1] == 0 && h[2] == 0 && h[3] == 0)
    }

    /// mp3d_match_frame: whether the frames that follow this one, up to ten of them, are of the same
    /// stream, each where the one before it says the next is. The end of the bytes, or a tag or
    /// zeros, after at least one is a match too.
    static func matchFrame(_ hdr: UnsafePointer<UInt8>, _ mp3Bytes: Int, _ frameBytes: Int) -> Bool {
        var i = 0
        for nmatch in 0 ..< MP3Decoder.maxFrameSyncMatches {
            i += Self.frameBytes(hdr + i, frameBytes) + padding(hdr + i)
            if i + size > mp3Bytes {
                return nmatch > 0
            }
            if isNullOrTag(hdr + i) {
                return nmatch > 0
            }
            if !compare(hdr, hdr + i) {
                return false
            }
        }
        return true
    }

    /// mp3d_find_frame: where the first frame is that is followed by others of its stream, and in
    /// `ptrFrameBytes` its size with its padding (0 if none is found, when the place returned is the
    /// end). The size of a frame of a stream of free format is found from where the next frame starts.
    static func findFrame(_ start: UnsafePointer<UInt8>, _ mp3Bytes: Int, _ freeFormatBytes: inout Int, _ ptrFrameBytes: inout Int) -> Int {
        var mp3 = start
        var i = 0
        while i < mp3Bytes - size {
            if isValid(mp3) {
                var frameBytes = Self.frameBytes(mp3, freeFormatBytes)
                var frameAndPadding = frameBytes + padding(mp3)

                var k = size
                while frameBytes == 0, k < MP3Decoder.maxFreeFormatFrameSize, i + 2 * k < mp3Bytes - size {
                    if compare(mp3, mp3 + k) {
                        let fb = k - padding(mp3)
                        let nextfb = fb + padding(mp3 + k)
                        if i + k + nextfb + size > mp3Bytes || !compare(mp3, mp3 + k + nextfb) {
                            k += 1
                            continue
                        }
                        frameAndPadding = k
                        frameBytes = fb
                        freeFormatBytes = fb
                    }
                    k += 1
                }
                if (frameBytes != 0 && i + frameAndPadding <= mp3Bytes && matchFrame(mp3, mp3Bytes - i, frameBytes)) || (i == 0 && frameAndPadding == mp3Bytes) {
                    ptrFrameBytes = frameAndPadding
                    return i
                }
                freeFormatBytes = 0
            }
            i += 1
            mp3 += 1
        }
        ptrFrameBytes = 0
        return mp3Bytes
    }
}
