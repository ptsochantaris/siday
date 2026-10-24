// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// A whole Ogg Vorbis file, for playing as a recording: stb_vorbis's decoder fed the file, page by page
/// as it asks, with what the push-data API leaves to its caller done here.
///
/// A file of several streams one after the other (a chained file) is played through, for as long as
/// each has the channels and the rate of the first. Each stream is cut to the length its last page
/// gives, as the Vorbis specification says (A.2: the end-of-stream granule position); stb_vorbis
/// cuts its last frame to about that itself, and this makes it exact. Past a damaged page it goes on, as
/// stb_vorbis finds its place again at the next whole page (libopenmpt, decoding a sample, stops there).
public final class VorbisFile {
    private let file: [UInt8]
    /// Each stream of the file: where its pages start and end, and the granule position of its last.
    private let links: [(start: Int, end: Int, granule: Int64?)]
    private var decoder: VorbisDecoder
    private var link = 0
    private var position = 0
    /// How many frames of the stream being played have been given.
    private var given: Int64 = 0
    private var finished = false

    public let channels: Int
    public let sampleRate: Int
    /// From TITLE=, else "".
    public let title: String
    /// From ARTIST=, else "".
    public let artist: String
    /// The stream's length in sample frames: the last page's granule position (for a chained file, the
    /// sum of the streams that are played), or nil if it cannot be found.
    public let length: Int?

    public init(_ file: [UInt8]) throws(TuneError) {
        self.file = file
        let links = VorbisFile.findLinks(file)
        self.links = links
        guard let first = links.first else { throw .malformed("Ogg Vorbis: no Ogg page") }
        var consumed = 0
        decoder = try VorbisDecoder(file, at: first.start, consumed: &consumed)
        position = first.start + consumed
        channels = decoder.channels
        sampleRate = decoder.sampleRate
        var title = "", artist = ""
        for comment in decoder.comments {
            if title.isEmpty, let value = VorbisFile.field("TITLE", comment) { title = value }
            if artist.isEmpty, let value = VorbisFile.field("ARTIST", comment) { artist = value }
        }
        self.title = title
        self.artist = artist

        // The streams after the first are counted while they have its channels and rate.
        var total: Int64? = 0
        for (index, l) in links.enumerated() {
            if index > 0 {
                var c = 0
                guard let d = try? VorbisDecoder(file, at: l.start, consumed: &c),
                      d.channels == channels, d.sampleRate == sampleRate else { break }
            }
            if let g = l.granule, g >= 0, let t = total { total = t + g } else { total = nil }
        }
        length = total.flatMap { Int(exactly: $0) }
    }

    /// The value of a comment if its field is `name` (the names of fields are not cased).
    private static func field(_ name: String, _ comment: String) -> String? {
        let key = Array(name.utf8)
        let bytes = Array(comment.utf8)
        guard bytes.count > key.count, bytes[key.count] == UInt8(ascii: "=") else { return nil }
        for i in 0 ..< key.count {
            var b = bytes[i]
            if b >= 0x61 && b <= 0x7A { b -= 0x20 }
            if b != key[i] { return nil }
        }
        return String(decoding: bytes[(key.count + 1)...], as: UTF8.self)
    }

    /// The streams of the file, from its pages: each starts with a page that begins a stream (a file of
    /// streams side by side, which Vorbis files are not, is not told apart), and its length is the
    /// granule position of its last whole page of the stream that has one.
    private static func findLinks(_ d: [UInt8]) -> [(start: Int, end: Int, granule: Int64?)] {
        var links: [(start: Int, end: Int, granule: Int64?)] = []
        var serial: UInt32 = 0
        var i = 0
        let n = d.count
        while i + 27 <= n {
            if !(d[i] == 0x4F && d[i + 1] == 0x67 && d[i + 2] == 0x67 && d[i + 3] == 0x53) {
                i += 1
                continue
            }
            let segments = Int(d[i + 26])
            if i + 27 + segments > n { break }
            var length = 27 + segments
            for s in 0 ..< segments { length += Int(d[i + 27 + s]) }
            let flags = d[i + 5]
            var granule: UInt64 = 0
            for k in 0 ..< 8 { granule |= UInt64(d[i + 6 + k]) << UInt64(8 * k) }
            var pageSerial: UInt32 = 0
            for k in 0 ..< 4 { pageSerial |= UInt32(d[i + 14 + k]) << UInt32(8 * k) }
            if links.isEmpty || flags & 2 != 0 {
                if !links.isEmpty { links[links.count - 1].end = i }
                links.append((start: i, end: n, granule: nil))
                serial = pageSerial
            }
            if pageSerial == serial && granule != ~0 && i + length <= n {
                links[links.count - 1].granule = Int64(bitPattern: granule)
            }
            i += length
        }
        return links
    }

    /// Decodes on to the next frame that has samples; returns how many (0 at the end of the stream, or at an error
    /// it cannot go past). The last packet is cut to `length`, as the Vorbis spec says.
    public func next() -> Int {
        while !finished {
            let l = links[link]
            let (consumed, frames) = decoder.decodeFrame(file, from: position, to: l.end)
            position += consumed
            if frames > 0 {
                var count = Int64(frames)
                if let g = l.granule, g >= 0, given + count > g { count = max(0, g - given) }
                given += count
                if count > 0 { return Int(count) }
                continue
            }
            if consumed == 0 { nextLink() }
        }
        return 0
    }

    /// On to the next stream of a chained file, if it can be played as the first is.
    private func nextLink() {
        guard link + 1 < links.count else {
            finished = true
            return
        }
        let start = links[link + 1].start
        var consumed = 0
        guard let d = try? VorbisDecoder(file, at: start, consumed: &consumed),
              d.channels == channels, d.sampleRate == sampleRate
        else {
            finished = true
            return
        }
        link += 1
        decoder = d
        position = start + consumed
        given = 0
    }

    public func samples(of channel: Int) -> UnsafePointer<Float> {
        decoder.samples(of: channel)
    }

    /// Back to the start, as if newly opened.
    public func restart() {
        var consumed = 0
        if let d = try? VorbisDecoder(file, at: links[0].start, consumed: &consumed) {
            decoder = d
            position = links[0].start + consumed
            link = 0
            given = 0
            finished = false
        }
    }
}
