// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayEightBit
@testable import SidayFoundation
@testable import SidayKit
@testable import SidayMIDI
import Testing

// Fast checks of MIDI files: how they are read, timed and looped, what they are taken to be written for,
// and the FM synthesiser's writes for a note. The thorough check is made outside the package, against
// libADLMIDI with the same bank and volume model: the two write the same registers at the same samples.

private func be32(_ value: Int) -> [UInt8] { [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
private func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

/// A track of the given events (each a delta time's bytes and then the event), and its End of Track.
private func track(_ events: [UInt8], end: Bool = true) -> [UInt8] {
    let body = events + (end ? [0x00, 0xFF, 0x2F, 0x00] : [])
    return Array("MTrk".utf8) + be32(body.count) + body
}

private func smf(format: Int = 1, division: Int = 96, _ tracks: [[UInt8]]) -> [UInt8] {
    Array("MThd".utf8) + be32(6) + be16(format) + be16(tracks.count) + be16(division) + tracks.flatMap { $0 }
}

/// Tempo of a quarter note a second, then middle C on channel 1 at tick 96 (a second in) held for a beat.
private let oneNote: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40, 0x60, 0x90, 60, 100, 0x60, 0x80, 60, 0]

@Test func midiFileIsReadWithRunningStatusSystemExclusiveAndRowsInOrder() throws {
    // At tick 0: a note started on channel 2 and ended by running status, a system exclusive message,
    // an escape, and a program change; the end of the note comes before its start in the row.
    let events: [UInt8] = [0x00, 0x91, 64, 90, 0x00, 64, 0, 0x00, 0xF0, 0x03, 0x7E, 0x7F, 0xF7, 0x00, 0xF7, 0x02, 0xF8, 0xF7,
                           0x00, 0xC1, 5, 0x10, 0x91, 67, 80, 0x10, 0x81, 67, 0]
    let file = try MIDIFile(smf([track([0x00, 0xFF, 0x03, 0x04] + Array("Song".utf8)), track(events)]))
    #expect(file.format == 1)
    #expect(file.title == "Song")
    #expect(file.songs.count == 1)
    let second = file.songs[0].tracks[1]
    let first = second.events[second.rows[1].events].map(\.kind)
    // As libADLMIDI orders them: messages, then ends, then programs, then starts; and a note ended
    // before it was started in the same row is ended after.
    #expect(first == [.systemExclusive, .systemExclusive, .program, .noteOn, .noteOff])
    #expect(second.events[second.rows[1].events].first?.bytes == [0xF0, 0x7E, 0x7F, 0xF7])
    #expect(second.rows[1].delay == 0x10)
    // The song starts with the start of the song, in its first track's first row.
    #expect(file.songs[0].tracks[0].events.first?.kind == .songBegins)
}

@Test func midiFormatTwoHasASongForEachTrackWithTheConductorsTempo() throws {
    // As XMI2MID wrote them: a first track of the tempo alone, then a track for each song.
    let conductor = track([0x00, 0xFF, 0x51, 0x03, 0x1E, 0x84, 0x80])
    let one = track([0x00, 0xFF, 0x03, 0x03] + Array("One".utf8) + [0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0])
    let two = track([0x00, 0xFF, 0x03, 0x03] + Array("Two".utf8) + [0x00, 0x90, 62, 100, 0x81, 0x40, 0x80, 62, 0])
    let file = try MIDIFile(smf(format: 2, [conductor, one, two]))
    #expect(file.songs.count == 2)
    #expect(file.songs.map(\.title) == ["One", "Two"])
    let renderer = try TuneLoader.load(smf(format: 2, [conductor, one, two]), format: .mid)
    #expect(renderer.subsongCount == 2)
    // Two seconds a beat: a beat, and two, each with the second after the last message.
    #expect(abs(renderer.songs[0].length! - 3.0) < 0.001)
    #expect(abs(renderer.songs[1].length! - 5.0) < 0.001)
}

@Test func midiWrappedInRIFFIsRead() throws {
    let inner = smf(format: 0, [track(oneNote)])
    let riff = Array("RIFF".utf8) + [UInt8](repeating: 0, count: 4) + Array("RMID".utf8) + Array("data".utf8)
        + [UInt8(inner.count & 0xFF), UInt8(inner.count >> 8), 0, 0] + inner
    let renderer = try TuneLoader.load(riff, format: TuneFormat(fileExtension: "rmi")!)
    #expect(renderer.info.format == "MID")
    // Heard from a twentieth of a second before its note, a second in, to a second after its end.
    #expect(abs(renderer.knownLength! - 2.05) < 0.001)
}

@Test func midiNoteIsTimedToTheSampleAndWrittenAsWindows9xDid() throws {
    let renderer = try MIDIFMRenderer(smf(format: 0, [track(oneNote)]), companion: nil)
    let writes = renderer.registerWrites(seconds: 3)
    // Middle C: the Windows 9x driver's F-number 0x2AD in block 3, with the key on, on the first channel.
    let keyOn = try #require(writes.first { $0.register == 0xB0 && $0.value & 0x20 != 0 })
    #expect(keyOn.value == 0x2E)
    #expect(writes.contains { $0.register == 0xA0 && $0.value == 0xAD && $0.sample == keyOn.sample })
    // A second in, at the chip's 49,716 samples a second; libADLMIDI's chip runs one sample behind.
    #expect(keyOn.sample == 49716 - 1)
    // The note ended a beat later: its key off.
    let keyOff = try #require(writes.first { $0.register == 0xB0 && $0.value == 0x0E && $0.sample > keyOn.sample })
    #expect(keyOff.sample == 2 * 49716 - 1)
}

@Test func midiEndsAfterItsLastMessageNotAtALateEndOfTrack() throws {
    // The second track's End of Track is an hour later than anything in it.
    let late = track([0x00, 0xC0, 0x01, 0x83, 0xE0, 0x80, 0x00, 0xFF, 0x2F, 0x00], end: false)
    let renderer = try TuneLoader.load(smf([track(oneNote), late]), format: .mid)
    #expect(abs(renderer.knownLength! - 2.05) < 0.001)
}

@Test func midiLoopsByTheAudioInterfaceLibrarysForAndNext() throws {
    // A FOR for ever at the start and a NEXT at the end, after the last note: the song goes round.
    let looped: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40, 0x00, 0xB0, 116, 0, 0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0, 0x00, 0xB0, 117, 127]
    let renderer = try TuneLoader.load(smf(format: 0, [track(looped)]), format: .mid)
    #expect(renderer.endsByLooping)
    #expect(abs(renderer.knownLength! - 1.0) < 0.001)
    #expect(abs(renderer.loopLength! - 1.0) < 0.001)
    var buffer = [Float](repeating: 0, count: 48000 * 2 * 3)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 48000 * 3) }
    #expect(renderer.loopCount == 2)

    // The same with a note after the NEXT: a game's part looped until the game moves on, which is
    // played through.
    // A marker "loopStart" a beat in, and no "loopEnd": the song goes round from there at its end.
    let marked: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40, 0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0,
                           0x00, 0xFF, 0x06, 0x09] + Array("loopStart".utf8) + [0x00, 0x90, 62, 100, 0x60, 0x80, 62, 0]
    let markers = try TuneLoader.load(smf(format: 0, [track(marked)]), format: .mid)
    #expect(markers.endsByLooping)
    #expect(abs(markers.knownLength! - 2.0) < 0.001)
    #expect(abs(markers.loopLength! - 1.0) < 0.001)

    let through = looped + [0x60, 0x90, 64, 100, 0x60, 0x80, 64, 0]
    let once = try TuneLoader.load(smf(format: 0, [track(through)]), format: .mid)
    #expect(!once.endsByLooping)
    #expect(abs(once.knownLength! - 4.0) < 0.001)
}

private func sysex(_ bytes: [UInt8]) -> [UInt8] { [0x00, 0xF0, UInt8(bytes.count)] + bytes }
private let gsReset: [UInt8] = [0x41, 0x10, 0x42, 0x12, 0x40, 0x00, 0x7F, 0x00, 0x41, 0xF7]
private let gmOn: [UInt8] = [0x7E, 0x7F, 0x09, 0x01, 0xF7]
private let xgReverb: [UInt8] = [0x43, 0x10, 0x4C, 0x02, 0x01, 0x00, 0x01, 0x01, 0xF7]
private let mt32Patch: [UInt8] = [0x41, 0x10, 0x16, 0x12, 0x03, 0x00, 0x00, 0x00, 0x7D, 0xF7]

@Test func midiSaysWhatItWasWrittenForFromItsOwnMessages() throws {
    func origin(_ events: [UInt8], companion: [[UInt8]] = []) throws -> MIDIOrigin {
        MIDIOrigin(try MIDIFile(smf(format: 0, [track(events + oneNote)])), companion: companion)
    }
    let none = try origin([])
    #expect(none.standard == .generalMIDI && !none.declared && !none.byCompanion)
    #expect(try origin(sysex(gsReset)).standard == .gs)
    // General MIDI's System On, with a reverb for an XG synthesiser's owners after it, is General MIDI.
    #expect(try origin(sysex(gmOn) + sysex(xgReverb)).standard == .generalMIDI)
    #expect(try origin(sysex(mt32Patch)).standard == .mt32)
    // A bank for an MT-32 beside a file of no messages of its own makes it an MT-32 file; beside a
    // General MIDI one, it does not.
    let bank = [[0xF0] + mt32Patch]
    #expect(try origin([], companion: bank).standard == .mt32)
    #expect(try origin([], companion: bank).byCompanion)
    #expect(try origin(sysex(gmOn), companion: bank).standard == .generalMIDI)

    let mt32 = try TuneLoader.load(smf(format: 0, [track(sysex(mt32Patch) + oneNote)]), format: .mid)
    #expect(mt32.info.detail.hasPrefix("Written for the Roland MT-32"))
    #expect(mt32.info.shortfalls.count == 1)
    #expect(mt32.info.playedOtherwiseWith == [.mt32, .sc55])
    let plain = try TuneLoader.load(smf(format: 0, [track(oneNote)]), format: .mid)
    #expect(plain.info.detail.hasPrefix("General MIDI;"))
    #expect(plain.info.shortfalls == ["It is played on FM, as a Sound Blaster played General MIDI. Given the ROMs of a Roland SC-55 once (dropped on the player, or with --roms), siday keeps them and plays it on the Sound Canvas, the General MIDI synthesiser of its day."])
    #expect(plain.info.chips == [.opl3])
    #expect(plain.info.playedOtherwiseWith == [.sc55])
}

@Test func midiCompanionMessagesAreSentBeforeTheSong() throws {
    // A file of messages back to back, as a .syx file is.
    let syx = [0xF0] + mt32Patch + [0xF0] + mt32Patch
    #expect(MIDIFile.messages(ofCompanion: syx).count == 2)
    // And a MIDI file of them alone.
    #expect(MIDIFile.messages(ofCompanion: smf(format: 0, [track(sysex(mt32Patch) + sysex(mt32Patch))])).count == 2)
    #expect(Companions.wanted(for: .mid, fileName: "LB2MT.MID").first?.names.first == "LB2MT.syx")
    #expect(Companions.are(fileName: "WC1.SYX"))
    #expect(Companions.are(fileName: "sysexmain.mid"))

    // Sent first, as fast as a MIDI cable carries them with a pause after each: the song starts after.
    let file = try MIDIFile(smf(format: 0, [track(oneNote)]))
    let sequencer = MIDISequencer(file.songs[0], of: file, prelude: MIDIFile.messages(ofCompanion: syx))
    #expect(abs(sequencer.preludeLength - 2 * (11.0 * 10 / 31250 + 0.04)) < 1e-9)
    // What comes before the first note is played unheard, the setup with it.
    let measured = MIDISequencer.measure(file.songs[0], of: file, prelude: MIDIFile.messages(ofCompanion: syx), granularity: 1.0 / 49716)
    #expect(abs(measured.firstNote! - (1.0 + sequencer.preludeLength)) < 0.001)
    let renderer = try MIDIFMRenderer(smf(format: 0, [track(oneNote)]), companion: syx)
    #expect(abs(renderer.knownLength! - 2.05) < 0.001)
}

@Test func midiIsHeardFromJustBeforeItsFirstNote() throws {
    // A note a second in: heard a twentieth of a second after the song is.
    let renderer = try MIDIFMRenderer(smf(format: 0, [track(oneNote)]), companion: nil)
    var buffer = [Float](repeating: 0, count: 48000 * 2)
    buffer.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress!, frames: 48000) }
    let first = try #require(buffer.firstIndex { $0 != 0 }) / 2
    #expect(abs(first - 2400) < 48)

    // A note stopped by all notes off a thousandth of a second after it is struck, as Wing Commander
    // II's music does before it begins, and a note of velocity 1, are not the music's first note.
    let marks: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40, 0x00, 0x92, 48, 64, 0x00, 0x99, 40, 1, 0x01, 0xB2, 123, 0]
    let file = try MIDIFile(smf(format: 0, [track(marks + oneNote.dropFirst(7))]))
    let measured = MIDISequencer.measure(file.songs[0], of: file, prelude: [], granularity: 1.0 / 32000)
    // (All notes off a tick after the notes, and the music's note a beat after that.)
    #expect(abs(measured.firstNote! - 97.0 / 96) < 0.001)
}

@Test func midiDamagedOrEmptyIsSaidOrRefused() throws {
    // A track cut short in the middle of its data.
    var cut = smf([track(oneNote), track([0x00, 0x90, 60, 100, 0x60, 0x80, 60, 0])])
    cut.removeLast(6)
    let renderer = try TuneLoader.load(cut, format: .mid)
    #expect(renderer.info.shortfalls.first == "The file is cut short: one of its tracks ends early.")
    // A file of messages alone has nothing to be heard.
    #expect(throws: TuneError.self) { try TuneLoader.load(smf(format: 0, [track(sysex(mt32Patch))]), format: .mid) }
    #expect(throws: TuneError.self) { try TuneLoader.load(Array("MThd".utf8) + [0, 0], format: .mid) }
}
