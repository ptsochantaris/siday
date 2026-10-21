// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import SwiftUI

/// What is playing: the tune's details, where in it the song is, its songs, and the controls.
struct PlayerTab: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    NowPlaying()
                    Controls()
                    if let tune = model.tune, tune.songs.count > 1 {
                        Songs(tune: tune)
                    }
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Player")
        }
    }
}

struct NowPlaying: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tune = model.tune {
                Text(tune.format)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(tune.title.isEmpty ? model.fileName : tune.title)
                    .font(.title2.weight(.semibold))
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
                TimeLine(length: tune.length)
            } else if let problem = model.problem {
                Text("\(model.fileName): \(problem)")
            } else if model.current != nil {
                Text("Loading \(model.fileName)…")
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing is playing yet. Add some tunes in the playlist.")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Where in the song the sound is, and how long it is.
struct TimeLine: View {
    @Environment(PlayerModel.self) private var model
    let length: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: model.paused || model.finished)) { _ in
            let position = model.position
            HStack {
                Text(time(position)).monospacedDigit()
                Slider(value: Binding(get: { min(position, length) }, set: { model.seek(to: $0) }), in: 0 ... max(length, 0.1))
                    .accessibilityLabel("Position")
                    .accessibilityValue(Text("\(time(position)) of \(time(length))"))
                Text(time(length)).monospacedDigit()
            }
            .font(.callout)
        }
    }
}

func time(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

struct Controls: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 20) {
            Button("Previous", systemImage: "backward.fill") { model.previous() }
                .disabled(!model.hasPrevious)
            Button(model.paused || model.finished || model.tune == nil ? "Play" : "Pause",
                   systemImage: model.paused || model.finished || model.tune == nil ? "play.fill" : "pause.fill") { model.togglePause() }
                .font(.title)
            Button("Next", systemImage: "forward.fill") { model.next() }
                .disabled(!model.hasNext)
            Toggle("Shuffle", systemImage: "shuffle", isOn: Binding(get: { model.shuffled }, set: { _ in model.toggleShuffle() }))
                .toggleStyle(.button)
            Spacer()
            Picker("Output", selection: $model.output) {
                ForEach(PlayerModel.outputs, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
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
                .opacity(model.passesOver(index, of: tune) ? 0.5 : 1)
                .accessibilityAddTraits(index == tune.song ? .isSelected : [])
            }
        }
    }
}
