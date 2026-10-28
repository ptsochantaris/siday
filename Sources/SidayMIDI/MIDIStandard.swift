// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// The kind of synthesiser a MIDI file was written for, as far as the file says.
///
/// A file says so in its system exclusive messages, which are each for one maker's synthesisers: a GS
/// reset or GS parameters for a Roland Sound Canvas, Yamaha's XG System On for an XG synthesiser,
/// parameters sent to the MT-32's model number for an MT-32 or its kind (the LAPC-I, the CM-32L), the
/// General MIDI System On for any General MIDI synthesiser. A file with none of these was written for
/// General MIDI, the common ground of them all, or so it is taken.
public enum MIDIStandard: String, Sendable, CaseIterable {
    case generalMIDI, gs, xg, mt32

    /// What it is called, for a listener.
    public var name: String {
        switch self {
        case .generalMIDI: "General MIDI"
        case .gs: "Roland GS (the Sound Canvas)"
        case .xg: "Yamaha XG"
        case .mt32: "the Roland MT-32"
        }
    }
}

/// What a file's system exclusive messages say of the synthesiser it was written for, and those of the
/// file of them beside it, if it has one (see `MIDIFile.messages(ofCompanion:)`).
///
/// It is read from the files alone, never from where they are kept: copies of the same game's music
/// made for an MT-32 and for General MIDI are often kept side by side, and only what is in them tells
/// them apart.
public struct MIDIOrigin: Sendable, Equatable {
    public var standard: MIDIStandard
    /// True if the file says so outright, by a reset or a System On, or by setting the synthesiser up, or
    /// a file beside it does; false for a file taken to be General MIDI because nothing says otherwise.
    public var declared: Bool
    /// True if what says so is the file beside it, not the file itself.
    public var byCompanion: Bool
    /// How many of the system exclusive messages are for an MT-32 (DT1, to model 16): the sounds and
    /// set-up of the MT-32 that the music was written with.
    public var mt32Messages: Int

    /// Counts of the messages of each kind in one run of them.
    struct Counts {
        var xgOn = 0, xg = 0, gsReset = 0, gs = 0, gmOn = 0, mt32 = 0

        init(_ messages: [[UInt8]]) {
            for message in messages where message.count >= 5 && message[0] == 0xF0 {
                switch message[1] {
                case 0x7E:
                    // Universal, not in real time: General MIDI System On is 09 01.
                    if message[3] == 0x09, message[4] == 0x01 { gmOn += 1 }
                case 0x41:
                    // Roland: the model is the third byte after the maker's; a DT1 (12) to 40 00 7F is
                    // the GS reset.
                    switch message[3] {
                    case 0x42:
                        if message.count >= 8, message[4] == 0x12, message[5] == 0x40, message[6] == 0x00, message[7] == 0x7F {
                            gsReset += 1
                        } else {
                            gs += 1
                        }
                    case 0x45: gs += 1
                    case 0x16: mt32 += 1
                    default: break
                    }
                case 0x43:
                    // Yamaha: XG's model is 4C, sent to a device of 1n; System On is a 0 to 00 00 7E.
                    if message[2] & 0xF0 == 0x10, message[3] == 0x4C {
                        if message.count >= 8, message[4] == 0, message[5] == 0, message[6] == 0x7E { xgOn += 1 } else { xg += 1 }
                    }
                default:
                    break
                }
            }
        }

        /// What they say, if anything: a reset or a System On first, as a synthesiser takes it, then
        /// the parameters of one kind. (A Sound Canvas's reverb set by a file that has begun with
        /// General MIDI's System On, or an XG synthesiser's, as many did for the owners of either, does
        /// not make it a GS or an XG file; and a file that sets up an MT-32 beside a GS reset, as Roland's
        /// own of the time did for an MT-32 on the same cable, is a GS file.)
        var standard: MIDIStandard? {
            if xgOn > 0 { return .xg }
            if gsReset > 0 { return .gs }
            if gmOn > 0 { return .generalMIDI }
            if gs > 0 { return .gs }
            if xg > 0 { return .xg }
            if mt32 > 0 { return .mt32 }
            return nil
        }
    }

    /// Reads it from a file's own system exclusive messages, and those of a file of them beside it.
    public init(_ file: MIDIFile, companion: [[UInt8]] = []) {
        let own = Counts(file.systemExclusiveMessages)
        mt32Messages = own.mt32
        byCompanion = false
        if let standard = own.standard {
            self.standard = standard
            declared = true
            return
        }
        // A file of system exclusive messages beside it counts only for a file that sends none of its
        // own: a bank for an MT-32 beside a General MIDI file is for an MT-32's owner who plays the
        // General MIDI music on it.
        let besides = Counts(companion)
        if !file.sendsSystemExclusive, besides.mt32 > 0 {
            standard = .mt32
            declared = true
            byCompanion = true
            mt32Messages = besides.mt32
            return
        }
        standard = .generalMIDI
        declared = false
    }
}
