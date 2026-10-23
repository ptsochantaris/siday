// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayPlayer
import SwiftUI
import UniformTypeIdentifiers

/// The list of tunes: searched, played from, taken out of, and added to. Beside the player, or on an
/// iPhone under it, with a bar at its foot to go back to what is playing.
struct PlaylistView: View {
    @Environment(PlayerModel.self) private var model
    @State private var selection = Set<Int>()
    @Environment(\.oneAtATime) private var oneAtATime

    var body: some View {
        @Bindable var model = model
        Group {
            if model.files.isEmpty {
                ContentUnavailableView {
                    Label("No Tunes", systemImage: "music.note.list")
                } description: {
                    Text("Add tunes, a whole folder of them, or a playlist with its tunes, or drop them here.")
                } actions: {
                    Button("Add Files…") { model.choosing = .files }
                    Button("Add Folder…") { model.choosing = .folder }
                }
            } else {
                List(selection: $selection) {
                    if let notice = model.notice {
                        Section {
                            Text(notice)
                            Button("Choose Folder…") { model.choosing = .wanted }
                        }
                    }
                    ForEach(model.listed) { tune in
                        Row(tune: tune, playing: model.current.map { model.files.indices.contains($0) && model.files[$0].id == tune.id } ?? false)
                            .tag(tune.id)
                    }
                    .onDelete { places in
                        let listed = model.listed
                        model.remove(Set(places.map { listed[$0].id }))
                    }
                }
                .contextMenu(forSelectionType: Int.self) { ids in
                    Button("Play") { ids.first.map(play) }
                    Button("Remove", role: .destructive) { model.remove(ids) }
                } primaryAction: { ids in
                    ids.first.map(play)
                }
                #if os(macOS)
                // (In the sidebar, over what it searches, and not in the window's toolbar over the player.)
                .searchable(text: $model.search, placement: .sidebar, prompt: Text("Search"))
                .onDeleteCommand { model.remove(selection) }
                #else
                .searchable(text: $model.search, prompt: Text("Search"))
                #endif
            }
        }
        .navigationTitle("Playlist")
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Button("Add Files…", systemImage: "doc.badge.plus") { model.choosing = .files }
                    Button("Add Folder…", systemImage: "folder.badge.plus") { model.choosing = .folder }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                if !model.files.isEmpty {
                    Button("Remove All…", systemImage: "trash", role: .destructive) { model.askingToRemoveAll = true }
                }
            }
            #if os(iOS)
            // (Beside the player, the player has this button; on an iPhone, the playlist may be all
            // there is, and so has it too.)
            if oneAtATime {
                ToolbarItem(placement: .topBarLeading) { SettingsButton() }
            }
            // (In the bar at the foot, which the search shares, as the system arranges it.)
            if oneAtATime, model.hasTune {
                ToolbarItem(placement: .bottomBar) { PlayingBar() }
            }
            #endif
        }
    }

    /// Plays a tune, and shows the player where there is room for only one of them.
    private func play(_ id: Int) {
        model.play(id: id)
        model.place = .player
    }

    struct Row: View {
        let tune: ListedTune
        let playing: Bool

        var body: some View {
            HStack {
                VStack(alignment: .leading) {
                    Text(tune.name)
                        .fontWeight(playing ? .semibold : .regular)
                        .accessibilityLabel(Text(spoken(tune.name)))
                    Text(tune.folder)
                        .font(.caption)
                        // (Not the system's secondary grey, which is too faint for text this small.)
                        .foregroundStyle(Explanation.colour)
                }
                Spacer()
                if let why = tune.shortfalls {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help("\(Tune.shortfallHeading) \(why)")
                        .accessibilityLabel(Text("\(Tune.shortfallHeading) \(why)"))
                }
                if playing {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Playing")
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

#if os(iOS)
/// At the foot of the playlist on an iPhone, what is playing, as Music has it: pressed, it shows the
/// player; with a button to pause it or play it again where it is.
private struct PlayingBar: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let playing = !(model.paused || model.finished || model.tune == nil)
        HStack(spacing: 12) {
            Button {
                model.place = .player
            } label: {
                HStack(spacing: 10) {
                    // (Its bars light one after another while the tune plays, and stand still while
                    // it does not: still too, for a listener who would rather things moved less.)
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers.nonReversing, isActive: playing && !reduceMotion)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.tune.map { $0.title.isEmpty ? model.fileName : $0.title } ?? model.fileName)
                            .lineLimit(1)
                            .accessibilityIdentifier("playing")
                        if let tune = model.tune, !tune.author.isEmpty {
                            Text(tune.author)
                                .font(.caption)
                                .foregroundStyle(Explanation.colour)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityShowsLargeContentViewer()
            .accessibilityLabel(Text("Now Playing: \(model.tune?.title ?? model.fileName)"))
            .accessibilityHint("Shows the player.")
            Button {
                model.togglePause()
            } label: {
                Control.label(playing ? "Pause" : "Play", playing ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .font(.title3)
        }
        .padding(.horizontal, 8)
    }
}
#endif
