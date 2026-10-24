// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from minimp3, by lieff (https://github.com/lieff/minimp3), dedicated to the public domain
// under CC0: OpenMPT's copy of it, which libopenmpt decodes with.

/// The polyphase synthesis filter, which every layer ends with: 32 subbands at a time to 32 samples.
extension MP3Decoder {
    /// mp3d_DCT_II: each of `n` times of the 32 subbands through a 32-point DCT, in place.
    private func dctII(_ grbuf: UnsafeMutablePointer<Float>, _ n: Int) {
        let sec = t.dctSecants
        let t = dctT
        for k in 0 ..< n {
            var y = grbuf + k

            for i in 0 ..< 8 {
                let x0 = y[i * 18]
                let x1 = y[(15 - i) * 18]
                let x2 = y[(16 + i) * 18]
                let x3 = y[(31 - i) * 18]
                let t0 = x0 + x3
                let t1 = x1 + x2
                let t2 = (x1 - x2) * sec[3 * i + 0]
                let t3 = (x0 - x3) * sec[3 * i + 1]
                t[i] = t0 + t1
                t[i + 8] = (t0 - t1) * sec[3 * i + 2]
                t[i + 16] = t3 + t2
                t[i + 24] = (t3 - t2) * sec[3 * i + 2]
            }
            var x = t
            for _ in 0 ..< 4 {
                var x0 = x[0], x1 = x[1], x2 = x[2], x3 = x[3], x4 = x[4], x5 = x[5], x6 = x[6], x7 = x[7]
                var xt = x0 - x7; x0 += x7
                x7 = x1 - x6; x1 += x6
                x6 = x2 - x5; x2 += x5
                x5 = x3 - x4; x3 += x4
                x4 = x0 - x3; x0 += x3
                x3 = x1 - x2; x1 += x2
                x[0] = x0 + x1
                x[4] = (x0 - x1) * 0.70710677
                x5 = x5 + x6
                x6 = (x6 + x7) * 0.70710677
                x7 = x7 + xt
                x3 = (x3 + x4) * 0.70710677
                x5 -= x7 * 0.198912367 // rotate by PI/8
                x7 += x5 * 0.382683432
                x5 -= x7 * 0.198912367
                x0 = xt - x6; xt += x6
                x[1] = (xt + x7) * 0.50979561
                x[2] = (x4 + x3) * 0.54119611
                x[3] = (x0 - x5) * 0.60134488
                x[5] = (x0 + x5) * 0.89997619
                x[6] = (x4 - x3) * 1.30656302
                x[7] = (xt - x7) * 2.56291556
                x += 8
            }
            for i in 0 ..< 7 {
                y[0 * 18] = t[i]
                y[1 * 18] = t[16 + i] + t[24 + i] + t[24 + i + 1]
                y[2 * 18] = t[8 + i] + t[8 + i + 1]
                y[3 * 18] = t[16 + i + 1] + t[24 + i] + t[24 + i + 1]
                y += 4 * 18
            }
            y[0 * 18] = t[7]
            y[1 * 18] = t[16 + 7] + t[24 + 7]
            y[2 * 18] = t[8 + 7]
            y[3 * 18] = t[24 + 7]
        }
    }

    /// mp3d_synth_pair: the first and the seventeenth sample of a channel's 32, which the window's
    /// symmetry gives from fewer terms.
    @inline(__always)
    private func synthPair<Sample: MP3Sample>(_ pcm: UnsafeMutablePointer<Sample>, _ nch: Int, _ zStart: UnsafePointer<Float>) {
        var z = zStart
        var a: Float
        a = (z[14 * 64] - z[0]) * 29
        a += (z[1 * 64] + z[13 * 64]) * 213
        a += (z[12 * 64] - z[2 * 64]) * 459
        a += (z[3 * 64] + z[11 * 64]) * 2037
        a += (z[10 * 64] - z[4 * 64]) * 5153
        a += (z[5 * 64] + z[9 * 64]) * 6574
        a += (z[8 * 64] - z[6 * 64]) * 37489
        a += z[7 * 64] * 75038
        pcm[0] = Sample.fromSynthesis(a)

        z += 2
        a = z[14 * 64] * 104
        a += z[12 * 64] * 1567
        a += z[10 * 64] * 9727
        a += z[8 * 64] * 64019
        a += z[6 * 64] * -9975
        a += z[4 * 64] * -45
        a += z[2 * 64] * 146
        a += z[0 * 64] * -5
        pcm[16 * nch] = Sample.fromSynthesis(a)
    }

    /// mp3d_synth: two times of the subbands, both channels side by side in `lins`, the filter's
    /// history, to 64 samples of each channel.
    private func synth<Sample: MP3Sample>(_ xl: UnsafeMutablePointer<Float>, _ dstl: UnsafeMutablePointer<Sample>, _ nch: Int, _ lins: UnsafeMutablePointer<Float>) {
        let xr = xl + 576 * (nch - 1)
        let dstr = dstl + (nch - 1)
        let zlin = lins + 15 * 64
        var w = t.synthWindow

        zlin[4 * 15] = xl[18 * 16]
        zlin[4 * 15 + 1] = xr[18 * 16]
        zlin[4 * 15 + 2] = xl[0]
        zlin[4 * 15 + 3] = xr[0]

        zlin[4 * 31] = xl[1 + 18 * 16]
        zlin[4 * 31 + 1] = xr[1 + 18 * 16]
        zlin[4 * 31 + 2] = xl[1]
        zlin[4 * 31 + 3] = xr[1]

        synthPair(dstr, nch, lins + 4 * 15 + 1)
        synthPair(dstr + 32 * nch, nch, lins + 4 * 15 + 64 + 1)
        synthPair(dstl, nch, lins + 4 * 15)
        synthPair(dstl + 32 * nch, nch, lins + 4 * 15 + 64)

        var i = 14
        while i >= 0 {
            var a0: Float = 0, a1: Float = 0, a2: Float = 0, a3: Float = 0
            var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0

            zlin[4 * i] = xl[18 * (31 - i)]
            zlin[4 * i + 1] = xr[18 * (31 - i)]
            zlin[4 * i + 2] = xl[1 + 18 * (31 - i)]
            zlin[4 * i + 3] = xr[1 + 18 * (31 - i)]
            zlin[4 * (i + 16)] = xl[1 + 18 * (1 + i)]
            zlin[4 * (i + 16) + 1] = xr[1 + 18 * (1 + i)]
            zlin[4 * (i - 16) + 2] = xl[18 * (1 + i)]
            zlin[4 * (i - 16) + 3] = xr[18 * (1 + i)]

            // The C's S0, S1 and S2, for k from 0 to 7: S0(0) S2(1) S1(2) S2(3) S1(4) S2(5) S1(6) S2(7).
            for k in 0 ..< 8 {
                let w0 = w[0], w1 = w[1]
                w += 2
                let vz = zlin + (4 * i - k * 64)
                let vy = zlin + (4 * i - (15 - k) * 64)
                if k == 0 {
                    b0 = vz[0] * w1 + vy[0] * w0; a0 = vz[0] * w0 - vy[0] * w1
                    b1 = vz[1] * w1 + vy[1] * w0; a1 = vz[1] * w0 - vy[1] * w1
                    b2 = vz[2] * w1 + vy[2] * w0; a2 = vz[2] * w0 - vy[2] * w1
                    b3 = vz[3] * w1 + vy[3] * w0; a3 = vz[3] * w0 - vy[3] * w1
                } else if k & 1 == 0 {
                    b0 += vz[0] * w1 + vy[0] * w0; a0 += vz[0] * w0 - vy[0] * w1
                    b1 += vz[1] * w1 + vy[1] * w0; a1 += vz[1] * w0 - vy[1] * w1
                    b2 += vz[2] * w1 + vy[2] * w0; a2 += vz[2] * w0 - vy[2] * w1
                    b3 += vz[3] * w1 + vy[3] * w0; a3 += vz[3] * w0 - vy[3] * w1
                } else {
                    b0 += vz[0] * w1 + vy[0] * w0; a0 += vy[0] * w1 - vz[0] * w0
                    b1 += vz[1] * w1 + vy[1] * w0; a1 += vy[1] * w1 - vz[1] * w0
                    b2 += vz[2] * w1 + vy[2] * w0; a2 += vy[2] * w1 - vz[2] * w0
                    b3 += vz[3] * w1 + vy[3] * w0; a3 += vy[3] * w1 - vz[3] * w0
                }
            }

            dstr[(15 - i) * nch] = Sample.fromSynthesis(a1)
            dstr[(17 + i) * nch] = Sample.fromSynthesis(b1)
            dstl[(15 - i) * nch] = Sample.fromSynthesis(a0)
            dstl[(17 + i) * nch] = Sample.fromSynthesis(b0)
            dstr[(47 - i) * nch] = Sample.fromSynthesis(a3)
            dstr[(49 + i) * nch] = Sample.fromSynthesis(b3)
            dstl[(47 - i) * nch] = Sample.fromSynthesis(a2)
            dstl[(49 + i) * nch] = Sample.fromSynthesis(b2)
            i -= 1
        }
    }

    /// mp3d_synth_granule: `nbands` times of each channel's subbands to sound, through the filter
    /// whose history is kept in `qmfState` from one granule to the next.
    func synthGranule<Sample: MP3Sample>(_ grbuf: UnsafeMutablePointer<Float>, _ nbands: Int, _ nch: Int, _ pcm: UnsafeMutablePointer<Sample>, _ lins: UnsafeMutablePointer<Float>) {
        for i in 0 ..< nch {
            dctII(grbuf + 576 * i, nbands)
        }

        lins.update(from: qmfState, count: 15 * 64)

        for i in stride(from: 0, to: nbands, by: 2) {
            synth(grbuf + i, pcm + 32 * nch * i, nch, lins + i * 64)
        }
        // A mono stream is filtered in all four lanes, the second and fourth a copy of the first and
        // third, and written from both, the first and third last; and of the history, as in the C
        // without MINIMP3_NONSTANDARD_BUT_LOGICAL, only that of the first and third is kept.
        if nch == 1 {
            for i in stride(from: 0, to: 15 * 64, by: 2) {
                qmfState[i] = lins[nbands * 64 + i]
            }
        } else {
            qmfState.update(from: lins + nbands * 64, count: 15 * 64)
        }
    }
}
