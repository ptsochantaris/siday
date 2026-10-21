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
                } footer: {
                    Text("Settings are kept for the next time the app is opened.")
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
                Picker(selection: Binding(get: { Int(model.value(of: setting)) }, set: { model.set(setting, to: Double($0)) })) {
                    ForEach(choices.indices, id: \.self) { index in
                        Text(choices[index].title).tag(index)
                    }
                } label: {
                    label(changed)
                }
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
                .foregroundStyle(.secondary)
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
