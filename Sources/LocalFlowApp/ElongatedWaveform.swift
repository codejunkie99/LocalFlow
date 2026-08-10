import SwiftUI

struct ElongatedWaveform: View {
    let color: Color
    let amplitude: CGFloat
    let speed: Double
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * speed
                drawWave(in: context, size: size, phase: phase)
            }
        }
        .drawingGroup(opaque: false, colorMode: .linear)
    }

    private func drawWave(in context: GraphicsContext, size: CGSize, phase: Double) {
        for layer in 0..<3 {
            var path = Path()
            let layerScale = 1 - CGFloat(layer) * 0.22
            let layerPhase = phase + Double(layer) * 0.72
            let opacity = 0.9 - Double(layer) * 0.25

            for step in 0...64 {
                let progress = CGFloat(step) / 64
                let x = progress * size.width
                let envelope = sin(.pi * progress)
                let carrier = sin(Double(progress) * .pi * 4.2 + layerPhase)
                let detail = sin(Double(progress) * .pi * 8.4 - layerPhase * 0.62) * 0.22
                let y = size.height / 2
                    + CGFloat(carrier + detail) * amplitude * envelope * layerScale

                if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }

            context.stroke(
                path,
                with: .color(color.opacity(opacity)),
                style: StrokeStyle(
                    lineWidth: layer == 0 ? 1.55 : 0.75,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }
}
