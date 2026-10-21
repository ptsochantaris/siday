// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import SwiftUI

/// What is playing: the tune's details, the spectrum analyser, where in it the song is, the controls,
/// a light for each voice, its songs, and the picture to listen by.
struct PlayerTab: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: !model.hasTune)) { timeline in
                        let frame = model.frame(at: timeline.date.timeIntervalSinceReferenceDate)
                        NowPlaying(frame: frame)
                    }
                    if let tune = model.tune, tune.songs.count > 1 {
                        Songs(tune: tune)
                    }
                    if model.hasTune, model.shows(.picture) {
                        PictureSection()
                    }
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Player")
            .toolbar {
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
            .inspector(isPresented: Binding(get: { model.slideOver != nil }, set: { if !$0 { model.slideOver = nil } })) {
                SlideOverView()
                    .inspectorColumnWidth(min: 280, ideal: 380, max: 560)
            }
        }
    }
}

/// What is slid over the player: a format's story, or what is not played as the tune's file asks.
struct SlideOverView: View {
    @Environment(PlayerModel.self) private var model

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
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { model.slideOver = nil }
                        .keyboardShortcut(.cancelAction)
                }
            }
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
            } else if let problem = model.problem {
                Text("\(model.fileName): \(problem)")
            } else if model.current != nil {
                Text("Loading \(model.fileName)…")
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing is playing yet. Add some tunes in the playlist.")
                    .foregroundStyle(.secondary)
            }
            Controls()
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
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .help("About this format")
                .accessibilityHint("Tells the format's story.")
            } else {
                Text(tune.format).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(tune.title.isEmpty ? model.fileName : tune.title)
                    .font(.title2.weight(.semibold))
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

struct Controls: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                transport
                Spacer()
                output
                volume.frame(maxWidth: 160)
            }
            VStack(alignment: .leading, spacing: 12) {
                transport
                HStack {
                    output
                    volume
                }
            }
        }
    }

    private var playing: Bool { !(model.paused || model.finished || model.tune == nil) }

    private var transport: some View {
        HStack(spacing: 20) {
            Button("Previous", systemImage: "backward.fill") { model.previous() }
                .disabled(!model.hasPrevious)
            Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") { model.togglePause() }
                .font(.title)
                .contentTransition(.symbolEffect(.replace))
            Button("Next", systemImage: "forward.fill") { model.next() }
                .disabled(!model.hasNext)
            Toggle("Shuffle", systemImage: "shuffle", isOn: Binding(get: { model.shuffled }, set: { _ in model.toggleShuffle() }))
                .toggleStyle(.button)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private var output: some View {
        @Bindable var model = model
        return Picker("Output", selection: $model.output) {
            ForEach(PlayerModel.outputs, id: \.self) { style in
                Text(style.title).tag(style)
            }
        }
        .fixedSize()
        .disabled(model.remaking)
        .help("What the tune is heard through: stereo is a module's own, or an AY chip's three channels spread out (which way round is in the settings), and a television is an early-1980s set's speaker")
    }

    private var volume: some View {
        @Bindable var model = model
        return Slider(value: $model.volume, in: 0 ... 1) {
            Text("Volume")
        } minimumValueLabel: {
            Image(systemName: "speaker.fill").accessibilityHidden(true)
        } maximumValueLabel: {
            Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
        }
        .foregroundStyle(.secondary)
    }
}

/// The songs of a tune that has several: listed by name where the file names them, numbered where not.
struct Songs: View {
    @Environment(PlayerModel.self) private var model
    let tune: Tune

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: tune.namesSongs ? 220 : 64), spacing: 8)], spacing: 8) {
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
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(index == tune.song ? .accentColor : nil)
                .opacity(passed ? 0.5 : 1)
                .help(passed ? "Passed over when the songs are played in turn: see the settings" : "")
                .accessibilityLabel(Text(song.title.isEmpty ? String(localized: "Song \(index + 1)") : song.title))
                .accessibilityValue(Text(song.length.map { time($0) } ?? ""))
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
            Picture()
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
