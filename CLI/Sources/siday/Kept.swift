// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayFiles
import SidayPlayer
import Synchronization

/// The files siday keeps (see `KeptFile`), as the command-line player has them: in its store in Application
/// Support, or, for a run that names one in `$SIDAY_KEPT`, in that folder, which is read and never written
/// (so that a test run never changes what the user has kept).
enum KeptFilesInUse {
    private static let cache = Mutex<KeptFiles?>(nil)

    /// The store in use.
    static var store: KeptFileStore? {
        if let folder = ProcessInfo.processInfo.environment["SIDAY_KEPT"] {
            return KeptFileStore(folder: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true), readOnly: true)
        }
        return KeptFileStore.standard
    }

    /// What is kept, read once.
    static var current: KeptFiles {
        if let kept = cache.withLock({ $0 }) { return kept }
        let kept = store?.load() ?? KeptFiles()
        cache.withLock { $0 = kept }
        return kept
    }

    /// Keeps the files below `keep` that siday keeps; says what is kept, if asked; forgets it all, if asked.
    static func handle(keep paths: [String], list: Bool, forget: Bool, playingOn model: SC55Model = .sc55) throws {
        guard let store else { throw TuneError.unreadable("there is no Application Support folder to keep files in") }
        var kept = current
        func say(_ line: String) { FileHandle.standardError.write(Data("siday: \(line)\n".utf8)) }
        if forget {
            store.forgetAll(in: &kept)
            say(store.readOnly ? "nothing forgotten: $SIDAY_KEPT names a folder that is only read" : "every kept file forgotten")
        }
        if !paths.isEmpty {
            let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            var taken = 0
            for url in KeptFileStore.keepable(in: urls) {
                guard let data = try? Data(contentsOf: url), let added = try store.keep([UInt8](data), in: &kept) else { continue }
                taken += 1
                say("kept \(added.file.name) (from \(url.lastPathComponent))" + (store.readOnly ? ", for this run only" : ""))
            }
            if taken == 0 { say("no new MT-32 or Sound Canvas ROM or song lengths found in \(paths.joined(separator: ", "))") }
        }
        cache.withLock { $0 = kept }
        if list || !paths.isEmpty {
            let lines = kept.summary(playingOn: model)
            if lines.isEmpty { say("nothing is kept") }
            for line in lines { say(line) }
            if list { say("kept in \(store.folder.path)" + (store.readOnly ? " (read only, from $SIDAY_KEPT)" : "")) }
        }
    }
}
