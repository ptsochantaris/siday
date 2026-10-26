// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Written from what exec.library's routines are documented to do (Commodore's Autodocs and the ROM Kernel
// Reference Manual: Libraries) and from what Electronic Arts' players were measured to ask of them and
// get on an A500 with Kickstart 1.3, which the games were made for, as Copperline runs it: none of Kickstart's code is in it.

import SidayM68000

/// As much of exec.library as a DeliTracker player gets from the system that it cannot get from UADE's
/// host (`DeliTrackerHost.System.exec`): tasks, each its own 68000 run as exec runs it, by priority; their
/// signals; message ports and the messages put to them; memory given and taken back; and the devices a
/// player times itself and plays its notes by (`AmigaTimerDevice`, `AmigaAudioDevice`). Electronic Arts'
/// players need it all: two tasks of their own, a sequencer woken by the player's interrupt and a task of
/// sound effects that plays the notes through audio.device as the sequencer sends them, its envelopes
/// stepped by timer.device each frame.
///
/// Everything in the system's own structures (the tasks, ports, messages and requests, and the lists they
/// are on) is in the machine's memory, where the player's code reads and writes it, and is changed there
/// as exec changes it, without checks: a player that sends a request still linked into a port relinks it,
/// as exec would. What exec keeps only for itself (which task runs, and where each that does not is to
/// go on from) is kept here.
///
/// A task that is not running is kept as the processor was when it stopped: its registers, its status
/// and where it goes on from. The one that runs is switched as exec switches it: when it waits for what
/// has not come, to the task of the highest priority that is ready (or, with none, to the processor's
/// waiting for an interrupt); when it makes a task of higher priority than its own ready, by a signal or a
/// message, to that one at once; and when an interrupt makes one ready, as the outermost interrupt goes
/// back to the task it interrupted (exec's ExitIntr). A wait that cannot be met goes back to its TRAP, to
/// be called again when its task next runs: then it is met.
///
/// The task that DeliTracker's routines are called in (`call`, the host's "DeliTracker" task) is one of
/// them, of priority nought, as DeliTracker's own is; once the host has nothing more for it to do it waits
/// for ever, and the player's tasks and interrupts go on without it.
struct AmigaExec {
    // MARK: Where things are

    /// The exec's code: its traps to the host, its waiting for an interrupt when no task is ready, and its
    /// handler of Paula's interrupts while audio.device is open. Above score's code (`DeliTrackerHost`),
    /// below its tables at $3000.
    static let codeAt: UInt32 = 0x2400
    /// The devices' bases: each with its vectors below it, BeginIO at -30 and AbortIO at -36.
    static let audioBase: UInt32 = 0x2A00
    static let timerBase: UInt32 = 0x2B00
    /// timer.device's unit of frames, as a request's `io_Unit` points at it.
    static let timerUnit: UInt32 = 0x2B10
    /// The host's own task's control block (a Task, 92 bytes), and its name.
    static let hostTask: UInt32 = 0x2C00
    static let hostTaskName: UInt32 = 0x2C60

    /// The routines of the host's that the exec's code calls by TRAP #15, each a TRAP #15 and an RTS at
    /// its place in a table at `codeAt`.
    enum Call: Int, CaseIterable {
        case allocMem, freeMem, allocVec, freeVec, availMem
        case insert, addHead, addTail, remove, remHead, remTail, enqueue, findName
        case addTask, remTask, findTask, setTaskPri, setSignal, wait, signal, allocSignal, freeSignal
        case addPort, remPort, putMsg, getMsg, replyMsg, waitPort, findPort
        case openDevice, closeDevice, doIO, sendIO, checkIO, waitIO, abortIO
        case createMsgPort, deleteMsgPort, createIORequest, deleteIORequest
        /// The end of every interrupt's handler: switches tasks as exec's ExitIntr does.
        case exitInterrupt
        /// The waiting with no task ready, after each interrupt: goes on with one if one is now ready.
        case idleDispatch
        /// Where a task whose routine returns goes (a finalPC of nought): it is removed.
        case taskEnd
        /// From the frame's interrupt: timer.device's frames.
        case frame
        /// Paula's interrupts, while audio.device is open.
        case audioInterrupt
        case audioBeginIO, audioAbortIO, audioUnimplemented
        case timerBeginIO, timerAbortIO, timerUnimplemented
    }

    static func stub(_ call: Call) -> UInt32 { codeAt + UInt32(call.rawValue * 4) }

    /// The call whose TRAP #15 the processor has stopped at, if `pc` (just past it) is one of these.
    static func call(at pc: UInt32) -> Call? {
        guard pc >= codeAt + 2, pc < codeAt + UInt32(Call.allCases.count * 4) + 2, (pc - codeAt - 2) % 4 == 0 else { return nil }
        return Call(rawValue: Int(pc - codeAt - 2) / 4)
    }

    /// The exec's code, at `codeAt`: the traps, and where `idle`, `audioLevel4` and `delay` begin.
    static func assemble() -> (code: [UInt8], idle: UInt32, audioLevel4: UInt32, delay: UInt32) {
        var a = AmigaAssembly(at: codeAt)
        for _ in Call.allCases { a.w(0x4E4F, 0x4E75) } // TRAP #15; RTS
        // The time a routine of the system's takes (see `costs`): a count on the stack taken down to
        // nought, fifteen of Paula's clocks a time round, and back to the routine's caller.
        let delay = a.here
        let round = a.placed()
        a.w(0x5397) // SUBQ.L #1,(A7)
        a.branch(0x6600, to: round) // BNE.S round
        a.w(0x588F, 0x4E75) // ADDQ.L #4,A7; RTS
        // With no task ready: STOP until an interrupt, then see whether it made one ready.
        let idle = a.here
        let loop = a.placed()
        a.w(0x4E72, 0x2000) // STOP #$2000
        a.w(0x4EB9)
        a.long(stub(.idleDispatch)) // JSR idleDispatch
        a.branch(0x6000, to: loop) // BRA.S loop
        // Paula's interrupts, for audio.device, and the end of an interrupt.
        let audioLevel4 = a.here
        a.w(0x4EB9)
        a.long(stub(.audioInterrupt)) // JSR audioInterrupt
        a.w(0x4EB9)
        a.long(stub(.exitInterrupt)) // JSR exitInterrupt
        a.w(0x4E73) // RTE
        return (a.assembled(), idle, audioLevel4, delay)
    }

    // MARK: The structures in memory (exec/nodes.i, exec/tasks.i, exec/ports.i, exec/io.i)

    // A Node: ln_Succ, ln_Pred, ln_Type, ln_Pri, ln_Name.
    static let lnSucc: UInt32 = 0, lnPred: UInt32 = 4, lnType: UInt32 = 8, lnPri: UInt32 = 9, lnName: UInt32 = 10
    // A List: lh_Head, lh_Tail, lh_TailPred.
    static let lhHead: UInt32 = 0, lhTail: UInt32 = 4, lhTailPred: UInt32 = 8
    // A Task.
    static let tcState: UInt32 = 15, tcSigAlloc: UInt32 = 18, tcSigWait: UInt32 = 22, tcSigRecvd: UInt32 = 26
    static let tcSPReg: UInt32 = 54, tcSPLower: UInt32 = 58, tcSPUpper: UInt32 = 62
    static let taskSize = 92
    // A MsgPort: mp_Flags, mp_SigBit, mp_SigTask, mp_MsgList.
    static let mpFlags: UInt32 = 14, mpSigBit: UInt32 = 15, mpSigTask: UInt32 = 16, mpMsgList: UInt32 = 20
    static let portSize: UInt32 = 34
    // A Message: mn_ReplyPort, mn_Length.
    static let mnReplyPort: UInt32 = 14, mnLength: UInt32 = 18
    // An IORequest: io_Device, io_Unit, io_Command, io_Flags, io_Error.
    static let ioDevice: UInt32 = 20, ioUnit: UInt32 = 24, ioCommand: UInt32 = 28, ioFlags: UInt32 = 30, ioError: UInt32 = 31
    static let iofQuick: UInt8 = 1
    // Node types.
    static let ntTask: UInt8 = 1, ntMessage: UInt8 = 5, ntFreeMsg: UInt8 = 6, ntReplyMsg: UInt8 = 7, ntMsgPort: UInt8 = 4
    // Task states.
    static let tsRun: UInt8 = 2, tsReady: UInt8 = 3, tsWait: UInt8 = 4, tsRemoved: UInt8 = 6
    /// ExecBase's ThisTask.
    static let thisTask: UInt32 = 276
    /// IOERR_ABORTED.
    static let aborted: Int8 = -2

    // MARK: State

    /// A task, as exec keeps it while it does not run: where it goes on from, and how it stopped.
    struct Task {
        let tcb: UInt32
        var priority: Int
        var running = false
        var ready = false
        /// The processor as the task left it: D0 to D7, A0 to A6 and its own stack pointer; its status;
        /// and where it goes on from.
        var registers = InlineArray<16, UInt32>(repeating: 0)
        var status: UInt32 = 0
        var pc: UInt32 = 0
        /// When it was last made ready: among the ready of a priority, the first made ready goes first.
        var readyAt = 0
        /// The signals a WaitPort waited for, which are cleared as it is called again (as the Wait it
        /// would have been in clears them as it returns).
        var clearsOnRetry: UInt32 = 0
    }

    private(set) var tasks: [Task] = []
    private var readyCount = 0
    /// The free memory, as places and sizes in order of place: what AllocMem gives from and FreeMem gives
    /// back to.
    private var free: [(at: UInt32, size: UInt32)] = []
    var audio = AmigaAudioDevice()
    var timer = AmigaTimerDevice()
    /// Where the exec's code waits with no task ready.
    private var idleAt: UInt32 = 0
    private var audioLevel4At: UInt32 = 0
    private var delayAt: UInt32 = 0
    /// Whether the routines take the time they took on the A500 the references were made on (each one's
    /// median, as measured there with Kickstart 1.3), rather than none. They do: so the players' writes
    /// come nearer the times they came there, and Marble Madness's notes whose attack ends before their
    /// rest is sent start again as they did there. (It takes a count on the caller's stack, which the
    /// caller's code takes down before it goes on: `delay`.)
    var costs = true
    /// The time the routine being done takes, in Paula's clocks, if `costs`.
    var charge = 0
    /// Why the player stopped, if it asked for something of the system's that this one does not give.
    var failure: String?

    /// The exec set up afresh in a machine just switched on, the host's own code and tables already in
    /// it (`DeliTrackerHost.prepare`): its code and vectors, the host's task running, and the memory from
    /// `heapFrom` to `heapTo` free.
    mutating func setUp(_ m: inout AmigaMachine, heapFrom: UInt32, heapTo: UInt32) {
        let costs = self.costs
        self = AmigaExec()
        self.costs = costs
        let (code, idle, level4, delay) = Self.assemble()
        m.load(code, at: Self.codeAt)
        idleAt = idle
        audioLevel4At = level4
        delayAt = delay
        let routines: [(Int, Call)] = [
            (198, .allocMem), (210, .freeMem), (684, .allocVec), (690, .freeVec), (216, .availMem),
            (234, .insert), (240, .addHead), (246, .addTail), (252, .remove), (258, .remHead), (264, .remTail),
            (270, .enqueue), (276, .findName),
            (282, .addTask), (288, .remTask), (294, .findTask), (300, .setTaskPri), (306, .setSignal), (318, .wait),
            (324, .signal), (330, .allocSignal), (336, .freeSignal),
            (354, .addPort), (360, .remPort), (366, .putMsg), (372, .getMsg), (378, .replyMsg), (384, .waitPort),
            (390, .findPort),
            (444, .openDevice), (450, .closeDevice), (456, .doIO), (462, .sendIO), (468, .checkIO), (474, .waitIO),
            (480, .abortIO),
            (654, .createIORequest), (660, .deleteIORequest), (666, .createMsgPort), (672, .deleteMsgPort),
        ]
        for (offset, call) in routines { m.setLibraryRoutine(offset, to: Self.stub(call)) }
        // The devices' vectors: Open, Close, Expunge and the reserved one, which a player does not call,
        // then BeginIO and AbortIO; and timer.device's own routines, none of them given.
        for (base, begin, abort, none, count) in [(Self.audioBase, Call.audioBeginIO, Call.audioAbortIO, Call.audioUnimplemented, 6),
                                                  (Self.timerBase, .timerBeginIO, .timerAbortIO, .timerUnimplemented, 11)] {
            for r in 1 ... count {
                let to = r == 5 ? Self.stub(begin) : r == 6 ? Self.stub(abort) : Self.stub(none)
                m.poke16(base &- UInt32(r * 6), 0x4EF9)
                m.poke32(base &- UInt32(r * 6) + 2, to)
            }
        }
        for (i, byte) in "DeliTracker".utf8.enumerated() { m.poke8(Self.hostTaskName + UInt32(i), byte) }
        // The host's task: priority nought, the system's sixteen signals its own, on the user's stack.
        let t = Self.hostTask
        m.poke8(t + Self.lnType, Self.ntTask)
        m.poke32(t + Self.lnName, Self.hostTaskName)
        m.poke8(t + Self.tcState, Self.tsRun)
        m.poke32(t + Self.tcSigAlloc, 0x0000_FFFF)
        m.poke32(t + Self.tcSPLower, DeliTrackerHost.userStack - 0x800)
        m.poke32(t + Self.tcSPUpper, DeliTrackerHost.userStack)
        tasks = [Task(tcb: t, priority: 0, running: true)]
        m.poke32(AmigaMachine.execBase + Self.thisTask, t)
        free = heapTo > heapFrom + 8 ? [((heapFrom + 7) & ~7, (heapTo - ((heapFrom + 7) & ~7)) & ~7)] : []
        // The frames of the A500 the references were made on, and its Paula's way of starting a voice by
        // hand (see `AmigaChips`).
        m.chips.longFrames = true
        m.chips.manualWordStartsBlock = true
    }

    // MARK: Tasks

    private var runningIndex: Int? { tasks.firstIndex { $0.running } }
    private func index(of tcb: UInt32) -> Int? { tasks.firstIndex { $0.tcb == tcb } }

    /// The task running, if any (none while the processor waits with no task ready).
    var running: UInt32? { runningIndex.map { tasks[$0].tcb } }

    /// The ready task to run next: the one of the highest priority, the first made ready among equals.
    private var best: Int? {
        var found: Int?
        for i in tasks.indices where tasks[i].ready {
            if let f = found {
                if tasks[i].priority > tasks[f].priority || tasks[i].priority == tasks[f].priority && tasks[i].readyAt < tasks[f].readyAt {
                    found = i
                }
            } else {
                found = i
            }
        }
        return found
    }

    private mutating func makeReady(_ i: Int, _ m: borrowing AmigaMachine) {
        tasks[i].ready = true
        tasks[i].running = false
        readyCount += 1
        tasks[i].readyAt = readyCount
        m.poke8(tasks[i].tcb + Self.tcState, Self.tsReady)
    }

    /// Keeps the running task as the processor has it in a TRAP of the task's own (in user mode): to go on
    /// past it, or (`again`) from the TRAP again.
    private mutating func keep(_ i: Int, _ m: borrowing AmigaMachine, again: Bool) {
        tasks[i].registers = m.cpu.registers
        tasks[i].status = m.cpu.statusRegister
        tasks[i].pc = again ? m.cpu.pc &- 2 : m.cpu.pc
    }

    /// Sends the processor to a task, from whatever it was doing: its registers, its stack and status, and
    /// on from where it left off, the supervisor's stack empty.
    private mutating func resume(_ i: Int, _ m: inout AmigaMachine) {
        tasks[i].ready = false
        tasks[i].running = true
        m.cpu.setStatus(0x2700)
        m.cpu.registers[15] = DeliTrackerHost.superStack
        for r in 0 ..< 15 { m.cpu.registers[r] = tasks[i].registers[r] }
        m.cpu.userStack = tasks[i].registers[15]
        m.cpu.setStatus(tasks[i].status)
        m.jump(to: tasks[i].pc)
        m.poke8(tasks[i].tcb + Self.tcState, Self.tsRun)
        m.poke32(AmigaMachine.execBase + Self.thisTask, tasks[i].tcb)
    }

    /// With no task ready: the processor waits for an interrupt, in the exec's code.
    private mutating func waitForInterrupt(_ m: inout AmigaMachine) {
        m.cpu.setStatus(0x2700)
        m.cpu.registers[15] = DeliTrackerHost.superStack
        m.jump(to: idleAt)
    }

    /// The task running (in a TRAP of its own) gives up the processor, to go on from the TRAP again when
    /// it next runs (`again`), from `at`, or past it: to the best of the ready, or to waiting.
    private mutating func giveUp(_ m: inout AmigaMachine, again: Bool, waiting: Bool, at: UInt32? = nil) {
        if let r = runningIndex {
            keep(r, m, again: again)
            if let at { tasks[r].pc = at }
            tasks[r].running = false
            if waiting { m.poke8(tasks[r].tcb + Self.tcState, Self.tsWait) } else { makeReady(r, m) }
        }
        if let b = best { resume(b, &m) } else { waitForInterrupt(&m) }
    }

    /// After something a task did in a TRAP of its own that may have made one of higher priority ready:
    /// that one runs now.
    private mutating func preemptIfBetter(_ m: inout AmigaMachine) {
        guard m.cpu.statusRegister & 0x2000 == 0, let r = runningIndex, let b = best, tasks[b].priority > tasks[r].priority else { return }
        giveUp(&m, again: false, waiting: false)
    }

    /// The host is about to call a routine of the player's (`DeliTrackerHost.call`), which is done in its
    /// own task: that task is made the one running. (It always is, as the host calls: a call comes back
    /// only in it, and no task of higher priority is then ready, or it would be running.)
    mutating func beginCall(_ m: inout AmigaMachine) {
        guard let host = index(of: Self.hostTask) else { return }
        if let r = runningIndex, r != host {
            // (Not met: kept as it is if it is in its own code.)
            if m.cpu.statusRegister & 0x2000 == 0 { keep(r, m, again: false) }
            tasks[r].running = false
            makeReady(r, m)
        }
        tasks[host].ready = false
        tasks[host].running = true
        m.poke8(Self.hostTask + Self.tcState, Self.tsRun)
        m.poke32(AmigaMachine.execBase + Self.thisTask, Self.hostTask)
    }

    /// The host has nothing more for its task to do (`DeliTrackerHost.idle`): it waits, for nothing, and
    /// the player's tasks run, or the processor waits for an interrupt.
    mutating func hostIdles(_ m: inout AmigaMachine) {
        guard let r = runningIndex, tasks[r].tcb == Self.hostTask else { return }
        m.poke32(Self.hostTask + Self.tcSigWait, 0)
        tasks[r].running = false
        m.poke8(Self.hostTask + Self.tcState, Self.tsWait)
        if let b = best { resume(b, &m) } else { waitForInterrupt(&m) }
    }

    /// Signals a task, from a task or an interrupt: if it waits for one of them, it is made ready.
    mutating func signal(_ tcb: UInt32, _ signals: UInt32, _ m: borrowing AmigaMachine) {
        let received = m.peek32(tcb + Self.tcSigRecvd) | signals
        m.poke32(tcb + Self.tcSigRecvd, received)
        guard let i = index(of: tcb), !tasks[i].running, !tasks[i].ready, received & m.peek32(tcb + Self.tcSigWait) != 0 else { return }
        makeReady(i, m)
    }

    // MARK: Lists, as exec's routines change them (and nothing checked)

    static func newList(_ list: UInt32, _ m: borrowing AmigaMachine) {
        m.poke32(list + lhHead, list + lhTail)
        m.poke32(list + lhTail, 0)
        m.poke32(list + lhTailPred, list + lhHead)
    }

    static func addHead(_ list: UInt32, _ node: UInt32, _ m: borrowing AmigaMachine) {
        let head = m.peek32(list + lhHead)
        m.poke32(node + lnSucc, head)
        m.poke32(node + lnPred, list + lhHead)
        m.poke32(head + lnPred, node)
        m.poke32(list + lhHead, node)
    }

    static func addTail(_ list: UInt32, _ node: UInt32, _ m: borrowing AmigaMachine) {
        let last = m.peek32(list + lhTailPred)
        m.poke32(node + lnSucc, list + lhTail)
        m.poke32(node + lnPred, last)
        m.poke32(last + lnSucc, node)
        m.poke32(list + lhTailPred, node)
    }

    static func remove(_ node: UInt32, _ m: borrowing AmigaMachine) {
        let succ = m.peek32(node + lnSucc), pred = m.peek32(node + lnPred)
        m.poke32(pred + lnSucc, succ)
        m.poke32(succ + lnPred, pred)
    }

    static func remHead(_ list: UInt32, _ m: borrowing AmigaMachine) -> UInt32 {
        let head = m.peek32(list + lhHead)
        let succ = m.peek32(head + lnSucc)
        guard succ != 0 else { return 0 }
        m.poke32(list + lhHead, succ)
        m.poke32(succ + lnPred, list + lhHead)
        return head
    }

    static func remTail(_ list: UInt32, _ m: borrowing AmigaMachine) -> UInt32 {
        let last = m.peek32(list + lhTailPred)
        let pred = m.peek32(last + lnPred)
        guard pred != 0 else { return 0 }
        m.poke32(list + lhTailPred, pred)
        m.poke32(pred + lnSucc, list + lhTail)
        return last
    }

    /// Insert: the node after `after` (or at the head, for nought).
    static func insert(_ list: UInt32, _ node: UInt32, after: UInt32, _ m: borrowing AmigaMachine) {
        guard after != 0 else { return addHead(list, node, m) }
        let succ = m.peek32(after + lnSucc)
        guard succ != 0 else { return addTail(list, node, m) }
        m.poke32(node + lnSucc, succ)
        m.poke32(node + lnPred, after)
        m.poke32(succ + lnPred, node)
        m.poke32(after + lnSucc, node)
    }

    /// Enqueue: the node before the first of lower priority. (At most a list of 4,096, for one that is
    /// not one.)
    static func enqueue(_ list: UInt32, _ node: UInt32, _ m: borrowing AmigaMachine) {
        let pri = Int8(bitPattern: m.peek8(node + lnPri))
        var at = m.peek32(list + lhHead)
        var count = 0
        while count < 4096, m.peek32(at + lnSucc) != 0, Int8(bitPattern: m.peek8(at + lnPri)) >= pri {
            at = m.peek32(at + lnSucc)
            count += 1
        }
        let pred = m.peek32(at + lnPred)
        m.poke32(node + lnSucc, at)
        m.poke32(node + lnPred, pred)
        m.poke32(pred + lnSucc, node)
        m.poke32(at + lnPred, node)
    }

    static func findName(_ list: UInt32, _ name: UInt32, _ m: borrowing AmigaMachine) -> UInt32 {
        var at = m.peek32(list + lhHead)
        var count = 0
        while count < 4096, m.peek32(at + lnSucc) != 0 {
            if sameString(m.peek32(at + lnName), name, m) { return at }
            at = m.peek32(at + lnSucc)
            count += 1
        }
        return 0
    }

    static func sameString(_ a: UInt32, _ b: UInt32, _ m: borrowing AmigaMachine) -> Bool {
        guard a != 0, b != 0 else { return false }
        for i in 0 ..< UInt32(256) {
            let x = m.peek8(a + i), y = m.peek8(b + i)
            if x != y { return false }
            if x == 0 { return true }
        }
        return true
    }

    // MARK: Messages

    /// PutMsg: the message put at the end of the port's list, and the port's task signalled, if the port
    /// says so (PA_SIGNAL; PA_IGNORE is nothing, and a software interrupt is not given).
    mutating func putMessage(_ port: UInt32, _ message: UInt32, type: UInt8, _ m: borrowing AmigaMachine) {
        m.poke8(message + Self.lnType, type)
        Self.addTail(port + Self.mpMsgList, message, m)
        if m.peek8(port + Self.mpFlags) & 3 == 0 {
            signal(m.peek32(port + Self.mpSigTask), 1 << UInt32(m.peek8(port + Self.mpSigBit) & 31), m)
        }
    }

    /// ReplyMsg: back to its reply port, or, with none, only marked as free.
    mutating func reply(_ message: UInt32, _ m: borrowing AmigaMachine) {
        let port = m.peek32(message + Self.mnReplyPort)
        if port == 0 {
            m.poke8(message + Self.lnType, Self.ntFreeMsg)
        } else {
            putMessage(port, message, type: Self.ntReplyMsg, m)
        }
    }

    /// A request done: its error set, and replied unless it was done at once (IOF_QUICK).
    mutating func done(_ request: UInt32, error: Int8, _ m: borrowing AmigaMachine) {
        m.poke8(request + Self.ioError, UInt8(bitPattern: error))
        if m.peek8(request + Self.ioFlags) & Self.iofQuick == 0 { reply(request, m) }
    }

    // MARK: Memory

    /// AllocMem: from the top of the highest free place it fits in, in eights, cleared if asked
    /// (MEMF_CLEAR); nought if it fits nowhere. (From the top, so that score's own way of loading files,
    /// from the bottom up, is left room.)
    private mutating func allocate(_ size: UInt32, clear: Bool, _ m: borrowing AmigaMachine) -> UInt32 {
        guard size > 0, size < 0x100_0000 else { return 0 }
        let need = (size + 7) & ~7
        for i in free.indices.reversed() where free[i].size >= need {
            free[i].size -= need
            let at = free[i].at + free[i].size
            if free[i].size == 0 { free.remove(at: i) }
            if clear { m.memory.advanced(by: Int(at)).initialize(repeating: 0, count: Int(need)) }
            return at
        }
        return 0
    }

    /// FreeMem: given back, and joined to the free places beside it.
    private mutating func release(_ at: UInt32, _ size: UInt32) {
        guard size > 0, at != 0 else { return }
        let start = at & ~7, need = (size + (at - start) + 7) & ~7
        var i = 0
        while i < free.count, free[i].at < start { i += 1 }
        free.insert((start, need), at: i)
        if i + 1 < free.count, free[i].at + free[i].size >= free[i + 1].at {
            free[i].size = max(free[i].size, free[i + 1].at + free[i + 1].size - free[i].at)
            free.remove(at: i + 1)
        }
        if i > 0, free[i - 1].at + free[i - 1].size >= free[i].at {
            free[i - 1].size = max(free[i - 1].size, free[i].at + free[i].size - free[i - 1].at)
            free.remove(at: i)
        }
    }

    // MARK: The routines

    /// Does the routine the player called, in its task (in user mode) or in an interrupt (in supervisor
    /// mode), its arguments in the registers as exec's Autodocs have them; and returns false for one that
    /// stops the player (`failure` says why).
    mutating func perform(_ call: Call, _ m: inout AmigaMachine) -> Bool {
        let pc = m.cpu.pc
        charge = Self.cost(call)
        guard perform(call, at: pc, &m) else { return false }
        // The time it takes, as the caller goes on (and not if the processor has gone to another task).
        if costs, charge >= 15, m.cpu.pc == pc {
            m.cpu.registers[15] &-= 4
            m.poke32(m.cpu.registers[15], UInt32(charge / 15))
            m.jump(to: delayAt)
        }
        return true
    }

    /// The times exec's routines took on the A500 of the references, in Paula's clocks: the median of each,
    /// as measured in Electronic Arts' players (those not measured, none; audio.device's and timer.device's
    /// are set as each command is done).
    private static func cost(_ call: Call) -> Int {
        switch call {
        case .getMsg: 102
        case .findTask: 44
        case .allocSignal: 125
        case .freeSignal: 54
        case .signal: 139
        case .putMsg: 496
        case .replyMsg: 510
        case .freeMem: 502
        case .allocMem: 1112
        case .addHead: 58
        case .addPort: 270
        case .openDevice: 1450
        case .checkIO: 52
        case .waitIO: 163
        default: 0
        }
    }

    private mutating func perform(_ call: Call, at pc: UInt32, _ m: inout AmigaMachine) -> Bool {
        let d0 = m.cpu.registers[0], d1 = m.cpu.registers[1], a0 = m.cpu.registers[8], a1 = m.cpu.registers[9]
        let inTask = m.cpu.statusRegister & 0x2000 == 0
        switch call {
        case .allocMem:
            m.cpu.registers[0] = allocate(d0, clear: d1 & 0x1_0000 != 0, m)
        case .freeMem:
            release(a1, d0)
        case .allocVec:
            let at = allocate(d0 &+ 8, clear: d1 & 0x1_0000 != 0, m)
            if at != 0 { m.poke32(at, d0 &+ 8) }
            m.cpu.registers[0] = at == 0 ? 0 : at + 8
        case .freeVec:
            if a1 >= 8 { release(a1 - 8, m.peek32(a1 - 8)) }
        case .availMem:
            // (MEMF_LARGEST: the largest free place; otherwise all that is free.)
            m.cpu.registers[0] = d1 & 0x2_0000 != 0 ? free.reduce(0) { max($0, $1.size) } : free.reduce(0) { $0 + $1.size }
        case .insert:
            Self.insert(a0, a1, after: m.cpu.registers[10], m)
        case .addHead:
            Self.addHead(a0, a1, m)
        case .addTail:
            Self.addTail(a0, a1, m)
        case .remove:
            Self.remove(a1, m)
        case .remHead:
            m.cpu.registers[0] = Self.remHead(a0, m)
        case .remTail:
            m.cpu.registers[0] = Self.remTail(a0, m)
        case .enqueue:
            Self.enqueue(a0, a1, m)
        case .findName:
            m.cpu.registers[0] = Self.findName(a0, a1, m)
        case .addTask:
            return addTask(a1, initialPC: m.cpu.registers[10], finalPC: m.cpu.registers[11], &m)
        case .remTask:
            removeTask(a1 == 0 ? running ?? 0 : a1, &m)
        case .findTask:
            if a1 == 0 {
                m.cpu.registers[0] = m.peek32(AmigaMachine.execBase + Self.thisTask)
            } else {
                m.cpu.registers[0] = tasks.first { Self.sameString(m.peek32($0.tcb + Self.lnName), a1, m) }?.tcb ?? 0
            }
        case .setTaskPri:
            if let i = index(of: a1) {
                m.cpu.registers[0] = UInt32(bitPattern: Int32(tasks[i].priority))
                tasks[i].priority = Int(Int8(truncatingIfNeeded: d0))
                m.poke8(a1 + Self.lnPri, UInt8(truncatingIfNeeded: d0))
                if inTask, let r = runningIndex, let b = best, tasks[b].priority > tasks[r].priority {
                    giveUp(&m, again: false, waiting: false)
                }
            }
        case .setSignal:
            guard let tcb = running else { break }
            let old = m.peek32(tcb + Self.tcSigRecvd)
            m.poke32(tcb + Self.tcSigRecvd, old & ~d1 | d0 & d1)
            m.cpu.registers[0] = old
        case .wait:
            wait(d0, &m, inTask: inTask)
        case .signal:
            signal(a1, d0, m)
            preemptIfBetter(&m)
        case .allocSignal:
            guard let tcb = running else {
                m.cpu.registers[0] = 0xFFFF_FFFF
                break
            }
            let allocated = m.peek32(tcb + Self.tcSigAlloc)
            var result: UInt32 = 0xFFFF_FFFF
            if Int8(truncatingIfNeeded: d0) == -1 {
                for s in stride(from: 31, through: 0, by: -1) where allocated & (1 << UInt32(s)) == 0 {
                    result = UInt32(s)
                    break
                }
            } else if allocated & (1 << (d0 & 31)) == 0 {
                result = d0 & 31
            }
            if result != 0xFFFF_FFFF {
                m.poke32(tcb + Self.tcSigAlloc, allocated | 1 << result)
                m.poke32(tcb + Self.tcSigRecvd, m.peek32(tcb + Self.tcSigRecvd) & ~(1 << result))
            }
            m.cpu.registers[0] = result
        case .freeSignal:
            if let tcb = running, Int32(bitPattern: d0) != -1 {
                m.poke32(tcb + Self.tcSigAlloc, m.peek32(tcb + Self.tcSigAlloc) & ~(1 << (d0 & 31)))
            }
        case .addPort:
            // (The system's list of ports is not kept: nothing here looks a port up by its name.)
            m.poke8(a1 + Self.lnType, Self.ntMsgPort)
            Self.newList(a1 + Self.mpMsgList, m)
        case .remPort:
            break
        case .putMsg:
            putMessage(a0, a1, type: Self.ntMessage, m)
            preemptIfBetter(&m)
        case .getMsg:
            m.cpu.registers[0] = Self.remHead(a0 + Self.mpMsgList, m)
        case .replyMsg:
            reply(a1, m)
            preemptIfBetter(&m)
        case .waitPort:
            waitPort(a0, &m, inTask: inTask)
        case .findPort:
            m.cpu.registers[0] = 0
        case .openDevice:
            return openDevice(name: a0, unit: d0, request: a1, &m)
        case .closeDevice:
            closeDevice(a1, &m)
        case .doIO:
            m.poke8(a1 + Self.ioFlags, m.peek8(a1 + Self.ioFlags) | Self.iofQuick)
            guard beginIO(a1, &m) else { return false }
            waitIO(a1, &m, inTask: inTask)
        case .sendIO:
            m.poke8(a1 + Self.ioFlags, m.peek8(a1 + Self.ioFlags) & ~Self.iofQuick)
            return beginIO(a1, &m)
        case .checkIO:
            let finished = m.peek8(a1 + Self.ioFlags) & Self.iofQuick != 0 || m.peek8(a1 + Self.lnType) == Self.ntReplyMsg
            m.cpu.registers[0] = finished ? a1 : 0
        case .waitIO:
            waitIO(a1, &m, inTask: inTask)
        case .abortIO:
            abortIO(a1, &m)
        case .createMsgPort:
            m.cpu.registers[0] = createPort(&m)
        case .deleteMsgPort:
            if a0 != 0 {
                if let tcb = running, m.peek8(a0 + Self.mpFlags) & 3 == 0 {
                    m.poke32(tcb + Self.tcSigAlloc, m.peek32(tcb + Self.tcSigAlloc) & ~(1 << UInt32(m.peek8(a0 + Self.mpSigBit) & 31)))
                }
                release(a0, Self.portSize)
            }
        case .createIORequest:
            let at = a0 == 0 || d0 < 32 ? 0 : allocate(d0, clear: true, m)
            if at != 0 {
                m.poke8(at + Self.lnType, Self.ntReplyMsg)
                m.poke32(at + Self.mnReplyPort, a0)
                m.poke16(at + Self.mnLength, UInt16(truncatingIfNeeded: d0))
            }
            m.cpu.registers[0] = at
        case .deleteIORequest:
            if a0 != 0 { release(a0, UInt32(m.peek16(a0 + Self.mnLength))) }
        case .exitInterrupt:
            exitInterrupt(&m)
        case .idleDispatch:
            if let b = best { resume(b, &m) }
        case .taskEnd:
            removeTask(running ?? 0, &m)
        case .frame:
            timerFrame(&m)
        case .audioInterrupt:
            audioInterrupt(&m)
        case .audioBeginIO:
            return audioBeginIO(a1, &m)
        case .audioAbortIO:
            audioAbortIO(a1, &m)
        case .timerBeginIO:
            return timerBeginIO(a1, &m)
        case .timerAbortIO:
            timerAbortIO(a1, &m)
        case .audioUnimplemented, .timerUnimplemented:
            failure = "a player that calls a routine of \(call == .audioUnimplemented ? "audio" : "timer").device's that siday's does not give"
            return false
        }
        return true
    }

    /// AddTask: the task's control block as the player made it, its stack as it says (tc_SPReg), going
    /// to `initialPC` with every register nought, and on its routine's return to `finalPC` (or, for
    /// nought, to its end). If it is of higher priority than the task adding it, it runs at once.
    private mutating func addTask(_ tcb: UInt32, initialPC: UInt32, finalPC: UInt32, _ m: inout AmigaMachine) -> Bool {
        guard index(of: tcb) == nil else {
            failure = "a player that adds a task twice"
            return false
        }
        var task = Task(tcb: tcb, priority: Int(Int8(bitPattern: m.peek8(tcb + Self.lnPri))))
        let stack = m.peek32(tcb + Self.tcSPReg) &- 4
        m.poke32(stack, finalPC == 0 ? Self.stub(.taskEnd) : finalPC)
        task.registers[15] = stack
        task.pc = initialPC
        task.status = 0
        m.poke8(tcb + Self.lnType, Self.ntTask)
        // (The system's sixteen signals, as every task has them.)
        if m.peek32(tcb + Self.tcSigAlloc) == 0 { m.poke32(tcb + Self.tcSigAlloc, 0x0000_FFFF) }
        tasks.append(task)
        makeReady(tasks.count - 1, m)
        m.cpu.registers[0] = tcb
        if m.cpu.statusRegister & 0x2000 == 0 { preemptIfBetter(&m) }
        return true
    }

    /// RemTask: the task taken out; if it is the one running, the processor goes to the next.
    private mutating func removeTask(_ tcb: UInt32, _ m: inout AmigaMachine) {
        guard let i = index(of: tcb) else { return }
        let wasRunning = tasks[i].running
        m.poke8(tcb + Self.tcState, Self.tsRemoved)
        tasks.remove(at: i)
        guard wasRunning else { return }
        if let b = best { resume(b, &m) } else { waitForInterrupt(&m) }
    }

    /// Wait: the signals asked for that have come, cleared and given back; if none has, the task waits for
    /// them, and calls Wait again once one comes. (In an interrupt, where nothing may wait, nought.)
    private mutating func wait(_ signals: UInt32, _ m: inout AmigaMachine, inTask: Bool) {
        guard inTask, let r = runningIndex else {
            m.cpu.registers[0] = 0
            return
        }
        let tcb = tasks[r].tcb
        let received = m.peek32(tcb + Self.tcSigRecvd)
        if received & signals != 0 {
            m.poke32(tcb + Self.tcSigRecvd, received & ~signals)
            m.cpu.registers[0] = received & signals
            return
        }
        m.poke32(tcb + Self.tcSigWait, signals)
        giveUp(&m, again: true, waiting: true)
    }

    /// WaitPort: the first message at the port, left there; if there is none, the task waits for the
    /// port's signal (and clears it, as Wait does, when it is called again).
    private mutating func waitPort(_ port: UInt32, _ m: inout AmigaMachine, inTask: Bool) {
        let head = m.peek32(port + Self.mpMsgList + Self.lhHead)
        let bit: UInt32 = 1 << UInt32(m.peek8(port + Self.mpSigBit) & 31)
        if let r = runningIndex, tasks[r].clearsOnRetry != 0 {
            let tcb = tasks[r].tcb
            m.poke32(tcb + Self.tcSigRecvd, m.peek32(tcb + Self.tcSigRecvd) & ~tasks[r].clearsOnRetry)
            tasks[r].clearsOnRetry = 0
        }
        if m.peek32(head + Self.lnSucc) != 0 || !inTask {
            m.cpu.registers[0] = m.peek32(head + Self.lnSucc) != 0 ? head : 0
            return
        }
        guard let r = runningIndex else { return }
        let tcb = tasks[r].tcb
        let received = m.peek32(tcb + Self.tcSigRecvd)
        // (The signal come already, with no message, is cleared, as Wait would clear it.)
        m.poke32(tcb + Self.tcSigRecvd, received & ~bit)
        m.poke32(tcb + Self.tcSigWait, bit)
        tasks[r].clearsOnRetry = bit
        giveUp(&m, again: true, waiting: true)
    }

    /// WaitIO: once the request is done (at once, or replied), it is taken off its reply port and its
    /// error given back; until then the task waits for the port's signal. (In an interrupt, where nothing
    /// may wait, it is given back as it is.)
    private mutating func waitIO(_ request: UInt32, _ m: inout AmigaMachine, inTask: Bool) {
        if let r = runningIndex, tasks[r].clearsOnRetry != 0 {
            let tcb = tasks[r].tcb
            m.poke32(tcb + Self.tcSigRecvd, m.peek32(tcb + Self.tcSigRecvd) & ~tasks[r].clearsOnRetry)
            tasks[r].clearsOnRetry = 0
        }
        if m.peek8(request + Self.ioFlags) & Self.iofQuick == 0 {
            if m.peek8(request + Self.lnType) == Self.ntReplyMsg {
                Self.remove(request, m)
            } else if inTask, let r = runningIndex {
                let port = m.peek32(request + Self.mnReplyPort)
                let bit: UInt32 = 1 << UInt32(m.peek8(port + Self.mpSigBit) & 31)
                let tcb = tasks[r].tcb
                let received = m.peek32(tcb + Self.tcSigRecvd)
                if received & bit != 0 {
                    m.poke32(tcb + Self.tcSigRecvd, received & ~bit)
                }
                m.poke32(tcb + Self.tcSigWait, bit)
                tasks[r].clearsOnRetry = bit
                // (To WaitIO's own TRAP: DoIO, too, goes on waiting, and does not begin its request again.)
                giveUp(&m, again: true, waiting: true, at: Self.stub(.waitIO))
                return
            }
        }
        m.cpu.registers[0] = UInt32(bitPattern: Int32(Int8(bitPattern: m.peek8(request + Self.ioError))))
    }

    /// CreateMsgPort: a port of the running task's, with a signal of its own.
    private mutating func createPort(_ m: inout AmigaMachine) -> UInt32 {
        guard let tcb = running else { return 0 }
        let allocated = m.peek32(tcb + Self.tcSigAlloc)
        guard let bit = stride(from: 31, through: 0, by: -1).first(where: { allocated & (1 << UInt32($0)) == 0 }) else { return 0 }
        let port = allocate(Self.portSize, clear: true, m)
        guard port != 0 else { return 0 }
        m.poke32(tcb + Self.tcSigAlloc, allocated | 1 << UInt32(bit))
        m.poke8(port + Self.lnType, Self.ntMsgPort)
        m.poke8(port + Self.mpSigBit, UInt8(bit))
        m.poke32(port + Self.mpSigTask, tcb)
        Self.newList(port + Self.mpMsgList, m)
        return port
    }

    // MARK: Interrupts' ends

    /// The end of an interrupt's handler, called by it as its last (a JSR before its RTE): if it goes back
    /// to no interrupt (the mask nought), audio.device's software interrupt has its turn first; and if it
    /// goes back to a task (user mode) and a task of higher priority than that one is ready, that one runs
    /// instead, as exec's ExitIntr has it.
    private mutating func exitInterrupt(_ m: inout AmigaMachine) {
        let frame = m.cpu.registers[15] &+ 4
        let status = UInt32(m.peek16(frame))
        if status & 0x0700 == 0 { softInterrupt(&m) }
        guard status & 0x2000 == 0, let r = runningIndex, let b = best, tasks[b].priority > tasks[r].priority else { return }
        // The task interrupted, kept as the interrupt found it.
        for i in 0 ..< 15 { tasks[r].registers[i] = m.cpu.registers[i] }
        tasks[r].registers[15] = m.cpu.userStack
        tasks[r].status = status
        tasks[r].pc = m.peek32(frame + 2)
        tasks[r].running = false
        makeReady(r, m)
        resume(b, &m)
    }

    /// After a routine called from a task (in user mode, its mask nought): audio.device's software
    /// interrupt has its turn at once, and a task it makes ready of higher priority runs.
    private mutating func afterDeviceCall(_ m: inout AmigaMachine) {
        guard m.cpu.statusRegister & 0x2700 == 0 else { return }
        softInterrupt(&m)
        preemptIfBetter(&m)
    }

    // MARK: Devices

    private mutating func openDevice(name: UInt32, unit: UInt32, request: UInt32, _ m: inout AmigaMachine) -> Bool {
        var bytes: [UInt8] = []
        for i in 0 ..< UInt32(32) {
            let b = m.peek8(name + i)
            if b == 0 { break }
            bytes.append(b)
        }
        let device = String(decoding: bytes, as: UTF8.self)
        var error: Int8 = 0
        switch device {
        case "audio.device":
            if !audio.opened {
                audio.opened = true
                // (Its handler of Paula's interrupts, in the vector of level 4.)
                m.poke32(0x70, audioLevel4At)
            }
            error = audioOpen(request, &m)
        case "timer.device":
            guard unit == 1 else {
                failure = "a player that times itself by a unit of timer.device other than the frames'"
                return false
            }
            m.poke32(request + Self.ioUnit, Self.timerUnit)
        default:
            failure = "a player that opens \(device)"
            return false
        }
        if error == 0 { m.poke32(request + Self.ioDevice, device == "audio.device" ? Self.audioBase : Self.timerBase) }
        m.poke8(request + Self.ioError, UInt8(bitPattern: error))
        m.cpu.registers[0] = UInt32(bitPattern: Int32(error))
        return true
    }

    private mutating func closeDevice(_ request: UInt32, _ m: inout AmigaMachine) {
        if m.peek32(request + Self.ioDevice) == Self.audioBase { audioClose(request, &m) }
        afterDeviceCall(&m)
    }

    /// BeginIO, through the request's device.
    private mutating func beginIO(_ request: UInt32, _ m: inout AmigaMachine) -> Bool {
        switch m.peek32(request + Self.ioDevice) {
        case Self.audioBase: return audioBeginIO(request, &m)
        case Self.timerBase: return timerBeginIO(request, &m)
        default:
            failure = "a player that sends a request to a device it has not opened"
            return false
        }
    }

    private mutating func abortIO(_ request: UInt32, _ m: inout AmigaMachine) {
        switch m.peek32(request + Self.ioDevice) {
        case Self.audioBase: audioAbortIO(request, &m)
        case Self.timerBase: timerAbortIO(request, &m)
        default: break
        }
    }

    /// audio.device's BeginIO, and then its software interrupt if called from a task.
    private mutating func audioBeginIO(_ request: UInt32, _ m: inout AmigaMachine) -> Bool {
        guard audioCommand(request, &m) else { return false }
        afterDeviceCall(&m)
        return true
    }

    private mutating func audioAbortIO(_ request: UInt32, _ m: inout AmigaMachine) {
        audioAbort(request, &m)
        afterDeviceCall(&m)
    }

    /// timer.device's BeginIO: only TR_ADDREQUEST, a wait.
    private mutating func timerBeginIO(_ request: UInt32, _ m: inout AmigaMachine) -> Bool {
        guard m.peek16(request + Self.ioCommand) == 9 else {
            failure = "a player that asks timer.device for more than to wait"
            return false
        }
        m.poke8(request + Self.ioFlags, m.peek8(request + Self.ioFlags) & ~Self.iofQuick)
        m.poke8(request + Self.lnType, Self.ntMessage)
        m.poke8(request + Self.ioError, 0)
        timer.add(request, m)
        charge = 464
        return true
    }

    private mutating func timerAbortIO(_ request: UInt32, _ m: inout AmigaMachine) {
        guard timer.take(request) else { return }
        done(request, error: Self.aborted, m)
        preemptIfBetter(&m)
    }

    /// timer.device's frames, from the frame's interrupt: each wait that is over as the frame begins is
    /// replied.
    private mutating func timerFrame(_ m: inout AmigaMachine) {
        for request in timer.frame() { done(request, error: 0, m) }
    }
}
