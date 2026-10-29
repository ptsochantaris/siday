// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

// What a player with a screen does around its tune player: the web player's engine (in a worker, in
// the audio module: Web/engine.js only carries messages to it and from it) and the app's.
//
// A song is rendered to its end as fast as the machine will go, and kept, so the listener can move
// to any place in it: these tunes are programs, and the only way to the middle of one is through
// everything before it. Moving is then a matter of sending from another place in what is kept; if
// the place has not been rendered yet, the sound waits until it has. A song costs 23 MB a minute
// while it is the one playing.
//
// It has no thread of its own and knows no clock. The front end calls it from one thread of its
// own, and only from that one: `work` renders a little and sends what is due, `played` says a chunk
// that was sent has been heard, and the rest are what the listener asks for. What it has to hand
// over is left in `outbox` (sound to be heard) and `events` (news for the screen), for the front
// end to take. Where it waits for a while, it is told the time by the front end, in seconds, and
// says until when (`wakesAt`).

/// The song as far as it has been rendered: the sound of each chunk, as the chip made it, and what
/// its voices were doing in it. It says of itself which voices were left out of it, and once all of
/// it is there, that it is done and the length that was found.
final class KeptSong {
    struct Chunk {
        var samples: [Float]
        /// The place in the song that the chunk reaches, in seconds.
        var position: Double
        /// True for the last chunk of the song.
        var last: Bool
        /// Five rows, a byte for each voice in each: how bright its light is, its pitch, whether a note
        /// was started on it, its side, and whether it is playing a sample (see `TunePlayer.voicesTaken`).
        var voices: [UInt8]
        /// Each voice's scope as the chunk ends: `ChannelWaves.points` bytes a voice.
        var scopes: [UInt8]?
    }

    var chunks: [Chunk] = []
    /// The voices left out of it, as a word (see `SongKeeper.written`).
    var mutes = ""
    var done = false
    var found = 0.0
}

public final class SongKeeper {
    /// Frames in a chunk: 21 ms. Each chunk sent carries the position it reaches, the spectrum
    /// analyser's bars and the lights of the tune's voices, so the screen is told of them all about
    /// 47 times a second.
    public static let chunkFrames = 1024
    /// How far ahead to send: chunks handed over and not yet heard. About a fifth of a second.
    public static let ahead = 10
    /// How bright a light has to have been for its voice to count as heard, of 255.
    static let heard: UInt8 = 24
    /// Silence left at the end of a song that ended by falling silent, in seconds.
    static let rest = 1.0
    /// How long sending waits for the front end to say what level was kept for the song, and then
    /// for the song to be measured, in seconds.
    static let keptWaitLongest = 0.150
    static let measuringWaitLongest = 1.0

    /// A chunk of sound to be heard, with what is to be shown while it is.
    public struct Sent: Sendable {
        /// The run of sound it belongs to: the front end starts another, with another number, for each
        /// tune and for each move within one, and drops what it has of the last.
        public var serial: Int
        /// The tune that is loaded: the front end's count of its requests to play.
        public var tune: Int
        /// Interleaved stereo, `chunkFrames` long, finished: levelled, through the television, if one
        /// is on, and heard by the spectrum analyser.
        public var samples: [Float]
        /// Where in the song it reaches, in seconds.
        public var position: Double
        /// The analyser's bars, low to high, and then as many caps, each a byte from 0 to 255.
        public var bars: [UInt8]
        /// The voices that have a light, five rows of them as in `KeptSong.Chunk.voices`, and a sixth:
        /// 1 for each voice the listener has left out, as that stands now.
        public var voices: [UInt8]
        /// Their scopes, in the same order, `ChannelWaves.points` bytes a voice; nil if the tune's
        /// player does not keep its voices' sound.
        public var scopes: [UInt8]?
        /// True for the last chunk of the song.
        public var last: Bool
    }

    /// What the screen is to be told.
    public enum Event: Sendable {
        /// A tune was loaded, or loaded again: whether it plays; why not, if not; its details, its
        /// songs and which is playing; how long the song is to be played; and what its level is kept under.
        case loaded(tune: Int, plays: Bool, problem: String?, info: TuneInfo?, songs: [SongInfo], song: Int, length: Double, lengthIsKnown: Bool, levelKey: String)
        /// The song's level, as it was found by measuring it, to be kept under its key.
        case level(tune: Int, key: String, text: String)
        /// How much of the song there is to move about in, in seconds; and its length, if that has
        /// been found by rendering it to its end, and 0 if not.
        case rendered(tune: Int, seconds: Double, length: Double)
        /// The song has started or stopped being made again for the listener: a voice muted or brought
        /// back, another output or setting.
        case remaking(tune: Int, busy: Bool)
        /// Which voices with a light the listener has left out, 1 for each: told at once, since
        /// what is shown is the sound of a moment ago.
        case muted(tune: Int, marks: [UInt8])
        /// Some of the tune's songs have still to be played through to find how long they are
        /// (`SongInfo.pending`): all of them are to be, somewhere the sound is not held up by it
        /// (`TunePlayer.measure`, on a player of its own), and what is found given to `adopt`.
        case measure(tune: Int, name: String, bytes: [UInt8], companions: [[UInt8]?])
        /// It is known now how long each of the tune's songs is.
        case songs(tune: Int, songs: [SongInfo])
    }

    public let player = TunePlayer()
    /// Sound to be heard, in order: the front end takes it.
    public var outbox: [Sent] = []
    /// News for the screen, in order: the front end takes it.
    public var events: [Event] = []

    /// The tune that is loaded: the front end's count of its requests to play.
    private var tune = 0
    /// The file it came from, the files it needs beside its own, and the song of it that was asked
    /// for. Kept in case the song has to be rendered again.
    private struct File {
        var name: String
        var bytes: [UInt8]
        var companions: [[UInt8]?]
        var subsong: Int
    }
    private var file: File?
    private var kept = KeptSong()
    /// What is being sent to be heard: `kept`, but for a while after the listener has muted a voice or
    /// brought one back. The song is then being rendered again, into a new `kept`, and what was kept
    /// before goes on being heard until the new has got as far as the listener is.
    private var source: KeptSong
    /// The voices the listener has left out of the sound: a byte for each voice of the tune, 1 for one
    /// that is not to be heard; nil, when every voice is. It lasts as long as the song does.
    private var mask: [UInt8]?
    /// How the song turned out when it was rendered with every voice heard: how many chunks, and the
    /// length found. A song with voices left out is made to come out the same, whatever silence there
    /// is in it. Nil, until the song has been rendered so to its end.
    private var whole: (chunks: Int, found: Double)?
    /// Which of the tune's voices have a light. Some voices are ones a tune may never use (a ZX
    /// Spectrum's beeper, the samples played on a SID's volume), and get a light once they have been
    /// heard in the song as far as it is rendered, which is well ahead of what is playing.
    public private(set) var shown: [Bool] = []
    /// True when there is no more of the song to render.
    private var complete = true
    /// The song's length in seconds, once all of it is rendered, if that is how it was found out: the
    /// file did not say, and the song came to an end before the time it was allowed; or the file did
    /// say, and the song fell silent for good before then. Otherwise 0.
    private var found = 0.0
    /// True while what is heard is not yet what the listener last asked for.
    private var remaking = false
    private var reported = -1.0
    private var serial = 0
    /// The next chunk to send, by its place in `source`.
    private var next = 0
    /// False once the last chunk of the song has been sent.
    private var sending = false
    /// Chunks handed over that have not yet been heard.
    private var waiting = 0
    /// Until when sending waits, after a song is loaded and while songs are levelled, for the song's
    /// level: first a moment for the front end to say what level was kept for it, so that a song
    /// measured before starts at its level; and then, if none was, up to a second more while it is
    /// measured as it is rendered. A song that is measured whole in that time starts at its level; one
    /// that is not starts at about it, by as much of it as has been measured, and glides to it once
    /// the whole of it has been. Nil once the level is known, or the song is on its way.
    private var levelWait: Double?
    /// True once the moment for the front end to answer is over, and the song is being measured.
    private var measuring = false
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: SongKeeper.chunkFrames * 2)

    public init() {
        source = kept
    }

    deinit {
        scratch.deallocate()
    }

    /// A mask as a word: the same word for the same voices left out, and nothing for none.
    static func written(_ marks: [UInt8]?) -> String {
        guard let marks, marks.contains(where: { $0 != 0 }) else { return "" }
        return String(marks.map { $0 != 0 ? "1" : "0" })
    }

    /// True if there is a song, rendered or being rendered.
    private var hasSong: Bool { file != nil && !(source.chunks.isEmpty && complete) }

    // MARK: What the listener asks for

    /// Loads a tune and starts on the song asked for (or the one the file asks to be played first,
    /// for a negative `subsong`), every voice of it heard; sending starts as a new run, `serial`.
    public func load(tune: Int, serial: Int, name: String, bytes: [UInt8], companions: [[UInt8]?], subsong: Int, now: Double) {
        self.tune = tune
        self.serial = serial
        file = File(name: name, bytes: bytes, companions: companions, subsong: subsong)
        mask = nil
        whole = nil
        let plays = load(nil)
        tell(plays: plays)
        if plays, player.songsPending {
            events.append(.measure(tune: tune, name: name, bytes: bytes, companions: companions))
        }
        next = 0
        waiting = 0
        sending = plays
        if plays {
            measuring = false
            levelWait = now + Self.keptWaitLongest
        }
        sayRemaking()
    }

    /// Takes what was found of a tune's songs by playing them through (`Event.measure`), and keeps
    /// it: the screen is told, if it is of the tune that is loaded.
    public func adopt(tune: Int, key: String, measures: SongMeasures) {
        guard player.adopt(measures, key: key), tune == self.tune else { return }
        events.append(.songs(tune: tune, songs: player.renderer?.songs ?? []))
    }

    /// The listener has moved to another place in the song: sending goes on from there, as a new run
    /// of sound, as soon as there is something there to send.
    public func seek(to position: Double, serial: Int, now: Double) {
        guard hasSong else { return }
        self.serial = serial
        next = max(0, Int((position * Double(outputSampleRate) / Double(Self.chunkFrames)).rounded(.down)))
        waiting = 0
        sending = true
        player.settle()
        send(now: now)
    }

    /// The listener has pressed a voice's light (by its place among those that are shown): to mute it
    /// or bring it back, or, with `solo`, to hear it alone (and pressed again on a voice heard alone,
    /// to bring the others back).
    public func mute(light: Int, solo: Bool) {
        let places = shown.indices.filter { shown[$0] }
        guard places.indices.contains(light) else { return }
        let voice = places[light]
        var marks = mask ?? [UInt8](repeating: 0, count: shown.count)
        if solo {
            let alone = marks.indices.allSatisfy { marks[$0] == ($0 == voice ? 0 : 1) }
            marks = marks.indices.map { alone || $0 == voice ? 0 : 1 }
        } else {
            marks[voice] ^= 1
        }
        mask = marks.contains(where: { $0 != 0 }) ? marks : nil
        remix()
        events.append(.muted(tune: tune, marks: marks.indices.filter { shown[$0] }.map { marks[$0] }))
        sayRemaking()
    }

    /// What tunes are heard through. A television is no more than something in the way of the sound
    /// as it is sent. Mono and stereo are what the chip makes, so a change between them means making
    /// the song again.
    public func setOutput(_ style: OutputStyle) {
        if player.setOutput(style) { again() }
        sayRemaking()
    }

    /// The listener's settings: a value for each, in the order of `Setting`'s cases. If one has changed
    /// that has to do with the tune that is loaded, the song is made again.
    public func setSettings(_ values: [Double]) {
        if player.setSettings(values) { again() }
        sayRemaking()
    }

    /// HVSC's own list of song lengths, for the SID tunes loaded after it.
    public func setSongLengths(_ database: SongLengthDatabase?) {
        player.setSongLengths(database)
    }

    /// The ROMs of an MT-32 of the LAPC-I's kind, for the MIDI files written for the MT-32 loaded after
    /// them (see `TunePlayer.setMT32ROMs`).
    public func setMT32ROMs(_ roms: MT32ROMSet?) {
        player.setMT32ROMs(roms)
    }

    /// The whole Sound Canvases kept, for the MIDI files loaded after them (see `TunePlayer.setSoundCanvases`).
    public func setSoundCanvases(_ sets: [SC55ROMSet]) {
        player.setSoundCanvases(sets)
    }

    /// The level the front end kept for the song, from when it was measured before (as `Event.level`
    /// gave it), or nil if none was.
    public func setKeptLevel(key: String, text: String?, now: Double) {
        guard file != nil, key == player.levelKey else { return }
        if let text, let level = SongLevel(text: text) { player.setLevel(level) }
        // (None was kept: the song is measured now, for a moment, before it is heard.)
        if levelWait != nil, !measuring, player.waitsForLevel { waitForMeasuring(now: now) }
        send(now: now)
        sayRemaking()
    }

    /// The tune has been taken out of the list, and nothing follows it: the song is let go.
    public func stop() {
        file = nil
        kept = KeptSong()
        source = kept
        mask = nil
        whole = nil
        complete = true
        sending = false
        sayRemaking()
    }

    // MARK: The front end's turns

    /// A chunk of this run has been heard, so there is room for another.
    public func played(serial: Int, now: Double) {
        guard serial == self.serial else { return }
        waiting -= 1
        send(now: now)
        sayRemaking()
    }

    /// True while there is more of the song to render.
    public var isWorking: Bool { !complete }

    /// When `work` is to be called again, if it is not called before, though there is nothing to
    /// render: sending waits until then for the song's level (see `levelWait`). Nil if it does not.
    public var wakesAt: Double? { levelWait }

    /// Renders up to `chunks` chunks of the song, sending what is due between them, and says how much
    /// there is to move about in. Returns true if there is more to render.
    @discardableResult
    public func work(chunks: Int, now: Double) -> Bool {
        var count = 0
        while !complete, count < chunks {
            render()
            send(now: now)
            count += 1
        }
        send(now: now)
        // (Only while there was something to render: once the song is whole, it has been said.)
        if count > 0 { report(now: now) }
        sayRemaking()
        return !complete
    }

    // MARK: Inside

    private func waitForMeasuring(now: Double) {
        measuring = true
        levelWait = now + Self.measuringWaitLongest
    }

    /// Tells the module which voices to leave out of the tune when it is next loaded. Returns false if
    /// it cannot do that yet: it has first to play the song through whole, to know how it ends.
    @discardableResult
    private func leaveOut(_ marks: [UInt8]?) -> Bool {
        player.setMuted(Self.written(marks) == "" ? [] : (marks ?? []).map { $0 != 0 })
    }

    /// Loads the tune in `file` and starts on the song asked for, with the voices in `marks` left out
    /// of it. Returns false if it cannot be played. What was being sent goes on being sent if
    /// `meanwhile` says so: the song is the same song.
    private func load(_ marks: [UInt8]?, meanwhile: Bool = false) -> Bool {
        guard let file else { return false }
        let before = source
        leaveOut(marks)
        player.companions = file.companions
        let plays = player.load(file.bytes, name: file.name)
        if plays, file.subsong >= 0 { player.select(file.subsong) }
        kept = KeptSong()
        kept.mutes = Self.written(marks)
        source = meanwhile && plays ? before : kept
        found = 0
        complete = !plays
        reported = -1
        // (The lights that have come on stay on, if it is the same song with the same voices.)
        let voices = plays ? player.voiceCount : 0
        if !meanwhile || shown.count != voices {
            let always = plays ? player.lightsAlwaysShown : 0
            shown = (0 ..< voices).map { $0 < always }
        }
        return plays
    }

    private func tell(plays: Bool) {
        let renderer = player.renderer
        events.append(.loaded(
            tune: tune, plays: plays, problem: player.problem, info: plays ? player.info : nil,
            songs: plays && player.subsongCount > 1 ? renderer?.songs ?? [] : [], song: player.subsong,
            length: player.length, lengthIsKnown: player.lengthIsKnown, levelKey: plays ? player.levelKey : ""
        ))
    }

    /// Renders the playing song again from its start, because what it is heard through, or a setting,
    /// has changed in a way that changes what is made. What was being heard goes on being heard, as it
    /// was, until the new rendering has got as far as the listener is; and the screen is told of the
    /// tune again, since how long it is to be played may have changed. It is the song that was
    /// playing, whichever the file would now be started at. And it is rendered whole first, whatever
    /// voices are left out: how it ends may have changed, and that has to be known before it can be
    /// rendered without them.
    private func again() {
        guard hasSong else { return }
        if player.subsongCount > 0 { file?.subsong = player.subsong }
        whole = nil
        guard load(nil, meanwhile: true) else { return }
        tell(plays: true)
    }

    /// Sees that the song is being rendered as the listener now wants to hear it: with the voices of
    /// `mask` left out. What is being heard goes on until the new rendering has caught up with it.
    private func remix() {
        guard hasSong else { return }
        let wanted = Self.written(mask)
        if kept.mutes == wanted { return }
        // What is being heard may be the very thing, if the listener has changed their mind again.
        if source.mutes == wanted, source.done {
            kept = source
            complete = true
            found = source.found
            return
        }
        // A song with voices left out ends as the whole song does, which has to be known first. If it
        // is not, the whole song is still being rendered, and this is come back to when it has been.
        if wanted != "", whole == nil {
            if kept.mutes != "" { _ = load(nil, meanwhile: true) }
            return
        }
        _ = load(mask, meanwhile: true)
    }

    /// Renders the next chunk of the song and keeps it.
    private func render() {
        let frames = Self.chunkFrames
        var samples = [Float](repeating: 0, count: frames * 2)
        // (What is left of the chunk after the tune's end stays silent: `pull` leaves it so.)
        let last = !samples.withUnsafeMutableBufferPointer { player.pull(into: $0.baseAddress!, frames: frames) }
        player.takeVoices()
        let count = shown.count
        let voices = Array(player.voicesTaken.prefix(count * 5))
        for voice in 0 ..< count where voices[voice] >= Self.heard { shown[voice] = true }
        var scopes: [UInt8]?
        if count > 0 {
            player.takeScopes()
            scopes = Array(player.scopes.prefix(count * ChannelWaves.points))
        }
        kept.chunks.append(KeptSong.Chunk(samples: samples, position: player.position, last: last, voices: voices, scopes: scopes))
        if kept.mutes != "", let whole {
            // With voices left out, the song is as long as it is whole: no longer, whatever the module
            // went on to render, and its length the length that was found then.
            if last || kept.chunks.count >= whole.chunks {
                kept.chunks.removeLast(max(0, kept.chunks.count - whole.chunks))
                kept.chunks[kept.chunks.count - 1].last = true
                complete = true
                found = whole.found
                kept.done = true
                kept.found = found
            }
            return
        }
        if last { finish() }
    }

    /// The whole song is rendered, and so it is known how it ends.
    private func finish() {
        complete = true
        let chunkSeconds = Double(Self.chunkFrames) / Double(outputSampleRate)
        let end = kept.chunks[kept.chunks.count - 1].position
        // A tune with no ending of its own is over when it has been silent for some seconds. Those
        // seconds were needed to find that out, and now it is known: a moment of them is kept and the
        // rest dropped.
        let silence = player.silenceAtEnd
        if silence > Self.rest {
            let keep = max(1, min(kept.chunks.count, Int(((end - silence + Self.rest) / chunkSeconds).rounded(.up))))
            kept.chunks.removeLast(kept.chunks.count - keep)
            kept.chunks[kept.chunks.count - 1].last = true
        }
        // Where the file gave no length the screen was told the time the tune would be allowed. If the
        // tune did not need it all, its real length is the sound it made. So it is for a tune whose
        // length is known but which fell silent before it: a module with nothing but empty rows
        // before it goes round.
        let length = end - silence
        found = (!player.lengthIsKnown || silence > 0) && length > 0 && length < player.length ? length : 0
        // So it is too for a tune that goes round, whose length was reckoned from its first time round:
        // one that goes back to a place after its beginning is shorter each time after, and one taken
        // to go round may simply end. Where its ending began is its length.
        let played = player.playedLength
        if found == 0, played > 0, abs(played - player.length) > 0.5 { found = played }
        kept.done = true
        kept.found = found
        // And how loud it is, if it was measured as it was rendered, for the front end to keep.
        if player.levelFound, let level = player.level {
            events.append(.level(tune: tune, key: player.levelKey, text: level.text))
        }
        // That was the whole song, and how it ends is now known: if the listener has voices left out,
        // it can be rendered as they want it.
        whole = (kept.chunks.count, found)
        remix()
    }

    /// Sends chunks until enough are waiting to be heard, or there are no more to send yet.
    private func send(now: Double) {
        if let wait = levelWait {
            if player.waitsForLevel {
                if now < wait { return }
                if !measuring {
                    waitForMeasuring(now: now)
                    return
                }
                player.startAtProvisionalLevel()
            }
            levelWait = nil
        }
        // The song as the listener now wants it is taken up as soon as it has been rendered past the
        // place they are at; and whatever there is of the song is, if what was being heard has run out.
        if source !== kept,
           (kept.mutes == Self.written(mask) && (kept.chunks.count > next + Self.ahead || complete)) || (next >= source.chunks.count && kept.chunks.count > next) {
            source = kept
        }
        // A place past the end of the song: its last moment is played, and so it ends.
        if sending, source.done, next >= source.chunks.count { next = source.chunks.count - 1 }
        while sending, waiting < Self.ahead, next < source.chunks.count {
            let chunk = source.chunks[next]
            next += 1
            // The television and the spectrum analyser belong to what is heard, not to what is kept.
            chunk.samples.withUnsafeBufferPointer { scratch.update(from: $0.baseAddress!, count: Self.chunkFrames * 2) }
            player.present(scratch, frames: Self.chunkFrames)
            let samples = Array(UnsafeBufferPointer(start: scratch, count: Self.chunkFrames * 2))
            player.analyse()
            // The voices that have a light, row by row as they were kept; and a sixth row, for which of
            // them the listener has left out, as that stands now.
            let count = shown.count
            var voices: [UInt8] = []
            for place in chunk.voices.indices where count > 0 && shown[place % count] { voices.append(chunk.voices[place]) }
            for voice in 0 ..< count where shown[voice] { voices.append(mask.map { voice < $0.count && $0[voice] != 0 ? 1 : 0 } ?? 0) }
            // The scopes of the voices that have a light, in the same order.
            var scopes: [UInt8]?
            if let all = chunk.scopes {
                var lit: [UInt8] = []
                let points = ChannelWaves.points
                for voice in 0 ..< count where shown[voice] && all.count >= (voice + 1) * points {
                    lit += all[(voice * points) ..< ((voice + 1) * points)]
                }
                scopes = lit
            }
            outbox.append(Sent(serial: serial, tune: tune, samples: samples, position: chunk.position, bars: player.bars, voices: voices, scopes: scopes, last: chunk.last))
            waiting += 1
            if chunk.last { sending = false }
        }
    }

    /// Tells the screen how much of the song there is to move about in: every tenth of a second at
    /// most while it is being rendered.
    private func report(now: Double) {
        if !complete, reported >= 0, now - reported < 0.1 { return }
        reported = now
        // (While a song is being rendered again for a voice muted or brought back, there is as much of
        // it to move about in as there was.)
        let chunks = max(kept.chunks.count, source.chunks.count)
        let length = complete ? found : source.done ? source.found : 0
        events.append(.rendered(tune: tune, seconds: Double(chunks * Self.chunkFrames) / Double(outputSampleRate), length: length))
    }

    /// Tells the screen when the song starts or stops being made again for the listener.
    private func sayRemaking() {
        let now = file != nil && (source !== kept || kept.mutes != Self.written(mask))
        if now == remaking { return }
        remaking = now
        events.append(.remaking(tune: tune, busy: now))
    }
}
