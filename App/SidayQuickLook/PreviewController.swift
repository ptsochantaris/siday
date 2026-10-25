// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

#if os(macOS)
import AppKit
import Quartz

/// What Quick Look asks for a preview of a tune: a view of it (see `PreviewView`).
final class PreviewController: NSViewController, QLPreviewingController {
    private let preview = TunePreview()
    private var level: NSKeyValueObservation?

    override func loadView() {
        view = NSHostingView(rootView: PreviewView(preview: preview))
        preferredContentSize = NSSize(width: 520, height: 360)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        try preview.open(url)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        preview.show(true)
        // Finder keeps the previews of the files either side of the one on show, and tells a kept one
        // nothing when it goes out of view or comes back into it; but its window is taken down from
        // the floating level while it is out of view, and put back when it returns.
        guard level == nil else { return }
        level = view.window?.observe(\.level, options: [.old, .new]) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, old != new else { return }
            MainActor.assumeIsolated { self?.preview.show(new > old) }
        }
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        preview.show(true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        preview.close()
    }
}
#endif
