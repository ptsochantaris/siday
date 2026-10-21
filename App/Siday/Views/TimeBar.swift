// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Where in the song the sound is. Pressed or dragged, it moves there. Behind the part played is the
/// part that is ready to be moved to at once; the rest has to be waited for. On a Mac, the time under
/// the pointer is shown above it.
struct TimeBar: View {
    @Environment(PlayerModel.self) private var model
    let position: Double
    let rendered: Double
    let length: Double

    @State private var pointed: Double?
    @State private var dragging: Double?
    @ScaledMetric(relativeTo: .body) private var thickness = 6

    var body: some View {
        HStack(spacing: 10) {
            Text(time(dragging ?? position)).monospacedDigit()
            GeometryReader { space in
                let width = max(1, space.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.45))
                    Capsule().fill(Color.primary.opacity(0.65))
                        .frame(width: width * fraction(rendered))
                    Capsule().fill(.tint)
                        .frame(width: width * fraction(dragging ?? position))
                        .opacity(position > rendered + 0.05 ? 0.5 : 1)
                }
                .frame(height: thickness)
                // (Over the bar, and not in with it, which would make the bar as tall as the mark.)
                .overlay(alignment: .leading) {
                    if let place = pointed ?? dragging {
                        Rectangle().fill(.primary).frame(width: 1, height: thickness * 2.5)
                            .offset(x: width * fraction(place))
                            .overlay(alignment: .top) {
                                Text(time(place)).font(.caption).monospacedDigit()
                                    .padding(.horizontal, 4).background(.regularMaterial, in: .capsule)
                                    .fixedSize()
                                    .offset(x: width * fraction(place), y: -thickness * 3.5)
                            }
                    }
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragging = seconds(at: $0.location.x, of: width) }
                    .onEnded {
                        model.seek(to: seconds(at: $0.location.x, of: width))
                        dragging = nil
                    })
                .onContinuousHover { phase in
                    if case .active(let point) = phase { pointed = seconds(at: point.x, of: width) } else { pointed = nil }
                }
            }
            .frame(height: thickness * 4)
            Text(time(length)).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .ignore)
        .accessibilityRepresentation {
            Slider(value: Binding(get: { position }, set: { model.seek(to: $0) }), in: 0 ... max(length, 0.1), step: 5) {
                Text("Position")
            }
            .accessibilityValue(Text("\(time(position)) of \(time(length))"))
        }
    }

    private func fraction(_ seconds: Double) -> CGFloat {
        guard length > 0 else { return 0 }
        return CGFloat(max(0, min(1, seconds / length)))
    }

    private func seconds(at x: CGFloat, of width: CGFloat) -> Double {
        Double(max(0, min(1, x / width))) * length
    }
}

func time(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}
