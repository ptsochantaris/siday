// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import SwiftUI

@main
struct SidayApp: App {
    @State private var model = PlayerModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onOpenURL { url in model.add([url]) }
                .task { openGivenOnLaunch() }
        }
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

/// The parts of the app, each a tab: what is playing, the list of tunes, the settings, and what siday
/// plays and who made what it is made of.
enum Tab: String, CaseIterable, Identifiable {
    case player, playlist, settings, about

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .player: "Player"
        case .playlist: "Playlist"
        case .settings: "Settings"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .player: "play.circle"
        case .playlist: "music.note.list"
        case .settings: "gearshape"
        case .about: "info.circle"
        }
    }
}

struct ContentView: View {
    @Environment(PlayerModel.self) private var model
    @State private var tab = Tab.player

    var body: some View {
        TabView(selection: $tab) {
            SwiftUI.Tab(Tab.player.title, systemImage: Tab.player.symbol, value: Tab.player) {
                PlayerTab()
            }
            SwiftUI.Tab(Tab.playlist.title, systemImage: Tab.playlist.symbol, value: Tab.playlist) {
                PlaylistTab()
            }
            SwiftUI.Tab(Tab.settings.title, systemImage: Tab.settings.symbol, value: Tab.settings) {
                Text("Settings")
            }
            SwiftUI.Tab(Tab.about.title, systemImage: Tab.about.symbol, value: Tab.about) {
                Text("\(TuneFormat.fileExtensions.count) kinds of file")
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        }
    }
}
