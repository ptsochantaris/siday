// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

import Foundation

/// Two independent modules played on two chips (TurboSound). Files carry both modules back to back,
/// followed by a 16-byte footer: type tag and size of each, then "02TS".
public final class TurboSoundPair: AYFrameSource {
    private let first: any AYFrameSource
    private let second: any AYFrameSource
    public let info: TuneInfo

    public init(_ first: any AYFrameSource, _ second: any AYFrameSource) {
        self.first = first
        self.second = second
        var info = first.info
        info.format = first.info.format == second.info.format ? "\(first.info.format) TS" : "\(first.info.format)+\(second.info.format) TS"
        if info.title.isEmpty { info.title = second.info.title }
        if info.author.isEmpty { info.author = second.info.author }
        self.info = info
    }

    public var chipCount: Int { 2 }
    public var fileClockHz: Double? { first.fileClockHz }
    public var fileFrameHz: Double? { first.fileFrameHz }
    public var fileChipType: AYChipType? { first.fileChipType }
    /// The pair has looped once both halves have.
    public var loopCount: Int { min(first.loopCount, second.loopCount) }
    public var hasEnded: Bool { first.hasEnded && second.hasEnded }

    public func restart() {
        first.restart()
        second.restart()
    }

    public func tick(_ regs: UnsafeMutablePointer<AYRegs>) {
        first.tick(regs)
        second.tick(regs + 1)
    }

    /// Splits a file with a TurboSound footer into its two modules and their formats.
    static func split(_ data: Data) -> (TuneFormat, Data, TuneFormat, Data)? {
        guard data.count > 16 else { return nil }
        let r = ByteReader(data.suffix(16))
        guard r.ascii(at: 12, length: 4) == "02TS" else { return nil }
        let size1 = r.u16le(4), size2 = r.u16le(10)
        guard size1 > 0, size2 > 0, size1 + size2 == data.count - 16,
              let type1 = format(tag: r.ascii(at: 0, length: 4)), let type2 = format(tag: r.ascii(at: 6, length: 4)) else { return nil }
        let start = data.startIndex
        return (type1, data.subdata(in: start ..< start + size1), type2, data.subdata(in: start + size1 ..< start + size1 + size2))
    }

    private static func format(tag: String) -> TuneFormat? {
        guard tag.count == 4, tag.hasSuffix("!") else { return nil }
        return TuneFormat(rawValue: tag.dropLast().lowercased())
    }
}
