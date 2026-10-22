// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// The C library's mathematics, declared here so that the library need import no platform's C module:
// every platform Swift runs on has these functions, but each has them in a module of a different name,
// and Embedded Swift has no such module on some of them. They are the same functions Foundation would
// have supplied.

@_extern(c, "sin") package func sin(_ x: Double) -> Double
@_extern(c, "cos") package func cos(_ x: Double) -> Double
@_extern(c, "tan") package func tan(_ x: Double) -> Double
@_extern(c, "tanh") package func tanh(_ x: Double) -> Double
@_extern(c, "exp") package func exp(_ x: Double) -> Double
@_extern(c, "log") package func log(_ x: Double) -> Double
@_extern(c, "log1p") package func log1p(_ x: Double) -> Double
@_extern(c, "log10") package func log10(_ x: Double) -> Double
@_extern(c, "pow") package func pow(_ x: Double, _ y: Double) -> Double
@_extern(c, "hypot") package func hypot(_ x: Double, _ y: Double) -> Double
@_extern(c, "ceil") package func ceil(_ x: Double) -> Double
@_extern(c, "floor") package func floor(_ x: Double) -> Double
@_extern(c, "sinf") package func sinf(_ x: Float) -> Float
@_extern(c, "cosf") package func cosf(_ x: Float) -> Float
@_extern(c, "expf") package func expf(_ x: Float) -> Float
@_extern(c, "asinf") package func asinf(_ x: Float) -> Float
@_extern(c, "atan2f") package func atan2f(_ y: Float, _ x: Float) -> Float
@_extern(c, "powf") package func powf(_ x: Float, _ y: Float) -> Float
@_extern(c, "logf") package func logf(_ x: Float) -> Float
@_extern(c, "tanf") package func tanf(_ x: Float) -> Float
@_extern(c, "sinhf") package func sinhf(_ x: Float) -> Float
