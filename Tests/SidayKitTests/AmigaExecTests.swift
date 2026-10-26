// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

@testable import SidayKit
@testable import SidayAmigaMachine
@testable import SidayChips
@testable import SidayFoundation
@testable import SidayM68000
import Foundation
import Testing

// Checks of exec's own system on the host of DeliTracker's players (`AmigaExec`), with little programs
// assembled here by hand: tasks switched as they wait and as they are signalled, from a task and from an
// interrupt; messages put, got and replied; memory given and taken back; timer.device's wait replied at a
// frame; and an audio.device write's writes to Paula, in order. The thorough check is made outside the
// package: what Electronic Arts' players write to Paula, tick by tick, against recordings of them on an
// A500 (the dump below).

// exec.library's routines, by their offsets from its base (as JSR d16(A6) has them).
private let allocMem: UInt16 = 0xFF3A, freeMem: UInt16 = 0xFF2E, addTask: UInt16 = 0xFEE6, findTask: UInt16 = 0xFEDA
private let wait: UInt16 = 0xFEC2, signal: UInt16 = 0xFEBC, allocSignal: UInt16 = 0xFEB6, addPort: UInt16 = 0xFE9E
private let putMsg: UInt16 = 0xFE92, getMsg: UInt16 = 0xFE8C, replyMsg: UInt16 = 0xFE86, waitPort: UInt16 = 0xFE80
private let openDevice: UInt16 = 0xFE44, waitIO: UInt16 = 0xFE26

/// A custom module of exec's own system: `initPlayer` and `interrupt` its DTP_InitPlayer and DTP_Interrupt,
/// each given the program to add its code and data to (after the routine itself, with labels of its own).
private func execModule(initPlayer: (inout HunkProgram) -> Void, interrupt: (inout HunkProgram) -> Void = { $0.w(0x4E75) },
                        rest: (inout HunkProgram) -> Void = { _ in }) -> [UInt8] {
    var p = HunkProgram()
    p.w(0x70FF, 0x4E75, 0x4445, 0x4C49, 0x5249, 0x554D) // MOVEQ #-1,D0; RTS; "DELIRIUM"
    p.address("tags")
    p.label("tags")
    p.long(DeliTag.customPlayer)
    p.long(0)
    p.long(DeliTag.interrupt)
    p.address("interrupt")
    p.long(DeliTag.initPlayer)
    p.address("initPlayer")
    p.long(0)
    p.label("initPlayer")
    initPlayer(&p)
    p.label("interrupt")
    interrupt(&p)
    rest(&p)
    return p.file()
}

/// A task's control block (92 bytes) at `label`, of priority `priority`, with a stack of 256 bytes after it.
private func task(_ p: inout HunkProgram, _ label: String, priority: UInt8) {
    p.label(label)
    p.w(0, 0, 0, 0, 0x0100 | UInt16(priority), 0, 0) // ln_Succ, ln_Pred, ln_Type NT_TASK, ln_Pri, ln_Name
    for _ in 0 ..< 20 { p.w(0) } // tc_Flags to tc_TrapCode
    p.address(label + "Top") // tc_SPReg
    p.address(label + "Stack") // tc_SPLower
    p.address(label + "Top") // tc_SPUpper
    for _ in 0 ..< 13 { p.w(0) } // tc_Switch to tc_UserData
    p.label(label + "Stack")
    for _ in 0 ..< 128 { p.w(0) }
    p.label(label + "Top")
}

/// MOVE.W #value,$DFF0xx: a mark on Paula, at register `register`.
private func mark(_ p: inout HunkProgram, _ register: UInt16, _ value: UInt16) { p.w(0x33FC, value, 0x00DF, 0xF000 | register) }

/// The values written to a register of Paula's since the machine was switched on.
private func marks(_ host: inout DeliTrackerHost, _ register: UInt16) -> [UInt16] {
    var writes: [AmigaWrite] = []
    host.takeWrites(into: &writes)
    return writes.filter { $0.register == register }.map { $0.value }
}

@Test func execTasksRunByPriorityAndAreSwitchedAsTheyWaitAndAreSignalled() throws {
    // DTP_InitPlayer adds a task of priority 5, which runs at once, until it waits; then signals it, and it
    // runs at once again, until it ends.
    let file = execModule(initPlayer: { p in
        p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        p.w(0x43FA); p.to("tcb") // LEA tcb(PC),A1
        p.w(0x45FA); p.to("code") // LEA code(PC),A2
        p.w(0x97CB) // SUBA.L A3,A3
        p.w(0x4EAE, addTask) // JSR AddTask(A6)
        mark(&p, 0xB6, 1)
        p.w(0x43FA); p.to("tcb") // LEA tcb(PC),A1
        p.w(0x203C, 0x8000, 0x0000) // MOVE.L #$80000000,D0
        p.w(0x4EAE, signal) // JSR Signal(A6)
        mark(&p, 0xB6, 3)
        p.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
    }, rest: { p in
        p.label("code")
        p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        p.w(0x70FF, 0x4EAE, allocSignal) // MOVEQ #-1,D0; JSR AllocSignal(A6)
        p.w(0x33C0, 0x00DF, 0xF0A6) // MOVE.W D0,$DFF0A6: its signal, 31
        p.w(0x203C, 0x8000, 0x0000) // MOVE.L #$80000000,D0
        p.w(0x4EAE, wait) // JSR Wait(A6)
        p.w(0x4840, 0x33C0, 0x00DF, 0xF0A6) // SWAP D0; MOVE.W D0,$DFF0A6: what it waited for, $8000
        p.w(0x4E75) // RTS: the task ends
        task(&p, "tcb", priority: 5)
    })
    var host = try DeliTrackerHost(player: file, system: .exec)
    try host.start(song: 0)
    var writes: [AmigaWrite] = []
    host.takeWrites(into: &writes)
    let order = writes.filter { $0.register == 0xA6 || $0.register == 0xB6 }.suffix(4).map { [$0.register, $0.value] }
    #expect(order == [[0xA6, 31], [0xB6, 1], [0xA6, 0x8000], [0xB6, 3]])
    #expect(host.exec.tasks.count == 1) // (The host's own, the other having ended.)
}

@Test func execSignalFromAnInterruptRunsTheTaskAsTheInterruptEnds() throws {
    // A task of priority -1 counts for ever, never waiting (below the host's own, which is done with once
    // DTP_InitPlayer has returned); one of priority 5 waits for the signal that DTP_Interrupt gives it each
    // tick, and writes the count each time: it can only run if the interrupt's end switches to it.
    let file = execModule(initPlayer: { p in
        p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        for (tcb, code) in [("low", "counting"), ("high", "waiting")] {
            p.w(0x43FA); p.to(tcb) // LEA tcb(PC),A1
            p.w(0x45FA); p.to(code) // LEA code(PC),A2
            p.w(0x97CB, 0x4EAE, addTask) // SUBA.L A3,A3; JSR AddTask(A6)
        }
        p.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
    }, interrupt: { p in
        p.w(0x43FA); p.to("high") // LEA high(PC),A1
        p.w(0x203C, 0x8000, 0x0000, 0x4EAE, signal) // MOVE.L #$80000000,D0; JSR Signal(A6)
        p.w(0x4E75) // RTS
    }, rest: { p in
        p.label("counting")
        p.w(0x41FA); p.to("count") // LEA count(PC),A0
        p.label("again")
        p.w(0x5250) // ADDQ.W #1,(A0)
        p.w(0x6000); p.to("again") // BRA.W again
        p.label("waiting")
        p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        p.label("wait")
        p.w(0x203C, 0x8000, 0x0000, 0x4EAE, wait) // MOVE.L #$80000000,D0; JSR Wait(A6)
        p.w(0x41FA); p.to("count") // LEA count(PC),A0
        p.w(0x33D0, 0x00DF, 0xF0A6) // MOVE.W (A0),$DFF0A6
        p.w(0x6000); p.to("wait") // BRA.W wait
        p.label("count")
        p.w(0)
        task(&p, "low", priority: 0xFF)
        task(&p, "high", priority: 5)
    })
    var host = try DeliTrackerHost(player: file, system: .exec)
    try host.start(song: 0)
    _ = marks(&host, 0xA6)
    // Ten ticks of the host's timer, and a written count for each, the counting task having gone on
    // between them (a word's count, which goes round).
    _ = host.run(until: host.nextTick(after: host.now) + 9 * (0x376B + 1) * 5 + 5000)
    let counts = marks(&host, 0xA6)
    #expect(counts.count == 10)
    #expect(zip(counts, counts.dropFirst()).allSatisfy { $1 &- $0 > 1000 })
}

@Test func execMessagesArePutGotAndRepliedAndWaitedFor() throws {
    // A task of priority 5 waits at its port; DTP_InitPlayer puts a message there (which runs the task at
    // once: it gets it, writes its length and replies it), then waits at its own port for the reply.
    let file = execModule(initPlayer: { p in
        p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        p.w(0x93C9, 0x4EAE, findTask) // SUBA.L A1,A1; JSR FindTask(A6)
        p.w(0x43FA); p.to("replies") // LEA replies(PC),A1
        p.w(0x2340, 0x0010, 0x137C, 0x001E, 0x000F) // MOVE.L D0,16(A1); MOVE.B #30,15(A1)
        p.w(0x4EAE, addPort) // JSR AddPort(A6)
        p.w(0x43FA); p.to("tcb") // LEA tcb(PC),A1
        p.w(0x45FA); p.to("code") // LEA code(PC),A2
        p.w(0x97CB, 0x4EAE, addTask) // SUBA.L A3,A3; JSR AddTask(A6)
        p.w(0x41FA); p.to("port") // LEA port(PC),A0
        p.w(0x43FA); p.to("message") // LEA message(PC),A1
        p.w(0x4EAE, putMsg) // JSR PutMsg(A6)
        mark(&p, 0xB6, 1)
        p.w(0x41FA); p.to("replies") // LEA replies(PC),A0
        p.w(0x4EAE, waitPort) // JSR WaitPort(A6)
        p.w(0x41FA); p.to("replies") // LEA replies(PC),A0
        p.w(0x4EAE, getMsg) // JSR GetMsg(A6)
        p.w(0x43FA); p.to("message") // LEA message(PC),A1
        p.w(0xB3C0) // CMPA.L D0,A1
        p.w(0x6608) // BNE.S past the mark
        mark(&p, 0xB6, 2) // the reply is the message
        p.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
    }, rest: { p in
        p.label("code")
        p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        p.w(0x93C9, 0x4EAE, findTask) // SUBA.L A1,A1; JSR FindTask(A6)
        p.w(0x43FA); p.to("port") // LEA port(PC),A1
        p.w(0x2340, 0x0010, 0x137C, 0x001F, 0x000F) // MOVE.L D0,16(A1); MOVE.B #31,15(A1)
        p.w(0x4EAE, addPort) // JSR AddPort(A6)
        p.label("loop")
        p.w(0x41FA); p.to("port") // LEA port(PC),A0
        p.w(0x4EAE, waitPort) // JSR WaitPort(A6)
        p.w(0x41FA); p.to("port") // LEA port(PC),A0
        p.w(0x4EAE, getMsg) // JSR GetMsg(A6)
        p.w(0x2240) // MOVEA.L D0,A1
        p.w(0x33E9, 0x0012, 0x00DF, 0xF0A6) // MOVE.W 18(A1),$DFF0A6: its length
        p.w(0x4EAE, replyMsg) // JSR ReplyMsg(A6)
        p.w(0x6000); p.to("loop") // BRA.W loop
        // Two ports (34 bytes each) and a message (20 bytes, of length 20, its reply port the second).
        for name in ["port", "replies"] {
            p.label(name)
            for _ in 0 ..< 17 { p.w(0) }
        }
        p.label("message")
        p.w(0, 0, 0, 0, 0, 0, 0)
        p.address("replies")
        p.w(20)
        task(&p, "tcb", priority: 5)
    })
    var host = try DeliTrackerHost(player: file, system: .exec)
    try host.start(song: 0)
    var writes: [AmigaWrite] = []
    host.takeWrites(into: &writes)
    let order = writes.filter { $0.register == 0xA6 || $0.register == 0xB6 }.suffix(3).map { [$0.register, $0.value] }
    #expect(order == [[0xA6, 20], [0xB6, 1], [0xB6, 2]])
}

@Test func execMemoryIsGivenBackAndGivenAgainCleared() throws {
    // AllocMem, its memory written and given back, and asked for again, cleared: the same place, empty.
    let file = execModule(initPlayer: { p in
        p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        p.w(0x7034, 0x223C, 0x0001, 0x0001, 0x4EAE, allocMem) // MOVEQ #$34,D0; MOVE.L #$10001,D1; JSR AllocMem(A6)
        p.w(0x2240, 0x22BC, 0x1234, 0x5678) // MOVEA.L D0,A1; MOVE.L #$12345678,(A1)
        p.w(0x2F09) // MOVE.L A1,-(A7)
        p.w(0x7034, 0x4EAE, freeMem) // MOVEQ #$34,D0; JSR FreeMem(A6)
        p.w(0x7034, 0x223C, 0x0001, 0x0001, 0x4EAE, allocMem) // MOVEQ #$34,D0; MOVE.L #$10001,D1; JSR AllocMem(A6)
        p.w(0x2240, 0x33D1, 0x00DF, 0xF0A6) // MOVEA.L D0,A1; MOVE.W (A1),$DFF0A6: nought
        p.w(0xB3DF, 0x6608) // CMPA.L (A7)+,A1; BNE.S past the mark
        mark(&p, 0xB6, 1) // the same place
        p.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
    })
    var host = try DeliTrackerHost(player: file, system: .exec)
    try host.start(song: 0)
    var writes: [AmigaWrite] = []
    host.takeWrites(into: &writes)
    #expect(writes.filter { $0.register == 0xA6 }.last?.value == 0)
    #expect(writes.filter { $0.register == 0xB6 }.last?.value == 1)
}

@Test func execTimerWaitIsRepliedAtTheFirstFrameAfterIt() throws {
    // timer.device's frames, asked to wait `micros` microseconds from line `line` of a frame: replied as
    // the frame begins by which so many fiftieths of a second have been counted as make that up, however
    // little of the frame it was sent in was left. The frames gone by are written, counted by the host's
    // own count of them.
    func frames(sentAt line: UInt16, micros: UInt16 = 16666) throws -> UInt16? {
        let file = execModule(initPlayer: { p in
            p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
            p.w(0x93C9, 0x4EAE, findTask) // SUBA.L A1,A1; JSR FindTask(A6)
            p.w(0x43FA); p.to("port") // LEA port(PC),A1
            p.w(0x2340, 0x0010, 0x137C, 0x001F, 0x000F) // MOVE.L D0,16(A1); MOVE.B #31,15(A1)
            p.w(0x4EAE, addPort) // JSR AddPort(A6)
            p.w(0x41FA); p.to("name") // LEA name(PC),A0
            p.w(0x7001) // MOVEQ #1,D0 (UNIT_VBLANK)
            p.w(0x43FA); p.to("request") // LEA request(PC),A1
            p.w(0x7200, 0x4EAE, openDevice) // MOVEQ #0,D1; JSR OpenDevice(A6)
            // To the line asked for, and the frame's count kept.
            p.label("beam")
            p.w(0x3039, 0x00DF, 0xF006, 0xE048) // MOVE.W $DFF006,D0; LSR.W #8,D0
            p.w(0x0C40, line) // CMPI.W #line,D0
            p.w(0x6600); p.to("beam") // BNE.W beam
            p.w(0x2F38, 0x3000) // MOVE.L $3000.W,-(A7)
            p.w(0x43FA); p.to("request") // LEA request(PC),A1
            p.w(0x337C, 0x0009, 0x001C) // MOVE.W #TR_ADDREQUEST,28(A1)
            p.w(0x237C, 0x0000, micros, 0x0024) // MOVE.L #micros,36(A1)
            p.w(0x2C69, 0x0014, 0x4EAE, 0xFFE2) // MOVEA.L 20(A1),A6; JSR BeginIO(A6)
            p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
            p.w(0x43FA); p.to("request") // LEA request(PC),A1
            p.w(0x4EAE, waitIO) // JSR WaitIO(A6)
            p.w(0x2038, 0x3000, 0x909F) // MOVE.L $3000.W,D0; SUB.L (A7)+,D0
            p.w(0x33C0, 0x00DF, 0xF0A6) // MOVE.W D0,$DFF0A6
            p.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        }, rest: { p in
            p.label("port")
            for _ in 0 ..< 17 { p.w(0) }
            p.label("request") // a timerequest: its reply port the one above
            p.w(0, 0, 0, 0, 0, 0, 0)
            p.address("port")
            for _ in 0 ..< 13 { p.w(0) }
            p.label("name")
            p.w(0x7469, 0x6D65, 0x722E, 0x6465, 0x7669, 0x6365, 0x0000) // "timer.device"
        })
        var host = try DeliTrackerHost(player: file, system: .exec)
        try host.start(song: 0)
        return marks(&host, 0xA6).last
    }
    // (16,666 microseconds is 260 lines and a half: sent at line 200, the next frame is sooner.)
    #expect(try frames(sentAt: 20) == 1)
    #expect(try frames(sentAt: 200) == 1)
    #expect(try frames(sentAt: 250) == 1)
    #expect(try frames(sentAt: 20, micros: 20000) == 1)
    #expect(try frames(sentAt: 20, micros: 30000) == 2)
}

@Test func execAudioDeviceStartsAWriteAsKickstartDoes() throws {
    // audio.device opened with an allocation of channel 0, and a CMD_WRITE of 64 bytes, its own period and
    // volume, played for ever: its writes to Paula, in 34.1's order.
    let file = execModule(initPlayer: { p in
        p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        p.w(0x41FA); p.to("name") // LEA name(PC),A0
        p.w(0x7000) // MOVEQ #0,D0
        p.w(0x43FA); p.to("request") // LEA request(PC),A1
        p.w(0x45FA); p.to("map") // LEA map(PC),A2
        p.w(0x234A, 0x0022, 0x7201, 0x2341, 0x0026) // MOVE.L A2,34(A1); MOVEQ #1,D1; MOVE.L D1,38(A1)
        p.w(0x7200, 0x4EAE, openDevice) // MOVEQ #0,D1; JSR OpenDevice(A6)
        p.w(0x43FA); p.to("request") // LEA request(PC),A1
        p.w(0x337C, 0x0003, 0x001C, 0x137C, 0x0011, 0x001E) // MOVE.W #CMD_WRITE,28(A1); MOVE.B #$11,30(A1)
        p.w(0x45FA); p.to("sample") // LEA sample(PC),A2
        p.w(0x234A, 0x0022) // MOVE.L A2,34(A1)
        p.w(0x237C, 0x0000, 0x0040, 0x0026) // MOVE.L #64,38(A1)
        p.w(0x337C, 0x012C, 0x002A, 0x337C, 0x0028, 0x002C, 0x4269, 0x002E) // period 300, volume 40, cycles 0
        p.w(0x2C69, 0x0014, 0x4EAE, 0xFFE2) // MOVEA.L 20(A1),A6; JSR BeginIO(A6)
        p.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
    }, rest: { p in
        p.label("request") // an IOAudio, 68 bytes
        for _ in 0 ..< 34 { p.w(0) }
        p.label("map")
        p.w(0x0100)
        p.label("name")
        p.w(0x6175, 0x6469, 0x6F2E, 0x6465, 0x7669, 0x6365, 0x0000) // "audio.device"
        p.label("sample")
        for i in 0 ..< 32 { p.w(UInt16(0x3700 | i)) }
    })
    var host = try DeliTrackerHost(player: file, system: .exec)
    try host.start(song: 0)
    _ = host.run(until: host.now + 2000)
    var all: [AmigaWrite] = []
    host.takeWrites(into: &all)
    // Paula's writes (and the interrupts' of the four channels), from the write's length on: what opening
    // and allocating the channel wrote before it is left out.
    let writes = all.filter { $0.register >= 0xA0 || $0.register == 0x96 || ($0.register == 0x9A || $0.register == 0x9C) && $0.value & 0x0780 != 0 }
    guard let from = writes.lastIndex(where: { $0.register == 0xA4 && $0.value == 32 }) else {
        Issue.record("no write started")
        return
    }
    let seen = writes[from...].prefix(13).map { [$0.register, $0.value] }
    #expect(seen.count == 13)
    #expect(seen[0] == [0xA4, 32])
    #expect(seen[1][0] == 0xA0 && seen[2][0] == 0xA2)
    #expect(Array(seen[3...]) == [[0x9C, 0x0080], [0x9A, 0x8080], [0xA6, 1], [0xAA, 0x3737],
                                  [0x9C, 0x0080], [0x96, 0x8001], [0xA6, 300], [0xA8, 40], [0x9A, 0x0080], [0x9C, 0x0080]])
}

@Test func execRoutineCalledThroughAStubIsNamed() {
    // A routine not given, called through a stub of the module's own (JSR stub(PC); stub: JMP -624(A6)), as
    // World Tour Golf's C library calls exec's: named by the stub's JMP, not by the JSR's displacement.
    let file = execModule(initPlayer: { p in
        p.w(0x2C78, 0x0004) // MOVEA.L 4.W,A6
        p.w(0x4EBA); p.to("stub") // JSR stub(PC)
        p.w(0x7000, 0x4E75) // MOVEQ #0,D0; RTS
        p.label("stub")
        p.w(0x4EEE, 0xFD90) // JMP -624(A6)
    })
    do {
        _ = try DeliCustomPlayer(file)
        Issue.record("played")
    } catch {
        #expect("\(error)".contains("CopyMem"))
    }
}

/// What a program on the machine wrote to Paula (its own writes and the device's), with their times in
/// Paula's clocks since the machine was switched on.
private func run(_ host: inout DeliTrackerHost, for clocks: UInt64, into writes: inout [(time: UInt64, write: AmigaWrite)]) {
    let end = host.now + clocks
    while host.now < end {
        let from = host.beginStretch()
        _ = host.run(until: min(end, host.now + 20000))
        var taken: [AmigaWrite] = []
        host.takeWrites(into: &taken)
        for w in taken { writes.append((from + UInt64(max(0, w.cycles) / 2), w)) }
    }
}

/// For comparing with recordings made on an Amiga: what a custom module writes to Paula, run on exec's own
/// system. SIDAY_EA_DUMP names a file of jobs, a line each: the module's path, the song, how far into its
/// frame the host's timer is to first run out (or "-" for as it plays), the seconds, the file to write, and
/// (if there) "yes" or "no" for whether the system's routines take their time (`AmigaExec.costs`). It writes
/// "base" and the module's first hunk's address, "tick0" and the first tick's time and "period" its
/// length, then a line for each write, its time, register and value (in hexadecimal).
@Test(.enabled(if: ProcessInfo.processInfo.environment["SIDAY_EA_DUMP"] != nil))
func execPlayersWritesAreDumped() throws {
    let jobs = try String(contentsOfFile: try #require(ProcessInfo.processInfo.environment["SIDAY_EA_DUMP"]), encoding: .utf8)
    for line in jobs.split(separator: "\n") {
        let f = line.split(separator: "\t").map(String.init)
        guard f.count >= 5, let song = Int(f[1]), let seconds = Double(f[3]) else { continue }
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: f[0])))
        var host = try DeliTrackerHost(player: bytes, name: URL(fileURLWithPath: f[0]).lastPathComponent, system: .exec)
        host.tickPhase = UInt64(f[2])
        if f.count > 5 { host.execCosts = f[5] == "yes" }
        try host.start(song: song)
        var writes: [(time: UInt64, write: AmigaWrite)] = []
        let tick0 = host.nextTick(after: host.now)
        let period = (UInt64(host.machine.peek16(DeliTrackerHost.globals + DeliTrackerHost.dtgTimer)) + 1) * 5
        run(&host, for: UInt64(seconds * 3_546_895), into: &writes)
        var out = "base \(host.segments[0].address)\ntick0 \(tick0)\nperiod \(period)\n"
        if let failure = host.failure { out += "failure \(failure)\n" }
        for (time, w) in writes { out += "\(time) \(String(w.register, radix: 16)) \(String(w.value, radix: 16))\n" }
        try out.write(toFile: f[4], atomically: true, encoding: .utf8)
    }
}
