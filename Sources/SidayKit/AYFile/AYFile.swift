// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from Ay_Emul, (c) 1999-2026 S.V. Bulba, whose source may be used freely with reference to
// its author (see THIRD-PARTY.md).

import Foundation

/// A parsed ZXAYEMUL (`.ay`) file: Z80 code and data ripped from ZX Spectrum and Amstrad CPC programs,
/// one or more songs each with its own memory image, entry points and register preset.
///
/// Layout after Patrik Rak's specification; every pointer is a big-endian signed offset relative to
/// its own position. Loading follows Ay_Emul (Sergey Bulba), including how it clamps memory blocks.
public struct AYFile: Sendable {
    public struct Block: Sendable {
        /// Z80 address the block is loaded at.
        public var address: Int
        /// Bytes to copy, after clamping to the 64 KB address space and to the end of the file.
        public var length: Int
        /// Position of the block's data in the file.
        public var fileOffset: Int
    }

    public struct Song: Sendable {
        public var name = ""
        /// Amiga channel assignment of AY channels A, B, C and noise. Not used on playback.
        public var channelMap: [UInt8] = [0, 1, 2, 3]
        /// Length in interrupts (1/50 s unless `frameHz` says otherwise); 0 means the file does not say.
        public var lengthFrames = 0
        /// Fade-out length in interrupts; 0 means none.
        public var fadeFrames = 0
        /// Preset for the high and low byte of every 16-bit register pair.
        public var highRegister: UInt8 = 0
        public var lowRegister: UInt8 = 0
        public var stack = 0
        /// Address called once to initialise; 0 means "the address of the first block".
        public var initAddress = 0
        /// Address called on every interrupt; 0 means the code installs its own handler.
        public var interruptAddress = 0
        /// Interrupts per second, for a song whose timing has been corrected (see `AYFileCorrection`);
        /// nil means the machine's usual rate.
        public var frameHz: Double?
        /// CPU clock in Hz when it matters which Spectrum the song came from; nil means the usual one.
        public var cpuHz: Double?
        /// True when the interrupt routine paces itself and is to be called again as soon as it returns,
        /// with interrupts off, instead of once per interrupt.
        public var freeRunning = false
        /// True when a built-in correction has changed how the song is timed.
        public var timingCorrected = false
        public var blocks: [Block] = []
    }

    public var fileVersion = 0
    public var playerVersion = 0
    public var author = ""
    public var misc = ""
    public var songs: [Song] = []
    /// Zero-based index of the song to play first.
    public var firstSong = 0
    private let bytes: [UInt8]

    /// - Parameter corrected: apply the built-in timing fixes for files known to be ripped at the wrong speed.
    public init(_ data: Data, corrected: Bool = true) throws {
        let reader = ByteReader(data)
        bytes = reader.data
        guard reader.count >= 20 else { throw TuneError.malformed("AY file is too short") }
        guard reader.ascii(at: 0, length: 4) == "ZXAY" else { throw TuneError.malformed("not a ZXAY file") }
        let type = reader.ascii(at: 4, length: 4)
        guard type == "EMUL" else {
            // AMAD (Fuxoft's AY language) and ST11 (Sound Tracker 1) share the container but carry no Z80 code.
            throw TuneError.unsupported("ZXAY file of type \(type) is not supported")
        }
        fileVersion = Int(reader[8])
        playerVersion = Int(reader[9])
        author = Self.text(reader, at: 12 + reader.s16be(12))
        misc = Self.text(reader, at: 14 + reader.s16be(14))
        let songCount = Int(reader[16]) + 1
        let table = 18 + reader.s16be(18)
        guard table >= 0, table + 4 <= reader.count else {
            throw TuneError.malformed("AY song table lies outside the file")
        }

        for index in 0 ..< songCount {
            let entry = table + index * 4
            // Songs whose table entry is cut off by the end of the file are left out.
            guard entry + 4 <= reader.count else { break }
            var song = Song()
            song.name = Self.text(reader, at: entry + reader.s16be(entry))
            let songData = entry + 2 + reader.s16be(entry + 2)
            if songData >= 0, songData + 14 <= reader.count {
                song.channelMap = [reader[songData], reader[songData + 1], reader[songData + 2], reader[songData + 3]]
                song.lengthFrames = reader.u16be(songData + 4)
                song.fadeFrames = reader.u16be(songData + 6)
                song.highRegister = reader[songData + 8]
                song.lowRegister = reader[songData + 9]
                let points = songData + 10 + reader.s16be(songData + 10)
                song.stack = reader.u16be(points)
                song.initAddress = reader.u16be(points + 2)
                song.interruptAddress = reader.u16be(points + 4)
                song.blocks = Self.blocks(reader, at: songData + 12 + reader.s16be(songData + 12))
            }
            songs.append(song)
        }
        guard songs.contains(where: { $0.blocks.contains { $0.length > 0 } }) else {
            throw TuneError.malformed("AY file has no memory blocks")
        }
        firstSong = Int(reader[17]) < songs.count ? Int(reader[17]) : 0
        if corrected {
            for fix in AYFileCorrection.corrections(for: data) where songs.indices.contains(fix.song) {
                fix.apply(to: &songs[fix.song])
            }
        }
    }

    private static func text(_ reader: ByteReader, at offset: Int) -> String {
        guard offset >= 0, offset < reader.count else { return "" }
        var end = offset
        while end < reader.count, reader[end] != 0, end - offset < 1024 { end += 1 }
        let slice = Array(reader.data[offset ..< end])
        // The collections are mostly ASCII; the rest is Windows Cyrillic, which is what Ay_Emul's users wrote.
        let text = slice.allSatisfy { $0 < 0x80 }
            ? String(decoding: slice, as: UTF8.self)
            : String(data: Data(slice), encoding: .windowsCP1251) ?? String(decoding: slice.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
        return String(text.unicodeScalars.map { $0.value < 0x20 ? " " : Character($0) })
            .trimmingCharacters(in: .whitespaces)
    }

    /// Reads the block list: address, length, relative data offset, ended by a zero address.
    private static func blocks(_ reader: ByteReader, at start: Int) -> [Block] {
        var blocks: [Block] = []
        var position = start
        while position >= 0, position + 2 <= reader.count {
            let address = reader.u16be(position)
            if address == 0 { break }
            var length = reader.u16be(position + 2)
            var offset = position + 4 + reader.s16be(position + 4)
            // In files over 32 KB some rippers let the 16-bit offset wrap: taken as signed it points
            // before the start of the file, taken modulo 64 KB it points at the data. (Ay_Emul cannot
            // read such a block at all.)
            if offset < 0 { offset += 65536 }
            // Ay_Emul's two clamps, in its order: the top of memory, then the end of the file.
            if address + length > 65536 { length = 65536 - address }
            if offset + length > reader.count { length = reader.count - offset }
            blocks.append(Block(address: address, length: max(0, length), fileOffset: offset))
            position += 6
        }
        return blocks
    }

    /// Builds the 64 KB memory image for a song the way the specification and Ay_Emul do:
    /// fill pattern, the player stub at address 0, then the song's blocks on top (a block may overwrite the stub).
    public func buildMemory(song index: Int, into memory: UnsafeMutablePointer<UInt8>) {
        (memory + 0x0000).update(repeating: 0xC9, count: 0x0100) // RET
        (memory + 0x0100).update(repeating: 0xFF, count: 0x3F00) // RST 38h
        (memory + 0x4000).update(repeating: 0x00, count: 0xC000)
        memory[0x38] = 0xFB // EI, so the mode 1 interrupt handler is EI, RET
        guard songs.indices.contains(index) else { return }
        let song = songs[index]

        let stub: [UInt8] = song.freeRunning
            ? [
                0xF3, // DI
                0xCD, 0, 0, // CALL init
                0xCD, UInt8(song.interruptAddress & 0xFF), UInt8(song.interruptAddress >> 8), // loop: CALL interrupt
                0x18, 0xFB, // JR loop
            ]
            : song.interruptAddress != 0
            ? [
                0xF3, // DI
                0xCD, 0, 0, // CALL init
                0xED, 0x56, // loop: IM 1
                0xFB, // EI
                0x76, // HALT
                0xCD, UInt8(song.interruptAddress & 0xFF), UInt8(song.interruptAddress >> 8), // CALL interrupt
                0x18, 0xF7, // JR loop
            ]
            : [
                0xF3, // DI
                0xCD, 0, 0, // CALL init
                0xED, 0x5E, // loop: IM 2
                0xFB, // EI
                0x76, // HALT
                0x18, 0xFA, // JR loop
            ]
        var initAddress = song.initAddress
        for block in song.blocks {
            if initAddress == 0 { initAddress = block.address }
            guard block.length > 0 else { continue }
            bytes.withUnsafeBufferPointer { source in
                (memory + block.address).update(from: source.baseAddress! + block.fileOffset, count: block.length)
            }
        }
        // The stub goes in after the blocks. The format's description and Ay_Emul put it in first, but a
        // few rips carry a whole ROM image as a block starting at address 1, which then overwrites the stub
        // and leaves the tune silent. Nothing in a rip can sensibly want to replace the stub.
        for (offset, byte) in stub.enumerated() { memory[offset] = byte }
        memory[2] = UInt8(initAddress & 0xFF)
        memory[3] = UInt8(initAddress >> 8)
    }
}
