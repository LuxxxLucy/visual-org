import AppKit
import WorkspaceCore

@MainActor
final class CanvasDetailLevel {
    private(set) var zoom = 1.0
    private var timer: Timer?
    private let changed: () -> Void

    init(changed: @escaping () -> Void) { self.changed = changed }

    func update(zoom: Double, shapeCount: Int) {
        timer?.invalidate()
        timer = nil
        guard shapeCount > CanvasCameraOptions.detailThreshold else { settle(zoom); return }
        let timer = Timer(timeInterval: CanvasCameraOptions.detailIdleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle(zoom) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func settle(_ value: Double) {
        timer = nil
        guard zoom != value else { return }
        zoom = value
        changed()
    }

    deinit { timer?.invalidate() }
}

@MainActor
final class CanvasGrid {
    private var path = NSBezierPath()
    private var cachedBounds = CGRect.zero
    private var cachedSpacing: Double = 0

    func draw(camera: CanvasCamera, size: CGSize, detailZoom: Double) {
        guard size.width > 0, size.height > 0 else { return }
        let spacing = 48 * pow(2, max(0, ceil(log2(8 / (48 * detailZoom)))))
        let visible = CGRect(x: -camera.x / camera.zoom, y: -camera.y / camera.zoom,
                             width: size.width / camera.zoom, height: size.height / camera.zoom)
        if cachedSpacing != spacing || !cachedBounds.contains(visible) {
            cachedSpacing = spacing
            cachedBounds = visible.insetBy(dx: -visible.width, dy: -visible.height)
            path.removeAllPoints()
            var x = floor(cachedBounds.minX / spacing) * spacing
            while x <= cachedBounds.maxX {
                path.move(to: CGPoint(x: x, y: cachedBounds.minY))
                path.line(to: CGPoint(x: x, y: cachedBounds.maxY))
                x += spacing
            }
            var y = floor(cachedBounds.minY / spacing) * spacing
            while y <= cachedBounds.maxY {
                path.move(to: CGPoint(x: cachedBounds.minX, y: y))
                path.line(to: CGPoint(x: cachedBounds.maxX, y: y))
                y += spacing
            }
        }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.transformStruct = NSAffineTransformStruct(m11: camera.zoom, m12: 0, m21: 0,
                                                            m22: camera.zoom, tX: camera.x, tY: camera.y)
        transform.concat()
        NSColor.white.withAlphaComponent(0.07).setStroke()
        path.lineWidth = 0.5 / camera.zoom
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
