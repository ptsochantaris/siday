// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation

enum Key {
    case pause, next, previous, nextSubsong, previousSubsong, quit
}

// Saved terminal state lives in globals so signal handlers can reach it.
private nonisolated(unsafe) var savedTermios = termios()
private nonisolated(unsafe) var termiosSaved = false

private func restoreTerminalState() {
    if termiosSaved {
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
    }
}

/// Single-key input from the controlling terminal. Does nothing when stdin is not a terminal.
enum Terminal {
    static let interactive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0

    static func enterKeyMode() {
        guard interactive, !termiosSaved, tcgetattr(STDIN_FILENO, &savedTermios) == 0 else { return }
        termiosSaved = true
        applyKeyMode()
        atexit { restoreTerminalState() }
        // Put the terminal back before dying, then let the default action run.
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGSEGV, SIGBUS, SIGTRAP, SIGABRT, SIGILL, SIGFPE] {
            signal(sig) { number in
                restoreTerminalState()
                signal(number, SIG_DFL)
                raise(number)
            }
        }
        signal(SIGTSTP) { _ in
            restoreTerminalState()
            signal(SIGTSTP, SIG_DFL)
            raise(SIGTSTP)
        }
        signal(SIGCONT) { _ in
            Terminal.applyKeyMode()
            signal(SIGTSTP) { _ in
                restoreTerminalState()
                signal(SIGTSTP, SIG_DFL)
                raise(SIGTSTP)
            }
        }
    }

    fileprivate static func applyKeyMode() {
        guard termiosSaved else { return }
        var raw = savedTermios
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
        withUnsafeMutablePointer(to: &raw.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }

    static func restore() {
        restoreTerminalState()
        termiosSaved = false
    }

    /// Waits up to `timeout` milliseconds for a key.
    static func readKey(timeout: Int32) -> Key? {
        guard interactive else {
            usleep(useconds_t(timeout) * 1000)
            return nil
        }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, timeout) > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 8)
        let n = read(STDIN_FILENO, &bytes, 8)
        guard n > 0 else { return nil }
        if n >= 3, bytes[0] == 0x1B, bytes[1] == UInt8(ascii: "[") {
            switch bytes[2] {
            case UInt8(ascii: "C"): return .next
            case UInt8(ascii: "D"): return .previous
            case UInt8(ascii: "A"): return .nextSubsong
            case UInt8(ascii: "B"): return .previousSubsong
            default: return nil
            }
        }
        switch bytes[0] {
        case UInt8(ascii: " "): return .pause
        case UInt8(ascii: "n"), UInt8(ascii: "N"), 0x0A, 0x0D: return .next
        case UInt8(ascii: "p"), UInt8(ascii: "P"): return .previous
        case UInt8(ascii: "+"), UInt8(ascii: "="): return .nextSubsong
        case UInt8(ascii: "-"), UInt8(ascii: "_"): return .previousSubsong
        case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x1B: return .quit
        default: return nil
        }
    }

    static var width: Int {
        var size = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 { return Int(size.ws_col) }
        return 80
    }
}

func formatTime(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Parses "m:ss" or plain seconds.
func parseTime(_ text: String) -> Double? {
    let parts = text.split(separator: ":")
    switch parts.count {
    case 1: return Double(parts[0])
    case 2:
        guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
        return m * 60 + s
    default: return nil
    }
}
