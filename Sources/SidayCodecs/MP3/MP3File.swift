// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// The finding of the stream and the gapless rules are derived from minimp3_ex.h, by lieff
// (https://github.com/lieff/minimp3), dedicated to the public domain under CC0.

import SidayFoundation

/// A whole MP3 file (or MP2 or MP1), for playing as a recording: its stream found past its tags, and
/// decoded a frame at a time as minimp3_ex.h's mp3dec_load_buf decodes it, without the encoder's
/// delay at the start and its padding at the end when the file's Xing or Info frame says what they
/// are, so that its samples are those of the sound that was encoded.
public final class MP3File {
    private let file: [UInt8]
    /// Where the frames to decode start, after any ID3v2 tag, junk, and the Xing or Info frame; and
    /// where they end, before any ID3v1 or APE tag.
    private let start: Int, end: Int
    /// Which of MPEG audio's three layers it is in: 3 for an MP3 file, 2 for an MP2 file.
    public let layer: Int
    public let channels: Int
    public let sampleRate: Int
    public let title: String
    public let artist: String
    /// The encoder's delay, and how many samples the file has after the delay and padding are taken
    /// off, as the Xing and LAME tags say (0 if they do not), each counted over all its channels.
    private let delaySamples: Int, taggedSamples: Int64

    private let decoder = MP3Decoder()
    /// A frame's samples as decoded, interleaved, and the frame's samples to give, a channel at a time.
    private let decoded = Memory<Float>(capacity: 1152 * 2), separated = Memory<Float>(capacity: 1152 * 2)
    private var pcm: UnsafeMutablePointer<Float> { decoded.pointer }
    private var channelSamples: UnsafeMutablePointer<Float> { separated.pointer }
    private var position = 0, toSkip = 0, produced: Int64 = 0, finished = false

    /// Skips an ID3v2 tag at the start, and an ID3v1 tag or APE tag at the end (minimp3_ex.h's
    /// rules), and finds the first frame. Throws for a file with no frames.
    public init(_ file: [UInt8]) throws(TuneError) {
        self.file = file
        decoded.pointer.initialize(repeating: 0, count: 1152 * 2)
        separated.pointer.initialize(repeating: 0, count: 1152 * 2)

        let tags = MP3Tags(file)
        title = tags.title
        artist = tags.artist

        // mp3dec_load_buf: mp3dec_skip_id3, then the first frame, and its Xing or Info tag.
        var bufStart = 0, bufSize = file.count
        let id3v2Size = MP3Tags.id3v2Size(file)
        if id3v2Size != 0 {
            let skip = min(id3v2Size, bufSize)
            bufStart += skip
            bufSize -= skip
        }
        MP3Tags.skipID3v1(file, bufStart, &bufSize)

        var found: (channels: Int, hz: Int, layer: Int, delay: Int, tagged: Int64)?
        file.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while bufSize > 0 {
                var freeFormatBytes = 0, frameSize = 0
                let i = MP3Header.findFrame(base + bufStart, bufSize, &freeFormatBytes, &frameSize)
                bufStart += i
                bufSize -= i
                if frameSize == 0 {
                    return
                }
                let hdr = base + bufStart
                let channels = MP3Header.isMono(hdr) ? 1 : 2
                let samples = MP3Header.frameSamples(hdr) * channels
                var frame = (channels: channels, hz: MP3Header.sampleRateHz(hdr), layer: 4 - MP3Header.layer(hdr), delay: 0, tagged: Int64(0))
                if frame.layer == 3 {
                    var frames: UInt32 = 0, delay = 0, padding = 0
                    let ret = MP3File.checkVBRTag(hdr, frameSize, &frames, &delay, &padding)
                    if ret > 0 {
                        padding *= channels
                        frame.delay = delay * channels
                        // (In 64 bits, as the C's uint64_t: a 32-bit count of frames, times their samples.)
                        var detected = Int64(samples) * Int64(frames)
                        if detected >= Int64(frame.delay) {
                            detected -= Int64(frame.delay)
                        }
                        if padding > 0, detected >= Int64(padding) {
                            detected -= Int64(padding)
                        }
                        if detected == 0 {
                            return
                        }
                        frame.tagged = detected
                    }
                    if ret != 0 {
                        bufStart += frameSize
                        bufSize -= frameSize
                    }
                }
                found = frame
                return
            }
        }
        guard let found else {
            throw .unsupported("no MPEG audio frames")
        }
        channels = found.channels
        sampleRate = found.hz
        layer = found.layer
        delaySamples = found.delay
        taggedSamples = found.tagged
        start = bufStart
        end = bufStart + bufSize
        restart()
    }

    /// Length in sample frames after gapless trimming: as many as `next()` gives, from the start to the
    /// end, found by going through every frame's header and side information without decoding, and
    /// no more than the Xing tag's count of frames, less the delay and padding, if it has one
    /// (mp3dec_check_vbrtag).
    public var length: Int? {
        if let measured { return measured }
        let counted = count()
        measured = counted
        return counted
    }

    private var measured: Int?

    /// Goes through the stream as `next()` does, measuring each frame instead of decoding it.
    private func count() -> Int {
        let counter = MP3Decoder()
        var position = start, toSkip = delaySamples, total: Int64 = 0
        file.withUnsafeBufferPointer { buffer in
            while true {
                var info = MP3FrameInfo()
                let samples: Int
                if let base = buffer.baseAddress, position < end {
                    samples = counter.measure(base + position, end - position, &info)
                } else {
                    samples = counter.measure(nil, 0, &info)
                }
                position += info.frameBytes
                if samples != 0 {
                    if info.hz != sampleRate || info.layer != layer || info.channels != channels {
                        break
                    }
                    var count = samples * info.channels
                    if toSkip != 0 {
                        let skip = min(count, toSkip)
                        toSkip -= skip
                        count -= skip
                    }
                    total += Int64(count)
                }
                if info.frameBytes == 0 {
                    break
                }
            }
        }
        if taggedSamples != 0, total > taggedSamples {
            total = taggedSamples
        }
        return Int(clamping: total / Int64(channels))
    }

    /// Decodes the next frame. Skips the Xing/Info frame itself, the encoder delay at the start and the
    /// padding at the end, as minimp3_ex.h's mp3dec_load_buf does. Returns frames of samples (0 at the
    /// end); the stream ends, too, where its sample rate, layer or number of channels changes.
    public func next() -> Int {
        while !finished {
            var info = MP3FrameInfo()
            let samples = file.withUnsafeBufferPointer { buffer -> Int in
                guard let base = buffer.baseAddress, position < end else { return decoder.decode(nil, 0, pcm, &info) }
                return decoder.decode(base + position, end - position, pcm, &info)
            }
            position += info.frameBytes
            if info.frameBytes == 0 {
                finished = true
            }
            guard samples != 0 else { continue }
            if info.hz != sampleRate || info.layer != layer || info.channels != channels {
                finished = true
                return 0
            }
            var count = samples * channels, skip = 0
            if toSkip != 0 {
                skip = min(count, toSkip)
                toSkip -= skip
                count -= skip
            }
            guard count > 0 else { continue }
            if taggedSamples != 0 {
                let left = taggedSamples - produced
                if left <= 0 {
                    finished = true
                    return 0
                }
                count = Int(min(Int64(count), left))
            }
            produced += Int64(count)
            let frames = count / channels
            let from = pcm + skip
            if channels == 1 {
                channelSamples.update(from: from, count: frames)
            } else {
                for i in 0 ..< frames {
                    channelSamples[i] = from[2 * i]
                    channelSamples[1152 + i] = from[2 * i + 1]
                }
            }
            return frames
        }
        return 0
    }

    /// One channel's float samples from the last `next()` (de-interleaved).
    public func samples(of channel: Int) -> UnsafePointer<Float> {
        UnsafePointer(channelSamples + (channel == 1 && channels == 2 ? 1152 : 0))
    }

    /// Back to the start of the sound.
    public func restart() {
        decoder.reset()
        position = start
        toSkip = delaySamples
        produced = 0
        finished = false
    }

    /// mp3dec_check_vbrtag: whether a layer III frame is a Xing or Info frame, which holds no sound but
    /// how many frames the stream has (1), or one that does not say (-1), or neither (0); and the
    /// encoder's delay and padding from a LAME tag after it.
    static func checkVBRTag(_ frame: UnsafePointer<UInt8>, _ frameSize: Int, _ frames: inout UInt32, _ delay: inout Int, _ padding: inout Int) -> Int {
        let framesFlag = 1, bytesFlag = 2, tocFlag = 4, vbrScaleFlag = 8
        if frameSize < MP3Header.size + 8 {
            return 0
        }
        var bs = MP3BitStream(frame + MP3Header.size, bytes: frameSize - MP3Header.size)
        if MP3Header.isCRC(frame) {
            _ = bs.bits(16)
        }
        let grInfo = UnsafeMutablePointer<MP3GranuleInfo>.allocate(capacity: 4)
        grInfo.initialize(repeating: MP3GranuleInfo(sfbtab: MP3TableMemory.shared.scfLong), count: 4)
        defer { grInfo.deallocate() }
        if MP3Decoder.readSideInfo(&bs, grInfo, frame, MP3TableMemory.shared) < 0 {
            return 0 // side info corrupted
        }

        var tagOff = MP3Header.size + bs.pos / 8
        if tagOff > frameSize || frameSize - tagOff < 8 {
            return 0
        }
        var tag = frame + tagOff
        let xing = tag[0] == 0x58 && tag[1] == 0x69 && tag[2] == 0x6E && tag[3] == 0x67
        let info = tag[0] == 0x49 && tag[1] == 0x6E && tag[2] == 0x66 && tag[3] == 0x6F
        if !xing && !info {
            return 0
        }
        let flags = Int(tag[7])
        if flags & framesFlag == 0 {
            return -1
        }
        tagOff += 8
        if frameSize - tagOff < 4 {
            return 0
        }
        tag = frame + tagOff
        frames = UInt32(tag[0]) << 24 | UInt32(tag[1]) << 16 | UInt32(tag[2]) << 8 | UInt32(tag[3])
        tagOff += 4
        if flags & bytesFlag != 0 {
            if frameSize - tagOff < 4 {
                return 0
            }
            tagOff += 4
        }
        if flags & tocFlag != 0 {
            if frameSize - tagOff < 100 {
                return 0
            }
            tagOff += 100
        }
        if flags & vbrScaleFlag != 0 {
            if frameSize - tagOff < 4 {
                return 0
            }
            tagOff += 4
        }
        delay = 0
        padding = 0
        if frameSize - tagOff < 1 {
            return 0
        }
        tag = frame + tagOff
        if tag[0] != 0 {
            // An extension, LAME's, Lavc's and so on, which have the same structure.
            if frameSize - tagOff <= 35 {
                return 0
            }
            tagOff += 21
            tag = frame + tagOff
            delay = ((Int(tag[0]) << 4) | (Int(tag[1]) >> 4)) + (528 + 1)
            padding = (((Int(tag[1]) & 0xF) << 8) | Int(tag[2])) - (528 + 1)
        }
        return 1
    }
}
