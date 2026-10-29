// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayFoundation

/// The state of an SC-55, its controller's and its PCM chip's, as bytes: taken once its firmware has started,
/// and put back into another, which is then as it would be had it started itself. Both ways go through the
/// one list of what there is to keep (`keep(_:)` of each part), so that nothing can be taken and not put
/// back. The bytes are only ever read by the build that wrote them.
struct SC55State {
    private(set) var bytes: [UInt8]
    private var at = 0
    private let taking: Bool

    /// To take a synthesiser's state.
    init() {
        bytes = []
        taking = true
    }

    /// To put one back.
    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        taking = false
    }

    mutating func keep<Value: FixedWidthInteger>(_ value: inout Value) {
        let size = Value.bitWidth / 8
        if taking {
            for i in 0 ..< size { bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        } else {
            var read: Value = 0
            for i in 0 ..< size { read |= Value(truncatingIfNeeded: bytes[at + i]) << (i * 8) }
            value = read
            at += size
        }
    }

    mutating func keep(_ value: inout Bool) {
        var byte: UInt8 = value ? 1 : 0
        keep(&byte)
        value = byte != 0
    }

    mutating func keep<Value: FixedWidthInteger>(_ values: UnsafeMutablePointer<Value>, count: Int) {
        for i in 0 ..< count { keep(&values[i]) }
    }
}

extension SC55MCU {
    /// Everything about the controller that changes as it runs (its ROMs do not).
    func keep(_ state: inout SC55State) {
        state.keep(r, count: 8)
        state.keep(&pc)
        state.keep(&sr)
        state.keep(&cp)
        state.keep(&dp)
        state.keep(&ep)
        state.keep(&tp)
        state.keep(&br)
        state.keep(&sleeping)
        state.keep(&exceptionIgnored)
        state.keep(&exceptionPending)
        state.keep(&interruptsPending)
        state.keep(&trapsPending)
        state.keep(&cycles)
        state.keep(ram, count: Self.ramSize)
        state.keep(sram, count: Self.sramSize)
        state.keep(devices, count: 0x80)
        state.keep(&ioSelect)
        state.keep(&gateLines)
        state.keep(&gateEnable)
        state.keep(&gateTrigger)
        state.keep(&lcdCounter)
        state.keep(&analogReadFlag)
        state.keep(&analogEndTime)
        state.keep(&serialStatusRead)
        state.keep(uartBuffer, count: Self.uartBufferSize)
        state.keep(&uartWrite)
        state.keep(&uartRead)
        state.keep(&uartByte)
        state.keep(&uartRxDelay)
        state.keep(&uartTxDelay)
        state.keep(&operandType)
        state.keep(&operandEA)
        state.keep(&operandEP)
        state.keep(&operandWord)
        state.keep(&operandReg)
        state.keep(&operandData)
        state.keep(&opcodeExtended)
        for n in 0 ..< 3 {
            state.keep(&frts[n].deadline)
            state.keep(&frts[n].tcr)
            state.keep(&frts[n].tcsr)
            state.keep(&frts[n].frc)
            state.keep(&frts[n].ocra)
            state.keep(&frts[n].ocrb)
            state.keep(&frts[n].icr)
            state.keep(&frts[n].statusRead)
            state.keep(&frts[n].stride)
        }
        state.keep(&tmr.deadline)
        state.keep(&tmr.stride)
        state.keep(&tmr.tcr)
        state.keep(&tmr.tcsr)
        state.keep(&tmr.tcora)
        state.keep(&tmr.tcorb)
        state.keep(&tmr.tcnt)
        state.keep(&tmr.statusRead)
        state.keep(&timerCycles)
        state.keep(&timerEvent)
        state.keep(&timerTemp)
    }
}

extension SC55PCM {
    /// Everything about the chip that changes as it runs (not its wave ROMs, nor what is kept for the
    /// listener, which is set after it starts; nor the frames it has made, which are taken as they are made).
    func keep(_ state: inout SC55State) {
        state.keep(ram1, count: 32 * 8)
        state.keep(ram2, count: 32 * 16)
        state.keep(eram, count: 0x4000)
        state.keep(&cycles)
        state.keep(&voiceMask)
        state.keep(&voiceMaskPending)
        state.keep(&writeLatch)
        state.keep(&readLatch)
        state.keep(&waveReadAddress)
        state.keep(&tvCounter)
        state.keep(&waveByteLatch)
        state.keep(&selectChannel)
        state.keep(&config3C)
        state.keep(&config3D)
        state.keep(&irqChannel)
        state.keep(&irqAssert)
        state.keep(&voiceMaskUpdating)
        state.keep(&nfs)
        state.keep(&accumL)
        state.keep(&accumR)
        state.keep(&rcsum0)
        state.keep(&rcsum1)
        state.keep(&orValue)
        state.keep(&noiseMask)
        state.keep(&writeMask)
        state.keep(&oversampling)
        state.keep(&slots)
        state.keep(&outputCount)
        state.keep(envelopeAddLow, count: 5)
        for i in 0 ..< 5 { state.keep(&envelopeMoves[i]) }
    }
}
