// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// siday.wasm <tune> <seconds> <out.f32> [residfp|resid] [plastic|wood]
// SidayKit as an Embedded Swift program for WebAssembly, run through WASI.

@_extern(c, "gettimeofday") private func gettimeofday(_: UnsafeMutableRawPointer, _: UnsafeMutableRawPointer?) -> Int32

private func now() -> Double {
    // Seconds, then microseconds, each in eight bytes.
    let time = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
    defer { time.deallocate() }
    time.initializeMemory(as: UInt8.self, repeating: 0, count: 16)
    _ = gettimeofday(time, nil)
    return Double(time.load(as: Int64.self)) + Double(time.load(fromByteOffset: 8, as: Int64.self)) / 1e6
}

/// The C library's start-up code calls this with the arguments.
@_cdecl("__main_argc_argv")
func wasiMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
    var args: [String] = []
    for index in 0 ..< Int(argc) {
        if let argument = argv[index] { args.append(String(cString: argument)) }
    }
    return render(args, clock: now) ? 0 : 1
}
