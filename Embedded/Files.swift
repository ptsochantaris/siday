// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Reading and writing whole files through the C library, for the two render programs. SidayKit itself
// touches no files, and Embedded Swift has no Foundation to do it with.

@_extern(c, "fopen") private func fopen(_: UnsafePointer<CChar>, _: UnsafePointer<CChar>) -> OpaquePointer?
@_extern(c, "fread") private func fread(_: UnsafeMutableRawPointer?, _: Int, _: Int, _: OpaquePointer) -> Int
@_extern(c, "fwrite") private func fwrite(_: UnsafeRawPointer?, _: Int, _: Int, _: OpaquePointer) -> Int
@_extern(c, "fclose") @discardableResult private func fclose(_: OpaquePointer) -> Int32

func readFile(_ path: String) -> [UInt8]? {
    guard let file = path.withCString({ name in "rb".withCString { fopen(name, $0) } }) else { return nil }
    defer { fclose(file) }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = chunk.withUnsafeMutableBytes { fread($0.baseAddress, 1, $0.count, file) }
        if count <= 0 { break }
        bytes.append(contentsOf: chunk[0 ..< count])
    }
    return bytes
}

func writeFile(_ path: String, _ bytes: UnsafeRawBufferPointer) -> Bool {
    guard let file = path.withCString({ name in "wb".withCString { fopen(name, $0) } }) else { return false }
    defer { fclose(file) }
    return fwrite(bytes.baseAddress, 1, bytes.count, file) == bytes.count
}

/// What follows the last dot of a file's name.
func fileExtension(_ path: String) -> String {
    let name = path.split(separator: "/").last ?? ""
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
    return String(name[name.index(after: dot)...])
}

/// Renders the first `seconds` of a tune to raw interleaved stereo Float32 and says how it went.
/// `clock` gives the time in seconds. Returns false if the tune could not be loaded.
func render(_ args: [String], clock: () -> Double) -> Bool {
    guard args.count >= 4, let seconds = Int(args[2]) else {
        print("usage: <tune> <seconds> <out.f32> [residfp|resid] [plastic|wood]")
        return false
    }
    var options = LoadOptions()
    options.findsMissingLengths = false
    if args.count > 4, args[4] == "resid" { options.sidEngine = .resid }
    var television = args.count > 5 ? TelevisionSet(rawValue: args[5]).map { Television($0) } : nil
    let loadStart = clock()
    guard let bytes = readFile(args[1]), let format = TuneFormat(fileExtension: fileExtension(args[1])),
          let renderer = try? TuneLoader.load(bytes, format: format, path: args[1], options: options)
    else {
        print("cannot load \(args[1])")
        return false
    }
    let frames = seconds * outputSampleRate
    let block = 1024
    let out = UnsafeMutablePointer<Float>.allocate(capacity: (frames + block) * 2)
    defer { out.deallocate() }
    let start = clock()
    var done = 0
    while done < frames {
        renderer.render(into: out + done * 2, frames: block)
        television?.process(out + done * 2, frames: block)
        done += block
    }
    let taken = clock() - start
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    let samples = UnsafeRawBufferPointer(start: out, count: done * 2 * 4)
    for byte in samples { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
    _ = writeFile(args[3], samples)
    print("\(renderer.info.format)  \(renderer.info.title)  \(Int(Double(seconds) / taken))x real time  load \(Int((start - loadStart) * 1000)) ms  hash \(hash)")
    return true
}
