// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import Foundation

/// Renders a SID register-write trace through ReSIDfpChip, for comparison with the C++ reSIDfp reference
/// harness (sidfpref.cc). Reached through the hidden `--sid-trace` option with `engine=residfp`.
///
/// Trace lines are those of SIDTrace; the pseudo-registers mean, for this engine:
///   32  setFilterEnabled(value != 0)
///   33  input(value)                 (signed 16-bit EXT IN sample)
///   34  voice mask of the reSID traces: voice v (0...2) is muted when bit v is clear
///   35  reset()                      (mode=lib: followed by write($18, $0f), as c64sid::reset() does)
///   36, 37, 38  no-op (reSID's external filter switch and filter bias; 38 only advances time)
///   39  explicit read(value), printed to the readback / reads file
///   40  clock(value) with no output (clockSilent), in addition to cycle_delta   (mode=lib: plain clocking)
///   41  clock one cycle `value` times with the output discarded                 (mode=lib: plain clocking)
///   42  setFilter6581Curve(value / 1000.0)
///   43  setFilter6581Range(value / 1000.0)
///   44  setFilter8580Curve(value / 1000.0)
///   45  setVoiceMuted(value & 3, (value >> 2) & 1 != 0)
///   46  setCombinedWaveforms(value)  1 average, 2 weak, 3 strong
///
/// Options, comma separated: engine=residfp, model=6581|8580, clock=<Hz>, rate=<Hz>, sampling=decimate|resample,
/// curve=<x> (the filter curve of the chip's model), curve6581=<x>, curve8580=<x>, range=<x>, cws=average|weak|strong,
/// mode=engine|lib (lib: set the chip up and drive it as libsidplayfp's ReSIDfp wrapper does), digiboost,
/// sids=<n> (mode=lib: the number of emulations the front end created, see below),
/// poweron=<cycles> (mode=lib: clocked and discarded before the trace), out=<raw 16-bit mono file>,
/// readback=<file> (OSC3 and ENV3 after every line), reads=<file> (explicit reads only),
/// tables (print a digest of every internal table), bench, repeat=<n>.
/// With an empty trace path only the tables are printed.
extension SIDTrace {
    static func runReSIDfp(trace: String, options: String) throws {
        var model = SIDModel.mos6581
        var clockHz = 985_248.0
        var rate = 48000.0
        var sampling = ReSIDfpSampling.resample
        var out: String?
        var readback: String?
        var reads: String?
        var tables = false
        var bench = false
        var repeats = 1
        var lib = false
        var digiboost = false
        var poweron = 0
        var sids = 1
        var curve: Double?
        var curve6581: Double?
        var curve8580: Double?
        var range: Double?
        var cws: ReSIDfpCombinedWaveforms?

        for option in options.split(separator: ",") {
            let parts = option.split(separator: "=", maxSplits: 1)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            switch key {
            case "engine": break
            case "model": model = value == "8580" ? .mos8580 : .mos6581
            case "clock": clockHz = Double(value) ?? clockHz
            case "rate": rate = Double(value) ?? rate
            case "sampling":
                switch value {
                case "decimate": sampling = .decimate
                case "resample": sampling = .resample
                default: throw TuneError.unsupported("sampling \(value)")
                }
            case "curve": curve = Double(value)
            case "curve6581": curve6581 = Double(value)
            case "curve8580": curve8580 = Double(value)
            case "range": range = Double(value)
            case "cws": cws = value == "weak" ? .weak : value == "strong" ? .strong : .average
            case "mode": lib = value == "lib"
            case "digiboost": digiboost = true
            case "poweron": poweron = Int(value) ?? 0
            case "sids": sids = max(1, Int(value) ?? 1)
            case "out": out = value
            case "readback": readback = value
            case "reads": reads = value
            case "tables": tables = true
            case "bench": bench = true
            case "repeat": repeats = Int(value) ?? 1
            default: throw TuneError.unsupported("sid-trace option \(key)")
            }
        }
        if let curve {
            if model == .mos6581 { curve6581 = curve } else { curve8580 = curve }
        }

        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) * 1e-6
        }

        let clock = ContinuousClock()
        let t0 = clock.now
        let c0 = cpuSeconds()
        // libsidplayfp hands the engine the CPU clock as a float: Player::sidParams(), s->sampling((float)cpuFreq, ...).
        var sid = ReSIDfpChip(model: model, clockHz: lib ? Double(Float(clockHz)) : clockHz, sampleRate: rate, sampling: sampling)
        if !lib {
            // sidfpref.cc --mode engine: setCombinedWaveforms before setSamplingParameters and reset (no effect on
            // the order of anything), then range and curves.
            if let cws { sid.setCombinedWaveforms(cws) }
            if let range { sid.setFilter6581Range(range) }
            if let curve6581 { sid.setFilter6581Curve(curve6581) }
            if let curve8580 { sid.setFilter8580Curve(curve8580) }
        } else {
            // What libsidplayfp does to a ReSIDfp between creating it and the first cycle:
            // ReSIDfpBuilder::create (the SID and reset(0)), the builder's setters, sidbuilder::lock -> ReSIDfp::model
            // (input, setChipModel), Player::sidParams -> sampling, c64::reset -> c64sid::reset -> reset($0f).
            //
            // sids=N: front ends create engine.info().maxsids() = 3 emulations whatever the tune needs. In reSIDfp
            // every SID that is constructed draws 5 values from its model's shared dither sequence, and
            // Filter8580::setFilterCurve() 2 more per SID. The chip here is the first one created (the one
            // libsidplayfp locks); the draws of the others are made up for with advanceDither.
            func others(_ draws: Int) {
                sid.advanceDither(by: (sids - 1) * draws)
            }
            others(5)
            sid.setFilterEnabled(true)
            if let range { sid.setFilter6581Range(range) }
            if let curve6581 { sid.setFilter6581Curve(curve6581) }
            if let curve8580 {
                sid.setFilter8580Curve(curve8580)
                if model == .mos8580 { others(2) }
            }
            if let cws { sid.setCombinedWaveforms(cws) }
            sid.input(digiboost && model == .mos8580 ? -32768 : 0)
            sid.reset()
            sid.write(0x18, 0x0F)
        }
        let t1 = clock.now
        let c1 = cpuSeconds()

        func seconds(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        }

        if tables {
            sid.withInternalTables { name, bytes, text in
                let padded = name.padding(toLength: 22, withPad: " ", startingAt: 0)
                if let bytes {
                    var h: UInt64 = 1_469_598_103_934_665_603
                    for b in bytes { h ^= UInt64(b); h = h &* 1_099_511_628_211 }
                    print("\(padded) \(String(repeating: " ", count: max(0, 9 - String(bytes.count).count)))\(bytes.count) \(String(format: "%016llx", h))")
                } else {
                    print("\(padded)\(text)")
                }
            }
        }
        if trace.isEmpty {
            if bench {
                print(String(format: "init %.3fs wall %.3fs cpu, shared tables %d bytes, chip %d bytes", seconds(t1 - t0), c1 - c0,
                             ReSIDfpChip.sharedTableBytes(for: model), sid.ownedBytes))
            }
            return
        }

        var lines: [Line] = []
        let text = try String(contentsOfFile: trace, encoding: .utf8)
        for row in text.split(separator: "\n") {
            if row.hasPrefix("#") { continue }
            let fields = row.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let d = parseInt(fields[0]), let r = parseInt(fields[1]), let v = parseInt(fields[2]) else { continue }
            lines.append(Line(delta: d, reg: r, value: v))
        }

        let bufferSize = 16384
        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var pcm = Data()
        var log = ""
        let logging = readback != nil || reads != nil
        var cycles = 0
        var samples = 0

        func hex2(_ v: Int) -> String {
            let s = String(v, radix: 16)
            return s.count < 2 ? "0" + s : s
        }

        func advance(_ n: Int, keep: Bool) {
            var delta = n
            cycles += n
            while delta > 0 {
                let got = sid.clock(&delta, into: buffer, maxSamples: bufferSize)
                if keep {
                    samples += got
                    if out != nil, got > 0 {
                        pcm.append(UnsafeBufferPointer(start: buffer, count: got))
                    }
                }
            }
        }

        if lib, poweron > 0 {
            advance(poweron, keep: false)
            cycles = 0
        }

        let t2 = clock.now
        let c2 = cpuSeconds()
        for _ in 0 ..< repeats {
            for line in lines {
                advance(line.delta, keep: true)
                if line.reg < 32 {
                    sid.write(line.reg, UInt8(truncatingIfNeeded: line.value))
                } else {
                    switch line.reg {
                    case 32: sid.setFilterEnabled(line.value != 0)
                    case 33: sid.input(line.value)
                    case 34: for v in 0 ..< 3 { sid.setVoiceMuted(v, (line.value >> v) & 1 == 0) }
                    case 35:
                        sid.reset()
                        if lib { sid.write(0x18, 0x0F) }
                    case 39:
                        if logging { log += "r\(hex2(line.value))=\(hex2(Int(sid.read(line.value))))\n" }
                    case 40:
                        if lib { advance(line.value, keep: true) } else {
                            sid.clock(line.value)
                            cycles += line.value
                        }
                    case 41:
                        if lib { advance(line.value, keep: true) } else {
                            for _ in 0 ..< line.value {
                                var one = 1
                                _ = sid.clock(&one, into: buffer, maxSamples: bufferSize)
                            }
                            cycles += line.value
                        }
                    case 42: sid.setFilter6581Curve(Double(line.value) / 1000.0)
                    case 43: sid.setFilter6581Range(Double(line.value) / 1000.0)
                    case 44:
                        sid.setFilter8580Curve(Double(line.value) / 1000.0)
                        if lib, model == .mos8580 { sid.advanceDither(by: (sids - 1) * 2) }
                    case 45: sid.setVoiceMuted(line.value & 3, (line.value >> 2) & 1 != 0)
                    case 46: sid.setCombinedWaveforms(line.value == 2 ? .weak : line.value == 3 ? .strong : .average)
                    default: break
                    }
                }
                if readback != nil, line.reg != 39 {
                    let o = sid.read(0x1B), e = sid.read(0x1C)
                    log += "\(hex2(Int(o))) \(hex2(Int(e)))\n"
                }
            }
        }
        let t3 = clock.now
        let c3 = cpuSeconds()

        if let out { try pcm.write(to: URL(fileURLWithPath: out)) }
        if let path = readback ?? reads { try Data(log.utf8).write(to: URL(fileURLWithPath: path)) }

        if bench {
            let render = seconds(t3 - t2)
            print(String(format: "init %.3fs wall %.3fs cpu, render %.3fs wall %.3fs cpu, cycles %d samples %d, speed %.1fx wall %.1fx cpu",
                         seconds(t1 - t0), c1 - c0, render, c3 - c2, cycles, samples, (Double(cycles) / clockHz) / render,
                         (Double(cycles) / clockHz) / (c3 - c2)))
        } else {
            print("cycles \(cycles) samples \(samples)")
        }
    }
}
