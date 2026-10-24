// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// What stb_vorbis says went wrong (enum STBVorbisError), by its numbers.
public enum VorbisError: Int32, Sendable {
    /// Not an error: the bytes given end before the next packet or header does.
    case needMoreData = 1
    case invalidApiMixing = 2
    /// The stream asks for more memory than it may have.
    case outOfMemory = 3
    /// Floor type 0, of the earliest encoders.
    case featureNotSupported = 4
    /// More than sixteen channels.
    case tooManyChannels = 5
    case fileOpenFailure = 6
    case seekWithoutLength = 7
    case unexpectedEOF = 10
    case seekInvalid = 11
    case invalidSetup = 20
    case invalidStream = 21
    case missingCapturePattern = 30
    case invalidStreamStructureVersion = 31
    case continuedPacketFlagInvalid = 32
    case incorrectStreamSerialNumber = 33
    case invalidFirstPage = 34
    case badPacketType = 35
    case cantFindLastPage = 36
    case seekFailed = 37
    case oggSkeletonNotSupported = 38
}

/// stb_vorbis's push-data decoder: it keeps no bytes of its own, it is given them each time.
///
/// It is fed as libopenmpt feeds it: all the bytes that are left on each call, from where the last
/// call stopped taking them.
public final class VorbisDecoder {
    private let stb: StbVorbis
    /// The error of the last call, taken (and so cleared) from the decoder after it, as
    /// stb_vorbis_get_error takes it.
    public private(set) var error: VorbisError?

    /// stb_vorbis_open_pushdata: reads the three header packets from `bytes` starting at `start`.
    /// `consumed` is how many bytes it took. Throws for bytes that are not a Vorbis stream's headers,
    /// or that end before the headers do (the error says which).
    public init(_ bytes: [UInt8], at start: Int, consumed: inout Int) throws(TuneError) {
        stb = StbVorbis()
        let f = stb.f
        let used: Int32? = bytes.withUnsafeBufferPointer { buffer in
            let from = min(max(start, 0), buffer.count)
            let base = buffer.baseAddress.map { UnsafePointer($0) + from } ?? f.pointee.data
            return f.pointee.openPushdata(base, Int32(clamping: buffer.count - from))
        }
        guard let used else {
            let e = VorbisError(rawValue: f.pointee.error)
            throw .malformed((e == .needMoreData ? "Ogg Vorbis: the headers are cut short"
                    : "Ogg Vorbis: not a stream's headers") + " (stb_vorbis error \(f.pointee.error))")
        }
        consumed = Int(used)
    }

    public var channels: Int { Int(stb.f.pointee.channels) }
    public var sampleRate: Int { Int(clamping: stb.f.pointee.sampleRate) }

    /// The user comments, "TITLE=..." and so on, as the file has them (UTF-8; not the vendor string).
    public var comments: [String] { stb.f.pointee.comments.map { String(decoding: $0, as: UTF8.self) } }

    /// stb_vorbis_decode_frame_pushdata on `bytes` from `start` to the end: how many bytes it took, and how
    /// many sample frames it decoded (each may be 0). The frames are in `samples(of:)` until the next call.
    public func decodeFrame(_ bytes: [UInt8], at start: Int) -> (consumed: Int, frames: Int) {
        decodeFrame(bytes, from: start, to: bytes.count)
    }

    /// The same, on the bytes from `start` up to `end` only.
    public func decodeFrame(_ bytes: [UInt8], from start: Int, to end: Int) -> (consumed: Int, frames: Int) {
        let f = stb.f
        var samples: Int32 = 0
        let used: Int32 = bytes.withUnsafeBufferPointer { buffer in
            let to = min(max(end, 0), buffer.count)
            let from = min(max(start, 0), to)
            let base = buffer.baseAddress.map { UnsafePointer($0) + from } ?? f.pointee.data
            return f.pointee.decodeFramePushdata(base, Int32(clamping: to - from), &samples)
        }
        let e = f.pointee.error
        f.pointee.error = StbVorbisError.noError
        error = e == StbVorbisError.noError ? nil : VorbisError(rawValue: e) ?? .invalidStream
        // The original can give a negative count, for a last page whose sample number is far behind
        // where the decoder has got to: that is no samples.
        return (Int(used), max(0, Int(samples)))
    }

    /// One channel's samples from the last decodeFrame, about -1...1, as stb_vorbis gives them.
    /// Before the first frame, the channel's buffer, which is silent; a channel the stream does not
    /// have is given as its last.
    public func samples(of channel: Int) -> UnsafePointer<Float> {
        let f = stb.f
        let c = min(max(channel, 0), Int(f.pointee.channels) - 1)
        return UnsafePointer((f.pointee.outputs[c] ?? f.pointee.channelBuffers[c])!)
    }

    /// stb_vorbis_flush_pushdata: the next bytes given do not follow on from the last; the decoder looks
    /// for the next page whose CRC is right, and goes on from the frame after it.
    public func flush() {
        stb.f.pointee.flushPushdata()
    }
}
