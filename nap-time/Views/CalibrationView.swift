import SwiftUI

struct CalibrationView: View {
    @State private var taps: [(id: UUID, point: CGPoint)] = []
    @State private var lastTap: CGPoint?
    @State private var screenSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Grid lines every 50pt
                Canvas { context, size in
                    let gridSpacing: CGFloat = 50
                    for x in stride(from: 0, through: size.width, by: gridSpacing) {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
                    }
                    for y in stride(from: 0, through: size.height, by: gridSpacing) {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
                    }
                }

                // Tap markers
                ForEach(taps, id: \.id) { tap in
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                        .position(tap.point)

                    // Crosshair
                    Path { path in
                        path.move(to: CGPoint(x: tap.point.x - 20, y: tap.point.y))
                        path.addLine(to: CGPoint(x: tap.point.x + 20, y: tap.point.y))
                        path.move(to: CGPoint(x: tap.point.x, y: tap.point.y - 20))
                        path.addLine(to: CGPoint(x: tap.point.x, y: tap.point.y + 20))
                    }
                    .stroke(.red, lineWidth: 1)
                }

                // Coordinate label for last tap
                if let last = lastTap {
                    VStack(spacing: 4) {
                        Text("Tap: (\(Int(last.x)), \(Int(last.y))) pt")
                            .font(.system(.body, design: .monospaced))
                        Text("Screen: \(Int(geo.size.width)) x \(Int(geo.size.height)) pt")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .position(x: geo.size.width / 2, y: 80)
                }

                if taps.isEmpty {
                    VStack(spacing: 8) {
                        Text("Tap Calibration")
                            .font(.title2.bold())
                        Text("Tap anywhere to see coordinates")
                            .foregroundStyle(.secondary)
                        Text("Screen: \(Int(geo.size.width)) x \(Int(geo.size.height)) pt")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { location in
                let tap = (id: UUID(), point: location)
                taps.append(tap)
                lastTap = location
                // Keep only last 10 taps
                if taps.count > 10 {
                    taps.removeFirst()
                }
            }
            .onAppear {
                screenSize = geo.size
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") {
                    taps.removeAll()
                    lastTap = nil
                }
            }
        }
    }
}
