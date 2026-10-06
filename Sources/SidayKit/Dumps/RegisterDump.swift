// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

/// VTX (Vortex) and YM (ST-Sound) files: a recording of the AY/YM registers, one set per interrupt.
/// Atari-only YM5/YM6 effects (digidrums, SID voice, sync buzzer) are not reproduced.
public final class RegisterDumpSource: AYFrameSource {
    public private(set) var info: TuneInfo
    public let fileClockHz: Double?
    public let fileFrameHz: Double?
    public let fileChipType: AYChipType?
    public private(set) var loopCount = 0

    private let data: [UInt8]
    /// Offset of register 0's first frame.
    private let base: Int
    private let frames: Int
    /// Interleaved: all frames of register 0, then all of register 1, and so on.
    private let interleaved: Bool
    private let registersPerFrame: Int
    private let loopFrame: Int
    private var position = 0

    private init(info: TuneInfo, data: [UInt8], base: Int, frames: Int, interleaved: Bool, registersPerFrame: Int,
                 loopFrame: Int, clock: Double?, frameHz: Double?, chip: AYChipType?) {
        self.info = info
        self.data = data
        self.base = base
        self.frames = frames
        self.interleaved = interleaved
        self.registersPerFrame = registersPerFrame
        self.loopFrame = loopFrame >= 0 && loopFrame < frames ? loopFrame : 0
        if let clock, let frameHz {
            let chipName = chip == .ym ? "YM" : "AY"
            let summary = "\(chipName) \(significant(clock / 1_000_000, digits: 4)) MHz, \(significant(frameHz)) Hz"
            self.info.detail = self.info.detail.isEmpty ? summary : "\(summary), \(self.info.detail)"
        }
        fileClockHz = clock
        fileFrameHz = frameHz
        fileChipType = chip
    }

    public static func vtx(_ file: [UInt8]) throws -> RegisterDumpSource {
        let r = ByteReader(file)
        let rawID = r.ascii(at: 0, length: 2)
        let id = rawID.lowercased()
        guard id == "ay" || id == "ym" else { throw TuneError.malformed("not a VTX file") }
        // The original VTX layout (upper-case id) has no year and only title and author.
        let old = rawID != id
        let loop = r.u16le(3)
        let clock = r.u32le(5)
        let rate = Int(r[9])
        let year = old ? 0 : r.u16le(10)
        let unpackedSize = r.u32le(old ? 10 : 12)
        var at = old ? 14 : 16
        var strings: [String] = []
        for _ in 0 ..< (old ? 2 : 5) {
            let (s, next) = r.cString(at: at, encoding: .windows1251)
            strings.append(s)
            at = next
        }
        while strings.count < 5 { strings.append("") }
        guard unpackedSize >= 14, let raw = LH5.decode(r.data, offset: at, originalSize: unpackedSize) else {
            throw TuneError.malformed("VTX data does not unpack")
        }
        var info = TuneInfo(format: "VTX")
        info.title = strings[0]
        info.author = strings[1]
        info.comment = strings[4]
        info.detail = [strings[2], strings[3], year > 0 ? String(year) : ""].filter { !$0.isEmpty }.joined(separator: ", ")
        return RegisterDumpSource(info: info, data: raw, base: 0, frames: unpackedSize / 14, interleaved: true, registersPerFrame: 14,
                                  loopFrame: loop, clock: clock > 0 ? Double(clock) : nil, frameHz: rate > 0 ? Double(rate) : nil,
                                  chip: id == "ym" ? .ym : .ay)
    }

    public static func ym(_ file: [UInt8]) throws -> RegisterDumpSource {
        var bytes = [UInt8](file)
        if let unpacked = LH5.unwrapArchive(bytes) { bytes = unpacked }
        let r = ByteReader(bytes)
        let id = r.ascii(at: 0, length: 4)
        // ST-Sound's defaults: an Atari ST YM2149 at 2 MHz, 50 Hz.
        switch id {
        case "YM2!", "YM3!", "YM3b":
            let trailer = id == "YM3b" ? 4 : 0
            let frames = (bytes.count - 4 - trailer) / 14
            guard frames > 0 else { throw TuneError.malformed("empty YM file") }
            let loop = id == "YM3b" ? r.u32be(bytes.count - 4) : 0
            return RegisterDumpSource(info: TuneInfo(format: String(id.prefix(3))), data: bytes, base: 4, frames: frames, interleaved: true,
                                      registersPerFrame: 14, loopFrame: loop, clock: 2_000_000, frameHz: 50, chip: .ym)
        case "YM5!", "YM6!":
            guard r.ascii(at: 4, length: 8) == "LeOnArD!" else { throw TuneError.malformed("bad YM header") }
            let frames = r.u32be(12)
            let attributes = r.u32be(16)
            let drums = r.u16be(20)
            let clock = r.u32be(22)
            let rate = r.u16be(26)
            let loop = r.u32be(28)
            var at = 34 + r.u16be(32)
            for _ in 0 ..< drums {
                at += 4 + r.u32be(at)
                if at > bytes.count { throw TuneError.malformed("bad YM digidrum table") }
            }
            var info = TuneInfo(format: String(id.prefix(3)))
            (info.title, at) = r.cString(at: at)
            (info.author, at) = r.cString(at: at)
            (info.comment, at) = r.cString(at: at)
            guard frames > 0, at + frames * 16 <= bytes.count + 4 else { throw TuneError.malformed("truncated YM data") }
            return RegisterDumpSource(info: info, data: bytes, base: at, frames: frames, interleaved: attributes & 1 != 0, registersPerFrame: 16,
                                      loopFrame: loop, clock: clock > 0 ? Double(clock) : 2_000_000, frameHz: rate > 0 ? Double(rate) : 50, chip: .ym)
        default:
            throw TuneError.unsupported("YM variant \(id)")
        }
    }

    public func restart() {
        position = 0
        loopCount = 0
    }

    @inline(__always) private func register(_ n: Int) -> Int {
        let i = interleaved ? base + n * frames + position : base + position * registersPerFrame + n
        return i < data.count ? Int(data[i]) : 0
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        if position >= frames {
            position = loopFrame
            loopCount += 1
        }
        regs[0].tonA = register(0) | (register(1) & 15) << 8
        regs[0].tonB = register(2) | (register(3) & 15) << 8
        regs[0].tonC = register(4) | (register(5) & 15) << 8
        regs[0].noise = register(6) & 31
        regs[0].mixer = register(7) & 63
        regs[0].amplA = register(8) & 31
        regs[0].amplB = register(9) & 31
        regs[0].amplC = register(10) & 31
        regs[0].envelope = register(11) | register(12) << 8
        let shape = register(13)
        if shape != 255 { regs[0].setEnvelopeRegister(shape) }
        position += 1
    }
}
