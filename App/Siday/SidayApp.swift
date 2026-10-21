// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import SwiftUI

@main
struct SidayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
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
    @State private var tab = Tab.player

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Tab.allCases) { tab in
                SwiftUI.Tab(tab.title, systemImage: tab.symbol, value: tab) {
                    Text("\(TuneFormat.fileExtensions.count) kinds of file")
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
