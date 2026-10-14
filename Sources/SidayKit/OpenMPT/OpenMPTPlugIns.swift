// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Derived from OpenMPT, Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and
// Copyright (c) 1997-2003 Olivier Lapicque, used under the BSD 3-Clause licence (see THIRD-PARTY.md):
// how it sends sound through a song's plug-ins (`ProcessPlugins` in `soundlib/Fastmix.cpp`, and
// `ProcessMixOps` in `soundlib/plugins/PlugInterface.cpp`).

/// A song's plug-ins, wired as the file wires them, for a mixer to send its voices through.
///
/// A file gives each plug-in a place, and they are run in the order of their places. A voice is
/// sent to a plug-in or straight to the listener: to its instrument's plug-in if that has one, and
/// otherwise to its channel's. What a plug-in makes goes to the listener, or on to a plug-in in a
/// later place. A plug-in can instead be put on the whole sound, everything that is on its way to
/// the listener when its turn comes (a "master effect"). How much of what a plug-in was given is
/// heard beside what it makes, how the two are put together, and how loud, are the file's to say.
///
/// Only OpenMPT's own effects are here. A place whose plug-in is somebody else's program is as
/// good as empty, as it is to OpenMPT on a machine that has not got the program: what was to go to
/// it goes straight to the listener.
///
/// A mixer makes a tick at a time. Before it mixes one it asks for the tick to be begun; it then
/// adds each voice into the buffer of the plug-in the voice is bound for, left and right in turn,
/// and when it has mixed them all it has the plug-ins run over the tick and what they make added
/// to its own buffer. OpenMPT runs its plug-ins on 512 frames at a time at the most, and so does this.
final class OpenMPTPlugIns {
    /// One plug-in that is played, with how its file wires it in.
    private final class Slot {
        let effect: OpenMPTEffect
        let isMaster: Bool, bypassed: Bool, dryMix: Bool, expandMix: Bool, autoSuspend: Bool
        let mixMode: UInt8
        let gain: Float
        var dryRatio: Float
        /// The place of the plug-in its sound goes on to; less than nought for the listener.
        let output: Int
        /// The sound sent to it in the tick being made, left and right in turn; and so much of
        /// that as it is being given at once, left and right apart and as loud as OpenMPT has it.
        var input: UnsafeMutablePointer<Float>
        let inL: UnsafeMutablePointer<Float>, inR: UnsafeMutablePointer<Float>
        /// What is left of the voices that have ended on their way to it, dying away.
        var clickL: Float = 0, clickR: Float = 0
        /// For a plug-in that is let rest when nothing is coming out of it.
        var silenceBypass = false
        var inputSilenceCount = 0

        init(_ plugIn: ModPlugPlugIn, effect: OpenMPTEffect, capacity: Int) {
            self.effect = effect
            isMaster = plugIn.routingFlags & ModPlugPlugIn.applyToMaster != 0
            bypassed = plugIn.routingFlags & ModPlugPlugIn.bypassed != 0
            dryMix = plugIn.routingFlags & ModPlugPlugIn.dryMix != 0
            expandMix = plugIn.routingFlags & ModPlugPlugIn.expandMix != 0
            autoSuspend = plugIn.routingFlags & ModPlugPlugIn.autoSuspend != 0
            mixMode = plugIn.mixMode
            gain = plugIn.gain == 0 ? 1 : 0.1 * Float(plugIn.gain)
            dryRatio = plugIn.dryRatio
            output = plugIn.outputRouting >= 0x80 && plugIn.outputRouting < 0x80 + 256 ? Int(plugIn.outputRouting) - 0x80 : -1
            input = .allocate(capacity: capacity * 2)
            input.initialize(repeating: 0, count: capacity * 2)
            inL = .allocate(capacity: OpenMPTPlugIns.block)
            inR = .allocate(capacity: OpenMPTPlugIns.block)
            inL.initialize(repeating: 0, count: OpenMPTPlugIns.block)
            inR.initialize(repeating: 0, count: OpenMPTPlugIns.block)
        }

        deinit {
            input.deallocate()
            inL.deallocate()
            inR.deallocate()
        }

        func resetSilence() {
            silenceBypass = false
            inputSilenceCount = 0
        }
    }

    /// As many frames as OpenMPT gives a plug-in at once.
    static let block = 512

    /// The plug-ins that are played, by their places; nil for a place that is empty or whose
    /// plug-in is not here.
    private var slots: [Slot?]
    private let played: [Int]
    private let channelPlugIns: [Int]
    private let level: Float
    private var capacity: Int
    private let mixL: UnsafeMutablePointer<Float>, mixR: UnsafeMutablePointer<Float>
    private let wetL: UnsafeMutablePointer<Float>, wetR: UnsafeMutablePointer<Float>
    /// True once a voice has been mixed in the tick being made.
    private var voicesMixed = false

    /// Nil if none of the file's plug-ins is one that is played.
    init?(_ sound: ModPlugSound) {
        capacity = 4096
        var slots: [Slot?] = []
        for plugIn in sound.plugIns.prefix(250) {
            if let effect = plugIn.makeEffect() {
                effect.resume()
                slots.append(Slot(plugIn, effect: effect, capacity: capacity))
            } else {
                slots.append(nil)
            }
        }
        played = slots.indices.filter { slots[$0] != nil }
        guard !played.isEmpty else { return nil }
        self.slots = slots
        channelPlugIns = sound.channelPlugIns
        level = sound.level > 0 && sound.plugInScale > 0 ? sound.level * sound.plugInScale : 1
        mixL = .allocate(capacity: Self.block)
        mixR = .allocate(capacity: Self.block)
        wetL = .allocate(capacity: Self.block)
        wetR = .allocate(capacity: Self.block)
        for buffer in [mixL, mixR, wetL, wetR] { buffer.initialize(repeating: 0, count: Self.block) }
    }

    deinit {
        mixL.deallocate()
        mixR.deallocate()
        wetL.deallocate()
        wetR.deallocate()
    }

    // MARK: Where a voice goes

    /// The place of the plug-in that a voice is sent to, counted from nought; less than nought if
    /// it goes straight to the listener.
    /// - Parameters:
    ///   - instrumentPlugIn: the plug-in its instrument plays through, counted from 1; nought for
    ///     none, or for a voice that has no instrument.
    ///   - channel: the channel the voice is, or was, a note of.
    @inline(__always) func place(instrumentPlugIn: Int, channel: Int) -> Int {
        var plugIn = instrumentPlugIn
        if plugIn == 0, channel < channelPlugIns.count { plugIn = channelPlugIns[channel] }
        guard plugIn > 0, plugIn <= slots.count, slots[plugIn - 1] != nil else { return -1 }
        return plugIn - 1
    }

    /// The buffer to add a voice bound for that place into, for the tick being made.
    @inline(__always) func buffer(ofPlace place: Int) -> UnsafeMutablePointer<Float> {
        slots[place]?.resetSilence()
        return slots[place]?.input ?? mixL
    }

    /// A voice on its way to that place has ended, leaving this much to die away.
    func addClick(toPlace place: Int, left: Float, right: Float) {
        slots[place]?.clickL += left
        slots[place]?.clickR += right
    }

    /// A voice has been mixed, to a plug-in or not.
    @inline(__always) func voiceMixed() {
        voicesMixed = true
    }

    // MARK: A tick

    /// Makes ready for a tick of so many frames: each plug-in's buffer starts from what is left
    /// of the voices that ended on their way to it.
    func begin(frames: Int) {
        if frames > capacity {
            capacity = frames
            for place in played {
                guard let slot = slots[place] else { continue }
                slot.input.deallocate()
                slot.input = .allocate(capacity: capacity * 2)
                slot.input.initialize(repeating: 0, count: capacity * 2)
            }
        }
        voicesMixed = false
        for place in played {
            guard let slot = slots[place] else { continue }
            slot.effect.tickFrames = frames
            var p = slot.input
            var left = slot.clickL, right = slot.clickR
            if left == 0, right == 0 {
                p.update(repeating: 0, count: frames * 2)
            } else {
                for _ in 0 ..< frames {
                    p[0] = left
                    p[1] = right
                    p += 2
                    left -= left * (1.0 / 4096.0)
                    right -= right * (1.0 / 4096.0)
                }
                // (And at last it is nothing.)
                if abs(left) < 1e-9 { left = 0 }
                if abs(right) < 1e-9 { right = 0 }
            }
            slot.clickL = left
            slot.clickR = right
        }
    }

    /// The voices of a tick have been mixed: runs the plug-ins over it, and leaves in `master`,
    /// left and right in turn, what the listener is to hear.
    func process(master: UnsafeMutablePointer<Float>, frames: Int) {
        let level = level, back = 1 / level
        let mixL = mixL, mixR = mixR, wetL = wetL, wetR = wetR
        var done = 0
        while done < frames {
            let count = min(Self.block, frames - done)

            // What each plug-in was sent, and what is on its way to the listener, as OpenMPT has
            // them: left and right apart, and as loud as OpenMPT makes them.
            var masterHasInput = voicesMixed
            for place in played {
                guard let slot = slots[place] else { continue }
                let from = slot.input + done * 2
                let inL = slot.inL, inR = slot.inR
                for i in 0 ..< count {
                    inL[i] = from[i * 2] * level
                    inR[i] = from[i * 2 + 1] * level
                }
                if !slot.isMaster, !slot.silenceBypass { masterHasInput = true }
            }
            let out = master + done * 2
            for i in 0 ..< count {
                mixL[i] = out[i * 2] * level
                mixR[i] = out[i * 2 + 1] * level
            }
            var pMixL = mixL, pMixR = mixR

            for place in played {
                guard let slot = slots[place] else { continue }
                let plugInputL = slot.inL, plugInputR = slot.inR
                // A master effect before this one may have sent the whole sound here.
                var isMasterMix = false
                if pMixL == plugInputL {
                    isMasterMix = true
                    pMixL = mixL
                    pMixR = mixR
                }
                var pOutL = pMixL, pOutR = pMixR
                if slot.output > place, slot.output < slots.count, let next = slots[slot.output] {
                    if !slot.silenceBypass { next.resetSilence() }
                    pOutL = next.inL
                    pOutR = next.inR
                }

                if slot.isMaster {
                    if !isMasterMix {
                        for i in 0 ..< count {
                            plugInputL[i] += pMixL[i]
                            plugInputR[i] += pMixR[i]
                            pMixL[i] = 0
                            pMixR[i] = 0
                        }
                    }
                    pMixL = pOutL
                    pMixR = pOutR
                    if masterHasInput {
                        // Something is sounding: this one is not to rest, and nor are those after it.
                        slot.resetSilence()
                        var chain = slot, previous = place
                        while chain.output > previous, chain.output < slots.count {
                            previous = chain.output
                            guard let next = slots[previous] else { break }
                            next.resetSilence()
                            chain = next
                        }
                    }
                }

                if slot.bypassed || (slot.autoSuspend && slot.silenceBypass) {
                    for i in 0 ..< count {
                        pOutL[i] += plugInputL[i]
                        pOutR[i] += plugInputR[i]
                    }
                } else {
                    slot.effect.process(inLeft: plugInputL, inRight: plugInputR, outLeft: wetL, outRight: wetR, frames: count)
                    Self.ProcessMixOps(slot, pOutL, pOutR, wetL, wetR, plugInputL, plugInputR, count)
                    slot.inputSilenceCount += count
                    if slot.autoSuspend, slot.inputSilenceCount >= outputSampleRate * 4 {
                        // Four seconds with nothing sent to it: if nothing is coming out either, it rests.
                        var isSilent = true
                        let epsilon = Float.ulpOfOne
                        for i in 0 ..< count where pOutL[i] >= epsilon || pOutL[i] <= -epsilon || pOutR[i] >= epsilon || pOutR[i] <= -epsilon {
                            isSilent = false
                            break
                        }
                        if isSilent { slot.silenceBypass = true } else { slot.inputSilenceCount = 0 }
                    }
                }
            }

            for i in 0 ..< count {
                out[i * 2] = pMixL[i] * back
                out[i * 2 + 1] = pMixR[i] * back
            }
            done += count
        }
    }

    /// Adds what a plug-in made, and what it was given, to where its sound goes, in the way and
    /// the proportion its file says.
    private static func ProcessMixOps(_ slot: Slot, _ pOutL: UnsafeMutablePointer<Float>, _ pOutR: UnsafeMutablePointer<Float>,
                                      _ leftPlugOutput: UnsafeMutablePointer<Float>, _ rightPlugOutput: UnsafeMutablePointer<Float>,
                                      _ plugInputL: UnsafeMutablePointer<Float>, _ plugInputR: UnsafeMutablePointer<Float>, _ numFrames: Int) {
        let mixop = slot.mixMode
        var wetRatio = 1 - slot.dryRatio
        var dryRatio = mixop == 6 ? 1 : slot.dryRatio
        // From nought to one made into from minus one to one.
        if slot.expandMix {
            wetRatio = 2 * wetRatio - 1
            dryRatio = -wetRatio
        }
        wetRatio *= slot.gain
        dryRatio *= slot.gain

        switch mixop {
        case 1: // what it made taken from what it was given
            for i in 0 ..< numFrames {
                pOutL[i] += plugInputL[i] - leftPlugOutput[i] * wetRatio
                pOutR[i] += plugInputR[i] - rightPlugOutput[i] * wetRatio
            }
        case 2: // what it was given taken from what it made
            for i in 0 ..< numFrames {
                pOutL[i] += leftPlugOutput[i] - plugInputL[i] * dryRatio
                pOutR[i] += rightPlugOutput[i] - plugInputR[i] * dryRatio
            }
        case 3: // the same taken from where it goes
            for i in 0 ..< numFrames {
                pOutL[i] -= leftPlugOutput[i] - plugInputL[i] * wetRatio
                pOutR[i] -= rightPlugOutput[i] - plugInputR[i] * wetRatio
            }
        case 4: // the middle of it all taken away
            for i in 0 ..< numFrames {
                let middle = (pOutL[i] + plugInputL[i] + pOutR[i] + plugInputR[i]) * 0.5
                pOutL[i] -= middle - leftPlugOutput[i] * wetRatio + middle - plugInputL[i]
                pOutR[i] -= middle - rightPlugOutput[i] * wetRatio + middle - plugInputR[i]
            }
        case 5: // more of it to one side
            if slot.expandMix {
                wetRatio /= 2
                dryRatio /= 2
            }
            for i in 0 ..< numFrames {
                pOutL[i] += wetRatio * (leftPlugOutput[i] - plugInputL[i]) + dryRatio * (plugInputR[i] - rightPlugOutput[i])
                pOutR[i] += dryRatio * (leftPlugOutput[i] - plugInputL[i]) + wetRatio * (plugInputR[i] - rightPlugOutput[i])
            }
        default: // so much of each
            for i in 0 ..< numFrames {
                pOutL[i] += leftPlugOutput[i] * wetRatio + plugInputL[i] * dryRatio
                pOutR[i] += rightPlugOutput[i] * wetRatio + plugInputR[i] * dryRatio
            }
        }
        // What it was given heard as well, whole, if the file says so.
        if slot.dryMix, mixop != 6 {
            for i in 0 ..< numFrames {
                pOutL[i] += plugInputL[i]
                pOutR[i] += plugInputR[i]
            }
        }
    }

    // MARK: Settings changed while playing

    /// Sets one of a plug-in's settings, from nought to one. Nothing is done for a place that has
    /// no plug-in that is played, or a setting it has not got.
    func setParameter(place: Int, _ index: Int, _ value: Float) {
        guard place >= 0, place < slots.count, let slot = slots[place], index >= 0, index < slot.effect.parameterCount else { return }
        slot.effect.setParameter(index, value)
    }

    func parameter(place: Int, _ index: Int) -> Float {
        guard place >= 0, place < slots.count, let slot = slots[place], index >= 0, index < slot.effect.parameterCount else { return 0 }
        return slot.effect.parameter(index)
    }

    /// How much of what the plug-in in a place is given is heard beside what it makes; nought for
    /// an empty place.
    func dryRatio(place: Int) -> Float {
        guard place >= 0, place < slots.count, let slot = slots[place] else { return 0 }
        return slot.dryRatio
    }

    /// Sets how much of what a plug-in is given is heard beside what it makes.
    func setDryRatio(place: Int, _ ratio: Float) {
        guard place >= 0, place < slots.count, let slot = slots[place] else { return }
        slot.dryRatio = max(0, min(1, ratio))
    }

    /// True if the place has a plug-in that is played.
    func plays(place: Int) -> Bool {
        place >= 0 && place < slots.count && slots[place] != nil
    }
}
