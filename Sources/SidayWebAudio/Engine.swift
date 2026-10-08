// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit

// The web player's engine. It is a WebAssembly module of its own, with no user interface and no
// JavaScript library: a worker (Web/engine.js) hands it the bytes of a tune and asks it for samples,
// through the functions exported at the foot of this file, and passes them on to the audio thread.
//
// The worker renders a whole song as fast as it can and keeps it, so that the listener can move about
// in it. What it keeps is the tune as the chip made it. The television, if the sound is going through
// one, and the spectrum analyser, which shows what is being heard, are applied to each piece as it is
// sent to be played: `pull` makes the sound and `present` finishes it. So a television can be put in
// the way or taken out of it at any moment; a change between mono and stereo is a change to what the
// chip makes, and the song has to be rendered again (`setOutput` says when).

/// One tune at a time: what the command-line player's engine does between a file and the sound card.
final class WebPlayer {
    /// The length of a block, as the command-line player renders them: the rules that end a tune look
    /// at the sound a block at a time, so the two front ends must cut it the same way.
    static let blockFrames = 512
    /// What is handed out at a time: the size of block a browser's audio thread works in.
    static let quantumFrames = 128

    var options = LoadOptions()
    /// Every song of a tune is played, from the first: the page lists them, and goes on to the next
    /// when one ends.
    var policy: PlaybackPolicy = {
        var policy = PlaybackPolicy()
        policy.allSubsongs = true
        return policy
    }()
    private var renderer: (any Renderer)?
    private var session: TuneSession?
    private var television: Television?
    /// How the loaded tune's channels were placed when it was loaded, if that is something it has:
    /// an AY tune has three channels to place, a SID tune has a single output, and an Atari ST joins
    /// its three into one.
    private var layout: StereoLayout?
    /// True for a tune whose stereo is its own (a module's), which the choice of output only keeps or folds.
    private var ownStereo = false
    private let block = UnsafeMutablePointer<Float>.allocate(capacity: WebPlayer.blockFrames * 2)
    private var blockLength = 0
    private var blockCursor = 0
    /// Interleaved stereo, `quantumFrames` long: what `pull` last produced.
    let output = UnsafeMutablePointer<Float>.allocate(capacity: WebPlayer.quantumFrames * 2)
    /// The last thing to tell the page in words: a tune's details, or why a file would not load.
    private(set) var text: [UInt8] = []
    private var spectrum = SpectrumAnalyzer()
    /// The analyser's bars and then their caps, each as a byte from 0 to 255.
    private(set) var bars: [UInt8] = []

    /// Loads a tune and starts its first song. Returns false, with the reason in `text`, if it cannot be played.
    func load(_ data: [UInt8], name: String) -> Bool {
        renderer = nil
        session = nil
        layout = nil
        let fileExtension = name.split(separator: ".").count > 1 ? String(name.split(separator: ".").last ?? "") : ""
        guard let format = TuneFormat(fileExtension: fileExtension) else {
            text = Array("unknown file type .\(fileExtension)".utf8)
            return false
        }
        do {
            let loaded = try TuneLoader.load(data, format: format, path: name, options: options)
            renderer = loaded
            layout = format == .sid || format == .sndh ? nil : options.stereo
            ownStereo = format == .mod || format == .xm
            select(policy.firstSubsong(of: loaded))
            return true
        } catch let error as TuneError {
            text = Array(error.description.utf8)
        } catch {
            text = Array("the file could not be played".utf8)
        }
        return false
    }

    /// Starts a song of the loaded tune from its beginning.
    func select(_ subsong: Int) {
        guard let renderer else { return }
        let song = min(max(0, subsong), renderer.subsongCount - 1)
        if renderer.subsongCount > 1 || song != renderer.currentSubsong { renderer.select(subsong: song) }
        session = TuneSession(renderer: renderer, policy: policy)
        settle()
        blockLength = 0
        blockCursor = 0
        // One line each: format, title, author, detail. Then a line for each song when there are several:
        // its length in milliseconds, if that is known, a tab, and its name, if it has one. The page
        // takes them apart again.
        let info = renderer.info
        func tidy(_ field: String) -> String { String(field.map { $0.isNewline || $0 == "\t" ? " " : $0 }) }
        var lines = [info.format, info.title, info.author, info.detail].map(tidy)
        if renderer.subsongCount > 1 {
            for song in renderer.songs {
                lines.append("\(song.length.map { String(Int($0 * 1000)) } ?? "")\t\(tidy(song.title))")
            }
        }
        text = Array(lines.joined(separator: "\n").utf8)
    }

    /// Changes what tunes are heard through. Returns true if the tune that is loaded has to be loaded
    /// again to be heard that way: its channels were placed otherwise when it was rendered.
    func setOutput(_ style: OutputStyle) -> Bool {
        if style.television != television?.set { television = style.television.map { Television($0) } }
        options.stereo = style.stereo
        // A module has a stereo of its own, which only mono does away with.
        return layout.map { ownStereo ? ($0 == .mono) != (style.stereo == .mono) : $0 != style.stereo } ?? false
    }

    /// What is about to be presented does not follow from what was presented last: the song has
    /// started, or the listener has moved to another place in it.
    func settle() {
        television?.reset()
        spectrum.reset()
    }

    /// Finishes sound that `pull` made, where it lies, as it goes to be heard: through the television,
    /// if one is switched on, and past the spectrum analyser. Interleaved stereo.
    func present(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        television?.process(samples, frames: frames)
        spectrum.add(samples, frames: frames)
    }

    /// Fills `output` with the next `quantumFrames` frames of the tune. Returns false once the tune is
    /// over: what is left of the buffer is then silence.
    func pull() -> Bool {
        var filled = 0
        while filled < Self.quantumFrames {
            if blockCursor == blockLength {
                guard let session, !session.finished else { break }
                blockLength = session.render(into: block, frames: Self.blockFrames)
                blockCursor = 0
                if blockLength == 0 { break }
            }
            let count = min(Self.quantumFrames - filled, blockLength - blockCursor)
            (output + filled * 2).update(from: block + blockCursor * 2, count: count * 2)
            filled += count
            blockCursor += count
        }
        if filled < Self.quantumFrames {
            (output + filled * 2).update(repeating: 0, count: (Self.quantumFrames - filled) * 2)
        }
        return filled == Self.quantumFrames || !(session?.finished ?? true)
    }

    /// Brings `bars` up to date with what has been presented.
    func analyse() {
        spectrum.analyse()
        bars = (spectrum.levels + spectrum.caps).map { UInt8(max(0, min(255, $0 * 255))) }
    }

    var subsongCount: Int { renderer?.subsongCount ?? 0 }
    var subsong: Int { renderer?.currentSubsong ?? 0 }
    var length: Double { session?.displayLength ?? 0 }
    /// False when the file does not say how long the song is, and `length` is only the time it is allowed.
    var lengthIsKnown: Bool { renderer?.knownLength != nil }
    /// For a song that ended because it had fallen silent, or never made a sound: the seconds of
    /// silence it took to be sure. 0 for a song that is still playing or ended any other way.
    var silenceAtEnd: Double {
        guard let session, session.end == .silent || session.end == .neverSounded else { return 0 }
        return session.silence
    }

    /// Seconds of the song made so far.
    var position: Double {
        guard let session else { return 0 }
        return Double(session.framesRendered - (blockLength - blockCursor)) / Double(outputSampleRate)
    }

    /// 0 while a tune is playing, 1 when it has run its course, 2 when it fell silent, 3 when it never made a sound.
    var state: Int {
        switch session?.end {
        case .playing?: 0
        case .completed?: 1
        case .silent?: 2
        case .neverSounded?: 3
        case nil: -1
        }
    }
}

nonisolated(unsafe) private let player = WebPlayer()

// MARK: Exports

// Memory for the page to put a file in before calling `siday_load`.
@_expose(wasm, "siday_alloc")
@_cdecl("siday_alloc")
public func sidayAlloc(_ size: Int32) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer.allocate(byteCount: max(1, Int(size)), alignment: 16)
}

@_expose(wasm, "siday_free")
@_cdecl("siday_free")
public func sidayFree(_ pointer: UnsafeMutableRawPointer) {
    pointer.deallocate()
}

/// Loads the tune in `data`; `name` is its file name or path, in UTF-8. Returns 1 if it will play.
@_expose(wasm, "siday_load")
@_cdecl("siday_load")
public func sidayLoad(_ data: UnsafePointer<UInt8>, _ length: Int32, _ name: UnsafePointer<UInt8>, _ nameLength: Int32) -> Int32 {
    let bytes = Array(UnsafeBufferPointer(start: data, count: Int(length)))
    let name = String(decoding: UnsafeBufferPointer(start: name, count: Int(nameLength)), as: UTF8.self)
    return player.load(bytes, name: name) ? 1 : 0
}

/// HVSC's Songlengths.md5, for the SID tunes loaded after it. A length of zero forgets it.
@_expose(wasm, "siday_set_songlengths")
@_cdecl("siday_set_songlengths")
public func sidaySetSongLengths(_ data: UnsafePointer<UInt8>, _ length: Int32) -> Int32 {
    let database = SongLengthDatabase(Array(UnsafeBufferPointer(start: data, count: Int(length))))
    player.options.songLengths = database.isEmpty ? nil : database
    return database.isEmpty ? 0 : 1
}

@_expose(wasm, "siday_select")
@_cdecl("siday_select")
public func sidaySelect(_ subsong: Int32) {
    player.select(Int(subsong))
}

/// What tunes are heard through: an output style, by its place in the order SidayKit lists them.
/// Returns 1 if the tune that is loaded has to be loaded again (`siday_load`) to be heard that way,
/// which is so when the change is between mono and stereo, or one stereo and the other, and the tune
/// is one that stereo makes a difference to. A television is put in or taken out as the tune plays.
@_expose(wasm, "siday_set_output")
@_cdecl("siday_set_output")
public func sidaySetOutput(_ style: Int32) -> Int32 {
    let styles = OutputStyle.allCases
    guard styles.indices.contains(Int(style)) else { return 0 }
    return player.setOutput(styles[Int(style)]) ? 1 : 0
}

/// Renders the next 128 frames into the buffer at `siday_output`, as the chip made them. Returns 0
/// once the tune is over.
@_expose(wasm, "siday_pull")
@_cdecl("siday_pull")
public func sidayPull() -> Int32 {
    player.pull() ? 1 : 0
}

@_expose(wasm, "siday_output")
@_cdecl("siday_output")
public func sidayOutput() -> UnsafeMutablePointer<Float> {
    player.output
}

/// Finishes `frames` frames of rendered sound at `samples`, in place, on their way to being heard:
/// the television, if one is on, and the spectrum analyser. They can be any part of the song, in any
/// order; call `siday_settle` first when they do not follow the last ones.
@_expose(wasm, "siday_present")
@_cdecl("siday_present")
public func sidayPresent(_ samples: UnsafeMutablePointer<Float>, _ frames: Int32) {
    player.present(samples, frames: Int(frames))
}

@_expose(wasm, "siday_settle")
@_cdecl("siday_settle")
public func sidaySettle() {
    player.settle()
}

/// The spectrum analyser's bars for the sound presented so far: `siday_spectrum_bands` bars, low to high,
/// and then as many caps, each a byte from 0 to 255. Call it as often as the bars are drawn.
@_expose(wasm, "siday_spectrum")
@_cdecl("siday_spectrum")
public func sidaySpectrum() -> UnsafePointer<UInt8>? {
    player.analyse()
    return player.bars.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "siday_spectrum_bands")
@_cdecl("siday_spectrum_bands")
public func sidaySpectrumBands() -> Int32 {
    Int32(player.bars.count / 2)
}

@_expose(wasm, "siday_text")
@_cdecl("siday_text")
public func sidayText() -> UnsafePointer<UInt8>? {
    player.text.withUnsafeBufferPointer { $0.baseAddress }
}

@_expose(wasm, "siday_text_length")
@_cdecl("siday_text_length")
public func sidayTextLength() -> Int32 {
    Int32(player.text.count)
}

@_expose(wasm, "siday_subsongs")
@_cdecl("siday_subsongs")
public func sidaySubsongs() -> Int32 { Int32(player.subsongCount) }

@_expose(wasm, "siday_subsong")
@_cdecl("siday_subsong")
public func sidaySubsong() -> Int32 { Int32(player.subsong) }

@_expose(wasm, "siday_length")
@_cdecl("siday_length")
public func sidayLength() -> Double { player.length }

/// 1 when the file says how long the song is; 0 when `siday_length` is only the time it is allowed.
@_expose(wasm, "siday_length_known")
@_cdecl("siday_length_known")
public func sidayLengthKnown() -> Int32 { player.lengthIsKnown ? 1 : 0 }

/// Once a song is over: the seconds of silence at its end that showed it was, if that is how it
/// ended, and 0 if not. They are no part of the song.
@_expose(wasm, "siday_silence")
@_cdecl("siday_silence")
public func sidaySilence() -> Double { player.silenceAtEnd }

@_expose(wasm, "siday_position")
@_cdecl("siday_position")
public func sidayPosition() -> Double { player.position }

@_expose(wasm, "siday_state")
@_cdecl("siday_state")
public func sidayState() -> Int32 { Int32(player.state) }

@main struct Main {
    /// Nothing to do: the module waits to be called.
    static func main() {}
}
