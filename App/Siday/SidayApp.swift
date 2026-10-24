// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayPlayer
import SwiftUI
import UniformTypeIdentifiers

@main
struct SidayApp: App {
    @State private var model: PlayerModel
    private let nowPlaying: SystemNowPlaying

    init() {
        let model = PlayerModel()
        _model = State(initialValue: model)
        nowPlaying = SystemNowPlaying(model: model)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onOpenURL { url in model.add([url]) }
                .task { openGivenOnLaunch() }
        }
        .commands {
            SidebarCommands()
            SidayCommands(model: model)
        }
        #if os(macOS)
        // On a Mac, the settings are a window of their own, opened from the app's menu; and what
        // the app is, from the same menu, another.
        Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 720)
        }
        Window("About Siday", id: "about") {
            AboutView()
                .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 680)
        }
        .windowResizability(.contentMinSize)
        #endif
    }

    /// For trying the app out: `-SidayOpen PATH` adds what is at the path, as if it had been chosen.
    private func openGivenOnLaunch() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let place = arguments.firstIndex(of: "-SidayOpen"), place + 1 < arguments.count {
            model.add([URL(fileURLWithPath: arguments[place + 1])])
        }
        #endif
    }
}

/// The playlist beside the player: a sidebar that can be put away, on a Mac or an iPad; on an
/// iPhone, one at a time, the player over the playlist. Files may be dropped on either (see
/// `takesDroppedTunes`).
struct ContentView: View {
    @Environment(PlayerModel.self) private var model
    /// What the file picker was last opened for: kept, since its answer comes once it has closed.
    @State private var asked = PlayerModel.Choosing.files
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(preferredCompactColumn: Binding(get: { model.place == .player ? .detail : .sidebar },
                                                            set: { model.place = $0 == .sidebar ? .playlist : .player })) {
            PlaylistView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 460)
        } detail: {
            PlayerView()
        }
        #if os(iOS)
        // (Told from the window's width: within the split view, the playlist's column is narrow
        // even when the player is beside it.)
        .environment(\.oneAtATime, sizeClass == .compact)
        #endif
        .fileImporter(isPresented: Binding(get: { model.choosing != nil }, set: { if !$0 { model.choosing = nil } }),
                      allowedContentTypes: (model.choosing ?? asked) == .files ? [.data] : [.folder],
                      allowsMultipleSelection: (model.choosing ?? asked) == .files) { result in
            guard let urls = try? result.get() else { return }
            if asked == .wanted, let folder = urls.first {
                model.gaveFolder(folder)
            } else {
                model.add(urls)
            }
        }
        .onChange(of: model.choosing) { _, wanted in
            if let wanted { asked = wanted }
        }
        .alert("Nothing to Play", isPresented: Binding(get: { model.emptyFolder != nil }, set: { if !$0 { model.emptyFolder = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No tunes that Siday plays were found in “\(model.emptyFolder ?? "")”, or the folder could not be looked into.")
        }
        // (Asked here, over everything, so that it is asked whichever part is showing.)
        .alert("Remove all the tunes?", isPresented: $model.askingToRemoveAll) {
            Button("Remove All", role: .destructive) { model.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The playlist will be empty. The files themselves are not touched.")
        }
        #if os(iOS)
        .sheet(isPresented: $model.showingSettings) {
            SettingsView().environment(model)
        }
        .fullScreenCover(isPresented: Binding(get: { model.pictureFillsScreen }, set: { model.pictureFillsScreen = $0 })) {
            WholeScreenPicture().environment(model)
        }
        #else
        .overlay {
            if model.pictureFillsScreen {
                WholeScreenPicture()
            }
        }
        #endif
    }
}

extension View {
    /// Adds what is dropped on the view, files and folders, as if they had been chosen. Each column
    /// of the split view takes them for itself: on a Mac each is a view of the system's own, and
    /// what is dropped on one goes no further, so that the split view as a whole is given nothing.
    func takesDroppedTunes(_ model: PlayerModel) -> some View {
        dropDestination(for: Dropped.self) { dropped, _ in
            model.add(dropped.map(\.url))
            return !dropped.isEmpty
        }
    }
}

/// A file or folder dropped on the app. From the Finder it comes as its URL. From the Files app or
/// another app on an iPhone or iPad it comes as itself, which has no URL to give: it is taken where
/// it is, if it may be read there, or else as a copy kept among the app's own files (the copy the
/// system makes is gone once the drop is over).
struct Dropped: Transferable {
    var url: URL

    static var transferRepresentation: some TransferRepresentation {
        #if os(iOS)
        FileRepresentation(importedContentType: .item, shouldAttemptToOpenInPlace: true) { received in
            Dropped(url: received.isOriginalFile ? received.file : try Library.keep(received.file))
        }
        #else
        ProxyRepresentation { (url: URL) in Dropped(url: url) }
        #endif
    }
}

extension EnvironmentValues {
    /// True where the playlist and the player are shown one at a time (an iPhone), and not side by side.
    @Entry var oneAtATime = false
}

#if os(iOS)
/// The button that shows the settings (and, from them, what the app is), where there is no
/// Settings menu to show them from.
struct SettingsButton: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Button("Settings", systemImage: "gearshape") { model.showingSettings = true }
    }
}
#endif
