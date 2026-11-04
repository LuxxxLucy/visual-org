import AppKit
import Combine
import Foundation
import WorkspaceCore

@MainActor
final class CanvasViewport: ObservableObject {
    @Published private(set) var value = CanvasCamera()

    private struct Animation {
        let start: CanvasCamera
        let target: CanvasCamera
        let began: TimeInterval
        let viewportWidth: Double
    }

    private var animation: Animation?
    private var timer: Timer?
    var isAnimating: Bool { animation != nil }

    func move(to target: CanvasCamera, viewportSize: CGSize, animated: Bool = true) {
        stopAnimation()
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              viewportSize.width.isFinite, viewportSize.width > 0, value != target else {
            value = target
            return
        }
        animation = Animation(start: value, target: target, began: ProcessInfo.processInfo.systemUptime,
                              viewportWidth: viewportSize.width)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceAnimation() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAnimation() {
        timer?.invalidate()
        timer = nil
        animation = nil
    }

    private func advanceAnimation() {
        guard let animation else { return }
        let progress = (ProcessInfo.processInfo.systemUptime - animation.began) / CanvasCameraOptions.animationDuration
        if progress >= 1 {
            stopAnimation()
            value = animation.target
        } else {
            value = animation.start.interpolated(to: animation.target, progress: progress, viewportWidth: animation.viewportWidth)
        }
    }

    func pan(_ delta: CGSize) {
        guard delta.width.isFinite, delta.height.isFinite else { return }
        stopAnimation()
        value = CanvasCamera(x: value.x + delta.width, y: value.y + delta.height, zoom: value.zoom)
    }

    func magnify(_ factor: Double, around anchor: CGPoint) {
        stopAnimation()
        value = value.zoomed(to: value.zoom * factor, around: CanvasPoint(x: anchor.x, y: anchor.y))
    }

    func zoom(wheelDelta: Double, around anchor: CGPoint) {
        stopAnimation()
        value = value.zoomed(wheelDelta: wheelDelta, around: CanvasPoint(x: anchor.x, y: anchor.y))
    }

    deinit { timer?.invalidate() }
}
