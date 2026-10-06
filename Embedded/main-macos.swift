// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// sidayemb <tune> <seconds> <out.f32> [residfp|resid] [plastic|wood]
// SidayKit as an Embedded Swift program for macOS.

@_extern(c, "clock_gettime_nsec_np") private func clock_gettime_nsec_np(_: UInt32) -> UInt64
@_extern(c, "_NSGetArgc") private func _NSGetArgc() -> UnsafeMutablePointer<Int32>
@_extern(c, "_NSGetArgv") private func _NSGetArgv() -> UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>>

@main struct Main {
    static func main() {
        // Embedded Swift has no CommandLine.
        var args: [String] = []
        let argv = _NSGetArgv().pointee
        for index in 0 ..< Int(_NSGetArgc().pointee) {
            if let argument = argv[index] { args.append(String(cString: argument)) }
        }
        // 4 is CLOCK_UPTIME_RAW.
        _ = render(args) { Double(clock_gettime_nsec_np(4)) / 1e9 }
    }
}
