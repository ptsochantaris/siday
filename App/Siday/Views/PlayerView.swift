// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayPlayer
import SwiftUI

/// What is playing: the tune's details, the spectrum analyser, where in it the song is, its songs, a
/// light for each voice, and the picture to listen by; and at its foot, the controls. Before a tune is
/// chosen, only the app's logo: what to do first is said in the playlist.
struct PlayerView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.oneAtATime) private var oneAtATime

    /// Whether what is slid over the player is a panel beside it: not on an iPhone, where it is a
    /// sheet from below.
    private var beside: Bool { !oneAtATime }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.current == nil {
                Logo(size: 160)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TimelineView(.animation(minimumInterval: 1 / 60, paused: !model.hasTune)) { timeline in
                            let frame = model.frame(at: timeline.date.timeIntervalSinceReferenceDate)
                            NowPlaying(frame: frame)
                        }
                        if model.hasTune, model.shows(.picture) {
                            PictureSection()
                        }
                    }
                    .padding()
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    PlayerBar()
                }
            }
        }
        .takesDroppedTunes(model)
        #if os(iOS)
        // (Over the playlist, its back button shows the playlist's sign, and is a back button still.)
        .background {
            if oneAtATime { PlaylistBackSign().frame(width: 0, height: 0).accessibilityHidden(true) }
        }
        #endif
        .navigationTitle("Siday")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem { SettingsButton() }
            #endif
            if model.current != nil {
                ToolbarItem {
                    Menu {
                        ForEach(Part.allCases) { part in
                            Toggle(part.title, systemImage: part.symbol, isOn: Binding(get: { model.shows(part) }, set: { _ in model.toggle(part) }))
                        }
                    } label: {
                        Label("Show", systemImage: "eye")
                    }
                }
            }
        }
        .inspector(isPresented: Binding(get: { beside && model.slideOver != nil }, set: { if !$0 { model.slideOver = nil } })) {
            // (Made only while it is showing: its Close button would otherwise be put in the
            // player's bar.)
            if beside, model.slideOver != nil {
                SlideOverView()
                    .inspectorColumnWidth(min: 280, ideal: 380, max: 560)
            }
        }
        .sheet(isPresented: Binding(get: { !beside && model.slideOver != nil }, set: { if !$0 { model.slideOver = nil } })) {
            // (A sheet is put away by sliding it down or pressing beside it: it needs no button.)
            SlideOverView(closable: false)
        }
    }
}

/// What is slid over the player: a format's story, or what is not played as the tune's file asks.
struct SlideOverView: View {
    @Environment(PlayerModel.self) private var model
    /// Whether it has a button to put it away: a panel beside the player has, a sheet has not.
    var closable = true

    var body: some View {
        NavigationStack {
            Group {
                switch model.slideOver {
                case .story(let chapter):
                    StoryView(chapter: chapter)
                case .shortfalls:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(Tune.shortfallHeading).font(.headline)
                            ForEach(model.tune?.shortfalls ?? [], id: \.self) { Text($0) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                    }
                case nil:
                    EmptyView()
                }
            }
            #if os(iOS)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if closable {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { model.slideOver = nil }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            #else
            // (On a Mac the window's toolbar is the window's: the panel has its own heading and button.)
            .safeAreaInset(edge: .top) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button("Close", systemImage: "xmark") { model.slideOver = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            #endif
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch model.slideOver {
        case .story: String(localized: "About This Format")
        case .shortfalls: String(localized: "Not Quite as Written")
        case nil: ""
        }
    }
}

struct NowPlaying: View {
    @Environment(PlayerModel.self) private var model
    let frame: Frame

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tune = model.tune {
                Details(tune: tune)
                if model.shows(.analyser) {
                    Analyser(bars: frame.bars, caps: frame.caps)
                }
                TimeBar(position: frame.position, rendered: model.rendered, length: tune.length)
                    .padding(.top, 6)
                // (Between where the song is and the controls, as the web player has them; and drawn
                // again only when they change, not with every frame of what is heard.)
                if tune.songs.count > 1 {
                    Songs(tune: tune)
                        .equatable()
                        .padding(.vertical, 4)
                }
            } else if let problem = model.problem {
                Text("\(model.fileName): \(problem)")
            } else {
                Text("Loading \(model.fileName)…")
                    .foregroundStyle(.secondary)
            }
            if model.hasTune, !frame.lights.isEmpty, model.shows(.lights) || model.shows(.waves) {
                Lights(frame: frame, lamps: model.shows(.lights), scopes: model.shows(.waves))
                    .padding(.top, 4)
                    .disabled(model.remaking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The tune's format, which is a button that tells the format's story; its title, author and details;
/// and a mark, for a tune that is not played quite as its file asks, which says why.
struct Details: View {
    @Environment(PlayerModel.self) private var model
    let tune: Tune

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let chapter = model.chapter {
                Button {
                    model.slideOver = .story(chapter)
                } label: {
                    Label(tune.format, systemImage: "book")
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .font(.subheadline.weight(.semibold))
                .help("About this format")
                .accessibilityHint("Tells the format's story.")
            } else {
                Text(tune.format).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(tune.title.isEmpty ? model.fileName : tune.title)
                    .font(.title2.weight(.semibold))
                    // (A file's name read out as words: its kind and underscores left out.)
                    .accessibilityLabel(Text(tune.title.isEmpty ? spoken(model.fileName) : tune.title))
                if !tune.shortfalls.isEmpty {
                    Button {
                        model.slideOver = .shortfalls
                    } label: {
                        Label(Tune.shortfallHeading, systemImage: "exclamationmark.triangle")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("\(Tune.shortfallHeading) \(tune.shortfalls.joined(separator: " "))")
                }
            }
            if !tune.author.isEmpty {
                Text(tune.author)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text([tune.songs.count > 1 ? String(localized: "song \(tune.song + 1) of \(tune.songs.count)") : "", tune.detail, tune.title.isEmpty ? "" : model.fileName]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let note = model.note {
                Text(note).font(.subheadline)
            }
        }
    }
}

/// Previous, play and next; and, unless it is elsewhere, shuffle.
struct Controls: View {
    @Environment(PlayerModel.self) private var model
    var shuffle = true

    private var playing: Bool { !(model.paused || model.finished || model.tune == nil) }

    var body: some View {
        HStack(spacing: 8) {
            Button { model.previous() } label: { Control.label("Previous", "backward.fill") }
                .disabled(!model.hasPrevious)
            Button { model.togglePause() } label: { Control.label(playing ? "Pause" : "Play", playing ? "pause.fill" : "play.fill") }
                .font(.title)
                .contentTransition(.symbolEffect(.replace))
                .disabled(model.tune == nil)
            Button { model.next() } label: { Control.label("Next", "forward.fill") }
                .disabled(!model.hasNext)
            if shuffle { Shuffle() }
        }
        .buttonStyle(.borderless)
    }
}

/// Shuffle, in the tint while it is on: on a Mac a borderless button shows no other difference. (While
/// it is off it is left as the other controls are: greyed, it would look as if it could not be pressed.)
struct Shuffle: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Toggle(isOn: Binding(get: { model.shuffled }, set: { _ in model.toggleShuffle() })) {
            if model.shuffled {
                Control.label("Shuffle", "shuffle").foregroundStyle(.tint)
            } else {
                Control.label("Shuffle", "shuffle")
            }
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
    }
}

/// A file's name as it is to be read out: without its ending, and with spaces for underscores.
func spoken(_ name: String) -> String {
    let stem = (name as NSString).deletingPathExtension
    return (stem.isEmpty ? name : stem).replacingOccurrences(of: "_", with: " ")
}

/// A control's picture, with its name for those who cannot see it, and room enough to be pressed.
enum Control {
    static func label(_ title: LocalizedStringKey, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

/// The songs of a tune that has several: listed by name where the file names them, numbered where not.
struct Songs: View, Equatable {
    @Environment(PlayerModel.self) private var model
    let tune: Tune

    static func == (one: Songs, other: Songs) -> Bool { one.tune == other.tune }

    /// How narrow a song's button may be: one that is named, and one that is only numbered, room
    /// enough for a number and a time on one line, at any size of text.
    @ScaledMetric(relativeTo: .body) private var named = 220
    @ScaledMetric(relativeTo: .body) private var numbered = 88

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tune.namesSongs ? named : numbered), spacing: 8)], spacing: 8) {
            ForEach(tune.songs.indices, id: \.self) { index in
                let song = tune.songs[index]
                let passed = model.passesOver(index, of: tune)
                Button {
                    model.playSong(index)
                } label: {
                    HStack {
                        Text(tune.namesSongs ? (song.title.isEmpty ? String(localized: "Song \(index + 1)") : "\(index + 1). \(song.title)") : "\(index + 1)")
                            .lineLimit(1)
                        if let length = song.length {
                            Spacer(minLength: 4)
                            Text(time(length)).monospacedDigit().foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        } else if song.pending {
                            // (Still being played through, unheard, to find how long it is.)
                            Spacer(minLength: 4)
                            Text(verbatim: "?").foregroundStyle(.secondary)
                                .help("Its length is still being found")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(index == tune.song ? .accentColor : nil)
                .opacity(passed ? 0.5 : 1)
                .help(passed ? "Passed over when the songs are played in turn: see the settings" : "")
                .accessibilityLabel(Text(song.title.isEmpty ? String(localized: "Song \(index + 1)") : song.title))
                .accessibilityValue(song.pending ? Text("Length not yet known") : Text(song.length.map { time($0) } ?? ""))
                .accessibilityAddTraits(index == tune.song ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Songs")
    }
}

/// The picture to listen by, the kind of picture it is, and a button to fill the screen with it.
struct PictureSection: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 8) {
            Picture(painting: !model.pictureFillsScreen)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
                .onTapGesture(count: 2) { model.pictureFillsScreen = true }
            HStack {
                Picker("Picture", selection: $model.picture) {
                    ForEach(Visualiser.Mode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .fixedSize()
                Spacer()
                Button("Fill the Screen", systemImage: "arrow.up.left.and.arrow.down.right") { model.pictureFillsScreen = true }
            }
        }
    }
}

/// The picture on the whole screen, until it is put back.
struct WholeScreenPicture: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Picture()
            .ignoresSafeArea()
            .onTapGesture { model.pictureFillsScreen = false }
            .overlay(alignment: .topTrailing) {
                Button("Put Back", systemImage: "arrow.down.right.and.arrow.up.left") { model.pictureFillsScreen = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                    .padding()
            }
    }
}

/// The bar at the foot of the player, within reach of a thumb: the controls, with what the tune is
/// heard through on their left and how loud on their right; or, where there is not room for all three
/// in a line (an iPhone, or an iPad mini beside its playlist), the controls above the other two, with
/// shuffle between them.
struct PlayerBar: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(speakers: true)
            // (Narrow enough for an iPad's player beside its playlist: the volume's speakers give way.)
            line(speakers: false)
            // (Shuffle goes below, out of the way of a thumb on play, and the three above are centred.)
            VStack(spacing: 4) {
                Controls(shuffle: false)
                HStack(spacing: 8) {
                    output
                    Spacer(minLength: 0)
                    Shuffle()
                    Spacer(minLength: 0)
                    volume(speakers: true)
                        .frame(maxWidth: 220)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var output: some View {
        @Bindable var model = model
        return Picker("Output", selection: $model.output) {
            ForEach(PlayerModel.outputs, id: \.self) { style in
                Text(style.title).tag(style)
            }
        }
        // (What is chosen, "Stereo", says what it is a choice of: no name beside it.)
        .labelsHidden()
        .fixedSize()
        .disabled(model.remaking)
        .help("What the tune is heard through: stereo is a module's own, or an AY chip's three channels spread out (which way round is in the settings), and a television is an early-1980s set's speaker")
    }

    /// All three in a line, the controls in the middle.
    private func line(speakers: Bool) -> some View {
        HStack(spacing: 12) {
            output
                .frame(maxWidth: .infinity, alignment: .leading)
            Controls()
            volume(speakers: speakers)
                .frame(minWidth: speakers ? 160 : 100, maxWidth: 220)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func volume(speakers: Bool) -> some View {
        @Bindable var model = model
        return Slider(value: $model.volume, in: 0 ... 1) {
            Text("Volume")
        } minimumValueLabel: {
            if speakers { Image(systemName: "speaker.fill").accessibilityHidden(true) }
        } maximumValueLabel: {
            if speakers { Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true) }
        }
        // (The speakers at its ends say what it is: no name beside it, as the output has none.)
        .labelsHidden()
        .foregroundStyle(.secondary)
    }
}

#if os(iOS)
/// Gives the back button of the screen it is in the playlist's sign in place of the arrow, on an
/// iPhone, where the player is over the playlist. SwiftUI has no way to say so, so it is said to the
/// screen's UIKit navigation item: for that screen only, and only its sign, so that the button is
/// the system's own still, and swiping from the edge still goes back. Should SwiftUI ever build its
/// screens otherwise, it finds nothing to change, and the arrow stays.
private struct PlaylistBackSign: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Finder { Finder() }
    func updateUIViewController(_ finder: Finder, context: Context) {}

    final class Finder: UIViewController {
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            mark()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            mark()
        }

        private func mark() {
            // The screen this is in: the one the navigation controller holds.
            var screen: UIViewController? = self
            while let place = screen, let parent = place.parent, !(parent is UINavigationController) { screen = parent }
            guard let screen, let bar = screen.navigationController?.navigationBar,
                  let sign = UIImage(systemName: "music.note.list") else { return }
            let item = screen.navigationItem
            func signed(_ appearance: UINavigationBarAppearance?) -> UINavigationBarAppearance? {
                guard let appearance = appearance?.copy() else { return nil }
                appearance.setBackIndicatorImage(sign, transitionMaskImage: sign)
                return appearance
            }
            item.standardAppearance = signed(item.standardAppearance ?? bar.standardAppearance)
            item.compactAppearance = signed(item.compactAppearance ?? bar.compactAppearance)
            item.scrollEdgeAppearance = signed(item.scrollEdgeAppearance ?? bar.scrollEdgeAppearance)
            item.compactScrollEdgeAppearance = signed(item.compactScrollEdgeAppearance ?? bar.compactScrollEdgeAppearance)
        }
    }
}
#endif
