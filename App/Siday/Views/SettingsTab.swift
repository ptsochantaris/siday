// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import SwiftUI

/// The listener's settings: the command-line player's options, in groups, each with what it does
/// written under it. One that has been changed is marked. They are kept from one visit to the next,
/// and a button puts them all back as they come.
struct SettingsTab: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                ForEach(Setting.Group.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(group.settings, id: \.self) { setting in
                            SettingRow(setting: setting)
                        }
                    }
                }
                Section {
                    Button("Reset to Defaults", role: .destructive) { model.resetSettings() }
                        .disabled(model.settingsAreStandard)
                    Text("Settings are kept for the next time the app is opened.")
                        .font(.footnote)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
        }
    }
}

private struct SettingRow: View {
    @Environment(PlayerModel.self) private var model
    let setting: Setting

    var body: some View {
        let value = model.value(of: setting)
        let changed = value != setting.standard
        VStack(alignment: .leading, spacing: 4) {
            switch setting.kind {
            case .choice(let choices):
                // (The name above what is chosen, so that each has the whole width, at any size of text.)
                label(changed)
                // (A menu of the choices, whose button says what is chosen in words that wrap at any size.)
                Menu {
                    Picker(selection: Binding(get: { Int(model.value(of: setting)) }, set: { model.set(setting, to: Double($0)) })) {
                        ForEach(choices.indices, id: \.self) { index in
                            Text(choices[index].title).tag(index)
                        }
                    } label: {
                        Text(setting.title)
                    }
                    .pickerStyle(.inline)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(choices[Int(value)].title)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(Text(setting.title))
                .accessibilityValue(Text(choices[Int(value)].title))
            case .scale(let low, let high):
                LabeledContent {
                    Slider(value: Binding(get: { model.value(of: setting) }, set: { model.set(setting, to: $0) }), in: 0 ... 100) {
                        label(changed)
                    } minimumValueLabel: {
                        Text(low).font(.caption)
                    } maximumValueLabel: {
                        Text(high).font(.caption)
                    }
                } label: {
                    label(changed)
                }
            }
            Text(setting.about)
                .font(.footnote)
                .foregroundStyle(Explanation.colour)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    /// The setting's name, with a mark when it is not as it comes.
    private func label(_ changed: Bool) -> some View {
        HStack(spacing: 6) {
            Text(setting.title)
            if changed {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Changed")
            }
        }
    }
}

/// Text that explains, a little fainter than what it explains, and still dark enough to read small.
enum Explanation {
    static let colour = Color.primary.opacity(0.7)
}
