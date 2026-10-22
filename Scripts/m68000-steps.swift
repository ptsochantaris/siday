// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Writes the steps that siday's 68000 runs its instructions by (`M68000Step`), and the switch that
// takes each to its own:
//
//     swift Scripts/m68000-steps.swift
//
// It writes Sources/SidayKit/M68000/M68000Steps.swift, which is to be committed with this whenever
// this changes. Run it from the top of the repository.
//
// The steps are kept out of SidayKit's module for its users (`@export(interface)`): the web player's
// Embedded Swift would otherwise write every one of them into it whole, and it would grow too big for
// the compiler to read back.
//
// A step is a function of its own, given the processor's pace and giving it back (see `M68000Pace`),
// which calls the work of its instruction in M68000.swift. There is a step for each instruction that
// works out its operands' addressing modes, and its size, condition or kind of operation where it has
// one, from the opcode as it runs; and for the instructions a tune's code runs most there are steps
// made for each of their modes as well, given those as constants, so that the compiler holds each such
// step to the modes it is for. Which opcode runs which step is worked out in M68000.swift
// (`M68000Step.table`), which asks the generated `specialised` for a step of the second kind.

import Foundation

/// One of the things a step can be made for, worked out from the opcode by a step that is not.
struct Axis {
    /// What it is in a general step's call, and how a step made for one of its values is found.
    let fromOpcode: String
    /// Its values, each as a step's name has it and as its call has it.
    let values: [(name: String, key: Int, call: String)]
}

let modeNames = ["dn", "an", "ind", "inc", "dec", "disp", "index", "absW", "absL", "pcDisp", "pcIndex", "imm"]

func modes(_ numbers: [Int], from expression: String) -> Axis {
    Axis(fromOpcode: expression, values: numbers.map { (modeNames[$0], $0, String($0)) })
}

let all = Array(0 ... 11)
let data = all.filter { $0 != 1 }
let alterable = [0, 2, 3, 4, 5, 6, 7, 8]
let memoryAlterable = [2, 3, 4, 5, 6, 7, 8]
let control = [2, 5, 6, 7, 8, 9, 10]

func source(_ numbers: [Int]) -> Axis { modes(numbers, from: "M68000Step.sourceMode(op)") }
func target(_ numbers: [Int]) -> Axis { modes(numbers, from: "M68000Step.targetMode(op)") }
let condition = Axis(fromOpcode: "(op >> 8) & 15", values: ["t", "f", "hi", "ls", "cc", "cs", "ne", "eq", "vc", "vs", "pl", "mi", "ge", "lt", "gt", "le"].enumerated().map { ($1, $0, String($0)) })

/// A step that runs an instruction of every mode, and those made from it for some of them: `call` is
/// its instruction's work in M68000.swift, with `{0}`, `{1}` and so on for its axes.
struct Step {
    let name: String
    let call: String
    var axes: [Axis] = []
}

let sizes = ["B", "W", "L"]
var steps: [Step] = []

for (number, name) in ["ori", "andi", "subi", "addi", "", "eori", "cmpi"].enumerated() where !name.isEmpty {
    for (size, letter) in sizes.enumerated() {
        steps.append(Step(name: name + letter, call: "immediate(op, \(number), \(size), to: {0}, &k)", axes: [source(alterable)]))
    }
}
let bits = Axis(fromOpcode: "(op >> 6) & 3", values: ["btst", "bchg", "bclr", "bset"].enumerated().map { ($1, $0, String($0)) })
steps.append(Step(name: "bitDynamic", call: "bitDynamic(op, {0}, to: {1}, &k)", axes: [bits, source(alterable)]))
steps.append(Step(name: "bitStatic", call: "bitStatic(op, {0}, to: {1}, &k)", axes: [bits, source(alterable)]))

for (size, letter) in sizes.enumerated() {
    steps.append(Step(name: "move" + letter, call: "move(op, \(size), from: {0}, to: {1}, &k)", axes: [source(size == 0 ? data : all), target(alterable)]))
}
steps.append(Step(name: "moveaB", call: "moveAddress(op, 0, from: {0}, &k)", axes: [source([])]))
steps.append(Step(name: "moveaW", call: "moveAddress(op, 1, from: {0}, &k)", axes: [source(all)]))
steps.append(Step(name: "moveaL", call: "moveAddress(op, 2, from: {0}, &k)", axes: [source(all)]))

steps.append(Step(name: "lea", call: "loadAddress(op, from: {0}, &k)", axes: [source(control)]))
steps.append(Step(name: "pea", call: "pushAddress(op, from: {0}, &k)", axes: [source(control)]))
steps.append(Step(name: "jsr", call: "jumpToSubroutine(op, from: {0}, &k)", axes: [source(control)]))
steps.append(Step(name: "jmp", call: "jump(op, from: {0}, &k)", axes: [source(control)]))
for (size, letter) in sizes.enumerated() {
    steps.append(Step(name: "clr" + letter, call: "clear(op, \(size), to: {0}, &k)", axes: [source(alterable)]))
    steps.append(Step(name: "tst" + letter, call: "test(op, \(size), from: {0}, &k)", axes: [source(alterable)]))
}
steps.append(Step(name: "neg", call: "negate(op, (op >> 6) & 3, to: {0}, &k)", axes: [source([])]))
steps.append(Step(name: "not", call: "complement(op, (op >> 6) & 3, to: {0}, &k)", axes: [source([])]))
steps.append(Step(name: "swap", call: "swapHalves(op, &k)"))
steps.append(Step(name: "extW", call: "extend(op, long: false, &k)"))
steps.append(Step(name: "extL", call: "extend(op, long: true, &k)"))
steps.append(Step(name: "movemStoreW", call: "moveMultiple(toMemory: true, long: false, op, &k)"))
steps.append(Step(name: "movemStoreL", call: "moveMultiple(toMemory: true, long: true, op, &k)"))
steps.append(Step(name: "movemLoadW", call: "moveMultiple(toMemory: false, long: false, op, &k)"))
steps.append(Step(name: "movemLoadL", call: "moveMultiple(toMemory: false, long: true, op, &k)"))
steps.append(Step(name: "nop", call: ""))
steps.append(Step(name: "rts", call: "returnFromSubroutine(&k)"))
steps.append(Step(name: "rte", call: "returnFromException(op, start, &k)"))

steps.append(Step(name: "dbra", call: "decrementAndBranch(op, 1, &k)"))
steps.append(Step(name: "dbcc", call: "decrementAndBranch(op, {0}, &k)", axes: [Axis(fromOpcode: condition.fromOpcode, values: condition.values.filter { $0.key != 1 })]))
steps.append(Step(name: "scc", call: "set(op, (op >> 8) & 15, to: {0}, &k)", axes: [source([])]))
steps.append(Step(name: "addqA", call: "quickAddress(op, subtracting: false, &k)"))
steps.append(Step(name: "subqA", call: "quickAddress(op, subtracting: true, &k)"))
for (size, letter) in sizes.enumerated() {
    steps.append(Step(name: "addq" + letter, call: "quick(op, \(size), subtracting: false, to: {0}, &k)", axes: [source(alterable)]))
    steps.append(Step(name: "subq" + letter, call: "quick(op, \(size), subtracting: true, to: {0}, &k)", axes: [source(alterable)]))
}
for (code, name) in ["bra", "bsr", "bhi", "bls", "bcc", "bcs", "bne", "beq", "bvc", "bvs", "bpl", "bmi", "bge", "blt", "bgt", "ble"].enumerated() {
    steps.append(Step(name: name, call: "branch(op, \(code), &k)"))
}
steps.append(Step(name: "moveq", call: "moveQuick(op, &k)"))

for (kind, name) in [("or", "or"), ("and", "and"), ("add", "add"), ("subtract", "sub")] {
    for (size, letter) in sizes.enumerated() {
        let anyAddress = (kind == "add" || kind == "subtract") && size != 0
        steps.append(Step(name: name + letter, call: "combine(op, .\(kind), \(size), intoRegister: true, {0}, &k)", axes: [source(anyAddress ? all : data)]))
        steps.append(Step(name: name + "Ea" + letter, call: "combine(op, .\(kind), \(size), intoRegister: false, {0}, &k)", axes: [source(memoryAlterable)]))
    }
}
let memory = Axis(fromOpcode: "op & 8 != 0", values: [("registers", 0, "false"), ("memory", 1, "true")])
for (size, letter) in sizes.enumerated() {
    steps.append(Step(name: "addx" + letter, call: "extended(op, adding: true, \(size), memory: {0}, &k)", axes: [memory]))
    steps.append(Step(name: "subx" + letter, call: "extended(op, adding: false, \(size), memory: {0}, &k)", axes: [memory]))
}
for (size, letter) in sizes.enumerated() {
    steps.append(Step(name: "eor" + letter, call: "combine(op, .eor, \(size), intoRegister: false, {0}, &k)", axes: [source(alterable)]))
    steps.append(Step(name: "cmp" + letter, call: "compare(op, \(size), from: {0}, &k)", axes: [source(size == 0 ? data : all)]))
}
for (size, letter) in [(1, "W"), (2, "L")] {
    steps.append(Step(name: "cmpa" + letter, call: "compareAddress(op, \(size), from: {0}, &k)", axes: [source(all)]))
    steps.append(Step(name: "adda" + letter, call: "addAddress(op, \(size), subtracting: false, from: {0}, &k)", axes: [source(all)]))
    steps.append(Step(name: "suba" + letter, call: "addAddress(op, \(size), subtracting: true, from: {0}, &k)", axes: [source(all)]))
}
steps.append(Step(name: "mulu", call: "multiply(op, signed: false, from: {0}, &k)", axes: [source(data)]))
steps.append(Step(name: "muls", call: "multiply(op, signed: true, from: {0}, &k)", axes: [source(data)]))
steps.append(Step(name: "shiftRegister", call: "shiftRegister(op, {0}, left: {1}, {2}, byRegister: {3}, &k)", axes: [
    Axis(fromOpcode: "(op >> 3) & 3", values: ["as", "ls", "rox", "ro"].enumerated().map { ($1, $0, String($0)) }),
    Axis(fromOpcode: "op & 0x100 != 0", values: [("r", 0, "false"), ("l", 1, "true")]),
    Axis(fromOpcode: "(op >> 6) & 3", values: sizes.enumerated().map { ($1, $0, String($0)) }),
    Axis(fromOpcode: "op & 0x20 != 0", values: [("byCount", 0, "false"), ("byRegister", 1, "true")]),
]))

/// Those a tune's code seldom runs, which all run by one step (`M68000.seldom`).
let seldom = ["movep", "immediateToStatus", "chk", "moveFromStatus", "negx", "moveToConditions", "moveToStatus",
              "nbcd", "tas", "trap", "link", "unlink", "moveUserStack", "resetInstruction", "stopInstruction",
              "trapv", "rtr", "divide", "decimal", "cmpm", "exchange", "shiftMemory", "unimplemented",
              "illegal"]

/// Every combination of the axes' values: a step's name, its call and its key.
func combinations(_ step: Step) -> [(name: String, call: String, key: [Int])] {
    var made: [(String, String, [Int])] = [(step.name, step.call, [])]
    for (index, axis) in step.axes.enumerated() {
        made = made.flatMap { name, call, key in
            axis.values.map { value in (name + "_" + value.name, call.replacingOccurrences(of: "{\(index)}", with: value.call), key + [value.key]) }
        }
    }
    return step.axes.isEmpty || step.axes.contains(where: \.values.isEmpty) ? [] : made
}

func general(_ step: Step) -> String {
    var call = step.call
    for (index, axis) in step.axes.enumerated() { call = call.replacingOccurrences(of: "{\(index)}", with: axis.fromOpcode) }
    return call
}

/// A step's key, all its axes' values in one number, four bits to each.
func key(_ values: [Int]) -> Int { values.reduce(0) { $0 << 4 | $1 } }

func keyExpression(_ step: Step) -> String {
    step.axes.enumerated().reversed().map { index, axis in
        let shift = 4 * (step.axes.count - 1 - index)
        let value = axis.fromOpcode.hasSuffix("!= 0") ? "(\(axis.fromOpcode) ? 1 : 0)" : "(\(axis.fromOpcode))"
        return shift == 0 ? value : "\(value) << \(shift)"
    }.reversed().joined(separator: " | ")
}

var cases: [String] = []
var dispatch = ""
var functions = ""
var lookup = ""
func addStep(_ name: String, _ call: String) {
    cases.append(name)
    dispatch += "        case .\(name): return run_\(name)(op, start, k)\n"
    if call.isEmpty {
        functions += "    @export(interface) @inline(never) mutating func run_\(name)(_: UInt32, _: UInt32, _ k: M68000Pace) -> M68000Pace { k }\n\n"
    } else {
        functions += """
            @export(interface) @inline(never) mutating func run_\(name)(_ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
                var k = k
                \(call)
                return k
            }


        """
    }
}
for step in steps {
    addStep(step.name, general(step))
}
for step in steps {
    let made = combinations(step)
    guard !made.isEmpty else { continue }
    lookup += "        case .\(step.name):\n            switch \(keyExpression(step)) {\n"
    for (name, call, values) in made {
        addStep(name, call)
        lookup += "            case \(key(values)): return .\(name)\n"
    }
    lookup += "            default: return nil\n            }\n"
}
cases += seldom
dispatch += "        case " + seldom.map { "." + $0 }.joined(separator: ", ") + ":\n            return seldom(step, op, start, k)\n"

func wrapped(_ names: [String]) -> String {
    var lines: [String] = []
    var line = "    case"
    for name in names {
        if line.count + name.count > 112 {
            lines.append(String(line.dropLast()))
            line = "    case"
        }
        line += " \(name),"
    }
    lines.append(String(line.dropLast()))
    return lines.joined(separator: "\n")
}

let swift = """
// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// Made by Scripts/m68000-steps.swift, which is where to change it. Do not edit.

/// What runs an opcode (`M68000.resume`): a step that runs an instruction of every mode, a step made for
/// some of its modes (or its size, condition or kind), or one of those a tune's code seldom runs.
enum M68000Step {
\(wrapped(cases))
}

extension M68000Step {
    /// The step made for an opcode's modes, if there is one, beside the step that runs any.
    @export(interface) static func specialised(_ step: M68000Step, _ op: UInt32) -> M68000Step? {
        switch step {
\(lookup)        default: return nil
        }
    }
}

extension M68000 {
    @inline(__always) mutating func run(_ step: M68000Step, _ op: UInt32, _ start: UInt32, _ k: M68000Pace) -> M68000Pace {
        switch step {
\(dispatch)        }
    }

\(functions.dropLast(1))}

"""
try swift.write(toFile: "Sources/SidayKit/M68000/M68000Steps.swift", atomically: true, encoding: .utf8)
print("\(cases.count) steps")
