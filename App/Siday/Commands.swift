// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import SwiftUI

/// Everything the app does, in its menus, with the keys of a Mac's music player: on a Mac's menu bar,
/// on an iPad's, and from a keyboard on any of them.
struct SidayCommands: Commands {
    let model: PlayerModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { model.choosing = .files }
                .keyboardShortcut("o")
            Button("Add Folder…") { model.choosing = .folder }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Remove All Tunes…", role: .destructive) { model.askingToRemoveAll = true }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.files.isEmpty)
        }

        #if os(macOS)
        // (Settings… is the Settings window's own; About is the app's own window.)
        CommandGroup(replacing: .appInfo) {
            Button("About Siday") { openWindow(id: "about") }
        }
        #else
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showingSettings = true }
                .keyboardShortcut(",")
        }
        #endif

        CommandMenu("Playback") {
            Button(model.paused || model.finished ? "Play" : "Pause") { model.togglePause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.tune == nil)
            Divider()
            Button("Next Tune") { model.next() }
                .keyboardShortcut(.rightArrow)
                .disabled(!model.hasNext)
            Button("Previous Tune") { model.previous() }
                .keyboardShortcut(.leftArrow)
                .disabled(!model.hasPrevious)
            Button("Next Song") { model.song(1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled((model.tune?.songs.count ?? 0) <= (model.tune?.song ?? 0) + 1)
            Button("Previous Song") { model.song(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled((model.tune?.song ?? 0) == 0)
            Divider()
            Button("Skip Forward 10 Seconds") { model.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(model.tune == nil)
            Button("Skip Back 10 Seconds") { model.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(model.tune == nil)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { model.shuffled }, set: { _ in model.toggleShuffle() }))
                .keyboardShortcut("s", modifiers: [.command, .option])
            Picker("Output", selection: Binding(get: { model.output }, set: { model.output = $0 })) {
                ForEach(PlayerModel.outputs, id: \.self) { style in
                    Text(style.title).tag(style)
                }
            }
            Divider()
            Button("Volume Up") { model.nudgeVolume(0.1) }
                .keyboardShortcut(.upArrow)
            Button("Volume Down") { model.nudgeVolume(-0.1) }
                .keyboardShortcut(.downArrow)
            Divider()
            Menu("Voices") {
                ForEach(0 ..< model.voiceCount, id: \.self) { voice in
                    Button("Mute or Bring Back Voice \(voice + 1)") { model.press(light: voice, solo: false) }
                        .keyboardShortcut(voice < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(voice + 1)")), modifiers: .control) : nil)
                    Button("Hear Voice \(voice + 1) Alone") { model.press(light: voice, solo: true) }
                        .keyboardShortcut(voice < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(voice + 1)")), modifiers: [.control, .shift]) : nil)
                }
            }
            .disabled(model.voiceCount == 0)
        }

        CommandGroup(before: .toolbar) {
            ForEach(Part.allCases) { part in
                Toggle(part.title, isOn: Binding(get: { model.shows(part) }, set: { _ in model.toggle(part) }))
            }
            Picker("Picture", selection: Binding(get: { model.picture }, set: { model.picture = $0 })) {
                ForEach(Visualiser.Mode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Button(model.pictureFillsScreen ? "Put the Picture Back" : "Fill the Screen with the Picture") {
                model.pictureFillsScreen.toggle()
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            .disabled(!model.hasTune)
            Divider()
            Button("About This Format") {
                if let chapter = model.chapter {
                    model.place = .player
                    model.slideOver = .story(chapter)
                }
            }
            .keyboardShortcut("i")
            .disabled(model.chapter == nil)
            Divider()
        }
    }
}
