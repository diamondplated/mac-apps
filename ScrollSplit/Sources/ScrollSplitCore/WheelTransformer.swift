import CoreGraphics

public struct WheelTransformer {
    public static let ownMarker: Int64 = 0x535343524F4C4C
    private let settings: ScrollSettings
    private var ticks = [WheelAccumulator(), WheelAccumulator()]
    private var points = [WheelAccumulator(), WheelAccumulator()]
    public init(settings: ScrollSettings) { self.settings = settings }
    public mutating func transform(_ event: CGEvent) {
        guard WheelClassifier.shouldTransform(
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            enabled: settings.enabled, isOwnEvent: event.getIntegerValueField(.eventSourceUserData) == Self.ownMarker
        ) else { return }
        let tickFields: [CGEventField] = [.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2]
        let pointFields: [CGEventField] = [.scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2]
        let fixedFields: [CGEventField] = [.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2]
        for axis in 0..<2 {
            let reverse = axis == 0 ? settings.reverseVertical : settings.reverseHorizontal
            let factor = settings.speedMultiplier * (reverse ? -1 : 1)
            // Quartz updates the point/fixed fields when the tick field changes.
            // Capture all representations before writing any of them.
            let tick = event.getIntegerValueField(tickFields[axis])
            let point = event.getIntegerValueField(pointFields[axis])
            let fixed = event.getDoubleValueField(fixedFields[axis])
            event.setIntegerValueField(tickFields[axis], value: ticks[axis].scale(tick, factor: factor))
            event.setIntegerValueField(pointFields[axis], value: points[axis].scale(point, factor: factor))
            event.setDoubleValueField(fixedFields[axis], value: fixed * factor)
        }
    }
}
