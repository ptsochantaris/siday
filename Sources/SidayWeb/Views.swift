// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import ElementaryUI
import SidayKit

@View
struct PlayerView {
    @State var player = Player()

    var body: some View {
        div(.class("page")) {
            header {
                h1 { "siday" }
                p(.class("tagline")) { "Chip music and modules from the ZX Spectrum, Amstrad CPC, Atari ST, Commodore 64, Amiga and PC, played in your browser." }
            }

            NowPlaying(player: player)

            if player.isShowing(.picture) {
                Picture(player: player)
            }

            div(.class("add")) {
                button { "Add files…" }.onClick { try? sidayChoose(false) }
                button { "Add a folder…" }.onClick { try? sidayChoose(true) }
                span(.class("hint")) { "or drop them anywhere on the page. They stay on your computer." }
            }

            // One tune needs no list to choose from.
            if player.isShowing(.list) {
                Playlist(player: player)
            }

            footer {
                p { "Keys: space pause · n or → next · p or ← previous · + and − song · f picture on the whole screen" }
                p {
                    "Plays "
                    TuneFormat.allCases.map { $0.rawValue.uppercased() }.joined(separator: ", ")
                    " files."
                }
                p {
                    "SID tunes take their lengths from the High Voltage SID Collection, release \(BuiltInSongLengths.release); a newer Songlengths.md5 from it, added like a tune, is used first."
                }
                p {
                    "siday is free software, written in Swift. "
                    a(.href("https://github.com/ptsochantaris/siday")) { "The source is on GitHub" }
                    "."
                }
            }
        }
        .onAppear { player.start() }
        .receive(GlobalDocument.onKeyDown) { event in player.key(event.key) }
    }
}

@View
struct NowPlaying {
    var player: Player

    var body: some View {
        section(.class("now")) {
            Shown(player: player)

            if let tune = player.tune {
                div(.class("what")) {
                    span(.class("format")) { tune.format }
                    span(.class("title")) { tune.title.isEmpty ? fileName(player) : tune.title }
                    if !tune.author.isEmpty {
                        span(.class("author")) { tune.author }
                    }
                }
                p(.class("detail")) {
                    [tune.songs.count > 1 ? "song \(tune.song + 1) of \(tune.songs.count)" : "", tune.detail, tune.title.isEmpty ? "" : fileName(player)]
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                }
                if player.shows(.analyser) {
                    Analyser(bars: player.bars, caps: player.caps)
                }
                div(.class("time")) {
                    span { formatTime(player.position) }
                    // Pressing the bar moves to that place in the song. Behind the part played is the
                    // part that is ready to be moved to at once; the rest has to be waited for.
                    div(.class("seek")) {
                        div(.class("bar")) {
                            div(.class("ready"), .style(["width": "\(percent(player.rendered, of: tune.length))%"])) {}
                            div(.class(player.waiting ? "fill waiting" : "fill"), .style(["width": "\(percent(player.position, of: tune.length))%"])) {}
                        }
                        if let pointed = player.pointed {
                            div(.class("pointer"), .style(["left": "\(percent(pointed, of: 1))%"])) {
                                span { formatTime(pointed * tune.length) }
                            }
                        }
                    }
                    span { formatTime(tune.length) }
                }
                if tune.songs.count > 1 {
                    Songs(player: player, tune: tune)
                }
            } else if let problem = player.problem {
                p(.class("problem")) { "\(fileName(player)): \(problem)" }
            } else if player.current != nil {
                p(.class("detail")) { "Loading \(fileName(player))…" }
            } else {
                p(.class("detail")) { "Nothing is playing yet. Add some tunes." }
            }

            div(.class("controls")) {
                button(.title("Previous (p)")) { "⏮" }.onClick { player.previous() }
                button(.class("main"), .title("Pause or play (space)")) { player.paused || player.finished || player.tune == nil ? "▶" : "⏸" }
                    .onClick { player.togglePause() }
                button(.title("Next (n)")) { "⏭" }.onClick { player.next() }
                button(.class(player.shuffled ? "toggle on" : "toggle"), .title("Play in random order")) { "shuffle" }
                    .onClick { player.toggleShuffle() }
                // What the tune is heard through. Stereo spreads an AY chip's three channels; a SID
                // has one output, so for a SID tune those two are mono.
                // The two have no words beside them: what each is shows in its shape, and they stand
                // together at the far end, apart from the buttons that move through the tunes.
                select(
                    .class("output"), .custom(name: "aria-label", value: "Output"),
                    .title("What the tune is heard through: stereo is a module's own, or an AY chip's three channels spread out, and a television is an early-1980s set's speaker")
                ) {
                    ForEach(OutputStyle.allCases, key: { $0.rawValue }) { style in
                        option(.value(style.rawValue)) { style.title }
                            .attributes(.selected, when: style == player.output)
                    }
                }
                .onInput { event in
                    if let style = event.targetValue.flatMap({ OutputStyle(rawValue: $0) }) { player.hear(through: style) }
                }
                input(.type(.range), .min(0), .max(100), .class("volume"), .custom(name: "aria-label", value: "Volume"), .title("The player's own volume"))
                    .bindValue(#Binding(player.volume))
            }

            if !player.lights.isEmpty, player.shows(.lights) {
                Lights(levels: player.lights)
            }
        }
    }
}

/// A button for each part of the page that can be put away, in the player's top corner: lit while
/// its part is on the page, and only then. While there is nothing for a part to show, its button is
/// not lit and cannot be pressed. Each is a small picture of its part, which the stylesheet draws.
@View
struct Shown {
    var player: Player

    var body: some View {
        div(.class("views")) {
            ForEach(Part.allCases, key: { $0.rawValue }) { part in
                button(
                    .class(player.isShowing(part) ? "view \(part.rawValue) on" : "view \(part.rawValue)"),
                    .title(part.title), .custom(name: "aria-label", value: part.title),
                    .custom(name: "aria-pressed", value: player.isShowing(part) ? "true" : "false")
                ) {}
                    .attributes(.disabled, when: !player.has(part))
                    .onClick { player.toggle(part) }
            }
        }
    }
}

/// The picture to listen by, and under it what kind of picture it is, a button for other colours, and
/// one to fill the screen with it. The picture itself is painted elsewhere, many times a second: see
/// `Visualiser`, and `frame` in Browser.swift.
@View
struct Picture {
    var player: Player

    var body: some View {
        section(.class("visual")) {
            canvas(.class("picture")) {}
            div(.class("bar")) {
                select(.custom(name: "aria-label", value: "Picture"), .title("The kind of picture")) {
                    ForEach(Visualiser.Mode.allCases, key: { $0.rawValue }) { mode in
                        option(.value(mode.rawValue)) { mode.title }
                            .attributes(.selected, when: mode == player.picture)
                    }
                }
                .onInput { event in
                    if let mode = event.targetValue.flatMap({ Visualiser.Mode(rawValue: $0) }) { player.show(mode) }
                }
                button(.title("Other colours, come by chance")) { "shuffle colours" }
                    .onClick { player.shuffleColours() }
                button(.class("whole"), .title("Fill the screen with it, or put it back (f)")) { "full screen" }
                    .onClick { try? sidayFillScreen() }
            }
        }
    }
}

/// A spectrum analyser: a bar for each band of pitch, low notes on the left, each with a cap that
/// stays a moment where the bar last reached. The colours run through the rainbow, because they should.
@View
struct Analyser {
    var bars: [Double]
    var caps: [Double]

    var body: some View {
        div(.class("analyser")) {
            ForEach(Array(bars.indices), key: { String($0) }) { index in
                div(.class("band")) {
                    div(.class("bar"), .style(["background": colour(index), "transform": "scaleY(\(hundredths(bars[index])))"])) {}
                    div(.class("cap"), .style(["background": colour(index), "bottom": "\(hundredths(index < caps.count ? caps[index] : 0) * 100)%"])) {}
                }
            }
        }
    }

    /// Red for the lowest band, round to violet for the highest.
    private func colour(_ index: Int) -> String {
        "hsl(\(index * 290 / max(1, bars.count - 1)) 95% 58%)"
    }

    private func hundredths(_ value: Double) -> Double {
        Double(Int(max(0, min(1, value)) * 100)) / 100
    }
}

/// A row of lights, one for each voice of the tune: a chip's channels, a module's tracks. Each is the
/// lamp of an early-1980s tape recorder's recording level: the louder its voice, the brighter it
/// glows, and the wider.
@View
struct Lights {
    var levels: [Double]

    var body: some View {
        div(.class("lights")) {
            ForEach(Array(levels.indices), key: { String($0) }) { index in
                div(.class("light")) {
                    div(.class("glow"), .style(["opacity": "\(glow(levels[index]))", "transform": "scale(\(size(levels[index])))"])) {}
                }
            }
        }
    }

    /// A lamp at half its level is well under half as bright, so that a loud voice stands out from a
    /// quiet one and a note is seen to die away.
    private func glow(_ level: Double) -> Double {
        let level = max(0, min(1, level))
        return Double(Int(level * level.squareRoot() * 100)) / 100
    }

    /// The glow is as wide as the lamp when it is faint, and nearly twice that at its brightest.
    private func size(_ level: Double) -> Double {
        Double(Int((0.5 + 0.5 * max(0, min(1, level))) * 100)) / 100
    }
}

/// The songs of a tune that has several. Where the file names them they are listed; where it only
/// numbers them, the numbers are enough.
@View
struct Songs {
    var player: Player
    var tune: Tune

    var body: some View {
        if tune.namesSongs {
            ul(.class("songs")) {
                ForEach(Array(tune.songs.indices), key: { String($0) }) { index in
                    SongRow(player: player, index: index, song: tune.songs[index], playing: index == tune.song)
                }
            }
        } else {
            div(.class("songs numbered")) {
                ForEach(Array(tune.songs.indices), key: { String($0) }) { index in
                    SongButton(player: player, index: index, song: tune.songs[index], playing: index == tune.song)
                }
            }
        }
    }
}

@View
struct SongRow {
    var player: Player
    var index: Int
    var song: Tune.Song
    var playing: Bool

    var body: some View {
        li(.class(playing ? "current" : "")) {
            span(.class("number")) { "\(index + 1)" }
            span(.class("name")) { song.title.isEmpty ? "Song \(index + 1)" : song.title }
            span(.class("length")) { song.length.map { formatTime($0) } ?? "" }
        }
        .onClick { player.playSong(index) }
    }
}

@View
struct SongButton {
    var player: Player
    var index: Int
    var song: Tune.Song
    var playing: Bool

    var body: some View {
        button(.class(playing ? "song on" : "song"), .title("Song \(index + 1)")) {
            span { "\(index + 1)" }
            if let length = song.length {
                span(.class("length")) { formatTime(length) }
            }
        }
        .onClick { player.playSong(index) }
    }
}

@View
struct Playlist {
    var player: Player

    var body: some View {
        let rows = player.rows
        section(.class("list")) {
            div(.class("search")) {
                input(.type(.search), .placeholder("Search \(player.files.count) tunes"))
                    .bindValue(#Binding(player.search))
                if player.found != nil {
                    span(.class("hint")) { "\(player.listed) found" }
                }
                // All of them, whatever is being searched for.
                button(.title("Take every tune out of the list")) { "Remove all" }
                    .onClick { player.removeAll() }
            }
            // Every tune has its place in the list, which is as tall as all of them, but only the rows
            // that can be seen are there: the rest is empty space, filled in as it is scrolled to.
            div(.class("rows")) {
                div(.style(["height": "\(player.listed * Player.rowHeight)px"])) {
                    ul(.style(["transform": "translateY(\(rows.first * Player.rowHeight)px)"])) {
                        ForEach(rows.files, key: { String($0) }) { index in
                            Row(player: player, index: index)
                        }
                    }
                }
            }
        }
    }
}

@View
struct Row {
    var player: Player
    var index: Int

    var body: some View {
        // The cross is beside what is pressed to play the tune and not inside it, so that pressing the
        // one is not also pressing the other.
        li(.class(index == player.current ? "current" : "")) {
            div(.class("pick")) {
                span(.class("name")) { lastComponent(player.file(at: index)) }
                span(.class("folder")) { folder(player.file(at: index)) }
            }
            .onClick { player.play(index) }
            button(.class("remove"), .title("Take out of the list"), .custom(name: "aria-label", value: "Take out of the list")) { "×" }
                .onClick { player.remove(index) }
        }
    }
}

// MARK: Text

private func fileName(_ player: Player) -> String {
    player.current.map { lastComponent(player.file(at: $0)) } ?? ""
}

private func lastComponent(_ path: String) -> String {
    String(path.split(separator: "/").last ?? "")
}

private func folder(_ path: String) -> String {
    path.split(separator: "/").dropLast().joined(separator: "/")
}

private func formatTime(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    let rest = total % 60
    return "\(total / 60):\(rest < 10 ? "0" : "")\(rest)"
}

/// How far along, from 0 to 100, in tenths.
private func percent(_ value: Double, of whole: Double) -> Double {
    guard whole > 0 else { return 0 }
    return Double(Int(max(0, min(1, value / whole)) * 1000)) / 10
}
