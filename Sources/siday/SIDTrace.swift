// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import Foundation

/// Renders a SID register-write trace through SIDChip, for comparison with the C++ reSID reference
/// harness (sidref.cc). Reached through the hidden `--sid-trace` option.
///
/// Trace lines: `<cycle_delta> <register> <value>` (decimal, or hex with 0x). Lines starting with # are ignored.
///   register 0x00...0x1f  write(register, value)
///   32  setFilterEnabled(value != 0)
///   33  input(value)                 (signed 16-bit EXT IN sample)
///   34  setVoiceMask(value)
///   35  reset()
///   36  setExternalFilterEnabled(value != 0)
///   37  adjustFilterBias(value / 1000.0)
///   38  no-op (only advances time; read-backs still happen in readback mode)
///   39  explicit read(value), printed to the readback / reads file
///   40  clock(value) with reSID's delta clocking (no output), in addition to cycle_delta
///   41  clock() value times: single-cycle clocking with no output, in addition to cycle_delta
///
/// Options, comma separated: model=6581|8580, clock=<Hz>, rate=<Hz>, sampling=fast|interpolate|resample|fastmem,
/// out=<raw 16-bit mono file>, readback=<file> (OSC3 and ENV3 after every line), reads=<file> (explicit reads only),
/// tables (print a digest of every internal table), bench, repeat=<n>.
/// With an empty trace path only the tables are printed.
enum SIDTrace {
    struct Line {
        var delta: Int
        var reg: Int
        var value: Int
    }

    static func parseInt(_ text: Substring) -> Int? {
        var t = text
        var negative = false
        if t.hasPrefix("-") { negative = true; t = t.dropFirst() }
        let value: Int? = if t.hasPrefix("0x") || t.hasPrefix("0X") { Int(t.dropFirst(2), radix: 16) } else { Int(t) }
        return value.map { negative ? -$0 : $0 }
    }

    static func run(trace: String, options: String) throws {
        if options.split(separator: ",").contains("engine=residfp") {
            try runReSIDfp(trace: trace, options: options)
            return
        }
        var model = SIDModel.mos6581
        var clockHz = 985_248.0
        var rate = 48000.0
        var sampling = SIDSampling.resample
        var out: String?
        var readback: String?
        var reads: String?
        var tables = false
        var bench = false
        var repeats = 1

        for option in options.split(separator: ",") {
            let parts = option.split(separator: "=", maxSplits: 1)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            switch key {
            case "model": model = value == "8580" ? .mos8580 : .mos6581
            case "clock": clockHz = Double(value) ?? clockHz
            case "rate": rate = Double(value) ?? rate
            case "sampling":
                switch value {
                case "fast": sampling = .fast
                case "interpolate": sampling = .interpolate
                case "resample": sampling = .resample
                case "fastmem": sampling = .resampleFastMem
                default: throw TuneError.unsupported("sampling \(value)")
                }
            case "out": out = value
            case "readback": readback = value
            case "reads": reads = value
            case "tables": tables = true
            case "bench": bench = true
            case "repeat": repeats = Int(value) ?? 1
            default: throw TuneError.unsupported("sid-trace option \(key)")
            }
        }

        let clock = ContinuousClock()
        let t0 = clock.now
        var sid = SIDChip(model: model, clockHz: clockHz, sampleRate: rate, sampling: sampling)
        defer { sid.deallocate() }
        let t1 = clock.now

        if tables {
            sid.withInternalTables { name, bytes in
                var h: UInt64 = 1_469_598_103_934_665_603
                for b in bytes { h ^= UInt64(b); h = h &* 1_099_511_628_211 }
                let padded = name.padding(toLength: 22, withPad: " ", startingAt: 0)
                print("\(padded) \(String(repeating: " ", count: max(0, 9 - String(bytes.count).count)))\(bytes.count) \(String(format: "%016llx", h))")
            }
        }
        if trace.isEmpty { return }

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

        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) * 1e-6
        }
        let t2 = clock.now
        let c2 = cpuSeconds()
        for _ in 0 ..< repeats {
            for line in lines {
                var delta = line.delta
                cycles += delta
                while delta > 0 {
                    let n = sid.clock(&delta, into: buffer, maxSamples: bufferSize)
                    samples += n
                    if out != nil, n > 0 {
                        pcm.append(UnsafeBufferPointer(start: buffer, count: n))
                    }
                }
                if line.reg < 32 {
                    sid.write(line.reg, UInt8(truncatingIfNeeded: line.value))
                } else {
                    switch line.reg {
                    case 32: sid.setFilterEnabled(line.value != 0)
                    case 33: sid.input(line.value)
                    case 34: sid.setVoiceMask(line.value)
                    case 35: sid.reset()
                    case 36: sid.setExternalFilterEnabled(line.value != 0)
                    case 37: sid.adjustFilterBias(Double(line.value) / 1000.0)
                    case 39:
                        if logging { log += "r\(hex2(line.value))=\(hex2(Int(sid.read(line.value))))\n" }
                    case 40:
                        sid.clock(line.value)
                        cycles += line.value
                    case 41:
                        for _ in 0 ..< line.value { sid.clock() }
                        cycles += line.value
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

        func seconds(_ d: Duration) -> Double {
            Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        }
        if bench {
            let render = seconds(t3 - t2)
            print(String(format: "init %.3fs render %.3fs wall %.3fs cpu, cycles %d samples %d, speed %.1fx wall %.1fx cpu",
                         seconds(t1 - t0), render, c3 - c2, cycles, samples, (Double(cycles) / clockHz) / render,
                         (Double(cycles) / clockHz) / (c3 - c2)))
        } else {
            print("cycles \(cycles) samples \(samples)")
        }
    }
}
