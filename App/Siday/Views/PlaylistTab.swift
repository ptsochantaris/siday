// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UniformTypeIdentifiers

/// The list of tunes: searched, played from, taken out of, and added to.
struct PlaylistTab: View {
    @Environment(PlayerModel.self) private var model
    @State private var selection = Set<Int>()
    @State private var choosing: Choosing?

    enum Choosing: Identifiable {
        case files, folder, wanted
        var id: Self { self }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.files.isEmpty {
                    ContentUnavailableView {
                        Label("No Tunes", systemImage: "music.note.list")
                    } description: {
                        Text("Add tunes, a whole folder of them, or a playlist with its tunes, or drop them here.")
                    } actions: {
                        Button("Add Files…") { choosing = .files }
                        Button("Add Folder…") { choosing = .folder }
                    }
                } else {
                    List(selection: $selection) {
                        if let notice = model.notice {
                            Section {
                                Text(notice)
                                Button("Choose Folder…") { choosing = .wanted }
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
                        Button("Play") { ids.first.map { model.play(id: $0) } }
                        Button("Remove", role: .destructive) { model.remove(ids) }
                    } primaryAction: { ids in
                        ids.first.map { model.play(id: $0) }
                    }
                    .searchable(text: $model.search, prompt: Text("Search \(model.files.count) tunes"))
                    #if os(macOS)
                    .onDeleteCommand { model.remove(selection) }
                    #endif
                }
            }
            .navigationTitle("Playlist")
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("Add Files…", systemImage: "doc.badge.plus") { choosing = .files }
                        Button("Add Folder…", systemImage: "folder.badge.plus") { choosing = .folder }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    if !model.files.isEmpty {
                        Button("Remove All", systemImage: "trash", role: .destructive) { model.removeAll() }
                    }
                }
            }
        }
        .fileImporter(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } }),
                      allowedContentTypes: choosing == .files ? [.data] : [.folder],
                      allowsMultipleSelection: choosing == .files) { result in
            guard let urls = try? result.get() else { return }
            if choosing == .wanted, let folder = urls.first {
                model.gaveFolder(folder)
            } else {
                model.add(urls)
            }
        }
    }

    struct Row: View {
        let tune: ListedTune
        let playing: Bool

        var body: some View {
            HStack {
                VStack(alignment: .leading) {
                    Text(tune.name)
                        .fontWeight(playing ? .semibold : .regular)
                    Text(tune.folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
