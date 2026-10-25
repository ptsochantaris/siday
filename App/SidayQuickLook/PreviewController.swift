// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

#if os(macOS)
import AppKit
import Quartz

/// What Quick Look asks for a preview of a tune: a view of it (see `PreviewView`).
final class PreviewController: NSViewController, QLPreviewingController {
    private let preview = TunePreview()

    override func loadView() {
        view = NSHostingView(rootView: PreviewView(preview: preview))
        preferredContentSize = NSSize(width: 520, height: 360)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        try preview.open(url)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        preview.close()
    }
}

#else
import QuickLook
import UIKit

/// What Quick Look asks for a preview of a tune: a view of it (see `PreviewView`).
final class PreviewController: UIViewController, QLPreviewingController {
    private let preview = TunePreview()

    override func viewDidLoad() {
        super.viewDidLoad()
        let hosting = UIHostingController(rootView: PreviewView(preview: preview))
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        try preview.open(url)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        preview.close()
    }
}
#endif
