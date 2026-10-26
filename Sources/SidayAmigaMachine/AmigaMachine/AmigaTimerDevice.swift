// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written from what timer.device's unit of frames is documented to do (Commodore's Autodocs) and from when
// Kickstart 1.3's (34.1) was measured to reply on an A500, as Copperline runs it: none of its code is in it.

/// timer.device's unit of frames (UNIT_VBLANK), for `AmigaExec`, as Kickstart 1.3's keeps it: its time goes
/// on by a fiftieth of a second as each frame begins (ExecBase's VBlankFrequency), and a wait (TR_ADDREQUEST)
/// is replied from the frame's interrupt at the first frame by which so many fiftieths have gone by since
/// it was sent as make up the time it asked for. So one of less than a fiftieth (Electronic Arts' players
/// ask for 16,666 microseconds) is replied as the next frame begins, wherever in its frame it was sent: as
/// measured, sent as late as line 283.
struct AmigaTimerDevice {
    /// The waits sent and not yet replied: the request, and the frames still to begin before it is.
    private var waits: [(request: UInt32, frames: UInt64)] = []

    /// A wait sent, for the seconds and microseconds of its timeval (tv_secs, tv_micro).
    mutating func add(_ request: UInt32, _ m: borrowing AmigaMachine) {
        let micros = UInt64(m.peek32(request + 32)) * 1_000_000 + UInt64(m.peek32(request + 36))
        waits.append((request, max(1, (micros + 19999) / 20000)))
    }

    /// The wait taken back, if it is waiting (AbortIO).
    mutating func take(_ request: UInt32) -> Bool {
        guard let i = waits.firstIndex(where: { $0.request == request }) else { return false }
        waits.remove(at: i)
        return true
    }

    /// A frame begins: the waits it ends, taken out, in the order they were sent.
    mutating func frame() -> [UInt32] {
        var done: [UInt32] = []
        var i = 0
        while i < waits.count {
            waits[i].frames -= 1
            if waits[i].frames == 0 {
                done.append(waits[i].request)
                waits.remove(at: i)
            } else {
                i += 1
            }
        }
        return done
    }
}
