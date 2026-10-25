// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayPlayer
import SwiftUI

/// A tune as Quick Look shows it: its details as the app's player gives them, a button to play it, and
/// once it plays, how far it has got and each voice's light and scope.
struct PreviewView: View {
    let preview: TunePreview

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let tune = preview.tune {
                details(tune)
                if !tune.shortfalls.isEmpty { shortfalls(tune) }
                Spacer(minLength: 0)
                TimelineView(.animation(paused: !preview.playing)) { timeline in
                    let frame = preview.frame(at: timeline.date.timeIntervalSinceReferenceDate)
                    VStack(alignment: .leading, spacing: 12) {
                        if preview.started { voices(frame) }
                        transport(tune, position: frame.position)
                    }
                }
            } else if let problem = preview.problem {
                Text(preview.fileName).font(.title2.weight(.semibold))
                Text(preview.note ?? problem).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// As the app's player: the format, the title (or the file's name), the author, and a line of what
    /// more is known.
    private func details(_ tune: Tune) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tune.format).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(tune.title.isEmpty ? preview.fileName : tune.title)
                .font(.title2.weight(.semibold))
            if !tune.author.isEmpty {
                Text(tune.author)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text([songs(tune), tune.detail, tune.title.isEmpty ? "" : preview.fileName]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func songs(_ tune: Tune) -> String {
        tune.songs.count > 1 ? String(localized: "song \(tune.song + 1) of \(tune.songs.count)") : ""
    }

    private func shortfalls(_ tune: Tune) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Self.shortfallHeading, systemImage: "exclamationmark.triangle").font(.subheadline.weight(.semibold))
            ForEach(tune.shortfalls, id: \.self) { Text($0).font(.subheadline) }
        }
        .foregroundStyle(.secondary)
    }

    /// Each voice's light, with its scope beneath it.
    private func voices(_ frame: Frame) -> some View {
        let points = ChannelWaves.points
        let count = frame.lights.count
        // (As many to a row as there is room for: a module may have dozens of voices.)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 56, maximum: 56), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
            ForEach(0 ..< count, id: \.self) { voice in
                let kind = voice < frame.kinds.count ? frame.kinds[voice] : .chip
                VStack(spacing: 6) {
                    Lamp(level: frame.lights[voice], kind: kind).frame(width: 30, height: 30)
                    let wave = frame.scopes.count >= (voice + 1) * points ? Array(frame.scopes[(voice * points) ..< ((voice + 1) * points)]) : []
                    Scope(wave: wave, kind: kind).frame(width: 56, height: 36)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func transport(_ tune: Tune, position: Double) -> some View {
        HStack(spacing: 12) {
            Button {
                preview.togglePlay()
            } label: {
                Label(preview.playing ? "Pause" : "Play", systemImage: preview.playing ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .contentTransition(.symbolEffect(.replace))
            Text(tune.length > 0 ? "\(Self.time(position)) / \(Self.time(tune.length))" : Self.time(position))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// (As the app's player says it.)
    private static let shortfallHeading = String(localized: "Not played quite as the file asks.")

    static func time(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return "\(whole / 60):" + String(repeating: "0", count: whole % 60 < 10 ? 1 : 0) + "\(whole % 60)"
    }
}
