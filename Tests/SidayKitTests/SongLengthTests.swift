// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
import Foundation
import Testing

private func digest(_ hex: String) -> [UInt8] {
    let digits = Array(hex.utf8)
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(decoding: digits[$0 ..< $0 + 2], as: UTF8.self), radix: 16)! }
}

/// A few entries of HVSC release 85, as its Songlengths.md5 has them.
@Test func builtInSongLengthsKnowTheCollection() {
    #expect(BuiltInSongLengths.release >= 85)
    // /MUSICIANS/H/Hubbard_Rob/Knucklebusters.sid: 16:42 3:22 0:58 0:01 0:01 0:02 0:01 0:02 0:05 0:03 0:01
    #expect(BuiltInSongLengths.lengths(md5: digest("e7c2ee739008d3d035a20d39ceefd115")) == [1002, 202, 58, 1, 1, 2, 1, 2, 5, 3, 1])
    // /DEMOS/UNKNOWN/Bach_Tribute.sid: 13:55.744
    #expect(BuiltInSongLengths.lengths(md5: digest("33ee53ebe42056fc3399c0e2e598048c")) == [780 + 55.744])
    // /DEMOS/G-L/Lazy_No-one.sid: lengths to one, two and three places.
    let places: [Double] = [180 + 12.4, 60 + 32.473, 24.403, 46.005, 15.341, 60 + 9.028, 46.185, 60 + 24.29]
    #expect(BuiltInSongLengths.lengths(md5: digest("90f28b9017fb0f835c2185ab393a9e49")) == places)
    // /DEMOS/0-9/10_Orbyte.sid, the first in the file.
    #expect(BuiltInSongLengths.lengths(md5: digest("5f08a730b280e54fd1e75a7046b93fdc")) == [77])
}

@Test func builtInSongLengthsDoNotKnowOtherFiles() {
    #expect(BuiltInSongLengths.lengths(md5: [UInt8](repeating: 0, count: 16)) == nil)
    #expect(BuiltInSongLengths.lengths(md5: [UInt8](repeating: 0xFF, count: 16)) == nil)
    // The same first six bytes as a tune of the collection is the same tune, as far as the table can
    // tell; one bit's difference in them is not.
    #expect(BuiltInSongLengths.lengths(md5: digest("e7c2ee739009d3d035a20d39ceefd115")) == nil)
    #expect(BuiltInSongLengths.lengths(of: Array("not a SID file".utf8)) == nil)
}

/// Every entry of the Songlengths.md5 the table was packed from, against the table. It needs that file:
/// SIDAY_SONGLENGTHS names it. To be run after Scripts/pack-songlengths.swift.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SIDAY_SONGLENGTHS"] != nil))
func builtInSongLengthsMatchTheFileTheyWerePackedFrom() throws {
    let path = try #require(ProcessInfo.processInfo.environment["SIDAY_SONGLENGTHS"])
    let file = SongLengthDatabase.parse([UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))).byHash
    #expect(file.count == SongLengthsData.tunes)
    var different = 0
    for (hex, lengths) in file where BuiltInSongLengths.lengths(md5: digest(hex)) != lengths { different += 1 }
    #expect(different == 0)
}
