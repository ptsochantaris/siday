// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import ElementaryUI

@main
struct App {
    static func main() {
        Application(PlayerView()).mount(in: "#app")
    }
}
