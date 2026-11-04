public enum CardGeometry {
    public static let width = 320.0
    public static let titleHeight = 46.0
    public static let headerHeight = 98.0
    public static let bodyHeight = 420.0

    public static func height(expanded: Bool) -> Double {
        headerHeight + (expanded ? bodyHeight : 0)
    }
}
