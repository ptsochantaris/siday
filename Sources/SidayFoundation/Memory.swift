// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

/// Memory that a class keeps by pointer, for speed, and that is given back when the class goes.
///
/// A class's `deinit` runs only for one that was wholly made. A loader that takes memory and then
/// finds that the file is not one it can play, and throws, would keep that memory for ever, a little
/// for every file it turned away. Held by the class beside its pointer, this is let go with whatever
/// else the class had been given when it threw, and the memory with it.
package final class Memory<Element> {
    package let pointer: UnsafeMutablePointer<Element>

    package init(capacity: Int) {
        pointer = .allocate(capacity: capacity)
    }

    deinit {
        pointer.deallocate()
    }
}
