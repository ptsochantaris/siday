// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import SidayKit
@testable import SidayPlayer
@testable import SidayFoundation

// The app's Info.plist says which files it opens, by their extensions, and those are SidayKit's:
// every one a tune or a playlist can have. So the file is written from SidayKit's lists, by this
// test, and the test fails when it is out of date, as it is once a format has been added:
//
//     SIDAY_WRITE_APP_TYPES=1 swift test --filter appOpensEveryKindOfFile
//
// writes it afresh.

/// The app's Info.plist, as it is to be: what Xcode does not make of the build settings, and as Xcode
/// keeps it when the project is opened (with no comment, and nothing a build setting says already, such
/// as opening documents in place).
func appInfoPlist() -> String {
    var lines = [
        #"<?xml version="1.0" encoding="UTF-8"?>"#,
        #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
        #"<plist version="1.0">"#,
        "<dict>",
        "\t<key>CFBundleDocumentTypes</key>",
        "\t<array>",
    ]
    /// - Parameter key: `LSItemContentTypes` for kinds of file, or `CFBundleTypeExtensions` for extensions.
    func documentType(_ name: String, _ key: String, _ items: [String]) {
        lines += [
            "\t\t<dict>",
            "\t\t\t<key>CFBundleTypeName</key>", "\t\t\t<string>\(name)</string>",
            "\t\t\t<key>CFBundleTypeRole</key>", "\t\t\t<string>Viewer</string>",
            "\t\t\t<key>LSHandlerRank</key>", "\t\t\t<string>Alternate</string>",
            "\t\t\t<key>\(key)</key>",
            "\t\t\t<array>",
        ]
        lines += items.map { "\t\t\t\t<string>\($0)</string>" }
        lines += ["\t\t\t</array>", "\t\t</dict>"]
    }
    let tunes = TuneFormat.fileExtensions
    documentType("Chip music", "LSItemContentTypes", tunes.map(tuneType))
    // (M3U lists are the system's own kind of file; Ay_Emul's are declared here.)
    documentType("Playlist", "LSItemContentTypes", ["build.bru.siday.playlist.ayl", "public.m3u-playlist"])
    // And the same by their extensions, for a Mac. Where another app declares a kind of file for one
    // of them too (VLC for .xm, and a Markdown or PostScript file is .md or .ps), the system takes
    // one of the two, and a file of the other's kind is not one of the app's by its kind. By its
    // extension it is, and the app is among those it can be opened with. (An iPhone or iPad goes
    // by kinds only, and passes this over.)
    documentType("Chip music or playlist", "CFBundleTypeExtensions", tunes + ["ayl"])
    lines += [
        "\t</array>",
        "\t<key>UIBackgroundModes</key>",
        "\t<array>",
        "\t\t<string>audio</string>",
        "\t</array>",
        "\t<key>UTImportedTypeDeclarations</key>",
        "\t<array>",
    ]
    func declaration(_ identifier: String, _ description: String, _ ending: String) {
        lines += [
            "\t\t<dict>",
            "\t\t\t<key>UTTypeConformsTo</key>",
            "\t\t\t<array>", "\t\t\t\t<string>public.data</string>", "\t\t\t</array>",
            "\t\t\t<key>UTTypeDescription</key>", "\t\t\t<string>\(description)</string>",
            "\t\t\t<key>UTTypeIdentifier</key>", "\t\t\t<string>\(identifier)</string>",
            "\t\t\t<key>UTTypeTagSpecification</key>",
            "\t\t\t<dict>",
            "\t\t\t\t<key>public.filename-extension</key>",
            "\t\t\t\t<array>", "\t\t\t\t\t<string>\(ending)</string>", "\t\t\t\t</array>",
            "\t\t\t</dict>",
            "\t\t</dict>",
        ]
    }
    for ending in tunes { declaration(tuneType(ending), "\(ending.uppercased()) music", ending) }
    declaration("build.bru.siday.playlist.ayl", "Ay_Emul playlist", "ayl")
    lines += ["\t</array>", "</dict>", "</plist>", ""]
    return lines.joined(separator: "\n")
}

/// The app's name for the kind of file a tune with this extension is. (A type's name has letters,
/// digits, stops and hyphens: `sa_old` is `sa-old`.)
func tuneType(_ ending: String) -> String {
    "build.bru.siday.tune." + String(ending.map { $0 == "_" ? "-" : $0 })
}

/// Where the app's Info.plist is: App/Siday, beside this repository's Tests.
private let infoPlistPath: String = {
    var parts = #filePath.split(separator: "/", omittingEmptySubsequences: false)
    parts.removeLast(3)
    return (parts + ["App", "Siday", "Info.plist"]).joined(separator: "/")
}()

@Test func appOpensEveryKindOfFile() throws {
    let wanted = appInfoPlist()
    if getenv("SIDAY_WRITE_APP_TYPES") != nil {
        let file = try #require(fopen(infoPlistPath, "w"))
        fputs(wanted, file)
        fclose(file)
    }
    var bytes: [UInt8] = []
    if let file = fopen(infoPlistPath, "r") {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = fread(&buffer, 1, buffer.count, file)
            if count <= 0 { break }
            bytes += buffer[..<count]
        }
        fclose(file)
    }
    #expect(String(decoding: bytes, as: UTF8.self) == wanted, "App/Siday/Info.plist is out of date: SIDAY_WRITE_APP_TYPES=1 swift test --filter appOpensEveryKindOfFile")
}

@Test func everyPlaylistExtensionNamesAKind() {
    for name in PlaylistFile.Kind.fileExtensions {
        #expect(PlaylistFile.Kind(fileExtension: name) != nil)
    }
    // (Each of the app's names for a kind of file is a name a type can have.)
    for ending in TuneFormat.fileExtensions {
        #expect(tuneType(ending).allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
    }
}
