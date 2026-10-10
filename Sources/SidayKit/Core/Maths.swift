// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// The C library's mathematics, declared here so that the library need import no platform's C module:
// every platform Swift runs on has these functions, but each has them in a module of a different name,
// and Embedded Swift has no such module on some of them. They are the same functions Foundation would
// have supplied.

@_extern(c, "sin") func sin(_ x: Double) -> Double
@_extern(c, "cos") func cos(_ x: Double) -> Double
@_extern(c, "tan") func tan(_ x: Double) -> Double
@_extern(c, "tanh") func tanh(_ x: Double) -> Double
@_extern(c, "exp") func exp(_ x: Double) -> Double
@_extern(c, "log") func log(_ x: Double) -> Double
@_extern(c, "log1p") func log1p(_ x: Double) -> Double
@_extern(c, "log10") func log10(_ x: Double) -> Double
@_extern(c, "pow") func pow(_ x: Double, _ y: Double) -> Double
@_extern(c, "hypot") func hypot(_ x: Double, _ y: Double) -> Double
@_extern(c, "ceil") func ceil(_ x: Double) -> Double
@_extern(c, "floor") func floor(_ x: Double) -> Double
@_extern(c, "sinf") func sinf(_ x: Float) -> Float
@_extern(c, "cosf") func cosf(_ x: Float) -> Float
@_extern(c, "expf") func expf(_ x: Float) -> Float
@_extern(c, "asinf") func asinf(_ x: Float) -> Float
@_extern(c, "atan2f") func atan2f(_ y: Float, _ x: Float) -> Float
