// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

extension IT2Module {
    /// What an IT file asks for that Impulse Tracker's replayer does not play as it asks: see
    /// `TuneInfo.shortfalls`.
    ///
    /// Most of it is what later trackers put in an IT file. ModPlug Tracker and OpenMPT play an
    /// instrument through a plug-in, which is played here only if it is one of OpenMPT's own
    /// (see `ModPlugSound`), and have commands and ways of packing a sample of their own;
    /// and Impulse Tracker itself could send an instrument's notes to a MIDI synthesiser, which is
    /// not here to play them. (Most files with such an instrument are ModPlug Tracker's, which
    /// marked the drums of a MIDI file it had read that way, and went on playing their samples.
    /// Impulse Tracker's replayer does not, so here they are silent.) Only what the patterns use
    /// is counted.
    func shortfalls() -> [String] {
        // The patterns, gone through as the replayer unpacks them: which instruments they play, on
        // which notes, and which commands they have that are not Impulse Tracker's.
        var usedInstrument = [Bool](repeating: false, count: 256)
        var usedNotes = [Bool](repeating: false, count: 256 * 120)
        var commands = Shortfall.Kinds()
        for index in 0 ..< patternLimit where hasPattern(index) {
            let pattern = pattern(index)
            var masks = [UInt8](repeating: 0, count: 64)
            var notes = [UInt8](repeating: 255, count: 64), instruments = [UInt8](repeating: 0, count: 64)
            var lastCommands = [UInt8](repeating: 0, count: 64), lastValues = [UInt8](repeating: 0, count: 64)
            var at = 0, row = 0
            func next() -> UInt8 {
                at += 1
                return at <= pattern.data.count ? pattern.data[at - 1] : 0
            }
            while row < Int(pattern.rows), at < pattern.data.count {
                let what = next()
                if what == 0 {
                    row += 1
                    continue
                }
                let channel = (Int(what & 0x7F) - 1) & 63
                if what & 0x80 != 0 { masks[channel] = next() }
                let mask = masks[channel]
                if mask & 1 != 0 { notes[channel] = next() }
                if mask & 2 != 0 { instruments[channel] = next() }
                if mask & 4 != 0 { _ = next() }
                if mask & 8 != 0 {
                    lastCommands[channel] = next()
                    lastValues[channel] = next()
                }
                // A note is played on the instrument the channel was last given.
                if mask & 0x33 != 0, instruments[channel] != 0 {
                    usedInstrument[Int(instruments[channel])] = true
                    if mask & 0x11 != 0, notes[channel] < 120 { usedNotes[Int(instruments[channel]) * 120 + Int(notes[channel])] = true }
                }
                if mask & 0x88 != 0 {
                    let command = lastCommands[channel]
                    // (Playing a sample backwards, S9F, is nothing to Impulse Tracker, and is done
                    // for a file that another tracker made. The command after Z is ModPlug Tracker's.)
                    if command == 28, !madeByModPlug { commands.note(1) }
                    if command == 27 || (command >= 29 && command <= 31) { commands.note(2) }
                }
            }
        }

        var sentences: [String] = []
        var usedSample = [Bool](repeating: false, count: 256)
        if usesInstruments {
            var unheard = 0, midi = 0
            for number in 1 ... 255 where usedInstrument[number] && number <= InsNum {
                let instrument = instrument(number - 1)
                var hasSample = false
                for note in 0 ..< 120 where usedNotes[number * 120 + note] {
                    let sample = Int(instrument.SmpNoteTable[note] >> 8)
                    guard sample > 0 else { continue }
                    usedSample[sample] = true
                    if let s = self.sample(sample - 1), s.Length > 0 { hasSample = true }
                }
                if extras.playsThroughPlugIn(instrument: number - 1) {
                    // (One with a sample is heard, through its plug-in or without it; and a plug-in
                    // that is an effect makes no sound of a note, here or in OpenMPT.)
                    if !hasSample, !extras.isPlayed(plugIn: extras.instrumentPlugIns[number - 1]) { unheard += 1 }
                } else if instrument.MIDIChn >= 1, instrument.MIDIChn <= 17, !madeByModPlug {
                    // (Impulse Tracker sends such an instrument's notes to the synthesiser and
                    // plays no sample for them, whether it has one or not. ModPlug Tracker and
                    // OpenMPT played the sample, and so a file of theirs has it played.)
                    midi += 1
                }
            }
            sentences.append(contentsOf: Shortfall.plugIns(unheard: unheard, bare: 0, channels: 0))
            if midi > 0 {
                sentences.append(Shortfall.some(midi, one: "instruments is sent to a MIDI synthesiser, and is not heard.", many: "instruments are sent to a MIDI synthesiser, and are not heard."))
            }
        } else {
            usedSample = usedInstrument
        }
        let leftOut = extras.plugInsLeftOut
        if let sentence = Shortfall.plugInsLeftOut(leftOut.names, of: leftOut.all) { sentences.append(sentence) }

        let silent = samplesNotRead.filter { $0 + 1 < usedSample.count && usedSample[$0 + 1] }.count
        if silent > 0 {
            sentences.append(Shortfall.some(silent, one: "samples is kept in a form this player does not read, and is silent.",
                                            many: "samples are kept in a form this player does not read, and are silent."))
        }
        if let sentence = Shortfall.commandsLeftOut(commands.named(["playing a sample backwards", "a smooth change to a filter or a plug-in's setting",
                                                                    "commands of OpenMPT's own"]),
                                                    why: "which Impulse Tracker did not have") {
            sentences.append(sentence)
        }
        if let sentence = cutShort.sentence { sentences.append(sentence) }
        return sentences
    }
}
