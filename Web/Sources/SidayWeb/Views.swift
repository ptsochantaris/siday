// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import ElementaryUI
import SidayPlayer

@View
struct PlayerView {
    @State var player = Player()

    var body: some View {
        div(.class("page")) {
            header {
                h1 { "siday" }
                p(.class("tagline")) { "Chip music and modules from the ZX Spectrum, Amstrad CPC, Atari ST, 8-bit Ataris, Commodore 64, Amiga and PC, played in your browser." }
            }

            NowPlaying(player: player)

            // A playlist was added, and tunes it names were not there to be found; or a tune could not
            // be played, for a file it needs beside its own was not. Being shown the folder they are
            // in is all the page needs: it looks in it for them, and adds nothing else.
            if let notice = player.notice {
                div(.class("notice")) {
                    p { notice }
                    button(.title("The folder is only looked in: nothing is added but what was not found")) { player.noticeButton }
                        .onClick { player.chooseTunes() }
                }
            }

            if player.settingsShown {
                SettingsPanel(player: player)
            }

            if player.isShowing(.picture) {
                Picture(player: player)
            }

            if player.isShowing(.list) {
                Playlist(player: player)
            }

            footer {
                p { "Keys: space pause · n or → next · p or ← previous · + and − song · f picture on the whole screen" }
                p {
                    "Supports: "
                    TuneFormat.allCases.map { $0.rawValue.uppercased() }.joined(separator: ", ")
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
                // Beside its details, the picture of the chip it is heard as made by.
                div(.class("heading")) {
                    if let chip = tune.chips.first {
                        img(.class("chip"), .src("generated/chips/\(chip.rawValue)-small.jpg"), .alt(chipName(chip)), .title(chipName(chip)))
                    }
                    div(.class("details")) {
                        div(.class("what")) {
                            // The format's name is a button: pressed, it tells the format's story, as
                            // FORMATS.md has it.
                            if let chapter = player.chapter {
                                button(.class("format"), .title("About this format")) { tune.format }
                                    .onClick { try? sidayAbout(chapter) }
                            } else {
                                span(.class("format")) { tune.format }
                            }
                            span(.class("title")) { tune.title.isEmpty ? fileName(player) : tune.title }
                            if !tune.author.isEmpty {
                                span(.class("author")) { tune.author }
                            }
                            // A tune that is not played quite as its file asks has a small mark beside its
                            // name, which says why when the pointer rests on it, and when it is pressed
                            // writes it out under the details.
                            if !tune.shortfalls.isEmpty {
                                ShortfallMark(player: player, why: tune.shortfalls.joined(separator: " "))
                            }
                        }
                        p(.class("detail")) {
                            [tune.songs.count > 1 ? "song \(tune.song + 1) of \(tune.songs.count)" : "", tune.detail, tune.title.isEmpty ? "" : fileName(player)]
                                .filter { !$0.isEmpty }.joined(separator: " · ")
                        }
                        // What the playlist the tune came by says about it.
                        if let note = player.note {
                            p(.class("note")) { note }
                        }
                    }
                }
                if !tune.shortfalls.isEmpty, player.shortfallsShown {
                    p(.class("shortfalls")) {
                        ForEach(Array(tune.shortfalls.indices), key: { String($0) }) { index in
                            span { tune.shortfalls[index] }
                        }
                    }
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
                // (The buttons that add tunes are in the list, which may have been put away.)
                p(.class("detail")) { player.shows(.list) ? "Nothing is playing yet. Add some tunes." : "Nothing is playing yet. Drop some tunes on the page, or bring back the list to add them." }
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
                    .title("What the tune is heard through: stereo is a module's own, or an AY chip's three channels spread out (which way round is in the settings), and a television is an early-1980s set's speaker")
                ) {
                    ForEach(Player.outputs, key: { $0.rawValue }) { style in
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

            if !player.lights.isEmpty, player.shows(.lights) || player.shows(.waves) {
                Lights(levels: player.lights, sampled: player.sampled, muted: player.muted, lamps: player.shows(.lights), scopes: player.shows(.waves))
            }
        }
    }
}

/// The mark beside the name of a tune that is not played quite as its file asks: a quiet one, since
/// most such tunes sound very nearly as they should. It is a button: what is wrong is its tooltip,
/// and pressing it writes that out under the tune's details, or puts it away again.
@View
struct ShortfallMark {
    var player: Player
    var why: String

    var body: some View {
        button(
            .class(player.shortfallsShown ? "shortfall on" : "shortfall"),
            .title("\(Tune.shortfallHeading) \(why)"), .custom(name: "aria-label", value: "\(Tune.shortfallHeading) \(why)"),
            .custom(name: "aria-expanded", value: player.shortfallsShown ? "true" : "false")
        ) { "≈" }
            .onClick { player.toggleShortfalls() }
    }
}

/// A button for each part of the page that can be put away, in the player's top corner: lit while
/// its part is on the page, and only then. While there is nothing for a part to show, its button is
/// not lit and cannot be pressed. (The list of tunes always has something to show: with no tunes in
/// it, how to add them.) Each is a small picture of its part, which the stylesheet draws.
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
            // And one for the settings, which are always there to be opened.
            button(
                .class(player.settingsShown ? "view settings on" : "view settings"),
                .title("Settings"), .custom(name: "aria-label", value: "Settings"),
                .custom(name: "aria-pressed", value: player.settingsShown ? "true" : "false")
            ) {}
                .onClick { player.toggleSettings() }
        }
    }
}

/// The listener's settings: the command-line player's options, in groups, each with what it does
/// to be read by resting the pointer on it. One that has been changed is marked. They are remembered
/// from one visit to the next, and a button puts them all back as they come.
@View
struct SettingsPanel {
    var player: Player

    var body: some View {
        section(.class("settings")) {
            // (Made anew when the settings are put back: see `Player.settingsRound`.)
            ForEach(Setting.Group.allCases, key: { "\($0.rawValue) \(player.settingsRound)" }) { group in
                div(.class("group")) {
                    h2 { group.title }
                    ForEach(group.settings, key: { $0.name }) { setting in
                        SettingRow(player: player, setting: setting)
                    }
                }
            }
            div(.class("bar")) {
                span(.class("hint")) { "Rest the pointer on a setting to read what it does. They are kept for your next visit." }
                button(.title("Put every setting back as it comes")) { "Reset to defaults" }
                    .attributes(.disabled, when: player.settingsAreStandard)
                    .onClick { player.resetSettings() }
            }
        }
    }
}

@View
struct SettingRow {
    var player: Player
    var setting: Setting

    var body: some View {
        let value = player.value(of: setting)
        label(.class(value == setting.standard ? "setting" : "setting changed"), .title(setting.about)) {
            span(.class("name")) { setting.title }
            if case .choice(let choices) = setting.kind {
                select {
                    ForEach(Array(choices.indices), key: { String($0) }) { index in
                        option(.value(String(index))) { choices[index].title }
                            .attributes(.selected, when: index == Int(value))
                    }
                }
                .onInput { event in
                    if let place = event.targetValue.flatMap({ Int($0) }) { player.set(setting, to: Double(place)) }
                }
            } else if case .scale(let low, let high) = setting.kind {
                span(.class("scale")) {
                    span(.class("end")) { low }
                    input(.type(.range), .min(0), .max(100))
                        .bindValue(Binding(get: { player.value(of: setting) }, set: { player.set(setting, to: $0 ?? setting.standard) }))
                    span(.class("end")) { high }
                }
            }
        }
    }
}

/// The picture to listen by, and under it what kind of picture it is and a button to fill the screen
/// with it. The picture itself is painted elsewhere, many times a second: see
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
/// glows, and the wider. And each is a button: pressed, it mutes its voice or brings it back; with
/// a right click, or held, it has its voice heard alone. (The presses are seen to in `Web/siday.js`,
/// which knows a held press from a short one; here a light is only shown as it stands.)
/// What a voice plays, as its light shows it.
enum VoiceKind: Equatable {
    /// A sound a chip makes of itself: a square wave, an FM voice, a waveform drawn in a tracker.
    case chip
    /// A recording of a sound.
    case sample
    /// The clicks of a loudspeaker that the computer's own code moves in and out: a beeper.
    case speaker
}

@View
struct Lights {
    var levels: [Double]
    /// What each voice is playing: a sample's light is blue, the computer's own loudspeaker's
    /// pink, and a chip's red.
    var sampled: [VoiceKind]
    /// Which the listener has muted: their lights are dimmed and have most of their colour taken
    /// out, and still flicker with what the voice is playing.
    var muted: [Bool]
    /// Whether the lamps are shown, and whether each voice has a scope of its wave under its lamp,
    /// as FastTracker 2 had a scope of each channel above its patterns. With scopes the voices are a grid, of rows of up to
    /// eight (four on a narrow screen), as even as they can be; the scopes are drawn by `Web/siday.js`.
    var lamps = true
    var scopes = false

    var body: some View {
        div(.class(scopes ? "lights scoped" : "lights"), .style(scopes ? ["--across": "\(Self.across(levels.count, 8))", "--across-narrow": "\(Self.across(levels.count, 4))"] : [:])) {
            ForEach(Array(levels.indices), key: { String($0) }) { index in
                div(.class(name(index)), .title("Click to mute this voice or bring it back. Right-click, or press and hold, to hear it alone."),
                    .custom(name: "role", value: "button"), .custom(name: "tabindex", value: "0"),
                    .custom(name: "aria-label", value: "Voice \(index + 1)"), .custom(name: "aria-pressed", value: isMuted(index) ? "true" : "false")) {
                    if scopes { canvas(.class("scope")) {} }
                    if lamps {
                        div(.class("glow"), .style(["opacity": "\(glow(levels[index]))", "transform": "scale(\(size(levels[index])))"])) {}
                    }
                }
            }
        }
    }

    /// How many voices to a row, for rows of at most `most`, the rows as nearly the same as can be.
    private static func across(_ count: Int, _ most: Int) -> Int {
        let rows = max(1, (count + most - 1) / most)
        return max(1, (count + rows - 1) / rows)
    }

    private func isMuted(_ index: Int) -> Bool { index < muted.count && muted[index] }

    private func name(_ index: Int) -> String {
        let kind = index < sampled.count ? sampled[index] : .chip
        return "light" + (kind == .sample ? " sampled" : kind == .speaker ? " speaker" : "") + (isMuted(index) ? " muted" : "") + (lamps ? "" : " unlit")
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
                    SongRow(player: player, index: index, song: tune.songs[index], playing: index == tune.song, passed: player.passesOver(index, of: tune))
                }
            }
        } else {
            div(.class("songs numbered")) {
                ForEach(Array(tune.songs.indices), key: { String($0) }) { index in
                    SongButton(player: player, index: index, song: tune.songs[index], playing: index == tune.song, passed: player.passesOver(index, of: tune))
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
    /// True if it is passed over when the tune's songs are played in turn. It is fainter, and can be played by pressing it.
    var passed: Bool

    var body: some View {
        li(.class(playing ? "current" : passed ? "passed" : ""), .title(passed ? "Passed over when the songs are played in turn: see the settings" : "")) {
            span(.class("number")) { "\(index + 1)" }
            span(.class("name")) { song.title.isEmpty ? "Song \(index + 1)" : song.title }
            // (A question mark while it is still being played through, unheard, to find how long it is.)
            span(.class("length")) { song.pending ? "?" : song.length.map { formatTime($0) } ?? "" }
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
    var passed: Bool

    var body: some View {
        button(
            .class(playing ? "song on" : passed ? "song passed" : "song"),
            .title(passed ? "Song \(index + 1): passed over when the songs are played in turn (see the settings)" : "Song \(index + 1)")
        ) {
            span { "\(index + 1)" }
            if song.pending {
                span(.class("length")) { "?" }
            } else if let length = song.length {
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
            if player.files.isEmpty {
                // With no tunes in it yet, the list says how they are put there.
                p(.class("empty")) { "Drop tunes, a whole folder of them, or a playlist with its tunes, anywhere on the page, or add them with the buttons below. They stay on your computer." }
            } else {
                div(.class("search")) {
                    // (What is typed is part of a file's name, which nothing is to put right.)
                    input(.type(.search), .placeholder(player.files.count == 1 ? "Search 1 tune" : "Search \(grouped(player.files.count)) tunes"),
                          .custom(name: "autocorrect", value: "off"), .custom(name: "autocapitalize", value: "off"),
                          .custom(name: "autocomplete", value: "off"), .custom(name: "spellcheck", value: "false"))
                        .bindValue(#Binding(player.search))
                    if player.found != nil {
                        span(.class("hint")) { "\(grouped(player.listed)) found" }
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
                // (A row dragged and let go anywhere but on a row goes nowhere.)
                .onMouseUp { _ in player.dropped() }
            }
            div(.class("add")) {
                button { "Add files…" }.onClick { try? sidayChoose(false) }
                button { "Add a folder…" }.onClick { try? sidayChoose(true) }
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
        // A row says its place, for what is dropped on it from outside the page (see siday.js). Dragged
        // to another, it is dimmed, and the row it is over shows where it would go.
        li(.class(classes), .custom(name: "data-index", value: "\(index)")) {
            // The chip its tune is heard as made by, or most likely is.
            if let chip = player.chip(ofFile: index) {
                img(.class("chip"), .src("generated/chips/\(chip.rawValue)-small.jpg"), .alt(""))
                    .onClick { player.play(index) }
            }
            div(.class("pick")) {
                span(.class("name")) { lastComponent(player.file(at: index)) }
                span(.class("folder")) { folder(player.file(at: index)) }
            }
            .onClick { player.play(index) }
            // A tune that has been played, and was not played quite as its file asks, keeps a mark
            // that says why.
            if let why = player.shortfalls(ofFile: index) {
                span(.class("shortfall"), .title("\(Tune.shortfallHeading) \(why)"), .custom(name: "aria-label", value: "\(Tune.shortfallHeading) \(why)"),
                     .custom(name: "role", value: "img")) { "≈" }
            }
            button(.class("remove"), .title("Take out of the list"), .custom(name: "aria-label", value: "Take out of the list")) { "×" }
                .onClick { player.remove(index) }
        }
        .onMouseDown { event in if event.button == 0 { player.pressed(index) } }
        .onMouseMove { event in player.draggedOver(index, buttons: event.buttons) }
        .onMouseUp { _ in player.dropped(over: index) }
    }

    private var classes: String {
        var classes: [String] = []
        if index == player.current { classes.append("current") }
        if let from = player.dragged, player.dragTarget != nil {
            if index == from { classes.append("dragged") }
            if index == player.dragTarget, index != from { classes.append(index > from ? "drop-after" : "drop-before") }
        }
        return classes.joined(separator: " ")
    }
}

// MARK: Text

/// A chip as it is known, for those who cannot see its picture.
private func chipName(_ chip: SoundChip) -> String {
    switch chip {
    case .sid6581: "The SID chip, MOS 6581"
    case .sid8580: "The SID chip, CSG 8580"
    case .ay8912: "The AY chip, AY-3-8912"
    case .ay8910: "The AY chip, AY-3-8910"
    case .ym2149: "The YM chip, YM2149"
    case .ula: "The ZX Spectrum's ULA, which drove its beeper"
    case .pokey: "The POKEY chip"
    case .paula: "The Amiga's Paula chip"
    case .opl2: "The OPL2 FM chip, YM3812"
    case .opl3: "The OPL3 FM chip, YMF262"
    case .saa1099: "The SAA1099 chip"
    case .sn76489: "The SN76489 chip"
    case .gf1: "The Gravis Ultrasound's GF1 chip"
    case .sbPro: "The Sound Blaster Pro's DSP"
    case .dac: "A recording, played through a digital-to-analogue converter"
    }
}

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

/// A count as it is easiest read: in threes, with commas between them (165,139).
func grouped(_ count: Int) -> String {
    // (By bytes: a digit is one.)
    let digits = Array(String(count.magnitude).utf8)
    var text: [UInt8] = count < 0 ? [UInt8(ascii: "-")] : []
    for (place, digit) in digits.enumerated() {
        if place > 0, (digits.count - place) % 3 == 0 { text.append(UInt8(ascii: ",")) }
        text.append(digit)
    }
    return String(decoding: text, as: UTF8.self)
}
