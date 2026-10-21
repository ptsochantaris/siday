// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SidayKit
import SwiftUI

/// The picture to listen by, painted from what the voices are doing (see SidayKit's `Visualiser`), small
/// and stretched soft over its place. It is calm: slower still if the listener would rather things
/// moved less.
struct Picture: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False while another picture is being painted (the one on the whole screen): there is one
    /// painter, and a picture of another size would start it again from black on every frame.
    var painting = true

    var body: some View {
        GeometryReader { space in
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 / 10 : nil, paused: !painting)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let image = painting ? paint(space.size, at: time, slowed: reduceMotion) : nil
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                } else {
                    Color.black
                }
            }
        }
        .background(.black)
        .accessibilityElement()
        .accessibilityLabel(Text("Picture: \(model.picture.title)"))
    }

    private func paint(_ space: CGSize, at seconds: Double, slowed: Bool) -> CGImage? {
        let visualiser = model.visualiser
        let size = Visualiser.size(for: space.width, space.height)
        visualiser.resize(width: size.width, height: size.height)
        // What the voices are doing comes with each frame the player works out (see `Display`), which
        // the picture asks for too: on the whole screen it is all there is to ask.
        _ = model.frame(at: seconds)
        visualiser.paint(at: slowed ? seconds / 3 : seconds)
        guard let pixels = visualiser.pixels, visualiser.width > 0 else { return nil }
        let count = visualiser.width * visualiser.height * 4
        let data = Data(bytes: pixels, count: count) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: visualiser.width, height: visualiser.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: visualiser.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
