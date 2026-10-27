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
        // On a Mac, one window: there is one list and one tune playing, and a file opened from the
        // Finder goes into it, and does not open a window of its own. On an iPad, as many as the
        // listener likes, as iPadOS has it.
        #if os(macOS)
        Window("Siday", id: "player") { player }
            .commands { commands }
        #else
        WindowGroup { player }
            .commands { commands }
        #endif
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

    /// The player and its list, in a window.
    private var player: some View {
        ContentView()
            .environment(model)
            .onOpenURL { url in model.add([url]) }
            .task { openGivenOnLaunch() }
    }

    @CommandsBuilder private var commands: some Commands {
        SidebarCommands()
        SidayCommands(model: model)
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
    /// This window's picture to listen by (see `Visualisers`).
    @State private var visualiser: Visualiser?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #else
    /// The window this is in, and whether it was put into full screen for the picture (and so is to be
    /// taken out of it again as the picture is put back).
    @State private var window = WindowFinder.Found()
    @State private var madeFullScreen = false
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
        .environment(\.visualiser, visualiser)
        .onAppear {
            if visualiser == nil { visualiser = model.visualisers.make() }
        }
        .fileImporter(isPresented: Binding(get: { model.choosing != nil }, set: { if !$0 { model.choosing = nil } }),
                      allowedContentTypes: (model.choosing ?? asked) == .files ? [.data] : [.folder],
                      allowsMultipleSelection: (model.choosing ?? asked) == .files) { result in
            model.choosingFrom = nil
            guard let urls = try? result.get() else { return }
            if asked == .wanted, let folder = urls.first {
                model.gaveFolder(folder)
            } else {
                model.add(urls)
            }
        }
        .fileDialogDefaultDirectory(model.choosingFrom)
        .onChange(of: model.choosing) { _, wanted in
            if let wanted { asked = wanted }
        }
        .alert("Nothing to Play", isPresented: Binding(get: { model.emptyFolder != nil }, set: { if !$0 { model.emptyFolder = nil } })) {
            // (A folder that seemed empty may be one whose files the system does not list, as on some
            // shares on the network on an iPad: they can still be chosen, from the file picker opened in it.)
            if model.emptyFolderFiles == 0, let place = model.emptyFolderPlace {
                Button("Choose Files…") {
                    model.choosingFrom = place
                    model.choosing = .files
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            if model.emptyFolderFiles == 0 {
                Text("Siday could not see any files in “\(model.emptyFolder ?? "")”. Some shares on the network do not show a folder’s files to apps, but you can still choose them.")
            } else {
                Text("None of the \(model.emptyFolderFiles) files in “\(model.emptyFolder ?? "")” is a tune Siday plays.")
            }
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
            WholeScreenPicture().environment(model).environment(\.visualiser, visualiser)
        }
        #else
        // (The picture over the window, given this window's picture to listen by, as the overlay is
        // outside where the rest are given it; and the window put into full screen, unless it is.)
        .overlay {
            if model.pictureFillsScreen {
                WholeScreenPicture().environment(\.visualiser, visualiser)
            }
        }
        .toolbarVisibility(model.pictureFillsScreen ? .hidden : .automatic, for: .windowToolbar)
        .background(WindowFinder(found: window))
        .onChange(of: model.pictureFillsScreen) { _, fills in
            guard let shown = window.window else { return }
            let isFullScreen = shown.styleMask.contains(.fullScreen)
            if fills, !isFullScreen {
                madeFullScreen = true
                shown.toggleFullScreen(nil)
            } else if !fills, madeFullScreen {
                madeFullScreen = false
                if isFullScreen { shown.toggleFullScreen(nil) }
            }
        }
        // (Taken out of full screen another way, as by its green button, the picture is put back too.)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard madeFullScreen, (note.object as? NSWindow) === window.window else { return }
            madeFullScreen = false
            model.pictureFillsScreen = false
        }
        #endif
    }
}

#if os(macOS)
/// Finds the window a view is in, once it is in one.
struct WindowFinder: NSViewRepresentable {
    /// Where the window is kept when found.
    final class Found {
        weak var window: NSWindow?
    }

    let found: Found

    func makeNSView(context: Context) -> NSView { Finding(found: found) }
    func updateNSView(_: NSView, context: Context) {}

    final class Finding: NSView {
        let found: Found

        init(found: Found) {
            self.found = found
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            found.window = window
        }
    }
}
#endif

/// That what was added is being looked through, and how far it has got: a wheel turning, and words.
struct AddingNotice: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.callout)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

extension View {
    /// Shows, at the top of the column, under its bar, what is being done with tunes that were added
    /// while it takes a moment, as the web page says it.
    func showsAdding(_ model: PlayerModel) -> some View {
        overlay(alignment: .top) {
            if let adding = model.adding {
                AddingNotice(text: adding)
                    .padding(.top, 8)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.adding == nil)
    }

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
    /// The window's picture to listen by.
    @Entry var visualiser: Visualiser?
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
