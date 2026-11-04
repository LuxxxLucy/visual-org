public struct CanvasPoint: Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct CanvasBounds: Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public extension CanvasCamera {
    func canvasPoint(at point: CanvasPoint) -> CanvasPoint {
        CanvasPoint(x: (point.x - x) / zoom, y: (point.y - y) / zoom)
    }

    func zoomed(to value: Double, around anchor: CanvasPoint) -> Self {
        guard value.isFinite else { return self }
        let next = min(CanvasCameraOptions.zoomRange.upperBound, max(CanvasCameraOptions.zoomRange.lowerBound, value))
        let ratio = next / zoom
        return Self(x: anchor.x - (anchor.x - x) * ratio,
                    y: anchor.y - (anchor.y - y) * ratio, zoom: next)
    }

    func zoomed(wheelDelta: Double, around anchor: CanvasPoint) -> Self {
        guard wheelDelta.isFinite else { return self }
        let limit = CanvasCameraOptions.wheelDeltaLimit
        let delta = min(limit, max(-limit, wheelDelta)) / CanvasCameraOptions.wheelDeltaDivisor
        return zoomed(to: zoom * (1 + delta * CanvasCameraOptions.zoomSpeed), around: anchor)
    }

    func zoomed(step direction: CanvasZoomDirection, around anchor: CanvasPoint) -> Self {
        let steps = CanvasCameraOptions.zoomSteps
        let intervals = Array(zip(steps, steps.dropFirst()))
        let next: Double
        switch direction {
        case .in:
            next = intervals.first { $0.1 - zoom > ($0.1 - $0.0) / 2 }?.1 ?? steps[steps.count - 1]
        case .out:
            next = intervals.reversed().first { $0.1 - zoom < ($0.1 - $0.0) / 2 }?.0 ?? steps[0]
        }
        return zoomed(to: next, around: anchor)
    }

    func interpolated(to target: Self, progress: Double, viewportWidth: Double) -> Self {
        guard progress.isFinite, progress > 0 else { return self }
        guard progress < 1, viewportWidth.isFinite, viewportWidth > 0 else { return target }
        let remaining = 1 - progress
        let t = progress < 0.5 ? 4 * progress * progress * progress : 1 - 4 * remaining * remaining * remaining
        let left = -x / zoom + (-target.x / target.zoom + x / zoom) * t
        let top = -y / zoom + (-target.y / target.zoom + y / zoom) * t
        let width = viewportWidth / zoom + (viewportWidth / target.zoom - viewportWidth / zoom) * t
        let scale = viewportWidth / width
        return Self(x: -left * scale, y: -top * scale, zoom: scale)
    }

    func focused(on point: CanvasPoint) -> Self {
        Self(x: 60 - point.x * zoom, y: 40 - point.y * zoom, zoom: zoom)
    }

    static func fitting(_ items: [CanvasBounds], width: Double, height: Double) -> Self? {
        guard let first = items.first else { return nil }
        var left = first.x, top = first.y
        var right = first.x + first.width, bottom = first.y + first.height
        for item in items.dropFirst() {
            left = min(left, item.x); top = min(top, item.y)
            right = max(right, item.x + item.width); bottom = max(bottom, item.y + item.height)
        }
        let zoom = min(1, max(CanvasCameraOptions.zoomRange.lowerBound, min((width - 80) / max(1, right - left),
                                       (height - 80) / max(1, bottom - top))))
        return Self(x: width / 2 - (left + right) / 2 * zoom,
                    y: height / 2 - (top + bottom) / 2 * zoom, zoom: zoom)
    }
}
