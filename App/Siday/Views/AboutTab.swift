// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import SwiftUI

/// What siday is, what it plays (each format's story a press away), whose work it is made from, and
/// the licence it comes under.
struct AboutTab: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Siday").font(.largeTitle.weight(.bold))
                        Text("Chip music and modules from the ZX Spectrum, Amstrad CPC, Atari ST, 8-bit Ataris, Commodore 64, Amiga and PC.")
                        Text("SID tunes take their lengths from the High Voltage SID Collection, release \(BuiltInSongLengths.release); a newer Songlengths.md5 from it, added like a tune, is used first.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Link(destination: URL(string: "https://github.com/ptsochantaris/siday")!) {
                        Label("The Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Section {
                    ForEach(Stories.all) { part in
                        NavigationLink {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(part.heading).font(.title2.weight(.semibold))
                                    MarkdownText(text: part.text)
                                }
                                .padding()
                                .frame(maxWidth: 760)
                                .frame(maxWidth: .infinity)
                            }
                            .navigationTitle(part.id)
                        } label: {
                            Text(part.heading)
                        }
                    }
                } header: {
                    Text("What It Plays")
                } footer: {
                    Text(TuneFormat.fileExtensions.map { $0.uppercased() }.joined(separator: ", "))
                }
                Section("Made With") {
                    NavigationLink("Credits") {
                        Document(name: "THIRD-PARTY", ending: "md", title: "Credits")
                    }
                    NavigationLink("Licence") {
                        Document(name: "LICENSE", ending: nil, title: "Licence")
                    }
                }
            }
            .navigationTitle("About")
        }
    }
}

/// One of the documents the app carries, to be read.
private struct Document: View {
    let name: String
    let ending: String?
    let title: LocalizedStringKey

    var body: some View {
        ScrollView {
            Group {
                if let url = Bundle.main.url(forResource: name, withExtension: ending), let text = try? String(contentsOf: url, encoding: .utf8) {
                    if ending == "md" {
                        MarkdownText(text: text)
                    } else {
                        Text(text).font(.callout.monospaced()).textSelection(.enabled)
                    }
                } else {
                    ContentUnavailableView("Not Found", systemImage: "doc")
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(title)
    }
}
