// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayPlayer
import SwiftUI

/// The app's logo, at a size, with what it shows for those who cannot see it.
struct Logo: View {
    let size: CGFloat

    var body: some View {
        Image("Logo")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("The siday logo: a chip marked SIDAY, with a stave of music")
    }
}

/// What siday is, what it plays (each format's story a press away), whose work it is made from, and
/// the licence it comes under.
struct AboutView: View {
    var body: some View {
        NavigationStack {
            AboutList()
        }
    }
}

/// What the app is, as a list: shown in a window of its own on a Mac, and from the settings elsewhere.
struct AboutList: View {
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize = 96

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        Logo(size: logoSize)
                        Text("Siday").font(.largeTitle.weight(.bold))
                    }
                    Text("Chip music and modules from the ZX Spectrum, Amstrad CPC, Atari ST, 8-bit Ataris, Commodore 64, Amiga and PC.")
                    Text("SID tunes take their lengths from the High Voltage SID Collection, release \(BuiltInSongLengths.release); a newer Songlengths.md5 from it, added like a tune, is used first.")
                        .font(.footnote)
                        .foregroundStyle(Explanation.colour)
                }
                .padding(.vertical, 4)
                Button {
                    openURL(URL(string: "https://github.com/ptsochantaris/siday")!)
                } label: {
                    Label("The Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .accessibilityAddTraits(.isLink)
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
                        .detailTitle()
                    } label: {
                        Text(part.heading)
                    }
                }
                Text(TuneFormat.fileExtensions.map { $0.uppercased() }.joined(separator: ", "))
                    .font(.footnote)
            } header: {
                Text("What It Plays")
            }
            .headerProminence(.increased)
            Section {
                NavigationLink("Credits") {
                    Document(name: "THIRD-PARTY", ending: "md", title: "Credits")
                }
                NavigationLink("Licence") {
                    Document(name: "LICENSE", ending: nil, title: "Licence")
                }
            } header: {
                Text("Made With")
            }
            .headerProminence(.increased)
        }
        .navigationTitle("About")
        .detailTitle()
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
        .detailTitle()
    }
}

private extension View {
    /// A page come to from another is titled small, in its bar, as a detail is.
    func detailTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
