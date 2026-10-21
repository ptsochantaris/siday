// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A spectrum analyser: a bar for each band of pitch, low notes on the left, each with a cap that stays
/// a moment where the bar last reached, drawn as a row of lights, the lights that are out only just
/// to be seen. The colours run through the rainbow, because they should.
struct Analyser: View {
    let bars: [Float]
    let caps: [Float]
    @ScaledMetric(relativeTo: .body) private var height = 72
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, size in
            let count = max(1, bars.count)
            let gap: CGFloat = 4
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            // Lights 5 points high with 2 between them, as many as fit.
            let step: CGFloat = 7, light: CGFloat = 5
            let rows = Int(size.height / step)
            // The lights that are out are there too, only just to be seen: a whisper off the ground.
            let unlit = scheme == .light ? Color(white: 0.955) : Color(white: 0.075)
            for band in bars.indices {
                let colour = Color(hue: Double(band) * 290 / 360 / Double(max(1, count - 1)), saturation: 0.95, brightness: contrast == .increased ? 0.85 : 1)
                let x = CGFloat(band) * (width + gap)
                let lit = Int((CGFloat(max(0, min(1, bars[band]))) * CGFloat(rows)).rounded())
                for row in lit ..< max(lit, rows) {
                    let y = size.height - CGFloat(row + 1) * step + (step - light)
                    context.fill(Path(CGRect(x: x, y: y, width: width, height: light)), with: .color(unlit))
                }
                for row in 0 ..< lit {
                    let y = size.height - CGFloat(row + 1) * step + (step - light)
                    context.fill(Path(CGRect(x: x, y: y, width: width, height: light)), with: .color(colour.opacity(0.9)))
                }
                if band < caps.count, caps[band] > 0 {
                    let y = size.height - CGFloat(max(0, min(1, caps[band]))) * size.height
                    context.fill(Path(CGRect(x: x, y: max(0, y - 2), width: width, height: 2)), with: .color(colour))
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
