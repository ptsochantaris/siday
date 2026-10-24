// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// A WAV file: Microsoft's and IBM's RIFF file of sound, its samples kept as they are, or a little
/// smaller in one of the ways the telephone and the PC's sound cards kept them.
///
/// Its samples are whole numbers of 8 bits (from 0 to 255, 128 the middle), 16, 24 or 32; floating-point
/// numbers of 32 or 64 bits; the telephone's A-law or μ-law, eight bits for each of thirteen or
/// fourteen; or IMA's or Microsoft's ADPCM, four bits for each of sixteen, in blocks that each begin
/// with a sample in full. Its title and artist are the INFO list's INAM and IART, where it has them.
public final class WAVFile: RecordingSource {
    public enum Coding: Equatable, Sendable {
        case integer, float, aLaw, muLaw, imaADPCM, microsoftADPCM
    }

    public let channels: Int
    public let sampleRate: Int
    public let coding: Coding
    /// Bits a sample as they are kept: 4 for ADPCM.
    public let bits: Int
    public let title: String
    public let artist: String
    public var length: Int? { frames }

    private let data: [UInt8]
    /// Where the samples are, and how many bytes of them.
    private let start: Int, size: Int
    private let blockAlign: Int
    /// For ADPCM, how many samples of each channel a block makes.
    private let blockSamples: Int
    /// Microsoft ADPCM's pairs of coefficients, which the file gives.
    private let coefficients: [(Int, Int)]
    private let frames: Int

    /// Where it has read to, in bytes from `start`, and how many samples of each channel it has given.
    private var read = 0, given = 0
    private let made: UnsafeMutablePointer<Float>
    private static let chunk = 4096

    public init(_ data: [UInt8]) throws(TuneError) {
        let file = ByteReader(data)
        guard file.ascii(at: 0, length: 4) == "RIFF", file.ascii(at: 8, length: 4) == "WAVE" else {
            throw .unsupported("not a RIFF WAVE file")
        }
        var format: (tag: Int, channels: Int, rate: Int, align: Int, bits: Int, extra: Int, extraSize: Int)?
        var samples: (start: Int, size: Int)?
        var factFrames: Int?
        var title = "", artist = ""
        var at = 12
        // (Each chunk's name as text, trimmed: "fmt " is "fmt".)
        while at + 8 <= data.count {
            let id = file.ascii(at: at, length: 4), stated = Self.u32(file, at + 4), size = Self.size(stated, data)
            let body = at + 8, end = min(data.count, body + size)
            switch id {
            case "fmt":
                format = (file.u16le(body), file.u16le(body + 2), Int(clamping: Self.u32(file, body + 4)), file.u16le(body + 12),
                          file.u16le(body + 14), body + 18, size >= 18 ? file.u16le(body + 16) : 0)
            case "data":
                // (A file written as it was recorded may give its data no size, or too large a one: its
                // samples then go on to the end of the file.)
                samples = (body, (stated == 0 || stated == 0xFFFF_FFFF ? data.count : end) - body)
            case "fact":
                factFrames = Int(clamping: Self.u32(file, body))
            case "LIST" where file.ascii(at: body, length: 4) == "INFO":
                var item = body + 4
                while item + 8 <= end {
                    let name = file.ascii(at: item, length: 4), length = Self.size(Self.u32(file, item + 4), data)
                    let text = Self.text(Array(data[min(item + 8, end) ..< min(item + 8 + length, end)]))
                    if name == "INAM" { title = text }
                    if name == "IART" { artist = text }
                    item += 8 + length + (length & 1)
                }
            default:
                break
            }
            if samples != nil, format != nil, id == "data", stated == 0 || stated == 0xFFFF_FFFF { break }
            at = body + size + (size & 1)
        }
        guard let format else { throw .malformed("no fmt chunk") }
        guard let samples else { throw .malformed("no data chunk") }
        var tag = format.tag
        // WAVE_FORMAT_EXTENSIBLE says what its samples are in the first two bytes of its sub-format.
        if tag == 0xFFFE, format.extraSize >= 22 { tag = file.u16le(format.extra + 6) }
        channels = format.channels
        sampleRate = format.rate
        bits = format.bits
        blockAlign = max(1, format.align)
        guard channels >= 1, channels <= 8 else { throw .unsupported("a recording of \(channels) channels") }
        var blockSamples = 1
        var coefficients: [(Int, Int)] = []
        switch (tag, bits) {
        case (1, 8), (1, 16), (1, 24), (1, 32): coding = .integer
        case (3, 32), (3, 64): coding = .float
        case (6, 8): coding = .aLaw
        case (7, 8): coding = .muLaw
        case (0x11, 4):
            coding = .imaADPCM
            // Each channel's four bytes of header, then eight samples to every four bytes of each.
            blockSamples = (blockAlign - 4 * channels) * 2 / channels + 1
        case (2, 4):
            coding = .microsoftADPCM
            blockSamples = format.extraSize >= 2 ? file.u16le(format.extra) : (blockAlign - 7 * channels) * 2 / channels + 2
            let count = format.extraSize >= 4 ? file.u16le(format.extra + 2) : 0
            for pair in 0 ..< min(count, (format.extraSize - 4) / 4) {
                coefficients.append((file.s16le(format.extra + 4 + pair * 4), file.s16le(format.extra + 6 + pair * 4)))
            }
            if coefficients.isEmpty { coefficients = Self.standardCoefficients }
        default:
            throw .unsupported("WAV samples of format \(tag), \(bits) bits")
        }
        if coding == .imaADPCM || coding == .microsoftADPCM {
            let header = coding == .imaADPCM ? 4 : 7
            guard blockAlign > header * channels, blockSamples >= 2 else { throw .malformed("ADPCM blocks of \(blockAlign) bytes") }
        } else {
            guard blockAlign == channels * bits / 8 else { throw .malformed("blocks of \(blockAlign) bytes for \(channels) × \(bits) bits") }
        }
        self.blockSamples = blockSamples
        self.coefficients = coefficients
        self.data = data
        start = samples.start
        size = max(0, samples.size)
        var frames = size / blockAlign * blockSamples
        if blockSamples > 1 {
            // A last block cut short holds as many samples as it has bytes for; the fact chunk says how
            // many of all of them are the recording's.
            let rest = size % blockAlign
            let header = (coding == .imaADPCM ? 4 : 7) * channels
            if rest > header { frames += (rest - header) * 2 / channels + (coding == .imaADPCM ? 1 : 2) }
            if let factFrames, factFrames > 0 { frames = min(frames, factFrames) }
        }
        self.frames = frames
        self.title = title
        self.artist = artist
        made = .allocate(capacity: max(Self.chunk, blockSamples) * channels)
        guard frames > 0 else { throw .malformed("no samples") }
    }

    deinit {
        made.deallocate()
    }

    /// What WAV's sub-formats are called, for a line about the file.
    public var detail: String {
        let kind = switch coding {
        case .integer: "\(bits)-bit"
        case .float: "\(bits)-bit floating point"
        case .aLaw: "A-law"
        case .muLaw: "μ-law"
        case .imaADPCM: "IMA ADPCM"
        case .microsoftADPCM: "Microsoft ADPCM"
        }
        return kind
    }

    public func restart() {
        read = 0
        given = 0
    }

    public func samples(of channel: Int) -> UnsafePointer<Float> {
        UnsafePointer(made + channel * max(Self.chunk, blockSamples))
    }

    public func next() -> Int {
        guard given < frames else { return 0 }
        let row = max(Self.chunk, blockSamples)
        var count = 0
        switch coding {
        case .imaADPCM, .microsoftADPCM:
            // A block at a time.
            let bytes = min(blockAlign, size - read)
            guard bytes > 0 else { return 0 }
            count = coding == .imaADPCM ? imaBlock(start + read, bytes, row) : microsoftBlock(start + read, bytes, row)
            read += blockAlign
        default:
            let width = bits / 8
            count = min(Self.chunk, (size - read) / blockAlign)
            data.withUnsafeBufferPointer { bytes in
                let from = bytes.baseAddress! + start + read
                for frame in 0 ..< count {
                    for channel in 0 ..< channels {
                        let at = from + frame * blockAlign + channel * width
                        made[channel * row + frame] = sample(at)
                    }
                }
            }
            read += count * blockAlign
        }
        count = min(count, frames - given)
        given += count
        return max(0, count)
    }

    @inline(__always) private func sample(_ at: UnsafePointer<UInt8>) -> Float {
        switch (coding, bits) {
        case (.integer, 8): return Float(Int(at[0]) - 128) / 128
        case (.integer, 16): return Float(Int16(bitPattern: UInt16(at[0]) | UInt16(at[1]) << 8)) / 32768
        case (.integer, 24):
            let value = Int32(bitPattern: UInt32(at[0]) << 8 | UInt32(at[1]) << 16 | UInt32(at[2]) << 24) >> 8
            return Float(value) / 8_388_608
        case (.integer, _): return Float(Int32(bitPattern: Self.u32(at))) / 2_147_483_648
        case (.float, 32): return Float(bitPattern: Self.u32(at))
        case (.float, _): return Float(Double(bitPattern: UInt64(Self.u32(at)) | UInt64(Self.u32(at + 4)) << 32))
        case (.aLaw, _): return Float(Self.aLaw(at[0])) / 32768
        default: return Float(Self.muLaw(at[0])) / 32768
        }
    }

    /// A count or size of four bytes, as it is: an `Int` is only 32 bits in the web player.
    private static func u32(_ file: ByteReader, _ at: Int) -> UInt32 {
        UInt32(file[at]) | UInt32(file[at + 1]) << 8 | UInt32(file[at + 2]) << 16 | UInt32(file[at + 3]) << 24
    }

    /// The same as an `Int`, no larger than the file: as many as there could be of anything in it.
    private static func size(_ stated: UInt32, _ data: [UInt8]) -> Int {
        Int(min(stated, UInt32(clamping: data.count)))
    }

    @inline(__always) private static func u32(_ at: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(at[0]) | UInt32(at[1]) << 8 | UInt32(at[2]) << 16 | UInt32(at[3]) << 24
    }

    /// G.711's A-law, to sixteen bits.
    static func aLaw(_ byte: UInt8) -> Int {
        let a = Int(byte ^ 0x55)
        let exponent = (a >> 4) & 7, mantissa = a & 15
        var value = exponent == 0 ? mantissa << 4 | 8 : (mantissa << 4 | 0x108) << (exponent - 1)
        if a & 0x80 == 0 { value = -value }
        return value
    }

    /// G.711's μ-law, to sixteen bits.
    static func muLaw(_ byte: UInt8) -> Int {
        let u = Int(~byte)
        let exponent = (u >> 4) & 7, mantissa = u & 15
        let value = ((mantissa << 3) + 0x84) << exponent - 0x84
        return u & 0x80 != 0 ? -value : value
    }

    // MARK: ADPCM

    private static let imaSteps: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428,
        4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350,
        22385, 24623, 27086, 29794, 32767,
    ]
    private static let imaMoves: [Int] = [-1, -1, -1, -1, 2, 4, 6, 8]

    /// One block of IMA ADPCM: each channel's first sample and step, then each channel's next eight
    /// samples from four bytes, low nibble first, the channels in turn. (As Microsoft's and IMA's
    /// reference decoders work out each difference: a part of the step for each bit, each rounded down.)
    private func imaBlock(_ at: Int, _ bytes: Int, _ row: Int) -> Int {
        let file = ByteReader(data)
        let end = at + bytes
        var predicted = [Int](repeating: 0, count: channels), index = predicted
        for channel in 0 ..< channels {
            predicted[channel] = file.s16le(at + channel * 4)
            index[channel] = min(88, max(0, Int(file[at + channel * 4 + 2])))
            made[channel * row] = Float(predicted[channel]) / 32768
        }
        var count = 1
        var group = at + 4 * channels
        while group + 4 * channels <= end, count + 8 <= blockSamples {
            for channel in 0 ..< channels {
                for k in 0 ..< 8 {
                    let byte = Int(data[group + channel * 4 + k / 2])
                    let nibble = k & 1 == 0 ? byte & 15 : byte >> 4
                    let step = Self.imaSteps[index[channel]]
                    var difference = step >> 3
                    if nibble & 4 != 0 { difference += step }
                    if nibble & 2 != 0 { difference += step >> 1 }
                    if nibble & 1 != 0 { difference += step >> 2 }
                    predicted[channel] = min(32767, max(-32768, predicted[channel] + (nibble & 8 != 0 ? -difference : difference)))
                    index[channel] = min(88, max(0, index[channel] + Self.imaMoves[nibble & 7]))
                    made[channel * row + count + k] = Float(predicted[channel]) / 32768
                }
            }
            count += 8
            group += 4 * channels
        }
        return count
    }

    private static let standardCoefficients: [(Int, Int)] = [(256, 0), (512, -256), (0, 0), (192, 64), (240, 0), (460, -208), (392, -232)]
    private static let microsoftMoves: [Int] = [230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230]

    /// One block of Microsoft ADPCM: each channel's choice of coefficients, step, and two samples to begin
    /// from (the earlier second), then a nibble for each sample, high first, the channels in turn.
    private func microsoftBlock(_ at: Int, _ bytes: Int, _ row: Int) -> Int {
        let file = ByteReader(data)
        let end = at + bytes
        var first = [Int](repeating: 0, count: channels), second = first, delta = first
        var one = first, two = first
        for channel in 0 ..< channels {
            let pair = coefficients[min(coefficients.count - 1, Int(file[at + channel]))]
            one[channel] = pair.0
            two[channel] = pair.1
            delta[channel] = file.s16le(at + channels + channel * 2)
            first[channel] = file.s16le(at + channels * 3 + channel * 2)
            second[channel] = file.s16le(at + channels * 5 + channel * 2)
            made[channel * row] = Float(second[channel]) / 32768
            made[channel * row + 1] = Float(first[channel]) / 32768
        }
        var count = 2
        var nibbleAt = (at + channels * 7) * 2
        while nibbleAt / 2 < end, count < blockSamples {
            for channel in 0 ..< channels where nibbleAt / 2 < end {
                let byte = Int(data[nibbleAt / 2])
                let nibble = nibbleAt & 1 == 0 ? byte >> 4 : byte & 15
                nibbleAt += 1
                let signed = nibble >= 8 ? nibble - 16 : nibble
                let predicted = (first[channel] * one[channel] + second[channel] * two[channel]) / 256
                let value = min(32767, max(-32768, predicted + signed * delta[channel]))
                second[channel] = first[channel]
                first[channel] = value
                delta[channel] = max(16, (Self.microsoftMoves[nibble] * delta[channel]) >> 8)
                made[channel * row + count] = Float(value) / 32768
            }
            count += 1
        }
        return count
    }

    /// A tag's text: UTF-8 where it is that, else Windows-1252, as the files written on Windows are.
    private static func text(_ bytes: [UInt8]) -> String {
        let bytes = Array(bytes.prefix { $0 != 0 })
        let utf8 = String(decoding: bytes, as: UTF8.self)
        if !utf8.unicodeScalars.contains("\u{FFFD}") { return utf8.trimmed() }
        return TextEncoding.windows1252.decode(bytes[...])?.trimmed() ?? utf8.trimmed()
    }
}
