public enum CanvasCameraOptions {
    public static let zoomSteps = [0.05, 0.1, 0.25, 0.5, 1, 2, 4, 8]
    public static let zoomRange = zoomSteps[0]...zoomSteps[zoomSteps.count - 1]
    public static let wheelDeltaLimit = 10.0
    public static let wheelDeltaDivisor = 100.0
    public static let zoomSpeed = 1.0
    public static let animationDuration = 0.2
    public static let detailThreshold = 500
    public static let detailIdleDelay = 0.064
}

public enum CanvasZoomDirection {
    case `in`, out
}
