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
                p(.class("tagline")) { "Chip music from the ZX Spectrum, Amstrad CPC and Commodore 64, played in your browser." }
            }

            NowPlaying(player: player)

            div(.class("add")) {
                button { "Add files…" }.onClick { try? sidayChoose(false) }
                button { "Add a folder…" }.onClick { try? sidayChoose(true) }
                span(.class("hint")) { "or drop them anywhere on the page. They stay on your computer." }
            }

            if !player.files.isEmpty {
                Playlist(player: player)
            }

            footer {
                p { "Keys: space pause · n or → next · p or ← previous · + and − song · t television" }
                p {
                    "Plays "
                    TuneFormat.allCases.map { $0.rawValue.uppercased() }.joined(separator: ", ")
                    " files. A Songlengths.md5 from the High Voltage SID Collection, added like a tune, gives SID tunes their lengths."
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
                Analyser(bars: player.bars, caps: player.caps)
                div(.class("time")) {
                    span { formatTime(player.position) }
                    div(.class("bar")) {
                        div(.class("fill"), .style(["width": "\(percent(player.position, of: tune.length))%"])) {}
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
                button(.class(player.television == nil ? "toggle" : "toggle on"), .title("Play through an early-1980s television (t)")) {
                    "tv: \(player.television?.rawValue ?? "off")"
                }
                .onClick { player.cycleTelevision() }
                button(.class(player.shuffled ? "toggle on" : "toggle"), .title("Play in random order")) { "shuffle" }
                    .onClick { player.toggleShuffle() }
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
        let visible = player.visible
        section(.class("list")) {
            div(.class("search")) {
                input(.type(.search), .placeholder("Search \(player.files.count) tunes"))
                    .bindValue(#Binding(player.search))
                if visible.rows.count < visible.total {
                    span(.class("hint")) { "showing \(visible.rows.count) of \(visible.total)" }
                }
            }
            ul {
                ForEach(visible.rows, key: { String($0) }) { index in
                    Row(player: player, index: index)
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
        li(.class(index == player.current ? "current" : "")) {
            span(.class("name")) { lastComponent(player.files[index]) }
            span(.class("folder")) { folder(player.files[index]) }
        }
        .onClick { player.play(index) }
    }
}

// MARK: Text

private func fileName(_ player: Player) -> String {
    player.current.map { lastComponent(player.files[$0]) } ?? ""
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
