// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SidayPlayer

/// Where the command-line player and the app keep the files they were given once (see `KeptFile`): a
/// folder of them, each under its kept name, in the user's Application Support folder (the app's own, in
/// its sandbox). A store can be one to read only, as a test's is: nothing is ever written to it.
public struct KeptFileStore: Sendable {
    public let folder: URL
    /// True for a store that is read and never written.
    public let readOnly: Bool

    public init(folder: URL, readOnly: Bool = false) {
        self.folder = folder
        self.readOnly = readOnly
    }

    /// The store of this user, for this program: `siday/Kept` in Application Support.
    public static var standard: KeptFileStore? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return KeptFileStore(folder: support.appendingPathComponent("siday", isDirectory: true).appendingPathComponent("Kept", isDirectory: true))
    }

    /// Every file kept, read back, each known by what is in it (whatever it is called: a folder named for
    /// a test may hold the ROMs as they came). A file in the folder that is none of those siday keeps is
    /// passed over.
    public func load() -> KeptFiles {
        var kept = KeptFiles()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        kept.add(eachOf: names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let url = folder.appendingPathComponent(name)
            guard KeptFileStore.keepable(in: [url]).count == 1, let data = try? Data(contentsOf: url) else { return nil }
            return [UInt8](data)
        })
        return kept
    }

    /// Keeps a file that is one siday keeps, and forgets those it replaces.
    /// - Returns: what it is, and what it replaced; nil for a file that is not one, or is kept already.
    @discardableResult
    public func keep(_ data: [UInt8], in kept: inout KeptFiles) throws -> (file: KeptFile, replaced: [KeptFile])? {
        guard let added = kept.add(data) else { return nil }
        guard !readOnly else { return added }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(data).write(to: folder.appendingPathComponent(added.file.keptName), options: .atomic)
        for old in added.replaced { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old.keptName)) }
        return added
    }

    /// Forgets a file kept.
    public func forget(_ file: KeptFile, in kept: inout KeptFiles) {
        kept.forget(file)
        guard !readOnly else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(file.keptName))
    }

    /// Forgets every file kept.
    public func forgetAll(in kept: inout KeptFiles) {
        for file in kept.files { forget(file, in: &kept) }
    }

    /// The files below these that siday keeps, found by what is in them: only a file of the size of a ROM,
    /// or beginning as a list of song lengths begins, is read whole.
    public static func keepable(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        func look(_ url: URL) {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 64 << 20,
                  let handle = try? FileHandle(forReadingFrom: url) else { return }
            let start = (try? handle.read(upToCount: 64)) ?? Data()
            try? handle.close()
            if KeptFile.mayBe(size: size, start: [UInt8](start)) { found.append(url) }
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
                while let file = walker?.nextObject() as? URL {
                    if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { look(file) }
                }
            } else {
                look(url)
            }
        }
        return found
    }
}
