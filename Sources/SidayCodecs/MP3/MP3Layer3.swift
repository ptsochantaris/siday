// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from minimp3, by lieff (https://github.com/lieff/minimp3), dedicated to the public domain
// under CC0: OpenMPT's copy of it, which libopenmpt decodes with.

/// Layer III: the side information, the bit reservoir, the scale factors, the Huffman codes, stereo
/// and the IMDCT, up to the 32 subbands of each of a granule's 18 times that the synthesis filter
/// makes sound of.
extension MP3Decoder {
    static let shortBlockType = 2
    static let stopBlockType = 3

    /// L3_read_side_info: each granule's and channel's side information, into `gr`; the place in the
    /// bit reservoir that the frame's main data starts at, or -1 if the side information cannot be.
    static func readSideInfo(_ bs: inout MP3BitStream, _ grStart: UnsafeMutablePointer<MP3GranuleInfo>, _ hdr: UnsafePointer<UInt8>, _ t: MP3TableMemory) -> Int {
        var tables: UInt32 = 0, scfsi: UInt32 = 0
        var mainDataBegin = 0, part23Sum = 0
        var srIdx = MP3Header.mySampleRate(hdr)
        srIdx -= srIdx != 0 ? 1 : 0
        let mono = MP3Header.isMono(hdr), mpeg1 = MP3Header.isMPEG1(hdr)
        var grCount = mono ? 1 : 2
        var gr = grStart

        if mpeg1 {
            grCount *= 2
            mainDataBegin = Int(bs.bits(9))
            scfsi = bs.bits(7 + grCount)
        } else {
            mainDataBegin = Int(bs.bits(8 + grCount) >> UInt32(grCount))
        }

        repeat {
            if mono {
                scfsi <<= 4
            }
            gr.pointee.part23Length = Int(bs.bits(12))
            part23Sum += gr.pointee.part23Length
            gr.pointee.bigValues = Int(bs.bits(9))
            if gr.pointee.bigValues > 288 {
                return -1
            }
            gr.pointee.globalGain = Int(bs.bits(8))
            gr.pointee.scalefacCompress = Int(bs.bits(mpeg1 ? 4 : 9))
            gr.pointee.sfbtab = t.scfLong + srIdx * 23
            gr.pointee.nLongSfb = 22
            gr.pointee.nShortSfb = 0
            if bs.bits(1) != 0 {
                gr.pointee.blockType = Int(bs.bits(2))
                if gr.pointee.blockType == 0 {
                    return -1
                }
                gr.pointee.mixedBlockFlag = Int(bs.bits(1))
                gr.pointee.regionCount0 = 7
                gr.pointee.regionCount1 = 255
                if gr.pointee.blockType == shortBlockType {
                    scfsi &= 0x0F0F
                    if gr.pointee.mixedBlockFlag == 0 {
                        gr.pointee.regionCount0 = 8
                        gr.pointee.sfbtab = t.scfShort + srIdx * 40
                        gr.pointee.nLongSfb = 0
                        gr.pointee.nShortSfb = 39
                    } else {
                        gr.pointee.sfbtab = t.scfMixed + srIdx * 40
                        gr.pointee.nLongSfb = mpeg1 ? 8 : 6
                        gr.pointee.nShortSfb = 30
                    }
                }
                tables = bs.bits(10)
                tables <<= 5
                gr.pointee.subblockGain0 = Int(bs.bits(3))
                gr.pointee.subblockGain1 = Int(bs.bits(3))
                gr.pointee.subblockGain2 = Int(bs.bits(3))
            } else {
                gr.pointee.blockType = 0
                gr.pointee.mixedBlockFlag = 0
                tables = bs.bits(15)
                gr.pointee.regionCount0 = Int(bs.bits(4))
                gr.pointee.regionCount1 = Int(bs.bits(3))
                gr.pointee.regionCount2 = 255
            }
            gr.pointee.tableSelect0 = Int(tables >> 10)
            gr.pointee.tableSelect1 = Int((tables >> 5) & 31)
            gr.pointee.tableSelect2 = Int(tables & 31)
            gr.pointee.preflag = mpeg1 ? Int(bs.bits(1)) : (gr.pointee.scalefacCompress >= 500 ? 1 : 0)
            gr.pointee.scalefacScale = Int(bs.bits(1))
            gr.pointee.count1Table = Int(bs.bits(1))
            gr.pointee.scfsi = Int((scfsi >> 12) & 15)
            scfsi <<= 4
            gr += 1
            grCount -= 1
        } while grCount != 0

        if part23Sum + bs.pos > bs.limit + mainDataBegin * 8 {
            return -1
        }
        return mainDataBegin
    }

    /// L3_read_scalefactors: up to four runs of scale factors of a size each. Those that the side
    /// information says are shared with the first granule are copied from `ist`, where the first
    /// granule's are left for them; `ist` is also where intensity stereo's positions are kept.
    @inline(__always)
    private func readScalefactors(_ scfStart: UnsafeMutablePointer<UInt8>, _ istStart: UnsafeMutablePointer<UInt8>, _ scfSize: UnsafePointer<UInt8>, _ scfCount: UnsafePointer<UInt8>, _ bitbuf: inout MP3BitStream, _ scfsiStart: Int) {
        var scf = scfStart, ist = istStart, scfsi = scfsiStart
        var i = 0
        while i < 4, scfCount[i] != 0 {
            let cnt = Int(scfCount[i])
            if scfsi & 8 != 0 {
                scf.update(from: ist, count: cnt)
            } else {
                let bits = Int(scfSize[i])
                if bits == 0 {
                    scf.update(repeating: 0, count: cnt)
                    ist.update(repeating: 0, count: cnt)
                } else {
                    let maxScf = scfsi < 0 ? (1 << bits) - 1 : -1
                    for k in 0 ..< cnt {
                        let s = Int(bitbuf.bits(bits))
                        ist[k] = s == maxScf ? 0xFF : UInt8(truncatingIfNeeded: s)
                        scf[k] = UInt8(truncatingIfNeeded: s)
                    }
                }
            }
            ist += cnt
            scf += cnt
            i += 1
            scfsi &*= 2
        }
        scf[0] = 0
        scf[1] = 0
        scf[2] = 0
    }

    /// L3_ldexp_q2: `y` times two to the power of minus a quarter of `expQ2`, in steps of at most 30.
    @inline(__always)
    static func ldexpQ2(_ yStart: Float, _ expQ2Start: Int, _ expFrac: UnsafePointer<Float>) -> Float {
        var y = yStart, expQ2 = expQ2Start
        repeat {
            let e = min(30 * 4, expQ2)
            y *= expFrac[e & 3] * Float((1 << 30) >> (e >> 2))
            expQ2 -= e
        } while expQ2 > 0
        return y
    }

    /// L3_decode_scalefactors: a granule's scale factors, each made the gain of its band.
    private func decodeScalefactors(_ hdr: UnsafePointer<UInt8>, _ ist: UnsafeMutablePointer<UInt8>, _ bs: inout MP3BitStream, _ gr: UnsafePointer<MP3GranuleInfo>, _ scf: UnsafeMutablePointer<Float>, _ ch: Int) {
        var scfPartition = t.scfPartitions + 28 * ((gr.pointee.nShortSfb != 0 ? 1 : 0) + (gr.pointee.nLongSfb == 0 ? 1 : 0))
        let scfShift = gr.pointee.scalefacScale + 1
        var scfsi = gr.pointee.scfsi

        if MP3Header.isMPEG1(hdr) {
            let part = t.scfcDecode[gr.pointee.scalefacCompress]
            scfSize[0] = part >> 2
            scfSize[1] = part >> 2
            scfSize[2] = part & 3
            scfSize[3] = part & 3
        } else {
            let ist = MP3Header.isIntensityStereo(hdr) && ch != 0 ? 1 : 0
            var sfc = gr.pointee.scalefacCompress >> ist
            var k = ist * 3 * 4
            while sfc >= 0 {
                var modprod = 1
                var i = 3
                while i >= 0 {
                    let mod = Int(t.scfMod[k + i])
                    scfSize[i] = UInt8(truncatingIfNeeded: sfc / modprod % mod)
                    modprod *= mod
                    i -= 1
                }
                sfc -= modprod
                k += 4
            }
            scfPartition += k
            scfsi = -16
        }
        readScalefactors(iscf, ist, scfSize, scfPartition, &bs, scfsi)

        let nLong = gr.pointee.nLongSfb, nShort = gr.pointee.nShortSfb
        if nShort != 0 {
            let sh = 3 - scfShift
            var i = 0
            while i < nShort {
                iscf[nLong + i + 0] &+= UInt8(truncatingIfNeeded: gr.pointee.subblockGain0 << sh)
                iscf[nLong + i + 1] &+= UInt8(truncatingIfNeeded: gr.pointee.subblockGain1 << sh)
                iscf[nLong + i + 2] &+= UInt8(truncatingIfNeeded: gr.pointee.subblockGain2 << sh)
                i += 3
            }
        } else if gr.pointee.preflag != 0 {
            for i in 0 ..< 10 {
                iscf[11 + i] &+= t.preamp[i]
            }
        }

        // BITS_DEQUANTIZER_OUT is -1, and MAX_SCFI 44.
        let gainExp = gr.pointee.globalGain + -1 * 4 - 210 - (MP3Header.isMSStereo(hdr) ? 2 : 0)
        let gain = Self.ldexpQ2(Float(1 << (44 / 4)), 44 - gainExp, t.expFrac)
        for i in 0 ..< nLong + nShort {
            scf[i] = Self.ldexpQ2(gain, Int(iscf[i]) << scfShift, t.expFrac)
        }
    }

    /// L3_pow_43: `x` to the power of four thirds, from the table up to 128, and above it from the
    /// table's nearest and a short series.
    @inline(__always)
    private static func pow43(_ xStart: Int, _ table: UnsafePointer<Float>) -> Float {
        var x = xStart, mult = 256
        if x < 129 {
            return table[16 + x]
        }
        if x < 1024 {
            mult = 16
            x <<= 3
        }
        let sign = 2 * x & 64
        let frac = Float((x & 63) - sign) / Float((x & ~63) + sign)
        return table[16 + ((x + sign) >> 6)] * (1 + frac * ((4.0 / 3) + frac * (2.0 / 9))) * Float(mult)
    }

    /// L3_huffman: a granule's frequency lines, from the big values' pairs and then the quadruples of
    /// ones, each times its band's scale factor, up to `layer3grLimit` bits into the main data.
    private func huffman(_ dstStart: UnsafeMutablePointer<Float>, _ bs: inout MP3BitStream, _ gr: UnsafePointer<MP3GranuleInfo>, _ scfStart: UnsafePointer<Float>, _ layer3grLimit: Int) {
        let tabs = t.huffman, pow43Table = t.pow43
        let buf = bs.buf
        // A granule that says it has more than the frame brings is read on into what the buffer holds
        // from the frames before, as the C reads on into its buffer on the stack, which the decoding of
        // the frames before left there too; a read past the end of the buffer gets zeros.
        let end = Self.mainDataCapacity
        @inline(__always) func byte(_ at: Int) -> UInt32 {
            at < end ? UInt32(buf[at]) : 0
        }

        var dst = dstStart
        var scf = scfStart
        var one: Float = 0
        var ireg = 0, bigValCnt = gr.pointee.bigValues
        var sfb = gr.pointee.sfbtab
        var next = bs.pos / 8
        var cache: UInt32 = (((byte(next) * 256 &+ byte(next + 1)) * 256 &+ byte(next + 2)) * 256 &+ byte(next + 3)) &<< UInt32(bs.pos & 7)
        var sh = (bs.pos & 7) - 8
        next += 4
        var np = 0

        // The C's PEEK_BITS, FLUSH_BITS and CHECK_BITS. A shift by 32 or more is taken as arm64 takes it.
        @inline(__always) func peek(_ n: Int) -> Int { Int(cache &>> UInt32(truncatingIfNeeded: 32 - n)) }
        @inline(__always) func flush(_ n: Int) {
            cache = cache &<< UInt32(truncatingIfNeeded: n)
            sh += n
        }
        @inline(__always) func check() {
            while sh >= 0 {
                cache |= byte(next) &<< UInt32(truncatingIfNeeded: sh)
                next += 1
                sh -= 8
            }
        }

        while bigValCnt > 0 {
            let tabNum: Int, sfbCount: Int
            switch ireg {
            case 0: tabNum = gr.pointee.tableSelect0; sfbCount = gr.pointee.regionCount0
            case 1: tabNum = gr.pointee.tableSelect1; sfbCount = gr.pointee.regionCount1
            default: tabNum = gr.pointee.tableSelect2; sfbCount = gr.pointee.regionCount2
            }
            ireg += 1
            var sfbCnt = sfbCount
            let codebook = tabs + Int(t.huffmanIndex[tabNum])
            let linbits = Int(t.linbits[tabNum])
            if linbits != 0 {
                repeat {
                    np = Int(sfb.pointee) / 2
                    sfb += 1
                    // (The tables' bands add up to all 576 lines, so a granule's big values always end
                    // within them; this is for safety only.)
                    if np == 0 { bigValCnt = 0; break }
                    var pairsToDecode = min(bigValCnt, np)
                    one = scf.pointee
                    scf += 1
                    repeat {
                        var w = 5
                        var leaf = Int(codebook[peek(w)])
                        while leaf < 0 {
                            flush(w)
                            w = leaf & 7
                            leaf = Int(codebook[peek(w) - (leaf >> 3)])
                        }
                        flush(leaf >> 8)

                        for _ in 0 ..< 2 {
                            var lsb = leaf & 0x0F
                            if lsb == 15 {
                                lsb += peek(linbits)
                                flush(linbits)
                                check()
                                dst.pointee = one * Self.pow43(lsb, pow43Table) * (Int32(bitPattern: cache) < 0 ? -1 : 1)
                            } else {
                                dst.pointee = pow43Table[16 + lsb - 16 * Int(cache >> 31)] * one
                            }
                            flush(lsb != 0 ? 1 : 0)
                            dst += 1
                            leaf >>= 4
                        }
                        check()
                        pairsToDecode -= 1
                    } while pairsToDecode != 0
                    bigValCnt -= np
                    sfbCnt -= 1
                } while bigValCnt > 0 && sfbCnt >= 0
            } else {
                repeat {
                    np = Int(sfb.pointee) / 2
                    sfb += 1
                    if np == 0 { bigValCnt = 0; break }
                    var pairsToDecode = min(bigValCnt, np)
                    one = scf.pointee
                    scf += 1
                    repeat {
                        var w = 5
                        var leaf = Int(codebook[peek(w)])
                        while leaf < 0 {
                            flush(w)
                            w = leaf & 7
                            leaf = Int(codebook[peek(w) - (leaf >> 3)])
                        }
                        flush(leaf >> 8)

                        for _ in 0 ..< 2 {
                            let lsb = leaf & 0x0F
                            dst.pointee = pow43Table[16 + lsb - 16 * Int(cache >> 31)] * one
                            flush(lsb != 0 ? 1 : 0)
                            dst += 1
                            leaf >>= 4
                        }
                        check()
                        pairsToDecode -= 1
                    } while pairsToDecode != 0
                    bigValCnt -= np
                    sfbCnt -= 1
                } while bigValCnt > 0 && sfbCnt >= 0
            }
        }

        np = 1 - bigValCnt
        let codebookCount1 = gr.pointee.count1Table != 0 ? t.count1B : t.count1A
        count1: while true {
            var leaf = Int(codebookCount1[peek(4)])
            if leaf & 8 == 0 {
                leaf = Int(codebookCount1[(leaf >> 3) + Int((cache &<< 4) &>> UInt32(truncatingIfNeeded: 32 - (leaf & 3)))])
            }
            flush(leaf & 7)
            if (next * 8 - 24 + sh) > layer3grLimit {
                break
            }
            // RELOAD_SCALEFACTOR and DEQ_COUNT1.
            np -= 1
            if np == 0 {
                np = Int(sfb.pointee) / 2
                sfb += 1
                if np == 0 { break count1 }
                one = scf.pointee
                scf += 1
            }
            if leaf & (128 >> 0) != 0 { dst[0] = Int32(bitPattern: cache) < 0 ? -one : one; flush(1) }
            if leaf & (128 >> 1) != 0 { dst[1] = Int32(bitPattern: cache) < 0 ? -one : one; flush(1) }
            np -= 1
            if np == 0 {
                np = Int(sfb.pointee) / 2
                sfb += 1
                if np == 0 { break count1 }
                one = scf.pointee
                scf += 1
            }
            if leaf & (128 >> 2) != 0 { dst[2] = Int32(bitPattern: cache) < 0 ? -one : one; flush(1) }
            if leaf & (128 >> 3) != 0 { dst[3] = Int32(bitPattern: cache) < 0 ? -one : one; flush(1) }
            check()
            dst += 4
        }

        bs.pos = layer3grLimit
    }

    /// L3_midside_stereo.
    @inline(__always)
    private func midsideStereo(_ left: UnsafeMutablePointer<Float>, _ n: Int) {
        let right = left + 576
        for i in 0 ..< n {
            let a = left[i], b = right[i]
            left[i] = a + b
            right[i] = a - b
        }
    }

    /// L3_intensity_stereo_band.
    @inline(__always)
    private func intensityStereoBand(_ left: UnsafeMutablePointer<Float>, _ n: Int, _ kl: Float, _ kr: Float) {
        for i in 0 ..< n {
            left[i + 576] = left[i] * kr
            left[i] = left[i] * kl
        }
    }

    /// L3_stereo_top_band: the highest band of each of the three windows in which the right channel
    /// has anything.
    private func stereoTopBand(_ rightStart: UnsafePointer<Float>, _ sfb: UnsafePointer<UInt8>, _ nbands: Int, _ maxBand: inout (Int, Int, Int)) {
        var right = rightStart
        maxBand = (-1, -1, -1)
        for i in 0 ..< nbands {
            let width = Int(sfb[i])
            var k = 0
            band: while k < width {
                if right[k] != 0 || right[k + 1] != 0 {
                    switch i % 3 {
                    case 0: maxBand.0 = i
                    case 1: maxBand.1 = i
                    default: maxBand.2 = i
                    }
                    break band
                }
                k += 2
            }
            right += width
        }
    }

    /// L3_stereo_process: intensity stereo above the top band, and middle and side below it.
    private func stereoProcess(_ leftStart: UnsafeMutablePointer<Float>, _ istPos: UnsafePointer<UInt8>, _ sfb: UnsafePointer<UInt8>, _ hdr: UnsafePointer<UInt8>, _ maxBand: (Int, Int, Int), _ mpeg2Sh: Int) {
        var left = leftStart
        let mpeg1 = MP3Header.isMPEG1(hdr)
        let maxPos = mpeg1 ? 7 : 64
        let msStereo = MP3Header.isMSStereoFlag(hdr)
        var i = 0
        while sfb[i] != 0 {
            let ipos = Int(istPos[i])
            let top: Int
            switch i % 3 {
            case 0: top = maxBand.0
            case 1: top = maxBand.1
            default: top = maxBand.2
            }
            if i > top, ipos < maxPos {
                var kl: Float, kr: Float
                let s: Float = msStereo ? 1.41421356 : 1
                if mpeg1 {
                    kl = t.pan[2 * ipos]
                    kr = t.pan[2 * ipos + 1]
                } else {
                    kl = 1
                    kr = Self.ldexpQ2(1, ((ipos + 1) >> 1) << mpeg2Sh, t.expFrac)
                    if ipos & 1 != 0 {
                        kl = kr
                        kr = 1
                    }
                }
                intensityStereoBand(left, Int(sfb[i]), kl * s, kr * s)
            } else if msStereo {
                midsideStereo(left, Int(sfb[i]))
            }
            left += Int(sfb[i])
            i += 1
        }
    }

    /// L3_intensity_stereo.
    private func intensityStereo(_ left: UnsafeMutablePointer<Float>, _ istPos: UnsafeMutablePointer<UInt8>, _ gr: UnsafePointer<MP3GranuleInfo>, _ hdr: UnsafePointer<UInt8>) {
        var maxBand = (0, 0, 0)
        let nSfb = gr.pointee.nLongSfb + gr.pointee.nShortSfb
        let maxBlocks = gr.pointee.nShortSfb != 0 ? 3 : 1

        stereoTopBand(left + 576, gr.pointee.sfbtab, nSfb, &maxBand)
        if gr.pointee.nLongSfb != 0 {
            let top = max(max(maxBand.0, maxBand.1), maxBand.2)
            maxBand = (top, top, top)
        }
        for i in 0 ..< maxBlocks {
            let defaultPos: UInt8 = MP3Header.isMPEG1(hdr) ? 3 : 0
            let itop = nSfb - maxBlocks + i
            let prev = itop - maxBlocks
            let band = i == 0 ? maxBand.0 : i == 1 ? maxBand.1 : maxBand.2
            istPos[itop] = band >= prev ? defaultPos : istPos[prev]
        }
        stereoProcess(left, istPos, gr.pointee.sfbtab, hdr, maxBand, gr[1].scalefacCompress & 1)
    }

    /// L3_reorder: a short block's lines from each window's run to the three windows side by side.
    private func reorder(_ grbuf: UnsafeMutablePointer<Float>, _ scratch: UnsafeMutablePointer<Float>, _ sfbStart: UnsafePointer<UInt8>) {
        var src = grbuf, dst = scratch, sfb = sfbStart
        while true {
            let len = Int(sfb.pointee)
            if len == 0 { break }
            for _ in 0 ..< len {
                dst[0] = src[0 * len]
                dst[1] = src[1 * len]
                dst[2] = src[2 * len]
                dst += 3
                src += 1
            }
            sfb += 3
            src += 2 * len
        }
        grbuf.update(from: scratch, count: dst - scratch)
    }

    /// L3_antialias: the butterflies between each pair of neighbouring subbands.
    private func antialias(_ grbufStart: UnsafeMutablePointer<Float>, _ nbandsStart: Int) {
        let aa = t.antialias
        var grbuf = grbufStart, nbands = nbandsStart
        while nbands > 0 {
            for i in 0 ..< 8 {
                let u = grbuf[18 + i]
                let d = grbuf[17 - i]
                grbuf[18 + i] = u * aa[i] - d * aa[8 + i]
                grbuf[17 - i] = u * aa[8 + i] + d * aa[i]
            }
            nbands -= 1
            grbuf += 18
        }
    }

    /// L3_dct3_9.
    @inline(__always)
    private func dct3_9(_ y: UnsafeMutablePointer<Float>) {
        var s0 = y[0], s2 = y[2], s4 = y[4], s6 = y[6], s8 = y[8]
        var t0 = s0 + s6 * 0.5
        s0 -= s6
        var t4 = (s4 + s2) * 0.93969262
        var t2 = (s8 + s2) * 0.76604444
        s6 = (s4 - s8) * 0.17364818
        s4 += s8 - s2

        s2 = s0 - s4 * 0.5
        y[4] = s4 + s0
        s8 = t0 - t2 + s6
        s0 = t0 - t4 + t2
        s4 = t0 + t4 - s6

        var s1 = y[1], s3 = y[3], s5 = y[5], s7 = y[7]

        s3 *= 0.86602540
        t0 = (s5 + s1) * 0.98480775
        t4 = (s5 - s7) * 0.34202014
        t2 = (s1 + s7) * 0.64278761
        s1 = (s1 - s5 - s7) * 0.86602540

        s5 = t0 - s3 - t2
        s7 = t4 - s3 - t0
        s3 = t4 + s3 - t2

        y[0] = s4 - s7
        y[1] = s2 + s1
        y[2] = s0 - s3
        y[3] = s8 + s5
        y[5] = s8 - s5
        y[6] = s0 + s3
        y[7] = s2 - s1
        y[8] = s4 + s7
    }

    /// L3_imdct36: the long blocks' 36-point IMDCT, windowed, overlapped with the last granule's.
    private func imdct36(_ grbufStart: UnsafeMutablePointer<Float>, _ overlapStart: UnsafeMutablePointer<Float>, _ window: UnsafePointer<Float>, _ nbands: Int) {
        let twid9 = t.twiddle9
        var grbuf = grbufStart, overlap = overlapStart
        // co and si, nine each.
        let co = dctT, si = dctT + 9
        for _ in 0 ..< nbands {
            co[0] = -grbuf[0]
            si[0] = grbuf[17]
            for i in 0 ..< 4 {
                si[8 - 2 * i] = grbuf[4 * i + 1] - grbuf[4 * i + 2]
                co[1 + 2 * i] = grbuf[4 * i + 1] + grbuf[4 * i + 2]
                si[7 - 2 * i] = grbuf[4 * i + 4] - grbuf[4 * i + 3]
                co[2 + 2 * i] = -(grbuf[4 * i + 3] + grbuf[4 * i + 4])
            }
            dct3_9(co)
            dct3_9(si)

            si[1] = -si[1]
            si[3] = -si[3]
            si[5] = -si[5]
            si[7] = -si[7]

            for i in 0 ..< 9 {
                let ovl = overlap[i]
                let sum = co[i] * twid9[9 + i] + si[i] * twid9[0 + i]
                overlap[i] = co[i] * twid9[0 + i] - si[i] * twid9[9 + i]
                grbuf[i] = ovl * window[0 + i] - sum * window[9 + i]
                grbuf[17 - i] = ovl * window[9 + i] + sum * window[0 + i]
            }
            grbuf += 18
            overlap += 9
        }
    }

    /// L3_idct3.
    @inline(__always)
    private func idct3(_ x0: Float, _ x1: Float, _ x2: Float, _ dst: UnsafeMutablePointer<Float>) {
        let m1 = x1 * 0.86602540
        let a1 = x0 - x2 * 0.5
        dst[1] = x0 + x2
        dst[0] = a1 + m1
        dst[2] = a1 - m1
    }

    /// L3_imdct12.
    @inline(__always)
    private func imdct12(_ x: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<Float>, _ overlap: UnsafeMutablePointer<Float>) {
        let twid3 = t.twiddle3
        let co = dctT + 18, si = dctT + 21
        idct3(-x[0], x[6] + x[3], x[12] + x[9], co)
        idct3(x[15], x[12] - x[9], x[6] - x[3], si)
        si[1] = -si[1]

        for i in 0 ..< 3 {
            let ovl = overlap[i]
            let sum = co[i] * twid3[3 + i] + si[i] * twid3[0 + i]
            overlap[i] = co[i] * twid3[0 + i] - si[i] * twid3[3 + i]
            dst[i] = ovl * twid3[2 - i] - sum * twid3[5 - i]
            dst[5 - i] = ovl * twid3[5 - i] + sum * twid3[2 - i]
        }
    }

    /// L3_imdct_short: the short blocks' three 12-point IMDCTs.
    private func imdctShort(_ grbufStart: UnsafeMutablePointer<Float>, _ overlapStart: UnsafeMutablePointer<Float>, _ nbandsStart: Int) {
        var grbuf = grbufStart, overlap = overlapStart, nbands = nbandsStart
        // The C's tmp, after imdct12's co and si.
        let tmp = syn + 32 * 64
        while nbands > 0 {
            tmp.update(from: grbuf, count: 18)
            grbuf.update(from: overlap, count: 6)
            imdct12(tmp, grbuf + 6, overlap + 6)
            imdct12(tmp + 1, grbuf + 12, overlap + 6)
            imdct12(tmp + 2, overlap, overlap + 6)
            nbands -= 1
            overlap += 9
            grbuf += 18
        }
    }

    /// L3_change_sign: every other time of every other subband turned over, for the synthesis.
    private func changeSign(_ grbufStart: UnsafeMutablePointer<Float>) {
        var grbuf = grbufStart + 18
        for _ in stride(from: 0, to: 32, by: 2) {
            var i = 1
            while i < 18 {
                grbuf[i] = -grbuf[i]
                i += 2
            }
            grbuf += 36
        }
    }

    /// L3_imdct_gr.
    private func imdctGranule(_ grbufStart: UnsafeMutablePointer<Float>, _ overlapStart: UnsafeMutablePointer<Float>, _ blockType: Int, _ nLongBands: Int) {
        var grbuf = grbufStart, overlap = overlapStart
        if nLongBands != 0 {
            imdct36(grbuf, overlap, t.mdctWindow, nLongBands)
            grbuf += 18 * nLongBands
            overlap += 9 * nLongBands
        }
        if blockType == Self.shortBlockType {
            imdctShort(grbuf, overlap, 32 - nLongBands)
        } else {
            imdct36(grbuf, overlap, t.mdctWindow + (blockType == Self.stopBlockType ? 18 : 0), 32 - nLongBands)
        }
    }

    /// L3_save_reservoir: what is left of the main data, up to 511 bytes, for the frames after.
    func saveReservoir() {
        var pos = (bs.pos + 7) / 8
        var remains = bs.limit / 8 - pos
        if remains > Self.maxBitReservoirBytes {
            pos += remains - Self.maxBitReservoirBytes
            remains = Self.maxBitReservoirBytes
        }
        if remains > 0 {
            reservBuf.update(from: maindata + pos, count: remains)
        }
        reserv = max(0, remains)
    }

    /// L3_restore_reservoir: the frame's main data after the bit reservoir's bytes that it starts in.
    /// Whether the reservoir had all of them.
    func restoreReservoir(_ bsFrame: inout MP3BitStream, _ mainDataBegin: Int) -> Bool {
        let frameBytes = min((bsFrame.limit - bsFrame.pos) / 8, Self.maxL3FramePayloadBytes)
        let bytesHave = min(reserv, mainDataBegin)
        maindata.update(from: reservBuf + max(0, reserv - mainDataBegin), count: bytesHave)
        maindata.advanced(by: bytesHave).update(from: bsFrame.buf + bsFrame.pos / 8, count: frameBytes)
        bs = MP3BitStream(UnsafePointer(maindata), bytes: bytesHave + frameBytes)
        return reserv >= mainDataBegin
    }

    /// L3_decode: a granule of each channel, to its 576 lines in the subbands' time order.
    func l3Decode(_ grStart: UnsafeMutablePointer<MP3GranuleInfo>, _ nch: Int) {
        let hdr = UnsafePointer(header)
        for ch in 0 ..< nch {
            let layer3grLimit = bs.pos + grStart[ch].part23Length
            decodeScalefactors(hdr, istPos + 39 * ch, &bs, grStart + ch, scf, ch)
            huffman(grbuf + 576 * ch, &bs, grStart + ch, scf, layer3grLimit)
        }

        if MP3Header.isIntensityStereo(hdr) {
            intensityStereo(grbuf, istPos + 39, grStart, hdr)
        } else if MP3Header.isMSStereo(hdr) {
            midsideStereo(grbuf, 576)
        }

        var gr = grStart
        for ch in 0 ..< nch {
            var aaBands = 31
            let nLongBands = (gr.pointee.mixedBlockFlag != 0 ? 2 : 0) << (MP3Header.mySampleRate(hdr) == 2 ? 1 : 0)
            let channel = grbuf + 576 * ch

            if gr.pointee.nShortSfb != 0 {
                aaBands = nLongBands - 1
                reorder(channel + nLongBands * 18, syn, gr.pointee.sfbtab + gr.pointee.nLongSfb)
            }

            antialias(channel, aaBands)
            imdctGranule(channel, mdctOverlap + 9 * 32 * ch, gr.pointee.blockType, nLongBands)
            changeSign(channel)
            gr += 1
        }
    }
}
