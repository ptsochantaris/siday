// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from minimp3, by lieff (https://github.com/lieff/minimp3), dedicated to the public domain
// under CC0: OpenMPT's copy of it, which libopenmpt decodes with.

/// Layers I and II: each subband's allocation and scale factors, and its samples, read straight from
/// the frame, for the synthesis filter.
extension MP3Decoder {
    /// L12_subband_alloc_table: which of the allocation tables the frame's bands are read with, by
    /// layer, MPEG version, bit rate and sample rate; and how many bands there are, and of them how
    /// many are in stereo, into the scale information.
    private func l12SubbandAllocTable(_ hdr: UnsafePointer<UInt8>) -> UnsafePointer<UInt8> {
        let alloc: UnsafePointer<UInt8>
        let mode = MP3Header.stereoMode(hdr)
        var nbands: Int
        let stereoBands = mode == 3 ? 0 : mode == 1 ? (MP3Header.stereoModeExt(hdr) << 2) + 4 : 32

        if MP3Header.isLayer1(hdr) {
            alloc = t.allocL1
            nbands = 32
        } else if !MP3Header.isMPEG1(hdr) {
            alloc = t.allocL2M2
            nbands = 30
        } else {
            let sampleRateIdx = MP3Header.sampleRateIndex(hdr)
            var kbps = MP3Header.bitrateKbps(hdr) >> (mode != 3 ? 1 : 0)
            if kbps == 0 { // free-format
                kbps = 192
            }

            var chosen = t.allocL2M1
            nbands = 27
            if kbps < 56 {
                chosen = t.allocL2M1LowRate
                nbands = sampleRateIdx == 2 ? 12 : 8
            } else if kbps >= 96, sampleRateIdx != 1 {
                nbands = 30
            }
            alloc = chosen
        }

        sciTotalBands = nbands
        sciStereoBands = min(stereoBands, nbands)
        return alloc
    }

    /// L12_read_scalefactors: each band's three scale factors, as many read as its code says and the
    /// rest the same as the one before.
    private func l12ReadScalefactors(_ bs: inout MP3BitStream, _ pba: UnsafePointer<UInt8>, _ scfcod: UnsafePointer<UInt8>, _ bands: Int, _ scfStart: UnsafeMutablePointer<Float>) {
        let deq = t.dequantL12
        var scf = scfStart
        for i in 0 ..< bands {
            var s: Float = 0
            let ba = Int(pba[i])
            let mask = ba != 0 ? 4 + ((19 >> Int(scfcod[i])) & 3) : 0
            var m = 4
            while m != 0 {
                if mask & m != 0 {
                    let b = Int(bs.bits(6))
                    s = deq[ba * 3 - 6 + b % 3] * Float((1 << 21) >> (b / 3))
                }
                scf.pointee = s
                scf += 1
                m >>= 1
            }
        }
    }

    /// L12_read_scale_info: the bands' allocations, the codes of their scale factors (layer II) and
    /// the scale factors.
    func l12ReadScaleInfo(_ hdr: UnsafePointer<UInt8>, _ bs: inout MP3BitStream) {
        var subbandAlloc = l12SubbandAllocTable(hdr)
        var k = 0, baBits = 0
        var baCodeTab = t.bitAllocCodes
        let total = sciTotalBands, stereo = sciStereoBands

        for i in 0 ..< total {
            if i == k {
                k += Int(subbandAlloc[2])
                baBits = Int(subbandAlloc[1])
                baCodeTab = t.bitAllocCodes + Int(subbandAlloc[0])
                subbandAlloc += 3
            }
            var ba = baCodeTab[Int(bs.bits(baBits))]
            sciBitalloc[2 * i] = ba
            if i < stereo {
                ba = baCodeTab[Int(bs.bits(baBits))]
            }
            sciBitalloc[2 * i + 1] = stereo != 0 ? ba : 0
        }

        let layer1 = MP3Header.isLayer1(hdr)
        for i in 0 ..< 2 * total {
            sciScfcod[i] = sciBitalloc[i] != 0 ? (layer1 ? 2 : UInt8(truncatingIfNeeded: bs.bits(2))) : 6
        }

        l12ReadScalefactors(&bs, sciBitalloc, sciScfcod, total * 2, sciScf)

        for i in stereo ..< total {
            sciBitalloc[2 * i + 1] = 0
        }
    }

    /// L12_dequantize_granule: four of each band's groups of samples (of one, for layer I, or of three,
    /// for layer II), each of its allocated size. How many times of each band that is.
    func l12DequantizeGranule(_ grbuf: UnsafeMutablePointer<Float>, _ bs: inout MP3BitStream, _ groupSize: Int) -> Int {
        var choff = 576
        let bands = 2 * sciTotalBands
        for j in 0 ..< 4 {
            var dst = grbuf + groupSize * j
            for i in 0 ..< bands {
                let ba = Int(sciBitalloc[i])
                if ba != 0 {
                    if ba < 17 {
                        let half = (1 << (ba - 1)) - 1
                        for k in 0 ..< groupSize {
                            dst[k] = Float(Int(bs.bits(ba)) - half)
                        }
                    } else {
                        let mod = (2 << (ba - 17)) + 1 // 3, 5, 9
                        var code = Int(bs.bits(mod + 2 - (mod >> 3))) // 5, 7, 10
                        for k in 0 ..< groupSize {
                            dst[k] = Float(code % mod - mod / 2)
                            code /= mod
                        }
                    }
                }
                dst += choff
                choff = 18 - choff
            }
        }
        return groupSize * 4
    }

    /// L12_apply_scf_384: twelve times of each band times their scale factor, the upper bands of
    /// joint stereo copied to the right first.
    func l12ApplyScf384(_ scfStart: UnsafePointer<Float>, _ dstStart: UnsafeMutablePointer<Float>) {
        let total = sciTotalBands, stereo = sciStereoBands
        (dstStart + 576 + stereo * 18).update(from: dstStart + stereo * 18, count: (total - stereo) * 18)
        var dst = dstStart, scf = scfStart
        for _ in 0 ..< total {
            for k in 0 ..< 12 {
                dst[k + 0] *= scf[0]
                dst[k + 576] *= scf[3]
            }
            dst += 18
            scf += 6
        }
    }
}
