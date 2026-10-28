// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// One thing that happens in a MIDI file: a message for a synthesiser (a note, a controller, a system
/// exclusive message), or something said to the sequencer that plays the file (a tempo, the end of
/// a track, the start of the song).
public struct MIDIEvent: Sendable, Equatable {
    public enum Kind: UInt8, Sendable {
        // The channel messages, by the high four bits of their status bytes.
        case noteOff = 0x8, noteOn = 0x9, polyTouch = 0xA, controller = 0xB, program = 0xC, channelTouch = 0xD, pitchBend = 0xE
        /// A system exclusive message, whole: `bytes` begins with its F0 (or the F7 of an escape) and
        /// has its ending F7 if the file gave it one.
        case systemExclusive = 0xF0
        /// A tempo: `tempo` microseconds to a quarter note.
        case tempo = 0x51
        case endOfTrack = 0x2F
        /// Any other meta event: `meta` is its type, `bytes` its data (a text, for the types 1 to 9).
        case meta = 0xFF
        /// Not in the file: the first thing in its first track, where a synthesiser is set as it is at
        /// the start of a song.
        case songBegins = 0x00
        /// A status byte of the system's own (F1 to FE): played as nothing.
        case system = 0xF1
    }

    public var kind: Kind
    /// The channel, 0 to 15, of a channel message.
    public var channel: UInt8 = 0
    /// The two data bytes of a channel message: a note and its velocity, a controller and its value,
    /// a program, a pressure; and a bend's low seven bits and its high seven.
    public var data1: UInt8 = 0, data2: UInt8 = 0
    /// The type of a meta event.
    public var meta: UInt8 = 0
    /// For a marker that marks where a song loops, as libADLMIDI reads it: 1 for "loopStart", 2 for
    /// "loopEnd"; nought for any other event.
    public var loopMark: UInt8 = 0
    /// For a tempo, microseconds to a quarter note.
    public var tempo: UInt32 = 0
    /// A system exclusive message, or a meta event's data.
    public var bytes: [UInt8] = []

    public init(kind: Kind, channel: UInt8 = 0, data1: UInt8 = 0, data2: UInt8 = 0) {
        self.kind = kind
        self.channel = channel
        self.data1 = data1
        self.data2 = data2
    }

    /// True for a message to a synthesiser on one of its channels.
    @inlinable public var isChannelMessage: Bool { kind.rawValue >= 0x8 && kind.rawValue <= 0xE }

    /// The message as it is sent down a MIDI cable, for a channel message: its status byte and its one
    /// or two data bytes.
    public var shortMessage: [UInt8] {
        guard isChannelMessage else { return [] }
        let status = kind.rawValue << 4 | channel
        return kind == .program || kind == .channelTouch ? [status, data1] : [status, data1, data2]
    }

    /// Which comes first of the things that happen at the same moment in one track, lowest first, as
    /// libADLMIDI's sequencer orders them: a system exclusive message before a note is ended, that
    /// before a controller or a program is changed, and that before a note is started; the start of
    /// the song before them all, a tempo after them, and the end of the track last of all.
    var priority: Int {
        switch kind {
        case .songBegins: -1
        case .systemExclusive: 0
        case .noteOff: 1
        case .polyTouch, .controller, .program, .channelTouch, .pitchBend: 3
        case .noteOn: 4
        case .endOfTrack: 20
        // (A marker, and so a loop's, before the messages; and a device's name.)
        case .meta where meta == 0x06 || meta == 0x09: 2
        case .tempo, .meta, .system: 10
        }
    }
}

/// What a sequencer plays a song to: a synthesiser, which is told each event as its moment comes.
/// (See `MIDISequencer`.) Only channel messages, system exclusive messages and the start of the song
/// are told: tempos and the like are the sequencer's own.
public protocol MIDIReceiver: AnyObject {
    /// One event, as it comes: a channel message or a system exclusive message.
    func receive(_ event: MIDIEvent)
    /// The song starts, or starts again: everything a song may have changed is put back as it was.
    func songBegins()
}
